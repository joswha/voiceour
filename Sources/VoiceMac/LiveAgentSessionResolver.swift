import AppKit
import Darwin
import Foundation
import Synchronization
import VoiceCore

/// Binds a paste into Tern to the omp or Claude Code session running in the
/// focused pane, from live state, exactly or not at all.
///
/// `capture` asks Tern's signed CLI which pane has focus before the paste;
/// `resolve` asks again after it, together with Tern's layout, and binds only
/// when the same local pane and foreground process kept focus, Tern's focused
/// element is the terminal input, and the foreground process is the agent in
/// that pane's terminal. The session then comes from the agent's own records
/// (`AgentSessionLocator`).
///
/// One call runs at a time: a call made while another runs returns nil, and
/// after a CLI call times out every call returns nil for ten seconds.
public final class LiveAgentSessionResolver: AgentSessionResolving {
    static let ternBundleIdentifier = "so.stencil.tern"
    static let timeoutQuietPeriod: Duration = .seconds(10)
    static let processArguments = ["process", "@focused", "--json"]
    static let inspectArguments = ["inspect", "--json"]
    /// The titles Tern gives a block's terminal input.
    static let terminalInputTitles: Set<String> = ["Terminal input", "Terminal"]

    private let ternExecutable: @Sendable (pid_t) -> URL?
    private let runTern: @Sendable (URL, [String]) async -> TernRunOutcome
    private let isGenuineTern: @Sendable (pid_t, URL) -> Bool
    private let processFacts: @Sendable (Int32) -> ProcessFacts?
    private let focusedElement: @Sendable (pid_t) -> FocusedElementFacts?
    private let userID: UInt32
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let locator: AgentSessionLocator
    private let state = Mutex(State())

    private struct State {
        var running = false
        var quietUntil: ContinuousClock.Instant?
    }

    public convenience init(homeDirectory: URL) {
        let runner = TernCommandRunner(environment: ["HOME": homeDirectory.path, "PATH": "/usr/bin:/bin"])
        self.init(
            homeDirectory: homeDirectory,
            ternExecutable: Self.runningTernExecutable,
            runTern: { executable, arguments in await runner.run(executable: executable, arguments: arguments) },
            isGenuineTern: { pid, executable in TernSignature.isGenuine(pid: pid, executable: executable) },
            processFacts: { ProcessInspector.facts(pid: $0) },
            openFilePaths: { ProcessInspector.openFilePaths(pid: $0) },
            pidsOnTerminal: { ProcessInspector.pids(onTerminal: $0, uid: $1) },
            focusedElement: { FocusedElementReader.read(pid: $0) },
            fileSystem: .live
        )
    }

    init(
        homeDirectory: URL,
        ternExecutable: @escaping @Sendable (pid_t) -> URL?,
        runTern: @escaping @Sendable (URL, [String]) async -> TernRunOutcome,
        isGenuineTern: @escaping @Sendable (pid_t, URL) -> Bool,
        processFacts: @escaping @Sendable (Int32) -> ProcessFacts?,
        openFilePaths: @escaping @Sendable (Int32) -> [String],
        pidsOnTerminal: @escaping @Sendable (UInt32, UInt32) -> [Int32],
        focusedElement: @escaping @Sendable (pid_t) -> FocusedElementFacts?,
        fileSystem: AgentSessionFileSystem,
        userID: UInt32 = getuid(),
        timeZone: TimeZone = .autoupdatingCurrent,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.ternExecutable = ternExecutable
        self.runTern = runTern
        self.isGenuineTern = isGenuineTern
        self.processFacts = processFacts
        self.focusedElement = focusedElement
        self.userID = userID
        self.clock = clock
        locator = AgentSessionLocator(
            files: AgentSessionFiles(home: homeDirectory, fileSystem: fileSystem),
            processFacts: processFacts,
            openFilePaths: openFilePaths,
            pidsOnTerminal: pidsOnTerminal,
            timeZone: timeZone
        )
    }

    @concurrent
    public func capture(target: TargetSnapshot) async -> AgentFocusCapture? {
        guard Self.isTern(target), begin() else { return nil }
        var timedOut = false
        defer { end(timedOut: timedOut) }
        guard let tern = genuineTern(pid: target.pid) else { return nil }

        var outcome = await runTern(tern, Self.processArguments)
        timedOut = outcome == .timedOut
        guard let process = Self.decodeErasing(&outcome, TernReports.process(from:)) else { return nil }
        return AgentFocusCapture(pane: String(process.pane), foregroundPid: process.foregroundPid)
    }

    @concurrent
    public func resolve(target: TargetSnapshot, before: AgentFocusCapture) async -> ResolvedAgentSession? {
        guard Self.isTern(target), begin() else { return nil }
        var timedOut = false
        defer { end(timedOut: timedOut) }
        guard let tern = genuineTern(pid: target.pid) else { return nil }

        // Each child task decodes and zeroes its own output, so no copy of
        // the raw bytes outlives the call.
        async let processRun = Self.decodedRun(runTern, tern, Self.processArguments, TernReports.process(from:))
        async let inspectRun = Self.decodedRun(runTern, tern, Self.inspectArguments, TernReports.inspect(from:))
        let (processResult, inspectResult) = await (processRun, inspectRun)
        timedOut = processResult.timedOut || inspectResult.timedOut
        guard let process = processResult.report, let inspect = inspectResult.report, !Task.isCancelled else {
            return nil
        }

        // One local window, showing the pane that had focus before the paste,
        // still running the same foreground process.
        guard
            inspect.windowClientCount == 1,
            inspect.windowClientsAreLocal,
            inspect.shownFocusedBlock == process.pane,
            String(process.pane) == before.pane,
            process.foregroundPid == before.foregroundPid,
            let pane = inspect.panes[process.pane],
            pane.isLocal
        else { return nil }

        // The paste went to the block's terminal input, not another control.
        guard
            let element = focusedElement(target.pid),
            element.role == "AXTextArea",
            let title = element.title,
            Self.terminalInputTitles.contains(title)
        else { return nil }

        // The foreground process leads the foreground group of the pane's own
        // terminal.
        guard
            let foreground = processFacts(process.foregroundPid),
            foreground.pid == process.foregroundPid,
            foreground.uid == userID,
            let terminal = foreground.terminalDevice,
            foreground.processGroup == foreground.terminalForegroundGroup,
            let shell = processFacts(process.shellPid),
            shell.terminalDevice == terminal
        else { return nil }

        return locator.locate(foreground: foreground, ternSessionFile: pane.ompSessionFile)
    }

    // MARK: Tern

    private static func isTern(_ target: TargetSnapshot) -> Bool {
        target.bundleId == ternBundleIdentifier && target.pid > 0
    }

    /// The CLI inside the running Tern's bundle, when both are Tern's signed
    /// code.
    private func genuineTern(pid: pid_t) -> URL? {
        guard let executable = ternExecutable(pid), isGenuineTern(pid, executable) else { return nil }
        return executable
    }

    static func runningTernExecutable(pid: pid_t) -> URL? {
        guard
            let application = NSRunningApplication(processIdentifier: pid),
            application.bundleIdentifier == ternBundleIdentifier,
            let bundle = application.bundleURL
        else { return nil }
        return bundle.appending(path: "Contents/MacOS/tern", directoryHint: .notDirectory)
    }

    /// Runs the CLI and decodes its output in the calling task, which then
    /// zeroes it; only the report and whether the call timed out leave.
    private static func decodedRun<Report: Sendable>(
        _ run: @Sendable (URL, [String]) async -> TernRunOutcome,
        _ executable: URL,
        _ arguments: [String],
        _ decode: (Data) -> Report?
    ) async -> (report: Report?, timedOut: Bool) {
        var outcome = await run(executable, arguments)
        let timedOut = outcome == .timedOut
        return (decodeErasing(&outcome, decode), timedOut)
    }

    /// Decodes the CLI's output, then zeroes it: it can hold argv, working
    /// directories and titles, none of which is kept.
    private static func decodeErasing<Report>(
        _ outcome: inout TernRunOutcome,
        _ decode: (Data) -> Report?
    ) -> Report? {
        guard case .output(var data) = outcome else { return nil }
        // Drop the outcome's reference so the bytes are erased in place.
        outcome = .failed
        let report = decode(data)
        data.resetBytes(in: data.startIndex..<data.endIndex)
        return report
    }

    // MARK: Single flight

    private func begin() -> Bool {
        let now = clock()
        return state.withLock { state in
            if state.running { return false }
            if let quietUntil = state.quietUntil, now < quietUntil { return false }
            state.running = true
            return true
        }
    }

    private func end(timedOut: Bool) {
        let quietUntil = timedOut ? clock().advanced(by: Self.timeoutQuietPeriod) : nil
        state.withLock { state in
            state.running = false
            if let quietUntil {
                state.quietUntil = quietUntil
            }
        }
    }
}

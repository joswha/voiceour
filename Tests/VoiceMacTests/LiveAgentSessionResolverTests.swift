import Foundation
import Synchronization
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// The CLI calls a resolver made, and what each returns.
private final class FakeTern: Sendable {
    struct Script: Sendable {
        var process: TernRunOutcome
        var inspect: TernRunOutcome
    }

    private let state: Mutex<(script: Script, calls: [[String]])>
    /// When set, every call waits for it after signalling `entered`.
    let hold: TestGate?
    let entered = TestGate()

    init(_ script: Script, hold: TestGate? = nil) {
        state = Mutex((script, []))
        self.hold = hold
    }

    var calls: [[String]] {
        state.withLock { $0.calls }
    }

    func setScript(_ script: Script) {
        state.withLock { $0.script = script }
    }

    func run(_ executable: URL, _ arguments: [String]) async -> TernRunOutcome {
        let script = state.withLock { state in
            state.calls.append(arguments)
            return state.script
        }
        entered.fire()
        if let hold {
            await hold.wait()
        }
        return arguments.first == "inspect" ? script.inspect : script.process
    }
}

private final class TestClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant {
        instant.withLock { $0 }
    }

    func advance(by duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}

private let localHop = #"{"principal":"vlad","method":"local","from":"","host":"Mac","user":"vlad"}"#
private let remoteHop = #"{"principal":"vlad","method":"ssh","from":"10.0.0.2","host":"server","user":"vlad"}"#

/// One Tern window showing pane 884763263011, whose shell (100) runs omp (200)
/// in the foreground; every check passes unless a test changes it.
private struct Scenario {
    static let pane: UInt64 = 884_763_263_011
    static let target = TargetSnapshot(bundleId: "so.stencil.tern", appName: "Tern", pid: 900, safety: .normalText)
    static let before = AgentFocusCapture(pane: "884763263011", foregroundPid: 200)

    var home: FakeAgentHome
    var processPane: UInt64 = Scenario.pane
    var foregroundPid: Int32 = 200
    var shownFocusedBlock: UInt64 = Scenario.pane
    var windows = 1
    var windowHops = [localHop]
    var paneHops = [localHop]
    var ompSessionFile: String?
    var processes: [ProcessFacts] = [AgentFixtures.shell(), AgentFixtures.omp()]
    var openFiles: [String] = []
    var element: FocusedElementFacts? = FocusedElementFacts(role: "AXTextArea", title: "Terminal input")
    var genuine = true

    var processOutput: TernRunOutcome {
        let json =
            #"{"pane":\#(processPane),"child":{"pid":100,"name":"zsh","argv":["-zsh"],"cwd":"/Users/v"},"#
            + #""group":\#(foregroundPid),"foreground":{"pid":\#(foregroundPid),"name":"18.18.3","#
            + #""argv":["omp"],"cwd":"/Users/v"}}"#
        return .output(Data(json.utf8))
    }

    var inspectOutput: TernRunOutcome {
        let file = ompSessionFile.map { #""\#($0)""# } ?? "null"
        let blocks =
            #"{"id":\#(shownFocusedBlock),"program":"omp","focused":true},"#
            + #"{"id":5,"program":"/bin/zsh","focused":false}"#
        let sessions =
            #"[{"id":1,"name":"Default","shown":true,"tabs":["#
            + #"{"id":1,"shown":false,"blocks":[{"id":7,"focused":true}]},"#
            + #"{"id":2,"shown":true,"blocks":[\#(blocks)]}]}]"#
        let panes =
            #"[{"pane":\#(Scenario.pane),"program":"omp","cwd":"/Users/v","title":"t","#
            + #""omp_session_file":\#(file),"identity":{"hops":[\#(paneHops.joined(separator: ","))]}},"#
            + #"{"pane":5,"omp_session_file":null,"identity":{"hops":[\#(localHop)]}}]"#
        let window =
            #"{"conn":2,"window":"","kind":"window","since":1,"#
            + #""identity":{"hops":[\#(windowHops.joined(separator: ","))]}}"#
        let clients =
            Array(repeating: window, count: windows)
            + [#"{"conn":9,"kind":"cli","since":2,"identity":{"hops":[\#(localHop)]}}"#]
        let json =
            #"{"sessions":\#(sessions),"detached":[],"panes":\#(panes),"#
            + #""clients":[\#(clients.joined(separator: ","))]}"#
        return .output(Data(json.utf8))
    }

    var script: FakeTern.Script {
        FakeTern.Script(process: processOutput, inspect: inspectOutput)
    }

    func resolver(
        _ tern: FakeTern,
        clock: TestClock = TestClock()
    ) -> LiveAgentSessionResolver {
        let facts = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let openFiles = openFiles
        let element = element
        let genuine = genuine
        return LiveAgentSessionResolver(
            homeDirectory: home.url,
            ternExecutable: { _ in URL(fileURLWithPath: "/Applications/Tern.app/Contents/MacOS/tern") },
            runTern: { await tern.run($0, $1) },
            isGenuineTern: { _, _ in genuine },
            processFacts: { facts[$0] },
            openFilePaths: { _ in openFiles },
            pidsOnTerminal: { _, _ in Array(facts.keys) },
            focusedElement: { _ in element },
            fileSystem: .live,
            userID: AgentFixtures.uid,
            timeZone: TimeZone(identifier: "UTC")!,
            clock: { clock.now }
        )
    }

    func resolve() async -> ResolvedAgentSession? {
        await resolver(FakeTern(script)).resolve(target: Self.target, before: Self.before)
    }
}

@Suite("LiveAgentSessionResolver")
struct LiveAgentSessionResolverTests {
    private func makeScenario(_ home: FakeAgentHome) throws -> Scenario {
        try home.write(
            AgentFixtures.nextSessionFile,
            lines: AgentFixtures.ompHead(id: AgentFixtures.nextSessionId, title: "Next")
        )
        var scenario = Scenario(home: home)
        scenario.ompSessionFile = home.path(AgentFixtures.nextSessionFile)
        scenario.openFiles = [home.canonicalPath(AgentFixtures.nextSessionFile)]
        return scenario
    }

    @Test func captureReportsTheFocusedPaneAndForegroundProcess() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let scenario = try makeScenario(home)
        let tern = FakeTern(scenario.script)

        let capture = await scenario.resolver(tern).capture(target: Scenario.target)

        #expect(capture == Scenario.before)
        #expect(tern.calls == [["process", "@focused", "--json"]])
    }

    @Test func aTargetThatIsNotTernIsNeverAsked() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let scenario = try makeScenario(home)
        let tern = FakeTern(scenario.script)
        let resolver = scenario.resolver(tern)
        var other = Scenario.target
        other.bundleId = "com.mitchellh.ghostty"

        #expect(await resolver.capture(target: other) == nil)
        #expect(await resolver.resolve(target: other, before: Scenario.before) == nil)
        #expect(tern.calls.isEmpty)
    }

    @Test func theFocusedOmpPaneBindsItsSession() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let scenario = try makeScenario(home)
        let tern = FakeTern(scenario.script)

        let resolved = await scenario.resolver(tern).resolve(target: Scenario.target, before: Scenario.before)

        #expect(resolved?.agent == .omp)
        #expect(resolved?.sessionId == AgentFixtures.nextSessionId)
        #expect(resolved?.sessionTitle == "Next")
        #expect(Set(tern.calls) == [["process", "@focused", "--json"], ["inspect", "--json"]])
    }

    /// The live case: "Testing." pasted into a fresh omp session whose file
    /// did not exist yet. Tern's variable alone names it.
    @Test func aFreshOmpSessionNamedOnlyByTernBinds() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = Scenario(home: home)
        scenario.ompSessionFile = home.path(AgentFixtures.freshSessionFile)

        let resolved = await scenario.resolve()

        #expect(resolved?.sessionId == AgentFixtures.freshSessionId)
        #expect(resolved?.promptLogOffset == 0)
        #expect(resolved?.resumable == false)
    }

    @Test func theClaudeCodePaneBindsItsRegistrySession() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = Scenario(home: home)
        scenario.foregroundPid = 61208
        scenario.processes = [AgentFixtures.shell(), AgentFixtures.claude()]
        scenario.processes[0].terminalForegroundGroup = 61208
        scenario.element = FocusedElementFacts(role: "AXTextArea", title: "Terminal")
        try home.write(
            ".claude/sessions/61208.json",
            text: AgentFixtures.claudeRecord(pid: 61208, sessionId: AgentFixtures.claudeSessionId)
        )

        let resolved = await scenario.resolver(FakeTern(scenario.script))
            .resolve(target: Scenario.target, before: AgentFocusCapture(pane: "884763263011", foregroundPid: 61208))

        #expect(resolved?.agent == .claudeCode)
        #expect(resolved?.sessionId == AgentFixtures.claudeSessionId)
    }

    @Test func anInvalidSignatureRunsNothing() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = try makeScenario(home)
        scenario.genuine = false
        let tern = FakeTern(scenario.script)
        let resolver = scenario.resolver(tern)

        #expect(await resolver.capture(target: Scenario.target) == nil)
        #expect(await resolver.resolve(target: Scenario.target, before: Scenario.before) == nil)
        #expect(tern.calls.isEmpty)
    }

    @Test func twoWindowsBindNothing() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = try makeScenario(home)
        #expect(await scenario.resolve() != nil)

        scenario.windows = 2
        #expect(await scenario.resolve() == nil)
        scenario.windows = 0
        #expect(await scenario.resolve() == nil)
    }

    @Test func aRemoteWindowOrPaneBindsNothing() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = try makeScenario(home)
        scenario.windowHops = [localHop, remoteHop]
        #expect(await scenario.resolve() == nil)

        scenario.windowHops = [localHop]
        scenario.paneHops = [remoteHop]
        #expect(await scenario.resolve() == nil)
    }

    @Test func aPaneChangeAcrossThePasteBindsNothing() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = try makeScenario(home)

        // Tern now focuses another pane than before the paste.
        scenario.processPane = 5
        scenario.shownFocusedBlock = 5
        #expect(await scenario.resolve() == nil)

        // `process @focused` and the layout disagree.
        scenario.processPane = Scenario.pane
        scenario.shownFocusedBlock = 5
        #expect(await scenario.resolve() == nil)
    }

    @Test func aForegroundProcessChangeAcrossThePasteBindsNothing() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = try makeScenario(home)
        scenario.foregroundPid = 201
        scenario.processes.append(AgentFixtures.omp(pid: 201))

        #expect(await scenario.resolve() == nil)
    }

    @Test func focusOnAnythingButTheTerminalInputBindsNothing() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = try makeScenario(home)
        scenario.element = FocusedElementFacts(role: "AXTextField", title: "Terminal input")
        #expect(await scenario.resolve() == nil)

        scenario.element = FocusedElementFacts(role: "AXTextArea", title: "Find")
        #expect(await scenario.resolve() == nil)

        scenario.element = FocusedElementFacts(role: "AXTextArea", title: nil)
        #expect(await scenario.resolve() == nil)

        scenario.element = nil
        #expect(await scenario.resolve() == nil)
    }

    @Test func aForegroundProcessOnAnotherTerminalBindsNothing() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = try makeScenario(home)
        scenario.processes = [AgentFixtures.shell(terminal: 0x1000_0009), AgentFixtures.omp()]

        #expect(await scenario.resolve() == nil)
    }

    @Test func aProcessOutsideTheForegroundGroupBindsNothing() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = try makeScenario(home)
        scenario.processes[1].terminalForegroundGroup = 300

        #expect(await scenario.resolve() == nil)
    }

    @Test func aForegroundProcessOfAnotherUserOrWithoutATerminalBindsNothing() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        var scenario = try makeScenario(home)
        scenario.processes[1].uid = 0
        #expect(await scenario.resolve() == nil)

        scenario.processes[1].uid = AgentFixtures.uid
        scenario.processes[1].terminalDevice = nil
        #expect(await scenario.resolve() == nil)

        scenario.processes = [AgentFixtures.shell()]
        #expect(await scenario.resolve() == nil)
    }

    @Test func aCallWhileAnotherRunsReturnsNil() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let scenario = try makeScenario(home)
        let release = TestGate()
        let tern = FakeTern(scenario.script, hold: release)
        let resolver = scenario.resolver(tern)

        let first = Task { await resolver.capture(target: Scenario.target) }
        await tern.entered.wait()
        #expect(await resolver.capture(target: Scenario.target) == nil)
        #expect(await resolver.resolve(target: Scenario.target, before: Scenario.before) == nil)
        release.fire()

        #expect(await first.value == Scenario.before)
        #expect(tern.calls.count == 1)
        #expect(await resolver.capture(target: Scenario.target) == Scenario.before)
    }

    @Test func aTimeoutQuietsEveryCallForTenSeconds() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let scenario = try makeScenario(home)
        let tern = FakeTern(FakeTern.Script(process: .timedOut, inspect: .timedOut))
        let clock = TestClock()
        let resolver = scenario.resolver(tern, clock: clock)

        #expect(await resolver.capture(target: Scenario.target) == nil)
        tern.setScript(scenario.script)

        clock.advance(by: .seconds(9))
        #expect(await resolver.capture(target: Scenario.target) == nil)
        #expect(await resolver.resolve(target: Scenario.target, before: Scenario.before) == nil)
        #expect(tern.calls.count == 1)

        clock.advance(by: .seconds(1))
        #expect(await resolver.capture(target: Scenario.target) == Scenario.before)
    }

    @Test func aFailedCallDoesNotQuietLaterCalls() async throws {
        let home = try FakeAgentHome()
        defer { home.remove() }
        let scenario = try makeScenario(home)
        let tern = FakeTern(FakeTern.Script(process: .failed, inspect: .failed))
        let resolver = scenario.resolver(tern)

        #expect(await resolver.capture(target: Scenario.target) == nil)
        tern.setScript(scenario.script)
        #expect(await resolver.capture(target: Scenario.target) == Scenario.before)
    }
}

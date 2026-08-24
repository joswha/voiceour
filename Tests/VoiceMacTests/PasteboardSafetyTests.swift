import AppKit
import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

@Suite("PasteboardSafetyTests", .serialized)
struct PasteboardSafetyTests {
    @Test func targetSafetyMatrixCopiesOnlyForProtectedTargetsAndPastesOnlyAllowedTargets() async {
        struct MatrixCase {
            var name: String
            var safety: TargetSafetyClass
            var input: String
            var expectedClipboard: String
            var expectedOutcome: InsertionOutcome
            var expectedPostCount: Int
        }

        let cases = [
            MatrixCase(
                name: "secure",
                safety: .secure,
                input: "secret text",
                expectedClipboard: "secret text",
                expectedOutcome: .copiedOnly(reason: "target_secure"),
                expectedPostCount: 0
            ),
            MatrixCase(
                name: "code editor",
                safety: .codeEditor,
                input: "let value = 1",
                expectedClipboard: "let value = 1",
                expectedOutcome: .copiedOnly(reason: "target_codeEditor"),
                expectedPostCount: 0
            ),
            MatrixCase(
                name: "terminal strips one trailing newline",
                safety: .terminal,
                input: "rm -rf /tmp/example\n",
                expectedClipboard: "rm -rf /tmp/example",
                expectedOutcome: .copiedOnly(reason: "target_terminal"),
                expectedPostCount: 0
            ),
            // Unconditional, with no way for a caller to opt out. A failed AX
            // inspection lands here, so this class can be a password field the
            // app was unable to read.
            MatrixCase(
                name: "unknown risky is always copy-only",
                safety: .unknownRisky,
                input: "unknown target text",
                expectedClipboard: "unknown target text",
                expectedOutcome: .copiedOnly(reason: "target_unknownRisky"),
                expectedPostCount: 0
            ),
            MatrixCase(
                name: "normal text",
                safety: .normalText,
                input: "normal target text",
                expectedClipboard: "normal target text",
                expectedOutcome: .pasteAttempted,
                expectedPostCount: 1
            ),
        ]

        for testCase in cases {
            replacePasteboard(with: "sentinel: \(testCase.name)")
            let postPaste = PasteboardPostSpy(result: true)
            let tracker = SequencedTargetTracker(responses: [true, true])
            let inserter = PasteboardInserter(
                permissions: FakePermissions(synth: .granted),
                tracker: tracker,
                postPaste: { postPaste.post() },
                scheduleTransientClear: { _ in }
            )

            let outcome = await inserter.insert(testCase.input, into: target(safety: testCase.safety))

            #expect(outcome == testCase.expectedOutcome)
            #expect(postPaste.callCount == testCase.expectedPostCount)
            #expect(pasteboardString() == testCase.expectedClipboard)
        }
    }

    @Test func unknownRiskyCopyStripsExactlyOneTrailingNewline() async {
        replacePasteboard(with: "before unknown-risky copy")
        let postPaste = PasteboardPostSpy(result: true)
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: SequencedTargetTracker(responses: [true, true]),
            postPaste: { postPaste.post() },
            scheduleTransientClear: { _ in }
        )

        let outcome = await inserter.insert("echo safe\n\n", into: target(safety: .unknownRisky))

        #expect(outcome == .copiedOnly(reason: "target_unknownRisky"))
        #expect(postPaste.callCount == 0)
        #expect(pasteboardString() == "echo safe\n")
    }

    /// `.normalText` is the only class the policy will paste into, and nothing can
    /// widen that. The previous version of this policy took a
    /// `copyOnlyUnknownRisky` flag; no production caller ever passed `false`, but
    /// the knob contradicted the rule in AGENTS.md and became a live fail-open
    /// route once a failed AX inspection started resolving to `.unknownRisky`.
    @Test func onlyNormalTextIsEverPasteable() {
        for safety in [TargetSafetyClass.secure, .terminal, .codeEditor, .unknownRisky] {
            #expect(
                InsertionSafetyPolicy.disposition(for: safety)
                    == .copyOnly(reason: InsertionSafetyPolicy.targetClassReason(safety)),
                "\(safety.rawValue) must never be pasteable"
            )
        }
        #expect(InsertionSafetyPolicy.disposition(for: .normalText) == .paste)
    }

    /// End to end through a real tracker: a target whose AX inspection could not
    /// complete is captured as `.unknownRisky`, and the inserter must copy without
    /// posting Cmd-V even though synthetic paste is granted.
    @Test func targetWithUnavailableAXInspectionIsCopiedWithoutPosting() async {
        replacePasteboard(with: "before unreadable target")
        let postPaste = PasteboardPostSpy(result: true)
        let inspector = ScriptedFocusInspector([.unavailable])
        let tracker = safariTracker(inspector)
        let captured = tracker.snapshot()
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() },
            scheduleTransientClear: { _ in }
        )

        let outcome = await inserter.insert("unreadable focus text", into: captured)

        #expect(captured.safety == .unknownRisky)
        #expect(outcome == .copiedOnly(reason: "target_unknownRisky"))
        #expect(postPaste.callCount == 0)
        #expect(pasteboardString() == "unreadable focus text")
    }

    @Test func activeSecureInputMakesAnOrdinaryTargetCopyOnlyWithoutPosting() async {
        replacePasteboard(with: "before secure input")
        let postPaste = PasteboardPostSpy(result: true)
        let inspector = ScriptedFocusInspector([.inspected(role: "AXTextField", subrole: nil)])
        let tracker = safariTracker(inspector, secureInputActive: { true })
        let captured = tracker.snapshot()
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() }
        )

        let outcome = await inserter.insert("secure input text", into: captured)

        #expect(captured.secureInputActive)
        #expect(captured.safety == .secure)
        #expect(outcome == .copiedOnly(reason: "target_secure"))
        #expect(postPaste.callCount == 0)
        #expect(pasteboardString() == "secure input text")
    }

    @Test func inactiveSecureInputKeepsOrdinaryTargetPasteable() async {
        replacePasteboard(with: "before ordinary input")
        let postPaste = PasteboardPostSpy(result: true)
        let inspector = ScriptedFocusInspector([.inspected(role: "AXTextField", subrole: nil)])
        let tracker = safariTracker(inspector, secureInputActive: { false })
        let captured = tracker.snapshot()
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() },
            scheduleTransientClear: { _ in }
        )

        let outcome = await inserter.insert("ordinary input text", into: captured)

        #expect(!captured.secureInputActive)
        #expect(captured.safety == .normalText)
        #expect(outcome == .pasteAttempted)
        #expect(postPaste.callCount == 1)
        #expect(pasteboardString() == "ordinary input text")
    }

    @Test func grantedSyntheticPasteRequestPostsAndCopies() async {
        replacePasteboard(with: "before granted permission request")
        let postPaste = PasteboardPostSpy(result: true)
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .denied, requestSynth: true),
            tracker: SequencedTargetTracker(responses: [true, true]),
            postPaste: { postPaste.post() },
            scheduleTransientClear: { _ in }
        )

        let outcome = await inserter.insert("paste", into: target(safety: .normalText))

        #expect(outcome == .pasteAttempted)
        #expect(postPaste.callCount == 1)
        #expect(pasteboardString() == "paste")
    }

    @Test func beforeCopyFocusRaceCopiesWithoutPosting() async {
        replacePasteboard(with: "before pre-copy focus race")
        let postPaste = PasteboardPostSpy(result: true)
        let tracker = SequencedTargetTracker(responses: [false])
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() }
        )

        let outcome = await inserter.insert("must not be copied", into: target(safety: .normalText))

        #expect(outcome == .copiedOnly(reason: "target_changed_before_copy"))
        #expect(tracker.callCount == 1)
        #expect(postPaste.callCount == 0)
        #expect(pasteboardString() == "must not be copied")
    }

    /// C3: target identity is bundle id + pid + safety class. A web page
    /// auto-focusing a password input keeps the first two, so before this the
    /// change passed both checks and the field received synthetic Cmd-V.
    @Test func sameProcessFocusChangeToASecureFieldDegradesToCopyOnlyBeforeTheWrite() async {
        replacePasteboard(with: "before same-process focus change")
        let postPaste = PasteboardPostSpy(result: true)
        let inspector = ScriptedFocusInspector([
            .inspected(role: "AXTextField", subrole: nil),
            .inspected(role: "AXTextField", subrole: "AXSecureTextField"),
        ])
        let tracker = safariTracker(inspector)
        let captured = tracker.snapshot()
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() }
        )

        let outcome = await inserter.insert("must not reach a password field", into: captured)

        #expect(captured.safety == .normalText)
        #expect(outcome == .copiedOnly(reason: "target_changed_before_copy"))
        #expect(postPaste.callCount == 0)
    }

    @Test func sameProcessFocusChangeToASecureFieldDegradesToCopyOnlyAfterTheWrite() async {
        let postPaste = PasteboardPostSpy(result: true)
        let ordinary = TargetFocusInspection.inspected(role: "AXTextField", subrole: nil)
        let inspector = ScriptedFocusInspector([
            ordinary,
            ordinary,
            .inspected(role: "AXTextField", subrole: "AXSecureTextField"),
        ])
        let tracker = safariTracker(inspector)
        let captured = tracker.snapshot()
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() }
        )

        let outcome = await inserter.insert("late focus change", into: captured)

        #expect(outcome == .copiedOnly(reason: "target_changed_after_copy"))
        #expect(postPaste.callCount == 0)
        #expect(pasteboardString() == "late focus change")
    }

    /// Losing AX inspection mid-insert is the other half of C2: the target is
    /// now `.unknownRisky`, which no longer equals the captured `.normalText`.
    @Test func axInspectionFailingMidInsertDegradesToCopyOnly() async {
        let postPaste = PasteboardPostSpy(result: true)
        let ordinary = TargetFocusInspection.inspected(role: "AXTextField", subrole: nil)
        let inspector = ScriptedFocusInspector([ordinary, ordinary, .unavailable])
        let tracker = safariTracker(inspector)
        let captured = tracker.snapshot()
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() }
        )

        let outcome = await inserter.insert("inspection lost", into: captured)

        #expect(outcome == .copiedOnly(reason: "target_changed_after_copy"))
        #expect(postPaste.callCount == 0)
    }

    @Test func deniedSyntheticPastePermissionPromptsOnlyOncePerInserter() async {
        replacePasteboard(with: "before denied permission")
        let permissions = CountingDeniedPastePermissions()
        let inserter = PasteboardInserter(
            permissions: permissions,
            tracker: SequencedTargetTracker(responses: [])
        )

        let first = await inserter.insert("first transcript", into: target(safety: .normalText))
        let second = await inserter.insert("second transcript", into: target(safety: .normalText))

        #expect(first == .copiedOnly(reason: "synth_paste_permission"))
        #expect(second == .copiedOnly(reason: "synth_paste_permission"))
        #expect(permissions.requestCount == 1)
        #expect(pasteboardString() == "second transcript")
    }

    @Test func afterCopyFocusRaceCopiesButDoesNotPostPaste() async {
        replacePasteboard(with: "before focus race")
        let postPaste = PasteboardPostSpy(result: true)
        let tracker = SequencedTargetTracker(responses: [true, false])
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() }
        )

        let outcome = await inserter.insert("race text", into: target(safety: .normalText))

        #expect(outcome == .copiedOnly(reason: "target_changed_after_copy"))
        #expect(tracker.callCount == 2)
        #expect(postPaste.callCount == 0)
        #expect(pasteboardString() == "race text")
    }

    /// Past the pasteboard write the clipboard is the delivery mechanism, so a
    /// Cmd-V that never went out is copy-only, not a failure. `CGEvent.post`
    /// returns void, so this path is only reachable when a `CGEvent`
    /// constructor returns nil; a missing permission is caught by the preflight.
    @Test func postEventFailureReportsCopiedOnlyAfterClipboardWrite() async {
        replacePasteboard(with: "before post failure")
        let postPaste = PasteboardPostSpy(result: false)
        let clearSpy = TransientClearSpy()
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: SequencedTargetTracker(responses: [true, true]),
            postPaste: { postPaste.post() },
            scheduleTransientClear: { clearSpy.record($0) }
        )

        let outcome = await inserter.insert("post failure text", into: target(safety: .normalText))

        #expect(outcome == .copiedOnly(reason: "post_event_failed"))
        #expect(postPaste.callCount == 1)
        #expect(pasteboardString() == "post failure text")
        #expect(clearSpy.scheduledChangeCounts.isEmpty)
    }

    /// Cancellation after the write is the same story: the text is already on
    /// the clipboard, so reporting a failure would understate what happened and
    /// clearing it would take the only delivery away.
    @Test func cancellationAfterCopyReportsCopiedOnlyAndKeepsTheClipboard() async {
        replacePasteboard(with: "before cancellation")
        let postPaste = PasteboardPostSpy(result: true)
        let clearSpy = TransientClearSpy()
        let tracker = CancellingAfterCopyTracker()
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() },
            scheduleTransientClear: { clearSpy.record($0) }
        )

        // The task handle has to exist before the tracker can cancel it, so the
        // gate holds the insert until the wiring is complete.
        let ready = TestGate()
        let pending = Task<InsertionOutcome, Never> {
            await ready.wait()
            return await inserter.insert("cancelled after copy", into: target(safety: .normalText))
        }
        tracker.cancelOnSecondCheck = { pending.cancel() }
        ready.fire()

        let outcome = await pending.value

        #expect(outcome == .copiedOnly(reason: "cancelled_after_copy"))
        #expect(postPaste.callCount == 0)
        #expect(pasteboardString() == "cancelled after copy")
        #expect(clearSpy.scheduledChangeCounts.isEmpty)
    }

    @Test func cancellationBeforeInsertReturnsCancelledWithoutPostingOrChangingKnownClipboardValue() async {
        replacePasteboard(with: "known pre-cancel clipboard")
        let postPaste = PasteboardPostSpy(result: true)
        let tracker = SequencedTargetTracker(responses: [true, true])
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: tracker,
            postPaste: { postPaste.post() }
        )

        let pending = Task<InsertionOutcome, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await inserter.insert("must not be written", into: target(safety: .normalText))
        }
        pending.cancel()

        let outcome = await pending.value

        #expect(outcome == .failed(reason: "cancelled"))
        #expect(tracker.callCount == 0)
        #expect(postPaste.callCount == 0)
        #expect(pasteboardString() == "known pre-cancel clipboard")
    }

    @Test func successfulPasteSchedulesTransientClearWithCopyChangeCount() async {
        let postPaste = PasteboardPostSpy(result: true)
        let clearSpy = TransientClearSpy()
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: SequencedTargetTracker(responses: [true, true]),
            postPaste: { postPaste.post() },
            scheduleTransientClear: { clearSpy.record($0) }
        )

        let outcome = await inserter.insert("transient text", into: target(safety: .normalText))

        #expect(outcome == .pasteAttempted)
        #expect(clearSpy.scheduledChangeCounts == [NSPasteboard.general.changeCount])
        #expect(pasteboardString() == "transient text")
        #expect(NSPasteboard.general.data(forType: GeneralPasteboard.transientType) == Data())
        #expect(NSPasteboard.general.data(forType: GeneralPasteboard.concealedType) == nil)
    }

    @Test func secureCopyWritesStringAndConcealedMarker() async {
        replacePasteboard(with: "before concealed copy")
        let postPaste = PasteboardPostSpy(result: true)
        let inserter = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: SequencedTargetTracker(responses: []),
            postPaste: { postPaste.post() }
        )

        let outcome = await inserter.insert("concealed text", into: target(safety: .secure))

        #expect(outcome == .copiedOnly(reason: "target_secure"))
        #expect(postPaste.callCount == 0)
        #expect(pasteboardString() == "concealed text")
        #expect(NSPasteboard.general.data(forType: GeneralPasteboard.concealedType) == Data())
        #expect(NSPasteboard.general.data(forType: GeneralPasteboard.transientType) == nil)
    }

    @Test func copyOnlyOutcomesNeverScheduleTransientClear() async {
        let clearSpy = TransientClearSpy()
        let copyOnly = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: SequencedTargetTracker(responses: [true, true]),
            postPaste: { true },
            scheduleTransientClear: { clearSpy.record($0) }
        )
        _ = await copyOnly.insert("echo hi\n", into: target(safety: .terminal))

        let failedPost = PasteboardInserter(
            permissions: FakePermissions(synth: .granted),
            tracker: SequencedTargetTracker(responses: [true, true]),
            postPaste: { false },
            scheduleTransientClear: { clearSpy.record($0) }
        )
        _ = await failedPost.insert("post failure text", into: target(safety: .normalText))

        #expect(clearSpy.scheduledChangeCounts.isEmpty)
    }

    @Test func clearIfUnchangedClearsOwnWriteButNeverNewerContent() {
        let ownCount = GeneralPasteboard.copy("dictated transient")
        #expect(GeneralPasteboard.clearIfUnchanged(since: ownCount))
        #expect(pasteboardString() == nil)

        let staleCount = GeneralPasteboard.copy("dictated stale")
        replacePasteboard(with: "user copied afterwards")
        #expect(!GeneralPasteboard.clearIfUnchanged(since: staleCount))
        #expect(pasteboardString() == "user copied afterwards")
    }

    private func target(safety: TargetSafetyClass) -> TargetSnapshot {
        TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 4242, safety: safety)
    }

    /// A real `WorkspaceTargetTracker` over a scripted inspector, so the safety
    /// re-check runs through production classification rather than a stub bool.
    private func safariTracker(
        _ inspector: ScriptedFocusInspector,
        secureInputActive: @escaping @Sendable () -> Bool = { false }
    ) -> WorkspaceTargetTracker {
        WorkspaceTargetTracker(
            frontmostApplication: {
                WorkspaceTargetApplication(bundleId: "com.apple.Safari", name: "Safari", pid: 4242)
            },
            focusInspector: { _ in inspector.next() },
            secureInputActive: secureInputActive
        )
    }

    private func replacePasteboard(with text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func pasteboardString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}

/// Answers successive focus inspections from a script, repeating the last entry
/// once exhausted. `snapshot()` consumes one, and each `stillMatches` consumes
/// another, so a script positions a focus change exactly between two checks.
private final class ScriptedFocusInspector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [TargetFocusInspection]
    private var last: TargetFocusInspection

    init(_ script: [TargetFocusInspection]) {
        precondition(!script.isEmpty)
        remaining = script
        last = script[script.count - 1]
    }

    func next() -> TargetFocusInspection {
        lock.withLock {
            guard !remaining.isEmpty else { return last }
            last = remaining.removeFirst()
            return last
        }
    }
}

private final class CountingDeniedPastePermissions: PermissionsChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    func microphone() -> PermissionState { .granted }
    func synthPaste() -> PermissionState { .denied }

    func requestSynthPaste() async -> Bool {
        recordRequest()
        return false
    }

    private func recordRequest() {
        lock.lock()
        requests += 1
        lock.unlock()
    }

    func accessibility() -> PermissionState { .denied }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class TransientClearSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func record(_ changeCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        counts.append(changeCount)
    }

    var scheduledChangeCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

private final class PasteboardPostSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let result: Bool
    private var calls = 0

    init(result: Bool) {
        self.result = result
    }

    func post() -> Bool {
        lock.lock()
        calls += 1
        lock.unlock()
        return result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Answers both identity checks affirmatively, then cancels the inserting task
/// from the second one — the only point where the pasteboard already carries the
/// dictated text but Cmd-V has not gone out.
private final class CancellingAfterCopyTracker: TargetTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var cancelHook: (@Sendable () -> Void)?

    var cancelOnSecondCheck: (@Sendable () -> Void)? {
        get { lock.withLock { cancelHook } }
        set { lock.withLock { cancelHook = newValue } }
    }

    func snapshot() -> TargetSnapshot {
        TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 4242, safety: .normalText)
    }

    func stillMatches(_ snap: TargetSnapshot) -> Bool {
        let (call, hook): (Int, (@Sendable () -> Void)?) = lock.withLock {
            calls += 1
            return (calls, cancelHook)
        }
        if call == 2 { hook?() }
        return true
    }
}

private final class SequencedTargetTracker: TargetTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Bool]
    private var calls = 0

    init(responses: [Bool]) {
        self.responses = responses
    }

    func snapshot() -> TargetSnapshot {
        TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 4242, safety: .normalText)
    }

    func stillMatches(_ snap: TargetSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        guard !responses.isEmpty else { return true }
        return responses.removeFirst()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

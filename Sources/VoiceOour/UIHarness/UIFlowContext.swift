// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// The flag comes from `scripts/ui_harness.sh` (and so every `make ui-*` target) and
// from the `make test` / CI `swift test` steps. Ordinary builds omit it, the
// `swift build -c release` inside `scripts/bundle.sh` that ships included -- which is
// the entire point: these objects used to link into the shipping binary even though
// execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import Combine
    import Foundation
    import VoiceCore
    import VoiceMac

    // The mutable half of a flow: the live coordinator, the gates that hold its asynchronous
    // boundaries open, and the two recorders that observe what it did.
    //
    // Everything here is `@MainActor`, which is also what makes it usable from the `Sendable`
    // adapter structs in `UIFlowFixtures`: a global-actor-isolated class is `Sendable`, so a
    // fake recorder or inserter can hold one and hop to it from its `async` port method.

    // MARK: - Gate

    /// One suspension point a flow script opens by name.
    ///
    /// Without this the whole pipeline runs to completion inside a single settle and
    /// `.transcribing` is unobservable; with it the script decides where the app pauses.
    ///
    /// Release is STICKY. A script that releases before the fake arrives must not deadlock,
    /// because the ordering of a `Task` hop is not something a scene author should have to
    /// reason about. `rearm()` closes the gate again for flows that cross it twice.
    @MainActor
    final class UIGateBox {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isReleased: Bool

        /// How many times a fake has reached this gate. Surfaces in the journal so a flow can
        /// prove the pipeline crossed a boundary exactly once.
        private(set) var arrivals = 0

        /// `armed == false` means the gate is transparent: `arrive()` returns immediately and
        /// the fixture behaves exactly like today's inert adapters.
        let armed: Bool

        init(armed: Bool) {
            self.armed = armed
            isReleased = !armed
        }

        func arrive() async {
            arrivals += 1
            guard armed, !isReleased else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            isReleased = true
            let pending = waiters
            waiters = []
            for continuation in pending { continuation.resume() }
        }

        func rearm() {
            guard armed else { return }
            isReleased = false
        }

        /// Releases every waiter without marking the gate open, so a flow that ends while a
        /// fake is parked cannot leak a suspended continuation into the next flow.
        func drain() {
            let pending = waiters
            waiters = []
            for continuation in pending { continuation.resume() }
        }
    }

    // MARK: - Transition recorder

    /// Records every `SessionState` the coordinator publishes, in order.
    ///
    /// Subscribed BEFORE the first action so transient states -- `checkingPermissions`,
    /// `finalizingAudio`, `cleaning` -- are recorded even when no checkpoint renders them.
    /// `statePublisher` is a `CurrentValueSubject`, so element zero is the state at
    /// subscription time; consecutive duplicates are dropped because a `didSet` that reassigns
    /// the same case is not a transition anyone means to assert.
    @MainActor
    final class UITransitionRecorder {
        private(set) var recorded: [UIStatePattern] = []
        private var cancellable: AnyCancellable?

        func attach(to coordinator: DictationCoordinator) {
            cancellable = coordinator.statePublisher.sink { [weak self] state in
                guard let self else { return }
                let pattern = UIStatePattern.of(state)
                if recorded.last == pattern { return }
                recorded.append(pattern)
            }
        }

        func detach() {
            cancellable?.cancel()
            cancellable = nil
        }

        func matches(_ expected: [UIStatePattern], order: UITransitionOrder) -> Bool {
            switch order {
            case .exact:
                return recorded == expected
            case .contiguous:
                guard !expected.isEmpty else { return true }
                guard recorded.count >= expected.count else { return false }
                for start in 0...(recorded.count - expected.count)
                where Array(recorded[start..<(start + expected.count)]) == expected {
                    return true
                }
                return false
            case .subsequence:
                var index = expected.startIndex
                for pattern in recorded where index < expected.endIndex && expected[index] == pattern {
                    index = expected.index(after: index)
                }
                return index == expected.endIndex
            }
        }

        var rendered: String {
            recorded.map(\.rawValue).joined(separator: " -> ")
        }
    }

    // MARK: - Effect recorder

    /// What left the app. The point of an end-to-end harness is not that the state machine
    /// reached `pasteAttempted`; it is that the exact text a user dictated reached the
    /// process that was focused, and that a copy-only target got copy-only treatment.
    /// "Process", not "window": `TargetSnapshot` carries no window or element identity,
    /// and a claim this file cannot check is not a claim it should make.
    @MainActor
    final class UIEffectRecorder {
        struct Delivery {
            let text: String
            let bundleID: String
            let disposition: String
        }

        private(set) var deliveries: [Delivery] = []
        /// Refiner inputs, so a flow can prove cloud filtering happened before the request.
        private(set) var refinerPrompts: [String] = []
        /// Transcription requests, so a flow can prove exactly one decode per utterance.
        private(set) var transcriptionRequests = 0
        /// Everything the app wrote to `NSPasteboard.general`, captured through
        /// `GeneralPasteboard.writeOverride` so nothing reaches the real clipboard.
        private(set) var pasteboardWrites: [String] = []

        func record(delivery: Delivery) { deliveries.append(delivery) }
        func record(refinerPrompt: String) { refinerPrompts.append(refinerPrompt) }
        func recordTranscriptionRequest() { transcriptionRequests += 1 }
        func record(pasteboardWrite text: String) { pasteboardWrites.append(text) }

        var lastDelivery: Delivery? { deliveries.last }

        static func disposition(of outcome: InsertionOutcome) -> String {
            switch outcome {
            case .pasteAttempted: return "paste"
            case .copiedOnly: return "copy"
            case .failed: return "failed"
            }
        }
    }

    // MARK: - Context

    /// Everything a flow's steps and expectations read.
    @MainActor
    final class UIFlowContext {
        let coordinator: DictationCoordinator
        let transitions = UITransitionRecorder()
        let effects = UIEffectRecorder()

        private var gates: [UIGate: UIGateBox]

        init(coordinator: DictationCoordinator, armedGates: Set<UIGate>) {
            self.coordinator = coordinator
            gates = Dictionary(
                uniqueKeysWithValues: UIGate.allCases.map { gate in
                    (gate, UIGateBox(armed: armedGates.contains(gate)))
                }
            )
            installPasteboardSeam()
        }

        /// Redirects `GeneralPasteboard` into the effect recorder for the life of this flow.
        ///
        /// Three SwiftUI actions copy straight to the pasteboard instead of going through the
        /// insertion adapter -- the menu's transcript copy, the Sessions transcript copy and
        /// `PropertyRow`'s value copy. Faking the inserter does not cover them, so without
        /// this seam a flow that presses one would overwrite the clipboard of whoever ran the
        /// harness. The harness must never reach into the user's workspace.
        ///
        /// `assumeIsolated` is sound here because every call site the override can reach is a
        /// SwiftUI button action on the main actor: the one off-main caller of
        /// `GeneralPasteboard` is `PasteboardInserter`, and a flow always substitutes a fake
        /// inserter for it. The change count is a monotonic counter rather than the real
        /// pasteboard's, so nothing here reads system state either.
        private func installPasteboardSeam() {
            let recorder = effects
            GeneralPasteboard.writeOverride = { text in
                MainActor.assumeIsolated {
                    recorder.record(pasteboardWrite: text)
                    return recorder.pasteboardWrites.count
                }
            }
            GeneralPasteboard.clearOverride = { _ in true }
        }

        func box(_ gate: UIGate) -> UIGateBox {
            guard let existing = gates[gate] else {
                let created = UIGateBox(armed: false)
                gates[gate] = created
                return created
            }
            return existing
        }

        /// Opens a gate. Returns false when the flow armed no such gate, which the runner
        /// reports as a script error rather than silently doing nothing.
        @discardableResult
        func release(_ gate: UIGate) -> Bool {
            let target = box(gate)
            guard target.armed else { return false }
            target.release()
            return true
        }

        func arrivals(_ gate: UIGate) -> Int { box(gate).arrivals }

        /// Called on every exit path so a parked fake never outlives its flow.
        func teardown() {
            transitions.detach()
            for gate in UIGate.allCases { box(gate).drain() }
        }
    }

#endif

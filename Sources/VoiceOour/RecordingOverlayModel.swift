import Combine
import VoiceCore

// Internal rather than private so the offscreen UI harness can drive a fixed
// overlay state (see Sources/VoiceOour/UIHarness/UISceneCatalog.swift).
// Behaviour is unchanged; only the access level differs.
@MainActor
final class RecordingOverlayModel: ObservableObject {
    private static let sampleCount = 11

    @Published private(set) var samples: [Float]
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var captureLive = false

    /// Rolled ONCE per session, on the idle -> active edge. Two `@ViewBuilder`
    /// branches used to own a `@State` head each, so SwiftUI destroyed one and
    /// constructed the other on the warm-up -> processing transition and a single
    /// dictation showed two different emoji.
    private(set) var cometHead: CometEmoji

    var isRecording: Bool {
        state == .recording
    }

    var isListening: Bool {
        isRecording && captureLive
    }

    var isProcessing: Bool {
        state.isOverlayProcessing
    }

    /// The pill's own label vocabulary. `SessionState.displayName` is written for the
    /// console and the menu; inside the capsule the centre slot measures 118pt and the
    /// label may use 110 of it. Measured at `micro` (SF Mono 10, tracking 0.8),
    /// "CHECKING PERMISSIONS" is 139.6pt and "FINALIZING AUDIO" 111.7pt — neither fits
    /// beside a 28pt control at any layout a 180pt pill can hold, so those two drop to
    /// the single present-participle word every other processing state already uses.
    /// Widest survivor: "READY TO INSERT" at 104.7pt.
    var processingLabel: String? {
        switch state {
        case .checkingPermissions: "CHECKING"
        case .finalizingAudio: "FINALIZING"
        case .transcribing, .cleaning, .refining, .readyToInsert: state.displayName.uppercased()
        default: nil
        }
    }

    var showsFinishButton: Bool {
        isRecording
    }

    /// Identity of what the island's centre and trailing slots hold, so the two
    /// crossfade together on the one value that actually changes them. Warm-up and
    /// live capture share the meter, so going live is not a phase change — the bars
    /// simply start moving.
    var centerPhaseToken: Int {
        if isRecording { return 1 }
        if isProcessing { return 2 }
        return 0
    }

    init() {
        samples = Array(repeating: 0, count: Self.sampleCount)
        cometHead = RenderOverrides.cometHead ?? CometEmoji.random()
    }

    func update(_ state: SessionState) {
        if !self.state.isActive, state.isActive {
            cometHead = RenderOverrides.cometHead ?? CometEmoji.random()
        }
        self.state = state
    }

    func updateCaptureLive(_ live: Bool) {
        captureLive = live
    }

    func record(_ rawLevel: Float) {
        guard isListening else { return }
        let level = Swift.min(Swift.max(rawLevel, 0), 1)
        var next = samples
        next.removeFirst()
        next.append(level)
        samples = next
    }

    func reset() {
        state = .idle
        samples = Array(repeating: 0, count: Self.sampleCount)
        captureLive = false
    }
}

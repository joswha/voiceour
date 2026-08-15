import Combine
import VoiceCore

// Internal rather than private so the offscreen UI harness can drive a fixed
// overlay state (see Sources/Voiceour/UIHarness/UISceneCatalog.swift).
// Behaviour is unchanged; only the access level differs.
@MainActor
final class RecordingOverlayModel: ObservableObject {
    private static let sampleCount = 11

    @Published private(set) var samples: [Float]
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var captureLive = false
    /// The live preview line, rendered under the island in the panel variant only. Nil until a
    /// preview decode lands, and cleared with the rest of the session state.
    @Published private(set) var partialText: String?

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

    /// Capture has been asked for but no buffer carrying a non-zero sample has arrived.
    /// The single source of the warm-up decision: nothing re-derives it inline.
    var isWarmingUp: Bool {
        isRecording && !captureLive
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

    /// The same vocabulary as `processingLabel`, for the window between "capture
    /// requested" and "audio actually flowing". Seven characters, measured on the same
    /// `micro` metric as the labels above — SF Mono 10 medium, tracking 0.8 — at 48.9pt
    /// against the 111.7pt that comment records for "FINALIZING AUDIO", so it clears the
    /// centre slot's 110pt budget with more than half of it to spare.
    var warmingLabel: String {
        "WARMING"
    }

    /// What the centre slot announces. `SessionState.displayName` says "Recording" from
    /// the instant capture is requested, which on a cold Bluetooth link is untrue for up
    /// to ~1.5 s, so the readout would tell a VoiceOver user the same thing the flat
    /// meter told everyone else.
    var accessibilityStatus: String {
        isWarmingUp ? "Microphone starting" : state.displayName
    }

    var showsFinishButton: Bool {
        isRecording
    }

    /// Identity of what the island's centre and trailing slots hold, so the two
    /// crossfade together on the one value that actually changes them. Warm-up and live
    /// capture hold DIFFERENT things — a word and a meter — so going live is a phase
    /// change and gets its own token.
    var centerPhaseToken: Int {
        if isWarmingUp { return 1 }
        if isListening { return 2 }
        if isProcessing { return 3 }
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

    func updatePartial(_ text: String?) {
        partialText = text
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
        partialText = nil
    }
}

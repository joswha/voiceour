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

    @Published private(set) var isSpeaking = false
    @Published private(set) var outcome: RecordingOverlayOutcome?

    private var attackRun = 0
    private var releaseRun = 0

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
        case .transcribing, .cleaning, .readyToInsert: state.displayName.uppercased()
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

    /// What the centre slot announces. One stable labelled node's VALUE:
    /// warm-up, listening, speaking, each processing phase, each outcome.
    /// Human sentences only — `SessionState.displayName` interpolates wire
    /// codes on `.error` and insertion-reason tokens on the copy-only paths.
    var accessibilityStatus: String {
        if let outcome {
            return outcome.accessibilityStatus
        }
        if isWarmingUp {
            return "Microphone starting"
        }
        if isListening {
            return isSpeaking ? "Speaking" : "Listening"
        }
        if let derived = RecordingOverlayOutcome(state: state) {
            return derived.accessibilityStatus
        }
        return state.displayName
    }

    var showsFinishButton: Bool {
        isRecording
    }

    /// Identity of what the island's centre and trailing slots hold, so the two
    /// crossfade together on the one value that actually changes them. Warm-up and live
    /// capture hold DIFFERENT things — a word and a meter — so going live is a phase
    /// change and gets its own token. An outcome is a fourth thing, so latching and
    /// clearing it have to move this value or the row's `.animation` never fires.
    var centerPhaseToken: Int {
        if outcome != nil { return 4 }
        if isWarmingUp { return 1 }
        if isListening { return 2 }
        if isProcessing { return 3 }
        return 0
    }

    init() {
        samples = Array(repeating: 0, count: Self.sampleCount)
    }

    func update(_ state: SessionState) {
        self.state = state
        if !isListening {
            clearSpeechActivity()
        }
    }

    func updateCaptureLive(_ live: Bool) {
        captureLive = live
        if !isListening {
            clearSpeechActivity()
        }
    }

    func record(_ rawLevel: Float) {
        guard isListening, outcome == nil else { return }
        let level = Swift.min(Swift.max(rawLevel, 0), 1)
        var next = samples
        next.removeFirst()
        next.append(level)
        samples = next
        applySpeechHysteresis(level)
    }

    /// The island shows this instead of the meter or the processing word, so
    /// the samples, the capture-live flag and the speech run all go with it.
    /// The controller latches rather than `update`, because `update` also
    /// runs for states that get no dwell and owns the 1.2s dismissal.
    func present(_ outcome: RecordingOverlayOutcome) {
        self.outcome = outcome
        samples = Array(repeating: 0, count: Self.sampleCount)
        captureLive = false
        clearSpeechActivity()
    }

    func reset() {
        state = .idle
        samples = Array(repeating: 0, count: Self.sampleCount)
        captureLive = false
        outcome = nil
        clearSpeechActivity()
    }

    /// Attack is 2 samples at 0.10 (80ms at the meter's 25Hz) so speech is
    /// noticed quickly; release is 7 samples at 0.05 (280ms) so a breath
    /// does not concede silence. Levels strictly between the thresholds
    /// hold the current state and do not reset either run.
    private func applySpeechHysteresis(_ level: Float) {
        if level >= RecordingOverlayMetrics.Speech.attackLevel {
            attackRun += 1
            releaseRun = 0
            if !isSpeaking, attackRun >= RecordingOverlayMetrics.Speech.attackSamples {
                isSpeaking = true
            }
        } else if level <= RecordingOverlayMetrics.Speech.releaseLevel {
            releaseRun += 1
            attackRun = 0
            if isSpeaking, releaseRun >= RecordingOverlayMetrics.Speech.releaseSamples {
                isSpeaking = false
            }
        }
    }

    private func clearSpeechActivity() {
        attackRun = 0
        releaseRun = 0
        if isSpeaking {
            isSpeaking = false
        }
    }
}

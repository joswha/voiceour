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

    /// What the island announces. One stable labelled node's VALUE:
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

    /// The mercury drive. The eleven newest levels, oldest first, shifted in place: a
    /// 25 Hz tick must not allocate, and the previous copy-and-append did twice.
    func record(_ rawLevel: Float) {
        guard isListening, outcome == nil else { return }
        let level = Swift.min(Swift.max(rawLevel, 0), 1)
        for index in 0..<(Self.sampleCount - 1) {
            samples[index] = samples[index + 1]
        }
        samples[Self.sampleCount - 1] = level
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

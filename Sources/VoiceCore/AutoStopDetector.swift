import Foundation

public struct AutoStopDetector: Sendable {
    private let silenceLevel: Float
    private let speechLevel: Float
    private let silenceDwell: TimeInterval
    private let minimumSessionDuration: TimeInterval

    private var firstSampleAt: Date?
    private var lastLoudAt: Date?
    private var hasObservedSpeech = false
    private var hasFired = false

    public init(
        silenceLevel: Float = 0.08,
        speechLevel: Float = 0.15,
        silenceDwellMs: Int = 2500,
        minimumSessionMs: Int = 3000
    ) {
        self.silenceLevel = silenceLevel
        self.speechLevel = speechLevel
        silenceDwell = TimeInterval(silenceDwellMs) / 1000
        minimumSessionDuration = TimeInterval(minimumSessionMs) / 1000
    }

    /// Feed one meter sample; returns true exactly once when auto-stop should fire.
    public mutating func observe(level: Float, at now: Date) -> Bool {
        guard !hasFired else { return false }
        let hadObservedSpeech = hasObservedSpeech

        if firstSampleAt == nil {
            firstSampleAt = now
        }
        if level >= silenceLevel {
            lastLoudAt = now
        }
        if level >= speechLevel {
            hasObservedSpeech = true
        }

        guard hadObservedSpeech,
            let firstSampleAt,
            let lastLoudAt,
            now.timeIntervalSince(lastLoudAt) >= silenceDwell,
            now.timeIntervalSince(firstSampleAt) >= minimumSessionDuration
        else {
            return false
        }

        hasFired = true
        return true
    }
}

import SwiftUI

/// The input meter. Its job is to prove the microphone is hearing you, so the curve
/// matters more than the peak: a smoothstep crushed everything below level 0.2 into
/// the baseline tick, which is exactly where conversational speech at desk distance
/// sits, and quiet speech read as a dead mic.
struct RecordingWaveform: View {
    let samples: [Float]
    let isSpeaking: Bool
    let surface: RecordingOverlaySurface

    private var a11y = A11y()

    init(samples: [Float], isSpeaking: Bool, surface: RecordingOverlaySurface) {
        self.samples = samples
        self.isSpeaking = isSpeaking
        self.surface = surface
    }

    var body: some View {
        HStack(alignment: .center, spacing: RecordingOverlayMetrics.Waveform.barSpacing) {
            ForEach(samples.indices, id: \.self) { index in
                // Silence holds every bar at rest so a room's noise floor cannot
                // twitch the row; the rest height still reads as an open microphone.
                let level: Float = isSpeaking ? samples[index] : 0
                Capsule(style: .continuous)
                    .fill(barFill.opacity(opacity(for: level)))
                    .frame(
                        width: RecordingOverlayMetrics.Waveform.barWidth,
                        height: height(for: level)
                    )
                    .animation(meterAnimation, value: level)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Meter.accent is Signal.cyan (0.62, 0.86, 1.00), a pastel authored for the
    /// near-black painted pill, and it lands on near-white when the adaptive
    /// material renders light. OnGlass.cyan is the mid-tone that stays readable
    /// on either adaptation.
    private var barFill: Color {
        surface == .systemGlass
            ? VoiceourPalette.OnGlass.cyan
            : VoiceourPalette.Meter.accent
    }

    /// Reduce Motion damps the meter; it does not un-smooth it. Dropping the
    /// animation made eleven bars jump up to 14.5pt instantly, twenty-five times a
    /// second — the jitteriest possible rendering of the same data, on the one
    /// perpetually animating element in the app. Reduced intensity is a shorter
    /// travel and a slower settle.
    private var meterAnimation: Animation {
        a11y.reduceMotion ? VoiceourMotion.deliberate : VoiceourMotion.meter
    }

    private var maximumHeight: CGFloat {
        a11y.reduceMotion
            ? RecordingOverlayMetrics.Waveform.maximumHeightReduced
            : RecordingOverlayMetrics.Waveform.maximumHeight
    }

    private func height(for rawLevel: Float) -> CGFloat {
        let level = Double(Swift.min(Swift.max(rawLevel, 0), 1))
        let eased = CGFloat(pow(level, RecordingOverlayMetrics.Waveform.levelExponent))
        let rest = RecordingOverlayMetrics.Waveform.restingHeight
        return rest + eased * (maximumHeight - rest)
    }

    private func opacity(for rawLevel: Float) -> Double {
        let level = Double(Swift.min(Swift.max(rawLevel, 0), 1))
        let floorOpacity =
            a11y.contrast == .increased
            ? RecordingOverlayMetrics.Waveform.opacityFloorIncreased
            : RecordingOverlayMetrics.Waveform.opacityFloor
        return floorOpacity + level * (1 - floorOpacity)
    }
}

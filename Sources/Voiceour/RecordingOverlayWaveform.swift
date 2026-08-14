import SwiftUI

/// The input meter. Its job is to prove the microphone is hearing you, so the curve
/// matters more than the peak: a smoothstep crushed everything below level 0.2 into
/// the baseline tick, which is exactly where conversational speech at desk distance
/// sits, and quiet speech read as a dead mic.
struct RecordingWaveform: View {
    let samples: [Float]

    private var a11y = A11y()

    init(samples: [Float]) {
        self.samples = samples
    }

    var body: some View {
        ZStack {
            // Ambient bloom — a soft luminous undertone so the bars read as
            // living light on the frost rather than flat ticks.
            bars
                .blur(radius: RecordingOverlayMetrics.Waveform.bloomBlur)
                .opacity(RecordingOverlayMetrics.Waveform.bloomOpacity)
                .blendMode(.plusLighter)
            bars
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Flatten the base bars + blurred/blended bloom into a single Metal
        // render target per frame; without this, the blur+plusLighter overlay
        // chains offscreen passes on every 25Hz level update.
        .drawingGroup()
    }

    private var bars: some View {
        HStack(alignment: .center, spacing: RecordingOverlayMetrics.Waveform.barSpacing) {
            ForEach(samples.indices, id: \.self) { index in
                let level = samples[index]
                Capsule(style: .continuous)
                    .fill(VoiceourPalette.Meter.accent.opacity(opacity(for: level, at: index)))
                    .frame(
                        width: RecordingOverlayMetrics.Waveform.barWidth,
                        height: height(for: level)
                    )
                    .animation(meterAnimation, value: level)
            }
        }
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
        let minimum = RecordingOverlayMetrics.Waveform.minimumHeight
        return minimum + eased * (maximumHeight - minimum)
    }

    /// Floor plus a small recency term: history dims, it does not disappear. The old
    /// ramp bottomed out at 0.34 — 3.74:1, the weakest mark on the surface.
    private func opacity(for rawLevel: Float, at index: Int) -> Double {
        let level = Double(Swift.min(Swift.max(rawLevel, 0), 1))
        let recency = samples.count > 1 ? Double(index) / Double(samples.count - 1) : 1
        let floorOpacity =
            a11y.contrast == .increased
            ? RecordingOverlayMetrics.Waveform.opacityFloorIncreased
            : RecordingOverlayMetrics.Waveform.opacityFloor
        let recencyTerm = RecordingOverlayMetrics.Waveform.opacityRecency
        return floorOpacity + recency * recencyTerm + level * (1 - floorOpacity - recencyTerm)
    }
}

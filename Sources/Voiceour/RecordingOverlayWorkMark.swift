import SwiftUI

/// The working mark. It sits in the finish disc's 28×28 slot while that action is
/// unavailable, so the island keeps one silhouette in every state. Three dots from
/// the meter's vocabulary; emphasis travels right → centre → left so the motion
/// reads as speech being drawn inward, not as a spinner. The centre readout already
/// names the work, so this mark does not take hits or speak.
struct RecordingWorkMark: View {
    let surface: RecordingOverlaySurface

    private var a11y = A11y()

    init(surface: RecordingOverlaySurface) {
        self.surface = surface
    }

    var body: some View {
        mark
            .frame(
                width: RecordingOverlayMetrics.Disc.hitSize,
                height: RecordingOverlayMetrics.Disc.hitSize
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        if a11y.reduceMotion {
            dots(phase: nil)
        } else {
            TimelineView(
                .animation(
                    minimumInterval: RecordingOverlayMetrics.WorkMark.frameInterval,
                    paused: false
                )
            ) { timeline in
                dots(phase: cyclePhase(timeline.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    private func dots(phase: Double?) -> some View {
        HStack(spacing: RecordingOverlayMetrics.WorkMark.dotSpacing) {
            ForEach(0..<RecordingOverlayMetrics.WorkMark.dotCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(ink.opacity(opacity(for: index, phase: phase)))
                    .frame(
                        width: RecordingOverlayMetrics.WorkMark.dotSize,
                        height: RecordingOverlayMetrics.WorkMark.dotSize
                    )
            }
        }
    }

    /// Pastel `Signal.cyan` was authored for the near-black pill and washes out on
    /// adaptive light glass; the mid-tone is the same hue that keeps the meter
    /// legible on that ground.
    private var ink: Color {
        surface == .systemGlass
            ? VoiceourPalette.OnGlass.cyan
            : VoiceourPalette.Meter.accent
    }

    private func cyclePhase(_ time: TimeInterval) -> Double {
        let period = RecordingOverlayMetrics.WorkMark.cyclePeriod
        return time.truncatingRemainder(dividingBy: period) / period
    }

    private func opacity(for index: Int, phase: Double?) -> Double {
        let dim =
            a11y.contrast == .increased
            ? RecordingOverlayMetrics.WorkMark.dimOpacityIncreased
            : RecordingOverlayMetrics.WorkMark.dimOpacity
        let bright = RecordingOverlayMetrics.WorkMark.brightOpacity
        // Reduce Motion freezes the travelling emphasis into one row: every dot
        // at the same mix, no timeline. Increase Contrast still lifts the dim
        // end of that mix.
        guard let phase else {
            return (dim + bright) / 2
        }
        let count = RecordingOverlayMetrics.WorkMark.dotCount
        // Right (last index) peaks at t=0, then centre, then left. Circular
        // distance so the wrap is a cross-fade of the ends, not a reversal
        // through the middle.
        let peak = Double(count - 1 - index) / Double(count)
        let delta = abs(phase - peak)
        let circular = min(delta, 1 - delta)
        let weight = max(0, 1 - circular * Double(count))
        return dim + (bright - dim) * weight
    }
}

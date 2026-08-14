import SwiftUI

// MARK: - Meter

/// One horizontal meter: a hairline track that draws the whole scale, and a fill
/// whose length is the value's share of it.
///
/// The track is the point. Without it a bar is a stub of unknowable magnitude —
/// the comparison a gauge exists to make happens against an axis the reader can
/// see. Track and fill share one weight token so a bar means the same thing in
/// the velocity gauges and in the destinations list.
struct MeterBar: View {
    var fraction: Double
    var fill: Color

    @Environment(\.displayScale) private var displayScale
    private var a11y = A11y()

    /// The one bar weight on the surface.
    static let weight = VoiceourMetrics.Space.sm

    init(fraction: Double, fill: Color) {
        self.fraction = fraction
        self.fill = fill
    }

    private var clamped: Double { min(max(fraction, 0), 1) }

    /// At least one device pixel: a 0.5pt rule on a half-pixel origin rounds
    /// away, and an axis that renders nothing is worse than no axis.
    private var hairline: CGFloat {
        max(1 / displayScale, VoiceourMetrics.Stroke.hairline(a11y.contrast))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .strokeBorder(a11y.meterRest, lineWidth: hairline)

                if clamped > 0 {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(proxy.size.width * CGFloat(clamped), Self.weight))
                }
            }
        }
        .frame(height: Self.weight)
        .accessibilityHidden(true)
    }
}

import SwiftUI

// MARK: - Metric readout

/// A metric composed from parts: numerals at the value face, units at the small
/// mono unit face, baseline-aligned.
///
/// A monospaced space carries a full advance, so joining "1m" and "44s" with one
/// opens a ~47pt hole at the hero size — the value visibly splits into two
/// words. Pairing the parts closes it, and it stops a unit from being set at the
/// quantity's size: `4 days` no longer occupies twice the width of `108` in an
/// equal-width shelf.
struct MetricValue: View {
    enum Scale {
        case hero
        case metric
        case tile

        var role: TextRole {
            switch self {
            case .hero: .heroMetric
            case .metric: .metric
            case .tile: .tileValue
            }
        }

        /// The unit face, held at roughly a third of the numeral so a unit
        /// reads as a qualifier and not as a second quantity. `micro` beside a
        /// 64pt hero numeral is not small, it is invisible.
        var unitRole: TextRole {
            switch self {
            case .hero: .tileValue
            case .metric, .tile: .micro
            }
        }
    }

    var parts: [HomeFormat.MetricPart]
    var scale: Scale
    var color: Color?

    private var a11y = A11y()

    init(parts: [HomeFormat.MetricPart], scale: Scale, color: Color? = nil) {
        self.parts = parts
        self.scale = scale
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VoiceOourMetrics.Space.sm) {
            ForEach(parts) { part in
                HStack(alignment: .firstTextBaseline, spacing: VoiceOourMetrics.Space.xs) {
                    Text(part.value)
                        .roleStyle(scale.role)
                        .monospacedDigit()
                        .foregroundStyle(color ?? scale.role.foreground)

                    if let unit = part.unit {
                        Text(unit)
                            .roleStyle(scale.unitRole)
                            .foregroundStyle(a11y.textMid)
                    }
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityRepresentation { Text(parts.plain) }
    }
}

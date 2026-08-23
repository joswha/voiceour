import SwiftUI
import VoiceCore

/// Dictation activity as a calendar grid: one square per day, one column per
/// week, oldest week on the left.
///
/// Every square is drawn into one `Canvas`. A 30-week window is 210 squares, and
/// 210 SwiftUI shapes would be 210 layout participants and 210 accessibility
/// nodes for a picture that says one thing. The grid is a single accessibility
/// element carrying that one thing.
struct ActivityHeatmap: View {
    private var a11y = A11y()

    let model: HeatmapModel

    init(model: HeatmapModel) {
        self.model = model
    }

    enum Geometry {
        static let cell: CGFloat = 14
        static let gap: CGFloat = 3
        static let corner: CGFloat = 4
        static let pitch: CGFloat = cell + gap
        /// The weekday-letter column to the left of the grid.
        static let gutter: CGFloat = 24
        static let legendSwatch: CGFloat = 10
        /// Blur radius for the brightest level's underlay.
        static let bloomBlur: CGFloat = 4

        /// The measure the grid gets on a console at or above its intended
        /// width: the page's capped column less the page and island padding.
        /// Used as the starting value so the first render already draws the
        /// span it will keep, instead of laying out a twelve-week grid and
        /// immediately replacing it.
        static let defaultWidth: CGFloat =
            VoiceourMetrics.Content.table - VoiceourMetrics.Space.xl * 2
            - VoiceourMetrics.Space.lg * 2

        /// Week columns that fit `width`, clamped to the policy's span.
        static func weeks(fitting width: CGFloat) -> Int {
            let available = width - gutter
            guard available > 0 else { return DictationStatsPolicy.heatmapMinWeeks }
            return min(
                DictationStatsPolicy.heatmapMaxWeeks,
                max(DictationStatsPolicy.heatmapMinWeeks, Int(available / pitch))
            )
        }
    }

    private var gridWidth: CGFloat {
        CGFloat(model.columns.count) * Geometry.pitch - Geometry.gap
    }

    private var gridHeight: CGFloat {
        7 * Geometry.pitch - Geometry.gap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            HStack(alignment: .top, spacing: 0) {
                weekdayColumn
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    grid
                    monthRow
                }
            }
            legend
        }
    }

    // MARK: Grid

    private var grid: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            for (column, cells) in model.columns.enumerated() {
                for (row, cell) in cells.enumerated() {
                    guard cell.isInRange else { continue }
                    draw(cell, column: column, row: row, in: &context)
                }
            }
        }
        .frame(width: gridWidth, height: gridHeight)
        .accessibilityElement()
        // One label, not label plus value: AppKit exposes the hosted `Canvas` as
        // a generic element, and a generic element carries no AXValue — the
        // figures were silently dropped from the tree when they lived there.
        .accessibilityLabel(
            "Dictation activity, last \(model.columns.count) weeks: "
                + "\(model.activeDaysInWindow) active days, "
                + "busiest day \(model.maxWords) words"
        )
        .accessibilityIdentifier("home.activity.grid")
    }

    private func draw(
        _ cell: HeatmapCell,
        column: Int,
        row: Int,
        in context: inout GraphicsContext
    ) {
        let origin = CGPoint(
            x: CGFloat(column) * Geometry.pitch,
            y: CGFloat(row) * Geometry.pitch
        )
        if a11y.differentiateWithoutColor {
            drawWithoutColor(cell, at: origin, in: &context)
            return
        }
        let path = squarePath(at: origin, inset: 0)
        // The brightest level is the reader's best day; a blurred underlay makes
        // it read as emitting light rather than merely being the last swatch on
        // a ladder. Only level 4 pays for the extra layer.
        if cell.level >= 4 {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: Geometry.bloomBlur))
                layer.opacity = 0.5
                layer.fill(path, with: .color(VoiceourPalette.Alien.heat4))
            }
        }
        context.fill(path, with: .color(VoiceourPalette.Alien.heat(cell.level)))
    }

    /// Differentiate Without Color asks for a second carrier. The ladder becomes
    /// size at one hue: an empty day is still the plate, and a busier day is a
    /// larger square of the same green, so the sequence survives with no hue
    /// discrimination at all.
    private func drawWithoutColor(
        _ cell: HeatmapCell,
        at origin: CGPoint,
        in context: inout GraphicsContext
    ) {
        context.fill(
            squarePath(at: origin, inset: 0),
            with: .color(VoiceourPalette.Alien.emptyCell)
        )
        guard cell.level > 0 else { return }
        let insets: [CGFloat] = [4, 3, 1.5, 0]
        let inset = insets[min(insets.count - 1, cell.level - 1)]
        context.fill(
            squarePath(at: origin, inset: inset),
            with: .color(VoiceourPalette.Alien.bloom)
        )
    }

    private func squarePath(at origin: CGPoint, inset: CGFloat) -> Path {
        Path(
            roundedRect: CGRect(
                x: origin.x + inset,
                y: origin.y + inset,
                width: Geometry.cell - inset * 2,
                height: Geometry.cell - inset * 2
            ),
            cornerRadius: max(0, Geometry.corner - inset)
        )
    }

    // MARK: Axes

    /// Every other weekday, which is the convention a calendar grid this size
    /// can label without the letters colliding with each other.
    private var weekdayColumn: some View {
        VStack(alignment: .leading, spacing: Geometry.gap) {
            ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                Text(index.isMultiple(of: 2) ? symbol : " ")
                    .roleStyle(.micro)
                    .frame(height: Geometry.cell, alignment: .center)
            }
        }
        .frame(width: Geometry.gutter, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var monthRow: some View {
        ZStack(alignment: .topLeading) {
            // A transparent spacer of the grid's own width, so the labels are
            // positioned in the grid's coordinate space rather than laid out as
            // a row whose gaps would have to be computed.
            Color.clear
                .frame(width: gridWidth, height: TextRole.micro.pointSize + 2)
            ForEach(model.monthLabels, id: \.column) { label in
                Text(label.label)
                    .roleStyle(.micro)
                    .offset(x: CGFloat(label.column) * Geometry.pitch)
            }
        }
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: VoiceourMetrics.Space.xs) {
            Text("Less")
                .roleStyle(.caption)
                .foregroundStyle(a11y.textMid)
            ForEach(0...4, id: \.self) { level in
                swatch(level)
            }
            Text("More")
                .roleStyle(.caption)
                .foregroundStyle(a11y.textMid)
        }
        .padding(.leading, Geometry.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Activity scale, less to more")
    }

    private func swatch(_ level: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        return
            shape
            .fill(
                a11y.differentiateWithoutColor
                    ? VoiceourPalette.Alien.emptyCell
                    : VoiceourPalette.Alien.heat(level)
            )
            .frame(width: Geometry.legendSwatch, height: Geometry.legendSwatch)
            .overlay {
                // The size ladder's legend has to be the size ladder.
                if a11y.differentiateWithoutColor, level > 0 {
                    shape
                        .fill(VoiceourPalette.Alien.bloom)
                        .padding(CGFloat(4 - level) * 0.75 + 0.5)
                }
            }
    }
}

import AppKit
import SwiftUI
import VoiceCore

/// Dictation activity as a calendar grid: one square per day, one column per
/// week, oldest week on the left.
///
/// Every square is drawn into one `Canvas`. A 30-week window is 210 squares, and
/// 210 SwiftUI shapes would be 210 layout participants and 210 accessibility
/// nodes for a picture that says one thing. The grid is a single accessibility
/// element carrying that one thing.
///
/// The steps are the theme's `heat` ramp: the empty day is the hover wash and
/// the four busier steps climb toward the accent, so the grid follows the
/// reader's appearance and accent choice without a colour of its own.
struct ActivityHeatmap: View {
    @Environment(\.theme) private var theme
    private var a11y = A11y()

    let model: HeatmapModel
    let calendar: Calendar

    init(model: HeatmapModel, calendar: Calendar) {
        self.model = model
        self.calendar = calendar
    }

    enum Geometry {
        static let cell: CGFloat = 14
        static let gap: CGFloat = 3
        static let corner: CGFloat = 4
        static let pitch: CGFloat = cell + gap
        /// The weekday-letter column to the left of the grid.
        static let gutter: CGFloat = 24
        static let legendSwatch: CGFloat = 10
        /// Inset of each busier step under Differentiate Without Color: the
        /// square grows with the count instead of changing hue.
        static let sizeSteps: [CGFloat] = [4, 3, 1.5, 0]

        /// The measure the grid gets when Home's column is at its full width:
        /// the column less the card's padding. The starting value, so the first
        /// render already draws the span it will keep instead of laying out a
        /// twelve-week grid and immediately replacing it.
        static let defaultWidth: CGFloat = HomeLayout.column - Kit.Metrics.cardPadding * 2

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                weekdayColumn
                VStack(alignment: .leading, spacing: 4) {
                    grid
                    monthRow
                }
            }
            legend
        }
    }

    // MARK: Grid

    private var grid: some View {
        // Captured once so the canvas closure reads plain values, not the
        // environment, while it draws.
        let heat = theme.heat
        let accent = theme.accent
        let sizeSteps = a11y.differentiateWithoutColor
        return Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            for (column, cells) in model.columns.enumerated() {
                for (row, cell) in cells.enumerated() {
                    guard cell.isInRange else { continue }
                    let origin = CGPoint(
                        x: CGFloat(column) * Geometry.pitch,
                        y: CGFloat(row) * Geometry.pitch
                    )
                    if sizeSteps {
                        Self.drawSized(
                            cell.level, at: origin, empty: Self.step(0, in: heat), fill: accent, in: &context)
                    } else {
                        context.fill(
                            Self.squarePath(at: origin, inset: 0),
                            with: .color(Self.step(cell.level, in: heat))
                        )
                    }
                }
            }
        }
        .frame(width: gridWidth, height: gridHeight)
        .overlay {
            HeatmapTooltipOverlay(model: model, calendar: calendar)
        }
        .accessibilityElement()
        // One label, not label plus value: AppKit exposes the hosted `Canvas` as
        // a generic element, and a generic element carries no AXValue — the
        // figures were silently dropped from the tree when they lived there.
        .accessibilityLabel(
            "Dictation activity, last \(model.columns.count) weeks: "
                + "\(model.activeDaysInWindow) active \(StatsFormatting.noun("day", count: model.activeDaysInWindow)), "
                + "busiest day \(model.maxWords) \(StatsFormatting.noun("word", count: model.maxWords))"
        )
        .accessibilityIdentifier("home.activity.grid")
    }

    /// The ramp entry for a level, clamped so a level outside 0...4 never
    /// indexes past the theme's five steps.
    private nonisolated static func step(_ level: Int, in heat: [Color]) -> Color {
        guard let last = heat.indices.last else { return .clear }
        return heat[min(max(level, 0), last)]
    }

    /// Differentiate Without Color asks for a second carrier. The ramp becomes
    /// size at one hue: an empty day is still the empty step, and a busier day
    /// is a larger square of the accent, so the sequence survives with no hue
    /// discrimination at all.
    private nonisolated static func drawSized(
        _ level: Int,
        at origin: CGPoint,
        empty: Color,
        fill: Color,
        in context: inout GraphicsContext
    ) {
        context.fill(squarePath(at: origin, inset: 0), with: .color(empty))
        guard level > 0 else { return }
        let inset = Geometry.sizeSteps[min(Geometry.sizeSteps.count - 1, level - 1)]
        context.fill(squarePath(at: origin, inset: inset), with: .color(fill))
    }

    private nonisolated static func squarePath(at origin: CGPoint, inset: CGFloat) -> Path {
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
                    .lineLimit(1)
                    .frame(height: Geometry.cell, alignment: .center)
            }
        }
        .frame(width: Geometry.gutter, alignment: .leading)
        .accessibilityHidden(true)
    }

    /// Month names placed in the grid's own coordinate space: each label is
    /// offset to its week column rather than laid out as a row whose gaps would
    /// have to be computed.
    private var monthRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.monthLabels, id: \.column) { label in
                Text(label.label)
                    .roleStyle(.micro)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: CGFloat(label.column) * Geometry.pitch)
            }
        }
        .frame(width: gridWidth, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less")
                .roleStyle(.meta)
            ForEach(0...4, id: \.self) { level in
                swatch(level)
            }
            Text("More")
                .roleStyle(.meta)
        }
        .padding(.leading, Geometry.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Activity scale, less to more")
    }

    private func swatch(_ level: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        let sizeSteps = a11y.differentiateWithoutColor
        return
            shape
            .fill(Self.step(sizeSteps ? 0 : level, in: theme.heat))
            .frame(width: Geometry.legendSwatch, height: Geometry.legendSwatch)
            .overlay {
                // The size ladder's legend has to be the size ladder.
                if sizeSteps, level > 0 {
                    shape
                        .fill(theme.accent)
                        .padding(CGFloat(4 - level) * 0.75 + 0.5)
                }
            }
    }
}

/// Native per-square tooltips over the heatmap canvas.
///
/// An `NSView` with one tooltip rect per in-range square rather than 210
/// SwiftUI views with `.help(_:)`: the grid is deliberately a single layout
/// participant and a single accessibility element, and AppKit tooltip rects are
/// tracking regions, not views — the pointer crossing from one square to the
/// next re-resolves the string without re-arming the tooltip delay.
private struct HeatmapTooltipOverlay: NSViewRepresentable {
    let model: HeatmapModel
    let calendar: Calendar

    func makeNSView(context: Context) -> HeatmapTooltipView {
        HeatmapTooltipView()
    }

    func updateNSView(_ view: HeatmapTooltipView, context: Context) {
        // Calendar before model: a rebuild must never format with a stale one.
        view.calendar = calendar
        view.model = model
    }
}

private final class HeatmapTooltipView: NSView, NSViewToolTipOwner {
    var calendar = Calendar.current
    var model: HeatmapModel? {
        didSet {
            // `HeatmapModel` is `Equatable`, and the home tab recomputes it on
            // every body evaluation; only a genuinely different window is worth
            // rebuilding 210 tooltip regions for.
            guard model != oldValue else { return }
            rebuildToolTips()
        }
    }

    /// Match the canvas's top-left origin so column/row math is shared.
    override var isFlipped: Bool { true }

    private func rebuildToolTips() {
        removeAllToolTips()
        guard let model else { return }
        for (column, cells) in model.columns.enumerated() {
            for (row, cell) in cells.enumerated() where cell.isInRange {
                // The cell, not the pitch: the 3pt gaps are dead space, so the
                // tooltip names exactly the square under the pointer.
                addToolTip(
                    NSRect(
                        x: CGFloat(column) * ActivityHeatmap.Geometry.pitch,
                        y: CGFloat(row) * ActivityHeatmap.Geometry.pitch,
                        width: ActivityHeatmap.Geometry.cell,
                        height: ActivityHeatmap.Geometry.cell
                    ),
                    owner: self,
                    userData: nil
                )
            }
        }
    }

    /// Resolved from `point` rather than from `userData`, so a rebuild allocates
    /// nothing per square. An empty string shows no tooltip.
    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        let column = Int(point.x / ActivityHeatmap.Geometry.pitch)
        let row = Int(point.y / ActivityHeatmap.Geometry.pitch)
        guard let model,
            model.columns.indices.contains(column),
            model.columns[column].indices.contains(row)
        else { return "" }
        let cell = model.columns[column][row]
        guard cell.isInRange else { return "" }
        return StatsFormatting.heatmapTooltip(
            words: cell.words,
            dayKey: cell.dayKey,
            calendar: calendar
        ) ?? ""
    }
}

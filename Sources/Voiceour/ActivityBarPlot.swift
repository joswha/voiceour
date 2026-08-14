import SwiftUI

enum ActivityBarPlotTextContext {
    case readout
    case accessibility
}

enum ActivityBarPlotReadoutOrder {
    case labelThenValue
    case valueThenLabel
}

/// The shared interaction and rendering engine for Home's linear activity plots.
/// Bucket adapters retain their own date/hour semantics, copy, spacing, identifiers,
/// and axis footer while this view owns selection, normalization, and input behavior.
struct ActivityBarPlot<AxisFooter: View>: View {
    var bucketValues: [Int]
    var columnSpacing: CGFloat
    var columnInset: CGFloat
    var labelBuilder: (Int, ActivityBarPlotTextContext) -> String
    var valueBuilder: (Int, ActivityBarPlotTextContext) -> String
    var readoutSummary: String
    var readoutOrder: ActivityBarPlotReadoutOrder
    var accessibilityChartLabel: String
    var accessibilitySummary: String
    var accessibilityIdentifierPrefix: String
    var pinnedPreposition: String
    var axisFooter: AxisFooter

    @Environment(\.displayScale) private var displayScale
    private var a11y = A11y()
    private var accent = HomeAccent()
    @FocusState private var chartFocused: Bool
    @State private var hoveredIndex: Int?
    @State private var keyboardIndex: Int?
    @State private var pinnedIndex: Int?

    init(
        bucketValues: [Int],
        columnSpacing: CGFloat,
        columnInset: CGFloat,
        labelBuilder: @escaping (Int, ActivityBarPlotTextContext) -> String,
        valueBuilder: @escaping (Int, ActivityBarPlotTextContext) -> String,
        readoutSummary: String,
        readoutOrder: ActivityBarPlotReadoutOrder,
        accessibilityChartLabel: String,
        accessibilitySummary: String,
        accessibilityIdentifierPrefix: String,
        pinnedPreposition: String,
        @ViewBuilder axisFooter: () -> AxisFooter
    ) {
        self.bucketValues = bucketValues
        self.columnSpacing = columnSpacing
        self.columnInset = columnInset
        self.labelBuilder = labelBuilder
        self.valueBuilder = valueBuilder
        self.readoutSummary = readoutSummary
        self.readoutOrder = readoutOrder
        self.accessibilityChartLabel = accessibilityChartLabel
        self.accessibilitySummary = accessibilitySummary
        self.accessibilityIdentifierPrefix = accessibilityIdentifierPrefix
        self.pinnedPreposition = pinnedPreposition
        self.axisFooter = axisFooter()
    }

    /// The shortest bar that still reads as a bar rather than as a thickened
    /// baseline.
    private var minimumBar: CGFloat { VoiceourMetrics.Space.sm }

    /// Square-footed, so a bar reads as standing on the baseline rather than as
    /// a lozenge floating near it. Track and bar share the shape, so a bar reads
    /// as its slot filled to a level rather than as a second object inside it.
    private var column: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: VoiceourMetrics.Radius.keycap,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: VoiceourMetrics.Radius.keycap,
            style: .continuous
        )
    }

    /// At least one device pixel: a 0.5pt rule on a half-pixel origin rounds
    /// away, and the baseline is the one mark that must never disappear.
    private var hairline: CGFloat {
        max(1 / displayScale, VoiceourMetrics.Stroke.hairline(a11y.contrast))
    }

    private var activeIndex: Int? { hoveredIndex ?? keyboardIndex ?? pinnedIndex }

    var body: some View {
        let maximum = max(bucketValues.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            Text(readout)
                .roleStyle(.micro)
                .monospacedDigit()
                .foregroundStyle(activeIndex == nil ? a11y.textLow : VoiceourPalette.Text.mono)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: columnSpacing) {
                    ForEach(bucketValues.indices, id: \.self) { index in
                        bucketColumn(count: bucketValues[index], maximum: maximum, index: index)
                    }
                }

                Rectangle()
                    .fill(a11y.meterRest)
                    .frame(height: hairline)
                    .allowsHitTesting(false)
            }
            .frame(height: HomeChart.band, alignment: .bottom)

            axisFooter
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(axLabel)
        .accessibilityValue(axValue)
        .accessibilityChildren {
            ZStack {
                ForEach(bucketValues.indices, id: \.self) { index in
                    let label = labelBuilder(index, .accessibility)
                    Text(label)
                        .accessibilityLabel(label)
                        .accessibilityValue(valueBuilder(index, .accessibility))
                        .accessibilityIdentifier("\(accessibilityIdentifierPrefix).\(index)")
                        .frame(width: VoiceourMetrics.Space.hair, height: VoiceourMetrics.Space.hair)
                        .offset(y: VoiceourMetrics.Space.sm)
                }
            }
        }
        .focusable(true)
        .focused($chartFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            moveKeyboard(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveKeyboard(by: 1)
            return .handled
        }
        .onKeyPress(.space) {
            pinKeyboardBucket()
            return .handled
        }
        .onKeyPress(.return) {
            pinKeyboardBucket()
            return .handled
        }
        .onKeyPress(.escape) {
            clearKeyboardSelection()
            return .handled
        }
        .overlay {
            if chartFocused {
                RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.row, style: .continuous)
                    .strokeBorder(
                        VoiceourPalette.Line.focus,
                        lineWidth: VoiceourMetrics.Stroke.selected(a11y.contrast)
                    )
                    .padding(-VoiceourMetrics.Space.hair)
                    .allowsHitTesting(false)
            }
        }
    }

    private var readout: String {
        guard let index = activeIndex, bucketValues.indices.contains(index) else {
            return readoutSummary
        }
        let label = labelBuilder(index, .readout)
        let value = valueBuilder(index, .readout)
        switch readoutOrder {
        case .labelThenValue:
            return "\(label) · \(value)"
        case .valueThenLabel:
            return "\(value) · \(label)"
        }
    }

    /// Base label plus the pinned bucket when one is set, so VoiceOver still
    /// announces the persistent selection after the cursor leaves.
    private var axLabel: String {
        guard let index = pinnedIndex, bucketValues.indices.contains(index) else {
            return accessibilityChartLabel
        }
        let label = labelBuilder(index, .readout)
        let value = valueBuilder(index, .readout)
        return "\(accessibilityChartLabel). Pinned: \(value) \(pinnedPreposition) \(label)"
    }

    private var axValue: String {
        guard let index = activeIndex, bucketValues.indices.contains(index) else {
            return accessibilitySummary
        }
        let detail = "\(labelBuilder(index, .accessibility)), \(valueBuilder(index, .accessibility))"
        return pinnedIndex == index ? "\(detail), pinned" : detail
    }

    /// The track fill: quiet enough that every slot reads as ruling rather than
    /// as data, and stepped up under Increase Contrast, where `meterRest` is
    /// raised too and a track at rest weight would fall out of the picture.
    private var trackFill: Color {
        a11y.contrast == .increased ? VoiceourPalette.Plate.hover : VoiceourPalette.Plate.rest
    }

    /// One slot: its track, and the bar filling the share of it the bucket earned.
    /// Both flex with the column rather than holding a fixed weight: the day chart's
    /// wider gutters keep fourteen bars distinct, while the hour chart's narrower
    /// gutters keep twenty-four bars from thinning toward tally marks.
    private func bucketColumn(count: Int, maximum: Int, index: Int) -> some View {
        let isActive = hoveredIndex == index || keyboardIndex == index || pinnedIndex == index
        let normalized = Double(count) / Double(maximum)
        return ZStack(alignment: .bottom) {
            column
                .fill(trackFill)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, columnInset)

            if count > 0 {
                column
                    .fill(isActive ? accent.color : a11y.meterRest)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, columnInset)
                    .frame(height: max(HomeChart.band * CGFloat(normalized), minimumBar))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: HomeChart.band, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { hovering in
            let next: Int? = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
            if a11y.reduceMotion {
                hoveredIndex = next
            } else {
                withAnimation(VoiceourMotion.quick) { hoveredIndex = next }
            }
        }
        .onTapGesture {
            setPinned(pinnedIndex == index ? nil : index)
        }
    }

    private func setPinned(_ next: Int?) {
        guard pinnedIndex != next else { return }
        if a11y.reduceMotion {
            pinnedIndex = next
        } else {
            withAnimation(VoiceourMotion.quick) { pinnedIndex = next }
        }
    }

    private func moveKeyboard(by delta: Int) {
        guard !bucketValues.isEmpty else { return }
        let next: Int
        if let keyboardIndex {
            next = min(max(keyboardIndex + delta, 0), bucketValues.count - 1)
        } else {
            next = delta < 0 ? bucketValues.count - 1 : 0
        }
        guard keyboardIndex != next else { return }
        if a11y.reduceMotion {
            keyboardIndex = next
        } else {
            withAnimation(VoiceourMotion.quick) { keyboardIndex = next }
        }
    }

    private func pinKeyboardBucket() {
        guard let index = keyboardIndex ?? hoveredIndex else { return }
        setPinned(pinnedIndex == index ? nil : index)
    }

    private func clearKeyboardSelection() {
        if a11y.reduceMotion {
            keyboardIndex = nil
            pinnedIndex = nil
        } else {
            withAnimation(VoiceourMotion.quick) {
                keyboardIndex = nil
                pinnedIndex = nil
            }
        }
    }
}

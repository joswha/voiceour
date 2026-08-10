import SwiftUI
import VoiceMac

/// The property-ledger vocabulary: the rows that state a *fact* rather than
/// offer a *control*.
///
/// `SettingsRow` says "here is a switch, set it". A ledger row says "here is
/// what is true right now, here is the mark that grades it, and here is the
/// one action that changes it". They share the Manifest Grid (§12.3), the
/// row-bounds anchor and the content lead, so a `SettingsSectionBlock` can
/// stack both kinds and its hairline dividers keep landing between rows
/// instead of through them.

/// The seam every ledger value, caption and footer starts on: the label
/// column plus its gutter (§7.2/§12.3). Spelled once, because a caption that
/// re-derived it at each call site is a caption that eventually drifts off
/// the column the value above it sits on.
enum PropertyGrid {
    static let valueOrigin = VoiceOourMetrics.Column.settingsLabel + VoiceOourMetrics.Space.xl
}

// MARK: - Accessory rail

/// What a ledger row carries on its trailing rail besides the fact itself.
///
/// Two kinds, and the row lays them out differently on purpose. A *mark*
/// (`metadata`, `status`) is text: it sits on the value's baseline, because a
/// chip whose label floats off the baseline of the value it qualifies reads
/// as a second row rather than an annotation of the first. A *control*
/// (`copy`, `action`) owns a `Control.medium` band and centres in it;
/// baseline-hanging a 32pt button off a 13pt value drops it past the row's
/// floor and re-opens the pitch the ledger exists to fix.
enum PropertyAccessory {
    /// A quiet trailing annotation — a count, a duration, a build number.
    /// Monospaced digits so a column of them does not shimmer between states.
    case metadata(String)

    /// The row's state as a compact mark. Prominence in this pane family is
    /// the chip's mode, never a promoted type scale.
    case status(String, StatusChip.Mode)

    /// Puts `payload` on the pasteboard. No acknowledgement state: a fact row
    /// that flashes is a fact row that moves, and the pasteboard is not the
    /// row's state to report.
    case copy(payload: String, label: String, identifier: String)

    /// Remediation. `label` and `identifier` are instance-scoped (§12.6)
    /// because several rows in one pane carry the same visible title.
    case action(
        title: String,
        kind: GlassButtonStyle.Kind = .ghost,
        label: String,
        identifier: String,
        isEnabled: Bool = true,
        isInFlight: Bool = false,
        perform: () -> Void
    )

    /// Marks share the value's baseline; controls centre in the band. The row
    /// resolves the two in different alignment domains, so it has to be able
    /// to tell them apart before it lays either out.
    var isMark: Bool {
        switch self {
        case .metadata, .status:
            true
        case .copy, .action:
            false
        }
    }
}

/// How a row renders its value.
///
/// `.mono` is the machine-value policy: the string is a path, an endpoint, a
/// model id or a shell command, so it keeps the mono face, truncates in the
/// middle because both ends carry meaning, and hands the full string to a
/// tooltip. It is deliberately **not** selectable — a selectable leaf forces
/// the row out of its combined accessibility element, and the copy accessory
/// already delivers the whole value with one press and a spoken label.
enum PropertyValueStyle {
    case body
    case mono
}

// MARK: - PropertyRow

/// One fact on the console's shared grid: a fixed label column, the value at
/// the same 200pt seam every control in the app starts on, and a trailing
/// rail of marks and remediations.
///
/// The value is optional. A readiness row whose entire payload is a chip and
/// a sentence has nothing to put at the seam, and inventing a placeholder
/// there would be a value that says nothing at full contrast.
struct PropertyRow: View {
    var label: String
    var value: String?
    var valueStyle: PropertyValueStyle
    var caption: String?
    var captionColor: Color?
    var accessories: [PropertyAccessory]
    /// Replaces the composed spoken value when the parts do not read as a
    /// sentence in the order the eye takes them.
    var accessibilityValueOverride: String?

    @Environment(\.isEnabled) private var isEnabled
    private var a11y = A11y()

    /// Explicit: a private stored property makes the synthesised memberwise
    /// initializer private too.
    init(
        _ label: String,
        value: String? = nil,
        valueStyle: PropertyValueStyle = .body,
        caption: String? = nil,
        captionColor: Color? = nil,
        accessories: [PropertyAccessory] = [],
        accessibilityValue: String? = nil
    ) {
        self.label = label
        self.value = value
        self.valueStyle = valueStyle
        self.caption = caption
        self.captionColor = captionColor
        self.accessories = accessories
        self.accessibilityValueOverride = accessibilityValue
    }

    /// A row with nothing to press is one fact, and VoiceOver should read it
    /// as one: label, then the composed value. The moment the row owns a copy
    /// or a remediation, the row's texts and controls stay direct siblings of
    /// the pane — the same flat treatment Glossary and Sessions rows use.
    /// Wrapping them in a `.contain` group is not an option here: SwiftUI
    /// reports the contained group's frame as the text band, not the padded
    /// row, so the 32pt control "escapes" a 17pt parent and trips the
    /// harness's clipped-child rule on geometry that is visually correct.
    @ViewBuilder
    var body: some View {
        if hasControlAccessory {
            row
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
                .accessibilityValue(accessibilityValueOverride ?? composedAccessibilityValue)
        }
    }

    /// A row with no value and no control is pure prose. Dropping its caption
    /// to a second line leaves the label beside an empty 32pt band and the
    /// prose floating below it — two strays instead of one fact. So the
    /// caption takes the value slot on line one, sharing the label's first
    /// baseline, and the marks that grade it keep the trailing rail they
    /// already close. Only rows that actually populate line one push their
    /// caption down: a value, or a control whose 32pt band leaves the
    /// sentence no room to be read.
    private var captionIsInline: Bool {
        value == nil && !hasControlAccessory && caption != nil
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
            band

            if let caption, !captionIsInline {
                // At the value origin, never indented behind whatever mark
                // happens to sit on line one: a caption that starts under the
                // chip loses the column the value above it established.
                CaptionText(caption, color: captionColor)
                    .padding(.leading, PropertyGrid.valueOrigin)
            }
        }
        .padding(.vertical, VoiceOourMetrics.Space.xs)
        .frame(
            maxWidth: .infinity,
            minHeight: minimumPitch,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .anchorPreference(key: SettingsRowBoundsPreferenceKey.self, value: .bounds) { [$0] }
        .settingsContentLead(VoiceOourMetrics.Space.xs)
    }

    /// Line one, in two alignment domains.
    ///
    /// One `HStack` cannot serve both: the marks have to share the value's
    /// `firstTextBaseline`, and the controls have to centre in the
    /// `Control.medium` band that sets the row's height. Nesting the
    /// baseline-aligned text run inside a centred outer stack gets both with
    /// no hand-tuned offset between a 13pt baseline and a 32pt control.
    ///
    /// That is also why the rail renders marks before controls rather than in
    /// strict declaration order: they live in different stacks. Every ledger
    /// row in the app declares them that way already — the mark grades the
    /// fact, the control acts on it, and the control closes the rail on the
    /// card's trailing content edge.
    private var band: some View {
        HStack(alignment: .center, spacing: VoiceOourMetrics.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: VoiceOourMetrics.Space.xl) {
                labelText

                HStack(alignment: .firstTextBaseline, spacing: VoiceOourMetrics.Space.sm) {
                    valueText

                    if captionIsInline, let caption {
                        CaptionText(caption, color: captionColor)
                    }

                    Spacer(minLength: VoiceOourMetrics.Space.sm)

                    ForEach(markIndices, id: \.self) { index in
                        accessoryView(accessories[index])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(controlIndices, id: \.self) { index in
                accessoryView(accessories[index])
            }
        }
        .frame(minHeight: VoiceOourMetrics.Control.medium)
    }

    private var labelText: some View {
        Text(label)
            .font(VoiceOourTypography.label)
            .foregroundStyle(labelForeground)
            .recordTextRole(.label, foreground: labelForeground)
            .frame(width: VoiceOourMetrics.Column.settingsLabel, alignment: .leading)
    }

    @ViewBuilder
    private var valueText: some View {
        if let value {
            switch valueStyle {
            case .body:
                Text(value)
                    .font(VoiceOourTypography.body)
                    .foregroundStyle(bodyValueForeground)
                    .recordTextRole(.body, foreground: bodyValueForeground)
                    .lineLimit(1)
            case .mono:
                Text(value)
                    // Spelled out rather than `roleStyle(.bodyMono)`: the role
                    // pins its colour closer to the leaf than any override
                    // applied over it, and this value has a disabled tone.
                    .font(VoiceOourTypography.bodyMono)
                    .foregroundStyle(monoValueForeground)
                    .recordTextRole(.bodyMono, foreground: monoValueForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
            }
        }
    }

    @ViewBuilder
    private func accessoryView(_ accessory: PropertyAccessory) -> some View {
        switch accessory {
        case .metadata(let text):
            // Already the A11y low tone in both states, which is what R5 asks
            // a disabled row to resolve to — there is no brighter enabled
            // variant to recede from, so there is no branch here to keep in
            // step with the label and value above.
            Text(text)
                .font(VoiceOourTypography.micro.monospacedDigit())
                .tracking(TextRole.micro.tracking)
                .foregroundStyle(a11y.textLow)
                .recordTextRole(.micro, foreground: a11y.textLow)
                .lineLimit(1)

        case .status(let statusLabel, let mode):
            StatusChip(label: statusLabel, mode: mode, size: .compact)

        case .copy(let payload, let axLabel, let identifier):
            RowIconButton(
                systemName: "doc.on.doc",
                accessibilityLabel: axLabel,
                accessibilityIdentifier: identifier
            ) {
                GeneralPasteboard.copy(payload)
            }

        case .action(let title, let kind, let axLabel, let identifier, let isActionEnabled, let isInFlight, let perform):
            Button(title, action: perform)
                .buttonStyle(GlassButtonStyle(kind: kind, isInFlight: isInFlight))
                .disabled(!isActionEnabled)
                .accessibilityLabel(axLabel)
                .accessibilityIdentifier(identifier)
        }
    }

    // MARK: Tone

    /// One label column, one tone: a ledger section stacks `PropertyRow` and
    /// `SettingsRow` in the same 176pt column, so their labels have to resolve
    /// the same colour or the column reads as damage. Disabled recedes to the
    /// A11y low tone here rather than in each pane, which is what lets a
    /// `DependentGroup` switch a whole block off without touching a call site.
    private var labelForeground: Color {
        isEnabled ? VoiceOourPalette.Text.high : a11y.textLow
    }

    private var bodyValueForeground: Color {
        isEnabled ? VoiceOourPalette.Text.high : a11y.textLow
    }

    private var monoValueForeground: Color {
        isEnabled ? VoiceOourPalette.Text.mono : a11y.textLow
    }

    // MARK: Geometry and composition

    /// A caption-less row is exactly `Row.table` 40: `Space.xs`, the 32pt
    /// band, `Space.xs`. A captioned one grows naturally and only floors at
    /// `Row.settings` — a single caption line already clears that floor, so it
    /// is a guard against an empty caption string, not the row's pitch.
    private var minimumPitch: CGFloat {
        caption == nil ? VoiceOourMetrics.Row.table : VoiceOourMetrics.Row.settings
    }

    private var markIndices: [Int] {
        accessories.indices.filter { accessories[$0].isMark }
    }

    private var controlIndices: [Int] {
        accessories.indices.filter { !accessories[$0].isMark }
    }

    private var hasControlAccessory: Bool {
        accessories.contains { !$0.isMark }
    }

    /// The fact, then the state that grades it, then the sentence that
    /// explains it, then the quiet annotation — the order the eye takes them,
    /// not the order they are laid out in.
    private var composedAccessibilityValue: String {
        var parts: [String] = []

        if let value {
            parts.append(value)
        }
        for accessory in accessories {
            if case .status(let statusLabel, _) = accessory {
                parts.append(statusLabel.uppercased())
            }
        }
        if let caption {
            parts.append(caption)
        }
        for accessory in accessories {
            if case .metadata(let text) = accessory {
                parts.append(text)
            }
        }

        return parts.joined(separator: ", ")
    }
}

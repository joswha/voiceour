import SwiftUI

extension Kit {
    /// A search field in a glass capsule, with the clear button that appears once
    /// there is something to clear.
    ///
    /// Escape clears a field that holds text, and Return runs `onSubmit` — the list
    /// moves its selection to the first match there.
    struct SearchField: View {
        private let prompt: String
        @Binding private var text: String
        private let identifier: String
        private let clearIdentifier: String
        private let focus: FocusState<Bool>.Binding?
        private let onSubmit: (() -> Void)?

        init(
            _ prompt: String,
            text: Binding<String>,
            identifier: String,
            clearIdentifier: String,
            focus: FocusState<Bool>.Binding? = nil,
            onSubmit: (() -> Void)? = nil
        ) {
            self.prompt = prompt
            self._text = text
            self.identifier = identifier
            self.clearIdentifier = clearIdentifier
            self.focus = focus
            self.onSubmit = onSubmit
        }

        var body: some View {
            HStack(spacing: VoiceourMetrics.Space.xs + VoiceourMetrics.Space.hair) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                field

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: Kit.Metrics.glyphControl, height: Kit.Metrics.glyphControl)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier(clearIdentifier)
                }
            }
            .padding(.leading, VoiceourMetrics.Space.md)
            .padding(.trailing, VoiceourMetrics.Space.xs)
            .frame(height: Kit.Metrics.control)
            .kitGlass(in: Capsule(), interactive: true)
        }

        @ViewBuilder
        private var field: some View {
            let base = TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onSubmit { onSubmit?() }
                .onExitCommand {
                    if !text.isEmpty { text = "" }
                }
                .accessibilityIdentifier(identifier)
            if let focus {
                base.focused(focus)
            } else {
                base
            }
        }
    }

    /// A labelled glass button, the kit's one action control.
    ///
    /// `.primary` is the page's one main action and takes the prominent glass; every
    /// other action is plain glass. Reduce Transparency trades both for the bordered
    /// styles, which draw the same hierarchy without a material.
    ///
    /// The glyph sits in a fixed box: at the large control size a glass button is 28 pt
    /// with a text label, and a tall symbol such as `doc.on.doc` grows it to 30, off the
    /// Control scale and out of line with its neighbours in the bar. In a compact bar
    /// (`kitCompactControls`) a button with a glyph draws the glyph alone and keeps its
    /// title as its accessibility label; its caller's tooltip says the rest.
    struct ActionButton: View {
        enum Prominence {
            case standard
            case primary
        }

        private let title: String
        private let systemImage: String?
        private let prominence: Prominence
        private let role: ButtonRole?
        private let action: () -> Void
        @Environment(\.kitCompactControls) private var isCompact
        private var a11y = A11y()

        init(
            _ title: String,
            systemImage: String? = nil,
            prominence: Prominence = .standard,
            role: ButtonRole? = nil,
            action: @escaping () -> Void
        ) {
            self.title = title
            self.systemImage = systemImage
            self.prominence = prominence
            self.role = role
            self.action = action
        }

        var body: some View {
            let showsTitle = !isCompact || systemImage == nil
            let button = Button(role: role, action: action) {
                Kit.ControlLabel(showsTitle ? title : nil, systemImage: systemImage)
            }
            .controlSize(.large)
            .accessibilityLabel(title)

            switch (prominence, a11y.reduceTransparency) {
            case (.primary, false): button.buttonStyle(.glassProminent)
            case (.standard, false): button.buttonStyle(.glass)
            case (.primary, true): button.buttonStyle(.borderedProminent)
            case (.standard, true): button.buttonStyle(.bordered)
            }
        }
    }

    /// A glass pull-down: the More menu on a page, File Under, the app filter.
    ///
    /// `identifier` is required because a menu whose label is a bare symbol otherwise
    /// publishes the symbol's name as its identifier, and a flow would be addressing a
    /// glyph choice.
    struct MenuButton<Content: View>: View {
        private let title: String
        private let systemImage: String
        private let showsTitle: Bool
        private let help: String?
        private let identifier: String
        private let content: Content
        @Environment(\.kitCompactControls) private var isCompact
        private var a11y = A11y()

        /// `showsTitle` false draws the glyph alone; the title still names the control.
        /// `help` is the tooltip when it should say more than the title.
        init(
            _ title: String,
            systemImage: String,
            showsTitle: Bool = true,
            help: String? = nil,
            identifier: String,
            @ViewBuilder content: () -> Content
        ) {
            self.title = title
            self.systemImage = systemImage
            self.showsTitle = showsTitle
            self.help = help
            self.identifier = identifier
            self.content = content()
        }

        var body: some View {
            let menu = Menu {
                content
            } label: {
                Kit.ControlLabel(showsTitle && !isCompact ? title : nil, systemImage: systemImage)
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .controlSize(.large)
            .fixedSize()
            .help(help ?? title)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)

            if a11y.reduceTransparency {
                menu.buttonStyle(.bordered)
            } else {
                menu.buttonStyle(.glass)
            }
        }
    }

    /// A control's label: a glyph in a fixed box, then the title when there is one.
    struct ControlLabel: View {
        private let title: String?
        private let systemImage: String?

        init(_ title: String?, systemImage: String?) {
            self.title = title
            self.systemImage = systemImage
        }

        var body: some View {
            HStack(spacing: VoiceourMetrics.Space.xs + 1) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: VoiceourMetrics.Space.lg, height: VoiceourMetrics.Space.lg)
                        .accessibilityHidden(true)
                }
                if let title {
                    Text(title)
                        .lineLimit(1)
                }
            }
        }
    }

    /// A narrowing in force, as a glass chip with the button that lifts it.
    struct FilterChip: View {
        private let title: String
        private let systemImage: String?
        private let clearLabel: String
        private let clearIdentifier: String
        private let onClear: () -> Void

        init(
            _ title: String,
            systemImage: String? = nil,
            clearLabel: String,
            clearIdentifier: String,
            onClear: @escaping () -> Void
        ) {
            self.title = title
            self.systemImage = systemImage
            self.clearLabel = clearLabel
            self.clearIdentifier = clearIdentifier
            self.onClear = onClear
        }

        var body: some View {
            HStack(spacing: VoiceourMetrics.Space.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(Kit.Fonts.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: Kit.Metrics.glyphControl, height: Kit.Metrics.glyphControl)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(clearLabel)
                .accessibilityLabel(clearLabel)
                .accessibilityIdentifier(clearIdentifier)
            }
            .padding(.leading, VoiceourMetrics.Space.md)
            .padding(.trailing, VoiceourMetrics.Space.hair)
            .frame(height: Kit.Metrics.control)
            .kitGlass(in: Capsule(), interactive: true)
        }
    }

    /// A fold: a heading that opens and shuts what sits under it.
    ///
    /// A button rather than a disclosure triangle, because the whole heading is the
    /// target and VoiceOver hears "Expanded" or "Collapsed" as the button's value
    /// instead of a triangle's bare 0 or 1.
    struct Disclosure<Content: View>: View {
        private let title: String
        @Binding private var isExpanded: Bool
        private let identifier: String
        private let content: Content
        private var a11y = A11y()

        init(
            _ title: String,
            isExpanded: Binding<Bool>,
            identifier: String,
            @ViewBuilder content: () -> Content
        ) {
            self.title = title
            self._isExpanded = isExpanded
            self.identifier = identifier
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                Button {
                    withAnimation(Kit.Motion.quick(a11y)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: VoiceourMetrics.Space.sm) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(a11y.textMid)
                            .frame(width: VoiceourMetrics.Space.md)
                        Text(title)
                            .roleStyle(.heading)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Kit.Metrics.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier(identifier)

                if isExpanded {
                    content
                        .padding(.leading, VoiceourMetrics.Space.lg + VoiceourMetrics.Space.xs)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The surface a list row or sidebar item draws for its state.
    ///
    /// A selected row is lit as a small island: the pane fill, a specular hairline and
    /// a 1 pt rim in the signal green — a crisp stroke rather than a glow, so the
    /// offscreen harness captures the same edge the reader sees. Hover and press are
    /// faint white washes; at rest the row draws nothing. Every state declares what it
    /// paints as the ground under the row's text. Increase Contrast thickens the rim
    /// and strengthens the washes; Reduce Transparency flattens the selected row to an
    /// opaque surface with the rim alone.
    struct RowButtonStyle: ButtonStyle {
        private let isSelected: Bool

        init(isSelected: Bool) {
            self.isSelected = isSelected
        }

        func makeBody(configuration: Configuration) -> some View {
            RowSurface(isSelected: isSelected, isPressed: configuration.isPressed) {
                configuration.label
            }
        }
    }

    /// The row surface ``RowButtonStyle`` draws, which needs state of its own for hover.
    private struct RowSurface<Label: View>: View {
        private let isSelected: Bool
        private let isPressed: Bool
        private let label: Label
        @State private var isHovered = false
        private var a11y = A11y()
        @Environment(\.surfaceGround) private var inheritedGround

        init(isSelected: Bool, isPressed: Bool, @ViewBuilder label: () -> Label) {
            self.isSelected = isSelected
            self.isPressed = isPressed
            self.label = label()
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.rowRadius, style: .continuous)
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { surface(in: shape) }
                .environment(\.surfaceGround, ground)
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }

        @ViewBuilder
        private func surface(in shape: RoundedRectangle) -> some View {
            if isSelected {
                let rim: CGFloat = a11y.contrast == .increased ? 1.5 : 1
                if a11y.reduceTransparency {
                    shape
                        .fill(VoiceourPalette.Ink.surface)
                        .overlay { shape.strokeBorder(Kit.Colors.signal, lineWidth: rim) }
                } else {
                    ZStack {
                        shape.fill(Kit.Colors.selection(a11y))
                        RoundedRectangle(
                            cornerRadius: VoiceourMetrics.Radius.nested(Kit.Metrics.rowRadius, inset: rim),
                            style: .continuous
                        )
                        .strokeBorder(VoiceourPalette.specularRim, lineWidth: Kit.Colors.hairline(a11y))
                        .blendMode(.plusLighter)
                        .padding(rim)
                        shape.strokeBorder(Kit.Colors.signal, lineWidth: rim)
                    }
                }
            } else if isPressed {
                shape.fill(Kit.Colors.pressed(a11y))
            } else if isHovered {
                shape.fill(Kit.Colors.hover(a11y))
            }
        }

        private var ground: SurfaceGround {
            if isSelected {
                return a11y.reduceTransparency
                    ? SurfaceGround(VoiceourPalette.Ink.surface)
                    : inheritedGround.painting(Kit.Colors.selection(a11y))
            }
            if isPressed { return inheritedGround.painting(Kit.Colors.pressed(a11y)) }
            if isHovered { return inheritedGround.painting(Kit.Colors.hover(a11y)) }
            return inheritedGround
        }
    }

    /// One destination in the sidebar: a glyph, a name, how many items it holds, and
    /// whether something there needs the reader. On the rail (`kitCompactControls`) it
    /// draws the glyph alone, and the name, count and attention stay its
    /// accessibility label and value and become its tooltip.
    ///
    /// The glyph takes the signal green when the item is selected, beside the row's
    /// lit rim. Attention is a state, so it is never colour alone: a caution triangle
    /// or a critical octagon trails the row, and VoiceOver hears "needs attention".
    struct SidebarItem: View {
        enum Attention {
            case caution
            case critical

            var symbol: String {
                switch self {
                case .caution: "exclamationmark.triangle.fill"
                case .critical: "xmark.octagon.fill"
                }
            }

            var color: Color {
                switch self {
                case .caution: VoiceourPalette.Signal.amber
                case .critical: VoiceourPalette.Signal.crimson
                }
            }
        }

        private let title: String
        private let systemImage: String
        private let count: Int?
        private let isSelected: Bool
        private let attention: Attention?
        private let action: () -> Void
        @Environment(\.kitCompactControls) private var isCompact
        private var a11y = A11y()

        init(
            _ title: String,
            systemImage: String,
            count: Int? = nil,
            isSelected: Bool,
            attention: Attention? = nil,
            action: @escaping () -> Void
        ) {
            self.title = title
            self.systemImage = systemImage
            self.count = count
            self.isSelected = isSelected
            self.attention = attention
            self.action = action
        }

        var body: some View {
            let item = Button(action: action) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Kit.Colors.signal : a11y.textMid)
                        .frame(width: VoiceourMetrics.Space.xl - VoiceourMetrics.Space.xs)
                        .overlay(alignment: .topTrailing) {
                            if isCompact, let attention {
                                attentionGlyph(attention, size: 8)
                                    .offset(x: VoiceourMetrics.Space.xs, y: -VoiceourMetrics.Space.xs)
                            }
                        }
                        .accessibilityHidden(true)
                    if !isCompact {
                        Text(title)
                            .roleStyle(isSelected ? .heading : .body)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: VoiceourMetrics.Space.xs)
                        if let count {
                            // Digits by hand, so no locale's grouping separator reaches a golden.
                            Text(verbatim: String(count))
                                .roleStyle(.caption)
                                .foregroundStyle(a11y.textMid)
                                .monospacedDigit()
                        }
                        if let attention {
                            attentionGlyph(attention, size: 10)
                        }
                    }
                }
                .padding(.horizontal, isCompact ? 0 : VoiceourMetrics.Space.sm)
                .frame(maxWidth: isCompact ? .infinity : nil)
                .frame(height: VoiceourMetrics.Control.medium)
            }
            .buttonStyle(RowButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            if isCompact {
                item.help(([title] + facts).joined(separator: ", "))
            } else {
                item
            }
        }

        private func attentionGlyph(_ attention: Attention, size: CGFloat) -> some View {
            Image(systemName: attention.symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(attention.color)
                .accessibilityHidden(true)
        }

        /// The count, then "needs attention", as VoiceOver and the rail's tooltip say them.
        private var facts: [String] {
            var facts: [String] = []
            if let count { facts.append(String(count)) }
            if attention != nil { facts.append("needs attention") }
            return facts
        }

        private var accessibilityValue: String {
            facts.joined(separator: ", ")
        }
    }

    /// The sidebar: a floating glass panel holding a column of ``Kit/SidebarItem``s and
    /// ``Kit/SidebarHeading``s, so every console tab that browses steers the same way.
    struct Sidebar<Content: View>: View {
        private let content: Content

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            Kit.GlassPanel {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    content
                }
                .padding(VoiceourMetrics.Space.sm)
            }
        }
    }

    /// A heading inside the sidebar, over the items it groups: the Journal's "Recent
    /// Threads". On the rail, where a name has no room, it draws a rule and keeps its
    /// name as the rule's tooltip.
    struct SidebarHeading: View {
        private let title: String
        @Environment(\.kitCompactControls) private var isCompact
        private var a11y = A11y()

        init(_ title: String) {
            self.title = title
        }

        var body: some View {
            if isCompact {
                Kit.Rule()
                    .padding(.horizontal, VoiceourMetrics.Space.sm)
                    .padding(.vertical, VoiceourMetrics.Space.xs)
                    .help(title)
            } else {
                Text(title)
                    .roleStyle(.subheading)
                    .foregroundStyle(a11y.textMid)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, VoiceourMetrics.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// One preference inside an island: its name leading and its control trailing on
    /// the same line, then a caption under both that says what the preference does.
    ///
    /// The caption is a sibling of the control, never its label: a control's label is
    /// what VoiceOver names it by, and a sentence there would be read on every focus.
    /// Rows stack inside an island separated by ``Kit/Rule``. `captionColor` lets a
    /// caption carry a state's colour — a refusal in crimson — when the words already
    /// say the state.
    struct SettingRow<Control: View>: View {
        private let title: String
        private let caption: String?
        private let captionColor: Color?
        private let control: Control
        private var a11y = A11y()

        init(
            _ title: String,
            caption: String? = nil,
            captionColor: Color? = nil,
            @ViewBuilder control: () -> Control
        ) {
            self.title = title
            self.caption = caption
            self.captionColor = captionColor
            self.control = control()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                HStack(alignment: .center, spacing: VoiceourMetrics.Space.md) {
                    Text(title)
                        .roleStyle(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: VoiceourMetrics.Space.md)
                    control
                }
                .frame(minHeight: Kit.Metrics.control)
                if let caption {
                    Text(caption)
                        .roleStyle(.caption)
                        .foregroundStyle(captionColor ?? a11y.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, VoiceourMetrics.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

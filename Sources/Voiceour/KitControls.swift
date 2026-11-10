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
                            .foregroundStyle(.secondary)
                            .frame(width: VoiceourMetrics.Space.md)
                        Text(title)
                            .font(Kit.Fonts.sectionTitle)
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

    /// The fill a list row or sidebar item draws for its state: the accent wash when
    /// selected, a faint wash under the pointer or the press, nothing at rest.
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

        init(isSelected: Bool, isPressed: Bool, @ViewBuilder label: () -> Label) {
            self.isSelected = isSelected
            self.isPressed = isPressed
            self.label = label()
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.rowRadius, style: .continuous)
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill, in: shape)
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }

        private var fill: Color {
            if isSelected { return Kit.Colors.selection(a11y) }
            if isPressed { return Kit.Colors.pressed(a11y) }
            if isHovered { return Kit.Colors.hover(a11y) }
            return .clear
        }
    }

    /// One destination in the sidebar: a glyph, a name and how many items it holds. On the
    /// rail (`kitCompactControls`) it draws the glyph alone, and the name and count stay
    /// its accessibility label and value and become its tooltip.
    struct SidebarItem: View {
        private let title: String
        private let systemImage: String
        private let count: Int?
        private let isSelected: Bool
        private let action: () -> Void
        @Environment(\.kitCompactControls) private var isCompact

        init(
            _ title: String,
            systemImage: String,
            count: Int? = nil,
            isSelected: Bool,
            action: @escaping () -> Void
        ) {
            self.title = title
            self.systemImage = systemImage
            self.count = count
            self.isSelected = isSelected
            self.action = action
        }

        var body: some View {
            let item = Button(action: action) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: VoiceourMetrics.Space.xl - VoiceourMetrics.Space.xs)
                        .accessibilityHidden(true)
                    if !isCompact {
                        Text(title)
                            .font(Kit.Fonts.sidebarItem)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: VoiceourMetrics.Space.xs)
                        if let count {
                            // Digits by hand, so no locale's grouping separator reaches a golden.
                            Text(verbatim: String(count))
                                .font(Kit.Fonts.meta)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, isCompact ? 0 : VoiceourMetrics.Space.sm)
                .frame(maxWidth: isCompact ? .infinity : nil)
                .frame(height: VoiceourMetrics.Control.medium)
            }
            .buttonStyle(RowButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(count.map(String.init) ?? "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            if isCompact {
                item.help(count.map { "\(title), \($0)" } ?? title)
            } else {
                item
            }
        }
    }
}

import SwiftUI

extension Kit {
    /// The kit's one labelled action control.
    ///
    /// `.primary` is the page's one main action and the only accent fill in a bar;
    /// `.secondary` is a bordered plate, `.plain` an accent-coloured word, and
    /// `.destructive` names an action that removes something (its confirmation stays the
    /// native dialog). In a compact bar (`kitCompactControls`) a button with a glyph
    /// draws the glyph alone; its title stays its accessibility label, and its caller's
    /// tooltip says the rest.
    struct Button: View {
        enum Prominence {
            case primary
            case secondary
            case plain
            case destructive
        }

        private let title: String
        private let systemImage: String?
        private let prominence: Prominence
        private let action: () -> Void
        @Environment(\.kitCompactControls) private var isCompact

        init(
            _ title: String,
            systemImage: String? = nil,
            prominence: Prominence = .secondary,
            action: @escaping () -> Void
        ) {
            self.title = title
            self.systemImage = systemImage
            self.prominence = prominence
            self.action = action
        }

        var body: some View {
            let glyphOnly = isCompact && systemImage != nil
            SwiftUI.Button(role: prominence == .destructive ? .destructive : nil, action: action) {
                ControlLabel(glyphOnly ? nil : title, systemImage: systemImage)
            }
            .buttonStyle(ControlStyle(kind: ControlStyle.Kind(prominence), isSquare: glyphOnly))
            .focusEffectDisabled()
            .accessibilityLabel(title)
        }
    }

    /// A glyph-only action in a bar or beside a field: 28 pt square, no plate until the
    /// pointer is over it. `label` names it to VoiceOver and is its tooltip.
    struct IconButton: View {
        private let systemImage: String
        private let label: String
        private let action: () -> Void

        init(systemImage: String, label: String, action: @escaping () -> Void) {
            self.systemImage = systemImage
            self.label = label
            self.action = action
        }

        var body: some View {
            SwiftUI.Button(action: action) {
                ControlLabel(nil, systemImage: systemImage)
            }
            .buttonStyle(ControlStyle(kind: .icon, isSquare: true))
            .focusEffectDisabled()
            .help(label)
            .accessibilityLabel(label)
        }
    }

    /// A pull-down: the More menu on a page, File Under, the app filter. A native
    /// `Menu`, so its items are a real NSMenu with keyboard navigation, drawn without a
    /// bezel like ``Kit/IconButton``; a titled one adds a chevron so it reads as a
    /// control rather than a word.
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
            let glyphOnly = !showsTitle || isCompact
            Menu {
                content
            } label: {
                MenuChrome(title: glyphOnly ? nil : title, systemImage: systemImage)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help ?? title)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        }
    }

    /// The drawn face of a ``Kit/MenuButton``, which needs hover state of its own because
    /// a menu takes no `ButtonStyle` of the kit's.
    private struct MenuChrome: View {
        private let title: String?
        private let systemImage: String
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.surfaceGround) private var inheritedGround
        @State private var isHovered = false

        init(title: String?, systemImage: String) {
            self.title = title
            self.systemImage = systemImage
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.controlRadius, style: .continuous)
            let showsPlate = isHovered && isEnabled
            HStack(spacing: VoiceourMetrics.Space.xs) {
                ControlLabel(title, systemImage: systemImage)
                if title != nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .roleStyle(.body, color: foreground)
            .padding(.horizontal, title == nil ? 0 : VoiceourMetrics.Space.sm)
            .frame(minWidth: Kit.Metrics.controlHeight, minHeight: Kit.Metrics.controlHeight)
            .frame(height: Kit.Metrics.controlHeight)
            .background {
                if showsPlate { shape.fill(theme.hover) }
            }
            .environment(\.surfaceGround, showsPlate ? SurfaceGround(theme.hover) : inheritedGround)
            .contentShape(shape)
            .onHover { isHovered = $0 }
        }

        private var foreground: Color {
            guard isEnabled else { return theme.textDisabled }
            if title != nil || isHovered { return theme.text1 }
            return theme.text2
        }
    }

    /// A control's label: a glyph in a fixed 16 pt box, so a tall symbol such as
    /// `doc.on.doc` cannot grow the control off the 28 pt scale, then the title when
    /// there is one. Colour and face come from the style that draws it.
    private struct ControlLabel: View {
        private let title: String?
        private let systemImage: String?

        init(_ title: String?, systemImage: String?) {
            self.title = title
            self.systemImage = systemImage
        }

        var body: some View {
            HStack(spacing: VoiceourMetrics.Space.xs + VoiceourMetrics.Space.hair) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: VoiceourMetrics.Space.lg, height: VoiceourMetrics.Space.lg)
                        .accessibilityHidden(true)
                }
                if let title {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// How ``Kit/Button`` and ``Kit/IconButton`` draw each state: the plate, its
    /// outline, the label colour, and a 2 pt focus ring outside the plate when the
    /// keyboard is on it. A disabled control draws its label in `textDisabled`; a
    /// secondary or destructive one keeps its plate and outline, and a disabled primary
    /// trades the accent fill for the quiet `hover` plate, so it never looks actionable.
    private struct ControlStyle: ButtonStyle {
        enum Kind {
            case primary
            case secondary
            case plain
            case destructive
            case icon

            init(_ prominence: Kit.Button.Prominence) {
                switch prominence {
                case .primary: self = .primary
                case .secondary: self = .secondary
                case .plain: self = .plain
                case .destructive: self = .destructive
                }
            }
        }

        let kind: Kind
        let isSquare: Bool

        func makeBody(configuration: Configuration) -> some View {
            ControlBody(kind: kind, isSquare: isSquare, isPressed: configuration.isPressed) {
                configuration.label
            }
        }
    }

    private struct ControlBody<Label: View>: View {
        private let kind: ControlStyle.Kind
        private let isSquare: Bool
        private let isPressed: Bool
        private let label: Label
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.surfaceGround) private var inheritedGround
        @State private var isHovered = false

        init(kind: ControlStyle.Kind, isSquare: Bool, isPressed: Bool, @ViewBuilder label: () -> Label) {
            self.kind = kind
            self.isSquare = isSquare
            self.isPressed = isPressed
            self.label = label()
        }

        var body: some View {
            let radius = Kit.Metrics.controlRadius
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let ring: CGFloat = 2
            label
                .roleStyle(.body, color: foreground)
                .padding(.horizontal, isSquare ? 0 : VoiceourMetrics.Space.md)
                .frame(minWidth: Kit.Metrics.controlHeight)
                .frame(width: isSquare ? Kit.Metrics.controlHeight : nil, height: Kit.Metrics.controlHeight)
                .background {
                    if let fill { shape.fill(fill) }
                }
                .overlay {
                    if let outline { shape.strokeBorder(outline, lineWidth: 1) }
                }
                .overlay {
                    if isFocused && isEnabled {
                        RoundedRectangle(cornerRadius: radius + ring + 1, style: .continuous)
                            .strokeBorder(theme.focusRing, lineWidth: ring)
                            .padding(-(ring + 1))
                    }
                }
                .environment(\.surfaceGround, fill.map { SurfaceGround($0) } ?? inheritedGround)
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }

        private var fill: Color? {
            let pressed = isEnabled && isPressed
            let hovered = isEnabled && isHovered
            switch kind {
            case .primary:
                guard isEnabled else { return theme.hover }
                return pressed ? theme.accentPressed : hovered ? theme.accentHover : theme.accent
            case .secondary, .destructive:
                return pressed ? theme.pressed : hovered ? theme.hover : theme.raised
            case .plain, .icon:
                return pressed ? theme.pressed : hovered ? theme.hover : nil
            }
        }

        private var outline: Color? {
            switch kind {
            case .secondary: theme.borderStrong
            case .destructive: theme.border
            case .primary, .plain, .icon: nil
            }
        }

        private var foreground: Color {
            guard isEnabled else { return theme.textDisabled }
            switch kind {
            case .primary: return theme.onAccent
            case .secondary: return theme.text1
            case .plain: return theme.accentText
            case .destructive: return theme.critical.text
            case .icon: return isHovered ? theme.text1 : theme.text2
            }
        }
    }

    /// A search field: a 28 pt `sunken` well with a magnifier, and the clear button that
    /// appears once there is something to clear.
    ///
    /// Escape clears a field that holds text, and Return runs `onSubmit` — the list
    /// moves its selection to the first match there. A long query scrolls inside the
    /// field rather than widening it.
    struct SearchField: View {
        private let prompt: String
        @Binding private var text: String
        private let identifier: String
        private let clearIdentifier: String
        private let focus: FocusState<Bool>.Binding?
        private let onSubmit: (() -> Void)?
        @Environment(\.theme) private var theme
        @FocusState private var isFocused: Bool

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
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.controlRadius, style: .continuous)
            HStack(spacing: VoiceourMetrics.Space.xs + VoiceourMetrics.Space.hair) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.text3)
                    .accessibilityHidden(true)

                field

                if !text.isEmpty {
                    SwiftUI.Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.text3)
                            .frame(width: Kit.Metrics.glyphTarget, height: Kit.Metrics.glyphTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier(clearIdentifier)
                }
            }
            .padding(.leading, VoiceourMetrics.Space.sm)
            .padding(.trailing, VoiceourMetrics.Space.xs)
            .frame(height: Kit.Metrics.controlHeight)
            .background { shape.fill(theme.sunken) }
            .overlay {
                shape.strokeBorder(
                    isFocused ? theme.focusRing : theme.border,
                    lineWidth: isFocused ? 2 : 1
                )
            }
            .environment(\.surfaceGround, SurfaceGround(theme.sunken))
        }

        @ViewBuilder
        private var field: some View {
            let base = TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(theme.text3))
                .textFieldStyle(.plain)
                .font(TextRole.body.font)
                .foregroundStyle(theme.text1)
                .focused($isFocused)
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

    /// A narrowing in force — "App: Cursor" — as a 24 pt token with the button that lifts
    /// it. The token's plate and its leading glyph (the caller's, or a checkmark) say
    /// the filter is on, so the state never rests on colour.
    struct FilterChip: View {
        private let title: String
        private let systemImage: String?
        private let clearLabel: String
        private let clearIdentifier: String
        private let onClear: () -> Void
        @Environment(\.theme) private var theme

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
                Image(systemName: systemImage ?? "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.text1)
                    .accessibilityHidden(true)
                Text(title)
                    .roleStyle(.label)
                    .foregroundStyle(theme.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)

                SwiftUI.Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.text2)
                        .frame(width: Kit.Metrics.glyphTarget, height: Kit.Metrics.glyphTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(clearLabel)
                .accessibilityLabel(clearLabel)
                .accessibilityIdentifier(clearIdentifier)
            }
            .padding(.leading, VoiceourMetrics.Space.sm)
            .padding(.trailing, VoiceourMetrics.Space.hair)
            .frame(height: VoiceourMetrics.Space.xl)
            .background { Capsule().fill(theme.hover) }
            .overlay { Capsule().strokeBorder(theme.border, lineWidth: 1) }
            .environment(\.surfaceGround, SurfaceGround(theme.hover))
        }
    }

    /// A fold: a heading that opens and shuts what sits under it.
    ///
    /// The whole 28 pt heading row is the target, and VoiceOver hears "Expanded" or
    /// "Collapsed" as the button's value instead of a triangle's bare 0 or 1. The
    /// chevron turns with the fold, and lands at once under Reduce Motion.
    struct Disclosure<Content: View>: View {
        private let title: String
        @Binding private var isExpanded: Bool
        private let identifier: String
        private let content: Content
        @Environment(\.theme) private var theme
        @State private var isHovered = false
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
                SwiftUI.Button {
                    withAnimation(Kit.Motion.quick(a11y)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: VoiceourMetrics.Space.sm) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(isHovered ? theme.text1 : theme.text2)
                            .frame(width: VoiceourMetrics.Space.md)
                            .accessibilityHidden(true)
                        Text(title)
                            .roleStyle(.heading)
                            .foregroundStyle(theme.text1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Kit.Metrics.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FocusRingStyle())
                .focusEffectDisabled()
                .onHover { isHovered = $0 }
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier(identifier)

                if isExpanded {
                    content
                        .padding(.leading, VoiceourMetrics.Space.md + VoiceourMetrics.Space.sm)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A plateless button that shows only the keyboard's 2 pt focus ring, for targets
    /// whose look is their content: a fold's heading, a picker's tile.
    struct FocusRingStyle: ButtonStyle {
        var radius: CGFloat = Kit.Metrics.controlRadius
        var outset: CGFloat = VoiceourMetrics.Space.hair

        func makeBody(configuration: Configuration) -> some View {
            FocusRingBody(radius: radius, outset: outset) { configuration.label }
        }
    }

    private struct FocusRingBody<Label: View>: View {
        private let radius: CGFloat
        private let outset: CGFloat
        private let label: Label
        @Environment(\.theme) private var theme
        @Environment(\.isFocused) private var isFocused

        init(radius: CGFloat, outset: CGFloat, @ViewBuilder label: () -> Label) {
            self.radius = radius
            self.outset = outset
            self.label = label()
        }

        var body: some View {
            label.overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: radius + outset, style: .continuous)
                        .strokeBorder(theme.focusRing, lineWidth: 2)
                        .padding(-outset)
                }
            }
        }
    }

    /// The plate a list row draws for its state, VS Code's way: a selected row in the
    /// list that has the keyboard takes the accent-tinted `selection` plate and a 2 pt
    /// `focusRing` bar at its leading edge; a selected row in a list without the
    /// keyboard (`\.kitListFocused` false) takes the quiet `selectionInactive` plate, so
    /// the reader always sees which column the arrow keys move. Hover and press are
    /// washes; at rest the row draws nothing. The plate fills the frame the row is
    /// given — the list column insets its rows — and every state declares the ground
    /// under the row's text.
    struct RowButtonStyle: ButtonStyle {
        private let isSelected: Bool

        init(isSelected: Bool) {
            self.isSelected = isSelected
        }

        func makeBody(configuration: Configuration) -> some View {
            RowPlate(isSelected: isSelected, isPressed: configuration.isPressed) {
                configuration.label
            }
        }
    }

    private struct RowPlate<Label: View>: View {
        private let isSelected: Bool
        private let isPressed: Bool
        private let label: Label
        @Environment(\.theme) private var theme
        @Environment(\.kitListFocused) private var isListFocused
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.surfaceGround) private var inheritedGround
        @State private var isHovered = false

        init(isSelected: Bool, isPressed: Bool, @ViewBuilder label: () -> Label) {
            self.isSelected = isSelected
            self.isPressed = isPressed
            self.label = label()
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.rowRadius, style: .continuous)
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if let fill { shape.fill(fill) }
                }
                .overlay(alignment: .leading) {
                    if isSelected && isListFocused {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(theme.focusRing)
                                .frame(width: 2, height: max(0, proxy.size.height - 12))
                                .position(x: Kit.Metrics.rowInset + 1, y: proxy.size.height / 2)
                        }
                        .accessibilityHidden(true)
                    }
                }
                .environment(\.surfaceGround, fill.map { SurfaceGround($0) } ?? inheritedGround)
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }

        private var fill: Color? {
            if isSelected {
                if isEnabled && isPressed { return theme.pressed }
                return isListFocused ? theme.selection : theme.selectionInactive
            }
            guard isEnabled else { return nil }
            if isPressed { return theme.pressed }
            if isHovered { return theme.hover }
            return nil
        }
    }

    /// One destination in the sidebar: a glyph, a name, and either how many items it
    /// holds or that something there needs the reader.
    ///
    /// Two levels of urgency, as Mail and Slack separate them: a count is quiet — small
    /// dim digits — and attention is loud — a capsule in the status wash with its glyph,
    /// carrying the count when there is one. Never both. The selected item takes the
    /// quiet plate, its glyph in `accentText` and its name in `rowTitle`. On the rail
    /// (`kitCompactControls`) it draws the glyph alone with a 6 pt corner dot for
    /// attention; the name and facts become its tooltip and stay its accessibility
    /// label and value.
    struct SidebarItem: View {
        enum Attention {
            case caution
            case critical
        }

        private let title: String
        private let systemImage: String
        private let count: Int?
        private let isSelected: Bool
        private let attention: Attention?
        private let action: () -> Void
        @Environment(\.kitCompactControls) private var isCompact
        @Environment(\.theme) private var theme

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
            let item = SwiftUI.Button(action: action) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? theme.accentText : theme.text2)
                        .frame(width: VoiceourMetrics.Space.lg, height: VoiceourMetrics.Space.lg)
                        .overlay(alignment: .topTrailing) {
                            if isCompact, let attention {
                                Circle()
                                    .fill(status(attention).text)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 3, y: -2)
                            }
                        }
                        .accessibilityHidden(true)
                    if !isCompact {
                        Text(title)
                            .roleStyle(isSelected ? .rowTitle : .body)
                            .foregroundStyle(isSelected ? theme.text1 : theme.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: VoiceourMetrics.Space.xs)
                        trailing
                    }
                }
                .padding(.horizontal, isCompact ? 0 : VoiceourMetrics.Space.sm)
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
                .frame(height: Kit.Metrics.controlHeight)
            }
            .buttonStyle(SidebarItemStyle(isSelected: isSelected))
            .focusEffectDisabled()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(facts.joined(separator: ", "))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            if isCompact {
                item.help(([title] + facts).joined(separator: ", "))
            } else {
                item
            }
        }

        @ViewBuilder
        private var trailing: some View {
            if let attention {
                let tone = status(attention)
                HStack(spacing: VoiceourMetrics.Space.hair) {
                    Image(systemName: symbol(attention))
                        .font(.system(size: 8, weight: .bold))
                    if let count {
                        Text(verbatim: Self.display(count))
                            .roleStyle(.label)
                            .foregroundStyle(tone.text)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(tone.text)
                .padding(.horizontal, VoiceourMetrics.Space.xs)
                .frame(minWidth: VoiceourMetrics.Space.lg, minHeight: VoiceourMetrics.Space.lg)
                .frame(height: VoiceourMetrics.Space.lg)
                .background { Capsule().fill(tone.wash) }
                .overlay {
                    if theme.isIncreasedContrast {
                        Capsule().strokeBorder(tone.text, lineWidth: 1)
                    }
                }
                .environment(\.surfaceGround, SurfaceGround(tone.wash))
                .fixedSize()
                .accessibilityHidden(true)
            } else if let count {
                Text(verbatim: Self.display(count))
                    .roleStyle(.label)
                    .foregroundStyle(theme.text3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }

        private func status(_ attention: Attention) -> Theme.Status {
            switch attention {
            case .caution: theme.caution
            case .critical: theme.critical
            }
        }

        private func symbol(_ attention: Attention) -> String {
            switch attention {
            case .caution: "exclamationmark.triangle.fill"
            case .critical: "xmark.octagon.fill"
            }
        }

        /// A count as the sidebar draws it, grouped in one pinned locale so a golden never
        /// depends on the Mac's region.
        private static func display(_ count: Int) -> String {
            count.formatted(.number.locale(Locale(identifier: "en_US")))
        }

        /// The count, then "needs attention", as VoiceOver and the rail's tooltip say them.
        private var facts: [String] {
            var facts: [String] = []
            if let count { facts.append(String(count)) }
            if attention != nil { facts.append("needs attention") }
            return facts
        }
    }

    /// The sidebar item's plate: the quiet `selectionInactive` when selected — the
    /// sidebar is chrome, so its selection never competes with the list's — a hover
    /// wash otherwise, and a 2 pt focus ring inside the plate for the keyboard.
    private struct SidebarItemStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            SidebarItemPlate(isSelected: isSelected, isPressed: configuration.isPressed) {
                configuration.label
            }
        }
    }

    private struct SidebarItemPlate<Label: View>: View {
        private let isSelected: Bool
        private let isPressed: Bool
        private let label: Label
        @Environment(\.theme) private var theme
        @Environment(\.isFocused) private var isFocused
        @Environment(\.surfaceGround) private var inheritedGround
        @State private var isHovered = false

        init(isSelected: Bool, isPressed: Bool, @ViewBuilder label: () -> Label) {
            self.isSelected = isSelected
            self.isPressed = isPressed
            self.label = label()
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.rowRadius, style: .continuous)
            label
                .background {
                    if let fill { shape.fill(fill) }
                }
                .overlay {
                    if isFocused { shape.strokeBorder(theme.focusRing, lineWidth: 2) }
                }
                .environment(\.surfaceGround, fill.map { SurfaceGround($0) } ?? inheritedGround)
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }

        private var fill: Color? {
            if isPressed { return theme.pressed }
            if isSelected { return theme.selectionInactive }
            if isHovered { return theme.hover }
            return nil
        }
    }

    /// One preference inside a ``Kit/Group``, System Settings' way: the name with its
    /// caption under it in the leading column, the control trailing and aligned with
    /// the name.
    ///
    /// The caption is a sibling of the control, never its label: a control's label is
    /// what VoiceOver names it by, and a sentence there would be read on every focus.
    /// The leading column always keeps at least half the row, so a wide control never
    /// squeezes the name into one character per line: a control wider than half the row
    /// moves under the caption instead. `captionColor` lets a caption carry a state's
    /// colour — a refusal in the critical text — when the words already say the state.
    struct SettingRow<Control: View>: View {
        private let title: String
        private let caption: String?
        private let captionColor: Color?
        private let control: Control
        @Environment(\.theme) private var theme

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
            let layout = SettingRowLayout()
            layout {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    Text(title)
                        .roleStyle(.body)
                        .foregroundStyle(theme.text1)
                        .fixedSize(horizontal: false, vertical: true)
                    if let caption {
                        Text(caption)
                            .roleStyle(.meta)
                            .foregroundStyle(captionColor ?? theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    control
                }
            }
            .padding(.horizontal, VoiceourMetrics.Space.md)
            .padding(.vertical, VoiceourMetrics.Space.sm)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
    }

    /// Places a setting's text column and its control side by side while the control
    /// takes at most half the row, else stacks the control under the text. A custom
    /// layout because `ViewThatFits` measures text at its one-line ideal width, which
    /// would stack every row with a long caption.
    private struct SettingRowLayout: Layout {
        /// Between the text column and a control beside it.
        private let gap: CGFloat = VoiceourMetrics.Space.md
        /// Between the caption and a control under it.
        private let stackGap: CGFloat = VoiceourMetrics.Space.sm
        /// The name's line at 13 pt, so a control beside it centres on the name's
        /// first line rather than on a multi-line caption.
        private let titleLine: CGFloat = 16

        private struct Arrangement {
            var size: CGSize
            var leading: CGRect
            var control: CGRect
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            arrange(width: proposal.width, subviews: subviews).size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let arrangement = arrange(width: bounds.width, subviews: subviews)
            let parts = [arrangement.leading, arrangement.control]
            for (subview, frame) in zip(subviews, parts) {
                subview.place(
                    at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(frame.size)
                )
            }
        }

        private func arrange(width proposed: CGFloat?, subviews: Subviews) -> Arrangement {
            guard subviews.count == 2 else {
                return Arrangement(size: .zero, leading: .zero, control: .zero)
            }
            let leading = subviews[0]
            let control = subviews[1]
            let controlIdeal = control.sizeThatFits(.unspecified)
            let width: CGFloat
            if let proposed, proposed.isFinite {
                width = proposed
            } else {
                width = leading.sizeThatFits(.unspecified).width + gap + controlIdeal.width
            }

            if controlIdeal.width + gap <= width / 2 {
                let leadingWidth = max(0, width - controlIdeal.width - gap)
                let leadingHeight = leading.sizeThatFits(ProposedViewSize(width: leadingWidth, height: nil)).height
                let leadingY = max(0, (controlIdeal.height - titleLine) / 2)
                let controlY = max(0, (titleLine - controlIdeal.height) / 2)
                let height = max(leadingY + leadingHeight, controlY + controlIdeal.height)
                return Arrangement(
                    size: CGSize(width: width, height: height),
                    leading: CGRect(x: 0, y: leadingY, width: leadingWidth, height: leadingHeight),
                    control: CGRect(
                        x: width - controlIdeal.width,
                        y: controlY,
                        width: controlIdeal.width,
                        height: controlIdeal.height
                    )
                )
            }

            let leadingHeight = leading.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let controlSize = control.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let controlWidth = min(controlSize.width, width)
            let controlY = leadingHeight + stackGap
            return Arrangement(
                size: CGSize(width: width, height: controlY + controlSize.height),
                leading: CGRect(x: 0, y: 0, width: width, height: leadingHeight),
                control: CGRect(x: 0, y: controlY, width: controlWidth, height: controlSize.height)
            )
        }
    }
}

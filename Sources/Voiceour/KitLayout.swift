import SwiftUI

extension Kit {
    /// The source list a browsing tab steers with: a dim, solid `sunken` column, flush
    /// with the window's leading edge, closed by a 1 pt separator.
    ///
    /// It sizes itself — `sidebarWidth`, or `railWidth` when the tab folds it to glyphs
    /// with `\.kitCompactControls` — so every tab divides the window the same way.
    /// Callers set the environment and never frame its width. The column's last two points
    /// hold the separator, outside the scrolling items, so both the items' scroll area and
    /// the page beside the column measure whole multiples of 4 pt. Its items scroll when a
    /// short window cannot hold them all, so no destination is ever cut off. The column and
    /// its separator run under the safe area; the items stay inside it.
    struct Sidebar<Content: View>: View {
        private let content: Content
        @Environment(\.theme) private var theme
        @Environment(\.kitCompactControls) private var isCompact

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            let width = isCompact ? Kit.Metrics.railWidth : Kit.Metrics.sidebarWidth
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    content
                }
                .padding(VoiceourMetrics.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: width - Self.separatorStrip)
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background {
                theme.sunken
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .trailing) {
                theme.separator
                    .frame(width: Kit.Rule.thickness)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            .environment(\.surfaceGround, SurfaceGround(theme.sunken))
        }

        /// The column's trailing strip outside the scrolling items: the hairline and one
        /// point of the column's fill before it. With the 8 pt padding on both sides an item
        /// is 204 pt wide in the 222 pt sidebar and 36 pt on the 54 pt rail.
        private static var separatorStrip: CGFloat { Kit.Rule.thickness * 2 }
    }

    /// A heading inside the sidebar over the items it groups, such as the Journal's
    /// "Recent threads": quiet, so the destinations lead. On the rail, where a name has
    /// no room, it draws a rule and keeps its name as the rule's tooltip and as what
    /// VoiceOver reads.
    struct SidebarSection: View {
        private let title: String
        @Environment(\.theme) private var theme
        @Environment(\.kitCompactControls) private var isCompact

        init(_ title: String) {
            self.title = title
        }

        var body: some View {
            if isCompact {
                Kit.Rule()
                    .padding(.horizontal, VoiceourMetrics.Space.xs)
                    .padding(.vertical, VoiceourMetrics.Space.sm)
                    .contentShape(Rectangle())
                    .help(title)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text(title)
                    .roleStyle(.label)
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, VoiceourMetrics.Space.sm)
                    .padding(.top, VoiceourMetrics.Space.md)
                    .padding(.bottom, VoiceourMetrics.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// A lens's two columns: the list a reader scans, a 1 pt separator, and the page the
    /// selection opens.
    ///
    /// The list keeps one width and the page takes the rest, so growing the window gives
    /// the reading its room instead of stretching every row. The separator is drawn over
    /// the list's last point, inside `listWidth`, where rows already keep a 4 pt inset,
    /// so the page keeps a width on the grid.
    struct Split<ListContent: View, PageContent: View>: View {
        private let list: ListContent
        private let page: PageContent
        @Environment(\.theme) private var theme

        init(@ViewBuilder list: () -> ListContent, @ViewBuilder page: () -> PageContent) {
            self.list = list()
            self.page = page()
        }

        var body: some View {
            HStack(spacing: 0) {
                list
                    .frame(width: Kit.Metrics.listWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        Kit.Rule(.vertical)
                    }
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.ground)
            .environment(\.surfaceGround, SurfaceGround(theme.ground))
        }
    }

    /// The list column: its title, a one-line account of what it holds, a bar for
    /// search and filters, and the rows under them.
    ///
    /// The header stands above the rows rather than floating over them, and a separator
    /// appears under it once rows scroll beneath, so the edge shows only when there is
    /// something to separate. Rows go in a lazy stack, so a list of 500 dictations builds
    /// only the rows near the viewport, and group headers pin to the top so a reader deep
    /// in a list still sees which day they are in. Rows sit 4 pt in from the column's
    /// edges with 2 pt between them; each row draws its own plate.
    ///
    /// With a `focus` binding the list takes keyboard focus, moves through its rows with
    /// the arrow keys (`onMove`), and publishes that focus as `\.kitListFocused`, so its
    /// selected row shows the active selection and focus bar while the keyboard is here
    /// and the quieter inactive selection when it is not. `reveal` scrolls the row a key
    /// press selected into view.
    struct ListColumn<Bar: View, Content: View>: View {
        private let title: String
        private let subtitle: String?
        private let reveal: AnyHashable?
        private let focus: FocusState<Bool>.Binding?
        private let onMove: ((MoveCommandDirection) -> Void)?
        private let bar: Bar
        private let content: Content
        @Environment(\.theme) private var theme
        @Environment(\.kitToastInset) private var toastInset
        @State private var isScrolled = false

        init(
            _ title: String,
            subtitle: String? = nil,
            reveal: AnyHashable? = nil,
            focus: FocusState<Bool>.Binding? = nil,
            onMove: ((MoveCommandDirection) -> Void)? = nil,
            @ViewBuilder bar: () -> Bar,
            @ViewBuilder content: () -> Content
        ) {
            self.title = title
            self.subtitle = subtitle
            self.reveal = reveal
            self.focus = focus
            self.onMove = onMove
            self.bar = bar()
            self.content = content()
        }

        var body: some View {
            VStack(spacing: 0) {
                header
                    .overlay(alignment: .bottom) {
                        Kit.Rule()
                            .opacity(isScrolled ? 1 : 0)
                    }
                ScrollViewReader { proxy in
                    keyboardList
                        .onChange(of: reveal) { _, target in
                            guard let target else { return }
                            proxy.scrollTo(target)
                        }
                }
            }
            .background(theme.ground)
            .environment(\.surfaceGround, SurfaceGround(theme.ground))
        }

        @ViewBuilder
        private var keyboardList: some View {
            if let focus {
                rows
                    .environment(\.kitListFocused, focus.wrappedValue)
                    .focusable()
                    .focusEffectDisabled()
                    .focused(focus)
                    .onMoveCommand { direction in onMove?(direction) }
            } else {
                rows
            }
        }

        private var rows: some View {
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: VoiceourMetrics.Space.hair,
                    pinnedViews: [.sectionHeaders]
                ) {
                    content
                }
                .padding(.horizontal, Kit.Metrics.rowInset)
                .padding(.top, VoiceourMetrics.Space.hair)
                .padding(.bottom, VoiceourMetrics.Space.md)
            }
            .contentMargins(.bottom, toastInset, for: .scrollContent)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 0.5
            } action: { _, scrolled in
                isScrolled = scrolled
            }
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    Text(title)
                        .roleStyle(.heading)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .roleStyle(.meta)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if Bar.self != EmptyView.self {
                    VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                        bar
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiceourMetrics.Space.lg)
            .padding(.top, VoiceourMetrics.Space.lg)
            .padding(.bottom, VoiceourMetrics.Space.md)
        }
    }

    /// The page column: a solid 48 pt bar of page actions above a centred reading
    /// measure that scrolls beneath it.
    ///
    /// The bar is painted in the page's own `ground`, so nothing behind it changes how it
    /// reads, and it draws a separator only once the content has scrolled under it. When
    /// the actions' titles do not fit the page's width, they draw their glyphs alone
    /// (`kitCompactControls`); when even the glyphs do not fit, the bar scrolls sideways,
    /// so a narrow window keeps every action rather than clipping one. `identity` names
    /// what the page shows, so moving to another item starts its page at the top rather
    /// than at the scroll offset the last one was left at; `reveal` scrolls one element of
    /// the page into view.
    struct PageColumn<Bar: View, Content: View>: View {
        private let identity: AnyHashable?
        private let reveal: AnyHashable?
        private let bar: Bar
        private let content: Content
        @Environment(\.theme) private var theme
        @Environment(\.kitToastInset) private var toastInset
        @State private var isScrolled = false

        init(
            identity: AnyHashable? = nil,
            reveal: AnyHashable? = nil,
            @ViewBuilder bar: () -> Bar,
            @ViewBuilder content: () -> Content
        ) {
            self.identity = identity
            self.reveal = reveal
            self.bar = bar()
            self.content = content()
        }

        var body: some View {
            VStack(spacing: 0) {
                barArea
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Kit.Metrics.sectionGap) {
                            content
                        }
                        .frame(maxWidth: Kit.Metrics.readableWidth, alignment: .leading)
                        .padding(.horizontal, Kit.Metrics.pagePadding)
                        .padding(.top, VoiceourMetrics.Space.sm)
                        .padding(.bottom, Kit.Metrics.pagePadding)
                        .frame(maxWidth: .infinity)
                    }
                    .contentMargins(.bottom, toastInset, for: .scrollContent)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top > 0.5
                    } action: { _, scrolled in
                        isScrolled = scrolled
                    }
                    .id(identity)
                    .onChange(of: identity) {
                        isScrolled = false
                    }
                    .onChange(of: reveal) { _, target in
                        guard let target else { return }
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            .background(theme.ground)
            .environment(\.surfaceGround, SurfaceGround(theme.ground))
        }

        private var barArea: some View {
            ViewThatFits(in: .horizontal) {
                barRow(compact: false)
                barRow(compact: true)
                ScrollView(.horizontal) {
                    barRow(compact: true)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, VoiceourMetrics.Space.lg)
            .frame(height: Self.barHeight)
            .background(theme.ground)
            .overlay(alignment: .bottom) {
                Kit.Rule()
                    .opacity(isScrolled ? 1 : 0)
            }
        }

        private func barRow(compact: Bool) -> some View {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                bar
            }
            .environment(\.kitCompactControls, compact)
        }

        private static var barHeight: CGFloat { 48 }
    }

    /// The head of a page: where it sits (the kicker), what it is (the title, at most two
    /// lines), and how much (the meta line, at most two lines: the page's own content says
    /// the rest), then any pills it carries on the line under them, wrapping when they
    /// outgrow the measure. A page about a code value, such as a glossary term, sets
    /// `monospacedTitle`; its title reads in the code face and truncates in the middle,
    /// where a path or identifier carries the least.
    struct PageHeader<Accessory: View>: View {
        private let kicker: String?
        private let title: String
        private let meta: String?
        private let monospacedTitle: Bool
        private let accessory: Accessory
        @Environment(\.theme) private var theme

        init(
            kicker: String? = nil,
            title: String,
            meta: String? = nil,
            monospacedTitle: Bool = false,
            @ViewBuilder accessory: () -> Accessory
        ) {
            self.kicker = kicker
            self.title = title
            self.meta = meta
            self.monospacedTitle = monospacedTitle
            self.accessory = accessory()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    if let kicker {
                        Text(kicker)
                            .roleStyle(.meta)
                            .foregroundStyle(theme.text3)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(title)
                        .roleStyle(monospacedTitle ? .codeTitle : .title)
                        .lineLimit(2)
                        .truncationMode(monospacedTitle ? .middle : .tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let meta {
                        Text(meta)
                            .roleStyle(.meta)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if Accessory.self != EmptyView.self {
                    WrapLayout(spacing: VoiceourMetrics.Space.sm - VoiceourMetrics.Space.hair) {
                        accessory
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A section's heading inside a page or a card, with an optional trailing control or
    /// figure. The title wraps to a second line rather than squeezing the trailing view.
    struct SectionHeader<Trailing: View>: View {
        private let title: String
        private let trailing: Trailing

        init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
            self.title = title
            self.trailing = trailing()
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                Text(title)
                    .roleStyle(.heading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: VoiceourMetrics.Space.sm)
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, VoiceourMetrics.Space.sm)
        }
    }

    /// A list's group heading — a day, a month, a project folder — pinned under the
    /// column's header while its rows scroll. It paints the list's `ground` across the
    /// column's full width, past the rows' inset, and declares it as its ground, so a
    /// row scrolling under it never shows through its words or beside them. A long name
    /// truncates in the middle, keeping both ends of a folder path; the detail never
    /// truncates.
    struct GroupHeader: View {
        private let title: String
        private let detail: String?
        @Environment(\.theme) private var theme

        init(_ title: String, detail: String? = nil) {
            self.title = title
            self.detail = detail
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                Text(title)
                    .roleStyle(.label)
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: VoiceourMetrics.Space.sm)
                if let detail {
                    Text(detail)
                        .roleStyle(.label)
                        .foregroundStyle(theme.text3)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, VoiceourMetrics.Space.md)
            .padding(.top, VoiceourMetrics.Space.md)
            .padding(.bottom, VoiceourMetrics.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                theme.ground
                    .padding(.horizontal, -Kit.Metrics.rowInset)
                    .accessibilityHidden(true)
            }
            .environment(\.surfaceGround, SurfaceGround(theme.ground))
        }
    }

    /// What a place shows when it holds nothing to show, centred in its column at most
    /// 320 pt wide: a glyph, a title, a sentence, and at most one action.
    ///
    /// Three uses, never one generic placeholder: first use (what fills this place, and
    /// the action that does), no results (the title echoes the query, the action clears
    /// it), and all clear (no action). The one place with two actions — an empty
    /// glossary's Add Term and Import… — passes the second as a secondary action, drawn
    /// beside the primary one. Long or unbroken text wraps; nothing truncates.
    struct EmptyState: View {
        private let systemImage: String
        private let title: String
        private let message: String
        private let actionTitle: String?
        private let actionIdentifier: String?
        private let action: (() -> Void)?
        private let secondaryActionTitle: String?
        private let secondaryActionIdentifier: String?
        private let secondaryAction: (() -> Void)?
        @Environment(\.theme) private var theme

        init(
            systemImage: String,
            title: String,
            message: String,
            actionTitle: String? = nil,
            actionIdentifier: String? = nil,
            action: (() -> Void)? = nil,
            secondaryActionTitle: String? = nil,
            secondaryActionIdentifier: String? = nil,
            secondaryAction: (() -> Void)? = nil
        ) {
            self.systemImage = systemImage
            self.title = title
            self.message = message
            self.actionTitle = actionTitle
            self.actionIdentifier = actionIdentifier
            self.action = action
            self.secondaryActionTitle = secondaryActionTitle
            self.secondaryActionIdentifier = secondaryActionIdentifier
            self.secondaryAction = secondaryAction
        }

        var body: some View {
            VStack(spacing: VoiceourMetrics.Space.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(theme.text3)
                    .accessibilityHidden(true)
                VStack(spacing: VoiceourMetrics.Space.xs) {
                    Text(title)
                        .roleStyle(.heading)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .roleStyle(.body)
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hasActions {
                    HStack(spacing: VoiceourMetrics.Space.sm) {
                        if let actionTitle, let action {
                            identified(
                                Kit.Button(actionTitle, prominence: .primary, action: action),
                                actionIdentifier
                            )
                        }
                        if let secondaryActionTitle, let secondaryAction {
                            identified(
                                Kit.Button(secondaryActionTitle, prominence: .secondary, action: secondaryAction),
                                secondaryActionIdentifier
                            )
                        }
                    }
                    .padding(.top, VoiceourMetrics.Space.xs)
                }
            }
            .frame(maxWidth: Self.maxWidth)
            .padding(Kit.Metrics.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private var hasActions: Bool {
            (actionTitle != nil && action != nil) || (secondaryActionTitle != nil && secondaryAction != nil)
        }

        @ViewBuilder
        private func identified(_ button: some View, _ identifier: String?) -> some View {
            if let identifier {
                button.accessibilityIdentifier(identifier)
            } else {
                button
            }
        }

        private static var maxWidth: CGFloat { 320 }
    }
}

extension Kit.PageHeader where Accessory == EmptyView {
    init(kicker: String? = nil, title: String, meta: String? = nil, monospacedTitle: Bool = false) {
        self.init(kicker: kicker, title: title, meta: meta, monospacedTitle: monospacedTitle) {
            EmptyView()
        }
    }
}

extension Kit.SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// Lays its children out in rows, left to right, starting a new row when the next child
/// would overflow the width it is offered — so a page's pills wrap under one another
/// instead of pushing past the reading measure. A child wider than a whole row is
/// offered the row's width.
private struct WrapLayout: Layout {
    let spacing: CGFloat

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [Row] {
        let limit = width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > limit {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: limit, height: nil))
            }
            if !current.items.isEmpty, current.width + spacing + size.width > limit {
                rows.append(current)
                current = Row()
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append((index: index, size: size))
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

import SwiftUI

extension Kit {
    /// A lens's two columns: the list a reader scans, and the page the selection opens.
    ///
    /// The list keeps one width and the page takes the rest, so growing the window
    /// gives the reading its room instead of stretching every row.
    struct Split<ListContent: View, PageContent: View>: View {
        private let list: ListContent
        private let page: PageContent

        init(@ViewBuilder list: () -> ListContent, @ViewBuilder page: () -> PageContent) {
            self.list = list()
            self.page = page()
        }

        var body: some View {
            HStack(spacing: 0) {
                // The rule overlays the list's edge rather than taking a column of its
                // own, so the page keeps a whole-point width on the 4 pt grid.
                list
                    .frame(width: Kit.Metrics.listWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        Kit.Rule(.vertical)
                    }
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The list column: its title in the display face, its count, a glass bar for
    /// search and filters, and the rows under them.
    ///
    /// The title is set like Home's hero at a reading size — 28 pt light monospaced —
    /// so every list opens in the voice of the reference page.
    ///
    /// The header stands above the rows rather than floating over them: its title is
    /// plain text, which only a scroll edge effect keeps legible over moving rows, and
    /// an offscreen capture paints that effect as an opaque white sheet. Rows go in a
    /// lazy stack, so a list of 500 dictations builds only the rows near the viewport,
    /// and group headers pin to the top so a reader deep in a list still sees which day
    /// they are in. A reader steering with the keyboard moves through the rows with the
    /// arrow keys once the list holds focus, and `reveal` scrolls the row a key press
    /// selected into view.
    struct ListColumn<Bar: View, Content: View>: View {
        private let title: String
        private let subtitle: String?
        private let reveal: AnyHashable?
        private let focus: FocusState<Bool>.Binding?
        private let onMove: ((MoveCommandDirection) -> Void)?
        private let bar: Bar
        private let content: Content
        private var a11y = A11y()

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
                ScrollViewReader { proxy in
                    keyboardList
                        .onChange(of: reveal) { _, target in
                            guard let target else { return }
                            proxy.scrollTo(target)
                        }
                }
            }
        }

        @ViewBuilder
        private var keyboardList: some View {
            if let focus {
                rows
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
                LazyVStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair, pinnedViews: [.sectionHeaders]) {
                    content
                }
                .padding(.horizontal, VoiceourMetrics.Space.sm)
                .padding(.bottom, VoiceourMetrics.Space.md)
            }
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    Text(title)
                        .roleStyle(.display)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .roleStyle(.caption)
                            .foregroundStyle(a11y.textMid)
                    }
                }
                .padding(.horizontal, VoiceourMetrics.Space.sm)

                bar
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiceourMetrics.Space.md)
            .padding(.top, VoiceourMetrics.Space.md)
            .padding(.bottom, VoiceourMetrics.Space.sm)
        }
    }

    /// The page column: a glass bar of actions above a centred reading measure that
    /// scrolls under it.
    ///
    /// The page scrolls under its glass buttons, so they refract the words passing
    /// beneath them. The bar holds glass and nothing else, which keeps it legible with
    /// the scroll edge effect hidden — the effect an offscreen capture paints as an
    /// opaque white sheet over the whole page. When the bar's titles do not fit the
    /// page's width, its controls draw their glyphs alone (`kitCompactControls`), so a
    /// narrow window keeps every action rather than truncating them. `identity` names
    /// what the page shows, so moving to another item starts its page at the top rather
    /// than at the scroll offset the last one was left at; `reveal` scrolls one element
    /// of the page into view.
    struct PageColumn<Bar: View, Content: View>: View {
        private let identity: AnyHashable?
        private let reveal: AnyHashable?
        private let bar: Bar
        private let content: Content

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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xl) {
                        content
                    }
                    .frame(maxWidth: Kit.Metrics.readableWidth, alignment: .leading)
                    .padding(.horizontal, Kit.Metrics.pagePadding)
                    .padding(.top, VoiceourMetrics.Space.sm)
                    .padding(.bottom, VoiceourMetrics.Space.xl + VoiceourMetrics.Space.lg)
                    .frame(maxWidth: .infinity)
                }
                .id(identity)
                .onChange(of: reveal) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .scrollEdgeEffectHidden(true, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    barRow(compact: false)
                    barRow(compact: true)
                }
                .frame(maxWidth: .infinity, minHeight: Kit.Metrics.control, alignment: .trailing)
                .padding(.horizontal, VoiceourMetrics.Space.lg)
                .padding(.vertical, VoiceourMetrics.Space.md)
            }
        }

        private func barRow(compact: Bool) -> some View {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                bar
            }
            .environment(\.kitCompactControls, compact)
        }
    }

    /// The head of a page: what it is about, in the order a reader asks — when or
    /// where (the eyebrow), what (the title), and how much (the subtitle) — then any
    /// marks the page carries. A page about a code value, such as a glossary term,
    /// sets `monospacedTitle` and its title reads in the code face.
    struct PageHeader<Accessory: View>: View {
        private let eyebrow: String?
        private let title: String
        private let subtitle: String?
        private let monospacedTitle: Bool
        private let accessory: Accessory
        private var a11y = A11y()

        init(
            eyebrow: String? = nil,
            title: String,
            subtitle: String? = nil,
            monospacedTitle: Bool = false,
            @ViewBuilder accessory: () -> Accessory
        ) {
            self.eyebrow = eyebrow
            self.title = title
            self.subtitle = subtitle
            self.monospacedTitle = monospacedTitle
            self.accessory = accessory()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    if let eyebrow {
                        Text(eyebrow)
                            .roleStyle(.caption)
                            .foregroundStyle(a11y.textMid)
                    }
                    Text(title)
                        .roleStyle(monospacedTitle ? .codeTitle : .title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .roleStyle(.caption)
                            .foregroundStyle(a11y.textMid)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                accessory
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A list's group heading — a day, a month, a project folder — pinned under the
    /// column's bar while its rows scroll. It paints the screen's `Ink.void` and
    /// declares it as its ground, so a row scrolling under it never shows through its
    /// words.
    struct GroupHeader: View {
        private let title: String
        private let detail: String?
        private var a11y = A11y()

        init(_ title: String, detail: String? = nil) {
            self.title = title
            self.detail = detail
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                Text(title)
                    .roleStyle(.subheading)
                    .foregroundStyle(a11y.textMid)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .roleStyle(.caption)
                        .foregroundStyle(a11y.textMid)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, VoiceourMetrics.Space.sm + VoiceourMetrics.Space.xs)
            .padding(.top, VoiceourMetrics.Space.md)
            .padding(.bottom, VoiceourMetrics.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Kit.Colors.ground)
            .environment(\.surfaceGround, SurfaceGround(Kit.Colors.ground))
        }
    }

    /// An island's heading, as Home's "Top apps" is: 13 pt medium in the quieter text
    /// step, at the island's top, with an optional trailing control or figure. Quiet
    /// because the island's content is the subject; the heading only names it.
    struct SectionTitle<Trailing: View>: View {
        private let title: String
        private let trailing: Trailing
        private var a11y = A11y()

        init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
            self.title = title
            self.trailing = trailing()
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                Text(title)
                    .roleStyle(.label)
                    .foregroundStyle(a11y.textMid)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Kit.PageHeader where Accessory == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String? = nil, monospacedTitle: Bool = false) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle, monospacedTitle: monospacedTitle) {
            EmptyView()
        }
    }
}

extension Kit.SectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

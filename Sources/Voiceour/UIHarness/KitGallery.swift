#if UI_HARNESS

    import SwiftUI
    import VoiceCore

    /// Every kit component in the states a reader meets, laid out the way the console composes
    /// them, in the theme the scene's colour scheme and `accent` resolve: the solid sidebar
    /// with its sections, a quiet count, a five-digit count and both attentions; a list column
    /// with its search bar, a filter chip, pinned group headers, a draft row, preview rows (one
    /// selected; CJK, emoji, right-to-left and unbroken text; a crowded meta line), title rows
    /// and line rows; and a page with its action bar, header, cards, a group of preference
    /// rows, pills in every tone and size, icon tiles, app icons, figures, meters, properties,
    /// keycaps, every button, folds, an empty state, both theme pickers and the toast.
    ///
    /// Fixed sample text and no clock, so the scene is byte-stable. The theme pickers are
    /// bound to local state and do not re-theme the scene: the scene's colour scheme and
    /// `accent` decide, so every appearance and accent golden shows the same composition.
    struct KitGallery: View {
        private let accent: ConsoleAccent

        init(accent: ConsoleAccent = .green) {
            self.accent = accent
        }

        var body: some View {
            KitGalleryComposition(accent: accent)
                .themeRoot(appearance: .system, accent: accent)
        }
    }

    private struct KitGalleryComposition: View {
        @State private var query = "offscreen"
        @State private var foldOpen = true
        @State private var foldShut = false
        @State private var pastes = true
        @State private var keepsAudio = false
        @State private var language = "en"
        @State private var trigger = "fn"
        @State private var appearance: ConsoleAppearance = .system
        @State private var accentChoice: ConsoleAccent

        init(accent: ConsoleAccent) {
            _accentChoice = State(initialValue: accent)
        }

        var body: some View {
            Kit.Screen {
                HStack(spacing: 0) {
                    sidebar

                    Kit.Split {
                        list
                    } page: {
                        page
                            .overlay(alignment: .bottom) {
                                Kit.Toast("Transcript copied to clipboard")
                                    .padding(.bottom, VoiceourMetrics.Space.lg)
                            }
                    }
                }
                // The console's tab view insets its content 3 pt from each side; the gallery
                // keeps the same measure, so its columns are the Journal's to the point.
                .padding(.horizontal, Self.tabInset)
            }
        }

        private static let tabInset: CGFloat = 3

        // MARK: Sidebar

        private var sidebar: some View {
            Kit.Sidebar {
                Kit.SidebarItem("Timeline", systemImage: "clock", count: 64, isSelected: true) {}
                Kit.SidebarItem("Rewind", systemImage: "calendar", isSelected: false) {}
                Kit.SidebarItem(
                    "Threads", systemImage: "bubble.left.and.text.bubble.right", count: 12_345, isSelected: false
                ) {}
                Kit.SidebarItem("Topics", systemImage: "tag", count: 3, isSelected: false) {}
                Kit.SidebarItem("Notes", systemImage: "note.text", count: 3, isSelected: false) {}

                Kit.SidebarSection("Recent threads")
                Kit.SidebarItem(
                    "Harness offscreen capture and the contact sheet beside the manifest",
                    systemImage: "terminal",
                    isSelected: false
                ) {}
                Kit.SidebarItem(
                    "Glossary import", systemImage: "terminal", count: 2, isSelected: false, attention: .caution
                ) {}

                Kit.SidebarSection("Needs attention")
                Kit.SidebarItem("Readiness", systemImage: "checkmark.seal", isSelected: false, attention: .caution) {}
                Kit.SidebarItem("Capture", systemImage: "scope", isSelected: false, attention: .critical) {}
            }
        }

        // MARK: List

        private var list: some View {
            Kit.ListColumn("Timeline", subtitle: "1,234 of 1,234 dictations match") {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                    HStack(spacing: VoiceourMetrics.Space.xs) {
                        Kit.SearchField(
                            "Search dictations",
                            text: $query,
                            identifier: "kit.search",
                            clearIdentifier: "kit.search.clear"
                        )
                        Kit.MenuButton(
                            "Filter by app",
                            systemImage: "line.3.horizontal.decrease",
                            showsTitle: false,
                            identifier: "kit.filter"
                        ) {
                            Button("All Apps") {}
                        }
                    }
                    Kit.FilterChip(
                        "Xcode",
                        systemImage: "app",
                        clearLabel: "Show all apps",
                        clearIdentifier: "kit.chip.clear"
                    ) {}
                }
            } content: {
                Section {
                    Kit.DraftRow("New topic", isSelected: false) {}
                    preview(
                        "14:54:40", app: "Xcode", text: Self.transcript, selected: true
                    ) {
                        Kit.Pill("Pasted", tone: .success)
                    }
                    preview(
                        "13:31:40",
                        app: "Visual Studio Code \u{2014} Insiders (Universal)",
                        text: "Ship the contact sheet next to the manifest so a reviewer sees every pane at once.",
                        selected: false
                    ) {
                        Kit.Pill("Copy only", tone: .caution)
                        Kit.Pill("Not sent", tone: .caution)
                    }
                    preview("12:08:15", app: "WeChat", text: Self.cjk, selected: false) {
                        Kit.Pill("Note")
                    }
                    preview("11:47:02", app: "Messages", text: Self.scripts, selected: false) {
                        Kit.Pill("Idea")
                    }
                    preview("10:46:40", app: "Safari", text: Self.unbroken, selected: false) {
                        Kit.Pill("Delivery failed", tone: .critical)
                    }
                } header: {
                    Kit.GroupHeader("Sunday \u{00B7} Jun 15 \u{00B7} 2025", detail: "1234")
                }

                Section {
                    Kit.TitleRow(
                        "Harness offscreen capture",
                        subtitle: "omp \u{00B7} 2 dictations \u{00B7} Jun 7 \u{2013} Jun 13",
                        isSelected: false,
                        action: {}
                    ) {
                        Kit.IconTile(systemImage: "terminal.fill", size: .small)
                    } trailing: {
                        Kit.Pill("1 not sent", tone: .caution)
                    }
                    Kit.TitleRow(
                        Self.unbrokenTerm,
                        subtitle: "Heard as a \u{00B7} b \u{00B7} c",
                        isSelected: false,
                        monospacedTitle: true,
                        action: {}
                    ) {
                        Kit.IconTile(systemImage: "character.book.closed.fill", size: .small)
                    } trailing: {
                        Kit.Pill("Built-in")
                    }
                } header: {
                    Kit.GroupHeader("voiceour")
                }

                Section {
                    Kit.LineRow("Xcode", isSelected: false) {
                    } leading: {
                        Kit.AppIcon(name: "Xcode", icon: nil, size: Kit.Metrics.iconTileMini)
                    } trailing: {
                        Text("27").monospacedDigit().roleStyle(.label)
                    }
                    Kit.LineRow("Slack", isSelected: false) {
                    } leading: {
                        Kit.AppIcon(name: "Slack", icon: nil, size: Kit.Metrics.iconTileMini)
                    } trailing: {
                        Text("12345").monospacedDigit().roleStyle(.label)
                    }
                } header: {
                    Kit.GroupHeader("Apps", detail: "2")
                }
            }
        }

        private func preview<Pills: View>(
            _ stamp: String,
            app: String,
            text: String,
            selected: Bool,
            @ViewBuilder pills: () -> Pills
        ) -> some View {
            Kit.PreviewRow(text, isSelected: selected) {
            } meta: {
                Text(stamp).monospacedDigit()
                Kit.AppLabel(app, icon: nil)
            } marks: {
                pills()
            }
        }

        // MARK: Page

        private var page: some View {
            Kit.PageColumn(identity: "kit.gallery") {
                Kit.Button("Copy", systemImage: "doc.on.doc", prominence: .primary) {}
                Kit.Button("Fix / Teach", systemImage: "character.cursor.ibeam") {}
                Kit.MenuButton("More", systemImage: "ellipsis", showsTitle: false, identifier: "kit.more") {
                    Button("Delete Transcript\u{2026}", role: .destructive) {}
                }
            } content: {
                Kit.PageHeader(
                    kicker: "Sunday \u{00B7} Jun 15 \u{00B7} 2025 at 14:54:40",
                    title: "Pasted into Xcode after the agent asked for the offscreen capture",
                    meta: "10 words"
                ) {
                    Kit.Pill("Pasted", tone: .success)
                    Kit.Pill("Note")
                }

                Kit.Card {
                    Text(Self.transcript)
                        .roleStyle(.reading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Kit.Hero("voiceouurs, rejoice!")

                settings
                pills
                tiles
                figures
                properties
                controls
                folds

                Kit.Card {
                    Kit.EmptyState(
                        systemImage: "magnifyingglass",
                        title: "No dictations match \u{201C}offscreen\u{201D}",
                        message: "Try a shorter word, or clear the search to see every dictation.",
                        actionTitle: "Clear Search",
                        actionIdentifier: "kit.empty.clear"
                    ) {}
                    .frame(maxWidth: .infinity)
                }

                Kit.Group(
                    "Appearance",
                    footer:
                        "System follows macOS. Increase Contrast in System Settings \u{203A} Accessibility raises contrast in every appearance."
                ) {
                    Kit.AppearancePicker(selection: $appearance)
                        .padding(Kit.Metrics.cardPadding)
                }
                Kit.Group("Accent colour") {
                    Kit.AccentPicker(selection: $accentChoice)
                        .padding(Kit.Metrics.cardPadding)
                }
            }
        }

        /// A group of preference rows: a switch, a picker, a long caption and a control too
        /// wide to sit beside its title, which drops under the caption.
        private var settings: some View {
            VStack(alignment: .leading, spacing: 0) {
                Kit.SectionHeader("Dictation")
                Kit.Group("Delivery", footer: "Secure fields always get a copy only, whatever these say.") {
                    Kit.SettingRow(
                        "Paste automatically",
                        caption: "Pastes into the focused app; secure fields get a copy only."
                    ) {
                        Toggle("Paste automatically", isOn: $pastes)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Kit.Rule(inset: 12)
                    Kit.SettingRow("Language") {
                        Picker("Language", selection: $language) {
                            Text("English").tag("en")
                            Text("Deutsch").tag("de")
                            Text("\u{65E5}\u{672C}\u{8A9E}").tag("ja")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Kit.Rule(inset: 12)
                    Kit.SettingRow("Keep recordings", caption: Self.longCaption) {
                        Toggle("Keep recordings", isOn: $keepsAudio)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Kit.Rule(inset: 12)
                    // A row radio group, as Settings ▸ Island's Coat and Room use: wider than
                    // half the row, so it drops under the caption.
                    Kit.SettingRow("Dictation key", caption: "Hold it to talk; release to paste.") {
                        Picker("Dictation key", selection: $trigger) {
                            Text("Fn key").tag("fn")
                            Text("Right Command").tag("rcmd")
                            Text("Right Option").tag("ropt")
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                    }
                }
            }
        }

        /// Pills in every tone at both sizes, with their own glyphs and with caller glyphs, and
        /// a word too long for its line.
        private var pills: some View {
            Kit.Card {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                    Kit.SectionHeader("Pills")
                    GalleryFlow {
                        pillSet(size: .small, glyphs: false)
                    }
                    GalleryFlow {
                        pillSet(size: .regular, glyphs: false)
                    }
                    GalleryFlow {
                        pillSet(size: .small, glyphs: true)
                    }
                    GalleryFlow {
                        pillSet(size: .regular, glyphs: true)
                    }
                    HStack(spacing: VoiceourMetrics.Space.sm) {
                        Text("Delivery")
                            .roleStyle(.meta)
                        Kit.Pill(Kit.Pill.sentence(Self.longPill), tone: .critical)
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                }
            }
        }

        @ViewBuilder
        private func pillSet(size: Kit.Pill.Size, glyphs: Bool) -> some View {
            Kit.Pill("Idea", size: size, systemImage: glyphs ? "lightbulb.fill" : nil)
            Kit.Pill("New", tone: .accent, size: size, systemImage: glyphs ? "sparkles" : nil)
            Kit.Pill("Pasted", tone: .success, size: size, systemImage: glyphs ? "checkmark" : nil)
            Kit.Pill("Copy only", tone: .caution, size: size, systemImage: glyphs ? "doc.on.clipboard" : nil)
            Kit.Pill("Failed", tone: .critical, size: size, systemImage: glyphs ? "xmark.octagon.fill" : nil)
            Kit.Pill("Live", tone: .info, size: size, systemImage: glyphs ? "waveform" : nil)
        }

        /// Icon tiles at three sizes, then app icons' monograms for a plain, an emoji, a CJK, a
        /// right-to-left and a blank name.
        private var tiles: some View {
            Kit.Card {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                    Kit.SectionHeader("Tiles and icons")
                    HStack(spacing: VoiceourMetrics.Space.md) {
                        Kit.IconTile(systemImage: "mic.fill")
                        Kit.IconTile(systemImage: "terminal.fill", size: .small)
                        Kit.IconTile(systemImage: "note.text", size: .mini)
                    }
                    HStack(spacing: VoiceourMetrics.Space.md) {
                        Kit.AppIcon(name: "Xcode", icon: nil, size: Kit.Metrics.iconTileRegular)
                        Kit.AppIcon(name: "Xcode", icon: nil)
                        Kit.AppIcon(name: "\u{1F3A7} Podcasts", icon: nil)
                        Kit.AppIcon(name: "\u{5FAE}\u{4FE1}", icon: nil)
                        Kit.AppIcon(name: "\u{05D8}\u{05DC}\u{05D2}\u{05E8}\u{05DD}", icon: nil)
                        Kit.AppIcon(name: "", icon: nil)
                    }
                }
            }
        }

        /// Home's figure parts: four stat tiles (one a seven-digit count, one a long duration),
        /// three figures, a meter row and both meters.
        private var figures: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                Grid(horizontalSpacing: VoiceourMetrics.Space.md, verticalSpacing: VoiceourMetrics.Space.md) {
                    GridRow {
                        Kit.Card {
                            Kit.StatTile(
                                label: "Total dictation time", value: "12345 hr 59 min", systemImage: "clock.fill")
                        }
                        Kit.Card {
                            Kit.StatTile(
                                label: "Words dictated", value: "1234567", unit: "words", systemImage: "mic.fill")
                        }
                    }
                    GridRow {
                        Kit.Card {
                            Kit.StatTile(label: "Time saved", value: "4 hr 32 min", systemImage: "hourglass")
                        }
                        Kit.Card {
                            Kit.StatTile(label: "Average pace", value: "142", unit: "wpm")
                        }
                    }
                }

                HStack(spacing: VoiceourMetrics.Space.md) {
                    Kit.MetricTile("Entries", value: "3", detail: "37 words")
                    Kit.MetricTile("Speaking time", value: "22 s")
                    Kit.MetricTile(
                        "Where", value: "Xcode", detail: "Slack \u{00B7} Notes \u{00B7} Safari \u{00B7} Mail")
                }

                Kit.Card {
                    VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
                        Kit.SectionHeader("Top apps")
                        Kit.MeterRow(
                            title: "Xcode",
                            fraction: 0.42,
                            value: "27",
                            caption: "dictations \u{00B7} 9.4K words",
                            accessibilityValue: "27 dictations, 9412 words"
                        ) {
                            Kit.AppIcon(name: "Xcode", icon: nil, size: 32)
                        }
                        HStack(alignment: .top, spacing: VoiceourMetrics.Space.lg) {
                            Kit.Figure(value: "23", label: "Active days")
                            Kit.Figure(value: "6 days", label: "Current streak")
                            Kit.Figure(value: "400 days", label: "Longest streak")
                        }
                        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                            Text("Share").roleStyle(.meta)
                            Kit.Meter(fraction: 0.64)
                            Text("Model download \u{00B7} 38%").roleStyle(.meta)
                            Kit.Meter(fraction: 0.38, style: .download)
                        }
                    }
                }
            }
        }

        /// Properties and facts in one table, a middle-truncated path, and keycaps.
        private var properties: some View {
            Kit.Card {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                    Kit.SectionHeader("From the session") {
                        Kit.IconTile(systemImage: "terminal.fill", size: .mini)
                    }
                    Kit.Property("Agent") {
                        Text("omp \u{00B7} Harness offscreen capture")
                    }
                    Kit.Property("Folder") {
                        Text(Self.path)
                            .roleStyle(.code)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Kit.Fact("Timings") {
                        Text("ASR 412 ms \u{00B7} insert 38 ms")
                    }
                    Kit.Property("Shortcut") {
                        HStack(spacing: VoiceourMetrics.Space.xs) {
                            Kit.KeyCap("fn")
                            Kit.KeyCap("\u{2318}")
                            Kit.KeyCap("\u{2325} Space")
                            Kit.KeyCap("Esc")
                        }
                    }
                }
            }
        }

        /// Every button prominence, one disabled, and the icon buttons.
        private var controls: some View {
            Kit.Card {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                    Kit.SectionHeader("Buttons")
                    GalleryFlow {
                        Kit.Button("Add Topic", systemImage: "plus", prominence: .primary) {}
                        Kit.Button("Cancel") {}
                        Kit.Button("Open Thread", prominence: .plain) {}
                        Kit.Button("Delete Term\u{2026}", systemImage: "trash", prominence: .destructive) {}
                        Kit.Button("Copy Agent Instructions", systemImage: "doc.on.doc") {}
                            .disabled(true)
                    }
                    HStack(spacing: VoiceourMetrics.Space.xs) {
                        Kit.IconButton(systemImage: "doc.on.doc", label: "Copy transcript") {}
                        Kit.IconButton(systemImage: "pin", label: "Pin thread") {}
                        Kit.IconButton(systemImage: "trash", label: "Remove alias") {}
                    }
                }
            }
        }

        /// An open and a shut fold.
        private var folds: some View {
            Kit.Card {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                    Kit.Disclosure("Raw", isExpanded: $foldOpen, identifier: "kit.fold.open") {
                        Text("wire the off screen renderer to ns hosting view and capture with cache display")
                            .roleStyle(.code)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Kit.Rule()
                    Kit.Disclosure("Details", isExpanded: $foldShut, identifier: "kit.fold.shut") {
                        Text("Unreachable while shut.")
                            .roleStyle(.body)
                    }
                }
            }
        }

        private static let transcript = "Wire the offscreen renderer to NSHostingView and capture with cacheDisplay."
        private static let cjk =
            "\u{628A}\u{79BB}\u{5C4F}\u{6E32}\u{67D3}\u{63A5}\u{5230}\u{0020}NSHostingView\u{FF0C}\u{7136}\u{540E}\u{7528}\u{0020}cacheDisplay\u{0020}\u{622A}\u{56FE}\u{FF1B}\u{6BCF}\u{4E2A}\u{9762}\u{677F}\u{90FD}\u{8981}\u{5728}\u{8054}\u{7CFB}\u{8868}\u{4E0A}\u{4E00}\u{773C}\u{770B}\u{5230}\u{3002}"
        private static let scripts =
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1E9}\u{1F1EA} \u{1F44B}\u{1F3FD} caf\u{0065}\u{0301} \u{2014} \u{0645}\u{0631}\u{062D}\u{0628}\u{0627} 42 \u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD}"
        private static let unbroken =
            "https://github.com/voiceour/voiceour/blob/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08/Sources/Voiceour/UIHarness/KitGallery.swift"
        private static let unbrokenTerm = "VoiceourOffscreenHarnessContactSheetManifestReviewerPaneRendererCacheDisplay"
        private static let path = "/Users/vlad/Desktop/voiceoour/Sources/Voiceour/UIHarness/Fixtures/Scenes/KitGallery"
        private static let longCaption =
            "Keeps each recording beside its transcript so you can replay what was heard. Recordings never leave this Mac, and clearing History removes them with their transcripts."
        private static let longPill = "DELIVERY FAILED BECAUSE THE TARGET APP REFUSED THE SYNTHESIZED PASTE"
    }

    /// Lays its children left to right and wraps them onto the next line when the page is too
    /// narrow, so a row of pills or buttons never runs off a narrow page.
    private struct GalleryFlow: Layout {
        private let spacing: CGFloat = VoiceourMetrics.Space.sm

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let rows = arrange(subviews, width: proposal.width ?? .infinity)
            let width = rows.map(\.width).max() ?? 0
            let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
            return CGSize(width: width, height: height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var y = bounds.minY
            for row in arrange(subviews, width: bounds.width) {
                var x = bounds.minX
                for index in row.indices {
                    let size = subviews[index].sizeThatFits(.unspecified)
                    subviews[index].place(
                        at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                        proposal: ProposedViewSize(size)
                    )
                    x += size.width + spacing
                }
                y += row.height + spacing
            }
        }

        private struct Row {
            var indices: [Int] = []
            var width: CGFloat = 0
            var height: CGFloat = 0
        }

        private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
            var rows: [Row] = []
            var current = Row()
            for index in subviews.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
                if added > width, !current.indices.isEmpty {
                    rows.append(current)
                    current = Row()
                }
                current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
                current.height = max(current.height, size.height)
                current.indices.append(index)
            }
            if !current.indices.isEmpty { rows.append(current) }
            return rows
        }
    }

#endif

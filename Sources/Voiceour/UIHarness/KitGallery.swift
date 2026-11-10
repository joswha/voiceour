#if UI_HARNESS

    import SwiftUI

    /// Every kit component in the states a reader meets, laid out the way the Journal
    /// composes them: the glass sidebar, a list column with its search bar and a filter
    /// chip, and a page with its action bar, header, marks, figures, facts, folds and the
    /// copy confirmation.
    ///
    /// Fixed sample text and no clock, so the scene is byte-stable. The offscreen capture
    /// drops the glass itself (docs/ui-harness.md › Invariants); what this scene locks is
    /// each component's layout, its accessibility and its Reduce Transparency fallback.
    struct KitGallery: View {
        @State private var query = "offscreen"
        @State private var foldOpen = true
        @State private var foldShut = false

        var body: some View {
            HStack(spacing: Kit.Metrics.gutter) {
                Kit.GlassPanel {
                    sidebar
                }
                .frame(width: Kit.Metrics.sidebarWidth)

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
            .padding([.leading, .vertical], Kit.Metrics.gutter)
            .background(Kit.Colors.ground)
            // The console's tab view insets its content 3 pt from each side; the gallery
            // keeps the same measure, so its columns are the Journal's to the point.
            .padding(.horizontal, Self.tabInset)
            .background(Kit.Colors.ground)
        }

        private static let tabInset: CGFloat = 3

        // MARK: Sidebar

        private var sidebar: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                Kit.SidebarItem("Timeline", systemImage: "clock", count: 64, isSelected: true) {}
                Kit.SidebarItem("Rewind", systemImage: "calendar", isSelected: false) {}
                Kit.SidebarItem(
                    "Threads", systemImage: "bubble.left.and.text.bubble.right", count: 4, isSelected: false
                ) {}
                Kit.SidebarItem("Topics", systemImage: "tag", count: 3, isSelected: false) {}
                Kit.SidebarItem("Notes", systemImage: "note.text", count: 3, isSelected: false) {}
            }
            .padding(VoiceourMetrics.Space.sm)
        }

        // MARK: List

        private var list: some View {
            Kit.ListColumn("Timeline", subtitle: "64 dictations") {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                    HStack(spacing: VoiceourMetrics.Space.sm) {
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
                    Kit.GlassGroup {
                        Kit.FilterChip(
                            "Xcode",
                            systemImage: "app",
                            clearLabel: "Show all apps",
                            clearIdentifier: "kit.chip.clear"
                        ) {}
                    }
                }
            } content: {
                Section {
                    row(
                        "14:54:40", destination: "Xcode", mark: ("PASTED", .success), text: Self.transcript,
                        selected: true)
                    row(
                        "13:31:40",
                        destination: "Xcode",
                        mark: ("PASTED", .success),
                        text: "Accessibility children stay empty until enhanced user interface is switched on.",
                        selected: false
                    )
                    row(
                        "10:46:40",
                        destination: "Slack",
                        mark: ("COPY ONLY", .caution),
                        text: "Ship the contact sheet next to the manifest so a reviewer sees every pane at once.",
                        selected: false
                    )
                } header: {
                    Kit.GroupHeader("Sunday \u{00B7} Jun 15 \u{00B7} 2025", detail: "3")
                }
                Section {
                    Kit.TitleRow(
                        "Harness offscreen capture",
                        subtitle: "omp \u{00B7} 2 dictations \u{00B7} Jun 7 \u{2013} Jun 13",
                        isSelected: false,
                        action: {}
                    ) {
                        Kit.Glyph(systemImage: "terminal.fill", tint: .indigo)
                    } trailing: {
                        Kit.Mark("1 NOT SENT", tone: .caution)
                    }
                } header: {
                    Kit.GroupHeader("voiceour")
                }
            }
        }

        private func row(
            _ stamp: String,
            destination: String,
            mark: (String, Kit.Mark.Tone),
            text: String,
            selected: Bool
        ) -> some View {
            Kit.PreviewRow(text, isSelected: selected) {
            } meta: {
                Text(stamp).font(Kit.Fonts.stamp)
                Kit.AppLabel(destination, icon: nil)
            } marks: {
                Kit.Mark(mark.0, tone: mark.1)
            }
        }

        // MARK: Page

        private var page: some View {
            Kit.PageColumn {
                Kit.GlassGroup {
                    Kit.ActionButton("Copy", systemImage: "doc.on.doc", prominence: .primary) {}
                    Kit.ActionButton("Fix / Teach", systemImage: "character.cursor.ibeam") {}
                    Kit.MenuButton("More", systemImage: "ellipsis", showsTitle: false, identifier: "kit.more") {
                        Button("Delete Transcript\u{2026}", role: .destructive) {}
                    }
                }
            } content: {
                Kit.PageHeader(
                    eyebrow: "Sunday \u{00B7} Jun 15 \u{00B7} 2025 at 14:54:40",
                    title: "Pasted into Xcode",
                    subtitle: "10 words"
                ) {
                    HStack(spacing: VoiceourMetrics.Space.xs) {
                        Kit.Mark("PASTED", tone: .success)
                        Kit.Mark("COPY ONLY", tone: .caution)
                        Kit.Mark("FAILED", tone: .critical)
                        Kit.Mark("NOTE", tone: .info)
                        Kit.Mark("IDEA")
                    }
                }

                Kit.Card {
                    Text(Self.transcript)
                        .font(.system(size: Kit.Fonts.readingLarge))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: VoiceourMetrics.Space.md) {
                    Kit.MetricTile("Entries", value: "3", detail: "37 words")
                    Kit.MetricTile("Speaking time", value: "22 s")
                    Kit.MetricTile("Where", value: "2", detail: "apps")
                }

                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                    Kit.SectionTitle("From the session") {
                        Kit.Glyph(systemImage: "terminal.fill", tint: .indigo, size: 18)
                    }
                    Kit.Card {
                        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                            Kit.Fact("Agent") { Text("omp \u{00B7} Harness offscreen capture") }
                            Kit.Fact("Timings") { Text("ASR 412 ms \u{00B7} insert 38 ms") }
                        }
                    }
                }

                Kit.Disclosure("Raw", isExpanded: $foldOpen, identifier: "kit.fold.open") {
                    Text("wire the off screen renderer to ns hosting view and capture with cache display")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Kit.Disclosure("Details", isExpanded: $foldShut, identifier: "kit.fold.shut") {
                    Text("Unreachable while shut.")
                }
            }
        }

        private static let transcript = "Wire the offscreen renderer to NSHostingView and capture with cacheDisplay."
    }

#endif

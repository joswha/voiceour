import SwiftUI

extension Kit {
    /// The narrowest a row's meta text gets before the marks beside it give way: room
    /// for "12:04 · Xcode". Below it the marks shrink rather than the facts vanishing.
    fileprivate static let metaFloor: CGFloat = 96

    /// A list row that previews words: a meta line — when, where, its marks — over two
    /// lines of the text itself.
    ///
    /// Every row is 64 pt for Latin text, so a list scans as an even column and a short
    /// dictation is still a full target; a CJK or emoji line box, taller than SF's, grows
    /// the row by the points it needs instead of clipping the second line. The words are
    /// primary: in a list of what was said, the text is the subject and the meta line its
    /// caption. On the meta line the facts truncate first, down to a readable floor; the
    /// marks keep their words. The row is one accessibility element; its caller names
    /// it, because only the caller knows which facts the meta line holds.
    struct PreviewRow<Meta: View, Marks: View>: View {
        private let text: String
        private let isSelected: Bool
        private let action: () -> Void
        private let meta: Meta
        private let marks: Marks
        @Environment(\.theme) private var theme

        init(
            _ text: String,
            isSelected: Bool,
            action: @escaping () -> Void,
            @ViewBuilder meta: () -> Meta,
            @ViewBuilder marks: () -> Marks
        ) {
            self.text = text
            self.isSelected = isSelected
            self.action = action
            self.meta = meta()
            self.marks = marks()
        }

        var body: some View {
            SwiftUI.Button(action: action) {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    HStack(spacing: VoiceourMetrics.Space.sm) {
                        HStack(spacing: VoiceourMetrics.Space.xs) {
                            meta
                        }
                        .roleStyle(.meta, color: theme.text3)
                        .lineLimit(1)
                        .frame(minWidth: Kit.metaFloor, maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: VoiceourMetrics.Space.xs) {
                            marks
                        }
                        .layoutPriority(1)
                    }
                    Text(text)
                        .roleStyle(.body)
                        .foregroundStyle(theme.text1)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, VoiceourMetrics.Space.md)
                .padding(.vertical, VoiceourMetrics.Space.xs)
                .frame(minHeight: Kit.Metrics.rowHeightPreview)
            }
            .buttonStyle(RowButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// A list row that names something — a thread, a topic, a day — with one line of
    /// facts under the name, a leading icon tile and trailing marks or a figure. A name
    /// that is a code value, such as a glossary term's spelling, sets `monospacedTitle`
    /// and reads in the code face. The name truncates before the trailing marks do,
    /// down to a readable floor.
    struct TitleRow<Leading: View, Trailing: View>: View {
        private let title: String
        private let subtitle: String
        private let monospacedTitle: Bool
        private let isSelected: Bool
        private let action: () -> Void
        private let leading: Leading
        private let trailing: Trailing
        @Environment(\.theme) private var theme

        init(
            _ title: String,
            subtitle: String,
            isSelected: Bool,
            monospacedTitle: Bool = false,
            action: @escaping () -> Void,
            @ViewBuilder leading: () -> Leading,
            @ViewBuilder trailing: () -> Trailing
        ) {
            self.title = title
            self.subtitle = subtitle
            self.isSelected = isSelected
            self.monospacedTitle = monospacedTitle
            self.action = action
            self.leading = leading()
            self.trailing = trailing()
        }

        var body: some View {
            SwiftUI.Button(action: action) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    leading
                    VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                        Text(title)
                            .roleStyle(monospacedTitle ? .code : .rowTitle)
                            .foregroundStyle(theme.text1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .roleStyle(.meta)
                            .foregroundStyle(theme.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(minWidth: Kit.metaFloor, maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: VoiceourMetrics.Space.xs) {
                        trailing
                    }
                    .layoutPriority(1)
                }
                .padding(.horizontal, VoiceourMetrics.Space.md)
                .padding(.vertical, VoiceourMetrics.Space.xs)
                .frame(minHeight: Kit.Metrics.rowHeightTwo)
            }
            .buttonStyle(RowButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// A one-line list row: a leading glyph or icon, a name, and a trailing fact.
    struct LineRow<Leading: View, Trailing: View>: View {
        private let title: String
        private let isSelected: Bool
        private let action: () -> Void
        private let leading: Leading
        private let trailing: Trailing
        @Environment(\.theme) private var theme

        init(
            _ title: String,
            isSelected: Bool,
            action: @escaping () -> Void,
            @ViewBuilder leading: () -> Leading,
            @ViewBuilder trailing: () -> Trailing
        ) {
            self.title = title
            self.isSelected = isSelected
            self.action = action
            self.leading = leading()
            self.trailing = trailing()
        }

        var body: some View {
            SwiftUI.Button(action: action) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    leading
                    Text(title)
                        .roleStyle(.rowTitle)
                        .foregroundStyle(theme.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: Kit.metaFloor, maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: VoiceourMetrics.Space.xs) {
                        trailing
                    }
                    .roleStyle(.meta, color: theme.text3)
                    .layoutPriority(1)
                }
                .padding(.horizontal, VoiceourMetrics.Space.md)
                .frame(minHeight: Kit.Metrics.rowHeightOne)
            }
            .buttonStyle(RowButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// The unsaved item at the head of a list while its draft page is open — "New
    /// topic", "New term" — as Notes shows a new note before it has words. The pencil
    /// and the italic, dimmer name say it is not saved yet.
    struct DraftRow: View {
        private let title: String
        private let isSelected: Bool
        private let action: () -> Void
        @Environment(\.theme) private var theme

        init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
            self.title = title
            self.isSelected = isSelected
            self.action = action
        }

        var body: some View {
            SwiftUI.Button(action: action) {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text2)
                        .frame(width: VoiceourMetrics.Space.lg, height: VoiceourMetrics.Space.lg)
                        .accessibilityHidden(true)
                    Text(title)
                        .italic()
                        .roleStyle(.body)
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, VoiceourMetrics.Space.md)
                .frame(minHeight: Kit.Metrics.rowHeightOne)
            }
            .buttonStyle(RowButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

extension Kit.TitleRow where Leading == EmptyView {
    init(
        _ title: String,
        subtitle: String,
        isSelected: Bool,
        monospacedTitle: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title,
            subtitle: subtitle,
            isSelected: isSelected,
            monospacedTitle: monospacedTitle,
            action: action
        ) {
            EmptyView()
        } trailing: {
            trailing()
        }
    }
}

extension Kit.LineRow where Leading == EmptyView {
    init(
        _ title: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title, isSelected: isSelected, action: action) {
            EmptyView()
        } trailing: {
            trailing()
        }
    }
}

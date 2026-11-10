import SwiftUI

extension Kit {
    /// A list row that previews words: a meta line — when, where, its marks — over two
    /// lines of the text itself.
    ///
    /// Every row is the Row scale's 64 pt whatever its text, so a list scans as an even
    /// column and a short dictation is still a full target. The words are primary: in a
    /// list of what was said, the text is the subject and the meta line its caption. The
    /// row is one accessibility element; its caller names it, because only the caller
    /// knows which facts the meta line holds.
    struct PreviewRow<Meta: View, Marks: View>: View {
        private let text: String
        private let isSelected: Bool
        private let action: () -> Void
        private let meta: Meta
        private let marks: Marks
        private var a11y = A11y()

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
            Button(action: action) {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                    HStack(spacing: VoiceourMetrics.Space.sm) {
                        meta
                            .roleStyle(.caption, color: a11y.textMid)
                            .lineLimit(1)
                        Spacer(minLength: VoiceourMetrics.Space.xs)
                        HStack(spacing: VoiceourMetrics.Space.xs) {
                            marks
                        }
                    }
                    Text(text)
                        .roleStyle(.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, VoiceourMetrics.Space.md)
                .padding(.vertical, VoiceourMetrics.Space.xs + 1)
                .frame(height: Kit.Metrics.previewRow, alignment: .top)
            }
            .buttonStyle(RowButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// A list row that names something — a thread, a topic, a day — with one line of
    /// facts under the name, a leading badge and trailing marks or a figure. A name
    /// that is a code value, such as a glossary term's spelling, sets
    /// `monospacedTitle` and reads in the code face.
    struct TitleRow<Leading: View, Trailing: View>: View {
        private let title: String
        private let subtitle: String
        private let monospacedTitle: Bool
        private let isSelected: Bool
        private let action: () -> Void
        private let leading: Leading
        private let trailing: Trailing
        private var a11y = A11y()

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
            Button(action: action) {
                HStack(spacing: VoiceourMetrics.Space.sm + VoiceourMetrics.Space.hair) {
                    leading
                    VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                        Text(title)
                            .roleStyle(monospacedTitle ? .code : .heading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .roleStyle(.caption)
                            .foregroundStyle(a11y.textMid)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
                .padding(.horizontal, VoiceourMetrics.Space.sm + VoiceourMetrics.Space.hair)
                .frame(height: Kit.Metrics.titleRow)
            }
            .buttonStyle(RowButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .combine)
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

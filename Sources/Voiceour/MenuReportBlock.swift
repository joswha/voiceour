import SwiftUI
import VoiceCore
import VoiceMac

/// What the report says about the agent thread a paste reached, when the
/// dictation was eligible for one.
///
/// Equatable so the menu can animate the line's arrival: a binding usually lands
/// seconds after the paste, while the popover may already be open.
enum MenuReportLink: Equatable {
    /// The History row is bound: the thread's title, and the key that opens it.
    case thread(title: String, key: AgentSessionKey)
    /// The link was attempted and missed, for this closed reason.
    case unlinked(AgentLinkMiss)
}

struct MenuReportBlock: View {
    let text: String
    @Binding var isCopied: Bool
    let summary: InsertionOutcomeSummary?
    let link: MenuReportLink?
    let openThread: (AgentSessionKey) -> Void
    @Environment(\.theme) private var theme

    init(
        text: String,
        isCopied: Binding<Bool>,
        summary: InsertionOutcomeSummary?,
        link: MenuReportLink?,
        openThread: @escaping (AgentSessionKey) -> Void
    ) {
        self.text = text
        self._isCopied = isCopied
        self.summary = summary
        self.link = link
        self.openThread = openThread
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            if !text.isEmpty {
                MenuTranscriptPreview(text: text, copy: copyTranscript)
            }

            if isCopied {
                caption("Copied to the clipboard.", color: theme.success.text)
            }

            if summary != nil || link != nil {
                // The outcome and where it landed read as one statement, so they
                // sit flush.
                VStack(alignment: .leading, spacing: 0) {
                    if let summary {
                        caption(summary.detail, color: detailColor(for: summary.severity))
                    }
                    if let link {
                        linkLine(link)
                    }
                }
            }
        }
    }

    /// Report sentences wrap in full: each is the one place the menu says what
    /// happened, so none is cut.
    private func caption(_ string: String, color: Color) -> some View {
        Text(string)
            .roleStyle(.meta)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func linkLine(_ link: MenuReportLink) -> some View {
        switch link {
        case .thread(let title, let key):
            Button {
                openThread(key)
            } label: {
                HStack(spacing: VoiceourMetrics.Space.xs) {
                    // The link colour says "this goes somewhere" without a plate,
                    // which would make the line a second bounded control beside
                    // the primary.
                    Text(title)
                        .roleStyle(.meta)
                        .foregroundStyle(theme.accentText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: VoiceourMetrics.Icon.mark, weight: .semibold))
                        .foregroundStyle(theme.text3)
                        .accessibilityHidden(true)
                }
                // The kit's control height, so the line is a full hit target.
                .frame(maxWidth: .infinity, minHeight: Kit.Metrics.controlHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open thread, \(title)")
            .accessibilityIdentifier("menu.report.thread")
        case .unlinked(let miss):
            caption("Not linked. \(miss.sentence)", color: theme.text2)
                .accessibilityIdentifier("menu.report.unlinked")
        }
    }

    private func detailColor(for severity: StatusSeverity) -> Color {
        switch severity {
        case .crit: theme.critical.text
        case .warn: theme.caution.text
        case .ok, .neutral: theme.text2
        }
    }

    private func copyTranscript() {
        // `isCopied` is the only confirmation the menu shows; it may never outrun
        // the write it reports.
        isCopied = GeneralPasteboard.copy(text) != nil
    }
}

extension InsertionOutcomeSummary {
    /// A saved note reports in the shape a delivery outcome uses, so the status
    /// chip names it and the report's detail line explains it the same way. It is
    /// not an `InsertionOutcome`: a note is delivered nowhere, and the detail says
    /// so because the clipboard is exactly where a reader would look for it.
    static let noteSaved = InsertionOutcomeSummary(
        label: "NOTE SAVED",
        detail: "Saved to memory. Nothing was pasted or copied.",
        severity: .ok
    )
}

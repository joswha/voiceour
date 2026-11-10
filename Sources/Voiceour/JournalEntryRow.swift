import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// One entry, readable in full: a timestamp gutter and the whole text. A click
/// copies the text.
///
/// Rewind and Threads are read rather than scanned, so a row holds the whole
/// text instead of History's two-line preview, and the timestamp sits in a
/// gutter of its own so the text's left edge lines up from row to row. The text
/// is the control, as it is in History's open transcript: a click copies it, and
/// a transient COPIED mark and a VoiceOver announcement confirm the write.
struct JournalEntryRow: View {
    private let entry: JournalEntry
    private let isInHistory: Bool
    private let showsThreadAction: Bool
    private let navigation: JournalNavigation

    @State private var showsCopied = false
    @State private var resetCopyFeedbackTask: Task<Void, Never>?

    private var a11y = A11y()

    /// `isInHistory` offers "Show in Timeline", which only a row History still
    /// holds can answer. `showsThreadAction` offers "Open Thread", which a lens
    /// already showing the entry's thread has no use for.
    init(entry: JournalEntry, isInHistory: Bool, showsThreadAction: Bool, navigation: JournalNavigation) {
        self.entry = entry
        self.isInHistory = isInHistory
        self.showsThreadAction = showsThreadAction
        self.navigation = navigation
    }

    var body: some View {
        Button(action: copyText) {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
                Text(timestamp)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    Text(entry.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if hasMarks {
                        HStack(spacing: VoiceourMetrics.Space.xs) {
                            if isNote {
                                ConsoleStateMark("NOTE", .neutral)
                            }
                            if isNotSent {
                                ConsoleStateMark("NOT SENT", .warn)
                            }
                            if let highlightKind {
                                ConsoleStateMark(highlightKind.displayName.uppercased(), .neutral)
                            }
                            if showsCopied {
                                ConsoleStateMark("COPIED", .ok)
                            }
                        }
                    }
                }
            }
            // One line of text is 16 pt tall; the row takes the smallest control
            // height so a short entry is still a full click target.
            .frame(maxWidth: .infinity, minHeight: VoiceourMetrics.Control.mini, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: "Copy text", copyText)
        .contextMenu {
            Button("Copy Text", action: copyText)
            if isInHistory {
                Button("Show in Timeline") {
                    navigation.showInTimeline(entry.id)
                }
            }
            if showsThreadAction, let thread = entry.thread {
                Button("Open Thread") {
                    navigation.openThread(thread.key)
                }
            }
        }
        .onDisappear {
            resetCopyFeedbackTask?.cancel()
        }
    }

    // MARK: Derived

    private var timestamp: String {
        SessionsFormatters.timestamp.string(from: entry.createdAt)
    }

    private var isNote: Bool {
        entry.kind == .note
    }

    /// Only an answered send check counts: a pending one (`nil`) says nothing
    /// about the prompt yet, and a row must not claim a failure it has not seen.
    private var isNotSent: Bool {
        entry.thread?.sent == false
    }

    /// The kinds Rewind lifts into its highlights, under the same confidence bar,
    /// so a row marks exactly the entries a day's highlights would name.
    private var highlightKind: UtteranceKind? {
        guard let label = entry.label, let kind = label.kind,
            let confidence = label.kindConfidence,
            confidence >= JournalQuery.highlightConfidence
        else { return nil }
        switch kind {
        case .decision, .idea, .todo, .question:
            return kind
        case .instruction, .observation, .chatter:
            return nil
        }
    }

    private var hasMarks: Bool {
        isNote || isNotSent || highlightKind != nil || showsCopied
    }

    /// The time, then the two states a reader acts on, then the words. The
    /// marks are words on screen, so VoiceOver hears them as words too.
    private var accessibilityLabel: String {
        var parts = [timestamp]
        if isNote { parts.append("note") }
        if isNotSent { parts.append("not sent") }
        parts.append(entry.text)
        return parts.joined(separator: ", ")
    }

    // MARK: Copy

    /// Mirrors History's copy: the mark and the announcement are claims about the
    /// clipboard, so a refused write leaves the row exactly as it was.
    private func copyText() {
        guard GeneralPasteboard.copy(entry.text) != nil else { return }
        announceCopy("Text copied to clipboard")
        resetCopyFeedbackTask?.cancel()
        withAnimation(feedbackAnimation) {
            showsCopied = true
        }
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(feedbackAnimation) {
                showsCopied = false
            }
        }
    }

    /// A mark that appears beside a row the VoiceOver cursor has already left
    /// confirms nothing, so the same sentence is spoken. A no-op when VoiceOver
    /// is not running.
    private func announceCopy(_ sentence: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private var feedbackAnimation: Animation? {
        a11y.reduceMotion ? nil : .easeInOut(duration: VoiceourMotion.quickDuration)
    }
}

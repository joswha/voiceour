import SwiftUI
import VoiceCore

struct RecentSessionDetailPane: View {
    var coordinator: DictationCoordinator
    var session: RecentSession?
    var isFiltering: Bool
    var hasSessions: Bool
    @Binding var pendingDeleteSession: RecentSession?
    @Binding var isDeletePersistencePending: Bool
    var delete: (RecentSession.ID) async -> Bool
    var copy: (String) -> Void

    private var a11y = A11y()
    @State private var copiedSessionID: RecentSession.ID?
    @State private var resetCopyFeedbackTask: Task<Void, Never>?
    @State private var pendingFixTeachPrefill: FixTeachPrefill?
    @State private var isTeaching = false
    @State private var deleteError: String?

    init(
        coordinator: DictationCoordinator,
        session: RecentSession?,
        isFiltering: Bool,
        hasSessions: Bool,
        pendingDeleteSession: Binding<RecentSession?>,
        isDeletePersistencePending: Binding<Bool>,
        delete: @escaping (RecentSession.ID) async -> Bool,
        copy: @escaping (String) -> Void
    ) {
        self.coordinator = coordinator
        self.session = session
        self.isFiltering = isFiltering
        self.hasSessions = hasSessions
        _pendingDeleteSession = pendingDeleteSession
        _isDeletePersistencePending = isDeletePersistencePending
        self.delete = delete
        self.copy = copy
    }

    private var displayedSession: RecentSession? {
        pendingDeleteSession ?? session
    }

    var body: some View {
        ContentCard(eyebrow: "SESSION") {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
                if let session = displayedSession {
                    header(for: session)

                    if let deleteError {
                        CaptionText(deleteError, color: VoiceourPalette.Signal.crimson)
                    }

                    TranscriptCard(
                        session: session,
                        isCopied: copiedSessionID == session.id,
                        isTeachEditorOpen: isTeaching,
                        copy: { copySession(session) },
                        delete: { pendingDeleteSession = session },
                        teach: { isTeaching = true },
                        onFixTeachWord: { word in
                            pendingFixTeachPrefill = FixTeachPrefill(word: word)
                            isTeaching = true
                        }
                    )

                    if isTeaching {
                        FixTeachControl(
                            coordinator: coordinator,
                            session: session,
                            externalPrefill: $pendingFixTeachPrefill,
                            isEditing: $isTeaching
                        )
                        .id(session.id)
                    }

                    if !coordinator.pendingSuggestions.isEmpty {
                        PendingSuggestionsCard(coordinator: coordinator)
                    }
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // The card fills the row beside the list instead of collapsing to its
        // content and leaving bare ground under it. Only the card fills: the
        // content still hugs and stays top-anchored, so a one-line transcript
        // is not stretched into a void.
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: session?.id) {
            pendingFixTeachPrefill = nil
            isTeaching = false
            deleteError = nil
            guard pendingDeleteSession == nil else { return }
            resetCopyFeedbackTask?.cancel()
            copiedSessionID = nil
        }
        .onDisappear {
            resetCopyFeedbackTask?.cancel()
        }
    }

    private func header(for session: RecentSession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.md) {
            Text(SessionsFormatters.detailStamp.string(from: session.createdAt))
                .font(VoiceourTypography.title)
                .foregroundStyle(VoiceourPalette.Text.high)

            Spacer(minLength: VoiceourMetrics.Space.sm)

            if pendingDeleteSession?.id == session.id {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    // In-flight is a state of the style, not a disabled label: it
                    // blocks activation while keeping the enabled foreground.
                    Button("CONFIRM DELETE") { confirmDelete(session) }
                        .buttonStyle(GlassButtonStyle(kind: .danger, isInFlight: isDeletePersistencePending))
                    Button("CANCEL") {
                        pendingDeleteSession = nil
                        deleteError = nil
                    }
                    .buttonStyle(GlassButtonStyle(kind: .ghost))
                    .disabled(isDeletePersistencePending)
                }
            } else {
                // Destructive intent is signalled at the confirmation step; the
                // resting affordance stays as quiet as the safe actions beside it.
                Button("DELETE") {
                    deleteError = nil
                    pendingDeleteSession = session
                }
                .buttonStyle(GlassButtonStyle(kind: .ghost))
            }
        }
    }

    private var placeholder: some View {
        EmptyState(
            glyph: "rectangle.stack",
            title: placeholderTitle,
            body: placeholderDetail
        )
        // Same inset as the list's empty state: the two states sit side by side
        // in `console.sessions.empty`, and centring each in its own card put
        // their glyphs 25pt out of line because one carries a hint and the other
        // does not. Top-anchored, they share an origin — and they follow the
        // populated card, which also stacks its content at the top.
        .padding(.vertical, VoiceourMetrics.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var placeholderTitle: String {
        if !hasSessions {
            return "Nothing recorded yet"
        }
        return isFiltering ? "No matching session" : "Select a session"
    }

    /// Never instructs the reader to click a card that the current state does not
    /// render — the no-selection copy tracks why there is no selection.
    private var placeholderDetail: String {
        if !hasSessions {
            return "Your first transcript will open here."
        }
        return isFiltering
            ? "No transcript matches the current search."
            : "Pick a session from the list to read its transcript."
    }

    private func confirmDelete(_ session: RecentSession) {
        deleteError = nil
        isDeletePersistencePending = true
        Task {
            let isDurable = await delete(session.id)
            isDeletePersistencePending = false
            guard isDurable else {
                deleteError = "Could not delete this session — it is still on disk. Try again."
                return
            }
            pendingDeleteSession = nil
        }
    }

    private var feedbackAnimation: Animation? {
        a11y.reduceMotion ? nil : .easeInOut(duration: VoiceourMotion.quickDuration)
    }

    private func copySession(_ session: RecentSession) {
        copy(session.text)
        resetCopyFeedbackTask?.cancel()
        // Both directions of the confirmation run through one curve and one
        // Reduce Motion branch; the arrival used to snap and only the exit faded.
        withAnimation(feedbackAnimation) {
            copiedSessionID = session.id
        }

        let copiedID = session.id
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled, copiedSessionID == copiedID else { return }
            withAnimation(feedbackAnimation) {
                copiedSessionID = nil
            }
        }
    }
}

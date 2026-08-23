import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// System: whether this Mac is ready to dictate, what it is allowed to do, what
/// is kept on disk, and how to unkeep it.
///
/// Every OS grant this app asks for is reported exactly once, in the row for the
/// capability it gates — microphone by **Microphone**, Accessibility by **Fn/Globe
/// capture** for the key tap and by **Insertion** for synthetic paste. There is no
/// second permissions section restating those grants: a grant reported twice is a
/// grant a reader has to reconcile. Remediation rides the row it remedies, and
/// only when the grant is actually missing.
struct ConsoleSystemTab: View {
    var coordinator: DictationCoordinator

    /// Real TCC state in production. The offscreen UI harness pins a fixed
    /// snapshot (`RenderOverrides.permissions`) so a golden never encodes this
    /// Mac's privacy grants, and so both the granted and the denied treatments can
    /// be captured.
    private let permissions: PermissionsChecking = RenderOverrides.permissions ?? SystemPermissions()
    private var a11y = A11y()

    @State private var microphone: PermissionState = .notDetermined
    @State private var synthPaste: PermissionState = .notDetermined
    @State private var accessibility: PermissionState = .notDetermined

    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingVocabularyClear = false
    @State private var isClearingHistory = false
    @State private var historyClearFailed = false
    @State private var didCopyDiagnostics = false
    @State private var resetCopyFeedbackTask: Task<Void, Never>?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        Form {
            Section("Readiness") {
                readinessRow(
                    "Backend",
                    backendReadout,
                    statusIdentifier: "system.backend.status"
                )
                modelRow
                readinessRow("Microphone", microphoneReadout)
            }

            Section("Capture") {
                readinessRow("Fn/Globe capture", captureReadout)
                readinessRow("Insertion", insertionReadout)
            }

            Section {
                ConsoleRow(
                    caption:
                        "Recent transcript history is saved locally on this Mac for the History tab. Audio temp "
                        + "files are removed after ASR. Network is used only to download the local speech model."
                ) {
                    LabeledContent {
                        HStack(spacing: VoiceourMetrics.Space.sm) {
                            if didCopyDiagnostics {
                                ConsoleStateMark("COPIED", .ok)
                            }
                            Button("Copy Diagnostics") { copyDiagnostics() }
                                .help("Copy storage paths, backend health, permissions and build info.")
                                .accessibilityIdentifier("system.diagnostics.copy")
                        }
                    } label: {
                        Text("Data handling")
                    }
                }
            } header: {
                Text("Privacy")
            }

            Section("Danger") {
                clearHistoryRow
                clearVocabularyRow
            }
        }
        .formStyle(.grouped)
        .onAppear {
            coordinator.refreshBackendHealth()
            refreshPermissions(animated: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions(animated: true)
        }
        .onDisappear {
            resetCopyFeedbackTask?.cancel()
        }
    }

    /// The user returning from System Settings is this tab's most important state
    /// change: three readouts change word and hue and up to three remediation
    /// buttons leave. Animating it means the grant visibly resolves instead of
    /// jump-cutting the rows that carry them.
    private func refreshPermissions(animated: Bool) {
        guard animated, !a11y.reduceMotion else {
            microphone = permissions.microphone()
            synthPaste = permissions.synthPaste()
            accessibility = permissions.accessibility()
            return
        }
        withAnimation(VoiceourMotion.deliberate) {
            microphone = permissions.microphone()
            synthPaste = permissions.synthPaste()
            accessibility = permissions.accessibility()
        }
    }

    // MARK: Readiness rows

    /// One readiness readout: the word the mark carries, its rung on the severity
    /// ladder, the sentence that explains it, and the one remediation this tab can
    /// offer for it.
    ///
    /// The branch ladders below choose between readouts, never between whole row
    /// literals, so the row that renders one is written exactly once.
    private struct Readout {
        var label: String
        var severity: ConsoleStateMark.Severity
        var detail: String
        var remediation: Remediation?
    }

    private struct Remediation {
        var title: String
        var accessibilityLabel: String
        var identifier: String
        var perform: () -> Void
    }

    /// A fact row: state on the trailing rail, its explanation on the caption
    /// line, remediation after the mark — what is wrong, then what to do about it.
    /// Healthy states keep their sentence: the reader who wants to know *why* the
    /// app is ready is the same reader who needs to know why it is not.
    private func readinessRow(
        _ label: String,
        _ readout: Readout,
        statusIdentifier: String? = nil
    ) -> some View {
        ConsoleRow(caption: readout.detail) {
            LabeledContent {
                HStack(spacing: VoiceourMetrics.Space.sm) {
                    if let statusIdentifier {
                        ConsoleStateMark(readout.label, readout.severity)
                            .accessibilityIdentifier(statusIdentifier)
                    } else {
                        ConsoleStateMark(readout.label, readout.severity)
                    }

                    if let remediation = readout.remediation {
                        Button(remediation.title, action: remediation.perform)
                            .accessibilityLabel(remediation.accessibilityLabel)
                            .accessibilityIdentifier(remediation.identifier)
                    }
                }
            } label: {
                Text(label)
            }
        }
    }

    /// The pinned model behind the running backend, with the revision it is
    /// pinned to. A machine string, so it is monospaced and copyable in place.
    private var modelRow: some View {
        LabeledContent {
            Text(DiagnosticsReport.modelIdentifier(coordinator))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } label: {
            Text("Model")
        }
    }

    /// The one remediation this tab can perform for a backend that is not ready:
    /// re-run the health probe in place, which is the check the readout is asking
    /// for. `refreshBackendHealth` clears `backendHealthError` before it probes,
    /// so the row flips to CHECKING… and back on its own.
    private var recheck: Remediation {
        Remediation(
            title: "Re-check",
            accessibilityLabel: "Re-check backend health",
            identifier: "system.backend.recheck",
            perform: { coordinator.refreshBackendHealth() }
        )
    }

    private func privacySettings(
        label: String,
        identifier: String,
        pane: PrivacySettings
    ) -> Remediation {
        Remediation(
            title: "Open System Settings…",
            accessibilityLabel: label,
            identifier: identifier,
            perform: { pane.open() }
        )
    }

    /// How the running backend describes itself. A saved id from a future build
    /// resolves to no descriptor, so the readout falls back to the id rather than
    /// naming a backend that is not running.
    private var activeDescriptor: ASRBackendDescriptor? {
        ASRBackendRegistry.builtIn.descriptor(for: coordinator.activeBackend)
    }

    /// Spelled exactly as the General tab's picker labels it, so the sentence and
    /// the option the reader chose share one vocabulary.
    private var activeBackendName: String {
        activeDescriptor?.displayName ?? coordinator.activeBackend.uppercased()
    }

    private var activeModelLabel: String {
        activeDescriptor?.modelLabel ?? coordinator.activeBackend
    }

    private var backendReadout: Readout {
        if coordinator.activeBackend == "fake" {
            return Readout(
                label: "DEV READY",
                severity: .ok,
                detail:
                    "Fake backend is ready for first launch and does not require microphone access or a model "
                    + "download."
            )
        } else if let failure = coordinator.acquisitionFailure {
            // The published acquisition failure — DOWNLOAD FAILED for a stopped
            // download, ENGINE OFFLINE for a probe that never answered — is the
            // honest state even while a stale fraction lingers: without this
            // branch the row fell through to MODEL NEEDED or CHECK NEEDED and
            // every dictation failed with a raw code.
            return Readout(
                label: failure.title.uppercased(),
                severity: failure.isRetryable ? .warn : .crit,
                detail: failure.cause,
                remediation: recheck
            )
        } else if let fraction = coordinator.modelDownloadFraction {
            // Formatted by hand rather than through ByteCountFormatter: that
            // formatter is locale-aware and rendered "1,26 GB" on this host, which
            // would bake the developer's region into a committed golden.
            let sizeText = String(format: "%.2f GB", Double(ASRModelContract.sizeBytes) / 1_000_000_000)
            return Readout(
                label: "DOWNLOADING",
                severity: .neutral,
                detail: "\(activeModelLabel) — \(Int(fraction * 100))% of \(sizeText) fetched."
            )
        } else if coordinator.isBackendWarming {
            // Ahead of READY on purpose: `ready` is already true while the model is
            // loading, so the honest state during a 3.5 s cold load is "warming",
            // not "ready".
            return Readout(
                label: "WARMING",
                severity: .neutral,
                detail: "\(activeBackendName) is loading its model and compiling Metal pipelines."
            )
        } else if coordinator.backendHealth?.cacheOk == true && coordinator.backendHealth?.ready == true {
            return Readout(
                label: "READY",
                severity: .ok,
                detail: "\(activeBackendName) is configured for local transcription."
            )
        } else if coordinator.backendHealth == nil, coordinator.backendHealthError == nil {
            // The probe starts from this tab's own onAppear, so "no verdict yet" is
            // a loading state, not a fault: it must not paint as a warning.
            return Readout(
                label: "CHECKING…",
                severity: .neutral,
                detail: "Probing the local backend for cache and model health."
            )
        } else if coordinator.backendHealth == nil {
            return Readout(
                label: "CHECK NEEDED",
                severity: .warn,
                detail: probeFailureDetail,
                remediation: recheck
            )
        } else {
            return Readout(
                label: "MODEL NEEDED",
                severity: .warn,
                detail:
                    "\(activeBackendName) may cold-load or download \(activeModelLabel) on first real "
                    + "transcription.",
                remediation: recheck
            )
        }
    }

    /// The probe's own sentence when it published one. `backendHealthError` is a
    /// `String(describing:)` dump, so the readable half is lifted back out of it;
    /// the whole dump reaches a bug report through Copy Diagnostics instead of
    /// being pasted into a settings row.
    private var probeFailureDetail: String {
        let standing = "The local backend did not answer its health probe. Re-check before starting real dictation."
        guard let payload = coordinator.backendHealthError else { return standing }
        return "\(standing) \(DiagnosticsReport.sentence(in: payload))"
    }

    private var microphoneReadout: Readout {
        if coordinator.activeBackend == "fake" {
            return Readout(
                label: "NOT REQUIRED",
                severity: .neutral,
                detail: "Fake mode uses synthetic audio for development and tests."
            )
        } else if microphone == .granted {
            return Readout(
                label: "GRANTED",
                severity: .ok,
                detail: "Real recording can start without a microphone prompt."
            )
        } else if microphone == .notDetermined {
            return Readout(
                label: "WILL PROMPT",
                severity: .warn,
                detail: "macOS may ask for microphone access when the first real recording starts."
            )
        } else {
            return Readout(
                label: "DENIED",
                severity: .crit,
                detail: "Grant microphone access in System Settings to use real recording.",
                remediation: privacySettings(
                    label: "Open Microphone privacy settings",
                    identifier: "system.microphone.settings",
                    pane: .microphone
                )
            )
        }
    }

    private var captureReadout: Readout {
        if accessibility == .granted {
            return Readout(
                label: "ACTIVE TAP",
                severity: .ok,
                detail: "Standalone Fn/Globe taps can be consumed before macOS shows its popup."
            )
        }
        return Readout(
            label: "PASSIVE FALLBACK",
            severity: .warn,
            detail:
                "Recording can still toggle, but macOS may also react to the key until Accessibility is granted.",
            remediation: privacySettings(
                label: "Open Accessibility privacy settings for key capture",
                identifier: "system.capture.settings",
                pane: .accessibility
            )
        )
    }

    private var insertionReadout: Readout {
        if synthPaste == .granted {
            return Readout(
                label: "PASTE READY",
                severity: .ok,
                detail: "Eligible text targets can receive Cmd-V after dictation."
            )
        }
        return Readout(
            label: "COPY-ONLY RISK",
            severity: .warn,
            detail:
                "Voiceour will keep transcripts on the clipboard when synthetic paste is unavailable or unsafe.",
            remediation: privacySettings(
                label: "Open Accessibility privacy settings for paste",
                identifier: "system.insertion.settings",
                pane: .accessibility
            )
        )
    }

    // MARK: Diagnostics

    private func copyDiagnostics() {
        GeneralPasteboard.copy(
            DiagnosticsReport.text(
                coordinator: coordinator,
                microphone: microphone,
                accessibility: accessibility,
                synthPaste: synthPaste
            )
        )
        resetCopyFeedbackTask?.cancel()
        withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.quick) {
            didCopyDiagnostics = true
        }
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.quick) {
                didCopyDiagnostics = false
            }
        }
    }

    // MARK: Danger

    /// The two erases the app owns. They read directly on the privacy row above:
    /// that row states what is kept locally, these two are how a user unkeeps it.
    /// Both are guarded by the system's own destructive confirmation rather than a
    /// typed token — the sheet names the subject, states the scope, and puts the
    /// destructive verb behind a deliberate second press.
    private var clearHistoryRow: some View {
        ConsoleRow(
            caption: historyClearFailed
                ? "Transcript history could not be erased from disk — it will come back on relaunch."
                : Self.historyClearSentence,
            captionColor: historyClearFailed ? .red : nil
        ) {
            LabeledContent {
                Button(isClearingHistory ? "Clearing…" : "Clear History…", role: .destructive) {
                    historyClearFailed = false
                    isConfirmingHistoryClear = true
                }
                .disabled(hasNothingToClear || isClearingHistory)
                .accessibilityIdentifier("system.history.arm")
            } label: {
                Text("Clear history")
            }
        }
        .confirmationDialog(
            "Clear transcript history?",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { clearHistory() }
                .accessibilityIdentifier("system.history.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel clearing transcript history")
                .accessibilityIdentifier("system.history.cancel")
        } message: {
            Text(Self.historyClearSentence)
        }
    }

    /// Named once because the row caption and the confirmation both state it,
    /// and a destructive action whose two sentences disagree about its scope is
    /// worse than one that says nothing.
    private static let historyClearSentence =
        "Clear local transcript history and the lifetime dictation stats on Home. "
        + "Settings and glossary terms are kept."

    /// The stats ledger outlives individual transcripts — a reader who deleted
    /// every row one at a time in History still has counts here — so an empty
    /// journal alone must not disarm the only control that erases them.
    private var hasNothingToClear: Bool {
        coordinator.recentSessions.isEmpty && coordinator.dictationStats == DictationStatsLedger()
    }

    private func clearHistory() {
        isClearingHistory = true
        historyClearFailed = false
        Task {
            let historyCleared = await coordinator.clearRecentSessions()
            let statsCleared = await coordinator.clearDictationStats()
            isClearingHistory = false
            // A destructive action that half-succeeds must say so: the row reports
            // that the data survived on disk instead of reporting nothing.
            historyClearFailed = !(historyCleared && statsCleared)
        }
    }

    /// Unlike `clearRecentSessions` this mutation is synchronous and publishes no
    /// durability result, so there is no failure state for the row to report.
    private var clearVocabularyRow: some View {
        ConsoleRow(
            caption:
                "Clear vocabulary you taught, imported, or that came from app profiles, and put the bundled "
                + "defaults back to their shipped surfaces."
        ) {
            LabeledContent {
                Button("Clear Vocabulary…", role: .destructive) {
                    isConfirmingVocabularyClear = true
                }
                .disabled(!coordinator.hasLearnedVocabulary)
                .accessibilityIdentifier("system.vocabulary.arm")
            } label: {
                Text("Clear vocabulary")
            }
        }
        .confirmationDialog(
            "Clear learned vocabulary?",
            isPresented: $isConfirmingVocabularyClear,
            titleVisibility: .visible
        ) {
            Button("Clear Vocabulary", role: .destructive) {
                coordinator.clearLearnedVocabulary()
            }
            .accessibilityIdentifier("system.vocabulary.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel clearing learned vocabulary")
                .accessibilityIdentifier("system.vocabulary.cancel")
        } message: {
            Text(
                "Clear vocabulary you taught, imported, or that came from app profiles, and put the bundled "
                    + "defaults back to their shipped surfaces."
            )
        }
    }
}

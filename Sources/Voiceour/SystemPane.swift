import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// System pane — the app's readiness, capture, audio and privacy ledger
/// (SettingsRow.swift / SettingsSectionBlock.swift / PropertyRow.swift).
///
/// Every runtime fact is a `PropertyRow`: the designator in the 176pt label
/// column, the state word as a compact chip on the trailing rail, and the
/// sentence that explains that state as a caption at the value-column origin.
/// This pane used to be a three-column bento of status-tile cards on
/// `Content.table` 940, sized by arithmetic on its own measure. A tile spent a
/// 32pt display value and a whole card floor on one word of state, and a
/// reader had to scan two axes to answer the one question the pane exists to
/// answer — is this Mac ready to dictate. The ledger answers it down a single
/// column on the form measure, in the same vocabulary the tiles carried, word
/// for word.
///
/// Remediation rides the row it remedies. The deep link that used to sit on a
/// tile floor is now a conditional `.action` accessory on the same line as the
/// chip that justifies it, so a grant, its consequence, and its fix are one
/// line of the ledger instead of one card of mosaic.
///
/// Every OS grant this app asks for is still reported exactly once, in the row
/// for the capability it gates — microphone by **Microphone**, Accessibility
/// by **Fn/Globe capture** for the key tap and by **Insertion** for synthetic
/// paste. There is no second PERMISSIONS section restating those grants: it
/// carried the same three words and the same three deep links one screenful
/// lower, and a grant reported twice is a grant a reader has to reconcile.
struct SystemPane: View {
    var coordinator: DictationCoordinator
    /// Real TCC state in production. The offscreen UI harness pins a fixed
    /// snapshot (`RenderOverrides.permissions`) so a golden never encodes this
    /// Mac's privacy grants, and so both the granted and the denied treatments
    /// can be captured.
    private let permissions: PermissionsChecking = RenderOverrides.permissions ?? SystemPermissions()
    private var a11y = A11y()
    @State private var microphone: PermissionState = .notDetermined
    @State private var synthPaste: PermissionState = .notDetermined
    @State private var accessibility: PermissionState = .notDetermined
    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingVocabularyClear = false

    /// Both destructive rows sit below the fold at the default window size, so
    /// arming one would otherwise change the pane entirely off screen. The pane
    /// scrolls its own danger section into view when a confirm row opens.
    private static let dangerAnchor = "system.danger"

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    /// The user returning from System Settings is the pane's most important
    /// state change: three readouts change word and hue and up to three
    /// remediation buttons leave. Animating it means the grant visibly
    /// resolves instead of jump-cutting the rows that carry them.
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

    var body: some View {
        SettingsPaneScroll {
            ScrollViewReader { proxy in
                // Sections sit `Space.lg` apart, the gap `SettingsPaneScroll`
                // gives its own children — the `ScrollViewReader` is a single
                // child in that stack, so the pane restates the step rather
                // than inheriting it.
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
                    SettingsSectionBlock(eyebrow: "READINESS") {
                        readinessRow("Backend", backendReadout)
                        readinessRow("Microphone", microphoneReadout(microphone))
                    }

                    SettingsSectionBlock(eyebrow: "CAPTURE") {
                        readinessRow("Fn/Globe capture", captureReadout(accessibility))
                        readinessRow("Insertion", insertionReadout(synthPaste))
                    }

                    SettingsSectionBlock(eyebrow: "AUDIO") {
                        muteRow
                    }

                    SettingsSectionBlock(eyebrow: "PRIVACY") {
                        // Valueless: the row states a standing policy, not a runtime
                        // reading, so there is nothing for the value column to hold and
                        // the prose is the permanent caption.
                        PropertyRow(
                            "Data handling",
                            caption:
                                "Recent transcript history is saved locally on this Mac for the Sessions view. Audio temp files are removed after ASR. Network is used only when optional refinement is enabled and configured."
                        )
                    }

                    dangerSection
                        .id(Self.dangerAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .paintedBottomScrollEdge()
                .onChange(of: isConfirmingHistoryClear || isConfirmingVocabularyClear) { _, isConfirming in
                    guard isConfirming else { return }
                    proxy.scrollTo(Self.dangerAnchor, anchor: .center)
                }
            }
        }
        .scrollEdge(.soft, for: .bottom)
        .onAppear {
            coordinator.refreshBackendHealth()
            refreshPermissions(animated: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions(animated: true)
        }
    }

    // MARK: DANGER

    /// The two erases the app owns, on the pane that owns everything else about
    /// this Mac's relationship with it. They read directly on PRIVACY above:
    /// that row states what is kept locally, these two are how a user unkeeps
    /// it. Both run one component and one state machine — they used to run four
    /// different grammars between two adjacent cards.
    private var dangerSection: some View {
        SettingsSectionBlock(eyebrow: "DANGER") {
            ConfirmActionRow(
                label: "Clear history",
                subject: "Transcript history",
                scope: "Clear local transcript history. Settings and glossary terms are kept.",
                actionTitle: "CLEAR HISTORY",
                inFlightTitle: "CLEARING…",
                failureLabel: "NOT ERASED",
                failureText: "Transcript history could not be erased from disk — it will come back on relaunch.",
                identifier: "system.history",
                isAvailable: !coordinator.recentSessions.isEmpty,
                isConfirming: $isConfirmingHistoryClear,
                perform: { await coordinator.clearRecentSessions() }
            )

            ConfirmActionRow(
                label: "Clear vocabulary",
                subject: "Learned vocabulary",
                scope:
                    "Clear vocabulary you taught, imported, or that came from app profiles, and put the bundled defaults back to their shipped surfaces.",
                actionTitle: "CLEAR VOCABULARY",
                inFlightTitle: "CLEARING…",
                failureLabel: "NOT ERASED",
                failureText: "Learned vocabulary could not be erased from disk — it will come back on relaunch.",
                identifier: "system.vocabulary",
                isAvailable: coordinator.hasLearnedVocabulary,
                isConfirming: $isConfirmingVocabularyClear,
                perform: {
                    // Unlike `clearRecentSessions` this mutation is
                    // synchronous and publishes no durability result.
                    coordinator.clearLearnedVocabulary()
                    return true
                }
            )
        }
    }

    // MARK: Readiness

    /// The severity ladder this pane keeps, and the reason the two hues are not
    /// interchangeable:
    ///
    /// * `.crit` — the app cannot do its job at all. Microphone denied is the
    ///   only state on this pane that qualifies: with no audio in, no amount of
    ///   retrying produces a transcript.
    /// * `.warn` — it works, degraded. A key tap macOS also reacts to, a
    ///   transcript that lands on the clipboard instead of in the field, a model
    ///   that cold-loads on first use, a grant that has not been asked for yet.
    ///
    /// Accessibility denied is deliberately *not* `.crit`. It is the default
    /// state of a freshly installed app (`AXIsProcessTrusted()` is false until
    /// the user adds the app), and both capabilities it gates degrade rather
    /// than stop: the Fn tap falls back to passive, insertion falls back to
    /// copy-only. Painting a fresh install crimson would flatten the ladder from
    /// the other end.

    /// One readiness readout: the word the chip carries, its rung on the ladder
    /// above, the sentence that explains it, and the one remediation this pane
    /// can offer for it.
    ///
    /// The branch ladder used to choose between whole tile literals, so the
    /// composition was restated once per state and could drift between them.
    /// It now chooses between readouts, and the row that renders one is written
    /// exactly once.
    private struct Readout {
        var status: String
        var mode: StatusChip.Mode
        var detail: String
        var remediation: PropertyAccessory?

        /// Chip first, remediation second: the rail reads in the order the
        /// reader needs it — what is wrong, then what to do about it.
        var accessories: [PropertyAccessory] {
            guard let remediation else { return [.status(status, mode)] }
            return [.status(status, mode), remediation]
        }

        /// The same word and mode shaped for `SettingsRow`'s status slot, for
        /// the control rows whose chip rides the control band instead of a
        /// `PropertyRow` accessory rail.
        var chip: (label: String, mode: StatusChip.Mode) { (label: status, mode: mode) }
    }

    /// A fact row: state on the rail, its explanation on the caption line.
    /// Healthy states keep their sentence — the reader who wants to know *why*
    /// the app is ready is the same reader who needs to know why it is not.
    private func readinessRow(_ label: String, _ readout: Readout) -> some View {
        PropertyRow(label, caption: readout.detail, accessories: readout.accessories)
    }

    /// The one remediation this pane can perform for a backend that is not
    /// ready: re-run the health probe in place, which is the check the readout
    /// is asking for. `refreshBackendHealth` clears `backendHealthError` before
    /// it probes, so the row flips to CHECKING… and back on its own.
    private func recheckBackend() {
        coordinator.refreshBackendHealth()
    }

    private var recheckAccessory: PropertyAccessory {
        .action(
            title: "RE-CHECK",
            kind: .ghost,
            label: "Re-check backend health",
            identifier: "system.backend.recheck",
            isEnabled: true,
            isInFlight: false,
            perform: recheckBackend
        )
    }

    private func privacySettingsAccessory(
        label: String,
        identifier: String,
        pane: PrivacySettings
    ) -> PropertyAccessory {
        .action(
            title: "OPEN SYSTEM SETTINGS…",
            kind: .ghost,
            label: label,
            identifier: identifier,
            isEnabled: true,
            isInFlight: false,
            perform: { pane.open() }
        )
    }

    /// How the running backend describes itself. A saved id from a future
    /// build resolves to no descriptor, so the readout falls back to the id
    /// rather than naming a backend that is not running.
    private var activeDescriptor: ASRBackendDescriptor? {
        ASRBackendRegistry.builtIn.descriptor(for: coordinator.activeBackend)
    }

    /// Spelled exactly as the Voice pane's picker labels it, so the sentence
    /// and the option the reader chose share one vocabulary.
    private var activeBackendName: String {
        activeDescriptor?.displayName ?? coordinator.activeBackend.uppercased()
    }

    private var activeModelLabel: String {
        activeDescriptor?.modelLabel ?? coordinator.activeBackend
    }

    private var backendReadout: Readout {
        if coordinator.activeBackend == "fake" {
            return Readout(
                status: "DEV READY",
                mode: .ok,
                detail:
                    "Fake backend is ready for first launch and does not require microphone access or a model download."
            )
        } else if coordinator.backendHealth?.cacheOk == true && coordinator.backendHealth?.ready == true {
            return Readout(
                status: "READY",
                mode: .ok,
                detail: "\(activeBackendName) is configured for local transcription."
            )
        } else if coordinator.backendHealth == nil, coordinator.backendHealthError == nil {
            // The probe starts from this pane's own onAppear, so "no verdict yet"
            // is a loading state, not a fault: it must not paint as a warning.
            return Readout(
                status: "CHECKING…",
                mode: .neutral,
                detail: "Probing the local backend for cache and model health."
            )
        } else if coordinator.backendHealth == nil {
            return Readout(
                status: "CHECK NEEDED",
                mode: .warn,
                detail: "The local backend did not answer its health probe. Re-check before starting real dictation.",
                remediation: recheckAccessory
            )
        } else {
            return Readout(
                status: "MODEL NEEDED",
                mode: .warn,
                detail:
                    "\(activeBackendName) may cold-load or download \(activeModelLabel) "
                    + "on first real transcription.",
                remediation: recheckAccessory
            )
        }
    }

    private func microphoneReadout(_ microphone: PermissionState) -> Readout {
        if coordinator.activeBackend == "fake" {
            return Readout(
                status: "NOT REQUIRED",
                mode: .neutral,
                detail: "Fake mode uses synthetic audio for development and tests."
            )
        } else if microphone == .granted {
            return Readout(
                status: "GRANTED",
                mode: .ok,
                detail: "Real recording can start without a microphone prompt."
            )
        } else if microphone == .notDetermined {
            return Readout(
                status: "WILL PROMPT",
                mode: .warn,
                detail: "macOS may ask for microphone access when the first real recording starts."
            )
        } else {
            return Readout(
                status: "DENIED",
                mode: .crit,
                detail: "Grant microphone access in System Settings to use real recording.",
                remediation: privacySettingsAccessory(
                    label: "Open Microphone privacy settings",
                    identifier: "system.microphone.settings",
                    pane: .microphone
                )
            )
        }
    }

    private func captureReadout(_ accessibility: PermissionState) -> Readout {
        if accessibility == .granted {
            return Readout(
                status: "ACTIVE TAP",
                mode: .ok,
                detail: "Standalone Fn/Globe taps can be consumed before macOS shows its popup."
            )
        } else {
            return Readout(
                status: "PASSIVE FALLBACK",
                mode: .warn,
                detail:
                    "Recording can still toggle, but macOS may also react to the key until Accessibility is granted.",
                remediation: privacySettingsAccessory(
                    label: "Open Accessibility privacy settings for key capture",
                    identifier: "system.capture.settings",
                    pane: .accessibility
                )
            )
        }
    }

    private func insertionReadout(_ synthPaste: PermissionState) -> Readout {
        if synthPaste == .granted {
            return Readout(
                status: "PASTE READY",
                mode: .ok,
                detail: "Eligible text targets can receive Cmd-V after dictation."
            )
        } else {
            return Readout(
                status: "COPY-ONLY RISK",
                mode: .warn,
                detail:
                    "Voiceour will keep transcripts on the clipboard when synthetic paste is unavailable or unsafe.",
                remediation: privacySettingsAccessory(
                    label: "Open Accessibility privacy settings for paste",
                    identifier: "system.insertion.settings",
                    pane: .accessibility
                )
            )
        }
    }

    // MARK: Audio

    /// What system audio is doing right now, on the same three-state ladder the
    /// standalone SYSTEM AUDIO tile carried. It is a readout *of* the switch
    /// beside it, so it rides that row's status slot rather than restating the
    /// setting as a fourth fact in a section of its own. Its `detail` is also
    /// the row's only explanatory caption: the state sentence already says what
    /// a static one would have, so nothing else is stacked under the switch
    /// except the live "applies next" note.
    ///
    /// UNAVAILABLE outranks MUTE ON because it is the same promise, refused.
    /// A device with neither a settable mute nor a settable volume — a
    /// DisplayPort monitor, measured — cannot be silenced at all, and the pane
    /// that kept saying "will be muted" is exactly how that went unnoticed.
    private var muteReadout: Readout {
        if coordinator.isSystemAudioMuted {
            return Readout(
                status: "MUTED NOW",
                mode: .ok,
                detail: "System audio is currently muted and will be restored when the session ends."
            )
        } else if coordinator.settings.muteSystemAudioDuringCapture, coordinator.isSystemAudioMuteUnavailable {
            return Readout(
                status: "UNAVAILABLE",
                mode: .warn,
                detail: "The current output device offers no mute or volume control, so audio kept playing."
            )
        } else if coordinator.settings.muteSystemAudioDuringCapture {
            return Readout(
                status: "MUTE ON",
                mode: .neutral,
                detail: "System audio fades out for the recording and fades back when the session ends."
            )
        } else {
            return Readout(
                status: "MUTE OFF",
                mode: .neutral,
                detail: "System audio will continue playing while recording."
            )
        }
    }

    private var muteRow: some View {
        SettingsRow(label: "Mute during capture", status: muteReadout.chip) {
            // Intrinsic width, so the track stays beside its own label instead
            // of pinning itself to the far edge of the content slot and turning
            // the empty middle into a live hit region.
            Toggle(
                "Mute system audio while recording", isOn: settingBinding(coordinator, \.muteSystemAudioDuringCapture)
            )
            .compactGlassToggle()
        } footer: {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                CaptionText(muteReadout.detail)

                if coordinator.state.isActive {
                    CaptionText("Applies from the next recording.")
                        .transition(.opacity)
                }
            }
        }
    }
}

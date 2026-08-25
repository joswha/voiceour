import SwiftUI
import VoiceCore
import VoiceMac

/// One readiness readout: the word the mark carries, its rung on the severity
/// ladder, the sentence that explains it, and the one remediation the console can
/// offer for it.
///
/// A value rather than a view so the two surfaces that report readiness cannot
/// describe the same state differently. Settings renders these as `LabeledContent`
/// rows on a native `Form` plate; Home's first-run card renders the same values
/// with the island vocabulary. The words are decided once, here.
struct ConsoleReadout {
    var label: String
    var severity: ConsoleStateMark.Severity
    var detail: String
    var remediation: ConsoleRemediation?
}

/// What the console can do about a readout that is not healthy.
struct ConsoleRemediation {
    var title: String
    var accessibilityLabel: String
    var identifier: String
    var perform: () -> Void
}

extension ConsoleRemediation {
    /// The same action under a surface-local identifier.
    ///
    /// Two surfaces may offer one remediation; two nodes may not answer to one
    /// identifier, because every harness query rejects a multiple match rather
    /// than silently retargeting. The title, the accessibility label and the
    /// action are the part that has to stay shared.
    func identified(_ identifier: String) -> ConsoleRemediation {
        var copy = self
        copy.identifier = identifier
        return copy
    }
}

/// The console's one readiness vocabulary: what the backend, the microphone, the
/// key tap and insertion are doing, in the user's words.
///
/// Extracted from the Settings tab when Home's first-run card began reporting the
/// same three states. Sharing the values rather than the sentences is the point:
/// a second spelling of "42% of 1.26 GB fetched" is a second thing to keep in
/// step, and the two surfaces would have drifted at the first edit.
@MainActor
enum ConsoleReadiness {

    // MARK: Remediation

    /// The one remediation for a backend that is not ready: re-run the health
    /// probe in place, which is the check the readout is asking for.
    /// `refreshBackendHealth` clears `backendHealthError` before it probes, so the
    /// row flips to CHECKING… and back on its own.
    static func recheck(_ coordinator: DictationCoordinator) -> ConsoleRemediation {
        ConsoleRemediation(
            title: "Re-check",
            accessibilityLabel: "Re-check backend health",
            identifier: "system.backend.recheck",
            perform: { coordinator.refreshBackendHealth() }
        )
    }

    static func privacySettings(
        label: String,
        identifier: String,
        pane: PrivacySettings
    ) -> ConsoleRemediation {
        ConsoleRemediation(
            title: "Open System Settings…",
            accessibilityLabel: label,
            identifier: identifier,
            perform: { pane.open() }
        )
    }

    // MARK: Backend identity

    /// How the running backend describes itself. A saved id from a future build
    /// resolves to no descriptor, so a readout falls back to the id rather than
    /// naming a backend that is not running.
    static func activeDescriptor(_ coordinator: DictationCoordinator) -> ASRBackendDescriptor? {
        ASRBackendRegistry.builtIn.descriptor(for: coordinator.activeBackend)
    }

    /// Spelled exactly as the Backend picker labels it, so the sentence and the
    /// option the reader chose share one vocabulary.
    static func activeBackendName(_ coordinator: DictationCoordinator) -> String {
        activeDescriptor(coordinator)?.displayName ?? coordinator.activeBackend.uppercased()
    }

    static func activeModelLabel(_ coordinator: DictationCoordinator) -> String {
        activeDescriptor(coordinator)?.modelLabel ?? coordinator.activeBackend
    }

    // MARK: Readouts

    static func backend(_ coordinator: DictationCoordinator) -> ConsoleReadout {
        let backendName = activeBackendName(coordinator)
        if coordinator.activeBackend == "fake" {
            return ConsoleReadout(
                label: "DEV READY",
                severity: .ok,
                detail:
                    "Fake backend is ready for first launch and does not require microphone access or a model "
                    + "download."
            )
        } else if let failure = coordinator.acquisitionFailure {
            // The published acquisition failure outranks every readout below it,
            // and it is the sidecar's own verdict wherever it has one — DISK FULL,
            // DOWNLOAD FAILED, DOWNLOAD DAMAGED, MODEL FAILED — with the inferred
            // DOWNLOAD FAILED and ENGINE OFFLINE behind it. Without this branch the
            // row fell through to MODEL NEEDED or CHECK NEEDED and every dictation
            // failed with a raw code.
            return ConsoleReadout(
                label: failure.title.uppercased(),
                severity: failure.isRetryable ? .warn : .crit,
                detail: failure.cause,
                remediation: recheck(coordinator)
            )
        } else if let fraction = coordinator.modelDownloadFraction {
            // Formatted by hand rather than through ByteCountFormatter: that
            // formatter is locale-aware and rendered "1,26 GB" on this host, which
            // would bake the developer's region into a committed golden.
            let sizeText = String(
                format: "%.2f GB", Double(coordinator.activeModelVariant.sizeBytes) / 1_000_000_000)
            return ConsoleReadout(
                label: "DOWNLOADING",
                severity: .neutral,
                detail: "\(activeModelLabel(coordinator)) — \(Int(fraction * 100))% of \(sizeText) fetched."
            )
        } else if coordinator.isBackendWarming {
            // Ahead of READY on purpose: `ready` is already true while the model is
            // loading, so the honest state during a 3.5 s cold load is "warming",
            // not "ready".
            return ConsoleReadout(
                label: "WARMING",
                severity: .neutral,
                detail: "\(backendName) is loading its model and compiling Metal pipelines."
            )
        } else if coordinator.backendHealth?.cacheOk == true && coordinator.backendHealth?.ready == true {
            return ConsoleReadout(
                label: "READY",
                severity: .ok,
                detail: "\(backendName) is configured for local transcription."
            )
        } else if coordinator.backendHealth == nil, coordinator.backendHealthError == nil {
            // The probe starts from the reporting surface's own onAppear, so "no
            // verdict yet" is a loading state, not a fault: it must not paint as a
            // warning.
            return ConsoleReadout(
                label: "CHECKING…",
                severity: .neutral,
                detail: "Probing the local backend for cache and model health."
            )
        } else if coordinator.backendHealth == nil {
            return ConsoleReadout(
                label: "CHECK NEEDED",
                severity: .warn,
                detail: probeFailureDetail(coordinator),
                remediation: recheck(coordinator)
            )
        } else {
            return ConsoleReadout(
                label: "MODEL NEEDED",
                severity: .warn,
                // Not "may cold-load or download on first real transcription": since
                // `start()` gained its readiness preflight, a tap with no usable model
                // is refused before recording, so no dictation will ever trigger that
                // download. What the reader needs is why the tap does nothing.
                detail:
                    "\(backendName) has no usable copy of \(activeModelLabel(coordinator)), so a dictation tap "
                    + "is refused instead of recording. Re-check after the download has finished.",
                remediation: recheck(coordinator)
            )
        }
    }

    /// The probe's own sentence when it published one. `backendHealthError` is a
    /// `String(describing:)` dump, so the readable half is lifted back out of it;
    /// the whole dump reaches a bug report through Copy Diagnostics instead of
    /// being pasted into a settings row.
    static func probeFailureDetail(_ coordinator: DictationCoordinator) -> String {
        let standing = "The local backend did not answer its health probe. Re-check before starting real dictation."
        guard let payload = coordinator.backendHealthError else { return standing }
        return "\(standing) \(DiagnosticsReport.sentence(in: payload))"
    }

    static func microphone(
        _ coordinator: DictationCoordinator,
        _ state: PermissionState
    ) -> ConsoleReadout {
        if coordinator.activeBackend == "fake" {
            return ConsoleReadout(
                label: "NOT REQUIRED",
                severity: .neutral,
                detail: "Fake mode uses synthetic audio for development and tests."
            )
        } else if state == .granted {
            return ConsoleReadout(
                label: "GRANTED",
                severity: .ok,
                detail: "Real recording can start without a microphone prompt."
            )
        } else if state == .notDetermined {
            return ConsoleReadout(
                label: "WILL PROMPT",
                severity: .warn,
                detail: "macOS may ask for microphone access when the first real recording starts."
            )
        } else {
            return ConsoleReadout(
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

    static func capture(_ accessibility: PermissionState) -> ConsoleReadout {
        if accessibility == .granted {
            return ConsoleReadout(
                label: "ACTIVE TAP",
                severity: .ok,
                detail: "Standalone Fn/Globe taps can be consumed before macOS shows its popup."
            )
        }
        return ConsoleReadout(
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

    static func insertion(_ synthPaste: PermissionState) -> ConsoleReadout {
        if synthPaste == .granted {
            return ConsoleReadout(
                label: "PASTE READY",
                severity: .ok,
                detail: "Eligible text targets can receive Cmd-V after dictation."
            )
        }
        return ConsoleReadout(
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
}

extension StatusChip.Mode {
    /// The island vocabulary for a console readiness severity.
    ///
    /// Two mark shapes, one ladder. `ConsoleStateMark` is a native-window mark on
    /// system semantic colours; `StatusChip` is the app's own mark for the three
    /// bespoke surfaces, and Home's islands are one of them. The severities are the
    /// same four rungs, so the readouts stay shared and only the paint differs.
    /// `.live` has no readiness meaning and is therefore unreachable from here.
    init(_ severity: ConsoleStateMark.Severity) {
        switch severity {
        case .neutral: self = .neutral
        case .ok: self = .ok
        case .warn: self = .warn
        case .crit: self = .crit
        }
    }
}

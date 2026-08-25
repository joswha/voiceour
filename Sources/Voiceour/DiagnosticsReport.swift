import Foundation
import VoiceCore
import VoiceMac

/// The install's runtime facts as one pasteable block.
///
/// This used to be a whole console pane of machine-facing property rows behind a
/// `--debug` flag: storage paths, a model id, probe evidence, a version and a
/// self-test command, each with its own copy button. Nobody reads a path off a
/// screen — they copy it into a bug report — so the pane collapsed into the one
/// action it existed to perform, and the facts are assembled here where they can
/// be produced without a view.
///
/// Permissions come in as parameters rather than being read here: the System tab
/// already resolves them through the harness's `RenderOverrides.permissions`
/// seam, and a second, unseamed read would put whichever privacy grants this Mac
/// happens to have into a report the harness is supposed to be able to pin.
enum DiagnosticsReport {
    static let selfTestCommand = "Voiceour --self-test"

    @MainActor
    static func text(
        coordinator: DictationCoordinator,
        microphone: PermissionState,
        accessibility: PermissionState,
        synthPaste: PermissionState
    ) -> String {
        var lines: [String] = []

        lines.append("Voiceour diagnostics")
        lines.append("")
        lines.append("APPLICATION")
        lines.append("  version: \(appVersion) (build \(appBuild))")
        lines.append("  saved sessions: \(coordinator.recentSessions.count)")
        lines.append("  self-test: \(selfTestCommand)")

        lines.append("")
        lines.append("BACKEND")
        lines.append("  backend: \(backendValue(coordinator))")
        lines.append("  model: \(modelIdentifier(coordinator))")
        lines.append("  status: \(backendStatusWord(coordinator))")
        lines.append("  evidence: \(backendEvidence(coordinator))")
        lines.append("  health probe: \(healthProbe(coordinator))")
        if let payload = coordinator.backendHealthError {
            // The untouched `String(describing:)` dump, which is the form a bug
            // report wants.
            lines.append("  health error: \(payload)")
        }
        if let fraction = coordinator.modelDownloadFraction {
            lines.append(
                "  download: \(Int(fraction * 100))% of \(coordinator.activeModelVariant.sizeBytes) bytes"
            )
        }
        if let failure = coordinator.acquisitionFailure {
            lines.append("  acquisition failure: \(failure.title) — \(failure.cause)")
        }

        lines.append("")
        lines.append("PERMISSIONS")
        lines.append("  microphone: \(microphone.rawValue)")
        lines.append("  accessibility: \(accessibility.rawValue)")
        lines.append("  synthetic paste: \(synthPaste.rawValue)")

        lines.append("")
        lines.append("STORAGE")
        lines.append("  settings: \(settingsPath)")
        lines.append("  recent sessions: \(recentSessionsPath)")
        lines.append("  dictation stats: \(dictationStatsPath)")

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Application

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "local"
    }

    // MARK: Backend

    /// One line for the saved/active pair. The only diagnostic content the two
    /// ever carried is whether they differ — the symptom of a backend switch that
    /// did not take — so agreement prints one name and disagreement prints the
    /// transition.
    @MainActor
    private static func backendValue(_ coordinator: DictationCoordinator) -> String {
        let saved = coordinator.settings.asrBackend.uppercased()
        guard coordinator.settings.asrBackend != coordinator.activeBackend else { return saved }
        return "\(saved) → \(coordinator.activeBackend.uppercased()) (drift)"
    }

    /// The model the running backend loads, with the revision it is pinned to.
    /// Backends without pinned model metadata fall back to their descriptor's own
    /// label rather than borrowing another backend's model id.
    ///
    /// Not private: the System tab prints the same string as a row, and two
    /// spellings of "which model is this" is exactly the drift this replaces.
    @MainActor
    static func modelIdentifier(_ coordinator: DictationCoordinator) -> String {
        guard let descriptor = ASRBackendRegistry.builtIn.descriptor(for: coordinator.activeBackend) else {
            return coordinator.activeBackend
        }
        guard let modelId = descriptor.modelId else { return descriptor.modelLabel }
        guard let revision = descriptor.modelRevision else { return modelId }
        // The artifact is named too: every variant shares the id and revision, so without it a
        // bug report cannot say which weights produced the transcript it is about.
        return "\(modelId)@\(revision) (\(coordinator.activeModelVariant.rawValue))"
    }

    /// A missing model is a recoverable gap — download it and dictation works. An
    /// unavailable backend is not: nothing transcribes until it comes back.
    @MainActor
    private static func backendStatusWord(_ coordinator: DictationCoordinator) -> String {
        switch coordinator.backendHealth?.backendStatus {
        case .ready: "ready"
        case .modelMissing: "model missing"
        case .backendUnavailable: "backend unavailable"
        case nil: "unknown"
        }
    }

    /// A probe that has not answered leaves cache and residency unknown rather
    /// than false — the difference between "the cache is missing" and "nobody has
    /// looked" is the whole content of this line on a cold start.
    @MainActor
    private static func backendEvidence(_ coordinator: DictationCoordinator) -> String {
        let health = coordinator.backendHealth
        let cache = health.map { $0.cacheOk ? "cache OK" : "cache missing" } ?? "cache unknown"
        let model = health.map { $0.modelLoaded ? "model loaded" : "model not loaded" } ?? "model unknown"
        return "\(cache) · \(model)"
    }

    @MainActor
    private static func healthProbe(_ coordinator: DictationCoordinator) -> String {
        if coordinator.backendHealthError != nil { return "error" }
        return coordinator.backendHealth == nil ? "not probed" : "all clear"
    }

    // MARK: Storage

    /// Pinned under the offscreen UI harness so a committed fixture never
    /// contains the developer's home directory.
    private static var settingsPath: String {
        RenderOverrides.settingsPath ?? SettingsStore.defaultURL.path
    }

    private static var recentSessionsPath: String {
        RenderOverrides.recentSessionsPath ?? RecentSessionStore.defaultURL.path
    }

    private static var dictationStatsPath: String {
        RenderOverrides.dictationStatsPath ?? DictationStatsStore.defaultURL.path
    }

    /// The human sentence inside a backend health payload.
    ///
    /// `backendHealthError` is published as `String(describing:)`, so by the time
    /// it reaches a view the structure is gone. Every error the sidecar itself
    /// raises is an `ASRErrorMessage`, which carries its one written sentence in
    /// `detail`; this lifts that field back out. Anything else — a launch
    /// failure, a decode error — has no such field and is shown whole, because
    /// then the dump is the only message there is.
    static func sentence(in payload: String) -> String {
        guard let start = payload.range(of: "detail: Optional(\"")?.upperBound else {
            return payload
        }
        var sentence = ""
        var index = start
        while index < payload.endIndex {
            let character = payload[index]
            index = payload.index(after: index)
            switch character {
            case "\"":
                return sentence
            case "\\" where index < payload.endIndex:
                sentence.append(payload[index])
                index = payload.index(after: index)
            default:
                sentence.append(character)
            }
        }
        return payload
    }
}

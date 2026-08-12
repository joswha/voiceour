// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: eleven production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    enum UICoverageRegistry {
        static let requirements: [UICoverageRequirement] = [
            // Every surface is represented independently of its deeper state inventory.
            surface(.home, "Home pane renders", "console.home.populated"),
            surface(.sessions, "Sessions pane renders", "console.sessions.populated"),
            surface(.voice, "Voice pane renders", "console.voice.default"),
            surface(.glossary, "Glossary pane renders", "console.glossary.populated"),
            surface(.refinement, "Refinement pane renders", "console.refinement.configured"),
            surface(.system, "System pane renders", "console.system.granted"),
            surface(.diagnostics, "Diagnostics pane renders", "console.diagnostics.healthy"),
            surface(.menu, "Menu popover content renders", "menu.idle"),
            surface(.overlay, "Recording overlay renders", "overlay.panel.recording"),
            surface(.atoms, "Shared property atoms render", "atom.properties"),

            // Home
            state(.home, "empty-history", "First-run empty dashboard", scene: "console.home.empty"),
            state(.home, "populated-dashboard", "Populated dashboard", scene: "console.home.populated"),
            state(.home, "listening", "Live recording dashboard", scene: "console.home.recording"),
            state(.home, "working-checking-permissions", "WORKING while checking permissions"),
            state(.home, "working-finalizing-audio", "WORKING while finalizing audio"),
            state(.home, "working-transcribing", "WORKING while transcribing"),
            state(.home, "working-cleaning", "WORKING while cleaning"),
            state(.home, "working-refining", "WORKING while refining"),
            state(.home, "working-ready-to-insert", "WORKING while ready to insert"),
            state(.home, "zero-words", "Dashboard with zero dictated words"),
            state(.home, "estimated-time-caption", "Estimated-time caption before enough history exists"),
            state(.home, "no-speaking-wpm", "Dashboard without a speaking WPM value"),
            state(.home, "fewer-than-three-dictations", "Chart caption before three dictations"),
            state(.home, "empty-top-apps", "TOP APPS with no destinations"),
            state(.home, "records-absent", "RECORDS section omitted without qualifying history"),
            state(.home, "records-present", "RECORDS section with qualifying history", scene: "console.home.populated"),
            state(.home, "chart-focus", "Keyboard focus on an activity chart"),
            state(.home, "chart-hover", "Pointer hover on a chart bucket", limitation: .pointerHover),
            state(.home, "chart-pin", "Pinned chart bucket"),
            state(.home, "chart-escape-clear", "Escape clears the pinned chart bucket"),
            journey(
                .home,
                "empty-to-populated",
                "First dictation turns the empty dashboard into a populated dashboard"
            ),
            journey(.home, "inspect-and-pin-chart", "Focus, inspect, pin and clear chart data"),

            // Sessions
            state(.sessions, "empty", "No transcript history", scene: "console.sessions.empty"),
            state(.sessions, "populated", "Session list and selected detail", scene: "console.sessions.populated"),
            state(
                .sessions,
                "search-matching",
                "Typed search with matching sessions",
                scene: "console.sessions.search"
            ),
            state(.sessions, "search-no-results", "Typed search with no matching sessions"),
            state(.sessions, "no-selection", "Populated history with no selected session"),
            state(.sessions, "delete-armed", "Delete confirmation armed"),
            state(.sessions, "delete-in-flight", "Delete persistence in flight"),
            state(.sessions, "delete-failure", "Delete persistence failure"),
            state(.sessions, "fix-teach-editor", "Fix and Teach correction editor"),
            state(.sessions, "pending-suggestions", "Pending correction suggestions"),
            state(.sessions, "raw-transcript-metadata", "Raw transcript and timing metadata"),
            journey(.sessions, "search-no-results", "Search reaches the no-match state"),
            journey(.sessions, "search-clear", "Clearing search restores the full list"),
            journey(.sessions, "search-select-copy-delete", "Search, select, copy and delete a session"),
            journey(.sessions, "teach-correction", "Teach a correction from a transcript"),

            // Glossary
            state(.glossary, "empty", "Empty glossary", scene: "console.glossary.empty"),
            state(.glossary, "populated", "Bundled glossary rows", scene: "console.glossary.populated"),
            state(.glossary, "duplicate-rejection", "Duplicate term rejection"),
            state(.glossary, "import-success", "Successful word-list import"),
            state(.glossary, "import-failure", "Failed word-list import"),
            state(.glossary, "manual-add-result", "New manual term row"),
            state(.glossary, "alias-commit", "Committed DETECTED AS edit"),
            state(.glossary, "removal", "Immediate term removal"),
            state(.glossary, "project-chip", "Project-scoped SCOPE chip"),
            state(.glossary, "mixed-policy-protected-source", "Mixed POLICY and non-global SCOPE presentation"),
            journey(.glossary, "add-term", "Add a term through the real fields"),
            journey(.glossary, "edit-alias", "Edit and commit DETECTED AS values for a term"),
            journey(.glossary, "remove-term", "Remove a term through its row action"),
            journey(.glossary, "import-word-list", "Import a glossary word list", limitation: .systemPanel),

            // Refinement
            state(.refinement, "disabled", "Refinement disabled", scene: "console.refinement.off"),
            state(.refinement, "provider-omp", "Oh My Pi provider", scene: "console.refinement.omp"),
            state(
                .refinement,
                "provider-apple-on-device",
                "Apple on-device provider",
                scene: "console.refinement.apple"
            ),
            state(
                .refinement,
                "reachability-unknown",
                "Reachability not checked",
                scene: "console.refinement.omp-login-failed"
            ),
            // No scene renders a probe in flight any more: the only remaining probe
            // spawns `omp`, and a scene that could reach it is a scene that could
            // spawn a subprocess. The flow holds that probe behind a gate instead,
            // which is the stronger reading anyway.
            state(.refinement, "reachability-checking", "Reachability probe in flight"),
            state(.refinement, "reachability-ok", "Reachable provider", scene: "console.refinement.omp"),
            state(.refinement, "reachability-failed", "Provider unreachable", scene: "console.refinement.unreachable"),
            state(
                .refinement,
                "model-catalog-loaded",
                "Model picker offering the loaded catalog",
                scene: "console.refinement.configured"
            ),
            state(.refinement, "model-catalog-loading", "Model catalog load in flight"),
            state(
                .refinement,
                "model-catalog-failed",
                "Model catalog load failed",
                scene: "console.refinement.unreachable"
            ),
            state(
                .refinement,
                "model-catalog-filtered",
                "Model picker narrowed by a typed filter",
                scene: "console.refinement.model-catalog"
            ),
            state(.refinement, "model-selected", "Model chosen out of the catalog"),
            state(
                .refinement,
                "model-defaulted",
                "Empty model field resolved to the provider default",
                scene: "console.refinement.omp"
            ),
            state(.refinement, "omp-status-idle", "OMP status not checked"),
            state(.refinement, "omp-status-checking", "OMP status check in flight"),
            state(.refinement, "omp-status-failed", "OMP status check failed"),
            state(.refinement, "omp-connected", "Connected OMP accounts", scene: "console.refinement.omp"),
            state(.refinement, "omp-no-accounts", "OMP returned no accounts"),
            state(.refinement, "omp-status-unknown", "OMP account status unknown"),
            state(.refinement, "omp-status-stale", "OMP account status stale"),
            state(.refinement, "onboarding-opening", "OMP onboarding opening"),
            state(.refinement, "onboarding-terminal-open", "OMP onboarding terminal open"),
            state(.refinement, "onboarding-cancelled", "OMP onboarding cancelled"),
            state(.refinement, "onboarding-signed-in", "OMP onboarding signed in"),
            state(
                .refinement,
                "onboarding-failed",
                "OMP onboarding failed",
                scene: "console.refinement.omp-login-failed"
            ),
            state(.refinement, "check-success", "Successful CHECK verdict for the current fingerprint"),
            journey(.refinement, "enable-and-check", "Enable refinement and check provider reachability"),
            journey(.refinement, "select-model", "Load the Oh My Pi model catalog, filter it and select a model"),
            journey(.refinement, "connect-omp-provider", "Connect an Oh My Pi provider", limitation: .systemPanel),

            // System
            state(.system, "backend-ready", "Backend ready", scene: "console.system.granted"),
            state(.system, "backend-check-needed", "Backend check needed", scene: "console.system.denied"),
            state(.system, "backend-loading", "Backend probe loading"),
            state(.system, "backend-model-needed", "Backend MODEL NEEDED"),
            state(.system, "microphone-granted", "Microphone granted", scene: "console.system.granted"),
            state(.system, "microphone-denied", "Microphone denied", scene: "console.system.denied"),
            state(.system, "microphone-not-determined", "Microphone WILL PROMPT"),
            state(.system, "capture-active", "Fn/Globe capture active", scene: "console.system.granted"),
            state(.system, "capture-passive", "Fn/Globe capture passive fallback", scene: "console.system.denied"),
            state(.system, "insertion-paste-ready", "Insertion paste ready", scene: "console.system.granted"),
            state(.system, "insertion-copy-only", "Insertion copy-only risk", scene: "console.system.denied"),
            state(.system, "mute-on", "Mute-during-capture enabled", scene: "console.system.granted"),
            state(.system, "muted-now", "System audio currently MUTED NOW"),
            state(.system, "mute-off", "Mute-during-capture disabled"),
            state(
                .system,
                "mute-unavailable",
                "Mute unsupported by the output device",
                scene: "console.system.denied"
            ),
            state(
                .system,
                "clear-history-armed",
                "Clear-history confirmation armed",
                scene: "console.system.confirm"
            ),
            state(.system, "clear-history-in-flight", "Clear-history persistence in flight"),
            state(.system, "clear-history-success", "Clear-history durable success"),
            state(.system, "clear-history-failure", "Clear-history persistence failure"),
            state(.system, "clear-vocabulary-unavailable", "Clear-vocabulary unavailable"),
            state(.system, "clear-vocabulary-confirm", "Clear-vocabulary confirmation armed"),
            state(.system, "clear-vocabulary-in-flight", "Clear-vocabulary persistence in flight"),
            state(.system, "clear-vocabulary-failure", "Clear-vocabulary persistence failure"),
            journey(.system, "recheck-backend", "Re-check backend health and observe readiness"),
            journey(
                .system,
                "repair-permissions",
                "Open privacy settings and return to readiness",
                limitation: .systemPanel
            ),
            journey(.system, "clear-history-confirm", "Confirm clear history and reach empty Sessions"),
            journey(.system, "clear-vocabulary", "Confirm clearing learned vocabulary"),

            // Diagnostics
            state(.diagnostics, "all-clear", "Healthy ALL CLEAR diagnostics", scene: "console.diagnostics.healthy"),
            state(.diagnostics, "backend-error", "Unavailable backend ERROR", scene: "console.diagnostics.unavailable"),
            state(.diagnostics, "backend-not-probed", "Backend NOT PROBED"),
            state(.diagnostics, "backend-model-missing", "Backend MODEL MISSING"),
            state(.diagnostics, "backend-report-copy", "Copied backend-health report"),
            state(.diagnostics, "backend-report-error", "Backend-health report copy error"),

            // Voice
            state(.voice, "default", "Default capture settings", scene: "console.voice.default"),
            state(
                .voice,
                "restart-required",
                "Saved backend awaiting restart",
                scene: "console.voice.restart-required"
            ),
            state(.voice, "invalid-locale", "Rejected speech locale"),
            state(.voice, "backend-selections", "Every saved ASR backend selection"),
            state(.voice, "silence-clamp", "Auto-stop silence parse and clamp rejection"),
            state(
                .voice,
                "auto-stop-disabled",
                "Auto-stop disabled and silence field disabled",
                scene: "console.voice.default"
            ),
            state(.voice, "auto-stop-enabled", "Auto-stop enabled and silence field enabled"),
            state(.voice, "cleanup-on", "Transcript cleanup enabled", scene: "console.voice.default"),
            state(.voice, "cleanup-off", "Transcript cleanup disabled"),
            state(.voice, "restart-unavailable", "Restart unavailable during an active session"),
            journey(.voice, "toggle-cleanup", "Toggle transcript cleanup"),
            journey(.voice, "auto-stop-dependency", "Toggle auto-stop and observe dependent enablement"),
            journey(.voice, "change-capture-settings", "Change backend, locale, auto-stop and cleanup settings"),
            journey(.voice, "restart-backend", "Restart to apply a saved backend"),

            // Menu
            state(.menu, "idle", "Idle menu", scene: "menu.idle"),
            state(.menu, "error", "Start error menu", scene: "menu.error"),
            state(.menu, "completed-transcript", "Completed transcript card", scene: "menu.transcript"),
            state(.menu, "live", "Live recording menu"),
            state(.menu, "working", "Processing menu"),
            state(.menu, "muted-header", "System-audio-muted header"),
            state(.menu, "copy-only-report", "Copy-only delivery report"),
            state(.menu, "failed-report", "Failed delivery report"),
            state(.menu, "copy-feedback", "Transcript copy feedback"),
            state(.menu, "host-chrome", "System MenuBarExtra chrome and dismissal", limitation: .menuHostChrome),
            journey(.menu, "dictation-paste-delivered", "Dictate and paste to an eligible target"),
            journey(
                .menu,
                "dictation-code-editor-skips-refinement",
                "Skip refinement for a configured code-editor target"
            ),
            journey(.menu, "dictation-copy-only", "Dictate to a terminal or secure target and copy only"),
            journey(.menu, "dictation-cancel", "Cancel a live dictation"),
            journey(.menu, "dictation-asr-error", "Surface an ASR failure without delivery"),
            journey(.menu, "copy-transcript", "Copy the last transcript"),
            journey(.menu, "open-console", "Open the console from the menu"),
            journey(.menu, "quit-key-equivalent", "Quit with the Command-Q key equivalent", limitation: .keyEquivalent),

            // Overlay
            state(.overlay, "recording", "Recording waveform and controls", scene: "overlay.panel.recording"),
            // Required rather than snapshot-only, even though `overlay.island.warmup`
            // pins the pixels: the subject is a TRANSITION. The island was blind to this
            // window for as long as liveness was measured off the first tap callback, and
            // only a flow that steps warm-up -> live can prove the label gives way to the
            // meter at the moment real audio arrives.
            state(.overlay, "capture-warmup", "Island readout while the microphone is still starting"),
            state(.overlay, "idle", "Idle overlay trailing slot"),
            state(.overlay, "processing", "Processing overlay label and controls"),
            state(.overlay, "processing-comet", "Processing comet animation", limitation: .perpetualAnimation),
            state(.overlay, "cancel-dictation-label", "Processing-state Cancel dictation label"),
            state(
                .overlay,
                "system-glass-backdrop",
                "Live transparent-island backdrop refraction",
                limitation: .behindWindowGlass
            ),
            journey(.overlay, "recording-controls", "Recording overlay exposes cancel and finish controls"),

            // Atoms
            state(.atoms, "confirm-unavailable", "Unavailable ConfirmActionRow", scene: "atom.properties"),
            state(.atoms, "confirm-collapsed", "Collapsed ConfirmActionRow", scene: "atom.properties"),
            state(.atoms, "confirm-armed", "Armed ConfirmActionRow", scene: "atom.properties"),
            state(.atoms, "confirm-failure", "Failed ConfirmActionRow", scene: "atom.properties"),
            state(.atoms, "confirm-in-flight", "ConfirmActionRow mutation in flight"),
            state(.atoms, "confirm-success", "ConfirmActionRow durable success"),
            state(
                .atoms,
                "property-row-variants",
                "PropertyRow prose, values, paths and statuses",
                scene: "atom.properties"
            ),
            journey(.atoms, "confirm-row", "ConfirmActionRow state machine end to end"),

            // Modern render path (macOS 26)
            //
            // The twelve `os26` scenes used to claim nothing, so the ledger could go green
            // while no requirement referenced the native branch at all. These entries split
            // that branch into the two halves the harness can and cannot see. The content
            // entries are claimed by `os26` scenes and flows: on the native code branch the
            // app's own paint, geometry, control boundaries and accessibility tree are all
            // verified. The `.systemGlassMaterial` entries exist precisely so the ledger
            // RECORDS that nothing verifies the material itself -- `cacheDisplay` does not
            // rasterise SwiftUI `.glassEffect`, so the material is absent from every capture
            // rather than flattened, and `scripts/console_shot.sh` remains the only way to see
            // it composited. A silent ledger would read as coverage.
            state(
                .home,
                "modern-branch-content",
                "Native-branch console content and geometry",
                scene: "console.home.os26"
            ),
            state(
                .home,
                "modern-ground-material",
                "System Liquid Glass window ground",
                limitation: .systemGlassMaterial
            ),
            state(.menu, "modern-branch-content", "Native-branch menu content and geometry", scene: "menu.idle.os26"),
            state(
                .overlay,
                "modern-branch-content",
                "Native-branch island content and geometry",
                scene: "overlay.island.recording.os26"
            ),
            state(
                .overlay,
                "modern-island-material",
                "System Liquid Glass island material",
                limitation: .systemGlassMaterial
            ),
            journey(.home, "modern-rail-navigation", "Navigate the rail on the native render path"),
            journey(.menu, "modern-primary-action", "Drive the menu primary action on the native render path"),
        ]

        private static func surface(_ surface: UISurface, _ title: String, _ sceneID: String) -> UICoverageRequirement {
            UICoverageRequirement(.surface(surface), title, .snapshotOnly(sceneID: sceneID))
        }

        private static func state(
            _ surface: UISurface,
            _ name: String,
            _ title: String,
            scene sceneID: String? = nil,
            limitation: UIKnownLimitation? = nil
        ) -> UICoverageRequirement {
            UICoverageRequirement(.state(surface, name), title, disposition(sceneID: sceneID, limitation: limitation))
        }

        private static func journey(
            _ surface: UISurface,
            _ name: String,
            _ title: String,
            limitation: UIKnownLimitation? = nil
        ) -> UICoverageRequirement {
            UICoverageRequirement(.journey(surface, name), title, disposition(sceneID: nil, limitation: limitation))
        }

        private static func disposition(
            sceneID: String?,
            limitation: UIKnownLimitation?
        ) -> UICoverageDisposition {
            if let sceneID { return .snapshotOnly(sceneID: sceneID) }
            if let limitation { return .notVerifiable(limitation) }
            return .required
        }
    }

#endif

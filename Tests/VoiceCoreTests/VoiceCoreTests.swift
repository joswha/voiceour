import Foundation
import Testing

@testable import VoiceCore

@Suite("VoiceCore")
struct VoiceCoreTests {
    @Test func cleanupPairs() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("fixtures/text/cleanup_pairs.json"))
        let pairs = try JSONDecoder().decode([CleanupPair].self, from: data)
        #expect(pairs.count >= 8)
        for pair in pairs {
            #expect(CleanupEngine.clean(pair.raw, glossary: Settings.defaultGlossary) == pair.expected, "\(pair.name)")
        }
    }

    @Test func cleanupReducesSilentOrFillerOnlyCaptureToEmpty() {
        // The coordinator treats a blank cleaned transcript as "nothing captured" and skips
        // both refinement and insertion. These are the inputs that must reduce to empty.
        #expect(CleanupEngine.clean("", glossary: []).isEmpty)
        #expect(CleanupEngine.clean("   \n\t ", glossary: []).isEmpty)
        #expect(CleanupEngine.clean("um uh um", glossary: []).isEmpty)
        // A genuine word must survive so a real capture is never mistaken for empty.
        #expect(!CleanupEngine.clean("hello", glossary: []).isEmpty)
    }

    /// Filler stripping and repeat collapsing both run before canonicalization, so
    /// a surface taught out of a raw transcript — which carries whatever the
    /// recogniser emitted, hesitations and stutters included — had the very span it
    /// needs in order to match rewritten out from under it. The correction the user
    /// taught then silently did nothing, forever after.
    @Test func cleanupSheltersSurfacesThatSpellTheirOwnDisfluency() {
        func taught(_ canonical: String, _ surface: String) -> ProtectedTerm {
            TermMutation.confirmingAlias(
                surface,
                on: ProtectedTerm(canonical: canonical, spokenAliases: []),
                at: Date(timeIntervalSince1970: 5)
            )
        }

        let hesitation = taught("kubectl", "cube uh cuddle")
        #expect(
            CleanupEngine.clean("please run cube uh cuddle now", glossary: [hesitation]) == "please run kubectl now")

        let wordStutter = taught("kubectl", "cube cube cuddle")
        #expect(CleanupEngine.clean("run cube cube cuddle now", glossary: [wordStutter]) == "run kubectl now")

        let phraseStutter = taught("Ubuntu", "boon to boon to")
        #expect(CleanupEngine.clean("use boon to boon to now", glossary: [phraseStutter]) == "use Ubuntu now")

        // The shelter is span-scoped, not a blanket amnesty: the same disfluency
        // outside an occurrence of the surface is still cleaned away.
        #expect(
            CleanupEngine.clean("uh please run cube uh cuddle uh now", glossary: [hesitation])
                == "please run kubectl now")
        let stutterOutside = taught("Ubuntu", "the the Ubun")
        #expect(
            CleanupEngine.clean("the the use the the Ubun now", glossary: [stutterOutside])
                == "the use Ubuntu now")

        // A glossary with nothing fragile in it leaves both passes exactly as they
        // were: no surface is sheltered, so ordinary disfluency still goes.
        let plain = ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"])
        #expect(CleanupEngine.clean("please uh run cube cuddle now", glossary: [plain]) == "please run kubectl now")
        #expect(CleanupEngine.clean("please please run cube cuddle now", glossary: [plain]) == "please run kubectl now")
    }

    @Test func glossaryCanonicalizationAndTermLock() throws {
        let terms = [ProtectedTerm(canonical: "NSPasteboard", spokenAliases: ["n s pasteboard", "ns paste board"])]
        #expect(Glossary.canonicalize("use n s pasteboard", terms: terms) == "use NSPasteboard")
        #expect(
            Glossary.validateTermLock(original: "use NSPasteboard", candidate: "use NSPasteboard safely", terms: terms))
        #expect(
            !Glossary.validateTermLock(original: "use NSPasteboard", candidate: "use pasteboard safely", terms: terms))
    }

    @Test func refinementGuardsNumbersPreserved() {
        #expect(
            RefinementGuards.numbersPreserved(
                original: "the budget is 15,000 not 50,000", candidate: "The budget is 15,000, not 50,000."))
        #expect(
            !RefinementGuards.numbersPreserved(
                original: "the budget is 15,000 not 50,000", candidate: "The budget is 15,000."))
        #expect(RefinementGuards.numbersPreserved(original: "hello world", candidate: "Hello world."))
        #expect(
            RefinementGuards.numbersPreserved(
                original: "set sample rate to 16000", candidate: "Set the sample rate to 16,000."))
        #expect(RefinementGuards.numbersPreserved(original: "open port 8080", candidate: "Open port 8080."))
    }

    @Test func refinementGuardsPassFaithfulCleanupButRejectDroppedNumbersAndTerms() {
        #expect(
            RefinementGuards.passesFaithfulnessGuards(
                original: "um the budget is 15,000 not 50000",
                candidate: "The budget is 15,000, not 50000.",
                glossary: []
            ))

        #expect(
            !RefinementGuards.passesFaithfulnessGuards(
                original: "meet at 3",
                candidate: "meet at three",
                glossary: []
            ))

        #expect(
            !RefinementGuards.passesFaithfulnessGuards(
                original: "deploy NeuroDock now",
                candidate: "deploy the service now",
                glossary: [ProtectedTerm(canonical: "NeuroDock", spokenAliases: [])]
            ))
    }

    @Test func refinementGuardsRejectOverTwiceLength() {
        #expect(
            !RefinementGuards.passesFaithfulnessGuards(
                original: "hi",
                candidate: "hello!",
                glossary: []
            ))
        #expect(
            RefinementGuards.passesFaithfulnessGuards(
                original: "hi",
                candidate: "Hi.",
                glossary: []
            ))
    }

    @Test func safetyClassifier() {
        let ordinary = TargetFocusInspection.inspected(role: nil, subrole: nil)
        #expect(SafetyClassifier.classify(bundleId: "com.apple.Terminal", focus: ordinary) == .terminal)
        #expect(SafetyClassifier.classify(bundleId: "com.jetbrains.intellij", focus: ordinary) == .codeEditor)
        #expect(SafetyClassifier.classify(bundleId: "com.1password.1password", focus: ordinary) == .secure)
        #expect(SafetyClassifier.classify(bundleId: "com.apple.TextEdit", focus: ordinary) == .normalText)
        #expect(
            SafetyClassifier.classify(
                bundleId: "com.apple.TextEdit",
                focus: .inspected(role: nil, subrole: "AXSecureTextField")
            ) == .secure
        )
        #expect(SafetyClassifier.classify(bundleId: nil, focus: ordinary) == .unknownRisky)
    }

    /// An unreadable focus is absent information, not evidence of an ordinary
    /// field, so it must not resolve to the one class that permits pasting. A
    /// known bundle whose own class is already restrictive keeps that class.
    @Test func unavailableFocusInspectionFailsClosed() {
        #expect(SafetyClassifier.classify(bundleId: "com.apple.TextEdit", focus: .unavailable) == .unknownRisky)
        #expect(SafetyClassifier.classify(bundleId: nil, focus: .unavailable) == .unknownRisky)
        #expect(SafetyClassifier.classify(bundleId: "com.apple.Terminal", focus: .unavailable) == .terminal)
        #expect(SafetyClassifier.classify(bundleId: "com.1password.1password", focus: .unavailable) == .secure)
    }

    /// The counterpart: an app that answers "nothing is focused" has told us
    /// something, and nothing focused cannot be a password field taking
    /// keystrokes. Every restrictive class still outranks it.
    @Test func noFocusedElementClassifiesByBundleRatherThanFailingClosed() {
        #expect(SafetyClassifier.classify(bundleId: "com.hnc.Discord", focus: .noFocusedElement) == .normalText)
        #expect(SafetyClassifier.classify(bundleId: nil, focus: .noFocusedElement) == .unknownRisky)
        #expect(SafetyClassifier.classify(bundleId: "com.apple.Terminal", focus: .noFocusedElement) == .terminal)
        #expect(SafetyClassifier.classify(bundleId: "com.microsoft.VSCode", focus: .noFocusedElement) == .codeEditor)
        #expect(
            SafetyClassifier.classify(bundleId: "com.1password.1password", focus: .noFocusedElement) == .secure)
        #expect(
            SafetyClassifier.classify(
                bundleId: "com.hnc.Discord",
                focus: .noFocusedElement,
                secureInputActive: true
            ) == .secure
        )
    }

    @Test func insertionOutcomeSummaryMapsPublicOutcomesToExactPresentation() {
        let cases: [(name: String, outcome: InsertionOutcome, expected: InsertionOutcomeSummary)] = [
            (
                "paste attempted",
                .pasteAttempted,
                InsertionOutcomeSummary(
                    label: "PASTE ATTEMPTED",
                    detail: "Command-V was posted to the captured target.",
                    severity: .ok
                )
            ),
            (
                "copied terminal target",
                .copiedOnly(reason: "target_terminal"),
                InsertionOutcomeSummary(
                    label: "COPIED ONLY",
                    detail: "Terminal target protected.",
                    severity: .warn
                )
            ),
            (
                "copied missing synthetic paste permission",
                .copiedOnly(reason: "synth_paste_permission"),
                InsertionOutcomeSummary(
                    label: "COPIED ONLY",
                    detail: "Accessibility or synthetic paste permission missing.",
                    severity: .warn
                )
            ),
            (
                "failed event post",
                .failed(reason: "post_event_failed"),
                InsertionOutcomeSummary(
                    label: "PASTE FAILED",
                    detail: "Command-V event post failed.",
                    severity: .crit
                )
            ),
        ]

        for testCase in cases {
            #expect(testCase.outcome.summary == testCase.expected, "\(testCase.name) summary")
        }
    }

    @Test func refinerResolvedDerivesEveryDirectProviderBaseURLAndModel() {
        let directCases: [(RefinerProvider, String, String)] = [
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-flash-lite"),
            (.openAI, "https://api.openai.com/v1", "gpt-4.1-nano"),
            (.openRouter, "https://openrouter.ai/api/v1", "meta-llama/llama-3.3-70b-instruct"),
        ]

        for (provider, expectedBaseURL, expectedModel) in directCases {
            let settings = Settings(refinerProvider: provider)
            #expect(RefinerResolved.baseURL(settings) == expectedBaseURL)
            #expect(RefinerResolved.model(settings) == expectedModel)
        }

        let custom = Settings(
            refinerProvider: .custom,
            refinerBaseURL: "https://custom.example/v1",
            refinerModel: "custom-model"
        )
        #expect(RefinerResolved.baseURL(custom) == "https://custom.example/v1")
        #expect(RefinerResolved.model(custom) == "custom-model")
        #expect(RefinerResolved.baseURL(Settings(refinerProvider: .custom)) == "")
        #expect(
            RefinerResolved.model(Settings(refinerProvider: .openAI, refinerModel: "override-model"))
                == "override-model")
    }

    @Test func refinerReadinessTruthTable() {
        #expect(RefinerReadiness.evaluate(settings: Settings(refinerEnabled: false), hasKey: true) == .disabled)
        #expect(
            RefinerReadiness.evaluate(settings: Settings(refinerEnabled: true, refinerProvider: .custom), hasKey: false)
                == .needsBaseURL)
        #expect(
            RefinerReadiness.evaluate(
                settings: Settings(
                    refinerEnabled: true,
                    refinerProvider: .custom,
                    refinerBaseURL: "https://custom.example/v1",
                    refinerModel: ""
                ),
                hasKey: false
            ) == .needsModel)
        #expect(
            RefinerReadiness.evaluate(
                settings: Settings(
                    refinerEnabled: true,
                    refinerProvider: .custom,
                    refinerBaseURL: "https://custom.example/v1",
                    refinerModel: "local-model"
                ),
                hasKey: false
            ) == .ready)

        for provider in [RefinerProvider.gemini, .openAI, .openRouter] {
            let settings = Settings(refinerEnabled: true, refinerProvider: provider)
            #expect(RefinerReadiness.evaluate(settings: settings, hasKey: false) == .needsKey)
            #expect(RefinerReadiness.evaluate(settings: settings, hasKey: true) == .ready)
        }

        // Apple On-Device needs no key, base URL, or model choice; runtime
        // availability is the refiner's concern, not readiness's.
        #expect(
            RefinerReadiness.evaluate(
                settings: Settings(refinerEnabled: true, refinerProvider: .appleOnDevice), hasKey: false) == .ready)
        #expect(
            RefinerReadiness.evaluate(
                settings: Settings(refinerEnabled: false, refinerProvider: .appleOnDevice), hasKey: false) == .disabled)
    }

    @Test func settingsDecodesProviderDefaultAndRoundTrips() throws {
        let legacyJSON = """
            {
              "cleanup_enabled": false,
              "asr_backend": "mlx",
              "model_id": "legacy-model-id",
              "model_revision": "legacy-revision",
              "refiner_enabled": true,
              "refiner_base_url": "https://legacy.example/v1",
              "refiner_model": "legacy-model",
              "refiner_timeout_ms": 2500
            }
            """

        let legacySettings = try JSONDecoder().decode(Settings.self, from: Data(legacyJSON.utf8))
        #expect(legacySettings.refinerProvider == .gemini)
        #expect(legacySettings.cleanupEnabled == false)
        #expect(legacySettings.asrBackend == "mlx")
        #expect(legacySettings.refinerBaseURL == "https://legacy.example/v1")
        #expect(legacySettings.refinerModel == "legacy-model")
        #expect(legacySettings.autoStopEnabled == false)
        #expect(legacySettings.autoStopSilenceMs == 2500)
        #expect(legacySettings.speechLocale == "en_US")
        #expect(legacySettings.automaticTermCorrectionEnabled == false)
        #expect(legacySettings.decoderBiasEnabled == false)

        let encoded = try JSONEncoder().encode(
            Settings(
                refinerProvider: .openAI,
                autoStopEnabled: true,
                autoStopSilenceMs: 1800,
                speechLocale: "de_DE"
            ))
        let decoded = try JSONDecoder().decode(Settings.self, from: encoded)

        #expect(decoded.refinerProvider == .openAI)
        #expect(decoded.autoStopEnabled)
        #expect(decoded.autoStopSilenceMs == 1800)
        #expect(decoded.speechLocale == "de_DE")
    }

    /// A build before the settings pane committed on submit persisted
    /// `speech_locale` on every keystroke, so `" "` reached disk and
    /// `SpeechTranscriber` then refused every request — the Apple backend was
    /// permanently unusable with no in-app way back. Decode heals it.
    @Test func settingsDecodeHealsAnUnresolvableSpeechLocale() throws {
        func locale(in json: String) throws -> String {
            try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).speechLocale
        }

        #expect(try locale(in: #"{"speech_locale": " "}"#) == "en_US")
        #expect(try locale(in: #"{"speech_locale": ""}"#) == "en_US")
        #expect(try locale(in: #"{"speech_locale": "de_DE_bogus"}"#) == "en_US")
        // A resolvable identifier survives, in either spelling.
        #expect(try locale(in: #"{"speech_locale": "de_DE"}"#) == "de_DE")
        #expect(try locale(in: #"{"speech_locale": "ja-JP"}"#) == "ja_JP")
    }

    @Test func speechLocaleCanonicalAcceptsBothSubtagSpellings() {
        #expect(SpeechLocale.canonical("en-GB") == "en_GB")
        #expect(SpeechLocale.canonical("  fr_FR  ") == "fr_FR")
        #expect(SpeechLocale.canonical(" ") == nil)
        #expect(SpeechLocale.canonical("not_a_locale") == nil)
    }

    @Test func legacySettingsJSONMissingMuteFieldsEnablesBuiltInOutputMute() throws {
        let legacyJSON = """
            {
              "cleanup_enabled": false,
              "asr_backend": "mlx"
            }
            """

        let settings = try JSONDecoder().decode(Settings.self, from: Data(legacyJSON.utf8))

        #expect(settings.cleanupEnabled == false)
        #expect(settings.asrBackend == "mlx")
        #expect(settings.muteSystemAudioDuringCapture == true)
        #expect(settings.muteScope == .builtInOutputOnly)
    }

    @Test func settingsStoreRoundTripPersistsCustomMuteValues() throws {
        let fixture = temporarySettingsFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = SettingsStore(url: fixture.url)
        let settings = Settings(
            asrBackend: "mlx",
            muteSystemAudioDuringCapture: false,
            muteScope: .allOutputs
        )

        try store.save(settings)
        let loaded = try store.load()

        #expect(loaded.asrBackend == "mlx")
        #expect(loaded.muteSystemAudioDuringCapture == false)
        #expect(loaded.muteScope == .allOutputs)
    }

    @Test func settingsStoreRestrictsPermissionsAfterEveryAtomicSave() throws {
        let fixture = temporarySettingsFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fileManager = FileManager.default
        let store = SettingsStore(url: fixture.url)

        try store.save(Settings(asrBackend: "fake"))
        #expect(try posixPermissions(at: fixture.directory) == 0o700)
        #expect(try posixPermissions(at: fixture.url) == 0o600)

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.url.path)
        try store.save(Settings(asrBackend: "mlx"))

        #expect(try posixPermissions(at: fixture.directory) == 0o700)
        #expect(try posixPermissions(at: fixture.url) == 0o600)
    }

    @Test func legacyRecentSessionJSONMissingOutcomeDecodesNil() throws {
        let legacyJSON = """
            {
              "id": "00000000-0000-0000-0000-000000000101",
              "createdAt": 42,
              "text": "legacy transcript"
            }
            """

        let session = try JSONDecoder().decode(RecentSession.self, from: Data(legacyJSON.utf8))

        #expect(session.id == UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        #expect(session.createdAt == Date(timeIntervalSinceReferenceDate: 42))
        #expect(session.text == "legacy transcript")
        #expect(session.mutedDuringCapture == false)
        #expect(session.outcome == nil)
        #expect(session.stages == nil)
    }

    @Test func recentSessionStageTimingsRoundTrip() throws {
        let stages = SessionStageTimings(
            captureMs: 2_400,
            asrMs: 125,
            insertMs: 18,
            startLatencyMs: 42,
            asrPath: "streamed",
            stopReleaseToInsertionOutcomeMs: 211,
            asrBackendId: "parakeet-mlx",
            asrLoadMs: 7,
            asrInferenceMs: 103,
            asrTotalMs: 110
        )
        let session = RecentSession(text: "observed transcript", stages: stages)

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RecentSession.self, from: encoded)

        #expect(decoded.stages == stages)
    }

    @Test func legacySessionStageTimingsDecodeNewTelemetryAsNil() throws {
        let legacyJSON = """
            {
              "id": "00000000-0000-0000-0000-000000000102",
              "createdAt": 42,
              "text": "legacy timed transcript",
              "stages": {
                "captureMs": 2400,
                "asrMs": 125,
                "insertMs": 18,
                "startLatencyMs": 42,
                "asrPath": "streamed"
              }
            }
            """

        let session = try JSONDecoder().decode(RecentSession.self, from: Data(legacyJSON.utf8))
        let stages = try #require(session.stages)

        #expect(stages.stopReleaseToInsertionOutcomeMs == nil)
        #expect(stages.asrBackendId == nil)
        #expect(stages.asrLoadMs == nil)
        #expect(stages.asrInferenceMs == nil)
        #expect(stages.asrTotalMs == nil)
    }

    @Test func recentSessionStoreLoadMissingFileReturnsEmptyHistory() throws {
        let fixture = temporaryRecentSessionFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = RecentSessionStore(url: fixture.url, limit: 5)

        #expect(try store.load() == [])
    }

    @Test func recentSessionStoreSaveRoundTripsTextFlagsAndOutcomeNewestFirst() throws {
        let fixture = temporaryRecentSessionFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentSessionStore(url: fixture.url, limit: 5)
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_120)
        let exactText = "  First line\nSecond \"quoted\" line\t☕️  "
        let outcome = RecentSessionOutcomeMetadata(
            disposition: .copiedOnly,
            reason: "target_terminal",
            targetSafety: .terminal,
            targetBundleId: "com.apple.Terminal"
        )

        try store.save([
            RecentSession(createdAt: older, text: "older session", mutedDuringCapture: false),
            RecentSession(createdAt: newer, text: exactText, mutedDuringCapture: true, outcome: outcome),
        ])
        let reloaded = try store.load()

        #expect(reloaded.map(\.text) == [exactText, "older session"])
        #expect(reloaded.map(\.createdAt) == [newer, older])
        #expect(reloaded.map(\.mutedDuringCapture) == [true, false])
        #expect(reloaded.first?.outcome == outcome)
        #expect(reloaded.last?.outcome == nil)
    }

    @Test func recentSessionStoreRestrictsPermissionsAfterEveryAtomicSave() throws {
        let fixture = temporaryRecentSessionFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fileManager = FileManager.default
        let store = RecentSessionStore(url: fixture.url, limit: 5)

        try store.save([RecentSession(text: "first private transcript")])
        #expect(try posixPermissions(at: fixture.directory) == 0o700)
        #expect(try posixPermissions(at: fixture.url) == 0o600)

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.url.path)
        try store.save([RecentSession(text: "replacement private transcript")])

        #expect(try posixPermissions(at: fixture.directory) == 0o700)
        #expect(try posixPermissions(at: fixture.url) == 0o600)
    }

    @Test func recentSessionWordCountUsesWhitespaceDelimitedWords() {
        let cases: [(name: String, text: String, expectedWordCount: Int)] = [
            ("whitespace only", " \n\t  \r\n", 0),
            ("mixed whitespace", "alpha beta\n gamma\t\tdelta\n\nemoji ☕️", 6),
        ]

        for testCase in cases {
            let session = RecentSession(text: testCase.text)

            #expect(session.wordCount == testCase.expectedWordCount, "\(testCase.name) word count")
        }
    }

    @Test func recentSessionStoreReloadsPersistedSessionsNewestFirst() throws {
        let fixture = temporaryRecentSessionFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentSessionStore(url: fixture.url, limit: 5)
        let oldest = RecentSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, createdAt: Date(timeIntervalSince1970: 1),
            text: "oldest")
        let newest = RecentSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, createdAt: Date(timeIntervalSince1970: 3),
            text: "newest")
        let middle = RecentSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, createdAt: Date(timeIntervalSince1970: 2),
            text: "middle")

        try store.save([oldest, newest, middle])

        #expect(try store.load() == [newest, middle, oldest])
    }

    @Test func recentSessionStoreDefaultLimitRetainsMoreThanOldMenuCap() throws {
        let fixture = temporaryRecentSessionFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentSessionStore(url: fixture.url)
        let base = Date(timeIntervalSince1970: 1_700_003_000)
        let sessions = (0..<25).map { offset in
            RecentSession(
                createdAt: base.addingTimeInterval(Double(offset)),
                text: "default session \(offset)"
            )
        }

        try store.save(sessions)
        let reloaded = try store.load()

        #expect(reloaded.count == 25)
        #expect(reloaded.first?.text == "default session 24")
        #expect(reloaded.last?.text == "default session 0")
    }

    @Test func recentSessionStoreSnapshotNormalizesNewestFirstAndCapsAtLimit() throws {
        let fixture = temporaryRecentSessionFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentSessionStore(url: fixture.url, limit: 500)
        let base = Date(timeIntervalSince1970: 1_700_010_000)
        let sessions = (0..<525).map { offset in
            RecentSession(
                createdAt: base.addingTimeInterval(Double(offset)),
                text: "snapshot session \(offset)"
            )
        }

        let normalized = store.normalized(sessions)
        try store.save(sessions)

        #expect(normalized.count == 500)
        #expect(normalized.first?.text == "snapshot session 524")
        #expect(normalized.last?.text == "snapshot session 25")
        #expect(try store.load() == normalized)
    }

    @Test func recentSessionStoreEmptySnapshotRemovesExistingFile() throws {
        let fixture = temporaryRecentSessionFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentSessionStore(url: fixture.url, limit: 5)
        try store.save([RecentSession(text: "saved")])
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))

        try store.save([])

        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(try store.load() == [])
    }

    @Test func recentSessionStoreClearRemovesFileAndLeavesEmptyHistory() throws {
        let fixture = temporaryRecentSessionFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentSessionStore(url: fixture.url, limit: 5)

        try store.save([RecentSession(createdAt: Date(timeIntervalSince1970: 1_700_002_000), text: "saved session")])
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))

        try store.clear()

        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(try store.load() == [])

        try store.clear()
        #expect(try store.load() == [])
    }

    @Test func noOpSystemAudioMuterNeverReportsAudioMuted() async {
        let muter: SystemAudioMuting = NoOpSystemAudioMuter()

        #expect(await muter.mute(scope: .builtInOutputOnly) == false)
        #expect(await muter.mute(scope: .allOutputs) == false)
        await muter.restore()
    }

    @Test func applicationSupportPathsDeriveFromTheVoiceOourBase() {
        let base = URL.voiceOourSupportDirectory
        #expect(base.lastPathComponent == "VoiceOour")
        #expect(SettingsStore.defaultURL.deletingLastPathComponent().path == base.path)
        #expect(SettingsStore.defaultURL.lastPathComponent == "settings.json")
        #expect(RecentSessionStore.defaultURL.deletingLastPathComponent().path == base.path)
        #expect(RecentSessionStore.defaultURL.lastPathComponent == "recent-sessions.json")
    }

    private func temporarySettingsFile() -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCoreTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("settings.json"))
    }

    private func temporaryRecentSessionFile() -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCoreTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("recent-sessions.json"))
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

}

func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private struct CleanupPair: Decodable {
    var name: String
    var raw: String
    var expected: String
}

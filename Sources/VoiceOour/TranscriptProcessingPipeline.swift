import Foundation
import VoiceCore
import VoiceMac

/// The stop pipeline: ASR, deterministic cleanup, term authorization, cloud
/// vocabulary filtering, refinement, insertion, and session telemetry. It
/// consumes the single per-utterance `VocabularySnapshot` compiled before ASR.
///
/// Extracted from `DictationCoordinator` as an extension rather than a separate
/// collaborator because every member here publishes to the coordinator's
/// main-actor UI state. Members that were `private` are now `internal`: Swift
/// scopes `private` to one file, so an extension in another file cannot see them.
@MainActor
extension DictationCoordinator {
    /// Maps retriever candidates over `transcript` into suggestion-only entries.
    /// Skips spans that already read as their canonical and de-duplicates by
    /// term + surface so the pending list stays free of overlapping repeats.
    nonisolated static func suggestions(in transcript: String, snapshot: VocabularySnapshot) -> [TermSuggestion] {
        let characters = Array(transcript)
        var results: [TermSuggestion] = []
        var seen = Set<String>()
        for candidate in CandidateRetriever.retrieve(in: transcript, snapshot: snapshot) {
            if let suggestion = suggestion(for: candidate, characters: characters, seen: &seen) {
                results.append(suggestion)
            }
        }
        return results
    }

    nonisolated static func suggestion(
        for candidate: TermCandidate,
        characters: [Character],
        seen: inout Set<String>
    ) -> TermSuggestion? {
        let end = candidate.spanStart + candidate.spanLength
        guard candidate.spanLength > 0,
            candidate.spanStart >= 0,
            end <= characters.count
        else { return nil }
        let misheard = String(characters[candidate.spanStart..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !misheard.isEmpty else { return nil }
        // A span that already reads as the canonical needs no correction.
        if misheard.lowercased() == candidate.canonical.lowercased() { return nil }
        // Never offer a rule the glossary would refuse to apply. Accepting a
        // suggestion writes an unconditional rewrite of every future utterance,
        // so a surface that cannot generalize is not a correction the user can
        // meaningfully consent to — offering it produced four live digit rules
        // in one 22-second click-through.
        guard Glossary.aliasCanGeneralize(misheard, canonical: candidate.canonical) else { return nil }
        let dedupeKey = "\(candidate.termId)|\(misheard.lowercased())"
        guard seen.insert(dedupeKey).inserted else { return nil }
        return TermSuggestion(
            id: "\(candidate.termId)|\(candidate.spanStart)|\(candidate.spanLength)",
            misheard: misheard,
            canonical: candidate.canonical,
            termId: candidate.termId
        )
    }

    /// Maps `.suggest` authorizer decisions over `text` into suggestion-only
    /// entries, mirroring `suggestions(in:snapshot:)`: skips spans that already
    /// read as their canonical and de-duplicates by term + surface. `decisions`
    /// and `candidates` are positionally aligned.
    static func suggestions(
        from decisions: [AuthorizerDecision],
        candidates: [TermCandidate],
        in text: String
    ) -> [TermSuggestion] {
        let characters = Array(text)
        var results: [TermSuggestion] = []
        var seen = Set<String>()
        for (index, candidate) in candidates.enumerated() {
            guard index < decisions.count else { break }
            guard case .suggest = decisions[index] else { continue }
            if let suggestion = suggestion(for: candidate, characters: characters, seen: &seen) {
                results.append(suggestion)
            }
        }
        return results
    }

    static func automaticTermDecisions(
        in text: String,
        snapshot: VocabularySnapshot,
        result: ASRResult
    ) -> (candidates: [TermCandidate], decisions: [AuthorizerDecision]) {
        let candidates = CandidateRetriever.retrieve(in: text, snapshot: snapshot)
        let decisions = candidates.map { candidate in
            RiskAuthorizer.decide(
                authorizerEvidence(
                    for: candidate,
                    amongst: candidates,
                    in: text,
                    result: result
                ),
                automaticEnabled: true
            )
        }
        return (candidates, decisions)
    }

    /// Builds the independent evidence the `RiskAuthorizer` weighs for one
    /// candidate, drawn entirely from the ASR `result`: calibrated transcript
    /// confidence and mode, whether the candidate's canonical or misheard surface
    /// appears in the acoustic n-best, decoder-bias state, and the per-span
    /// candidate score gap used as the runner-up margin.
    static func authorizerEvidence(
        for candidate: TermCandidate,
        amongst candidates: [TermCandidate],
        in text: String,
        result: ASRResult
    ) -> AuthorizerEvidence {
        let characters = Array(text)
        let start = candidate.spanStart
        let end = candidate.spanStart + candidate.spanLength
        let surface: String? =
            (start >= 0 && candidate.spanLength > 0 && end <= characters.count)
            ? String(characters[start..<end])
            : nil

        // Independent acoustic support: the canonical or the misheard surface must
        // appear in an n-best hypothesis. Decoder-biased support is vetoed by the
        // authorizer separately, so the two are never conflated.
        let canonicalKey = candidate.canonical.lowercased()
        let surfaceKey = surface?.lowercased()
        var appearsInNBest = false
        for hypothesis in result.hypotheses ?? [] {
            let hypothesisText = hypothesis.text.lowercased()
            if hypothesisText.contains(canonicalKey)
                || (surfaceKey.map { hypothesisText.contains($0) } ?? false)
            {
                appearsInNBest = true
                break
            }
        }

        // Per-span runner-up margin: the winning candidate for a span beats its
        // closest rival by this gap. A lone candidate has no rival (measured from
        // zero); a tie yields a zero gap, which the authorizer reads as ambiguous.
        let signal = blendedSignal(candidate)
        var bestRival = 0.0
        for other in candidates
        where other.termId != candidate.termId
            && other.spanStart == candidate.spanStart
            && other.spanLength == candidate.spanLength
        {
            bestRival = max(bestRival, blendedSignal(other))
        }

        return AuthorizerEvidence(
            candidate: candidate,
            termRisk: TermRiskClassifier.risk(for: candidate.canonical),
            transcriptConfidence: result.transcript.confidence,
            confidenceMode: result.transcript.confidenceMode,
            appearsInNBest: appearsInNBest,
            decoderBiasEnabled: result.decoder?.biasEnabled,
            runnerUpMargin: signal - bestRival
        )
    }

    /// Blended acoustic/textual signal on the same weights the authorizer and
    /// retriever use, so the per-span margin lands on a consistent scale.
    static func blendedSignal(_ candidate: TermCandidate) -> Double {
        0.6 * candidate.phoneSimilarity + 0.4 * candidate.textSimilarity
    }

    /// Upper bound on decoder-bias phrases.
    ///
    /// One snapshot per utterance means one cap: this is the same 100 the
    /// vocabulary compiler enforces and that `docs/architecture.md` documents,
    /// and it stays well under the sidecar's own rejection limit.
    static let biasPhraseCap = 100

    /// Bias phrases for one compiled snapshot: canonical plus user aliases,
    /// de-duplicated case-insensitively and bounded.
    static func biasPhrases(from snapshot: VocabularySnapshot) -> [ASRBiasPhrase] {
        var phrases: [ASRBiasPhrase] = []
        var seen = Set<String>()
        for term in snapshot.terms {
            let aliases = Glossary.userAliases(for: term)
            for surface in [term.renderedCanonical] + aliases {
                let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard seen.insert(trimmed.lowercased()).inserted else { continue }
                phrases.append(ASRBiasPhrase(text: trimmed))
                if phrases.count >= biasPhraseCap { return phrases }
            }
        }
        return phrases
    }

    func removeTemporaryAudio(_ audioURL: inout URL?) {
        guard let url = audioURL else { return }
        do {
            try temporaryAudioRemover(url)
            audioURL = nil
        } catch {
            do {
                try temporaryAudioRemover(url)
                audioURL = nil
            } catch {
                // Leave local ownership intact when both attempts fail.
            }
        }
    }

    func processStop(generation: AsyncGenerationGate.Token, stopReleaseStarted: Date) async {
        // Foundation Models prewarming is most effective shortly before use.
        // Run it independently so recorder finalization and ASR provide the
        // lead time without adding an await to the post-ASR critical path.
        // A disabled or incomplete configuration must not start a backend.
        if settings.refinerEnabled, refinerReadiness.isReady {
            let warmBinding = currentRefinerBinding()
            Task { await warmBinding.backend.warmUp() }
        }
        var audioURL: URL?
        defer { removeTemporaryAudio(&audioURL) }
        // The mute resolves concurrently with recorder start; await the pending
        // decision so the recorded session captures the true muted state even
        // when stop outruns the mute's flag publication.
        let mutedDuringCapture = await pendingMuteResult?.value ?? false
        let totalSpan = StopPath.signposter.beginInterval(StopPath.Stage.total)
        defer { StopPath.signposter.endInterval(StopPath.Stage.total, totalSpan) }
        do {
            try ensureCurrentProcessing(generation)
            stopInputMetering()
            state = .finalizingAudio
            let finalizeSpan = StopPath.signposter.beginInterval(StopPath.Stage.finalizeAudio)
            let audio = try await recorder.stop()
            StopPath.signposter.endInterval(StopPath.Stage.finalizeAudio, finalizeSpan)
            audioURL = audio.url
            // Audio comes back the moment capture ends, not when transcription
            // finishes. Every other restore path is a safety net for a throw that
            // beat this point; the restore is idempotent per session. Started, not
            // awaited: its 120 ms volume fade does not gate transcription, and
            // awaiting it here delayed every ASR call on a muted session by longer
            // than the inference itself.
            beginSystemAudioRestore()
            try ensureCurrentProcessing(generation)

            // No-speech gate, before inference rather than after. ASR models do not
            // return nothing for noise, they invent: 8 s of quiet dither measured
            // here yields "Esta mañana está en su mayor mayor mayor." from the
            // default backend and "嗯。" from ark-0.6b. `shouldSkipTranscript` cannot
            // catch that because it is not whitespace, and this app pastes it into
            // the user's document. Placing the gate here also saves the inference.
            if DictationPolicy.capturedSpeechIsAbsent(
                telemetry: audio.telemetry,
                isSynthetic: audio.isSynthetic
            ) {
                state = .cancelled
                clearCapturedTargetAndRefreshLabel()
                resetToIdleWhenInactive(generation: generation)
                return
            }

            // One vocabulary snapshot per utterance, compiled here and held for
            // the rest of the stop path. `settings.glossary` and
            // `activeProjectId` stay mutable across the ASR await, so compiling
            // again later let an edit mid-transcription make the ASR bias list,
            // the cleanup glossary and the refiner's terms disagree.
            let vocabularySpan = StopPath.signposter.beginInterval(StopPath.Stage.vocabulary)
            let snapshot = target ?? tracker.snapshot()
            let vocabulary = VocabularyCompiler.compile(
                persistent: settings.glossary,
                ephemeral: [],
                capturedBundleId: snapshot.bundleId,
                activeProjectId: activeProjectId
            )
            let biasPhrases = settings.decoderBiasEnabled ? Self.biasPhrases(from: vocabulary) : []
            StopPath.signposter.endInterval(StopPath.Stage.vocabulary, vocabularySpan)

            state = .transcribing
            let asrStarted = runtime.now()
            let result = try await asr.transcribe(audio, timeoutMs: 30_000, biasPhrases: biasPhrases)
            let asrMs = Int(runtime.now().timeIntervalSince(asrStarted) * 1000)
            try ensureCurrentProcessing(generation)
            removeTemporaryAudio(&audioURL)

            state = .cleaning
            let cleanupSpan = StopPath.signposter.beginInterval(StopPath.Stage.cleanup)
            let rawTranscript = result.transcript.text
            let activeTerms = vocabulary.terms
            let composed = LiteralComposition.apply(rawTranscript)
            var deterministic =
                settings.cleanupEnabled ? CleanupEngine.clean(composed, glossary: activeTerms) : composed
            lastTranscript = deterministic
            StopPath.signposter.endInterval(StopPath.Stage.cleanup, cleanupSpan)
            try ensureCurrentProcessing(generation)

            if DictationPolicy.shouldSkipTranscript(deterministic) {
                state = .cancelled
                clearCapturedTargetAndRefreshLabel()
                resetToIdleWhenInactive(generation: generation)
                return
            }

            // Term-correction authorization. Off by default: when the flag is
            // disabled this block is skipped entirely and the suggestion-only path
            // below stays byte-for-byte unchanged. When enabled, the authorizer may
            // automatically replace only independent (non-decoder-biased,
            // n-best-supported), above-threshold candidates BEFORE refinement, and
            // those canonicals are locked so the refiner cannot alter them.
            var authorizedSuggestions: [TermSuggestion]?
            var lockedCanonicals: Set<String> = []
            if settings.automaticTermCorrectionEnabled {
                let scanned = deterministic
                let automatic = Self.automaticTermDecisions(
                    in: scanned,
                    snapshot: vocabulary,
                    result: result
                )
                let replaced = TermDecisionApplier.apply(
                    decisions: automatic.decisions,
                    candidates: automatic.candidates,
                    terms: activeTerms,
                    to: scanned
                )
                if replaced != scanned {
                    deterministic = replaced
                    lastTranscript = deterministic
                }
                // Lock only what actually landed. An authorized replacement the
                // applier dropped (a stale span, an unresolvable id) leaves a
                // canonical the text does not contain, and locking that would
                // discard every refinement for a correction never made.
                for (index, decision) in automatic.decisions.enumerated()
                where index < automatic.candidates.count {
                    if case .replace(let termId) = decision,
                        let term = activeTerms.first(where: { $0.termId == termId }),
                        deterministic.contains(term.renderedCanonical)
                    {
                        lockedCanonicals.insert(term.renderedCanonical)
                    }
                }
                authorizedSuggestions = Self.suggestions(
                    from: automatic.decisions,
                    candidates: automatic.candidates,
                    in: scanned
                )
            }

            let readiness = refinerReadiness
            let configuredIdentity = RefinerIdentity(settings: settings)
            var finalText: String
            var trace: RefinementTrace
            let style = DictationPolicy.refinementStyle(forBundleId: snapshot.bundleId)
            switch DictationPolicy.refinementDecision(
                refinerEnabled: settings.refinerEnabled,
                refinerConfigured: readiness.isReady,
                targetSafety: snapshot.safety,
                providerReadiness: readiness,
                assessment: DictationPolicy.assessTranscript(rawTranscript, glossary: activeTerms)
            ) {
            case .refine:
                let binding = currentRefinerBinding()
                let providerTerms =
                    binding.identity.isCloud
                    ? RefinerPrivacy.cloudEligible(activeTerms)
                    : activeTerms
                let providerInput: String
                if binding.identity.isCloud {
                    if providerTerms.count == activeTerms.count {
                        providerInput = deterministic
                    } else {
                        let cloudBase =
                            settings.cleanupEnabled
                            ? CleanupEngine.clean(composed, glossary: providerTerms)
                            : composed
                        if settings.automaticTermCorrectionEnabled, !providerTerms.isEmpty {
                            let cloudVocabulary = VocabularySnapshot(
                                terms: providerTerms,
                                ephemeral: [],
                                capturedBundleId: vocabulary.capturedBundleId,
                                generatedAt: vocabulary.generatedAt
                            )
                            let automatic = Self.automaticTermDecisions(
                                in: cloudBase,
                                snapshot: cloudVocabulary,
                                result: result
                            )
                            providerInput = TermDecisionApplier.apply(
                                decisions: automatic.decisions,
                                candidates: automatic.candidates,
                                terms: providerTerms,
                                to: cloudBase
                            )
                        } else {
                            providerInput = cloudBase
                        }
                    }
                } else {
                    providerInput = deterministic
                }

                state = .refining
                let started = runtime.now()
                let outcome = await binding.backend.refine(
                    providerInput,
                    glossary: activeTerms,
                    safety: snapshot.safety,
                    style: style
                )
                let latencyMs = Int(runtime.now().timeIntervalSince(started) * 1000)
                // Read straight after the call, before anything else can refine:
                // this is the model that produced THIS candidate, which the
                // configured label cannot say for the on-device provider.
                let modelIdentity = binding.backend.lastModelIdentity()
                switch outcome {
                case .refined(let text):
                    finalText =
                        binding.identity.isCloud
                        ? Glossary.canonicalize(text, terms: activeTerms)
                        : text
                    trace = RefinementTrace(
                        kind: .refined,
                        provider: binding.identity.label,
                        model: modelIdentity,
                        reason: nil,
                        latencyMs: latencyMs
                    )
                case .fellBack(_, let reason):
                    finalText = deterministic
                    trace = RefinementTrace(
                        kind: .fellBack,
                        provider: binding.identity.label,
                        model: modelIdentity,
                        reason: reason,
                        latencyMs: latencyMs
                    )
                    applyRefinerReachabilityFailureIfCurrent(reason, binding: binding)
                case .skipped(let reason):
                    finalText = deterministic
                    trace = RefinementTrace(
                        kind: .skipped,
                        provider: binding.identity.label,
                        reason: reason,
                        latencyMs: latencyMs
                    )
                }
            case .skip(let reason):
                finalText = deterministic
                trace = RefinementTrace(
                    kind: .skipped,
                    provider: configuredIdentity.label,
                    reason: reason,
                    latencyMs: nil
                )
            }
            try ensureCurrentProcessing(generation)
            // Refiner lock: an automatic replacement must survive refinement. If
            // the refiner dropped a locked canonical, fall back to the
            // deterministic text that already carries the correction.
            if !lockedCanonicals.isEmpty,
                !lockedCanonicals.allSatisfy({ finalText.contains($0) })
            {
                finalText = deterministic
                if trace.kind == .refined {
                    trace.kind = .fellBack
                    trace.reason = "guard_rejected"
                }
            }
            lastTranscript = finalText
            let stages = SessionStageTimings(
                captureMs: audio.meta.durationMs,
                asrMs: asrMs,
                insertMs: nil,
                startLatencyMs: recorder.lastStartLatencyMs(),
                asrPath: asr.lastTranscriptionPath(),
                asrBackendId: result.backendId,
                asrLoadMs: result.timingsMs.load,
                asrInferenceMs: result.timingsMs.inference,
                asrTotalMs: result.timingsMs.total
            )
            let journalSpan = StopPath.signposter.beginInterval(StopPath.Stage.journal)
            let sessionID = await recordRecentSession(
                text: finalText,
                rawTranscript: rawTranscript,
                refinement: trace,
                mutedDuringCapture: mutedDuringCapture,
                stages: stages
            )
            StopPath.signposter.endInterval(StopPath.Stage.journal, journalSpan)
            try ensureCurrentProcessing(generation)

            state = .readyToInsert
            let insertionTarget = tracker.snapshot()
            updateTargetLabel(for: insertionTarget)
            let insertStarted = runtime.now()
            let insertSpan = StopPath.signposter.beginInterval(StopPath.Stage.insert)
            let outcome = await inserter.insert(finalText, into: insertionTarget)
            StopPath.signposter.endInterval(StopPath.Stage.insert, insertSpan)
            let insertMs = Int(runtime.now().timeIntervalSince(insertStarted) * 1000)
            let stopReleaseToInsertionOutcomeMs = Int(runtime.now().timeIntervalSince(stopReleaseStarted) * 1000)
            // Publish before the durable checkpoint so the UI sees the outcome
            // while a snapshot write is still in flight, but only for the
            // session still on screen: a cancel that raced the insertion must
            // not resurrect an outcome, even though the completed side effect
            // below is still recorded in history.
            let outcomeIsCurrent = !Task.isCancelled && generations.isCurrent(generation)
            if outcomeIsCurrent {
                lastOutcome = outcome
            }
            await updateRecentSessionOutcome(
                id: sessionID,
                outcome: RecentSessionOutcomeMetadata(outcome: outcome, target: insertionTarget),
                insertMs: insertMs,
                stopReleaseToInsertionOutcomeMs: stopReleaseToInsertionOutcomeMs
            )
            try ensureCurrentProcessing(generation)
            // Suggestion-only: propose term corrections for the completed
            // dictation. Never edits finalText or the inserted target. The
            // fallback scan is O(spans x terms x aliases) (~0.4-2.9 s at 40
            // words on a 57-term glossary), so it runs off the main actor and
            // commits only if no newer session has started: start() takes a new
            // .recordingStart token, and cancel/error paths invalidate .processing.
            if let authorizedSuggestions {
                pendingSuggestions = authorizedSuggestions
            } else {
                let spawnStartToken = generations.currentToken(.recordingStart)
                suggestionTask?.cancel()
                suggestionTask = Task.detached(priority: .utility) { [weak self, finalText, vocabulary] in
                    let suggestions = Self.suggestions(in: finalText, snapshot: vocabulary)
                    await MainActor.run { [weak self] in
                        guard let self,
                            !Task.isCancelled,
                            self.generations.isCurrent(generation),
                            self.generations.isCurrent(spawnStartToken)
                        else { return }
                        self.pendingSuggestions = suggestions
                    }
                }
            }
            state = DictationPolicy.sessionState(for: outcome)
            clearCapturedTargetAndRefreshLabel()
            resetToIdleWhenInactive(generation: generation)
        } catch is CancellationError {
            await restoreSystemAudioIfNeeded()
            guard generations.isCurrent(generation) else { return }
            state = .cancelled
            clearCapturedTargetAndRefreshLabel()
            resetToIdleWhenInactive(generation: generation)
        } catch let error as ASRErrorMessage {
            await restoreSystemAudioIfNeeded()
            guard generations.isCurrent(generation) else { return }
            state = .error(error.code)
            errorMessage = error.detail
            clearCapturedTargetAndRefreshLabel()
        } catch {
            await restoreSystemAudioIfNeeded()
            guard generations.isCurrent(generation) else { return }
            state = .error(.internalError)
            errorMessage = error.localizedDescription
            clearCapturedTargetAndRefreshLabel()
        }
    }
}

import Foundation
import VoiceCore
import VoiceMac

/// The stop pipeline: ASR, deterministic cleanup, term suggestion retrieval,
/// insertion, and session telemetry. It consumes the single per-utterance
/// `VocabularySnapshot` compiled before ASR.
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

    func finishCancelledProcessing(generation: AsyncGenerationGate.Token) {
        state = .cancelled
        clearCapturedTargetAndRefreshLabel()
        resetToIdleWhenInactive(generation: generation)
    }

    /// Ends a failed or cancelled stop path.
    ///
    /// `discardRecording()` is called here, on the one path that owns the recorder
    /// for this session. A throw before `recorder.stop()` returned — a cancellation
    /// that landed mid-finalize, a capture that failed — otherwise leaves the
    /// microphone session running and its WAV on disk with nothing left to claim
    /// them. It is idempotent and identity-checked, so calling it after a
    /// successful stop is a no-op.
    func finishFailedProcessing(
        generation: AsyncGenerationGate.Token,
        state failedState: SessionState,
        failure: UserFacingDictationFailure? = nil
    ) async {
        await recorder.discardRecording()
        await restoreSystemAudioIfNeeded()
        guard generations.isCurrent(generation) else { return }
        if failedState == .cancelled {
            finishCancelledProcessing(generation: generation)
            return
        }
        state = failedState
        lastFailure = failure
        errorMessage = failure?.cause
        clearCapturedTargetAndRefreshLabel()
    }

    func processStop(
        generation: AsyncGenerationGate.Token,
        stopReleaseStarted: Date,
        trigger: DictationCoordinator.StopTrigger = .manual
    ) async {
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
                finishCancelledProcessing(generation: generation)
                return
            }

            // One vocabulary snapshot per utterance, compiled here and held for
            // the rest of the stop path. `settings.glossary` and
            // `activeProjectId` stay mutable across the ASR await, so compiling
            // again later let an edit mid-transcription change the glossary
            // cleanup and suggestion retrieval disagree about.
            let vocabularySpan = StopPath.signposter.beginInterval(StopPath.Stage.vocabulary)
            let snapshot = target ?? tracker.snapshot()
            let vocabulary = VocabularyCompiler.compile(
                persistent: settings.glossary,
                ephemeral: [],
                capturedBundleId: snapshot.bundleId,
                activeProjectId: activeProjectId
            )
            StopPath.signposter.endInterval(StopPath.Stage.vocabulary, vocabularySpan)

            state = .transcribing
            let asrStarted = runtime.now()
            let result = try await asr.transcribe(audio, timeoutMs: 30_000)
            let asrMs = Int(runtime.now().timeIntervalSince(asrStarted) * 1000)
            try ensureCurrentProcessing(generation)
            removeTemporaryAudio(&audioURL)

            state = .cleaning
            let cleanupSpan = StopPath.signposter.beginInterval(StopPath.Stage.cleanup)
            let rawTranscript = result.transcript.text
            let activeTerms = vocabulary.terms
            let composed = LiteralComposition.apply(rawTranscript)
            let deterministic =
                settings.cleanupEnabled ? CleanupEngine.clean(composed, glossary: activeTerms) : composed
            lastTranscript = deterministic
            StopPath.signposter.endInterval(StopPath.Stage.cleanup, cleanupSpan)
            try ensureCurrentProcessing(generation)

            if DictationPolicy.shouldSkipTranscript(deterministic) {
                finishCancelledProcessing(generation: generation)
                return
            }

            let finalText = deterministic
            try ensureCurrentProcessing(generation)
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
            // The decoder's least sure word, from the RAW transcript's words —
            // cleanup may have rewritten them, and the evidence must name what
            // the model actually emitted. Unconditional: the score itself
            // conveys strength, so no display threshold is applied here.
            let leastConfidentWord = (result.transcript.segments?.flatMap { $0.words ?? [] } ?? [])
                .compactMap { word in word.confidence.map { (text: word.text, score: $0) } }
                .min { $0.score < $1.score }
                .map { LeastConfidentWord(text: $0.text, score: $0.score) }
            // The delivery target decides whether this dictation is recorded at all,
            // so it is snapshotted before the journal rather than just before the
            // paste. `PasteboardInserter` re-checks target identity itself before it
            // writes the pasteboard and again before posting Cmd-V, so an app switch
            // inside this window still degrades to copy-only rather than pasting
            // somewhere unintended.
            state = .readyToInsert
            let insertionTarget = tracker.snapshot()
            updateTargetLabel(for: insertionTarget)

            // A secure field is the one target whose text must not outlive the
            // dictation. The transcript is still delivered — concealed, copy-only —
            // but nothing about it is written to history: a password the user spoke
            // into a password field would otherwise sit in plain text in
            // recent-sessions.json, searchable, until 500 dictations evicted it.
            let sessionID: RecentSession.ID?
            if insertionTarget.safety == .secure {
                sessionID = nil
            } else {
                let journalSpan = StopPath.signposter.beginInterval(StopPath.Stage.journal)
                sessionID = await recordRecentSession(
                    text: finalText,
                    rawTranscript: rawTranscript,
                    mutedDuringCapture: mutedDuringCapture,
                    stages: stages,
                    leastConfidentWord: leastConfidentWord
                )
                StopPath.signposter.endInterval(StopPath.Stage.journal, journalSpan)
                try ensureCurrentProcessing(generation)
                // Counted exactly where the transcript is journaled, so the two
                // durable records agree about what happened: a secure target
                // reaches neither, and every delivery disposition reaches both —
                // the words were spoken and transcribed whether or not the paste
                // landed.
                if sessionID != nil {
                    await recordDictationStats(
                        words: WordCount.count(in: finalText),
                        seconds: Double(audio.meta.durationMs) / 1000
                    )
                    try ensureCurrentProcessing(generation)
                }
            }

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
            state = DictationPolicy.sessionState(for: outcome)
            clearCapturedTargetAndRefreshLabel()
            resetToIdleWhenInactive(generation: generation)
        } catch is CancellationError {
            await finishFailedProcessing(
                generation: generation,
                state: .cancelled
            )
        } catch let error as ASRErrorMessage {
            // The wire's code names a mechanism; the user reads a sentence and a
            // place to go. One translation, so the menu and any later surface
            // cannot describe the same failure differently.
            await finishFailedProcessing(
                generation: generation,
                state: .error(error.code),
                failure: UserFacingDictationFailure(
                    code: error.code,
                    detail: error.detail,
                    acquisitionFraction: modelDownloadFraction
                )
            )
        } catch let error as RecorderError {
            let reason: String
            if case .captureFailed(let latched) = error {
                reason = latched
            } else {
                reason = error.localizedDescription
            }
            await finishFailedProcessing(
                generation: generation,
                state: .error(.internalError),
                failure: .captureFailed(reason: reason)
            )
        } catch {
            await finishFailedProcessing(
                generation: generation,
                state: .error(.internalError),
                failure: UserFacingDictationFailure(
                    code: .internalError,
                    detail: error.localizedDescription
                )
            )
        }
    }
}

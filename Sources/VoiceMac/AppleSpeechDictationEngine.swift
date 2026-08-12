import AVFoundation
import Foundation
import VoiceCore

#if canImport(Speech)
    import Speech

    /// Fused recorder + ASR for the `apple` backend (macOS 26+): transcribes WHILE
    /// recording so stop-to-text is near-instant.
    ///
    /// The coordinator injects one instance as both `AudioRecording` and
    /// `ASRClienting`; its protocol contracts are unchanged. Internally each
    /// dictation is one `StreamingSession`: an AVAudioEngine input tap converts
    /// microphone buffers once to 16 kHz mono Int16 (the app's WAV format, which is
    /// also `SpeechAnalyzer.bestAvailableAudioFormat` on this OS) and feeds them to
    /// BOTH an incrementally written WAV file and a live SpeechAnalyzer input
    /// stream. `stop()` drains the converter, hands the finished WAV to the caller
    /// (existing cleanup invariants keep working), and starts finalization;
    /// `transcribe()` then awaits the already-running finalization — measured
    /// 67-285ms after stop versus 220-900ms for batch file transcription. Any
    /// streaming failure falls back to batch transcription of the recorded file,
    /// and foreign files (bench, tests) always take the batch path.
    ///
    /// Sessions are strictly one-shot: probing showed a SpeechAnalyzer cannot be
    /// restarted after finish, so every dictation builds a fresh analyzer;
    /// `SpeechAnalyzer.Options(modelRetention: .processLifetime)` keeps the system
    /// model warm across sessions.
    @available(macOS 26.0, *)
    public final class AppleSpeechDictationEngine: NSObject, AudioRecording, ASRClienting, @unchecked Sendable {
        private let locale: Locale
        private let batch: AppleSpeechASRClient
        private let lock = NSLock()
        private var session: StreamingSession?
        private var lastStartLatency: Int?
        private var lastTranscriptionPathValue: String?

        public init(locale: Locale = Locale(identifier: "en_US")) {
            self.locale = locale
            batch = AppleSpeechASRClient(locale: locale)
            super.init()
        }

        // MARK: - AudioRecording

        public func start() throws {
            lock.lock()
            if session != nil {
                lock.unlock()
                throw RecorderError.alreadyRecording
            }
            lock.unlock()

            let fresh = try StreamingSession(locale: locale)
            lock.lock()
            // start() is only called from the main-actor coordinator, but stay defensive.
            if session != nil {
                lock.unlock()
                Task { await fresh.teardown(deleteFile: true) }
                throw RecorderError.alreadyRecording
            }
            session = fresh
            lock.unlock()
        }

        public func stop() async throws -> RecordedAudio {
            guard let active = currentSession() else { throw RecorderError.notRecording }
            do {
                let audio = try await active.stopCapture()
                setLastStartLatency(active.startLatencyMs())
                return audio
            } catch {
                setLastStartLatency(active.startLatencyMs())
                // A capture that cannot produce a file is unrecoverable: drop the session.
                await active.teardown(deleteFile: true)
                clearSession(active)
                throw error
            }
        }

        public func discardRecording() async {
            guard let active = currentSession() else { return }
            clearSession(active)
            await active.teardown(deleteFile: true)
        }

        public func currentInputLevel() -> Float? {
            currentSession()?.currentLevel()
        }

        public func lastStartLatencyMs() -> Int? {
            lock.withLock { lastStartLatency }
        }

        public func captureIsLive() -> Bool {
            currentSession()?.hasReceivedAudio() ?? false
        }

        // MARK: - ASRClienting

        public func warmUp() async {
            await batch.warmUp()
            await StreamingSession.prewarmModel(locale: locale)
        }

        public func health(timeoutMs: Int) async throws -> ASRBackendHealth {
            try await batch.health(timeoutMs: timeoutMs)
        }

        public func lastTranscriptionPath() -> String? {
            lock.withLock { lastTranscriptionPathValue }
        }

        public func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
            guard let finalizing = currentSession(), finalizing.owns(url: audio.url) else {
                // Foreign file (bench, tests) or no live session: plain batch path.
                let result = try await batch.transcribe(audio, timeoutMs: timeoutMs)
                setLastTranscriptionPath("batch")
                return result
            }
            clearSession(finalizing)

            // A failed route-change recovery leaves the analyzer holding only
            // pre-switch audio; its finalization would look valid ("streamed")
            // while silently truncating the utterance. Serve the WAV via batch.
            if finalizing.routeRecoveryDidFail() {
                await finalizing.teardown(deleteFile: false)
                let result = try await batch.transcribe(audio, timeoutMs: timeoutMs)
                setLastTranscriptionPath("batch")
                return result
            }

            do {
                let streamed = try await finalizing.awaitFinalText(timeoutMs: timeoutMs)
                let trimmed = streamed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let result = ASRResult(
                        requestId: UUID().uuidString,
                        backendId: AppleSpeechASRClient.backendId,
                        modelId: "apple/SpeechTranscriber/\(streamed.locale)",
                        modelRevision: ProcessInfo.processInfo.operatingSystemVersionString,
                        transcript: ASRTranscript(
                            text: trimmed, language: streamed.language, segments: streamed.segments,
                            confidence: streamed.confidence, confidenceMode: streamed.confidenceMode),
                        timingsMs: ASRTimings(load: 0, inference: streamed.finalizeMs, total: streamed.finalizeMs)
                    )
                    setLastTranscriptionPath("streamed")
                    return result
                }
            } catch is CancellationError {
                await finalizing.teardown(deleteFile: false)
                throw CancellationError()
            } catch {
                // Fall through to batch below.
            }

            // Streamed finalization failed, hung, or produced nothing: the WAV is
            // complete on disk, so recover through the proven batch path.
            await finalizing.teardown(deleteFile: false)
            let result = try await batch.transcribe(audio, timeoutMs: timeoutMs)
            setLastTranscriptionPath("batch")
            return result
        }

        // MARK: - Session bookkeeping

        private func currentSession() -> StreamingSession? {
            lock.lock()
            defer { lock.unlock() }
            return session
        }

        private func clearSession(_ candidate: StreamingSession) {
            lock.lock()
            if session === candidate {
                session = nil
            }
            lock.unlock()
        }

        private func setLastStartLatency(_ latency: Int?) {
            lock.withLock { lastStartLatency = latency }
        }

        private func setLastTranscriptionPath(_ path: String) {
            lock.withLock { lastTranscriptionPathValue = path }
        }
    }

    /// One dictation's capture + streaming transcription. Single-use.
    @available(macOS 26.0, *)
    private final class StreamingSession: @unchecked Sendable {
        private enum Phase {
            case capturing
            case finalizing
            case done
        }

        static let sampleRate = 16_000

        private let locale: Locale

        private let lock = NSLock()
        private var phase: Phase = .capturing
        private var routeRecoveryFailed = false

        private let capture: MicrophoneCapture
        private let fileURL: URL
        private var file: AVAudioFile?
        private var converter: CaptureConverter?
        private let targetFormat: AVAudioFormat
        private var writtenFrames: Int64 = 0
        private let initStartedAt: Date

        private let analyzer: SpeechAnalyzer
        private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        private let analyzerStartTask: Task<Void, Error>
        private let collectTask: Task<AppleSpeechTranscript, Error>
        private var finalizeTask: Task<AppleSpeechTranscript, Error>?
        private var stoppedAt: Date?

        init(locale: Locale) throws {
            let initStartedAt = Date()
            self.initStartedAt = initStartedAt
            self.locale = locale

            // `file=` in the breakdown below is this bracket: the whole capture-file
            // construction, target format included. The format is an in-memory
            // `AVAudioFormat` init, so the number is still dominated by the temporary
            // directory and the `AVAudioFile` open.
            let fileSetupStartedAt = Date()
            let wav = try CaptureWAVTarget(sampleRate: Self.sampleRate)
            let fileSetupDuration = Date().timeIntervalSince(fileSetupStartedAt)
            targetFormat = wav.format
            fileURL = wav.url
            file = wav.file

            let analyzerConstructionStartedAt = Date()
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: AppleSpeechTranscriptBuilder.attributeOptions
            )
            analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
            )
            let analyzerConstructionDuration = Date().timeIntervalSince(analyzerConstructionStartedAt)

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
            inputContinuation = continuation

            collectTask = Task {
                // Volatile (non-final) results are intentionally ignored: the
                // reporting options match the measured FAST A/B configuration,
                // but only finalized text is ever surfaced or pasted.
                var builder = AppleSpeechTranscriptBuilder()
                for try await result in transcriber.results where result.isFinal {
                    builder.add(result)
                }
                return builder.finish()
            }

            let analyzerHandoffStartedAt = Date()
            let analyzer = analyzer
            analyzerStartTask = Task {
                // Streaming requires the analyzer's preferred format to match what we
                // feed it. Measured to be 16 kHz mono Int16 on macOS 26; if a future
                // OS changes it, buffers are still written to the WAV and transcribe()
                // recovers through the batch path.
                if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                    best.sampleRate != Double(Self.sampleRate) || best.channelCount != 1
                {
                    throw makeASRError(.internalError, requestId: nil, detail: "unexpected analyzer format \(best)")
                }
                try await analyzer.start(inputSequence: stream)
            }
            let analyzerDuration =
                analyzerConstructionDuration
                + Date().timeIntervalSince(analyzerHandoffStartedAt)

            // Pinned away from a Bluetooth headset whenever one is the system default
            // input: that microphone delivers digital zeros for ~1.4 s while the HFP/SCO
            // link negotiates, and streaming those zeros into the analyzer is how the
            // opening words of an utterance used to disappear.
            let capture: MicrophoneCapture
            do {
                capture = try MicrophoneCapture(
                    preferredDeviceUID: CoreAudioInputDevice.preferredCaptureUID())
            } catch {
                file = nil
                try? FileManager.default.removeItem(at: fileURL)
                inputContinuation.finish()
                collectTask.cancel()
                analyzerStartTask.cancel()
                throw error
            }
            self.capture = capture
            // Built here but fed lazily: the converter's source is whatever format the
            // first buffer actually arrives in, not a format guessed before capture.
            converter = CaptureConverter(targetFormat: wav.format)

            let captureStartStartedAt = Date()
            capture.start { [weak self] buffer in
                self?.consume(buffer: buffer)
            }
            let captureStartDuration = Date().timeIntervalSince(captureStartStartedAt)

            let totalDuration = Date().timeIntervalSince(initStartedAt)
            let breakdown = String(
                format:
                    "VoiceOour: session init breakdown total=%.1fms capture_start=%.1fms analyzer=%.1fms file=%.1fms device=%@%@\n",
                totalDuration * 1_000,
                captureStartDuration * 1_000,
                analyzerDuration * 1_000,
                fileSetupDuration * 1_000,
                capture.source.name,
                capture.source.isRedirected ? " (redirected)" : ""
            )
            try? FileHandle.standardError.write(contentsOf: Data(breakdown.utf8))
        }

        // MARK: - Capture path (audio thread)

        private func consume(buffer: AVAudioPCMBuffer) {
            lock.lock()
            guard phase == .capturing, let converter else {
                lock.unlock()
                return
            }
            let chunks = converter.convert(buffer)
            // A route change now arrives as a new format on the buffer itself, and the
            // converter follows it. The only unrecoverable case is a format no converter
            // can be built for: from there the analyzer holds pre-change audio only and
            // would finalize a plausible but silently truncated utterance, so latch it
            // and let transcribe() serve the WAV through the batch path.
            if converter.didFailToFollowFormat {
                routeRecoveryFailed = true
            }
            for chunk in chunks {
                writeAndYield(chunk)
            }
            lock.unlock()
        }

        /// Must be called with `lock` held.
        private func writeAndYield(_ buffer: AVAudioPCMBuffer) {
            guard buffer.frameLength > 0 else { return }
            if let file {
                do {
                    try file.write(from: buffer)
                    writtenFrames += Int64(buffer.frameLength)
                } catch {
                    // Keep streaming even if the fallback file fails; the streamed
                    // result is primary and transcribe() validates non-empty text.
                }
            }
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        }

        func routeRecoveryDidFail() -> Bool {
            lock.withLock { routeRecoveryFailed }
        }

        // MARK: - Lifecycle

        func stopCapture() async throws -> RecordedAudio {
            let wasCapturing: Bool = lock.withLock {
                guard phase == .capturing else { return false }
                phase = .finalizing
                return true
            }
            guard wasCapturing else { throw RecorderError.notRecording }

            capture.stop()

            let frames: Int64 = lock.withLock {
                if let converter {
                    // Drain sample-rate-conversion remainders; skipping this truncates
                    // the tail of the utterance (measured up to 220 frames on live input).
                    for chunk in converter.drain() {
                        writeAndYield(chunk)
                    }
                }
                converter = nil
                if let file {
                    file.close()
                }
                file = nil
                stoppedAt = Date()
                return writtenFrames
            }

            inputContinuation.finish()

            let analyzer = analyzer
            let analyzerStartTask = analyzerStartTask
            let collectTask = collectTask
            let finalize = Task { () throws -> AppleSpeechTranscript in
                try await analyzerStartTask.value
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await collectTask.value
            }
            lock.withLock { finalizeTask = finalize }

            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            guard FileManager.default.fileExists(atPath: fileURL.path), frames > 0 else {
                throw RecorderError.outputUnavailable
            }
            let durationMs = max(0, Int(Date().timeIntervalSince(initStartedAt) * 1000))
            return RecordedAudio(
                url: fileURL,
                meta: ASRAudioMeta(
                    path: fileURL.path,
                    format: "wav",
                    sampleRateHz: Self.sampleRate,
                    channels: 1,
                    durationMs: durationMs,
                    byteCount: byteCount
                )
            )
        }

        struct StreamedText {
            let text: String
            let segments: [ASRSegment]?
            let confidence: Double?
            let confidenceMode: ASRConfidenceMode?
            let finalizeMs: Int
            let locale: String
            let language: String?
        }

        func awaitFinalText(timeoutMs: Int) async throws -> StreamedText {
            let pending: (finalize: Task<AppleSpeechTranscript, Error>, reference: Date)? = lock.withLock {
                guard phase == .finalizing, let finalize = finalizeTask else { return nil }
                return (finalize, stoppedAt ?? Date())
            }
            guard let pending else {
                throw makeASRError(.internalError, requestId: nil, detail: "no finalization in flight")
            }
            let finalize = pending.finalize
            let reference = pending.reference

            let transcript: AppleSpeechTranscript = try await withThrowingTaskGroup(of: AppleSpeechTranscript.self) {
                group in
                group.addTask { try await finalize.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 1)) * 1_000_000)
                    throw makeASRError(.timeout, requestId: nil, detail: "streamed finalization timed out")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw makeASRError(.internalError, requestId: nil, detail: "no finalization result")
                }
                return result
            }

            lock.withLock { phase = .done }
            let finalizeMs = max(0, Int(Date().timeIntervalSince(reference) * 1000))
            return StreamedText(
                text: transcript.text,
                segments: transcript.segments,
                confidence: transcript.confidence,
                confidenceMode: transcript.confidenceMode,
                finalizeMs: finalizeMs,
                locale: locale.identifier(.bcp47),
                language: locale.language.languageCode?.identifier
            )
        }

        func owns(url: URL) -> Bool {
            url.standardizedFileURL == fileURL.standardizedFileURL
        }

        // All three delegate to the capture, which is the only thing that sees raw
        // buffers. `capture` outlives `stop()` precisely so the coordinator can still
        // read the start latency after the WAV has been handed over.
        func currentLevel() -> Float? {
            capture.currentLevel()
        }

        func startLatencyMs() -> Int? {
            capture.startLatencyMs()
        }

        func hasReceivedAudio() -> Bool {
            capture.hasReceivedAudio()
        }

        /// Idempotent teardown for cancel/error paths. `deleteFile` is true only
        /// while the engine still owns the WAV (before `stopCapture` returned it).
        func teardown(deleteFile: Bool) async {
            let finalize: Task<AppleSpeechTranscript, Error>? = lock.withLock {
                phase = .done
                converter = nil
                if let file {
                    file.close()
                }
                file = nil
                let finalize = finalizeTask
                finalizeTask = nil
                return finalize
            }

            // Unconditional: MicrophoneCapture.stop() is idempotent, so this no longer
            // needs to know whether the session was still capturing.
            capture.stop()
            inputContinuation.finish()
            finalize?.cancel()
            collectTask.cancel()
            analyzerStartTask.cancel()
            await analyzer.cancelAndFinishNow()
            if deleteFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        /// Loads speech assets and model resources ahead of the first dictation.
        static func prewarmModel(locale: Locale) async {
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .processLifetime)
            )
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)
            try? await analyzer.prepareToAnalyze(in: format)
            await analyzer.cancelAndFinishNow()
        }

    }
#endif

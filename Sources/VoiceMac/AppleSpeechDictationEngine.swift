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
        private var meterLevel: Float = 0
        private var routeRecoveryFailed = false

        private let engine = AVAudioEngine()
        private let fileURL: URL
        private var file: AVAudioFile?
        private var converter: AVAudioConverter?
        private let targetFormat: AVAudioFormat
        private var writtenFrames: Int64 = 0
        private let initStartedAt: Date
        private var firstBufferAt: Date?
        private var routeChangeObserver: NSObjectProtocol?
        private var tapInstalled = false

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
            guard
                let target = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(Self.sampleRate),
                    channels: 1,
                    interleaved: true
                )
            else {
                throw RecorderError.fileMissing
            }
            targetFormat = target

            let fileSetupStartedAt = Date()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "voiceoour", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            // commonFormat/interleaved set the file's PROCESSING format to match the
            // converter output; the default Float32 processing format makes
            // write(from:) abort on Int16 buffers (CoreAudio CAVerboseAbort).
            file = try AVAudioFile(
                forWriting: fileURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ],
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let fileSetupDuration = Date().timeIntervalSince(fileSetupStartedAt)

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

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
                file = nil
                try? FileManager.default.removeItem(at: fileURL)
                inputContinuation.finish()
                collectTask.cancel()
                analyzerStartTask.cancel()
                throw RecorderError.fileMissing
            }
            self.converter = converter

            let tapInstallStartedAt = Date()
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.consume(buffer: buffer)
            }
            tapInstalled = true
            let tapInstallDuration = Date().timeIntervalSince(tapInstallStartedAt)
            engine.prepare()
            let engineStartStartedAt = Date()
            let engineStartDuration: TimeInterval
            do {
                try engine.start()
                engineStartDuration = Date().timeIntervalSince(engineStartStartedAt)
            } catch {
                input.removeTap(onBus: 0)
                tapInstalled = false
                file = nil
                try? FileManager.default.removeItem(at: fileURL)
                inputContinuation.finish()
                collectTask.cancel()
                analyzerStartTask.cancel()
                throw error
            }

            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.handleRouteChange()
            }

            let totalDuration = Date().timeIntervalSince(initStartedAt)
            let breakdown = String(
                format:
                    "VoiceOour: session init breakdown total=%.1fms engine_start=%.1fms analyzer=%.1fms file=%.1fms tap=%.1fms\n",
                totalDuration * 1_000,
                engineStartDuration * 1_000,
                analyzerDuration * 1_000,
                fileSetupDuration * 1_000,
                tapInstallDuration * 1_000
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
            if firstBufferAt == nil {
                firstBufferAt = Date()
            }
            let converted = Self.convert(buffer: buffer, with: converter, to: targetFormat, endOfStream: false)
            for chunk in converted {
                writeAndYield(chunk)
            }
            meterLevel = Self.rmsLevel(of: buffer)
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

        private func handleRouteChange() {
            do {
                try lock.withLock {
                    guard phase == .capturing else { return }

                    let input = engine.inputNode
                    if tapInstalled {
                        input.removeTap(onBus: 0)
                        tapInstalled = false
                    }
                    if let converter {
                        // Preserve the old converter's resampling tail before replacing it.
                        for chunk in Self.convert(buffer: nil, with: converter, to: targetFormat, endOfStream: true) {
                            writeAndYield(chunk)
                        }
                    }
                    converter = nil

                    let inputFormat = input.outputFormat(forBus: 0)
                    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                        let replacement = AVAudioConverter(from: inputFormat, to: targetFormat)
                    else {
                        throw RecorderError.fileMissing
                    }
                    converter = replacement
                    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                        self?.consume(buffer: buffer)
                    }
                    tapInstalled = true
                    if !engine.isRunning {
                        engine.prepare()
                        try engine.start()
                    }
                }
            } catch {
                // Streaming is unusable from here on: the analyzer only has
                // pre-switch audio. Flag it so transcribe() takes the batch path.
                lock.withLock { routeRecoveryFailed = true }
                let detail = String(describing: error).replacingOccurrences(of: "\n", with: " ")
                let message = "VoiceOour: audio route change recovery failed: \(detail)\n"
                try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            }
        }

        func routeRecoveryDidFail() -> Bool {
            lock.withLock { routeRecoveryFailed }
        }

        // MARK: - Lifecycle

        func stopCapture() async throws -> RecordedAudio {
            let transition: (observer: NSObjectProtocol?, removeTap: Bool)? = lock.withLock {
                guard phase == .capturing else { return nil }
                phase = .finalizing
                let observer = routeChangeObserver
                routeChangeObserver = nil
                let removeTap = tapInstalled
                tapInstalled = false
                return (observer, removeTap)
            }
            guard let transition else { throw RecorderError.notRecording }

            if let observer = transition.observer {
                NotificationCenter.default.removeObserver(observer)
            }
            if transition.removeTap {
                engine.inputNode.removeTap(onBus: 0)
            }
            engine.stop()

            let frames: Int64 = lock.withLock {
                if let converter {
                    // Drain sample-rate-conversion remainders; skipping this truncates
                    // the tail of the utterance (measured up to 220 frames on live input).
                    for chunk in Self.convert(buffer: nil, with: converter, to: targetFormat, endOfStream: true) {
                        writeAndYield(chunk)
                    }
                }
                converter = nil
                if let file {
                    file.close()
                }
                file = nil
                meterLevel = 0
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
                throw RecorderError.fileMissing
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

        func currentLevel() -> Float? {
            lock.lock()
            defer { lock.unlock() }
            guard phase == .capturing else { return nil }
            return meterLevel
        }

        func startLatencyMs() -> Int? {
            lock.withLock {
                guard let firstBufferAt else { return nil }
                return max(0, Int(firstBufferAt.timeIntervalSince(initStartedAt) * 1000))
            }
        }

        func hasReceivedAudio() -> Bool {
            lock.withLock { firstBufferAt != nil }
        }

        /// Idempotent teardown for cancel/error paths. `deleteFile` is true only
        /// while the engine still owns the WAV (before `stopCapture` returned it).
        func teardown(deleteFile: Bool) async {
            let cleanup:
                (
                    wasCapturing: Bool,
                    removeTap: Bool,
                    observer: NSObjectProtocol?,
                    finalize: Task<AppleSpeechTranscript, Error>?
                ) = lock.withLock {
                    let wasCapturing = phase == .capturing
                    phase = .done
                    converter = nil
                    if let file {
                        file.close()
                    }
                    file = nil
                    meterLevel = 0
                    let removeTap = tapInstalled
                    tapInstalled = false
                    let observer = routeChangeObserver
                    routeChangeObserver = nil
                    let finalize = finalizeTask
                    finalizeTask = nil
                    return (wasCapturing, removeTap, observer, finalize)
                }

            if let observer = cleanup.observer {
                NotificationCenter.default.removeObserver(observer)
            }
            if cleanup.removeTap {
                engine.inputNode.removeTap(onBus: 0)
            }
            if cleanup.wasCapturing {
                engine.stop()
            }
            inputContinuation.finish()
            cleanup.finalize?.cancel()
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

        // MARK: - Audio helpers

        /// Converts one tap buffer (or drains the converter at end of stream).
        /// Reuses the converter across calls so fractional resampling phase carries
        /// over; always consumes `.inputRanDry` output per AVAudioConverter contract.
        static func convert(
            buffer: AVAudioPCMBuffer?,
            with converter: AVAudioConverter,
            to format: AVAudioFormat,
            endOfStream: Bool
        ) -> [AVAudioPCMBuffer] {
            var pending = buffer
            var out: [AVAudioPCMBuffer] = []
            let sourceRate = converter.inputFormat.sampleRate
            let targetRate = format.sampleRate

            while true {
                let inputFrames = Double(pending?.frameLength ?? 0)
                let capacity = AVAudioFrameCount(
                    max(256, (inputFrames * targetRate / max(sourceRate, 1)).rounded(.up) + 64))
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return out }
                var consumed = false
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, outStatus in
                    if endOfStream, pending == nil {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    if consumed || pending == nil {
                        outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                        return nil
                    }
                    consumed = true
                    let next = pending
                    pending = nil
                    outStatus.pointee = .haveData
                    return next
                }
                if output.frameLength > 0 {
                    out.append(output)
                }
                switch status {
                case .haveData:
                    continue
                case .inputRanDry:
                    if endOfStream { continue }
                    return out
                case .endOfStream, .error:
                    return out
                @unknown default:
                    return out
                }
            }
        }

        static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return 0 }
            var sum: Double = 0
            if let floatData = buffer.floatChannelData {
                let samples = floatData[0]
                for index in 0..<frames {
                    let sample = Double(samples[index])
                    sum += sample * sample
                }
            } else if let intData = buffer.int16ChannelData {
                let samples = intData[0]
                for index in 0..<frames {
                    let sample = Double(samples[index]) / 32768.0
                    sum += sample * sample
                }
            } else {
                return 0
            }
            let rms = sqrt(sum / Double(frames))
            // Same perceptual mapping as AVAudioEngineRecorder's decibel curve.
            let decibels = Float(20 * log10(max(rms, 1e-7)))
            let floor: Float = -55
            let ceiling: Float = -8
            let clamped = Swift.min(Swift.max(decibels, floor), ceiling)
            let normalized = (clamped - floor) / (ceiling - floor)
            return Swift.min(Swift.max(sqrtf(normalized), 0), 1)
        }
    }
#endif

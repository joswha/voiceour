import AVFoundation
import CoreMedia
import Foundation
import VoiceCore

#if canImport(Speech)
    import Speech
#endif

/// Mirrors the Python sidecar's `protocol_error` taxonomy so native backends
/// produce identical category/retryable/user-message metadata on the wire shape.
func makeASRError(_ code: ASRErrorCode, requestId: String?, detail: String?) -> ASRErrorMessage {
    let setupCodes: Set<ASRErrorCode> = [.modelNotInstalled, .manifestMismatch, .backendUnavailable]
    let retryableCodes: Set<ASRErrorCode> = [.timeout, .internalError, .inferenceFailed]
    return ASRErrorMessage(
        requestId: requestId,
        code: code,
        category: setupCodes.contains(code) ? "setup" : "runtime",
        retryable: retryableCodes.contains(code),
        userMessageKey: "asr.\(code.rawValue)",
        detail: detail
    )
}

/// ASR client that always fails: installed when the selected backend cannot run
/// on this system (e.g. `apple` on macOS < 26). Keeps the coordinator's error
/// path uniform instead of spawning a Python sidecar that can never match.
public struct UnsupportedASRClient: ASRClienting {
    public let backendId: String
    public let detail: String

    public init(backendId: String, detail: String) {
        self.backendId = backendId
        self.detail = detail
    }

    public func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
        throw makeASRError(.backendUnavailable, requestId: nil, detail: detail)
    }

    public func health(timeoutMs: Int) async throws -> ASRBackendHealth {
        ASRBackendHealth(
            backendId: backendId, backendStatus: .backendUnavailable, ready: false, modelLoaded: false, cacheOk: false)
    }
}

#if canImport(Speech)
    /// Native macOS 26 ASR backend: SpeechAnalyzer + SpeechTranscriber.
    ///
    /// Runs Apple's on-device dictation model with no Python sidecar, no model
    /// download managed by Voiceour, and no speech-recognition authorization
    /// prompt (the API is fully on-device). Benchmarked against the pinned
    /// Parakeet MLX backend on this machine (2026-07-17, identical scorer):
    /// LibriSpeech n=64 U-WER 3.07% vs 2.84%, FLEURS n=8 U-WER 3.85% vs 4.49%,
    /// ASR p95 885ms vs 2327ms (flat latency even on 35s audio). Opt-in backend;
    /// `mlx` remains the default.
    @available(macOS 26.0, *)
    public final class AppleSpeechASRClient: ASRClienting, @unchecked Sendable {
        static let backendId = "apple-speech"

        private let locale: Locale

        public init(locale: Locale = Locale(identifier: "en_US")) {
            self.locale = locale
        }

        /// Requests the locale's speech assets if they are not installed yet, so the
        /// first dictation after launch never pays a download.
        public func warmUp() async {
            guard let resolved = await Self.resolvedLocale(matching: locale) else { return }
            let transcriber = Self.makeTranscriber(locale: resolved)
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try? await request.downloadAndInstall()
            }
        }

        public func health(timeoutMs: Int) async throws -> ASRBackendHealth {
            guard let resolved = await Self.resolvedLocale(matching: locale) else {
                return ASRBackendHealth(
                    backendId: Self.backendId, backendStatus: .backendUnavailable, ready: false, modelLoaded: false,
                    cacheOk: false)
            }
            let installed = await SpeechTranscriber.installedLocales.contains {
                $0.identifier(.bcp47) == resolved.identifier(.bcp47)
            }
            return ASRBackendHealth(
                backendId: Self.backendId,
                backendStatus: installed ? .ready : .modelMissing,
                ready: installed,
                modelLoaded: installed,
                cacheOk: installed
            )
        }

        public func transcribe(_ audio: RecordedAudio, timeoutMs: Int) async throws -> ASRResult {
            let requestId = UUID().uuidString
            guard let resolved = await Self.resolvedLocale(matching: locale) else {
                // Name the identifier: the bare "locale not supported" this used to
                // raise was indistinguishable from a broken backend, and the value
                // that caused it can be whitespace the settings field cannot show.
                throw makeASRError(
                    .backendUnavailable,
                    requestId: requestId,
                    detail: "speech locale \(locale.identifier.debugDescription) is not supported by SpeechTranscriber"
                )
            }
            guard FileManager.default.fileExists(atPath: audio.url.path) else {
                throw makeASRError(.audioNotFound, requestId: requestId, detail: audio.url.path)
            }

            let start = ContinuousClock.now
            let transcript = try await withThrowingTaskGroup(of: AppleSpeechTranscript.self) { group in
                group.addTask {
                    try await Self.transcribeFile(url: audio.url, locale: resolved)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 1)) * 1_000_000)
                    throw makeASRError(.timeout, requestId: requestId, detail: "apple speech transcription timed out")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw makeASRError(.internalError, requestId: requestId, detail: "no transcription result")
                }
                return result
            }

            let elapsed = start.duration(to: .now)
            let ms = Int(
                (Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e15).rounded())
            return ASRResult(
                requestId: requestId,
                backendId: Self.backendId,
                modelId: "apple/SpeechTranscriber/\(resolved.identifier(.bcp47))",
                modelRevision: ProcessInfo.processInfo.operatingSystemVersionString,
                transcript: ASRTranscript(
                    text: transcript.text, language: resolved.language.languageCode?.identifier,
                    segments: transcript.segments, confidence: transcript.confidence,
                    confidenceMode: transcript.confidenceMode),
                timingsMs: ASRTimings(load: 0, inference: ms, total: ms)
            )
        }

        private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
            SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [],
                attributeOptions: AppleSpeechTranscriptBuilder.attributeOptions)
        }

        private static func resolvedLocale(matching locale: Locale) async -> Locale? {
            await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }

        private static func transcribeFile(url: URL, locale: Locale) async throws -> AppleSpeechTranscript {
            let transcriber = makeTranscriber(locale: locale)
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            let collectTask = Task { () -> AppleSpeechTranscript in
                var builder = AppleSpeechTranscriptBuilder()
                for try await result in transcriber.results where result.isFinal {
                    builder.add(result)
                }
                return builder.finish()
            }

            do {
                let file = try AVAudioFile(forReading: url)
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                collectTask.cancel()
                throw makeASRError(.inferenceFailed, requestId: nil, detail: String(describing: error))
            }

            return try await collectTask.value
        }
    }

    /// Wire-shape transcript pieces reduced from SpeechTranscriber results:
    /// concatenated text plus optional per-segment/word evidence and an aggregate
    /// confidence. `segments`/`confidence` stay nil when the OS or requested
    /// attribute options yield no run attributes, so callers degrade to text-only
    /// without fabricating evidence.
    @available(macOS 26.0, *)
    struct AppleSpeechTranscript: Sendable {
        let text: String
        let segments: [ASRSegment]?
        let confidence: Double?
        let confidenceMode: ASRConfidenceMode?
    }

    /// Shared reduction used by both the streaming (StreamingSession.collectTask)
    /// and batch (AppleSpeechASRClient.transcribeFile) Apple Speech paths. Each
    /// finalized SpeechTranscriber result becomes one ASRSegment; each run carrying
    /// a `.audioTimeRange` attribute becomes one ASRWord with ms-scaled bounds and,
    /// when present, `.transcriptionConfidence`. Apple publishes no documented
    /// confidence scale, so the aggregate is reported with `confidenceMode == .none`
    /// — never a fabricated greedy/beam label.
    @available(macOS 26.0, *)
    struct AppleSpeechTranscriptBuilder {
        /// Attribute options both call sites request so per-word evidence is emitted
        /// whenever the installed model provides it.
        static let attributeOptions: Set<SpeechTranscriber.ResultAttributeOption> = [
            .audioTimeRange, .transcriptionConfidence,
        ]

        private var text = ""
        private var segments: [ASRSegment] = []
        private var confidenceSum = 0.0
        private var confidenceCount = 0

        /// Folds one finalized result's AttributedString into the accumulator.
        mutating func add(_ result: SpeechTranscriber.Result) {
            let attributed = result.text
            text += String(attributed.characters)

            var words: [ASRWord] = []
            var segStartMs: Int?
            var segEndMs: Int?
            for run in attributed.runs {
                guard let range = run.audioTimeRange,
                    let startMs = Self.milliseconds(range.start),
                    let endMs = Self.milliseconds(range.end)
                else { continue }
                let word = String(attributed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { continue }
                let confidence = run.transcriptionConfidence
                if let confidence {
                    confidenceSum += confidence
                    confidenceCount += 1
                }
                words.append(
                    ASRWord(text: word, startMs: startMs, endMs: Swift.max(startMs, endMs), confidence: confidence))
                segStartMs = Swift.min(segStartMs ?? startMs, startMs)
                segEndMs = Swift.max(segEndMs ?? endMs, endMs)
            }

            guard !words.isEmpty, let start = segStartMs, let end = segEndMs else { return }
            let segmentText = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(ASRSegment(startMs: start, endMs: Swift.max(start, end), text: segmentText, words: words))
        }

        /// Produces the finalized transcript. When no run carried a time range the
        /// evidence fields are nil (text-only), so an OS or model that omits the
        /// attributes degrades gracefully.
        func finish() -> AppleSpeechTranscript {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segments.isEmpty else {
                return AppleSpeechTranscript(text: trimmed, segments: nil, confidence: nil, confidenceMode: nil)
            }
            let confidence = confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : nil
            return AppleSpeechTranscript(
                text: trimmed,
                segments: segments,
                confidence: confidence,
                confidenceMode: confidence == nil ? nil : ASRConfidenceMode.none
            )
        }

        private static func milliseconds(_ time: CMTime) -> Int? {
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, seconds >= 0 else { return nil }
            return Int((seconds * 1000).rounded())
        }
    }
#endif

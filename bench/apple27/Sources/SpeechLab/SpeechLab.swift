import AVFoundation
import CoreMedia
import Darwin
import Foundation
import PrototypeSupport
import Speech

private enum Engine: String, Sendable {
    case speech
    case dictation
    case dictationVocabulary = "dictation-vocabulary"

    var moduleName: String { self == .speech ? "SpeechTranscriber" : "DictationTranscriber" }

    func resolve(_ locale: Locale) async -> Locale? {
        if self == .speech { return await SpeechTranscriber.supportedLocale(equivalentTo: locale) }
        return await DictationTranscriber.supportedLocale(equivalentTo: locale)
    }

    func locales(installed: Bool) async -> [String] {
        let locales: [Locale]
        if self == .speech {
            locales = installed ? await SpeechTranscriber.installedLocales : await SpeechTranscriber.supportedLocales
        } else {
            locales =
                installed ? await DictationTranscriber.installedLocales : await DictationTranscriber.supportedLocales
        }
        return locales.map(\.identifier).sorted()
    }
}

private struct Configuration {
    let engine: Engine
    let locale: String
    let input: URL?
    let output: URL?
    let vocabulary: URL?
    let probe: Bool
    let downloadAssets: Bool
    let timeout: Double

    init() throws {
        let args = try PrototypeArguments(
            values: ["--engine", "--input", "--output", "--locale", "--vocabulary", "--timeout-seconds"],
            flags: ["--probe", "--download-assets"]
        )
        guard let engine = Engine(rawValue: try args.require("--engine")) else {
            throw PrototypeError.message("--engine must be speech, dictation, or dictation-vocabulary")
        }
        self.engine = engine
        locale = args["--locale"] ?? "en-US"
        probe = args.contains("--probe")
        downloadAssets = args.contains("--download-assets")
        input = args["--input"].map { URL(fileURLWithPath: $0) }
        output = args["--output"].map { URL(fileURLWithPath: $0) }
        vocabulary = args["--vocabulary"].map { URL(fileURLWithPath: $0) }
        guard let timeout = Double(args["--timeout-seconds"] ?? "120"),
            timeout.isFinite, timeout > 0, timeout <= 3600
        else {
            throw PrototypeError.message("--timeout-seconds must be in (0, 3600]")
        }
        self.timeout = timeout
        guard probe || (input != nil && output != nil) else {
            throw PrototypeError.message("--input and --output are required unless --probe is supplied")
        }
        guard engine == .dictationVocabulary || vocabulary == nil else {
            throw PrototypeError.message("--vocabulary is only accepted with dictation-vocabulary")
        }
        guard probe || engine != .dictationVocabulary || vocabulary != nil else {
            throw PrototypeError.message("dictation-vocabulary requires --vocabulary for inference")
        }
    }
}

private struct Segment: Sendable {
    let start: CMTime
    let duration: CMTime
    let text: String
}

private enum Transcriber: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    init(engine: Engine, locale: Locale) {
        // No volatile results, filtering, alternatives or confidence attributes. The two
        // dictation modes differ only in their AnalysisContext contextual strings.
        if engine == .speech {
            self = .speech(
                SpeechTranscriber(
                    locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: []
                ))
        } else {
            self = .dictation(
                DictationTranscriber(
                    locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [],
                    attributeOptions: []
                ))
        }
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let module): return module
        case .dictation(let module): return module
        }
    }

    func collect() async throws -> String {
        var segments: [Segment] = []
        var unexpectedVolatileResults = 0
        switch self {
        case .speech(let module):
            for try await result in module.results {
                try Task.checkCancellation()
                if result.isFinal {
                    segments.append(
                        Segment(
                            start: result.range.start, duration: result.range.duration,
                            text: String(result.text.characters)))
                } else {
                    unexpectedVolatileResults += 1
                }
            }
        case .dictation(let module):
            for try await result in module.results {
                try Task.checkCancellation()
                if result.isFinal {
                    segments.append(
                        Segment(
                            start: result.range.start, duration: result.range.duration,
                            text: String(result.text.characters)))
                } else {
                    unexpectedVolatileResults += 1
                }
            }
        }
        guard unexpectedVolatileResults == 0 else {
            throw PrototypeError.message(
                "Received \(unexpectedVolatileResults) non-final results without volatileResults enabled")
        }
        // Results are documented as ordered phrases. Sort by audio time defensively,
        // preserve receipt order on ties, and reject overlapping finalized ranges.
        let ordered = segments.enumerated().sorted {
            let comparison = CMTimeCompare($0.element.start, $1.element.start)
            return comparison == 0 ? $0.offset < $1.offset : comparison < 0
        }.map(\.element)
        var previousEnd: CMTime?
        for segment in ordered {
            guard segment.start.isNumeric, segment.duration.isNumeric,
                CMTimeCompare(segment.duration, .zero) >= 0
            else {
                throw PrototypeError.message("Transcriber returned an invalid final result range")
            }
            if let previousEnd, CMTimeCompare(segment.start, previousEnd) < 0 {
                throw PrototypeError.message("Transcriber returned overlapping final results")
            }
            previousEnd = CMTimeAdd(segment.start, segment.duration)
        }
        let text = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        // A successfully finished analysis may contain no speech. Keep that observable
        // as an empty transcript; thrown framework failures remain errors.
        return text
    }
}

private struct Session: Sendable {
    let transcriber: Transcriber
    let analyzer: SpeechAnalyzer

    init(engine: Engine, locale: Locale) {
        transcriber = Transcriber(engine: engine, locale: locale)
        analyzer = SpeechAnalyzer(
            modules: [transcriber.module],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime, ignoresResourceLimits: false)
        )
    }

    func prepare(hints: [String]) async throws {
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: hints]
            try await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber.module]) else {
            throw PrototypeError.message("No supported audio format for transcriber")
        }
        try await analyzer.prepareToAnalyze(in: format)
    }

    func transcribe(url: URL) async throws -> String {
        // The macOS 27 file provider reads and converts the first audio track to a
        // supported format. Keep it alive until finalization and result collection.
        let provider = try await AssetInputSequenceProvider.provider(
            from: AVURLAsset(url: url), compatibleWith: [transcriber.module], priority: .userInitiated
        )
        async let transcript = transcriber.collect()
        do {
            guard let end = try await analyzer.analyzeSequence(provider.analyzerInputs) else {
                throw PrototypeError.message("Audio file contains no samples")
            }
            try await analyzer.finalizeAndFinish(through: end)
            let text = try await transcript
            withExtendedLifetime(provider) {}
            return text
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

/// Framework cancellation is cooperative. Explicitly finishing the analyzer releases
/// both its input wait and module result streams before the task-group scope exits.
private func withDeadline<T: Sendable>(
    seconds: Double,
    phase: String,
    cancel: @escaping @Sendable () async -> Void = {},
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw PrototypeError.message("Timed out during \(phase) after \(seconds) seconds")
        }
        do {
            guard let value = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return value
        } catch {
            group.cancelAll()
            await cancel()
            throw error
        }
    }
}

private func statusName(_ status: AssetInventory.Status) -> String {
    switch status {
    case .unsupported: return "unsupported"
    case .supported: return "supported"
    case .downloading: return "downloading"
    case .installed: return "installed"
    @unknown default: return "unknown"
    }
}

private func runtimeBuild() -> String? {
    var count = 0
    guard sysctlbyname("kern.osversion", nil, &count, nil, 0) == 0, count > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: count)
    let status = bytes.withUnsafeMutableBytes { sysctlbyname("kern.osversion", $0.baseAddress, &count, nil, 0) }
    guard status == 0 else { return nil }
    return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
}

@main
private struct SpeechLab {
    static func main() async {
        var writer: PrototypeWriter?
        var activeAnalyzer: SpeechAnalyzer?
        var metadata: [String: Any] = ["type": "blocked", "backend": "apple-speech"]
        do {
            let config = try Configuration()
            if let output = config.output { writer = try PrototypeWriter(at: output) }
            let setupStart = PrototypeClock.now()
            metadata.merge([
                "engine": config.engine.rawValue,
                "module": config.engine.moduleName,
                "model_identity": "system-managed; public model revision unavailable",
                "runtime_os": ProcessInfo.processInfo.operatingSystemVersionString,
                "runtime_os_build": runtimeBuild() as Any? ?? NSNull(),
                "requested_locale": config.locale,
                "download_assets_allowed": config.downloadAssets,
                "asset_request_called": false,
                "asset_request_created": false,
                "download_and_install_called": false,
                "timeout_seconds": config.timeout,
                "transcription_options": config.engine == .speech ? [] : ["punctuation"],
                "reporting_options": [String](),
                "attribute_options": [String](),
                "content_hints": [String](),
                "model_retention": "processLifetime",
                "ignores_resource_limits": false,
                "first_request": "process-first after explicit prewarm, not guaranteed OS-model cold",
                "inference_timing":
                    "includes file-provider creation, file read, format conversion, analysis, finalization and result collection; excludes SHA validation and session prepare",
                "input_provider": "AssetInputSequenceProvider, first audio track, supported-format conversion",
            ]) { _, new in new }
            let hints = try config.vocabulary.map { try PrototypeIO.vocabulary(at: $0) } ?? []
            metadata["vocabulary_count"] = hints.count
            metadata["contextual_strings_tag"] = config.engine == .dictationVocabulary ? "general" : NSNull()
            metadata["vocabulary_sha256"] =
                try config.vocabulary.map { try PrototypeIO.digest(of: $0) } as Any? ?? NSNull()
            metadata["manifest_sha256"] = try config.input.map { try PrototypeIO.digest(of: $0) } as Any? ?? NSNull()
            let rows = try config.input.map { try PrototypeIO.inputs(at: $0) } ?? []
            metadata["row_count"] = rows.count
            metadata["hardware_available"] = config.engine == .speech ? SpeechTranscriber.isAvailable : NSNull()
            metadata["supported_locales"] = await config.engine.locales(installed: false)
            metadata["installed_locales_before"] = await config.engine.locales(installed: true)
            guard let locale = await config.engine.resolve(Locale(identifier: config.locale)) else {
                metadata["asset_status_before"] = "unsupported"
                metadata["asset_status_after"] = "unsupported"
                if config.probe {
                    metadata["type"] = "capability"
                    metadata["available"] = false
                    metadata["reason"] = "No supported equivalent locale"
                    try emit(metadata, writer: writer)
                    try writer?.close()
                    return
                }
                throw PrototypeError.message("No supported equivalent locale for \(config.locale)")
            }
            metadata["resolved_locale"] = locale.identifier
            let initialSession = Session(engine: config.engine, locale: locale)
            activeAnalyzer = initialSession.analyzer
            let modules = [initialSession.transcriber.module]
            let before = await AssetInventory.status(forModules: modules)
            metadata["asset_status_before"] = statusName(before)
            metadata["asset_status_after"] = statusName(before)
            if config.downloadAssets && before != .installed && before != .unsupported {
                let downloadStart = PrototypeClock.now()
                // This is the only path that requests assets or reserves locales.
                metadata["asset_request_called"] = true
                if let request = try await withDeadline(
                    seconds: config.timeout, phase: "asset request",
                    operation: {
                        try await AssetInventory.assetInstallationRequest(supporting: modules)
                    })
                {
                    metadata["asset_request_created"] = true
                    metadata["download_and_install_called"] = true
                    PrototypeIO.diagnostic(
                        "Requesting system Speech assets for \(config.engine.rawValue), \(locale.identifier)")
                    do {
                        try await withDeadline(
                            seconds: config.timeout, phase: "asset download/install",
                            cancel: {
                                request.progress.cancel()
                            },
                            operation: {
                                try await request.downloadAndInstall()
                            })
                    } catch {
                        metadata["asset_status_after"] = statusName(await AssetInventory.status(forModules: modules))
                        metadata["asset_download_ms"] = PrototypeClock.milliseconds(since: downloadStart)
                        throw error
                    }
                }
                metadata["asset_download_ms"] = PrototypeClock.milliseconds(since: downloadStart)
            } else {
                metadata["asset_download_ms"] = 0.0
            }
            let after = await AssetInventory.status(forModules: modules)
            metadata["asset_status_after"] = statusName(after)
            metadata["installed_locales_after"] = await config.engine.locales(installed: true)
            let hardwareAvailable = config.engine != .speech || SpeechTranscriber.isAvailable
            metadata["available"] = after == .installed && hardwareAvailable
            if config.probe {
                metadata["type"] = "capability"
                metadata["setup_ms"] = PrototypeClock.milliseconds(since: setupStart)
                try emit(metadata, writer: writer)
                try writer?.close()
                return
            }
            guard hardwareAvailable else {
                throw PrototypeError.message("SpeechTranscriber unavailable on this hardware")
            }
            guard after == .installed else {
                throw PrototypeError.message(
                    "Speech assets are \(statusName(after)), not installed; installation is permitted only with --download-assets"
                )
            }
            let prewarmStart = PrototypeClock.now()
            try await withDeadline(
                seconds: config.timeout, phase: "initial prepare",
                cancel: {
                    await initialSession.analyzer.cancelAndFinishNow()
                },
                operation: {
                    try await initialSession.prepare(hints: hints)
                })
            metadata["prewarm_ms"] = PrototypeClock.milliseconds(since: prewarmStart)
            metadata["setup_ms"] = PrototypeClock.milliseconds(since: setupStart)
            metadata["type"] = "bench_meta"
            try emit(metadata, writer: writer)
            guard let writer else { throw PrototypeError.message("Missing results writer") }
            for (index, row) in rows.enumerated() {
                let session = index == 0 ? initialSession : Session(engine: config.engine, locale: locale)
                activeAnalyzer = session.analyzer
                var details = [
                    "engine": config.engine.rawValue, "resolved_locale": locale.identifier,
                    "request_state": index == 0 ? "process-first-after-prewarm" : "retained-model-new-session",
                ]
                var inferenceStart: UInt64?
                do {
                    let pinStart = PrototypeClock.now()
                    let audio = try PrototypeIO.audioURL(for: row)
                    details["audio_validation_ms"] = String(PrototypeClock.milliseconds(since: pinStart))
                    let prepareStart = PrototypeClock.now()
                    if index != 0 {
                        try await withDeadline(
                            seconds: config.timeout, phase: "row prepare",
                            cancel: {
                                await session.analyzer.cancelAndFinishNow()
                            }, operation: { try await session.prepare(hints: hints) })
                    }
                    details["session_prepare_ms"] =
                        index == 0 ? "0" : String(PrototypeClock.milliseconds(since: prepareStart))
                    let started = PrototypeClock.now()
                    inferenceStart = started
                    let text = try await withDeadline(
                        seconds: config.timeout, phase: "file transcription",
                        cancel: {
                            await session.analyzer.cancelAndFinishNow()
                        }, operation: { try await session.transcribe(url: audio) })
                    let elapsed = PrototypeClock.milliseconds(since: started)
                    try writer.write(
                        PrototypeOutput(
                            id: row.id, rawTranscript: text, audioS: row.audioS,
                            asrMs: elapsed, details: details))
                } catch {
                    let elapsed = inferenceStart.map { PrototypeClock.milliseconds(since: $0) }
                    await session.analyzer.cancelAndFinishNow()
                    try writer.write(
                        PrototypeOutput(
                            id: row.id, rawTranscript: "", audioS: row.audioS,
                            asrMs: elapsed, error: String(describing: error), details: details))
                }
                activeAnalyzer = nil
            }
            if rows.isEmpty { await initialSession.analyzer.cancelAndFinishNow() }
            await SpeechModels.endRetention()
            try writer.close()
        } catch {
            if let activeAnalyzer { await activeAnalyzer.cancelAndFinishNow() }
            metadata["type"] = "blocked"
            metadata["status"] = "blocked"
            metadata["error"] = String(describing: error)
            do {
                try emit(metadata, writer: writer)
                try writer?.close()
            } catch { PrototypeIO.diagnostic("Unable to write blocked result: \(error)") }
            PrototypeIO.diagnostic(String(describing: error))
            await SpeechModels.endRetention()
            exit(1)
        }
    }

    private static func emit(_ object: [String: Any], writer: PrototypeWriter?) throws {
        if let writer {
            try writer.writeObject(object)
        } else {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}

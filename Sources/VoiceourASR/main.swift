import ASRSidecarCore
import CParakeet
import Foundation
import VoiceCore

/// Entry point of the `voiceour-asr` helper: a persistent NDJSON sidecar over stdio.
///
/// stdout is protocol-only. Everything diagnostic — ggml's own logging included — goes to
/// stderr, which is why the log callback is installed before anything else can print.
private let standardError = FileHandle.standardError

private func logLine(_ message: String) {
    try? standardError.write(contentsOf: Data((message + "\n").utf8))
}

/// Threshold for ggml/parakeet's own logging, from `VOICEOUR_ASR_LOG`.
///
/// The vendored runtime is chatty at INFO: one line per Metal pipeline it compiles, which is
/// hundreds on a cold start. Levels are ggml's own (`ggml_log_level`): DEBUG 1, INFO 2, WARN 3,
/// ERROR 4, CONT 5. `none` parks the threshold above every real level.
private nonisolated(unsafe) var logThreshold: Int32 = 2
/// Whether the last non-continuation line was forwarded. `GGML_LOG_LEVEL_CONT` continues the
/// previous line and carries no level of its own, so it inherits that verdict. Display-only: the
/// race between two logging threads can only interleave text that was already interleaved.
private nonisolated(unsafe) var lastLogPassed = true

private func installParakeetLogging(_ environment: [String: String]) {
    switch (environment["VOICEOUR_ASR_LOG"] ?? "info").lowercased() {
    case "debug": logThreshold = 1
    case "warn": logThreshold = 3
    case "error": logThreshold = 4
    case "none": logThreshold = 99
    default: logThreshold = 2
    }
    // `parakeet_log_set` forwards the same callback to `ggml_log_set`, so one install covers
    // both loggers (Vendor/parakeet/src/parakeet.cpp:3883-3887). The callback takes no captures.
    parakeet_log_set(
        { level, text, _ in
            guard let text else { return }
            let raw = level.rawValue
            let pass = raw == GGML_LOG_LEVEL_CONT.rawValue ? lastLogPassed : raw >= logThreshold
            if raw != GGML_LOG_LEVEL_CONT.rawValue { lastLogPassed = pass }
            guard pass else { return }
            FileHandle.standardError.write(Data(String(cString: text).utf8))
        },
        nil
    )
}

private func makeBackend(_ environment: [String: String]) throws -> SidecarBackend? {
    switch environment["VOICEOUR_ASR_BACKEND"] ?? "fake" {
    case "fake":
        return FakeASRBackend(environment: environment)
    case "parakeet":
        // Unset keeps the 30-minute default; a value <= 0 disables the unload entirely.
        let idleUnloadMs = environment["VOICEOUR_IDLE_UNLOAD_MS"].flatMap(Int.init)
        return try ParakeetSidecarBackend(
            cache: .standard(environment: environment),
            environment: environment,
            log: logLine,
            idleUnloadMs: idleUnloadMs ?? 1_800_000
        )
    default:
        return nil
    }
}

/// `--prove <wav>`: acquire, load, transcribe, report. The one command that proves a fresh
/// machine can go from no model to a real local transcript, and the replacement for the
/// retired `scripts/phase0_asr_proof.py`.
///
/// It drives the same `ParakeetSidecarBackend` the protocol loop uses, so a green `--prove`
/// is evidence about the shipping path rather than about a parallel one.
private func prove(wavPath: String, environment: [String: String]) -> Int32 {
    // No idle unload: --prove is one load and one decode, and a timer would only add a way
    // for the measurement to change under it.
    let backend: ParakeetSidecarBackend
    do {
        backend = try ParakeetSidecarBackend(
            cache: .standard(environment: environment),
            environment: environment,
            log: logLine,
            idleUnloadMs: 0
        )
    } catch {
        logLine("prove: sidecar startup failed: \(error)")
        return 1
    }
    defer { backend.shutdown() }

    let loadStart = DispatchTime.now().uptimeNanoseconds
    do {
        try backend.warmUp()
    } catch {
        logLine("prove: model acquisition failed: \(error)")
        return 1
    }
    let coldLoadMs = (DispatchTime.now().uptimeNanoseconds - loadStart) / 1_000_000

    let url = URL(fileURLWithPath: wavPath)
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    let request = ASRTranscribeRequest(
        requestId: "prove",
        audio: ASRAudioMeta(
            path: url.path,
            format: "wav",
            sampleRateHz: WAVFile.requiredSampleRate,
            channels: WAVFile.requiredChannels,
            durationMs: 0,
            byteCount: byteCount
        ),
        expectedModel: nil,
        timeoutMs: 600_000
    )

    guard case .result(let transcript, _, _, _, let timings) = backend.transcribe(request, isCancelled: { false })
    else {
        logLine("prove: transcription did not produce a result")
        return 1
    }

    let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    print("transcript=\(text)")
    print("cold_load_ms=\(coldLoadMs) warm_inference_ms=\(timings.inference)")

    let lowercased = text.lowercased()
    guard !text.isEmpty, lowercased.contains("hello"), lowercased.contains("world") else {
        logLine("prove: transcript did not contain the expected words")
        return 1
    }
    return 0
}

let environment = ProcessInfo.processInfo.environment

installParakeetLogging(environment)

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--prove" {
    guard arguments.count == 2 else {
        logLine("usage: voiceour-asr --prove <wav>")
        exit(2)
    }
    exit(prove(wavPath: arguments[1], environment: environment))
}

let backend: SidecarBackend?
do {
    backend = try makeBackend(environment)
} catch {
    logLine("voiceour-asr startup failed: \(error)")
    exit(1)
}

let server = SidecarServer(
    backend: backend,
    output: SidecarOutput(handle: FileHandle.standardOutput),
    log: logLine,
    preloadEnabled: environment["VOICEOUR_PRELOAD"] == "1"
)
exit(server.run(input: FileHandle.standardInput))

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

private func installParakeetLogging() {
    parakeet_log_set(
        { _, text, _ in
            guard let text else { return }
            FileHandle.standardError.write(Data(String(cString: text).utf8))
        },
        nil
    )
}

private func makeBackend(_ environment: [String: String]) -> SidecarBackend? {
    switch environment["VOICEOUR_ASR_BACKEND"] ?? "fake" {
    case "fake":
        return FakeASRBackend(environment: environment)
    case "parakeet":
        return ParakeetSidecarBackend(cache: .standard(environment: environment), log: logLine)
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
    let backend = ParakeetSidecarBackend(cache: .standard(environment: environment), log: logLine)
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

installParakeetLogging()

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--prove" {
    guard arguments.count == 2 else {
        logLine("usage: voiceour-asr --prove <wav>")
        exit(2)
    }
    exit(prove(wavPath: arguments[1], environment: environment))
}

let server = SidecarServer(
    backend: makeBackend(environment),
    output: SidecarOutput(handle: FileHandle.standardOutput),
    log: logLine,
    preloadEnabled: environment["VOICEOUR_PRELOAD"] == "1"
)
exit(server.run(input: FileHandle.standardInput))

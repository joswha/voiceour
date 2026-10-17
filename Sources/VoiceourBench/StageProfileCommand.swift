import ASRSidecarCore
import Darwin
import Foundation
import VoiceCore
import VoiceMac

/// B0 offline stage ledger: where one production in-process decode's time goes.
///
/// Per pass and manifest row this times the route the sidecar runs for a request — reading and
/// decoding the WAV (`wav_read`), one `parakeet_full` (`full`), segment collection and transcript
/// assembly (`assemble`) — then the deterministic text stage (`cleanup`, and `repair` with
/// `--vocabulary`). Within `full`, `mel`, `encode` and `tail` are the native stage counters,
/// reset before and read after that one call; `full_unattributed_us` is what the counters leave
/// out (blank-step argmax, token data, encoder scheduling, result construction). Pass 0 is
/// warmup. A `cold` row records context construction and the first decode before any pass.
///
/// With `--sidecar`, each row also runs through the real `voiceour-asr` process via the
/// `pipeline` command's client, right after its in-process decode, so `client_us - full`
/// isolates IPC and sidecar shell overhead.
struct StageProfileCommand {
    var options: BenchOptions

    func run() async throws {
        let rows = try GlossaryConditioningContract.readManifest(at: options.input)
        // Timing rows are evidence; a rerun belongs in a new file.
        guard !FileManager.default.fileExists(atPath: options.output.path) else {
            throw BenchError.io("refusing to overwrite \(options.output.path)")
        }
        let repair = try options.vocabulary.map(LoadedRepairEngine.load)
        let cache = ParakeetModelCache.standard()
        guard cache.cacheOK() else {
            throw BenchError.io("pinned model cache is not ready: \(cache.modelURL.path)")
        }
        let backend = options.backend ?? ASRBackendRegistry.builtIn.defaultDescriptor.id
        let sidecarAudio = options.sidecar ? try rows.map { try BenchRunner.recordedAudio(for: $0.row) } : []

        let writer = try JSONLWriter(url: options.output)
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let host = BenchHost.snapshot()

        // The sidecar's own construction: pinned artifact, its weight arena, Metal tail, 6 threads.
        let initStart = BenchClock.mark()
        let context = try ParakeetContext(
            modelPath: cache.modelURL.path,
            weightArenaPath: cache.weightArenaURL.path
        )
        let initEnd = BenchClock.mark()

        try writer.write(
            StageProfileRunMeta(
                gitSHA: BenchHost.gitSHA(),
                startedAt: startedAt,
                host: host,
                arms: options.sidecar ? ["native-full", "sidecar"] : ["native-full"],
                passes: options.passes,
                corpus: options.input.path,
                manifestSHA256: try BenchRunner.sha256(of: options.input),
                audioManifestSHA256: try BenchRunner.audioManifestSHA256(of: options.input),
                model: cache.modelURL.path,
                modelVariant: BenchRunner.modelVariant.rawValue,
                weightArena: cache.weightArenaURL.path,
                threads: Int(context.decodeThreadCount),
                sidecarBackend: options.sidecar ? backend : nil,
                vocabularySHA256: repair?.sha256,
                environment: ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("VOICEOUR_") }
            )
        )

        let first = rows[0]
        let firstSamples = try WAVFile.readSamples(at: first.audio)
        let firstStart = BenchClock.mark()
        try context.decodeForProfiling(samples: firstSamples)
        let firstEnd = BenchClock.mark()
        var cold = StageProfileColdRow(
            initUs: Self.microseconds(from: initStart, to: initEnd),
            firstFullUs: Self.microseconds(from: firstStart, to: firstEnd),
            firstRowID: first.row.id
        )

        var client: (any ASRClienting)?
        if options.sidecar {
            let launched = BenchRunner.makeASRClient(backend: backend)
            let launchStart = BenchClock.mark()
            try await Self.waitUntilLoaded(launched, timeoutMs: options.timeoutMs)
            cold.sidecarReadyUs = Self.microseconds(from: launchStart, to: BenchClock.mark())
            let requestStart = BenchClock.mark()
            _ = try await launched.transcribe(sidecarAudio[0], timeoutMs: options.timeoutMs)
            cold.sidecarFirstClientUs = Self.microseconds(from: requestStart, to: BenchClock.mark())
            client = launched
        }
        try writer.write(cold)

        var seq = 0
        // Keeps every text-stage result observable, so no stage can be optimized away.
        var checksum = 0
        for pass in 0...options.passes {
            for (offset, entry) in rows.enumerated() {
                let wavStart = BenchClock.mark()
                let samples = try WAVFile.readSamples(at: entry.audio)
                let wavEnd = BenchClock.mark()

                context.resetStageTimings()
                let fullStart = BenchClock.mark()
                try context.decodeForProfiling(samples: samples)
                let fullEnd = BenchClock.mark()
                guard let native = context.stageTimings() else {
                    throw BenchError.io("\(entry.row.id): native stage timings are unavailable")
                }

                let assembleStart = BenchClock.mark()
                let segments = context.collectDecodedSegments()
                let transcript = TokenMapping.transcript(from: segments)
                let assembleEnd = BenchClock.mark()

                let cleanupStart = BenchClock.mark()
                let cleaned = CleanupEngine.clean(transcript.text, glossary: [])
                let cleanupEnd = BenchClock.mark()
                checksum &+= cleaned.utf8.count

                var repairUs: Double?
                if let repair {
                    let repairStart = BenchClock.mark()
                    let repaired = repair.engine.repair(cleaned)
                    let repairEnd = BenchClock.mark()
                    checksum &+= repaired.text.utf8.count
                    repairUs = Self.microseconds(from: repairStart, to: repairEnd)
                }

                let full = Self.microseconds(from: fullStart, to: fullEnd)
                let tail = Double(native.decodeMicroseconds + native.predictMicroseconds + native.sampleMicroseconds)
                let mel = Double(native.melMicroseconds)
                let encode = Double(native.encodeMicroseconds)
                try writer.write(
                    StageProfileRow(
                        rowID: entry.row.id,
                        pass: pass,
                        seq: seq,
                        audioS: entry.row.audioS ?? Double(samples.count) / Double(WAVFile.requiredSampleRate),
                        stagesUs: StageProfileStages(
                            wavRead: Self.microseconds(from: wavStart, to: wavEnd),
                            mel: mel,
                            encode: encode,
                            tail: tail,
                            assemble: Self.microseconds(from: assembleStart, to: assembleEnd),
                            full: full,
                            cleanup: Self.microseconds(from: cleanupStart, to: cleanupEnd),
                            repair: repairUs
                        ),
                        tailPartsUs: StageProfileTailParts(
                            decode: Double(native.decodeMicroseconds),
                            predict: Double(native.predictMicroseconds),
                            sample: Double(native.sampleMicroseconds)
                        ),
                        fullUnattributedUs: full - mel - encode - tail,
                        counts: StageProfileCounts(
                            melFrames: context.storedMelFrameCount,
                            encoderFrames: context.storedEncoderFrameCount ?? 0,
                            tokens: segments.reduce(0) { $0 + $1.tokens.count },
                            decodeSteps: native.decodeCount,
                            predictions: native.predictCount,
                            encodes: native.encodeCount
                        )
                    )
                )
                seq += 1

                if let client {
                    let requestStart = BenchClock.mark()
                    let result = try await client.transcribe(sidecarAudio[offset], timeoutMs: options.timeoutMs)
                    let requestEnd = BenchClock.mark()
                    try writer.write(
                        SidecarRoundTripRow(
                            rowID: entry.row.id,
                            pass: pass,
                            seq: seq,
                            clientUs: Self.microseconds(from: requestStart, to: requestEnd),
                            sidecarInferenceMs: result.timingsMs.inference,
                            textEqual: result.transcript.text.utf8.elementsEqual(transcript.text.utf8)
                        )
                    )
                    seq += 1
                }
            }
            print("stage-profile pass \(pass) done: \(rows.count) rows")
        }
        print("wrote \(seq) timed rows to \(options.output.path) (text checksum \(checksum))")
    }

    /// Launches the sidecar and returns once it holds the model; its preload then runs one
    /// throwaway decode, which the first request waits behind.
    private static func waitUntilLoaded(_ client: any ASRClienting, timeoutMs: Int) async throws {
        await client.warmUp()
        let deadline = BenchClock.mark() + UInt64(timeoutMs) * 1_000_000
        while true {
            let health = try await client.health(timeoutMs: timeoutMs)
            if health.modelLoaded { return }
            guard health.ready else {
                throw BenchError.io("sidecar cannot load the model: \(health)")
            }
            guard BenchClock.mark() < deadline else {
                throw BenchError.io("sidecar did not load the model within \(timeoutMs) ms")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func microseconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000 : 0
    }
}

private struct StageProfileRunMeta: Encodable {
    var gitSHA: String?
    var startedAt: String
    var host: BenchHost.Snapshot
    var arms: [String]
    var passes: Int
    var corpus: String
    var manifestSHA256: String
    var audioManifestSHA256: String
    var model: String
    var modelVariant: String
    var weightArena: String
    var threads: Int
    var sidecarBackend: String?
    var vocabularySHA256: String?
    var environment: [String: String]

    enum CodingKeys: String, CodingKey {
        case type
        case bet
        case harness
        case gitSHA = "git_sha"
        case startedAt = "started_at"
        case host
        case arms
        case passes
        case warmupPasses = "warmup_passes"
        case order
        case corpus
        case notes
        case manifestSHA256 = "manifest_sha256"
        case audioManifestSHA256 = "audio_manifest_sha256"
        case model
        case modelVariant = "model_variant"
        case weightArena = "weight_arena"
        case tail
        case threads
        case sidecarBackend = "sidecar_backend"
        case vocabularySHA256 = "vocabulary_sha256"
        case environment = "env"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("run_meta", forKey: .type)
        try container.encode("B0", forKey: .bet)
        try container.encode("voiceour-bench stage-profile", forKey: .harness)
        try container.encode(gitSHA, forKey: .gitSHA)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(host, forKey: .host)
        try container.encode(arms, forKey: .arms)
        try container.encode(passes, forKey: .passes)
        try container.encode(1, forKey: .warmupPasses)
        try container.encode(
            "passes 0...passes in manifest order; per row native-full, then sidecar when present",
            forKey: .order
        )
        try container.encode(corpus, forKey: .corpus)
        try container.encode(Self.notes, forKey: .notes)
        try container.encode(manifestSHA256, forKey: .manifestSHA256)
        try container.encode(audioManifestSHA256, forKey: .audioManifestSHA256)
        try container.encode(model, forKey: .model)
        try container.encode(modelVariant, forKey: .modelVariant)
        try container.encode(weightArena, forKey: .weightArena)
        try container.encode("metal", forKey: .tail)
        try container.encode(threads, forKey: .threads)
        try container.encode(sidecarBackend, forKey: .sidecarBackend)
        try container.encode(vocabularySHA256, forKey: .vocabularySHA256)
        try container.encode(environment, forKey: .environment)
    }

    private static let notes = """
        stages_us: wav_read=WAVFile.readSamples; full=wall time of one parakeet_full \
        (ParakeetContext.decodeForProfiling, the transcribe decode); mel/encode/tail=native stage \
        counters reset before that call, tail=decode+predict+sample (tail_parts_us); \
        assemble=segment collection + TokenMapping.transcript; cleanup=CleanupEngine.clean(raw, \
        glossary: []); repair=LoadedRepairEngine.engine.repair(cleaned) or null. Pass 0 is warmup. \
        The app's text stage also runs LiteralComposition.apply and cleans with the active glossary; \
        neither is in this profile.
        """
}

private struct StageProfileColdRow: Encodable {
    var initUs: Double
    var firstFullUs: Double
    var firstRowID: String
    var sidecarReadyUs: Double?
    var sidecarFirstClientUs: Double?

    enum CodingKeys: String, CodingKey {
        case type
        case initUs = "init_us"
        case firstFullUs = "first_full_us"
        case firstRowID = "first_row_id"
        case sidecarReadyUs = "sidecar_ready_us"
        case sidecarFirstClientUs = "sidecar_first_client_us"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("cold", forKey: .type)
        try container.encode(initUs, forKey: .initUs)
        try container.encode(firstFullUs, forKey: .firstFullUs)
        try container.encode(firstRowID, forKey: .firstRowID)
        try container.encode(sidecarReadyUs, forKey: .sidecarReadyUs)
        try container.encode(sidecarFirstClientUs, forKey: .sidecarFirstClientUs)
    }
}

private struct StageProfileRow: Encodable {
    var type = "stage_profile"
    var rowID: String
    var pass: Int
    var seq: Int
    var audioS: Double
    var stagesUs: StageProfileStages
    var tailPartsUs: StageProfileTailParts
    var fullUnattributedUs: Double
    var counts: StageProfileCounts

    enum CodingKeys: String, CodingKey {
        case type
        case rowID = "row_id"
        case pass
        case seq
        case audioS = "audio_s"
        case stagesUs = "stages_us"
        case tailPartsUs = "tail_parts_us"
        case fullUnattributedUs = "full_unattributed_us"
        case counts
    }
}

private struct StageProfileStages: Encodable {
    var wavRead: Double
    var mel: Double
    var encode: Double
    var tail: Double
    var assemble: Double
    var full: Double
    var cleanup: Double
    var repair: Double?

    enum CodingKeys: String, CodingKey {
        case wavRead = "wav_read"
        case mel
        case encode
        case tail
        case assemble
        case full
        case cleanup
        case repair
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wavRead, forKey: .wavRead)
        try container.encode(mel, forKey: .mel)
        try container.encode(encode, forKey: .encode)
        try container.encode(tail, forKey: .tail)
        try container.encode(assemble, forKey: .assemble)
        try container.encode(full, forKey: .full)
        try container.encode(cleanup, forKey: .cleanup)
        try container.encode(repair, forKey: .repair)
    }
}

private struct StageProfileTailParts: Encodable {
    var decode: Double
    var predict: Double
    var sample: Double
}

private struct StageProfileCounts: Encodable {
    var melFrames: Int
    var encoderFrames: Int
    var tokens: Int
    var decodeSteps: Int
    var predictions: Int
    var encodes: Int

    enum CodingKeys: String, CodingKey {
        case melFrames = "n_mel_frames"
        case encoderFrames = "n_enc_frames"
        case tokens = "n_tokens"
        case decodeSteps = "n_decode_steps"
        case predictions = "n_predict"
        case encodes = "n_encode"
    }
}

private struct SidecarRoundTripRow: Encodable {
    var type = "sidecar_rt"
    var rowID: String
    var pass: Int
    var seq: Int
    var clientUs: Double
    var sidecarInferenceMs: Int
    var textEqual: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case rowID = "row_id"
        case pass
        case seq
        case clientUs = "client_us"
        case sidecarInferenceMs = "sidecar_inference_ms"
        case textEqual = "text_equal"
    }
}

/// Host facts a benchmark row is only comparable under.
enum BenchHost {
    struct Snapshot: Encodable {
        var chip: String?
        var os: String
        var osBuild: String?
        var power: String?
        var loadAverage: [Double]
        var cpuThreads: Int
        var performanceCores: Int?
        var efficiencyCores: Int?
        var memoryBytes: UInt64

        enum CodingKeys: String, CodingKey {
            case chip
            case os
            case osBuild = "os_build"
            case power
            case loadAverage = "load_avg"
            case cpuThreads = "cpu_threads"
            case performanceCores = "perf_cores"
            case efficiencyCores = "eff_cores"
            case memoryBytes = "memory_bytes"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(chip, forKey: .chip)
            try container.encode(os, forKey: .os)
            try container.encode(osBuild, forKey: .osBuild)
            try container.encode(power, forKey: .power)
            try container.encode(loadAverage, forKey: .loadAverage)
            try container.encode(cpuThreads, forKey: .cpuThreads)
            try container.encode(performanceCores, forKey: .performanceCores)
            try container.encode(efficiencyCores, forKey: .efficiencyCores)
            try container.encode(memoryBytes, forKey: .memoryBytes)
        }
    }

    static func snapshot() -> Snapshot {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) != 3 {
            loads = []
        }
        return Snapshot(
            chip: sysctlString("machdep.cpu.brand_string"),
            os: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osBuild: sysctlString("kern.osversion"),
            power: powerSource(),
            loadAverage: loads,
            cpuThreads: sysctlInteger("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            performanceCores: sysctlInteger("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInteger("hw.perflevel1.physicalcpu"),
            memoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    static func gitSHA() -> String? {
        run("/usr/bin/git", ["rev-parse", "HEAD"])
    }

    /// `pmset -g batt`'s first line names the source: "Now drawing from 'AC Power'".
    static func powerSource() -> String? {
        guard let output = run("/usr/bin/pmset", ["-g", "batt"]),
            let open = output.firstIndex(of: "'")
        else {
            return nil
        }
        let rest = output[output.index(after: open)...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<close])
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func sysctlInteger(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<Int32>.size: return Int(Int32(truncatingIfNeeded: value))
        case MemoryLayout<Int64>.size: return Int(value)
        default: return nil
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

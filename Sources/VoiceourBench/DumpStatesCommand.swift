import ASRSidecarCore
import Foundation
import VoiceCore

/// Encoder-state dumps for the Rust rewrite benchmarks, one directory per corpus.
///
/// Per manifest row this runs the production native decode — `ParakeetContext.transcribe` into
/// `parakeet_full` on the Metal tail, with the sidecar's weight arena and thread count — and
/// dumps what that one decode left in the default state: the native mel as `<n>.mel.f32`
/// (`[frames][128]`) and the Metal encoder output its TDT tail read as `<n>.enc.f32`
/// (`[frames][1024]`), both raw little-endian F32, plus the tail's tokens as `ref`. The enc file
/// is then read back from disk and replayed through the unchanged external-encoder tail twice:
/// on the same Metal-tail context, where it must reproduce `ref` exactly
/// (`ref_roundtrip_equal`), and on an opt-in CPU-tail context, which yields `ref_cpu`.
///
/// `index.jsonl` (one object per manifest row, in manifest order) and `dump_meta.json` are
/// written atomically after every row is dumped, so a directory holding an index is complete.
struct DumpStatesCommand {
    var options: BenchOptions

    func run() throws {
        let rows = try GlossaryConditioningContract.readManifest(at: options.input)
        print("validated \(rows.count) manifest rows")

        let directory = options.output
        let indexURL = directory.appendingPathComponent("index.jsonl")
        let metaURL = directory.appendingPathComponent("dump_meta.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BenchError.io("cannot create \(directory.path): \(BenchError.describe(error))")
        }
        // A dump's index is a downstream input; a second pass belongs in a fresh directory.
        for url in [indexURL, metaURL] where FileManager.default.fileExists(atPath: url.path) {
            throw BenchError.io("refusing to overwrite \(url.path)")
        }

        let model = try Self.resolveModel(options.model)
        let reference = try ParakeetContext(
            modelPath: model.url.path,
            weightArenaPath: model.weightArenaPath
        )
        // No weight arena: the sidecar's `.tail-cpu` arena would be created inside the app's
        // model cache. Arenas only place weights, so the tail's arithmetic is the same.
        let cpuTail = try ParakeetContext(
            modelPath: model.url.path,
            weightArenaPath: nil,
            tailBackendCPU: true,
            persistentCPUPool: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var index = Data()
        var summary = DumpSummary()
        for (number, entry) in rows.enumerated() {
            let row = try dumpRow(
                number: number,
                input: entry.row,
                audioURL: entry.audio,
                directory: directory,
                reference: reference,
                cpuTail: cpuTail
            )
            summary.record(row)
            index.append(try encoder.encode(row))
            index.append(0x0A)
        }

        try Self.write(index, to: indexURL)
        try Self.write(
            try JSONSerialization.data(
                withJSONObject: try meta(
                    model: model,
                    reference: reference,
                    cpuTail: cpuTail,
                    summary: summary
                ),
                options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            ),
            to: metaURL
        )

        print(
            "wrote \(summary.rows) rows to \(directory.path): "
                + "ref_roundtrip_equal=\(summary.roundTripEqual)/\(summary.rows) "
                + "ref_cpu_tokens_differ=\(summary.rows - summary.cpuTokensEqual) "
                + "ref_cpu_identical=\(summary.cpuIdentical) "
                + "mel_recompute_equal=\(summary.melRecomputeEqual)/\(summary.rows) "
                + "mel_bytes=\(summary.melBytes) enc_bytes=\(summary.encBytes)"
        )
        print("index.jsonl sha256=\(try BenchRunner.sha256(of: indexURL))")
        guard summary.roundTripEqual == summary.rows else {
            throw BenchError.io(
                "\(summary.rows - summary.roundTripEqual) rows did not reproduce ref through the Metal round trip"
            )
        }
    }

    private func dumpRow(
        number: Int,
        input: PipelineInputRow,
        audioURL: URL,
        directory: URL,
        reference: ParakeetContext,
        cpuTail: ParakeetContext
    ) throws -> DumpIndexRow {
        let samples = try WAVFile.readSamples(at: audioURL)
        let segments = try reference.transcribe(samples: samples, isCancelled: { false })
        let ref = DumpReference(tokens: reference.decodedNativeTokens().flatMap { $0 }, segments: segments)

        guard let mel = reference.storedMel(),
            mel.frameCount == GlossaryConditioningContract.melFrameCount(sampleCount: samples.count)
        else {
            throw BenchError.io("\(input.id): stored mel does not cover \(samples.count) samples")
        }
        guard let states = reference.storedEncoderStates(),
            states.frameCount == GlossaryConditioningContract.encoderFrameCount(melFrameCount: mel.frameCount)
        else {
            throw BenchError.io("\(input.id): stored encoder output does not match \(mel.frameCount) mel frames")
        }
        if let offending = states.values.firstIndex(where: { !$0.isFinite }) {
            throw BenchError.io(
                "\(input.id): non-finite encoder state at frame \(offending / ParakeetContext.encoderStateWidth), channel \(offending % ParakeetContext.encoderStateWidth)"
            )
        }

        let melFile = "\(number).mel.f32"
        let encFile = "\(number).enc.f32"
        let melData = Self.bytes(of: mel.values)
        let encData = Self.bytes(of: states.values)
        try Self.write(melData, to: directory.appendingPathComponent(melFile))
        try Self.write(encData, to: directory.appendingPathComponent(encFile))

        // Both replays read the states back from disk, so the round trip vouches for the file.
        let replayed = try Self.readFloats(directory.appendingPathComponent(encFile))
        guard replayed.count == states.values.count else {
            throw BenchError.io("\(input.id): \(encFile) read back \(replayed.count) floats")
        }

        let roundTripSegments = try replayed.withUnsafeBufferPointer { buffer in
            try reference.transcribeWithExternalStates(
                samples: samples,
                states: buffer,
                frameCount: states.frameCount,
                tailThreadCount: reference.decodeThreadCount,
                isCancelled: { false }
            )
        }
        let roundTrip = DumpReference(
            tokens: reference.decodedNativeTokens().flatMap { $0 },
            segments: roundTripSegments
        )
        // That replay recomputed the mel through `parakeet_pcm_to_mel`, the contract's own
        // definition of the dumped mel; agreement shows the frontend is deterministic.
        let melRecomputeEqual = reference.storedMel().map { Self.bitwiseEqual($0.values, mel.values) } ?? false

        let cpuSegments = try replayed.withUnsafeBufferPointer { buffer in
            try cpuTail.transcribeWithExternalStates(
                samples: samples,
                states: buffer,
                frameCount: states.frameCount,
                tailThreadCount: cpuTail.decodeThreadCount,
                isCancelled: { false }
            )
        }
        let cpu = DumpReference(tokens: cpuTail.decodedNativeTokens().flatMap { $0 }, segments: cpuSegments)

        let roundTripDifference = Self.firstDifference(ref.tokens, roundTrip.tokens, by: Self.identical)
        let roundTripEqual = roundTripDifference == nil && ref.text.utf8.elementsEqual(roundTrip.text.utf8)
        let cpuDifference = Self.firstDifference(ref.tokens, cpu.tokens, by: Self.canonicallyEqual)
        if !roundTripEqual {
            print(
                "ROUND TRIP MISMATCH \(input.id): first differing token \(roundTripDifference.map(String.init) ?? "none"); "
                    + "ref=\(Self.describe(ref.tokens, at: roundTripDifference)) "
                    + "replay=\(Self.describe(roundTrip.tokens, at: roundTripDifference)) "
                    + "text_equal=\(ref.text == roundTrip.text)"
            )
        }
        print(
            "dumped \(number) \(input.id) mel=\(mel.frameCount) enc=\(states.frameCount) tokens=\(ref.tokens.count) "
                + "roundtrip=\(roundTripEqual) cpu_tokens_equal=\(cpuDifference == nil)"
        )

        return DumpIndexRow(
            id: input.id,
            audioPath: input.audioPath,
            audioSHA256: input.audioSHA256.lowercased(),
            audioS: input.audioS ?? Double(samples.count) / Double(WAVFile.requiredSampleRate),
            sampleCount: samples.count,
            melFrameCount: mel.frameCount,
            melBins: ParakeetContext.NativeMel.melBins,
            encoderFrameCount: states.frameCount,
            stateWidth: ParakeetContext.encoderStateWidth,
            melFile: melFile,
            encFile: encFile,
            melSHA256: GlossaryConditioningDigest.hex(melData),
            encSHA256: GlossaryConditioningDigest.hex(encData),
            ref: ref,
            refCPU: cpu,
            roundTripEqual: roundTripEqual,
            roundTripFirstDifference: roundTripDifference,
            cpuTokensEqual: cpuDifference == nil,
            cpuFirstDifference: cpuDifference,
            cpuIdentical: Self.firstDifference(ref.tokens, cpu.tokens, by: Self.identical) == nil
                && ref.text.utf8.elementsEqual(cpu.text.utf8),
            melRecomputeEqual: melRecomputeEqual
        )
    }

    /// The pinned product cache with its weight arena, exactly as the sidecar loads it, unless
    /// `--model` names some other file, which loads without an arena.
    private static func resolveModel(_ requested: URL?) throws -> DumpModel {
        let cache = ParakeetModelCache.standard()
        if let requested,
            requested.resolvingSymlinksInPath().path != cache.modelURL.resolvingSymlinksInPath().path
        {
            guard FileManager.default.fileExists(atPath: requested.path) else {
                throw BenchError.io("model file missing: \(requested.path)")
            }
            return DumpModel(url: requested, weightArenaPath: nil)
        }
        guard cache.cacheOK() else {
            throw BenchError.io("pinned model cache is not ready: \(cache.modelURL.path)")
        }
        return DumpModel(url: cache.modelURL, weightArenaPath: cache.weightArenaURL.path)
    }

    private func meta(
        model: DumpModel,
        reference: ParakeetContext,
        cpuTail: ParakeetContext,
        summary: DumpSummary
    ) throws -> [String: Any] {
        [
            "schema": "voiceour-rust-bench-dump-v1",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "git_sha": BenchHost.gitSHA().map { $0 as Any } ?? NSNull(),
            "command": ProcessInfo.processInfo.arguments.joined(separator: " "),
            "manifest": options.input.path,
            "manifest_sha256": try BenchRunner.sha256(of: options.input),
            "audio_manifest_sha256": try BenchRunner.audioManifestSHA256(of: options.input),
            "model": [
                "path": model.url.path,
                "file": model.url.lastPathComponent,
                "weight_arena": model.weightArenaPath.map { $0 as Any } ?? NSNull(),
            ] as [String: Any],
            "layout": [
                "mel":
                    "little-endian f32 [n_mel_frames][n_mels], parakeet_get_mel_data after the production parakeet_full",
                "enc": "little-endian f32 [n_enc_frames][n_state], parakeet_copy_encoder_states after that decode",
                "tokens": "parakeet_token_data of the result segments; t0/t1 in mel frames after refine_timestamps_tdt",
                "tokens_sha256": "sha256 of '<id>:<frame_index>:<duration>' joined by ','",
                "text": "TokenMapping.transcript(from:).text, the sidecar's transcript text",
            ],
            "ref": [
                "route": "ParakeetContext.transcribe -> parakeet_full",
                "tail": "metal",
                "threads": Int(reference.decodeThreadCount),
            ] as [String: Any],
            "ref_roundtrip": [
                "route": "enc file -> parakeet_full_with_external_encoder on the ref context",
                "tail": "metal",
                "threads": Int(reference.decodeThreadCount),
            ] as [String: Any],
            "ref_cpu": [
                "route": "enc file -> parakeet_full_with_external_encoder",
                "tail": "cpu",
                "threads": Int(cpuTail.decodeThreadCount),
                "persistent_cpu_pool_threads": Int(cpuTail.decodeThreadCount),
                "weight_arena": NSNull(),
            ] as [String: Any],
            "summary": [
                "rows": summary.rows,
                "ref_roundtrip_equal": summary.roundTripEqual,
                "ref_cpu_tokens_equal": summary.cpuTokensEqual,
                "ref_cpu_tokens_differ": summary.rows - summary.cpuTokensEqual,
                "ref_cpu_identical": summary.cpuIdentical,
                "mel_recompute_equal": summary.melRecomputeEqual,
                "mel_bytes": summary.melBytes,
                "enc_bytes": summary.encBytes,
            ],
        ]
    }

    /// Bitwise for the floats, so a replay that drifts by one ulp is not "equal".
    static func identical(_ lhs: ParakeetNativeToken, _ rhs: ParakeetNativeToken) -> Bool {
        canonicallyEqual(lhs, rhs)
            && lhs.durationIndex == rhs.durationIndex
            && lhs.probability.bitPattern == rhs.probability.bitPattern
            && lhs.logProbability.bitPattern == rhs.logProbability.bitPattern
            && lhs.t0 == rhs.t0
            && lhs.t1 == rhs.t1
    }

    /// The fields the canonical token string carries.
    static func canonicallyEqual(_ lhs: ParakeetNativeToken, _ rhs: ParakeetNativeToken) -> Bool {
        lhs.id == rhs.id && lhs.frameIndex == rhs.frameIndex && lhs.duration == rhs.duration
    }

    static func firstDifference(
        _ lhs: [ParakeetNativeToken],
        _ rhs: [ParakeetNativeToken],
        by equal: (ParakeetNativeToken, ParakeetNativeToken) -> Bool
    ) -> Int? {
        for index in 0..<max(lhs.count, rhs.count) {
            guard index < lhs.count, index < rhs.count, equal(lhs[index], rhs[index]) else {
                return index
            }
        }
        return nil
    }

    private static func describe(_ tokens: [ParakeetNativeToken], at index: Int?) -> String {
        guard let index, index < tokens.count else { return "end" }
        let token = tokens[index]
        return
            "\(token.id):\(token.frameIndex):\(token.duration) idx=\(token.durationIndex) p=\(token.probability) plog=\(token.logProbability) t=\(token.t0)-\(token.t1)"
    }

    private static func bitwiseEqual(_ lhs: [Float], _ rhs: [Float]) -> Bool {
        lhs.count == rhs.count
            && lhs.withUnsafeBytes { left in rhs.withUnsafeBytes { right in left.elementsEqual(right) } }
    }

    private static func bytes(of values: [Float]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    private static func readFloats(_ url: URL) throws -> [Float] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BenchError.io("cannot read \(url.path): \(BenchError.describe(error))")
        }
        guard data.count % MemoryLayout<Float>.size == 0 else {
            throw BenchError.io("\(url.path) is \(data.count) bytes, not whole F32 values")
        }
        var values = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    private static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw BenchError.io("cannot write \(url.path): \(BenchError.describe(error))")
        }
    }
}

private struct DumpModel {
    var url: URL
    var weightArenaPath: String?
}

private struct DumpSummary {
    var rows = 0
    var roundTripEqual = 0
    var cpuTokensEqual = 0
    var cpuIdentical = 0
    var melRecomputeEqual = 0
    var melBytes = 0
    var encBytes = 0

    mutating func record(_ row: DumpIndexRow) {
        rows += 1
        if row.roundTripEqual { roundTripEqual += 1 }
        if row.cpuTokensEqual { cpuTokensEqual += 1 }
        if row.cpuIdentical { cpuIdentical += 1 }
        if row.melRecomputeEqual { melRecomputeEqual += 1 }
        melBytes += row.melFrameCount * row.melBins * MemoryLayout<Float>.size
        encBytes += row.encoderFrameCount * row.stateWidth * MemoryLayout<Float>.size
    }
}

/// One tail's answer: its tokens, the sidecar's transcript text, and the canonical token digest.
struct DumpReference: Encodable {
    var tokens: [ParakeetNativeToken]
    var text: String
    var tokensSHA256: String

    init(tokens: [ParakeetNativeToken], segments: [ParakeetSegmentRaw]) {
        self.tokens = tokens
        // The sidecar's own transcript construction (`ParakeetSidecarBackend.transcribe`).
        self.text = TokenMapping.transcript(from: segments).text
        self.tokensSHA256 = GlossaryConditioningDigest.hex(Self.canonicalString(tokens))
    }

    static func canonicalString(_ tokens: [ParakeetNativeToken]) -> String {
        tokens.map { "\($0.id):\($0.frameIndex):\($0.duration)" }.joined(separator: ",")
    }

    enum CodingKeys: String, CodingKey {
        case tokens
        case text
        case tokensSHA256 = "tokens_sha256"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tokens.map(DumpToken.init), forKey: .tokens)
        try container.encode(text, forKey: .text)
        try container.encode(tokensSHA256, forKey: .tokensSHA256)
    }
}

private struct DumpToken: Encodable {
    var id: Int32
    var frameIndex: Int32
    var durationIndex: Int32
    var duration: Int32
    var p: Float
    var plog: Float
    var t0: Int64
    var t1: Int64

    init(_ token: ParakeetNativeToken) {
        id = token.id
        frameIndex = token.frameIndex
        durationIndex = token.durationIndex
        duration = token.duration
        p = token.probability
        plog = token.logProbability
        t0 = token.t0
        t1 = token.t1
    }

    enum CodingKeys: String, CodingKey {
        case id
        case frameIndex = "frame_index"
        case durationIndex = "duration_idx"
        case duration
        case p
        case plog
        case t0
        case t1
    }
}

struct DumpIndexRow: Encodable {
    var id: String
    var audioPath: String
    var audioSHA256: String
    var audioS: Double
    var sampleCount: Int
    var melFrameCount: Int
    var melBins: Int
    var encoderFrameCount: Int
    var stateWidth: Int
    var melFile: String
    var encFile: String
    var melSHA256: String
    var encSHA256: String
    var ref: DumpReference
    var refCPU: DumpReference
    var roundTripEqual: Bool
    var roundTripFirstDifference: Int?
    var cpuTokensEqual: Bool
    var cpuFirstDifference: Int?
    var cpuIdentical: Bool
    var melRecomputeEqual: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case audioPath = "audio_path"
        case audioSHA256 = "audio_sha256"
        case audioS = "audio_s"
        case sampleCount = "n_samples"
        case melFrameCount = "n_mel_frames"
        case melBins = "n_mels"
        case encoderFrameCount = "n_enc_frames"
        case stateWidth = "n_state"
        case melFile = "mel_file"
        case encFile = "enc_file"
        case melSHA256 = "mel_sha256"
        case encSHA256 = "enc_sha256"
        case ref
        case refCPU = "ref_cpu"
        case roundTripEqual = "ref_roundtrip_equal"
        case roundTripFirstDifference = "ref_roundtrip_first_diff"
        case cpuTokensEqual = "ref_cpu_tokens_equal"
        case cpuFirstDifference = "ref_cpu_first_diff"
        case cpuIdentical = "ref_cpu_identical"
        case melRecomputeEqual = "mel_recompute_equal"
    }

    /// Absent differences encode as explicit nulls so every row has the same keys.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(audioPath, forKey: .audioPath)
        try container.encode(audioSHA256, forKey: .audioSHA256)
        try container.encode(audioS, forKey: .audioS)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encode(melFrameCount, forKey: .melFrameCount)
        try container.encode(melBins, forKey: .melBins)
        try container.encode(encoderFrameCount, forKey: .encoderFrameCount)
        try container.encode(stateWidth, forKey: .stateWidth)
        try container.encode(melFile, forKey: .melFile)
        try container.encode(encFile, forKey: .encFile)
        try container.encode(melSHA256, forKey: .melSHA256)
        try container.encode(encSHA256, forKey: .encSHA256)
        try container.encode(ref, forKey: .ref)
        try container.encode(refCPU, forKey: .refCPU)
        try container.encode(roundTripEqual, forKey: .roundTripEqual)
        try container.encode(roundTripFirstDifference, forKey: .roundTripFirstDifference)
        try container.encode(cpuTokensEqual, forKey: .cpuTokensEqual)
        try container.encode(cpuFirstDifference, forKey: .cpuFirstDifference)
        try container.encode(cpuIdentical, forKey: .cpuIdentical)
        try container.encode(melRecomputeEqual, forKey: .melRecomputeEqual)
    }
}

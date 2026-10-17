import ASRSidecarCore
import CryptoKit
import Darwin
import Foundation

/// Shared pieces of the Rust rewrite proof program's paired harness (`tail-bench`, `mel-bench`,
/// `encoder-bench`): the dump reader, the common `run_meta`/`timing` rows, arm ordering, and
/// output comparisons. Row and dump formats are the program contract's.
enum RustBench {
    /// TDT emits at most `n_max_tokens` symbols per encoder frame (model fact, parakeet.cpp).
    static let maxTokensPerFrame = 10
    /// Headroom past the expected frame count, so an arm that over- or under-produces is
    /// measured and reported instead of overflowing.
    static let frameSlack = 16

    static func expectedMelFrames(sampleCount: Int) -> Int {
        GlossaryConditioningContract.melFrameCount(sampleCount: sampleCount)
    }

    static func expectedEncoderFrames(melFrameCount: Int) -> Int {
        GlossaryConditioningContract.encoderFrameCount(melFrameCount: melFrameCount)
    }

    static func microseconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000 : 0
    }

    /// The arm orders rows rotate through: a Williams design, i.e. the cyclic Latin square
    /// built from the sequence `0, 1, n-1, 2, n-2, …` plus, for an odd arm count, its
    /// reversals. Every arm leads equally often, as under plain rotation, and also immediately
    /// follows every other arm equally often. Plain rotation would keep each arm's cyclic
    /// predecessor fixed, so carryover from the previous call, such as a GPU it left warm,
    /// would bias one arm (an A/A twin always running second).
    static func orderSequences(armCount: Int) -> [[Int]] {
        guard armCount > 1 else { return [Array(0..<armCount)] }
        let base = (0..<armCount).map { position in
            position == 0 ? 0 : position % 2 == 1 ? (position + 1) / 2 : armCount - position / 2
        }
        let shifted = (0..<armCount).map { shift in base.map { ($0 + shift) % armCount } }
        return armCount % 2 == 0 ? shifted : shifted + shifted.map { Array($0.reversed()) }
    }

    /// Row `row` of pass `pass` runs sequence `(pass + row) mod sequences`.
    static func ordered<Arm>(_ arms: [Arm], pass: Int, row: Int) -> [Arm] {
        let sequences = orderSequences(armCount: arms.count)
        return sequences[(pass + row) % sequences.count].map { arms[$0] }
    }

    static func orderDescription(arms: [String]) -> String {
        let count = orderSequences(armCount: arms.count).count
        return "passes 0...passes, pass 0 warmup; rows in dump index order; pass p, row index r runs Williams "
            + "sequence (p + r) mod \(count) of order_sequences (every arm leads, and immediately follows every "
            + "other arm, equally often); seq is the global execution order"
    }

    static func hex(_ bytes: UnsafeRawBufferPointer) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ values: UnsafeBufferPointer<Float>) -> String {
        hex(UnsafeRawBufferPointer(values))
    }

    static func environment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("VOICEOUR_") }
    }

    /// The pinned product cache, which every native arm loads exactly as the sidecar does.
    static func pinnedModelCache() throws -> ParakeetModelCache {
        let cache = ParakeetModelCache.standard()
        guard cache.cacheOK() else {
            throw BenchError.io("pinned model cache is not ready: \(cache.modelURL.path)")
        }
        return cache
    }

    /// Comma-separated, trimmed, non-empty, distinct.
    static func list(_ value: String, option: String) throws -> [String] {
        let items = value.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !items.contains(where: \.isEmpty), Set(items).count == items.count else {
            throw BenchError.usage("\(option) takes a comma-separated list of distinct non-empty names")
        }
        return items
    }

    static func readFloats(_ url: URL, count: Int, expectedSHA256: String?) throws -> [Float] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BenchError.io("cannot read \(url.path): \(BenchError.describe(error))")
        }
        guard data.count == count * MemoryLayout<Float>.size else {
            throw BenchError.io("\(url.path) is \(data.count) bytes, expected \(count) F32 values")
        }
        if let expectedSHA256 {
            let digest = GlossaryConditioningDigest.hex(data)
            guard digest == expectedSHA256 else {
                throw BenchError.io("\(url.path) sha256 \(digest) does not match the dump index's \(expectedSHA256)")
            }
        }
        var values = [Float](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }
}

/// Shared command-line options of the three paired commands.
struct RustBenchOptions {
    var dumps: URL
    var output: URL
    /// Measured passes, each after warmup pass 0.
    var passes: Int
    var limit: Int?
    var rustArms: [String]?

    /// Parses `arguments`, handing every option it does not own to `other`, which returns false
    /// for an option it does not know either.
    static func parse(
        _ arguments: [String],
        other: (_ parsed: (name: String, inlineValue: String?), _ index: inout Int) throws -> Bool
    ) throws -> RustBenchOptions {
        var dumps: URL?
        var output: URL?
        var passes = 1
        var limit: Int?
        var rustArms: [String]?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let parsed = BenchCLI.splitOption(arguments[index])
            switch parsed.name {
            case "--dumps":
                dumps = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--output":
                output = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--passes":
                let value = try BenchCLI.value(for: parsed, in: arguments, index: &index)
                guard let parsedPasses = Int(value), parsedPasses > 0 else {
                    throw BenchError.usage("--passes must be a positive integer")
                }
                passes = parsedPasses
            case "--limit":
                let value = try BenchCLI.value(for: parsed, in: arguments, index: &index)
                guard let parsedLimit = Int(value), parsedLimit > 0 else {
                    throw BenchError.usage("--limit must be a positive integer")
                }
                limit = parsedLimit
            case "--rust-arms":
                rustArms = try RustBench.list(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index),
                    option: "--rust-arms"
                )
            default:
                guard try other(parsed, &index) else {
                    throw BenchError.usage("unknown option: \(arguments[index])")
                }
            }
            index = arguments.index(after: index)
        }
        guard let dumps else { throw BenchError.usage("missing --dumps") }
        guard let output else { throw BenchError.usage("missing --output") }
        // Timing rows are evidence; a rerun belongs in a new file.
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw BenchError.io("refusing to overwrite \(output.path)")
        }
        return RustBenchOptions(dumps: dumps, output: output, passes: passes, limit: limit, rustArms: rustArms)
    }
}

/// One `dump-states` directory: `index.jsonl` rows plus the raw mel/enc files they name.
struct RustBenchDump {
    var directory: URL
    var corpus: String
    var rows: [RustBenchDumpRow]
    var provenance: RustBenchDumpProvenance

    static func load(_ directory: URL, limit: Int?) throws -> RustBenchDump {
        let indexURL = directory.appendingPathComponent("index.jsonl")
        let metaURL = directory.appendingPathComponent("dump_meta.json")
        // dump-states writes both only after every row is on disk.
        for url in [indexURL, metaURL] where !FileManager.default.fileExists(atPath: url.path) {
            throw BenchError.io("\(directory.path) is not a complete dump: \(url.lastPathComponent) is missing")
        }

        let reader = try JSONLLineReader(url: indexURL)
        let decoder = JSONDecoder()
        var rows: [RustBenchDumpRow] = []
        var seen = Set<String>()
        var lineNumber = 0
        while let line = try reader.nextLine() {
            lineNumber += 1
            let row: RustBenchDumpRow
            do {
                row = try decoder.decode(RustBenchDumpRow.self, from: Data(line.utf8))
            } catch {
                throw BenchError.malformedInput(line: lineNumber, detail: "index.jsonl: \(BenchError.describe(error))")
            }
            guard seen.insert(row.id).inserted else {
                throw BenchError.malformedInput(line: lineNumber, detail: "index.jsonl: duplicate id \(row.id)")
            }
            try row.validate()
            rows.append(row)
        }
        guard !rows.isEmpty else { throw BenchError.io("\(indexURL.path) has no rows") }
        let total = rows.count
        if let limit {
            rows = Array(rows.prefix(limit))
        }

        let metaData: Data
        let meta: [String: Any]
        do {
            metaData = try Data(contentsOf: metaURL)
            meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] ?? [:]
        } catch {
            throw BenchError.io("cannot read \(metaURL.path): \(BenchError.describe(error))")
        }
        return RustBenchDump(
            directory: directory,
            corpus: directory.lastPathComponent,
            rows: rows,
            provenance: RustBenchDumpProvenance(
                path: directory.path,
                schema: meta["schema"] as? String,
                createdAt: meta["created_at"] as? String,
                gitSHA: meta["git_sha"] as? String,
                manifest: meta["manifest"] as? String,
                model: (meta["model"] as? [String: Any])?["path"] as? String,
                indexSHA256: try BenchRunner.sha256(of: indexURL),
                metaSHA256: GlossaryConditioningDigest.hex(metaData),
                rowsTotal: total,
                rowsUsed: rows.count
            )
        )
    }

    /// The row's dumped mel, `[n_mel_frames][n_mels]`; digest-checked against the index when
    /// `validate`.
    func mel(_ row: RustBenchDumpRow, validate: Bool) throws -> [Float] {
        try RustBench.readFloats(
            directory.appendingPathComponent(row.melFile),
            count: row.melFrameCount * row.melBins,
            expectedSHA256: validate ? row.melSHA256 : nil
        )
    }

    /// The row's dumped native encoder output, `[n_enc_frames][n_state]`.
    func enc(_ row: RustBenchDumpRow, validate: Bool) throws -> [Float] {
        try RustBench.readFloats(
            directory.appendingPathComponent(row.encFile),
            count: row.encoderFrameCount * row.stateWidth,
            expectedSHA256: validate ? row.encSHA256 : nil
        )
    }
}

struct RustBenchDumpProvenance: Encodable {
    var path: String
    var schema: String?
    var createdAt: String?
    var gitSHA: String?
    var manifest: String?
    var model: String?
    var indexSHA256: String
    var metaSHA256: String
    var rowsTotal: Int
    var rowsUsed: Int

    enum CodingKeys: String, CodingKey {
        case path
        case schema
        case createdAt = "created_at"
        case gitSHA = "git_sha"
        case manifest
        case model
        case indexSHA256 = "index_sha256"
        case metaSHA256 = "meta_sha256"
        case rowsTotal = "rows_total"
        case rowsUsed = "rows_used"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(schema, forKey: .schema)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(gitSHA, forKey: .gitSHA)
        try container.encode(manifest, forKey: .manifest)
        try container.encode(model, forKey: .model)
        try container.encode(indexSHA256, forKey: .indexSHA256)
        try container.encode(metaSHA256, forKey: .metaSHA256)
        try container.encode(rowsTotal, forKey: .rowsTotal)
        try container.encode(rowsUsed, forKey: .rowsUsed)
    }
}

/// The fields of a `dump-states` index row this harness reads.
struct RustBenchDumpRow: Decodable {
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
    var ref: RustBenchReference
    var refCPU: RustBenchReference

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
    }

    /// The model geometry and frame arithmetic the native seams check, plus a recomputation of
    /// both references' canonical token digests, so a row this harness misreads stops here.
    func validate() throws {
        guard melBins == ParakeetContext.NativeMel.melBins, stateWidth == ParakeetContext.encoderStateWidth else {
            throw BenchError.io("\(id): dump geometry is \(melBins) mels x \(stateWidth) states")
        }
        guard melFrameCount == RustBench.expectedMelFrames(sampleCount: sampleCount),
            encoderFrameCount == RustBench.expectedEncoderFrames(melFrameCount: melFrameCount)
        else {
            throw BenchError.io(
                "\(id): \(sampleCount) samples, \(melFrameCount) mel and \(encoderFrameCount) encoder frames disagree"
            )
        }
        for (name, reference) in [("ref", ref), ("ref_cpu", refCPU)] {
            let digest = RustBenchToken.canonicalSHA256(reference.tokens.map(RustBenchToken.init))
            guard digest == reference.tokensSHA256 else {
                throw BenchError.io("\(id): \(name) tokens hash to \(digest), the index says \(reference.tokensSHA256)")
            }
        }
    }
}

struct RustBenchReference: Decodable {
    var tokens: [RustBenchReferenceToken]
    var text: String
    var tokensSHA256: String

    enum CodingKeys: String, CodingKey {
        case tokens
        case text
        case tokensSHA256 = "tokens_sha256"
    }
}

struct RustBenchReferenceToken: Decodable {
    var id: Int32
    var frameIndex: Int32
    var durationIndex: Int32
    var duration: Int32
    var p: Float
    var plog: Float

    enum CodingKeys: String, CodingKey {
        case id
        case frameIndex = "frame_index"
        case durationIndex = "duration_idx"
        case duration
        case p
        case plog
    }
}

/// One decoded token in the fields every tail reports (native, Rust, and dumped references).
struct RustBenchToken: Equatable {
    var id: Int32
    var frameIndex: Int32
    var durationIndex: Int32
    var duration: Int32
    var p: Float
    var plog: Float

    init(_ token: ParakeetNativeToken) {
        self.init(
            token.id, token.frameIndex, token.durationIndex, token.duration, token.probability, token.logProbability)
    }

    init(_ token: RustTailToken) {
        self.init(token.id, token.frameIndex, token.durationIndex, token.duration, token.p, token.plog)
    }

    init(_ token: RustBenchReferenceToken) {
        self.init(token.id, token.frameIndex, token.durationIndex, token.duration, token.p, token.plog)
    }

    private init(_ id: Int32, _ frameIndex: Int32, _ durationIndex: Int32, _ duration: Int32, _ p: Float, _ plog: Float)
    {
        self.id = id
        self.frameIndex = frameIndex
        self.durationIndex = durationIndex
        self.duration = duration
        self.p = p
        self.plog = plog
    }

    /// The contract's canonical token string: `<id>:<frame_index>:<duration>` joined by `,`.
    static func canonicalString(_ tokens: [RustBenchToken]) -> String {
        tokens.map { "\($0.id):\($0.frameIndex):\($0.duration)" }.joined(separator: ",")
    }

    static func canonicalSHA256(_ tokens: [RustBenchToken]) -> String {
        GlossaryConditioningDigest.hex(canonicalString(tokens))
    }

    func canonicallyEqual(_ other: RustBenchToken) -> Bool {
        id == other.id && frameIndex == other.frameIndex && duration == other.duration
    }

    /// Every field, the floats bitwise.
    func identical(_ other: RustBenchToken) -> Bool {
        canonicallyEqual(other) && durationIndex == other.durationIndex
            && p.bitPattern == other.p.bitPattern && plog.bitPattern == other.plog.bitPattern
    }
}

/// A tail's tokens judged against a dumped reference.
struct RustBenchTokenComparison {
    var tokensSHA256: String
    var equalRef: Bool
    /// First token index whose canonical fields differ; nil when the sequences agree.
    var firstDifference: Int?
    var identicalRef: Bool
    /// `plog` error against the reference's, defined only when the canonical sequences agree
    /// and are not empty.
    var plogErr: RustBenchErr?
    var pMaxAbs: Double?

    init(_ tokens: [RustBenchToken], reference: RustBenchReference) {
        let expected = reference.tokens.map(RustBenchToken.init)
        tokensSHA256 = RustBenchToken.canonicalSHA256(tokens)
        equalRef = tokensSHA256 == reference.tokensSHA256
        firstDifference = (0..<max(tokens.count, expected.count)).first { index in
            index >= tokens.count || index >= expected.count || !tokens[index].canonicallyEqual(expected[index])
        }
        identicalRef = tokens.count == expected.count && zip(tokens, expected).allSatisfy { $0.identical($1) }
        guard firstDifference == nil, !tokens.isEmpty else { return }
        let plog = tokens.map(\.plog)
        let expectedPlog = expected.map(\.plog)
        plogErr = plog.withUnsafeBufferPointer { candidate in
            expectedPlog.withUnsafeBufferPointer { reference in
                RustBenchComparison(candidate, reference: reference).err
            }
        }
        pMaxAbs = zip(tokens, expected).map { abs(Double($0.p) - Double($1.p)) }.max()
    }
}

/// What a native encoder-plus-tail decode left in a context: its tokens and the sidecar's text.
struct RustBenchTranscript {
    /// The sidecar's transcript text itself, so a consumer can score it. Result rows carry it
    /// only for the public benchmark corpora (`RustBenchDump.requirePublicText`).
    var text: String
    var tokensSHA256: String
    var textSHA256: String
    var tokenCount: Int
    var tokensEqualRef: Bool
    var textEqualRef: Bool

    init(collectingFrom context: ParakeetContext, reference: RustBenchReference) {
        let tokens = context.decodedNativeTokens().flatMap { $0 }.map(RustBenchToken.init)
        // The sidecar's own transcript construction (`ParakeetSidecarBackend.transcribe`).
        let text = TokenMapping.transcript(from: context.collectDecodedSegments()).text
        self.text = text
        tokensSHA256 = RustBenchToken.canonicalSHA256(tokens)
        textSHA256 = GlossaryConditioningDigest.hex(text)
        tokenCount = tokens.count
        tokensEqualRef = tokensSHA256 == reference.tokensSHA256
        textEqualRef = text.utf8.elementsEqual(reference.text.utf8)
    }
}

/// A float output against its reference: bitwise identity plus the contract's error measures.
struct RustBenchComparison {
    var identical: Bool
    var maxAbs: Double
    var relL2: Double
    /// Non-finite candidate values; any makes the error undefined.
    var nonFinite: Int

    init(_ candidate: UnsafeBufferPointer<Float>, reference: UnsafeBufferPointer<Float>) {
        precondition(candidate.count == reference.count)
        identical =
            candidate.isEmpty
            || memcmp(candidate.baseAddress, reference.baseAddress, candidate.count * MemoryLayout<Float>.size) == 0
        var maxAbs = 0.0
        var differenceSquares = 0.0
        var referenceSquares = 0.0
        var nonFinite = 0
        for index in 0..<candidate.count {
            let value = Double(candidate[index])
            let expected = Double(reference[index])
            guard value.isFinite else {
                nonFinite += 1
                continue
            }
            let difference = abs(value - expected)
            maxAbs = max(maxAbs, difference)
            differenceSquares += difference * difference
            referenceSquares += expected * expected
        }
        self.maxAbs = maxAbs
        // An all-zero reference has no relative scale; report the absolute L2 distance.
        relL2 =
            referenceSquares > 0 ? (differenceSquares / referenceSquares).squareRoot() : differenceSquares.squareRoot()
        self.nonFinite = nonFinite
    }

    var err: RustBenchErr? {
        guard nonFinite == 0, maxAbs.isFinite, relL2.isFinite else { return nil }
        return RustBenchErr(maxAbs: maxAbs, relL2: relL2)
    }
}

struct RustBenchErr: Encodable {
    var maxAbs: Double
    var relL2: Double

    enum CodingKeys: String, CodingKey {
        case maxAbs = "max_abs"
        case relL2 = "rel_l2"
    }
}

/// One `timing` row of the program's common format.
struct RustBenchTimingRow<Work: Encodable>: Encodable {
    var bet: String
    var arm: String
    var rowID: String
    var pass: Int
    var seq: Int
    /// Nil when the arm's call failed, so the analyzer reports the row as invalid instead of
    /// timing it.
    var elapsedUs: Double?
    var outputSHA256: String?
    var equalRef: Bool?
    var audioS: Double?
    var work: Work
    var err: RustBenchErr?

    enum CodingKeys: String, CodingKey {
        case type
        case bet
        case arm
        case rowID = "row_id"
        case pass
        case seq
        case elapsedUs = "elapsed_us"
        case outputSHA256 = "output_sha256"
        case equalRef = "equal_ref"
        case audioS = "audio_s"
        case work
        case err
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("timing", forKey: .type)
        try container.encode(bet, forKey: .bet)
        try container.encode(arm, forKey: .arm)
        try container.encode(rowID, forKey: .rowID)
        try container.encode(pass, forKey: .pass)
        try container.encode(seq, forKey: .seq)
        try container.encode(elapsedUs, forKey: .elapsedUs)
        try container.encode(outputSHA256, forKey: .outputSHA256)
        try container.encode(equalRef, forKey: .equalRef)
        try container.encode(audioS, forKey: .audioS)
        try container.encode(work, forKey: .work)
        try container.encode(err, forKey: .err)
    }
}

/// One loaded Rust library and the arms this run drives from it.
struct RustBenchLibraryInfo: Encodable {
    var path: String
    var sha256: String
    var abi: String
    var abiVersion: Int32
    var engine: String?
    var armsAvailable: [String]
    var armsSelected: [String]
    /// `<prefix>_engine_new` wall time per selected arm.
    var engineInitUs: [String: Double]

    init(_ library: RustArmLibrary, engine: String? = nil, selected: [String], engineInitUs: [String: Double]) {
        path = library.url.path
        sha256 = library.sha256
        abi = library.abi.rawValue
        abiVersion = RustArmLibrary.abiVersion
        self.engine = engine
        armsAvailable = library.arms
        armsSelected = selected
        self.engineInitUs = engineInitUs
    }

    enum CodingKeys: String, CodingKey {
        case path
        case sha256
        case abi
        case abiVersion = "abi_version"
        case engine
        case armsAvailable = "arms_available"
        case armsSelected = "arms_selected"
        case engineInitUs = "engine_init_us"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(abi, forKey: .abi)
        try container.encode(abiVersion, forKey: .abiVersion)
        try container.encode(engine, forKey: .engine)
        try container.encode(armsAvailable, forKey: .armsAvailable)
        try container.encode(armsSelected, forKey: .armsSelected)
        try container.encode(engineInitUs, forKey: .engineInitUs)
    }
}

/// The common `run_meta` line, with each command's own settings under `config`.
struct RustBenchRunMeta<Config: Encodable>: Encodable {
    var bet: String
    var harness: String
    var startedAt: String
    var host: BenchHost.Snapshot
    var arms: [String]
    var passes: Int
    var corpus: String
    var notes: String
    var dump: RustBenchDumpProvenance
    var model: String
    var weightArena: String?
    var threads: Int
    var libraries: [RustBenchLibraryInfo]
    /// What ran, hashed once before the first timed loop.
    var provenance: RustBenchProvenance
    var config: Config

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
        case orderSequences = "order_sequences"
        case corpus
        case notes
        case dump
        case model
        case weightArena = "weight_arena"
        case threads
        case libraries
        case environment = "env"
        case config
        case completionRequired = "completion_required"
        case executablePath = "executable_path"
        case executableSHA256 = "executable_sha256"
        case executableBytes = "executable_bytes"
        case gitDirty = "git_dirty"
        case gitStatusEntries = "git_status_entries"
        case gitStatusSHA256 = "git_status_sha256"
        case gitTrackedSourceDiffSHA256 = "git_tracked_source_diff_sha256"
        case gitUntrackedSourceSHA256 = "git_untracked_source_sha256"
        case vendorPatchSetSHA256 = "vendor_patch_set_sha256"
        case vendorPatchCount = "vendor_patch_count"
        case vendorParakeetSourcesSHA256 = "vendor_parakeet_sources_sha256"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("run_meta", forKey: .type)
        try container.encode(bet, forKey: .bet)
        try container.encode(harness, forKey: .harness)
        try container.encode(BenchHost.gitSHA(), forKey: .gitSHA)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(host, forKey: .host)
        try container.encode(arms, forKey: .arms)
        try container.encode(passes, forKey: .passes)
        try container.encode(1, forKey: .warmupPasses)
        try container.encode(RustBench.orderDescription(arms: arms), forKey: .order)
        try container.encode(
            RustBench.orderSequences(armCount: arms.count).map { $0.map { arms[$0] } },
            forKey: .orderSequences
        )
        try container.encode(corpus, forKey: .corpus)
        try container.encode(notes, forKey: .notes)
        try container.encode(dump, forKey: .dump)
        try container.encode(model, forKey: .model)
        try container.encode(weightArena, forKey: .weightArena)
        try container.encode(threads, forKey: .threads)
        try container.encode(libraries, forKey: .libraries)
        try container.encode(RustBench.environment(), forKey: .environment)
        try container.encode(config, forKey: .config)
        // A file without its closing `run_end` line, or whose `run_end` reports failures or a
        // short grid, is not evidence.
        try container.encode(true, forKey: .completionRequired)
        try container.encode(provenance.executablePath, forKey: .executablePath)
        try container.encode(provenance.executableSHA256, forKey: .executableSHA256)
        try container.encode(provenance.executableBytes, forKey: .executableBytes)
        try container.encode(provenance.gitDirty, forKey: .gitDirty)
        try container.encode(provenance.gitStatusEntries, forKey: .gitStatusEntries)
        try container.encode(provenance.gitStatusSHA256, forKey: .gitStatusSHA256)
        try container.encode(provenance.gitTrackedSourceDiffSHA256, forKey: .gitTrackedSourceDiffSHA256)
        try container.encode(provenance.gitUntrackedSourceSHA256, forKey: .gitUntrackedSourceSHA256)
        try container.encode(provenance.vendorPatchSetSHA256, forKey: .vendorPatchSetSHA256)
        try container.encode(provenance.vendorPatchCount, forKey: .vendorPatchCount)
        try container.encode(provenance.vendorParakeetSourcesSHA256, forKey: .vendorParakeetSourcesSHA256)
    }
}

/// Console tally per arm, printed when a run ends: measured-pass medians and identity counts.
struct RustBenchSummary {
    private let arms: [String]
    private var elapsed: [String: [Double]] = [:]
    private var equal: [String: Int] = [:]
    private var unequal: [String: Int] = [:]
    private var failed: [String: Int] = [:]

    init(arms: [String]) {
        self.arms = arms
    }

    mutating func record(arm: String, pass: Int, elapsedUs: Double?, equalRef: Bool?) {
        guard let elapsedUs else {
            failed[arm, default: 0] += 1
            return
        }
        if pass > 0 {
            elapsed[arm, default: []].append(elapsedUs)
        }
        switch equalRef {
        case true?: equal[arm, default: 0] += 1
        case false?: unequal[arm, default: 0] += 1
        case nil: break
        }
    }

    func report(to output: URL, seq: Int) {
        print("wrote \(seq) timing rows to \(output.path)")
        for arm in arms {
            let sorted = (elapsed[arm] ?? []).sorted()
            let median = sorted.isEmpty ? "n/a" : String(format: "%.1f", sorted[sorted.count / 2])
            print(
                "  \(arm): measured=\(sorted.count) median_elapsed_us=\(median) "
                    + "equal_ref=\(equal[arm] ?? 0)/\((equal[arm] ?? 0) + (unequal[arm] ?? 0)) failed=\(failed[arm] ?? 0)"
            )
        }
        let failures = failed.values.reduce(0, +)
        if failures > 0 {
            fputs(
                "voiceour-bench: \(failures) arm calls failed; their rows carry elapsed_us null and work.error\n",
                stderr)
        }
    }

    /// Prints the report, writes the closing `run_end` line, and throws unless the declared grid
    /// was written in full and every arm call produced a valid result. `extraFailures` carries a
    /// command's own failure counts (an output it judged invalid); each is added to `failures`.
    func finish(
        to writer: JSONLWriter,
        bet: String,
        output: URL,
        expectedTimingRows: Int,
        writtenTimingRows: Int,
        extraFailures: [String: Int] = [:],
        informational: [String: Int] = [:]
    ) throws {
        report(to: output, seq: writtenTimingRows)
        var counts = extraFailures.filter { $0.value > 0 }
        let failedCalls = failed.values.reduce(0, +)
        if failedCalls > 0 { counts["failed_arm_calls"] = failedCalls }
        if writtenTimingRows != expectedTimingRows {
            counts["timing_row_grid_shortfall"] = abs(expectedTimingRows - writtenTimingRows)
        }
        let failures = counts.values.reduce(0, +)
        try writer.write(
            RustBenchRunEnd(
                bet: bet,
                status: failures == 0 ? "complete" : "invalid",
                expectedTimingRows: expectedTimingRows,
                writtenTimingRows: writtenTimingRows,
                failures: failures,
                counts: counts,
                informational: informational,
                error: nil
            )
        )
        guard failures == 0 else {
            let detail = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            throw BenchError.io(
                "\(bet) is invalid (\(detail)); \(output.path) is kept for diagnosis and is not evidence"
            )
        }
    }
}

/// The last line of every result file these commands write. `failures` counts failed arm calls
/// and outputs the command judged invalid; a complete file has `failures` 0 and
/// `written_timing_rows == expected_timing_rows`. A killed run has no `run_end` at all.
struct RustBenchRunEnd: Encodable {
    var bet: String
    var status: String
    var expectedTimingRows: Int
    var writtenTimingRows: Int
    var failures: Int
    /// Failure categories behind `failures`.
    var counts: [String: Int]
    /// Counts that are reported but are not failures.
    var informational: [String: Int]
    var error: String?
    var finishedAt = ISO8601DateFormatter().string(from: Date())

    enum CodingKeys: String, CodingKey {
        case type
        case bet
        case status
        case expectedTimingRows = "expected_timing_rows"
        case writtenTimingRows = "written_timing_rows"
        case failures
        case counts
        case informational
        case error
        case finishedAt = "finished_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("run_end", forKey: .type)
        try container.encode(bet, forKey: .bet)
        try container.encode(status, forKey: .status)
        try container.encode(expectedTimingRows, forKey: .expectedTimingRows)
        try container.encode(writtenTimingRows, forKey: .writtenTimingRows)
        try container.encode(failures, forKey: .failures)
        try container.encode(counts, forKey: .counts)
        try container.encode(informational, forKey: .informational)
        try container.encode(error, forKey: .error)
        try container.encode(finishedAt, forKey: .finishedAt)
    }
}

/// What ran, hashed before the first timed loop: the executable, the worktree's state, and the
/// vendored native sources and patch set it was built from. A git failure leaves its fields nil
/// (the run is not in a repository); the executable and the vendor files are required.
struct RustBenchProvenance {
    var executablePath: String
    var executableSHA256: String
    var executableBytes: Int64
    var gitDirty: Bool?
    var gitStatusEntries: Int?
    var gitStatusSHA256: String?
    var gitTrackedSourceDiffSHA256: String?
    /// Digest of every untracked file under the source paths (names and contents).
    var gitUntrackedSourceSHA256: String?
    /// Digest of every `Vendor/parakeet/patches/*.patch` (name and content, name order).
    var vendorPatchSetSHA256: String
    var vendorPatchCount: Int
    /// Digest of the vendored `parakeet.h`, `parakeet-arch.h` and `parakeet.cpp` the binary built.
    var vendorParakeetSourcesSHA256: String

    private static let sourcePaths = ["Sources", "Vendor", "Package.swift", "Package.resolved", "scripts", "bench"]

    static func capture() throws -> RustBenchProvenance {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let executableBytes = try byteCount(of: executable)
        let executableSHA256 = try BenchRunner.sha256(of: executable)

        let root =
            git(["rev-parse", "--show-toplevel"]).flatMap {
                String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let vendor = root.appendingPathComponent("Vendor/parakeet")
        let patches = try patchFiles(in: vendor.appendingPathComponent("patches"))
        let sources = ["include/parakeet.h", "src/parakeet-arch.h", "src/parakeet.cpp"].map {
            vendor.appendingPathComponent($0)
        }

        let status = git(["status", "--porcelain=v1", "-uall"])
        let diff = git(["diff", "HEAD", "--"] + sourcePaths)
        let untracked = git(["ls-files", "--others", "--exclude-standard", "-z", "--"] + sourcePaths)
        return RustBenchProvenance(
            executablePath: executable.path,
            executableSHA256: executableSHA256,
            executableBytes: executableBytes,
            gitDirty: status.map { !$0.isEmpty },
            gitStatusEntries: status.map { $0.split(separator: 0x0A).count },
            gitStatusSHA256: status.map(GlossaryConditioningDigest.hex),
            gitTrackedSourceDiffSHA256: diff.map(GlossaryConditioningDigest.hex),
            gitUntrackedSourceSHA256: try untracked.map { try untrackedDigest($0, root: root) },
            vendorPatchSetSHA256: try namedDigest(patches),
            vendorPatchCount: patches.count,
            vendorParakeetSourcesSHA256: try namedDigest(sources)
        )
    }

    private static func patchFiles(in directory: URL) throws -> [URL] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw BenchError.io("cannot list \(directory.path); run from the repository: \(BenchError.describe(error))")
        }
        let patches = names.filter { $0.hasSuffix(".patch") }.sorted().map { directory.appendingPathComponent($0) }
        guard !patches.isEmpty else { throw BenchError.io("\(directory.path) holds no patches") }
        return patches
    }

    /// sha256 over `<file name>\t<file sha256>\n` for each file, in the given order.
    private static func namedDigest(_ files: [URL]) throws -> String {
        var manifest = ""
        for file in files {
            manifest += "\(file.lastPathComponent)\t\(try BenchRunner.sha256(of: file))\n"
        }
        return GlossaryConditioningDigest.hex(manifest)
    }

    private static func untrackedDigest(_ listing: Data, root: URL) throws -> String {
        let paths = listing.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }.sorted()
        var manifest = ""
        for path in paths {
            let url = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else {
                manifest += "\(path)\t-\n"
                continue
            }
            manifest += "\(path)\t\(try BenchRunner.sha256(of: url))\n"
        }
        return GlossaryConditioningDigest.hex(manifest)
    }

    private static func byteCount(of url: URL) throws -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw BenchError.io("cannot stat \(url.path): \(BenchError.describe(error))")
        }
    }

    /// `git <arguments>` standard output, or nil when git is unavailable or fails.
    private static func git(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
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
        return process.terminationStatus == 0 ? data : nil
    }
}

extension RustBenchDump {
    /// Result rows may carry transcript text, so the corpus must be a public benchmark: every audio
    /// file lives under the repository's `benchmarks/data/`, never a recorded session.
    func requirePublicText() throws {
        for row in rows {
            let path = BenchCLI.fileURL(row.audioPath).path
            guard path.contains("/benchmarks/data/") else {
                throw BenchError.usage(
                    "\(row.id): \(path) is not under benchmarks/data/; this command emits transcript text and refuses non-public audio"
                )
            }
        }
    }
}

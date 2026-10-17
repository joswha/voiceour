import Foundation
import VoiceCore

/// What an arm runs. An arm is an implementation name, optionally suffixed `@aa` for an A/A
/// replicate with its own state.
enum Implementation: String, CaseIterable {
    /// The shipped VoiceCore code.
    case swift
    /// `Optimized` with memoization: same algorithm and output, the profile's costs removed.
    case swiftOpt = "swift-opt"
    /// `Optimized` without memoization: production's per-call work in better representations.
    case swiftOptRepr = "swift-opt-repr"
    /// The Rust port in this process, through `libvoiceour_text.dylib`.
    case rustFFI = "rust-ffi"

    init(arm: String) throws {
        let base = arm.hasSuffix("@aa") ? String(arm.dropLast(3)) : arm
        guard let implementation = Implementation(rawValue: base) else {
            let known = Implementation.allCases.map(\.rawValue).joined(separator: ", ")
            throw HarnessError.message("unknown arm \(arm); known: \(known) (each optionally suffixed @aa)")
        }
        self = implementation
    }
}

enum ParityCommand {
    /// One record per case with every stage of the text path, plus a meta line with the compiled
    /// snapshot and the repair partition. Same schema as `text-bench parity`. `--impl` picks the
    /// Swift implementation (default `swift`, the shipped code); the meta then comes from that
    /// implementation's own compile and partition, so `text-bench compare` checks them too.
    static func run(_ arguments: Arguments) throws {
        let cases = try IO.readCases(try arguments.required("cases"))
        let glossary = try IO.readGlossary(try arguments.required("glossary"))
        let implementation = try Implementation(arm: arguments.options["impl"] ?? "swift")
        let words = RepairVocabulary.bundledOrdinaryWords
        let active: [ProtectedTerm]
        let partition: (surfaces: [String], protected: [String])
        let process: (String) -> (composed: String, cleaned: String, outcome: RepairOutcome?)
        switch implementation {
        case .swift:
            active = VocabularyCompiler.compile(persistent: glossary.terms, ephemeral: []).terms
            let vocabulary = RepairVocabulary.fromActiveTerms(active, ordinaryWords: words)
            partition = (vocabulary.surfaces, vocabulary.protectedSurfaces)
            let path = ProductionTextPath()
            process = { path.processStages($0, activeTerms: active) }
        case .swiftOpt, .swiftOptRepr:
            let memoize = implementation == .swiftOpt
            active =
                memoize
                ? Optimized.compile(persistent: glossary.terms)
                : VocabularyCompiler.compile(persistent: glossary.terms, ephemeral: []).terms
            partition = Optimized.partition(active, ordinaryWords: words)
            let path = Optimized.TextPath(memoize: memoize)
            process = { path.processStages($0, activeTerms: active) }
        case .rustFFI:
            throw HarnessError.message("parity --impl rust-ffi: use `text-bench parity` for the Rust port")
        }
        var lines: [String] = []
        lines.reserveCapacity(cases.count + 1)
        lines.append(
            IO.jsonLine([
                "type": "parity_meta",
                "harness": implementation.rawValue,
                "glossary": glossary.name,
                "active": active.map(\.termId),
                "surfaces": partition.surfaces,
                "protected": partition.protected,
            ]))
        for item in cases {
            let stages = process(item.text)
            let text = stages.outcome?.text ?? stages.cleaned
            let events: [[Any]] = (stages.outcome?.events ?? []).map { event in
                [event.start, event.end, event.before, event.after, event.kind, String(format: "%016llx", event.score.bitPattern)]
            }
            lines.append(
                IO.jsonLine([
                    "id": item.id,
                    "composed": stages.composed,
                    "cleaned": stages.cleaned,
                    "out": text,
                    "out_sha256": IO.sha256Hex(text),
                    "events": events,
                ]))
        }
        try IO.writeLines(lines, to: try arguments.required("out"))
        FileHandle.standardError.write(
            Data(
                "parity[\(implementation.rawValue)]: \(cases.count) cases, glossary \(glossary.name) (\(active.count) active)\n"
                    .utf8))
    }
}

/// One arm's state: the Swift paths hold their cached engine (and, memoized, their prepared
/// glossary); the Rust engine holds the same inside the library.
private enum ArmState {
    case production(ProductionTextPath)
    case optimized(Optimized.TextPath)
    case rust(RustTextEngine)
}

enum BenchCommand {
    /// The arm run at `step` for the row at `position` of `pass`: a cyclic rotation starting at
    /// `(pass + position) % arms`, reversed on every other cycle, so each arm takes every slot
    /// equally often and follows more than one neighbour. Two arms alternate forward/reverse.
    /// Same as `bench::arm_at` in the Rust harness.
    static func armAt(_ arms: Int, visit: Int, step: Int) -> Int {
        let first = visit % arms
        return (visit / arms) % 2 == 0 ? (first + step) % arms : (first + arms - step) % arms
    }

    static func run(_ arguments: Arguments) throws {
        let stage = arguments.options["stage"] ?? "text"
        let cases = try IO.readCases(try arguments.required("cases"))
        let glossaryPath = try arguments.required("glossary")
        let glossary = try IO.readGlossary(glossaryPath)
        let passes = arguments.int("passes", 10)
        let seed = UInt64(arguments.options["seed"] ?? "") ?? 0xB3
        let arms = (arguments.options["arms"] ?? "swift,swift@aa").split(separator: ",").map(String.init)
        let engineReps = arguments.int("engine-reps", 20)
        var reference: [String: String] = [:]
        if let refPath = arguments.options["ref"] {
            for row in try IO.readJSONLines(refPath) {
                if let id = row["id"] as? String, let sha = row["out_sha256"] as? String { reference[id] = sha }
            }
        }
        let startedAt = Host.iso8601Now()

        let persistent = glossary.terms
        let active = VocabularyCompiler.compile(persistent: persistent, ephemeral: []).terms
        // Loads the bundled set once, as the first utterance of a process does.
        let words = RepairVocabulary.bundledOrdinaryWords
        let implementations = try arms.map(Implementation.init(arm:))
        var library: RustTextLibrary?
        var states: [ArmState] = []
        for implementation in implementations {
            // A warm process: an earlier utterance built the cached engine (and the prepared
            // glossary of the memoized path).
            switch implementation {
            case .swift:
                let path = ProductionTextPath()
                _ = path.repairEngine(for: active)
                states.append(.production(path))
            case .swiftOpt, .swiftOptRepr:
                let path = Optimized.TextPath(memoize: implementation == .swiftOpt)
                path.warm(activeTerms: active)
                states.append(.optimized(path))
            case .rustFFI:
                if library == nil {
                    let loaded = try RustTextLibrary(path: arguments.options["rust-lib"] ?? RustTextLibrary.defaultPath)
                    guard loaded.arms.contains(Implementation.rustFFI.rawValue) else {
                        throw HarnessError.message("\(loaded.path) advertises \(loaded.arms), not rust-ffi")
                    }
                    library = loaded
                }
                let engine = try RustTextEngine(
                    library: library!,
                    glossaryJSON: try Data(contentsOf: URL(fileURLWithPath: glossaryPath)),
                    ordinaryWordsPath: Paths.ordinaryWords,
                    arm: Implementation.rustFFI.rawValue
                )
                states.append(.rust(engine))
            }
        }
        let rowIDs: [String]
        switch stage {
        case "text", "compile", "boundary": rowIDs = cases.map(\.id)
        case "engine", "ordinary": rowIDs = (0..<engineReps).map { "\(glossary.name)#\($0)" }
        default: throw HarnessError.message("unknown stage \(stage)")
        }
        if stage == "ordinary", implementations.contains(.rustFFI) {
            throw HarnessError.message("stage ordinary has no rust-ffi arm (text-bench times the Rust load)")
        }
        if stage == "boundary", implementations.contains(where: { $0 != .rustFFI }) {
            throw HarnessError.message("stage boundary times the FFI crossing alone: rust-ffi arms only")
        }

        var rows: [String] = []
        rows.reserveCapacity(rowIDs.count * arms.count * (passes + 1))
        var seq = 0
        for pass in 0...passes {
            for (position, row) in SplitMix64.passOrder(rows: rowIDs.count, pass: pass, seed: seed).enumerated() {
                for step in 0..<arms.count {
                    let armIndex = armAt(arms.count, visit: pass + position, step: step)
                    let arm = arms[armIndex]
                    var output = ""
                    var work: [String: Any] = [:]
                    var elapsedNs: UInt64 = 0
                    switch stage {
                    case "text":
                        let raw = cases[row].text
                        switch states[armIndex] {
                        case .production(let path):
                            let start = IO.uptimeNanoseconds()
                            output = path.process(raw, activeTerms: active)
                            elapsedNs = IO.uptimeNanoseconds() - start
                        case .optimized(let path):
                            let start = IO.uptimeNanoseconds()
                            output = path.process(raw, activeTerms: active)
                            elapsedNs = IO.uptimeNanoseconds() - start
                        case .rust(let engine):
                            let start = IO.uptimeNanoseconds()
                            output = try engine.run(.text, raw)
                            elapsedNs = IO.uptimeNanoseconds() - start
                            engine.release()
                        }
                        work = [
                            "chars_in": raw.unicodeScalars.count, "chars_out": output.unicodeScalars.count,
                            "active_terms": active.count,
                        ]
                    case "boundary":
                        // The rust-ffi timed unit with no work inside: the UTF-8 view in, Rust's
                        // validation and copy, `String(decoding:)` out.
                        let raw = cases[row].text
                        guard case .rust(let engine) = states[armIndex] else { break }
                        let start = IO.uptimeNanoseconds()
                        output = try engine.run(.echo, raw)
                        elapsedNs = IO.uptimeNanoseconds() - start
                        engine.release()
                        work = ["bytes": raw.utf8.count, "echo_identical": output.utf8.elementsEqual(raw.utf8)]
                    case "compile":
                        var count = 0
                        switch states[armIndex] {
                        case .optimized(let path) where path.memoize:
                            let start = IO.uptimeNanoseconds()
                            let terms = Optimized.compile(persistent: persistent)
                            elapsedNs = IO.uptimeNanoseconds() - start
                            output = terms.map(\.termId).joined(separator: "\n")
                            count = terms.count
                        case .production, .optimized:
                            let start = IO.uptimeNanoseconds()
                            let snapshot = VocabularyCompiler.compile(persistent: persistent, ephemeral: [])
                            elapsedNs = IO.uptimeNanoseconds() - start
                            output = snapshot.terms.map(\.termId).joined(separator: "\n")
                            count = snapshot.terms.count
                        case .rust(let engine):
                            let start = IO.uptimeNanoseconds()
                            output = try engine.run(.compile, "")
                            elapsedNs = IO.uptimeNanoseconds() - start
                            engine.release()
                            count = output.isEmpty ? 0 : output.split(separator: "\n", omittingEmptySubsequences: false).count
                        }
                        work = ["terms_in": persistent.count, "active_terms": count]
                    case "engine":
                        var surfaces = 0
                        switch states[armIndex] {
                        case .production:
                            let start = IO.uptimeNanoseconds()
                            let vocabulary = RepairVocabulary.fromActiveTerms(active, ordinaryWords: words)
                            let engine = VocabularyRepairEngine(vocabulary: vocabulary)
                            elapsedNs = IO.uptimeNanoseconds() - start
                            withExtendedLifetime(engine) {}
                            output = vocabulary.surfaces.joined(separator: "\n") + "\n--\n"
                                + vocabulary.protectedSurfaces.joined(separator: "\n")
                            surfaces = vocabulary.surfaces.count
                        case .optimized(let path):
                            let start = IO.uptimeNanoseconds()
                            let partition = Optimized.partition(active, ordinaryWords: words)
                            let engine = Optimized.RepairEngine(
                                surfaces: partition.surfaces,
                                protectedSurfaces: partition.protected,
                                ordinaryWords: words,
                                memoizeConstants: path.memoize
                            )
                            elapsedNs = IO.uptimeNanoseconds() - start
                            withExtendedLifetime(engine) {}
                            output = partition.surfaces.joined(separator: "\n") + "\n--\n"
                                + partition.protected.joined(separator: "\n")
                            surfaces = partition.surfaces.count
                        case .rust(let engine):
                            let start = IO.uptimeNanoseconds()
                            output = try engine.run(.engine, "")
                            elapsedNs = IO.uptimeNanoseconds() - start
                            engine.release()
                            surfaces = output.components(separatedBy: "\n--\n")[0].split(separator: "\n").count
                        }
                        work = ["active_terms": active.count, "surfaces": surfaces]
                    default:
                        // `RepairVocabulary.bundledOrdinaryWords`' initializer, restated
                        // (VocabularyRepair.swift:14-30): it runs once per process in the app.
                        let start = IO.uptimeNanoseconds()
                        let contents = try String(contentsOfFile: Paths.ordinaryWords, encoding: .utf8)
                        let loaded = Set(contents.split(whereSeparator: \.isNewline).map(String.init))
                        elapsedNs = IO.uptimeNanoseconds() - start
                        output = String(loaded.count)
                        work = ["words": loaded.count]
                    }
                    let sha = IO.sha256Hex(output)
                    var equalRef: Any = NSNull()
                    if stage == "text", !reference.isEmpty, let expected = reference[rowIDs[row]] {
                        equalRef = expected == sha
                    }
                    rows.append(
                        IO.jsonLine([
                            "type": "timing", "bet": "B3", "arm": arm, "row_id": rowIDs[row], "pass": pass, "seq": seq,
                            "elapsed_us": Double(elapsedNs) / 1000, "output_sha256": sha, "equal_ref": equalRef,
                            "audio_s": NSNull(), "work": work, "err": NSNull(),
                        ]))
                    seq += 1
                }
            }
        }

        var meta: [String: Any] = [
            "type": "run_meta", "bet": "B3", "harness": "swift:swift-text-bench",
            "git_sha": Host.gitSHA(repo: Paths.repoRoot) as Any, "started_at": startedAt, "host": Host.meta(),
            "arms": arms, "passes": passes,
            "order":
                "per-pass seeded row permutation (seed \(seed)); arm order per row: cyclic rotation from (pass + position) mod arms, reversed on every other cycle",
            "corpus": arguments.options["corpus"] ?? "unnamed",
            "notes":
                "stage=\(stage); glossary=\(glossary.name) (\(persistent.count) terms, \(active.count) active); cases=\(cases.count); swift build -c release; "
                + "timed units: swift = VoiceCore (ProductionTextPath.process / VocabularyCompiler.compile / fromActiveTerms + VocabularyRepairEngine.init); "
                + "swift-opt, swift-opt-repr = Optimized (same signatures, Optimized.swift); "
                + "rust-ffi = RustTextEngine.run in this process: the input String's UTF-8 view into vtx_run (Rust validates UTF-8, runs the port, copies its output into a caller buffer) and String(decoding:) of the result, so both marshalling directions are inside the timed unit; for compile and engine Rust also joins the output ids or surfaces inside it",
            "stage": stage, "glossary": glossary.name,
        ]
        if let library {
            meta["rust_lib"] = library.path
            meta["rust_lib_sha256"] = IO.sha256Hex(data: try Data(contentsOf: URL(fileURLWithPath: library.path)))
        }
        try IO.writeLines([IO.jsonLine(meta)] + rows, to: try arguments.required("out"))
    }
}

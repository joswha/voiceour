// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: eleven production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import Foundation

    // The coverage ratchet.
    //
    // `UICoverageRegistry` declares every surface, state and journey this app has, including the
    // ones nothing verifies yet. On the day the ledger landed that was 83 unclaimed required
    // keys, and a gate that is red on day one is a gate everyone learns to pass with `|| true`.
    //
    // The ratchet is how a ledger becomes enforceable immediately without pretending the gaps are
    // closed. `fixtures/ui/coverage-baseline.txt` records exactly which required keys are
    // currently unclaimed. The gate then asserts two things, and neither of them is "zero gaps":
    //
    //   - A key that is uncovered and NOT in the baseline is a REGRESSION. Someone added a
    //     surface, or deleted the flow that covered one, and that fails.
    //   - A key that IS in the baseline but is now covered is a STALE ENTRY. The baseline has to
    //     shrink when the gap closes, or it silently becomes permission to un-cover it again.
    //
    // Both directions are enforced, so the file can only ever get shorter. That is the whole
    // mechanism: coverage is allowed to be incomplete, and is not allowed to get worse.
    //
    // `--flow-update` rewrites the file. Review the diff: a line REMOVED is a gap you closed, a
    // line ADDED is coverage you dropped and should have to justify.

    enum UICoverageBaseline {
        static let fileName = "coverage-baseline.txt"

        private static let header = """
            # Required coverage keys with no flow claiming them, one per line, sorted.
            #
            # This file is a ratchet, not a to-do list. `make ui-flow` fails when an uncovered key
            # is missing from here (a regression) AND when a key listed here is now covered (a
            # stale entry). It can therefore only ever get shorter.
            #
            # Regenerate with `make ui-flow-update`. A removed line is a gap you closed; an added
            # line is coverage you dropped.
            """

        struct Verdict {
            /// Uncovered keys absent from the baseline: coverage got worse.
            let regressions: [String]
            /// Baseline keys that are now covered: the file needs pruning.
            let stale: [String]
            /// Keys the current run could not judge, so they are neither enforced nor pruned.
            let deferred: Int
            /// Baseline is absent. Reported, never fatal: a fresh checkout has not generated one.
            let missing: Bool

            var failing: Bool { !regressions.isEmpty || !stale.isEmpty }
        }

        static func url(_ request: UIHarnessRequest) -> URL {
            request.goldenDirectory.appendingPathComponent(fileName, isDirectory: false)
        }

        /// Keys the current run proves are unclaimed, sorted and deduplicated.
        static func uncovered(in report: UICoverageReport) -> [String] {
            report.entries
                .filter { $0.status == .uncovered }
                .map(\.requirement.key.description)
                .sorted()
        }

        static func read(_ request: UIHarnessRequest) -> [String]? {
            guard let text = try? String(contentsOf: url(request), encoding: .utf8) else { return nil }
            return
                text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }

        /// Compares the run against the committed baseline.
        ///
        /// A filtered run cannot judge the whole app -- `--only sessions` leaves every other
        /// surface reported as `not-selected` -- so it enforces regressions only against the keys
        /// it actually evaluated, and never prunes. Only an unfiltered run can retire an entry.
        static func evaluate(_ report: UICoverageReport, request: UIHarnessRequest) -> Verdict {
            guard let baseline = read(request) else {
                return Verdict(regressions: [], stale: [], deferred: 0, missing: true)
            }
            let listed = Set(baseline)
            let uncoveredNow = Set(uncovered(in: report))
            let regressions = uncoveredNow.subtracting(listed).sorted()

            let judged = Set(
                report.entries
                    .filter { $0.status == .uncovered || $0.status == .covered }
                    .map(\.requirement.key.description)
            )
            let deferredKeys = listed.subtracting(judged)
            let stale =
                listed
                .subtracting(uncoveredNow)
                .subtracting(deferredKeys)
                .sorted()

            return Verdict(
                regressions: regressions,
                stale: stale,
                deferred: deferredKeys.count,
                missing: false
            )
        }

        /// Rewrites the baseline from an UNFILTERED run.
        ///
        /// Refuses a filtered run outright rather than writing a short file: `--only sessions
        /// --flow-update` would otherwise retire every key on every other surface in one commit,
        /// which is the exact failure the ratchet exists to prevent.
        static func write(
            _ report: UICoverageReport,
            request: UIHarnessRequest,
            warnings: inout [String]
        ) -> Bool {
            guard request.only.isEmpty else {
                warnings.append(
                    "refused to rewrite \(fileName) from a filtered run; rerun --flow-update without --only"
                )
                return false
            }
            let body = uncovered(in: report).joined(separator: "\n")
            let text = body.isEmpty ? "\(header)\n" : "\(header)\n\(body)\n"
            guard let data = text.data(using: .utf8) else { return false }
            let destination = url(request)
            if let existing = try? Data(contentsOf: destination), existing == data { return false }
            do {
                try data.write(to: destination, options: .atomic)
                return true
            } catch {
                warnings.append("could not write \(destination.lastPathComponent): \(error)")
                return false
            }
        }
    }

#endif

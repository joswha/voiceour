// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// The flag comes from `scripts/ui_harness.sh` (and so every `make ui-*` target) and
// from the `make test` / CI `swift test` steps. Ordinary builds omit it, the
// `swift build -c release` inside `scripts/bundle.sh` that ships included -- which is
// the entire point: these objects used to link into the shipping binary even though
// execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import Foundation
    import SwiftUI
    import VoiceCore

    // Shared vocabulary for the end-to-end flow layer.
    //
    // A `UIScene` answers "does this pane still look and read the way it did?". A `UIFlow`
    // answers the question a snapshot cannot: "does the app still WORK?" -- press this
    // control, reach that state, and the text that leaves the app is exactly this.
    //
    // The two layers share one process, one offscreen window path, one accessibility dump
    // and one lint pass. What a flow adds is time: it drives the real `DictationCoordinator`
    // and the real views through an ordered script, and it asserts named, self-describing
    // expectations at every checkpoint instead of diffing a blob.
    //
    // Determinism rules, in order of how easy they are to break:
    //
    //   1. No wait is ever a wall-clock deadline. Every wait is a bounded number of run-loop
    //      pumps, so a loaded machine produces the same verdict as an idle one.
    //   2. Every asynchronous boundary the flow crosses is a `UIGate` the script releases by
    //      name, so state transitions happen where the script says they do.
    //   3. Nothing that reaches an artifact may carry a date, a duration, a UUID, a process
    //      id, a hostname or an absolute path.
    //
    // See docs/ui-harness.md.

    // MARK: - Selectors

    /// Exact address for accessibility nodes, evaluated against one checkpoint's tree.
    ///
    /// Deliberately different from `AXDump.find`, which walks a fuzzy precedence chain and
    /// returns the first hit in document order. That is the right behaviour for a best-effort
    /// snapshot script and the wrong behaviour for a contract: a substring that silently
    /// retargets is exactly the failure mode a flow exists to catch. Every query here yields
    /// the full match SET, and an expectation that needs one node fails loudly on zero or two.
    enum UIQuery: Hashable, CustomStringConvertible {
        /// Exact `accessibilityIdentifier`.
        case id(String)
        /// Exact accessibility label (`AXLabel`, or `AXTitle` when the node publishes no label).
        case label(String)
        /// Exact `AXValue` rendered as text.
        case value(String)
        /// Exact `AXPlaceholderValue`. SwiftUI text fields publish no label at all, so for
        /// those this is the only text on the element.
        case placeholder(String)
        /// Label containing this substring. Use only where the label is genuinely dynamic.
        case labelContains(String)
        /// Value containing this substring.
        case valueContains(String)
        /// Accessibility role, e.g. `AXButton`, `AXStaticText`, `AXTextField`, `AXCheckBox`.
        case role(String)
        /// Every child query must match the same node.
        indirect case all([UIQuery])

        var description: String {
            switch self {
            case .id(let value): return "id=\(value)"
            case .label(let value): return "label=\(Self.quote(value))"
            case .value(let value): return "value=\(Self.quote(value))"
            case .placeholder(let value): return "placeholder=\(Self.quote(value))"
            case .labelContains(let value): return "label~=\(Self.quote(value))"
            case .valueContains(let value): return "value~=\(Self.quote(value))"
            case .role(let value): return "role=\(value)"
            case .all(let queries): return queries.map(\.description).joined(separator: " & ")
            }
        }

        /// One-line rendering safe to embed in a journal: no raw newlines, no unbalanced quotes.
        static func quote(_ raw: String) -> String {
            let escaped =
                raw
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
    }

    /// Cardinality assertion over a query's match set.
    enum UICount: Hashable, CustomStringConvertible {
        case exactly(Int)
        case atLeast(Int)
        case atMost(Int)
        case between(Int, Int)

        func accepts(_ observed: Int) -> Bool {
            switch self {
            case .exactly(let count): return observed == count
            case .atLeast(let count): return observed >= count
            case .atMost(let count): return observed <= count
            case .between(let low, let high): return observed >= low && observed <= high
            }
        }

        var description: String {
            switch self {
            case .exactly(let count): return "exactly \(count)"
            case .atLeast(let count): return "at least \(count)"
            case .atMost(let count): return "at most \(count)"
            case .between(let low, let high): return "between \(low) and \(high)"
            }
        }
    }

    /// String assertion used by value/label/text expectations.
    enum UIText: Hashable, CustomStringConvertible {
        case equals(String)
        case contains(String)
        case hasPrefix(String)
        case hasSuffix(String)
        case isEmpty
        case isNotEmpty

        func accepts(_ observed: String) -> Bool {
            switch self {
            case .equals(let expected): return observed == expected
            // `"voice".contains("")` is FALSE in Swift, because `contains` bottoms out in
            // `range(of:)` and an empty needle has no range. That surprise would read as a
            // harness bug the first time an author writes `.contains(someEmptyConstant)`, so
            // spell the mathematical answer instead: every string contains the empty string.
            case .contains(let expected): return expected.isEmpty || observed.contains(expected)
            case .hasPrefix(let expected): return observed.hasPrefix(expected)
            case .hasSuffix(let expected): return observed.hasSuffix(expected)
            case .isEmpty: return observed.isEmpty
            case .isNotEmpty: return !observed.isEmpty
            }
        }

        var description: String {
            switch self {
            case .equals(let value): return "== \(UIQuery.quote(value))"
            case .contains(let value): return "contains \(UIQuery.quote(value))"
            case .hasPrefix(let value): return "starts with \(UIQuery.quote(value))"
            case .hasSuffix(let value): return "ends with \(UIQuery.quote(value))"
            case .isEmpty: return "is empty"
            case .isNotEmpty: return "is not empty"
            }
        }
    }

    // MARK: - Session state patterns

    /// Case-only pattern over `SessionState`, which carries associated values that a flow
    /// should not have to spell out just to say "we passed through `copiedOnly`".
    enum UIStatePattern: String, CaseIterable, Hashable, CustomStringConvertible {
        case idle
        case checkingPermissions
        case recording
        case finalizingAudio
        case transcribing
        case cleaning
        case refining
        case readyToInsert
        case pasteAttempted
        case copiedOnly
        case insertFailed
        case error
        case cancelled

        var description: String { rawValue }

        /// The pattern for a concrete state. Total by construction: a new `SessionState` case
        /// makes this switch fail to compile, which is the point.
        static func of(_ state: SessionState) -> UIStatePattern {
            switch state {
            case .idle: return .idle
            case .checkingPermissions: return .checkingPermissions
            case .recording: return .recording
            case .finalizingAudio: return .finalizingAudio
            case .transcribing: return .transcribing
            case .cleaning: return .cleaning
            case .refining: return .refining
            case .readyToInsert: return .readyToInsert
            case .pasteAttempted: return .pasteAttempted
            case .copiedOnly: return .copiedOnly
            case .insertFailed: return .insertFailed
            case .error: return .error
            case .cancelled: return .cancelled
            }
        }

        func matches(_ state: SessionState) -> Bool { self == Self.of(state) }
    }

    /// How a recorded transition sequence is compared against an expected one.
    enum UITransitionOrder: String, Hashable {
        /// The recorded sequence equals the expected sequence element for element.
        case exact
        /// The expected sequence appears as a contiguous run inside the recorded one.
        case contiguous
        /// The expected states appear in order, possibly with others between them.
        case subsequence
    }

    // MARK: - Model probes

    /// Closed set of coordinator/model facts a flow may assert.
    ///
    /// A closed enum rather than a closure: journals stay byte-stable, the evaluator stays
    /// exhaustive, and a reviewer can read every fact a flow can possibly check in one place.
    enum UIModelKey: String, CaseIterable, Hashable, CustomStringConvertible {
        /// `coordinator.lastTranscript`.
        case transcript
        /// Human summary of `coordinator.lastOutcome`.
        case outcome
        /// `coordinator.errorMessage` (empty when nil).
        case errorMessage
        /// `coordinator.targetLabel`.
        case targetLabel
        /// Decimal count of `coordinator.recentSessions` — kept transcripts,
        /// which the store caps.
        case recentSessionCount
        /// Decimal `coordinator.insights.dictationCount` — the lifetime tally,
        /// which outlives eviction and is what Home's ALL TIME strip reads.
        case lifetimeDictationCount
        /// Decimal `settings.typingSpeedWPM`, the baseline every saving is
        /// measured against.
        case typingSpeedWPM
        /// Decimal count of active glossary terms in settings.
        case glossaryTermCount
        /// `true`/`false` for `settings.refinementEnabled`.
        case refinementEnabled
        /// `true`/`false` for `settings.cleanupEnabled`.
        case cleanupEnabled
        /// Active ASR backend identifier.
        case activeBackend
        /// `true`/`false` for `coordinator.isProcessingInFlight`.
        case processingInFlight
        /// Text the insertion adapter was last asked to deliver (empty when none).
        case deliveredText
        /// Bundle identifier of the delivery target the inserter saw (empty when none).
        case deliveryBundleID
        /// `paste`, `copy`, `failed` or empty: how the last delivery resolved.
        case deliveryDisposition
        /// Decimal count of insertion attempts the flow observed.
        case deliveryCount
        /// Text the app last wrote to the pasteboard through `GeneralPasteboard.copy`
        /// (empty when none). Captured through a nil-by-default seam, so a flow that presses
        /// a copy button never touches the real clipboard.
        case pasteboardText
        /// Decimal count of pasteboard writes the flow observed.
        case pasteboardWrites

        var description: String { rawValue }
    }

    // MARK: - Expectations

    /// One named, self-describing check evaluated at a checkpoint.
    ///
    /// Every expectation renders to a stable `expected:`/`observed:` pair, so a failure is
    /// readable without opening a diff, and the journal golden is a review artifact rather
    /// than a blob to rubber-stamp.
    enum UIExpectation {
        /// The query matches at least one node.
        case exists(UIQuery)
        /// The query matches no node.
        case absent(UIQuery)
        /// The query's match count satisfies the cardinality.
        case count(UIQuery, UICount)
        /// The single matching node is enabled (or not).
        case enabled(UIQuery, Bool)
        /// The single matching node publishes the `.isSelected` accessibility trait (or not).
        ///
        /// `AXDump` never prints this, so it is a flow-only contract: the committed dumps
        /// record a rail whose selected row is indistinguishable from its siblings.
        case selected(UIQuery, Bool)
        /// The single matching node's value satisfies the text rule.
        case value(UIQuery, UIText)
        /// The single matching node's label satisfies the text rule.
        case label(UIQuery, UIText)
        /// The single matching node's role equals this role.
        case role(UIQuery, String)
        /// Visible static text anywhere in the tree satisfies the text rule, this many times.
        case text(UIText, UICount)
        /// The coordinator is currently in this state.
        case state(UIStatePattern)
        /// The transitions recorded since the flow started match this sequence.
        case transitions([UIStatePattern], UITransitionOrder)
        /// A model fact satisfies the text rule.
        case model(UIModelKey, UIText)
        /// The interaction script produced this many warnings so far.
        case warnings(UICount)
        /// Re-running the lint rules over this checkpoint's tree and raster finds no error.
        case lintClean

        /// Stable one-line rendering of what was asked for.
        var expectation: String {
            switch self {
            case .exists(let query): return "exists \(query)"
            case .absent(let query): return "absent \(query)"
            case .count(let query, let count): return "count \(query) \(count)"
            case .enabled(let query, let flag): return "enabled(\(flag)) \(query)"
            case .selected(let query, let flag): return "selected(\(flag)) \(query)"
            case .value(let query, let text): return "value \(query) \(text)"
            case .label(let query, let text): return "label \(query) \(text)"
            case .role(let query, let role): return "role \(query) == \(role)"
            case .text(let text, let count): return "text \(text) \(count)"
            case .state(let pattern): return "state == \(pattern)"
            case .transitions(let states, let order):
                return "transitions \(order.rawValue) [\(states.map(\.rawValue).joined(separator: " -> "))]"
            case .model(let key, let text): return "model \(key) \(text)"
            case .warnings(let count): return "interaction warnings \(count)"
            case .lintClean: return "lint clean"
            }
        }

        /// The selector this expectation addressed, when it has one. Reported on failure so
        /// the reader does not have to re-derive it from the message.
        var selector: UIQuery? {
            switch self {
            case .exists(let query), .absent(let query): return query
            case .count(let query, _), .enabled(let query, _), .selected(let query, _): return query
            case .value(let query, _), .label(let query, _), .role(let query, _): return query
            case .text, .state, .transitions, .model, .warnings, .lintClean: return nil
            }
        }
    }

    // MARK: - Script vocabulary

    /// Named asynchronous boundary a flow releases explicitly.
    ///
    /// Without gates the pipeline runs to completion inside one settle and the intermediate
    /// states are unobservable; with them the script decides where the app pauses, so
    /// `.transcribing` is a checkpoint rather than a race.
    enum UIGate: String, CaseIterable, Hashable, CustomStringConvertible {
        /// Microphone permission check inside `start()`.
        case permission
        /// The capture reporting its first buffer that carries a non-zero sample.
        ///
        /// Unlike every other gate here, the port this one holds is SYNCHRONOUS:
        /// `AudioRecording.captureIsLive()` is polled by the metering loop, so the fixture
        /// parks a task on this gate and flips the flag the fake recorder answers from.
        /// The boundary is real either way — on a cold Bluetooth link it is a 1.4 s wait —
        /// and naming it is what lets a flow stand inside the warm-up window instead of
        /// racing through it.
        case captureLive
        /// `recorder.stop()` handing back the recorded audio.
        case recorderStop
        /// The ASR client returning a transcript.
        case transcription
        /// The refiner returning refined text.
        case refinement
        /// The insertion adapter returning an outcome.
        case insertion
        /// Recent-session persistence completing.
        case persistence

        var description: String { rawValue }
    }

    /// Coordinator entry points a flow may drive directly, for journeys whose trigger is the
    /// global hotkey rather than an on-screen control.
    enum UIDictateAction: String, Hashable, CustomStringConvertible {
        case start
        case stopAndProcess
        case cancel
        case toggle

        var description: String { rawValue }
    }

    /// One thing a flow does to the app.
    enum UIFlowAction: CustomStringConvertible {
        /// Accessibility press on the single node matching the query. The default click path.
        case press(UIQuery)
        /// Synthetic mouse click at the centre of the matching node's frame. Escape hatch.
        case click(UIQuery)
        /// Focus the matching text field, clear it, and type this text.
        case type(String, into: UIQuery)
        /// Drive the coordinator directly.
        case dictate(UIDictateAction)
        /// Press the console rail button for a section. Sugar over `press(.label(...))`.
        case navigate(ConsoleSection)

        var description: String {
            switch self {
            case .press(let query): return "press \(query)"
            case .click(let query): return "click \(query)"
            case .type(let text, let query): return "type \(UIQuery.quote(text)) into \(query)"
            case .dictate(let action): return "dictate \(action)"
            case .navigate(let section): return "navigate \(section.rawValue)"
            }
        }
    }

    /// A bounded condition the runner pumps toward. Never a wall-clock deadline.
    enum UIWait: CustomStringConvertible {
        /// Until the coordinator reaches this state.
        case state(UIStatePattern)
        /// Until at least one node matches.
        case element(UIQuery)
        /// Until no node matches.
        case absent(UIQuery)
        /// Unconditional fixed pump, in run-loop turns.
        case settle(Int)

        var description: String {
            switch self {
            case .state(let pattern): return "state == \(pattern)"
            case .element(let query): return "exists \(query)"
            case .absent(let query): return "absent \(query)"
            case .settle(let turns): return "settle \(turns) turns"
            }
        }
    }

    /// One line of a flow script.
    enum UIFlowStep {
        case act(UIFlowAction)
        case release(UIGate)
        case wait(UIWait)
        /// Named checkpoint. Every expectation is evaluated; none short-circuits.
        case check(String, [UIExpectation])
        /// Named frame: raster + accessibility dump + lint, reconciled like a scene golden.
        case capture(String)
    }

    // MARK: - Hosting

    /// Which surface a flow drives. Sizes come from the same tokens the scene catalog uses,
    /// so a flow frame and a scene snapshot of the same pane are directly comparable.
    enum UIFlowHost {
        case console(ConsoleSection)
        case tallConsole(ConsoleSection)
        case menu
        case overlay
        case custom(size: CGSize, colorScheme: ColorScheme, build: @MainActor (UIFlowContext) -> AnyView)
    }

    // MARK: - Flow

    /// One deterministic end-to-end journey.
    struct UIFlow {
        /// Stable identifier and artifact basename: lowercase, dot-separated, filesystem-safe.
        let id: String
        /// One-line human description.
        let title: String
        /// Free-form grouping for `--only` / `--except`.
        let tags: [String]
        /// Coverage keys this flow claims. The ledger fails when a required key has no claimant.
        let covers: [UICoverageKey]
        let host: UIFlowHost
        let fixture: UIFlowFixture
        let steps: [UIFlowStep]

        init(
            id: String,
            title: String,
            tags: [String] = [],
            covers: [UICoverageKey] = [],
            host: UIFlowHost,
            fixture: UIFlowFixture,
            steps: [UIFlowStep]
        ) {
            self.id = id
            self.title = title
            self.tags = tags
            self.covers = covers
            self.host = host
            self.fixture = fixture
            self.steps = steps
        }

        /// Number of checkpoints, used by the catalog test that rejects a flow asserting nothing.
        var checkpointCount: Int {
            steps.reduce(into: 0) { total, step in
                if case .check = step { total += 1 }
            }
        }

        var expectationCount: Int {
            steps.reduce(into: 0) { total, step in
                if case .check(_, let expectations) = step { total += expectations.count }
            }
        }
    }

    // MARK: - Results

    /// One evaluated expectation, in declaration order.
    struct UIExpectationLine {
        let ordinal: Int
        let checkpoint: String
        let passed: Bool
        let expectation: String
        let observed: String
        let selector: String?
        /// Sorted, capped list of nearby addressable nodes, populated only on a selector miss.
        let candidates: [String]
    }

    /// A failure the runner attributes to a specific script position.
    struct UIFlowFailure {
        enum Domain: String {
            /// An action could not be performed: no match, ambiguous match, dead control.
            case action
            /// A wait ran out its pump budget.
            case wait
            /// A checkpoint expectation was not satisfied.
            case expectation
            /// A captured frame produced an error-severity lint finding.
            case lint
            /// The flow violated a harness safety invariant.
            case safety
        }

        let ordinal: Int
        let checkpoint: String?
        let domain: Domain
        let expectation: String
        let observed: String
        let selector: String?
        let candidates: [String]
    }

    /// A named frame captured mid-flow, reconciled against `fixtures/ui/flows/`.
    struct UIFlowFrame {
        let name: String
        /// `<flow-id>.<frame-name>`; the artifact basename.
        let id: String
        let pixelStatus: UISceneResult.Status
        let axStatus: UISceneResult.Status
        let pngDigest: String?
        let goldenPngDigest: String?
        let nodeCount: Int
        let findings: [UIFinding]
    }

    /// Outcome of one flow.
    struct UIFlowResult {
        enum Status: String {
            case ok
            case failed
            case changed
            case missingGolden
            case written

            /// Precedence for the worst-of reduction below: failure beats changed beats
            /// missing-golden beats written beats ok.
            var severity: Int {
                switch self {
                case .ok: return 0
                case .written: return 1
                case .missingGolden: return 2
                case .changed: return 3
                case .failed: return 4
                }
            }
        }

        let flow: UIFlow
        let lines: [UIExpectationLine]
        let transitions: [UIStatePattern]
        let frames: [UIFlowFrame]
        let failures: [UIFlowFailure]
        let warnings: [String]
        /// Non-nil when the flow could not run at all.
        let error: String?
        /// Golden reconciliation verdict for the journal text.
        let journalStatus: UISceneResult.Status

        var passed: Bool { failures.isEmpty && error == nil }

        /// Worst verdict across the journal golden and every captured frame.
        ///
        /// A strict precedence over the WHOLE set, not a first-source-wins scan: a flow whose
        /// journal is merely missing a golden while a frame genuinely changed must report
        /// `changed`, because `missing-golden` reads as "new, go bless it" and would send a
        /// reviewer past a real regression.
        var status: Status {
            if error != nil || !failures.isEmpty { return .failed }
            var worst = Status.ok
            for candidate in [journalStatus] + frames.flatMap({ [$0.pixelStatus, $0.axStatus] }) {
                let mapped: Status
                switch candidate {
                case .ok: mapped = .ok
                case .written: mapped = .written
                case .missingGolden: mapped = .missingGolden
                case .changed: mapped = .changed
                case .failed: mapped = .failed
                }
                if mapped.severity > worst.severity { worst = mapped }
            }
            return worst
        }
    }

#endif

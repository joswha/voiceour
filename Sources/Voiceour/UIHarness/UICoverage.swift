// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// The flag comes from `scripts/ui_harness.sh` (and so every `make ui-*` target) and
// from the `make test` / CI `swift test` steps. Ordinary builds omit it, the
// `swift build -c release` inside `scripts/bundle.sh` that ships included -- which is
// the entire point: these objects used to link into the shipping binary even though
// execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/Voiceour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import Foundation

    // The coverage ledger.
    //
    // A large scene and flow catalog still tells you nothing about the states
    // NOBODY wrote a scene for, and that absence is invisible by construction: a missing test
    // produces no output. The ledger inverts that. Every surface, every pane state and every
    // journey is declared here whether or not anything verifies it, and a declared requirement
    // with no claimant FAILS the run.
    //
    // Three dispositions keep the ledger honest rather than aspirational:
    //
    //   - `.required` -- something must claim it, or the run is red.
    //   - `.snapshotOnly(sceneID:)` -- a static scene is genuinely sufficient (a pane state
    //     with no behaviour to drive), and that scene must exist in the catalog.
    //   - `.notVerifiable(limitation)` -- an offscreen render measurably cannot show it. The
    //     reason comes from a closed enum, so "we skipped it" can never be spelled as prose.
    //
    // The registry lives in `UICoverageRegistry.swift`.

    // MARK: - Keys

    /// Top-level UI area. One case per console pane plus the three surfaces outside the console.
    enum UISurface: String, CaseIterable, Comparable {
        case home
        case sessions
        case voice
        case glossary
        case system
        case diagnostics
        case menu
        case overlay
        case atoms

        static func < (lhs: UISurface, rhs: UISurface) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The console section that renders this surface, when it is a console pane.
        var consoleSection: ConsoleSection? {
            switch self {
            case .home: return .home
            case .sessions: return .sessions
            case .voice: return .voice
            case .glossary: return .glossary
            case .system: return .system
            case .diagnostics: return .diagnostics
            case .menu, .overlay, .atoms: return nil
            }
        }
    }

    /// One thing that must be verified.
    struct UICoverageKey: Hashable, Comparable, CustomStringConvertible {
        enum Kind: String, Comparable {
            /// The surface renders at all.
            case surface
            /// A named branch of the surface's own code.
            case state
            /// A multi-step user journey across the surface.
            case journey

            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let kind: Kind
        let surface: UISurface
        let name: String

        var description: String { "\(kind.rawValue):\(surface.rawValue):\(name)" }

        static func < (lhs: UICoverageKey, rhs: UICoverageKey) -> Bool {
            if lhs.surface != rhs.surface { return lhs.surface < rhs.surface }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.name < rhs.name
        }

        static func surface(_ surface: UISurface) -> UICoverageKey {
            UICoverageKey(kind: .surface, surface: surface, name: "renders")
        }

        static func state(_ surface: UISurface, _ name: String) -> UICoverageKey {
            UICoverageKey(kind: .state, surface: surface, name: name)
        }

        static func journey(_ surface: UISurface, _ name: String) -> UICoverageKey {
            UICoverageKey(kind: .journey, surface: surface, name: name)
        }
    }

    // MARK: - Limitations

    /// Closed set of measured reasons an offscreen render cannot verify something.
    ///
    /// Each one is a property of the capture path documented in docs/ui-harness.md, not an
    /// excuse. Adding a case is a deliberate act that shows up in review.
    enum UIKnownLimitation: String, CaseIterable, CustomStringConvertible {
        /// `NSTableView` row selection needs an active application; the harness is never active.
        case listRowSelection
        /// `performKeyEquivalent:` is only consulted for the key window.
        case keyEquivalent
        /// Pointer hover has no synthetic equivalent that survives an inactive app.
        case pointerHover
        /// `MenuBarExtra` host chrome and dismissal are supplied by the system popover.
        case menuHostChrome
        /// Legacy behind-window `NSVisualEffectView` glass has no desktop to sample
        /// offscreen; it rasterises flat.
        case behindWindowGlass
        /// `cacheDisplay` does not rasterise SwiftUI `.glassEffect`; the modern material is
        /// absent from the capture rather than flattened.
        case systemGlassMaterial
        /// `cacheDisplay` does not composite Core Animation `.blur`/`.shadow` filters.
        case coreAnimationFilter
        /// The subject is a `.repeatForever` animation whose phase is wall-clock driven.
        case perpetualAnimation
        /// The action opens a system panel (`NSOpenPanel`, System Settings) out of process.
        case systemPanel
        /// The state needs a real TCC prompt or a real Keychain, both machine-specific.
        case realPermissionOrKeychain
        /// The state needs a real network, a real model or a real subprocess.
        case realNetworkOrModel

        var description: String { rawValue }
    }

    // MARK: - Requirements

    enum UICoverageDisposition {
        /// A flow must claim this key.
        case required
        /// A static scene is sufficient. The scene must exist in `UISceneCatalog`.
        case snapshotOnly(sceneID: String)
        /// Measurably unverifiable offscreen.
        case notVerifiable(UIKnownLimitation)

        var label: String {
            switch self {
            case .required: return "required"
            case .snapshotOnly: return "snapshot-only"
            case .notVerifiable: return "not-verifiable"
            }
        }
    }

    struct UICoverageRequirement {
        let key: UICoverageKey
        /// What the reader should picture. One line, no trailing period.
        let title: String
        let disposition: UICoverageDisposition

        init(_ key: UICoverageKey, _ title: String, _ disposition: UICoverageDisposition = .required) {
            self.key = key
            self.title = title
            self.disposition = disposition
        }
    }

    // MARK: - Report

    struct UICoverageEntry {
        enum Status: String {
            /// Claimed by at least one passing flow.
            case covered
            /// Claimed by a scene that exists.
            case snapshot
            /// Declared unverifiable, with a measured reason.
            case notVerifiable = "not-verifiable"
            /// Required and unclaimed. Fails the run.
            case uncovered
            /// Claimed only by flows the current `--only`/`--except` filter excluded.
            case notSelected = "not-selected"
            /// The declaration itself is wrong: a snapshot scene id that does not exist.
            case broken
        }

        let requirement: UICoverageRequirement
        let status: Status
        /// Flow ids claiming this key, sorted.
        let claimants: [String]
        /// Non-nil when `status == .broken`.
        let problem: String?

        var failing: Bool { status == .uncovered || status == .broken }
    }

    struct UICoverageReport {
        let entries: [UICoverageEntry]
        /// Keys a flow claimed that the registry never declared. Always a failure: a typo in
        /// `covers:` would otherwise look like coverage.
        let undeclared: [String]

        var failing: Bool { entries.contains(where: \.failing) || !undeclared.isEmpty }

        func count(_ status: UICoverageEntry.Status) -> Int {
            entries.filter { $0.status == status }.count
        }
    }

    // MARK: - Ledger

    enum UICoverageLedger {
        /// Evaluates the registry against the flows that ran and the scenes that exist.
        ///
        /// - Parameters:
        ///   - requirements: every declared requirement, in registry order.
        ///   - passingClaims: coverage keys claimed by flows that PASSED. A failing flow
        ///     covers nothing; otherwise a broken journey would keep its own gap green.
        ///   - selectedClaims: coverage keys claimed by flows the filter selected, whether or
        ///     not they passed, so a focused run can distinguish "excluded" from "missing".
        ///   - allClaims: coverage keys claimed by every flow in the catalog.
        ///   - sceneIDs: every scene id in the unfiltered catalog.
        static func evaluate(
            requirements: [UICoverageRequirement],
            passingClaims: [UICoverageKey: [String]],
            selectedClaims: Set<UICoverageKey>,
            allClaims: [UICoverageKey: [String]],
            sceneIDs: Set<String>
        ) -> UICoverageReport {
            let declared = Set(requirements.map(\.key))
            let undeclared =
                allClaims.keys
                .filter { !declared.contains($0) }
                .map(\.description)
                .sorted()

            let entries = requirements.map { requirement -> UICoverageEntry in
                let claimants = (passingClaims[requirement.key] ?? []).sorted()
                switch requirement.disposition {
                case .notVerifiable:
                    return UICoverageEntry(
                        requirement: requirement,
                        status: .notVerifiable,
                        claimants: claimants,
                        problem: nil
                    )
                case .snapshotOnly(let sceneID):
                    guard sceneIDs.contains(sceneID) else {
                        return UICoverageEntry(
                            requirement: requirement,
                            status: .broken,
                            claimants: claimants,
                            problem: "snapshot scene \(sceneID) is not in the catalog"
                        )
                    }
                    return UICoverageEntry(
                        requirement: requirement,
                        status: .snapshot,
                        claimants: claimants,
                        problem: nil
                    )
                case .required:
                    if !claimants.isEmpty {
                        return UICoverageEntry(
                            requirement: requirement,
                            status: .covered,
                            claimants: claimants,
                            problem: nil
                        )
                    }
                    // A key whose only claimants were filtered out is not a gap in the
                    // catalog, so a focused `--only sessions` run must not report the whole
                    // app as uncovered. Only an unfiltered run can prove completeness.
                    if allClaims[requirement.key] != nil, !selectedClaims.contains(requirement.key) {
                        return UICoverageEntry(
                            requirement: requirement,
                            status: .notSelected,
                            claimants: [],
                            problem: nil
                        )
                    }
                    return UICoverageEntry(
                        requirement: requirement,
                        status: .uncovered,
                        claimants: [],
                        problem: nil
                    )
                }
            }

            return UICoverageReport(entries: entries, undeclared: undeclared)
        }
    }

#endif

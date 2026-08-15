import Foundation
import Testing

@testable import VoiceCore

@Suite("Glossary derived aliases")
struct GlossaryAliasTests {
    @Test func derivesDeterministicCaseAndSeparatorVariants() {
        #expect(
            Glossary.derivedAliases(for: "NSPasteboard") == [
                "ns pasteboard",
                "n s pasteboard",
            ])
        #expect(
            Glossary.derivedAliases(for: "AVAudioEngine") == [
                "av audio engine",
                "a v audio engine",
            ])
        #expect(
            Glossary.derivedAliases(for: "FastConformer-TDT") == [
                "fast conformer tdt",
                "fast conformer t d t",
            ])
        #expect(Glossary.derivedAliases(for: "kubectl").isEmpty)
        #expect(
            Glossary.derivedAliases(for: "SwiftUI") == [
                "swift ui",
                "swift u i",
            ])
    }

    @Test func canonicalizesDerivedAliasesWithoutHandWrittenAliases() {
        let term = ProtectedTerm(canonical: "NSPasteboard", spokenAliases: [])

        #expect(Glossary.canonicalize("use ns pasteboard here", terms: [term]) == "use NSPasteboard here")
        #expect(Glossary.canonicalize("use n s pasteboard here", terms: [term]) == "use NSPasteboard here")
    }

    @Test func locksCanonicalPresentOnlyThroughDerivedAlias() {
        let term = ProtectedTerm(canonical: "NSPasteboard", spokenAliases: [])

        #expect(
            Glossary.lockedCanonicals(
                presentIn: "copy with ns pasteboard",
                terms: [term]
            ) == Set(["NSPasteboard"]))
    }

    @Test func preservesHandWrittenAliasBehavior() {
        let term = ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"])

        #expect(Glossary.canonicalize("run cube cuddle now", terms: [term]) == "run kubectl now")
    }

    @Test func derivedAliasesMatchOnlyAtWordBoundaries() {
        let term = ProtectedTerm(canonical: "NSPasteboard", spokenAliases: [])
        let unrelated = "XNSPasteboarder and ns pasteboardish stay unchanged"

        #expect(Glossary.canonicalize(unrelated, terms: [term]) == unrelated)
    }

    @Test func canonicalizationDoesNotRescanReplacementOutput() {
        let terms = [
            ProtectedTerm(canonical: "Bravo", spokenAliases: ["alpha"]),
            ProtectedTerm(canonical: "Charlie", spokenAliases: ["bravo"])
        ]

        #expect(Glossary.canonicalize("alpha", terms: terms) == "Bravo")
    }

    @Test func canonicalizationPreservesDollarInCanonicalVerbatim() {
        let term = ProtectedTerm(canonical: "C$1", spokenAliases: ["see dollar one"])

        #expect(Glossary.canonicalize("use see dollar one here", terms: [term]) == "use C$1 here")
    }

    @Test func overlappingAliasesPreferLongestMatchThenLeftmost() {
        let longerLater = [
            ProtectedTerm(canonical: "SHORT", spokenAliases: ["alpha beta"]),
            ProtectedTerm(canonical: "LONG", spokenAliases: ["beta gamma delta"])
        ]
        #expect(
            Glossary.canonicalize("alpha beta gamma delta", terms: longerLater)
                == "alpha LONG"
        )

        let equalLengthRightFirst = [
            ProtectedTerm(canonical: "RIGHT", spokenAliases: ["beta gamma"]),
            ProtectedTerm(canonical: "LEFT", spokenAliases: ["alpha beta"])
        ]
        #expect(
            Glossary.canonicalize("alpha beta gamma", terms: equalLengthRightFirst)
                == "LEFT gamma"
        )
    }

    @Test func vocabularySanitizerRejectsCaseInsensitiveAliasCollisionsAcrossTerms() {
        let canonicalCollision = [
            ProtectedTerm(canonical: "Bravo", spokenAliases: ["alpha"]),
            ProtectedTerm(canonical: "Charlie", spokenAliases: [" bravo "])
        ]
        let aliasCollision = [
            ProtectedTerm(canonical: "Delta", spokenAliases: ["Shared Alias"]),
            ProtectedTerm(canonical: "Echo", spokenAliases: [" shared alias "])
        ]
        let unambiguous = [
            ProtectedTerm(canonical: "Foxtrot", spokenAliases: ["fox trot"]),
            ProtectedTerm(canonical: "Golf", spokenAliases: ["golf term"])
        ]

        #expect(!VocabularySanitizer.aliasesAreUnambiguous(in: canonicalCollision))
        #expect(!VocabularySanitizer.aliasesAreUnambiguous(in: aliasCollision))
        #expect(VocabularySanitizer.aliasesAreUnambiguous(in: unambiguous))
    }

    @Test func userAliasesIncludesConfirmedLabeledAlias() {
        let term = ProtectedTerm(
            canonical: "kubectl",
            spokenAliases: [],
            labeledAliases: [
                AliasLabel(
                    surface: "cube control",
                    confirmedAt: Date(timeIntervalSince1970: 5)
                )
            ]
        )

        #expect(Glossary.userAliases(for: term).contains("cube control"))
    }

    @Test func userAliasesReturnsOnlyNormalizedUserSurfaces() {
        let confirmedAt = Date(timeIntervalSince1970: 5)
        let term = ProtectedTerm(
            canonical: "NSPasteboard",
            spokenAliases: [
                "  manual alias  ",
                "MANUAL ALIAS",
                " NSPasteboard ",
                "   ",
            ],
            labeledAliases: [
                AliasLabel(surface: "rejected alias", confirmedAt: confirmedAt, rejectedAt: confirmedAt),
                AliasLabel(surface: " Second Alias ", confirmedAt: confirmedAt),
                AliasLabel(surface: "second alias"),
                AliasLabel(surface: "NSPASTEBOARD", confirmedAt: confirmedAt),
            ]
        )

        let aliases = Glossary.userAliases(for: term)
        #expect(aliases == ["manual alias", "Second Alias"])
        #expect(Glossary.derivedAliases(for: term.canonical).allSatisfy { !aliases.contains($0) })
    }

    @Test func settingAliasesReconcilesLabeledAliasState() throws {
        let confirmedAt = Date(timeIntervalSince1970: 5)
        let rejectedAt = Date(timeIntervalSince1970: 6)
        let term = ProtectedTerm(
            canonical: "kubectl",
            spokenAliases: [],
            labeledAliases: [
                AliasLabel(surface: "Cube Control", confirmedAt: confirmedAt)
            ]
        )

        let removed = TermMutation.settingAliases([], on: term, at: rejectedAt)
        try #require(removed.labeledAliases.count == 1)
        #expect(removed.labeledAliases[0].confirmedAt == nil)
        #expect(removed.labeledAliases[0].rejectedAt == rejectedAt)
        #expect(
            !Glossary.matchingAliases(for: removed).contains {
                $0.lowercased() == "cube control"
            })

        let restored = TermMutation.settingAliases(["CUBE CONTROL"], on: removed)
        try #require(restored.labeledAliases.count == 1)
        #expect(restored.spokenAliases == ["CUBE CONTROL"])
        #expect(restored.labeledAliases[0].rejectedAt == nil)
        #expect(
            Glossary.matchingAliases(for: restored).contains {
                $0.lowercased() == "cube control"
            })
    }

    @Test func matchingAliasesRetainsCanonicalUserAndDerivedOrdering() {
        let term = ProtectedTerm(
            canonical: "NSPasteboard",
            spokenAliases: ["paste board API"],
            labeledAliases: [
                AliasLabel(
                    surface: "native paste board",
                    confirmedAt: Date(timeIntervalSince1970: 5)
                )
            ]
        )

        #expect(
            Glossary.matchingAliases(for: term) == [
                "native paste board",
                "paste board API",
                "n s pasteboard",
                "ns pasteboard",
                "NSPasteboard",
            ])
    }

    /// `settingAliases` denormalizes a taught surface into `spokenAliases`, so a
    /// rejection that only stamped the label would leave the surface live in the
    /// other store — the REJECT button promising "don't suggest this again" while
    /// the alias keeps matching.
    @Test func rejectingAnAliasClearsItFromBothStores() {
        let taught = TermMutation.confirmingAlias(
            "cube control",
            on: ProtectedTerm(canonical: "kubectl", spokenAliases: []),
            at: Date(timeIntervalSince1970: 5)
        )
        let edited = TermMutation.settingAliases(
            Glossary.userAliases(for: taught),
            on: taught,
            at: Date(timeIntervalSince1970: 6)
        )
        #expect(edited.spokenAliases == ["cube control"])

        let rejected = TermMutation.rejectingAlias(
            "Cube Control",
            on: edited,
            at: Date(timeIntervalSince1970: 7)
        )

        #expect(rejected.spokenAliases.isEmpty)
        #expect(rejected.labeledAliases.first?.rejectedAt == Date(timeIntervalSince1970: 7))
        #expect(rejected.labeledAliases.first?.confirmedAt == nil)
        #expect(Glossary.userAliases(for: rejected).isEmpty)
        #expect(Glossary.canonicalize("run cube control now", terms: [rejected]) == "run cube control now")
    }
}

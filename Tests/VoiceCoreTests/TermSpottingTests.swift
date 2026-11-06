import Testing

@testable import VoiceCore

@Suite("Term spotting")
struct TermSpottingTests {
    private let ordinary: Set<String> = ["run", "now", "the", "go"]

    private func spot(_ term: Int, _ words: ClosedRange<Int>?, score: Double = -1, tokens: Int = 4) -> TermSpot {
        TermSpot(
            term: term, variant: 0, firstWord: words?.lowerBound, lastWord: words?.upperBound, score: score,
            tokenCount: tokens)
    }

    private func apply(
        _ words: [String],
        _ spots: [TermSpot],
        canonicals: [String] = ["kubectl"],
        protectedSurfaces: [String] = []
    ) -> [String]? {
        TermSpotting.apply(
            words: words,
            spots: spots,
            canonicals: canonicals,
            protectedSurfaces: protectedSurfaces,
            ordinaryWords: ordinary,
            policy: .frozen
        )
    }

    /// Targets are the canonicals spotting may write; ordinary-English and two-character ones are
    /// protected instead, and no target is ever searched under a user's heard-as form.
    @Test func targetsKeepCanonicalsOnlyAndProtectOrdinaryAndShortOnes() {
        let targets = TermSpotTargets(
            terms: [
                ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"]),
                ProtectedTerm(canonical: "Go", spokenAliases: ["go lang"]),
                ProtectedTerm(canonical: "SwiftUI", spokenAliases: []),
                ProtectedTerm(canonical: "IO", spokenAliases: []),
            ],
            ordinaryWords: ordinary
        )

        #expect(targets.canonicals == ["kubectl", "SwiftUI"])
        #expect(targets.protectedSurfaces == ["Go", "IO"])
        #expect(targets.variants == [TermSpotting.variants(for: "kubectl"), TermSpotting.variants(for: "SwiftUI")])
        #expect(Array(targets.variants[0].prefix(3)) == ["kubectl", "Kubectl", "kubectl"])
        #expect(targets.variants[1].contains("swift ui"))
        #expect(!targets.variants.joined().contains("cube cuddle"))
        #expect(!targets.variants.joined().contains("go lang"))
        #expect(targets.spotTerms.map(\.variants) == targets.variants)
    }

    @Test func theFrozenPolicyIsTheWaveTwoPoint() {
        #expect(TermSpottingPolicy.frozen == TermSpottingPolicy(total: 6, perToken: 1.5, ordinaryScale: 1))
        let words = ["cube", "cuddle"]
        #expect(apply(words, [spot(0, 0...1, score: -6, tokens: 4)]) == ["kubectl"])
        #expect(apply(words, [spot(0, 0...1, score: -6.01, tokens: 8)]) == nil)
        #expect(apply(words, [spot(0, 0...1, score: -2, tokens: 1)]) == nil)
    }

    /// A span holding a protected surface, whole-word and case-insensitively, is never rewritten.
    @Test func aProtectedSurfaceRefusesTheSpot() {
        #expect(apply(["run", "go", "cuddle"], [spot(0, 1...2)], protectedSurfaces: ["Go"]) == nil)
        #expect(apply(["run", "gopher", "cuddle"], [spot(0, 1...2)], protectedSurfaces: ["Go"]) == ["run", "kubectl"])
    }

    /// A span already holding a target's exact canonical is left alone; the check is case-sensitive,
    /// so a recased spelling is still corrected.
    @Test func anExactCanonicalIsANoOpButARecasedOneIsCorrected() {
        #expect(apply(["run", "kubectl", "now"], [spot(0, 1...1)]) == nil)
        #expect(apply(["nginx", "cube", "cuddle"], [spot(0, 0...2)], canonicals: ["kubectl", "nginx"]) == nil)
        #expect(apply(["run", "Kubectl", "now"], [spot(0, 1...1)]) == ["run", "kubectl", "now"])
    }

    @Test func aReplacedSpanKeepsItsOuterPunctuation() {
        #expect(apply(["(cube", "cuddle),"], [spot(0, 0...1)]) == ["(kubectl),"])
        #expect(apply(["\"cube", "cuddle.\""], [spot(0, 0...1)]) == ["\"kubectl.\""])
    }

    /// Overlapping spots keep the higher score, then more tokens, then the lower term index.
    @Test func overlappingSpotsAreSuppressedInOrder() {
        let words = ["cube", "cuddle", "engine", "x"]
        let canonicals = ["kubectl", "nginx"]
        #expect(
            apply(words, [spot(0, 0...1, score: -2), spot(1, 1...2, score: -1, tokens: 3)], canonicals: canonicals)
                == ["cube", "nginx", "x"])
        #expect(
            apply(
                words, [spot(1, 1...2, score: -1, tokens: 3), spot(0, 0...1, score: -1, tokens: 4)],
                canonicals: canonicals)
                == ["kubectl", "engine", "x"])
        #expect(
            apply(words, [spot(1, 1...2, score: -1), spot(0, 0...1, score: -1)], canonicals: canonicals)
                == ["kubectl", "engine", "x"])
    }

    @Test func aSpotWithoutAWordRangeIsRefused() {
        #expect(apply(["cube", "cuddle"], [spot(0, nil)]) == nil)
        #expect(
            apply(
                ["cube", "cuddle"],
                [TermSpot(term: 0, variant: 0, firstWord: 0, lastWord: nil, score: 0, tokenCount: 4)]) == nil)
    }
}

@Suite("Dictation text stage with term spots")
struct DictationTextStageSpottingTests {
    private let glossary = [ProtectedTerm(canonical: "Kubernetes", spokenAliases: [])]

    private var targets: TermSpotTargets {
        TermSpotTargets(terms: glossary, ordinaryWords: RepairVocabulary.bundledOrdinaryWords)
    }

    /// `Kubernetes` heard as *cooper netties*, words `first...last` of `raw`.
    private func evidence(_ raw: String, first: Int, last: Int) -> TermSpotEvidence {
        TermSpotEvidence(
            words: raw.split(separator: " ").map(String.init),
            spots: [TermSpot(term: 0, variant: 0, firstWord: first, lastWord: last, score: -3, tokenCount: 4)],
            targets: targets
        )
    }

    private func stage(_ raw: String, spotting: TermSpotEvidence? = nil, cleanup: Bool = true) -> String {
        DictationTextStage.apply(
            raw, spotting: spotting, cleanupEnabled: cleanup, glossary: glossary, repairEngine: nil
        ).text
    }

    /// Spotting reads the recognizer's own words, so it runs before literal composition rewrites
    /// them; the rest of the stage then treats the spotted text as the transcript.
    @Test func spotsApplyBeforeLiteralComposition() {
        let raw = "open the cooper netties dot yaml file"
        let spotted = stage(raw, spotting: evidence(raw, first: 2, last: 3))

        #expect(spotted == stage("open the Kubernetes dot yaml file"))
        #expect(spotted.contains("Kubernetes"))
        #expect(spotted != stage(raw))
        let outcome = DictationTextStage.apply(
            raw, spotting: evidence(raw, first: 2, last: 3), cleanupEnabled: true, glossary: glossary,
            repairEngine: nil)
        #expect(outcome.text == spotted)
        #expect(outcome.language == DictationLanguage.detect(raw))
    }

    @Test func cleanupOffSkipsSpotting() {
        let raw = "deploy it to cooper netties today"
        #expect(stage(raw, spotting: evidence(raw, first: 3, last: 4), cleanup: false) == stage(raw, cleanup: false))
        #expect(stage(raw, spotting: evidence(raw, first: 3, last: 4)).contains("Kubernetes"))
    }

    @Test func anotherLanguageSkipsSpotting() {
        let raw = "O comitê comprou um carro e disse que a capital usa cooper netties"
        #expect(DictationLanguage.detect(raw) == .portuguese)
        #expect(stage(raw, spotting: evidence(raw, first: 11, last: 12)) == stage(raw))
    }

    /// Word indices address the words, so a transcript whose words do not join back into its text
    /// is not spotted.
    @Test func wordsThatDoNotSpellTheTextSkipSpotting() {
        let raw = "deploy it to cooper netties today."
        var spotting = evidence(raw, first: 3, last: 4)
        spotting.words = ["deploy", "it", "to", "cooper", "netties", "today"]
        #expect(stage(raw, spotting: spotting) == stage(raw))
    }
}

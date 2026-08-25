import Foundation
import Testing

@testable import VoiceCore

@Suite("CandidateRetriever")
struct CandidateRetrievalTests {
    private func snapshot(_ terms: [ProtectedTerm]) -> VocabularySnapshot {
        VocabularySnapshot(
            terms: terms,
            ephemeral: [],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func substring(_ transcript: String, _ candidate: TermCandidate) -> String {
        let start = transcript.index(transcript.startIndex, offsetBy: candidate.spanStart)
        let end = transcript.index(start, offsetBy: candidate.spanLength)
        return String(transcript[start..<end])
    }

    @Test func nearMissSurfaceRetrievesIntendedTermAboveUnrelated() {
        let kubectl = ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"])
        let unrelated = ProtectedTerm(canonical: "watermelon", spokenAliases: [])
        let transcript = "please run cube cuddle on the pod"

        let results = CandidateRetriever.retrieve(
            in: transcript,
            snapshot: snapshot([kubectl, unrelated])
        )

        #expect(!results.isEmpty)
        #expect(results.contains { $0.termId == "kubectl" })
        // The intended term ranks first and pins the exact near-miss span.
        #expect(results.first?.termId == "kubectl")
        #expect(results.first.map { substring(transcript, $0) } == "cube cuddle")
        // The unrelated term never surfaces at all.
        #expect(!results.contains { $0.termId == "watermelon" })
    }

    @Test func ordinaryTextYieldsNoSpuriousCandidate() {
        let terms = [
            ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"]),
            ProtectedTerm(canonical: "NSPasteboard", spokenAliases: []),
            ProtectedTerm(canonical: "SwiftUI", spokenAliases: []),
        ]

        let results = CandidateRetriever.retrieve(
            in: "the quick brown fox jumps over the lazy dog",
            snapshot: snapshot(terms)
        )

        #expect(results.isEmpty)
        #expect(!results.contains { $0.phoneSimilarity >= 0.6 })
    }

    @Test func retrievalIsDeterministic() {
        let terms = [
            ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"]),
            ProtectedTerm(canonical: "SwiftUI", spokenAliases: []),
        ]
        let snap = snapshot(terms)
        let transcript = "open the view in swift you eye then run cube cuddle"

        let first = CandidateRetriever.retrieve(in: transcript, snapshot: snap)
        let second = CandidateRetriever.retrieve(in: transcript, snapshot: snap)

        #expect(first == second)
    }

    @Test func maxPerSpanCapsCandidatesPerSpan() {
        let terms = [
            ProtectedTerm(canonical: "cache", spokenAliases: []),
            ProtectedTerm(canonical: "cash", spokenAliases: []),
        ]
        let snap = snapshot(terms)

        // A single one-word span ("cash") that both terms match.
        let capped = CandidateRetriever.retrieve(in: "cash", snapshot: snap, maxPerSpan: 1)
        #expect(capped.count == 1)
        #expect(capped.first?.termId == "cash")

        let uncapped = CandidateRetriever.retrieve(in: "cash", snapshot: snap, maxPerSpan: 5)
        #expect(uncapped.count == 2)
        #expect(Set(uncapped.map(\.termId)) == ["cash", "cache"])
    }

    @Test func degenerateInputsReturnNoCandidates() {
        let snap = snapshot([ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"])])

        #expect(CandidateRetriever.retrieve(in: "", snapshot: snap).isEmpty)
        #expect(CandidateRetriever.retrieve(in: "run cube cuddle", snapshot: snap, maxPerSpan: 0).isEmpty)
        #expect(CandidateRetriever.retrieve(in: "run cube cuddle", snapshot: snapshot([])).isEmpty)
    }

    @Test func tombstonedTermsAreIgnored() {
        var kubectl = ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"])
        kubectl.tombstonedAt = Date(timeIntervalSince1970: 0)

        let results = CandidateRetriever.retrieve(
            in: "please run cube cuddle now",
            snapshot: snapshot([kubectl])
        )

        #expect(results.isEmpty)
    }
}

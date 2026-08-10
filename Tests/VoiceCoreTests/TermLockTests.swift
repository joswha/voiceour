import Foundation
import Testing

@testable import VoiceCore

@Suite("Glossary word-boundary term lock")
struct TermLockTests {
    // A locked canonical must survive as its own token, not merely as a substring
    // of an unrelated longer word: locked `AX` is not satisfied by `AXIOM`.
    @Test func lockedTermRejectsSubstringInsideLongerToken() {
        let term = ProtectedTerm(canonical: "AX", spokenAliases: [])

        // Present at a word boundary in the original, so it locks.
        #expect(
            Glossary.lockedCanonicals(
                presentIn: "ship the AX handle",
                terms: [term]
            ) == Set(["AX"]))

        // A candidate where "AX" survives only as a substring of "AXIOM" is rejected,
        // where the old plain-substring check would have false-passed.
        #expect(
            !Glossary.validateTermLock(
                original: "ship the AX handle",
                candidate: "ship the AXIOM handle",
                terms: [term]
            ))
    }

    // A genuine word-boundary reoccurrence of the locked canonical still passes.
    @Test func lockedTermAcceptsWordBoundaryReoccurrence() {
        let term = ProtectedTerm(canonical: "AX", spokenAliases: [])

        #expect(
            Glossary.validateTermLock(
                original: "ship the AX handle",
                candidate: "Ship the AX handle now.",
                terms: [term]
            ))
    }

    // The lock matches the casing-policy canonical regardless of the candidate's
    // casing, closing the old false-fail where a re-cased term was rejected.
    @Test func casingPolicyCanonicalMatchesRegardlessOfCandidateCase() {
        let term = ProtectedTerm(canonical: "GraphQL", spokenAliases: [], casePolicy: .lower)
        #expect(term.renderedCanonical == "graphql")

        #expect(
            Glossary.lockedCanonicals(
                presentIn: "use graphql here",
                terms: [term]
            ) == Set(["graphql"]))

        #expect(
            Glossary.validateTermLock(
                original: "use graphql here",
                candidate: "Use GraphQL here.",
                terms: [term]
            ))
    }

    // A tombstoned term never locks, so a rewrite may legitimately drop it.
    @Test func tombstonedTermDoesNotLock() {
        let term = ProtectedTerm(
            canonical: "NeuroDock",
            spokenAliases: [],
            tombstonedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(
            Glossary.lockedCanonicals(
                presentIn: "deploy NeuroDock now",
                terms: [term]
            ).isEmpty)

        #expect(
            Glossary.validateTermLock(
                original: "deploy NeuroDock now",
                candidate: "deploy the service now",
                terms: [term]
            ))
    }
}

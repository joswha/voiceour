import Testing
import VoiceCore

@testable import VoiceourBench

struct AssistArbitrationTests {
    @Test("distinct phonetic forms authorize relaxed whole-transcript adoption")
    func distinctFormsAuthorizeAdoption() {
        let primary = "Check whether containered accepts the registry credentials."
        let candidates = [
            AssistArbitration.RelaxedCandidate(
                text: "Check whether containerd accepts the registry credentials.",
                events: [phoneticEvent(before: "containered", after: "containerd")]
            ),
            AssistArbitration.RelaxedCandidate(
                text: "Check whether containerd accepts the registry credentials.",
                events: [phoneticEvent(before: "contained", after: "containerd")]
            ),
        ]

        let result = AssistArbitration.arbitrateRelaxed(
            primary: primary,
            candidates: candidates,
            surfaces: ["containerd"]
        )

        #expect(result == candidates[0].text)
    }

    @Test("repeated identical homophone is not independent repair evidence")
    func identicalHomophoneDoesNotAuthorizeAdoption() {
        let primary = "We waited in the queue outside the bakery."
        let candidate = AssistArbitration.RelaxedCandidate(
            text: "We waited in the kqueue outside the bakery.",
            events: [phoneticEvent(before: "queue", after: "kqueue")]
        )

        let result = AssistArbitration.arbitrateRelaxed(
            primary: primary,
            candidates: Array(repeating: candidate, count: 6),
            surfaces: ["kqueue"]
        )

        #expect(result == primary)
    }

    @Test("phonetic consensus cannot invent acronym or camel-case identifiers")
    func shapedIdentifierDoesNotAuthorizeAdoption() {
        let primary = "I'm pleased to announce the annual plan."
        let candidates = [
            AssistArbitration.RelaxedCandidate(
                text: "IAM pleased to announce the annual plan.",
                events: [phoneticEvent(before: "I'm", after: "IAM")]
            ),
            AssistArbitration.RelaxedCandidate(
                text: "IAM pleased to announce the annual plan.",
                events: [phoneticEvent(before: "am", after: "IAM")]
            ),
        ]

        let result = AssistArbitration.arbitrateRelaxed(
            primary: primary,
            candidates: candidates,
            surfaces: ["IAM"]
        )

        #expect(result == primary)
    }

    @Test("title-case canonical needs nonordinary phonetic evidence")
    func titleCaseCanonicalRejectsOrdinaryInflections() {
        let primary = "We need more portable radios for the department."
        let candidates = [
            AssistArbitration.RelaxedCandidate(
                text: "We need more portable Redis for the department.",
                events: [phoneticEvent(before: "radios", after: "Redis")]
            ),
            AssistArbitration.RelaxedCandidate(
                text: "We need more portable Redis for the department.",
                events: [phoneticEvent(before: "radius", after: "Redis")]
            ),
        ]

        let result = AssistArbitration.arbitrateRelaxed(
            primary: primary,
            candidates: candidates,
            surfaces: ["Redis"],
            ordinaryWords: ["radio", "radius"]
        )

        #expect(result == primary)
    }

    @Test("two raw sources shelter spoken C-plus-plus before cleanup")
    func spokenPlusAliasConsensusSheltersCanonical() {
        let raw = [
            "the c plus plus compiler rejects this overload",
            "The C plus plus compiler rejects this overload.",
            "The C compiler rejects this overload.",
        ]

        let protected = AssistArbitration.protectSpokenAliases(in: raw, surfaces: ["C++"])

        #expect(protected[0] == "the C++ compiler rejects this overload")
        #expect(protected[1] == "The C++ compiler rejects this overload.")
        #expect(protected[2] == raw[2])
    }

    @Test("one source or ambiguous sharp alias is not sheltered")
    func unsupportedSpokenAliasRemainsRaw() {
        let raw = ["Our C sharp target builds.", "Our C plus plus target builds."]

        let protected = AssistArbitration.protectSpokenAliases(in: raw, surfaces: ["C#", "C++"])

        #expect(protected == raw)
    }

    @Test("two spellings inside one source are not decoder consensus")
    func oneSourceCannotAuthorizeItsOwnVariants() {
        let primary = "We launch the product and launched the beta."
        let candidate = AssistArbitration.RelaxedCandidate(
            text: "We launchd the product and launchd the beta.",
            events: [
                phoneticEvent(before: "launch", after: "launchd"),
                phoneticEvent(before: "launched", after: "launchd"),
            ]
        )

        let result = AssistArbitration.arbitrateRelaxed(
            primary: primary,
            candidates: [candidate],
            surfaces: ["launchd"]
        )

        #expect(result == primary)
    }

    @Test("punctuation differences are one phonetic form")
    func punctuationDoesNotCreateDistinctEvidence() {
        let primary = "Taxes paid as expected."
        let candidates = [
            AssistArbitration.RelaxedCandidate(
                text: "Taxes pandas expected.",
                events: [phoneticEvent(before: "paid, as", after: "pandas")]
            ),
            AssistArbitration.RelaxedCandidate(
                text: "Taxes pandas expected.",
                events: [phoneticEvent(before: "paid as", after: "pandas")]
            ),
        ]

        let result = AssistArbitration.arbitrateRelaxed(
            primary: primary,
            candidates: candidates,
            surfaces: ["pandas"]
        )

        #expect(result == primary)
    }

    @Test("approved repair cannot carry an unrelated unapproved repair")
    func candidateWithUnapprovedEventIsRejected() {
        let primary = "We use kqueue on macOS and a queue for jobs so containered handles it."
        let candidates = [
            AssistArbitration.RelaxedCandidate(
                text: "We use kqueue on macOS and a kqueue for jobs so containerd handles it.",
                events: [
                    phoneticEvent(before: "queue", after: "kqueue"),
                    phoneticEvent(before: "containered", after: "containerd"),
                ]
            ),
            AssistArbitration.RelaxedCandidate(
                text: "We use kqueue on macOS and a kqueue for jobs so containerd handles it.",
                events: [
                    phoneticEvent(before: "queue", after: "kqueue"),
                    phoneticEvent(before: "contained", after: "containerd"),
                ]
            ),
        ]

        let result = AssistArbitration.arbitrateRelaxed(
            primary: primary,
            candidates: candidates,
            surfaces: ["kqueue", "containerd"]
        )

        #expect(result == primary)
    }

    private func phoneticEvent(before: String, after: String) -> RepairEvent {
        RepairEvent(start: 0, end: before.count, before: before, after: after, kind: "phonetic", score: 0.85)
    }
}

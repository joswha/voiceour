import Testing
@testable import VoiceourBench
import VoiceCore

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
            )
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

    private func phoneticEvent(before: String, after: String) -> RepairEvent {
        RepairEvent(start: 0, end: before.count, before: before, after: after, kind: "phonetic", score: 0.85)
    }
}

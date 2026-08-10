import Testing

@testable import VoiceCore

@Suite("Phonetics")
struct PhoneticsTests {
    @Test func identicalInputsHavePerfectAlignment() {
        let phones = Phonetics.phones(for: "NSPasteboard2")

        #expect(Phonetics.alignmentDistance(phones, phones) == 0)
        #expect(Phonetics.similarity("NSPasteboard2", "NSPasteboard2") == 1)
    }

    @Test func nearHomophonesOutrankUnrelatedWords() {
        let kubectlAlias = Phonetics.similarity("kubectl", "cube cuddle")
        let kubectlUnrelated = Phonetics.similarity("kubectl", "watermelon")
        let cacheAlias = Phonetics.similarity("cache", "cash")
        let cacheUnrelated = Phonetics.similarity("cache", "window")

        #expect(kubectlAlias > kubectlUnrelated)
        #expect(cacheAlias > cacheUnrelated)
        #expect(Phonetics.similarity("kubectl", "cube cuddle") == Phonetics.similarity("cube cuddle", "kubectl"))
        #expect(
            Phonetics.alignmentDistance(
                Phonetics.phones(for: "cache"),
                Phonetics.phones(for: "catch")
            )
                == Phonetics.alignmentDistance(
                    Phonetics.phones(for: "catch"),
                    Phonetics.phones(for: "cache")
                ))
    }

    @Test func emptyInputsAreSafe() {
        #expect(Phonetics.phones(for: "").isEmpty)
        #expect(Phonetics.alignmentDistance([], []) == 0)
        #expect(Phonetics.alignmentDistance([], ["K"]) == 1)
        #expect(Phonetics.similarity("", "") == 1)
        #expect(Phonetics.similarity("", "cache") == 0)
    }

    @Test func camelCaseDigitsAndAcronymsSplitPredictably() {
        #expect(Phonetics.phones(for: "voiceCore") == Phonetics.phones(for: "voice Core"))
        #expect(Phonetics.phones(for: "HTTP2Server") == Phonetics.phones(for: "H T T P 2 Server"))
    }

    @Test func resultsAreDeterministicAndNormalized() {
        let expectedPhones = Phonetics.phones(for: "FastConformer2D")
        let expectedDistance = Phonetics.alignmentDistance(
            expectedPhones, Phonetics.phones(for: "fast conformer two d"))
        let expectedSimilarity = Phonetics.similarity("FastConformer2D", "fast conformer two d")

        for _ in 0..<20 {
            #expect(Phonetics.phones(for: "FastConformer2D") == expectedPhones)
            #expect(
                Phonetics.alignmentDistance(expectedPhones, Phonetics.phones(for: "fast conformer two d"))
                    == expectedDistance)
            #expect(Phonetics.similarity("FastConformer2D", "fast conformer two d") == expectedSimilarity)
        }

        #expect(expectedDistance >= 0)
        #expect((0...1).contains(expectedSimilarity))
        #expect(Phonetics.similarity("cache", "cash") >= Phonetics.similarity("cache", "catch"))
    }
}

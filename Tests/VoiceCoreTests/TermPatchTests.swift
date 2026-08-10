import Testing

@testable import VoiceCore

@Suite("TermPatchRenderer")
struct TermPatchTests {
    @Test func appliesMultipleDisjointPatches() {
        // "the cat sat": the=[0,3) cat=[4,7) sat=[8,11)
        let patches = [
            TermPatch(spanStart: 4, spanLength: 3, replacement: "dog", termId: "dog"),
            TermPatch(spanStart: 0, spanLength: 3, replacement: "The", termId: "the"),
        ]

        #expect(TermPatchRenderer.apply(patches, to: "the cat sat") == "The dog sat")
    }

    @Test func appliesLengthChangingPatchesRightToLeft() {
        // Replacements of differing length must not corrupt lower offsets.
        let patches = [
            TermPatch(spanStart: 0, spanLength: 3, replacement: "A", termId: "a"),
            TermPatch(spanStart: 4, spanLength: 3, replacement: "elephant", termId: "elephant"),
        ]

        #expect(TermPatchRenderer.apply(patches, to: "the cat sat") == "A elephant sat")
    }

    @Test func rejectsOverlappingPatchesByReturningOriginal() {
        let original = "the cat sat"
        let patches = [
            TermPatch(spanStart: 0, spanLength: 4, replacement: "X", termId: "x"),
            TermPatch(spanStart: 2, spanLength: 3, replacement: "Y", termId: "y"),
        ]

        #expect(TermPatchRenderer.apply(patches, to: original) == original)
    }

    @Test func rejectsOutOfRangeAndNegativeSpans() {
        let original = "hi"

        let overrun = [TermPatch(spanStart: 0, spanLength: 5, replacement: "X", termId: "x")]
        #expect(TermPatchRenderer.apply(overrun, to: original) == original)

        let negative = [TermPatch(spanStart: -1, spanLength: 1, replacement: "X", termId: "x")]
        #expect(TermPatchRenderer.apply(negative, to: original) == original)

        let pastEnd = [TermPatch(spanStart: 2, spanLength: 1, replacement: "X", termId: "x")]
        #expect(TermPatchRenderer.apply(pastEnd, to: original) == original)
    }

    @Test func emptyPatchListIsNoOp() {
        #expect(TermPatchRenderer.apply([], to: "hello world") == "hello world")
    }

    @Test func adjacentTouchingPatchesAreAppliedNotRejected() {
        // [0,3) and [3,1) touch but do not overlap.
        let patches = [
            TermPatch(spanStart: 0, spanLength: 3, replacement: "AB", termId: "ab"),
            TermPatch(spanStart: 3, spanLength: 1, replacement: "-", termId: "dash"),
        ]

        #expect(TermPatchRenderer.apply(patches, to: "xyz.rest") == "AB-rest")
    }

    @Test func usesCharacterOffsetsForMultibyteText() {
        // "café ☕ time": t=index 7, len 4 -> "time"
        let transcript = "café ☕ time"
        let patches = [TermPatch(spanStart: 7, spanLength: 4, replacement: "tea", termId: "tea")]

        #expect(TermPatchRenderer.apply(patches, to: transcript) == "café ☕ tea")
    }
}

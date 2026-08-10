/// A single, resolved text substitution over a transcript.
///
/// `spanStart` and `spanLength` are `Character` offsets (grapheme clusters) into
/// the transcript the patch targets. `replacement` MUST be a resolved term's
/// `renderedCanonical`; the renderer copies it verbatim and never authors text of
/// its own, so no model-generated string can enter the transcript through this path.
struct TermPatch: Equatable, Sendable {
    let spanStart: Int
    let spanLength: Int
    let replacement: String
    let termId: String
}

/// Deterministic, fail-safe application of resolved term patches.
///
/// The renderer validates every patch against the transcript, rejects any set
/// containing an out-of-range span or overlapping spans, and applies the
/// survivors right-to-left so that lower offsets stay valid as spans of a
/// different length are substituted. On *any* inconsistency it returns the input
/// transcript verbatim, guaranteeing that a malformed patch set can never corrupt
/// or partially rewrite the text. It only ever emits caller-supplied
/// `replacement` strings, never text of its own.
enum TermPatchRenderer {
    /// Applies `patches` to `transcript`, or returns `transcript` unchanged if the
    /// patch set is empty, out of range, or contains overlapping spans.
    static func apply(_ patches: [TermPatch], to transcript: String) -> String {
        guard !patches.isEmpty else { return transcript }

        let characters = Array(transcript)
        let count = characters.count

        // Reject any span that is negative or runs past the current length.
        for patch in patches {
            guard patch.spanStart >= 0,
                patch.spanLength >= 0,
                patch.spanStart + patch.spanLength <= count
            else {
                return transcript
            }
        }

        // Order by span position with total tie-breakers for determinism.
        let ordered = patches.sorted { lhs, rhs in
            if lhs.spanStart != rhs.spanStart { return lhs.spanStart < rhs.spanStart }
            if lhs.spanLength != rhs.spanLength { return lhs.spanLength < rhs.spanLength }
            if lhs.replacement != rhs.replacement { return lhs.replacement < rhs.replacement }
            return lhs.termId < rhs.termId
        }

        // Reject overlaps. Adjacent (touching) spans are permitted; any prior span
        // whose end passes the next span's start is an inconsistency.
        if ordered.count > 1 {
            for index in 1..<ordered.count {
                let previous = ordered[index - 1]
                let current = ordered[index]
                if previous.spanStart + previous.spanLength > current.spanStart {
                    return transcript
                }
            }
        }

        // Apply right-to-left so untouched lower offsets remain valid even when a
        // replacement changes the span's length.
        var result = characters
        for patch in ordered.reversed() {
            let start = patch.spanStart
            let end = patch.spanStart + patch.spanLength
            result.replaceSubrange(start..<end, with: Array(patch.replacement))
        }
        return String(result)
    }
}

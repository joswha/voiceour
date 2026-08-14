import OSLog

/// Signposts for the post-stop critical path: hotkey release to text inserted.
///
/// This path carried no instrumentation at all. Everything known about it was
/// reconstructed from `SessionStageTimings`, which records capture, ASR, insert
/// and the end-to-end span but nothing between them — so the stages in the middle
/// were invisible. That is how a 120 ms system-audio fade sat in front of four out
/// of five ASR calls until someone read the code: no measurement would have shown
/// it, because no measurement covered that span.
///
/// These are signposts rather than persisted timings on purpose. The persisted
/// stages are product telemetry with a durability contract; these are developer
/// instrumentation, free when nobody is recording, and captured with:
///
///     xctrace record --instrument os_signpost --output /tmp/stop.trace --attach <pid>
///     xctrace export --input /tmp/stop.trace \
///       --xpath '/trace-toc/run[@number=1]/data/table[@schema="os-signpost"]' --output /tmp/stop.xml
///
/// Verified 2026-08-14: that pipeline produces `os-signpost` rows carrying this
/// category and these interval names. `log show` and `log stream` will NOT show
/// them, and neither will a stock template such as `CPU Profiler` — signposts are
/// an ephemeral channel that only a recording tool with the `os_signpost`
/// instrument collects, which is also why they cost nothing when nobody is looking.
///
/// Add a span whenever a stage lands on this path. An unmeasured stage is a stage
/// that will eventually be discovered by reading source, at a cost.
enum StopPath {
    static let signposter = OSSignposter(subsystem: "com.voiceoour.app", category: "stop-path")

    /// Names are `StaticString` because `OSSignposter` requires it, and they are
    /// listed here so the set of measured stages is enumerable in one place.
    enum Stage {
        static let total: StaticString = "stop.total"
        static let finalizeAudio: StaticString = "stop.finalizeAudio"
        static let vocabulary: StaticString = "stop.vocabulary"
        static let cleanup: StaticString = "stop.cleanup"
        static let termAuthorization: StaticString = "stop.termAuthorization"
        static let journal: StaticString = "stop.journal"
        static let insert: StaticString = "stop.insert"
    }
}

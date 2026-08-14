import Foundation

// Production code, never gated behind `UI_HARNESS`.
//
// Named for the runtime values it supplies rather than for its main consumer.
// The offscreen flow harness installs a deterministic instance, but production
// reads `override ?? .live`, so a shipping launch behaves exactly as before.

/// Timing and identity operations whose real values are nondeterministic.
///
/// `.live` calls the same Foundation and task APIs production used before this
/// seam existed. The flow harness overrides it only while building a fixture.
public struct DictationRuntime: Sendable {
    public let now: @Sendable () -> Date
    public let makeUUID: @Sendable () -> UUID
    public let sleep: @Sendable (UInt64) async throws -> Void
    /// The calendar dictation statistics are bucketed by. A value, not a
    /// behaviour: the harness pins it so a golden's day rows and streak do not
    /// depend on the developer's region.
    public let calendar: @Sendable () -> Calendar

    // Closure literals, not `Date.init`/`UUID.init`: an initializer reference is not
    // `@Sendable`, and the resulting conversion warning is fatal under CI's
    // `-warnings-as-errors`.
    public init(
        now: @escaping @Sendable () -> Date,
        makeUUID: @escaping @Sendable () -> UUID,
        sleep: @escaping @Sendable (UInt64) async throws -> Void,
        calendar: @escaping @Sendable () -> Calendar = { Calendar.current }
    ) {
        self.now = now
        self.makeUUID = makeUUID
        self.sleep = sleep
        self.calendar = calendar
    }

    public static let live = DictationRuntime(
        now: { Date() },
        makeUUID: { UUID() },
        sleep: { try await Task.sleep(nanoseconds: $0) }
    )
}

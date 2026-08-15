import Foundation

/// Monotonic generation counters for async work that a newer request supersedes.
///
/// Async invalidation has one mechanism across every concern: take a token
/// before launching, and on resume only commit if the token is still current.
/// Named scopes keep ownership explicit without parallel hand-written counters.
///
/// Main-actor bound on purpose. Every read and bump happens while deciding
/// whether to publish UI state, so a lock would buy nothing and an actor would
/// make each check an await, which is exactly what these guards must not be.
@MainActor
struct AsyncGenerationGate {
    /// The distinct pieces of superseded work the coordinator tracks.
    enum Scope: CaseIterable, Sendable {
        /// A dictation start. Bumped by `start()`; a queued begin-recording task
        /// from an older start must not take the recorder.
        case recordingStart
        /// The stop pipeline. Bumped by cancel and error paths as well as by a
        /// newer stop, because those also invalidate an in-flight result.
        case processing
    }

    /// A claim on one scope, taken before launching async work.
    ///
    /// Carries its scope so a token cannot be checked against the wrong counter,
    /// which a bare `Int` allowed.
    struct Token: Equatable, Sendable {
        let scope: Scope
        let value: Int
    }

    private var counters: [Scope: Int] = [:]

    init() {
        for scope in Scope.allCases { counters[scope] = 0 }
    }

    /// Bumps `scope` and returns the token the caller must re-check on resume.
    mutating func begin(_ scope: Scope) -> Token {
        let next = (counters[scope] ?? 0) + 1
        counters[scope] = next
        return Token(scope: scope, value: next)
    }

    /// True while `token` is still the newest claim on its scope.
    func isCurrent(_ token: Token) -> Bool {
        counters[token.scope] == token.value
    }

    /// Abandons whatever holds `scope` without issuing a new token, for a cancel
    /// that starts nothing in its place.
    ///
    /// This is why cancelling *work* and cancelling *user-visible state* stay
    /// separate: invalidating the processing scope stops a late result from
    /// landing, and the caller still decides what the session should display.
    mutating func invalidate(_ scope: Scope) {
        counters[scope] = (counters[scope] ?? 0) + 1
    }

    /// The current claim on `scope` without taking a new one, for a caller that
    /// must observe another scope's generation rather than own it — the
    /// suggestion task watches `recordingStart` while owning `processing`.
    func currentToken(_ scope: Scope) -> Token {
        Token(scope: scope, value: counters[scope] ?? 0)
    }
}

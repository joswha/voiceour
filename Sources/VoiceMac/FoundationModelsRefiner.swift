import Foundation
import VoiceCore

#if canImport(FoundationModels)
    import FoundationModels
#endif

public struct FoundationModelsRefinerConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var timeoutMs: Int

    public init(enabled: Bool, timeoutMs: Int = 3000) {
        self.enabled = enabled
        self.timeoutMs = timeoutMs
    }
}

enum FoundationModelsRefinerError: Error, Equatable {
    case timedOut

    var reason: String {
        switch self {
        case .timedOut: "timed_out"
        }
    }
}

private final class WallClockTimeoutRace<Response: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Response, Error>?
    private var pendingResult: Result<Response, Error>?
    private var tasks: (operation: Task<Void, Never>, timer: Task<Void, Never>)?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Response, Error>) {
        lock.lock()
        if let result = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func own(
        operation: Task<Void, Never>,
        timer: Task<Void, Never>
    ) {
        lock.lock()
        tasks = (operation, timer)
        let shouldCancel = isResolved
        lock.unlock()
        if shouldCancel {
            operation.cancel()
            timer.cancel()
        }
    }

    func resolve(_ result: Result<Response, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let tasks = tasks
        lock.unlock()

        tasks?.operation.cancel()
        tasks?.timer.cancel()
        continuation?.resume(with: result)
    }
}

/// Races an async operation against a monotonic wall-clock deadline and
/// cancels whichever side loses. It returns as soon as one side resolves,
/// even when the losing operation does not cooperate with cancellation.
func withWallClockTimeout<Response: Sendable>(
    timeoutNanoseconds: UInt64,
    timeoutError: @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> Response,
    sleep: @escaping @Sendable (UInt64) async throws -> Void = {
        try await Task.sleep(nanoseconds: $0)
    }
) async throws -> Response {
    try Task.checkCancellation()
    let race = WallClockTimeoutRace<Response>()
    return try await withTaskCancellationHandler(
        operation: {
            try Task.checkCancellation()
            let operationTask = Task {
                do {
                    try Task.checkCancellation()
                    let value = try await operation()
                    try Task.checkCancellation()
                    race.resolve(.success(value))
                } catch {
                    race.resolve(.failure(error))
                }
            }
            let timerTask = Task {
                do {
                    try Task.checkCancellation()
                    try await sleep(timeoutNanoseconds)
                    try Task.checkCancellation()
                    race.resolve(.failure(timeoutError()))
                } catch {
                    race.resolve(.failure(error))
                }
            }
            race.own(operation: operationTask, timer: timerTask)
            return try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        },
        onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    )
}

/// Races one response against the transcript-adaptive refinement timeout.
func withFoundationModelsResponseTimeout<Response: Sendable>(
    configuredTimeoutMs: Int,
    transcript: String,
    response: @escaping @Sendable () async throws -> Response,
    sleep: @escaping @Sendable (UInt64) async throws -> Void = {
        try await Task.sleep(nanoseconds: $0)
    }
) async throws -> Response {
    let timeoutMs = RefinerPolicy.effectiveTimeoutMs(
        configuredMs: configuredTimeoutMs,
        transcript: transcript
    )
    return try await withWallClockTimeout(
        timeoutNanoseconds: UInt64(max(timeoutMs, 1)) * 1_000_000,
        timeoutError: { FoundationModelsRefinerError.timedOut },
        operation: response,
        sleep: sleep
    )
}

/// Human-readable Apple Intelligence availability for the settings UI.
/// Safe to call on any macOS version.
public enum FoundationModelsAvailability {
    public static func summary() -> (available: Bool, detail: String) {
        #if canImport(FoundationModels)
            guard #available(macOS 26.0, *) else {
                return (false, "Requires macOS 26 or later")
            }
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "Apple Intelligence model ready")
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return (false, "This Mac does not support Apple Intelligence")
                case .appleIntelligenceNotEnabled:
                    return (false, "Enable Apple Intelligence in System Settings")
                case .modelNotReady:
                    return (false, "Apple Intelligence model is still downloading")
                @unknown default:
                    return (false, "Apple Intelligence unavailable")
                }
            }
        #else
            return (false, "Requires macOS 26 or later")
        #endif
    }
}

/// Refiner that never runs: installed when the selected provider cannot work on
/// this system (e.g. Apple On-Device on macOS < 26). Refinement degrades to the
/// deterministic cleanup path via a skip, mirroring other preflight skips.
public struct UnsupportedRefiner: TranscriptRefining {
    private let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func refine(_ raw: String, glossary: [ProtectedTerm], safety: TargetSafetyClass, style: RefinementStyle)
        async -> RefineOutcome
    {
        .skipped(reason: reason)
    }
}

/// Concurrency-safe owner for one-shot sessions.
///
/// A checked-out session is never returned. Replenishment is single-flight and
/// only runs while no checkout or discarded-but-responding session exists, so
/// preparation cannot contend with generation. A later warm-up or terminal
/// checkout prunes settled discards and safely retries replenishment. `Session`
/// stays generic so the lifecycle can be tested without loading the system
/// language model.
final class SingleUsePrewarmedSessionSlot<Session: Sendable>: @unchecked Sendable {
    struct Checkout: Sendable {
        fileprivate let id: UInt64
        let session: Session
    }

    struct Snapshot: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case empty
            case prewarming
            case ready
        }

        let state: State
        let activeCheckouts: Int
        let respondingCheckouts: Int
        let unsettledDiscardedSessions: Int
        let rejectedPrewarms: Int
        let unsettledDiscards: Int
    }

    private enum State {
        case empty
        case prewarming
        case ready(Session)
    }

    private let lock = NSLock()
    private let makeSession: @Sendable () -> Session
    private let prepare: @Sendable (Session) -> Bool
    private let isSettled: @Sendable (Session) -> Bool
    private var state: State = .empty
    private var activeCheckouts: [UInt64: Session] = [:]
    private var nextCheckoutID: UInt64 = 0
    private var replenishmentRequested = false
    private var rejectedPrewarms = 0
    private var unsettledDiscards = 0
    private var unsettledDiscardedSessions: [Session] = []

    init(
        makeSession: @escaping @Sendable () -> Session,
        prepare: @escaping @Sendable (Session) -> Bool,
        isSettled: @escaping @Sendable (Session) -> Bool = { _ in true }
    ) {
        self.makeSession = makeSession
        self.prepare = prepare
        self.isSettled = isSettled
    }

    func warmUp() {
        prepare(replacingReadySession: false)
    }

    /// Replaces an unused prepared session so the next checkout receives one
    /// prewarmed for an imminent request rather than a stale spare.
    ///
    /// This is the only routine path that prepares a session. Preparation is
    /// deliberately *not* triggered by finishing a refine: a spare prepared at
    /// that moment sits idle until the next dictation, and keeps little of its
    /// value across that gap. Measured with idle held at 30s and only the
    /// prewarm placement varied (240 trials, shuffled): preparing after the
    /// idle with a ~400ms lead is 383.5ms faster (paired median) than
    /// preparing before it, while a pre-idle spare retains only 37.2ms of the
    /// 419.1ms a freshly-timed prewarm is worth. No eviction threshold was
    /// located and 30s is a lower bound on real idle; see
    /// docs/performance-roadmap.md. Preparing on the imminent-use hook means
    /// exactly one preparation per refined utterance, correctly timed, rather
    /// than one wasted spare plus one useful one.
    func prepareFresh() {
        prepare(replacingReadySession: true)
    }

    private func prepare(replacingReadySession: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard activeCheckouts.isEmpty else {
            replenishmentRequested = true
            return
        }
        discardSettledSessionsLocked()
        guard unsettledDiscardedSessions.isEmpty else {
            replenishmentRequested = true
            return
        }
        if replacingReadySession, case .ready = state {
            state = .empty
        }
        prepareIfNeededLocked()
    }

    func checkout() -> Checkout {
        lock.lock()
        defer { lock.unlock() }

        let session: Session
        switch state {
        case .ready(let prepared):
            session = prepared
            state = .empty
        case .empty:
            session = makeSession()
        case .prewarming:
            // Preparation holds this lock until it resolves, so no caller can
            // observe the transitional state.
            preconditionFailure("prewarming state escaped session-slot lock")
        }

        let id = nextCheckoutID
        nextCheckoutID &+= 1
        activeCheckouts[id] = session
        // Deliberately does not request replenishment; see `prepareFresh()`.
        // `replenishmentRequested` is set only when an imminent-use preparation
        // had to be deferred past an in-flight checkout, so `discard` still
        // honours that case for back-to-back dictations.
        return Checkout(id: id, session: session)
    }

    func discard(_ checkout: Checkout) {
        lock.lock()
        defer { lock.unlock() }
        guard activeCheckouts.removeValue(forKey: checkout.id) != nil else { return }
        if !isSettled(checkout.session) {
            unsettledDiscards += 1
            unsettledDiscardedSessions.append(checkout.session)
            return
        }
        discardSettledSessionsLocked()
        guard activeCheckouts.isEmpty,
            unsettledDiscardedSessions.isEmpty,
            replenishmentRequested
        else { return }
        prepareIfNeededLocked()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let visibleState: Snapshot.State
        switch state {
        case .empty: visibleState = .empty
        case .prewarming: visibleState = .prewarming
        case .ready: visibleState = .ready
        }
        return Snapshot(
            state: visibleState,
            activeCheckouts: activeCheckouts.count,
            respondingCheckouts: activeCheckouts.values.lazy.filter { !self.isSettled($0) }.count,
            unsettledDiscardedSessions: unsettledDiscardedSessions.lazy.filter { !self.isSettled($0) }.count,
            rejectedPrewarms: rejectedPrewarms,
            unsettledDiscards: unsettledDiscards
        )
    }

    private func discardSettledSessionsLocked() {
        unsettledDiscardedSessions.removeAll(where: isSettled)
    }

    private func prepareIfNeededLocked() {
        guard case .empty = state else {
            replenishmentRequested = false
            return
        }
        state = .prewarming
        let session = makeSession()
        if prepare(session) {
            state = .ready(session)
        } else {
            rejectedPrewarms += 1
            state = .empty
        }
        replenishmentRequested = false
    }
}

#if canImport(FoundationModels)
    /// Refines transcripts with Apple's on-device system model (macOS 26+).
    ///
    /// Zero network, zero app-managed model memory (the system loads and evicts the
    /// model), with measured p50 refinement latency of ~1.6-2.0s on M4 Pro using the
    /// production glossary. Each utterance gets a fresh `LanguageModelSession` so
    /// dictations never share context. Uses the permissive content-transformation
    /// guardrails: dictation is a text-transform workload, and
    /// the transcript must be treated as data even when it sounds imperative.
    @available(macOS 26.0, *)
    public final class FoundationModelsRefiner: TranscriptRefining, @unchecked Sendable {
        private let configuration: FoundationModelsRefinerConfiguration
        private let deterministicFallback: ((String) -> String)?
        private let model: SystemLanguageModel
        private let sessionSlot: SingleUsePrewarmedSessionSlot<LanguageModelSession>

        public init(
            configuration: FoundationModelsRefinerConfiguration,
            deterministicFallback: ((String) -> String)? = nil
        ) {
            self.configuration = configuration
            self.deterministicFallback = deterministicFallback
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            self.model = model
            self.sessionSlot = SingleUsePrewarmedSessionSlot(
                makeSession: {
                    LanguageModelSession(model: model, instructions: RefinerPolicy.onDeviceSystemPrompt)
                },
                prepare: { session in
                    let pristineTranscript = session.transcript
                    session.prewarm(promptPrefix: nil)
                    return session.transcript == pristineTranscript
                },
                isSettled: { !$0.isResponding }
            )
        }

        /// Prepares a fresh one-shot session for a likely imminent refinement.
        public func warmUp() async {
            guard configuration.enabled, case .available = model.availability else { return }
            sessionSlot.prepareFresh()
        }

        static func userMessage(
            raw: String,
            glossary: [ProtectedTerm],
            style: RefinementStyle
        ) -> String {
            RefinerPolicy.ompUserMessage(raw: raw, glossary: glossary, style: style)
        }

        public func refine(_ raw: String, glossary: [ProtectedTerm], safety: TargetSafetyClass, style: RefinementStyle)
            async -> RefineOutcome
        {
            let fallback = RefinerPolicy.deterministicFallback(for: raw, using: deterministicFallback)
            if let reason = RefinerPolicy.preflightSkipReason(
                enabled: configuration.enabled,
                safety: safety,
                isConfigured: true
            ) {
                return .skipped(reason: reason)
            }
            guard case .available = model.availability else {
                return .fellBack(fallback, reason: "apple_intelligence_unavailable")
            }

            let message = Self.userMessage(raw: raw, glossary: glossary, style: style)
            do {
                let candidate = try await respondWithTimeout(message, transcript: raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else { return .fellBack(fallback, reason: "empty_output") }
                return RefinerPolicy.guardedOutcome(
                    original: raw, candidate: candidate, glossary: glossary, fallback: fallback)
            } catch is CancellationError {
                return .fellBack(fallback, reason: "cancelled")
            } catch let error as FoundationModelsRefinerError {
                return .fellBack(fallback, reason: error.reason)
            } catch {
                return .fellBack(fallback, reason: Self.fallbackReason(for: error))
            }
        }

        func sessionLifecycleSnapshot() -> SingleUsePrewarmedSessionSlot<LanguageModelSession>.Snapshot {
            sessionSlot.snapshot()
        }

        private func respondWithTimeout(_ message: String, transcript: String) async throws -> String {
            let checkout = sessionSlot.checkout()
            let session = checkout.session
            defer { sessionSlot.discard(checkout) }
            let options = GenerationOptions(sampling: .greedy, temperature: 0.0, maximumResponseTokens: 512)
            return try await withFoundationModelsResponseTimeout(
                configuredTimeoutMs: configuration.timeoutMs,
                transcript: transcript,
                response: {
                    try await session.respond(to: message, options: options).content
                }
            )
        }

        /// Maps FoundationModels generation errors to session-trace reasons.
        static func fallbackReason(for error: Error) -> String {
            guard let error = error as? LanguageModelSession.GenerationError else {
                return "generation_failed"
            }
            switch error {
            case .guardrailViolation:
                return "guardrail"
            case .refusal:
                return "refusal"
            case .exceededContextWindowSize:
                return "context_overflow"
            case .rateLimited:
                return "rate_limited"
            case .concurrentRequests:
                return "busy"
            case .assetsUnavailable:
                return "apple_intelligence_unavailable"
            case .unsupportedLanguageOrLocale:
                return "unsupported_language"
            case .decodingFailure:
                return "generation_failed"
            case .unsupportedGuide:
                return "generation_failed"
            @unknown default:
                return "generation_failed"
            }
        }
    }

#endif

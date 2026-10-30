/// When the recording island hands itself to another display.
///
/// A hand-off is a siphon — the body drains into one display's top edge and grows out of
/// the next — so a move costs a visible gesture, and a policy that moved on every signal would
/// pump the body between displays. Each rule answers one way that happens:
///
/// - A click on another display is a hint, not an answer: it may land on wallpaper or a
///   menu-bar extra. It waits `clickDeferral` for the activation it may cause, then focus
///   decides.
/// - Focus moves at once: the frontmost window's display is where dictation will land.
/// - Going back to a display left less than `returnWindow` ago must persist for `returnHold`
///   first, so focus bouncing between two displays — a Command-Tab overshoot, a transient
///   panel — does not ping-pong the body.
/// - `stormMoves` moves within `stormWindow` mean the user is moving faster than a siphon can
///   read; later moves are instant re-frames until `stormQuiet` passes without one.
/// - A frozen island stays. An outcome dwell shows its result where it is, and a session the
///   user dragged has been placed. A reconfiguring arrangement describes displays that are
///   still changing, so every move waits for `reconfigurationQuiet` without another
///   reconfiguration, then focus decides.
/// - The display the island is already on is never a move.
///
/// Pure and time-injected: `now` is any monotonic clock in seconds, the caller's choice. The
/// policy reads no clock, screen or pointer, so every rule replays exactly as a table.
struct RecordingOverlayMovePolicy: Sendable {
    /// What proposed the candidate display.
    enum Cause: Sendable, Equatable {
        /// An app activation, a Space change, or the frontmost window landing elsewhere.
        case focus
        /// A mouse-down on another display.
        case pointerClick
        /// Displays were attached, detached, re-moded or rearranged.
        case reconfiguration
    }

    enum Decision: Sendable, Equatable {
        /// Keep the island where it is.
        case stay
        /// Hand the island to `display`; `instant` re-frames it without the siphon.
        case move(display: UInt32, instant: Bool)
        /// Not yet: at `at`, resolve the candidate by focus again and evaluate it as `.focus`.
        case reevaluate(at: Double)
    }

    /// How long a click waits for the activation it may cause, in seconds.
    static let clickDeferral: Double = 0.12
    /// A display left less than this long ago is a return.
    static let returnWindow: Double = 1.5
    /// How long a return must persist before the island goes back.
    static let returnHold: Double = 0.4
    /// This many moves inside one `stormWindow` make the moves after them instant.
    static let stormMoves = 3
    static let stormWindow: Double = 5
    /// Time without a move that ends a storm.
    static let stormQuiet: Double = 3
    /// Time without a reconfiguration before the arrangement is trusted again.
    static let reconfigurationQuiet: Double = 0.3

    /// When the island last left each display.
    private var departures: [UInt32: Double] = [:]
    /// A return waiting out `returnHold`: the display and when it was first proposed.
    private var pendingReturn: (display: UInt32, since: Double)?
    /// Moves within the last `stormWindow`, oldest first; the last is the latest move.
    private var recentMoves: [Double] = []
    private var isStorming = false
    private var lastReconfiguration: Double?

    /// Decides what to do with `candidate`, proposed by `cause` while the island is on
    /// `current`. `frozen` is the caller's own reason to stay: an outcome dwell, or a session
    /// the user dragged.
    mutating func evaluate(
        now: Double,
        current: UInt32,
        candidate: UInt32,
        cause: Cause,
        frozen: Bool
    ) -> Decision {
        if cause == .reconfiguration {
            lastReconfiguration = now
        }
        if frozen {
            return .stay
        }
        if let lastReconfiguration, now < lastReconfiguration + Self.reconfigurationQuiet {
            return .reevaluate(at: lastReconfiguration + Self.reconfigurationQuiet)
        }
        if candidate == current {
            pendingReturn = nil
            return .stay
        }
        if cause == .pointerClick {
            return .reevaluate(at: now + Self.clickDeferral)
        }
        if pendingReturn?.display != candidate, let left = departures[candidate], now - left < Self.returnWindow {
            pendingReturn = (candidate, now)
        }
        if let pendingReturn, pendingReturn.display == candidate, now < pendingReturn.since + Self.returnHold {
            return .reevaluate(at: pendingReturn.since + Self.returnHold)
        }
        endStormIfQuiet(now: now)
        return .move(display: candidate, instant: isStorming)
    }

    /// Records a hand-off the controller carried out, at the moment the island left `from`.
    /// A hand-off onto the display it was already on is not a move and records nothing.
    mutating func didMove(now: Double, from: UInt32, to: UInt32) {
        guard from != to else { return }
        endStormIfQuiet(now: now)
        departures[from] = now
        recentMoves.append(now)
        recentMoves.removeAll { now - $0 >= Self.stormWindow }
        if recentMoves.count >= Self.stormMoves {
            isStorming = true
        }
        pendingReturn = nil
    }

    private mutating func endStormIfQuiet(now: Double) {
        if isStorming, let latest = recentMoves.last, now - latest >= Self.stormQuiet {
            isStorming = false
        }
    }
}

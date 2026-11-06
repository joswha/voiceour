import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

/// The idle-unload decision, tested as the pure function it was extracted to be.
///
/// The timer's process-level behaviour needs a loadable model and is covered by the
/// `VOICEOUR_GRANITE_INTEGRATION` case in `SidecarProcessTests`; this suite pins the rule that
/// decides when it fires.
@Suite("IdleUnloadTests")
struct IdleUnloadTests {
    @Test func aDisabledUnloadNeverFires() {
        #expect(
            !GraniteSidecarBackend.isIdleUnloadDue(idleUnloadMs: 0, contextLoaded: true, idleMs: 10_000_000)
        )
        #expect(
            !GraniteSidecarBackend.isIdleUnloadDue(idleUnloadMs: -1, contextLoaded: true, idleMs: 10_000_000)
        )
    }

    @Test func anUnloadedBackendHasNothingToUnload() {
        #expect(
            !GraniteSidecarBackend.isIdleUnloadDue(idleUnloadMs: 1_800_000, contextLoaded: false, idleMs: 3_600_000)
        )
    }

    @Test func theDeadlineIsInclusiveAndNotEarly() {
        let threshold = 1_800_000
        #expect(
            !GraniteSidecarBackend.isIdleUnloadDue(
                idleUnloadMs: threshold,
                contextLoaded: true,
                idleMs: threshold - 1
            )
        )
        #expect(
            GraniteSidecarBackend.isIdleUnloadDue(idleUnloadMs: threshold, contextLoaded: true, idleMs: threshold)
        )
        #expect(
            GraniteSidecarBackend.isIdleUnloadDue(idleUnloadMs: threshold, contextLoaded: true, idleMs: threshold * 2)
        )
    }

    /// A backend that never loaded a model answers "no" however long it has been sitting there,
    /// which is what keeps the timer from logging an unload of nothing.
    @Test func liveStateSaysNoWhileNoContextExists() {
        let backend = GraniteSidecarBackend(
            cache: ModelCache(directory: FileManager.default.temporaryDirectory),
            log: { _ in },
            idleUnloadMs: 1
        )

        #expect(!backend.shouldUnloadNow(now: DispatchTime.now() + .seconds(3_600)))
    }
}

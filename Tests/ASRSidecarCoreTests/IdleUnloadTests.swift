import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

/// The idle-unload decision, tested as the pure function it was extracted to be.
///
/// The timer's process-level behaviour needs a loadable 1.26 GB model and is covered by the
/// `VOICEOUR_PARAKEET_INTEGRATION` case in `SidecarProcessTests`; this suite pins the rule that
/// decides when it fires.
@Suite("IdleUnloadTests")
struct IdleUnloadTests {
    @Test func aDisabledUnloadNeverFires() {
        #expect(
            !ParakeetSidecarBackend.isIdleUnloadDue(idleUnloadMs: 0, contextLoaded: true, idleMs: 10_000_000)
        )
        #expect(
            !ParakeetSidecarBackend.isIdleUnloadDue(idleUnloadMs: -1, contextLoaded: true, idleMs: 10_000_000)
        )
    }

    @Test func anUnloadedBackendHasNothingToUnload() {
        #expect(
            !ParakeetSidecarBackend.isIdleUnloadDue(idleUnloadMs: 1_800_000, contextLoaded: false, idleMs: 3_600_000)
        )
    }

    @Test func theDeadlineIsInclusiveAndNotEarly() {
        let threshold = 1_800_000
        #expect(
            !ParakeetSidecarBackend.isIdleUnloadDue(
                idleUnloadMs: threshold,
                contextLoaded: true,
                idleMs: threshold - 1
            )
        )
        #expect(
            ParakeetSidecarBackend.isIdleUnloadDue(idleUnloadMs: threshold, contextLoaded: true, idleMs: threshold)
        )
        #expect(
            ParakeetSidecarBackend.isIdleUnloadDue(idleUnloadMs: threshold, contextLoaded: true, idleMs: threshold * 2)
        )
    }

    /// A backend that never loaded a model answers "no" however long it has been sitting there,
    /// which is what keeps the timer from logging an unload of nothing.
    @Test func liveStateSaysNoWhileNoContextExists() {
        let backend = ParakeetSidecarBackend(
            cache: ParakeetModelCache(directory: FileManager.default.temporaryDirectory),
            log: { _ in },
            idleUnloadMs: 1
        )

        #expect(!backend.shouldUnloadNow(now: DispatchTime.now() + .seconds(3_600)))
    }
}

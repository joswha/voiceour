import Foundation
import Testing

@testable import VoiceMac

@Suite("FoundationModels session lifecycle", .serialized)
struct FoundationModelsSessionLifecycleTests {
    @Test func concurrentWarmUpsProduceOneReadySpare() async {
        let probe = SessionSlotProbe()
        let slot = probe.makeSlot()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { slot.warmUp() }
            }
        }

        #expect(probe.madeIDs.count == 1)
        #expect(probe.prewarmedIDs == probe.madeIDs)
        #expect(
            slot.snapshot()
                == .init(
                    state: .ready,
                    activeCheckouts: 0,
                    respondingCheckouts: 0,
                    unsettledDiscardedSessions: 0,
                    rejectedPrewarms: 0,
                    unsettledDiscards: 0
                ))
    }

    @Test func responseTimeoutSchedulesTranscriptAdaptiveDuration() async throws {
        let sleepProbe = TimeoutSleepProbe()
        let transcript = Array(repeating: "word", count: 50).joined(separator: " ")

        let result: String = try await withFoundationModelsResponseTimeout(
            configuredTimeoutMs: 100,
            transcript: transcript,
            response: {
                while sleepProbe.scheduledNanoseconds == nil {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                return "refined"
            },
            sleep: { nanoseconds in
                sleepProbe.record(nanoseconds)
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )

        #expect(result == "refined")
        #expect(sleepProbe.scheduledNanoseconds == 200_000_000)
    }

    @Test func responseTimeoutReturnsBeforeCancellationIgnoringResponseSettles() async {
        let sleepProbe = TimeoutSleepProbe()
        let responseStarted = TestGate()
        let responseGate = TestGate()
        let completion = TimeoutRaceProbe()
        let operation = Task { () -> TimeoutRaceOutcome in
            let outcome: TimeoutRaceOutcome
            do {
                let value: String = try await withFoundationModelsResponseTimeout(
                    configuredTimeoutMs: 100,
                    transcript: "one two three",
                    response: {
                        responseStarted.fire()
                        await responseGate.wait()
                        return "too late"
                    },
                    sleep: { nanoseconds in
                        sleepProbe.record(nanoseconds)
                        await responseStarted.wait()
                    }
                )
                outcome = .value(value)
            } catch let error as FoundationModelsRefinerError {
                outcome = error == .timedOut ? .timedOut : .unexpectedError(String(describing: error))
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .unexpectedError(String(describing: error))
            }
            completion.record(outcome)
            return outcome
        }
        defer {
            responseStarted.fire()
            responseGate.fire()
            operation.cancel()
        }

        await waitUntilTimeoutCondition { completion.outcome != nil }

        #expect(completion.outcome == .timedOut)
        #expect(!responseGate.isOpen)
        #expect(sleepProbe.scheduledNanoseconds == 160_000_000)

        responseGate.fire()
        _ = await operation.value
    }

    @Test func callerCancellationReturnsBeforeCancellationIgnoringResponseSettles() async {
        let responseStarted = TestGate()
        let responseGate = TestGate()
        let completion = TimeoutRaceProbe()
        let operation = Task { () -> TimeoutRaceOutcome in
            let outcome: TimeoutRaceOutcome
            do {
                let value: String = try await withFoundationModelsResponseTimeout(
                    configuredTimeoutMs: 100,
                    transcript: "one two three",
                    response: {
                        responseStarted.fire()
                        await responseGate.wait()
                        return "too late"
                    },
                    sleep: { nanoseconds in
                        try await Task.sleep(nanoseconds: nanoseconds)
                    }
                )
                outcome = .value(value)
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as FoundationModelsRefinerError {
                outcome = error == .timedOut ? .timedOut : .unexpectedError(String(describing: error))
            } catch {
                outcome = .unexpectedError(String(describing: error))
            }
            completion.record(outcome)
            return outcome
        }
        defer {
            responseStarted.fire()
            responseGate.fire()
            operation.cancel()
        }

        await waitUntilTimeoutCondition { responseStarted.isOpen }
        #expect(responseStarted.isOpen)
        operation.cancel()
        await waitUntilTimeoutCondition { completion.outcome != nil }

        #expect(completion.outcome == .cancelled)
        #expect(!responseGate.isOpen)

        responseGate.fire()
        _ = await operation.value
    }

    @Test func imminentPreparationReplacesAnUnusedReadySpare() {
        let probe = SessionSlotProbe()
        let slot = probe.makeSlot()
        slot.warmUp()

        slot.prepareFresh()

        #expect(probe.madeIDs.count == 2)
        #expect(probe.prewarmedIDs.count == 2)
        let checkout = slot.checkout()
        #expect(probe.prewarmedIDs.last.map { $0 == checkout.session.id } == true)
        slot.discard(checkout)
    }

    @Test func imminentPreparationWaitsForAnActiveCheckout() {
        let probe = SessionSlotProbe()
        let slot = probe.makeSlot()
        slot.warmUp()
        let checkout = slot.checkout()

        slot.prepareFresh()

        #expect(probe.madeIDs.count == 1)
        #expect(slot.snapshot().activeCheckouts == 1)
        slot.discard(checkout)
        #expect(probe.prewarmedIDs.count == 2)
        #expect(slot.snapshot().state == .ready)
    }

    @Test func concurrentCheckoutsAreDistinctAndDeferredPreparationLandsAfterAllFinish() async {
        let probe = SessionSlotProbe()
        let slot = probe.makeSlot()
        slot.warmUp()

        let checkouts = await withTaskGroup(
            of: SingleUsePrewarmedSessionSlot<FakeSession>.Checkout.self,
            returning: [SingleUsePrewarmedSessionSlot<FakeSession>.Checkout].self
        ) { group in
            for _ in 0..<12 {
                group.addTask { slot.checkout() }
            }
            var values: [SingleUsePrewarmedSessionSlot<FakeSession>.Checkout] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(Set(checkouts.map(\.session.id)).count == 12)
        #expect(probe.prewarmedIDs.count == 1)
        #expect(slot.snapshot().activeCheckouts == 12)
        #expect(slot.snapshot().state == .empty)

        // An imminent-use preparation raised while checkouts are in flight is
        // deferred rather than dropped, and must land once the last settles.
        slot.prepareFresh()
        #expect(probe.prewarmedIDs.count == 1)

        for checkout in checkouts.dropLast() {
            slot.discard(checkout)
        }
        #expect(probe.prewarmedIDs.count == 1)
        #expect(slot.snapshot().activeCheckouts == 1)

        slot.discard(checkouts.last!)
        #expect(probe.prewarmedIDs.count == 2)
        #expect(slot.snapshot().state == .ready)
        #expect(slot.snapshot().activeCheckouts == 0)

        let next = slot.checkout()
        #expect(!checkouts.map(\.session.id).contains(next.session.id))
        slot.discard(next)
    }

    @Test func everyTerminalCheckoutIsDiscardedAndNeverReused() {
        let probe = SessionSlotProbe()
        let slot = probe.makeSlot()
        slot.warmUp()

        for _ in 0..<4 {
            let used = slot.checkout()
            let usedID = used.session.id
            slot.discard(used)
            let replacement = slot.checkout()
            #expect(replacement.session.id != usedID)
            slot.discard(replacement)
        }

        #expect(slot.snapshot().activeCheckouts == 0)
        // Finishing a refine deliberately leaves no prepared spare: one made
        // here would be evicted before the next dictation. Readiness comes
        // from the imminent-use hook instead, so exactly one preparation is
        // paid per refined utterance.
        #expect(slot.snapshot().state == .empty)
        slot.prepareFresh()
        #expect(slot.snapshot().state == .ready)
    }

    @Test func unsettledDiscardSuppressesPrewarmUntilLaterWarmUpAfterSettlement() {
        let probe = SessionSlotProbe(acceptPrewarm: false)
        let slot = probe.makeSlot()
        slot.warmUp()

        #expect(slot.snapshot().state == .empty)
        #expect(slot.snapshot().rejectedPrewarms == 1)

        let checkout = slot.checkout()
        probe.setSettled(false, for: checkout.session.id)
        #expect(slot.snapshot().respondingCheckouts == 1)
        slot.discard(checkout)

        var snapshot = slot.snapshot()
        #expect(snapshot.state == .empty)
        #expect(snapshot.activeCheckouts == 0)
        #expect(snapshot.respondingCheckouts == 0)
        #expect(snapshot.unsettledDiscardedSessions == 1)
        #expect(snapshot.rejectedPrewarms == 1)
        #expect(snapshot.unsettledDiscards == 1)
        #expect(probe.prewarmedIDs.count == 1)

        probe.setSettled(true, for: checkout.session.id)
        snapshot = slot.snapshot()
        #expect(snapshot.unsettledDiscardedSessions == 0)
        #expect(snapshot.state == .empty)
        #expect(probe.prewarmedIDs.count == 1)

        slot.warmUp()
        snapshot = slot.snapshot()
        #expect(snapshot.state == .empty)
        #expect(snapshot.rejectedPrewarms == 2)
        #expect(probe.prewarmedIDs.count == 2)
    }
}

private final class TimeoutSleepProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64?

    func record(_ value: UInt64) {
        lock.lock()
        nanoseconds = value
        lock.unlock()
    }

    var scheduledNanoseconds: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return nanoseconds
    }
}

private enum TimeoutRaceOutcome: Equatable, Sendable {
    case value(String)
    case timedOut
    case cancelled
    case unexpectedError(String)
}

private final class TimeoutRaceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOutcome: TimeoutRaceOutcome?

    var outcome: TimeoutRaceOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return recordedOutcome
    }

    func record(_ outcome: TimeoutRaceOutcome) {
        lock.lock()
        recordedOutcome = outcome
        lock.unlock()
    }
}

private final class FakeSession: @unchecked Sendable {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

private final class SessionSlotProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let acceptPrewarm: Bool
    private var nextID = 0
    private var made: [Int] = []
    private var prewarmed: [Int] = []
    private var settled: [Int: Bool] = [:]

    init(acceptPrewarm: Bool = true) {
        self.acceptPrewarm = acceptPrewarm
    }

    var madeIDs: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    var prewarmedIDs: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return prewarmed
    }

    func makeSlot() -> SingleUsePrewarmedSessionSlot<FakeSession> {
        SingleUsePrewarmedSessionSlot(
            makeSession: { [self] in makeSession() },
            prepare: { [self] session in prepare(session) },
            isSettled: { [self] session in isSettled(session) }
        )
    }

    func setSettled(_ value: Bool, for id: Int) {
        lock.lock()
        settled[id] = value
        lock.unlock()
    }

    private func makeSession() -> FakeSession {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        made.append(id)
        settled[id] = true
        return FakeSession(id: id)
    }

    private func prepare(_ session: FakeSession) -> Bool {
        lock.lock()
        prewarmed.append(session.id)
        lock.unlock()
        return acceptPrewarm
    }

    private func isSettled(_ session: FakeSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled[session.id] ?? false
    }
}

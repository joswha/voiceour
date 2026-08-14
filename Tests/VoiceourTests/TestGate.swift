import Foundation

/// A one-shot async gate: `wait()` suspends until some other task calls `fire()`.
/// Used to hold an injected fake service mid-flight so a test can observe intermediate state.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyOpen: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

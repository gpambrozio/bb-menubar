import Foundation

/// How long `eventually` waits by default. Every gate a test holds work
/// behind must time out well after this (see `gateTimeout`), so a test that
/// forgets to open one fails on its own expectation first.
let eventuallyTimeout: Duration = .seconds(10)

/// How long a test gate blocks before giving up on its own.
let gateTimeout: DispatchTimeInterval = .seconds(30)

/// Polls `condition` on the main actor until it holds, sleeping on the real
/// clock between checks, for work that finishes on another thread (a gate's
/// release, a read on a global queue, an FSEvents delivery). Gives up after
/// `timeout` so a broken implementation fails the test's own expectation
/// instead of hanging it. Returns whether the condition held.
///
/// `settle(until:)` is for work confined to the main actor, where yielding is
/// enough; this is for work that is not.
@MainActor
@discardableResult
func eventually(timeout: Duration = eventuallyTimeout, _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await clock.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// A one-shot gate a test opens to release a pending async call. Waits on a
/// global dispatch queue, never on a Swift concurrency thread. Ported from
/// paseo-menubar.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var opened = false

    func open() {
        let first = lock.withLock {
            defer { opened = true }
            return !opened
        }
        if first { semaphore.signal() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.semaphore.wait(timeout: .now() + gateTimeout)
                continuation.resume()
            }
        }
    }
}

import Foundation

extension Clock where Duration == Swift.Duration {
    /// Runs `body` on the main actor once `delay` has passed on this clock,
    /// unless the returned task is cancelled first. The deadline is fixed
    /// here, when the timer is armed, not when the task first runs, so how
    /// soon the task gets scheduled cannot stretch the delay: a `TestClock`
    /// advanced before the task starts still fires it.
    ///
    /// Shared by `RealtimeSession` and `RuntimeSession` for their debounce,
    /// reconnect, and poll timers.
    func timer(delay: Duration, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let deadline = now.advanced(by: delay)
        return Task { @MainActor in
            do {
                try await sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            // The sleep can end and this task wait its turn on the main actor
            // while its owner cancels it; that cancel still wins.
            guard !Task.isCancelled else { return }
            body()
        }
    }
}

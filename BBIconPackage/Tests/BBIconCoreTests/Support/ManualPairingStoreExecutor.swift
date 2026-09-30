import Foundation
import BBIconCore

/// A `PairingStoreExecutor` a test drives by hand. Passing through, it runs
/// each call at once; holding, it queues them until the test releases one,
/// in any order, which is how a test makes a Keychain call answer late.
final class ManualPairingStoreExecutor: PairingStoreExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var holding: Bool
    private var jobs: [@Sendable () -> Void] = []

    init(holding: Bool = false) {
        self.holding = holding
    }

    /// Calls waiting to be released.
    var pending: Int { lock.withLock { jobs.count } }

    func hold() { lock.withLock { holding = true } }

    /// Runs the waiting call at `index` (0 is the oldest) and answers it.
    /// Returns false when there is no such call.
    @discardableResult
    func release(_ index: Int = 0) -> Bool {
        let job = lock.withLock { () -> (@Sendable () -> Void)? in
            guard jobs.indices.contains(index) else { return nil }
            return jobs.remove(at: index)
        }
        job?()
        return job != nil
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, any Error> {
        await withCheckedContinuation { continuation in
            let job: @Sendable () -> Void = { continuation.resume(returning: Result { try work() }) }
            let runNow = lock.withLock { () -> Bool in
                if holding { jobs.append(job) }
                return !holding
            }
            if runNow { job() }
        }
    }
}

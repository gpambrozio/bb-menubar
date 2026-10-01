import Foundation
import BBIconCore

/// An in-memory `PairingStore` that records what was asked of it and can be
/// told to fail, so everything above the Keychain is tested without it.
/// `KeychainPairingStoreTests` runs the same contract against this fake and
/// the real store, so the two cannot drift apart.
///
/// A class under a lock rather than an actor, because `PairingStore` is
/// synchronous.
final class FakePairingStore: PairingStore, @unchecked Sendable {
    struct Failure: MessageError, Equatable {
        let message: String
    }

    private let lock = NSLock()
    private var stored: Pairing?
    private var loadFailure: Failure?
    private var saveFailure: Failure?
    private var deleteFailure: Failure?
    private var saveCount = 0
    private var deleteCount = 0

    init(_ pairing: Pairing? = nil) {
        stored = pairing
    }

    /// What is stored now, without going through `load()`.
    var pairing: Pairing? { lock.withLock { stored } }
    var saves: Int { lock.withLock { saveCount } }
    var deletes: Int { lock.withLock { deleteCount } }

    /// Makes every later call of that kind throw `message`, until cleared
    /// with `nil`.
    func failLoad(_ message: String?) { lock.withLock { loadFailure = message.map(Failure.init) } }
    func failSave(_ message: String?) { lock.withLock { saveFailure = message.map(Failure.init) } }
    func failDelete(_ message: String?) { lock.withLock { deleteFailure = message.map(Failure.init) } }

    func load() throws -> Pairing? {
        try lock.withLock {
            if let loadFailure { throw loadFailure }
            return stored
        }
    }

    func save(_ pairing: Pairing) throws {
        try lock.withLock {
            saveCount += 1
            if let saveFailure { throw saveFailure }
            stored = pairing
        }
    }

    func delete() throws {
        try lock.withLock {
            deleteCount += 1
            if let deleteFailure { throw deleteFailure }
            stored = nil
        }
    }
}

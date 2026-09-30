import Foundation

/// Where the pairing store's calls run. The Keychain can block — reading the
/// item after an update raises a prompt that waits for the user — so the
/// calls go somewhere that is neither the main thread nor a cooperative-pool
/// thread. Injected, so tests decide when each call answers.
public protocol PairingStoreExecutor: Sendable {
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, any Error>
}

/// The production executor: one serial dispatch queue, which also keeps the
/// store's calls in the order they were asked for.
public struct SerialQueuePairingStoreExecutor: PairingStoreExecutor {
    private let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    public func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, any Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result { try work() })
            }
        }
    }
}

/// How a pairing attempt ended.
public enum PairOutcome: Equatable, Sendable {
    /// Paired and in use. A notice, when there is one, is something the user
    /// should read before the window closes.
    case paired(notice: String?)
    /// Nothing was paired; the sentence says why.
    case failed(String)
}

/// What a Forget could not do, to be shown once it is over.
public struct ForgetReport: Equatable, Sendable {
    public let handle: String
    /// One sentence per failure, revoke first; empty when all went well.
    public let problems: [String]
    /// The revoke failed, so the device may still be listed at
    /// getbb.app/dashboard.
    public let revokeFailed: Bool
}

/// The pairing's life: loading it at launch, pairing from a code, and
/// forgetting it. Every step is a core call (`ConnectPairing`, the
/// `PairingStore`, `ConnectRevoke`); what this owns is their order, what each
/// failure is called, and the races between them. The result goes to
/// `ServerConnection.setPairing` and to the `.pairing` error row.
///
/// The `.pairing` row names the last Keychain failure — a load, save, or
/// delete — and is cleared by the next one that succeeds.
///
/// A code is spent once getbb.app has answered, and every redeemed pairing
/// holds one of the account's machine slots, so no pairing is dropped without
/// a best-effort revoke: not one that could not be stored, and not one that a
/// new pairing replaces.
@MainActor
public final class PairingController {
    private let pairingStore: any PairingStore
    private let http: any HTTPClient
    private let executor: any PairingStoreExecutor
    private let threadStore: ThreadStore
    private let connection: ServerConnection

    /// The pairing in use, as last loaded or stored. The credential in it is
    /// a password; only the handle reaches any view, through the store.
    public private(set) var pairing: Pairing?

    /// Bumped whenever the user decides the pairing — a pair that was stored,
    /// a Forget — so a launch-time load that answers afterwards cannot undo
    /// it.
    private var generation = 0
    /// Saves queued and not yet answered. While there is one, the Keychain
    /// item is (or is about to be) a newer pairing than the one in memory,
    /// and a Forget, which is about the one in memory, leaves it alone.
    private var savesInFlight = 0
    /// Set while a Forget runs; a second one meanwhile does nothing.
    private var forgetting = false
    /// Pairs and Forgets under way, and who is waiting for none to be.
    private var operations = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: any PairingStore,
        http: any HTTPClient,
        executor: any PairingStoreExecutor,
        threadStore: ThreadStore,
        connection: ServerConnection
    ) {
        self.pairingStore = store
        self.http = http
        self.executor = executor
        self.threadStore = threadStore
        self.connection = connection
    }

    /// A pair or Forget is under way. Quitting now could lose a stored
    /// pairing or leave a machine slot held.
    public var isBusy: Bool { operations > 0 }

    /// Returns once no pair or Forget is under way. Each is bounded by the
    /// HTTP client's timeouts and the Keychain.
    public func waitUntilIdle() async {
        guard isBusy else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Reads the stored pairing, at launch, and starts using it. Returns it,
    /// so a pairing window opened before it was known can say so; nil when
    /// there is none, the read failed (named in the `.pairing` row), or the
    /// user paired or forgot before it answered, which wins.
    @discardableResult
    public func load() async -> Pairing? {
        let asked = generation
        let pairingStore = self.pairingStore
        let result = await executor.run { try pairingStore.load() }
        guard asked == generation else { return nil }
        switch result {
        case .success(let loaded):
            threadStore.setError(.pairing, nil)
            use(loaded)
            return loaded
        case .failure(let error):
            threadStore.setError(.pairing, errorText(error))
            return nil
        }
    }

    public static let codeSpent = "The code has been used; make a new one to try again."

    public static func pairedWhileLocal(handle: String) -> String {
        "Paired with \(handle). bb Icon will watch it whenever this Mac's own bb is not running."
    }

    /// Parses what was typed, redeems it at getbb.app, stores the answer, and
    /// starts using it.
    ///
    /// A pairing that cannot be stored is revoked rather than kept only in
    /// memory, where it would be lost at the next launch. If a Forget ran
    /// while that save was in flight, it left the item alone for this pair's
    /// sake; with the save failed, the item may still hold the forgotten
    /// pairing, so it is deleted here. A pairing this one replaces is revoked
    /// once replaced. When this Mac's own bb is the server
    /// in use, the new pairing is kept but unused, and the notice says so:
    /// nothing else in the tray would change.
    public func pair(input: String) async -> PairOutcome {
        operations += 1
        defer { operationEnded() }

        let redeemed: Pairing
        do {
            redeemed = try await ConnectPairing.redeem(code: ConnectPairing.parseInput(input), http: http)
        } catch {
            return .failed(errorText(error))
        }

        let pairingStore = self.pairingStore
        let generationBeforeSave = generation
        savesInFlight += 1
        let saved = await executor.run { try pairingStore.save(redeemed) }
        savesInFlight -= 1
        if case .failure(let error) = saved {
            let message = errorText(error)
            threadStore.setError(.pairing, message)
            // Only a Forget moves the generation while a pair is saving.
            if generation != generationBeforeSave {
                await deleteForgotten()
            }
            let revokeFailure = await ConnectRevoke.revoke(pairing: redeemed, http: http)
            return .failed(([message, Self.codeSpent] + (revokeFailure.map { [$0] } ?? [])).joined(separator: " "))
        }

        generation += 1
        threadStore.setError(.pairing, nil)
        let replaced = pairing
        use(redeemed)

        var notices: [String] = []
        // Another server in use after `use` can only be this Mac's own bb,
        // which wins over the pairing.
        if let inUse = connection.serverURL, inUse != redeemed.serverURL {
            notices.append(Self.pairedWhileLocal(handle: redeemed.handle))
        }
        if let replaced, replaced != redeemed,
           let revokeFailure = await ConnectRevoke.revoke(pairing: replaced, http: http) {
            notices.append(revokeFailure)
        }
        return .paired(notice: notices.isEmpty ? nil : notices.joined(separator: "\n\n"))
    }

    public static let stillStored = "bb Icon has stopped using it, but will read it again at its next launch."

    /// Stops using the pairing at once — the menu is back to "Connect to a
    /// remote bb…" and the socket closed before anything slow happens — then
    /// deletes the Keychain item, then revokes the pairing best effort with
    /// the copy still in memory. The item is deleted whatever the revoke will
    /// answer. Nil when there was nothing to forget, or a Forget is already
    /// under way.
    ///
    /// A pair whose save is still in flight has replaced the item with a
    /// newer pairing, which this Forget is not about: the item is left alone,
    /// and that pair starts using it when its save answers — or, if the save
    /// fails, deletes the item itself (see `pair`).
    public func forget() async -> ForgetReport? {
        guard !forgetting, let forgotten = pairing else { return nil }
        forgetting = true
        operations += 1
        defer {
            forgetting = false
            operationEnded()
        }
        generation += 1
        use(nil)

        var deleteFailure: String?
        if savesInFlight == 0 {
            deleteFailure = await deleteForgotten()
        }
        let revokeFailure = await ConnectRevoke.revoke(pairing: forgotten, http: http)

        return ForgetReport(
            handle: forgotten.handle,
            problems: [revokeFailure, deleteFailure].compactMap { $0 },
            revokeFailed: revokeFailure != nil
        )
    }

    /// Deletes the Keychain item for a pairing that was forgotten, and
    /// returns the failure, which is also the `.pairing` row.
    @discardableResult
    private func deleteForgotten() async -> String? {
        let pairingStore = self.pairingStore
        switch await executor.run({ try pairingStore.delete() }) {
        case .success:
            threadStore.setError(.pairing, nil)
            return nil
        case .failure(let error):
            let message = errorText(error) + " " + Self.stillStored
            threadStore.setError(.pairing, message)
            return message
        }
    }

    private func use(_ pairing: Pairing?) {
        self.pairing = pairing
        connection.setPairing(pairing)
    }

    private func operationEnded() {
        operations -= 1
        guard operations == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

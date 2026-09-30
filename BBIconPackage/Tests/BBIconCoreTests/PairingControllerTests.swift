import Clocks
import Foundation
import Testing
@testable import BBIconCore

/// Loading, pairing, and forgetting, against a fake Keychain, a fake
/// getbb.app, and an executor the test answers by hand. Redeem and revoke
/// answers are shaped from bb 0.44.0's sources (see `ConnectPairingTests`).
@MainActor
struct PairingControllerTests {
    static let redeemPath = "/api/connect/redeem-machine"
    static let revokePath = "/api/connect/revoke-machine"

    static func pairing(_ handle: String) throws -> Pairing {
        try Pairing(
            serverURL: try #require(URL(string: "https://\(handle).getbb.app")),
            handle: handle,
            machineId: "m-\(handle)",
            credential: "cred-test-\(handle)"
        )
    }

    /// Hands requests to a `FakeHTTPClient`, except that a request for a held
    /// path waits for its gate first. Records each path as it is asked,
    /// before any wait, so a test can see a request that has not answered.
    final class GatedHTTPClient: HTTPClient, @unchecked Sendable {
        private let inner: FakeHTTPClient
        private let lock = NSLock()
        private var gates: [String: AsyncGate] = [:]
        private var askedPaths: [String] = []

        init(_ inner: FakeHTTPClient) {
            self.inner = inner
        }

        var asked: [String] { lock.withLock { askedPaths } }

        func hold(_ path: String) -> AsyncGate {
            let gate = AsyncGate()
            lock.withLock { gates[path] = gate }
            return gate
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let gate = lock.withLock { () -> AsyncGate? in
                askedPaths.append(path)
                return gates.removeValue(forKey: path)
            }
            if let gate { await gate.wait() }
            return try await inner.send(request)
        }
    }

    @MainActor
    struct Harness {
        let threadStore = ThreadStore()
        let http = FakeHTTPClient()
        let gated: GatedHTTPClient
        let factory = FakeTransportFactory()
        let keychain: FakePairingStore
        let executor = ManualPairingStoreExecutor()
        let connection: ServerConnection
        let controller: PairingController

        /// getbb.app redeems any code as `studio` and revokes anything.
        init(stored: Pairing? = nil) async {
            keychain = FakePairingStore(stored)
            gated = GatedHTTPClient(http)
            connection = ServerConnection(store: threadStore, http: http, makeTransport: factory.make, clock: TestClock())
            controller = PairingController(
                store: keychain, http: gated, executor: executor, threadStore: threadStore, connection: connection
            )
            await http.respond(
                PairingControllerTests.redeemPath,
                body: #"{"credential":"cred-test-studio","machineId":"m-studio","serverUrl":"https://studio.getbb.app"}"#
            )
            await revokeAnswers(status: 200, body: #"{"ok":true}"#)
        }

        func revokeAnswers(status: Int, body: String = "") async {
            await http.respond(PairingControllerTests.revokePath, status: status, body: body)
        }

        /// The machine id of every revoke sent, in order.
        func revoked() async -> [String] {
            await http.requests
                .filter { $0.url?.path == PairingControllerTests.revokePath }
                .compactMap { request in
                    request.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["machineId"]
                }
        }

        /// The handle the menu offers to forget; nil means it offers Connect.
        var paired: String? { threadStore.state.paired }
        var errors: [String] { threadStore.state.errors }
    }

    @MainActor
    final class Flag {
        var raised = false
    }

    // MARK: - Load

    @Test("a stored pairing is loaded and used")
    func loadUsesStoredPairing() async throws {
        let mini = try Self.pairing("mini")
        let h = await Harness(stored: mini)
        #expect(await h.controller.load() == mini)
        #expect(h.controller.pairing == mini)
        #expect(h.paired == "mini")
        #expect(h.errors.isEmpty)
    }

    @Test("a load that fails is the pairing row, and the menu offers Connect")
    func loadFailureIsNamed() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        h.keychain.failLoad("the Keychain said no")
        #expect(await h.controller.load() == nil)
        #expect(h.errors == ["the Keychain said no"])
        #expect(h.paired == nil)
    }

    // MARK: - Pair

    @Test("a redeemed code is stored and used")
    func pairStoresAndUses() async throws {
        let studio = try Self.pairing("studio")
        let h = await Harness()
        #expect(await h.controller.pair(input: "code-test") == .paired(notice: nil))
        #expect(h.keychain.pairing == studio)
        #expect(h.paired == "studio")
        #expect(h.connection.serverURL == nil, "no runtime answer yet, so no server")
        #expect(await h.revoked().isEmpty)
    }

    @Test("pairing while this Mac's own bb is in use says the pairing waits")
    func pairedWhileLocalSaysSo() async throws {
        let h = await Harness()
        let local = try #require(URL(string: "http://127.0.0.1:38886"))
        h.connection.apply(.running(RuntimeInfo(pid: 1, serverURL: local, version: "0.44.0")))
        #expect(await h.controller.pair(input: "code-test") == .paired(notice: PairingController.pairedWhileLocal(handle: "studio")))
        #expect(h.connection.serverURL == local)
        #expect(h.paired == "studio")
    }

    @Test("a pairing that cannot be stored is revoked, named, and not used")
    func saveFailureRevokes() async throws {
        let h = await Harness()
        h.keychain.failSave("the Keychain is full")
        let outcome = await h.controller.pair(input: "code-test")
        #expect(outcome == .failed("the Keychain is full " + PairingController.codeSpent))
        #expect(await h.revoked() == ["m-studio"])
        #expect(h.errors == ["the Keychain is full"])
        #expect(h.paired == nil)
        #expect(h.controller.pairing == nil)
    }

    @Test("a refused code stores nothing")
    func refusedCodeStoresNothing() async throws {
        let h = await Harness()
        await h.http.respond(Self.redeemPath, status: 410, body: #"{"error":"expired"}"#)
        #expect(await h.controller.pair(input: "code-test") == .failed(ConnectPairingError.expired.message))
        #expect(h.keychain.saves == 0)
        #expect(h.paired == nil)
    }

    @Test("a pairing replaced by a new one is revoked, and a failed revoke is a notice")
    func replacingRevokesOld() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        #expect(await h.controller.pair(input: "code-test") == .paired(notice: nil))
        #expect(await h.revoked() == ["m-mini"])
        #expect(h.paired == "studio")

        let again = await Harness(stored: try Self.pairing("mini"))
        await again.controller.load()
        await again.revokeAnswers(status: 503)
        guard case .paired(let notice?) = await again.controller.pair(input: "code-test") else {
            Issue.record("expected a notice naming the failed revoke")
            return
        }
        #expect(notice.contains("Could not revoke bb Icon's pairing with mini"))
        #expect(again.paired == "studio")
    }

    // MARK: - Forget

    @Test("Forget stops using the pairing before it touches the Keychain or getbb.app")
    func forgetStopsFirst() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        h.executor.hold()
        let forgetting = Task { await h.controller.forget() }
        await eventually { h.executor.pending == 1 }
        #expect(h.paired == nil, "the menu offers Connect at once")
        #expect(h.controller.pairing == nil)
        #expect(await h.revoked().isEmpty, "the revoke waits for the delete")
        h.executor.release()
        let report = await forgetting.value
        #expect(report == ForgetReport(handle: "mini", problems: [], revokeFailed: false))
        #expect(h.keychain.pairing == nil)
        #expect(await h.revoked() == ["m-mini"])
    }

    @Test("Forget deletes the item even when the revoke fails, and names the revoke")
    func forgetDeletesWhenRevokeFails() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        await h.revokeAnswers(status: 500)
        let report = try #require(await h.controller.forget())
        #expect(report.revokeFailed)
        #expect(report.problems.count == 1)
        #expect(report.problems.first?.contains("getbb.app/dashboard") == true)
        #expect(h.keychain.deletes == 1)
        #expect(h.keychain.pairing == nil)
        #expect(h.paired == nil)
        #expect(h.errors.isEmpty)
    }

    @Test("a delete that fails is named in the report and the pairing row, until a Keychain call succeeds")
    func forgetNamesDeleteFailure() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        h.keychain.failDelete("the Keychain is locked")
        let report = try #require(await h.controller.forget())
        let expected = "the Keychain is locked " + PairingController.stillStored
        #expect(report == ForgetReport(handle: "mini", problems: [expected], revokeFailed: false))
        #expect(h.errors == [expected])
        #expect(h.paired == nil)

        #expect(await h.controller.pair(input: "code-test") == .paired(notice: nil))
        #expect(h.errors.isEmpty)
    }

    @Test("Forget during a pair's save leaves the new pairing stored, and the pair uses it")
    func forgetDuringSaveKeepsNewItem() async throws {
        let studio = try Self.pairing("studio")
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        h.executor.hold()
        let pairing = Task { await h.controller.pair(input: "code-test") }
        await eventually { h.executor.pending == 1 }
        try #require(h.executor.pending == 1, "the save is held")

        let done = Flag()
        let forgetting = Task {
            let report = await h.controller.forget()
            done.raised = true
            return report
        }
        await eventually { done.raised || h.executor.pending == 2 }
        while h.executor.release() {}
        #expect(await forgetting.value?.handle == "mini")
        #expect(await pairing.value == .paired(notice: nil))
        #expect(h.keychain.deletes == 0)
        #expect(h.keychain.pairing == studio)
        #expect(h.paired == "studio")
        #expect(await h.revoked() == ["m-mini"], "the forgotten pairing is revoked once")
    }

    @Test("a launch-time load that answers after a pair is dropped")
    func staleLoadAfterPair() async throws {
        let mini = try Self.pairing("mini")
        let studio = try Self.pairing("studio")
        let h = await Harness(stored: mini)
        h.executor.hold()
        let loading = Task { await h.controller.load() }
        await eventually { h.executor.pending == 1 }
        let pairing = Task { await h.controller.pair(input: "code-test") }
        await eventually { h.executor.pending == 2 }
        h.executor.release(1)
        #expect(await pairing.value == .paired(notice: nil))
        // The load read the item before the save replaced it.
        try h.keychain.save(mini)
        h.executor.release()
        #expect(await loading.value == nil)
        #expect(h.controller.pairing == studio)
        #expect(h.paired == "studio")
    }

    @Test("a load that answers after a Forget is dropped")
    func staleLoadAfterForget() async throws {
        let mini = try Self.pairing("mini")
        let h = await Harness(stored: mini)
        await h.controller.load()
        // A second load, held, so that only the Forget can make it stale.
        h.executor.hold()
        let loading = Task { await h.controller.load() }
        await eventually { h.executor.pending == 1 }
        let forgetting = Task { await h.controller.forget() }
        await eventually { h.executor.pending == 2 }
        h.executor.release(1)
        #expect(await forgetting.value?.handle == "mini")
        // The load read the item before the delete removed it.
        try h.keychain.save(mini)
        h.executor.release()
        #expect(await loading.value == nil)
        #expect(h.controller.pairing == nil)
        #expect(h.paired == nil)
    }

    @Test(
        "a pair's save that fails after a Forget ran deletes the forgotten item, and names a failed delete",
        arguments: [false, true]
    )
    func failedSaveAfterForgetDeletes(deleteFails: Bool) async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        h.keychain.failSave("the Keychain is full")
        if deleteFails { h.keychain.failDelete("the Keychain is locked") }
        h.executor.hold()
        let pairing = Task { await h.controller.pair(input: "code-test") }
        await eventually { h.executor.pending == 1 }
        #expect(await h.controller.forget()?.handle == "mini", "the save is in flight, so Forget leaves the item")
        #expect(h.keychain.deletes == 0)
        h.executor.release()
        await eventually { h.executor.pending == 1 }
        h.executor.release()
        #expect(await pairing.value == .failed("the Keychain is full " + PairingController.codeSpent))
        #expect(h.keychain.deletes == 1)
        #expect(h.paired == nil)
        #expect(await h.revoked() == ["m-mini", "m-studio"])
        if deleteFails {
            #expect(h.keychain.pairing != nil)
            #expect(h.errors == ["the Keychain is locked " + PairingController.stillStored])
        } else {
            #expect(h.keychain.pairing == nil)
            #expect(h.errors.isEmpty)
        }
    }

    @Test("busy while a Forget runs, until its revoke has answered")
    func forgetBusyUntilRevokeAnswers() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        h.executor.hold()
        let revoke = h.gated.hold(Self.revokePath)
        let forgetting = Task { await h.controller.forget() }
        await eventually { h.executor.pending == 1 }
        #expect(h.controller.isBusy)
        let idle = Flag()
        let waiting = Task {
            await h.controller.waitUntilIdle()
            idle.raised = true
        }
        h.executor.release()
        await eventually { h.gated.asked.contains(Self.revokePath) }
        await settle()
        #expect(h.controller.isBusy, "the delete is done, the revoke is not")
        #expect(!idle.raised)
        revoke.open()
        #expect(await forgetting.value?.problems == [])
        await waiting.value
        #expect(idle.raised)
        #expect(!h.controller.isBusy)
    }

    @Test("busy while a pair runs, and idle waiters are let go when it ends")
    func busyUntilDone() async throws {
        let h = await Harness()
        #expect(!h.controller.isBusy)
        h.executor.hold()
        let pairing = Task { await h.controller.pair(input: "code-test") }
        await eventually { h.executor.pending == 1 }
        #expect(h.controller.isBusy)
        let idle = Flag()
        let waiting = Task {
            await h.controller.waitUntilIdle()
            idle.raised = true
        }
        await settle()
        #expect(!idle.raised)
        h.executor.release()
        _ = await pairing.value
        await waiting.value
        #expect(idle.raised)
        #expect(!h.controller.isBusy)
    }
}

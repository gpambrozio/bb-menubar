import Clocks
import Foundation
import Testing
@testable import BBIconCore

/// Loading, pairing, and forgetting, against a fake Keychain, a fake
/// getbb.app, and an executor the test answers by hand. Redeem answers are
/// shaped from bb 0.44.0's sources (see `ConnectPairingTests`). Nothing here
/// ever asks getbb.app to revoke a device: the live relay refuses a device's
/// own revoke (401), so no request but the redeem is ever sent.
@MainActor
struct PairingControllerTests {
    static let redeemPath = "/api/connect/redeem-machine"

    static func pairing(_ handle: String) throws -> Pairing {
        try Pairing(
            serverURL: try #require(URL(string: "https://\(handle).getbb.app")),
            handle: handle,
            machineId: "m-\(handle)",
            credential: "cred-test-\(handle)"
        )
    }

    @MainActor
    struct Harness {
        let threadStore = ThreadStore()
        let http = FakeHTTPClient()
        let factory = FakeTransportFactory()
        let keychain: FakePairingStore
        let executor = ManualPairingStoreExecutor()
        let connection: ServerConnection
        let controller: PairingController

        /// getbb.app redeems any code as `studio`.
        init(stored: Pairing? = nil) async {
            keychain = FakePairingStore(stored)
            connection = ServerConnection(store: threadStore, http: http, makeTransport: factory.make, clock: TestClock())
            controller = PairingController(
                store: keychain, http: http, executor: executor, threadStore: threadStore, connection: connection
            )
            await http.respond(
                PairingControllerTests.redeemPath,
                body: #"{"credential":"cred-test-studio","machineId":"m-studio","serverUrl":"https://studio.getbb.app"}"#
            )
        }

        /// The path of every request sent to getbb.app, in order.
        func sent() async -> [String] {
            await http.requests.compactMap { $0.url?.path }
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
        #expect(await h.sent() == [Self.redeemPath])
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

    @Test("a pairing that cannot be stored is named, not used, and pointed to the dashboard")
    func saveFailureNamesUnusedDevice() async throws {
        let h = await Harness()
        h.keychain.failSave("the Keychain is full")
        let outcome = await h.controller.pair(input: "code-test")
        #expect(outcome == .failed(
            "the Keychain is full " + PairingController.codeSpent + " " + PairingController.unusedDevice
        ))
        #expect(PairingController.unusedDevice.contains("getbb.app/dashboard"))
        #expect(await h.sent() == [Self.redeemPath], "no revoke is attempted")
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

    @Test("a pairing replaced by a new one is named for removal at the dashboard, and nothing is revoked")
    func replacingNamesOldDevice() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        #expect(await h.controller.pair(input: "code-test") == .paired(notice: PairingController.replacedStillListed(handle: "mini")))
        #expect(PairingController.replacedStillListed(handle: "mini").contains("getbb.app/dashboard"))
        #expect(await h.sent() == [Self.redeemPath])
        #expect(h.paired == "studio")

        // Replaced while this Mac's own bb is in use: both notices.
        let local = await Harness(stored: try Self.pairing("mini"))
        await local.controller.load()
        let url = try #require(URL(string: "http://127.0.0.1:38886"))
        local.connection.apply(.running(RuntimeInfo(pid: 1, serverURL: url, version: "0.44.0")))
        #expect(await local.controller.pair(input: "code-test") == .paired(notice: [
            PairingController.pairedWhileLocal(handle: "studio"),
            PairingController.replacedStillListed(handle: "mini"),
        ].joined(separator: "\n\n")))
    }

    // MARK: - Forget

    @Test("Forget stops using the pairing before it touches the Keychain, and sends nothing to getbb.app")
    func forgetStopsFirst() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        h.executor.hold()
        let forgetting = Task { await h.controller.forget() }
        await eventually { h.executor.pending == 1 }
        #expect(h.paired == nil, "the menu offers Connect at once")
        #expect(h.controller.pairing == nil)
        h.executor.release()
        let report = await forgetting.value
        #expect(report == ForgetReport(handle: "mini", problems: []))
        #expect(h.keychain.deletes == 1)
        #expect(h.keychain.pairing == nil)
        #expect(h.errors.isEmpty)
        #expect(await h.sent().isEmpty, "no revoke: getbb.app refuses a device's own")
    }

    @Test("a Forget's report always says the device is still listed at the dashboard")
    func forgetReportPointsToDashboard() {
        let clean = ForgetReport(handle: "mini", problems: [])
        #expect(clean.detail == PairingController.stillListed(handle: "mini"))
        #expect(clean.detail.contains("getbb.app/dashboard"))
        let failed = ForgetReport(handle: "mini", problems: ["the Keychain is locked"])
        #expect(failed.detail == "the Keychain is locked\n\n" + PairingController.stillListed(handle: "mini"))
        #expect(PairingController.forgetQuestion(handle: "mini").contains("getbb.app/dashboard"))
        #expect(PairingController.dashboard == "https://getbb.app/dashboard")
    }

    @Test("a delete that fails is named in the report and the pairing row, until a Keychain call succeeds")
    func forgetNamesDeleteFailure() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        h.keychain.failDelete("the Keychain is locked")
        let report = try #require(await h.controller.forget())
        let expected = "the Keychain is locked " + PairingController.stillStored
        #expect(report == ForgetReport(handle: "mini", problems: [expected]))
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
        #expect(await h.sent() == [Self.redeemPath])
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
        "a pair's save that fails after a Forget ran deletes the forgotten item, and names a failed delete in the row and the outcome",
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
        let saveFailure = "the Keychain is full " + PairingController.codeSpent + " " + PairingController.unusedDevice
        let cleanupFailure = "the Keychain is locked " + PairingController.stillStored
        // A failed delete is in the outcome as well as the row: a pair that
        // ends while quitting shows only the outcome.
        #expect(await pairing.value == .failed(deleteFails ? saveFailure + "\n\n" + cleanupFailure : saveFailure))
        #expect(h.keychain.deletes == 1)
        #expect(h.paired == nil)
        #expect(await h.sent() == [Self.redeemPath])
        if deleteFails {
            #expect(h.keychain.pairing != nil)
            #expect(h.errors == [cleanupFailure])
        } else {
            #expect(h.keychain.pairing == nil)
            #expect(h.errors.isEmpty)
        }
    }

    @Test("busy while a Forget runs, until its delete has answered")
    func forgetBusyUntilDeleteAnswers() async throws {
        let h = await Harness(stored: try Self.pairing("mini"))
        await h.controller.load()
        h.executor.hold()
        let forgetting = Task { await h.controller.forget() }
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

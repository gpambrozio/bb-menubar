import Testing
@testable import BBIconCore

@MainActor
struct ThreadStoreTests {
    private func snapshot(
        threads: [ThreadRow] = [thread()],
        projects: [ProjectRow] = [ProjectRow(id: "proj_a", name: "web-app")],
        truncated: Bool = false,
        decodeFailures: [String] = []
    ) -> BBSnapshot {
        BBSnapshot(threads: threads, projects: projects, truncated: truncated, decodeFailures: decodeFailures)
    }

    /// A store with a snapshot applied and the connection up.
    private func connected(_ snapshot: BBSnapshot) -> ThreadStore {
        let store = ThreadStore()
        store.setStatus(.connected)
        store.apply(snapshot)
        return store
    }

    @Test("starts not running and empty")
    func initialState() {
        #expect(ThreadStore().state == .initial)
        #expect(BBState.initial.status == .notRunning)
        #expect(BBState.initial.threads.isEmpty)
        #expect(BBState.initial.errors.isEmpty)
    }

    @Test("applies a snapshot's threads, project names, and truncation")
    func appliesSnapshot() {
        let store = connected(snapshot(truncated: true))
        #expect(store.state.threads.map(\.id) == ["thr_a"])
        #expect(store.state.projectNames == ["proj_a": "web-app"])
        #expect(store.state.truncated)
    }

    @Test("accepts a snapshot before the connection reports connected, because the session delivers it first")
    func appliesWhileConnecting() {
        let store = ThreadStore()
        store.setStatus(.connecting)
        store.apply(snapshot())
        store.setStatus(.connected)
        #expect(store.state.threads.map(\.id) == ["thr_a"])
    }

    @Test(
        "drops the rows of the last connection whenever it is not connected",
        arguments: [ConnectionStatus.notRunning, .connecting, .reconnecting]
    )
    func leavingConnectedClearsRows(_ status: ConnectionStatus) {
        let store = connected(snapshot(truncated: true))
        store.setStatus(status)
        #expect(store.state.status == status)
        #expect(store.state.threads.isEmpty)
        #expect(store.state.projectNames.isEmpty)
        #expect(!store.state.truncated)
    }

    @Test("drops the decode error with the rows it describes, and keeps every other error")
    func leavingConnectedClearsDecodeError() {
        let store = connected(snapshot(decodeFailures: ["item 3 (thr_x): missing createdAt"]))
        store.setError(.runtime, "runtime")
        store.setError(.fetch, "fetch")
        store.setError(.open, "open")
        #expect(store.state.errors.count == 4)

        store.setStatus(.reconnecting)
        // The decode error names a row of a snapshot that is gone. The rest
        // are not about the snapshot, and their owners clear them.
        #expect(store.state.errors == ["runtime", "fetch", "open"])
    }

    @Test("notifies listeners only when the state actually changes")
    func listenersFireOnlyOnChange() {
        let store = ThreadStore()
        var notifications = 0
        _ = store.subscribe { notifications += 1 }

        store.setStatus(.connecting)
        store.setStatus(.connecting)
        #expect(notifications == 1)

        store.setError(.fetch, "boom")
        store.setError(.fetch, "boom")
        #expect(notifications == 2)

        store.setError(.open, nil)
        #expect(notifications == 2)

        store.apply(snapshot())
        store.apply(snapshot())
        #expect(notifications == 3)
    }

    @Test("stops notifying a listener once it unsubscribes")
    func unsubscribe() {
        let store = ThreadStore()
        var notifications = 0
        let unsubscribe = store.subscribe { notifications += 1 }
        store.setStatus(.connecting)
        unsubscribe()
        store.setStatus(.connected)
        #expect(notifications == 1)
    }

    @Test("orders errors by source, whatever order they were set in")
    func errorsOrderedBySource() {
        let store = ThreadStore()
        store.setError(.open, "c")
        store.setError(.pairing, "b")
        store.setError(.runtime, "a")
        #expect(store.state.errors == ["a", "b", "c"])

        store.setError(.runtime, nil)
        #expect(store.state.errors == ["b", "c"])

        // Where bb is comes before whether it can be read: a pairing that
        // could not be loaded outranks a fetch that failed.
        store.setError(.fetch, "fetch")
        #expect(store.state.errors == ["b", "fetch", "c"])
    }

    @Test("turns a snapshot's decode failures into one error, and clears it with the next clean snapshot")
    func decodeFailuresBecomeOneError() {
        let store = connected(snapshot(decodeFailures: ["item 1 (thr_b): missing id", "item 4: bad status"]))
        #expect(store.state.errors == ["Some threads could not be read: item 1 (thr_b): missing id; item 4: bad status"])

        store.apply(snapshot())
        #expect(store.state.errors.isEmpty)
    }

    @Test("files the decode error in its own source order among the others")
    func decodeErrorOrder() {
        let store = connected(snapshot(decodeFailures: ["x"]))
        store.setError(.open, "open")
        store.setError(.runtime, "runtime")
        #expect(store.state.errors == ["runtime", "Some threads could not be read: x", "open"])
    }

    @Test("keeps the last name bb sent when two projects share an id")
    func duplicateProjectIds() {
        let store = connected(snapshot(projects: [ProjectRow(id: "p", name: "one"), ProjectRow(id: "p", name: "two")]))
        #expect(store.state.projectNames == ["p": "two"])
    }

    @Test("names the server and the pairing, notifies, and keeps both across status changes")
    func serverNameAndPairing() {
        let store = ThreadStore()
        var notified = 0
        let unsubscribe = store.subscribe { notified += 1 }
        defer { unsubscribe() }
        store.setServerName("mini")
        store.setPaired("mini")
        #expect(notified == 2)
        store.setStatus(.connecting)
        store.setStatus(.notRunning)
        #expect(store.state.serverName == "mini")
        #expect(store.state.paired == "mini")
        store.setServerName(nil)
        store.setPaired(nil)
        #expect(store.state == .initial)
        #expect(BBState.initial.serverName == nil)
        #expect(BBState.initial.paired == nil)
    }
}

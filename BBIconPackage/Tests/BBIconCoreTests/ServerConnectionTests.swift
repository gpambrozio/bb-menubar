import Clocks
import Foundation
import Testing
@testable import BBIconCore

@MainActor
struct ServerConnectionTests {
    /// Every bb server a test runs, told apart by port, or by host for a
    /// remote one (`mini.getbb.app`), which has none. Each answers its
    /// projects with one project and its threads with one thread named after
    /// the server (`thr_38886`, `thr_mini.getbb.app`), and its open request
    /// reaches one window unless told otherwise. A held server's (or one held
    /// request's) next request waits until the test opens the gate, and the
    /// gate is then gone: `AsyncGate` releases one waiter, so the requests
    /// after it go straight through. A refused server answers every `/api/v1`
    /// request 401. `/api/connect/servers` answers what `setHealth` says, and
    /// 404 until it says anything.
    ///
    /// A class under a lock rather than an actor, so `eventually` can read
    /// what was asked and answered without awaiting.
    final class ServersHTTPClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [String: AsyncGate] = [:]
        private var delivered: [String: Int] = [:]
        private var refused: Set<String> = []
        private var health: [String: (status: Int, body: String)] = [:]
        private var askedKeys: [String] = []
        private var answeredKeys: [String] = []
        private var askedHeaders: [(key: String, headers: [String: String])] = []

        /// `<server> <path>` of every request, in the order they were sent.
        var asked: [String] { lock.withLock { askedKeys } }
        /// The same, in the order they were answered.
        var answered: [String] { lock.withLock { answeredKeys } }
        /// Every request's key and its headers, in the order they were sent.
        var headers: [(key: String, headers: [String: String])] { lock.withLock { askedHeaders } }
        /// How many relay probes were sent.
        var probes: Int { asked.filter { $0.hasSuffix(" /api/connect/servers") }.count }

        static func server(_ url: URL) -> String {
            url.port.map(String.init) ?? url.host ?? ""
        }

        /// Holds `server`'s next request, or, with `path`, only the next
        /// request for that path.
        func hold(_ server: String, path: String? = nil) -> AsyncGate {
            let gate = AsyncGate()
            lock.withLock { gates[path.map { "\(server) \($0)" } ?? server] = gate }
            return gate
        }

        func hold(_ port: Int) -> AsyncGate { hold(String(port)) }

        func setDelivered(_ count: Int, port: Int) {
            lock.withLock { delivered[String(port)] = count }
        }

        func refuse(_ server: String) {
            lock.withLock { _ = refused.insert(server) }
        }

        func refuse(_ port: Int) { refuse(String(port)) }

        func unrefuse(_ server: String) {
            lock.withLock { _ = refused.remove(server) }
        }

        func setHealth(_ server: String, status: Int, body: String) {
            lock.withLock { health[server] = (status, body) }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url else { throw URLError(.badURL) }
            let server = Self.server(url)
            let path = url.path(percentEncoded: true)
            let key = "\(server) \(path)"
            let held = lock.withLock { () -> (key: String, gate: AsyncGate)? in
                askedKeys.append(key)
                askedHeaders.append((key, request.allHTTPHeaderFields ?? [:]))
                if let gate = gates[key] { return (key, gate) }
                return gates[server].map { (server, $0) }
            }
            if let (gateKey, gate) = held {
                await gate.wait()
                lock.withLock { if gates[gateKey] === gate { gates[gateKey] = nil } }
            }
            let (status, body) = lock.withLock { () -> (Int, String) in
                answeredKeys.append(key)
                if path == "/api/connect/servers" { return health[server] ?? (404, "") }
                if refused.contains(server) { return (401, "") }
                switch path {
                case "/api/v1/projects":
                    return (200, #"[{"id":"proj_a","name":"web-app"}]"#)
                case "/api/v1/threads":
                    return (200, #"[{"id":"thr_\#(server)","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1}]"#)
                case let open where open.hasSuffix("/open"):
                    return (200, #"{"delivered":\#(delivered[server] ?? 1)}"#)
                default:
                    return (404, "")
                }
            }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
    }

    static let portA = 38886
    static let portB = 40123
    static let remote = "mini.getbb.app"
    static let handle = "mini"
    static let credential = "cred-test"
    static let credentialHeader = "x-bb-connect-machine"

    @MainActor
    struct Harness {
        let store = ThreadStore()
        let http = ServersHTTPClient()
        let factory = FakeTransportFactory()
        let clock = TestClock()
        let connection: ServerConnection

        init() {
            connection = ServerConnection(store: store, http: http, makeTransport: factory.make, clock: clock)
        }

        func running(_ port: Int) throws -> RuntimeResolution {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)"))
            return .running(RuntimeInfo(pid: 1, serverURL: url, version: "0.44.0"))
        }

        func transport(_ index: Int) throws -> FakeTransport {
            try #require(factory.transports.indices.contains(index) ? factory.transports[index] : nil)
        }

        var threadIds: [String] { store.state.threads.map(\.id) }

        func pairing(credential: String = ServerConnectionTests.credential) throws -> Pairing {
            try Pairing(
                serverURL: try #require(URL(string: "https://\(ServerConnectionTests.remote)")),
                handle: ServerConnectionTests.handle,
                machineId: "machine-test",
                credential: credential
            )
        }

        /// Pairs, finds no local bb, opens the socket the pairing's server is
        /// dialled on, and waits for its rows.
        func connectRemote() async throws -> FakeTransport {
            connection.setPairing(try pairing())
            connection.apply(.notRunning(error: nil))
            let transport = try #require(factory.last)
            transport.simulateOpen()
            await eventually { store.state.status == .connected }
            try #require(store.state.status == .connected)
            try #require(threadIds == ["thr_\(ServerConnectionTests.remote)"])
            return transport
        }

        /// Every state the store publishes from now on.
        func recordStates() -> () -> [BBState] {
            let states = StateLog()
            _ = store.subscribe { [store] in states.append(store.state) }
            return { states.states }
        }

        /// Points the connection at `port`, opens the socket it dials, and
        /// waits for that server's rows.
        func connect(_ port: Int) async throws -> FakeTransport {
            connection.apply(try running(port))
            let transport = try #require(factory.last)
            transport.simulateOpen()
            await eventually { store.state.status == .connected }
            try #require(store.state.status == .connected)
            try #require(threadIds == ["thr_\(port)"])
            return transport
        }
    }

    @MainActor
    final class StateLog {
        private(set) var states: [BBState] = []
        func append(_ state: BBState) { states.append(state) }
    }

    /// The server a state's rows came from, told by the thread `thr_<server>`
    /// each one serves, against the one the state names. A mismatch is one
    /// server's rows shown under another's name.
    static func rowsMatchName(_ state: BBState) -> Bool {
        let named = state.serverName.map { _ in remote }
        return state.threads.allSatisfy { thread in
            let server = String(thread.id.dropFirst("thr_".count))
            return named == nil ? server != remote : server == named
        }
    }

    // MARK: - Server changes

    @Test("a new server stops the old session and dials the new one")
    func newServerReplacesSession() async throws {
        let h = Harness()
        let old = try await h.connect(Self.portA)

        h.connection.apply(try h.running(Self.portB))
        #expect(old.closedWith?.code == 1000)
        #expect(h.factory.transports.count == 2)
        let new = try h.transport(1)
        #expect(new.request.url.absoluteString == "ws://127.0.0.1:\(Self.portB)/ws")
        #expect(h.connection.serverURL?.port == Self.portB)
        #expect(h.store.state.status == .connecting)
        #expect(h.threadIds.isEmpty, "the old server's rows are gone")

        new.simulateOpen()
        await eventually { h.store.state.status == .connected }
        #expect(h.threadIds == ["thr_\(Self.portB)"])
    }

    @Test("the old server's late callbacks and late fetch are ignored")
    func oldSessionIsSilenced() async throws {
        let h = Harness()
        let gate = h.http.hold(Self.portA)
        h.connection.apply(try h.running(Self.portA))
        let old = try h.transport(0)
        old.simulateOpen()
        await eventually { h.http.asked.contains("\(Self.portA) /api/v1/projects") }
        try #require(h.http.asked.contains("\(Self.portA) /api/v1/projects"), "a fetch to the old server is in flight")

        h.connection.apply(try h.running(Self.portB))
        let after = h.store.state
        #expect(after == BBState(status: .connecting, threads: [], projectNames: [:], truncated: false, errors: []))

        old.simulateOpen()
        old.simulateText(#"{"type":"changed","entity":"thread","id":"thr_a"}"#)
        old.simulateError("late")
        old.simulateClose()
        gate.open()
        await eventually { h.http.answered.contains("\(Self.portA) /api/v1/threads") }
        try #require(h.http.answered.contains("\(Self.portA) /api/v1/threads"), "the old fetch ran to the end")
        let leaked = await eventually(timeout: .milliseconds(300)) { h.store.state != after }
        #expect(!leaked, "nothing from the old server reached the store: \(h.store.state)")
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 2, "the old socket's close did not reconnect anything")
    }

    @Test("the same server twice does not reconnect")
    func sameServerKeepsSession() async throws {
        let h = Harness()
        let transport = try await h.connect(Self.portA)
        h.connection.apply(try h.running(Self.portA))
        #expect(h.factory.transports.count == 1)
        #expect(transport.closedWith == nil)
        #expect(h.store.state.status == .connected)
        #expect(h.threadIds == ["thr_\(Self.portA)"])
    }

    @Test("a server change clears the old server's fetch error")
    func serverChangeClearsFetchError() async throws {
        let h = Harness()
        h.http.refuse(Self.portA)
        h.connection.apply(try h.running(Self.portA))
        try h.transport(0).simulateOpen()
        await eventually { !h.store.state.errors.isEmpty }
        #expect(h.store.state.errors == [BBAPIError.authenticationRequired.message])

        h.connection.apply(try h.running(Self.portB))
        #expect(h.store.state.errors.isEmpty)
        #expect(h.store.state.status == .connecting)
    }

    // MARK: - bb's lifecycle

    @Test("bb not running stops the session, drops the rows, and names why")
    func notRunningStopsSession() async throws {
        let h = Harness()
        let transport = try await h.connect(Self.portA)
        h.connection.apply(.notRunning(error: "bb-app-runtime.json is missing serverUrl"))
        #expect(transport.closedWith?.code == 1000)
        #expect(h.connection.serverURL == nil)
        #expect(h.store.state.status == .notRunning)
        #expect(h.threadIds.isEmpty)
        #expect(h.store.state.errors == ["bb-app-runtime.json is missing serverUrl"])

        // The same server coming back is a new connection, not "unchanged".
        h.connection.apply(try h.running(Self.portA))
        #expect(h.factory.transports.count == 2)
    }

    @Test("bb running again clears the runtime error")
    func runningClearsRuntimeError() throws {
        let h = Harness()
        h.connection.apply(.notRunning(error: "unreadable"))
        #expect(h.store.state.status == .notRunning)
        #expect(h.store.state.errors == ["unreadable"])
        #expect(h.factory.transports.isEmpty)

        h.connection.apply(try h.running(Self.portA))
        #expect(h.store.state.errors.isEmpty)
        #expect(h.store.state.status == .connecting)
        // A re-check that finds bb where it was clears it too.
        h.store.setError(.runtime, "stale")
        h.connection.apply(try h.running(Self.portA))
        #expect(h.store.state.errors.isEmpty)
        #expect(h.factory.transports.count == 1)
    }

    // MARK: - Opening a thread

    @Test("an open request that reaches no window is named")
    func openFailureIsNamed() async throws {
        let h = Harness()
        _ = try await h.connect(Self.portA)
        h.http.setDelivered(0, port: Self.portA)
        await h.connection.openThread("thr_\(Self.portA)", prepare: { true }).value
        #expect(h.http.asked.contains("\(Self.portA) /api/v1/threads/thr_\(Self.portA)/open"))
        #expect(h.store.state.errors == [BBAPIError.noWindow.message])

        h.http.setDelivered(1, port: Self.portA)
        await h.connection.openThread("thr_\(Self.portA)", prepare: { true }).value
        #expect(h.store.state.errors.isEmpty, "the next open that lands clears it")
    }

    @Test("an open request answered after a server change does not write its error")
    func staleOpenAnswerIsDropped() async throws {
        let h = Harness()
        _ = try await h.connect(Self.portA)
        h.http.setDelivered(0, port: Self.portA)
        let gate = h.http.hold(Self.portA)
        let open = h.connection.openThread("thr_\(Self.portA)", prepare: { true })
        await eventually { h.http.asked.contains("\(Self.portA) /api/v1/threads/thr_\(Self.portA)/open") }

        h.connection.apply(try h.running(Self.portB))
        gate.open()
        await open.value
        #expect(h.http.answered.contains("\(Self.portA) /api/v1/threads/thr_\(Self.portA)/open"))
        #expect(h.store.state.errors.isEmpty)
    }

    @Test("a later open request supersedes an earlier one's answer")
    func laterOpenWins() async throws {
        let h = Harness()
        _ = try await h.connect(Self.portA)
        h.http.setDelivered(0, port: Self.portA)
        let gate = h.http.hold(Self.portA)
        let first = h.connection.openThread("thr_1", prepare: { true })
        await eventually { h.http.asked.contains("\(Self.portA) /api/v1/threads/thr_1/open") }
        let second = h.connection.openThread("thr_2", prepare: { false })
        gate.open()
        await first.value
        await second.value
        #expect(h.store.state.errors.isEmpty, "the first answer arrived after the second click")
    }

    @Test("an open whose preparation fails, or with no server, sends nothing")
    func openWithoutPreparationOrServerSendsNothing() async throws {
        let h = Harness()
        await h.connection.openThread("thr_x", prepare: { true }).value
        _ = try await h.connect(Self.portA)
        await h.connection.openThread("thr_y", prepare: { false }).value
        #expect(!h.http.asked.contains { $0.hasSuffix("/open") })
        #expect(h.store.state.errors.isEmpty)
    }

    @Test("stop stops the session and is idempotent")
    func stopIsIdempotent() async throws {
        let h = Harness()
        let transport = try await h.connect(Self.portA)
        h.connection.stop()
        h.connection.stop()
        #expect(transport.closedWith?.code == 1000)
        #expect(h.connection.serverURL == nil)
        #expect(h.factory.transports.count == 1)
    }

    // MARK: - Local, then the pairing

    @Test("a local bb wins over the pairing, which is kept but unused")
    func localWinsOverPairing() async throws {
        let h = Harness()
        h.connection.setPairing(try h.pairing())
        #expect(h.factory.transports.isEmpty, "no target until the runtime file has been read")
        #expect(h.http.asked.isEmpty)

        _ = try await h.connect(Self.portA)
        #expect(h.factory.transports.count == 1)
        #expect(try h.transport(0).request.url.absoluteString == "ws://127.0.0.1:\(Self.portA)/ws")
        #expect(h.store.state.serverName == nil)
        #expect(h.store.state.paired == Self.handle)
    }

    @Test("a local bb that starts takes over from the pairing")
    func localTakesOverFromPairing() async throws {
        let h = Harness()
        let log = h.recordStates()
        let remote = try await h.connectRemote()
        #expect(h.store.state.serverName == Self.handle)

        h.connection.apply(try h.running(Self.portA))
        #expect(remote.closedWith?.code == 1000)
        #expect(h.store.state.status == .connecting)
        #expect(h.store.state.serverName == nil)
        #expect(h.threadIds.isEmpty, "the remote bb's rows are gone")
        try h.transport(1).simulateOpen()
        await eventually { h.store.state.status == .connected }
        #expect(h.threadIds == ["thr_\(Self.portA)"])
        #expect(h.factory.transports.count == 2)
        let mismatched = log().filter { !Self.rowsMatchName($0) }.map { "\($0.serverName ?? "local"): \($0.threads.map(\.id))" }
        #expect(mismatched.isEmpty, "states that showed one server's rows under the other's name")
    }

    @Test("a local bb that stops hands over to the pairing, with none of its rows")
    func pairingTakesOverFromLocal() async throws {
        let h = Harness()
        let log = h.recordStates()
        let local = try await h.connect(Self.portA)
        h.connection.setPairing(try h.pairing())
        #expect(h.factory.transports.count == 1, "pairing while a local bb runs dials nothing")
        #expect(local.closedWith == nil)

        h.connection.apply(.notRunning(error: nil))
        #expect(local.closedWith?.code == 1000)
        let remote = try h.transport(1)
        #expect(remote.request.url.absoluteString == "wss://\(Self.remote)/ws")
        #expect(h.connection.serverURL?.host == Self.remote)
        #expect(h.store.state.status == .connecting)
        #expect(h.store.state.serverName == Self.handle)
        #expect(h.threadIds.isEmpty, "the local bb's rows are gone")

        remote.simulateOpen()
        await eventually { h.store.state.status == .connected }
        #expect(h.threadIds == ["thr_\(Self.remote)"])
        let mismatched = log().filter { !Self.rowsMatchName($0) }.map { "\($0.serverName ?? "local"): \($0.threads.map(\.id))" }
        #expect(mismatched.isEmpty, "states that showed one server's rows under the other's name")
    }

    @Test("forgetting the pairing while it is in use leaves nothing running")
    func pairingRemovedWhileRemote() async throws {
        let h = Harness()
        let remote = try await h.connectRemote()
        h.connection.setPairing(nil)
        #expect(remote.closedWith?.code == 1000)
        #expect(h.connection.serverURL == nil)
        #expect(h.store.state == BBState(status: .notRunning, threads: [], projectNames: [:], truncated: false, errors: []))
        #expect(h.factory.transports.count == 1)
    }

    @Test("the same pairing again keeps the session; a new credential reconnects")
    func samePairingKeepsSession() async throws {
        let h = Harness()
        let remote = try await h.connectRemote()
        h.connection.setPairing(try h.pairing())
        h.connection.apply(.notRunning(error: nil))
        #expect(h.factory.transports.count == 1)
        #expect(remote.closedWith == nil)

        h.connection.setPairing(try h.pairing(credential: "cred-other"))
        #expect(remote.closedWith?.code == 1000)
        #expect(try h.transport(1).request.headers == [Self.credentialHeader: "cred-other"])
    }

    @Test("only a remote bb's requests carry the credential, and none carries an Origin")
    func headersOnRemoteOnly() async throws {
        let h = Harness()
        _ = try await h.connect(Self.portA)
        await h.connection.openThread("thr_\(Self.portA)", prepare: { true }).value
        h.connection.apply(.notRunning(error: nil))
        h.connection.setPairing(try h.pairing())
        try h.transport(1).simulateOpen()
        await eventually { h.store.state.status == .connected }
        try #require(h.threadIds == ["thr_\(Self.remote)"])
        await h.connection.openThread("thr_\(Self.remote)", prepare: { true }).value

        #expect(try h.transport(0).request.headers.isEmpty)
        #expect(try h.transport(1).request.headers == [Self.credentialHeader: Self.credential])
        let local = h.http.headers.filter { $0.key.hasPrefix("\(Self.portA) ") }
        let remote = h.http.headers.filter { $0.key.hasPrefix("\(Self.remote) ") }
        #expect(local.map(\.key).contains("\(Self.portA) /api/v1/threads/thr_\(Self.portA)/open"))
        #expect(remote.map(\.key).contains("\(Self.remote) /api/v1/threads/thr_\(Self.remote)/open"))
        #expect(remote.map(\.key).contains("\(Self.remote) /api/v1/projects"))
        #expect(local.allSatisfy { $0.headers[Self.credentialHeader] == nil })
        #expect(remote.allSatisfy { $0.headers[Self.credentialHeader] == Self.credential })
        #expect(h.http.headers.allSatisfy { !$0.headers.keys.contains { $0.lowercased() == "origin" } })
    }

    // MARK: - Naming a remote failure

    nonisolated static let offlineBody = #"{"servers":[{"handle":"mini","live":false}]}"#
    nonisolated static let liveBody = #"{"servers":[{"handle":"mini","live":true}]}"#

    @Test(
        "a failing remote fetch is named by the relay's answer",
        arguments: [
            (401, "", ConnectHealthFinding.revoked),
            (200, offlineBody, .offline),
            (200, liveBody, .live),
        ]
    )
    func probeNamesTheFailure(_ status: Int, _ body: String, _ finding: ConnectHealthFinding) async throws {
        let h = Harness()
        h.http.refuse(Self.remote)
        h.http.setHealth(Self.remote, status: status, body: body)
        h.connection.setPairing(try h.pairing())
        h.connection.apply(.notRunning(error: nil))
        try h.transport(0).simulateOpen()
        let expected = finding.message(handle: Self.handle) ?? BBAPIError.authenticationRequired.message
        await eventually { h.store.state.errors == [expected] && h.http.answered.contains("\(Self.remote) /api/connect/servers") }
        #expect(h.store.state.errors == [expected])
        #expect(h.store.state.status == .reconnecting)
        #expect(h.http.probes == 1, "one failure, one probe")
        let probe = h.http.headers.first { $0.key == "\(Self.remote) /api/connect/servers" }
        #expect(probe?.headers[Self.credentialHeader] == Self.credential)
    }

    @Test("an unreachable relay is named as the probe names it")
    func probeNamesUnreachableRelay() async throws {
        let h = Harness()
        h.http.refuse(Self.remote)
        h.http.setHealth(Self.remote, status: 503, body: "")
        let pairing = try h.pairing()
        let reference = FakeHTTPClient(["/api/connect/servers": (503, Data())])
        let expected = try #require(await ConnectHealth.probe(pairing: pairing, http: reference).message(handle: Self.handle))
        h.connection.setPairing(pairing)
        h.connection.apply(.notRunning(error: nil))
        try h.transport(0).simulateOpen()
        await eventually { h.store.state.errors == [expected] }
        #expect(h.store.state.errors == [expected])
    }

    @Test("a socket lost after it opened is named too, and each later failure may probe again")
    func probeAfterSocketLossAndAgain() async throws {
        let h = Harness()
        let remote = try await h.connectRemote()
        h.http.setHealth(Self.remote, status: 200, body: Self.offlineBody)
        remote.simulateClose()
        let offline = try #require(ConnectHealthFinding.offline.message(handle: Self.handle))
        await eventually { h.store.state.errors == [offline] }
        #expect(h.store.state.errors == [offline])
        #expect(h.http.probes == 1)

        // The next attempt fails before it opens; the finding stands until
        // the new probe answers, and then says what the relay says now.
        h.http.setHealth(Self.remote, status: 401, body: "")
        await h.clock.advance(by: RealtimeSession.initialBackoff)
        await settle(until: { h.factory.transports.count == 2 })
        try h.transport(1).simulateClose()
        let revoked = try #require(ConnectHealthFinding.revoked.message(handle: Self.handle))
        await eventually { h.store.state.errors == [revoked] }
        #expect(h.store.state.errors == [revoked])
        #expect(h.http.probes == 2)
    }

    @Test("a finding that landed is gone once the session connects again")
    func findingClearsOnReconnect() async throws {
        let h = Harness()
        let remote = try await h.connectRemote()
        h.http.setHealth(Self.remote, status: 200, body: Self.offlineBody)
        remote.simulateClose()
        let offline = try #require(ConnectHealthFinding.offline.message(handle: Self.handle))
        await eventually { h.store.state.errors == [offline] }
        try #require(h.store.state.errors == [offline])

        await h.clock.advance(by: RealtimeSession.initialBackoff)
        await settle(until: { h.factory.transports.count == 2 })
        try h.transport(1).simulateOpen()
        await eventually { h.store.state.status == .connected }
        #expect(h.store.state.status == .connected)
        #expect(h.store.state.errors.isEmpty)
    }

    @Test("no probe runs while one is in flight")
    func oneProbeAtATime() async throws {
        let h = Harness()
        let remote = try await h.connectRemote()
        h.http.setHealth(Self.remote, status: 200, body: Self.offlineBody)
        let gate = h.http.hold(Self.remote, path: "/api/connect/servers")
        remote.simulateClose()
        await eventually { h.http.probes == 1 }
        for index in 1...3 {
            await h.clock.advance(by: .seconds(30))
            await settle(until: { h.factory.transports.count == index + 1 })
            try h.transport(index).simulateError("refused")
        }
        #expect(h.factory.transports.count == 4)
        #expect(h.http.probes == 1)
        gate.open()
        let offline = try #require(ConnectHealthFinding.offline.message(handle: Self.handle))
        await eventually { h.store.state.errors == [offline] }
        #expect(h.store.state.errors == [offline], "the answer landed, though the session re-dialled meanwhile")
    }

    @Test("a probe answered after the server changed is dropped")
    func staleProbeAfterServerChange() async throws {
        let h = Harness()
        h.http.refuse(Self.remote)
        h.http.setHealth(Self.remote, status: 401, body: "")
        let gate = h.http.hold(Self.remote, path: "/api/connect/servers")
        h.connection.setPairing(try h.pairing())
        h.connection.apply(.notRunning(error: nil))
        try h.transport(0).simulateOpen()
        await eventually { h.http.probes == 1 }
        try #require(h.http.probes == 1)

        h.connection.apply(try h.running(Self.portA))
        let after = h.store.state
        #expect(after.errors.isEmpty)
        gate.open()
        await eventually { h.http.answered.contains("\(Self.remote) /api/connect/servers") }
        try #require(h.http.answered.contains("\(Self.remote) /api/connect/servers"))
        let leaked = await eventually(timeout: .milliseconds(300)) { h.store.state != after }
        #expect(!leaked, "the old target's probe reached the store: \(h.store.state)")
    }

    @Test("a probe answered after the session connected again is dropped")
    func staleProbeAfterReconnect() async throws {
        let h = Harness()
        h.http.refuse(Self.remote)
        h.http.setHealth(Self.remote, status: 401, body: "")
        let gate = h.http.hold(Self.remote, path: "/api/connect/servers")
        h.connection.setPairing(try h.pairing())
        h.connection.apply(.notRunning(error: nil))
        try h.transport(0).simulateOpen()
        await eventually { h.http.probes == 1 }

        h.http.unrefuse(Self.remote)
        await h.clock.advance(by: RealtimeSession.initialBackoff)
        await settle(until: { h.factory.transports.count == 2 })
        try h.transport(1).simulateOpen()
        await eventually { h.store.state.status == .connected }
        try #require(h.store.state.status == .connected)
        #expect(h.store.state.errors.isEmpty)

        gate.open()
        await eventually { h.http.answered.contains("\(Self.remote) /api/connect/servers") }
        let leaked = await eventually(timeout: .milliseconds(300)) { !h.store.state.errors.isEmpty }
        #expect(!leaked, "a probe about the last failure named a connected server: \(h.store.state.errors)")
    }

    @Test("a local bb is never probed")
    func noProbeForLocal() async throws {
        let h = Harness()
        h.connection.setPairing(try h.pairing())
        h.http.refuse(Self.portA)
        h.connection.apply(try h.running(Self.portA))
        let transport = try h.transport(0)
        transport.simulateOpen()
        await eventually { h.store.state.status == .reconnecting }
        await h.clock.advance(by: RealtimeSession.initialBackoff)
        await settle(until: { h.factory.transports.count == 2 })
        try h.transport(1).simulateClose()
        await settle()
        #expect(h.store.state.errors == ["bb live updates: the connection closed before it opened (code 1006)"])
        #expect(h.http.probes == 0)
        #expect(!h.http.asked.contains { $0.hasPrefix("\(Self.remote) ") })
    }

    @Test("a connected remote bb is never probed")
    func noProbeWhileConnected() async throws {
        let h = Harness()
        let remote = try await h.connectRemote()
        for _ in 0..<3 {
            remote.simulateText(#"{"type":"changed","entity":"thread","id":"thr_a"}"#)
            await h.clock.advance(by: .seconds(2))
            await settle()
        }
        await eventually { h.http.asked.filter { $0.hasSuffix("/api/v1/projects") }.count >= 2 }
        #expect(h.http.asked.filter { $0.hasSuffix("/api/v1/projects") }.count >= 2, "re-fetches ran")
        #expect(h.store.state.status == .connected)
        #expect(h.http.probes == 0)
    }
}

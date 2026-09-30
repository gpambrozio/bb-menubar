import Clocks
import Foundation
import Testing
@testable import BBIconCore

@MainActor
struct ServerConnectionTests {
    /// Every bb server a test runs, told apart by port. Each answers its
    /// projects with one project and its threads with one thread named after
    /// the port (`thr_38886`), and its open request reaches one window unless
    /// told otherwise. A held port's next request waits until the test opens
    /// the gate, and the gate is then gone: `AsyncGate` releases one waiter,
    /// so the requests after it go straight through. A refused port answers
    /// every request 401.
    ///
    /// A class under a lock rather than an actor, so `eventually` can read
    /// what was asked and answered without awaiting.
    final class ServersHTTPClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [Int: AsyncGate] = [:]
        private var delivered: [Int: Int] = [:]
        private var refused: Set<Int> = []
        private var askedKeys: [String] = []
        private var answeredKeys: [String] = []

        /// `<port> <path>` of every request, in the order they were sent.
        var asked: [String] { lock.withLock { askedKeys } }
        /// The same, in the order they were answered.
        var answered: [String] { lock.withLock { answeredKeys } }

        func hold(_ port: Int) -> AsyncGate {
            let gate = AsyncGate()
            lock.withLock { gates[port] = gate }
            return gate
        }

        func setDelivered(_ count: Int, port: Int) {
            lock.withLock { delivered[port] = count }
        }

        func refuse(_ port: Int) {
            lock.withLock { _ = refused.insert(port) }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url, let port = url.port else { throw URLError(.badURL) }
            let path = url.path(percentEncoded: true)
            let key = "\(port) \(path)"
            let gate = lock.withLock {
                askedKeys.append(key)
                return gates[port]
            }
            if let gate {
                await gate.wait()
                lock.withLock { if gates[port] === gate { gates[port] = nil } }
            }
            let (status, body) = lock.withLock { () -> (Int, String) in
                answeredKeys.append(key)
                if refused.contains(port) { return (401, "") }
                switch path {
                case "/api/v1/projects":
                    return (200, #"[{"id":"proj_a","name":"web-app"}]"#)
                case "/api/v1/threads":
                    return (200, #"[{"id":"thr_\#(port)","projectId":"proj_a","status":"idle","latestAttentionAt":1,"createdAt":1}]"#)
                case let open where open.hasSuffix("/open"):
                    return (200, #"{"delivered":\#(delivered[port] ?? 1)}"#)
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
}

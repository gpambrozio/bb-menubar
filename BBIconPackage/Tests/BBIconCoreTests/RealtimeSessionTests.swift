import Clocks
import Foundation
import Testing
@testable import BBIconCore

@MainActor
struct RealtimeSessionTests {
    static let threadChanged = #"{"type":"changed","entity":"thread","id":"thr_a","changes":["events-appended"]}"#
    static let projectChanged = #"{"type":"changed","entity":"project","id":"proj_a","changes":["updated"]}"#
    static let subscribeMessages = [
        #"{"type":"subscribe","target":{"kind":"thread-list"}}"#,
        #"{"type":"subscribe","target":{"kind":"project-list"}}"#,
    ]

    /// A snapshot fetch the test controls. Each call's snapshot carries the
    /// call's number in its one thread id, so a test can tell which fetch a
    /// delivered snapshot came from.
    @MainActor
    final class FakeFetcher {
        private(set) var calls = 0
        /// When set, every call waits for `release` or `fail`.
        var suspends = false
        /// When set, every call throws it at once.
        var failure: (any Error)?
        private var pending: [Int: CheckedContinuation<BBSnapshot, any Error>] = [:]

        static func snapshot(_ call: Int) -> BBSnapshot {
            BBSnapshot(threads: [thread("thr_\(call)")], projects: [], truncated: false, decodeFailures: [])
        }

        func fetch() async throws -> BBSnapshot {
            calls += 1
            let call = calls
            if let failure { throw failure }
            guard suspends else { return Self.snapshot(call) }
            return try await withCheckedThrowingContinuation { pending[call] = $0 }
        }

        var pendingCalls: [Int] { pending.keys.sorted() }

        func release(_ call: Int) {
            pending.removeValue(forKey: call)?.resume(returning: Self.snapshot(call))
        }

        func fail(_ call: Int, _ error: any Error) {
            pending.removeValue(forKey: call)?.resume(throwing: error)
        }

        /// Every test that suspends a fetch ends here, so no continuation leaks.
        func releaseAll() {
            for call in pendingCalls { release(call) }
        }
    }

    enum Event: Equatable {
        case status(ConnectionStatus)
        case snapshot(BBSnapshot)
        case error(String?)
    }

    /// Every callback, in the order the session made them.
    @MainActor
    final class Log {
        var events: [Event] = [] {
            didSet { if let event = events.last, events.count > oldValue.count { onEvent?(event) } }
        }
        /// Runs inside the session's callback, for re-entrancy tests.
        var onEvent: ((Event) -> Void)?
        var statuses: [ConnectionStatus] { events.compactMap { if case .status(let s) = $0 { s } else { nil } } }
        var snapshots: [BBSnapshot] { events.compactMap { if case .snapshot(let s) = $0 { s } else { nil } } }
        var errors: [String?] { events.compactMap { if case .error(let e) = $0 { .some(e) } else { nil } } }
    }

    @MainActor
    struct Harness {
        let clock = TestClock()
        let factory = FakeTransportFactory()
        let fetcher = FakeFetcher()
        let log = Log()
        let session: RealtimeSession

        init() throws {
            let server = try #require(URL(string: "http://127.0.0.1:38886"))
            session = RealtimeSession(
                serverURL: server,
                makeTransport: factory.make,
                fetch: { @MainActor [fetcher] in try await fetcher.fetch() },
                onStatus: { [log] in log.events.append(.status($0)) },
                onSnapshot: { [log] in log.events.append(.snapshot($0)) },
                onError: { [log] in log.events.append(.error($0)) },
                clock: clock
            )
        }

        func transport(_ index: Int) throws -> FakeTransport {
            try #require(factory.transports.indices.contains(index) ? factory.transports[index] : nil)
        }

        /// Starts, opens the first transport, and waits for the first fetch to
        /// land, which is what `connected` means.
        func startConnected() async throws -> FakeTransport {
            session.start()
            let transport = try transport(0)
            transport.simulateOpen()
            await settle(until: { log.statuses.last == .connected })
            try #require(log.statuses.last == .connected)
            return transport
        }
    }

    // MARK: - Pure parts

    @Test("maps the server URL to its /ws endpoint")
    func websocketURLMapping() throws {
        let plain = try #require(URL(string: "http://127.0.0.1:38886"))
        #expect(RealtimeSession.websocketURL(for: plain).absoluteString == "ws://127.0.0.1:38886/ws")
        let slash = try #require(URL(string: "http://127.0.0.1:38886/"))
        #expect(RealtimeSession.websocketURL(for: slash).absoluteString == "ws://127.0.0.1:38886/ws")
        let tls = try #require(URL(string: "https://h.example/base?x=1#frag"))
        #expect(RealtimeSession.websocketURL(for: tls).absoluteString == "wss://h.example/ws")
    }

    @Test("backs off from 1 s by 1.5x, capped at 30 s")
    func backoffSequence() {
        var delay = RealtimeSession.initialBackoff
        var sequence: [Duration] = []
        for _ in 0..<12 {
            sequence.append(delay)
            delay = RealtimeSession.nextBackoff(after: delay)
        }
        #expect(sequence == [
            .seconds(1), .milliseconds(1500), .milliseconds(2250), .microseconds(3_375_000),
            .nanoseconds(5_062_500_000), .nanoseconds(7_593_750_000), .nanoseconds(11_390_625_000),
            .nanoseconds(17_085_937_500), .nanoseconds(25_628_906_250), .seconds(30), .seconds(30), .seconds(30),
        ])
        #expect(RealtimeSession.initialBackoff == .seconds(1))
        #expect(RealtimeSession.maxBackoff == .seconds(30))
    }

    @Test("the backoff step cannot overflow or go below the first delay")
    func backoffIsBounded() {
        #expect(RealtimeSession.nextBackoff(after: .seconds(Int64.max)) == .seconds(30))
        #expect(RealtimeSession.nextBackoff(after: .seconds(29)) == .seconds(30))
        #expect(RealtimeSession.nextBackoff(after: .zero) == .seconds(1))
        #expect(RealtimeSession.nextBackoff(after: .seconds(-5)) == .seconds(1))
    }

    // MARK: - Connecting

    @Test("start reports connecting and dials the /ws URL")
    func startDials() throws {
        let h = try Harness()
        h.session.start()
        #expect(h.log.statuses == [.connecting])
        let transport = try h.transport(0)
        #expect(transport.request.url.absoluteString == "ws://127.0.0.1:38886/ws")
        #expect(transport.connectCalls == 1)
        #expect(h.fetcher.calls == 0)
    }

    @Test("on open, subscribes to both lists and fetches at once")
    func subscribesOnOpenAndFetches() async throws {
        let h = try Harness()
        h.session.start()
        let transport = try h.transport(0)
        transport.simulateOpen()
        #expect(transport.sentText == Self.subscribeMessages)
        await settle(until: { h.log.statuses.count == 2 })
        await settle()
        #expect(h.fetcher.calls == 1)
        #expect(h.log.statuses == [.connecting, .connected])
        // The error row clears and the rows land before `connected`, so the
        // tray never shows a connected state over the previous rows.
        #expect(h.log.events == [
            .status(.connecting), .error(nil), .snapshot(FakeFetcher.snapshot(1)), .status(.connected),
        ])
    }

    @Test("connected is reported once per open, not per fetch")
    func connectedOncePerOpen() async throws {
        let h = try Harness()
        let transport = try await h.startConnected()
        transport.simulateText(Self.threadChanged)
        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle(until: { h.log.snapshots.count == 2 })
        #expect(h.log.snapshots.count == 2)
        #expect(h.log.statuses == [.connecting, .connected])
    }

    // MARK: - Invalidations

    @Test("a burst of changed frames costs one fetch, after the debounce")
    func changedMessagesAreDebouncedIntoOneFetch() async throws {
        let h = try Harness()
        let transport = try await h.startConnected()
        // Past the open fetch's minimum interval, so only the debounce decides.
        await h.clock.advance(by: .seconds(1))
        await settle()
        for index in 0..<5 {
            if index > 0 { await h.clock.advance(by: .milliseconds(25)) }
            transport.simulateText(index.isMultiple(of: 2) ? Self.threadChanged : Self.projectChanged)
            await settle()
        }
        #expect(h.fetcher.calls == 1)
        await h.clock.advance(by: .milliseconds(149))
        await settle()
        #expect(h.fetcher.calls == 1, "250 ms after the first frame has not elapsed yet")
        await h.clock.advance(by: .milliseconds(1))
        await settle(until: { h.fetcher.calls == 2 })
        #expect(h.fetcher.calls == 2)
        await h.clock.advance(by: .seconds(5))
        await settle()
        #expect(h.fetcher.calls == 2)
    }

    @Test("a steady stream of changed frames fetches once a second, no more and no less")
    func steadyStreamIsCappedAtOncePerSecond() async throws {
        let h = try Harness()
        let transport = try await h.startConnected()
        // A running thread appends events for as long as it runs: a frame
        // every 100 ms for 5 s. A debounce that restarted on every frame would
        // never fetch; one that did not, uncapped, would fetch back to back.
        // Fetches start at 0 (the open), 1, 2, 3, 4, and 5 s.
        var expected = 1
        for step in 1...50 {
            transport.simulateText(Self.threadChanged)
            await settle()
            await h.clock.advance(by: .milliseconds(100))
            if step.isMultiple(of: 10) {
                expected += 1
                await settle(until: { h.fetcher.calls == expected })
            } else {
                await settle()
            }
            #expect(h.fetcher.calls == expected, "at \(step * 100) ms")
        }
        #expect(h.fetcher.calls == 6)
    }

    @Test("the fetch on open is not held back by the interval")
    func openFetchIsImmediate() async throws {
        let h = try Harness()
        _ = try await h.startConnected()
        #expect(h.fetcher.calls == 1)
        // A new connection within the same second still fetches at once:
        // what changed while it was down was never announced.
        h.session.stop()
        h.session.start()
        let second = try h.transport(1)
        second.simulateOpen()
        await settle(until: { h.fetcher.calls == 2 })
        #expect(h.fetcher.calls == 2)
        // And that fetch starts the interval again.
        second.simulateText(Self.threadChanged)
        await settle()
        await h.clock.advance(by: .milliseconds(999))
        await settle()
        #expect(h.fetcher.calls == 2)
        await h.clock.advance(by: .milliseconds(1))
        await settle(until: { h.fetcher.calls == 3 })
        #expect(h.fetcher.calls == 3)
    }

    @Test("a follow-up owed when a slow fetch ends starts at once if the interval has passed")
    func followUpAfterSlowFetchIsImmediate() async throws {
        let h = try Harness()
        h.fetcher.suspends = true
        h.session.start()
        let transport = try h.transport(0)
        transport.simulateOpen()
        await settle(until: { h.fetcher.pendingCalls == [1] })
        transport.simulateText(Self.threadChanged)
        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle()
        #expect(h.fetcher.calls == 1)
        h.fetcher.release(1)
        await settle(until: { h.fetcher.pendingCalls == [2] })
        #expect(h.fetcher.calls == 2, "1.5 s since fetch 1 started, so no wait")
        h.fetcher.releaseAll()
    }

    @Test("other frames, and frames that are not JSON, are ignored")
    func ignoresOtherMessages() async throws {
        let h = try Harness()
        let transport = try await h.startConnected()
        transport.simulateText(#"{"type":"plugin-signal","pluginId":"xcode","channel":"xcode:activity","payload":{"at":1}}"#)
        transport.simulateText(#"{"type":"changed","entity":"host","id":"h"}"#)
        transport.simulateText(#"{"type":"changed"}"#)
        transport.simulateText(#"{"type":"changed","entity":7}"#)
        transport.simulateText(#"[1,2]"#)
        transport.simulateText("not json")
        transport.simulateBinary(Array(Self.threadChanged.utf8))
        await settle()
        await h.clock.advance(by: .seconds(5))
        await settle()
        #expect(h.fetcher.calls == 1)
        #expect(transport.closedWith == nil)
    }

    @Test("bb's recorded frames fetch once per thread or project change")
    func replaysRecordedMessages() async throws {
        let url = try #require(Bundle.module.url(forResource: "ws-messages", withExtension: "jsonl", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        // Classified independently of the session's parser.
        let isChange = try lines.map { line in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return object["type"] as? String == "changed" && ["thread", "project"].contains(object["entity"] as? String)
        }
        let changes = isChange.filter { $0 }.count
        try #require(changes > 0 && changes < lines.count, "the fixture mixes changes with other frames")

        let h = try Harness()
        let transport = try await h.startConnected()
        var expected = 1
        for (line, change) in zip(lines, isChange) {
            transport.simulateText(line)
            await settle()
            // Past both the debounce and the one-second minimum interval.
            await h.clock.advance(by: .seconds(1))
            if change {
                expected += 1
                await settle(until: { h.fetcher.calls == expected })
            } else {
                await settle()
            }
            #expect(h.fetcher.calls == expected, "after: \(line)")
        }
        #expect(h.fetcher.calls == 1 + changes)
    }

    @Test("bb's whole recording at once costs one fetch")
    func recordedBurstIsOneFetch() async throws {
        let url = try #require(Bundle.module.url(forResource: "ws-messages", withExtension: "jsonl", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let h = try Harness()
        let transport = try await h.startConnected()
        for line in lines { transport.simulateText(line) }
        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle(until: { h.fetcher.calls == 2 })
        await h.clock.advance(by: .seconds(5))
        await settle()
        #expect(h.fetcher.calls == 2)
    }

    @Test("invalidations during a fetch cause exactly one follow-up fetch")
    func invalidationDuringFetchRefetchesOnce() async throws {
        let h = try Harness()
        h.fetcher.suspends = true
        h.session.start()
        let transport = try h.transport(0)
        transport.simulateOpen()
        await settle(until: { h.fetcher.pendingCalls == [1] })
        // Three separate windows close while fetch 1 is still running; each
        // one finds a fetch in flight.
        for window in 1...3 {
            transport.simulateText(Self.threadChanged)
            await settle()
            await h.clock.advance(by: .milliseconds(250))
            await settle()
            #expect(h.fetcher.calls == 1, "never two fetches at once (window \(window))")
        }
        h.fetcher.release(1)
        await settle()
        // 750 ms since fetch 1 started: the follow-up waits the remainder
        // of the one-second interval, not a whole new one.
        #expect(h.fetcher.calls == 1, "not before a second has passed since fetch 1 started")
        await h.clock.advance(by: .milliseconds(250))
        await settle(until: { h.fetcher.pendingCalls == [2] })
        #expect(h.fetcher.calls == 2)
        h.fetcher.release(2)
        await settle(until: { h.log.snapshots.count == 2 })
        await h.clock.advance(by: .seconds(5))
        await settle()
        #expect(h.fetcher.calls == 2)
        #expect(h.log.snapshots == [FakeFetcher.snapshot(1), FakeFetcher.snapshot(2)])
        h.fetcher.releaseAll()
    }

    @Test("a fetch that starts covers the frames of a window still open")
    func followUpFetchCoversPendingWindow() async throws {
        let h = try Harness()
        h.fetcher.suspends = true
        h.session.start()
        let transport = try h.transport(0)
        transport.simulateOpen()
        await settle(until: { h.fetcher.pendingCalls == [1] })
        // A window closes during fetch 1, so a follow-up is owed.
        transport.simulateText(Self.threadChanged)
        await settle()
        await h.clock.advance(by: .milliseconds(250))
        await settle()
        // A second window opens. The follow-up owed from the first already
        // covers this frame, whether it starts before the window closes or
        // (as here, waiting out the one-second interval) after.
        transport.simulateText(Self.threadChanged)
        await settle()
        h.fetcher.release(1)
        await settle()
        await h.clock.advance(by: .milliseconds(750))
        await settle(until: { h.fetcher.pendingCalls == [2] })
        h.fetcher.release(2)
        await settle(until: { h.log.snapshots.count == 2 })
        await h.clock.advance(by: .seconds(5))
        await settle()
        #expect(h.fetcher.calls == 2)
        h.fetcher.releaseAll()
    }

    // MARK: - Reconnecting

    @Test("the backoff keeps growing while every fetch after open fails")
    func backoffGrowsWhileFetchesFail() async throws {
        let h = try Harness()
        h.fetcher.failure = BBAPIError.authenticationRequired
        h.session.start()
        // Each transport opens and its fetch fails. An open alone is not a
        // success, so the delays still grow: 1 s, 1.5 s, 2.25 s.
        let delays: [Duration] = [.seconds(1), .milliseconds(1500), .milliseconds(2250)]
        for (index, delay) in delays.enumerated() {
            try h.transport(index).simulateOpen()
            await settle(until: { h.log.errors.count == index + 1 })
            #expect(try h.transport(index).closedWith != nil)
            await settle()
            await h.clock.advance(by: delay - .milliseconds(1))
            await settle()
            #expect(h.factory.transports.count == index + 1, "not before \(delay)")
            await h.clock.advance(by: .milliseconds(1))
            await settle(until: { h.factory.transports.count == index + 2 })
            #expect(h.factory.transports.count == index + 2, "after \(delay)")
        }
        #expect(h.log.statuses == [.connecting, .reconnecting])
    }

    @Test("a transport that fails before it opens names the failure")
    func handshakeFailureNamesItself() async throws {
        let h = try Harness()
        h.session.start()
        let first = try h.transport(0)
        first.simulateError("There was a bad response from the server.")
        #expect(h.log.errors == ["bb live updates: There was a bad response from the server."])
        #expect(h.log.statuses == [.connecting, .reconnecting])
        #expect(first.closedWith != nil)
        first.simulateClose()
        #expect(h.log.errors.count == 1, "the dropped transport's close adds nothing")

        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle(until: { h.factory.transports.count == 2 })
        try h.transport(1).simulateClose(code: 1002, reason: "")
        #expect(h.log.errors.last == "bb live updates: the connection closed before it opened (code 1002)")

        await settle()
        await h.clock.advance(by: .milliseconds(1500))
        await settle(until: { h.factory.transports.count == 3 })
        let third = try h.transport(2)
        third.simulateOpen()
        await settle(until: { h.log.statuses.last == .connected })
        #expect(h.log.errors.last == .some(nil), "the first good fetch clears it")

        // After an open, losing the socket is a bb restart: just reconnecting.
        let errors = h.log.errors
        third.simulateClose(code: 1001, reason: "server shutting down")
        #expect(h.log.statuses.last == .reconnecting)
        #expect(h.log.errors == errors)
    }

    @Test("a close reconnects after the backoff, which grows until an open resets it")
    func closeReconnectsWithBackoff() async throws {
        let h = try Harness()
        let first = try await h.startConnected()
        first.simulateClose()
        #expect(h.log.statuses.last == .reconnecting)
        #expect(first.closedWith != nil)
        await settle()
        await h.clock.advance(by: .milliseconds(999))
        await settle()
        #expect(h.factory.transports.count == 1)
        await h.clock.advance(by: .milliseconds(1))
        await settle(until: { h.factory.transports.count == 2 })
        let second = try h.transport(1)
        #expect(second.connectCalls == 1)
        #expect(second.request.url.absoluteString == "ws://127.0.0.1:38886/ws")

        second.simulateClose()
        await settle()
        await h.clock.advance(by: .milliseconds(1499))
        await settle()
        #expect(h.factory.transports.count == 2)
        await h.clock.advance(by: .milliseconds(1))
        await settle(until: { h.factory.transports.count == 3 })
        let third = try h.transport(2)

        third.simulateOpen()
        await settle(until: { h.log.statuses.last == .connected })
        third.simulateClose()
        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle(until: { h.factory.transports.count == 4 })
        #expect(h.factory.transports.count == 4, "an open resets the backoff to 1 s")
        #expect(h.log.statuses == [.connecting, .connected, .reconnecting, .connected, .reconnecting])
    }

    @Test("a transport error drops the connection like a close")
    func transportErrorReconnects() async throws {
        let h = try Harness()
        let first = try await h.startConnected()
        first.simulateError("The network connection was lost.")
        #expect(h.log.statuses.last == .reconnecting)
        #expect(h.log.errors == [nil], "a socket lost after open is not an error row")
        #expect(first.closedWith != nil)
        // The close that follows the error belongs to a transport already
        // dropped; it must not advance the backoff a second time.
        first.simulateClose()
        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle(until: { h.factory.transports.count == 2 })
        #expect(h.factory.transports.count == 2)
    }

    @Test("a replaced transport's callbacks are ignored")
    func replacedTransportIsIgnored() async throws {
        let h = try Harness()
        let old = try await h.startConnected()
        old.simulateClose()
        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle(until: { h.factory.transports.count == 2 })
        let current = try h.transport(1)
        current.simulateOpen()
        await settle(until: { h.log.statuses.last == .connected })
        let events = h.log.events
        let calls = h.fetcher.calls

        old.simulateText(Self.threadChanged)
        old.simulateOpen()
        old.simulateError("late")
        old.simulateClose()
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()

        #expect(h.log.events == events)
        #expect(h.fetcher.calls == calls)
        #expect(h.factory.transports.count == 2)
        #expect(current.closedWith == nil)
        #expect(old.sentText == Self.subscribeMessages, "the old transport's late open subscribed nothing")
    }

    @Test("a fetch that finishes after a reconnect is discarded")
    func staleFetchIsDiscarded() async throws {
        let h = try Harness()
        h.fetcher.suspends = true
        h.session.start()
        let old = try h.transport(0)
        old.simulateOpen()
        await settle(until: { h.fetcher.pendingCalls == [1] })
        old.simulateClose()
        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle(until: { h.factory.transports.count == 2 })
        let current = try h.transport(1)
        current.simulateOpen()
        await settle(until: { h.fetcher.pendingCalls == [1, 2] })
        #expect(h.fetcher.calls == 2, "the new open fetches without waiting for the stale one")

        h.fetcher.release(1)
        await settle()
        #expect(h.log.snapshots.isEmpty)
        #expect(h.log.statuses == [.connecting, .reconnecting])

        h.fetcher.release(2)
        await settle(until: { h.log.snapshots.count == 1 })
        #expect(h.log.snapshots == [FakeFetcher.snapshot(2)])
        #expect(h.log.statuses == [.connecting, .reconnecting, .connected])
    }

    @Test("a fetch failure that finishes after a reconnect is discarded")
    func staleFailureIsDiscarded() async throws {
        let h = try Harness()
        h.fetcher.suspends = true
        h.session.start()
        let old = try h.transport(0)
        old.simulateOpen()
        await settle(until: { h.fetcher.pendingCalls == [1] })
        old.simulateClose()
        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle(until: { h.factory.transports.count == 2 })
        let current = try h.transport(1)
        current.simulateOpen()
        await settle(until: { h.fetcher.pendingCalls == [1, 2] })

        h.fetcher.fail(1, BBAPIError.authenticationRequired)
        await settle()
        #expect(h.log.errors.isEmpty)
        #expect(current.closedWith == nil)
        #expect(h.log.statuses == [.connecting, .reconnecting])
        h.fetcher.releaseAll()
    }

    @Test("a failed fetch names its error and reconnects")
    func fetchFailureNamesErrorAndReconnects() async throws {
        let h = try Harness()
        h.fetcher.failure = BBAPIError.authenticationRequired
        h.session.start()
        let first = try h.transport(0)
        first.simulateOpen()
        await settle(until: { !h.log.errors.isEmpty })
        #expect(h.log.errors == [BBAPIError.authenticationRequired.message])
        #expect(first.closedWith != nil)
        #expect(h.log.statuses == [.connecting, .reconnecting])
        #expect(h.log.snapshots.isEmpty)

        h.fetcher.failure = nil
        await settle()
        await h.clock.advance(by: .seconds(1))
        await settle(until: { h.factory.transports.count == 2 })
        try h.transport(1).simulateOpen()
        await settle(until: { h.log.statuses.last == .connected })
        #expect(h.log.errors == [BBAPIError.authenticationRequired.message, nil])
    }

    // MARK: - Stopping

    @Test("after stop, nothing reaches the callbacks")
    func stopIsSilent() async throws {
        let h = try Harness()
        h.fetcher.suspends = true
        h.session.start()
        let transport = try h.transport(0)
        transport.simulateOpen()
        await settle(until: { h.fetcher.pendingCalls == [1] })
        transport.simulateText(Self.threadChanged)
        await settle()
        let events = h.log.events

        h.session.stop()
        #expect(transport.closedWith?.code == 1000)
        h.fetcher.release(1)
        await settle()
        await h.clock.advance(by: .seconds(60))
        transport.simulateText(Self.threadChanged)
        transport.simulateOpen()
        transport.simulateError("late")
        transport.simulateClose()
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()

        #expect(h.log.events == events)
        #expect(h.fetcher.calls == 1)
        #expect(h.factory.transports.count == 1)
    }

    @Test("stop cancels a pending reconnect")
    func stopCancelsReconnect() async throws {
        let h = try Harness()
        let transport = try await h.startConnected()
        transport.simulateClose()
        await settle()
        h.session.stop()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1)
    }

    @Test("a stop from inside a callback silences the rest of that fetch")
    func stopFromCallbackIsSilent() async throws {
        let h = try Harness()
        h.log.onEvent = { [weak session = h.session] event in
            if case .snapshot = event { session?.stop() }
        }
        h.session.start()
        let transport = try h.transport(0)
        transport.simulateOpen()
        await settle(until: { !h.log.snapshots.isEmpty })
        await settle()
        #expect(h.log.events == [.status(.connecting), .error(nil), .snapshot(FakeFetcher.snapshot(1))])
        #expect(transport.closedWith?.code == 1000)
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.factory.transports.count == 1)
        h.log.onEvent = nil
    }

    @Test("a stop from inside the error callback prevents the reconnect")
    func stopFromErrorCallbackIsSilent() async throws {
        let h = try Harness()
        h.fetcher.failure = BBAPIError.authenticationRequired
        h.log.onEvent = { [weak session = h.session] event in
            if case .error = event { session?.stop() }
        }
        h.session.start()
        try h.transport(0).simulateOpen()
        await settle(until: { !h.log.errors.isEmpty })
        await settle()
        await h.clock.advance(by: .seconds(60))
        await settle()
        #expect(h.log.statuses == [.connecting])
        #expect(h.factory.transports.count == 1)
        h.log.onEvent = nil
    }

    @Test("start after stop connects afresh")
    func startAfterStop() async throws {
        let h = try Harness()
        _ = try await h.startConnected()
        h.session.stop()
        h.session.start()
        #expect(h.factory.transports.count == 2)
        try h.transport(1).simulateOpen()
        await settle(until: { h.log.statuses.count == 4 })
        #expect(h.log.statuses == [.connecting, .connected, .connecting, .connected])
        #expect(h.fetcher.calls == 2)
    }

    @Test("a second start while running does nothing")
    func startIsIdempotent() throws {
        let h = try Harness()
        h.session.start()
        h.session.start()
        #expect(h.factory.transports.count == 1)
        #expect(h.log.statuses == [.connecting])
    }
}

import Clocks
import Foundation
import Testing
@testable import BBIconCore

@MainActor
struct RuntimeSessionTests {
    static func runtimeJSON(pid: Int = 16746, port: Int = 38886) -> Data {
        Data(#"{"pid": \#(pid), "serverUrl": "http://127.0.0.1:\#(port)", "surface": "desktop", "version": "0.44.0"}"#.utf8)
    }

    static func info(pid: Int32 = 16746, port: Int = 38886) throws -> RuntimeInfo {
        RuntimeInfo(pid: pid, serverURL: try #require(URL(string: "http://127.0.0.1:\(port)")), version: "0.44.0")
    }

    /// The runtime file as `readFile` sees it. `readFile` runs on a global
    /// dispatch queue, so this is shared across threads and guards its state
    /// with a lock.
    final class FakeFile: @unchecked Sendable {
        private let lock = NSLock()
        private var _contents: Data?
        private var _failure: (any Error)?
        private var _reads = 0
        private var _finished = 0
        private var pendingHold: BlockingGate?

        var contents: Data? {
            get { lock.withLock { _contents } }
            set { lock.withLock { _contents = newValue } }
        }

        var failure: (any Error)? {
            get { lock.withLock { _failure } }
            set { lock.withLock { _failure = newValue } }
        }

        /// Reads started.
        var reads: Int { lock.withLock { _reads } }
        /// Reads that have returned or thrown.
        var finished: Int { lock.withLock { _finished } }

        /// Makes the next read take the contents as they are when it starts,
        /// then block until the returned gate opens.
        func holdNextRead() -> BlockingGate {
            let gate = BlockingGate()
            lock.withLock { pendingHold = gate }
            return gate
        }

        func read() throws -> Data? {
            let (contents, failure, hold) = lock.withLock {
                _reads += 1
                defer { pendingHold = nil }
                return (_contents, _failure, pendingHold)
            }
            defer { lock.withLock { _finished += 1 } }
            hold?.wait()
            if let failure { throw failure }
            return contents
        }
    }

    /// Blocks a synchronous read on the dispatch thread it runs on. Bounded
    /// by `gateTimeout`, well past `eventually`'s, so a test that forgets to
    /// open it fails on its own expectation instead of hanging.
    final class BlockingGate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func open() { semaphore.signal() }
        func wait() { _ = semaphore.wait(timeout: .now() + gateTimeout) }
    }

    /// The injected watch: keeps the callback so the test can fire it.
    @MainActor
    final class FakeWatch {
        private(set) var onChange: (() -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0

        func watch(_ onChange: @escaping () -> Void) -> () -> Void {
            starts += 1
            self.onChange = onChange
            return { [weak self] in self?.stops += 1 }
        }

        func fire() { onChange?() }
    }

    @MainActor
    final class Harness {
        let clock = TestClock()
        let file = FakeFile()
        let watcher = FakeWatch()
        var alive = true
        var appRunning = true
        private(set) var pidsChecked: [Int32] = []
        /// Every resolution delivered, in order.
        private(set) var deliveries: [RuntimeResolution] = []
        /// Reads the session applied: the deterministic signal that one finished.
        private(set) var afterReads = 0
        private(set) var session: RuntimeSession?

        init() {
            let file = self.file
            session = RuntimeSession(
                readFile: { try file.read() },
                isProcessAlive: { [weak self] pid in
                    self?.pidsChecked.append(pid)
                    return self?.alive ?? false
                },
                isAppRunning: { [weak self] in self?.appRunning ?? false },
                watch: { [weak self] onChange in self?.watcher.watch(onChange) ?? {} },
                afterRead: { [weak self] in self?.afterReads += 1 },
                onChange: { [weak self] resolution in self?.deliveries.append(resolution) },
                clock: clock
            )
        }

        func start() throws { try #require(session).start() }
        func refresh() throws { try #require(session).refresh() }
        func stop() throws { try #require(session).stop() }

        /// Starts the session and waits for its first read to be applied.
        func startAndSettle() async throws {
            try start()
            await eventually { self.afterReads == 1 }
            #expect(afterReads == 1)
        }

        /// Gives anything that should not happen a fair chance to happen:
        /// reads on the global queue, main-actor hops, timers.
        func quiesce() async {
            await settle()
            try? await Task.sleep(for: .milliseconds(50))
            await settle()
        }
    }

    // MARK: - Resolution

    @Test("a missing file is not running, with no error")
    func missingFileIsNotRunning() async throws {
        let h = Harness()
        h.file.contents = nil
        try await h.startAndSettle()
        #expect(h.deliveries == [.notRunning(error: nil)])
    }

    @Test("a malformed file is not running, and names what is wrong")
    func malformedFileNamesError() async throws {
        let h = Harness()
        h.file.contents = Data(#"{"serverUrl": "http://127.0.0.1:38886"}"#.utf8)
        try await h.startAndSettle()
        #expect(h.deliveries == [.notRunning(error: "bb's runtime file could not be read: pid is missing")])
    }

    @Test("a file that cannot be read is not running, and names the failure")
    func unreadableFileNamesError() async throws {
        let h = Harness()
        h.file.failure = CocoaError(.fileReadNoPermission)
        try await h.startAndSettle()
        let expected = "bb's runtime file could not be read: \(errorText(CocoaError(.fileReadNoPermission)))"
        #expect(h.deliveries == [.notRunning(error: expected)])
    }

    @Test("a runtime file whose pid is dead is not running")
    func deadPidIsNotRunning() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON(pid: 4242)
        h.alive = false
        try await h.startAndSettle()
        #expect(h.deliveries == [.notRunning(error: nil)])
        #expect(h.pidsChecked == [4242])
    }

    @Test("a live pid without bb.app running is not running")
    func appNotRunningIsNotRunning() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        h.appRunning = false
        try await h.startAndSettle()
        #expect(h.deliveries == [.notRunning(error: nil)])
    }

    @Test("a running bb is delivered once, however often it is re-read")
    func runningDeliversInfoOnce() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        try await h.startAndSettle()
        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))
        await eventually { h.afterReads == 2 }
        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))
        await eventually { h.afterReads == 3 }

        #expect(h.afterReads == 3)
        #expect(h.deliveries == [.running(try Self.info())])
    }

    @Test("bb relaunching on a new port is reported")
    func serverURLChangeIsReported() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON(port: 38886)
        try await h.startAndSettle()

        // Only the port: a pid that changed too would pass on the pid alone.
        h.file.contents = Self.runtimeJSON(port: 40111)
        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))
        await eventually { h.deliveries.count == 2 }

        #expect(h.deliveries == [
            .running(try Self.info(port: 38886)),
            .running(try Self.info(port: 40111)),
        ])
    }

    @Test("bb dying without removing its file is reported")
    func pidDyingIsReported() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        try await h.startAndSettle()

        // The file is untouched; only the process is gone.
        h.alive = false
        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))
        await eventually { h.deliveries.count == 2 }

        #expect(h.deliveries == [.running(try Self.info()), .notRunning(error: nil)])
    }

    @Test("bb quitting after it was running is reported")
    func quitIsReported() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        try await h.startAndSettle()

        h.file.contents = nil
        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))
        await eventually { h.deliveries.count == 2 }

        #expect(h.deliveries == [.running(try Self.info()), .notRunning(error: nil)])
    }

    // MARK: - When it reads

    @Test("a burst of refreshes is one read, 300 ms after the first")
    func refreshIsDebounced() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        try await h.startAndSettle()

        for _ in 0..<4 {
            try h.refresh()
            await h.clock.advance(by: .milliseconds(25))
        }
        try h.refresh()
        await h.clock.advance(by: .milliseconds(199))
        await h.quiesce()
        #expect(h.file.reads == 1, "no read before the window closes")

        await h.clock.advance(by: .milliseconds(1))
        await eventually { h.afterReads == 2 }
        await h.quiesce()
        #expect(h.file.reads == 2)
        #expect(h.afterReads == 2)
    }

    @Test("a refresh after a debounced read opens a new window")
    func refreshAfterReadReadsAgain() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        try await h.startAndSettle()
        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))
        await eventually { h.afterReads == 2 }

        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))
        await eventually { h.afterReads == 3 }
        #expect(h.file.reads == 3)
    }

    @Test("the poll re-reads without any event")
    func pollRereadsWithoutEvents() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        try await h.startAndSettle()

        await h.clock.advance(by: .seconds(29))
        await h.quiesce()
        #expect(h.file.reads == 1)

        await h.clock.advance(by: .seconds(1))
        await eventually { h.afterReads == 2 }
        #expect(h.file.reads == 2)

        await h.clock.advance(by: .seconds(30))
        await eventually { h.afterReads == 3 }
        #expect(h.file.reads == 3)
    }

    @Test("a watch event triggers a read after the debounce")
    func watchEventTriggersRead() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        try await h.startAndSettle()
        #expect(h.watcher.starts == 1)

        h.watcher.fire()
        await h.clock.advance(by: .milliseconds(299))
        await h.quiesce()
        #expect(h.file.reads == 1)

        await h.clock.advance(by: .milliseconds(1))
        await eventually { h.afterReads == 2 }
        #expect(h.file.reads == 2)
    }

    @Test("afterRead runs after failed reads too")
    func afterReadRunsOnFailure() async throws {
        let h = Harness()
        h.file.failure = CocoaError(.fileReadNoPermission)
        try await h.startAndSettle()
        h.file.contents = Data("not json".utf8)
        h.file.failure = nil
        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))
        await eventually { h.afterReads == 2 }
        #expect(h.afterReads == 2)
        #expect(h.deliveries.count == 2)
    }

    // MARK: - Stale reads and stopping

    @Test("reads asked for while one is in flight become exactly one more")
    func readsDoNotPileUp() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON(port: 38886)
        let gate = h.file.holdNextRead()
        try h.start()
        await eventually { h.file.reads == 1 }

        // bb relaunched while the first read was stuck, and every trigger
        // there is fired: two debounced refreshes, a watch event, the poll.
        h.file.contents = Self.runtimeJSON(port: 40111)
        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))
        h.watcher.fire()
        await h.clock.advance(by: .milliseconds(300))
        await h.clock.advance(by: .seconds(30))
        await h.quiesce()
        #expect(h.file.reads == 1, "nothing starts while a read is in flight")

        gate.open()
        await eventually { h.afterReads == 2 }
        await h.quiesce()
        #expect(h.file.reads == 2)
        #expect(h.afterReads == 2)
        #expect(h.deliveries == [
            .running(try Self.info(port: 38886)),
            .running(try Self.info(port: 40111)),
        ])
    }

    @Test("a read left over from before a restart is discarded")
    func readFromBeforeRestartIsDiscarded() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON(port: 38886)
        let gate = h.file.holdNextRead()
        try h.start()
        await eventually { h.file.reads == 1 }

        try h.stop()
        h.file.contents = Self.runtimeJSON(port: 40111)
        try h.start()
        // The stuck read does not hold up the new session's first read.
        await eventually { h.afterReads == 1 }
        #expect(h.file.reads == 2)
        #expect(h.deliveries == [.running(try Self.info(port: 40111))])

        gate.open()
        await eventually { h.file.finished == 2 }
        await h.quiesce()
        #expect(h.deliveries == [.running(try Self.info(port: 40111))])
        #expect(h.afterReads == 1)
    }

    @Test("stop is silent: no reads, no deliveries, the watch detached")
    func stopIsSilent() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        try await h.startAndSettle()

        try h.refresh()
        try h.stop()
        #expect(h.watcher.stops == 1)

        h.file.contents = Self.runtimeJSON(port: 40111)
        try h.refresh()
        h.watcher.fire()
        await h.clock.advance(by: .seconds(120))
        await h.quiesce()

        #expect(h.file.reads == 1)
        #expect(h.deliveries == [.running(try Self.info())])
        #expect(h.afterReads == 1)
    }

    @Test("a read that finishes after stop is discarded")
    func readAfterStopIsDiscarded() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        let gate = h.file.holdNextRead()
        try h.start()
        await eventually { h.file.reads == 1 }
        // And a follow-up waiting behind it.
        try h.refresh()
        await h.clock.advance(by: .milliseconds(300))

        try h.stop()
        gate.open()
        await eventually { h.file.finished == 1 }
        await h.quiesce()

        #expect(h.deliveries.isEmpty)
        #expect(h.afterReads == 0)
        #expect(h.file.reads == 1)
    }

    @Test("starting again delivers the resolution again, even if unchanged")
    func restartDeliversAgain() async throws {
        let h = Harness()
        h.file.contents = Self.runtimeJSON()
        try await h.startAndSettle()
        try h.stop()
        try h.start()
        await eventually { h.afterReads == 2 }

        #expect(h.deliveries == [.running(try Self.info()), .running(try Self.info())])
        #expect(h.watcher.starts == 2)
    }
}

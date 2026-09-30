import Foundation

/// Keeps the snapshot current from bb's `/ws` invalidations.
///
/// bb pushes no data over `/ws`, only "this changed" notices, so the session
/// is a trigger for `fetch`: once on every open (invalidations sent while
/// disconnected are lost), and after a burst of `changed` frames for a thread
/// or a project. Everything else on the socket is ignored.
///
/// Three rules keep a result from landing on the wrong state:
/// - At most one fetch runs per connection. An invalidation that arrives while
///   one runs sets `dirty`, and that fetch's success starts exactly one more.
/// - Every fetch carries the `generation` it started in. Open, loss of the
///   connection, and `stop` each start a new generation, and a result from an
///   older one is dropped whole: no snapshot, no error, no status.
/// - A callback from a transport that is no longer `transport` is ignored, by
///   identity, so a socket's late close cannot tear down its successor.
///
/// Every callback fires on the main actor. Timers use the injected clock.
@MainActor
public final class RealtimeSession {
    public static let initialBackoff: Duration = .seconds(1)
    public static let maxBackoff: Duration = .seconds(30)

    /// bb's own `BbRealtimeClient` step: ×1.5, capped. A non-positive delay
    /// starts over at `initialBackoff`. The cap is checked before multiplying,
    /// so the multiplication only ever sees a value below 30 s.
    public static func nextBackoff(after current: Duration) -> Duration {
        guard current > .zero else { return initialBackoff }
        guard current < maxBackoff else { return maxBackoff }
        return min(current * 3 / 2, maxBackoff)
    }

    /// `http→ws`, `https→wss`, the path replaced by `/ws`, the query and
    /// fragment dropped. A URL `URLComponents` cannot take apart is returned
    /// unchanged, so the dial fails and the reconnect state names it.
    public static func websocketURL(for serverURL: URL) -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return serverURL }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: break
        }
        components.path = "/ws"
        components.query = nil
        components.fragment = nil
        return components.url ?? serverURL
    }

    static let subscribeMessages = [
        #"{"type":"subscribe","target":{"kind":"thread-list"}}"#,
        #"{"type":"subscribe","target":{"kind":"project-list"}}"#,
    ]

    private let websocketURL: URL
    private let makeTransport: TransportFactory
    private let fetch: @Sendable () async throws -> BBSnapshot
    private let onStatus: (ConnectionStatus) -> Void
    private let onSnapshot: (BBSnapshot) -> Void
    private let onError: (String?) -> Void
    private let clock: any Clock<Duration>
    private let debounce: Duration

    private var running = false
    private var transport: (any WebSocketTransport)?
    /// The open transport has subscribed; fetches are allowed.
    private var isOpen = false
    private var backoff = initialBackoff
    private var generation = 0
    /// Whether `connected` has been reported since the last open.
    private var connectedSinceOpen = false
    private var lastStatus: ConnectionStatus?
    private var fetchInFlight = false
    private var dirty = false
    private var fetchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    public init(
        serverURL: URL,
        makeTransport: @escaping TransportFactory,
        fetch: @escaping @Sendable () async throws -> BBSnapshot,
        onStatus: @escaping (ConnectionStatus) -> Void,
        onSnapshot: @escaping (BBSnapshot) -> Void,
        onError: @escaping (String?) -> Void,
        clock: any Clock<Duration> = ContinuousClock(),
        debounce: Duration = .milliseconds(250)
    ) {
        self.websocketURL = Self.websocketURL(for: serverURL)
        self.makeTransport = makeTransport
        self.fetch = fetch
        self.onStatus = onStatus
        self.onSnapshot = onSnapshot
        self.onError = onError
        self.clock = clock
        self.debounce = debounce
    }

    // MARK: - Lifecycle

    /// Reports `connecting` and dials. Does nothing while already running;
    /// after `stop()` it starts afresh, backoff included.
    public func start() {
        guard !running else { return }
        running = true
        backoff = Self.initialBackoff
        lastStatus = nil
        emitStatus(.connecting)
        connect()
    }

    /// Cancels every timer, drops any fetch still running, and closes the
    /// transport. Nothing reaches a callback after this returns.
    public func stop() {
        guard running else { return }
        running = false
        generation += 1
        resetConnectionState()
        reconnectTask?.cancel()
        reconnectTask = nil
        disposeTransport(code: 1000, reason: "Client closed")
    }

    // MARK: - Connecting

    private func connect() {
        reconnectTask = nil
        let transport = makeTransport(TransportRequest(url: websocketURL))
        self.transport = transport
        transport.onOpen = { [weak self, weak transport] in
            guard let self, self.isCurrent(transport) else { return }
            self.handleOpen()
        }
        transport.onFrame = { [weak self, weak transport] frame in
            guard let self, self.isCurrent(transport) else { return }
            self.handleFrame(frame)
        }
        transport.onClose = { [weak self, weak transport] _ in
            guard let self, self.isCurrent(transport) else { return }
            self.connectionLost()
        }
        // A send that failed may have been a subscribe, and an open socket
        // without its subscriptions would go silent. Start over instead.
        transport.onError = { [weak self, weak transport] _ in
            guard let self, self.isCurrent(transport) else { return }
            self.connectionLost()
        }
        transport.connect()
    }

    private func isCurrent(_ candidate: (any WebSocketTransport)?) -> Bool {
        guard running, let candidate, let transport else { return false }
        return candidate === transport
    }

    private func handleOpen() {
        guard !isOpen, let transport else { return }
        generation += 1
        isOpen = true
        connectedSinceOpen = false
        backoff = Self.initialBackoff
        for message in Self.subscribeMessages {
            transport.send(.text(message))
        }
        // Whatever changed while disconnected was never announced.
        startFetch()
    }

    /// The close path, for a close, a transport error, or a failed fetch:
    /// drop this connection and try again after the current backoff.
    private func connectionLost() {
        guard running else { return }
        generation += 1
        resetConnectionState()
        disposeTransport(code: 1001, reason: "Reconnecting")
        emitStatus(.reconnecting)
        let delay = backoff
        backoff = Self.nextBackoff(after: backoff)
        reconnectTask?.cancel()
        reconnectTask = after(delay) { [weak self] in
            guard let self, self.running else { return }
            self.connect()
        }
    }

    private func resetConnectionState() {
        isOpen = false
        connectedSinceOpen = false
        dirty = false
        fetchInFlight = false
        fetchTask?.cancel()
        fetchTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Leaves the old transport's callbacks in place on purpose: `isCurrent`
    /// is what silences them, so a late one is ignored however it arrives.
    private func disposeTransport(code: Int, reason: String) {
        guard let old = transport else { return }
        transport = nil
        old.close(code: code, reason: reason)
    }

    // MARK: - Invalidations

    private struct Invalidation: Decodable {
        let type: String?
        let entity: String?
    }

    private func handleFrame(_ frame: TransportFrame) {
        guard case .text(let text) = frame,
              let message = try? JSONDecoder().decode(Invalidation.self, from: Data(text.utf8)),
              message.type == "changed",
              message.entity == "thread" || message.entity == "project"
        else { return }
        scheduleFetch()
    }

    /// Coalesces a burst into one fetch `debounce` after its first frame. The
    /// window does not restart on later frames: a running thread appends
    /// events for as long as it runs, and a restarting window would not fetch
    /// until it stopped.
    private func scheduleFetch() {
        guard isOpen, debounceTask == nil else { return }
        debounceTask = after(debounce) { [weak self] in
            guard let self else { return }
            self.debounceTask = nil
            self.startFetch()
        }
    }

    // MARK: - Fetching

    private func startFetch() {
        guard running, isOpen else { return }
        guard !fetchInFlight else {
            dirty = true
            return
        }
        fetchInFlight = true
        dirty = false
        let generation = self.generation
        let fetch = self.fetch
        fetchTask = Task { @MainActor [weak self] in
            let result: Result<BBSnapshot, any Error>
            do {
                result = .success(try await fetch())
            } catch {
                result = .failure(error)
            }
            self?.finishFetch(result, generation: generation)
        }
    }

    private func finishFetch(_ result: Result<BBSnapshot, any Error>, generation: Int) {
        guard running, generation == self.generation else { return }
        fetchInFlight = false
        fetchTask = nil
        switch result {
        case .success(let snapshot):
            onError(nil)
            onSnapshot(snapshot)
            if !connectedSinceOpen {
                connectedSinceOpen = true
                emitStatus(.connected)
            }
            // The invalidations it absorbed already waited out their window,
            // so the follow-up starts now rather than after another one.
            if dirty { startFetch() }
        case .failure(let error):
            onError(errorText(error))
            connectionLost()
        }
    }

    // MARK: - Helpers

    private func emitStatus(_ status: ConnectionStatus) {
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus(status)
    }

    private func after(_ delay: Duration, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        clock.timer(delay: delay, body)
    }
}

extension Clock where Duration == Swift.Duration {
    /// Runs `body` on the main actor once `delay` has passed on this clock,
    /// unless the returned task is cancelled first. The deadline is fixed
    /// here, when the timer is armed, not when the task first runs, so how
    /// soon the task gets scheduled cannot stretch the delay.
    fileprivate func timer(delay: Duration, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let deadline = now.advanced(by: delay)
        return Task { @MainActor in
            do {
                try await sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            // The sleep can end and this task wait its turn on the main actor
            // while `stop` or a reconnect cancels it; that cancel still wins.
            guard !Task.isCancelled else { return }
            body()
        }
    }
}

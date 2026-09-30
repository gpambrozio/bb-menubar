import Foundation

/// Keeps the snapshot current from bb's `/ws` invalidations.
///
/// bb pushes no data over `/ws`, only "this changed" notices, so the session
/// is a trigger for `fetch`: once on every open (invalidations sent while
/// disconnected are lost), and after a burst of `changed` frames for a thread
/// or a project. Everything else on the socket is ignored.
///
/// Fetches are capped at one start per `minFetchInterval` (1 s). A running
/// bb thread announces `events-appended` for as long as it runs, so without
/// the cap every debounce window would end in a fetch, back to back. A fetch
/// that is owed sooner waits out the rest of the interval instead. The fetch
/// on open is exempt: it starts at once, and starts the interval again.
///
/// Three rules keep a result from landing on the wrong state:
/// - At most one fetch runs per connection. An invalidation that arrives while
///   one runs, or while the interval holds fetches back, sets `dirty`, and
///   exactly one more fetch follows.
/// - Every fetch carries the `generation` it started in. Open, loss of the
///   connection, and `stop` each start a new generation, and a result from an
///   older one is dropped whole: no snapshot, no error, no status.
/// - A callback from a transport that is no longer `transport` is ignored, by
///   identity, so a socket's late close cannot tear down its successor.
///
/// A connection counts as good once its first fetch succeeds, not when the
/// socket opens: that is what resets the backoff and reports `connected`. A
/// bb that accepts the socket and then refuses every fetch (authentication, a
/// shape this build cannot read) is retried at a growing interval, not every
/// second. A socket that fails before it opens names why through `onError`,
/// since that is what a moved or refused `/ws` looks like; one lost after it
/// opened is a bb restart, and only reports `reconnecting`.
///
/// A target may need headers that cannot be fixed in advance: a remote bb's
/// `/ws` upgrade needs a session cookie minted just before it (see
/// `ConnectSession`). `prepareDial`, when given, runs before every dial and
/// its headers are merged over the static ones. Its failure is a dial that
/// failed before it opened: named through `onError` as it is (its text is
/// already a sentence), then the same reconnect backoff. A local target
/// passes none, and dials at once.
///
/// Failure text reaches `onError` without any value of the dial's headers in
/// it, since a close reason or transport error could echo one.
///
/// Every callback fires on the main actor, and a callback may call `stop()`:
/// nothing further is delivered once it has. Timers use the injected clock.
///
/// The owner must call `stop()` when done with a session. There is no cleanup
/// in `deinit`: the timers and the fetch hold the session only weakly, but the
/// transport stays open until `stop()` closes it.
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

    /// Extra headers for one dial, asked for before each. Must finish in
    /// bounded time; production's is one `URLSessionHTTPClient` request.
    public typealias DialPreparation = @Sendable () async throws -> [String: String]

    /// The `/ws` URL and the target's headers, the same for every dial. Kept
    /// as a `TransportRequest`, whose description and mirror name header
    /// fields and never their values, so a dump of the session does not
    /// carry the credential.
    private let baseRequest: TransportRequest
    private let prepareDial: DialPreparation?
    private let makeTransport: TransportFactory
    /// Must finish, with a value or an error, in bounded time: while it runs,
    /// every invalidation only marks the session `dirty`, so a fetch that
    /// never returns stalls the snapshot until the socket drops. Production
    /// passes `BBAPI.fetchSnapshot`: up to 26 sequential requests (the
    /// projects and at most 25 thread pages), each bounded as a whole by
    /// `URLSessionHTTPClient`'s 30 s resource timeout, and the first that
    /// fails ends the fetch. So a fetch is bounded, though a bb that answers
    /// every page just inside the timeout can hold it for minutes.
    private let fetch: @Sendable () async throws -> BBSnapshot
    private let onStatus: (ConnectionStatus) -> Void
    private let onSnapshot: (BBSnapshot) -> Void
    private let onError: (String?) -> Void
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private let minFetchInterval: Duration

    private var running = false
    private var transport: (any WebSocketTransport)?
    /// The open transport has subscribed; fetches are allowed.
    private var isOpen = false
    private var backoff = initialBackoff
    private var generation = 0
    /// Whether a fetch has succeeded since the last open, which is when
    /// `connected` is reported and the backoff resets.
    private var connectedSinceOpen = false
    private var lastStatus: ConnectionStatus?
    private var fetchInFlight = false
    private var dirty = false
    private var fetchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// Armed for `minFetchInterval` whenever a fetch starts. While it is set,
    /// a debounced or follow-up fetch only marks the session `dirty`, and the
    /// timer starts it when it fires.
    private var intervalTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// The `prepareDial` call in flight, if any.
    private var prepareTask: Task<Void, Never>?
    /// Numbers each `prepareDial` call, so an answer that `stop()` or a newer
    /// dial has overtaken is dropped.
    private var dialAttempt = 0
    /// The current dial's request, whose header values are scrubbed from any
    /// failure text before it is reported.
    private var dialRequest: TransportRequest

    /// `headers` ride on every `/ws` upgrade, as `BBAPI`'s ride on every
    /// request: none for this Mac's own bb, the relay's credential for a
    /// remote one. No `Origin` is added here. `prepareDial`'s headers ride
    /// on the one dial they were prepared for, over `headers`.
    public init(
        serverURL: URL,
        headers: [String: String] = [:],
        prepareDial: DialPreparation? = nil,
        makeTransport: @escaping TransportFactory,
        fetch: @escaping @Sendable () async throws -> BBSnapshot,
        onStatus: @escaping (ConnectionStatus) -> Void,
        onSnapshot: @escaping (BBSnapshot) -> Void,
        onError: @escaping (String?) -> Void,
        clock: any Clock<Duration> = ContinuousClock(),
        debounce: Duration = .milliseconds(250),
        minFetchInterval: Duration = .seconds(1)
    ) {
        self.baseRequest = TransportRequest(url: Self.websocketURL(for: serverURL), headers: headers)
        self.dialRequest = baseRequest
        self.prepareDial = prepareDial
        self.makeTransport = makeTransport
        self.fetch = fetch
        self.onStatus = onStatus
        self.onSnapshot = onSnapshot
        self.onError = onError
        self.clock = clock
        self.debounce = debounce
        self.minFetchInterval = minFetchInterval
    }

    // MARK: - Lifecycle

    /// Reports `connecting` and dials. Does nothing while already running;
    /// after `stop()` it starts afresh, backoff included.
    public func start() {
        guard !running else { return }
        running = true
        backoff = Self.initialBackoff
        lastStatus = nil
        let generation = self.generation
        emitStatus(.connecting)
        // `onStatus` may have stopped the session, or stopped and started it
        // again (which dialled already): either way this dial is not wanted.
        guard running, generation == self.generation else { return }
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
        cancelPreparation()
        disposeTransport(code: 1000, reason: "Client closed")
    }

    // MARK: - Connecting

    /// Dials at once, or once `prepareDial` has answered.
    private func connect() {
        reconnectTask = nil
        // Only ever one socket: never leave one open behind a new one.
        disposeTransport(code: 1001, reason: "Reconnecting")
        cancelPreparation()
        dialRequest = baseRequest
        guard let prepareDial else {
            dial(extraHeaders: [:])
            return
        }
        let attempt = dialAttempt
        prepareTask = Task { @MainActor [weak self] in
            let result: Result<[String: String], any Error>
            do {
                result = .success(try await prepareDial())
            } catch {
                result = .failure(error)
            }
            self?.finishPreparing(result, attempt: attempt)
        }
    }

    /// Drops any `prepareDial` call in flight; its answer will be ignored.
    private func cancelPreparation() {
        dialAttempt += 1
        prepareTask?.cancel()
        prepareTask = nil
    }

    private func finishPreparing(_ result: Result<[String: String], any Error>, attempt: Int) {
        guard running, attempt == dialAttempt else { return }
        prepareTask = nil
        switch result {
        case .success(let extraHeaders):
            dial(extraHeaders: extraHeaders)
        case .failure(let error):
            let text = scrubbed(errorText(error))
            connectionLost()
            guard running else { return }
            onError(text)
        }
    }

    private func dial(extraHeaders: [String: String]) {
        dialRequest = TransportRequest(
            url: baseRequest.url,
            headers: baseRequest.headers.merging(extraHeaders) { _, prepared in prepared }
        )
        let transport = makeTransport(dialRequest)
        self.transport = transport
        transport.onOpen = { [weak self, weak transport] in
            guard let self, self.isCurrent(transport) else { return }
            self.handleOpen()
        }
        transport.onFrame = { [weak self, weak transport] frame in
            guard let self, self.isCurrent(transport) else { return }
            self.handleFrame(frame)
        }
        transport.onClose = { [weak self, weak transport] close in
            guard let self, self.isCurrent(transport) else { return }
            self.transportFailed(Self.describe(close))
        }
        // A send that failed may have been a subscribe, and an open socket
        // without its subscriptions would go silent. Start over instead.
        transport.onError = { [weak self, weak transport] message in
            guard let self, self.isCurrent(transport) else { return }
            self.transportFailed(message)
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
        for message in Self.subscribeMessages {
            transport.send(.text(message))
        }
        // Whatever changed while disconnected was never announced, so this
        // one does not wait for the interval.
        startFetch(throttled: false)
    }

    /// A close or an error from the current transport. Before the socket
    /// opened, the reason is the only sign of why bb cannot be reached, so it
    /// is named; after, it is a restart, and `reconnecting` says enough.
    private func transportFailed(_ reason: String) {
        let wasOpen = isOpen
        let text = scrubbed("bb live updates: " + reason)
        connectionLost()
        guard !wasOpen, running else { return }
        onError(text)
    }

    /// `text` without any value of the current dial's headers in it.
    private func scrubbed(_ text: String) -> String {
        scrubbingHeaderValues(dialRequest.headers, from: text)
    }

    static func describe(_ close: TransportClose) -> String {
        let reason = close.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty
            ? "the connection closed before it opened (code \(close.code))"
            : "\(reason) (code \(close.code))"
    }

    /// The close path, for a close, a transport error, or a failed fetch:
    /// drop this connection and try again after the current backoff.
    private func connectionLost() {
        guard running else { return }
        generation += 1
        let generation = self.generation
        resetConnectionState()
        disposeTransport(code: 1001, reason: "Reconnecting")
        emitStatus(.reconnecting)
        // As in `start`: a stop from `onStatus` has already cancelled the
        // reconnect, so arming one now would outlive it and dial into
        // whatever session starts next.
        guard running, generation == self.generation else { return }
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
        intervalTask?.cancel()
        intervalTask = nil
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

    /// Starts a fetch now, or, with one running or the interval since the
    /// last start not yet over, owes one (`dirty`). Only the fetch on open
    /// passes `throttled: false`.
    private func startFetch(throttled: Bool = true) {
        guard running, isOpen else { return }
        guard !fetchInFlight, !(throttled && intervalTask != nil) else {
            dirty = true
            return
        }
        fetchInFlight = true
        dirty = false
        // Every frame so far is covered by this fetch, including those of a
        // window that has not closed yet.
        debounceTask?.cancel()
        debounceTask = nil
        intervalTask?.cancel()
        intervalTask = after(minFetchInterval) { [weak self] in
            guard let self else { return }
            self.intervalTask = nil
            // A fetch still running starts the owed one when it finishes.
            if self.dirty, !self.fetchInFlight { self.startFetch() }
        }
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

    /// Every callback can re-enter through `stop()`, so the result is checked
    /// against the session again after each one.
    private func finishFetch(_ result: Result<BBSnapshot, any Error>, generation: Int) {
        func current() -> Bool { running && generation == self.generation }
        guard current() else { return }
        fetchInFlight = false
        fetchTask = nil
        switch result {
        case .success(let snapshot):
            let firstSinceOpen = !connectedSinceOpen
            if firstSinceOpen {
                connectedSinceOpen = true
                backoff = Self.initialBackoff
            }
            onError(nil)
            guard current() else { return }
            onSnapshot(snapshot)
            guard current() else { return }
            if firstSinceOpen {
                emitStatus(.connected)
                guard current() else { return }
            }
            // The invalidations it absorbed already waited out their window,
            // so the follow-up starts as soon as the interval allows rather
            // than after another window.
            if dirty { startFetch() }
        case .failure(let error):
            onError(errorText(error))
            guard current() else { return }
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

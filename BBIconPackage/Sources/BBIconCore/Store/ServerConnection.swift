import Foundation

/// Which bb server the tray talks to, and the realtime session and API that
/// talk to it. `RuntimeSession` says where bb is; this turns each answer into
/// the right session, and writes what that session reports into the store.
///
/// A server change is ordered so nothing from the old server can land on the
/// new one's state: the old session is stopped before anything else (a stopped
/// session delivers nothing, however late), its `.fetch` and `.open` error rows
/// go with it, and `connecting` then drops its rows from the store before the
/// new session dials.
///
/// Realtime sessions have no cleanup in `deinit`, so the owner must call
/// `stop()` when done: it stops the current session, if any.
@MainActor
public final class ServerConnection {
    private let store: ThreadStore
    /// One client for every server, shared by every `BBAPI`:
    /// `URLSessionHTTPClient` never invalidates its session, so one per server
    /// change would leak one per bb relaunch.
    private let http: any HTTPClient
    private let makeTransport: TransportFactory
    private let clock: any Clock<Duration>

    /// The realtime session, its API, and the server both talk to. Set and
    /// cleared together.
    private var session: RealtimeSession?
    private var api: BBAPI?
    public private(set) var serverURL: URL?
    /// Numbers open-thread requests, so a slow request's answer cannot replace
    /// the answer to a later one in the `.open` error row, and an answer from
    /// a server that has since gone away is dropped.
    private var openRequests = 0

    public init(
        store: ThreadStore,
        http: any HTTPClient,
        makeTransport: @escaping TransportFactory,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.store = store
        self.http = http
        self.makeTransport = makeTransport
        self.clock = clock
    }

    /// Follows `RuntimeSession`'s answer: connects to a server that is new,
    /// leaves one already in use alone, and stops when bb is not running.
    public func apply(_ resolution: RuntimeResolution) {
        switch resolution {
        case .running(let info):
            store.setError(.runtime, nil)
            // The same server as before is a poll or a re-check that found bb
            // where it was; the live session already covers it.
            guard info.serverURL != serverURL else { return }
            connect(to: info.serverURL)
        case .notRunning(let error):
            stop()
            store.setStatus(.notRunning)
            store.setError(.runtime, error)
        }
    }

    /// Stops and drops the realtime session. Its `.fetch` and `.open` errors
    /// go with it: those rows describe a server that is no longer the one in
    /// use, and the next session sets them again if the new server fails the
    /// same way. Bumping `openRequests` drops the answer of an open request
    /// still in flight to the old server, so it cannot write `.open` later.
    /// Idempotent.
    public func stop() {
        guard let session else { return }
        session.stop()
        self.session = nil
        api = nil
        serverURL = nil
        openRequests += 1
        store.setError(.fetch, nil)
        store.setError(.open, nil)
    }

    /// Asks bb to show a thread, after `prepare` (bringing bb forward) says
    /// it may. The request is what navigates; `prepare` is what makes the
    /// navigation visible, so it is awaited first, and a `false` from it sends
    /// no request. Its answer, or its failure, is the `.open` error row —
    /// unless a later request, or a server change, has superseded it by then.
    ///
    /// The request is numbered now, when it is asked for, not when the task
    /// gets to run. The returned task is for tests to await.
    @discardableResult
    public func openThread(
        _ threadId: String,
        prepare: @escaping @MainActor () async -> Bool
    ) -> Task<Void, Never> {
        openRequests += 1
        let request = openRequests
        return Task { [weak self] in
            guard await prepare(), let self else { return }
            // No server known means bb is not running or not connected yet,
            // so all a click can do is what `prepare` already did.
            guard request == self.openRequests, let api = self.api else { return }
            let failure: String?
            do {
                try await api.openThread(threadId)
                failure = nil
            } catch {
                failure = errorText(error)
            }
            guard request == self.openRequests else { return }
            self.store.setError(.open, failure)
        }
    }

    /// bb relaunched on a new port, or appeared for the first time.
    private func connect(to url: URL) {
        stop()
        store.setStatus(.connecting)
        let api = BBAPI(serverURL: url, http: http)
        let store = self.store
        let session = RealtimeSession(
            serverURL: url,
            makeTransport: makeTransport,
            fetch: { try await api.fetchSnapshot() },
            onStatus: { store.setStatus($0) },
            onSnapshot: { store.apply($0) },
            onError: { store.setError(.fetch, $0) },
            clock: clock
        )
        self.session = session
        self.api = api
        serverURL = url
        session.start()
    }
}

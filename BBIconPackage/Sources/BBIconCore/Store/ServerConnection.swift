import Foundation

/// The one bb server the tray watches: where it is, and what to send with
/// every request to it.
enum ServerTarget: Equatable {
    /// This Mac's own bb, from the runtime file. Loopback, no headers.
    case local(URL)
    /// The paired remote bb, through the getbb.app relay, which accepts the
    /// pairing's credential in `x-bb-connect-machine`. A new pairing is a new
    /// target even at the same address: its credential is what is sent.
    case remote(Pairing)

    var url: URL {
        switch self {
        case .local(let url): url
        case .remote(let pairing): pairing.serverURL
        }
    }

    var headers: [String: String] {
        switch self {
        case .local: [:]
        case .remote(let pairing): [ConnectHealth.credentialHeader: pairing.credential]
        }
    }

    /// What the status line calls it: nil for this Mac's bb, which it calls
    /// "bb".
    var name: String? {
        switch self {
        case .local: nil
        case .remote(let pairing): pairing.handle
        }
    }
}

/// Which bb server the tray talks to, and the realtime session and API that
/// talk to it. Two inputs decide it: `RuntimeSession`'s answer about this
/// Mac's bb, through `apply(_:)`, and the stored pairing, through
/// `setPairing(_:)`. This Mac's bb always wins; the pairing is used only while
/// no local bb is running; with neither there is no server. That target is
/// turned into the right session, and what that session reports is written
/// into the store.
///
/// A server change is ordered so nothing from the old server can land on the
/// new one's state: the old session is stopped before anything else (a stopped
/// session delivers nothing, however late), its `.fetch` and `.open` error rows
/// go with it, `connecting` then drops its rows from the store, and only then
/// is the new server's name set, so no state ever shows one server's rows
/// under another's name. The new session dials last.
///
/// For a remote target, a failing fetch or socket is followed by a
/// `ConnectHealth` probe of the relay, whose finding names the failure in
/// the `.fetch` row (see `probeIfRemote`).
///
/// Realtime sessions have no cleanup in `deinit`, so the owner must call
/// `stop()` when done: it stops the current session, if any.
@MainActor
public final class ServerConnection {
    private let store: ThreadStore
    /// One client for every server, shared by every `BBAPI` and every probe:
    /// `URLSessionHTTPClient` never invalidates its session, so one per server
    /// change would leak one per bb relaunch.
    private let http: any HTTPClient
    private let makeTransport: TransportFactory
    private let clock: any Clock<Duration>

    /// The latest answer about this Mac's bb. Nil until the first one, and
    /// until then there is no target, not even the pairing's: the runtime
    /// session answers as soon as it has read the file, and dialling the
    /// remote bb first would only drop it again when the local one is found.
    private var runtime: RuntimeResolution?
    private var pairing: Pairing?

    /// The realtime session, its API, and the server both talk to. Set and
    /// cleared together.
    private var session: RealtimeSession?
    private var api: BBAPI?
    private var target: ServerTarget?
    /// Numbers open-thread requests, so a slow request's answer cannot replace
    /// the answer to a later one in the `.open` error row, and an answer from
    /// a server that has since gone away is dropped.
    private var openRequests = 0

    /// What the session last said was wrong with a fetch or its socket, as it
    /// said it. The `.fetch` row shows this unless a probe named it better.
    private var sessionError: String?
    /// The latest probe's error row for the current trouble, or nil when there
    /// is none, the probe found the server live, or none has answered yet.
    private var probeMessage: String?
    /// Bumped whenever a probe's answer stops describing the current trouble:
    /// the target changed, or the session fetched successfully. An answer
    /// carrying an older epoch is dropped.
    private var probeEpoch = 0
    /// The probe in flight, if any. Only one runs at a time.
    private var probeTask: Task<Void, Never>?

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

    /// The address of the server in use, or nil when there is none.
    public var serverURL: URL? { target?.url }

    /// Follows `RuntimeSession`'s answer. A running local bb is the target;
    /// one that is not running hands over to the pairing, if there is one.
    /// The `.runtime` row says only whether the runtime file could be read,
    /// whichever server ends up in use.
    public func apply(_ resolution: RuntimeResolution) {
        runtime = resolution
        switch resolution {
        case .running:
            store.setError(.runtime, nil)
        case .notRunning(let error):
            store.setError(.runtime, error)
        }
        reconcile()
    }

    /// The stored pairing, or nil once there is none (never paired, or
    /// forgotten). It becomes the target only while no local bb is running.
    public func setPairing(_ pairing: Pairing?) {
        self.pairing = pairing
        store.setPaired(pairing?.handle)
        reconcile()
    }

    /// The server the two inputs choose: this Mac's bb, else the pairing's,
    /// else none.
    private var chosenTarget: ServerTarget? {
        switch runtime {
        case nil:
            return nil
        case .running(let info):
            return .local(info.serverURL)
        case .notRunning:
            return pairing.map { .remote($0) }
        }
    }

    /// Moves to the chosen target. The same target as before is a poll, a
    /// re-check, or an unrelated input changing, and the live session already
    /// covers it. No target at all is settled every time, which costs nothing
    /// when it already is.
    private func reconcile() {
        guard let next = chosenTarget else {
            stop()
            store.setStatus(.notRunning)
            store.setServerName(nil)
            return
        }
        guard next != target else { return }
        connect(to: next)
    }

    /// Stops and drops the realtime session. Its `.fetch` and `.open` errors
    /// go with it: those rows describe a server that is no longer the one in
    /// use, and the next session sets them again if the new server fails the
    /// same way. Bumping `openRequests` drops the answer of an open request
    /// still in flight to the old server, so it cannot write `.open` later,
    /// and ending the trouble drops a probe's answer the same way.
    /// Idempotent.
    public func stop() {
        guard let session else { return }
        session.stop()
        self.session = nil
        api = nil
        target = nil
        openRequests += 1
        endTrouble()
        sessionError = nil
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

    /// A new server: bb relaunched on a new port or appeared for the first
    /// time, the pairing took over from a local bb or handed back to one.
    private func connect(to target: ServerTarget) {
        stop()
        store.setStatus(.connecting)
        store.setServerName(target.name)
        let api = BBAPI(serverURL: target.url, headers: target.headers, http: http)
        let store = self.store
        // A stopped session delivers nothing, so these reach `self` only
        // while this session is the current one.
        let session = RealtimeSession(
            serverURL: target.url,
            headers: target.headers,
            makeTransport: makeTransport,
            fetch: { try await api.fetchSnapshot() },
            onStatus: { [weak self] in self?.sessionReported($0) },
            onSnapshot: { store.apply($0) },
            onError: { [weak self] in self?.sessionFailed($0) },
            clock: clock
        )
        self.session = session
        self.api = api
        self.target = target
        session.start()
    }

    // MARK: - Naming a remote failure

    private func sessionReported(_ status: ConnectionStatus) {
        store.setStatus(status)
        // Losing the connection is a failure even when nothing names it: a
        // socket that closes after it opened reports only this.
        if status == .reconnecting { probeIfRemote() }
    }

    /// The session's fetch or socket error, or nil after a fetch that
    /// succeeded, which ends the trouble.
    private func sessionFailed(_ message: String?) {
        sessionError = message
        if message == nil {
            endTrouble()
        } else if store.state.status != .connected {
            // A fetch that fails while connected is followed at once by
            // `reconnecting`, which probes; this is the path for the attempts
            // after that, which fail without the status changing again.
            probeIfRemote()
        }
        showFetchError()
    }

    /// The `.fetch` row: the probe's finding when it named one, else the
    /// session's own error.
    ///
    /// The finding replaces the row rather than getting an `ErrorSource` of
    /// its own, because it is the same failure named better: the design's
    /// table has one row per failure, which is the original error only when
    /// the relay says the server is live. Two rows would say one thing twice,
    /// in two voices. It stays `.fetch`'s, so a server change clears it the
    /// way it clears the error it replaced.
    private func showFetchError() {
        store.setError(.fetch, probeMessage ?? sessionError)
    }

    /// Asks the relay what is wrong, for a remote target that is failing.
    ///
    /// At most one probe runs at a time, and one starts only on a failure the
    /// session reports — a lost connection, or a failed fetch or dial while
    /// not connected — so probes can never outpace the session's own
    /// reconnect backoff, and none runs while connected. Each failed attempt
    /// may probe again once the last probe has answered: a finding describes
    /// the relay at one moment, and an outage that changes shape (the network
    /// comes back, the server is still asleep) should be named as it is now,
    /// not as it first was.
    ///
    /// Until a probe answers, the last finding for this trouble stands. An
    /// answer is dropped if the target changed or a fetch succeeded since it
    /// was asked, not merely because the session re-dialled: a failed re-dial
    /// is the same trouble, and dropping those answers would starve the row
    /// whenever the relay answers slower than the backoff. A local target is
    /// never probed: it has no relay.
    private func probeIfRemote() {
        guard case .remote(let pairing) = target, probeTask == nil else { return }
        let epoch = probeEpoch
        let http = self.http
        probeTask = Task { [weak self] in
            let finding = await ConnectHealth.probe(pairing: pairing, http: http)
            self?.probeAnswered(finding, handle: pairing.handle, epoch: epoch)
        }
    }

    private func probeAnswered(_ finding: ConnectHealthFinding, handle: String, epoch: Int) {
        guard epoch == probeEpoch else { return }
        probeTask = nil
        // `.live` has no message: the session's own error is the one to show.
        probeMessage = finding.message(handle: handle)
        showFetchError()
    }

    /// The failure is over, or no longer this server's: drop the finding and
    /// any probe still running, whose answer would describe it.
    private func endTrouble() {
        probeEpoch += 1
        probeTask?.cancel()
        probeTask = nil
        probeMessage = nil
    }
}

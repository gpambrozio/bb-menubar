import Foundation

/// One complete read of bb: every thread page and the project list, fetched
/// together so the rows and their project names describe the same moment.
public struct BBSnapshot: Equatable, Sendable {
    public let threads: [ThreadRow]
    public let projects: [ProjectRow]
    /// The page ceiling was reached, so `threads` is a subset of bb's list.
    public let truncated: Bool
    /// Rows bb sent that could not be decoded, each named by `LenientList`.
    public let decodeFailures: [String]

    public init(threads: [ThreadRow], projects: [ProjectRow], truncated: Bool, decodeFailures: [String]) {
        self.threads = threads
        self.projects = projects
        self.truncated = truncated
        self.decodeFailures = decodeFailures
    }
}

/// Whether this app has a live view of bb. Only `connected` rows are ever
/// shown; every other state reads as "not connected" and dims the icon.
public enum ConnectionStatus: String, CaseIterable, Sendable {
    case notRunning
    case connecting
    case connected
    case reconnecting
}

/// Who owns an error row. Each source sets and clears only its own, so one
/// part of the app recovering never hides another's failure. The display
/// order is the case order: why bb cannot be found comes before why it cannot
/// be read, which comes before why one click did not land.
public enum ErrorSource: Int, CaseIterable, Sendable {
    /// The runtime file could not be read.
    case runtime
    /// The bb Connect pairing's Keychain item could not be read at launch,
    /// written by a pair, or removed by a Forget. Owned by
    /// `PairingController`; no server change or runtime poll touches it, so
    /// it stays until the next Keychain operation succeeds.
    case pairing
    /// The snapshot fetch failed.
    case fetch
    /// Some rows of the latest snapshot could not be decoded.
    case decode
    /// The last open-thread request failed.
    case open
}

/// Everything the tray draws from, as one value, so a listener sees a
/// consistent whole and the view model is a pure function of it.
public struct BBState: Equatable, Sendable {
    public let status: ConnectionStatus
    public let threads: [ThreadRow]
    /// Project id to name, for the second half of a row's label.
    public let projectNames: [String: String]
    public let truncated: Bool
    /// One message per `ErrorSource` that has one, in `ErrorSource` order.
    public let errors: [String]
    /// The handle of the remote bb being watched, or nil for this Mac's own
    /// bb (and for none). Names the server in the status line.
    public let serverName: String?
    /// The handle of the stored pairing, whether or not it is the server in
    /// use: a local bb wins over it, and the pairing is still there to forget.
    public let paired: String?

    public init(
        status: ConnectionStatus,
        threads: [ThreadRow],
        projectNames: [String: String],
        truncated: Bool,
        errors: [String],
        serverName: String? = nil,
        paired: String? = nil
    ) {
        self.status = status
        self.threads = threads
        self.projectNames = projectNames
        self.truncated = truncated
        self.errors = errors
        self.serverName = serverName
        self.paired = paired
    }

    public static let initial = BBState(status: .notRunning, threads: [], projectNames: [:], truncated: false, errors: [])
}

/// The latest snapshot, the connection state, and the error rows. The
/// realtime session, the runtime session, and the click handler report into
/// it; the tray reads `state` and rebuilds when a listener fires.
@MainActor
public final class ThreadStore {
    public private(set) var state: BBState = .initial

    private var status: ConnectionStatus = .notRunning
    private var threads: [ThreadRow] = []
    private var projectNames: [String: String] = [:]
    private var truncated = false
    private var serverName: String?
    private var paired: String?
    /// Keyed by owner rather than kept as a list, so setting one source's
    /// message can never reorder or replace another's. `state.errors` is
    /// derived from it in `ErrorSource` order.
    private var errors: [ErrorSource: String] = [:]
    private var listeners: [UUID: () -> Void] = [:]

    public init() {}

    /// Leaving `connected` for any reason drops the last connection's rows:
    /// the icon never shows data it cannot vouch for, and a reconnect re-fetches
    /// everything anyway.
    ///
    /// The `.decode` error goes with them. It names rows of a snapshot that is
    /// no longer shown, and keeping it would describe data that is not there;
    /// the next snapshot sets it again if the rows are still unreadable. The
    /// other sources are not about the snapshot and are cleared by their owners.
    public func setStatus(_ status: ConnectionStatus) {
        self.status = status
        if status != .connected {
            threads = []
            projectNames = [:]
            truncated = false
            errors[.decode] = nil
        }
        commit()
    }

    /// Replaces the rows wholesale, so a thread bb dropped cannot linger.
    ///
    /// Accepted in any status: the realtime session delivers the first
    /// snapshot after an open *before* it reports `connected`. The view model
    /// is what refuses to draw rows while not connected, and `setStatus`
    /// clears them whenever the connection is lost.
    public func apply(_ snapshot: BBSnapshot) {
        threads = snapshot.threads
        // Two projects under one id would be bb's bug, not a reason to trap:
        // `Dictionary(uniqueKeysWithValues:)` would. The last one wins.
        projectNames = Dictionary(snapshot.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
        truncated = snapshot.truncated
        errors[.decode] = snapshot.decodeFailures.isEmpty
            ? nil
            : "Some threads could not be read: " + snapshot.decodeFailures.joined(separator: "; ")
        commit()
    }

    /// Sets or, with nil, clears one source's error row.
    public func setError(_ source: ErrorSource, _ message: String?) {
        errors[source] = message
        commit()
    }

    /// Names the server the rows come from: a remote bb's handle, or nil for
    /// this Mac's own. `ServerConnection` sets it after it has left
    /// `connected` for the new server, so no state ever carries one server's
    /// rows under another's name.
    public func setServerName(_ name: String?) {
        serverName = name
        commit()
    }

    /// The stored pairing's handle, or nil when there is none.
    public func setPaired(_ handle: String?) {
        paired = handle
        commit()
    }

    /// Returns the function that unsubscribes.
    public func subscribe(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// Rebuilds `state` and notifies only when it differs, so a redundant
    /// report (the same status twice, an unchanged re-fetch) costs no rebuild.
    private func commit() {
        let next = BBState(
            status: status,
            threads: threads,
            projectNames: projectNames,
            truncated: truncated,
            errors: ErrorSource.allCases.compactMap { errors[$0] },
            serverName: serverName,
            paired: paired
        )
        guard next != state else { return }
        state = next
        for listener in listeners.values { listener() }
    }
}

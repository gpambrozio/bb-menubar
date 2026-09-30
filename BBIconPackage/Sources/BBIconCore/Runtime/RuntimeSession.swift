import Foundation

/// Whether bb is running on this Mac, and where its server is.
public enum RuntimeResolution: Equatable, Sendable {
    case running(RuntimeInfo)
    /// `error` names a runtime file that exists but cannot be used. A missing
    /// file, a dead pid, and bb.app not running are all a plain "not running".
    case notRunning(error: String?)
}

/// Owns the tray's view of bb's runtime file: when to re-read it, what it
/// resolves to, and when that is news.
///
/// It reads once on `start`, then after a watch event or a `refresh()` (both
/// debounced), and on a poll as a safety net for events the watch misses.
///
/// Resolution: file missing → not running; file unreadable or malformed →
/// not running, with the error named; `pid` dead or bb.app not running → not
/// running; otherwise running. `onChange` fires once after every `start()`
/// and after that only when the resolution differs from the last one
/// delivered, so a poll that finds bb where it was is silent and bb
/// relaunching on a new port is not.
///
/// Reads run detached, off the main actor. Every read is numbered, and a
/// result is applied only if it is newer than the last one applied and the
/// session has not stopped since the read began, so a slow read cannot land
/// over a newer answer or after `stop()`.
///
/// Every callback fires on the main actor. Timers use the injected clock.
@MainActor
public final class RuntimeSession {
    private let readFile: @Sendable () throws -> Data?
    private let isProcessAlive: (Int32) -> Bool
    private let isAppRunning: () -> Bool
    private let watch: (@escaping () -> Void) -> () -> Void
    private let afterRead: (() -> Void)?
    private let onChange: (RuntimeResolution) -> Void
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private let pollInterval: Duration

    private var running = false
    private var lastDelivered: RuntimeResolution?
    private var stopWatching: (() -> Void)?
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// The number of the most recent read started.
    private var readsStarted = 0
    /// Results numbered at or below this are dropped: already superseded, or
    /// started before the last `stop()`.
    private var appliedThrough = 0

    /// - Parameters:
    ///   - readFile: the runtime file's bytes, or nil when it does not exist.
    ///     Runs detached; a throw is reported as a named error.
    ///   - isProcessAlive: whether the file's `pid` is a live process.
    ///   - isAppRunning: whether bb.app is running.
    ///   - watch: starts watching the file; returns the stop function.
    ///   - afterRead: runs after every read that is applied, failed ones
    ///     included. Production re-attaches the directory watch here, so a
    ///     `~/.bb` that appears mid-session is watched from the next read on.
    ///   - pollInterval: safety net for events the watch misses. Zero disables it.
    public init(
        readFile: @escaping @Sendable () throws -> Data?,
        isProcessAlive: @escaping (Int32) -> Bool,
        isAppRunning: @escaping () -> Bool,
        watch: @escaping (@escaping () -> Void) -> () -> Void,
        afterRead: (() -> Void)? = nil,
        onChange: @escaping (RuntimeResolution) -> Void,
        clock: any Clock<Duration> = ContinuousClock(),
        debounce: Duration = .milliseconds(300),
        pollInterval: Duration = .seconds(30)
    ) {
        self.readFile = readFile
        self.isProcessAlive = isProcessAlive
        self.isAppRunning = isAppRunning
        self.watch = watch
        self.afterRead = afterRead
        self.onChange = onChange
        self.clock = clock
        self.debounce = debounce
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    /// Starts watching and polling, and reads at once. Does nothing while
    /// already running; after `stop()` it starts afresh, and its first read
    /// is delivered even if it matches what was delivered before.
    public func start() {
        guard !running else { return }
        running = true
        lastDelivered = nil
        stopWatching = watch { [weak self] in self?.refresh() }
        schedulePoll()
        startRead()
    }

    /// Re-reads `debounce` after the first call of a burst. The window does
    /// not restart on later calls, so a steady stream of events cannot hold
    /// the read off indefinitely. The coordinator calls this when bb.app
    /// launches or terminates; the watch calls it when the file changes.
    public func refresh() {
        guard running, debounceTask == nil else { return }
        debounceTask = clock.timer(delay: debounce) { [weak self] in
            guard let self, self.running else { return }
            self.debounceTask = nil
            self.startRead()
        }
    }

    /// Cancels the timers, detaches the watch, and drops any read still in
    /// flight. Nothing reaches a callback after this returns.
    public func stop() {
        guard running else { return }
        running = false
        appliedThrough = readsStarted
        debounceTask?.cancel()
        debounceTask = nil
        pollTask?.cancel()
        pollTask = nil
        stopWatching?()
        stopWatching = nil
    }

    // MARK: - Reading

    private func schedulePoll() {
        guard pollInterval > .zero else { return }
        pollTask = clock.timer(delay: pollInterval) { [weak self] in
            guard let self, self.running else { return }
            self.schedulePoll()
            self.startRead()
        }
    }

    private func startRead() {
        readsStarted += 1
        let number = readsStarted
        let readFile = self.readFile
        Task { @MainActor [weak self] in
            // Detached so the file system call never runs on the main actor,
            // where it would stall the menu bar behind a slow disk.
            let outcome = await Task.detached { Result { try readFile() } }.value
            self?.finishRead(outcome, number: number)
        }
    }

    private func finishRead(_ outcome: Result<Data?, any Error>, number: Int) {
        guard running, number > appliedThrough else { return }
        appliedThrough = number
        let resolution = resolve(outcome)
        if resolution != lastDelivered {
            lastDelivered = resolution
            onChange(resolution)
        }
        // `onChange` may have stopped the session.
        guard running else { return }
        afterRead?()
    }

    private func resolve(_ outcome: Result<Data?, any Error>) -> RuntimeResolution {
        let data: Data
        switch outcome {
        case .failure(let error):
            return .notRunning(error: RuntimeFileError.unreadable(errorText(error)).message)
        case .success(nil):
            return .notRunning(error: nil)
        case .success(let contents?):
            data = contents
        }
        let info: RuntimeInfo
        do {
            info = try RuntimeFile.parse(data)
        } catch {
            return .notRunning(error: errorText(error))
        }
        // bb killed without cleaning up leaves the file behind. Its pid is
        // dead, or reused by something else while bb.app is not running;
        // either way there is no server to dial.
        guard isProcessAlive(info.pid), isAppRunning() else { return .notRunning(error: nil) }
        return .running(info)
    }
}

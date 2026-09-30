import AppKit
import BBIconCore
import ServiceManagement
import SwiftUI

/// Wiring, and only wiring. Every decision this reads from belongs to
/// `BBIconCore`: the runtime session decides whether bb is running and where,
/// the server connection follows it with a realtime session, the store holds
/// the state, and the view model turns it into a menu. What lives here is what
/// genuinely needs AppKit — `NSWorkspace`, the login item, alerts — plus the
/// object graph that connects them.
///
/// Neither session has cleanup in `deinit`, so `stop()` stops the runtime
/// session and the server connection (which stops its realtime session)
/// explicitly.
@MainActor
@Observable
final class AppCoordinator {
    private(set) var model: TrayViewModel = .empty
    private(set) var loginItemEnabled = false

    /// The bb desktop app.
    nonisolated static let bbBundleID = "dev.bb.desktop"

    @ObservationIgnored private let store: ThreadStore
    @ObservationIgnored private let connection: ServerConnection
    @ObservationIgnored private let watcher: DirectoryWatcher
    @ObservationIgnored private var runtimeSession: RuntimeSession?
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var unsubscribe: (() -> Void)?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// Renders are coalesced: a reconnect lands as several store writes in a
    /// row, and rebuilding the menu for each is work nobody sees.
    private static let rebuildDebounce = Duration.milliseconds(120)

    init() {
        let store = ThreadStore()
        self.store = store
        // One HTTP client for the app's lifetime, shared by every server.
        connection = ServerConnection(
            store: store,
            http: URLSessionHTTPClient(),
            makeTransport: { URLSessionWebSocketTransport(request: $0) }
        )
        watcher = DirectoryWatcher(
            // Throws while `~/.bb` does not exist, so the watcher stays
            // unattached and the next read retries through `ensureAttached`,
            // rather than FSEvents watching a path that is not there.
            resolveDir: { try Self.runtimeDirectory() },
            open: { dir, onChange, onError in
                try FSEventsWatch.open(
                    directory: dir,
                    include: { RuntimeFile.isRuntimeFileEvent($0) },
                    onChange: onChange,
                    onError: onError
                )
            }
        )
        runtimeSession = RuntimeSession(
            readFile: { try AppCoordinator.readRuntimeFile() },
            // EPERM means the process exists but belongs to someone else:
            // alive, as far as "is bb's pid dead" is concerned.
            isProcessAlive: { pid in kill(pid, 0) == 0 || errno == EPERM },
            isAppRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bbBundleID).isEmpty },
            watch: { [watcher] onChange in watcher.watch(onChange) },
            // A read that ran means `~/.bb` may exist now even if it did not
            // at launch, which is what makes installing bb mid-session take
            // effect on the next read rather than never.
            afterRead: { [watcher] in watcher.ensureAttached() },
            onChange: { [weak self] resolution in self?.connection.apply(resolution) }
        )
    }

    func start() {
        guard !started else { return }
        started = true
        unsubscribe = store.subscribe { [weak self] in self?.scheduleRebuild() }
        observeBBLaunches()
        refreshLoginItem()
        rebuild()
        runtimeSession?.start()
    }

    /// Idempotent: quitting from the menu calls it, and so does the app
    /// delegate on termination.
    func stop() {
        runtimeSession?.stop()
        connection.stop()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers = []
        rebuildTask?.cancel()
        rebuildTask = nil
        unsubscribe?()
        unsubscribe = nil
    }

    // MARK: - Menu actions

    /// Brings bb forward, then asks it to show the thread. The order, and
    /// which answer may land in the error row, is `ServerConnection`'s.
    func openThread(_ row: TrayThreadRow) {
        connection.openThread(row.threadId, prepare: { [weak self] in
            await self?.activateBB() ?? false
        })
    }

    /// Activates bb, launching it when it is not running.
    func openApp() {
        Task { [weak self] in _ = await self?.activateBB() }
    }

    func showError(_ detail: String) {
        report(title: "bb Icon — error", detail: detail, action: AlertAction(title: "Open bb") { [weak self] in
            self?.openApp()
        })
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                // Registering can succeed and still leave the item off until
                // the user approves it, which from the checkbox looks like a
                // click that did nothing.
                if SMAppService.mainApp.status == .requiresApproval {
                    report(
                        title: "bb Icon — the login item needs your approval",
                        detail: "Allow bb Icon in System Settings › General › Login Items to start it at login.",
                        action: AlertAction(title: "Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                    )
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // `swift run` has no bundle to register, and a user can decline in
            // System Settings. Neither is worth killing the tray over.
            report(title: "bb Icon — could not change the login item", detail: errorText(error))
        }
        refreshLoginItem()
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - bb's lifecycle

    /// bb.app launching or quitting is when its runtime file becomes true or
    /// stale, so both prompt a re-read rather than waiting for the poll.
    private func observeBBLaunches() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bbBundleID else { return }
                // Delivered on the main queue, as asked for above.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.runtimeSession?.refresh()
                }
            }
            workspaceObservers.append(observer)
        }
    }

    // MARK: - Internals

    /// Opens bb.app: activates it when it runs, launches it when it does not.
    /// Returns once AppKit has answered, true when bb is up. A failure is an
    /// alert, like every other action that could not happen, because a menu
    /// row that silently does nothing reads as a broken app.
    private func activateBB() async -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bbBundleID) else {
            report(
                title: "bb Icon — could not open bb",
                detail: "bb is not installed. Install the bb desktop app to open threads from the menu bar."
            )
            return false
        }
        // Only the failure text crosses back: the `NSRunningApplication` the
        // completion also carries is not `Sendable`, and nothing here needs it.
        let failure: String? = await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // The completion arrives on an arbitrary queue.
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                continuation.resume(returning: error.map { errorText($0) })
            }
        }
        if let failure {
            report(title: "bb Icon — could not open bb", detail: failure)
            return false
        }
        return true
    }

    /// The one extra button an alert can offer besides Close.
    struct AlertAction {
        let title: String
        let run: @MainActor () -> Void
    }

    /// Shows an alert on the next turn of the main actor, never inline. The
    /// alert is modal and runs its own loop, so raising it from a panel row's
    /// action would spin that loop with the panel still open and key, and the
    /// panel would only close once the alert was dismissed.
    private func report(title: String, detail: String, action: AlertAction? = nil) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            if let action {
                alert.addButton(withTitle: action.title)
                alert.addButton(withTitle: "Close")
            }
            NSApp.activate()
            let response = alert.runModal()
            if let action, response == .alertFirstButtonReturn { action.run() }
        }
    }

    private func refreshLoginItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        // Guarded, because this runs on every rebuild and an unconditional
        // write invalidates every observer whether or not anything changed.
        if enabled != loginItemEnabled { loginItemEnabled = enabled }
    }

    private func scheduleRebuild() {
        guard rebuildTask == nil else { return }
        rebuildTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.rebuildDebounce)
            } catch {
                // Cancelled by `stop()`. Swallowing this with `try?` would let
                // the rebuild run anyway, which is not what cancelling means.
                self?.rebuildTask = nil
                return
            }
            guard let self else { return }
            self.rebuildTask = nil
            self.rebuild()
        }
    }

    private func rebuild() {
        // Re-read on every rebuild: the switch lives in System Settings,
        // outside this app, so a checkmark that only updates on relaunch is
        // simply wrong.
        refreshLoginItem()
        let next = TrayViewModelBuilder.build(store.state)
        if next != model { model = next }
    }

    /// `~/.bb`, the directory bb.app writes its runtime file into. Throws
    /// while it does not exist.
    nonisolated static func runtimeDirectory() throws -> String {
        let dir = RuntimeFile.directory(home: NSHomeDirectory())
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: dir])
        }
        return dir
    }

    /// The runtime file's bytes, or nil when it does not exist (bb is not
    /// running, or never ran). Any other failure — permissions, a directory
    /// where the file should be — throws, and is named in the error row.
    nonisolated static func readRuntimeFile() throws -> Data? {
        let path = RuntimeFile.directory(home: NSHomeDirectory()) + "/" + RuntimeFile.fileName
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            let nsError = error as NSError
            let missing = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
            if missing { return nil }
            throw error
        }
    }
}

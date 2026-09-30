import AppKit
import BBIconCore
import ServiceManagement
import SwiftUI

/// Wiring, and only wiring. Every decision this reads from belongs to
/// `BBIconCore`: the runtime session decides whether bb is running and where,
/// the server connection follows it with a realtime session, the store holds
/// the state, and the view model turns it into a menu. What lives here is what
/// genuinely needs AppKit — `NSWorkspace`, the login item, alerts, the pairing
/// window — plus the object graph that connects them. Pairing, Forget, and
/// the launch-time load are `PairingController`'s; this shows its answers.
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
    /// Loads, pairs, and forgets; the Keychain calls run on its own serial
    /// queue, never the main thread, since a Keychain prompt blocks them.
    @ObservationIgnored private let pairing: PairingController
    @ObservationIgnored private let pairingWindow = PairingWindowController()
    @ObservationIgnored private let watcher: DirectoryWatcher
    @ObservationIgnored private var runtimeSession: RuntimeSession?
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var unsubscribe: (() -> Void)?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// Renders are coalesced: a reconnect lands as several store writes in a
    /// row, and rebuilding the menu for each is work nobody sees.
    private static let rebuildDebounce = Duration.milliseconds(120)

    init(pairingStore: any PairingStore = KeychainPairingStore()) {
        let store = ThreadStore()
        self.store = store
        // One HTTP client for the app's lifetime, shared by every server and
        // by getbb.app's redeem and revoke.
        let http = URLSessionHTTPClient()
        let connection = ServerConnection(
            store: store,
            http: http,
            makeTransport: { URLSessionWebSocketTransport(request: $0) }
        )
        self.connection = connection
        pairing = PairingController(
            store: pairingStore,
            http: http,
            executor: SerialQueuePairingStoreExecutor(label: "br.eng.gustavo.bb-menubar.keychain"),
            threadStore: store,
            connection: connection
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
        loadPairing()
        runtimeSession?.start()
    }

    /// Idempotent. The app delegate calls it on termination, however the app
    /// was quit.
    func stop() {
        pairingWindow.close()
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

    // MARK: - Pairing

    /// Opens the pairing window, or brings it forward. On the next main-actor
    /// turn, like an alert, so the menu panel has closed first and does not
    /// take key back from the window.
    func showPairingWindow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pairingWindow.show(connect: { [weak self] input in
                await self?.pairing.pair(input: input) ?? .failed("bb Icon is shutting down.")
            })
        }
    }

    /// Asks before forgetting the pairing with `handle`, then forgets it and
    /// names whatever did not happen. Deferred, as `report` is, so the modal
    /// alert does not run with the panel still open.
    func forgetRemote(handle: String) {
        Task { @MainActor [weak self] in
            let alert = NSAlert()
            alert.messageText = "Forget \(handle)?"
            alert.informativeText = "bb Icon will stop watching \(handle) and ask getbb.app to revoke its pairing. "
                + "To watch it again, you will need a new machine code."
            alert.addButton(withTitle: "Forget")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn,
                  let self,
                  let outcome = await self.pairing.forget(),
                  !outcome.problems.isEmpty
            else { return }
            self.report(
                title: "bb Icon — forgetting \(outcome.handle) did not fully succeed",
                detail: outcome.problems.joined(separator: "\n\n"),
                action: outcome.revokeFailed ? AlertAction(title: "Open getbb.app/dashboard") {
                    if let url = URL(string: "https://getbb.app/dashboard") { NSWorkspace.shared.open(url) }
                } : nil
            )
        }
    }

    /// A pair or Forget is under way; see `AppDelegate`'s termination.
    var isPairingBusy: Bool { pairing.isBusy }

    /// Returns once no pair or Forget is under way.
    func waitForPairing() async {
        await pairing.waitUntilIdle()
    }

    /// Reads the stored pairing at launch. A pairing window opened before it
    /// answered is told, so it does not offer to pair again.
    private func loadPairing() {
        Task { [weak self] in
            guard let loaded = await self?.pairing.load() else { return }
            self?.pairingWindow.alreadyPaired(handle: loaded.handle)
        }
    }

    /// Terminates through AppKit, which asks the delegate first: an
    /// in-flight pair or Forget is let finish, and the delegate's
    /// `applicationWillTerminate` then calls `stop()`.
    func quit() {
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

    /// Re-reads the login item's state. The switch also lives in System
    /// Settings, outside this app, so the checkmark is re-read whenever the
    /// panel appears (`MenuContent`'s `onAppear`), besides on every rebuild:
    /// a rebuild only follows a change in bb, and a checkmark that waited for
    /// one would show the state from before the user flipped it there.
    func refreshLoginItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        // Guarded, because this runs on every rebuild and every panel open,
        // and an unconditional write invalidates every observer whether or
        // not anything changed.
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
        // One of the two times the login item is re-read; see
        // `refreshLoginItem`.
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

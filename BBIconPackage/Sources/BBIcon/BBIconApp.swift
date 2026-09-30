import AppKit
import BBIconCore
import SwiftUI

/// The menu bar app. `MenuBarExtra` in window style is the whole interface, and
/// every action lives in its panel, which belongs to the menu bar item and
/// closes when it resigns key. The one free-standing window is the pairing
/// window, which `AppCoordinator` opens from the "Connect to a remote bb…"
/// row; it is AppKit's, not a scene here, so closing it never quits the app
/// and there is no window to restore at launch.
@main
struct BBIconApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                items: MenuModel.build(coordinator.model, loginItemEnabled: coordinator.loginItemEnabled),
                coordinator: coordinator
            )
        } label: {
            MenuBarLabel(
                icon: coordinator.model.icon,
                count: coordinator.model.count,
                needsAttention: coordinator.model.needsAttention,
                isDimmed: coordinator.model.isDimmed
            )
                .task {
                    // The delegate is created by AppKit and cannot reach the
                    // scene's state on its own; this is the one place both
                    // exist. Weakly held there, so nothing is kept alive by it.
                    appDelegate.coordinator = coordinator
                    coordinator.start()
                }
        }
        // Window style, stated rather than left to `.automatic`. The panel is
        // the whole interface: menu style makes every row an `NSMenuItem`,
        // which drops view modifiers and draws a non-clickable row in the
        // disabled grey, so a section heading could not be given the weight it
        // needs. This is still not a free-standing window — the panel belongs
        // to the menu bar item and closes when it resigns key.
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the scene once both exist. Every way of quitting through AppKit
    /// — the menu's Quit row, logging out, shutting down — ends in
    /// `applicationWillTerminate`, which stops the coordinator. A raw
    /// `SIGTERM` gets neither, because AppKit installs no handler for it —
    /// the socket closes with the process instead.
    weak var coordinator: AppCoordinator?

    /// A pair or Forget under way is let finish before the app goes. Quitting
    /// in the middle of one could spend a code without storing its pairing,
    /// or delete a pairing without revoking it, leaving a machine slot held
    /// at getbb.app. The wait is bounded by the HTTP client's 30 s resource
    /// timeout per request (a pair makes at most two, a Forget one) plus
    /// the Keychain call, which only a Keychain prompt left open can hold up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.isPairingBusy else { return .terminateNow }
        Task { @MainActor in
            await coordinator.waitForPairing()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No dock icon; this app is the menu bar item. The bundle sets
        // LSUIElement too, but `swift run` has no Info.plist.
        NSApplication.shared.setActivationPolicy(.accessory)

        // A second copy would put a second item in the menu bar, both watching
        // the same bb. The bundle id is the lock.
        if isAlreadyRunning() {
            NSApplication.shared.terminate(nil)
            return
        }

        do {
            try TrayIcons.preflight()
        } catch {
            // No icon means no visible item at all: nothing to click, nothing
            // to quit. Say so and exit rather than running invisibly.
            let alert = NSAlert()
            alert.messageText = "bb Icon — failed to start"
            alert.informativeText = errorText(error)
            // An accessory app is not frontmost, so without this the alert can
            // open behind every other window while the main thread sits in its
            // modal loop: no menu bar item, nothing to click, nothing to quit.
            NSApp.activate()
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private func isAlreadyRunning() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
}

import AppKit

/// Putting this app's window in front of every other app's, which an
/// accessory app has to do by hand: it has no Dock icon, is never frontmost on
/// its own, and by the time a menu row's action runs, the menu has closed and
/// the app that was active before is active again.
///
/// On macOS 14 and later `NSApp.activate()` is only a request under
/// cooperative activation, and is declined whenever another app is active —
/// which is exactly when the pairing window opened behind other windows.
/// `activate(ignoringOtherApps:)` still asks harder, and builds without a
/// warning (it is marked to be deprecated, not deprecated). Neither is what
/// makes the window visible, though: `orderFrontRegardless()` puts it in
/// front whether or not the activation is granted, and `makeKey()` gives it
/// the keyboard once it is.
///
/// Not raised to `.floating`: while the pairing window is open the user is
/// often in bb's own window making the code, and a floating window would sit
/// on top of it.
@MainActor
enum Foreground {
    static func bring(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Runs `alert` modally, in front. The alert's window exists only once it
    /// has been laid out, so that comes first.
    @discardableResult
    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alert.layout()
        bring(alert.window)
        return alert.runModal()
    }
}

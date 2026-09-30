import AppKit
import SwiftUI

/// The "Connect to a remote bb…" window: the design's instructions, a code
/// field, and the named failure. It decides nothing about pairing: what was
/// typed goes to `connect`, which answers with the failure to show, or with
/// success — closing the window, or first showing a notice when the pairing
/// changes nothing visible yet.
///
/// One window at a time: showing it while it is open brings that one forward.
/// It cannot be closed while a code is being redeemed, because the code is
/// spent as soon as getbb.app answers, and the answer must land somewhere.
///
/// Nothing here logs, prints, or keeps what was typed beyond the field.
@MainActor
final class PairingWindowController: NSObject, NSWindowDelegate {
    /// What `connect` answers.
    enum Outcome {
        /// Nothing was paired; the sentence says why.
        case failed(String)
        /// Paired. A notice, when there is one, is shown before the window
        /// closes, and the user closes it; without one it closes at once.
        case paired(notice: String?)
    }

    /// Redeems what was typed, stores the pairing, and starts using it.
    typealias Connect = @MainActor (String) async -> Outcome

    private var window: NSWindow?
    private var form: PairingForm?

    /// Opens the window, or brings the open one forward. The app is an
    /// accessory, with no Dock icon and never frontmost on its own, so the
    /// window is activated explicitly or it opens behind everything else.
    func show(connect: @escaping Connect) {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let form = PairingForm()
        let view = PairingView(
            form: form,
            submit: { [weak self] in self?.submit(connect: connect) },
            close: { [weak self] in self?.window?.performClose(nil) }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = .preferredContentSize
        let window = EditingWindow(contentViewController: hosting)
        window.title = "Connect to a remote bb"
        window.styleMask = [.titled, .closable]
        // Owned here and dropped in `windowWillClose`, not freed by AppKit
        // underneath this reference.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.form = form
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// A stored pairing turned up while the window was open — the launch-time
    /// load answered late. Unless a code is being redeemed, whose own answer
    /// will replace that pairing, the window says so and offers only Done.
    func alreadyPaired(handle: String) {
        guard let form, !form.inProgress else { return }
        form.error = nil
        form.notice = "Already paired with \(handle)."
    }

    /// Closes the window, if it is open. Used on quit.
    func close() {
        window?.close()
    }

    private func submit(connect: @escaping Connect) {
        guard let form, form.canConnect else { return }
        form.inProgress = true
        form.error = nil
        let input = form.input
        Task { [weak self] in
            let outcome = await connect(input)
            guard let self, let form = self.form else { return }
            form.inProgress = false
            switch outcome {
            case .failed(let message):
                form.error = message
            case .paired(let notice?):
                form.notice = notice
            case .paired(notice: nil):
                self.window?.close()
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !(form?.inProgress ?? false)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        form = nil
    }
}

/// What the window shows. The only rule here is the button's: there must be
/// something to send, nothing already being sent, and no pairing made.
@MainActor
@Observable
final class PairingForm {
    var input = ""
    var inProgress = false
    var error: String?
    /// Set once paired, when the window stays open to say something.
    var notice: String?

    var canConnect: Bool {
        !inProgress && notice == nil && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct PairingView: View {
    @Bindable var form: PairingForm
    let submit: () -> Void
    let close: () -> Void

    /// The design's instructions, word for word. Markdown, so the commands
    /// read as code; selectable, so they can be copied.
    private static let instructions: LocalizedStringKey = """
        Enter a machine code from the bb you want to watch. In any bb window, open \
        Settings → Remote access → Add mobile device; or, on the Mac running bb, run \
        `bb settings experiment mobileApp true` and then `bb connect machine-code`. \
        Codes last 10 minutes and work once.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.instructions)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            TextField("Machine code", text: $form.input)
                .textFieldStyle(.roundedBorder)
                .disabled(form.inProgress || form.notice != nil)
                // Return submits. The Connect button's default-action
                // shortcut may fire too; `submit` ignores the second press.
                .onSubmit(submit)

            if let error = form.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .foregroundStyle(.red)
            }

            if let notice = form.notice {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text(notice)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            HStack {
                if form.inProgress {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").foregroundStyle(.secondary)
                }
                Spacer()
                if form.notice != nil {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: close)
                        .keyboardShortcut(.cancelAction)
                        .disabled(form.inProgress)
                    Button("Connect", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!form.canConnect)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// A window whose text fields get the standard editing keys.
///
/// ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z, and ⇧⌘Z are menu key equivalents: AppKit finds them
/// in the main menu's Edit menu, and a text field has no binding of its own.
/// This app is an accessory with only a `MenuBarExtra`, so there is no Edit
/// menu to find them in, and pasting a machine code would beep. Rather than
/// install a main menu underneath SwiftUI, which owns `NSApp.mainMenu` in the
/// App lifecycle, this window maps the keys to the Edit menu's own actions
/// and sends them down the responder chain, where the field editor takes them.
/// Anything the window's own views claim first (the buttons' shortcuts) still
/// wins.
final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown, let action = Self.editAction(for: event) else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    static func editAction(for event: NSEvent) -> Selector? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch (modifiers, key) {
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "a"): return #selector(NSText.selectAll(_:))
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }
}

import AppKit
import BBIconCore
import SwiftUI

/// Renders the menu `MenuModel` decided on. Nothing here chooses what the menu
/// contains: every row, label, and ordering rule lives in the core, which is
/// what lets the whole menu be tested without a menu bar.
///
/// This is a panel rather than an `NSMenu`: `MenuBarExtra` is in window style,
/// so every row is a real SwiftUI view. An `NSMenu` row is an `NSMenuItem`,
/// which drops the view modifiers on the way in and draws a non-clickable row
/// in the disabled grey no matter what colour the title asks for — which is
/// what the section headings ran into in Paseo Icon, where this is ported from.
struct MenuContent: View {
    let items: [MenuItem]
    let coordinator: AppCoordinator

    /// Closes the panel. Actions that take the user elsewhere call it first,
    /// the way clicking a menu row used to close the menu, so the panel is gone
    /// before any alert the action raises: the coordinator shows its alerts on
    /// the next main-actor turn, never inline.
    @Environment(\.dismiss) private var dismiss

    /// The rows' own height, reported by the rows. It decides one thing: which
    /// of the two layouts below the panel is in. Nothing reads it as a
    /// measurement, so being a point out near the boundary picks a branch that
    /// is correct either way.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let overflows = contentHeight > MenuMetrics.maxHeight
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // `MenuItem.id` is unique per menu by construction; two rows
                // sharing one would render as one, a silent cap.
                ForEach(items) { item in
                    row(item)
                }
            }
            .padding(.vertical, MenuMetrics.outerPadding)
            // Measured inside the scroll view, where the rows are laid out at
            // their natural height whichever branch is in force. Measuring the
            // scroll view instead would make the two branches feed each other:
            // hug reports the content, clamp reports the cap, and the panel
            // flips between them forever.
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(width: MenuMetrics.width)
        // A menu that loses rows (bb quitting drops them all) makes the content
        // shorter; nothing else makes the panel follow it.
        .background(PanelResizer(items: items))
        // Two layouts, and the menu needs both.
        //
        // `fixedSize` is what keeps a short menu from opening as an empty
        // sliver: a window-style `MenuBarExtra` sizes its panel by asking what
        // fits under a proposal with no height in it, and a `ScrollView`
        // answers zero, because it will be any height and so asks for none.
        //
        // But `fixedSize` lays the scroll view out at its *content's* height,
        // and `maxHeight` then clamps only the size the panel is told. Past the
        // cap those two disagree and the rows hang off the window with nothing
        // to scroll — every footer row, Quit included, out of reach.
        //
        // So past the cap the scroll view is given the cap as a real height
        // instead, which lays it out at the cap and lets it scroll. `maxHeight`
        // stays as the backstop for the first pass, before the rows have
        // reported anything.
        .fixedSize(horizontal: false, vertical: !overflows)
        .frame(height: overflows ? MenuMetrics.maxHeight : nil)
        .frame(maxHeight: MenuMetrics.maxHeight)
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
        }
        // The login item can be switched in System Settings while the panel
        // is closed, so its checkmark is re-read each time the panel opens.
        .onAppear { coordinator.refreshLoginItem() }
    }

    @ViewBuilder
    private func row(_ item: MenuItem) -> some View {
        switch item {
        case .sectionHeading(let bucket, let label):
            // Full-strength label colour and the menu font at bold weight,
            // with the section's glyph.
            MenuStaticRow {
                HStack(spacing: MenuMetrics.iconSpacing) {
                    glyph(bucket)
                    Text(label)
                        .font(MenuMetrics.boldFont)
                        .foregroundStyle(.primary)
                }
            }

        case .thread(let row, let label):
            MenuActionRow { dismiss(); coordinator.openThread(row) } label: { _ in
                Text(label).font(MenuMetrics.font)
            }

        case .overflow(_, let label):
            // The capped rows are only reachable in bb.
            MenuActionRow { dismiss(); coordinator.openApp() } label: { _ in
                Text(label).font(MenuMetrics.font)
            }

        case .separator:
            Divider().padding(.horizontal, MenuMetrics.dividerInset).padding(.vertical, 4)

        case .note(_, let text):
            MenuStaticRow {
                Text(text).font(MenuMetrics.font).foregroundStyle(.secondary)
            }

        case .error(_, let detail):
            // The failure is named in the row itself, clipped to a few lines;
            // clicking shows the whole sentence.
            MenuActionRow { dismiss(); coordinator.showError(detail) } label: { _ in
                HStack(alignment: .firstTextBaseline, spacing: MenuMetrics.iconSpacing) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(detail)
                        .lineLimit(MenuMetrics.errorLineLimit)
                        .truncationMode(.tail)
                }
                .font(MenuMetrics.font)
            }

        case .status(let label):
            MenuStaticRow {
                Text(label).font(MenuMetrics.font).foregroundStyle(.secondary)
            }

        case .openApp:
            MenuActionRow { dismiss(); coordinator.openApp() } label: { _ in
                Text("Open bb").font(MenuMetrics.font)
            }

        case .loginItem(let enabled):
            // A Toggle, not a row with a tick in its title: it reports a
            // checked state to VoiceOver where a prefixed character reports
            // none. The panel stays open, because the switch is the result and
            // there is nowhere to go.
            MenuStaticRow {
                Toggle("Start at login", isOn: Binding(
                    get: { enabled },
                    set: { coordinator.setLoginItem($0) }
                ))
                .toggleStyle(.checkbox)
                .font(MenuMetrics.font)
            }

        case .quit:
            MenuActionRow { coordinator.quit() } label: { _ in
                Text("Quit bb Icon").font(MenuMetrics.font)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    @ViewBuilder
    private func glyph(_ bucket: ThreadBucket) -> some View {
        if let image = try? TrayIcons.image(for: bucket) {
            // Template, so it takes the row's own colour.
            Image(nsImage: image).renderingMode(.template)
        }
    }
}

/// How tall the rows are, reported up from inside the scroll view.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The measurements every row shares. The font is the menu's own rather than
/// `NSFont.systemFontSize`, which is a different size.
enum MenuMetrics {
    /// A row longer than this wraps rather than truncating, because a clipped
    /// thread title is information the menu should show.
    static let width: CGFloat = 480
    static let maxHeight: CGFloat = 560
    static let outerPadding: CGFloat = 6
    static let rowInset: CGFloat = 10
    static let rowSpacing: CGFloat = 4
    static let iconSpacing: CGFloat = 6
    static let dividerInset: CGFloat = 12
    static let cornerRadius: CGFloat = 5
    /// An error row shows this much of its sentence; the alert shows the rest.
    static let errorLineLimit = 3

    static let font = Font(NSFont.menuFont(ofSize: 0))
    static let boldFont = Font(NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize))
}

/// Shrinks the panel back after its content does.
///
/// A window-style `MenuBarExtra` grows its panel when the content grows and
/// never shrinks it again, leaving the menu centred in a panel taller than it.
/// The panel's own content view reports a `fittingSize` of zero, so it cannot
/// be asked; the view planted here backs the rows, so after layout its own
/// `bounds` is exactly the height the panel should be. Ported from Paseo Icon.
///
/// Only shrinking is handled. Growing already works, and setting a frame
/// SwiftUI is also setting would be two things fighting over one window.
struct PanelResizer: NSViewRepresentable {
    /// Not read. It is here so SwiftUI runs `updateNSView` whenever the rows
    /// change, which is the only moment the panel can be wrong.
    let items: [MenuItem]

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // Next turn of the main actor, and a layout pass before measuring. Both
        // are load-bearing: when this runs, `view` is still the height of the
        // rows that are going away, and only laying the window out brings it to
        // the new one.
        Task { @MainActor in
            guard let window = view.window, let content = window.contentView else { return }
            content.layoutSubtreeIfNeeded()
            guard let frame = Self.shrunkFrame(from: window.frame, contentHeight: view.bounds.height, in: window) else { return }
            window.setFrame(frame, display: true)
        }
    }

    /// The frame a panel should take to fit content of `contentHeight`, or nil
    /// when it already fits or would have to grow. The top edge is preserved,
    /// not the origin: the panel hangs from the menu bar item.
    @MainActor
    static func shrunkFrame(from frame: NSRect, contentHeight: CGFloat, in window: NSWindow) -> NSRect? {
        guard contentHeight > 0 else { return nil }
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: contentHeight)).height
        guard frame.height - target > 0.5 else { return nil }
        return NSRect(x: frame.minX, y: frame.maxY - target, width: frame.width, height: target)
    }
}

/// A row that does something. Full-width hit area and a highlight under the
/// pointer, which is what a menu row gave for free and a panel does not.
private struct MenuActionRow<Label: View>: View {
    let action: () -> Void
    /// Handed the pointer state, so a label can adapt to the highlight.
    @ViewBuilder let label: (Bool) -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label(hovering)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MenuMetrics.rowInset)
                .padding(.vertical, MenuMetrics.rowSpacing)
                // Without this the row is only clickable where its text is,
                // and the gap to the right of a short label does nothing.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The system's own selection colours, not the accent colour and white.
        // These follow the user's Highlight colour and stay legible against a
        // light accent or graphite.
        .foregroundStyle(hovering ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor)) : AnyShapeStyle(.primary))
        .background(
            RoundedRectangle(cornerRadius: MenuMetrics.cornerRadius)
                .fill(hovering ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
        )
        .padding(.horizontal, MenuMetrics.outerPadding)
        .onHover { hovering = $0 }
    }
}

/// A row that only says something: the same metrics, no highlight, no action.
private struct MenuStaticRow<Label: View>: View {
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MenuMetrics.rowInset)
            .padding(.vertical, MenuMetrics.rowSpacing)
            .padding(.horizontal, MenuMetrics.outerPadding)
    }
}

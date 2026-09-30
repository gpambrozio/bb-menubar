import AppKit
import BBIconCore
import SwiftUI

/// The menu bar item itself: the bucket's glyph, plus the count when there is
/// one. `MenuBarExtra`'s label does not respect colour, opacity, or layout
/// modifiers directly, so the composed view is rasterized through
/// `ImageRenderer` and handed over as an image.
///
/// Resting states stay a template image, so they invert with the menu bar. A
/// tray that needs the user is drawn red instead, which a template image
/// cannot be — the menu bar recolours a template and throws the red away — so
/// that one case ships as a plain image.
///
/// Dimmed means "not connected" (`TrayViewModel.isDimmed`): the glyph is drawn
/// at 40 % opacity through the same renderer and stays a template, since a
/// template image keeps its alpha and the menu bar only replaces its colour.
struct MenuBarLabel: View {
    let icon: TrayIconState
    let count: Int
    /// `TrayViewModel.needsAttention`. The rule is the view model's; this view
    /// only picks a colour from it.
    let needsAttention: Bool
    /// `TrayViewModel.isDimmed`. The rule is the view model's; this view only
    /// picks an opacity from it.
    let isDimmed: Bool

    var body: some View {
        if let image = Self.render(icon: icon, count: count, needsAttention: needsAttention, isDimmed: isDimmed) {
            Image(nsImage: image)
        } else {
            // Only reachable if the icons are missing, which `preflight`
            // already refuses to start on.
            Image(systemName: "circle.dashed")
        }
    }

    /// A fixed red rather than `NSColor.systemRed`. The attention image is not
    /// a template, so it does not follow the menu bar's appearance, and a
    /// dynamic colour would resolve against this app's appearance rather than
    /// the bar's — the wrong one of the two. This value is systemRed's light
    /// variant, which reads on a light and a dark menu bar alike.
    private static let attentionRed = Color(red: 1.0, green: 0.23, blue: 0.19)

    /// How much of the glyph shows while not connected.
    private static let dimmedOpacity = 0.4

    @MainActor
    private static func render(icon: TrayIconState, count: Int, needsAttention: Bool, isDimmed: Bool) -> NSImage? {
        guard let glyph = try? TrayIcons.image(for: icon) else { return nil }
        // The glyph alone is already the template image the resting menu bar
        // wants; only colour, opacity, or a count needs the renderer.
        if count == 0, !needsAttention, !isDimmed { return glyph }

        let content = HStack(spacing: 3) {
            // Stated rather than inferred from `glyph.isTemplate`, because the
            // tint below is what makes the mark red and a non-template image
            // ignores it.
            Image(nsImage: glyph)
                .renderingMode(.template)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(needsAttention ? Self.attentionRed : Color.black)
        .opacity(isDimmed ? Self.dimmedOpacity : 1)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        // The plain glyph, deliberately: it loses the red, the count, or the
        // dimming, but a menu bar item with no image at all is one with
        // nothing to click and no way to quit. `ImageRenderer` returning nil
        // is not known to happen.
        guard let image = renderer.nsImage else { return glyph }
        // Black is a template and gets inverted by the menu bar; red must not
        // be, or the menu bar paints over it.
        image.isTemplate = !needsAttention
        return image
    }
}

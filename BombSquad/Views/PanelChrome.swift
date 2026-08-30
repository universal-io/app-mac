import AppKit
import SwiftUI

/// Borderless floating panel that can still take keyboard focus. The system
/// gives borderless windows no key status by default; the I//O panel is a
/// text-entry surface, so it must become key.
final class KeyablePanel: NSPanel {
    var onCloseRequested: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// Esc anywhere in the panel (outside the editors, which handle it
    /// themselves) closes it — borderless windows have no close button.
    override func cancelOperation(_ sender: Any?) {
        guard let onCloseRequested else {
            super.cancelOperation(sender)
            return
        }
        onCloseRequested()
    }
}

/// Chrome for the floating panel. Opaque window background (2026-07-06):
/// the earlier glass/material let the desktop bleed through and hurt text
/// legibility, and its edge treatment showed as a stray dark outline around
/// the panel. The window behind is transparent; this shape IS the panel.
struct PanelChrome: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 1))
            .clipShape(shape)
    }
}

extension View {
    func panelChrome() -> some View {
        modifier(PanelChrome())
    }
}

/// Chrome for a companion bubble — the card Vision's bubble established, kept
/// as one definition so Compose's bubble is the same object on screen rather
/// than a second card that drifts a radius or a hairline away from it.
///
/// Opaque, and deliberately not a material: what sits behind a bubble is the
/// wash or the user's own screen, and a material would sample it into the one
/// surface that has to stay readable. `windowBackgroundColor` keeps the default
/// label colours legible in both appearances. The shadow is the window's
/// (`hasShadow`), never drawn in here: a view-drawn shadow needs the window to
/// be larger than the card to hold it, and that margin swallows clicks meant
/// for whatever is underneath.
struct BubbleChrome: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16)
    }

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
            .clipShape(shape)
    }
}

extension View {
    func bubbleChrome() -> some View {
        modifier(BubbleChrome())
    }
}

/// The two surfaces inside a bubble, as tone rather than as depth.
///
/// The place to read and the place to type have to be told apart — without
/// that the answer, the empty space and the input box are one area with
/// nothing saying where a click puts a cursor. A shade of the foreground does
/// it in both appearances without either surface claiming to be a layer of its
/// own. One definition for both bubbles, same reason as `BubbleChrome`.
enum BubbleSurface {
    static let reading = Color.primary.opacity(0.05)
    static let typing = Color.primary.opacity(0.10)
}

/// Monochrome "I//O" glyph for the menu bar (template image so it follows
/// the menu bar appearance). The logo glyph and the diff colors are the only
/// custom visuals the design system allows.
enum MenuBarGlyph {
    static let image: NSImage = {
        let text = "I//O" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let size = text.size(withAttributes: attributes)
        let image = NSImage(
            size: NSSize(width: ceil(size.width), height: ceil(size.height)),
            flipped: false
        ) { _ in
            text.draw(at: .zero, withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }()
}

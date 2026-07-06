import AppKit
import SwiftUI

/// Borderless floating panel that can still take keyboard focus. The system
/// gives borderless windows no key status by default; the I//O panel is a
/// text-entry surface, so it must become key.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Esc anywhere in the panel (outside the editors, which handle it
    /// themselves) closes it — borderless windows have no close button.
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .closePanel, object: nil)
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

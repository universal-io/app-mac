import AppKit
import SwiftUI

/// A transparent view that lets the user drag the borderless panel by this
/// area only (the header row), the way a title bar would. Everywhere else,
/// drags belong to the content: text selection, image panning, annotation
/// drawing. Buttons layered on top still receive their clicks first.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        /// The first click on a window whose app is not active is otherwise
        /// spent bringing the window forward and never reaches the view. During
        /// guidance the guided app is the active one, so every first grab of the
        /// bubble slid off and only the second one dragged (owner, 2026-09-08).
        /// The covering canvas has had this since R14; the grip did not.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

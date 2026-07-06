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
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

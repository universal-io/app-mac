import AppKit
import SwiftUI

/// An NSTextView-backed editor that "sends" on a plain Enter, but lets the input
/// method (IME) confirm an in-progress conversion first: while composing kanji,
/// the first Enter only commits the conversion (handled by the IME, so
/// `doCommandBySelector(insertNewline:)` is never reached); a subsequent Enter
/// then sends. Shift+Enter inserts a newline. Esc invokes `onEscape`.
///
/// Focus is bridged through `focusedField` so SwiftUI can drive/observe which
/// editor is first responder (used for the blue highlight and post-review focus).
struct SendableTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusedField: FocusField?
    let field: FocusField
    var onSend: () -> Void
    var onEscape: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SendingTextView()
        textView.delegate = context.coordinator
        textView.onFocusChange = { focused in
            guard focused else { return }
            let field = context.coordinator.parent.field
            if context.coordinator.parent.focusedField != field {
                context.coordinator.parent.focusedField = field
            }
        }
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? SendingTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        // Drive first responder from SwiftUI focus state.
        if focusedField == field, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SendableTextEditor
        init(_ parent: SendableTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        /// Intercept command selectors. This delegate is IME-aware: while
        /// composing kanji, the confirming Enter is consumed by the input method
        /// and never reaches here, so the first Enter only commits the
        /// conversion; a subsequent Enter then sends.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+Enter → newline (let the text view handle it);
                // a plain Enter → send.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false
                }
                parent.onSend()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard let onEscape = parent.onEscape else { return false }
                onEscape()
                return true
            default:
                return false
            }
        }
    }
}

/// NSTextView that reports first-responder changes so SwiftUI focus can track it.
final class SendingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}

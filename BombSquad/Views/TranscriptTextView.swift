import AppKit
import SwiftUI

/// The navigator conversation as ONE selectable read-only NSTextView.
///
/// SwiftUI's `.textSelection(.enabled)` works per `Text` view: selection
/// cannot sweep across paragraphs/turns and only engages when the cursor is
/// exactly on a glyph — which reads as "this panel can't be selected". A
/// real text view gives the native experience: select from anywhere, drag
/// across the whole conversation, ⌘A / ⌘C just work.
struct TranscriptTextView: NSViewRepresentable {
    let turns: [NavigatorDisplayTurn]
    /// Streaming answer (already marker-stripped); appended below the turns.
    let streamingText: String?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [:]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let content = Self.attributedTranscript(turns: turns, streaming: streamingText)
        // Replace only on real change so an idle re-render never clears the
        // user's selection mid-read.
        guard textView.textStorage?.string != content.string else { return }
        textView.textStorage?.setAttributedString(content)
        textView.scrollToEndOfDocument(nil)
    }

    private static func attributedTranscript(
        turns: [NavigatorDisplayTurn],
        streaming: String?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let userParagraph = NSMutableParagraphStyle()
        userParagraph.paragraphSpacing = 4
        let userAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: userParagraph,
        ]

        let assistantParagraph = NSMutableParagraphStyle()
        assistantParagraph.paragraphSpacing = 14
        assistantParagraph.lineSpacing = 2
        let assistantAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: assistantParagraph,
        ]

        func append(role: NavigateTurn.Role, text: String) {
            guard !text.isEmpty else { return }
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            switch role {
            case .user:
                result.append(NSAttributedString(string: "▸ \(text)", attributes: userAttributes))
            case .assistant:
                result.append(NSAttributedString(string: text, attributes: assistantAttributes))
            }
        }

        for turn in turns {
            append(role: turn.role, text: turn.text)
        }
        if let streaming, !streaming.isEmpty {
            append(role: .assistant, text: streaming)
        }
        return result
    }
}

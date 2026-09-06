import SwiftUI

/// The conversation in the bubble, as the rows it is drawn from.
///
/// The bubble used to show one question and one answer, each overwriting the
/// last. That is not what a conversation looks like to anybody who has used a
/// messenger, and it threw away the one thing that made a follow-up question
/// readable — the exchange it followed. Rows accumulate downward, newest at the
/// bottom, the field to type in below that.
///
/// **A thread is one subject.** Pointing somewhere else starts a new one
/// (`VisionSession.point` empties `turns`), and what is visible is exactly what
/// the model remembers: the two never disagree, so a user never asks about a
/// message the model has already forgotten. Guidance is one subject — the
/// goal — so its steps accumulate in the same thread until it is reached or
/// left.
///
/// Pure, so the rules can be pinned without a hosting view: what appears while
/// an answer streams, while nothing has arrived, when something went wrong, and
/// where guidance's honest note about an unchanged screen sits.
enum VisionThreadRow: Identifiable, Equatable {
    /// Something the user said — typed, or the short line a gesture stands for.
    case user(id: UUID, text: String)
    /// A validated answer.
    case assistant(id: UUID, text: String)
    /// The answer still being written. Same side as an answer; it becomes one.
    case streaming(String)
    /// Nothing readable yet, and what the wait is for.
    case waiting(String)
    /// Guidance's note that the screen did not change after the user acted.
    case note(String)
    /// An attempt that went wrong.
    case error(String)
    /// The bubble with nothing to say yet.
    case hint(String)

    var id: String {
        switch self {
        case .user(let id, _): return "user-\(id.uuidString)"
        case .assistant(let id, _): return "assistant-\(id.uuidString)"
        case .streaming: return "streaming"
        case .waiting: return "waiting"
        case .note: return "note"
        case .error: return "error"
        case .hint: return "hint"
        }
    }

    /// Whether the row sits on the product's side of the conversation.
    var isFromProduct: Bool {
        switch self {
        case .assistant, .streaming, .waiting: return true
        case .user, .note, .error, .hint: return false
        }
    }

    static let noChangeNote = "操作は検知しましたが、画面に変化は見えませんでした"
    static let readingHere = "ここを読んでいます…"
    static let readingScreen = "画面を読んでいます…"
    static let emptyHint = "画面のどこかをクリックすると、その場所について説明します。"

    /// The rows for a session's state, in reading order.
    ///
    /// - The turns come first, as they happened.
    /// - Guidance's note goes **before** the step it qualifies: the note was
    ///   known before the step was asked for, and the step is the model's answer
    ///   to a screen that had not changed. While that step is still being
    ///   evaluated the note is the last thing said.
    /// - One trailing row at most says what is happening now: an error, the
    ///   words arriving, or the wait. An error outranks the draft — a draft
    ///   that failed is not something to keep reading.
    /// - With nothing at all to show and nothing on the way, the bubble says
    ///   what pointing does.
    static func rows(
        turns: [VisionDisplayTurn],
        streamingMessage: String?,
        isLoading: Bool,
        isPointing: Bool,
        isCopilotChecking: Bool = false,
        errorMessage: String?,
        refusal: String?,
        copilotSawNoChange: Bool
    ) -> [VisionThreadRow] {
        var rows: [VisionThreadRow] = turns.map { turn in
            switch turn.role {
            case .user: return .user(id: turn.id, text: turn.text)
            case .assistant: return .assistant(id: turn.id, text: turn.text)
            }
        }
        if copilotSawNoChange {
            if let last = rows.indices.last, case .assistant = rows[last] {
                rows.insert(.note(noChangeNote), at: last)
            } else {
                rows.append(.note(noChangeNote))
            }
        }
        if let error = errorMessage, error != refusal {
            rows.append(.error(error))
        } else if let streaming = streamingMessage, !streaming.isEmpty {
            rows.append(.streaming(streaming))
        } else if isLoading {
            rows.append(.waiting(isPointing ? readingHere : readingScreen))
        } else if isCopilotChecking {
            // A guidance step being evaluated is the same wait in the same
            // words: the screen is being read. The status row used to say
            // "waiting for the screen to change and settle" and "checking the
            // new screen for the next step", which described the pipeline
            // rather than the wait.
            rows.append(.waiting(readingScreen))
        }
        if rows.isEmpty {
            rows.append(.hint(emptyHint))
        }
        return rows
    }
}

/// The thread, drawn.
///
/// The product speaks from the left under its own icon; the user from the
/// right under theirs. Two sides and two faces are what make a column of text
/// read as an exchange rather than as a transcript — the convention every
/// messenger settled on, kept here because inventing another one would only
/// have to be learned.
struct VisionThreadView: View {
    let rows: [VisionThreadRow]
    /// The user's picture, already loaded, or nil for the placeholder. One
    /// image for every row: when each row fetched its own, the same account
    /// showed a picture on one line and a placeholder on the next, depending on
    /// which fetch had finished — two faces for one person.
    let userAvatar: NSImage?
    let fontSize: CGFloat

    private static let bubbleVerticalPadding: CGFloat = 6

    /// Extra space between the lines of a message, on top of the font's own
    /// line box.
    ///
    /// The system font's line box is 1.18 times its size (measured: 15.3 pt at
    /// 13 pt), which is set for labels and read as cramped in a paragraph — the
    /// owner put it at "1.1 or 1.2" by eye and asked for 1.4 to 1.5
    /// (2026-09-07). Four points at 13 pt makes 1.49. One rule for every row,
    /// and `VisionBubbleView.answerLineHeight` adds the same amount so the
    /// pane still lands on whole lines.
    static func lineSpacing(fontSize: CGFloat) -> CGFloat {
        (fontSize * 0.3).rounded()
    }

    private var lineSpacing: CGFloat { Self.lineSpacing(fontSize: fontSize) }

    /// Every face is the same circle, and the circle is exactly as tall as a
    /// one-line message: line height plus the message's own vertical padding.
    /// Top-aligned, a single line and its avatar then share their edges, and a
    /// longer message hangs below its face the way it does in any messenger.
    static func avatarSize(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let line = font.ascender - font.descender + font.leading
        return (line + bubbleVerticalPadding * 2).rounded()
    }

    private var avatarSize: CGFloat { Self.avatarSize(fontSize: fontSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                self.row(row)
            }
        }
    }

    @ViewBuilder
    private func row(_ row: VisionThreadRow) -> some View {
        switch row {
        case .user(_, let text):
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: avatarSize + 8)
                Text(text)
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, Self.bubbleVerticalPadding)
                    // The product's own purple, not the system accent: the
                    // user's words in the one place the product speaks, and iris
                    // is what that place is made of. State never borrows it.
                    .background(MarkStyle.swiftUIColor, in: RoundedRectangle(cornerRadius: 10))
                ThreadAvatar.user(image: userAvatar, size: avatarSize)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("あなた: \(text)")
        case .assistant(_, let text):
            productRow(text: text, accessibility: "Universal I/O: \(text)") {
                Text(text)
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .streaming(let text):
            productRow(text: text, accessibility: "Universal I/O: \(text)") {
                Text(text)
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .waiting(let text):
            productRow(text: text, accessibility: text) {
                // Named, not spun: a spinner says work is happening, this says
                // what the work is.
                Label(text, systemImage: "eye")
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(.secondary)
            }
        case .note(let text):
            Label(text, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, avatarSize + 8)
        case .error(let text):
            Text(text)
                .font(.system(size: fontSize))
                .lineSpacing(lineSpacing)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, avatarSize + 8)
        case .hint(let text):
            Text(text)
                .font(.system(size: fontSize))
                .lineSpacing(lineSpacing)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func productRow<Content: View>(
        text: String,
        accessibility: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ThreadAvatar.product(size: avatarSize)
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, Self.bubbleVerticalPadding)
                // The reading tone, on the bubble's own ground. The surface
                // that used to hold the whole answer is now each answer's own.
                .background(BubbleSurface.reading, in: RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: avatarSize + 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }
}

/// Who is speaking, small enough not to compete with what is said.
///
/// One component, two contents. Both faces are the same circle at the same
/// size, whatever is inside: the product's icon, the user's picture, or the
/// placeholder. Anything that differs between them — a square icon beside a
/// round photo, a symbol with its own inner margin beside a full-bleed image —
/// reads as two kinds of thing rather than two speakers.
enum ThreadAvatar {
    /// The app's own icon, which is how the product is already recognised in
    /// the Dock and the menu bar — clipped to the same circle as everyone else.
    static func product(size: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    /// The user's picture where the account has one (Google sign-in supplies
    /// it), and a neutral placeholder where it does not. The placeholder is
    /// drawn as a filled circle with the symbol inside it, not as the symbol
    /// alone: `person.crop.circle.fill` carries its own margin, so at the same
    /// frame it looked smaller and sat lower than the picture next to it.
    static func user(image: NSImage?, size: CGFloat) -> some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Circle().fill(Color.primary.opacity(0.12))
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

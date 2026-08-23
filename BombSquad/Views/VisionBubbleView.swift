import SwiftUI

/// The only thing this product says out loud while pointing.
///
/// Everything the app tells the user comes from here: what it is looking at,
/// what the thing they pointed at is, what went wrong, and what to do next. A
/// product whose promise is "ask about the thing next to you" cannot answer
/// beside the thing and explain itself from somewhere else — and a card in the
/// middle of the picture covers the place the user is trying to look at, which
/// the web client established by doing it.
///
/// It never draws on the screen behind it and never decides anything. The mark
/// and the frame belong to the overlay; the turn belongs to the session.
struct VisionBubbleView: View {
    @ObservedObject var session: VisionSession
    /// Whether the user has pointed at something yet. Before that, the bubble
    /// waits in the corner and says what pointing does.
    let hasPointed: Bool
    let onClose: () -> Void

    /// How tall the answer may grow before it scrolls instead.
    ///
    /// An answer has no length limit, so something has to give: either the text
    /// is cut, or the bubble is. Cutting the text loses the sentence the user is
    /// reading — which is what was happening, with SwiftUI quietly appending an
    /// ellipsis — while cutting the bubble only means scrolling. `ViewThatFits`
    /// keeps short answers short: the plain text is used whenever it fits, and
    /// the scrolling copy takes over only when it would not.
    static let maxAnswerHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            handle
            VStack(alignment: .leading, spacing: 10) {
                if let question = latestQuestion {
                    Text(question)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("送信した質問: \(question)")
                }
                ViewThatFits(in: .vertical) {
                    answer
                    ScrollView { answer }
                }
                .frame(maxHeight: Self.maxAnswerHeight)
                ask
            }
            .padding(12)
        }
        .frame(width: VisionPointingOverlay.bubbleWidth, alignment: .leading)
        // Opaque, and deliberately not a material. A material samples what is
        // behind it *within the same window*, and what is behind this one is the
        // wash — so the bubble came out tinted purple, sitting in the colour it
        // is supposed to be readable against. `windowBackgroundColor` also keeps
        // the default label colours legible in both appearances, which a fixed
        // dark card would not.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    /// Skill and close, on their own bar. A close button floating in the body
    /// makes the answer's first line wrap around it and read as part of the
    /// sentence.
    private var handle: some View {
        HStack(spacing: 8) {
            if let skill = session.activeSkillName {
                ActiveSkillLabel(
                    skillName: skill,
                    help: "この画面に「\(skill)」の知識を適用しています"
                )
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Visionを閉じる")
            .help("閉じる（Esc）")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var answer: some View {
        if let error = session.errorMessage {
            Text(error)
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let streaming = session.streamingMessage, !streaming.isEmpty {
            Text(streaming)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let answered = latestAnswer {
            Text(answered)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if session.isLoading {
            // Named, not spun: a spinner says work is happening, this says what
            // the work is.
            Label(hasPointed ? "ここを読んでいます…" : "画面を読んでいます…", systemImage: "eye")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else {
            Text("画面のどこかをクリックすると、その場所について説明します。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var ask: some View {
        HStack(alignment: .bottom, spacing: 8) {
            SendableTextEditor(
                text: $session.input,
                focusedField: $session.focusedField,
                field: .navigator,
                onSend: session.sendQuestion,
                onEscape: onClose
            )
            .frame(minHeight: 34, maxHeight: 72)

            PanelSendButton(
                accessibilityLabel: "Visionへの質問を送信",
                help: "質問を送信（Enter）",
                isEnabled: session.canSend,
                action: session.sendQuestion
            )
        }
    }

    /// The most recent thing the user said, unless it was the gesture itself.
    /// Pointing is already shown by the mark on the screen; repeating it as a
    /// chip would be the bubble telling the user what they just did.
    private var latestQuestion: String? {
        guard let turn = session.turns.last(where: { $0.role == .user }) else { return nil }
        guard turn.text != VisionSession.pointedHereText else { return nil }
        return turn.text
    }

    private var latestAnswer: String? {
        session.turns.last(where: { $0.role == .assistant })?.text
    }
}

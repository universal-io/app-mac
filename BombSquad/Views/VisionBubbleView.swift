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
    /// How much room the answer may take, decided by the caller from the screen
    /// this is being shown on. Passed in rather than read here: a view that
    /// measured the screen itself could disagree with the one the overlay
    /// covers, and on two displays those are different heights.
    let answerHeightBudget: CGFloat
    let onClose: () -> Void

    private static let answerFontSize: CGFloat = 13

    /// One line of the answer, in the answer's own font.
    ///
    /// Ascender to descender plus leading is what text layout uses for a line
    /// box, so this is the unit the answer is actually built from — not an
    /// estimate of it.
    static let answerLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: answerFontSize)
        return font.ascender - font.descender + font.leading
    }()

    /// How tall the answer may grow before it scrolls instead, in whole lines.
    ///
    /// An answer has no length limit, so something has to give: either the text
    /// is cut, or the bubble is. Cutting the text loses the sentence the user is
    /// reading — which is what was happening, with SwiftUI quietly appending an
    /// ellipsis — while cutting the bubble only means scrolling. `ViewThatFits`
    /// keeps short answers short: the plain text is used whenever it fits, and
    /// the scrolling copy takes over only when it would not.
    ///
    /// **The height has to land on a line boundary.** An arbitrary height cuts
    /// the last visible line through the middle of its glyphs, which reads as a
    /// broken renderer rather than as more text below — the answer looked
    /// damaged even though scrolling reached all of it.
    ///
    /// Four lines is the floor: below that the scroll view shows too little for
    /// its own scrolling to make sense, and no real display is that small.
    static func answerHeight(within budget: CGFloat) -> CGFloat {
        max(4, (budget / answerLineHeight).rounded(.down)) * answerLineHeight
    }

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
                // Two surfaces, because there are two jobs: this is the place to
                // read, the field below is the place to type. Both sat directly
                // on the card, which made the answer, the empty space and the
                // input box one undifferentiated area — there was nothing to
                // tell the user where a click would put a cursor.
                ViewThatFits(in: .vertical) {
                    answer
                    ScrollView { answer }
                }
                .frame(maxHeight: Self.answerHeight(within: answerHeightBudget))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                ask
                startGuidance
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
            // Skill and processing info, the same pair Compose shows. The info
            // button came from the panel that used to hold it: what model, what
            // route, what the accessibility walk found and what was captured is
            // how an operator tells a wrong answer from a broken pipeline, and
            // the bubble is the only place the product speaks now.
            PanelToolInfo(
                toolName: session.activeSkillName,
                toolHelp: session.activeSkillName.map {
                    "この画面に「\($0)」の知識を適用しています"
                } ?? "検出されたツールはありません",
                informationHelp: "処理情報を表示",
                informationAccessibilityLabel: "Visionの処理情報"
            ) {
                VisionDiagnosticsPopover(
                    report: VisionDiagnosticsReport.text(for: session)
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
                .font(.system(size: Self.answerFontSize))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let streaming = session.streamingMessage, !streaming.isEmpty {
            Text(streaming)
                .font(.system(size: Self.answerFontSize))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let answered = latestAnswer {
            Text(answered)
                .font(.system(size: Self.answerFontSize))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if session.isLoading {
            // Named, not spun: a spinner says work is happening, this says what
            // the work is.
            Label(hasPointed ? "ここを読んでいます…" : "画面を読んでいます…", systemImage: "eye")
                .font(.system(size: Self.answerFontSize))
                .foregroundStyle(.secondary)
        } else {
            Text("画面のどこかをクリックすると、その場所について説明します。")
                .font(.system(size: Self.answerFontSize))
                .foregroundStyle(.secondary)
        }
    }

    /// The way into guidance, which used to live in the static panel.
    ///
    /// It had to move here, and not as a tidy-up: the panel it was in is only
    /// presented once guidance has already started, so from the moment pointing
    /// replaced the panel this button was the only entrance to Copilot and
    /// nothing could reach it. Starting guidance closes the overlay, because
    /// being told "click this" is useless while a wash is swallowing clicks.
    @ViewBuilder
    private var startGuidance: some View {
        if session.canStartCopilot {
            Button {
                session.startCopilot()
            } label: {
                Label("案内を開始", systemImage: "location.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("この画面での操作案内を開始")
            .accessibilityHint("同じ会話の内容を引き継いで操作案内を開始します")
        }
    }

    private var ask: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // A real field surface, which is what macOS uses to say "text goes
            // in here" — the editor draws no background of its own, so without
            // this it is an invisible box on the card.
            SendableTextEditor(
                text: $session.input,
                focusedField: $session.focusedField,
                field: .navigator,
                onSend: session.sendQuestion,
                onEscape: onClose
            )
            .frame(minHeight: 34, maxHeight: 72)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )

            PanelSendButton(
                accessibilityLabel: "Visionへの質問を送信",
                help: "質問を送信（Enter）",
                isEnabled: session.canSend,
                action: session.sendQuestion
            )
        }
    }

    /// The most recent thing the user said, unless it was the gesture itself.
    /// Pointing is shown by the mark and a sweep by its own highlight;
    /// repeating either as a chip would be the bubble telling the user what
    /// they just did.
    private var latestQuestion: String? {
        guard let turn = session.turns.last(where: { $0.role == .user }) else { return nil }
        guard turn.text != VisionSession.pointedHereText,
              turn.text != VisionSession.sweptTextHereText else { return nil }
        return turn.text
    }

    private var latestAnswer: String? {
        session.turns.last(where: { $0.role == .assistant })?.text
    }
}

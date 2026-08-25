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
    /// How much room the answer may take, decided by the caller from the screen
    /// this is being shown on. Passed in rather than read here: a view that
    /// measured the screen itself could disagree with the one the overlay
    /// covers, and on two displays those are different heights.
    let answerHeightBudget: CGFloat
    let onClose: () -> Void

    /// What the question being typed currently needs. The field grows with it:
    /// a fixed box shows the user three lines of their own sentence and hides
    /// the rest of what they are about to send.
    @State private var inputContentHeight: CGFloat = VisionBubbleView.inputMinHeight

    private static let answerFontSize: CGFloat = 13

    /// The two surfaces inside the bubble, as tone rather than as depth.
    ///
    /// The place to read and the place to type still have to be told apart —
    /// without that the answer, the empty space and the input box are one area
    /// with nothing saying where a click puts a cursor. A shade of the
    /// foreground does it in both appearances without either surface claiming
    /// to be a layer of its own.
    private static let readingSurface = Color.primary.opacity(0.05)
    private static let typingSurface = Color.primary.opacity(0.10)

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

    /// The smallest the answer area gets, whatever is in it.
    ///
    /// A box that hugs its content is why raising the ceiling changed nothing
    /// visible: most answers never reached it, so the reading area was two and a
    /// half lines of a sentence still arriving and the bubble was a sliver. An
    /// explanation is longer than that, and the first delta of a streaming one
    /// is a single character — sizing to it means the bubble grows under the
    /// reader's eyes on every answer.
    ///
    /// Ten lines, so the pane is a place to read before there is anything in it
    /// — never more than the ceiling, which is what a display too small for ten
    /// lines gets instead.
    static func answerMinHeight(within budget: CGFloat) -> CGFloat {
        min(10 * answerLineHeight, answerHeight(within: budget))
    }

    /// Everything in the bubble that is not the answer, at its tallest.
    ///
    /// Derived from the layout below rather than guessed: the handle with its
    /// named close button (44), the body's own padding (24), the gaps between
    /// its rows (30), the sent question's chip (25), the answer surface's
    /// padding (20), the input at its ceiling (160), the guidance button (22)
    /// and the margin the placement keeps on both edges (24). It exists so the
    /// answer can be told how much of the screen is left, instead of being
    /// given a share of it and letting the total run off the top — the
    /// placement can move a bubble that is too tall, but it cannot shrink one.
    ///
    /// An upper bound, and meant to be: no single bubble carries all of these at
    /// once. Being wrong low is what puts the top of the answer above the menu
    /// bar, so it is rounded up whenever the chrome grows.
    static let chromeHeight: CGFloat = 352

    /// How much of the covered screen the answer may take.
    ///
    /// This used to be half the screen, and half was not enough: answers were
    /// scrolling with two thirds of the display standing empty. The rule is now
    /// "as much as is left", with two thirds as the ceiling so a large display
    /// does not get a bubble running from the Dock to the menu bar — the rest
    /// of the screen is the thing the answer is about, which is the reason this
    /// is a bubble on the picture and not a window beside it.
    static func answerHeightBudget(visibleHeight: CGFloat) -> CGFloat {
        min(visibleHeight * 2 / 3, visibleHeight - chromeHeight)
    }

    /// One line plus the field's own insets: what an empty question box is.
    static let inputMinHeight: CGFloat = 34

    /// How tall the question box may be for the height its text needs.
    ///
    /// It follows the text, because the sentence being sent is the one thing in
    /// the bubble the user wrote and cannot re-read anywhere else. The ceiling
    /// is ten lines, and never more than a third of the answer's budget: on a
    /// small display an input taller than the answer would leave the reply with
    /// nothing, and the point of the bubble is the reply.
    static func inputHeight(content: CGFloat, within budget: CGFloat) -> CGFloat {
        let ceiling = max(inputMinHeight, min(160, budget / 3))
        return min(max(content, inputMinHeight), ceiling)
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
                        // The product's own purple, not the system accent: the
                        // chip is the user's own words in the one place the
                        // product speaks, and iris is what that place is made
                        // of. State never borrows it — this is not state.
                        .background(MarkStyle.swiftUIColor, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("送信した質問: \(question)")
                }
                // Two surfaces, because there are two jobs: this is the place to
                // read, the field below is the place to type. Both sat directly
                // on the card, which made the answer, the empty space and the
                // input box one undifferentiated area — there was nothing to
                // tell the user where a click would put a cursor.
                //
                // Told apart by tone alone. `controlBackgroundColor` and
                // `textBackgroundColor` with a hairline around each read as two
                // panes stacked on the card, and the bubble then had depth
                // inside it as well as under it — a card floating over the
                // screen, holding two more cards. One shadow in the whole thing,
                // and it belongs to the bubble.
                ViewThatFits(in: .vertical) {
                    answer
                    ScrollView { answer }
                }
                // Top-left, not centre: with a floor under it a short answer
                // would otherwise sit in the middle of its own box, which reads
                // as a caption rather than as the start of an explanation.
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.answerMinHeight(within: answerHeightBudget),
                    maxHeight: Self.answerHeight(within: answerHeightBudget),
                    alignment: .topLeading
                )
                .padding(10)
                .background(Self.readingSurface, in: RoundedRectangle(cornerRadius: 10))
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
            // Named, not just an ×. This is the way out of a mode that has taken
            // over the whole screen, and a bare glyph in a corner asks the user
            // to guess what dismissing it does — whether the explanation goes
            // away, or the wash, or the app. "終了" was avoided for the same
            // reason: it reads as quitting the application.
            Button(action: onClose) {
                HStack(spacing: 5) {
                    Label("解説を閉じる", systemImage: "xmark")
                        .font(.system(size: 11))
                    // The key, on the button, the way a menu item carries its
                    // equivalent. A tooltip only teaches somebody who already
                    // waited on the control long enough to be told, and Esc is
                    // the thing a user reaches for first when a mode has taken
                    // the screen.
                    Text("Esc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .arrowCursorOnHover()
            .accessibilityLabel("解説を閉じる")
            .help("この解説モードを抜けます（Esc）")
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
            Label(session.isPointing ? "ここを読んでいます…" : "画面を読んでいます…", systemImage: "eye")
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
            .tint(MarkStyle.swiftUIColor)
            .controlSize(.small)
            .arrowCursorOnHover()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("この画面での操作案内を開始")
            .accessibilityHint("同じ会話の内容を引き継いで操作案内を開始します")
        }
    }

    /// Enter sends, Shift+Enter breaks the line, and there is no button.
    ///
    /// The editor has behaved this way since it was written, so the button was
    /// a second way to do the one thing the keyboard already did — and it took
    /// width from the field on the narrowest surface in the product. Messenger
    /// apps settled this convention long ago; the help text on the field is
    /// what carries it for somebody who has not met it.
    private var ask: some View {
        // The microphone lives inside the field's own surface rather than beside
        // it: the two share one background, so it reads as part of the place you
        // type rather than as a control that happens to sit next to it.
        HStack(alignment: .bottom, spacing: 0) {
            editor
            DictationButton(
                isRecording: session.isRecording,
                isTranscribing: session.isTranscribing,
                action: { session.onToggleDictation?() }
            )
            .padding(.trailing, 8)
            .padding(.bottom, 7)
        }
        .background(Self.typingSurface, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Visionへの質問")
        .help("Enterで送信、Shift+Enterで改行")
    }

    private var editor: some View {
        // The editor draws no background of its own, which is why the surface
        // above exists: without it this is an invisible box on the card.
        SendableTextEditor(
            text: $session.input,
            focusedField: $session.focusedField,
            field: .navigator,
            onSend: session.sendQuestion,
            onEscape: onClose,
            onContentHeightChange: { height in
                // Compared before it is assigned: the editor reports on
                // every update as well as on every keystroke, and an
                // unconditional write would restart the update it was
                // reported from.
                guard abs(height - inputContentHeight) > 0.5 else { return }
                inputContentHeight = height
            }
        )
        .frame(
            height: Self.inputHeight(
                content: inputContentHeight,
                within: answerHeightBudget
            )
        )
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

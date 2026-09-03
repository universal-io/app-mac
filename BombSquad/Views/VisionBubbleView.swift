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
    /// One condition of the account, read by every surface from the same place.
    @ObservedObject private var availability = GatewayAvailability.shared
    /// How much room the answer may take, decided by the caller from the screen
    /// this is being shown on. Passed in rather than read here: a view that
    /// measured the screen itself could disagree with the one the overlay
    /// covers, and on two displays those are different heights.
    let answerHeightBudget: CGFloat
    let onClose: () -> Void
    /// The face on the user's side of the thread, already loaded. Injected, not
    /// read from the account here: the bubble is measured in tests without an
    /// account, and the coordinator is the one place that already knows who is
    /// signed in.
    var userAvatar: NSImage? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the question being typed currently needs. The field grows with it:
    /// a fixed box shows the user three lines of their own sentence and hides
    /// the rest of what they are about to send.
    @State private var inputContentHeight: CGFloat = VisionBubbleView.inputMinHeight

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
    /// state chip and named close button (44), the body's own padding (24), the
    /// gaps between its rows (40), guidance's status row (52), the input at its
    /// ceiling (160), the guidance button (22) and the margin the placement
    /// keeps on both edges (24). The question chip and the answer pane's own
    /// padding (45 together) moved into the thread, which is measured by the
    /// answer budget; the number is kept rather than lowered, since being wrong
    /// low is the failure this guards against. It exists so the answer can be told
    /// how much of the screen is left, instead of being given a share of it and
    /// letting the total run off the top — the placement can move a bubble that
    /// is too tall, but it cannot shrink one.
    ///
    /// An upper bound, and meant to be: no single bubble carries all of these at
    /// once. Being wrong low is what puts the top of the answer above the menu
    /// bar, so it is rounded up whenever the chrome grows.
    static let chromeHeight: CGFloat = 422

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
                if let refusal = availability.refusal {
                    ServiceRefusalBanner(message: refusal)
                }
                // The conversation, newest at the bottom, on the card's own
                // ground: each thing said has its own surface now, so the
                // pane that used to hold one answer is gone. Plain when it
                // fits — the empty part then belongs to the drag — and
                // scrolling when it does not, with its end kept in view,
                // because the end is where the words are arriving.
                ViewThatFits(in: .vertical) {
                    thread
                    ScrollViewReader { proxy in
                        ScrollView {
                            thread
                            Color.clear.frame(height: 1).id(Self.threadEnd)
                        }
                        .onAppear { proxy.scrollTo(Self.threadEnd, anchor: .bottom) }
                        .onChange(of: threadRows) {
                            proxy.scrollTo(Self.threadEnd, anchor: .bottom)
                        }
                    }
                }
                // Top-left, not centre: with a floor under it a short thread
                // would otherwise sit in the middle of its own box, which reads
                // as a caption rather than as the start of an exchange.
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.answerMinHeight(within: answerHeightBudget),
                    maxHeight: Self.answerHeight(within: answerHeightBudget),
                    alignment: .topLeading
                )
                guidanceStatus
                ask
                startGuidance
            }
            .padding(12)
        }
        .frame(width: VisionPointingOverlay.bubbleWidth, alignment: .leading)
        // Everything that is not a control or the field the user types in is a
        // place to pick the bubble up by. It sits over whatever the user is
        // trying to look at — that is the price of putting the answer beside
        // its subject — so moving it out of the way has to be possible from
        // wherever the hand happens to be, not from one small grip. Buttons,
        // the editor and the answer's own text are in front of this and take
        // their clicks first; the surfaces behind them opt out of hit testing
        // so that everything else falls through to here.
        //
        // No label on it. A grip that has to be labelled is not a grip
        // (`app-web/docs/pointing.md` §3).
        .background(WindowDragHandle())
        // The card itself — one definition, shared with Compose's bubble
        // (`BubbleChrome`): why it is opaque, and why the shadow belongs to the
        // window, is written there.
        .bubbleChrome()
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
            stateChip
            Spacer(minLength: 0)
            BubbleCloseButton(action: onClose)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// Which of the two states this is, named — both of them.
    ///
    /// The web client learned this the hard way: it labelled one state and let
    /// the label's absence stand for the other, and nobody could read the
    /// absence (`app-web/docs/solo-mode.md` §1). The wash already says
    /// "pointing" to anyone who knows the product; the chip says it to anyone
    /// who does not, and says "案内" once the wash is gone and a click will
    /// press things. The cross on this chip goes back to pointing; the one at
    /// the far right of the bar ends the session. Two exits on one bar, told
    /// apart by where they sit rather than by wording: this one is inside the
    /// purple token, against the word it dismisses.
    ///
    /// Guidance wears the product's purple: it is "the actions that lead to
    /// this", which is what the colour means. Pointing wears none — it is not
    /// an action and not a state of anything, it is where the product rests.
    @ViewBuilder
    private var stateChip: some View {
        if session.isCopilotActive {
            HStack(spacing: 6) {
                // "案内中", and the icon beats: this is a mode the user is in
                // right now, with the screen live under it, and a still label
                // reads as a heading rather than as a state. Still under Reduce
                // Motion, like every other beat in the product.
                Label {
                    Text("案内中")
                } icon: {
                    Image(systemName: "location.fill")
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                Button {
                    session.leaveGuidance()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .arrowCursorOnHover()
                .accessibilityLabel("案内を終える")
                .hoverHint(
                    "案内を終えて、画面を指せる状態に戻ります",
                    alignment: .bottomLeading,
                    offset: CGSize(width: 0, height: 28)
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(MarkStyle.swiftUIColor).allowsHitTesting(false))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("案内中")
        } else {
            Label("解説", systemImage: "eye")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(BubbleSurface.reading).allowsHitTesting(false))
                .allowsHitTesting(false)
                .accessibilityLabel("解説中")
        }
    }

    /// What guidance is doing, and the one button it needs.
    ///
    /// The strip's status line, moved here with the strip's retirement (R15):
    /// the frame on the real screen says where, this says what is being waited
    /// for, and 再確認 is for the actions the click monitor cannot see —
    /// keyboard ones, and clicks on another display.
    @ViewBuilder
    private var guidanceStatus: some View {
        if session.isCopilotActive {
            // The note about an unchanged screen is a row of the thread now
            // (`VisionThreadRow.note`), beside the step it qualifies.
            // Outcomes only. "Click where the frame is; the screen is checked
            // automatically afterwards" and the two progress lines described
            // the pipeline to somebody who can already see the frame, and the
            // wait itself is the thread's last row now. What remains is what
            // the user could not know otherwise: arrived, stuck, or asked.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let statusText {
                        Image(systemName: statusIcon)
                            .foregroundStyle(.secondary)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if session.copilotState != .complete, session.copilotState != .stepLimit {
                        Button {
                            session.requestCopilotProgressCheck()
                        } label: {
                            Label("再確認", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(session.isCopilotChecking)
                        .arrowCursorOnHover()
                        .hoverHint(
                            "いまの画面をもう一度確認します",
                            alignment: .bottomTrailing,
                            offset: CGSize(width: 0, height: 30)
                        )
                    }
                }
            }
        }
    }

    private var statusText: String? {
        switch session.copilotState {
        case .idle, .waitingForChange, .evaluating:
            // The frame says where, the thread's last row says the screen is
            // being read. Nothing to add.
            return nil
        case .timedOut:
            return "画面を撮影できませんでした。「再確認」を押してください"
        case .complete:
            return "目的に到達しました"
        case .clarification:
            return "案内をご確認ください。進める場合はそのまま操作すると続きます"
        case .stepLimit:
            return "案内の回数が上限に達しました。目的を絞ってもう一度質問してください"
        }
    }

    private var statusIcon: String {
        switch session.copilotState {
        case .complete:
            return "checkmark.circle.fill"
        case .timedOut, .clarification, .stepLimit:
            return "exclamationmark.circle"
        default:
            return "cursorarrow.click.2"
        }
    }

    /// The way into guidance for a typed question the model answered rather
    /// than guided.
    ///
    /// A guide answer opens guidance by itself (`VisionSession.opensGuidance`);
    /// this is for the other case, where the user still wants to be walked
    /// there. Pressing it lifts the wash and asks for the first step, because
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
            .hoverHint(
                "幕が消え、次に押す場所を枠で示します",
                alignment: .bottomTrailing,
                offset: CGSize(width: 0, height: 30)
            )
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
        // The one surface that keeps its clicks. Everywhere else in the bubble
        // is a place to pick it up by; here a press has to put a cursor in the
        // sentence being written.
        .background(BubbleSurface.typing, in: RoundedRectangle(cornerRadius: 8))
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

    private static let threadEnd = "thread-end"

    /// The conversation as rows: what was said, and the one trailing row for
    /// what is happening now. The rules are `VisionThreadRow.rows` and are
    /// pinned there; this only hands over the session's state.
    private var threadRows: [VisionThreadRow] {
        VisionThreadRow.rows(
            turns: session.turns,
            streamingMessage: session.streamingMessage,
            isLoading: session.isLoading,
            isPointing: session.isPointing,
            isCopilotChecking: session.isCopilotChecking,
            errorMessage: session.errorMessage,
            refusal: availability.refusal,
            copilotSawNoChange: session.copilotSawNoChange
        )
    }

    private var thread: some View {
        VisionThreadView(
            rows: threadRows,
            userAvatar: userAvatar,
            fontSize: Self.answerFontSize
        )
    }
}

import AppKit
import SwiftUI

/// R18: the companion's window (決定2). Bottom-right of the working screen,
/// above ordinary windows, and never brought to the front of the user's app on
/// its own — the conversation happens beside the work, not in front of it.
///
/// It is a bubble like Vision's and Compose's (owner, 2026-10-09): the same
/// thread, the same width, text that can be selected and copied, and a height
/// that follows the conversation until it scrolls. A fixed two-line strip made
/// the companion's answers useless whenever the answer was the point — 「これ
/// 英語でなんて言えば」 gave a sentence the user could neither read in full nor
/// copy into Slack.
///
/// Its two window controls are its own, at the top left where the OS keeps
/// them (owner, 2026-10-11): × ends the companion, and the expand button zooms
/// — up to the screen's height, about two and a half bubbles wide, in the
/// middle, so a long conversation can be read as a whole — and, pressed again,
/// puts the window back where it was. Builds 28–29 used the OS's own buttons;
/// a window that cannot go to the Dock shows a disabled yellow between red
/// and green, and green wears a + for zoom, and neither could be changed.
@MainActor
final class CompanionPanelController {
    static var width: CGFloat { VisionPointingOverlay.bubbleWidth }
    private static let margin: CGFloat = 24
    /// Zoomed: wide enough to see the conversation's flow, narrow enough that
    /// a line of it can still be read in one sweep (rows run the full width).
    private static let zoomedWidth: CGFloat = 950

    private var panel: CompanionPanel?
    private var host: NSHostingView<CompanionView>?
    private var reflow: Timer?
    private let layout = CompanionWindowLayout()
    /// Where the window was before it zoomed: its bottom-left corner, which is
    /// the corner the height grows from.
    private var unzoomedOrigin: NSPoint?
    /// A zoom is in motion; another press waits for it to land.
    private var zooming = false
    /// The height this class last gave the window. Measured against this,
    /// never against the window's own frame: with the hosting view as the
    /// window's content, AppKit resized the window to the view's size keeping
    /// the top edge, this class put the point back keeping the bottom edge, and
    /// the window crept up the screen a point every tenth of a second (build
    /// 23 on the device).
    private var placedHeight: CGFloat = 0

    /// The window's frame on screen, while it is shown.
    var frame: NSRect? { panel?.frame }

    func show(_ session: CompanionSession, on screen: NSScreen?, onClose: @escaping () -> Void) {
        close()
        let panel = CompanionPanel()
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let host = NSHostingView(rootView: CompanionView(
            session: session,
            layout: layout,
            visibleHeight: bounds.height,
            onClose: onClose,
            onZoom: { [weak self] in self?.toggleZoom() }
        ))
        // The SwiftUI view's own ideal size, kept current as the content
        // changes — the measurement Vision's and Compose's bubbles use.
        host.sizingOptions = [.intrinsicContentSize]
        // Inside a plain view, as Vision's bubble is: the window's size is this
        // class's alone to set, and AppKit does not follow the hosting view's
        // size on its own.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 1))
        // The view follows the window through a zoom, frame by frame: laid
        // out for the final size from the first frame, it was clipped to the
        // growing window and looked as if it stretched sideways first and
        // then up (build 30 on the device).
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        let height = Self.height(of: host)
        panel.setFrame(
            NSRect(
                x: bounds.maxX - Self.margin - Self.width,
                y: bounds.minY + Self.margin,
                width: Self.width,
                height: height
            ),
            display: false
        )
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        placedHeight = height
        panel.orderFrontRegardless()
        self.panel = panel
        self.host = host
        // AppKit does not tell a window that a hosting view's content got
        // taller. Same cadence as the other bubbles.
        reflow = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followContent() }
        }
    }

    func close() {
        reflow?.invalidate()
        reflow = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
        placedHeight = 0
        layout.zoomed = nil
        unzoomedOrigin = nil
        zooming = false
    }

    /// The expand button. Zooming keeps nothing of the small window but where
    /// it was; coming back, the height is the conversation's again. The view
    /// fills the window throughout (`layout.zoomed` is set for the whole
    /// motion), and the window moves through its own animator rather than the
    /// blocking `setFrame(_:display:animate:)`, which would hold the run loop
    /// — and with it the companion's audio and socket — for the duration.
    private func toggleZoom() {
        guard let panel, let host, !zooming else { return }
        let origin: NSPoint
        let size: NSSize
        let landed: () -> Void
        if layout.zoomed == nil {
            let bounds = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
            size = NSSize(
                width: min(Self.zoomedWidth, bounds.width - Self.margin * 2),
                height: bounds.height - Self.margin * 2
            )
            origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.minY + Self.margin)
            unzoomedOrigin = panel.frame.origin
            layout.zoomed = size
            landed = {}
        } else {
            // The bubble's own height, measured with the view as a bubble,
            // then the view fills the shrinking window down to that size.
            layout.zoomed = nil
            host.layoutSubtreeIfNeeded()
            size = NSSize(width: Self.width, height: Self.height(of: host))
            layout.zoomed = size
            origin = unzoomedOrigin ?? panel.frame.origin
            unzoomedOrigin = nil
            landed = { [weak self] in self?.layout.zoomed = nil }
        }
        let frame = NSRect(origin: origin, size: size)
        zooming = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            panel.setFrame(frame, display: true)
            host.frame = NSRect(origin: .zero, size: frame.size)
            panel.invalidateShadow()
            placedHeight = frame.height
            landed()
            zooming = false
        })
    }

    /// The conversation grew or shrank. The window keeps its bottom edge —
    /// the corner it sits in, or wherever the user dragged it — and grows up,
    /// away from the Dock, like a chat whose newest line is at the bottom.
    private func followContent() {
        // Zoomed, the window is the screen's height and the thread scrolls.
        guard layout.zoomed == nil, let panel, let host, panel.isVisible else { return }
        let height = Self.height(of: host)
        guard abs(height - placedHeight) > 0.5 else { return }
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        host.frame = NSRect(x: 0, y: 0, width: frame.width, height: height)
        placedHeight = height
    }

    /// The taller of the two answers AppKit will give, plus a point for the
    /// final line's descender — the other bubbles' measurement.
    private static func height(of host: NSView) -> CGFloat {
        max(host.intrinsicContentSize.height, host.fittingSize.height) + 1
    }
}

/// Whether the window is zoomed, and to what size — the view lays itself out
/// for the one the controller chose.
@MainActor
final class CompanionWindowLayout: ObservableObject {
    @Published var zoomed: NSSize?
}

/// Non-activating: a click leaves the user's app the active one. It can
/// become key, because copying what was selected (⌘C) needs the keyboard, and
/// it does so only when clicked — showing it never takes the keyboard away.
///
final class CompanionPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: CompanionPanelController.width, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct CompanionView: View {
    @ObservedObject var session: CompanionSession
    @ObservedObject var layout: CompanionWindowLayout
    /// The screen's visible height, for how tall the conversation may grow.
    let visibleHeight: CGFloat
    let onClose: () -> Void
    let onZoom: () -> Void
    /// The copy button's tick, shown for a moment after a copy.
    @State private var copied = false
    /// What is being typed, and the field's state, as Vision's bubble keeps them.
    @State private var draft = ""
    @State private var focusedField: FocusField?
    @State private var inputContentHeight: CGFloat = 0

    /// The thread's own size, as in Vision's bubble.
    private static let fontSize: CGFloat = 13
    private static let threadEnd = "thread-end"

    /// The strip the window controls sit in.
    private static let controlsHeight: CGFloat = 24
    /// Each control answers a click anywhere in a 24pt square, the size of a
    /// toolbar button's target, while its glyph stays where an 18pt one put
    /// it (the row is pulled out by the difference). At 18pt the collapse
    /// button missed clicks on the owner's Mac (build 31); a replica took
    /// every click, so the cause is not known, and the larger target is the
    /// remedy that holds whatever it was.
    private static let controlTarget: CGFloat = 24
    /// The glyphs' type size: × at 12 and the diagonal arrows at 10 both ink
    /// 9.5pt square (measured, 2026-10-11); at the default 13 the arrows were
    /// 12 against the ×'s 10 and the two read as different sizes.
    private static let closeGlyph = Font.system(size: 12, weight: .medium)
    private static let zoomGlyph = Font.system(size: 10, weight: .medium)
    private static let sideGlyph = Font.system(size: 12, weight: .medium)
    /// Everything that is not the conversation: the controls strip (24), the
    /// header row (50), the input at its smallest (34), the window's padding
    /// and the gaps (54), and the margins kept from the screen's edges (48),
    /// rounded up — wrong low would put the header above the menu bar.
    private static let chromeHeight: CGFloat = 214

    /// As much of the screen as is left, two thirds at most, on whole lines —
    /// Vision's rule (`VisionBubbleView.answerHeightBudget`), with this
    /// window's own chrome.
    private var threadHeight: CGFloat {
        // A taller input takes its lines from the conversation, not the screen.
        let grownInput = max(0, inputHeight - VisionBubbleView.inputMinHeight)
        let budget = min(visibleHeight * 2 / 3, visibleHeight - Self.chromeHeight - grownInput)
        return VisionBubbleView.answerHeight(within: budget)
    }

    private var inputHeight: CGFloat {
        VisionBubbleView.inputHeight(content: inputContentHeight, within: visibleHeight * 2 / 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            header
            conversation
            input
        }
        .padding(12)
        // A bubble of its own size, or — zoomed, and while zooming — the
        // window's size, whatever it is at the moment.
        .frame(width: layout.zoomed == nil ? CompanionPanelController.width : nil)
        .frame(
            maxWidth: layout.zoomed == nil ? nil : .infinity,
            maxHeight: layout.zoomed == nil ? nil : .infinity,
            alignment: .top
        )
        .bubbleChrome()
    }

    /// The window's controls on the left, where the OS keeps a window's; the
    /// conversation's own on the right, on the same line.
    private var controls: some View {
        HStack(spacing: 10 - (Self.controlTarget - 18)) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(Self.closeGlyph)
                    .frame(width: Self.controlTarget, height: Self.controlTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("終了（右Shift 2回でも終わります）")
            Button(action: onZoom) {
                Image(systemName: layout.zoomed == nil
                    ? "arrow.up.left.and.arrow.down.right"
                    : "arrow.down.right.and.arrow.up.left")
                    .font(Self.zoomGlyph)
                    .frame(width: Self.controlTarget, height: Self.controlTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(layout.zoomed == nil ? "広げる" : "元の大きさに戻す")
            Spacer(minLength: 0)
            // The voice's two switches, and only those: text is always there.
            // On is the ordinary glyph, off is grey and struck through — state,
            // so not the product's purple (`MarkStyle`).
            Button(action: session.toggleMute) {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(Self.sideGlyph)
                    .foregroundStyle(session.isMuted ? .secondary : .primary)
                    .frame(width: Self.controlTarget, height: Self.controlTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(session.isMuted ? "マイクをオンにする" : "マイクをオフにする（文字で話しかけられます）")
            Button(action: session.toggleSpeaker) {
                Image(systemName: session.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(Self.sideGlyph)
                    .foregroundStyle(session.isSpeakerOn ? .primary : .secondary)
                    .frame(width: Self.controlTarget, height: Self.controlTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(session.isSpeakerOn ? "読み上げをオフにする（文字だけで答えます）" : "読み上げをオンにする")
        }
        .frame(height: Self.controlsHeight)
        .padding(.horizontal, -(Self.controlTarget - 18) / 2)
    }

    private var header: some View {
        HStack(spacing: 10) {
            CompanionAvatar(phase: session.phase, inputLevel: session.inputLevel)
            VStack(alignment: .leading, spacing: 2) {
                Text("山田")
                    .font(.headline)
                Text(session.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // The knowledge the eye applied is always visible
                // (master plan R18 決定2; no silent injection). The line
                // is always there so the header keeps its size.
                Text(session.skillName.map { "Skill: \($0)" } ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Selection stops at the edge of one message (each is its own
            // text), so the whole conversation is one click away instead.
            Button(action: copyConversation) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(Self.sideGlyph)
                    .frame(width: Self.controlTarget, height: Self.controlTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(session.transcript.lines.isEmpty)
            .help("会話をすべてコピー")
        }
    }

    /// Text is always there: Enter sends, Shift+Enter breaks the line — Vision's
    /// field, on Vision's surface. Typed while the companion talks, the words
    /// are in the thread at once and go to it when it has finished.
    private var input: some View {
        SendableTextEditor(
            text: $draft,
            focusedField: $focusedField,
            field: .companion,
            onSend: sendDraft,
            onContentHeightChange: { height in
                // Compared before it is assigned, as in Vision's bubble: the
                // editor reports on every update, and an unconditional write
                // would restart the update it was reported from.
                guard abs(height - inputContentHeight) > 0.5 else { return }
                inputContentHeight = height
            }
        )
        .frame(height: inputHeight)
        .background(BubbleSurface.typing, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("相棒への入力")
        .help("Enterで送信、Shift+Enterで改行")
    }

    private func sendDraft() {
        if session.send(typed: draft) { draft = "" }
    }

    /// Plain while it fits, scrolling once it does not, with the newest line
    /// kept in view — the newest line is where the words are arriving.
    private var conversation: some View {
        ViewThatFits(in: .vertical) {
            thread
            ScrollViewReader { proxy in
                ScrollView {
                    thread
                    Color.clear.frame(height: 1).id(Self.threadEnd)
                }
                .onAppear { proxy.scrollTo(Self.threadEnd, anchor: .bottom) }
                .onChange(of: rows) {
                    proxy.scrollTo(Self.threadEnd, anchor: .bottom)
                }
            }
        }
        // Zoomed, the window's height is fixed and the thread takes the rest.
        .frame(
            maxWidth: .infinity,
            maxHeight: layout.zoomed == nil ? threadHeight : .infinity,
            alignment: .topLeading
        )
    }

    private var thread: some View {
        VisionThreadView(rows: rows, userAvatar: nil, fontSize: Self.fontSize)
    }

    /// The conversation in the other bubbles' rows: the user on the right,
    /// the companion on the left, selectable both; then what is happening now.
    private var rows: [VisionThreadRow] {
        var rows: [VisionThreadRow] = session.transcript.lines.map { line in
            let id = Self.rowID(line.id)
            switch line.speaker {
            case .user: return .user(id: id, text: line.text)
            case .companion: return .assistant(id: id, text: line.text)
            }
        }
        if let failure = session.failureMessage {
            rows.append(.error(failure))
        } else if let notice = session.notice {
            rows.append(.note(notice))
        } else if session.phase == .looking {
            rows.append(.waiting("画面を確認しています"))
        } else if rows.isEmpty {
            rows.append(.hint(session.isMuted ? "下の欄に入力してください" : "話しかけるか、下の欄に入力してください"))
        }
        return rows
    }

    /// Who said what, in order, as plain text for the clipboard.
    private func copyConversation() {
        let text = session.transcript.lines
            .map { "\($0.speaker == .user ? "あなた" : "山田"): \($0.text)" }
            .joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// A line's number as the row's identity, stable while its text grows.
    private static func rowID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", number)) ?? UUID()
    }
}

/// Presence without a face: a ring that follows the microphone while
/// listening and breathes while speaking. Neutral on purpose — the purple is
/// reserved for "here, this" (`MarkStyle`) and is not lent to a state.
private struct CompanionAvatar: View {
    let phase: CompanionSession.Phase
    let inputLevel: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: (phase != .speaking && phase != .looking) || reduceMotion)) { context in
            let breath = (sin(context.date.timeIntervalSinceReferenceDate * 6) + 1) / 2
            let reach: CGFloat = {
                switch phase {
                case .speaking: return reduceMotion ? 3 : 2 + 4 * breath
                case .listening, .hearing: return CGFloat(inputLevel) * 6
                case .looking: return reduceMotion ? 2 : 1 + 2 * breath
                default: return 0
                }
            }()
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(phase == .speaking ? 0.35 : 0.2), lineWidth: 2)
                    .frame(width: 36 + reach * 2, height: 36 + reach * 2)
                Circle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: "person.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 50, height: 50)
            .opacity(phase == .connecting || phase == .reconnecting ? 0.5 : 1)
        }
    }
}

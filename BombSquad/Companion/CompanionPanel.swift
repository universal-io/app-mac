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
/// Its frame is the OS's (owner, 2026-10-10): the real red and green buttons at
/// the top left, light or dark as the system is. Green zooms rather than going
/// full screen — up to the screen's height, about two and a half bubbles wide,
/// in the middle, so a long conversation can be read as a whole — and green
/// again puts it back where it was.
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
        panel.onClose = onClose
        panel.onZoom = { [weak self] in self?.toggleZoom() }
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let host = NSHostingView(rootView: CompanionView(
            session: session,
            layout: layout,
            visibleHeight: bounds.height
        ))
        // The SwiftUI view's own ideal size, kept current as the content
        // changes — the measurement Vision's and Compose's bubbles use.
        host.sizingOptions = [.intrinsicContentSize]
        // The content runs under the title bar, and the title strip in it is
        // where the buttons sit. Left to SwiftUI, the whole view moved down by
        // the title bar's height and the OS's buttons hung over a see-through
        // strip above the window (build 28 on the device).
        host.safeAreaRegions = []
        // Inside a plain view, as Vision's bubble is: the window's size is this
        // class's alone to set, and AppKit does not follow the hosting view's
        // size on its own.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 1))
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
    }

    /// The green button. Zooming keeps nothing of the small window but where
    /// it was; coming back, the height is the conversation's again.
    private func toggleZoom() {
        guard let panel, let host else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if layout.zoomed == nil {
            let bounds = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
            let size = NSSize(
                width: min(Self.zoomedWidth, bounds.width - Self.margin * 2),
                height: bounds.height - Self.margin * 2
            )
            unzoomedOrigin = panel.frame.origin
            layout.zoomed = size
            place(NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.minY + Self.margin,
                width: size.width,
                height: size.height
            ), animate: !reduceMotion)
        } else {
            layout.zoomed = nil
            // The view is a bubble again; its height is measured from it.
            host.layoutSubtreeIfNeeded()
            let origin = unzoomedOrigin ?? panel.frame.origin
            unzoomedOrigin = nil
            place(NSRect(
                x: origin.x,
                y: origin.y,
                width: Self.width,
                height: Self.height(of: host)
            ), animate: !reduceMotion)
        }
    }

    private func place(_ frame: NSRect, animate: Bool) {
        guard let panel, let host else { return }
        panel.setFrame(frame, display: true, animate: animate)
        panel.invalidateShadow()
        host.frame = NSRect(origin: .zero, size: frame.size)
        placedHeight = frame.height
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
/// Titled for the OS's own buttons, with the title bar see-through and the
/// content under it. The window draws its own background, corners and edge, as
/// Xcode's does (the owner's model, 2026-10-10) — not a card drawn inside a
/// clear window. Resizable only because AppKit enables the green button for
/// resizable windows: dragging an edge does nothing (`windowWillResize`), the
/// size is the conversation's or the zoom's. Not miniaturizable, so the yellow
/// shows disabled, as the OS shows it on any window that cannot go to the
/// Dock; hiding it left a gap between red and green (build 28).
final class CompanionPanel: NSPanel, NSWindowDelegate {
    var onClose: () -> Void = {}
    var onZoom: () -> Void = {}

    /// The height of the title bar the content runs under, where the buttons
    /// sit.
    static let titlebarHeight: CGFloat = {
        let content = NSRect(x: 0, y: 0, width: 100, height: 100)
        let frame = NSWindow.frameRect(forContentRect: content, styleMask: [.titled, .closable])
        return frame.height - content.height
    }()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: CompanionPanelController.width, height: 1),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        delegate = self
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Red ends the companion, as the hotkey does — not just this window.
    override func performClose(_ sender: Any?) { onClose() }
    /// Green, and a double-click on the title bar.
    override func zoom(_ sender: Any?) { onZoom() }
    override func miniaturize(_ sender: Any?) {}

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        sender.frame.size
    }
}

struct CompanionView: View {
    @ObservedObject var session: CompanionSession
    @ObservedObject var layout: CompanionWindowLayout
    /// The screen's visible height, for how tall the conversation may grow.
    let visibleHeight: CGFloat
    /// The copy button's tick, shown for a moment after a copy.
    @State private var copied = false

    /// The thread's own size, as in Vision's bubble.
    private static let fontSize: CGFloat = 13
    private static let threadEnd = "thread-end"

    /// Everything that is not the conversation: the title bar, the header row
    /// (50), the window's padding and the gap (22), and the margins kept from
    /// the screen's edges (48), rounded up — wrong low would put the header
    /// above the menu bar.
    private static let chromeHeight: CGFloat = 128 + CompanionPanel.titlebarHeight

    /// As much of the screen as is left, two thirds at most, on whole lines —
    /// Vision's rule (`VisionBubbleView.answerHeightBudget`), with this
    /// window's own chrome.
    private var threadHeight: CGFloat {
        let budget = min(visibleHeight * 2 / 3, visibleHeight - Self.chromeHeight)
        return VisionBubbleView.answerHeight(within: budget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: 10) {
                header
                conversation
            }
        }
        .padding([.horizontal, .bottom], 12)
        .frame(
            width: layout.zoomed?.width ?? CompanionPanelController.width,
            height: layout.zoomed?.height
        )
        .ignoresSafeArea()
    }

    /// The strip the OS's buttons sit in on the left; the conversation's own
    /// controls on the right, on the same line.
    private var titleBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            // Selection stops at the edge of one message (each is its own
            // text), so the whole conversation is one click away instead.
            Button(action: copyConversation) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(session.transcript.lines.isEmpty)
            .help("会話をすべてコピー")
            Button(action: session.toggleMute) {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(session.isMuted ? "ミュートを解除" : "ミュート")
        }
        .frame(height: CompanionPanel.titlebarHeight)
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
        }
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
            rows.append(.hint("話しかけてください"))
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

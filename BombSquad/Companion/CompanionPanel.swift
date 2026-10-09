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
@MainActor
final class CompanionPanelController {
    static var width: CGFloat { VisionPointingOverlay.bubbleWidth }
    private static let margin: CGFloat = 24

    private var panel: CompanionPanel?
    private var host: NSHostingView<CompanionView>?
    private var reflow: Timer?

    /// The window's frame on screen, while it is shown.
    var frame: NSRect? { panel?.frame }

    func show(_ session: CompanionSession, on screen: NSScreen?, onClose: @escaping () -> Void) {
        close()
        let panel = CompanionPanel()
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let host = NSHostingView(rootView: CompanionView(
            session: session,
            visibleHeight: bounds.height,
            onClose: onClose
        ))
        // The SwiftUI view's own ideal size, kept current as the content
        // changes — the measurement Vision's and Compose's bubbles use.
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: 1)
        panel.contentView = host
        panel.setFrame(
            NSRect(
                x: bounds.maxX - Self.margin - Self.width,
                y: bounds.minY + Self.margin,
                width: Self.width,
                height: Self.height(of: host)
            ),
            display: false
        )
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
    }

    /// The conversation grew or shrank. The window keeps its bottom edge —
    /// the corner it sits in, or wherever the user dragged it — and grows up,
    /// away from the Dock, like a chat whose newest line is at the bottom.
    private func followContent() {
        guard let panel, let host, panel.isVisible else { return }
        let height = Self.height(of: host)
        guard abs(height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// The taller of the two answers AppKit will give, plus a point for the
    /// final line's descender — the other bubbles' measurement.
    private static func height(of host: NSView) -> CGFloat {
        max(host.intrinsicContentSize.height, host.fittingSize.height) + 1
    }
}

/// Non-activating: a click leaves the user's app the active one. It can
/// become key, because copying what was selected (⌘C) needs the keyboard, and
/// it does so only when clicked — showing it never takes the keyboard away.
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
    /// The screen's visible height, for how tall the conversation may grow.
    let visibleHeight: CGFloat
    let onClose: () -> Void

    /// The thread's own size, as in Vision's bubble.
    private static let fontSize: CGFloat = 13
    private static let threadEnd = "thread-end"

    /// Everything that is not the conversation: the header row (50), the
    /// window's padding and the gap (34), and the margins kept from the
    /// screen's edges (48), rounded up — wrong low would put the header above
    /// the menu bar.
    private static let chromeHeight: CGFloat = 140

    /// As much of the screen as is left, two thirds at most, on whole lines —
    /// Vision's rule (`VisionBubbleView.answerHeightBudget`), with this
    /// window's own chrome.
    private var threadHeight: CGFloat {
        let budget = min(visibleHeight * 2 / 3, visibleHeight - Self.chromeHeight)
        return VisionBubbleView.answerHeight(within: budget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Spacer(minLength: 8)
                Button(action: session.toggleMute) {
                    Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(session.isMuted ? "ミュートを解除" : "ミュート")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("終了（右Shift 2回でも終わります）")
            }
            conversation
        }
        .padding(12)
        .frame(width: CompanionPanelController.width)
        .bubbleChrome()
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
        .frame(maxWidth: .infinity, maxHeight: threadHeight, alignment: .topLeading)
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
        } else if session.phase == .looking {
            rows.append(.waiting("画面を確認しています"))
        } else if rows.isEmpty {
            rows.append(.hint("話しかけてください"))
        }
        return rows
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

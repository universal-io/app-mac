import AppKit
import SwiftUI

/// R18: the companion's small window (決定2). Bottom-right of the working
/// screen, above ordinary windows, and never taking focus from the app the
/// user is working in — the conversation happens beside the work, not in
/// front of it.
@MainActor
final class CompanionPanelController {
    static let width: CGFloat = 320
    private static let margin: CGFloat = 24

    private var panel: CompanionPanel?

    /// The window's frame on screen, while it is shown.
    var frame: NSRect? { panel?.frame }

    func show(_ session: CompanionSession, on screen: NSScreen?, onClose: @escaping () -> Void) {
        close()
        let panel = CompanionPanel()
        let host = NSHostingView(rootView: CompanionView(session: session, onClose: onClose))
        let size = host.fittingSize
        panel.contentView = host
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(
            NSRect(
                x: bounds.maxX - Self.margin - Self.width,
                y: bounds.minY + Self.margin,
                width: Self.width,
                height: size.height
            ),
            display: false
        )
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Non-activating, so a click on mute or close leaves the user's app in front.
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
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct CompanionView: View {
    @ObservedObject var session: CompanionSession
    let onClose: () -> Void

    /// Fixed so the window never grows or shrinks under the user's eye:
    /// two lines of conversation, each at most two lines, the newest words kept.
    private static let conversationHeight: CGFloat = 76

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
                    // is always there so the window keeps its size.
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

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = session.failureMessage {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if session.transcript.recent.isEmpty {
                Text("話しかけてください")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            ForEach(session.transcript.recent) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.speaker == .user ? "あなた" : "山田")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    Text(line.text)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .frame(
            maxWidth: .infinity,
            minHeight: Self.conversationHeight,
            maxHeight: Self.conversationHeight,
            alignment: .topLeading
        )
        .background(BubbleSurface.reading, in: RoundedRectangle(cornerRadius: 10))
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

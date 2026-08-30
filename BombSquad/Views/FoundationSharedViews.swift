import AppKit
import SwiftUI

/// Names the skill that shaped the answer on screen. A skill is injected
/// knowledge about the product the user is looking at, and it is named wherever
/// it acts: knowledge the user cannot see is knowledge they cannot correct or
/// distrust. Every panel that consumes skills shows the same chip.
struct ActiveSkillLabel: View {
    let skillName: String
    let help: String

    var body: some View {
        Label(skillName, systemImage: "puzzlepiece.extension")
            .font(.caption)
            .foregroundStyle(.secondary)
            .hoverHint(help, alignment: .bottomLeading, offset: CGSize(width: 0, height: 28))
            .accessibilityLabel("適用中のスキル: \(skillName)")
    }
}

/// Keeps the detected tool and its supporting information in the same trailing
/// position across Compose, Vision, and other transient panel surfaces.
struct PanelToolInfo<PopoverContent: View>: View {
    let toolName: String?
    let toolHelp: String
    let informationHelp: String
    let informationAccessibilityLabel: String
    @ViewBuilder let popoverContent: () -> PopoverContent

    @State private var isShowingInformation = false

    var body: some View {
        HStack(spacing: 8) {
            if let toolName {
                ActiveSkillLabel(skillName: toolName, help: toolHelp)
            }

            Button {
                isShowingInformation.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .arrowCursorOnHover()
            .hoverHint(
                informationHelp,
                alignment: .bottomLeading,
                offset: CGSize(width: 0, height: 28)
            )
            .accessibilityLabel(informationAccessibilityLabel)
            .popover(isPresented: $isShowingInformation, arrowEdge: .bottom) {
                popoverContent()
            }
        }
    }
}

/// Shared popover chrome for selectable, optionally copyable panel details.
struct PanelInformationPopover<Content: View>: View {
    let title: String
    let copyText: String?
    let note: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let copyText {
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(copyText, forType: .string)
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("表示情報をすべてコピー")
                }
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(14)
    }
}

/// Selectable error text shared by all transient panel modes.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.red)
    }
}

/// A successful request that switched to its secondary model must not look
/// identical to a clean request. The user can dismiss the notice after reading.
struct OperationalNoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("警告を閉じる")
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.orange)
    }
}

/// The microphone, inside the field it types into.
///
/// Dictation was hold-to-talk on a key and nothing else: no button, and the
/// only sign it existed was a red `mic.fill` that appeared *outside* the form
/// once recording had already started. A capability whose sole affordance shows
/// up after you have used it is a capability nobody finds. It sits in the field
/// now, the way every messenger does it, so it is visible before it is needed
/// and reachable by somebody who has never heard of the shortcut.
///
/// Click to start, click again to stop — the key stays hold-to-talk. Two
/// interaction models for one feature is the convention, not a compromise: a
/// held key ends when you let go, and a button has nothing to let go of.
struct DictationButton: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let action: () -> Void

    private var hint: String {
        if isTranscribing { return "文字起こし中…" }
        if isRecording { return "録音中。クリックで停止します" }
        return "音声入力（クリック、または\(KeybindingSettings.gestureKey().hintLabel) 長押し）"
    }

    var body: some View {
        Button(action: action) {
            if isTranscribing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    // Red is state, so it never borrows the product's purple
                    // (`MarkStyle`). Grey until it is doing something is the
                    // whole point: the icon has to be legible as available
                    // rather than as active.
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                    .font(.system(size: 13))
            }
        }
        .buttonStyle(.borderless)
        .arrowCursorOnHover()
        .disabled(isTranscribing)
        .accessibilityLabel(isRecording ? "音声入力を停止" : "音声入力を開始")
        // Drawn rather than asked for. One mechanism in both places: this button
        // lives in the bubble as well as in Compose, and the bubble's window
        // cannot show a system tooltip at all.
        .hoverHint(hint)
    }
}

extension View {
    /// Says the arrow belongs here, because the pointing overlay's panel does
    /// not say it for us.
    ///
    /// The bubble lives in a `.nonactivatingPanel` that can become key but never
    /// main, and AppKit's cursor rectangles do not run for it: whatever last set
    /// the cursor keeps it. The text field sets an I-beam, so every control in
    /// the bubble — the microphone, the close button, the info button — was
    /// reached with an I-beam still showing, which says "type here" over things
    /// you press.
    ///
    /// Set rather than pushed. A push needs a matching pop, and the pop is owed
    /// by a hover that ends — which never arrives if the bubble is torn down
    /// while the pointer is over the control, leaving the whole app holding a
    /// cursor nobody can put back.
    func arrowCursorOnHover() -> some View {
        onHover { inside in
            guard inside else { return }
            NSCursor.arrow.set()
        }
    }
}

extension View {
    /// A hint this window draws itself, because the system's cannot be seen here.
    ///
    /// `.help()` is dead on the pointing overlay, and not because of an ordering
    /// bug that can be fixed: AppKit draws tooltips in **their own window** at
    /// pop-up level, and the overlay panel sits at `.screenSaver` covering the
    /// whole display. The tooltip renders correctly and lands behind the thing
    /// it belongs to, every time, and there is no public way to raise it. The
    /// only hint that can be seen over this panel is one the panel draws.
    ///
    /// Delayed like a tooltip, because a label that appears the instant the
    /// pointer crosses a control reads as the interface twitching.
    func hoverHint(
        _ text: String,
        alignment: Alignment = .top,
        offset: CGSize = CGSize(width: 0, height: -28)
    ) -> some View {
        modifier(HoverHint(text: text, alignment: alignment, offset: offset))
    }
}

private struct HoverHint: ViewModifier {
    let text: String
    let alignment: Alignment
    let offset: CGSize

    @State private var isShown = false
    @State private var reveal: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                reveal?.cancel()
                guard inside else {
                    isShown = false
                    return
                }
                reveal = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    isShown = true
                }
            }
            .overlay(alignment: alignment) {
                if isShown {
                    Text(text)
                        .font(.system(size: 11))
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                        )
                        .offset(offset)
                        // It is a label, not a target: hit testing it would put
                        // a hole in the control it is describing.
                        .allowsHitTesting(false)
                }
            }
    }
}

import SwiftUI

/// The panel, which now exists only for guidance.
///
/// Vision itself moved onto the real screen (R14): a still of the screen beside
/// a conversation made the eye travel between the thing being asked about and
/// the answer, so the answer goes beside the thing instead and the picture is
/// the screen the user is already looking at. What is left here is the copilot
/// strip, which keeps the panel on purpose — guidance has to hand the screen
/// back for every click it asks the user to make, and an overlay that swallows
/// clicks cannot.
struct VisionRootView: View {
    @ObservedObject var session: VisionSession
    @ObservedObject private var authViewModel = AuthViewModel.shared
    @ObservedObject private var noticeCenter = OperationalNoticeCenter.shared

    var body: some View {
        Group {
            if authViewModel.hasSession {
                VStack(spacing: 0) {
                    if let notice = noticeCenter.current {
                        OperationalNoticeBanner(
                            message: notice.message,
                            onDismiss: noticeCenter.dismiss
                        )
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    }
                    // Only the strip. `startCopilot` sets `isCopilotActive`
                    // before requesting the transition that presents this, so
                    // there is no moment where guidance is presented without it.
                    CopilotStripView(session: session)
                }
            } else {
                LoginRequiredView(
                    viewModel: authViewModel,
                    config: BombSquadConfig.snapshot()
                )
            }
        }
        .panelChrome()
    }
}

private struct CopilotStripView: View {
    @ObservedObject var session: VisionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.tint)
                Text("案内中")
                    .font(.caption.weight(.semibold))
                Text(session.copilotGoal ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let skillName = session.activeSkillName {
                    ActiveSkillLabel(
                        skillName: skillName,
                        help: "\(skillName) の知識を参照して案内しています"
                    )
                }
                Button {
                    session.stopCopilot()
                } label: {
                    Label("終了", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            if let errorMessage = session.errorMessage {
                ErrorBanner(message: errorMessage)
            }

            Text(session.latestInstruction)
                .font(.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .textSelection(.enabled)

            if session.copilotSawNoChange {
                Label(
                    "操作は検知しましたが、画面に変化は見えませんでした",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if session.isCopilotChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusIcon)
                        .foregroundStyle(.secondary)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.copilotState != .complete, session.copilotState != .stepLimit {
                    Button {
                        session.requestCopilotProgressCheck()
                    } label: {
                        Label("再確認", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(session.isCopilotChecking)
                }
            }
        }
        .padding(14)
        .background(WindowDragHandle())
    }

    private var statusText: String {
        switch session.copilotState {
        case .idle:
            // A guide turn may legitimately return no target (candidate
            // missing from AX); never point the user at a red frame that
            // does not exist.
            return session.selectedCandidate != nil
                ? "赤い枠の場所をクリックしてください。画面変化を自動で確認します"
                : "案内に従って操作してください。操作後の画面を自動で確認します"
        case .waitingForChange:
            return "クリック後の画面変化と安定を待っています…"
        case .evaluating:
            return "新しい画面から次の案内を確認しています…"
        case .timedOut:
            return "画面を撮影できませんでした。「再確認」を押してください"
        case .complete:
            return "目的の情報を確認しました"
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
}

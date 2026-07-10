import Foundation

enum PanelFlowState {
    case text
    case vision
    case navigator
    case copilot
}

enum PanelPresentation {
    case compose(PanelSession)
    case transform(PanelSession)
    case vision(ReviewViewModel)
    case copilot(ReviewViewModel)
}

enum PanelPlacement {
    case centered
    case bottomTrailing
}

struct PanelLayoutSpec: Equatable {
    let size: CGSize
    let placement: PanelPlacement
}

@MainActor
final class PanelSession: ObservableObject {
    static let textPanelSize = CGSize(width: 680, height: 660)
    static let visionPanelSize = CGSize(width: 960, height: 640)
    static let copilotPanelSize = CGSize(width: 460, height: 240)

    let viewModel: ReviewViewModel

    init(viewModel: ReviewViewModel) {
        self.viewModel = viewModel
    }

    func configurePanelCallbacks(
        onVisionModeExited: @escaping () -> Void,
        onHidePanelForAction: @escaping () -> Void,
        onShowPanelAfterAction: @escaping () -> Void,
        onClosePanelRequested: @escaping () -> Void,
        onCopilotModeChanged: @escaping (Bool) -> Void
    ) {
        viewModel.onVisionModeExited = onVisionModeExited
        viewModel.onHidePanelForAction = onHidePanelForAction
        viewModel.onShowPanelAfterAction = onShowPanelAfterAction
        viewModel.onClosePanelRequested = onClosePanelRequested
        viewModel.onCopilotModeChanged = onCopilotModeChanged
    }

    var mode: ReviewMode {
        viewModel.mode
    }

    var flowState: PanelFlowState {
        if viewModel.navigatorActiveTask != nil {
            return .copilot
        }
        if viewModel.sessionKind == .vision {
            return viewModel.navigatorSessionActive ? .navigator : .vision
        }
        return .text
    }

    var isTextActive: Bool {
        flowState == .text
    }

    var isVisionActive: Bool {
        switch flowState {
        case .vision, .navigator, .copilot:
            return true
        case .text:
            return false
        }
    }

    var canToggleEditorFocus: Bool {
        isTextActive
    }

    var canAcceptDictation: Bool {
        switch flowState {
        case .text, .navigator, .copilot:
            return true
        case .vision:
            return false
        }
    }

    var canStartScreenshotCaptureFromHotkey: Bool {
        viewModel.focusedField == .draft && viewModel.isEmptyDraft && !isVisionActive
    }

    var shouldClosePanelOnHotkeyDoubleTap: Bool {
        isVisionActive
    }

    var panelLayout: PanelLayoutSpec {
        switch flowState {
        case .copilot:
            return PanelLayoutSpec(size: Self.copilotPanelSize, placement: .bottomTrailing)
        case .vision, .navigator:
            return PanelLayoutSpec(size: Self.visionPanelSize, placement: .centered)
        case .text:
            return PanelLayoutSpec(size: Self.textPanelSize, placement: .centered)
        }
    }

    var shouldAutoReviewAfterLogin: Bool {
        mode == .transform
            && viewModel.result == nil
            && !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var presentation: PanelPresentation {
        switch flowState {
        case .copilot:
            return .copilot(viewModel)
        case .vision, .navigator:
            return .vision(viewModel)
        case .text:
            switch mode {
            case .compose:
                return .compose(self)
            case .transform:
                return .transform(self)
            }
        }
    }

    func beginScreenshotCapture() {
        viewModel.isCapturingScreenshot = true
        viewModel.needsScreenCapturePermission = false
        viewModel.errorMessage = nil
    }

    func handleCapturedScreenshot(_ attachment: ScreenshotAttachment) {
        viewModel.addScreenshotAttachment(attachment)
    }

    func finishScreenshotCapture() {
        viewModel.isCapturingScreenshot = false
    }

    func failScreenshotCapture(message: String) {
        viewModel.errorMessage = message
    }

    func prepareForPresentation(contextTask: Task<SituationalContext?, Never>) {
        viewModel.restorePersistedDraftIfNeeded()
        viewModel.attachContextCapture(contextTask)
    }

    func applyPrefill(_ text: String, autoReviewIfAuthenticated: Bool) {
        viewModel.draft = text
        guard autoReviewIfAuthenticated, mode == .transform else { return }
        Task { await viewModel.runReview() }
    }

    func handlePanelWillClose() {
        viewModel.onVisionModeExited = nil
        viewModel.onHidePanelForAction = nil
        viewModel.onShowPanelAfterAction = nil
        viewModel.onClosePanelRequested = nil
        viewModel.onCopilotModeChanged = nil
        viewModel.panelWillClose()
    }

    func toggleEditorFocus() {
        guard canToggleEditorFocus else { return }
        viewModel.toggleFocusedField()
    }

    func requestReviewFromHotkey() {
        viewModel.requestReviewFromHotkey()
    }

    func requestPanelClose() {
        if let onClosePanelRequested = viewModel.onClosePanelRequested {
            onClosePanelRequested()
        } else {
            NotificationCenter.default.post(name: .closePanel, object: nil)
        }
    }

    func requestScreenshotCapture() {
        NotificationCenter.default.post(name: .captureScreenshot, object: nil)
    }

    func requestScreenCaptureSettings() {
        NotificationCenter.default.post(name: .openScreenCaptureSettings, object: nil)
    }

    func markDraftFocusedIfNeeded() {
        guard isTextActive else { return }
        viewModel.focusedField = .draft
    }

    func markScreenCapturePermissionRequired(_ required: Bool) {
        viewModel.needsScreenCapturePermission = required
    }
}

import AppKit
import Foundation

struct CoreNavigatorDisplayTurn: Identifiable {
    let id = UUID()
    let role: NavigateTurn.Role
    let text: String
}

struct CoreNavigatorAction: Equatable {
    enum Kind: Equatable {
        case press
        case fill(text: String)
    }

    let kind: Kind
    let targetLabel: String
    let globalRect: CGRect?

    var buttonTitle: String {
        switch kind {
        case .press:
            return "「\(targetLabel)」を押す"
        case .fill:
            return "「\(targetLabel)」に入力する"
        }
    }
}

private struct CoreNavigatorHighlightResolution {
    let panelBox: CGRect?
    let liveBox: CGRect?
}

enum CopilotCaptureState: Equatable {
    case idle
    case waitingForChange
    case settling
    case timedOut
}

private enum CopilotProgressCaptureOutcome {
    case stable(ScreenshotAttachment)
    case timedOut
}

/// Phase 3-c/d screenshot interpretation state. It owns the legacy split:
/// Navigator-first when available, one-shot Vision only as fallback, plus
/// Copilot on top of the same screenshot session.
@MainActor
final class VisionSession: ObservableObject {
    @Published private(set) var attachment: ScreenshotAttachment
    @Published private(set) var result: VisionInterpretationResult?
    @Published private(set) var isInterpreting = false
    @Published var errorMessage: String?
    @Published private(set) var lastDurationMs: Int?
    @Published private(set) var lastModelName: String?
    @Published private(set) var situationalContext: SituationalContext?
    @Published private(set) var isContextExcluded = false
    @Published private(set) var navigatorTurns: [CoreNavigatorDisplayTurn] = []
    @Published private(set) var navigatorStreamingText: String?
    @Published var navigatorInput = ""
    @Published private(set) var isNavigating = false
    @Published private(set) var panelNavigatorHighlight: CGRect?
    @Published private(set) var navigatorProposedAction: CoreNavigatorAction?
    @Published private(set) var navigatorProposedTask: NavigatorTask?
    @Published private(set) var navigatorActiveTask: NavigatorTask?
    @Published private(set) var isExecutingNavigatorAction = false
    @Published private(set) var isCopilotChecking = false
    @Published private(set) var copilotCaptureState: CopilotCaptureState = .idle
    @Published var focusedField: FocusField? = nil
    @Published var isRecording = false
    @Published var isTranscribing = false

    private let deployer: Deployer
    private let fallbackTargetPID: pid_t?
    private let overrideProvider: VisionProvider?
    private let onEditSuggestedAction: (String) -> Void
    private let onRequestModeTransition: (AppMode, String) -> Void
    private let onRequestPanelClose: () -> Void
    private let onHidePanelForAction: () -> Void
    private let onShowPanelAfterAction: () -> Void

    private var contextCaptureTask: Task<SituationalContext?, Never>?
    private var interpretationTask: Task<Void, Never>?
    private var hasStartedInitialFlow = false

    private var navigatorWireTurns: [NavigateTurn] = []
    private var navigatorPendingCapture: NavigateTurn?
    private var navigatorOCRFragments: [RecognizedTextFragment] = []
    private var navigatorTask: Task<Void, Never>?
    private var navigatorGeneration = 0
    private var queuedNavigatorQuestion: String?
    private var copilotClickMonitor: Any?
    private var copilotRecaptureTask: Task<Void, Never>?
    private var copilotProgressGeneration = 0
    private var liveNavigatorHighlight: CGRect?
    private var didSaveNavigatorSession = false

    let outputLanguage: OutputLanguage
    private static let copilotCaptureSampleDelayNanoseconds: UInt64 = 350_000_000
    private static let copilotCaptureSettleComparisons = 1
    private static let copilotCaptureMaxAttempts = 8
    private static let copilotChangeThreshold = 0.015
    private static let copilotStableThreshold = 0.003
    private static let copilotComparisonSide = 48

    init(
        attachment: ScreenshotAttachment,
        deployer: Deployer,
        contextCaptureTask: Task<SituationalContext?, Never>,
        fallbackTargetPID: pid_t? = nil,
        provider: VisionProvider? = nil,
        onRequestModeTransition: @escaping (AppMode, String) -> Void = { _, _ in },
        onRequestPanelClose: @escaping () -> Void = {},
        onHidePanelForAction: @escaping () -> Void = {},
        onShowPanelAfterAction: @escaping () -> Void = {},
        onEditSuggestedAction: @escaping (String) -> Void
    ) {
        self.attachment = attachment
        self.deployer = deployer
        self.contextCaptureTask = contextCaptureTask
        self.fallbackTargetPID = fallbackTargetPID
        self.overrideProvider = provider
        self.onRequestModeTransition = onRequestModeTransition
        self.onRequestPanelClose = onRequestPanelClose
        self.onHidePanelForAction = onHidePanelForAction
        self.onShowPanelAfterAction = onShowPanelAfterAction
        self.onEditSuggestedAction = onEditSuggestedAction
        self.outputLanguage = AppSettings.outputLanguage()

        Task { [weak self] in
            let context = await contextCaptureTask.value
            guard !Task.isCancelled else { return }
            self?.situationalContext = context
        }
    }

    var isNavigatorAvailable: Bool {
        AppSettings.isNavigatorEnabled() && GatewayNavigateClient.make() != nil
    }

    var canSendNavigatorQuestion: Bool {
        !navigatorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isNavigating
    }

    var hasNavigatorConversation: Bool {
        !navigatorTurns.isEmpty
            || navigatorStreamingText != nil
            || navigatorPendingCapture != nil
            || navigatorProposedTask != nil
            || navigatorActiveTask != nil
            || isNavigating
    }

    var isCopilotActive: Bool {
        navigatorActiveTask != nil
    }

    func startInitialFlowIfNeeded() {
        guard !hasStartedInitialFlow else { return }
        hasStartedInitialFlow = true

        if isNavigatorAvailable {
            focusedField = .navigator
            prepareNavigatorCapture(
                attachment,
                autoRun: AppSettings.isNavigatorAutoFirstTurnEnabled()
            )
        } else {
            requestInterpretation()
        }
    }

    func requestInterpretation() {
        interpretationTask?.cancel()
        interpretationTask = Task { [weak self] in
            await self?.runInterpretation()
        }
    }

    func excludeContext() {
        isContextExcluded = true
    }

    func requestPanelClose() {
        onRequestPanelClose()
    }

    /// Saves an explicit copy of the temporary capture at the user's chosen
    /// location. Captures are never written to a permanent location implicitly.
    func saveScreenshotAs() {
        let sourceURL = attachment.url
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
        }
    }

    func appendTranscription(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if navigatorInput.isEmpty {
            navigatorInput = piece
        } else if navigatorInput.last?.isWhitespace == true {
            navigatorInput += piece
        } else {
            navigatorInput += " \(piece)"
        }
        focusedField = .navigator
    }

    func approveSuggestedAction(_ action: VisionSuggestedAction) {
        guard action.hasDraft else { return }
        let text = action.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try deployer.deploy(text)
            Task {
                await LocalHistoryStore.shared.record(HistoryEntryInput(
                    mode: .compose,
                    sourceText: text,
                    finalText: text,
                    modelID: nil,
                    modelName: lastModelName,
                    outputLanguage: outputLanguage.displayName,
                    action: .sent
                ))
            }
        } catch {
            errorMessage = "デプロイに失敗しました: \(error.localizedDescription)"
        }
    }

    func editSuggestedAction(_ action: VisionSuggestedAction) {
        guard action.hasDraft else { return }
        onEditSuggestedAction(action.draft)
    }

    func sendNavigatorQuestion() {
        guard isNavigatorAvailable else { return }
        let question = navigatorInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isNavigating else { return }

        clearNavigatorHighlights()
        navigatorProposedAction = nil
        navigatorInput = ""
        focusedField = .navigator
        onRequestModeTransition(.navigator, "navigatorQuestion")

        if navigatorPendingCapture == nil && navigatorWireTurns.isEmpty {
            queuedNavigatorQuestion = question
            isNavigating = true
            navigatorStreamingText = ""
            prepareNavigatorCapture(attachment, autoRun: false)
            return
        }

        beginNavigatorQuestion(question)
    }

    func startProposedNavigation() {
        guard let task = navigatorProposedTask, !isNavigating else { return }
        isNavigating = true
        navigatorStreamingText = ""
        navigatorProposedTask = nil
        navigatorActiveTask = task
        navigatorProposedAction = nil
        clearNavigatorHighlights()
        navigatorTurns.append(CoreNavigatorDisplayTurn(
            role: .user,
            text: "（ナビゲーション開始: \(task.goal)）"
        ))
        navigatorWireTurns.append(NavigateTurn(
            role: .user,
            text: "案内を開始します。現在の画面に対して次に取るべき操作を案内してください。"
        ))
        enterCopilotMode()
        navigatorTask?.cancel()
        navigatorTask = Task { [weak self] in
            await self?.runNavigatorStream()
        }
    }

    func dismissProposedNavigation() {
        navigatorProposedTask = nil
    }

    func requestCopilotProgressCheck() {
        guard isCopilotActive else { return }
        startCopilotProgressCheck(after: 0)
    }

    func approveNavigatorAction() {
        guard let action = navigatorProposedAction, !isExecutingNavigatorAction else { return }
        isExecutingNavigatorAction = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isExecutingNavigatorAction = false }
            guard let pid = await self.resolveActionPID() else {
                self.errorMessage = "操作対象のアプリを特定できませんでした。"
                return
            }

            onHidePanelForAction()
            try? await Task.sleep(nanoseconds: 150_000_000)
            do {
                switch action.kind {
                case .press:
                    let pressedFrame = try await AXActionService.press(
                        pid: pid,
                        label: action.targetLabel,
                        near: action.globalRect
                    )
                    if let pressedFrame {
                        HighlightOverlayPresenter.shared.show(around: pressedFrame, duration: 0.5)
                    }
                case .fill(let text):
                    try await AXActionService.focusTextInput(
                        pid: pid,
                        label: action.targetLabel,
                        near: action.globalRect
                    )
                    try await Task.sleep(nanoseconds: 250_000_000)
                    let deployer = PasteDeployer(
                        targetApp: NSRunningApplication(processIdentifier: pid),
                        onDismiss: {}
                    )
                    try deployer.deploy(text)
                }
                navigatorProposedAction = nil
                navigatorTurns.append(CoreNavigatorDisplayTurn(
                    role: .user,
                    text: "（\(action.buttonTitle) を実行しました）"
                ))
                saveNavigatorSessionIfNeeded()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                HighlightOverlayPresenter.shared.hide()
                onRequestPanelClose()
            } catch {
                onShowPanelAfterAction()
                errorMessage =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func tearDown() {
        interpretationTask?.cancel()
        interpretationTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        resetNavigatorSession()
    }

    private func runInterpretation() async {
        errorMessage = nil
        result = nil
        isInterpreting = true
        let started = Date()
        defer { isInterpreting = false }

        let context = await resolveContext()
        let memory = await resolveMemory(context: context)
        guard !Task.isCancelled else { return }
        let provider = currentProvider()

        do {
            let interpreted = try await provider.interpret(
                imageURL: attachment.url,
                instruction: nil,
                language: outputLanguage,
                context: context,
                memory: memory
            )
            try Task.checkCancellation()
            lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
            lastModelName = provider is GatewayVisionClient
                ? "I//O Cloud"
                : "OpenAI · \(interpreted.modelID ?? AppSettings.selectedVisionModelID())"
            result = interpreted
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func beginNavigatorQuestion(_ question: String) {
        isNavigating = true
        navigatorStreamingText = ""
        navigatorTurns.append(CoreNavigatorDisplayTurn(role: .user, text: question))

        if var pending = navigatorPendingCapture {
            pending.text = question
            navigatorPendingCapture = nil
            navigatorWireTurns.append(pending)
        } else {
            navigatorWireTurns.append(NavigateTurn(role: .user, text: question))
        }
        navigatorTask?.cancel()
        navigatorTask = Task { [weak self] in
            await self?.runNavigatorStream()
        }
    }

    private func prepareNavigatorCapture(_ attachment: ScreenshotAttachment, autoRun: Bool) {
        navigatorTask?.cancel()
        navigatorGeneration += 1
        let generation = navigatorGeneration
        let environmentTask = SituationalContextService.environmentTask(
            preferredPID: situationalContext?.pid ?? fallbackTargetPID
        )
        navigatorTask = Task { [weak self] in
            guard let self else { return }
            async let imageAsync = GatewayNavigateClient.preparedImage(from: attachment.url)
            async let ocrAsync = ScreenTextRecognizer.recognize(at: attachment.url)
            let environment = await environmentTask.value
            let image = await imageAsync
            let ocr = await ocrAsync
            guard !Task.isCancelled, generation == self.navigatorGeneration else { return }
            guard image != nil || ocr != nil else {
                self.isNavigating = false
                self.navigatorStreamingText = nil
                self.errorMessage = "最新の画面を推論用に準備できませんでした。撮り直してください。"
                return
            }

            self.navigatorOCRFragments = ocr?.fragments ?? []
            let turn = NavigateTurn(
                role: .user,
                text: nil,
                imageBase64: image?.base64,
                mediaType: image?.mediaType,
                ocrText: ocr?.joinedText,
                observation: VisionObservation.make(
                    attachment: attachment,
                    environment: environment,
                    ocr: ocr
                )
            )
            if autoRun {
                self.navigatorWireTurns.append(turn)
                await self.runNavigatorStream()
            } else {
                self.navigatorPendingCapture = turn
                if let queued = self.queuedNavigatorQuestion {
                    self.queuedNavigatorQuestion = nil
                    self.beginNavigatorQuestion(queued)
                } else {
                    self.isNavigating = false
                    self.navigatorStreamingText = nil
                }
            }
        }
    }

    private func appendNavigatorCapture(_ attachment: ScreenshotAttachment) {
        self.attachment = attachment
        clearNavigatorHighlights()
        navigatorProposedAction = nil
        navigatorTurns.append(CoreNavigatorDisplayTurn(
            role: .user,
            text: "（画面を撮り直しました）"
        ))
        prepareNavigatorCapture(attachment, autoRun: true)
    }

    private func enterCopilotMode() {
        guard copilotClickMonitor == nil else { return }
        copilotClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleCopilotProgressCheck()
            }
        }
        onRequestModeTransition(.copilot, "copilotStarted")
    }

    private func exitCopilotMode(notifyCoordinator: Bool = true) {
        if let monitor = copilotClickMonitor {
            NSEvent.removeMonitor(monitor)
            copilotClickMonitor = nil
        }
        copilotRecaptureTask?.cancel()
        copilotRecaptureTask = nil
        copilotProgressGeneration += 1
        isCopilotChecking = false
        setCopilotCaptureState(.idle)
        clearNavigatorHighlights()
        if notifyCoordinator {
            onRequestModeTransition(.navigator, "copilotStopped")
        }
    }

    private func scheduleCopilotProgressCheck() {
        guard isCopilotActive, !isExecutingNavigatorAction else { return }
        startCopilotProgressCheck(after: 1_200_000_000)
    }

    private func startCopilotProgressCheck(after delayNanoseconds: UInt64) {
        copilotRecaptureTask?.cancel()
        copilotProgressGeneration += 1
        let generation = copilotProgressGeneration
        isCopilotChecking = true
        errorMessage = nil
        setCopilotCaptureState(.waitingForChange)
        clearNavigatorHighlights()
        copilotRecaptureTask = Task { [weak self] in
            guard let self else { return }
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, generation == self.copilotProgressGeneration else { return }
            await self.performCopilotProgressCapture(generation: generation)
        }
    }

    private func performCopilotProgressCapture(generation: Int) async {
        guard isCopilotActive,
              generation == copilotProgressGeneration,
              !Task.isCancelled,
              !isNavigating else {
            if generation == copilotProgressGeneration {
                isCopilotChecking = false
                copilotRecaptureTask = nil
            }
            return
        }
        defer {
            if generation == copilotProgressGeneration {
                isCopilotChecking = false
                copilotRecaptureTask = nil
            }
        }
        do {
            liveNavigatorHighlight = nil
            HighlightOverlayPresenter.shared.hide()
            try await Task.sleep(nanoseconds: 180_000_000)
            let baseline = attachment
            let outcome = try await captureCopilotProgressAttachment(baseline: baseline)
            guard isCopilotActive,
                  !Task.isCancelled,
                  generation == copilotProgressGeneration else { return }
            switch outcome {
            case .stable(let capture):
                setCopilotCaptureState(.idle)
                appendNavigatorCapture(capture)
            case .timedOut:
                setCopilotCaptureState(.timedOut)
                errorMessage = "画面の変化が安定する前に確認期限を超えました。反映後に「撮り直す」で再確認してください。"
            }
        } catch is CancellationError {
            return
        } catch {
            if generation == copilotProgressGeneration {
                NSLog("[Copilot] auto progress capture failed: %@", String(describing: error))
            }
        }
    }

    private func captureCopilotProgressAttachment(
        baseline: ScreenshotAttachment
    ) async throws -> CopilotProgressCaptureOutcome {
        let displayID = copilotCaptureDisplayID()
        let captureService = ScreenshotCaptureService()
        var lastChangedCapture: ScreenshotAttachment?
        var previousChangedCapture: ScreenshotAttachment?
        var changeDetected = false
        var stableComparisons = 0

        for attempt in 0..<Self.copilotCaptureMaxAttempts {
            let current = try await captureService.captureFullScreen(displayID: displayID)
            try Task.checkCancellation()

            if !changeDetected {
                let difference = await Self.captureDifferenceRatio(baseline.url, current.url)
                if difference >= Self.copilotChangeThreshold {
                    changeDetected = true
                    lastChangedCapture = current
                    setCopilotCaptureState(.settling)
                    NSLog("[Copilot] progress change detected (diff=%.4f, attempt=%d)", difference, attempt + 1)
                } else {
                    Self.removeDiscardedCapture(current)
                }
            } else if let previousChangedCapture {
                let difference = await Self.captureDifferenceRatio(previousChangedCapture.url, current.url)
                if difference <= Self.copilotStableThreshold {
                    stableComparisons += 1
                } else {
                    stableComparisons = 0
                }
                if let previous = lastChangedCapture, previous.id != previousChangedCapture.id {
                    Self.removeDiscardedCapture(previous)
                }
                lastChangedCapture = current
                if stableComparisons >= Self.copilotCaptureSettleComparisons {
                    Self.removeDiscardedCapture(previousChangedCapture)
                    NSLog("[Copilot] progress screen stabilized (diff=%.4f, attempt=%d)", difference, attempt + 1)
                    return .stable(current)
                }
            }

            if let changed = lastChangedCapture, changed.id != previousChangedCapture?.id {
                if let previousChangedCapture {
                    Self.removeDiscardedCapture(previousChangedCapture)
                }
                previousChangedCapture = changed
            }

            if attempt < Self.copilotCaptureMaxAttempts - 1 {
                try await Task.sleep(nanoseconds: Self.copilotCaptureSampleDelayNanoseconds)
            }
        }

        if let lastChangedCapture {
            Self.removeDiscardedCapture(lastChangedCapture)
        }
        if let previousChangedCapture, previousChangedCapture.id != lastChangedCapture?.id {
            Self.removeDiscardedCapture(previousChangedCapture)
        }
        NSLog(
            "[Copilot] progress capture timed out (%@)",
            changeDetected ? "screen never settled" : "screen never changed"
        )
        return .timedOut
    }

    private func copilotCaptureDisplayID() -> CGDirectDisplayID {
        if let rect = attachment.captureRect {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            for screen in NSScreen.screens {
                if let id = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID,
                   CGDisplayBounds(id).contains(center) {
                    return id
                }
            }
        }
        return CGMainDisplayID()
    }

    private func setCopilotCaptureState(_ state: CopilotCaptureState) {
        guard copilotCaptureState != state else { return }
        copilotCaptureState = state
        NSLog("[Copilot] progress state -> %@", String(describing: state))
    }

    private nonisolated static func captureDifferenceRatio(_ lhs: URL, _ rhs: URL) async -> Double {
        await Task.detached(priority: .utility) {
            guard let left = grayscalePixels(at: lhs),
                  let right = grayscalePixels(at: rhs),
                  left.count == right.count,
                  !left.isEmpty else { return 1 }
            let totalDifference = zip(left, right).reduce(0) { partial, pair in
                partial + abs(Int(pair.0) - Int(pair.1))
            }
            let maxDifference = left.count * 255
            guard maxDifference > 0 else { return 1 }
            return Double(totalDifference) / Double(maxDifference)
        }.value
    }

    private nonisolated static func grayscalePixels(at url: URL) -> [UInt8]? {
        guard let data = try? Data(contentsOf: url),
              let source = NSBitmapImageRep(data: data),
              let image = source.cgImage,
              let context = CGContext(
                  data: nil,
                  width: copilotComparisonSide,
                  height: copilotComparisonSide,
                  bitsPerComponent: 8,
                  bytesPerRow: copilotComparisonSide,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: copilotComparisonSide,
                height: copilotComparisonSide
            )
        )
        guard let buffer = context.data else { return nil }
        let pointer = buffer.bindMemory(
            to: UInt8.self,
            capacity: copilotComparisonSide * copilotComparisonSide
        )
        return Array(
            UnsafeBufferPointer(
                start: pointer,
                count: copilotComparisonSide * copilotComparisonSide
            )
        )
    }

    private nonisolated static func removeDiscardedCapture(_ attachment: ScreenshotAttachment) {
        try? FileManager.default.removeItem(at: attachment.url)
    }

    private func runNavigatorStream() async {
        guard !Task.isCancelled else { return }
        guard let client = GatewayNavigateClient.make() else {
            isNavigating = false
            navigatorStreamingText = nil
            errorMessage = "ナビゲーターには I//O Cloud へのログインが必要です。"
            return
        }
        isNavigating = true
        navigatorStreamingText = ""
        errorMessage = nil
        navigatorProposedAction = nil
        navigatorGeneration += 1
        let generation = navigatorGeneration
        let started = Date()
        var firstTokenMs: Int?
        defer {
            if generation == navigatorGeneration {
                isNavigating = false
                navigatorStreamingText = nil
            }
        }

        let context = await resolveContext()
        guard generation == navigatorGeneration, !Task.isCancelled else { return }
        do {
            let stream = try await client.navigateStream(
                turns: navigatorWireTurns,
                hints: isContextExcluded ? nil : context,
                language: outputLanguage,
                task: navigatorActiveTask
            )
            var finalText: String?
            var harness: String?
            var modelID: String?
            var plannedTask: NavigatorTask?
            for try await event in stream {
                guard generation == navigatorGeneration, !Task.isCancelled else { return }
                switch event {
                case .delta(let text):
                    if firstTokenMs == nil {
                        firstTokenMs = Int(Date().timeIntervalSince(started) * 1000)
                        lastDurationMs = firstTokenMs
                    }
                    navigatorStreamingText = (navigatorStreamingText ?? "") + text
                case .result(let text, let resultHarness, let resultModelID, let resultTask):
                    finalText = text
                    harness = resultHarness
                    modelID = resultModelID
                    plannedTask = resultTask
                }
            }
            guard let finalText else {
                throw ProviderError.decoding("stream ended without a result")
            }
            guard generation == navigatorGeneration, !Task.isCancelled else { return }

            let (displayText, vlmBox, target, fill, stepDone) = NavigatorLocator.extract(from: finalText)
            navigatorWireTurns.append(NavigateTurn(role: .assistant, text: finalText))
            navigatorTurns.append(CoreNavigatorDisplayTurn(role: .assistant, text: displayText))

            let copilotTurn = isCopilotActive
            if stepDone, var active = navigatorActiveTask {
                active.currentStep += 1
                if active.isFinished {
                    navigatorActiveTask = nil
                    navigatorTurns.append(CoreNavigatorDisplayTurn(
                        role: .user,
                        text: "（ナビゲーション完了: \(active.goal)）"
                    ))
                    exitCopilotMode()
                } else {
                    navigatorActiveTask = active
                }
            }

            if let plannedTask, navigatorActiveTask == nil {
                navigatorProposedTask = plannedTask
            }

            let grounding: (target: String?, resolution: CoreNavigatorHighlightResolution)
            if copilotTurn {
                let expectedTarget = currentNavigatorTaskTarget()
                if shouldSuppressCopilotHighlight(
                    text: displayText,
                    responseTarget: target,
                    expectedTarget: expectedTarget,
                    fill: fill,
                    stepDone: stepDone
                ) {
                    grounding = (nil, CoreNavigatorHighlightResolution(panelBox: nil, liveBox: nil))
                } else if stepDone {
                    let responseMatchesExpected = expectedTarget.map {
                        target.map(Self.matchKey) == Self.matchKey($0)
                    } ?? false
                    let trustedVLMBox = responseMatchesExpected ? vlmBox : nil
                    grounding = (
                        expectedTarget,
                        resolveHighlight(target: expectedTarget, vlmBox: trustedVLMBox)
                    )
                } else {
                    grounding = (target, resolveHighlight(target: target, vlmBox: vlmBox))
                }
            } else {
                grounding = (target, resolveHighlight(target: target, vlmBox: vlmBox))
            }

            panelNavigatorHighlight = grounding.resolution.panelBox
            liveNavigatorHighlight = grounding.resolution.liveBox
            if let box = grounding.resolution.liveBox, isCopilotActive || !copilotTurn {
                showLiveHighlight(for: box, persistent: isCopilotActive)
            } else {
                liveNavigatorHighlight = nil
                HighlightOverlayPresenter.shared.hide()
            }

            if let target = grounding.target, !isCopilotActive {
                navigatorProposedAction = CoreNavigatorAction(
                    kind: fill.map { .fill(text: $0) } ?? .press,
                    targetLabel: target,
                    globalRect: projectToGlobal(
                        grounding.resolution.liveBox ?? grounding.resolution.panelBox
                    )
                )
            }

            let engineLabel = modelID ?? "I//O Cloud"
            lastModelName = harness.map { "\(engineLabel) · \($0)" } ?? engineLabel
        } catch is CancellationError {
            return
        } catch {
            guard generation == navigatorGeneration, !Task.isCancelled else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func currentNavigatorTaskTarget() -> String? {
        guard let task = navigatorActiveTask,
              task.steps.indices.contains(task.currentStep) else { return nil }
        return task.steps[task.currentStep].target
    }

    private func shouldSuppressCopilotHighlight(
        text: String,
        responseTarget: String?,
        expectedTarget: String?,
        fill: String?,
        stepDone: Bool
    ) -> Bool {
        guard !stepDone, fill == nil else { return false }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let observationCues = [
            "反映されています",
            "表示されています",
            "開いています",
            "見えています",
            "確認してください",
            "確認できます",
            "このまま",
            "あとは",
            "行を確認",
            "数値を確認",
            "比較できます",
            "状態です",
            "まで開いています",
            "読み取れます",
        ]
        let actionCues = [
            "押して",
            "押す",
            "クリック",
            "選択",
            "開き",
            "入力",
            "切り替",
            "展開",
            "移動",
            "スクロール",
            "ドラッグ",
            "タップ",
        ]

        let mentionsObservation = observationCues.contains { normalized.contains($0) }
        let mentionsAction = actionCues.contains { normalized.contains($0) }
        guard mentionsObservation, !mentionsAction else { return false }

        if let expectedTarget, let responseTarget {
            return Self.matchKey(expectedTarget) == Self.matchKey(responseTarget)
        }
        return true
    }

    private func resolveHighlight(target: String?, vlmBox: CGRect?) -> CoreNavigatorHighlightResolution {
        guard let target, !navigatorOCRFragments.isEmpty else {
            return CoreNavigatorHighlightResolution(panelBox: vlmBox, liveBox: vlmBox)
        }
        let needle = Self.matchKey(target)
        guard !needle.isEmpty else {
            return CoreNavigatorHighlightResolution(panelBox: vlmBox, liveBox: vlmBox)
        }

        let ranked = navigatorOCRFragments.compactMap {
            fragment -> (tier: Int, fragment: RecognizedTextFragment)? in
            guard let tier = Self.matchTier(needle: needle, candidate: fragment.text) else {
                return nil
            }
            return (tier, fragment)
        }
        guard let bestTier = ranked.map(\.tier).min() else {
            return CoreNavigatorHighlightResolution(panelBox: vlmBox, liveBox: vlmBox)
        }
        let hits = ranked.filter { $0.tier == bestTier }.map(\.fragment)

        if let vlmBox, hits.count > 1 {
            let center = CGPoint(x: vlmBox.midX, y: vlmBox.midY)
            let nearest = hits.min { lhs, rhs in
                distanceSquared(from: lhs.rect, to: center)
                    < distanceSquared(from: rhs.rect, to: center)
            }?.rect
            return CoreNavigatorHighlightResolution(panelBox: nearest, liveBox: nearest)
        }

        if hits.count == 1 {
            return CoreNavigatorHighlightResolution(panelBox: hits[0].rect, liveBox: hits[0].rect)
        }

        let union = hits
            .map(\.rect)
            .reduce(into: CGRect.null) { partial, rect in
                partial = partial.union(rect)
            }
        let safePanelBox = union.isNull ? nil : union
        return CoreNavigatorHighlightResolution(panelBox: safePanelBox, liveBox: nil)
    }

    static func matchTier(needle: String, candidate: String) -> Int? {
        let key = matchKey(candidate)
        guard !key.isEmpty else { return nil }
        if key == needle { return 0 }
        if key.contains(needle) { return 1 }
        if needle.contains(key), key.count >= 2 { return 2 }
        return nil
    }

    private static func matchKey(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    private func distanceSquared(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return dx * dx + dy * dy
    }

    private func clearNavigatorHighlights() {
        panelNavigatorHighlight = nil
        liveNavigatorHighlight = nil
        HighlightOverlayPresenter.shared.hide()
    }

    private func projectToGlobal(_ box: CGRect?) -> CGRect? {
        guard let box, let capture = attachment.captureRect else { return nil }
        return CGRect(
            x: capture.minX + box.minX * capture.width,
            y: capture.minY + box.minY * capture.height,
            width: box.width * capture.width,
            height: box.height * capture.height
        )
    }

    private func showLiveHighlight(for box: CGRect?, persistent: Bool = false) {
        guard let target = projectToGlobal(box) else { return }
        HighlightOverlayPresenter.shared.show(around: target, duration: persistent ? nil : 2.6)
    }

    private func saveNavigatorSessionIfNeeded() {
        guard !didSaveNavigatorSession else { return }
        let turns = navigatorTurns.map {
            NavigatorSessionRecord.Turn(role: $0.role.rawValue, text: $0.text)
        }
        guard turns.contains(where: { $0.role == "assistant" }) else { return }
        didSaveNavigatorSession = true
        Task.detached(priority: .utility) {
            await NavigatorSessionStore.shared.save(turns: turns)
        }
    }

    private func resetNavigatorSession() {
        saveNavigatorSessionIfNeeded()
        exitCopilotMode(notifyCoordinator: false)
        didSaveNavigatorSession = false
        navigatorTask?.cancel()
        navigatorTask = nil
        navigatorGeneration += 1
        queuedNavigatorQuestion = nil
        navigatorTurns = []
        navigatorWireTurns = []
        navigatorPendingCapture = nil
        navigatorStreamingText = nil
        navigatorInput = ""
        isNavigating = false
        panelNavigatorHighlight = nil
        navigatorOCRFragments = []
        navigatorProposedAction = nil
        navigatorProposedTask = nil
        navigatorActiveTask = nil
        isExecutingNavigatorAction = false
        isCopilotChecking = false
        copilotCaptureState = .idle
        liveNavigatorHighlight = nil
        HighlightOverlayPresenter.shared.hide()
    }

    private func currentProvider() -> VisionProvider {
        if let overrideProvider { return overrideProvider }
        if let gateway = GatewayVisionClient.make() { return gateway }
        return OpenAIVisionClient()
    }

    private func resolveContext() async -> SituationalContext? {
        guard !isContextExcluded else { return nil }
        if situationalContext == nil, let contextCaptureTask {
            situationalContext = await contextCaptureTask.value
        }
        return situationalContext
    }

    private func resolveActionPID() async -> pid_t? {
        if let context = await resolveContext() {
            return context.pid
        }
        return fallbackTargetPID
    }

    private func resolveMemory(context: SituationalContext?) async -> MemoryInjection? {
        guard AppSettings.isMemoryEnabled() else { return nil }
        let persona = try? await MemoryStore.shared.personaCard()

        var relationship: MemoryCard?
        if let context {
            let haystack = [context.windowTitle, context.conversationExcerpt]
                .compactMap { $0 }
                .joined(separator: "\n")
            relationship = try? await MemoryStore.shared.matchRelationship(inText: haystack)
        }

        let injection = MemoryInjection(
            personaMD: persona?.contentMD,
            relationshipSubject: relationship?.subject,
            relationshipMD: relationship?.contentMD
        )
        return injection.isEmpty ? nil : injection
    }
}

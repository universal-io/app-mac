import AppKit
import Foundation
import SwiftUI

/// One turn of the navigator conversation as shown in the panel transcript.
struct NavigatorDisplayTurn: Identifiable {
    let id = UUID()
    let role: NavigateTurn.Role
    let text: String
}

/// An executable step proposed by the navigator, pending user approval.
struct NavigatorAction: Equatable {
    enum Kind: Equatable {
        /// Press the element carrying `targetLabel` (AXPress, click fallback).
        case press
        /// Focus the field carrying `targetLabel` and paste `text` into it.
        case fill(text: String)
    }

    let kind: Kind
    let targetLabel: String
    /// The model's own location estimate projected to global display
    /// coordinates; disambiguates duplicate labels in the AX tree.
    let globalRect: CGRect?

    var buttonTitle: String {
        switch kind {
        case .press: return "「\(targetLabel)」を押す"
        case .fill: return "「\(targetLabel)」に入力する"
        }
    }
}

/// Coordinator-side effects a navigator session needs. Implemented by
/// `SessionCoordinator`; every call is a mode/window transition decision that
/// must not live inside the session (redesign plan §4-c).
@MainActor
protocol NavigatorSessionHost: AnyObject {
    /// esc from the question input, or "編集する" carrying an action draft:
    /// swap this session for a compose session in the same panel.
    func navigatorRequestsCompose(carriedDraft: String?)
    /// The session is finished (single-action execution): close the panel.
    func navigatorRequestsClose()
    /// Copilot guidance started (the user tapped "ナビゲーション開始") or the
    /// guided task finished — the coordinator switches AppMode and the panel
    /// layout (center pane ↔ corner strip).
    func navigatorCopilotStateChanged(active: Bool)
    /// Panel out of the way while a synthetic click runs; back on failure.
    func navigatorRequestsPanelHiddenForAction()
    func navigatorRequestsPanelRestoredAfterAction()
}

/// Screen Q&A session (AppMode.navigator): screenshot → streaming
/// conversation with live on-screen highlights, plus the legacy one-shot
/// interpretation as the signed-out/BYOK fallback
/// (docs/navigator-copilot-plan.md).
@MainActor
final class NavigatorSession: ObservableObject, SessionLifecycle, DictationTarget {
    // MARK: Published state (names kept from the pre-R1-b view model so the
    // vision views moved over without churn)

    @Published var visionImage: ScreenshotAttachment?
    @Published var visionResult: VisionInterpretationResult?
    @Published var isInterpretingVision = false
    @Published private(set) var navigatorTurns: [NavigatorDisplayTurn] = []
    @Published private(set) var navigatorStreamingText: String?
    @Published var navigatorInput = ""
    @Published private(set) var isNavigating = false
    /// What a mouse drag does on the screenshot preview (hand vs. pen tool).
    @Published var previewTool: ScreenshotPreviewTool = .pan
    @Published var annotationTint: ScreenshotAnnotation.Tint = .red
    /// User-drawn rectangles; burned into the next question's image.
    @Published var screenshotAnnotations: [ScreenshotAnnotation] = []
    /// Box the AI pointed at in its latest answer (normalized image coords).
    @Published private(set) var navigatorHighlight: CGRect?
    /// Executable proposal from the latest answer (press a button / fill a
    /// field). Nothing runs until the user presses the approve button —
    /// approval-driven by product principle (master plan §1.2).
    @Published private(set) var navigatorProposedAction: NavigatorAction?
    @Published private(set) var isExecutingNavigatorAction = false
    /// Step plan the gateway planner generated for this session, awaiting
    /// the user's "start navigation" tap (docs/navigator-copilot-plan.md §3).
    @Published private(set) var navigatorProposedTask: NavigatorTask?
    /// Plan being guided step by step (copilot mode). Client-owned session
    /// state: rides on every request, advances on [[step:done]].
    @Published private(set) var navigatorActiveTask: NavigatorTask?
    /// Briefly toggled true after a copy for toast feedback.
    @Published var didDeploy = false
    @Published var focusedField: FocusField?
    @Published var errorMessage: String?
    @Published var lastDurationMs: Int?
    @Published var lastModelName: String?
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var outputLanguage: OutputLanguage = AppSettings.outputLanguage()
    @Published private(set) var situationalContext: SituationalContext?
    @Published private(set) var isContextExcluded = false

    // MARK: Private state

    /// Full navigator conversation as sent to the gateway (screenshots and
    /// OCR ride on user turns; the client trims images to first + latest).
    private var navigatorWireTurns: [NavigateTurn] = []
    /// OCR fragments (text + measured rect) of the current screenshot, kept
    /// on-device to resolve AI-named targets to exact positions.
    private var navigatorOCRFragments: [RecognizedTextFragment] = []
    /// Guards against double-saving one session into the history store.
    private var didSaveNavigatorSession = false
    /// Prepared capture waiting for the first question (auto first turn off).
    private var navigatorPendingCapture: NavigateTurn?
    private var navigatorStreamTask: Task<Void, Never>?
    /// Guards a superseded stream (re-capture cancels the previous one) from
    /// clearing the state of the stream that replaced it.
    private var navigatorStreamGeneration = 0
    private var contextCaptureTask: Task<SituationalContext?, Never>?

    private weak var host: NavigatorSessionHost?
    /// The panel-lifetime paste deployer ("承認して送信" injects into the
    /// summon-time field).
    private let deployer: Deployer
    private let overrideVisionProvider: VisionProvider?

    init(
        deployer: Deployer,
        host: NavigatorSessionHost?,
        visionProvider: VisionProvider? = nil
    ) {
        self.deployer = deployer
        self.host = host
        self.overrideVisionProvider = visionProvider
    }

    // MARK: - SessionLifecycle

    /// Every exit path lands here via the coordinator: stop the stream, save
    /// the conversation, and take the highlight ring down with the session.
    func willEnd() {
        saveNavigatorSessionIfNeeded()
        navigatorStreamTask?.cancel()
        navigatorStreamTask = nil
        navigatorStreamGeneration += 1
        HighlightOverlayPresenter.shared.hide()
    }

    // MARK: - Context (L1)

    func attachContextCapture(_ task: Task<SituationalContext?, Never>) {
        contextCaptureTask = task
        Task { [weak self] in
            let context = await task.value
            self?.situationalContext = context
        }
    }

    func excludeContext() {
        isContextExcluded = true
    }

    private func resolveContext() async -> SituationalContext? {
        guard !isContextExcluded else { return nil }
        if situationalContext == nil, let task = contextCaptureTask {
            situationalContext = await task.value
        }
        return situationalContext
    }

    // MARK: - Session entry

    /// The navigator is gateway-only (server-owned prompts, model staging,
    /// harness selection). Signed-out/BYOK sessions fall back to the legacy
    /// one-shot interpretation.
    var isNavigatorAvailable: Bool {
        AppSettings.isNavigatorEnabled()
            && (overrideVisionProvider == nil)
            && GatewayNavigateClient.make() != nil
    }

    var navigatorSessionActive: Bool {
        !navigatorWireTurns.isEmpty || navigatorPendingCapture != nil
    }

    var canSendNavigatorQuestion: Bool {
        !navigatorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isNavigating
    }

    /// First capture of the session: start the conversation (or the one-shot
    /// fallback). Called by the coordinator right after the mode switch.
    func begin(with attachment: ScreenshotAttachment) {
        visionImage = attachment
        visionResult = nil
        if isNavigatorAvailable {
            startNavigatorSession(with: attachment)
        } else {
            lastDurationMs = nil
            lastModelName = nil
            Task { await runVisionInterpretation() }
        }
    }

    /// Re-capture inside the running session ("did I get to the right
    /// place?") — the copilot's automatic progress check and the manual
    /// 撮り直す both land here.
    func appendCapture(_ attachment: ScreenshotAttachment) {
        visionImage = attachment
        guard navigatorSessionActive else {
            visionResult = nil
            Task { await runVisionInterpretation() }
            return
        }
        // Annotations, highlights, and pending proposals are anchored to the
        // previous image.
        screenshotAnnotations = []
        navigatorHighlight = nil
        navigatorProposedAction = nil
        navigatorTurns.append(NavigatorDisplayTurn(role: .user, text: "（画面を撮り直しました）"))
        prepareNavigatorCapture(attachment, autoRun: true)
    }

    /// Starts a navigator session for a fresh capture. Image downscale and
    /// OCR run concurrently off the main thread; when the auto first turn is
    /// enabled the stream fires as soon as they land (the hotkey itself is
    /// the intent "read this screen").
    private func startNavigatorSession(with attachment: ScreenshotAttachment) {
        errorMessage = nil
        lastDurationMs = nil
        lastModelName = nil
        // The input is ready immediately: the user can type the follow-up
        // question while the auto first turn is still streaming.
        focusedField = .navigator
        prepareNavigatorCapture(attachment, autoRun: AppSettings.isNavigatorAutoFirstTurnEnabled())
    }

    private func prepareNavigatorCapture(_ attachment: ScreenshotAttachment, autoRun: Bool) {
        navigatorStreamTask?.cancel()
        navigatorStreamTask = Task { [weak self] in
            async let imageAsync = GatewayNavigateClient.preparedImage(from: attachment.url)
            async let ocrAsync = ScreenTextRecognizer.recognize(at: attachment.url)
            let image = await imageAsync
            let ocr = await ocrAsync
            guard let self, !Task.isCancelled else { return }
            // Fragment rects stay on-device: they resolve [[target:…]] labels
            // to measured rectangles, which beat the model's estimated box.
            self.navigatorOCRFragments = ocr?.fragments ?? []
            let turn = NavigateTurn(
                role: .user,
                text: nil,
                imageBase64: image?.base64,
                mediaType: image?.mediaType,
                ocrText: ocr?.joinedText
            )
            if autoRun {
                self.navigatorWireTurns.append(turn)
                await self.runNavigatorStream()
            } else {
                // Auto first turn off: hold the capture until the first
                // question, which will carry it.
                self.navigatorPendingCapture = turn
            }
        }
    }

    /// Sends the question in the input field as the next conversation turn.
    /// If the user drew annotation rectangles, they are burned into a fresh
    /// copy of the screenshot that rides with this turn — the model literally
    /// sees what "this part" points at.
    func sendNavigatorQuestion() {
        let question = navigatorInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isNavigating else { return }
        navigatorInput = ""
        navigatorHighlight = nil
        navigatorProposedAction = nil
        navigatorTurns.append(NavigatorDisplayTurn(role: .user, text: question))

        let annotations = screenshotAnnotations
        if !annotations.isEmpty, let imageURL = visionImage?.url {
            screenshotAnnotations = []
            let pendingOCR = navigatorPendingCapture?.ocrText
            navigatorPendingCapture = nil
            navigatorStreamTask = Task { [weak self] in
                let image = await GatewayNavigateClient.preparedImage(
                    from: imageURL, annotations: annotations
                )
                guard let self, !Task.isCancelled else { return }
                self.navigatorWireTurns.append(NavigateTurn(
                    role: .user,
                    text: question,
                    imageBase64: image?.base64,
                    mediaType: image?.mediaType,
                    ocrText: pendingOCR
                ))
                await self.runNavigatorStream()
            }
            return
        }

        if var pending = navigatorPendingCapture {
            pending.text = question
            navigatorPendingCapture = nil
            navigatorWireTurns.append(pending)
        } else {
            navigatorWireTurns.append(NavigateTurn(role: .user, text: question))
        }
        navigatorStreamTask = Task { [weak self] in
            await self?.runNavigatorStream()
        }
    }

    // MARK: - Copilot handoff (mode switches live in the coordinator)

    /// Enters copilot mode with the planner's proposal (the "start
    /// navigation" button). The mode switch is the user's tap — deterministic,
    /// never a per-turn model judgement.
    func startProposedNavigation() {
        guard let task = navigatorProposedTask, !isNavigating else { return }
        navigatorProposedTask = nil
        navigatorActiveTask = task
        navigatorHighlight = nil
        navigatorProposedAction = nil
        navigatorTurns.append(NavigatorDisplayTurn(
            role: .user,
            text: "（ナビゲーション開始: \(task.goal)）"
        ))
        navigatorWireTurns.append(NavigateTurn(
            role: .user,
            text: "ナビゲーションを開始します。最初のステップを案内してください。"
        ))
        host?.navigatorCopilotStateChanged(active: true)
        navigatorStreamTask = Task { [weak self] in
            await self?.runNavigatorStream()
        }
    }

    /// Dismisses the planner's proposal without starting it.
    func dismissProposedNavigation() {
        navigatorProposedTask = nil
    }

    /// The copilot strip's exit button / an abandoned task: drop the plan and
    /// return to the Q&A panel.
    func abandonActiveTask() {
        guard navigatorActiveTask != nil else { return }
        navigatorActiveTask = nil
        HighlightOverlayPresenter.shared.hide()
        host?.navigatorCopilotStateChanged(active: false)
    }

    // MARK: - Streaming

    private func runNavigatorStream() async {
        guard let client = GatewayNavigateClient.make() else {
            errorMessage = "ナビゲーターには I//O Cloud へのログインが必要です。"
            return
        }
        isNavigating = true
        navigatorStreamingText = ""
        errorMessage = nil
        navigatorStreamGeneration += 1
        let generation = navigatorStreamGeneration
        let started = Date()
        var firstTokenMs: Int?
        defer {
            if generation == navigatorStreamGeneration {
                isNavigating = false
                navigatorStreamingText = nil
            }
        }

        let context = await resolveContext()
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
                switch event {
                case .delta(let text):
                    if firstTokenMs == nil {
                        // The POC's success metric: capture-confirm → first
                        // visible token (target ≤1500ms). Shown in the header
                        // and logged for measurement runs.
                        firstTokenMs = Int(Date().timeIntervalSince(started) * 1000)
                        lastDurationMs = firstTokenMs
                        NSLog("[Navigator] first token in %d ms", firstTokenMs!)
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
            // The wire history keeps the raw text (marker included) so the
            // model sees its own past answers verbatim; the display and the
            // highlight take the parsed halves.
            let (displayText, vlmBox, target, fill, stepDone) = NavigatorLocator.extract(from: finalText)
            navigatorWireTurns.append(NavigateTurn(role: .assistant, text: finalText))
            navigatorTurns.append(NavigatorDisplayTurn(role: .assistant, text: displayText))
            let copilotTurn = navigatorActiveTask != nil
            // Copilot progress: the step advance is client-owned data, moved
            // only by the model's explicit [[step:done]] signal.
            if stepDone, var active = navigatorActiveTask {
                active.currentStep += 1
                if active.isFinished {
                    navigatorActiveTask = nil
                    navigatorTurns.append(NavigatorDisplayTurn(
                        role: .user,
                        text: "（ナビゲーション完了: \(active.goal)）"
                    ))
                    NSLog("[Navigator] task finished: %@", active.goal)
                    // Back to the full panel so the final answer is readable.
                    HighlightOverlayPresenter.shared.hide()
                    host?.navigatorCopilotStateChanged(active: false)
                } else {
                    navigatorActiveTask = active
                    NSLog("[Navigator] step advanced to %d/%d", active.currentStep + 1, active.steps.count)
                }
            }
            // A freshly planned task becomes a proposal (start button); it
            // never interrupts a plan already being guided.
            if let plannedTask, navigatorActiveTask == nil {
                navigatorProposedTask = plannedTask
            }
            // Precision ladder: an OCR-measured rect for the named target
            // wins over the model's estimated box (which stays as fallback).
            let box = resolveHighlightRect(target: target, vlmBox: vlmBox)
            navigatorHighlight = box
            let copilotStillActive = navigatorActiveTask != nil
            if copilotStillActive || !copilotTurn {
                // While guiding, the ring stays up until the step advances —
                // a highlight nobody can find again is no highlight at all.
                showLiveHighlight(for: box, persistent: copilotStillActive)
            }
            // The approve/execute button belongs to Q&A sessions only; the
            // copilot has exactly one interaction (click the highlight).
            if let target, !copilotTurn {
                navigatorProposedAction = NavigatorAction(
                    kind: fill.map { .fill(text: $0) } ?? .press,
                    targetLabel: target,
                    globalRect: projectToGlobal(box)
                )
            }
            // Surface the actual model id: a leftover experiment override
            // (e.g. a weaker vision model in .env.local) once masqueraded as
            // a regression — never let the engine choice be invisible.
            let engineLabel = modelID ?? "I//O Cloud"
            lastModelName = harness.map { "\(engineLabel) · \($0)" } ?? engineLabel
        } catch is CancellationError {
            // Session was reset mid-stream; nothing to surface.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - One-shot interpretation (signed-out / BYOK fallback)

    private func currentVisionProvider() -> VisionProvider {
        if let overrideVisionProvider { return overrideVisionProvider }
        if let gateway = GatewayVisionClient.make() { return gateway }
        return OpenAIVisionClient()
    }

    func runVisionInterpretation() async {
        guard let visionImage else { return }
        errorMessage = nil
        visionResult = nil
        isInterpretingVision = true
        let started = Date()
        defer { isInterpretingVision = false }

        // Vision drafts replies as the user, so it gets the same L1 context
        // and persona/relationship cards as a compose review (M1/M2 → M4).
        let context = await resolveContext()
        let memory = await SessionMemory.injection(for: context)
        let provider = currentVisionProvider()
        do {
            let result = try await provider.interpret(
                imageURL: visionImage.url,
                instruction: nil,
                language: outputLanguage,
                context: context,
                memory: memory
            )
            self.lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
            self.lastModelName = provider is GatewayVisionClient
                ? "I//O Cloud"
                : "OpenAI · \(result.modelID ?? AppSettings.selectedVisionModelID())"
            self.visionResult = result
        } catch is CancellationError {
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Exits

    /// esc from the question input: back to the compose panel.
    func requestExitToCompose() {
        host?.navigatorRequestsCompose(carriedDraft: nil)
    }

    /// "承認して送信": deploy a prepared action draft as-is into the field the
    /// panel was summoned from. The user's approval is the only input — this
    /// is the North Star loop closing for reply actions.
    func approveSuggestedAction(_ action: VisionSuggestedAction) {
        guard action.hasDraft else { return }
        do {
            try deployer.deploy(action.draft)
            Task {
                await LocalHistoryStore.shared.record(.init(
                    mode: .compose,
                    sourceText: action.draft,
                    finalText: action.draft,
                    modelID: nil,
                    modelName: lastModelName,
                    outputLanguage: outputLanguage.displayName,
                    action: .sent
                ))
            }
            didDeploy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self.didDeploy = false
            }
        } catch {
            errorMessage = "デプロイに失敗しました: \(error.localizedDescription)"
        }
    }

    /// "編集する": carry the action draft into the compose editor so the user
    /// can adjust it (and optionally re-review) before deploying.
    func editSuggestedAction(_ action: VisionSuggestedAction) {
        host?.navigatorRequestsCompose(carriedDraft: action.draft)
    }

    func copyVisionResult() {
        guard let visionResult else { return }
        do {
            try ClipboardDeployer().deploy(visionResult.copyText)
            didDeploy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self.didDeploy = false
            }
        } catch {
            errorMessage = "コピーに失敗しました: \(error.localizedDescription)"
        }
    }

    /// Saves a copy of the current screenshot wherever the user picks.
    func saveScreenshotAs() {
        guard let sourceURL = visionImage?.url else { return }
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

    // MARK: - Approved AX action (Q&A sessions; master plan stair 2)

    /// Runs the approved action. Approval-driven: this only ever fires from
    /// the button the user pressed.
    func approveNavigatorAction() {
        guard let action = navigatorProposedAction, !isExecutingNavigatorAction else { return }
        isExecutingNavigatorAction = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isExecutingNavigatorAction = false }
            guard let context = await self.resolveContext() else {
                self.errorMessage = "操作対象のアプリを特定できませんでした。"
                return
            }
            // The panel must not sit between the synthetic click and the
            // target app — hide it for the whole execute-and-verify beat.
            NSLog("[Action] approving: %@", action.buttonTitle)
            self.host?.navigatorRequestsPanelHiddenForAction()
            try? await Task.sleep(nanoseconds: 150_000_000)
            do {
                switch action.kind {
                case .press:
                    let pressedFrame = try await AXActionService.press(
                        pid: context.pid,
                        label: action.targetLabel,
                        near: action.globalRect
                    )
                    // Show exactly where the press landed — mis-hits become
                    // visible instead of silently looping.
                    if let pressedFrame {
                        HighlightOverlayPresenter.shared.show(around: pressedFrame, duration: 0.5)
                    }
                case .fill(let text):
                    try await AXActionService.focusTextInput(
                        pid: context.pid,
                        label: action.targetLabel,
                        near: action.globalRect
                    )
                    // Give focus a beat to settle, then paste through the
                    // existing clipboard-preserving synthesis.
                    try await Task.sleep(nanoseconds: 250_000_000)
                    let deployer = PasteDeployer(
                        targetApp: NSRunningApplication(processIdentifier: context.pid),
                        onDismiss: {}
                    )
                    try deployer.deploy(text)
                }
                self.navigatorProposedAction = nil
                self.navigatorTurns.append(NavigatorDisplayTurn(
                    role: .user,
                    text: "（\(action.buttonTitle) を実行しました）"
                ))
                // Single-action sessions for now: the multi-step loop
                // (execute → auto re-capture → panel restore) is parked as a
                // known issue — the panel reliably failed to come back after
                // a synthetic click (3 attempts, unresolved). The click
                // feedback ring plays out on the live screen, then the
                // session ends; past sessions stay reachable via history.
                NSLog("[Action] executed; ending session (single-action mode)")
                self.saveNavigatorSessionIfNeeded()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                HighlightOverlayPresenter.shared.hide()
                self.host?.navigatorRequestsClose()
            } catch {
                self.host?.navigatorRequestsPanelRestoredAfterAction()
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: - Highlight resolution (model = what, OCR/AX = where)

    /// Resolves the highlight rectangle with the precision ladder:
    /// 1. The model names the target's on-screen label ([[target:…]]) and
    ///    local OCR measured that exact string → pixel-accurate rect.
    /// 2. Otherwise the model's own estimated box ([[loc:…]]).
    ///
    /// Matching is tiered — exact label, then fragment-contains-label, then
    /// partial — because with [[loc]] now optional there is often no model
    /// box to disambiguate with, and a bare "ユーザー" row must never outrank
    /// "ユーザーの環境の詳細" (the 2026-07-06 mis-highlight).
    private func resolveHighlightRect(target: String?, vlmBox: CGRect?) -> CGRect? {
        guard let target, !navigatorOCRFragments.isEmpty else { return vlmBox }
        let needle = Self.matchKey(target)
        guard !needle.isEmpty else { return vlmBox }

        let ranked = navigatorOCRFragments.compactMap {
            fragment -> (tier: Int, fragment: RecognizedTextFragment)? in
            guard let tier = Self.matchTier(needle: needle, candidate: fragment.text) else {
                return nil
            }
            return (tier, fragment)
        }
        guard let bestTier = ranked.map(\.tier).min() else { return vlmBox }
        let hits = ranked.filter { $0.tier == bestTier }.map(\.fragment)

        // Same-tier duplicates (a menu item and a breadcrumb, say): prefer
        // the one nearest the model's own estimate when it exists, otherwise
        // the fragment whose length is closest to the label's.
        if let vlmBox, hits.count > 1 {
            let center = CGPoint(x: vlmBox.midX, y: vlmBox.midY)
            let nearest = hits.min { lhs, rhs in
                distanceSquared(from: lhs.rect, to: center)
                    < distanceSquared(from: rhs.rect, to: center)
            }
            return nearest?.rect
        }
        let closest = hits.min { lhs, rhs in
            abs(Self.matchKey(lhs.text).count - needle.count)
                < abs(Self.matchKey(rhs.text).count - needle.count)
        }
        return closest?.rect
    }

    /// Shared label-match quality: 0 = exact, 1 = candidate contains the
    /// label, 2 = partial (label contains the candidate). nil = no match.
    static func matchTier(needle: String, candidate: String) -> Int? {
        let key = matchKey(candidate)
        guard !key.isEmpty else { return nil }
        if key == needle { return 0 }
        if key.contains(needle) { return 1 }
        if needle.contains(key), key.count >= 2 { return 2 }
        return nil
    }

    /// Case/whitespace-insensitive comparison key for label matching.
    private static func matchKey(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    private func distanceSquared(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return dx * dx + dy * dy
    }

    /// Normalized image box → global display coordinates (CG top-left),
    /// via the recorded capture origin. nil when the origin is unknown.
    private func projectToGlobal(_ box: CGRect?) -> CGRect? {
        guard let box, let capture = visionImage?.captureRect else { return nil }
        return CGRect(
            x: capture.minX + box.minX * capture.width,
            y: capture.minY + box.minY * capture.height,
            width: box.width * capture.width,
            height: box.height * capture.height
        )
    }

    /// Projects the normalized box back onto the physical screen and rings
    /// it there: the panel shows where in the picture, the live overlay
    /// points at the actual pixels. Only possible when the capture origin is
    /// known (ScreenCaptureKit paths; not `screencapture -i`).
    private func showLiveHighlight(for box: CGRect?, persistent: Bool = false) {
        guard let target = projectToGlobal(box) else { return }
        HighlightOverlayPresenter.shared.show(around: target, duration: persistent ? nil : 2.6)
    }

    // MARK: - Persistence and dictation

    /// Persists the finished conversation (text only) so the guidance stays
    /// reachable after the session ends. Idempotent per session — called from
    /// every exit path via `willEnd()` and the executed-action path.
    func saveNavigatorSessionIfNeeded() {
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

    /// Dictation lands in the question input — the only editable field here.
    func appendTranscription(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if navigatorInput.isEmpty {
            navigatorInput = piece
        } else {
            let needsSpace = !(navigatorInput.hasSuffix(" ") || navigatorInput.hasSuffix("\n"))
            navigatorInput += (needsSpace ? " " : "") + piece
        }
    }
}

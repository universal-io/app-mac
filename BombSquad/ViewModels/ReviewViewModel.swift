import AppKit
import Foundation
import SwiftUI

private enum ComposeDraftStore {
    private static let key = "ReviewViewModel.composeDraft"

    static func load() -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    static func save(_ draft: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(draft, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

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

/// Owns the staging → review → deploy flow and all UI state.
@MainActor
final class ReviewViewModel: ObservableObject {
    /// Staging draft the user is editing.
    @Published var draft: String = "" {
        didSet {
            guard mode == .compose else { return }
            ComposeDraftStore.save(draft)
        }
    }
    /// Latest review result, if any.
    @Published var result: ReviewResult?
    /// Adopted/edited revision that will actually be deployed.
    @Published var revisedDraft: String = ""
    /// Revised text accumulating token by token during a streaming review;
    /// nil when no stream is in flight. Drives the live preview in the panel.
    @Published private(set) var streamingRevision: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Wall-clock latency of the last successful review, in milliseconds.
    @Published var lastDurationMs: Int?
    /// Display name of the model used for the last review.
    @Published var lastModelName: String?
    /// Hold-to-talk dictation state.
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isCapturingScreenshot = false
    @Published var needsScreenCapturePermission = false
    @Published private(set) var screenshotAttachments: [ScreenshotAttachment] = []
    @Published var sessionKind: InputSessionKind = .text
    @Published var visionImage: ScreenshotAttachment?
    @Published var visionResult: VisionInterpretationResult?
    @Published var visionInstruction = ""
    @Published var isInterpretingVision = false
    /// Navigator conversation shown in the vision panel (docs/poc-ga-navigator.md).
    @Published private(set) var navigatorTurns: [NavigatorDisplayTurn] = []
    /// Answer accumulating token by token during a navigator stream.
    @Published private(set) var navigatorStreamingText: String?
    /// The question being typed in the navigator input field.
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
    /// Briefly toggled true after a successful deploy for toast feedback.
    @Published var didDeploy = false
    @Published var focusedField: FocusField?
    @Published private(set) var recentHistoryEntries: [HistoryEntry] = []
    @Published private(set) var isLoadingRecentHistory = false
    /// Target language for the deliverable (`revisedDraft`). Read from the
    /// persisted setting at panel open; changed in settings, not the panel.
    @Published var outputLanguage: OutputLanguage = AppSettings.outputLanguage()
    /// L1 situational context captured at summon time (shown as a chip).
    @Published private(set) var situationalContext: SituationalContext?
    /// True after the user dismissed the chip: no injection for this session.
    @Published private(set) var isContextExcluded = false

    /// The exact draft text and language that produced the current `result`.
    private var reviewedDraft: String?
    private var reviewedLanguage: OutputLanguage?
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
    private var hasLoadedRecentHistory = false
    /// Pending background AX capture; resolved lazily on first use.
    private var contextCaptureTask: Task<SituationalContext?, Never>?

    /// Direction of this session: composing an outgoing draft (review/soften)
    /// or transforming a received message (make it readable). Drives the prompt.
    let mode: ReviewMode

    /// Optional fixed provider (used by tests/previews). When nil, the provider
    /// is built from the user's selection at review time.
    private let overrideProvider: ReviewProvider?
    private let overrideVisionProvider: VisionProvider?
    private let deployer: Deployer

    init(
        provider: ReviewProvider? = nil,
        visionProvider: VisionProvider? = nil,
        deployer: Deployer = ClipboardDeployer(),
        mode: ReviewMode = .compose
    ) {
        self.overrideProvider = provider
        self.overrideVisionProvider = visionProvider
        self.deployer = deployer
        self.mode = mode
    }

    /// Resolve the engine to use for the next review. The gateway is the
    /// production path (server-owned keys, prompts, and metering); the BYOK
    /// direct clients remain as a developer fallback when no gateway URL is
    /// configured or the user is signed out.
    private func currentProvider() -> ReviewProvider {
        if let overrideProvider { return overrideProvider }
        if let gateway = GatewayReviewClient.make() { return gateway }
        let model = AppSettings.selectedModel()
        switch model.vendor {
        case .anthropic: return ClaudeClient(model: model.apiModelID)
        case .openAI, .groq: return OpenAICompatibleClient(model: model)
        }
    }

    /// Same gateway-first resolution as `currentProvider()`, for Vision.
    private func currentVisionProvider() -> VisionProvider {
        if let overrideVisionProvider { return overrideVisionProvider }
        if let gateway = GatewayVisionClient.make() { return gateway }
        return OpenAIVisionClient()
    }

    var canReview: Bool {
        sessionKind == .text && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    /// Hand over the background context capture started at summon time. The
    /// value is awaited lazily (first review or chip display), never blocking
    /// the panel from showing.
    func attachContextCapture(_ task: Task<SituationalContext?, Never>) {
        contextCaptureTask = task
        Task { [weak self] in
            let context = await task.value
            self?.situationalContext = context
        }
    }

    /// Excludes the captured context from this session (chip dismissed).
    func excludeContext() {
        isContextExcluded = true
    }

    /// Context to inject into the next review. The AX walk is budget-bounded
    /// (~1.5s worst case), so awaiting the pending capture here is safe.
    private func resolveContext() async -> SituationalContext? {
        guard !isContextExcluded else { return nil }
        if situationalContext == nil, let task = contextCaptureTask {
            situationalContext = await task.value
        }
        return situationalContext
    }

    /// Memory cards for the next review: the persona card plus the
    /// relationship card whose subject appears in the situational context.
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

    func runReview() async {
        // M4-B: the receiving side is a special case of interpretation — the
        // selected text goes through the same "understand → respond" schema
        // and UI as a screenshot. Compose keeps the review/diff flow.
        if mode == .transform {
            await runTransformInterpretation()
            return
        }
        errorMessage = nil
        if result != nil {
            result = nil
            revisedDraft = ""
        }
        isLoading = true
        let model = AppSettings.selectedModel()
        let started = Date()
        defer {
            isLoading = false
            streamingRevision = nil
        }
        let input = draft
        let language = outputLanguage
        let context = await resolveContext()
        let memory = await resolveMemory(context: context)
        let provider = currentProvider()
        do {
            let result: ReviewResult
            if let gateway = provider as? GatewayReviewClient {
                // Streaming path: revised_text flows into the live preview
                // token by token, then the final event carries the full result.
                streamingRevision = ""
                var finalResult: ReviewResult?
                let stream = try await gateway.reviewStream(
                    draft: input, mode: mode, language: language, context: context, memory: memory
                )
                for try await event in stream {
                    switch event {
                    case .delta(let text):
                        streamingRevision = (streamingRevision ?? "") + text
                    case .result(let parsed):
                        finalResult = parsed
                    }
                }
                guard let finalResult else {
                    throw ProviderError.decoding("stream ended without a result")
                }
                result = finalResult
            } else {
                result = try await provider.review(
                    draft: input, mode: mode, language: language, context: context, memory: memory
                )
            }
            self.lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
            self.lastModelName = provider is GatewayReviewClient ? "I//O Cloud" : model.displayName
            self.result = result
            self.revisedDraft = result.revisedText
            self.reviewedDraft = input
            self.reviewedLanguage = language
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Interpret the received message (transform sessions). Same provider and
    /// result surface as vision; the exit stays clipboard-only — a received
    /// message is never written back.
    private func runTransformInterpretation() async {
        errorMessage = nil
        visionResult = nil
        isLoading = true
        let started = Date()
        defer { isLoading = false }

        let input = draft
        let context = await resolveContext()
        let memory = await resolveMemory(context: context)
        let provider = currentVisionProvider()
        do {
            let result = try await provider.interpret(
                receivedText: input,
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
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var canDeployDraft: Bool {
        sessionKind == .text && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when there is nothing to act on — used so a Right-Shift double-tap on an empty draft
    /// closes the panel instead of doing nothing.
    var isEmptyDraft: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canFocusRevision: Bool {
        sessionKind == .text && result != nil
    }

    /// Restore the last in-progress compose draft after reopening the panel.
    func restorePersistedDraftIfNeeded() {
        guard mode == .compose else { return }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ComposeDraftStore.load()
    }

    func loadRecentHistoryIfNeeded() async {
        guard mode == .compose else { return }
        guard !hasLoadedRecentHistory else { return }
        hasLoadedRecentHistory = true
        await reloadRecentHistory()
    }

    func applyRecentHistory(_ entry: HistoryEntry) {
        deploy(text: entry.finalText, historyInput: .init(
            mode: historyMode,
            sourceText: entry.finalText,
            finalText: entry.finalText,
            modelID: entry.modelID,
            modelName: entry.modelName,
            outputLanguage: entry.outputLanguage,
            action: historyAction
        ))
    }

    func toggleFocusedField() {
        guard canFocusRevision else {
            focusedField = .draft
            return
        }
        switch focusedField {
        case .revision:
            focusedField = .draft
        default:
            focusedField = .revision
        }
    }

    /// Routes dictated text to whichever input is active, so hold-to-talk
    /// behaves identically in every text field (draft, revision, navigator).
    func appendTranscription(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        switch activeTranscriptionTarget {
        case .navigator:
            navigatorInput = appending(piece, to: navigatorInput)
        case .revision:
            revisedDraft = appending(piece, to: revisedDraft)
        case .draft:
            draft = appending(piece, to: draft)
        }
    }

    /// The field dictation should land in. Inside a navigator session the
    /// question input is the only editable field; otherwise follow focus.
    private var activeTranscriptionTarget: FocusField {
        if sessionKind == .vision {
            return navigatorSessionActive ? .navigator : .draft
        }
        if focusedField == .revision, canFocusRevision { return .revision }
        return .draft
    }

    private func appending(_ piece: String, to base: String) -> String {
        if base.isEmpty { return piece }
        let needsSpace = !(base.hasSuffix(" ") || base.hasSuffix("\n"))
        return base + (needsSpace ? " " : "") + piece
    }

    func addScreenshotAttachment(_ attachment: ScreenshotAttachment) {
        needsScreenCapturePermission = false
        screenshotAttachments = [attachment]
        enterVisionMode(with: attachment)
    }

    func removeScreenshotAttachment(id: ScreenshotAttachment.ID) {
        screenshotAttachments.removeAll { $0.id == id }
        if visionImage?.id == id {
            exitVisionMode()
        }
    }

    func enterVisionMode(with attachment: ScreenshotAttachment) {
        // A capture while a navigator conversation is open is a re-capture
        // ("did I get to the right place?"), not a new session.
        let isRecapture = sessionKind == .vision && navigatorSessionActive
        sessionKind = .vision
        visionImage = attachment
        visionResult = nil
        revisedDraft = ""
        result = nil
        focusedField = nil
        if isNavigatorAvailable {
            if isRecapture {
                appendNavigatorCapture(attachment)
            } else {
                startNavigatorSession(with: attachment)
            }
        } else {
            lastDurationMs = nil
            lastModelName = nil
            Task { await runVisionInterpretation() }
        }
    }

    func exitVisionMode() {
        sessionKind = .text
        visionImage = nil
        visionResult = nil
        isInterpretingVision = false
        resetNavigatorSession()
        focusedField = .draft
        // The panel window is owned by AppDelegate; let it restore the narrow
        // single-column layout when vision's two-pane session ends.
        NotificationCenter.default.post(name: .visionSessionEnded, object: nil)
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
        let memory = await resolveMemory(context: context)
        let provider = currentVisionProvider()
        do {
            let result = try await provider.interpret(
                imageURL: visionImage.url,
                instruction: visionInstruction,
                language: outputLanguage,
                context: context,
                memory: memory
            )
            self.lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
            self.lastModelName = provider is GatewayVisionClient
                ? "I//O Cloud"
                : "OpenAI · \(result.modelID ?? AppSettings.selectedVisionModelID())"
            self.visionResult = result
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Navigator (docs/poc-ga-navigator.md)

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

    /// Starts a navigator session for a fresh capture. Image downscale and
    /// OCR run concurrently off the main thread; when the auto first turn is
    /// enabled the stream fires as soon as they land (the hotkey itself is
    /// the intent "read this screen").
    private func startNavigatorSession(with attachment: ScreenshotAttachment) {
        resetNavigatorSession()
        errorMessage = nil
        lastDurationMs = nil
        lastModelName = nil
        // The input is ready immediately: the user can type the follow-up
        // question while the auto first turn is still streaming.
        focusedField = .navigator
        prepareNavigatorCapture(attachment, autoRun: AppSettings.isNavigatorAutoFirstTurnEnabled())
    }

    /// Re-capture inside a running session: always auto-runs — pressing
    /// 撮り直す is itself the question "check my progress".
    private func appendNavigatorCapture(_ attachment: ScreenshotAttachment) {
        // Annotations, highlights, and pending proposals are anchored to the
        // previous image.
        screenshotAnnotations = []
        navigatorHighlight = nil
        navigatorProposedAction = nil
        navigatorTurns.append(NavigatorDisplayTurn(role: .user, text: "（画面を撮り直しました）"))
        prepareNavigatorCapture(attachment, autoRun: true)
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
                language: outputLanguage
            )
            var finalText: String?
            var harness: String?
            var modelID: String?
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
                case .result(let text, let resultHarness, let resultModelID):
                    finalText = text
                    harness = resultHarness
                    modelID = resultModelID
                }
            }
            guard let finalText else {
                throw ProviderError.decoding("stream ended without a result")
            }
            // The wire history keeps the raw text (marker included) so the
            // model sees its own past answers verbatim; the display and the
            // highlight take the parsed halves.
            let (displayText, vlmBox, target, fill) = NavigatorLocator.extract(from: finalText)
            navigatorWireTurns.append(NavigateTurn(role: .assistant, text: finalText))
            navigatorTurns.append(NavigatorDisplayTurn(role: .assistant, text: displayText))
            // Precision ladder: an OCR-measured rect for the named target
            // wins over the model's estimated box (which stays as fallback).
            let box = resolveHighlightRect(target: target, vlmBox: vlmBox)
            navigatorHighlight = box
            showLiveHighlight(for: box)
            if let target {
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

    /// Saves a copy of the current screenshot wherever the user picks. The
    /// capture is already auto-saved on the Desktop; this is the explicit
    /// download affordance on the preview.
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

    /// Copies the latest navigator answer to the clipboard.
    func copyNavigatorAnswer() {
        guard let last = navigatorTurns.last(where: { $0.role == .assistant }) else { return }
        do {
            try ClipboardDeployer().deploy(last.text)
            didDeploy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self.didDeploy = false
            }
        } catch {
            errorMessage = "コピーに失敗しました: \(error.localizedDescription)"
        }
    }

    /// Resolves the highlight rectangle with the precision ladder:
    /// 1. The model names the target's on-screen label ([[target:…]]) and
    ///    local OCR measured that exact string → pixel-accurate rect.
    /// 2. Otherwise the model's own estimated box ([[loc:…]]).
    private func resolveHighlightRect(target: String?, vlmBox: CGRect?) -> CGRect? {
        guard let target, !navigatorOCRFragments.isEmpty else { return vlmBox }
        let needle = Self.matchKey(target)
        guard !needle.isEmpty else { return vlmBox }

        let hits = navigatorOCRFragments.filter { fragment in
            let key = Self.matchKey(fragment.text)
            return key.contains(needle) || needle.contains(key) && key.count >= 2
        }
        guard !hits.isEmpty else { return vlmBox }

        // Several fragments can carry the same label (e.g. a menu item and a
        // breadcrumb); prefer the one nearest the model's own estimate.
        if let vlmBox, hits.count > 1 {
            let center = CGPoint(x: vlmBox.midX, y: vlmBox.midY)
            let nearest = hits.min { lhs, rhs in
                distanceSquared(from: lhs.rect, to: center)
                    < distanceSquared(from: rhs.rect, to: center)
            }
            return nearest?.rect
        }
        return hits[0].rect
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
    /// it there (POC Step 3): the panel shows where in the picture, the live
    /// overlay points at the actual pixels. Only possible when the capture
    /// origin is known (ScreenCaptureKit paths; not `screencapture -i`).
    private func showLiveHighlight(for box: CGRect?) {
        guard let target = projectToGlobal(box) else { return }
        HighlightOverlayPresenter.shared.show(around: target)
    }

    /// Runs the approved action (master plan stair 2). Approval-driven: this
    /// only ever fires from the button the user pressed. On success the
    /// screen is silently re-captured so the AI verifies the step landed —
    /// execution needs approval; observation is automatic.
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
            // target app — hide it for the whole execute-and-verify beat
            // (the progress capture brings it back with the new turn).
            NSLog("[Action] approving: %@", action.buttonTitle)
            NotificationCenter.default.post(name: .hidePanelForAction, object: nil)
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
                NotificationCenter.default.post(name: .closePanel, object: nil)
            } catch {
                NotificationCenter.default.post(name: .showPanelAfterAction, object: nil)
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Persists the finished conversation (text only) so the guidance stays
    /// reachable after the session ends. Idempotent per session — called from
    /// every exit path (reset, panel close, executed action).
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

    private func resetNavigatorSession() {
        saveNavigatorSessionIfNeeded()
        didSaveNavigatorSession = false
        navigatorStreamTask?.cancel()
        navigatorStreamTask = nil
        navigatorStreamGeneration += 1
        navigatorTurns = []
        navigatorWireTurns = []
        navigatorPendingCapture = nil
        navigatorStreamingText = nil
        navigatorInput = ""
        isNavigating = false
        screenshotAnnotations = []
        navigatorHighlight = nil
        navigatorOCRFragments = []
        navigatorProposedAction = nil
        isExecutingNavigatorAction = false
        previewTool = .pan
        HighlightOverlayPresenter.shared.hide()
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

    /// "承認して送信": deploy a prepared action draft as-is into the field the
    /// panel was summoned from. The user's approval is the only input — this
    /// is the North Star loop closing for reply actions.
    func approveSuggestedAction(_ action: VisionSuggestedAction) {
        guard action.hasDraft else { return }
        deploy(text: action.draft, historyInput: .init(
            mode: historyMode,
            sourceText: action.draft,
            finalText: action.draft,
            modelID: nil,
            modelName: lastModelName,
            outputLanguage: outputLanguage.displayName,
            action: historyAction
        ))
    }

    /// "編集する": carry the action draft into the compose editor so the user
    /// can adjust it (and optionally re-review) before deploying.
    func editSuggestedAction(_ action: VisionSuggestedAction) {
        exitVisionMode()
        draft = action.draft
        result = nil
        revisedDraft = ""
        focusedField = .draft
    }

    /// True when a review exists but the draft has changed since it was made.
    var needsReReview: Bool {
        result != nil && (reviewedDraft != draft || reviewedLanguage != outputLanguage)
    }

    /// Right-Shift double-tap requests a review only from the left draft editor.
    func requestReviewFromHotkey() {
        guard canReview else { return }
        Task { await runReview() }
    }

    /// Deploy the original draft as-is (skip review).
    func deployDraft() {
        deploy(text: draft, historyInput: .init(
            mode: historyMode,
            sourceText: draft,
            finalText: draft,
            modelID: nil,
            modelName: nil,
            outputLanguage: nil,
            action: historyAction
        ))
    }

    /// Deploy the reviewed/edited revision (falls back to the draft if empty).
    func deployRevision() {
        let finalText = revisedDraft.isEmpty ? draft : revisedDraft
        let model = result == nil ? nil : AppSettings.selectedModel()
        deploy(text: finalText, historyInput: .init(
            mode: historyMode,
            sourceText: draft,
            finalText: finalText,
            modelID: model?.id,
            modelName: lastModelName ?? model?.displayName,
            outputLanguage: outputLanguage.displayName,
            action: historyAction
        ))
        scheduleDistillation(finalText: finalText)
    }

    /// The gap between the AI suggestion and what the user actually sent is
    /// the best teacher for the persona/relationship cards. Observed off the
    /// hot path after a successful compose deploy; failures never surface.
    private func scheduleDistillation(finalText: String) {
        guard didDeploy, mode == .compose, AppSettings.isMemoryEnabled() else { return }
        guard let result else { return }
        let original = draft
        let suggestion = result.revisedText
        let context = situationalContext
        Task.detached(priority: .background) {
            await MemoryDistiller.distillAfterDeploy(
                original: original, suggestion: suggestion, final: finalText, context: context
            )
        }
    }

    /// Deploy text to the live destination (clipboard, or paste into the
    /// originating field for the hotkey panel).
    private func deploy(text: String, historyInput: HistoryEntryInput) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try deployer.deploy(text)
            Task {
                await LocalHistoryStore.shared.record(historyInput)
                await self.reloadRecentHistory()
            }
            if mode == .compose {
                ComposeDraftStore.clear()
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

    private var historyMode: HistoryEntryMode {
        switch mode {
        case .compose: return .compose
        case .transform: return .transform
        }
    }

    private var historyAction: HistoryAction {
        switch mode {
        case .compose: return .sent
        case .transform: return .copied
        }
    }

    private func reloadRecentHistory() async {
        guard mode == .compose else { return }
        guard AppSettings.isHistoryEnabled() else {
            recentHistoryEntries = []
            isLoadingRecentHistory = false
            return
        }

        isLoadingRecentHistory = true
        defer { isLoadingRecentHistory = false }

        do {
            recentHistoryEntries = try await LocalHistoryStore.shared.fetchEntries(
                limit: 5,
                mode: .compose,
                action: .sent
            )
        } catch {
            recentHistoryEntries = []
        }
    }
}

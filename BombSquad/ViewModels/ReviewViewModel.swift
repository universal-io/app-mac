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

    /// Append dictated text to the draft (with a separating space as needed).
    func appendTranscription(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if draft.isEmpty {
            draft = piece
        } else {
            let needsSpace = !(draft.hasSuffix(" ") || draft.hasSuffix("\n"))
            draft += (needsSpace ? " " : "") + piece
        }
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
        sessionKind = .vision
        visionImage = attachment
        visionResult = nil
        revisedDraft = ""
        result = nil
        lastDurationMs = nil
        lastModelName = nil
        focusedField = nil
        Task { await runVisionInterpretation() }
    }

    func exitVisionMode() {
        sessionKind = .text
        visionImage = nil
        visionResult = nil
        isInterpretingVision = false
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

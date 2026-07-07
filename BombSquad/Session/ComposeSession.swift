import Foundation
import SwiftUI

/// Persists the in-progress compose draft across panel sessions and mode
/// transitions (continuity by persistence, not by keeping sessions alive —
/// redesign plan §4-b). The key predates the redesign so existing drafts
/// survive the update.
enum ComposeDraftStore {
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

/// Outgoing review session (AppMode.compose): staging draft → review (diff) →
/// deploy into the field the panel was summoned from.
@MainActor
final class ComposeSession: ObservableObject, SessionLifecycle, DictationTarget {
    /// Staging draft the user is editing.
    @Published var draft: String = "" {
        didSet { ComposeDraftStore.save(draft) }
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
    private var reviewTask: Task<Void, Never>?

    /// Optional fixed provider (used by tests/previews). When nil, the provider
    /// is built from the user's selection at review time.
    private let overrideProvider: ReviewProvider?
    let deployer: Deployer

    init(deployer: Deployer = ClipboardDeployer(), provider: ReviewProvider? = nil) {
        self.deployer = deployer
        self.overrideProvider = provider
    }

    // MARK: - SessionLifecycle

    func willEnd() {
        reviewTask?.cancel()
        reviewTask = nil
    }

    // MARK: - Context (L1)

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

    // MARK: - Review

    var canReview: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    var canDeployDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when there is nothing to act on — used so a Right-Shift double-tap
    /// on an empty draft enters vision capture instead of reviewing.
    var isEmptyDraft: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canFocusRevision: Bool {
        result != nil
    }

    /// True when a review exists but the draft has changed since it was made.
    var needsReReview: Bool {
        result != nil && (reviewedDraft != draft || reviewedLanguage != outputLanguage)
    }

    /// Right-Shift double-tap requests a review only from the draft editor.
    func requestReviewFromHotkey() {
        guard canReview else { return }
        startReview()
    }

    /// Kicks the review off as a cancellable task (`willEnd` stops it).
    func startReview() {
        guard canReview else { return }
        reviewTask = Task { [weak self] in
            await self?.runReview()
        }
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

    func runReview() async {
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
        let memory = await SessionMemory.injection(for: context)
        let provider = currentProvider()
        do {
            let result: ReviewResult
            if let gateway = provider as? GatewayReviewClient {
                // Streaming path: revised_text flows into the live preview
                // token by token, then the final event carries the full result.
                streamingRevision = ""
                var finalResult: ReviewResult?
                let stream = try await gateway.reviewStream(
                    draft: input, mode: .compose, language: language, context: context, memory: memory
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
                    draft: input, mode: .compose, language: language, context: context, memory: memory
                )
            }
            self.lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
            self.lastModelName = provider is GatewayReviewClient ? "I//O Cloud" : model.displayName
            self.result = result
            self.revisedDraft = result.revisedText
            self.reviewedDraft = input
            self.reviewedLanguage = language
        } catch is CancellationError {
            // Session ended mid-stream; nothing to surface.
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Draft persistence and history

    /// Restore the last in-progress compose draft after reopening the panel.
    func restorePersistedDraftIfNeeded() {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ComposeDraftStore.load()
    }

    func loadRecentHistoryIfNeeded() async {
        guard !hasLoadedRecentHistory else { return }
        hasLoadedRecentHistory = true
        await reloadRecentHistory()
    }

    func applyRecentHistory(_ entry: HistoryEntry) {
        deploy(text: entry.finalText, historyInput: .init(
            mode: .compose,
            sourceText: entry.finalText,
            finalText: entry.finalText,
            modelID: entry.modelID,
            modelName: entry.modelName,
            outputLanguage: entry.outputLanguage,
            action: .sent
        ))
    }

    private func reloadRecentHistory() async {
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

    // MARK: - Focus and dictation

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

    /// Routes dictated text to whichever editor is active, so hold-to-talk
    /// behaves identically in the draft and the revision.
    func appendTranscription(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if focusedField == .revision, canFocusRevision {
            revisedDraft = appending(piece, to: revisedDraft)
        } else {
            draft = appending(piece, to: draft)
        }
    }

    private func appending(_ piece: String, to base: String) -> String {
        if base.isEmpty { return piece }
        let needsSpace = !(base.hasSuffix(" ") || base.hasSuffix("\n"))
        return base + (needsSpace ? " " : "") + piece
    }

    // MARK: - Deploy

    /// Deploy the original draft as-is (skip review).
    func deployDraft() {
        deploy(text: draft, historyInput: .init(
            mode: .compose,
            sourceText: draft,
            finalText: draft,
            modelID: nil,
            modelName: nil,
            outputLanguage: nil,
            action: .sent
        ))
    }

    /// Deploy the reviewed/edited revision (falls back to the draft if empty).
    func deployRevision() {
        let finalText = revisedDraft.isEmpty ? draft : revisedDraft
        let model = result == nil ? nil : AppSettings.selectedModel()
        deploy(text: finalText, historyInput: .init(
            mode: .compose,
            sourceText: draft,
            finalText: finalText,
            modelID: model?.id,
            modelName: lastModelName ?? model?.displayName,
            outputLanguage: outputLanguage.displayName,
            action: .sent
        ))
        scheduleDistillation(finalText: finalText)
    }

    /// The gap between the AI suggestion and what the user actually sent is
    /// the best teacher for the persona/relationship cards. Observed off the
    /// hot path after a successful compose deploy; failures never surface.
    private func scheduleDistillation(finalText: String) {
        guard didDeploy, AppSettings.isMemoryEnabled() else { return }
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

    /// Deploy text to the live destination (paste into the originating field,
    /// or the clipboard for the standalone fallback deployer).
    private func deploy(text: String, historyInput: HistoryEntryInput) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try deployer.deploy(text)
            Task {
                await LocalHistoryStore.shared.record(historyInput)
                await self.reloadRecentHistory()
            }
            ComposeDraftStore.clear()
            didDeploy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self.didDeploy = false
            }
        } catch {
            errorMessage = "デプロイに失敗しました: \(error.localizedDescription)"
        }
    }
}

import Foundation

/// Persisted compose draft. The key retains its pre-rebuild spelling so an
/// existing user's unfinished draft survives the architecture replacement.
enum FoundationComposeDraftStore {
    private static let legacyKey = "ReviewViewModel.composeDraft"
    private static var activeUserID: UUID?

    static func activateAccount(userID: UUID?, migrateLegacyDraft: Bool = false) {
        activeUserID = userID
        guard let userID, migrateLegacyDraft else { return }
        let scopedKey = key(for: userID)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: scopedKey) == nil,
           let legacyDraft = defaults.string(forKey: legacyKey) {
            defaults.set(legacyDraft, forKey: scopedKey)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    static func removeAccountData(userID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(for: userID))
    }

    static func load() -> String {
        guard let activeUserID else { return "" }
        return UserDefaults.standard.string(forKey: key(for: activeUserID)) ?? ""
    }

    static func save(_ draft: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let activeUserID else { return }
            UserDefaults.standard.removeObject(forKey: key(for: activeUserID))
        } else {
            guard let activeUserID else { return }
            UserDefaults.standard.set(draft, forKey: key(for: activeUserID))
        }
    }

    static func clear() {
        guard let activeUserID else { return }
        UserDefaults.standard.removeObject(forKey: key(for: activeUserID))
    }

    private static func key(for userID: UUID) -> String {
        "foundation.composeDraft.\(userID.uuidString.lowercased())"
    }
}

/// Lifecycle of the proactive, Vision-grounded draft suggestion that shares
/// the compose panel's lower slot with the review result (the two are mutually
/// exclusive). `.idle` and `.preparing` keep the panel compact; `.ready` and
/// `.unavailable` open the lower surface for useful content or a visible error.
enum ComposeSuggestionStatus: Equatable {
    case idle
    case preparing
    case ready
    case unavailable
}

/// Outgoing-message session state. It owns review, deployment, history, and
/// dictation insertion while depending only on leaf services.
@MainActor
final class ComposeSession: ObservableObject {
    @Published var draft: String {
        didSet { FoundationComposeDraftStore.save(draft) }
    }
    @Published var revisedDraft = ""
    @Published private(set) var result: ReviewResult?
    @Published private(set) var streamingRevision: String?
    @Published private(set) var isReviewing = false
    @Published var errorMessage: String?
    @Published private(set) var lastDurationMs: Int?
    @Published private(set) var lastModelName: String?
    @Published var focusedField: FocusField? = .draft
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published private(set) var recentHistoryEntries: [HistoryEntry] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var situationalContext: SituationalContext?
    @Published private(set) var isContextExcluded = false
    /// Proactive Vision-grounded draft suggestion for the focused external
    /// field. Shares the lower slot with the review result; a review takes it
    /// over. Ephemeral: it is never persisted and disappears when unused.
    @Published private(set) var suggestionStatus: ComposeSuggestionStatus = .idle
    @Published var suggestedDraft = ""
    @Published private(set) var suggestionNote: String?
    /// Set only when the request actually FAILED (capture error, transport
    /// error, gateway error). Nil means "no candidate", which is a different,
    /// non-error outcome. Never collapse a failure into the empty case: the
    /// user must be able to see what went wrong.
    @Published private(set) var suggestionErrorMessage: String?
    /// Technical detail behind the failure (status code, endpoint, raw error),
    /// shown small next to the message so a real cause is never hidden.
    @Published private(set) var suggestionErrorDetail: String?

    let outputLanguage: OutputLanguage

    private let deployer: Deployer
    private let injectedReviewProvider: ReviewProvider?
    private var contextCaptureTask: Task<SituationalContext?, Never>?
    private var reviewTask: Task<Void, Never>?
    private var hasLoadedHistory = false
    private var reviewedDraft: String?
    private var reviewedLanguage: OutputLanguage?

    init(
        deployer: Deployer,
        contextCaptureTask: Task<SituationalContext?, Never>,
        provider: ReviewProvider? = nil
    ) {
        self.deployer = deployer
        self.injectedReviewProvider = provider
        self.contextCaptureTask = contextCaptureTask
        self.outputLanguage = AppSettings.outputLanguage()
        self.draft = FoundationComposeDraftStore.load()

        Task { [weak self] in
            let context = await contextCaptureTask.value
            guard !Task.isCancelled else { return }
            self?.situationalContext = context
        }
    }

    var canReview: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isReviewing
    }

    var canDeployDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canFocusRevision: Bool { result != nil }

    var hasSuggestion: Bool {
        suggestionStatus == .ready
            && !suggestedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEmptyDraft: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var needsReReview: Bool {
        result != nil && (reviewedDraft != draft || reviewedLanguage != outputLanguage)
    }

    func excludeContext() {
        isContextExcluded = true
    }

    func toggleFocusedField() {
        // The lower slot (`.revision`) is the switch target whether it holds a
        // review result or a proactive suggestion; the two never coexist.
        let secondFieldAvailable = canFocusRevision || suggestionStatus == .ready
        guard secondFieldAvailable else {
            focusedField = .draft
            return
        }
        focusedField = focusedField == .revision ? .draft : .revision
    }

    // MARK: - Proactive suggestion

    /// Coordinator drives these once the shared pre-capture resolves. A review
    /// owns the lower slot outright, so suggestion transitions no-op while a
    /// review is present or in flight.
    func markSuggestionPreparing() {
        guard result == nil, !isReviewing else { return }
        suggestionStatus = .preparing
        suggestionNote = nil
        clearSuggestionError()
    }

    func applySuggestion(draft suggestion: String, note: String?) {
        guard result == nil, !isReviewing else {
            suggestionStatus = .idle
            return
        }
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            markSuggestionUnavailable()
            return
        }
        suggestedDraft = trimmed
        suggestionNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        clearSuggestionError()
        suggestionStatus = .ready
    }

    /// The request succeeded but the model had no candidate. This is the only
    /// case that may show the plain "no suggestion" copy.
    func markSuggestionUnavailable() {
        guard result == nil, !isReviewing else {
            suggestionStatus = .idle
            return
        }
        suggestedDraft = ""
        suggestionNote = nil
        clearSuggestionError()
        suggestionStatus = .unavailable
    }

    func resetSuggestion() {
        suggestedDraft = ""
        suggestionNote = nil
        clearSuggestionError()
        suggestionStatus = .idle
        if focusedField == .revision {
            focusedField = .draft
        }
    }

    /// The request FAILED. Surfaces the real reason instead of the vague
    /// "no suggestion" copy — hiding the failure would make a broken endpoint
    /// look like a model that simply had nothing to say.
    func markSuggestionFailed(_ message: String, detail: String? = nil) {
        guard result == nil, !isReviewing else {
            suggestionStatus = .idle
            return
        }
        suggestedDraft = ""
        suggestionNote = nil
        suggestionErrorMessage = message
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestionErrorDetail = (trimmedDetail?.isEmpty ?? true) ? nil : trimmedDetail
        suggestionStatus = .unavailable
    }

    private func clearSuggestionError() {
        suggestionErrorMessage = nil
        suggestionErrorDetail = nil
    }

    /// Send the (possibly edited) suggestion straight to the target field.
    /// Confirming the focused slot is a single action: the old path adopted the
    /// text into the draft and then required a second confirm, which is a
    /// redundant round trip — the slot is editable in place, so there is
    /// nothing the draft hop added.
    func deploySuggestion() {
        let text = suggestedDraft
        let historyInput = HistoryEntryInput(
            sourceText: text,
            finalText: text,
            modelID: nil,
            modelName: nil,
            outputLanguage: outputLanguage.displayName
        )
        guard deploy(text: text, historyInput: historyInput) else { return }
        suggestedDraft = ""
        suggestionNote = nil
        suggestionStatus = .idle
        focusedField = .draft
    }

    func awaitSituationalContext() async -> SituationalContext? {
        await resolveContext()
    }

    func appendTranscription(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if focusedField == .revision, canFocusRevision {
            revisedDraft = appending(piece, to: revisedDraft)
        } else {
            draft = appending(piece, to: draft)
            focusedField = .draft
        }
    }

    func requestReview() {
        guard canReview else { return }
        reviewTask?.cancel()
        reviewTask = Task { [weak self] in
            await self?.runReview()
        }
    }

    func deployDraft() {
        deploy(
            text: draft,
            historyInput: HistoryEntryInput(
                sourceText: draft,
                finalText: draft,
                modelID: nil,
                modelName: nil,
                outputLanguage: nil
            )
        )
    }

    func deployRevision() {
        let finalText = revisedDraft.isEmpty ? draft : revisedDraft
        let historyInput = HistoryEntryInput(
            sourceText: draft,
            finalText: finalText,
            modelID: nil,
            modelName: lastModelName,
            outputLanguage: outputLanguage.displayName
        )
        let original = draft
        let suggestion = result?.revisedText
        let context = situationalContext

        guard deploy(text: finalText, historyInput: historyInput) else { return }
        if AppSettings.isMemoryEnabled(), let suggestion {
            Task.detached(priority: .background) {
                await MemoryDistiller.distillAfterDeploy(
                    original: original,
                    suggestion: suggestion,
                    final: finalText,
                    context: context
                )
            }
        }
    }

    func restoreHistoryEntry(_ entry: HistoryEntry) {
        // Input history is a drafting aid, not a send shortcut. Restoring an
        // entry must leave the user in control of review and deployment.
        adoptSuggestedDraft(entry.finalText)
    }

    func adoptSuggestedDraft(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        reviewTask?.cancel()
        reviewTask = nil
        errorMessage = nil
        result = nil
        revisedDraft = ""
        streamingRevision = nil
        draft = trimmed
        reviewedDraft = nil
        reviewedLanguage = nil
        focusedField = .draft
    }

    func inheritedContextCaptureTask() -> Task<SituationalContext?, Never> {
        let excluded = isContextExcluded
        let captured = situationalContext
        let pending = contextCaptureTask
        return Task {
            guard !excluded else { return nil }
            if let captured { return captured }
            return await pending?.value
        }
    }

    func loadRecentHistoryIfNeeded() async {
        guard !hasLoadedHistory else { return }
        hasLoadedHistory = true
        await reloadHistory()
    }

    func tearDown() {
        reviewTask?.cancel()
        reviewTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
    }

    private func runReview() async {
        OperationalNoticeCenter.shared.beginOperation()
        errorMessage = nil
        result = nil
        revisedDraft = ""
        streamingRevision = nil
        // The review claims the lower slot; drop any pending/ready suggestion.
        suggestionStatus = .idle
        suggestedDraft = ""
        suggestionNote = nil
        isReviewing = true
        let input = draft
        let language = outputLanguage
        let started = Date()
        defer {
            isReviewing = false
            streamingRevision = nil
        }

        let context = await resolveContext()
        let memory = await resolveMemory(context: context)
        guard !Task.isCancelled else { return }
        if let injectedReviewProvider {
            do {
                let reviewed = try await injectedReviewProvider.review(
                    draft: input,
                    language: language,
                    context: context,
                    memory: memory
                )
                try Task.checkCancellation()
                lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
                lastModelName = "Test Provider"
                result = reviewed
                revisedDraft = reviewed.revisedText
                reviewedDraft = input
                reviewedLanguage = language
                focusedField = .draft
            } catch is CancellationError {
                return
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
            return
        }

        guard let provider = GatewayReviewClient.make() else {
            errorMessage = "入力レビューサービスを利用できません。ログイン状態を確認してください。"
            return
        }

        do {
            streamingRevision = ""
            var finalResult: ReviewResult?
            let stream = try await provider.reviewStream(
                draft: input,
                language: language,
                context: context,
                memory: memory
            )
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .delta(let text):
                    streamingRevision = (streamingRevision ?? "") + text
                case .result(let result):
                    finalResult = result
                }
            }
            guard let reviewed = finalResult else {
                throw ProviderError.decoding("stream ended without a result")
            }
            try Task.checkCancellation()
            lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
            lastModelName = "I//O Cloud"
            result = reviewed
            revisedDraft = reviewed.revisedText
            reviewedDraft = input
            reviewedLanguage = language
            // A review is advisory: completing it must not silently change
            // what Enter will deploy. The revision becomes active only after
            // the user explicitly toggles or clicks into that editor.
            focusedField = .draft
        } catch is CancellationError {
            return
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private func resolveContext() async -> SituationalContext? {
        guard !isContextExcluded else { return nil }
        if situationalContext == nil, let contextCaptureTask {
            situationalContext = await contextCaptureTask.value
        }
        return situationalContext
    }

    private func resolveMemory(context: SituationalContext?) async -> MemoryInjection? {
        guard AppSettings.isMemoryEnabled() else { return nil }
        let persona = try? await MemoryStore.shared.personaCard()
        var relationship: MemoryCard?
        if let context {
            let searchableText = [context.windowTitle, context.conversationExcerpt]
                .compactMap { $0 }
                .joined(separator: "\n")
            relationship = try? await MemoryStore.shared.matchRelationship(inText: searchableText)
        }
        let injection = MemoryInjection(
            personaMD: persona?.contentMD,
            relationshipSubject: relationship?.subject,
            relationshipMD: relationship?.contentMD
        )
        return injection.isEmpty ? nil : injection
    }

    @discardableResult
    private func deploy(text: String, historyInput: HistoryEntryInput) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            try deployer.deploy(text)
            FoundationComposeDraftStore.clear()
            Task {
                await LocalHistoryStore.shared.record(historyInput)
                await reloadHistory()
            }
            return true
        } catch {
            errorMessage = "送信に失敗しました。もう一度お試しください。"
            return false
        }
    }

    private func reloadHistory() async {
        guard AppSettings.isHistoryEnabled() else {
            recentHistoryEntries = []
            isLoadingHistory = false
            return
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        recentHistoryEntries = (try? await LocalHistoryStore.shared.fetchEntries(
            limit: 5
        )) ?? []
    }

    private func appending(_ piece: String, to existing: String) -> String {
        guard !existing.isEmpty else { return piece }
        let separator = existing.last?.isWhitespace == true ? "" : " "
        return existing + separator + piece
    }
}

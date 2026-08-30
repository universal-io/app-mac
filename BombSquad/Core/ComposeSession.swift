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
    /// Start or stop dictation from inside the view. The recorder, the
    /// transcriber and the mode rules all live in the coordinator; this is the
    /// microphone in the field asking it to do what the held key asks it to do.
    var onToggleDictation: (() -> Void)?
    /// Ask for a reply draft for this screen now, whatever the always-on
    /// toggle says. The pre-capture and the request live in the coordinator;
    /// this is the 自動返信 button in the bubble asking for one.
    var onRequestSuggestion: (() -> Void)?
    @Published private(set) var situationalContext: SituationalContext?
    @Published private(set) var isContextExcluded = false
    /// Proactive Vision-grounded draft suggestion for the focused external
    /// field. Shares the lower slot with the review result; a review takes it
    /// over. Ephemeral: it is never persisted and disappears when unused.
    @Published private(set) var suggestionStatus: ComposeSuggestionStatus = .idle
    @Published var suggestedDraft = ""
    @Published private(set) var suggestionNote: String?
    /// Display name of the skill the gateway applied to this suggestion.
    /// Shown next to the mode header so injected knowledge is never invisible.
    @Published private(set) var activeSkillName: String?
    /// Set only when the request actually FAILED (capture error, transport
    /// error, gateway error). Nil means "no candidate", which is a different,
    /// non-error outcome. Never collapse a failure into the empty case: the
    /// user must be able to see what went wrong.
    @Published private(set) var suggestionErrorMessage: String?
    /// Technical detail behind the failure (status code, endpoint, raw error),
    /// shown small next to the message so a real cause is never hidden.
    @Published private(set) var suggestionErrorDetail: String?
    /// The one fact this session may ask about, if the gateway found one. At
    /// most one per session by construction: a compose session makes a single
    /// suggestion call, and that call returns at most one candidate.
    @Published private(set) var factQuestion: FactQuestion?
    @Published private(set) var factQuestionState: FactQuestionState = .asking

    let outputLanguage: OutputLanguage

    private let deployer: Deployer
    private let injectedReviewProvider: ReviewProvider?
    private var contextCaptureTask: Task<SituationalContext?, Never>?
    private var reviewTask: Task<Void, Never>?
    /// The draft as it was when the review ran. Published because the bubble
    /// shows it as the user's own speech chip: the sentence the review is
    /// about, which editing the field afterwards must not rewrite.
    @Published private(set) var reviewedDraft: String?
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

    /// An explicit suggestion request takes the result surface over from a
    /// review — the mirror of `runReview` claiming it from a suggestion. The
    /// draft itself is untouched: only the review's output comes down.
    func takeDownReviewSurface() {
        reviewTask?.cancel()
        reviewTask = nil
        isReviewing = false
        result = nil
        revisedDraft = ""
        streamingRevision = nil
        reviewedDraft = nil
        reviewedLanguage = nil
        if focusedField == .revision {
            focusedField = .draft
        }
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
        activeSkillName = nil
        clearSuggestionError()
        // The 自動返信 button can run this more than once per session now; a
        // question left over from the previous answer would sit under a draft
        // it was not asked about.
        clearFactQuestion()
    }

    func applySuggestion(draft suggestion: String, note: String?, skillName: String?) {
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
        activeSkillName = skillName
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
        activeSkillName = nil
        clearSuggestionError()
        suggestionStatus = .unavailable
    }

    func resetSuggestion() {
        suggestedDraft = ""
        suggestionNote = nil
        activeSkillName = nil
        clearSuggestionError()
        clearFactQuestion()
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
        activeSkillName = nil
        suggestionErrorMessage = message
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestionErrorDetail = (trimmedDetail?.isEmpty ?? true) ? nil : trimmedDetail
        suggestionStatus = .unavailable
    }

    private func clearSuggestionError() {
        suggestionErrorMessage = nil
        suggestionErrorDetail = nil
    }

    // MARK: - Fact confirmation

    /// Show the one question this session may ask. Silent learning is not an
    /// option here: nothing is stored unless the user says yes to a sentence
    /// they can read.
    func presentFactQuestion(_ question: FactQuestion?) {
        guard let question else { return }
        factQuestion = question
        factQuestionState = .asking
    }

    /// "No" means "do not store this", not "that value is wrong" — one meaning,
    /// one pair of buttons. A wrong value is corrected on the management
    /// screen, which is also where anything stored here can be deleted.
    func answerFactQuestion(accepted: Bool) {
        guard let question = factQuestion, factQuestionState == .asking else { return }
        guard let client = GatewayFactsClient.make() else {
            factQuestionState = .failed("保存できませんでした。")
            return
        }
        factQuestionState = .saving
        Task { [weak self] in
            do {
                if accepted {
                    try await client.save(
                        scope: question.scope,
                        key: question.key,
                        value: question.value
                    )
                } else {
                    try await client.decline(scope: question.scope, key: question.key)
                }
                await MainActor.run {
                    guard let self, self.factQuestion == question else { return }
                    self.factQuestionState = accepted ? .saved : .declined
                }
            } catch {
                await MainActor.run {
                    guard let self, self.factQuestion == question else { return }
                    self.factQuestionState = .failed(
                        accepted ? "保存できませんでした。" : "設定を記録できませんでした。"
                    )
                }
            }
        }
    }

    private func clearFactQuestion() {
        factQuestion = nil
        factQuestionState = .asking
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
        activeSkillName = nil
        clearFactQuestion()
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
        deploy(text: finalText, historyInput: historyInput)
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
        // The review claims the lower slot; drop any pending/ready suggestion
        // and the question that shared that space.
        suggestionStatus = .idle
        suggestedDraft = ""
        suggestionNote = nil
        activeSkillName = nil
        clearFactQuestion()
        isReviewing = true
        let input = draft
        // Fixed at the start, not on completion: the chip above the result
        // shows the sentence being reviewed, and editing the field while the
        // review runs must not rewrite what it claims to be about.
        reviewedDraft = input
        let language = outputLanguage
        let started = Date()
        defer {
            isReviewing = false
            streamingRevision = nil
        }

        let context = await resolveContext()
        guard !Task.isCancelled else { return }
        if let injectedReviewProvider {
            do {
                let reviewed = try await injectedReviewProvider.review(
                    draft: input,
                    language: language,
                    context: context
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
                context: context
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

    @discardableResult
    private func deploy(text: String, historyInput: HistoryEntryInput) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            try deployer.deploy(text)
            FoundationComposeDraftStore.clear()
            Task {
                await LocalHistoryStore.shared.record(historyInput)
            }
            return true
        } catch {
            errorMessage = "送信に失敗しました。もう一度お試しください。"
            return false
        }
    }

    private func appending(_ piece: String, to existing: String) -> String {
        guard !existing.isEmpty else { return piece }
        let separator = existing.last?.isWhitespace == true ? "" : " "
        return existing + separator + piece
    }
}

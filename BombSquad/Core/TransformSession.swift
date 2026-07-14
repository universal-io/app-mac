import Foundation

/// Phase 3-b receiving-side state. It owns only the selected-text ->
/// interpretation -> clipboard flow and depends on leaf services only.
@MainActor
final class TransformSession: ObservableObject {
    @Published private(set) var draft: String
    @Published private(set) var result: VisionInterpretationResult?
    @Published private(set) var isInterpreting = false
    @Published var errorMessage: String?
    @Published private(set) var lastDurationMs: Int?
    @Published private(set) var lastModelName: String?
    @Published private(set) var didCopy = false
    @Published private(set) var situationalContext: SituationalContext?
    @Published private(set) var isContextExcluded = false

    let outputLanguage: OutputLanguage

    private let deployer: Deployer
    private let overrideProvider: VisionProvider?
    private var contextCaptureTask: Task<SituationalContext?, Never>?
    private var interpretationTask: Task<Void, Never>?
    private var hasStartedInitialInterpretation = false

    init(
        receivedText: String,
        deployer: Deployer = ClipboardDeployer(),
        contextCaptureTask: Task<SituationalContext?, Never>,
        provider: VisionProvider? = nil
    ) {
        self.draft = receivedText
        self.deployer = deployer
        self.contextCaptureTask = contextCaptureTask
        self.overrideProvider = provider
        self.outputLanguage = AppSettings.outputLanguage()

        Task { [weak self] in
            let context = await contextCaptureTask.value
            guard !Task.isCancelled else { return }
            self?.situationalContext = context
        }
    }

    var canInterpret: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isInterpreting
    }

    func excludeContext() {
        isContextExcluded = true
    }

    func startInitialInterpretationIfNeeded() {
        guard !hasStartedInitialInterpretation else { return }
        hasStartedInitialInterpretation = true
        requestInterpretation()
    }

    func requestInterpretation() {
        guard canInterpret else { return }
        interpretationTask?.cancel()
        interpretationTask = Task { [weak self] in
            await self?.runInterpretation()
        }
    }

    func copyInterpretation() {
        guard let result else { return }
        copy(text: result.copyText, historyInput: nil)
    }

    func approveSuggestedAction(_ action: VisionSuggestedAction) {
        guard action.hasDraft else { return }
        copy(
            text: action.draft,
            historyInput: HistoryEntryInput(
                mode: .transform,
                sourceText: draft,
                finalText: action.draft,
                modelID: nil,
                modelName: lastModelName,
                outputLanguage: outputLanguage.displayName,
                action: .copied
            )
        )
    }

    func tearDown() {
        interpretationTask?.cancel()
        interpretationTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
    }

    private func runInterpretation() async {
        OperationalNoticeCenter.shared.beginOperation()
        errorMessage = nil
        result = nil
        isInterpreting = true
        let started = Date()
        defer { isInterpreting = false }

        let input = draft
        let context = await resolveContext()
        let memory = await resolveMemory(context: context)
        guard !Task.isCancelled else { return }
        let provider = currentProvider()

        do {
            let interpreted = try await provider.interpret(
                receivedText: input,
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

    private func copy(text: String, historyInput: HistoryEntryInput?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try deployer.deploy(text)
            if let historyInput {
                Task {
                    await LocalHistoryStore.shared.record(historyInput)
                }
            }
            didCopy = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self?.didCopy = false
            }
        } catch {
            errorMessage = "コピーに失敗しました: \(error.localizedDescription)"
        }
    }

    private func currentProvider() -> VisionProvider {
        if let overrideProvider { return overrideProvider }
        if let gateway = GatewayVisionClient.make() { return gateway }
        OperationalNoticeCenter.shared.publish(
            code: "CLIENT_PROVIDER_FALLBACK",
            message: "I//O Cloudにアクセスできなかったため、端末のOpenAI Visionで処理します。"
        )
        return OpenAIVisionClient()
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

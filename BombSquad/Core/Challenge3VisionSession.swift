import Foundation

struct Challenge3VisionDisplayTurn: Identifiable, Equatable {
    let id = UUID()
    let role: ScreenUnderstandingTurn.Role
    let text: String
    let mode: ScreenUnderstandingResult.Mode?
    let uncertainties: [String]
}

/// Vision-first Challenge 3 state, intentionally independent from VisionSession.
@MainActor
final class Challenge3VisionSession: ObservableObject {
    @Published private(set) var attachment: ScreenshotAttachment
    @Published private(set) var turns: [Challenge3VisionDisplayTurn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var metadata: ScreenUnderstandingMetadata?
    @Published var input = ""
    @Published var errorMessage: String?
    @Published var focusedField: FocusField? = .navigator
    @Published var isRecording = false
    @Published var isTranscribing = false

    private let client: GatewayScreenUnderstandingClient?
    private let outputLanguage: OutputLanguage
    private let onRequestPanelClose: () -> Void
    private var requestTask: Task<Void, Never>?
    private var hasStarted = false

    init(
        attachment: ScreenshotAttachment,
        client: GatewayScreenUnderstandingClient? = GatewayScreenUnderstandingClient.make(),
        onRequestPanelClose: @escaping () -> Void = {}
    ) {
        self.attachment = attachment
        self.client = client
        self.outputLanguage = AppSettings.outputLanguage()
        self.onRequestPanelClose = onRequestPanelClose
    }

    var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        run(question: nil, priorTurns: [])
    }

    func sendQuestion() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }

        let priorTurns = wireTurns
        input = ""
        errorMessage = nil
        turns.append(Challenge3VisionDisplayTurn(
            role: .user,
            text: question,
            mode: nil,
            uncertainties: []
        ))
        run(question: question, priorTurns: priorTurns)
    }

    func appendTranscription(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        input += input.isEmpty || input.last?.isWhitespace == true ? piece : " \(piece)"
        focusedField = .navigator
    }

    func requestPanelClose() {
        onRequestPanelClose()
    }

    func tearDown() {
        requestTask?.cancel()
        requestTask = nil
    }

    private var wireTurns: [ScreenUnderstandingTurn] {
        turns.map { ScreenUnderstandingTurn(role: $0.role, text: $0.text) }
    }

    private func run(question: String?, priorTurns: [ScreenUnderstandingTurn]) {
        requestTask?.cancel()
        guard let client else {
            errorMessage = "Challenge 3 Gatewayを利用できません。ログインとGateway設定を確認してください。"
            return
        }

        isLoading = true
        errorMessage = nil
        let expectedCaptureID = attachment.id
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            do {
                let response = try await client.understand(
                    attachment: self.attachment,
                    question: question,
                    turns: priorTurns,
                    language: self.outputLanguage
                )
                try Task.checkCancellation()
                guard response.captureID == expectedCaptureID,
                      self.attachment.id == expectedCaptureID else {
                    throw ProviderError.decoding("Challenge 3 capture changed during the request.")
                }
                self.metadata = response.metadata
                self.turns.append(Challenge3VisionDisplayTurn(
                    role: .assistant,
                    text: response.result.message,
                    mode: response.result.mode,
                    uncertainties: response.result.uncertainties
                ))
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

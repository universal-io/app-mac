import Foundation
import SwiftUI

/// Receiving-side session (AppMode.transform): a message selected in another
/// app → the shared "understand → respond" interpretation. The exit principle
/// is absolute: the sender's message is never written back — every action
/// only copies to the clipboard.
@MainActor
final class TransformSession: ObservableObject, SessionLifecycle {
    /// The received message pulled in at summon time. Read-only by design:
    /// this pane is reference material, not an editor (and unlike the legacy
    /// path, dictation can no longer silently mutate it).
    let sourceText: String

    @Published private(set) var interpretation: VisionInterpretationResult?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastDurationMs: Int?
    @Published var lastModelName: String?
    /// Briefly toggled true after a copy for toast feedback.
    @Published var didDeploy = false
    @Published var outputLanguage: OutputLanguage = AppSettings.outputLanguage()
    /// L1 situational context captured at summon time (shown as a chip).
    @Published private(set) var situationalContext: SituationalContext?
    @Published private(set) var isContextExcluded = false

    private var contextCaptureTask: Task<SituationalContext?, Never>?
    private var interpretTask: Task<Void, Never>?
    private let overrideVisionProvider: VisionProvider?

    init(sourceText: String, visionProvider: VisionProvider? = nil) {
        self.sourceText = sourceText
        self.overrideVisionProvider = visionProvider
    }

    // MARK: - SessionLifecycle

    func willEnd() {
        interpretTask?.cancel()
        interpretTask = nil
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

    // MARK: - Interpretation

    /// One-stop receiving: runs at summon when signed in, re-runs on a
    /// Right-Shift double-tap, and runs after a mid-session login.
    func startInterpretation() {
        guard !isLoading else { return }
        interpretTask = Task { [weak self] in
            await self?.runInterpretation()
        }
    }

    private func currentVisionProvider() -> VisionProvider {
        if let overrideVisionProvider { return overrideVisionProvider }
        if let gateway = GatewayVisionClient.make() { return gateway }
        return OpenAIVisionClient()
    }

    private func runInterpretation() async {
        errorMessage = nil
        interpretation = nil
        isLoading = true
        let started = Date()
        defer { isLoading = false }

        let context = await resolveContext()
        let memory = await SessionMemory.injection(for: context)
        let provider = currentVisionProvider()
        do {
            let result = try await provider.interpret(
                receivedText: sourceText,
                instruction: nil,
                language: outputLanguage,
                context: context,
                memory: memory
            )
            self.lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
            self.lastModelName = provider is GatewayVisionClient
                ? "I//O Cloud"
                : "OpenAI · \(result.modelID ?? AppSettings.selectedVisionModelID())"
            self.interpretation = result
        } catch is CancellationError {
            // Session ended mid-flight; nothing to surface.
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Exits (clipboard only)

    /// "承認してコピー": copy the prepared reply draft for the reader's own use.
    func approve(_ action: VisionSuggestedAction) {
        guard action.hasDraft else { return }
        copyToClipboard(action.draft, recordHistory: true)
    }

    /// Copies the whole readable interpretation.
    func copyInterpretation() {
        guard let interpretation else { return }
        copyToClipboard(interpretation.copyText, recordHistory: false)
    }

    private func copyToClipboard(_ text: String, recordHistory: Bool) {
        do {
            try ClipboardDeployer().deploy(text)
            if recordHistory {
                let input = HistoryEntryInput(
                    mode: .transform,
                    sourceText: text,
                    finalText: text,
                    modelID: nil,
                    modelName: lastModelName,
                    outputLanguage: outputLanguage.displayName,
                    action: .copied
                )
                Task { await LocalHistoryStore.shared.record(input) }
            }
            didDeploy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self.didDeploy = false
            }
        } catch {
            errorMessage = "コピーに失敗しました: \(error.localizedDescription)"
        }
    }
}

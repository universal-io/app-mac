import Foundation

/// "Understand → respond" interpretation. The source is either a screenshot
/// (vision mode) or a received message (transform mode, M4-B) — both return
/// the same schema so the UI is shared.
protocol VisionProvider {
    func interpret(
        imageURL: URL,
        instruction: String?,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> VisionInterpretationResult

    func interpret(
        receivedText: String,
        instruction: String?,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> VisionInterpretationResult
}

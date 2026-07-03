import Foundation

protocol VisionProvider {
    func interpret(
        imageURL: URL,
        instruction: String?,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> VisionInterpretationResult
}

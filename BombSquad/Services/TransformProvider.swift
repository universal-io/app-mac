import Foundation

protocol TransformProvider {
    func interpret(
        receivedText: String,
        instruction: String?,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> TransformInterpretationResult
}

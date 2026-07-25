import Foundation

protocol TransformProvider {
    func interpret(
        receivedText: String,
        instruction: String?,
        language: OutputLanguage,
        context: SituationalContext?
    ) async throws -> TransformInterpretationResult
}

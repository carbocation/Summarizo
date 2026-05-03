import Foundation

struct LLMDiagnostic: Codable, Hashable, Sendable {
    var modelID: String
    var modelName: String
    var promptVersion: String
    var textSource: DocumentTextSource?
    var contextLength: Int?
    var promptTokens: Int?
    var generatedTokens: Int?
    var stopReason: String?
    var enableThinking: Bool?
    var truncationNote: String?
    var locationStrategy: String?
    var locationSelectorCalls: Int?
    var locationPromptTokens: Int?
    var locationGeneratedTokens: Int?
    var locationDurationSeconds: Double?
    var locationStartPercent: Int?
    var locationLengthChars: Int?
    var locationSelectedStartParagraph: Int?
    var locationSelectedEndParagraph: Int?
    var locationFallbackReason: String?
    var responsePreview: String?
    var error: String?
    var startedAt: Date?
    var finishedAt: Date?
    var fullPrompt: String?
    var fullResponse: String?

    static let empty = LLMDiagnostic(
        modelID: "",
        modelName: "",
        promptVersion: SummaryLLMOperations.promptVersion,
        textSource: nil,
        contextLength: nil,
        promptTokens: nil,
        generatedTokens: nil,
        stopReason: nil,
        enableThinking: nil,
        truncationNote: nil,
        locationStrategy: nil,
        locationSelectorCalls: nil,
        locationPromptTokens: nil,
        locationGeneratedTokens: nil,
        locationDurationSeconds: nil,
        locationStartPercent: nil,
        locationLengthChars: nil,
        locationSelectedStartParagraph: nil,
        locationSelectedEndParagraph: nil,
        locationFallbackReason: nil,
        responsePreview: nil,
        error: nil,
        startedAt: nil,
        finishedAt: nil,
        fullPrompt: nil,
        fullResponse: nil
    )
}

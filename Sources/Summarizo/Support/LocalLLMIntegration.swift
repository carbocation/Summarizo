import CarbocationLocalLLM
import CarbocationLocalLLMRuntime
import CarbocationLocalLLMRuntimeUI
import Foundation

typealias GenerationOptions = CarbocationLocalLLM.GenerationOptions
typealias GenerationOptionsMode = CarbocationLocalLLM.GenerationOptionsMode
typealias GenerationOptionsPreferenceKeys = CarbocationLocalLLM.GenerationOptionsPreferenceKeys
typealias GenerationOptionsResolver = CarbocationLocalLLM.GenerationOptionsResolver
typealias InstalledModel = CarbocationLocalLLM.InstalledModel
typealias JSONSalvage = CarbocationLocalLLM.JSONSalvage
typealias LocalLLMJSON = CarbocationLocalLLM.LocalLLMJSON
typealias LLMChatTemplateMode = CarbocationLocalLLM.LLMChatTemplateMode
typealias LLMEngine = CarbocationLocalLLM.LLMEngine
typealias LLMEngineError = CarbocationLocalLLM.LLMEngineError
typealias LLMGenerationBudget = CarbocationLocalLLM.LLMGenerationBudget
typealias LLMModelSelection = CarbocationLocalLLM.LLMModelSelection
typealias LLMResponsePreview = CarbocationLocalLLM.LLMResponsePreview
typealias LLMStreamEvent = CarbocationLocalLLM.LLMStreamEvent
typealias LLMSystemModelOption = CarbocationLocalLLM.LLMSystemModelOption
typealias LlamaContextCalibrationRecord = CarbocationLocalLLM.LlamaContextCalibrationRecord
typealias LlamaContextCalibrationStore = CarbocationLocalLLM.LlamaContextCalibrationStore
typealias LlamaContextMode = CarbocationLocalLLM.LlamaContextMode
typealias LlamaContextPolicy = CarbocationLocalLLM.LlamaContextPolicy
typealias LlamaContextPreferenceKeys = CarbocationLocalLLM.LlamaContextPreferenceKeys
typealias ModelLibrary = CarbocationLocalLLM.ModelLibrary
typealias ModelSource = CarbocationLocalLLM.ModelSource
typealias ModelStorage = CarbocationLocalLLM.ModelStorage
typealias TokenEstimator = CarbocationLocalLLM.TokenEstimator

typealias LocalLLMEngine = CarbocationLocalLLMRuntime.LocalLLMEngine
typealias LocalLLMEngineError = CarbocationLocalLLMRuntime.LocalLLMEngineError
typealias LocalLLMLoadPlan = CarbocationLocalLLMRuntime.LocalLLMLoadPlan
typealias LocalLLMModelCapabilities = CarbocationLocalLLMRuntime.LocalLLMModelCapabilities
typealias LocalLLMModelConfigurationView = CarbocationLocalLLMRuntimeUI.LocalLLMModelConfigurationView

struct SummaryLLMThinkingPreferences: Equatable, Sendable {
    static let summarizationKey = "llama.thinking.summarization"
    static let defaultSummarization = true

    var summarization: Bool

    static func configured(defaults: UserDefaults = .standard) -> SummaryLLMThinkingPreferences {
        guard defaults.object(forKey: summarizationKey) != nil else {
            return SummaryLLMThinkingPreferences(summarization: defaultSummarization)
        }
        return SummaryLLMThinkingPreferences(summarization: defaults.bool(forKey: summarizationKey))
    }
}

extension GenerationOptions {
    static func configuredSummaryOptions(defaults: UserDefaults = .standard) -> GenerationOptions {
        GenerationOptionsResolver.configuredExtractionOptions(defaults: defaults)
    }
}

extension LlamaContextPolicy {
    static let contextModeKey = LlamaContextPreferenceKeys().contextMode
    static let numCtxKey = LlamaContextPreferenceKeys().numCtx
}

@MainActor
extension ModelLibrary {
    static let shared = ModelLibrary(
        root: AppPaths.modelsDirectory,
        contextLengthProbe: { LocalLLMEngine.probeTrainingContext(at: $0) }
    )
}

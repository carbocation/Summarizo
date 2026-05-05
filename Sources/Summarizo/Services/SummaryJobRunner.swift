import Foundation

actor SummaryJobRunner {
    private struct LoadedLocalLLM {
        var operations: SummaryLLMOperations
        var options: GenerationOptions
        var modelID: String
        var modelName: String
        var contextLength: Int
        var supportsGrammar: Bool
    }

    private var loaded: LoadedLocalLLM?

    func unload() async {
        loaded = nil
        await LocalLLMEngine.shared.unload()
    }

    func summarize(
        candidate: ZoteroPDFCandidate,
        allowOCRFallback: Bool,
        includeFullPrompts: Bool,
        progress: (@Sendable (String) async -> Void)?
    ) async throws -> SummaryRunResult {
        try Task.checkCancellation()
        await progress?("Extracting text")
        let extracted = try await DocumentTextExtractor.extract(
            from: candidate,
            allowOCRFallback: allowOCRFallback,
            onProgress: progress
        )

        try Task.checkCancellation()
        var localLLM = try await loadLocalLLM(includeFullPrompts: includeFullPrompts)
        await progress?("Locating summary source")
        let location = await localLLM.operations.findMethodsResultsSlice(
            in: extracted.fullText,
            options: localLLM.options,
            progress: progress
        )

        guard let slice = location.slice?.nilIfBlank else {
            throw SummaryJobError.noSummarySource
        }

        try Task.checkCancellation()
        await progress?("Summarizing")
        var summaryResult: ChunkedSummaryResult
        while true {
            summaryResult = await localLLM.operations.extractChunkedSummary(
                from: slice,
                textSource: extracted.source,
                options: localLLM.options,
                progress: progress
            )

            let error = summaryResult.diagnostics.last?.error
            guard summaryResult.summary?.nilIfBlank == nil,
                  SummaryContextPolicy.isDecodeResourceFailure(error),
                  let retryContext = SummaryContextPolicy.fallbackContext(below: localLLM.contextLength)
            else { break }

            try Task.checkCancellation()
            await progress?("Model ran out of GPU memory at \(localLLM.contextLength.formatted()) tokens; retrying at \(retryContext.formatted()).")
            localLLM = try await loadLocalLLM(
                includeFullPrompts: includeFullPrompts,
                requestedContextOverride: retryContext
            )
        }

        guard let summary = summaryResult.summary?.nilIfBlank else {
            let error = summaryResult.diagnostics.last?.error ?? "The model did not return a usable summary."
            throw SummaryJobError.summarizationFailed(error)
        }

        var diagnostic = summaryResult.diagnostics.last ?? .empty
        diagnostic.modelID = localLLM.modelID
        diagnostic.modelName = localLLM.modelName
        diagnostic.contextLength = localLLM.contextLength
        diagnostic.textSource = extracted.source
        diagnostic.locationStrategy = location.strategy.rawValue
        diagnostic.locationSelectorCalls = location.selectorCallCount
        diagnostic.locationPromptTokens = location.diagnostics.compactMap(\.promptTokens).reduce(0, +)
        diagnostic.locationGeneratedTokens = location.diagnostics.compactMap(\.generatedTokens).reduce(0, +)
        diagnostic.locationDurationSeconds = location.durationSeconds
        diagnostic.locationStartPercent = location.startPercent
        diagnostic.locationLengthChars = location.lengthChars
        diagnostic.locationSelectedStartParagraph = location.selectedStartParagraphID
        diagnostic.locationSelectedEndParagraph = location.selectedEndParagraphID
        diagnostic.locationFallbackReason = location.fallbackReason

        return SummaryRunResult(
            summary: summary,
            textSource: extracted.source,
            modelID: localLLM.modelID,
            modelName: localLLM.modelName,
            promptVersion: SummaryLLMOperations.promptVersion,
            diagnostic: diagnostic,
            ocrLog: extracted.ocrLog
        )
    }

    private func loadLocalLLM(
        includeFullPrompts: Bool,
        requestedContextOverride: Int? = nil
    ) async throws -> LoadedLocalLLM {
        let selectedModelID = UserDefaults.standard.string(forKey: "llama.selectedModelID") ?? ""
        guard !selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryJobError.modelNotConfigured
        }

        let requestedOptions = GenerationOptions.configuredSummaryOptions()
        let thinkingPreferences = SummaryLLMThinkingPreferences.configured()
        let loadPlan = try await localLLMLoadPlan(for: selectedModelID)
        let requestedContext = SummaryContextPolicy.requestedContext(
            for: loadPlan,
            override: requestedContextOverride
        )
        let expectedContext = SummaryContextPolicy.expectedLoadedContext(
            for: loadPlan,
            requestedContext: requestedContext
        )

        if let loaded, loaded.modelID == selectedModelID {
            if loaded.contextLength == expectedContext,
               loaded.operations.includeFullPrompts == includeFullPrompts,
               loaded.operations.thinkingPreferences == thinkingPreferences,
               loaded.options == requestedOptions {
                return loaded
            }

            if loaded.contextLength == expectedContext {
                let refreshed = LoadedLocalLLM(
                    operations: SummaryLLMOperations(
                        engine: LocalLLMEngine.shared,
                        modelID: loaded.modelID,
                        modelLabel: loaded.modelName,
                        contextLength: loaded.contextLength,
                        supportsGrammar: loaded.supportsGrammar,
                        thinkingPreferences: thinkingPreferences,
                        includeFullPrompts: includeFullPrompts
                    ),
                    options: requestedOptions,
                    modelID: loaded.modelID,
                    modelName: loaded.modelName,
                    contextLength: loaded.contextLength,
                    supportsGrammar: loaded.supportsGrammar
                )
                self.loaded = refreshed
                return refreshed
            }
        }

        let info = try await LocalLLMEngine.shared.load(
            selection: loadPlan.selection,
            from: ModelLibrary.shared,
            requestedContext: requestedContext
        )

        if case .installed(let id) = info.selection, info.trainingContextSize > 0 {
            try? await ModelLibrary.shared.syncContextLength(info.trainingContextSize, for: id)
        }

        let loaded = LoadedLocalLLM(
            operations: SummaryLLMOperations(
                engine: LocalLLMEngine.shared,
                modelID: info.selection.storageValue,
                modelLabel: info.displayName,
                contextLength: info.contextSize,
                supportsGrammar: info.supportsGrammar,
                thinkingPreferences: thinkingPreferences,
                includeFullPrompts: includeFullPrompts
            ),
            options: requestedOptions,
            modelID: info.selection.storageValue,
            modelName: info.displayName,
            contextLength: info.contextSize,
            supportsGrammar: info.supportsGrammar
        )
        self.loaded = loaded
        return loaded
    }

    private func localLLMLoadPlan(for selectedModelID: String) async throws -> LocalLLMLoadPlan {
        let selection = try LocalLLMEngine.selection(from: selectedModelID)
        if let plan = await LocalLLMEngine.loadPlan(
            from: selectedModelID,
            in: ModelLibrary.shared
        ) {
            return plan
        }

        switch selection {
        case .installed(let id):
            throw LocalLLMEngineError.installedModelNotFound(id)
        case .system(let id):
            throw LocalLLMEngineError.unavailableSystemModel(id)
        }
    }

}

enum SummaryContextPolicy {
    static let resourceRetryFloor = 16_384

    static func requestedContext(
        for plan: LocalLLMLoadPlan,
        override: Int? = nil
    ) -> Int {
        let planned = max(plan.requestedContext, LlamaContextPolicy.minimumContext)
        if let override {
            return min(max(override, LlamaContextPolicy.minimumContext), planned)
        }
        return planned
    }

    static func expectedLoadedContext(
        for plan: LocalLLMLoadPlan,
        requestedContext: Int
    ) -> Int {
        let requested = max(requestedContext, LlamaContextPolicy.minimumContext)
        let upperBound = plan.capabilities.contextSize > 0
            ? plan.capabilities.contextSize
            : requested
        return max(LlamaContextPolicy.minimumContext, min(requested, upperBound))
    }

    static func fallbackContext(below context: Int) -> Int? {
        guard context > resourceRetryFloor else { return nil }
        return max(resourceRetryFloor, context / 2)
    }

    static func isDecodeResourceFailure(_ error: String?) -> Bool {
        guard let error else { return false }
        return error.localizedCaseInsensitiveContains("llama_decode failed")
            || error.localizedCaseInsensitiveContains("insufficient memory")
            || error.localizedCaseInsensitiveContains("outofmemory")
            || error.localizedCaseInsensitiveContains("out of memory")
    }
}

struct SummaryRunResult: Sendable {
    var summary: String
    var textSource: DocumentTextSource
    var modelID: String
    var modelName: String
    var promptVersion: String
    var diagnostic: LLMDiagnostic
    var ocrLog: OCRRunLog?
}

enum SummaryJobError: LocalizedError {
    case modelNotConfigured
    case noSummarySource
    case summarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotConfigured:
            "No inference model is configured. Choose one in Settings before summarizing."
        case .noSummarySource:
            "No usable summary source was found in the document text."
        case .summarizationFailed(let detail):
            "Summarization failed: \(detail)"
        }
    }
}

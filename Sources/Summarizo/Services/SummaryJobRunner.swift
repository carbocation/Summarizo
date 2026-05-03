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
        let localLLM = try await loadLocalLLM(includeFullPrompts: includeFullPrompts)
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
        let summaryResult = await localLLM.operations.extractChunkedSummary(
            from: slice,
            textSource: extracted.source,
            options: localLLM.options,
            progress: progress
        )

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

    private func loadLocalLLM(includeFullPrompts: Bool) async throws -> LoadedLocalLLM {
        let selectedModelID = UserDefaults.standard.string(forKey: "llama.selectedModelID") ?? ""
        guard !selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryJobError.modelNotConfigured
        }

        let requestedOptions = GenerationOptions.configuredSummaryOptions()
        let thinkingPreferences = SummaryLLMThinkingPreferences.configured()

        if let loaded, loaded.modelID == selectedModelID {
            if loaded.operations.includeFullPrompts == includeFullPrompts,
               loaded.operations.thinkingPreferences == thinkingPreferences,
               loaded.options == requestedOptions {
                return loaded
            }

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

        await ModelLibrary.shared.refresh()
        let selection = try LocalLLMEngine.selection(from: selectedModelID)
        let desiredContext: Int

        switch selection {
        case .installed(let id):
            guard let installed = await ModelLibrary.shared.model(id: id) else {
                throw LocalLLMEngineError.installedModelNotFound(id)
            }
            desiredContext = LlamaContextPolicy.resolvedRequestedContext(for: installed)
        case .system:
            let capabilities = await LocalLLMEngine.capabilities(for: selection, in: ModelLibrary.shared)
            desiredContext = max(capabilities.contextSize, LlamaContextPolicy.minimumContext)
        }

        let info = try await LocalLLMEngine.shared.load(
            selection: selection,
            from: ModelLibrary.shared,
            requestedContext: desiredContext
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

import Foundation
import OSLog

private let summaryLLMLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.carbocation.Summarizo",
    category: "LLM"
)

struct SummaryLLMOperations {
    static let promptVersion = "summary-v1"

    let engine: any LLMEngine
    let modelID: String
    let modelLabel: String
    let contextLength: Int
    let supportsGrammar: Bool
    let thinkingPreferences: SummaryLLMThinkingPreferences
    let includeFullPrompts: Bool

    init(
        engine: any LLMEngine,
        modelID: String,
        modelLabel: String,
        contextLength: Int,
        supportsGrammar: Bool,
        thinkingPreferences: SummaryLLMThinkingPreferences,
        includeFullPrompts: Bool
    ) {
        self.engine = engine
        self.modelID = modelID
        self.modelLabel = modelLabel
        self.contextLength = max(contextLength, LlamaContextPolicy.minimumContext)
        self.supportsGrammar = supportsGrammar
        self.thinkingPreferences = thinkingPreferences
        self.includeFullPrompts = includeFullPrompts
    }

    func findMethodsResultsSlice(
        in fullText: String,
        options: GenerationOptions,
        progress: (@Sendable (String) async -> Void)?
    ) async -> MethodsResultsLocationResult {
        let chars = Array(fullText)
        let length = chars.count
        guard length > 0 else {
            return MethodsResultsLocationResult(slice: nil, startPercent: nil, lengthChars: nil, diagnostics: [])
        }

        let boundaries = summaryBodyBoundaries(in: fullText, length: length)
        if let headingRange = headingAnchoredSummaryRange(boundaries: boundaries, length: length) {
            let slice = String(chars[headingRange])
            let pct = Int((Double(headingRange.lowerBound) / Double(max(length, 1))) * 100)
            await progress?("Summary source from headings at ~\(pct)% of document.")
            return MethodsResultsLocationResult(slice: slice, startPercent: pct, lengthChars: slice.count, diagnostics: [])
        }

        let windowSize = 1_200
        let scanStride = 900
        let scanEnd = min(boundaries.scanCeiling, boundaries.hardCeiling, length)
        var diagnostics: [LLMDiagnostic] = []
        var positiveStart: Int?
        var positiveEnd: Int?
        var toleratedGap = false
        var cursor = boundaries.searchFloor

        while cursor < scanEnd {
            if Task.isCancelled { break }
            let windowHi = min(scanEnd, cursor + windowSize)
            let excerpt = String(chars[cursor..<windowHi])
            await progress?("Classifying source at \(Int(Double(cursor) / Double(length) * 100))%")
            let result = await classifySectionType(excerpt, options: options)
            diagnostics.append(result.diagnostic)

            guard let value = result.value else {
                cursor += scanStride
                continue
            }

            if value.sectionType == "methods_results" {
                positiveStart = positiveStart ?? cursor
                positiveEnd = windowHi
                toleratedGap = false
            } else if positiveStart != nil {
                if value.sectionType == "back" || value.sectionType == "other" || toleratedGap {
                    break
                }
                toleratedGap = true
            }
            cursor += scanStride
        }

        if let lower = positiveStart, let upper = positiveEnd, lower < upper {
            let slice = String(chars[lower..<upper])
            let pct = Int((Double(lower) / Double(max(length, 1))) * 100)
            await progress?("Summary source classified at ~\(pct)% of document.")
            return MethodsResultsLocationResult(slice: slice, startPercent: pct, lengthChars: slice.count, diagnostics: diagnostics)
        }

        let fallbackStart = min(max(boundaries.searchFloor, length / 5), max(length - 1, 0))
        let fallbackEnd = max(fallbackStart + 1, min(boundaries.hardCeiling, length - length / 5))
        let fallback = fallbackStart < fallbackEnd ? String(chars[fallbackStart..<fallbackEnd]) : fullText
        await progress?("Using heuristic summary slice.")
        return MethodsResultsLocationResult(slice: fallback, startPercent: nil, lengthChars: fallback.count, diagnostics: diagnostics)
    }

    func extractChunkedSummary(
        from slice: String,
        textSource: DocumentTextSource,
        options: GenerationOptions,
        progress: (@Sendable (String) async -> Void)?
    ) async -> ChunkedSummaryResult {
        let chunkFixedCost = estimateTokens(Systems.paperSummarizer)
            + estimateTokens(SummaryPrompts.chunkHeaderBudgetSample)
            + estimateTokens(SummaryPrompts.chunkInstructions)
        let outputBudget = 512
        let safetyMargin = 256
        let chunkPayloadBudget = max(contextLength - chunkFixedCost - outputBudget - safetyMargin, 0)
        let cap = max(chunkPayloadBudget * 3, 1_000)

        if slice.count <= cap {
            let result = await summarizeChunk(
                slice,
                index: 0,
                total: 1,
                textSource: textSource,
                options: options,
                progress: progress
            )
            return ChunkedSummaryResult(summary: result.value, diagnostics: [result.diagnostic])
        }

        let chunks = splitByBlankLines(slice, maxChars: cap).flatMap { hardSplit($0, maxChars: cap) }
        await progress?("Splitting summary source into \(chunks.count) chunks.")

        var partials: [String] = []
        var diagnostics: [LLMDiagnostic] = []
        for (index, chunk) in chunks.enumerated() {
            try? await Task.sleep(nanoseconds: 0)
            await progress?("Summarizing chunk \(index + 1) of \(chunks.count)")
            let result = await summarizeChunk(
                chunk,
                index: index,
                total: chunks.count,
                textSource: textSource,
                options: options,
                progress: progress
            )
            diagnostics.append(result.diagnostic)
            if let value = result.value {
                partials.append(value)
            }
        }

        guard !partials.isEmpty else {
            return ChunkedSummaryResult(summary: nil, diagnostics: diagnostics)
        }

        let synthesis = await synthesizeSummaries(
            partials,
            textSource: textSource,
            options: options,
            progress: progress
        )
        diagnostics.append(synthesis.diagnostic)
        return ChunkedSummaryResult(summary: synthesis.value, diagnostics: diagnostics)
    }

    private func classifySectionType(
        _ excerpt: String,
        options: GenerationOptions
    ) async -> LLMCallResult<SectionClassification> {
        let prompt = """
        Classify which part of a research paper this excerpt comes from.

        Categories:
        - "front": abstract, introduction, background, related work, motivation, or literature review
        - "methods_results": main research contribution, methods, materials, algorithm, implementation, experiments, evaluation, results, measurements, figures, or tables with data
        - "back": discussion, conclusion, limitations, future work, or implications
        - "other": acknowledgments, references, appendices, supplementary/demo transcripts, author contributions, or boilerplate

        Respond with JSON in exactly this shape:
        {"section_type": "methods_results"}

        Excerpt:
        \(excerpt)
        """

        return await generateStructured(
            operation: "classifySection",
            prompt: prompt,
            system: Systems.sectionClassifier,
            grammar: SummaryJSONGrammar.sectionClassification,
            options: options,
            textSource: nil,
            maxOutputTokens: 64,
            progress: nil
        )
    }

    private func summarizeChunk(
        _ chunk: String,
        index: Int,
        total: Int,
        textSource: DocumentTextSource,
        options: GenerationOptions,
        progress: (@Sendable (String) async -> Void)?
    ) async -> LLMCallResult<String> {
        let header = SummaryPrompts.chunkHeader(index: index, total: total)
        let prompt = header + chunk + SummaryPrompts.chunkInstructions
        let result: LLMCallResult<SummaryExtractionResponse> = await generateStructured(
            operation: total == 1 ? "extractSummary" : "summarizeChunk",
            prompt: prompt,
            system: Systems.paperSummarizer,
            grammar: SummaryJSONGrammar.shared,
            options: options,
            textSource: textSource,
            maxOutputTokens: 512,
            progress: progress
        )
        return LLMCallResult(
            value: result.value?.summary.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            diagnostic: result.diagnostic
        )
    }

    private func synthesizeSummaries(
        _ partials: [String],
        textSource: DocumentTextSource,
        options: GenerationOptions,
        progress: (@Sendable (String) async -> Void)?
    ) async -> LLMCallResult<String> {
        let numbered = partials.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
        let prompt = """
        Partial summaries of a work's main research content:

        \(numbered)

        ---

        Merge the partial summaries above into a single 2-4 sentence summary of what the work did and what its method, evidence, evaluation, or examples showed.

        Rules:
        - State observed results, capabilities, limits, or examples in neutral, plain language.
        - Do not use phrases like "the authors show" or "this work demonstrates."
        - Do not invent details not present in the partial summaries.
        - Use short, simple words.

        Respond with JSON in exactly this shape:
        {"summary": "..."}
        """

        let result: LLMCallResult<SummaryExtractionResponse> = await generateStructured(
            operation: "synthesizeSummary",
            prompt: prompt,
            system: Systems.paperSummaryMerger,
            grammar: SummaryJSONGrammar.shared,
            options: options,
            textSource: textSource,
            maxOutputTokens: 512,
            progress: progress
        )
        return LLMCallResult(
            value: result.value?.summary.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            diagnostic: result.diagnostic
        )
    }

    private func generateStructured<T: Decodable & Sendable>(
        operation: String,
        prompt: String,
        system: String,
        grammar: String,
        options: GenerationOptions,
        textSource: DocumentTextSource?,
        maxOutputTokens: Int,
        progress: (@Sendable (String) async -> Void)?
    ) async -> LLMCallResult<T> {
        let startedAt = Date()
        let stats = GenerationStatsBox()
        var callOptions = options
        callOptions.grammar = supportsGrammar ? grammar : nil
        callOptions.enableThinking = thinkingPreferences.summarization
        let initialOutputPlan = structuredOutputPlan(
            system: system,
            prompt: prompt,
            requestedOutputTokens: callOptions.maxOutputTokens ?? maxOutputTokens,
            enableThinking: callOptions.enableThinking
        )
        callOptions.maxOutputTokens = initialOutputPlan.maxOutputTokens
        callOptions.stopAtBalancedJSON = supportsGrammar || !callOptions.enableThinking
        stats.enableThinking = callOptions.enableThinking

        do {
            let attempt: StructuredGenerationAttempt<T> = try await performStructuredGeneration(
                operation: operation,
                prompt: prompt,
                system: system,
                options: callOptions,
                stats: stats,
                progress: progress
            )
            return LLMCallResult(
                value: attempt.value,
                diagnostic: diagnostic(
                    textSource: textSource,
                    startedAt: startedAt,
                    error: nil,
                    response: attempt.normalizedResponse,
                    stats: stats,
                    prompt: prompt,
                    truncationNote: initialOutputPlan.note
                )
            )
        } catch is CancellationError {
            return LLMCallResult(
                value: nil,
                diagnostic: diagnostic(
                    textSource: textSource,
                    startedAt: startedAt,
                    error: "Cancelled",
                    response: nil,
                    stats: stats,
                    prompt: prompt,
                    truncationNote: initialOutputPlan.note
                )
            )
        } catch {
            let primaryError = error
            if shouldRetryStructuredGenerationWithoutThinking(error, options: callOptions) {
                await progress?("Retrying \(operation) with thinking disabled")
                var retryOptions = callOptions
                retryOptions.enableThinking = false
                retryOptions.stopAtBalancedJSON = true
                let retryOutputPlan = structuredOutputPlan(
                    system: system,
                    prompt: prompt,
                    requestedOutputTokens: maxOutputTokens,
                    enableThinking: false
                )
                retryOptions.maxOutputTokens = retryOutputPlan.maxOutputTokens
                let retryStats = GenerationStatsBox()
                retryStats.enableThinking = false

                do {
                    let attempt: StructuredGenerationAttempt<T> = try await performStructuredGeneration(
                        operation: "\(operation)-retry",
                        prompt: prompt,
                        system: system,
                        options: retryOptions,
                        stats: retryStats,
                        progress: progress
                    )
                    var retryDiagnostic = diagnostic(
                        textSource: textSource,
                        startedAt: startedAt,
                        error: nil,
                        response: attempt.normalizedResponse,
                        stats: retryStats,
                        prompt: prompt,
                        truncationNote: nil
                    )
                    retryDiagnostic.truncationNote = [
                        "Retried with model thinking disabled after structured output did not start.",
                        retryOutputPlan.note
                    ].compactMap(\.self).joined(separator: " ")
                    return LLMCallResult(value: attempt.value, diagnostic: retryDiagnostic)
                } catch is CancellationError {
                    return LLMCallResult(
                        value: nil,
                        diagnostic: diagnostic(
                            textSource: textSource,
                            startedAt: startedAt,
                            error: "Cancelled",
                            response: nil,
                            stats: retryStats,
                            prompt: prompt,
                            truncationNote: retryOutputPlan.note
                        )
                    )
                } catch {
                    let detail = "Primary attempt: \(primaryError.localizedDescription). Retry without thinking: \(error.localizedDescription)"
                    summaryLLMLog.error("LLM retry failed operation=\(operation, privacy: .public) error=\(detail, privacy: .public)")
                    return LLMCallResult(
                        value: nil,
                        diagnostic: diagnostic(
                            textSource: textSource,
                            startedAt: startedAt,
                            error: detail,
                            response: nil,
                            stats: retryStats,
                            prompt: prompt,
                            truncationNote: retryOutputPlan.note
                        )
                    )
                }
            }
            summaryLLMLog.error("LLM operation failed operation=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return LLMCallResult(
                value: nil,
                diagnostic: diagnostic(
                    textSource: textSource,
                    startedAt: startedAt,
                    error: error.localizedDescription,
                    response: nil,
                    stats: stats,
                    prompt: prompt,
                    truncationNote: initialOutputPlan.note
                )
            )
        }
    }

    private func performStructuredGeneration<T: Decodable & Sendable>(
        operation: String,
        prompt: String,
        system: String,
        options: GenerationOptions,
        stats: GenerationStatsBox,
        progress: (@Sendable (String) async -> Void)?
    ) async throws -> StructuredGenerationAttempt<T> {
        await progress?("Preparing \(operation) request (\(prompt.count) chars)")
        let response = try await engine.generate(
            system: system,
            prompt: prompt,
            options: options
        ) { event in
            stats.capture(event)
            if let progress {
                Task { await emitProgress(event, progress: progress) }
            }
        }

        let normalized = JSONSalvage.normalizeStringControlChars(JSONSalvage.unwrapResponse(response))
        summaryLLMLog.info("LLM response operation=\(operation, privacy: .public) model=\(modelLabel, privacy: .public) bytes=\(response.utf8.count, privacy: .public)")
        let decoded = try JSONSalvage.decode(T.self, from: response)
        return StructuredGenerationAttempt(value: decoded, normalizedResponse: normalized)
    }

    private func structuredOutputPlan(
        system: String,
        prompt: String,
        requestedOutputTokens: Int,
        enableThinking: Bool
    ) -> StructuredOutputPlan {
        guard !enableThinking else {
            return StructuredOutputPlan(
                maxOutputTokens: nil,
                note: nil
            )
        }

        let promptEstimate = estimateTokens(system) + estimateTokens(prompt)
        let reserve = 128
        let available = contextLength - promptEstimate - reserve
        let note: String?
        if available < requestedOutputTokens {
            note = "Estimated remaining context after prompt is \(max(available, 0)) token(s), below the requested \(requestedOutputTokens)-token output budget; kept the requested budget because local token estimates are conservative and the engine performs the final tokenizer-level context check."
        } else {
            note = nil
        }
        return StructuredOutputPlan(maxOutputTokens: requestedOutputTokens, note: note)
    }

    private func shouldRetryStructuredGenerationWithoutThinking(_ error: Error, options: GenerationOptions) -> Bool {
        guard options.enableThinking else { return false }
        if let llmError = error as? LLMEngineError,
           case .structuredOutputPhaseFailed = llmError {
            return true
        }
        let description = error.localizedDescription
        return description.contains("Structured output generation failed")
            && description.contains("structured output")
    }

    private func diagnostic(
        textSource: DocumentTextSource?,
        startedAt: Date,
        error: String?,
        response: String?,
        stats: GenerationStatsBox,
        prompt: String,
        truncationNote: String?
    ) -> LLMDiagnostic {
        LLMDiagnostic(
            modelID: modelID,
            modelName: modelLabel,
            promptVersion: Self.promptVersion,
            textSource: textSource,
            contextLength: contextLength,
            promptTokens: stats.promptTokens,
            generatedTokens: stats.generatedTokens,
            stopReason: stats.stopReason,
            enableThinking: stats.enableThinking,
            truncationNote: truncationNote,
            responsePreview: response.map { LLMResponsePreview.describe($0, limit: 500) },
            error: error,
            startedAt: startedAt,
            finishedAt: Date(),
            fullPrompt: includeFullPrompts ? prompt : nil,
            fullResponse: includeFullPrompts ? response : nil
        )
    }

    private func splitByBlankLines(_ text: String, maxChars: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var chunks: [String] = []
        var current = ""
        for para in paragraphs {
            let candidate = current.isEmpty ? para : current + "\n\n" + para
            if candidate.count > maxChars && !current.isEmpty {
                chunks.append(current)
                current = para
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    private func hardSplit(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var result: [String] = []
        var remaining = Substring(text)
        while remaining.count > maxChars {
            let hardCut = remaining.index(remaining.startIndex, offsetBy: maxChars)
            let searchStart = remaining.index(remaining.startIndex, offsetBy: maxChars * 9 / 10)
            let breakIndex = remaining[searchStart..<hardCut].lastIndex(where: { ".!?".contains($0) })
                .map { remaining.index(after: $0) }
                ?? hardCut
            result.append(String(remaining[..<breakIndex]))
            remaining = remaining[breakIndex...]
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }

    private func estimateTokens(_ text: String) -> Int {
        TokenEstimator.estimate(text: text)
    }

    private func emitProgress(
        _ event: LLMStreamEvent,
        progress: @Sendable (String) async -> Void
    ) async {
        switch event {
        case .requestSent:
            await progress("Prompt sent")
        case .firstByteReceived(let delay):
            await progress("First response in \(Int(delay))s")
        case .tokenChunk(let preview, let bytes):
            await progress("Streamed \(bytes) bytes: \(preview.replacingOccurrences(of: "\n", with: " "))")
        case .generationStats, .done:
            break
        }
    }

    private func summaryBodyBoundaries(in fullText: String, length: Int) -> SummaryBodyBoundaries {
        let headings = summarySectionHeadings(in: fullText)
        let minimumBodyOffset = min(max(length / 20, 500), 1_500)
        let introductionOffset = headings.first { $0.role == .front && $0.normalizedTitle == "introduction" }?.offset
        let abstractOffset = headings.first { $0.role == .front && $0.normalizedTitle == "abstract" }?.offset
        let searchFloor = introductionOffset
            ?? abstractOffset.map { min(length, $0 + minimumBodyOffset) }
            ?? minimumBodyOffset
        let hardCeiling = headings.first { $0.role == .hardStop && $0.offset > searchFloor }?.offset ?? length
        let backCeiling = headings.first { $0.role == .backStart && $0.offset > searchFloor && $0.offset < hardCeiling }?.offset
        return SummaryBodyBoundaries(
            headings: headings,
            searchFloor: min(searchFloor, length),
            hardCeiling: min(hardCeiling, length),
            scanCeiling: min(backCeiling ?? hardCeiling, hardCeiling, length)
        )
    }

    private func headingAnchoredSummaryRange(boundaries: SummaryBodyBoundaries, length: Int) -> Range<Int>? {
        guard let start = boundaries.headings.first(where: {
            $0.role == .summaryStart && $0.offset >= boundaries.searchFloor && $0.offset < boundaries.hardCeiling
        }) else { return nil }
        let end = boundaries.headings.first {
            $0.offset > start.offset && $0.offset <= boundaries.hardCeiling && ($0.role == .backStart || $0.role == .hardStop)
        }?.offset ?? boundaries.hardCeiling
        return start.offset < end ? start.offset..<min(end, length) : nil
    }

    private func summarySectionHeadings(in text: String) -> [SummarySectionHeading] {
        var headings: [SummarySectionHeading] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines]) { substring, range, _, _ in
            guard let rawLine = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let normalized = normalizedSummaryHeading(rawLine),
                  let role = summaryHeadingRole(for: normalized, rawLine: rawLine)
            else { return }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            headings.append(SummarySectionHeading(offset: offset, normalizedTitle: normalized, role: role))
        }
        return headings
    }

    private func normalizedSummaryHeading(_ line: String) -> String? {
        guard !line.isEmpty else { return nil }
        let words = line.split { $0.isWhitespace }
        guard line.count <= 120, words.count <= 14 else { return nil }
        var candidate = line.replacingOccurrences(
            of: #"^\s*(?:(?:\d+(?:\.\d+)*|[A-Z](?:\.\d+)+)[.)]?|[A-Z])\s+"#,
            with: "",
            options: .regularExpression
        )
        candidate = candidate.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        candidate = candidate.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:")))
        return candidate.isEmpty ? nil : candidate.lowercased()
    }

    private func summaryHeadingRole(for normalized: String, rawLine: String) -> SummaryHeadingRole? {
        if ["abstract", "introduction", "background", "related work", "literature review"].contains(normalized) {
            return .front
        }
        let summaryStarts: Set<String> = [
            "method", "methods", "methodology", "materials and methods", "study design",
            "data and methods", "experimental setup", "experiments", "evaluation",
            "results", "findings", "analysis", "implementation", "protocol"
        ]
        if summaryStarts.contains(normalized) || normalized.hasPrefix("methods ") || normalized.hasPrefix("method ") {
            return .summaryStart
        }
        if ["discussion", "conclusion", "conclusions", "limitations", "future work", "implications"].contains(normalized) {
            return .backStart
        }
        let hardStops: Set<String> = [
            "acknowledgments", "acknowledgements", "references", "bibliography",
            "works cited", "appendix", "appendices", "supplementary material",
            "supplemental material", "author contributions", "funding"
        ]
        if hardStops.contains(normalized) || normalized.hasPrefix("appendix ") || normalized.hasPrefix("supplementary ") {
            return .hardStop
        }
        return nil
    }
}

private enum Systems {
    static let sectionClassifier = "You classify document excerpts by section type. Return only JSON matching the shape shown in the user message."
    static let paperSummarizer = "You summarize what a research work did and what its method, evidence, evaluation, or examples showed, using only the provided main research content. Avoid repeating authors' claims. Return only valid JSON matching the shape shown in the user message."
    static let paperSummaryMerger = "You merge partial summaries of a research work's main content into a single coherent summary. The input is already-summarized text, not raw excerpts. Do not invent details not present in the partial summaries. Return only valid JSON matching the shape shown in the user message."
}

private enum SummaryPrompts {
    static let chunkInstructions = """


    ---

    Summarize in 2-4 short sentences what this work did and what its method, evidence, evaluation, or examples showed, using only the excerpt above.

    Rules:
    - For empirical studies, describe the experiment or analysis concretely.
    - For technical or theoretical papers, describe the protocol, algorithm, system, proof-of-concept, evaluation setup, or worked examples concretely.
    - State observed results, capabilities, limits, or examples in neutral, plain language.
    - Do not use phrases like "the authors show" or "this work demonstrates."
    - Ignore appendix prompt transcripts, chatbot conversations, or safety-demo text unless clearly part of the main evidence.
    - If the excerpt is insufficient, return a brief note of what is observable rather than speculation.

    Respond with JSON in exactly this shape:
    {"summary": "..."}
    """

    static func chunkHeader(index: Int, total: Int) -> String {
        total == 1
            ? "Excerpt (main research content):\n\n"
            : "Excerpt (part \(index + 1) of \(total) of main research content):\n\n"
    }

    static let chunkHeaderBudgetSample = "Excerpt (part 9999 of 9999 of main research content):\n\n"
}

private final class GenerationStatsBox: @unchecked Sendable {
    var promptTokens: Int?
    var generatedTokens: Int?
    var stopReason: String?
    var templateMode: LLMChatTemplateMode?
    var enableThinking: Bool?

    func capture(_ event: LLMStreamEvent) {
        if case .generationStats(let promptTokens, let generatedTokens, let stopReason, let templateMode) = event {
            self.promptTokens = promptTokens
            self.generatedTokens = generatedTokens
            self.stopReason = stopReason
            self.templateMode = templateMode
        }
    }
}

struct MethodsResultsLocationResult: Sendable {
    var slice: String?
    var startPercent: Int?
    var lengthChars: Int?
    var diagnostics: [LLMDiagnostic]
}

struct ChunkedSummaryResult: Sendable {
    var summary: String?
    var diagnostics: [LLMDiagnostic]
}

struct LLMCallResult<Value: Sendable>: Sendable {
    var value: Value?
    var diagnostic: LLMDiagnostic
}

private struct StructuredGenerationAttempt<Value: Sendable>: Sendable {
    var value: Value
    var normalizedResponse: String
}

private struct StructuredOutputPlan: Sendable {
    var maxOutputTokens: Int?
    var note: String?
}

private struct SummaryExtractionResponse: Decodable, Sendable {
    var summary: String
}

private struct SectionClassification: Decodable, Sendable {
    enum CodingKeys: String, CodingKey {
        case sectionType = "section_type"
    }

    var sectionType: String
}

private struct SummaryBodyBoundaries {
    var headings: [SummarySectionHeading]
    var searchFloor: Int
    var hardCeiling: Int
    var scanCeiling: Int
}

private struct SummarySectionHeading {
    var offset: Int
    var normalizedTitle: String
    var role: SummaryHeadingRole
}

private enum SummaryHeadingRole {
    case front
    case summaryStart
    case backStart
    case hardStop
}

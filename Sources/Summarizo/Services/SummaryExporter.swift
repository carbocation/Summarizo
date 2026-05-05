import AppKit
import Foundation

enum SummaryExporter {
    static let exportSchemaVersion = 1

    static func export(_ papers: [SummarizedPaper]) throws -> [URL] {
        let timestamp = Self.timestamp()
        let rows = rowsForExport(
            papers,
            batchID: UUID().uuidString,
            exportedAt: ISO8601DateFormatter().string(from: .now)
        )
        let tsv = AppPaths.exportsDirectory.appending(path: "summarizo-\(timestamp).tsv")
        let jsonl = AppPaths.exportsDirectory.appending(path: "summarizo-\(timestamp).jsonl")

        try tsvString(rows: rows).write(to: tsv, atomically: true, encoding: .utf8)
        try jsonlString(rows: rows).write(to: jsonl, atomically: true, encoding: .utf8)
        _ = try? ZoteroPluginConfigWriter.writeExportDirectoryConfig()
        NSWorkspace.shared.activateFileViewerSelecting([tsv, jsonl])
        return [tsv, jsonl]
    }

    static func rowsForExport(
        _ papers: [SummarizedPaper],
        batchID: String,
        exportedAt: String
    ) -> [SummaryExportRow] {
        addExportMetadata(
            to: papers.map { $0.exportRow() },
            batchID: batchID,
            exportedAt: exportedAt
        )
    }

    static func addExportMetadata(
        to rows: [SummaryExportRow],
        batchID: String,
        exportedAt: String
    ) -> [SummaryExportRow] {
        rows.map { row in
            var row = row
            row.exportSchemaVersion = exportSchemaVersion
            row.exportBatchID = batchID
            row.exportedAt = exportedAt
            return row
        }
    }

    static func tsvString(rows: [SummaryExportRow]) -> String {
        let header = [
            "library", "libraryID", "parentKey", "attachmentKey", "itemType",
            "title", "creators", "date", "journalAbbreviation", "doi", "url",
            "pdfPath", "status", "summary", "model", "summarizedAt", "error",
            "dateAdded", "exportSchemaVersion", "exportBatchID", "exportedAt",
            "modelID", "modelName", "promptVersion", "textSource",
            "contextLength", "promptTokens", "generatedTokens", "stopReason",
            "thinkingEnabled", "truncationNote", "locationStrategy",
            "locationSelectorCalls", "locationPromptTokens", "locationGeneratedTokens",
            "locationDurationSeconds", "locationStartPercent", "locationLengthChars",
            "locationSelectedStartParagraph", "locationSelectedEndParagraph",
            "locationFallbackReason", "responsePreview", "diagnosticError",
            "diagnosticStartedAt", "diagnosticFinishedAt", "sourceFingerprint",
            "storageHash", "storageModTime", "fileSize", "fulltextIndexedPages",
            "fulltextTotalPages", "fulltextIndexedChars", "fulltextTotalChars",
            "primarySelectionScore", "primarySelectionReason", "diagnosticJSON"
        ].joined(separator: "\t")
        let body = rows.map { row in
            let diagnostic = row.diagnostic
            let cells = [
                row.library,
                String(row.libraryID),
                row.parentKey,
                row.attachmentKey,
                row.itemType,
                row.title,
                row.creators,
                row.date,
                row.journalAbbreviation,
                row.doi,
                row.url,
                row.pdfPath,
                row.status,
                row.summary,
                row.model,
                row.summarizedAt,
                row.error,
                row.dateAdded,
                text(row.exportSchemaVersion),
                row.exportBatchID ?? "",
                row.exportedAt ?? "",
                row.modelID,
                row.modelName,
                row.promptVersion,
                row.textSource,
                text(diagnostic?.contextLength),
                text(diagnostic?.promptTokens),
                text(diagnostic?.generatedTokens),
                diagnostic?.stopReason ?? "",
                text(diagnostic?.enableThinking),
                diagnostic?.truncationNote ?? "",
                diagnostic?.locationStrategy ?? "",
                text(diagnostic?.locationSelectorCalls),
                text(diagnostic?.locationPromptTokens),
                text(diagnostic?.locationGeneratedTokens),
                text(diagnostic?.locationDurationSeconds),
                text(diagnostic?.locationStartPercent),
                text(diagnostic?.locationLengthChars),
                text(diagnostic?.locationSelectedStartParagraph),
                text(diagnostic?.locationSelectedEndParagraph),
                diagnostic?.locationFallbackReason ?? "",
                diagnostic?.responsePreview ?? "",
                diagnostic?.error ?? "",
                diagnostic?.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                diagnostic?.finishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                row.sourceFingerprint,
                row.storageHash,
                text(row.storageModTime),
                text(row.fileSize),
                text(row.fulltextIndexedPages),
                text(row.fulltextTotalPages),
                text(row.fulltextIndexedChars),
                text(row.fulltextTotalChars),
                text(row.primarySelectionScore),
                row.primarySelectionReason,
                diagnosticJSONString(row.diagnostic)
            ]
            return cells.map(escapeTSV).joined(separator: "\t")
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    static func jsonlString(rows: [SummaryExportRow]) throws -> String {
        let encoder = compactJSONEncoder()
        return try rows.map { row in
            let data = try encoder.encode(row)
            return String(data: data, encoding: .utf8) ?? "{}"
        }.joined(separator: "\n") + "\n"
    }

    private static func escapeTSV(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func diagnosticJSONString(_ diagnostic: LLMDiagnostic?) -> String {
        guard let diagnostic,
              let data = try? compactJSONEncoder().encode(diagnostic),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    private static func text<T: CustomStringConvertible>(_ value: T?) -> String {
        value?.description ?? ""
    }

    private static func compactJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

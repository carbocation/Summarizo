import Foundation
import SwiftData

struct SummaryImportResult: Equatable, Sendable {
    var rowsRead = 0
    var imported = 0
    var skippedMissing = 0
    var skippedEmptySummary = 0
    var skippedInvalid = 0
    var importedAsStale = 0

    var statusLine: String {
        var parts = [
            "Imported \(imported.formatted()) summary backup row(s)"
        ]
        if importedAsStale > 0 {
            parts.append("\(importedAsStale.formatted()) marked stale")
        }
        if skippedMissing > 0 {
            parts.append("\(skippedMissing.formatted()) skipped because the Zotero item is not in the current library")
        }
        if skippedEmptySummary > 0 {
            parts.append("\(skippedEmptySummary.formatted()) skipped without summaries")
        }
        if skippedInvalid > 0 {
            parts.append("\(skippedInvalid.formatted()) skipped as invalid")
        }
        parts.append("\(rowsRead.formatted()) row(s) read")
        return parts.joined(separator: "; ") + "."
    }
}

enum SummaryImportError: LocalizedError {
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail):
            "Could not import summary backup: \(detail)"
        }
    }
}

enum SummaryImporter {
    static func importSummaries(from url: URL, into modelContext: ModelContext) throws -> SummaryImportResult {
        let data = try Data(contentsOf: url)
        let rows = try decodeRows(from: data)
        return try importRows(rows, into: modelContext)
    }

    static func decodeRows(from data: Data) throws -> [SummaryExportRow] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SummaryImportError.invalidFormat("the file is not valid UTF-8.")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return [] }

        let decoder = JSONDecoder.summarizo
        if first == "[" {
            do {
                return try decoder.decode([SummaryExportRow].self, from: Data(trimmed.utf8))
            } catch {
                throw SummaryImportError.invalidFormat(error.localizedDescription)
            }
        }

        guard first == "{" else {
            throw SummaryImportError.invalidFormat("expected a JSON array or one or more JSON objects.")
        }

        let objects = try topLevelObjectData(in: text)
        return try objects.map { objectData in
            do {
                return try decoder.decode(SummaryExportRow.self, from: objectData)
            } catch {
                throw SummaryImportError.invalidFormat(error.localizedDescription)
            }
        }
    }

    static func importRows(
        _ rows: [SummaryExportRow],
        into modelContext: ModelContext
    ) throws -> SummaryImportResult {
        var result = SummaryImportResult(rowsRead: rows.count)
        let existing = try modelContext.fetch(FetchDescriptor<SummarizedPaper>())
        let papersByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for row in rows {
            guard let parentKey = row.parentKey.nilIfBlank else {
                result.skippedInvalid += 1
                continue
            }

            let id = SummarizedPaper.makeID(libraryID: row.libraryID, parentKey: parentKey)
            guard let paper = papersByID[id] else {
                result.skippedMissing += 1
                continue
            }

            guard let summary = row.summary.nilIfBlank else {
                result.skippedEmptySummary += 1
                continue
            }

            let importedAsStale = apply(row: row, summary: summary, to: paper)
            result.imported += 1
            if importedAsStale {
                result.importedAsStale += 1
            }
        }

        if result.imported > 0 {
            try modelContext.save()
        }
        return result
    }

    private static func apply(
        row: SummaryExportRow,
        summary: String,
        to paper: SummarizedPaper
    ) -> Bool {
        let restoredDate = date(from: row.summarizedAt)
        let diagnostic = restoredDiagnostic(from: row, summarizedAt: restoredDate)
        let sourceFingerprint = row.sourceFingerprint.nilIfBlank
        let shouldMarkStale = sourceFingerprint.map { $0 != paper.sourceFingerprint } ?? false
        let backupStatus = SummaryStatus(rawValue: row.status)

        paper.summary = summary
        paper.modelID = firstNonBlank(row.modelID, diagnostic.modelID)
        paper.modelName = firstNonBlank(row.modelName, row.model, diagnostic.modelName)
        paper.promptVersion = firstNonBlank(row.promptVersion, diagnostic.promptVersion)
            ?? SummaryLLMOperations.promptVersion
        if let textSource = textSource(from: row, diagnostic: diagnostic) {
            paper.textSource = textSource
        }
        paper.errorMessage = row.error.nilIfBlank
        paper.summarizedAt = restoredDate ?? .now
        paper.diagnostic = diagnostic
        paper.status = (shouldMarkStale || backupStatus == .stale) ? .stale : .ready
        paper.updatedAt = .now
        return shouldMarkStale
    }

    private static func restoredDiagnostic(
        from row: SummaryExportRow,
        summarizedAt: Date?
    ) -> LLMDiagnostic {
        var diagnostic = row.diagnostic ?? .empty
        if diagnostic.modelID.isEmpty {
            diagnostic.modelID = row.modelID
        }
        if diagnostic.modelName.isEmpty {
            diagnostic.modelName = firstNonBlank(row.modelName, row.model) ?? ""
        }
        if diagnostic.promptVersion.isEmpty {
            diagnostic.promptVersion = firstNonBlank(row.promptVersion) ?? SummaryLLMOperations.promptVersion
        }
        if diagnostic.textSource == nil,
           let source = DocumentTextSource(rawValue: row.textSource) {
            diagnostic.textSource = source
        }
        if diagnostic.error == nil {
            diagnostic.error = row.error.nilIfBlank
        }
        if diagnostic.finishedAt == nil {
            diagnostic.finishedAt = summarizedAt
        }
        return diagnostic
    }

    private static func textSource(
        from row: SummaryExportRow,
        diagnostic: LLMDiagnostic
    ) -> DocumentTextSource? {
        if let source = DocumentTextSource(rawValue: row.textSource) {
            return source
        }
        return diagnostic.textSource
    }

    private static func date(from text: String) -> Date? {
        guard let text = text.nilIfBlank else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func firstNonBlank(_ values: String?...) -> String? {
        values.lazy.compactMap { $0?.nilIfBlank }.first
    }

    private static func topLevelObjectData(in text: String) throws -> [Data] {
        var objects: [Data] = []
        var objectStart: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in text.indices {
            let character = text[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                if depth > 0 {
                    isInsideString = true
                }
                continue
            }

            if character == "{" {
                if depth == 0 {
                    objectStart = index
                }
                depth += 1
                continue
            }

            if character == "}" {
                guard depth > 0 else {
                    throw SummaryImportError.invalidFormat("found a closing brace before an object was opened.")
                }
                depth -= 1
                if depth == 0, let start = objectStart {
                    let objectText = String(text[start...index])
                    objects.append(Data(objectText.utf8))
                    objectStart = nil
                }
                continue
            }

            if depth == 0, !character.isWhitespace {
                throw SummaryImportError.invalidFormat("expected whitespace between top-level JSON objects.")
            }
        }

        guard depth == 0, !isInsideString else {
            throw SummaryImportError.invalidFormat("the JSON object is incomplete.")
        }
        guard !objects.isEmpty else {
            throw SummaryImportError.invalidFormat("no JSON objects were found.")
        }
        return objects
    }
}

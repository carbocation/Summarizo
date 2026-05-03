import AppKit
import Foundation

enum SummaryExporter {
    static func export(_ papers: [SummarizedPaper]) throws -> [URL] {
        let timestamp = Self.timestamp()
        let rows = papers.map { $0.exportRow() }
        let tsv = AppPaths.exportsDirectory.appending(path: "summarizo-\(timestamp).tsv")
        let jsonl = AppPaths.exportsDirectory.appending(path: "summarizo-\(timestamp).jsonl")

        try tsvString(rows: rows).write(to: tsv, atomically: true, encoding: .utf8)
        try jsonlString(rows: rows).write(to: jsonl, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([tsv, jsonl])
        return [tsv, jsonl]
    }

    static func tsvString(rows: [SummaryExportRow]) -> String {
        let header = [
            "library", "libraryID", "parentKey", "attachmentKey", "itemType",
            "title", "creators", "date", "journalAbbreviation", "doi", "url",
            "pdfPath", "status", "summary", "model", "summarizedAt", "error"
        ].joined(separator: "\t")
        let body = rows.map { row in
            [
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
                row.error
            ].map(escapeTSV).joined(separator: "\t")
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    static func jsonlString(rows: [SummaryExportRow]) throws -> String {
        let encoder = JSONEncoder.summarizo
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

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

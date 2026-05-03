import AppKit
import Foundation
import PDFKit

struct ExtractedDocumentText: Sendable {
    var fullText: String
    var source: DocumentTextSource
    var pageCount: Int?
    var cacheUsed: Bool
    var ocrLog: OCRRunLog?

    var titleContext: String {
        String(fullText.prefix(12_000))
    }
}

struct OCRRunLog: Codable, Hashable, Sendable {
    var pageCount: Int
    var totalCharacters: Int
    var durationSeconds: Double
    var perPageCharacterCounts: [Int]
    var triggerReason: String
}

enum DocumentTextError: LocalizedError {
    case couldNotOpenPDF(String)
    case noTextFound
    case needsOCR(String)

    var errorDescription: String? {
        switch self {
        case .couldNotOpenPDF(let detail):
            "The PDF could not be opened. \(detail)"
        case .noTextFound:
            "No extractable text was found in the PDF."
        case .needsOCR(let reason):
            "This PDF appears to need OCR: \(reason)"
        }
    }
}

enum DocumentTextExtractor {
    static func extract(
        from candidate: ZoteroPDFCandidate,
        allowOCRFallback: Bool,
        onProgress: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ExtractedDocumentText {
        if let cache = candidate.cacheURL,
           let cached = try? String(contentsOf: cache, encoding: .utf8),
           shouldUseCache(cached, candidate: candidate) {
            return ExtractedDocumentText(
                fullText: cached.trimmingCharacters(in: .whitespacesAndNewlines),
                source: .zoteroCache,
                pageCount: candidate.fulltextTotalPages,
                cacheUsed: true,
                ocrLog: nil
            )
        }

        guard let pdfURL = candidate.resolvedURL else {
            throw DocumentTextError.couldNotOpenPDF("No resolved PDF path was stored for this Zotero attachment.")
        }

        guard let document = PDFDocument(url: pdfURL) else {
            throw DocumentTextError.couldNotOpenPDF(openFailureDetail(for: pdfURL))
        }

        let rawText = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pageCount = max(document.pageCount, 1)
        let charsPerPage = rawText.count / pageCount
        let isSparse = charsPerPage < 200

        if rawText.isEmpty || isSparse {
            let reason = rawText.isEmpty
                ? "empty text layer"
                : "\(rawText.count) characters across \(pageCount) page(s)"

            if allowOCRFallback {
                let ocrURL = AppPaths.ocrResultURL(forAttachmentKey: candidate.attachmentKey)
                let result = try await VisionOCRExtractor.extract(
                    from: pdfURL,
                    cacheURL: ocrURL,
                    onProgress: onProgress
                )
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DocumentTextError.noTextFound
                }
                return ExtractedDocumentText(
                    fullText: result.text,
                    source: .ocr,
                    pageCount: result.pageCount,
                    cacheUsed: false,
                    ocrLog: OCRRunLog(
                        pageCount: result.pageCount,
                        totalCharacters: result.text.count,
                        durationSeconds: result.durationSeconds,
                        perPageCharacterCounts: result.perPageCharacterCounts,
                        triggerReason: reason
                    )
                )
            }

            throw DocumentTextError.needsOCR(reason)
        }

        guard !rawText.isEmpty else {
            throw DocumentTextError.noTextFound
        }

        return ExtractedDocumentText(
            fullText: rawText,
            source: .pdfKit,
            pageCount: pageCount,
            cacheUsed: false,
            ocrLog: nil
        )
    }

    private static func shouldUseCache(_ cached: String, candidate: ZoteroPDFCandidate) -> Bool {
        let trimmed = cached.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 500 else { return false }

        if let indexedChars = candidate.fulltextIndexedChars, indexedChars > 0 {
            return trimmed.count >= min(500, indexedChars / 20)
        }

        if let pdfModified = candidate.fileModificationDate,
           let cacheURL = candidate.cacheURL,
           let values = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let cacheModified = values.contentModificationDate {
            return cacheModified >= pdfModified.addingTimeInterval(-60)
        }

        return true
    }

    private static func openFailureDetail(for url: URL) -> String {
        let path = url.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return "The path does not exist: \(path)"
        }
        guard fileManager.isReadableFile(atPath: path) else {
            return "The path exists but is not readable by Summarizo. This usually means the Zotero folder permission bookmark is not active for summarization: \(path)"
        }
        return "The path exists and is readable, but PDFKit could not parse it as a PDF: \(path)"
    }
}

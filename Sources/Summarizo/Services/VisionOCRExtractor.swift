import Foundation
import PDFKit
import Vision

enum VisionOCRExtractor {
    struct Result: Sendable {
        var text: String
        var pageCount: Int
        var perPageCharacterCounts: [Int]
        var durationSeconds: Double
    }

    static func extract(
        from pdfURL: URL,
        cacheURL: URL?,
        onProgress: (@Sendable (String) async -> Void)? = nil
    ) async throws -> Result {
        if let cacheURL,
           let cached = try? String(contentsOf: cacheURL, encoding: .utf8),
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let pages = cached.components(separatedBy: "\n\n")
            return Result(
                text: cached,
                pageCount: pages.count,
                perPageCharacterCounts: pages.map(\.count),
                durationSeconds: 0
            )
        }

        let start = Date()
        guard let document = PDFDocument(url: pdfURL) else {
            throw DocumentTextError.couldNotOpenPDF("Vision OCR could not open the PDF at \(pdfURL.path).")
        }

        var pageTexts: [String] = []
        var pageCounts: [Int] = []

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            await onProgress?("OCR page \(index + 1) of \(document.pageCount)")
            guard let page = document.page(at: index) else {
                pageTexts.append("")
                pageCounts.append(0)
                continue
            }
            let text = recognizeText(in: page)
            pageTexts.append(text)
            pageCounts.append(text.count)
        }

        let fullText = pageTexts.joined(separator: "\n\n")
        if let cacheURL, !fullText.isEmpty {
            try? fullText.write(to: cacheURL, atomically: true, encoding: .utf8)
        }

        return Result(
            text: fullText,
            pageCount: document.pageCount,
            perPageCharacterCounts: pageCounts,
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    private static func recognizeText(in page: PDFPage) -> String {
        let mediaBox = page.bounds(for: .mediaBox)
        let scale: CGFloat = 300.0 / 72.0
        let targetSize = CGSize(
            width: ceil(mediaBox.width * scale),
            height: ceil(mediaBox.height * scale)
        )
        guard targetSize.width > 0, targetSize.height > 0 else { return "" }

        let thumbnail = page.thumbnail(of: targetSize, for: .mediaBox)
        guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

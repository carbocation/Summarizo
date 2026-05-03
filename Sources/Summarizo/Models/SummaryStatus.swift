import Foundation

enum SummaryStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case queued
    case extractingText
    case summarizing
    case ready
    case failed
    case needsOCR
    case skippedSupplementalOnly
    case ambiguousPrimary
    case cancelled
    case stale

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .extractingText: "Extracting Text"
        case .summarizing: "Summarizing"
        case .ready: "Ready"
        case .failed: "Failed"
        case .needsOCR: "Needs OCR"
        case .skippedSupplementalOnly: "Skipped"
        case .ambiguousPrimary: "Ambiguous"
        case .cancelled: "Cancelled"
        case .stale: "Stale"
        }
    }

    var sortRank: Int {
        switch self {
        case .queued: 0
        case .extractingText: 1
        case .summarizing: 2
        case .ready: 3
        case .stale: 4
        case .failed: 5
        case .needsOCR: 6
        case .ambiguousPrimary: 7
        case .skippedSupplementalOnly: 8
        case .cancelled: 9
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "tray"
        case .extractingText: "doc.text.magnifyingglass"
        case .summarizing: "text.bubble"
        case .ready: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .needsOCR: "eye"
        case .skippedSupplementalOnly: "forward.end"
        case .ambiguousPrimary: "questionmark.diamond"
        case .cancelled: "pause.circle"
        case .stale: "arrow.clockwise"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .ready, .failed, .needsOCR, .skippedSupplementalOnly, .ambiguousPrimary, .cancelled:
            true
        case .queued, .extractingText, .summarizing, .stale:
            false
        }
    }
}

enum SummaryFilter: String, CaseIterable, Identifiable {
    case all
    case queued
    case ready
    case failed
    case needsOCR
    case ambiguous
    case skipped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .queued: "Queued"
        case .ready: "Ready"
        case .failed: "Failed"
        case .needsOCR: "Needs OCR"
        case .ambiguous: "Ambiguous"
        case .skipped: "Skipped"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .queued: "tray"
        case .ready: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .needsOCR: "eye"
        case .ambiguous: "questionmark.diamond"
        case .skipped: "forward.end"
        }
    }

    func includes(_ status: SummaryStatus) -> Bool {
        switch self {
        case .all:
            true
        case .queued:
            status == .queued || status == .stale || status == .extractingText || status == .summarizing
        case .ready:
            status == .ready
        case .failed:
            status == .failed || status == .cancelled
        case .needsOCR:
            status == .needsOCR
        case .ambiguous:
            status == .ambiguousPrimary
        case .skipped:
            status == .skippedSupplementalOnly
        }
    }
}

enum DocumentTextSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case zoteroCache
    case pdfKit
    case ocr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zoteroCache: "Zotero cache"
        case .pdfKit: "PDFKit"
        case .ocr: "Vision OCR"
        }
    }
}

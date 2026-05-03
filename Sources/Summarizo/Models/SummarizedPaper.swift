import Foundation
import SwiftData

@Model
final class SummarizedPaper {
    @Attribute(.unique) var id: String
    var libraryID: Int
    var libraryName: String
    var parentItemID: Int
    var parentKey: String
    var parentItemType: String
    var attachmentItemID: Int
    var attachmentKey: String
    var title: String
    var creators: [String]
    var date: String?
    var year: String?
    var doi: String?
    var itemURL: String?
    var abstractNote: String?
    var pdfPath: String?
    var cachePath: String?
    var linkMode: Int
    var rawAttachmentPath: String?
    var statusRawValue: String
    var summary: String
    var errorMessage: String?
    var modelID: String?
    var modelName: String?
    var promptVersion: String
    var textSourceRawValue: String?
    var sourceFingerprint: String
    var storageHash: String?
    var storageModTime: Int64?
    var fileSize: Int64?
    var fulltextIndexedPages: Int?
    var fulltextTotalPages: Int?
    var fulltextIndexedChars: Int?
    var fulltextTotalChars: Int?
    var primarySelectionScore: Int
    var primarySelectionReason: String
    var diagnosticsJSON: String
    var createdAt: Date
    var updatedAt: Date
    var summarizedAt: Date?

    init(candidate: ZoteroPDFCandidate, status: SummaryStatus, reason: String) {
        self.id = Self.makeID(libraryID: candidate.libraryID, parentKey: candidate.parentKey)
        self.libraryID = candidate.libraryID
        self.libraryName = candidate.libraryName
        self.parentItemID = candidate.parentItemID
        self.parentKey = candidate.parentKey
        self.parentItemType = candidate.parentItemType
        self.attachmentItemID = candidate.attachmentItemID
        self.attachmentKey = candidate.attachmentKey
        self.title = candidate.title
        self.creators = candidate.creators
        self.date = candidate.date
        self.year = candidate.year
        self.doi = candidate.doi
        self.itemURL = candidate.url
        self.abstractNote = candidate.abstractNote
        self.pdfPath = candidate.resolvedURL?.path
        self.cachePath = candidate.cacheURL?.path
        self.linkMode = candidate.linkMode
        self.rawAttachmentPath = candidate.rawPath
        self.statusRawValue = status.rawValue
        self.summary = ""
        self.errorMessage = nil
        self.modelID = nil
        self.modelName = nil
        self.promptVersion = SummaryLLMOperations.promptVersion
        self.textSourceRawValue = nil
        self.sourceFingerprint = candidate.sourceFingerprint
        self.storageHash = candidate.storageHash
        self.storageModTime = candidate.storageModTime
        self.fileSize = candidate.fileSize
        self.fulltextIndexedPages = candidate.fulltextIndexedPages
        self.fulltextTotalPages = candidate.fulltextTotalPages
        self.fulltextIndexedChars = candidate.fulltextIndexedChars
        self.fulltextTotalChars = candidate.fulltextTotalChars
        self.primarySelectionScore = candidate.score
        self.primarySelectionReason = reason
        self.diagnosticsJSON = Self.encodeDiagnostic(.empty)
        self.createdAt = .now
        self.updatedAt = .now
        self.summarizedAt = nil
    }

    static func makeID(libraryID: Int, parentKey: String) -> String {
        "\(libraryID):\(parentKey)"
    }

    var status: SummaryStatus {
        get { SummaryStatus(rawValue: statusRawValue) ?? .failed }
        set {
            statusRawValue = newValue.rawValue
            updatedAt = .now
        }
    }

    var textSource: DocumentTextSource? {
        get {
            guard let textSourceRawValue else { return nil }
            return DocumentTextSource(rawValue: textSourceRawValue)
        }
        set {
            textSourceRawValue = newValue?.rawValue
            updatedAt = .now
        }
    }

    var creatorYearSortValue: String {
        [creators.first ?? "", year ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var statusSortValue: String {
        "\(status.sortRank)-\(status.displayName)"
    }

    var textSourceSortValue: String {
        textSource?.displayName ?? ""
    }

    var summaryAgeSortValue: Date {
        summarizedAt ?? updatedAt
    }

    var diagnostic: LLMDiagnostic {
        get {
            guard let data = diagnosticsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder.summarizo.decode(LLMDiagnostic.self, from: data)
            else { return .empty }
            return decoded
        }
        set {
            diagnosticsJSON = Self.encodeDiagnostic(newValue)
            updatedAt = .now
        }
    }

    func apply(candidate: ZoteroPDFCandidate, status newStatus: SummaryStatus, reason: String) {
        libraryID = candidate.libraryID
        libraryName = candidate.libraryName
        parentItemID = candidate.parentItemID
        parentKey = candidate.parentKey
        parentItemType = candidate.parentItemType
        attachmentItemID = candidate.attachmentItemID
        attachmentKey = candidate.attachmentKey
        title = candidate.title
        creators = candidate.creators
        date = candidate.date
        year = candidate.year
        doi = candidate.doi
        itemURL = candidate.url
        abstractNote = candidate.abstractNote
        pdfPath = candidate.resolvedURL?.path
        cachePath = candidate.cacheURL?.path
        linkMode = candidate.linkMode
        rawAttachmentPath = candidate.rawPath
        storageHash = candidate.storageHash
        storageModTime = candidate.storageModTime
        fileSize = candidate.fileSize
        fulltextIndexedPages = candidate.fulltextIndexedPages
        fulltextTotalPages = candidate.fulltextTotalPages
        fulltextIndexedChars = candidate.fulltextIndexedChars
        fulltextTotalChars = candidate.fulltextTotalChars
        primarySelectionScore = candidate.score
        primarySelectionReason = reason

        if sourceFingerprint != candidate.sourceFingerprint {
            sourceFingerprint = candidate.sourceFingerprint
            if status == .ready {
                status = .stale
            } else if status != .summarizing && status != .extractingText {
                status = newStatus
            }
        } else if status != .ready {
            status = newStatus
        }
        updatedAt = .now
    }

    func makeCandidate() -> ZoteroPDFCandidate {
        ZoteroPDFCandidate(
            libraryID: libraryID,
            libraryName: libraryName,
            parentItemID: parentItemID,
            parentKey: parentKey,
            parentItemType: parentItemType,
            title: title,
            creators: creators,
            date: date,
            doi: doi,
            url: itemURL,
            abstractNote: abstractNote,
            attachmentItemID: attachmentItemID,
            attachmentKey: attachmentKey,
            attachmentTitle: nil,
            linkMode: linkMode,
            rawPath: rawAttachmentPath,
            resolvedURL: pdfPath.map(URL.init(fileURLWithPath:)),
            cacheURL: cachePath.map(URL.init(fileURLWithPath:)),
            isReadable: pdfPath.map { FileManager.default.isReadableFile(atPath: $0) } ?? false,
            storageModTime: storageModTime,
            storageHash: storageHash,
            fileSize: fileSize,
            fileModificationDate: nil,
            fulltextIndexedPages: fulltextIndexedPages,
            fulltextTotalPages: fulltextTotalPages,
            fulltextIndexedChars: fulltextIndexedChars,
            fulltextTotalChars: fulltextTotalChars,
            score: primarySelectionScore,
            selectionReason: primarySelectionReason
        )
    }

    func exportRow() -> SummaryExportRow {
        SummaryExportRow(
            library: libraryName,
            libraryID: libraryID,
            parentKey: parentKey,
            attachmentKey: attachmentKey,
            itemType: parentItemType,
            title: title,
            creators: creators.joined(separator: "; "),
            date: date ?? "",
            doi: doi ?? "",
            url: itemURL ?? "",
            pdfPath: pdfPath ?? "",
            status: status.rawValue,
            summary: summary,
            model: modelName ?? "",
            summarizedAt: summarizedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            error: errorMessage ?? ""
        )
    }

    private static func encodeDiagnostic(_ diagnostic: LLMDiagnostic) -> String {
        guard let data = try? JSONEncoder.summarizo.encode(diagnostic),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

import Foundation

struct SummaryExportRow: Codable, Sendable {
    var library: String
    var libraryID: Int
    var parentKey: String
    var attachmentKey: String
    var itemType: String
    var title: String
    var creators: String
    var date: String
    var dateAdded: String = ""
    var exportSchemaVersion: Int?
    var exportBatchID: String?
    var exportedAt: String?
    var journalAbbreviation: String
    var doi: String
    var url: String
    var pdfPath: String
    var status: String
    var summary: String
    var model: String
    var modelID: String
    var modelName: String
    var promptVersion: String
    var textSource: String
    var summarizedAt: String
    var error: String
    var sourceFingerprint: String
    var storageHash: String
    var storageModTime: Int64?
    var fileSize: Int64?
    var fulltextIndexedPages: Int?
    var fulltextTotalPages: Int?
    var fulltextIndexedChars: Int?
    var fulltextTotalChars: Int?
    var primarySelectionScore: Int?
    var primarySelectionReason: String
    var diagnostic: LLMDiagnostic?

    init(
        library: String,
        libraryID: Int,
        parentKey: String,
        attachmentKey: String,
        itemType: String,
        title: String,
        creators: String,
        date: String,
        dateAdded: String = "",
        exportSchemaVersion: Int? = nil,
        exportBatchID: String? = nil,
        exportedAt: String? = nil,
        journalAbbreviation: String,
        doi: String,
        url: String,
        pdfPath: String,
        status: String,
        summary: String,
        model: String,
        modelID: String = "",
        modelName: String = "",
        promptVersion: String = "",
        textSource: String = "",
        summarizedAt: String,
        error: String,
        sourceFingerprint: String = "",
        storageHash: String = "",
        storageModTime: Int64? = nil,
        fileSize: Int64? = nil,
        fulltextIndexedPages: Int? = nil,
        fulltextTotalPages: Int? = nil,
        fulltextIndexedChars: Int? = nil,
        fulltextTotalChars: Int? = nil,
        primarySelectionScore: Int? = nil,
        primarySelectionReason: String = "",
        diagnostic: LLMDiagnostic? = nil
    ) {
        self.library = library
        self.libraryID = libraryID
        self.parentKey = parentKey
        self.attachmentKey = attachmentKey
        self.itemType = itemType
        self.title = title
        self.creators = creators
        self.date = date
        self.dateAdded = dateAdded
        self.exportSchemaVersion = exportSchemaVersion
        self.exportBatchID = exportBatchID
        self.exportedAt = exportedAt
        self.journalAbbreviation = journalAbbreviation
        self.doi = doi
        self.url = url
        self.pdfPath = pdfPath
        self.status = status
        self.summary = summary
        self.model = model
        self.modelID = modelID
        self.modelName = modelName
        self.promptVersion = promptVersion
        self.textSource = textSource
        self.summarizedAt = summarizedAt
        self.error = error
        self.sourceFingerprint = sourceFingerprint
        self.storageHash = storageHash
        self.storageModTime = storageModTime
        self.fileSize = fileSize
        self.fulltextIndexedPages = fulltextIndexedPages
        self.fulltextTotalPages = fulltextTotalPages
        self.fulltextIndexedChars = fulltextIndexedChars
        self.fulltextTotalChars = fulltextTotalChars
        self.primarySelectionScore = primarySelectionScore
        self.primarySelectionReason = primarySelectionReason
        self.diagnostic = diagnostic
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        library = try container.decodeStringIfPresent(forKey: .library)
        libraryID = try container.decodeFlexibleIntIfPresent(forKey: .libraryID) ?? 0
        parentKey = try container.decodeStringIfPresent(forKey: .parentKey)
        attachmentKey = try container.decodeStringIfPresent(forKey: .attachmentKey)
        itemType = try container.decodeStringIfPresent(forKey: .itemType)
        title = try container.decodeStringIfPresent(forKey: .title)
        creators = try container.decodeStringIfPresent(forKey: .creators)
        date = try container.decodeStringIfPresent(forKey: .date)
        dateAdded = try container.decodeStringIfPresent(forKey: .dateAdded)
        exportSchemaVersion = try container.decodeFlexibleIntIfPresent(forKey: .exportSchemaVersion)
        exportBatchID = try container.decodeIfPresent(String.self, forKey: .exportBatchID)
        exportedAt = try container.decodeIfPresent(String.self, forKey: .exportedAt)
        journalAbbreviation = try container.decodeStringIfPresent(forKey: .journalAbbreviation)
        doi = try container.decodeStringIfPresent(forKey: .doi)
        url = try container.decodeStringIfPresent(forKey: .url)
        pdfPath = try container.decodeStringIfPresent(forKey: .pdfPath)
        status = try container.decodeStringIfPresent(forKey: .status)
        summary = try container.decodeStringIfPresent(forKey: .summary)
        model = try container.decodeStringIfPresent(forKey: .model)
        modelID = try container.decodeStringIfPresent(forKey: .modelID)
        modelName = try container.decodeStringIfPresent(forKey: .modelName)
        promptVersion = try container.decodeStringIfPresent(forKey: .promptVersion)
        textSource = try container.decodeStringIfPresent(forKey: .textSource)
        summarizedAt = try container.decodeStringIfPresent(forKey: .summarizedAt)
        error = try container.decodeStringIfPresent(forKey: .error)
        sourceFingerprint = try container.decodeStringIfPresent(forKey: .sourceFingerprint)
        storageHash = try container.decodeStringIfPresent(forKey: .storageHash)
        storageModTime = try container.decodeFlexibleInt64IfPresent(forKey: .storageModTime)
        fileSize = try container.decodeFlexibleInt64IfPresent(forKey: .fileSize)
        fulltextIndexedPages = try container.decodeFlexibleIntIfPresent(forKey: .fulltextIndexedPages)
        fulltextTotalPages = try container.decodeFlexibleIntIfPresent(forKey: .fulltextTotalPages)
        fulltextIndexedChars = try container.decodeFlexibleIntIfPresent(forKey: .fulltextIndexedChars)
        fulltextTotalChars = try container.decodeFlexibleIntIfPresent(forKey: .fulltextTotalChars)
        primarySelectionScore = try container.decodeFlexibleIntIfPresent(forKey: .primarySelectionScore)
        primarySelectionReason = try container.decodeStringIfPresent(forKey: .primarySelectionReason)
        diagnostic = try container.decodeIfPresent(LLMDiagnostic.self, forKey: .diagnostic)
    }
}

private extension KeyedDecodingContainer {
    func decodeStringIfPresent(forKey key: Key) throws -> String {
        try decodeIfPresent(String.self, forKey: key) ?? ""
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int(text)
        }
        return nil
    }

    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(text)
        }
        return nil
    }
}

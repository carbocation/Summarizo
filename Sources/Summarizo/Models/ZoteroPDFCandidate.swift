import Foundation

struct ZoteroPDFCandidate: Identifiable, Hashable, Sendable {
    var id: String { "\(libraryID):\(parentKey):\(attachmentKey)" }

    var libraryID: Int
    var libraryName: String
    var parentItemID: Int
    var parentKey: String
    var parentItemType: String
    var title: String
    var creators: [String]
    var date: String?
    var dateAdded: String? = nil
    var journalAbbreviation: String?
    var doi: String?
    var url: String?
    var abstractNote: String?
    var attachmentItemID: Int
    var attachmentKey: String
    var attachmentTitle: String?
    var linkMode: Int
    var rawPath: String?
    var resolvedURL: URL?
    var cacheURL: URL?
    var isReadable: Bool
    var storageModTime: Int64?
    var storageHash: String?
    var fileSize: Int64?
    var fileModificationDate: Date?
    var fulltextIndexedPages: Int?
    var fulltextTotalPages: Int?
    var fulltextIndexedChars: Int?
    var fulltextTotalChars: Int?
    var score: Int = 0
    var selectionReason: String = ""

    var year: String? {
        guard let date else { return nil }
        return date.firstYear
    }

    var sourceFingerprint: String {
        [
            "lib=\(libraryID)",
            "parent=\(parentKey)",
            "attachment=\(attachmentKey)",
            "hash=\(storageHash ?? "")",
            "mtime=\(storageModTime.map(String.init) ?? "")",
            "size=\(fileSize.map(String.init) ?? "")",
            "fileMtime=\(fileModificationDate?.timeIntervalSince1970.description ?? "")"
        ].joined(separator: "|")
    }
}

struct PrimaryPDFSelection: Sendable {
    var parentID: String
    var candidate: ZoteroPDFCandidate?
    var status: SummaryStatus
    var reason: String
}

private extension String {
    var firstYear: String? {
        let pattern = #"(?:19|20)\d{2}"#
        guard let range = range(of: pattern, options: .regularExpression) else { return nil }
        return String(self[range])
    }
}

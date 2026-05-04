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
    var journalAbbreviation: String
    var doi: String
    var url: String
    var pdfPath: String
    var status: String
    var summary: String
    var model: String
    var summarizedAt: String
    var error: String
}

import Foundation

struct ZoteroScanResult: Sendable {
    var candidates: [ZoteroPDFCandidate]
    var selected: [PrimaryPDFSelection]
}

struct ZoteroDatabaseReader {
    let dataDirectory: URL
    let databaseURL: URL
    let fileManager: FileManager

    init(dataDirectory: URL, databaseURL: URL, fileManager: FileManager = .default) {
        self.dataDirectory = dataDirectory
        self.databaseURL = databaseURL
        self.fileManager = fileManager
    }

    func scanPrimaryPDFs() throws -> ZoteroScanResult {
        let database = try SQLiteDatabase(path: databaseURL.path, readOnly: true)
        let candidates = try database.rows(sql: Self.attachmentQuery) { row in
            makeCandidate(row)
        }
        let selections = PrimaryPDFSelector.selectPrimaryPDFs(from: candidates)
        return ZoteroScanResult(candidates: candidates, selected: selections)
    }

    private func makeCandidate(_ row: SQLiteRow) -> ZoteroPDFCandidate {
        let libraryID = row.int(0)
        let libraryType = row.string(1) ?? "library"
        let groupName = row.string(2)?.nilIfBlank
        let libraryName = groupName ?? (libraryType == "user" ? "My Library" : libraryType.capitalized)
        let parentItemID = row.int(3)
        let parentKey = row.string(4) ?? ""
        let parentItemType = row.string(5) ?? "item"
        let parentTitle = row.string(6)?.nilIfBlank ?? "Untitled"
        let creators = (row.string(7) ?? "")
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let date = row.string(8)?.nilIfBlank
        let journalAbbreviation = row.string(9)?.nilIfBlank
        let doi = row.string(10)?.nilIfBlank
        let url = row.string(11)?.nilIfBlank
        let abstractNote = row.string(12)?.nilIfBlank
        let attachmentItemID = row.int(13)
        let attachmentKey = row.string(14) ?? ""
        let attachmentTitle = row.string(15)?.nilIfBlank
        let linkMode = row.int(16)
        let rawPath = row.string(17)?.nilIfBlank
        let storageModTime = row.int64(18)
        let storageHash = row.string(19)?.nilIfBlank
        let fulltextIndexedPages = row.int64(20).map(Int.init)
        let fulltextTotalPages = row.int64(21).map(Int.init)
        let fulltextIndexedChars = row.int64(22).map(Int.init)
        let fulltextTotalChars = row.int64(23).map(Int.init)

        let resolved = resolveAttachmentURL(attachmentKey: attachmentKey, linkMode: linkMode, rawPath: rawPath)
        let resourceValues = try? resolved?.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let isReadable = resolved.map { fileManager.isReadableFile(atPath: $0.path) } ?? false
        let cacheURL = cacheURL(attachmentKey: attachmentKey, linkMode: linkMode)

        return ZoteroPDFCandidate(
            libraryID: libraryID,
            libraryName: libraryName,
            parentItemID: parentItemID,
            parentKey: parentKey,
            parentItemType: parentItemType,
            title: parentTitle,
            creators: creators,
            date: date,
            journalAbbreviation: journalAbbreviation,
            doi: doi,
            url: url,
            abstractNote: abstractNote,
            attachmentItemID: attachmentItemID,
            attachmentKey: attachmentKey,
            attachmentTitle: attachmentTitle,
            linkMode: linkMode,
            rawPath: rawPath,
            resolvedURL: resolved,
            cacheURL: cacheURL,
            isReadable: isReadable,
            storageModTime: storageModTime,
            storageHash: storageHash,
            fileSize: resourceValues?.fileSize.map(Int64.init),
            fileModificationDate: resourceValues?.contentModificationDate,
            fulltextIndexedPages: fulltextIndexedPages,
            fulltextTotalPages: fulltextTotalPages,
            fulltextIndexedChars: fulltextIndexedChars,
            fulltextTotalChars: fulltextTotalChars
        )
    }

    private func resolveAttachmentURL(attachmentKey: String, linkMode: Int, rawPath: String?) -> URL? {
        guard let rawPath else { return nil }
        switch linkMode {
        case 0, 1:
            guard rawPath.hasPrefix("storage:") else { return nil }
            let filename = String(rawPath.dropFirst("storage:".count))
            return dataDirectory
                .appending(path: "storage", directoryHint: .isDirectory)
                .appending(path: attachmentKey, directoryHint: .isDirectory)
                .appending(path: filename)
        case 2:
            guard rawPath.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: rawPath)
        default:
            return nil
        }
    }

    private func cacheURL(attachmentKey: String, linkMode: Int) -> URL? {
        guard linkMode == 0 || linkMode == 1 else { return nil }
        let url = dataDirectory
            .appending(path: "storage", directoryHint: .isDirectory)
            .appending(path: attachmentKey, directoryHint: .isDirectory)
            .appending(path: ".zotero-ft-cache")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private static let attachmentQuery = """
    SELECT
      p.libraryID,
      l.type,
      g.name,
      p.itemID,
      p.key,
      it.typeName,
      title.value,
      (
        SELECT GROUP_CONCAT(name, '|||') FROM (
          SELECT TRIM(
            CASE
              WHEN c.fieldMode = 1 THEN COALESCE(c.lastName, '')
              ELSE TRIM(COALESCE(c.firstName, '') || ' ' || COALESCE(c.lastName, ''))
            END
          ) AS name
          FROM itemCreators ic
          JOIN creators c ON c.creatorID = ic.creatorID
          WHERE ic.itemID = p.itemID
          ORDER BY ic.orderIndex
        )
      ) AS creators,
      dateValue.value,
      journalAbbreviationValue.value,
      doiValue.value,
      urlValue.value,
      abstractValue.value,
      a.itemID,
      ai.key,
      attachmentTitle.value,
      a.linkMode,
      a.path,
      a.storageModTime,
      a.storageHash,
      ft.indexedPages,
      ft.totalPages,
      ft.indexedChars,
      ft.totalChars
    FROM itemAttachments a
    JOIN items ai ON ai.itemID = a.itemID
    JOIN items p ON p.itemID = a.parentItemID
    JOIN libraries l ON l.libraryID = p.libraryID
    LEFT JOIN groups g ON g.libraryID = p.libraryID
    JOIN itemTypesCombined it ON it.itemTypeID = p.itemTypeID
    LEFT JOIN itemData titleData ON titleData.itemID = p.itemID AND titleData.fieldID = 1
    LEFT JOIN itemDataValues title ON title.valueID = titleData.valueID
    LEFT JOIN itemData dateData ON dateData.itemID = p.itemID AND dateData.fieldID = 6
    LEFT JOIN itemDataValues dateValue ON dateValue.valueID = dateData.valueID
    LEFT JOIN fields journalAbbreviationField ON journalAbbreviationField.fieldName = 'journalAbbreviation'
    LEFT JOIN itemData journalAbbreviationData ON journalAbbreviationData.itemID = p.itemID AND journalAbbreviationData.fieldID = journalAbbreviationField.fieldID
    LEFT JOIN itemDataValues journalAbbreviationValue ON journalAbbreviationValue.valueID = journalAbbreviationData.valueID
    LEFT JOIN itemData doiData ON doiData.itemID = p.itemID AND doiData.fieldID = 59
    LEFT JOIN itemDataValues doiValue ON doiValue.valueID = doiData.valueID
    LEFT JOIN itemData urlData ON urlData.itemID = p.itemID AND urlData.fieldID = 13
    LEFT JOIN itemDataValues urlValue ON urlValue.valueID = urlData.valueID
    LEFT JOIN itemData abstractData ON abstractData.itemID = p.itemID AND abstractData.fieldID = 2
    LEFT JOIN itemDataValues abstractValue ON abstractValue.valueID = abstractData.valueID
    LEFT JOIN itemData attachmentTitleData ON attachmentTitleData.itemID = a.itemID AND attachmentTitleData.fieldID = 1
    LEFT JOIN itemDataValues attachmentTitle ON attachmentTitle.valueID = attachmentTitleData.valueID
    LEFT JOIN fulltextItems ft ON ft.itemID = a.itemID
    WHERE lower(a.contentType) = 'application/pdf'
      AND a.parentItemID IS NOT NULL
      AND it.typeName NOT IN ('attachment', 'note')
      AND a.itemID NOT IN (SELECT itemID FROM deletedItems)
      AND p.itemID NOT IN (SELECT itemID FROM deletedItems)
    ORDER BY p.libraryID, p.key, a.itemID;
    """
}

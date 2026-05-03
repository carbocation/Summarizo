import XCTest
@testable import Summarizo

final class SummarizoTests: XCTestCase {
    func testProfileLocatorParsesDefaultProfileAndCustomDataDir() throws {
        let ini = """
        [Profile0]
        Name=default
        IsRelative=1
        Path=Profiles/abc.default
        Default=1
        """

        let path = ZoteroProfileLocator.parseDefaultProfilePath(from: ini)
        XCTAssertEqual(path?.path, "Profiles/abc.default")
        XCTAssertEqual(path?.isRelative, true)

        let prefs = """
        user_pref("extensions.zotero.useDataDir", true);
        user_pref("extensions.zotero.dataDir", "/Users/example/Zotero");
        """
        XCTAssertEqual(ZoteroProfileLocator.parseBoolPref("extensions.zotero.useDataDir", in: prefs), true)
        XCTAssertEqual(ZoteroProfileLocator.parseStringPref("extensions.zotero.dataDir", in: prefs), "/Users/example/Zotero")
    }

    func testSuggestedDataDirectoryPrefersStandardZoteroFolderWhenPresent() throws {
        let home = try temporaryDirectory()
        let standard = home.appending(path: "Zotero", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: standard.appending(path: "storage", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data().write(to: standard.appending(path: "zotero.sqlite"))

        XCTAssertEqual(ZoteroProfileLocator.suggestedDataDirectory(homeDirectory: home), standard)
    }

    func testPrimarySelectorPrefersFullTextOverSupplement() {
        let fullText = candidate(
            attachmentKey: "FULLTEXT",
            attachmentTitle: "Full Text PDF",
            filename: "Smith et al - 2024 - Deep Learning Study.pdf",
            readable: true
        )
        let supplement = candidate(
            attachmentKey: "SUPP",
            attachmentTitle: "Supplementary material",
            filename: "41588_2024_MOESM1_ESM.pdf",
            readable: true
        )

        let selection = PrimaryPDFSelector.selectPrimaryPDFs(from: [supplement, fullText])
        XCTAssertEqual(selection.count, 1)
        XCTAssertEqual(selection.first?.candidate?.attachmentKey, "FULLTEXT")
        XCTAssertEqual(selection.first?.status, .queued)
    }

    func testPrimarySelectorSkipsSupplementalOnly() {
        let supplement = candidate(
            attachmentKey: "SUPP",
            attachmentTitle: "Supplementary material",
            filename: "supplementary_protocol.pdf",
            readable: true
        )

        let selection = PrimaryPDFSelector.selectPrimaryPDFs(from: [supplement])
        XCTAssertEqual(selection.first?.status, .skippedSupplementalOnly)
    }

    func testReaderScansChildPDFAndIgnoresDeletedAttachment() throws {
        let root = try temporaryDirectory()
        let storage = root.appending(path: "storage/ATTACH1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let pdf = storage.appending(path: "Paper.pdf")
        try Data("PDF".utf8).write(to: pdf)
        try Data("Cached full text with enough characters ".repeated(30).utf8)
            .write(to: storage.appending(path: ".zotero-ft-cache"))

        let dbURL = root.appending(path: "zotero.sqlite")
        let db = try SQLiteDatabase(path: dbURL.path, readOnly: false)
        try db.execute(Self.fixtureSchema)
        try db.execute("""
        INSERT INTO libraries VALUES (1, 'user', 1, 1, 0, 0, 0, 0, 0);
        INSERT INTO itemTypesCombined VALUES (22, 'journalArticle');
        INSERT INTO items VALUES (1, 22, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1, 'PARENT1', 0, 0);
        INSERT INTO items VALUES (2, 3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1, 'ATTACH1', 0, 0);
        INSERT INTO items VALUES (3, 3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1, 'DELETED1', 0, 0);
        INSERT INTO itemAttachments VALUES (2, 1, 1, 'application/pdf', NULL, 'storage:Paper.pdf', 0, 123, 'abc', NULL, NULL);
        INSERT INTO itemAttachments VALUES (3, 1, 1, 'application/pdf', NULL, 'storage:Deleted.pdf', 0, 123, 'def', NULL, NULL);
        INSERT INTO deletedItems VALUES (3);
        INSERT INTO itemDataValues VALUES (10, 'Deep Learning Study');
        INSERT INTO itemDataValues VALUES (11, 'J Test');
        INSERT INTO fields VALUES (90, 'journalAbbreviation');
        INSERT INTO itemData VALUES (1, 1, 10);
        INSERT INTO itemData VALUES (1, 90, 11);
        INSERT INTO creators VALUES (1, 'Jane', 'Smith', 0);
        INSERT INTO itemCreators VALUES (1, 1, 1, 0);
        INSERT INTO fulltextItems VALUES (2, 4, 4, 900, 900, 0, 0);
        """)

        let result = try ZoteroDatabaseReader(dataDirectory: root, databaseURL: dbURL).scanPrimaryPDFs()
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.title, "Deep Learning Study")
        XCTAssertEqual(result.candidates.first?.creators, ["Jane Smith"])
        XCTAssertEqual(result.candidates.first?.journalAbbreviation, "J Test")
        XCTAssertEqual(result.candidates.first?.resolvedURL?.path, pdf.path)
        XCTAssertEqual(result.selected.first?.candidate?.attachmentKey, "ATTACH1")
    }

    func testSQLiteBackupCopiesOpenMultiPageDatabase() throws {
        let root = try temporaryDirectory()
        let sourceURL = root.appending(path: "source.sqlite")
        let snapshotURL = root.appending(path: "snapshot.sqlite")
        let db = try SQLiteDatabase(path: sourceURL.path, readOnly: false)
        try db.execute("PRAGMA journal_mode=WAL;")
        try db.execute("CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT NOT NULL);")
        try db.execute("BEGIN;")
        let payload = String(repeating: "snapshot-page-data-", count: 256)
        for index in 0..<400 {
            try db.execute("INSERT INTO records (value) VALUES ('\(payload)\(index)');")
        }
        try db.execute("COMMIT;")

        try SQLiteDatabase.backup(source: sourceURL, destination: snapshotURL)

        let snapshot = try SQLiteDatabase(path: snapshotURL.path, readOnly: true)
        let rows = try snapshot.rows(sql: "SELECT COUNT(*), SUM(LENGTH(value)) FROM records;") { row in
            (row.int(0), row.int64(1) ?? 0)
        }
        XCTAssertEqual(rows.first?.0, 400)
        XCTAssertGreaterThan(rows.first?.1 ?? 0, 1_000_000)
    }

    func testSnapshotterCopiesSQLiteFilesBeforeOpeningSnapshot() throws {
        let root = try temporaryDirectory()
        let snapshotRoot = root.appending(path: "snapshots", directoryHint: .isDirectory)
        let sourceURL = root.appending(path: "zotero.sqlite")
        let db = try SQLiteDatabase(path: sourceURL.path, readOnly: false)
        try db.execute("PRAGMA journal_mode=WAL;")
        try db.execute("PRAGMA wal_autocheckpoint=0;")
        try db.execute("CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT NOT NULL);")
        try db.execute("INSERT INTO records (value) VALUES ('checkpointed');")
        try db.execute("PRAGMA wal_checkpoint(FULL);")
        try db.execute("INSERT INTO records (value) VALUES ('wal-only');")

        let snapshot = try ZoteroDatabaseSnapshotter.snapshotDatabase(
            in: root,
            destinationDirectory: snapshotRoot
        )

        XCTAssertNotNil(snapshot.note)
        let copied = try SQLiteDatabase(path: snapshot.url.path, readOnly: true)
        let values = try copied.rows(sql: "SELECT value FROM records ORDER BY id;") { row in
            row.string(0) ?? ""
        }
        XCTAssertEqual(values, ["checkpointed", "wal-only"])
    }

    func testTSVExportEscapesTabsAndNewlines() throws {
        let row = SummaryExportRow(
            library: "My\tLibrary",
            libraryID: 1,
            parentKey: "PARENT",
            attachmentKey: "ATTACH",
            itemType: "journalArticle",
            title: "A\nTitle",
            creators: "Smith",
            date: "2024",
            journalAbbreviation: "J\tTest",
            doi: "",
            url: "",
            pdfPath: "/tmp/a.pdf",
            status: "ready",
            summary: "Line 1\nLine 2",
            model: "Model",
            summarizedAt: "",
            error: ""
        )

        let tsv = SummaryExporter.tsvString(rows: [row])
        XCTAssertFalse(tsv.contains("\tLibrary"))
        XCTAssertFalse(tsv.contains("A\nTitle"))
        XCTAssertTrue(tsv.contains("J Test"))
        XCTAssertTrue(tsv.contains("Line 1 Line 2"))

        let jsonl = try SummaryExporter.jsonlString(rows: [row])
        XCTAssertTrue(jsonl.contains(#""journalAbbreviation" : "J\tTest""#))
    }

    func testSummaryThinkingToggleDisablesEngineThinkingAndUsesBoundedJSONOutput() async {
        let engine = CapturingLLMEngine(response: #"{"summary":"ok"}"#)
        let operations = SummaryLLMOperations(
            engine: engine,
            modelID: "model",
            modelLabel: "Model",
            contextLength: 4096,
            supportsGrammar: true,
            thinkingPreferences: SummaryLLMThinkingPreferences(summarization: false),
            includeFullPrompts: false
        )

        let result = await operations.extractChunkedSummary(
            from: "Methods and results. ".repeated(50),
            textSource: .pdfKit,
            options: .extractionSafe,
            progress: nil
        )

        let options = await engine.capturedOptions()
        XCTAssertEqual(result.summary, "ok")
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.enableThinking, false)
        XCTAssertEqual(options.first?.maxOutputTokens, 512)
        XCTAssertEqual(result.diagnostics.last?.enableThinking, false)
    }

    func testSummaryThinkingToggleLeavesThinkingOutputUnbounded() async {
        let engine = CapturingLLMEngine(response: #"{"summary":"ok"}"#)
        let operations = SummaryLLMOperations(
            engine: engine,
            modelID: "model",
            modelLabel: "Model",
            contextLength: 4096,
            supportsGrammar: true,
            thinkingPreferences: SummaryLLMThinkingPreferences(summarization: true),
            includeFullPrompts: false
        )

        let result = await operations.extractChunkedSummary(
            from: "Methods and results. ".repeated(50),
            textSource: .pdfKit,
            options: .extractionSafe,
            progress: nil
        )

        let options = await engine.capturedOptions()
        XCTAssertEqual(result.summary, "ok")
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.enableThinking, true)
        XCTAssertNil(options.first?.maxOutputTokens)
        XCTAssertEqual(result.diagnostics.last?.enableThinking, true)
    }

    func testPaperDisplayStateSortsEveryTableColumnFromCachedRows() {
        let oldest = Date(timeIntervalSince1970: 100)
        let middleDate = Date(timeIntervalSince1970: 200)
        let newest = Date(timeIntervalSince1970: 300)
        let zebra = displayPaper(
            parentKey: "ZEBRA",
            title: "Zebra",
            status: .failed,
            creators: ["Carol Clark"],
            date: "2023",
            journalAbbreviation: "Beta Journal",
            libraryName: "Beta Library",
            textSource: .ocr,
            updatedAt: newest
        )
        let alpha = displayPaper(
            parentKey: "ALPHA",
            title: "Alpha",
            status: .ready,
            creators: ["Alice Adams"],
            date: "2022",
            journalAbbreviation: "Alpha Journal",
            libraryName: "Alpha Library",
            textSource: .pdfKit,
            updatedAt: oldest
        )
        let middle = displayPaper(
            parentKey: "MIDDLE",
            title: "Middle",
            status: .queued,
            creators: ["Bob Brown"],
            date: "2021",
            journalAbbreviation: "Gamma Journal",
            libraryName: "Gamma Library",
            textSource: .zoteroCache,
            updatedAt: middleDate
        )
        let papers = [zebra, alpha, middle]

        XCTAssertEqual(sortedRowIDs(papers, by: .title), [alpha.id, middle.id, zebra.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .creators), [alpha.id, middle.id, zebra.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .year), [middle.id, alpha.id, zebra.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .journal), [alpha.id, zebra.id, middle.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .library), [alpha.id, zebra.id, middle.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .status), [middle.id, alpha.id, zebra.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .textSource), [alpha.id, zebra.id, middle.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .updated), [alpha.id, middle.id, zebra.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .title, order: .reverse), [zebra.id, middle.id, alpha.id])
    }

    func testPaperDisplayStatePreservesSourceOrderForLargeTiedSortGroups() {
        let updatedAt = Date(timeIntervalSince1970: 100)
        let papers = (0..<5_000).map { index in
            displayPaper(
                parentKey: "TIE-\(index)",
                title: "Same Title",
                status: .ready,
                creators: ["Same Creator"],
                date: "2024",
                libraryName: "Same Library",
                textSource: .pdfKit,
                updatedAt: updatedAt
            )
        }

        let state = PaperDisplayState.make(
            papers: papers,
            filter: .all,
            searchText: "",
            selection: [],
            sortOrder: [PaperRowSortComparator(.title)]
        )

        XCTAssertEqual(state.rows.map(\.id), papers.map(\.id))
    }

    func testPaperDisplayStateFiltersAndKeepsSelectionInDisplayOrder() {
        let matchingSelected = displayPaper(
            parentKey: "MATCH",
            title: "Indexed Study",
            status: .ready,
            summary: "Neural retrieval model"
        )
        let hiddenSelected = displayPaper(
            parentKey: "HIDDEN",
            title: "Hidden Study",
            status: .failed,
            summary: "Neural retrieval model"
        )
        let matchingUnselected = displayPaper(
            parentKey: "OTHER",
            title: "Another Study",
            status: .ready,
            summary: "Neural retrieval model"
        )

        let state = PaperDisplayState.make(
            papers: [matchingSelected, hiddenSelected, matchingUnselected],
            filter: .ready,
            searchText: "retrieval",
            selection: [matchingSelected.id, hiddenSelected.id],
            sortOrder: [PaperRowSortComparator(.title)]
        )

        XCTAssertEqual(state.rows.map(\.id), [
            matchingUnselected.id,
            matchingSelected.id
        ])
        XCTAssertEqual(state.selectedPapers.map(\.id), [matchingSelected.id])
        XCTAssertEqual(state.selectedPaper?.id, matchingSelected.id)
    }

    func testPaperDisplayStateSearchesJournalAbbreviationAndShowsAllCreators() {
        let paper = displayPaper(
            parentKey: "JOURNAL",
            title: "Clinical Study",
            status: .ready,
            creators: ["Alice Adams", "Bob Brown", "Carol Clark", "Dana Davis"],
            journalAbbreviation: "JAMA"
        )

        let state = PaperDisplayState.make(
            papers: [paper],
            filter: .all,
            searchText: "jama",
            selection: [],
            sortOrder: [PaperRowSortComparator(.title)]
        )

        XCTAssertEqual(state.rows.map(\.id), [paper.id])
        XCTAssertEqual(state.rows.first?.creatorsDisplay, "Alice Adams, Bob Brown, Carol Clark, Dana Davis")
        XCTAssertEqual(state.rows.first?.yearDisplay, "2024")
        XCTAssertEqual(state.rows.first?.journalDisplayName, "JAMA")
    }

    func testPaperDisplayStateResortsCachedRowsAndSelection() {
        let alpha = displayPaper(parentKey: "ALPHA", title: "Alpha", status: .ready)
        let zebra = displayPaper(parentKey: "ZEBRA", title: "Zebra", status: .ready)
        let state = PaperDisplayState.make(
            papers: [alpha, zebra],
            filter: .all,
            searchText: "",
            selection: [alpha.id],
            sortOrder: [PaperRowSortComparator(.title)]
        )

        let resorted = state.sorted(
            using: [PaperRowSortComparator(.title, order: .reverse)],
            selection: [alpha.id]
        )

        XCTAssertEqual(resorted.rows.map(\.id), [zebra.id, alpha.id])
        XCTAssertEqual(resorted.selectedPapers.map(\.id), [alpha.id])
        XCTAssertEqual(resorted.selectedPaper?.id, alpha.id)
    }

    func testJournalAbbreviationBackfillDoesNotMarkReadyPaperStale() {
        let paper = displayPaper(parentKey: "BACKFILL", title: "Backfill", status: .ready)
        paper.summary = "Existing summary"
        paper.summarizedAt = Date(timeIntervalSince1970: 1_000)
        let originalFingerprint = paper.sourceFingerprint
        let originalSummarizedAt = paper.summarizedAt

        var candidate = paper.makeCandidate()
        candidate.journalAbbreviation = "J Backfill"
        paper.apply(candidate: candidate, status: .queued, reason: "refresh")

        XCTAssertEqual(paper.journalAbbreviation, "J Backfill")
        XCTAssertEqual(paper.sourceFingerprint, originalFingerprint)
        XCTAssertEqual(paper.status, .ready)
        XCTAssertEqual(paper.summary, "Existing summary")
        XCTAssertEqual(paper.summarizedAt, originalSummarizedAt)
    }

    private func displayPaper(
        parentKey: String,
        title: String,
        status: SummaryStatus,
        creators: [String] = ["Jane Smith"],
        date: String? = "2024",
        journalAbbreviation: String? = nil,
        libraryName: String = "My Library",
        textSource: DocumentTextSource? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 100),
        summarizedAt: Date? = nil,
        summary: String = ""
    ) -> SummarizedPaper {
        let candidate = ZoteroPDFCandidate(
            libraryID: 1,
            libraryName: libraryName,
            parentItemID: 1,
            parentKey: parentKey,
            parentItemType: "journalArticle",
            title: title,
            creators: creators,
            date: date,
            journalAbbreviation: journalAbbreviation,
            doi: nil,
            url: nil,
            abstractNote: nil,
            attachmentItemID: 1,
            attachmentKey: "ATTACH-\(parentKey)",
            attachmentTitle: nil,
            linkMode: 1,
            rawPath: "storage:Paper.pdf",
            resolvedURL: URL(fileURLWithPath: "/tmp/Paper.pdf"),
            cacheURL: nil,
            isReadable: true,
            storageModTime: 1,
            storageHash: nil,
            fileSize: 1_000_000,
            fileModificationDate: nil,
            fulltextIndexedPages: nil,
            fulltextTotalPages: nil,
            fulltextIndexedChars: nil,
            fulltextTotalChars: nil
        )
        let paper = SummarizedPaper(candidate: candidate, status: status, reason: "test")
        paper.summary = summary
        paper.textSource = textSource
        paper.updatedAt = updatedAt
        paper.summarizedAt = summarizedAt
        return paper
    }

    private func sortedRowIDs(
        _ papers: [SummarizedPaper],
        by column: PaperRowSortComparator.Column,
        order: SortOrder = .forward
    ) -> [String] {
        PaperDisplayState.make(
            papers: papers,
            filter: .all,
            searchText: "",
            selection: [],
            sortOrder: [PaperRowSortComparator(column, order: order)]
        ).rows.map(\.id)
    }

    private func candidate(
        attachmentKey: String,
        attachmentTitle: String,
        filename: String,
        readable: Bool
    ) -> ZoteroPDFCandidate {
        ZoteroPDFCandidate(
            libraryID: 1,
            libraryName: "My Library",
            parentItemID: 1,
            parentKey: "PARENT",
            parentItemType: "journalArticle",
            title: "Deep Learning Study",
            creators: ["Jane Smith"],
            date: "2024",
            journalAbbreviation: nil,
            doi: nil,
            url: nil,
            abstractNote: nil,
            attachmentItemID: attachmentKey == "FULLTEXT" ? 2 : 3,
            attachmentKey: attachmentKey,
            attachmentTitle: attachmentTitle,
            linkMode: 1,
            rawPath: "storage:\(filename)",
            resolvedURL: URL(fileURLWithPath: "/tmp/\(filename)"),
            cacheURL: nil,
            isReadable: readable,
            storageModTime: 1,
            storageHash: nil,
            fileSize: 1_000_000,
            fileModificationDate: nil,
            fulltextIndexedPages: nil,
            fulltextTotalPages: nil,
            fulltextIndexedChars: nil,
            fulltextTotalChars: nil
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SummarizoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let fixtureSchema = """
    CREATE TABLE libraries (libraryID INTEGER PRIMARY KEY, type TEXT, editable INT, filesEditable INT, version INT, storageVersion INT, lastSync INT, archived INT, isAdmin INT);
    CREATE TABLE groups (groupID INTEGER PRIMARY KEY, libraryID INT, name TEXT, description TEXT, version INT);
    CREATE TABLE itemTypesCombined (itemTypeID INTEGER PRIMARY KEY, typeName TEXT);
    CREATE TABLE items (itemID INTEGER PRIMARY KEY, itemTypeID INT, dateAdded TIMESTAMP, dateModified TIMESTAMP, clientDateModified TIMESTAMP, libraryID INT, key TEXT, version INT, synced INT);
    CREATE TABLE itemAttachments (itemID INTEGER PRIMARY KEY, parentItemID INT, linkMode INT, contentType TEXT, charsetID INT, path TEXT, syncState INT, storageModTime INT, storageHash TEXT, lastProcessedModificationTime INT, lastRead INT);
    CREATE TABLE deletedItems (itemID INT);
    CREATE TABLE fields (fieldID INTEGER PRIMARY KEY, fieldName TEXT);
    CREATE TABLE itemData (itemID INT, fieldID INT, valueID INT);
    CREATE TABLE itemDataValues (valueID INTEGER PRIMARY KEY, value TEXT);
    CREATE TABLE creators (creatorID INTEGER PRIMARY KEY, firstName TEXT, lastName TEXT, fieldMode INT);
    CREATE TABLE itemCreators (itemID INT, creatorID INT, creatorTypeID INT, orderIndex INT);
    CREATE TABLE fulltextItems (itemID INTEGER PRIMARY KEY, indexedPages INT, totalPages INT, indexedChars INT, totalChars INT, version INT, synced INT);
    """
}

private extension String {
    func repeated(_ count: Int) -> String {
        Array(repeating: self, count: count).joined()
    }
}

private actor CapturingLLMEngine: LLMEngine {
    private let response: String
    private var optionsLog: [GenerationOptions] = []

    init(response: String) {
        self.response = response
    }

    func currentModelID() async -> UUID? {
        nil
    }

    func currentContextSize() async -> Int {
        4096
    }

    func generate(
        system: String,
        prompt: String,
        options: GenerationOptions,
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws -> String {
        optionsLog.append(options)
        onEvent(.generationStats(
            promptTokens: TokenEstimator.estimate(text: system + prompt),
            generatedTokens: TokenEstimator.estimate(text: response),
            stopReason: "json-complete",
            templateMode: .unavailable
        ))
        return response
    }

    func capturedOptions() -> [GenerationOptions] {
        optionsLog
    }
}

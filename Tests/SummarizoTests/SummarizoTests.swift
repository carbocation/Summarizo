import XCTest
import SwiftData
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

    func testPrimarySelectorUsesCacheHeadingForArticleLikeSupplementFilename() throws {
        let root = try temporaryDirectory()
        let supplementCache = root.appending(path: "supplement-cache")
        let articleCache = root.appending(path: "article-cache")
        try """
        Supplementary Table 1 - Characteristics of coronary artery disease cases and controls in
        UK Biobank
        """.write(to: supplementCache, atomically: true, encoding: .utf8)
        try """
        letters
        Genetic analysis in UK Biobank links insulin resistance and transendothelial migration pathways to coronary artery disease
        The characteristics of UK Biobank participants are presented in Supplementary Table 1.
        """.write(to: articleCache, atomically: true, encoding: .utf8)

        let title = "Genetic analysis in UK Biobank links insulin resistance and transendothelial migration pathways to coronary artery disease"
        let supplement = candidate(
            attachmentKey: "SUPP",
            attachmentTitle: "Klarin et al. - 2017 - Genetic analysis in UK Biobank links insulin resistance and transendothelial migration pathways to coronary artery disease",
            filename: "Klarin et al. - 2017 - Genetic analysis in UK Biobank links insulin resistance and transendothelial migration pathways to coronary arter.pdf",
            readable: true,
            title: title,
            cacheURL: supplementCache,
            fileSize: 478_673
        )
        let article = candidate(
            attachmentKey: "FULLTEXT",
            attachmentTitle: "Klarin et al. - 2017 - Genetic analysis in UK Biobank links insulin resistance and transendothelial migration pathways to coronary artery disease",
            filename: "Klarin et al. - 2017 - Genetic analysis in UK Biobank links insulin resistance and transendothelial migration pathways to coronary ar(2).pdf",
            readable: true,
            title: title,
            cacheURL: articleCache,
            fileSize: 1_535_995
        )

        let scoredSupplement = PrimaryPDFSelector.score(supplement)
        let scoredArticle = PrimaryPDFSelector.score(article)
        let selection = PrimaryPDFSelector.selectPrimaryPDFs(from: [supplement, article])

        XCTAssertLessThanOrEqual(scoredArticle.score - scoredSupplement.score, 20)
        XCTAssertEqual(selection.first?.candidate?.attachmentKey, "FULLTEXT")
        XCTAssertEqual(selection.first?.status, .queued)
        XCTAssertTrue(selection.first?.reason.contains("not supplemental-looking") == true)
        XCTAssertFalse(selection.first?.reason.contains("supplement/protocol-like metadata or text") == true)
    }

    func testPrimarySelectorDoesNotReadCacheWhenMetadataWinnerIsClear() throws {
        let root = try temporaryDirectory()
        let misleadingCache = root.appending(path: "misleading-cache")
        try """
        Supplementary Table 1 - This cache would demote the clear metadata winner if read
        """.write(to: misleadingCache, atomically: true, encoding: .utf8)

        let fullText = candidate(
            attachmentKey: "FULLTEXT",
            attachmentTitle: "Full Text PDF",
            filename: "Smith et al - 2024 - Deep Learning Study.pdf",
            readable: true,
            cacheURL: misleadingCache
        )
        let other = candidate(
            attachmentKey: "OTHER",
            attachmentTitle: "PDF",
            filename: "Unrelated.pdf",
            readable: true
        )

        let fullTextScore = PrimaryPDFSelector.score(fullText)
        let otherScore = PrimaryPDFSelector.score(other)
        let selection = PrimaryPDFSelector.selectPrimaryPDFs(from: [fullText, other])

        XCTAssertGreaterThan(fullTextScore.score - otherScore.score, 20)
        XCTAssertEqual(selection.first?.candidate?.attachmentKey, "FULLTEXT")
        XCTAssertEqual(selection.first?.status, .queued)
        XCTAssertTrue(selection.first?.reason.contains("not supplemental-looking") == true)
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
        INSERT INTO items VALUES (1, 22, '2023-11-05 12:34:56', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1, 'PARENT1', 0, 0);
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
        XCTAssertEqual(result.candidates.first?.dateAdded, "2023-11-05 12:34:56")
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
            dateAdded: "2023-11-05 12:34:56",
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
        XCTAssertTrue(tsv.contains("\t2023-11-05 12:34:56\t"))

        let jsonl = try SummaryExporter.jsonlString(rows: [row])
        let lines = jsonl.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let decoded = try JSONDecoder.summarizo.decode(SummaryExportRow.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.dateAdded, "2023-11-05 12:34:56")
        XCTAssertEqual(decoded.journalAbbreviation, "J\tTest")
    }

    func testExportIncludesDiagnosticBackupFields() throws {
        var diagnostic = LLMDiagnostic.empty
        diagnostic.modelID = "model-id"
        diagnostic.modelName = "Model Name"
        diagnostic.contextLength = 8192
        diagnostic.promptTokens = 123
        diagnostic.generatedTokens = 45
        diagnostic.locationStrategy = "selector"
        diagnostic.responsePreview = "Preview"

        let row = backupRow(
            modelID: "model-id",
            modelName: "Model Name",
            promptVersion: "summary-v3",
            textSource: .pdfKit,
            sourceFingerprint: "fingerprint",
            diagnostic: diagnostic
        )

        let jsonl = try SummaryExporter.jsonlString(rows: [row])
        let decodedRows = try SummaryImporter.decodeRows(from: Data(jsonl.utf8))
        XCTAssertEqual(decodedRows.first?.modelID, "model-id")
        XCTAssertEqual(decodedRows.first?.promptVersion, "summary-v3")
        XCTAssertEqual(decodedRows.first?.sourceFingerprint, "fingerprint")
        XCTAssertEqual(decodedRows.first?.diagnostic?.contextLength, 8192)
        XCTAssertEqual(decodedRows.first?.diagnostic?.promptTokens, 123)

        let tsv = SummaryExporter.tsvString(rows: [row])
        XCTAssertTrue(tsv.contains("contextLength"))
        XCTAssertTrue(tsv.contains("8192"))
        XCTAssertTrue(tsv.contains("fingerprint"))
    }

    func testImporterDecodesLegacyPrettyPrintedJSONObjects() throws {
        let encoder = JSONEncoder.summarizo
        let rowA = backupRow(parentKey: "A", summary: "Summary A")
        let rowB = backupRow(parentKey: "B", summary: "Summary B")
        let legacyObjects = try [rowA, rowB].map { row in
            let data = try encoder.encode(row)
            return String(data: data, encoding: .utf8) ?? "{}"
        }.joined(separator: "\n")

        let decoded = try SummaryImporter.decodeRows(from: Data(legacyObjects.utf8))
        XCTAssertEqual(decoded.map(\.parentKey), ["A", "B"])
        XCTAssertEqual(decoded.map(\.summary), ["Summary A", "Summary B"])

        let jsonArray = try encoder.encode([rowA, rowB])
        let decodedArray = try SummaryImporter.decodeRows(from: jsonArray)
        XCTAssertEqual(decodedArray.map(\.parentKey), ["A", "B"])
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

    func testSummaryRetriesOversizedChunkAsSmallerChunks() async {
        let engine = CapturingLLMEngine(
            responses: [
                #"{"summary":"partial one"}"#,
                #"{"summary":"partial two"}"#,
                #"{"summary":"merged"}"#
            ],
            budgetFailures: 1
        )
        let operations = SummaryLLMOperations(
            engine: engine,
            modelID: "model",
            modelLabel: "Model",
            contextLength: 16_384,
            supportsGrammar: true,
            thinkingPreferences: SummaryLLMThinkingPreferences(summarization: false),
            includeFullPrompts: false
        )

        let result = await operations.extractChunkedSummary(
            from: "Methods and results reported measured outcomes against baseline. ".repeated(300),
            textSource: .pdfKit,
            options: .extractionSafe,
            progress: nil
        )

        let prompts = await engine.capturedPrompts()
        let chunkPrompts = prompts.filter { $0.contains("Excerpt") }
        XCTAssertEqual(result.summary, "merged")
        XCTAssertGreaterThanOrEqual(prompts.count, 4)
        XCTAssertTrue(prompts.last?.contains("Partial summaries") == true)
        XCTAssertGreaterThanOrEqual(chunkPrompts.count, 3)
        XCTAssertGreaterThan(chunkPrompts.first?.count ?? 0, chunkPrompts.dropFirst().first?.count ?? 0)
        XCTAssertTrue(result.diagnostics.first?.error?.contains("Prompt used 16016 tokens") == true)
        XCTAssertNil(result.diagnostics.last?.error)
    }

    @MainActor
    func testLocalLLMLoadPlanUsesCalibratedContextInAutoMode() async throws {
        let suiteName = "SummarizoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = try temporaryDirectory()
        let source = root.appending(path: "model.gguf")
        try Data("fake model".utf8).write(to: source)
        let library = ModelLibrary(root: root.appending(path: "models", directoryHint: .isDirectory))
        let model = try await library.add(
            weightsAt: source,
            displayName: "Calibrated Model",
            filename: "model.gguf",
            sizeBytes: 10,
            source: .imported,
            contextLength: 262_144
        )
        let store = LlamaContextCalibrationStore(
            defaults: defaults,
            recordsKey: "records",
            deviceIDKey: "device"
        )
        let runtime = LocalLLMEngine.contextCalibrationRuntimeFingerprint()
        let key = store.key(for: model, runtime: runtime)
        store.save(LlamaContextCalibrationRecord(
            key: key,
            maximumSupportedContext: 131_072,
            probedTiers: []
        ))

        let maybePlan = await LocalLLMEngine.loadPlan(
            from: model.id.uuidString,
            in: library,
            defaults: defaults,
            refreshingLibrary: false,
            calibrationStore: store
        )
        let plan = try XCTUnwrap(maybePlan)

        XCTAssertEqual(plan.requestedContext, 131_072)
    }

    func testSummaryContextPolicyStartsAutoAtHalfOfInstalledContextButHonorsManual() {
        let plan = LocalLLMLoadPlan(
            selection: .installed(UUID()),
            displayName: "Large Context Model",
            requestedContext: 262_144,
            capabilities: LocalLLMModelCapabilities(
                supportsGrammar: true,
                usesExactTokenCounts: true,
                contextSize: 262_144
            )
        )

        XCTAssertEqual(
            SummaryContextPolicy.requestedContext(for: plan, mode: .auto),
            131_072
        )
        XCTAssertEqual(
            SummaryContextPolicy.requestedContext(for: plan, mode: .manual),
            262_144
        )
        XCTAssertEqual(
            SummaryContextPolicy.requestedContext(for: plan, mode: .manual, override: 32_768),
            32_768
        )
        XCTAssertEqual(SummaryContextPolicy.fallbackContext(below: 65_536), 32_768)
        XCTAssertNil(SummaryContextPolicy.fallbackContext(below: 16_384))
        XCTAssertEqual(SummaryContextPolicy.automaticStartingContext(for: 8_192), 8_192)
        XCTAssertTrue(SummaryContextPolicy.isDecodeResourceFailure("llama_decode failed."))
    }

    func testSummaryPromptsUseDomainNeutralEvidenceRules() async {
        let engine = CapturingLLMEngine(responses: [
            #"{"summary":"partial"}"#,
            #"{"summary":"merged"}"#
        ])
        let operations = summaryOperations(engine: engine)
        let source = """
        We measured samples against baseline systems and reported observed values.

        """.repeated(500)

        let result = await operations.extractChunkedSummary(
            from: source,
            textSource: .pdfKit,
            options: .extractionSafe,
            progress: nil
        )

        let prompts = await engine.capturedPrompts()
        let systems = await engine.capturedSystems()
        let chunkPrompt = prompts.first ?? ""
        let mergePrompt = prompts.last ?? ""
        let joinedPrompts = prompts.joined(separator: "\n")

        XCTAssertEqual(SummaryLLMOperations.promptVersion, "summary-v4")
        XCTAssertEqual(result.summary, "merged")
        XCTAssertTrue(systems.first?.contains("what was done and what was observed") == true)
        XCTAssertTrue(systems.first?.contains("Prioritize named observed findings") == true)
        XCTAssertTrue(systems.first?.contains("convert claims into measured observations") == true)
        XCTAssertTrue(chunkPrompt.contains("Sentence plan:"))
        XCTAssertTrue(chunkPrompt.contains("Sentence 1: study setup only if needed."))
        XCTAssertTrue(chunkPrompt.contains("Sentences 2-4: named observed findings."))
        XCTAssertTrue(chunkPrompt.contains("what was studied, built, or tested"))
        XCTAssertTrue(chunkPrompt.contains("materials, data, cases, system, organism, model, or setup"))
        XCTAssertTrue(chunkPrompt.contains("the most important observed findings, not just the study design"))
        XCTAssertTrue(chunkPrompt.contains("2-4 distinct findings if the excerpt reports several outcomes; do not collapse them into one broad category"))
        XCTAssertTrue(chunkPrompt.contains("specific variable, condition, material, marker, system, method, or model and the outcome it was linked to"))
        XCTAssertTrue(chunkPrompt.contains("directions, effect sizes, P values, odds ratios, confidence intervals, variance explained, accuracy, AUC"))
        XCTAssertTrue(chunkPrompt.contains("Do not stop after the methods, cohort, or setup description when results are present."))
        XCTAssertTrue(chunkPrompt.contains("Spend most of the summary on observed findings; keep setup brief."))
        XCTAssertTrue(chunkPrompt.contains(#"Do not use vague result phrases like "associations were observed""#))
        XCTAssertTrue(chunkPrompt.contains("Do not generalize findings beyond the reported group, condition, treatment, cohort, or outcome."))
        XCTAssertTrue(chunkPrompt.contains("If a central result comes from a score, equation, model, classifier, simulation, benchmark, or other derived measure, include that fact, name the measure"))
        XCTAssertTrue(chunkPrompt.contains("If changing an input definition or coding choice changes the result, state that the result depends on that operational definition."))
        XCTAssertTrue(chunkPrompt.contains("Replication, validation, and limitations are not substitutes for primary findings"))
        XCTAssertTrue(chunkPrompt.contains("State null, failed, mixed, or non-replicated results directly."))
        XCTAssertTrue(chunkPrompt.contains("If the paper offers a possible reason for a null or failed result, attribute it as a note from the paper rather than making it the cause."))
        XCTAssertTrue(chunkPrompt.contains("concrete basis for the result: material, sample, dataset, system, experiment, measurement, comparator, or evaluation method"))
        XCTAssertTrue(chunkPrompt.contains(#"When reporting "higher", "lower", "increased", "decreased", "near the null", or "different", state the comparison anchor exactly."#))
        XCTAssertTrue(chunkPrompt.contains("Do not change the anchor. Distinguish group comparisons from comparisons between methods, codings, timepoints, or models."))
        XCTAssertTrue(chunkPrompt.contains("If a paper reports multiple metric types for the same result, keep them separate; do not transfer a description from one metric type to another."))
        XCTAssertTrue(chunkPrompt.contains(#"When using phrases like "near the null", "matched", "higher", or "lower", include both the metric type and comparison anchor."#))
        XCTAssertTrue(chunkPrompt.contains("If the evidence is limited, keep the conclusion narrow."))
        XCTAssertTrue(chunkPrompt.contains("When choosing one limitation, prefer the limitation that most changes interpretation of the central result."))
        XCTAssertTrue(chunkPrompt.contains("Prioritize limitations about derived outcomes, validation/calibration, missing direct outcomes, measurement, or causal interpretation over routine exclusions or sample-size details."))
        XCTAssertTrue(mergePrompt.contains("Preserve concrete details about the material, sample, dataset, system, experiment, measurement, comparator, or evaluation method"))
        XCTAssertTrue(mergePrompt.contains("Preserve 2-4 distinct observed findings when the partial summaries report several outcomes; do not collapse them into a single broad category."))
        XCTAssertTrue(mergePrompt.contains("For each key finding, name the specific variable, condition, material, marker, system, method, or model and the outcome it was linked to."))
        XCTAssertTrue(mergePrompt.contains("Do not generalize findings beyond the reported group, condition, treatment, cohort, or outcome."))
        XCTAssertTrue(mergePrompt.contains("If a central result comes from a score, equation, model, classifier, simulation, benchmark, or other derived measure, include that fact, name the measure"))
        XCTAssertTrue(mergePrompt.contains("If changing an input definition or coding choice changes the result, state that the result depends on that operational definition."))
        XCTAssertTrue(mergePrompt.contains("State null, failed, mixed, or non-replicated results directly."))
        XCTAssertTrue(mergePrompt.contains(#"When reporting "higher", "lower", "increased", "decreased", "near the null", or "different", state the comparison anchor exactly."#))
        XCTAssertTrue(mergePrompt.contains("Do not change the anchor. Distinguish group comparisons from comparisons between methods, codings, timepoints, or models."))
        XCTAssertTrue(mergePrompt.contains("If a paper reports multiple metric types for the same result, keep them separate; do not transfer a description from one metric type to another."))
        XCTAssertTrue(mergePrompt.contains(#"When using phrases like "near the null", "matched", "higher", or "lower", include both the metric type and comparison anchor."#))
        XCTAssertTrue(mergePrompt.contains("When choosing one limitation, prefer the limitation that most changes interpretation of the central result."))
        XCTAssertTrue(mergePrompt.contains("Prioritize limitations about derived outcomes, validation/calibration, missing direct outcomes, measurement, or causal interpretation over routine exclusions or sample-size details."))
        XCTAssertTrue(mergePrompt.contains("Include a limitation only after the central findings, and skip it if space is tight."))
        XCTAssertFalse(joinedPrompts.localizedCaseInsensitiveContains("physician"))
        XCTAssertFalse(joinedPrompts.localizedCaseInsensitiveContains("triage"))
        XCTAssertFalse(joinedPrompts.localizedCaseInsensitiveContains("chatgpt"))
    }

    func testExpandedHeadingSelectionAvoidsSpanSelectorCall() async {
        let engine = CapturingLLMEngine(response: #"{"start_id":1,"end_id":1,"confidence":"high"}"#)
        let operations = summaryOperations(engine: engine)
        let text = """
        Abstract
        This overview introduces the work.

        Introduction
        \("The introduction frames motivation and prior claims. ".repeated(30))

        Patients and Methods
        We enrolled participants, collected measurements, and fit prespecified models.

        Results
        The primary analysis compared model outputs with clinical measurements.

        Discussion
        The paper closes by describing implications and limitations.
        """

        let result = await operations.findMethodsResultsSlice(
            in: text,
            options: .extractionSafe,
            progress: nil
        )

        let options = await engine.capturedOptions()
        XCTAssertEqual(options.count, 0)
        XCTAssertEqual(result.strategy, .headingAnchored)
        XCTAssertNotNil(result.startPercent)
        XCTAssertEqual(result.selectedStartParagraphID, 2)
        XCTAssertEqual(result.selectedEndParagraphID, 3)
        XCTAssertEqual(result.lengthChars, result.slice?.count)
        XCTAssertTrue(result.slice?.contains("Patients and Methods") == true)
        XCTAssertTrue(result.slice?.contains("Results") == true)
        XCTAssertFalse(result.slice?.contains("Discussion") == true)
    }

    func testStructuredAbstractHeadingsAreNotUsedAsMainBodyStart() async {
        let engine = CapturingLLMEngine(response: #"{"start_id":1,"end_id":1,"confidence":"high"}"#)
        let operations = summaryOperations(engine: engine)
        let text = """
        Abstract
        \("The abstract frames the question and study context. ".repeated(18))

        Methods
        The abstract briefly says that samples were analyzed.

        Results
        The abstract briefly reports that associations were found.

        Conclusions
        The abstract says the result may be useful.

        \("Additional front matter and keywords separate the abstract from the body. ".repeated(22))

        Methods
        The main body protocol enrolled participants, measured biomarkers, and fit prespecified models.

        Results
        The main body reports validation metrics and subgroup measurements.

        Discussion
        The paper closes by describing implications and limitations.
        """

        let result = await operations.findMethodsResultsSlice(
            in: text,
            options: .extractionSafe,
            progress: nil
        )

        let options = await engine.capturedOptions()
        XCTAssertEqual(options.count, 0)
        XCTAssertEqual(result.strategy, .headingAnchored)
        XCTAssertNotNil(result.startPercent)
        XCTAssertEqual(result.selectedStartParagraphID, 2)
        XCTAssertEqual(result.selectedEndParagraphID, 3)
        XCTAssertEqual(result.lengthChars, result.slice?.count)
        XCTAssertTrue(result.slice?.contains("main body protocol") == true)
        XCTAssertTrue(result.slice?.contains("validation metrics") == true)
        XCTAssertFalse(result.slice?.contains("abstract briefly") == true)
        XCTAssertFalse(result.slice?.contains("The abstract says") == true)
    }

    func testSpanSelectorUsesOneCallForUnheadedBody() async {
        let engine = CapturingLLMEngine(response: #"{"start_id":2,"end_id":3,"confidence":"high"}"#)
        let operations = summaryOperations(engine: engine)
        let text = """
        Introduction
        \("The introduction discusses motivation and related claims. ".repeated(12))

        We ran an assay protocol on held-out samples and recorded prespecified measurements.

        The measured outcomes were compared against baseline systems and manual review.
        """

        let result = await operations.findMethodsResultsSlice(
            in: text,
            options: .extractionSafe,
            progress: nil
        )

        let options = await engine.capturedOptions()
        let prompts = await engine.capturedPrompts()
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(result.strategy, .spanSelectorDetailed)
        XCTAssertEqual(result.selectorCallCount, 1)
        XCTAssertTrue(result.slice?.contains("assay protocol") == true)
        XCTAssertTrue(result.slice?.contains("measured outcomes") == true)
        XCTAssertFalse(prompts.first?.contains("Classify which part") == true)
    }

    func testSpanSelectorDetailedDoesNotSeeStructuredAbstractHeadings() async {
        let engine = CapturingLLMEngine(response: #"{"start_id":2,"end_id":3,"confidence":"high"}"#)
        let operations = summaryOperations(engine: engine)
        let text = """
        Abstract
        \("The abstract frames the question and study context. ".repeated(18))

        Methods
        The abstract briefly says that samples were analyzed.

        Results
        The abstract briefly reports that associations were found.

        Conclusions
        The abstract says the result may be useful.

        \("Additional front matter and keywords separate the abstract from the body. ".repeated(24))

        We enrolled participants, measured biomarkers, and fit prespecified models.

        The validation analysis reports metrics and subgroup measurements.
        """

        let result = await operations.findMethodsResultsSlice(
            in: text,
            options: .extractionSafe,
            progress: nil
        )

        let options = await engine.capturedOptions()
        let prompt = await engine.capturedPrompts().first ?? ""
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(result.strategy, .spanSelectorDetailed)
        XCTAssertFalse(prompt.contains("abstract briefly"))
        XCTAssertFalse(prompt.contains("The abstract says"))
        XCTAssertTrue(result.slice?.contains("measured biomarkers") == true)
        XCTAssertTrue(result.slice?.contains("validation analysis") == true)
        XCTAssertFalse(result.slice?.contains("abstract briefly") == true)
    }

    func testInvalidSpanSelectionFallsBackDeterministically() async {
        let engine = CapturingLLMEngine(response: #"{"start_id":99,"end_id":100,"confidence":"high"}"#)
        let operations = summaryOperations(engine: engine)
        let text = """
        Introduction
        \("The introduction discusses motivation and related claims. ".repeated(12))

        We ran a validation protocol and collected outcomes.

        The results compared observed and predicted values.
        """

        let result = await operations.findMethodsResultsSlice(
            in: text,
            options: .extractionSafe,
            progress: nil
        )

        let options = await engine.capturedOptions()
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(result.strategy, .heuristicFallback)
        XCTAssertEqual(result.selectorCallCount, 1)
        XCTAssertEqual(result.fallbackReason, "invalid-detailed-span-selection")
        XCTAssertNotNil(result.slice?.nilIfBlank)
    }

    func testLongUnheadedBodyUsesCoarseThenDetailedSelection() async {
        let engine = CapturingLLMEngine(responses: [
            #"{"start_id":2,"end_id":17,"confidence":"high"}"#,
            #"{"start_id":5,"end_id":6,"confidence":"high"}"#
        ])
        let operations = summaryOperations(engine: engine, contextLength: 4096)
        let body = (1...80).map { index in
            if index == 4 {
                return "We implemented the protocol and ran the evaluation on a held-out cohort \(index)."
            }
            if index == 5 {
                return "The results paragraph reports measured outcomes and comparison baselines \(index)."
            }
            return "Background or neighboring content paragraph \(index) with enough words to consume prompt budget."
        }.joined(separator: "\n\n")
        let text = """
        Introduction
        \("The introduction discusses motivation and related claims. ".repeated(12))

        \(body)
        """

        let result = await operations.findMethodsResultsSlice(
            in: text,
            options: .extractionSafe,
            progress: nil
        )

        let options = await engine.capturedOptions()
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(result.strategy, .spanSelectorDetailed)
        XCTAssertEqual(result.selectorCallCount, 2)
        XCTAssertTrue(result.slice?.contains("implemented the protocol") == true)
        XCTAssertTrue(result.slice?.contains("measured outcomes") == true)
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
            dateAdded: "2023-02-01 00:00:00",
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
            dateAdded: "2023-01-01 00:00:00",
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
            dateAdded: "2023-03-01 00:00:00",
            journalAbbreviation: "Gamma Journal",
            libraryName: "Gamma Library",
            textSource: .zoteroCache,
            updatedAt: middleDate
        )
        let papers = [zebra, alpha, middle]

        XCTAssertEqual(sortedRowIDs(papers, by: .title), [alpha.id, middle.id, zebra.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .creators), [alpha.id, middle.id, zebra.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .year), [middle.id, alpha.id, zebra.id])
        XCTAssertEqual(sortedRowIDs(papers, by: .dateAdded), [alpha.id, zebra.id, middle.id])
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

    func testPaperTableSortPreferenceRestoresDateAddedDescending() {
        let preference = PaperTableSortPreference(
            columnRawValue: "dateAdded",
            isAscending: false
        )

        XCTAssertEqual(
            preference.sortOrder,
            [PaperRowSortComparator(.dateAdded, order: .reverse)]
        )
    }

    func testPaperTableSortPreferenceStoresSortChanges() {
        let preference = PaperTableSortPreference(
            sortOrder: [PaperRowSortComparator(.updated, order: .forward)]
        )

        XCTAssertEqual(preference.columnRawValue, "updated")
        XCTAssertEqual(preference.isAscending, true)
    }

    func testPaperTableSortPreferenceFallsBackForUnknownColumn() {
        let preference = PaperTableSortPreference(
            columnRawValue: "unknown",
            isAscending: false
        )

        XCTAssertEqual(preference.columnRawValue, "title")
        XCTAssertEqual(preference.isAscending, true)
        XCTAssertEqual(preference.sortOrder, [PaperRowSortComparator(.title)])
    }

    @MainActor
    func testImporterRestoresExistingPaperAndSkipsMissingBackupRows() throws {
        let container = try makeInMemoryModelContainer()
        let modelContext = ModelContext(container)
        let paper = displayPaper(parentKey: "RESTORE", title: "Restore", status: .ready, summary: "Bad summary")
        paper.modelID = "bad-model"
        paper.modelName = "Bad Model"
        modelContext.insert(paper)
        try modelContext.save()

        var diagnostic = LLMDiagnostic.empty
        diagnostic.modelID = "good-model"
        diagnostic.modelName = "Good Model"
        diagnostic.promptVersion = "summary-v3"
        diagnostic.textSource = .zoteroCache
        diagnostic.contextLength = 16_384
        diagnostic.promptTokens = 321
        let restoredDate = "2025-01-02T03:04:05Z"
        let existingRow = backupRow(
            parentKey: "RESTORE",
            summary: "Restored summary",
            modelID: "good-model",
            modelName: "Good Model",
            promptVersion: "summary-v3",
            textSource: .zoteroCache,
            summarizedAt: restoredDate,
            sourceFingerprint: paper.sourceFingerprint,
            diagnostic: diagnostic
        )
        let missingRow = backupRow(parentKey: "MISSING", summary: "Missing summary")

        let result = try SummaryImporter.importRows([existingRow, missingRow], into: modelContext)

        XCTAssertEqual(result.rowsRead, 2)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skippedMissing, 1)
        XCTAssertEqual(paper.summary, "Restored summary")
        XCTAssertEqual(paper.status, .ready)
        XCTAssertEqual(paper.modelID, "good-model")
        XCTAssertEqual(paper.modelName, "Good Model")
        XCTAssertEqual(paper.promptVersion, "summary-v3")
        XCTAssertEqual(paper.textSource, .zoteroCache)
        XCTAssertEqual(paper.diagnostic.contextLength, 16_384)
        XCTAssertEqual(paper.diagnostic.promptTokens, 321)
        XCTAssertEqual(paper.summarizedAt, ISO8601DateFormatter().date(from: restoredDate))
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<SummarizedPaper>()).count, 1)
    }

    @MainActor
    func testImporterMarksRestoredSummaryStaleWhenFingerprintDiffers() throws {
        let container = try makeInMemoryModelContainer()
        let modelContext = ModelContext(container)
        let paper = displayPaper(parentKey: "STALE", title: "Stale", status: .failed, summary: "Bad summary")
        modelContext.insert(paper)
        try modelContext.save()

        let row = backupRow(
            parentKey: "STALE",
            summary: "Restored summary",
            sourceFingerprint: "different-fingerprint"
        )

        let result = try SummaryImporter.importRows([row], into: modelContext)

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.importedAsStale, 1)
        XCTAssertEqual(paper.summary, "Restored summary")
        XCTAssertEqual(paper.status, .stale)
    }

    @MainActor
    func testRetryStartsSummariesWhenIdleAndModelConfigured() async throws {
        let suiteName = "SummarizoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("system.apple-intelligence", forKey: "llama.selectedModelID")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = try makeInMemoryModelContainer()
        let modelContext = ModelContext(container)
        let paper = displayPaper(parentKey: "RETRY-IDLE", title: "Retry", status: .failed)
        modelContext.insert(paper)
        try modelContext.save()

        let didStart = expectation(description: "summary executor started")
        let controller = LibraryController(defaults: defaults) { _ in
            didStart.fulfill()
        }

        controller.retry([paper], modelContext: modelContext)

        await fulfillment(of: [didStart], timeout: 1.0)
        XCTAssertEqual(paper.status, .queued)
    }

    @MainActor
    func testRetryWithoutConfiguredModelLeavesPaperQueued() throws {
        let suiteName = "SummarizoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = try makeInMemoryModelContainer()
        let modelContext = ModelContext(container)
        let paper = displayPaper(parentKey: "RETRY-NO-MODEL", title: "Retry", status: .failed)
        modelContext.insert(paper)
        try modelContext.save()

        var didStart = false
        let controller = LibraryController(defaults: defaults) { _ in
            didStart = true
        }

        controller.retry([paper], modelContext: modelContext)

        XCTAssertEqual(paper.status, .queued)
        XCTAssertFalse(didStart)
        XCTAssertFalse(controller.isSummarizing)
        XCTAssertEqual(controller.alertMessage, SummaryJobError.modelNotConfigured.localizedDescription)
        XCTAssertTrue(
            controller.recentStatusLines.contains(SummaryJobError.modelNotConfigured.localizedDescription)
        )
    }

    @MainActor
    func testRetryWhileScanningQueuesWithoutStartingSummaries() throws {
        let suiteName = "SummarizoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("system.apple-intelligence", forKey: "llama.selectedModelID")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = try makeInMemoryModelContainer()
        let modelContext = ModelContext(container)
        let paper = displayPaper(parentKey: "RETRY-SCANNING", title: "Retry", status: .failed)
        modelContext.insert(paper)
        try modelContext.save()

        var didStart = false
        let controller = LibraryController(defaults: defaults) { _ in
            didStart = true
        }
        controller.isScanning = true

        controller.retry([paper], modelContext: modelContext)

        XCTAssertEqual(paper.status, .queued)
        XCTAssertFalse(didStart)
        XCTAssertFalse(controller.isSummarizing)
    }

    @MainActor
    func testRetryWhileSummarizingQueuesWithoutStartingAnotherRun() throws {
        let suiteName = "SummarizoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("system.apple-intelligence", forKey: "llama.selectedModelID")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = try makeInMemoryModelContainer()
        let modelContext = ModelContext(container)
        let paper = displayPaper(parentKey: "RETRY-SUMMARIZING", title: "Retry", status: .failed)
        modelContext.insert(paper)
        try modelContext.save()

        var didStart = false
        let controller = LibraryController(defaults: defaults) { _ in
            didStart = true
        }
        controller.isSummarizing = true

        controller.retry([paper], modelContext: modelContext)

        XCTAssertEqual(paper.status, .queued)
        XCTAssertFalse(didStart)
        XCTAssertTrue(controller.isSummarizing)
    }

    func testMetadataBackfillDoesNotMarkReadyPaperStale() {
        let paper = displayPaper(parentKey: "BACKFILL", title: "Backfill", status: .ready)
        paper.summary = "Existing summary"
        paper.summarizedAt = Date(timeIntervalSince1970: 1_000)
        let originalFingerprint = paper.sourceFingerprint
        let originalSummarizedAt = paper.summarizedAt

        var candidate = paper.makeCandidate()
        candidate.journalAbbreviation = "J Backfill"
        candidate.dateAdded = "2023-11-05 12:34:56"
        paper.apply(candidate: candidate, status: .queued, reason: "refresh")

        XCTAssertEqual(paper.journalAbbreviation, "J Backfill")
        XCTAssertEqual(paper.dateAdded, "2023-11-05 12:34:56")
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
        dateAdded: String? = nil,
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
            dateAdded: dateAdded,
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

    private func backupRow(
        parentKey: String = "PARENT",
        summary: String = "Backup summary",
        status: SummaryStatus = .ready,
        modelID: String = "",
        modelName: String = "",
        promptVersion: String = "",
        textSource: DocumentTextSource? = nil,
        summarizedAt: String = "",
        sourceFingerprint: String = "",
        diagnostic: LLMDiagnostic? = nil
    ) -> SummaryExportRow {
        SummaryExportRow(
            library: "My Library",
            libraryID: 1,
            parentKey: parentKey,
            attachmentKey: "ATTACH-\(parentKey)",
            itemType: "journalArticle",
            title: "Title \(parentKey)",
            creators: "Jane Smith",
            date: "2024",
            dateAdded: "2023-11-05 12:34:56",
            journalAbbreviation: "J Test",
            doi: "10.1234/test",
            url: "https://example.com/\(parentKey)",
            pdfPath: "/tmp/\(parentKey).pdf",
            status: status.rawValue,
            summary: summary,
            model: modelName,
            modelID: modelID,
            modelName: modelName,
            promptVersion: promptVersion,
            textSource: textSource?.rawValue ?? "",
            summarizedAt: summarizedAt,
            error: "",
            sourceFingerprint: sourceFingerprint,
            storageHash: "hash-\(parentKey)",
            storageModTime: 123,
            fileSize: 456,
            fulltextIndexedPages: 10,
            fulltextTotalPages: 10,
            fulltextIndexedChars: 20_000,
            fulltextTotalChars: 20_000,
            primarySelectionScore: 42,
            primarySelectionReason: "test",
            diagnostic: diagnostic
        )
    }

    private func summaryOperations(
        engine: CapturingLLMEngine,
        contextLength: Int = 4096
    ) -> SummaryLLMOperations {
        SummaryLLMOperations(
            engine: engine,
            modelID: "model",
            modelLabel: "Model",
            contextLength: contextLength,
            supportsGrammar: true,
            thinkingPreferences: SummaryLLMThinkingPreferences(summarization: false),
            includeFullPrompts: false
        )
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

    private func makeInMemoryModelContainer() throws -> ModelContainer {
        let schema = Schema([SummarizedPaper.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func candidate(
        attachmentKey: String,
        attachmentTitle: String,
        filename: String,
        readable: Bool,
        title: String = "Deep Learning Study",
        cacheURL: URL? = nil,
        fileSize: Int64? = 1_000_000
    ) -> ZoteroPDFCandidate {
        ZoteroPDFCandidate(
            libraryID: 1,
            libraryName: "My Library",
            parentItemID: 1,
            parentKey: "PARENT",
            parentItemType: "journalArticle",
            title: title,
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
            cacheURL: cacheURL,
            isReadable: readable,
            storageModTime: 1,
            storageHash: nil,
            fileSize: fileSize,
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
    private let responses: [String]
    private var remainingBudgetFailures: Int
    private var optionsLog: [GenerationOptions] = []
    private var promptLog: [String] = []
    private var systemLog: [String] = []
    private var responseIndex = 0

    init(response: String, budgetFailures: Int = 0) {
        self.responses = [response]
        self.remainingBudgetFailures = budgetFailures
    }

    init(responses: [String], budgetFailures: Int = 0) {
        self.responses = responses
        self.remainingBudgetFailures = budgetFailures
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
        promptLog.append(prompt)
        systemLog.append(system)
        if remainingBudgetFailures > 0 {
            remainingBudgetFailures -= 1
            throw LLMEngineError.insufficientGenerationBudget(
                contextSize: 16_384,
                promptTokens: 16_016,
                reserve: LLMGenerationBudget.outputTokenReserve
            )
        }
        let response = responses.isEmpty ? "{}" : responses[min(responseIndex, responses.count - 1)]
        responseIndex += 1
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

    func capturedPrompts() -> [String] {
        promptLog
    }

    func capturedSystems() -> [String] {
        systemLog
    }
}

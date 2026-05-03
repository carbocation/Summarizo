import AppKit
import Foundation
import SwiftData

@MainActor
final class LibraryController: ObservableObject {
    @Published var isScanning = false
    @Published var isSummarizing = false
    @Published var statusLine: String?
    @Published var recentStatusLines: [String] = []
    @Published var alertMessage: String?
    @Published var dataRevision = 0

    private let runner = SummaryJobRunner()
    private var summaryTask: Task<Void, Never>?

    func scan(modelContext: ModelContext) {
        guard !isScanning else { return }
        isScanning = true
        recentStatusLines = []
        Task {
            defer {
                Task { @MainActor in
                    self.isScanning = false
                    self.statusLine = nil
                }
            }
            do {
                let dataDirectory = try await resolveZoteroDataDirectory()
                try await scan(dataDirectory: dataDirectory, modelContext: modelContext)
            } catch {
                await MainActor.run {
                    alertMessage = error.localizedDescription
                    appendStatus(error.localizedDescription)
                }
            }
        }
    }

    func summarizeQueued(modelContext: ModelContext) {
        guard !isSummarizing else { return }
        isSummarizing = true
        recentStatusLines = []
        summaryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isSummarizing = false
                    self.statusLine = nil
                    self.summaryTask = nil
                }
            }
            await self.performSummaries(modelContext: modelContext)
        }
    }

    func cancelSummaries() {
        summaryTask?.cancel()
        summaryTask = nil
        isSummarizing = false
        statusLine = "Cancelling"
        appendStatus("Cancellation requested.")
    }

    func retry(_ paper: SummarizedPaper, modelContext: ModelContext) {
        retry([paper], modelContext: modelContext)
    }

    func retry(_ papers: [SummarizedPaper], modelContext: ModelContext) {
        guard !papers.isEmpty else { return }
        for paper in papers {
            paper.status = .queued
            paper.errorMessage = nil
            paper.updatedAt = .now
        }
        do {
            try save(modelContext)
            appendStatus("Queued \(papers.count.formatted()) paper(s) for retry.")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func exportAll(_ papers: [SummarizedPaper]) {
        do {
            let urls = try SummaryExporter.export(papers)
            appendStatus("Exported \(urls.count) file(s) to \(AppPaths.exportsDirectory.path).")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func resolveZoteroDataDirectory() async throws -> URL {
        if let stored = SecurityScopedBookmarkStore.shared.resolvedZoteroDirectory() {
            return stored
        }

        let suggested = ZoteroProfileLocator.suggestedDataDirectory()
        if let selected = try SecurityScopedBookmarkStore.shared.chooseZoteroDirectory(suggestedURL: suggested) {
            return selected
        }
        throw ControllerError.zoteroAccessNotGranted
    }

    private func scan(dataDirectory: URL, modelContext: ModelContext) async throws {
        let didAccessData = dataDirectory.startAccessingSecurityScopedResource()
        let linkedRoot = SecurityScopedBookmarkStore.shared.resolvedLinkedAttachmentRoot()
        let didAccessLinked = linkedRoot?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didAccessData { dataDirectory.stopAccessingSecurityScopedResource() }
            if didAccessLinked { linkedRoot?.stopAccessingSecurityScopedResource() }
        }

        statusLine = "Snapshotting Zotero database"
        appendStatus("Reading Zotero data directory: \(dataDirectory.path)")
        let snapshot = try ZoteroDatabaseSnapshotter.snapshotDatabase(in: dataDirectory)
        appendStatus("SQLite snapshot written to \(snapshot.url.path)")
        if let note = snapshot.note {
            appendStatus(note)
        }

        statusLine = "Scanning child PDFs"
        let reader = ZoteroDatabaseReader(dataDirectory: dataDirectory, databaseURL: snapshot.url)
        let result = try reader.scanPrimaryPDFs()
        appendStatus("Found \(result.candidates.count.formatted()) child PDF attachment(s).")

        let existing = try modelContext.fetch(FetchDescriptor<SummarizedPaper>())
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var inserted = 0
        var updated = 0
        for selection in result.selected {
            guard let candidate = selection.candidate else { continue }
            let id = SummarizedPaper.makeID(libraryID: candidate.libraryID, parentKey: candidate.parentKey)
            if let paper = byID[id] {
                paper.apply(candidate: candidate, status: selection.status, reason: selection.reason)
                updated += 1
            } else {
                modelContext.insert(SummarizedPaper(candidate: candidate, status: selection.status, reason: selection.reason))
                inserted += 1
            }
        }

        try save(modelContext)
        appendStatus("Scan complete: \(inserted.formatted()) new, \(updated.formatted()) updated, \(result.selected.count.formatted()) primary candidates.")
    }

    private func performSummaries(modelContext: ModelContext) async {
        let dataDirectory = SecurityScopedBookmarkStore.shared.resolvedZoteroDirectory()
        let didAccessData = dataDirectory?.startAccessingSecurityScopedResource() ?? false
        let linkedRoot = SecurityScopedBookmarkStore.shared.resolvedLinkedAttachmentRoot()
        let didAccessLinked = linkedRoot?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didAccessData { dataDirectory?.stopAccessingSecurityScopedResource() }
            if didAccessLinked { linkedRoot?.stopAccessingSecurityScopedResource() }
        }

        do {
            let papers = try modelContext.fetch(FetchDescriptor<SummarizedPaper>())
                .filter { $0.status == .queued || $0.status == .stale }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

            guard !papers.isEmpty else {
                appendStatus("No queued papers to summarize.")
                return
            }

            appendStatus("Summarizing \(papers.count.formatted()) paper(s).")
            for (index, paper) in papers.enumerated() {
                try Task.checkCancellation()
                statusLine = "Summarizing \(index + 1) of \(papers.count): \(paper.title)"
                appendStatus("Starting \(paper.title)")

                paper.status = .extractingText
                paper.errorMessage = nil
                try save(modelContext)

                let candidate = paper.makeCandidate()
                do {
                    let result = try await runner.summarize(
                        candidate: candidate,
                        allowOCRFallback: UserDefaults.standard.bool(forKey: "summarizo.ocrEnabled"),
                        includeFullPrompts: UserDefaults.standard.bool(forKey: "summarizo.verboseDiagnostics"),
                        progress: { [weak self] line in
                            await self?.appendProgress(line)
                        }
                    )
                    paper.summary = result.summary
                    paper.textSource = result.textSource
                    paper.modelID = result.modelID
                    paper.modelName = result.modelName
                    paper.promptVersion = result.promptVersion
                    paper.diagnostic = result.diagnostic
                    paper.status = .ready
                    paper.errorMessage = nil
                    paper.summarizedAt = .now
                    try save(modelContext)
                    appendStatus("Stored summary for \(paper.title)")
                } catch let error as DocumentTextError {
                    paper.status = (error.errorDescription?.contains("OCR") == true) ? .needsOCR : .failed
                    paper.errorMessage = error.localizedDescription
                    paper.diagnostic = diagnosticForError(error)
                    try save(modelContext)
                    appendStatus(error.localizedDescription)
                } catch {
                    paper.status = .failed
                    paper.errorMessage = error.localizedDescription
                    paper.diagnostic = diagnosticForError(error)
                    try save(modelContext)
                    appendStatus("Failed: \(error.localizedDescription)")
                }
            }
        } catch is CancellationError {
            appendStatus("Summarization cancelled.")
        } catch {
            alertMessage = error.localizedDescription
            appendStatus(error.localizedDescription)
        }
    }

    private func diagnosticForError(_ error: Error) -> LLMDiagnostic {
        var diagnostic = LLMDiagnostic.empty
        diagnostic.error = error.localizedDescription
        diagnostic.finishedAt = .now
        return diagnostic
    }

    private func appendProgress(_ line: String) {
        appendStatus(line)
    }

    private func appendStatus(_ line: String) {
        recentStatusLines.append(line)
        if recentStatusLines.count > 12 {
            recentStatusLines.removeFirst(recentStatusLines.count - 12)
        }
    }

    private func save(_ modelContext: ModelContext) throws {
        try modelContext.save()
        dataRevision += 1
    }
}

enum ControllerError: LocalizedError {
    case zoteroAccessNotGranted

    var errorDescription: String? {
        switch self {
        case .zoteroAccessNotGranted:
            "Zotero data directory access was not granted."
        }
    }
}

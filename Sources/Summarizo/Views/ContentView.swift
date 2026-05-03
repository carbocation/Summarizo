import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \SummarizedPaper.title) private var papers: [SummarizedPaper]

    @StateObject private var controller = LibraryController()
    @State private var filter: SummaryFilter = .all
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SummarizedPaper.title)]
    @State private var searchText = ""

    private var filteredPapers: [SummarizedPaper] {
        papers.filter { paper in
            guard filter.includes(paper.status) else { return false }
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            let haystack = [
                paper.title,
                paper.creators.joined(separator: " "),
                paper.year ?? "",
                paper.libraryName,
                paper.doi ?? "",
                paper.summary
            ].joined(separator: " ").lowercased()
            return haystack.contains(searchText.lowercased())
        }
    }

    private var displayedPapers: [SummarizedPaper] {
        filteredPapers.sorted(using: sortOrder)
    }

    private var selectedPapers: [SummarizedPaper] {
        displayedPapers.filter { selection.contains($0.id) }
    }

    private var selectedPaper: SummarizedPaper? {
        selectedPapers.first ?? displayedPapers.first
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                filter: $filter,
                papers: papers,
                isSummarizing: controller.isSummarizing
            )
        } content: {
            PaperTableView(
                papers: displayedPapers,
                selection: $selection,
                sortOrder: $sortOrder,
                canRetrySelection: !selectedPapers.isEmpty && !controller.isScanning && !controller.isSummarizing,
                onRetrySelection: retrySelected
            )
            .navigationTitle(filter.title)
            .searchable(text: $searchText, placement: .toolbar)
        } detail: {
            PaperDetailView(
                paper: selectedPaper,
                onOpenPDF: openPDF,
                onRetry: retry
            )
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    controller.scan(modelContext: modelContext)
                } label: {
                    Label("Scan Zotero", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(controller.isScanning || controller.isSummarizing)
                .help("Scan the granted Zotero data directory for primary child PDFs.")

                if controller.isSummarizing {
                    Button {
                        controller.cancelSummaries()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .help("Cancel the current summarization run.")
                } else {
                    Button {
                        controller.summarizeQueued(modelContext: modelContext)
                    } label: {
                        Label("Summarize", systemImage: "text.bubble")
                    }
                    .disabled(controller.isScanning)
                    .help("Summarize queued and stale papers.")
                }

                Button {
                    retrySelected()
                } label: {
                    Label(
                        selectedPapers.count <= 1 ? "Retry Selected" : "Retry \(selectedPapers.count) Selected",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(selectedPapers.isEmpty || controller.isScanning || controller.isSummarizing)
                .help("Queue the selected visible papers for retry.")

                Button {
                    controller.exportAll(papers)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(papers.isEmpty)
                .help("Export summaries to TSV and JSONL.")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Summarizo settings.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBarView(controller: controller)
        }
        .alert(
            "Summarizo",
            isPresented: Binding(
                get: { controller.alertMessage != nil },
                set: { if !$0 { controller.alertMessage = nil } }
            )
        ) {
            Button("OK") { controller.alertMessage = nil }
        } message: {
            Text(controller.alertMessage ?? "")
        }
        .onChange(of: filter) { _, _ in
            pruneSelectionToDisplayedPapers()
        }
        .onChange(of: searchText) { _, _ in
            pruneSelectionToDisplayedPapers()
        }
    }

    private func openPDF(_ paper: SummarizedPaper) {
        guard let path = paper.pdfPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func retry(_ paper: SummarizedPaper) {
        controller.retry(paper, modelContext: modelContext)
    }

    private func retrySelected() {
        let papersToRetry = selectedPapers
        controller.retry(papersToRetry, modelContext: modelContext)
        pruneSelectionToDisplayedPapers()
    }

    private func pruneSelectionToDisplayedPapers() {
        let visibleIDs = Set(displayedPapers.map(\.id))
        selection.formIntersection(visibleIDs)
    }
}

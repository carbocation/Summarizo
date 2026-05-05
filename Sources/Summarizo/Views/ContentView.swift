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
    @State private var sortOrder = PaperTableSortPreference.defaultSortOrder
    @State private var searchText = ""
    @State private var displayState = PaperDisplayState.empty
    @State private var zoteroPluginStatus = ZoteroPluginStatus(
        kind: .unknown,
        installedVersion: nil,
        expectedVersion: ZoteroPluginInstaller.pluginVersion,
        detail: "Zotero profile has not been checked yet."
    )
    @State private var zoteroPluginErrorMessage: String?
    @State private var zoteroPluginInstallPreparation: ZoteroPluginInstallPreparation?

    @AppStorage(PaperTableSortPreference.columnKey) private var storedSortColumn = PaperTableSortPreference.defaultColumnRawValue
    @AppStorage(PaperTableSortPreference.ascendingKey) private var storedSortAscending = PaperTableSortPreference.defaultAscending

    var body: some View {
        NavigationSplitView {
            SidebarView(
                filter: $filter,
                counts: displayState.filterCounts,
                isSummarizing: controller.isSummarizing,
                zoteroPluginStatus: zoteroPluginStatus,
                onPrepareZoteroPluginInstall: prepareZoteroPluginInstall
            )
        } content: {
            PaperTableView(
                rows: displayState.rows,
                selection: $selection,
                sortOrder: $sortOrder,
                canRetrySelection: !displayState.selectedPapers.isEmpty
                    && canQueueRetry,
                onRetrySelection: { retry(displayState.selectedPapers) }
            )
            .navigationTitle(filter.title)
            .searchable(text: $searchText, placement: .toolbar)
        } detail: {
            PaperDetailView(
                paper: displayState.selectedPaper,
                canRetry: canRetry,
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
                    retry(displayState.selectedPapers)
                } label: {
                    Label(
                        displayState.selectedPapers.count <= 1
                            ? "Retry Selected"
                            : "Retry \(displayState.selectedPapers.count) Selected",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(displayState.selectedPapers.isEmpty || !canQueueRetry)
                .help("Queue the selected visible papers for retry.")

                Button {
                    controller.exportAll(papers)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(papers.isEmpty)
                .help("Export summaries to TSV and JSONL.")

                Button {
                    controller.importBackup(modelContext: modelContext)
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(controller.isScanning || controller.isSummarizing)
                .help("Import summaries and diagnostics from a JSON or JSONL backup for papers still present in the current library.")

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
        .alert(
            "Zotero Plugin",
            isPresented: Binding(
                get: { zoteroPluginErrorMessage != nil },
                set: { if !$0 { zoteroPluginErrorMessage = nil } }
            )
        ) {
            Button("OK") { zoteroPluginErrorMessage = nil }
        } message: {
            Text(zoteroPluginErrorMessage ?? "")
        }
        .sheet(item: $zoteroPluginInstallPreparation, onDismiss: refreshZoteroPluginStatus) { preparation in
            ZoteroPluginInstallInstructionsView(preparation: preparation)
        }
        .onAppear {
            restoreSortOrder()
            refreshDisplayState()
            refreshZoteroPluginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshZoteroPluginStatus()
        }
        .onChange(of: filter) { _, _ in
            refreshDisplayState(pruningSelection: true)
        }
        .onChange(of: searchText) { _, _ in
            refreshDisplayState(pruningSelection: true)
        }
        .onChange(of: sortOrder) { _, newSortOrder in
            persistSortOrder(newSortOrder)
            displayState = displayState.sorted(using: newSortOrder, selection: selection)
        }
        .onChange(of: selection) { _, newSelection in
            displayState = displayState.selecting(newSelection)
        }
        .onChange(of: papers.count) { _, _ in
            refreshDisplayState(pruningSelection: true)
        }
        .onChange(of: controller.dataRevision) { _, _ in
            refreshDisplayState(pruningSelection: true)
        }
    }

    private func openPDF(_ paper: SummarizedPaper) {
        guard let path = paper.pdfPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func retry(_ paper: SummarizedPaper) {
        controller.retry(paper, modelContext: modelContext)
    }

    private func retry(_ papers: [SummarizedPaper]) {
        controller.retry(papers, modelContext: modelContext)
        refreshDisplayState(pruningSelection: true)
    }

    private var canRetry: Bool {
        canQueueRetry
    }

    private var canQueueRetry: Bool {
        !controller.isScanning
    }

    private func restoreSortOrder() {
        let preference = PaperTableSortPreference(
            columnRawValue: storedSortColumn,
            isAscending: storedSortAscending
        )
        sortOrder = preference.sortOrder
        storedSortColumn = preference.columnRawValue
        storedSortAscending = preference.isAscending
    }

    private func persistSortOrder(_ sortOrder: [PaperRowSortComparator]) {
        let preference = PaperTableSortPreference(sortOrder: sortOrder)
        storedSortColumn = preference.columnRawValue
        storedSortAscending = preference.isAscending
    }

    private func refreshDisplayState(pruningSelection: Bool = false) {
        var nextSelection = selection
        var nextState = PaperDisplayState.make(
            papers: papers,
            filter: filter,
            searchText: searchText,
            selection: nextSelection,
            sortOrder: sortOrder
        )

        if pruningSelection {
            let visibleIDs = Set(nextState.rows.map(\.id))
            nextSelection.formIntersection(visibleIDs)
            if nextSelection != selection {
                selection = nextSelection
                nextState = nextState.selecting(nextSelection)
            }
        }

        displayState = nextState
    }

    private func refreshZoteroPluginStatus() {
        zoteroPluginStatus = ZoteroPluginStatusDetector.detect()
    }

    private func prepareZoteroPluginInstall() {
        do {
            let result = try ZoteroPluginInstaller.prepareInstall()
            zoteroPluginInstallPreparation = result
            refreshZoteroPluginStatus()
        } catch {
            zoteroPluginInstallPreparation = nil
            zoteroPluginErrorMessage = error.localizedDescription
        }
    }
}

import SwiftUI

struct PaperTableView: View {
    let papers: [SummarizedPaper]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<SummarizedPaper>]
    let canRetrySelection: Bool
    let onRetrySelection: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !selection.isEmpty {
                selectionActionBar
                Divider()
            }

            Table(of: SummarizedPaper.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title) { paper in
                    Text(paper.title)
                        .lineLimit(2)
                        .padding(.vertical, 3)
                }

                TableColumn("Creator/Year", value: \.creatorYearSortValue) { paper in
                    Text(subtitle(for: paper))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 170)

                TableColumn("Library", value: \.libraryName) { paper in
                    Text(paper.libraryName)
                        .lineLimit(1)
                }
                .width(min: 90, ideal: 130)

                TableColumn("Status", value: \.statusSortValue) { paper in
                    Label(paper.status.displayName, systemImage: paper.status.systemImage)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 150)

                TableColumn("Text", value: \.textSourceSortValue) { paper in
                    Text(paper.textSource?.displayName ?? "")
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)

                TableColumn("Updated", value: \.summaryAgeSortValue) { paper in
                    Text(relativeDate(paper.summarizedAt ?? paper.updatedAt))
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)
            } rows: {
                ForEach(papers, id: \.id) { paper in
                    TableRow(paper)
                }
            }
            .contextMenu {
                Button {
                    onRetrySelection()
                } label: {
                    Label("Retry Selected", systemImage: "arrow.clockwise")
                }
                .disabled(!canRetrySelection)
            }
            .overlay {
                if papers.isEmpty {
                    ContentUnavailableView(
                        "No Papers",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Scan Zotero to populate the summary queue.")
                    )
                }
            }
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count.formatted()) selected")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onRetrySelection()
            } label: {
                Label("Retry Selected", systemImage: "arrow.clockwise")
            }
            .disabled(!canRetrySelection)
            .help("Queue the selected visible papers for retry.")
            Button {
                selection.removeAll()
            } label: {
                Label("Clear Selection", systemImage: "xmark.circle")
            }
            .help("Clear the current table selection.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func subtitle(for paper: SummarizedPaper) -> String {
        let creators = paper.creators.prefix(3).joined(separator: ", ")
        let year = paper.year ?? ""
        return [creators, year].filter { !$0.isEmpty }.joined(separator: " - ")
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

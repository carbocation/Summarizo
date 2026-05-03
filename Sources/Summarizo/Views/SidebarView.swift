import SwiftUI

struct SidebarView: View {
    @Binding var filter: SummaryFilter
    let papers: [SummarizedPaper]
    let isSummarizing: Bool

    var body: some View {
        List(selection: $filter) {
            Section("Library") {
                ForEach(SummaryFilter.allCases) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(countLabel(for: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(item)
                }
            }

            Section("Model") {
                Label(isSummarizing ? "Running" : "Idle", systemImage: isSummarizing ? "play.circle" : "pause.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Summarizo")
    }

    private func countLabel(for filter: SummaryFilter) -> String {
        let count = papers.filter { filter.includes($0.status) }.count
        return "\(count.formatted()) item\(count == 1 ? "" : "s")"
    }
}

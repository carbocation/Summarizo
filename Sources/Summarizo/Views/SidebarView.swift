import SwiftUI

struct SidebarView: View {
    @Binding var filter: SummaryFilter
    let counts: SummaryFilterCounts
    let isSummarizing: Bool
    let zoteroPluginStatus: ZoteroPluginStatus
    let onPrepareZoteroPluginInstall: () -> Void

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

            Section("Zotero") {
                ZoteroPluginStatusView(
                    status: zoteroPluginStatus,
                    onPrepareInstall: onPrepareZoteroPluginInstall
                )
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Summarizo")
    }

    private func countLabel(for filter: SummaryFilter) -> String {
        let count = counts.count(for: filter)
        return "\(count.formatted()) item\(count == 1 ? "" : "s")"
    }
}

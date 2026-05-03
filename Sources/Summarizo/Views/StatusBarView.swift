import SwiftUI

struct StatusBarView: View {
    @ObservedObject var controller: LibraryController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if controller.isScanning || controller.isSummarizing {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(controller.statusLine ?? lastLine ?? "Ready")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if controller.isScanning || controller.isSummarizing {
                ForEach(controller.recentStatusLines.suffix(3), id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var lastLine: String? {
        controller.recentStatusLines.last
    }
}

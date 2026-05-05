import AppKit
import SwiftUI

struct ZoteroPluginInstallInstructionsView: View {
    let preparation: ZoteroPluginInstallPreparation

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Install Zotero Plugin")
                        .font(.headline)
                    Text("Summarizo opened Finder and selected \(ZoteroPluginInstaller.pluginFileName). Keep this window open while you install it in Zotero.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                instructionRow(1, "Open Zotero.")
                instructionRow(2, "Choose Tools > Plugins.")
                instructionRow(3, "Drag \(ZoteroPluginInstaller.pluginFileName) from Finder into the Plugins window, or use Zotero's install-from-file control if visible.")
                instructionRow(4, "Restart Zotero if prompted.")
                instructionRow(5, "Confirm Tools > Import Summarizo Summaries... appears.")
            }

            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([preparation.pluginURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func instructionRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

import SwiftUI

struct ZoteroPluginStatusView: View {
    let status: ZoteroPluginStatus
    let onPrepareInstall: () -> Void

    var body: some View {
        Group {
            if status.canPrepareInstall {
                Button(action: onPrepareInstall) {
                    content
                }
                .buttonStyle(.plain)
                .help(helpText)
            } else {
                content
                    .help(helpText)
            }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(iconPrimaryColor, iconSecondaryColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if status.canPrepareInstall {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        switch status.kind {
        case .unknown:
            "Plugin status unknown"
        case .notInstalled:
            "Plugin not installed"
        case .installed:
            "Plugin installed"
        case .outdated:
            "Plugin update available"
        case .disabled:
            "Plugin disabled"
        }
    }

    private var systemImage: String {
        switch status.kind {
        case .unknown:
            "questionmark.circle.fill"
        case .notInstalled:
            "puzzlepiece.extension.fill"
        case .installed:
            "checkmark.seal.fill"
        case .outdated:
            "exclamationmark.triangle.fill"
        case .disabled:
            "pause.circle.fill"
        }
    }

    private var iconPrimaryColor: Color {
        switch status.kind {
        case .unknown:
            .secondary
        case .notInstalled:
            .red
        case .installed:
            .green
        case .outdated, .disabled:
            .yellow
        }
    }

    private var iconSecondaryColor: Color {
        switch status.kind {
        case .outdated, .disabled:
            .black.opacity(0.55)
        default:
            .white
        }
    }

    private var helpText: String {
        switch status.kind {
        case .unknown:
            "Copy and reveal the bundled Summarizo Zotero plugin. Summarizo could not check Zotero's plugin registry."
        case .notInstalled:
            "Copy and reveal the bundled Summarizo Zotero plugin for installation."
        case .installed:
            "The Summarizo Zotero plugin is installed."
        case .outdated:
            "Copy and reveal the current bundled Summarizo Zotero plugin."
        case .disabled:
            "Open the bundled plugin so it can be reinstalled or enabled in Zotero."
        }
    }
}

import SwiftUI

struct PaperDetailView: View {
    let paper: SummarizedPaper?
    let onOpenPDF: (SummarizedPaper) -> Void
    let onRetry: (SummarizedPaper) -> Void

    var body: some View {
        Group {
            if let paper {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(paper)
                        summarySection(paper)
                        metadataSection(paper)
                        diagnosticsSection(paper)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Select a Paper",
                    systemImage: "doc.text",
                    description: Text("Choose a Zotero item to inspect its summary, source PDF, and diagnostics.")
                )
            }
        }
    }

    private func header(_ paper: SummarizedPaper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(paper.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                    Text([paper.creators.joined(separator: ", "), paper.year ?? ""].filter { !$0.isEmpty }.joined(separator: " - "))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Label(paper.status.displayName, systemImage: paper.status.systemImage)
                    .font(.callout)
                    .foregroundStyle(statusStyle(paper.status))
            }

            HStack {
                Button {
                    onOpenPDF(paper)
                } label: {
                    Label("Open PDF", systemImage: "doc.richtext")
                }
                .disabled(paper.pdfPath == nil)

                Button {
                    onRetry(paper)
                } label: {
                    Label("Queue Retry", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func summarySection(_ paper: SummarizedPaper) -> some View {
        DetailSection(title: "Summary") {
            if paper.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(paper.errorMessage ?? "No summary stored yet.")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(paper.summary)
                    .textSelection(.enabled)
            }
        }
    }

    private func metadataSection(_ paper: SummarizedPaper) -> some View {
        DetailSection(title: "Zotero Source") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                metadataRow("Library", paper.libraryName)
                metadataRow("Parent key", paper.parentKey)
                metadataRow("Attachment key", paper.attachmentKey)
                metadataRow("Item type", paper.parentItemType)
                metadataRow("Journal", paper.journalAbbreviation ?? "")
                metadataRow("DOI", paper.doi ?? "")
                metadataRow("URL", paper.itemURL ?? "")
                metadataRow("PDF", paper.pdfPath ?? "")
                metadataRow("Primary PDF", paper.primarySelectionReason)
                metadataRow("Fingerprint", paper.sourceFingerprint)
            }
            .textSelection(.enabled)
        }
    }

    private func diagnosticsSection(_ paper: SummarizedPaper) -> some View {
        let diagnostic = paper.diagnostic
        return DetailSection(title: "Diagnostics") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                metadataRow("Model", diagnostic.modelName.isEmpty ? (paper.modelName ?? "") : diagnostic.modelName)
                metadataRow("Prompt", diagnostic.promptVersion)
                metadataRow("Text source", diagnostic.textSource?.displayName ?? paper.textSource?.displayName ?? "")
                metadataRow("Context", diagnostic.contextLength.map { $0.formatted() } ?? "")
                metadataRow("Thinking", diagnostic.enableThinking.map { $0 ? "Enabled" : "Disabled" } ?? "")
                metadataRow("Prompt tokens", diagnostic.promptTokens.map { $0.formatted() } ?? "")
                metadataRow("Generated tokens", diagnostic.generatedTokens.map { $0.formatted() } ?? "")
                metadataRow("Stop reason", diagnostic.stopReason ?? "")
                metadataRow("Error", diagnostic.error ?? paper.errorMessage ?? "")
            }
            if let preview = diagnostic.responsePreview?.nilIfBlank {
                Divider()
                    .padding(.vertical, 4)
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .lineLimit(label == "PDF" || label == "Fingerprint" ? 3 : 2)
        }
    }

    private func statusStyle(_ status: SummaryStatus) -> Color {
        switch status {
        case .ready:
            .green
        case .failed, .needsOCR:
            .orange
        case .ambiguousPrimary, .skippedSupplementalOnly:
            .secondary
        case .cancelled:
            .red
        case .queued, .extractingText, .summarizing, .stale:
            .accentColor
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

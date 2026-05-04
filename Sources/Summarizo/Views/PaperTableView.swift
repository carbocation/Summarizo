import AppKit
import SwiftUI

struct PaperTableView: View {
    let rows: [PaperDisplayRow]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [PaperRowSortComparator]
    let canRetrySelection: Bool
    let onRetrySelection: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            selectionActionBar
            Divider()

            PaperAppKitTableView(
                rows: rows,
                selection: $selection,
                sortOrder: $sortOrder,
                canRetrySelection: canRetrySelection,
                onRetrySelection: onRetrySelection
            )
            .overlay {
                if rows.isEmpty {
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
            Text(selection.isEmpty ? "No selection" : "\(selection.count.formatted()) selected")
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
            .disabled(selection.isEmpty)
            .help("Clear the current table selection.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// SwiftUI Table was spending large-sort time in NSHostingView/KVO teardown.
// This bridge keeps SwiftUI state ownership while using reusable AppKit cells.
private struct PaperAppKitTableView: NSViewRepresentable {
    let rows: [PaperDisplayRow]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [PaperRowSortComparator]
    let canRetrySelection: Bool
    let onRetrySelection: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: $selection,
            sortOrder: $sortOrder,
            onRetrySelection: onRetrySelection
        )
    }

    func makeNSView(context: Context) -> PaperTableContainerView {
        let container = PaperTableContainerView()
        let tableView = container.tableView
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        PaperTableColumn.allCases.forEach { spec in
            let tableColumn = NSTableColumn(identifier: spec.identifier)
            tableColumn.title = spec.title
            tableColumn.width = spec.width
            tableColumn.minWidth = spec.minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.sortKey,
                ascending: true
            )
            tableView.addTableColumn(tableColumn)
        }

        let menu = NSMenu()
        let retryItem = NSMenuItem(
            title: "Retry Selected",
            action: #selector(Coordinator.retrySelected),
            keyEquivalent: ""
        )
        retryItem.target = context.coordinator
        menu.addItem(retryItem)
        tableView.menu = menu

        return container
    }

    func updateNSView(_ container: PaperTableContainerView, context: Context) {
        context.coordinator.update(
            rows: rows,
            selectedIDs: selection,
            sortOrderValue: sortOrder,
            selection: $selection,
            sortOrder: $sortOrder,
            canRetrySelection: canRetrySelection,
            onRetrySelection: onRetrySelection,
            tableView: container.tableView
        )
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        private var rows: [PaperDisplayRow] = []
        private var selection: Binding<Set<String>>
        private var sortOrder: Binding<[PaperRowSortComparator]>
        private var canRetrySelection = false
        private var onRetrySelection: () -> Void
        private var isApplyingSelection = false
        private var isApplyingSortDescriptors = false

        init(
            selection: Binding<Set<String>>,
            sortOrder: Binding<[PaperRowSortComparator]>,
            onRetrySelection: @escaping () -> Void
        ) {
            self.selection = selection
            self.sortOrder = sortOrder
            self.onRetrySelection = onRetrySelection
        }

        func update(
            rows: [PaperDisplayRow],
            selectedIDs: Set<String>,
            sortOrderValue: [PaperRowSortComparator],
            selection: Binding<Set<String>>,
            sortOrder: Binding<[PaperRowSortComparator]>,
            canRetrySelection: Bool,
            onRetrySelection: @escaping () -> Void,
            tableView: NSTableView
        ) {
            self.canRetrySelection = canRetrySelection
            self.onRetrySelection = onRetrySelection
            self.selection = selection
            self.sortOrder = sortOrder

            applySortDescriptors(sortOrderValue, to: tableView)

            if rows != self.rows {
                self.rows = rows
                tableView.reloadData()
            }

            applySelection(selectedIDs, to: tableView)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row rowIndex: Int
        ) -> NSView? {
            guard
                rowIndex < rows.count,
                let tableColumn,
                let spec = PaperTableColumn(identifier: tableColumn.identifier)
            else {
                return nil
            }

            let cell = tableView.makeView(
                withIdentifier: spec.cellIdentifier,
                owner: self
            ) as? PaperTableCellView ?? PaperTableCellView(identifier: spec.cellIdentifier)

            let row = rows[rowIndex]
            switch spec.column {
            case .title:
                cell.configure(text: row.title, maximumLines: 2)
            case .creators:
                cell.configure(text: row.creatorsDisplay, isSecondary: true)
            case .year:
                cell.configure(text: row.yearDisplay, isSecondary: true)
            case .dateAdded:
                cell.configure(text: row.dateAddedDisplay, isSecondary: true)
            case .journal:
                cell.configure(text: row.journalDisplayName, isSecondary: true)
            case .library:
                cell.configure(text: row.libraryName)
            case .status:
                cell.configure(
                    text: row.statusDisplayName,
                    systemImage: row.statusSystemImage
                )
            case .textSource:
                cell.configure(text: row.textSourceDisplayName, isSecondary: true)
            case .updated:
                cell.configure(text: row.updatedText, isSecondary: true)
            }

            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard
                !isApplyingSelection,
                let tableView = notification.object as? NSTableView
            else {
                return
            }

            var selectedIDs = Set<String>()
            tableView.selectedRowIndexes.forEach { rowIndex in
                guard rowIndex < rows.count else { return }
                selectedIDs.insert(rows[rowIndex].id)
            }
            selection.wrappedValue = selectedIDs
        }

        func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard
                !isApplyingSortDescriptors,
                let descriptor = tableView.sortDescriptors.first,
                let key = descriptor.key,
                let column = PaperRowSortComparator.Column(sortKey: key)
            else {
                return
            }

            sortOrder.wrappedValue = [
                PaperRowSortComparator(
                    column,
                    order: descriptor.ascending ? .forward : .reverse
                )
            ]
        }

        @objc func retrySelected() {
            guard canRetrySelection else { return }
            onRetrySelection()
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            menuItem.action == #selector(retrySelected) ? canRetrySelection : true
        }

        private func applySelection(_ selection: Set<String>, to tableView: NSTableView) {
            var rowIndexes = IndexSet()
            for (rowIndex, row) in rows.enumerated() where selection.contains(row.id) {
                rowIndexes.insert(rowIndex)
            }

            guard tableView.selectedRowIndexes != rowIndexes else { return }

            isApplyingSelection = true
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        private func applySortDescriptors(
            _ sortOrder: [PaperRowSortComparator],
            to tableView: NSTableView
        ) {
            guard let comparator = sortOrder.first else {
                guard !tableView.sortDescriptors.isEmpty else { return }
                isApplyingSortDescriptors = true
                tableView.sortDescriptors = []
                isApplyingSortDescriptors = false
                return
            }

            let key = comparator.column.sortKey
            let ascending = comparator.order == .forward
            if let descriptor = tableView.sortDescriptors.first,
               descriptor.key == key,
               descriptor.ascending == ascending,
               tableView.sortDescriptors.count == 1 {
                return
            }

            isApplyingSortDescriptors = true
            tableView.sortDescriptors = [
                NSSortDescriptor(key: key, ascending: ascending)
            ]
            isApplyingSortDescriptors = false
        }
    }
}

private final class PaperTableContainerView: NSScrollView {
    let tableView = NSTableView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false

        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 42
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.usesAutomaticRowHeights = false
        tableView.focusRingType = .none
        documentView = tableView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class PaperTableCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private var showsIcon = false
    private var maximumLines = 1

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.isHidden = true

        labelField.font = .systemFont(ofSize: NSFont.systemFontSize)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1

        addSubview(iconView)
        addSubview(labelField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        text: String,
        systemImage: String? = nil,
        isSecondary: Bool = false,
        maximumLines: Int = 1
    ) {
        labelField.stringValue = text
        labelField.textColor = isSecondary ? .secondaryLabelColor : .labelColor
        labelField.maximumNumberOfLines = maximumLines
        labelField.usesSingleLineMode = maximumLines == 1
        labelField.lineBreakMode = maximumLines == 1 ? .byTruncatingTail : .byWordWrapping
        if let textCell = labelField.cell as? NSTextFieldCell {
            textCell.wraps = maximumLines > 1
            textCell.isScrollable = maximumLines == 1
            textCell.lineBreakMode = maximumLines == 1 ? .byTruncatingTail : .byWordWrapping
            textCell.truncatesLastVisibleLine = maximumLines > 1
        }
        self.maximumLines = maximumLines

        if let systemImage {
            iconView.image = NSImage(
                systemSymbolName: systemImage,
                accessibilityDescription: nil
            )
            iconView.isHidden = false
            showsIcon = true
        } else {
            iconView.image = nil
            iconView.isHidden = true
            showsIcon = false
        }

        needsLayout = true
    }

    override func layout() {
        super.layout()

        let horizontalInset: CGFloat = 6
        let iconSize: CGFloat = 16
        let iconGap: CGFloat = 6
        let contentBounds = bounds.insetBy(dx: horizontalInset, dy: 3)
        var textMinX = contentBounds.minX

        if showsIcon {
            iconView.frame = NSRect(
                x: contentBounds.minX,
                y: contentBounds.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            textMinX = iconView.frame.maxX + iconGap
        }

        let textHeight = maximumLines == 1
            ? min(labelField.intrinsicContentSize.height, contentBounds.height)
            : contentBounds.height
        labelField.frame = NSRect(
            x: textMinX,
            y: contentBounds.midY - textHeight / 2,
            width: max(0, contentBounds.maxX - textMinX),
            height: textHeight
        )
    }
}

private struct PaperTableColumn: CaseIterable {
    static let allCases = [
        PaperTableColumn(.title, title: "Title", width: 380, minWidth: 240),
        PaperTableColumn(.creators, title: "Creators", width: 220, minWidth: 140),
        PaperTableColumn(.year, title: "Year", width: 70, minWidth: 60),
        PaperTableColumn(.dateAdded, title: "Added", width: 140, minWidth: 120),
        PaperTableColumn(.journal, title: "Journal", width: 120, minWidth: 90),
        PaperTableColumn(.library, title: "Library", width: 120, minWidth: 90),
        PaperTableColumn(.status, title: "Status", width: 140, minWidth: 120),
        PaperTableColumn(.textSource, title: "Text", width: 100, minWidth: 90),
        PaperTableColumn(.updated, title: "Updated", width: 100, minWidth: 90)
    ]

    let column: PaperRowSortComparator.Column
    let title: String
    let width: CGFloat
    let minWidth: CGFloat

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(column.sortKey)
    }

    var cellIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("\(column.sortKey)-cell")
    }

    var sortKey: String {
        column.sortKey
    }

    init(
        _ column: PaperRowSortComparator.Column,
        title: String,
        width: CGFloat,
        minWidth: CGFloat
    ) {
        self.column = column
        self.title = title
        self.width = width
        self.minWidth = minWidth
    }

    init?(identifier: NSUserInterfaceItemIdentifier) {
        guard let spec = Self.allCases.first(where: { $0.identifier == identifier }) else {
            return nil
        }

        self = spec
    }
}

import Foundation

struct PaperTableSortPreference: Equatable {
    static let columnKey = "summarizo.paperTable.sortColumn"
    static let ascendingKey = "summarizo.paperTable.sortAscending"
    static let defaultColumnRawValue = PaperRowSortComparator.Column.title.rawValue
    static let defaultAscending = true
    static let defaultSortOrder = [PaperRowSortComparator(.title)]

    let columnRawValue: String
    let isAscending: Bool

    init(columnRawValue: String, isAscending: Bool) {
        if let column = PaperRowSortComparator.Column(rawValue: columnRawValue) {
            self.columnRawValue = column.rawValue
            self.isAscending = isAscending
        } else {
            self.columnRawValue = Self.defaultColumnRawValue
            self.isAscending = Self.defaultAscending
        }
    }

    init(sortOrder: [PaperRowSortComparator]) {
        guard let comparator = sortOrder.first else {
            self.init(
                columnRawValue: Self.defaultColumnRawValue,
                isAscending: Self.defaultAscending
            )
            return
        }

        self.init(
            columnRawValue: comparator.column.rawValue,
            isAscending: comparator.order == .forward
        )
    }

    var sortOrder: [PaperRowSortComparator] {
        guard let column = PaperRowSortComparator.Column(rawValue: columnRawValue) else {
            return Self.defaultSortOrder
        }

        return [
            PaperRowSortComparator(
                column,
                order: isAscending ? .forward : .reverse
            )
        ]
    }
}

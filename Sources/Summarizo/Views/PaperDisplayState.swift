import Foundation

struct PaperDisplayState {
    static let empty = PaperDisplayState(
        rows: [],
        selectedPapers: [],
        firstPaper: nil,
        filterCounts: .empty,
        papersByID: [:]
    )

    let rows: [PaperDisplayRow]
    let selectedPapers: [SummarizedPaper]
    let firstPaper: SummarizedPaper?
    let filterCounts: SummaryFilterCounts

    private let papersByID: [String: SummarizedPaper]

    var selectedPaper: SummarizedPaper? {
        selectedPapers.first ?? firstPaper
    }

    static func make(
        papers: [SummarizedPaper],
        filter: SummaryFilter,
        searchText: String,
        selection: Set<String>,
        sortOrder: [PaperRowSortComparator]
    ) -> PaperDisplayState {
        let normalizedSearchText = PaperDisplayRow.normalizedSearchText(searchText)
        let now = Date()
        var filterCounts = SummaryFilterCounts.empty

        let visibleItems = papers.enumerated().compactMap { sourceIndex, paper -> PaperDisplayItem? in
            let status = paper.status
            filterCounts.include(status)
            guard filter.includes(status) else { return nil }

            let row = PaperDisplayRow(
                paper: paper,
                sourceIndex: sourceIndex,
                relativeTo: now,
                includesSearchText: !normalizedSearchText.isEmpty
            )
            guard normalizedSearchText.isEmpty || row.searchText.contains(normalizedSearchText) else {
                return nil
            }

            return PaperDisplayItem(row: row, paper: paper)
        }

        let comparator = sortOrder.first ?? PaperRowSortComparator(.title)
        let sortedItems = visibleItems.sorted {
            comparator.compare($0.row, $1.row) == .orderedAscending
        }

        return PaperDisplayState(
            rows: sortedItems.map(\.row),
            selectedPapers: sortedItems.compactMap { selection.contains($0.row.id) ? $0.paper : nil },
            firstPaper: sortedItems.first?.paper,
            filterCounts: filterCounts,
            papersByID: Dictionary(uniqueKeysWithValues: sortedItems.map { ($0.row.id, $0.paper) })
        )
    }

    func selecting(_ selection: Set<String>) -> PaperDisplayState {
        PaperDisplayState(
            rows: rows,
            selectedPapers: rows.compactMap { selection.contains($0.id) ? papersByID[$0.id] : nil },
            firstPaper: firstPaper,
            filterCounts: filterCounts,
            papersByID: papersByID
        )
    }

    func sorted(
        using sortOrder: [PaperRowSortComparator],
        selection: Set<String>
    ) -> PaperDisplayState {
        let comparator = sortOrder.first ?? PaperRowSortComparator(.title)
        let sortedRows = rows.sorted {
            comparator.compare($0, $1) == .orderedAscending
        }

        return PaperDisplayState(
            rows: sortedRows,
            selectedPapers: sortedRows.compactMap { selection.contains($0.id) ? papersByID[$0.id] : nil },
            firstPaper: sortedRows.first.flatMap { papersByID[$0.id] },
            filterCounts: filterCounts,
            papersByID: papersByID
        )
    }

    static func visibleIDs(
        in papers: [SummarizedPaper],
        filter: SummaryFilter,
        searchText: String
    ) -> Set<String> {
        let normalizedSearchText = PaperDisplayRow.normalizedSearchText(searchText)

        return Set(papers.compactMap { paper in
            guard filter.includes(paper.status) else { return nil }
            guard !normalizedSearchText.isEmpty else { return paper.id }

            return PaperDisplayRow.searchText(for: paper).contains(normalizedSearchText)
                ? paper.id
                : nil
        })
    }
}

struct SummaryFilterCounts: Equatable {
    static let empty = SummaryFilterCounts()

    private var counts: [SummaryFilter: Int] = Dictionary(
        uniqueKeysWithValues: SummaryFilter.allCases.map { ($0, 0) }
    )

    mutating func include(_ status: SummaryStatus) {
        for filter in SummaryFilter.allCases where filter.includes(status) {
            counts[filter, default: 0] += 1
        }
    }

    func count(for filter: SummaryFilter) -> Int {
        counts[filter, default: 0]
    }
}

struct PaperDisplayRow: Identifiable, Hashable {
    let id: String
    let title: String
    let titleSortValue: String
    let creatorsDisplay: String
    let creatorsSortValue: String
    let yearDisplay: String
    let yearSortValue: String
    let dateAddedDisplay: String
    let dateAddedSortValue: String
    let journalDisplayName: String
    let journalSortValue: String
    let libraryName: String
    let librarySortValue: String
    let statusRank: Int
    let statusDisplayName: String
    let statusSystemImage: String
    let textSourceDisplayName: String
    let textSourceSortValue: String
    let updatedDate: Date
    let updatedText: String
    let searchText: String
    let sourceIndex: Int

    init(
        paper: SummarizedPaper,
        sourceIndex: Int,
        relativeTo now: Date,
        includesSearchText: Bool
    ) {
        let status = paper.status
        let textSourceDisplayName = paper.textSource?.displayName ?? ""
        let creatorsDisplay = paper.creators.joined(separator: ", ")
        let yearDisplay = paper.year ?? ""
        let dateAddedDisplay = paper.dateAdded ?? ""
        let journalDisplayName = paper.journalAbbreviation ?? ""
        let updatedDate = paper.summarizedAt ?? paper.updatedAt

        self.id = paper.id
        self.title = paper.title
        self.titleSortValue = Self.sortText(paper.title)
        self.creatorsDisplay = creatorsDisplay
        self.creatorsSortValue = Self.sortText(paper.creators.joined(separator: " "))
        self.yearDisplay = yearDisplay
        self.yearSortValue = Self.sortText(yearDisplay)
        self.dateAddedDisplay = dateAddedDisplay
        self.dateAddedSortValue = Self.sortText(dateAddedDisplay)
        self.journalDisplayName = journalDisplayName
        self.journalSortValue = Self.sortText(journalDisplayName)
        self.libraryName = paper.libraryName
        self.librarySortValue = Self.sortText(paper.libraryName)
        self.statusRank = status.sortRank
        self.statusDisplayName = status.displayName
        self.statusSystemImage = status.systemImage
        self.textSourceDisplayName = textSourceDisplayName
        self.textSourceSortValue = Self.sortText(textSourceDisplayName)
        self.updatedDate = updatedDate
        self.updatedText = Self.relativeDateFormatter.localizedString(for: updatedDate, relativeTo: now)
        self.searchText = includesSearchText ? Self.searchText(for: paper) : ""
        self.sourceIndex = sourceIndex
    }

    static func normalizedSearchText(_ text: String) -> String {
        sortText(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func searchText(for paper: SummarizedPaper) -> String {
        sortText([
            paper.title,
            paper.creators.joined(separator: " "),
            paper.year ?? "",
            paper.dateAdded ?? "",
            paper.journalAbbreviation ?? "",
            paper.libraryName,
            paper.doi ?? "",
            paper.summary
        ].joined(separator: " "))
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func sortText(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

struct PaperRowSortComparator: SortComparator, Hashable {
    enum Column: Hashable {
        case title
        case creators
        case year
        case dateAdded
        case journal
        case library
        case status
        case textSource
        case updated
    }

    typealias Compared = PaperDisplayRow

    let column: Column
    var order: SortOrder

    init(_ column: Column, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    func compare(_ lhs: PaperDisplayRow, _ rhs: PaperDisplayRow) -> ComparisonResult {
        let primaryResult = comparePrimary(lhs, rhs)
        if primaryResult != .orderedSame {
            return apply(order, to: primaryResult)
        }

        return compareInts(lhs.sourceIndex, rhs.sourceIndex)
    }

    private func comparePrimary(_ lhs: PaperDisplayRow, _ rhs: PaperDisplayRow) -> ComparisonResult {
        switch column {
        case .title:
            compareStrings(lhs.titleSortValue, rhs.titleSortValue)
        case .creators:
            compareStrings(lhs.creatorsSortValue, rhs.creatorsSortValue)
        case .year:
            compareStrings(lhs.yearSortValue, rhs.yearSortValue)
        case .dateAdded:
            compareStrings(lhs.dateAddedSortValue, rhs.dateAddedSortValue)
        case .journal:
            compareStrings(lhs.journalSortValue, rhs.journalSortValue)
        case .library:
            compareStrings(lhs.librarySortValue, rhs.librarySortValue)
        case .status:
            compareInts(lhs.statusRank, rhs.statusRank)
        case .textSource:
            compareStrings(lhs.textSourceSortValue, rhs.textSourceSortValue)
        case .updated:
            compareDates(lhs.updatedDate, rhs.updatedDate)
        }
    }

    private func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func compareInts(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func compareDates(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func apply(_ order: SortOrder, to result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }

        switch result {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }
}

private struct PaperDisplayItem {
    let row: PaperDisplayRow
    let paper: SummarizedPaper
}

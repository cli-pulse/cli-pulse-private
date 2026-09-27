import XCTest
@testable import CLIPulseCore

/// Which heatmap columns carry a month name.
///
/// The labels used to drift right of their columns and wrap inside the name
/// ("Ma/r", "Au/g"), and the last month ran past the card's edge ("S/p", a bare
/// "9" in Chinese, Japanese and Korean). The row now starts each name over its
/// own column and lets it run on over the next ones, so a name needs room after
/// it: these are the rules that give it that room.
final class UsageHeatmapMonthLabelColumnsTests: XCTestCase {

    /// Months of each column's first day, four or five columns to a month.
    private func months(_ runs: [(month: Int, columns: Int)]) -> [Int?] {
        runs.flatMap { Array(repeating: Optional($0.month), count: $0.columns) }
    }

    func test_each_new_month_is_named_on_its_first_column() {
        let columns = months([(3, 4), (4, 5), (5, 4), (6, 4)])
        XCTAssertEqual(UsageHeatmapGrid.labeledColumns(months: columns), [0, 4, 9, 13])
    }

    func test_a_month_starting_in_the_last_two_columns_is_not_named() {
        // September starts on the second-to-last column: its name would run past
        // the grid's trailing edge.
        let columns = months([(7, 4), (8, 5), (9, 2)])
        XCTAssertEqual(UsageHeatmapGrid.labeledColumns(months: columns), [0, 4])

        // With three columns left it fits.
        let roomy = months([(7, 4), (8, 5), (9, 3)])
        XCTAssertEqual(UsageHeatmapGrid.labeledColumns(months: roomy), [0, 4, 9])
    }

    func test_the_first_column_is_not_named_when_the_next_month_follows_too_soon() {
        // The grid opens on the last week of February: "Feb" at column 0 would be
        // printed over by "Mar" at column 1.
        let columns = months([(2, 1), (3, 4), (4, 5)])
        XCTAssertEqual(UsageHeatmapGrid.labeledColumns(months: columns), [1, 5])

        let twoWeeks = months([(2, 2), (3, 4), (4, 5)])
        XCTAssertEqual(UsageHeatmapGrid.labeledColumns(months: twoWeeks), [2, 6])

        let threeWeeks = months([(2, 3), (3, 4), (4, 5)])
        XCTAssertEqual(UsageHeatmapGrid.labeledColumns(months: threeWeeks), [0, 3, 7])
    }

    func test_columns_without_a_date_are_never_named() {
        XCTAssertEqual(UsageHeatmapGrid.labeledColumns(months: [nil, nil, 5, 5, 5, 5]), [2])
        XCTAssertEqual(UsageHeatmapGrid.labeledColumns(months: []), [])
        XCTAssertEqual(UsageHeatmapGrid.labeledColumns(months: [4, 4]), [])
    }

    /// A year of the real column maths: every month that starts early enough is
    /// named once, and no two names are closer than a name is wide.
    func test_a_year_of_real_columns() {
        let today = "2026-09-27"
        let columns = DailyUsageStats.heatmapColumns(todayKey: today, weeks: 53)
        let calendar = DayKey.calendar(in: DayKey.utc)
        let formatter = DayKey.formatter(in: DayKey.utc)
        let months: [Int?] = columns.map { week in
            week.first.flatMap { formatter.date(from: $0) }.map { calendar.component(.month, from: $0) }
        }
        let labeled = UsageHeatmapGrid.labeledColumns(months: months)
        XCTAssertGreaterThanOrEqual(labeled.count, 11)
        XCTAssertLessThanOrEqual(labeled.count, 13)
        for (a, b) in zip(labeled, labeled.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 3, "\(labeled)")
        }
        XCTAssertLessThanOrEqual(labeled.last ?? 0, columns.count - 3)
    }
}

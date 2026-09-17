import XCTest
@testable import CLIPulseCore

/// The heatmap labels its columns with the month of each column's first day
/// key. Day keys are Gregorian, so the label has to name a Gregorian month in
/// the user's language. The names used to come from a formatter that followed
/// the locale's calendar: on a Persian or Islamic Mac, September's column was
/// labelled Azar or Ramadan.
final class UsageHeatmapMonthNamesTests: XCTestCase {

    /// A locale whose calendar is Persian or Islamic, in a language whose
    /// Gregorian month names are plain numbers, so the expected value cannot
    /// drift with CLDR updates.
    func test_month_names_are_gregorian_under_a_persian_or_islamic_calendar() {
        let cases: [(locale: String, calendar: Calendar.Identifier, september: String)] = [
            ("ja_JP@calendar=persian", .persian, "9月"),
            ("ko_KR@calendar=persian", .persian, "9월"),
            ("ja_JP@calendar=islamic-umalqura", .islamicUmmAlQura, "9月"),
        ]
        for c in cases {
            let locale = Locale(identifier: c.locale)
            // The locale really carries that calendar, and a formatter left to it
            // names its own ninth month: without this the check below could pass
            // on a calendar that happens to use Gregorian names.
            let unpinned = DateFormatter()
            unpinned.locale = locale
            XCTAssertEqual(unpinned.calendar.identifier, c.calendar, c.locale)
            XCTAssertNotEqual(unpinned.shortStandaloneMonthSymbols?[8], c.september, c.locale)

            let names = UsageHeatmapGrid.shortMonthNames(locale: locale)
            XCTAssertEqual(names.count, 12, c.locale)
            XCTAssertEqual(UsageHeatmapGrid.name(ofMonth: 9, in: names), c.september, c.locale)
        }
    }

    /// fa_IR and ar_SA get Persian and islamic-umalqura by default, with no
    /// keyword. Their month names must be the ones the same language uses for
    /// the Gregorian calendar.
    func test_month_names_ignore_the_default_calendar_of_the_region() {
        for (region, calendar) in [("fa_IR", Calendar.Identifier.persian), ("ar_SA", .islamicUmmAlQura)] {
            let unpinned = DateFormatter()
            unpinned.locale = Locale(identifier: region)
            XCTAssertEqual(unpinned.calendar.identifier, calendar, region)

            let names = UsageHeatmapGrid.shortMonthNames(locale: Locale(identifier: region))
            let gregorianNames = UsageHeatmapGrid.shortMonthNames(locale: Locale(identifier: "\(region)@calendar=gregorian"))
            XCTAssertEqual(names.count, 12, region)
            XCTAssertEqual(names, gregorianNames, region)
            XCTAssertNotEqual(names, unpinned.shortStandaloneMonthSymbols, region)
        }
    }

    func test_month_number_outside_one_to_twelve_has_no_name() {
        let names = UsageHeatmapGrid.shortMonthNames(locale: Locale(identifier: "ja_JP"))
        XCTAssertEqual(UsageHeatmapGrid.name(ofMonth: 1, in: names), "1月")
        XCTAssertEqual(UsageHeatmapGrid.name(ofMonth: 12, in: names), "12月")
        XCTAssertEqual(UsageHeatmapGrid.name(ofMonth: 0, in: names), "")
        XCTAssertEqual(UsageHeatmapGrid.name(ofMonth: 13, in: names), "")
    }
}

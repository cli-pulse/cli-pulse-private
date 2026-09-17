import XCTest
@testable import CLIPulseCore

// Day keys ("2026-09-17") are stored, uploaded as `metric_date`, sent as
// `p_user_today`, and matched against Codex's YYYY/MM/DD directories. They were
// built with whatever calendar the device used, so a Mac set to the Japanese
// calendar (和暦) wrote 0008-09-17, one set to the Republic of China calendar
// (民國) 0115-09-17, and one in Thailand (Buddhist by default) 2569-09-17.
//
// This file deliberately calls only APIs that existed before the fix, so it
// can be run against the old code as a control.

/// Functions that take a calendar: pass one that numbers years differently and
/// the key must still be Gregorian. Only the calendar's time zone may matter.
final class DayKeyInjectedCalendarTests: XCTestCase {

    /// 2026-09-17 12:00 in Tokyo, 11:00 in Taipei, 10:00 in Bangkok.
    private let instant = ISO8601DateFormatter().date(from: "2026-09-17T03:00:00Z")!

    private func calendar(_ id: Calendar.Identifier, _ zone: String) -> Calendar {
        var c = Calendar(identifier: id)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    /// Each calendar with the year it gives this instant. Asserting that year
    /// first keeps the test honest: if a calendar ever numbered like Gregorian
    /// here, the key assertions below would pass without proving anything.
    private var nonGregorian: [(Calendar, Int)] {
        [(calendar(.japanese, "Asia/Tokyo"), 8),
         (calendar(.republicOfChina, "Asia/Taipei"), 115),
         (calendar(.buddhist, "Asia/Bangkok"), 2569)]
    }

    func test_keys_are_gregorian_whatever_calendar_is_passed_in() {
        for (cal, eraYear) in nonGregorian {
            let id = "\(cal.identifier)"
            XCTAssertEqual(cal.component(.year, from: instant), eraYear, "\(id): not a non-Gregorian calendar")

            XCTAssertEqual(DailyUsageStats.localDayKey(instant, calendar: cal), "2026-09-17", id)
            XCTAssertEqual(APIClient.localTodayKey(now: instant, calendar: cal), "2026-09-17", id)
            XCTAssertEqual(DateRange.ymd(instant, calendar: cal), "2026-09-17", id)
            XCTAssertEqual(DateRange.rollingWeekStartYMD(from: instant, calendar: cal), "2026-09-11", id)
            XCTAssertEqual(ProviderUsageHistory.currentLocalDayKey(calendar: cal, now: instant), "2026-09-17", id)
        }
    }

    /// Pinning the numbering must not pin the day boundary: the same instant is
    /// still a different day in Tokyo and in Honolulu.
    func test_the_calendars_time_zone_still_splits_the_day() {
        let evening = ISO8601DateFormatter().date(from: "2026-09-16T20:00:00Z")!
        XCTAssertEqual(DailyUsageStats.localDayKey(evening, calendar: calendar(.japanese, "Asia/Tokyo")), "2026-09-17")
        XCTAssertEqual(DailyUsageStats.localDayKey(evening, calendar: calendar(.japanese, "Pacific/Honolulu")), "2026-09-16")
        XCTAssertEqual(APIClient.localTodayKey(now: evening, calendar: calendar(.republicOfChina, "Asia/Taipei")), "2026-09-17")
        XCTAssertEqual(APIClient.localTodayKey(now: evening, calendar: calendar(.republicOfChina, "UTC")), "2026-09-16")
    }

    /// The usage-history chart on a Japanese-calendar iPhone: the server's rows
    /// are Gregorian, so a window ending at "0008-09-17" showed all zeros.
    func test_usage_history_finds_the_servers_rows_under_the_japanese_calendar() {
        let jp = calendar(.japanese, "Asia/Tokyo")
        let rows = [
            DailyUsage(date: "2026-09-16", provider: "Codex", model: "gpt-5",
                       inputTokens: 100, cachedTokens: 0, outputTokens: 20, cost: 1),
            DailyUsage(date: "2026-09-17", provider: "Codex", model: "gpt-5",
                       inputTokens: 300, cachedTokens: 0, outputTokens: 40, cost: 2),
        ]
        let today = ProviderUsageHistory.currentLocalDayKey(calendar: jp, now: instant)
        let series = ProviderUsageHistory.series(from: rows, provider: "Codex", days: 3, todayKey: today, calendar: jp)
        XCTAssertEqual(series.map(\.dateKey), ["2026-09-15", "2026-09-16", "2026-09-17"])
        XCTAssertEqual(series.map(\.ioTokens), [0, 120, 340])
    }

    /// Demo mode feeds the same archive the heatmap reads with Gregorian keys.
    func test_demo_rows_are_gregorian_under_the_roc_calendar() {
        let roc = calendar(.republicOfChina, "Asia/Taipei")
        let dates = Set(DemoDataProvider.dailyUsage(days: 3, today: instant, calendar: roc).map(\.date))
        XCTAssertTrue(dates.contains("2026-09-17"), "today's demo row: \(dates.sorted())")
        XCTAssertTrue(dates.isSubset(of: ["2026-09-15", "2026-09-16", "2026-09-17"]), "\(dates.sorted())")
    }
}

/// Code that reads the device calendar (`Calendar.current`, a bare
/// `DateFormatter()`) rather than taking one. On a Gregorian machine these pass
/// whether or not the code is fixed — and so does every other test that reaches
/// such code — so they prove something only when the test process runs under
/// another calendar. Foundation reads `-AppleLocale` from the command line, and
/// swift-ci.yml runs the whole bundle that way under the Japanese, ROC and
/// Buddhist calendars after `swift test`. Locally, after `swift build --build-tests`:
///
///     CLIPULSE_EXPECT_CALENDAR=japanese xcrun xctest -AppleLocale "en_US@calendar=japanese" \
///         -XCTest All "$(swift build --show-bin-path)"/*.xctest
///
/// (`roc`, `buddhist`; a class name instead of `All` narrows the run). The flag
/// goes before `-XCTest`: xctest reads its last argument as the bundle path. The
/// environment variable makes the run fail if the flag did not take, instead of
/// passing under Gregorian. A source guard cannot stand in for this run: the
/// ways to read the device calendar are too many to list.
final class DayKeyDeviceCalendarTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let expected = ProcessInfo.processInfo.environment["CLIPULSE_EXPECT_CALENDAR"] {
            XCTAssertEqual("\(Calendar.current.identifier)", expected,
                           "the forced calendar did not take effect; these tests would prove nothing")
        }
    }

    /// Noon on a Gregorian date in the device's time zone, built without the
    /// code under test.
    private func localNoon(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    #if os(macOS)
    /// These keys become `metric_date`: a Japanese-calendar Mac uploaded 0008-09-17.
    func test_scanner_keys_are_gregorian() {
        let noon = localNoon(2026, 9, 17)
        XCTAssertEqual(CostUsageScanner.DayRange.dayKey(from: noon), "2026-09-17")
        let stamp = ISO8601DateFormatter().string(from: noon)   // e.g. 2026-09-17T03:00:00Z
        XCTAssertEqual(CostUsageScanner.dayKeyFromTimestamp(stamp), "2026-09-17")
    }

    /// Codex writes `sessions/2026/09/17/*.jsonl`. Under the Japanese calendar
    /// the scanner looked in `sessions/0008/09/17`, and Codex tokens and cost
    /// read zero.
    func test_codex_usage_is_found_in_its_gregorian_directory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("daykey-codex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sessions = tmp.appendingPathComponent("sessions", isDirectory: true)

        let now = Date()
        let dayFormatter = ISO8601DateFormatter()          // always Gregorian
        dayFormatter.formatOptions = [.withFullDate]
        dayFormatter.timeZone = .current
        let today = dayFormatter.string(from: now)         // "2026-09-17"
        let dir = today.split(separator: "-").reduce(sessions) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: now)
        let lines = [
            #"{"type":"session_meta","timestamp":"\#(ts)","payload":{"session_id":"daykey"}}"#,
            #"{"type":"turn_context","timestamp":"\#(ts)","payload":{"model":"gpt-5"}}"#,
            #"{"type":"event_msg","timestamp":"\#(ts)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500}}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("rollout-daykey.jsonl"), atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(codexSessionsRoot: sessions, claudeProjectsRoots: [],
                                               cacheRoot: tmp.appendingPathComponent("cache"), daysToScan: 7)
        options.refreshMinIntervalSeconds = 0
        let codex = CostUsageScanner.scan(options: options).entries.filter { $0.provider == "Codex" }
        XCTAssertEqual(codex.map(\.date), [today])
        XCTAssertEqual(codex.first?.inputTokens, 1000)
    }
    #endif

    /// Yield rows come from the server in Gregorian. A bare formatter under the
    /// Japanese calendar parsed them into the year 4044, past the window's end,
    /// and the Yield card always showed its empty state.
    func test_yield_rows_parse_as_gregorian_and_stay_in_the_window() {
        let row = YieldScoreRow(provider: "Claude", day: "2026-09-17", total_cost: 4,
                                weighted_commit_count: 2, raw_commit_count: 2, ambiguous_commit_count: 0)
        XCTAssertEqual(row.dayDate, ISO8601DateFormatter().date(from: "2026-09-17T00:00:00Z"))
        let now = ISO8601DateFormatter().date(from: "2026-09-18T12:00:00Z")!
        let summaries = YieldScoreAggregator.summarize(rows: [row], range: .sevenDays, now: now)
        XCTAssertEqual(summaries.map(\.provider), ["Claude"])
    }

    /// The month-end forecast looks its rows up by key; under the Japanese
    /// calendar it asked for 0008-09-01 … and found nothing.
    func test_forecast_finds_this_months_rows() throws {
        let rows = (1...17).map {
            DailyUsage(date: String(format: "2026-09-%02d", $0), provider: "Claude", model: "m",
                       inputTokens: 1, cachedTokens: 0, outputTokens: 1, cost: 1)
        }
        let forecast = try XCTUnwrap(CostForecastEngine.forecast(from: rows, referenceDate: localNoon(2026, 9, 17)))
        XCTAssertEqual(forecast.actualToDate, 17, accuracy: 0.0001)
        XCTAssertEqual(forecast.daysInMonth, 30)
    }

    #if os(macOS)
    /// The PDF export suggested cli-pulse-report-0008-09-17.pdf.
    func test_pdf_export_is_named_with_the_gregorian_date() {
        let destination = PDFReportGenerator.defaultDestination(for: localNoon(2026, 9, 17), existing: { _ in false })
        XCTAssertEqual(destination.preferred.lastPathComponent, "cli-pulse-report-2026-09-17.pdf")
    }
    #endif
}

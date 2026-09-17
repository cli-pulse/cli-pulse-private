import XCTest
@testable import CLIPulseCore

private let isoFormatter = ISO8601DateFormatter()
/// 2026-09-17 12:00 in Tokyo.
private let instant = isoFormatter.date(from: "2026-09-17T03:00:00Z")!

private func calendar(_ id: Calendar.Identifier, _ zone: String = "Asia/Tokyo") -> Calendar {
    var c = Calendar(identifier: id)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

/// The key the code wrote before `DayKey`: the device calendar's own numbers.
private func legacyKey(_ date: Date, in cal: Calendar) -> String {
    let c = cal.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

/// Every calendar Foundation offers on the oldest OS this package supports.
private let foreignCalendars: [Calendar.Identifier] = [
    .buddhist, .chinese, .coptic, .ethiopicAmeteAlem, .ethiopicAmeteMihret, .hebrew, .indian,
    .islamic, .islamicCivil, .islamicTabular, .islamicUmmAlQura, .japanese, .persian, .republicOfChina,
]

/// The calendars Foundation added in macOS 26 and iOS 26, by locale keyword so
/// the tests compile with an SDK that predates their `Calendar.Identifier`
/// cases. Vikram and Gujarati number the years closest above the Gregorian
/// window (2076 on 2020-01-01).
private let newerCalendarKeywords = [
    "bangla", "dangi", "gujarati", "kannada", "malayalam", "marathi", "odia", "tamil", "telugu", "vikram", "vietnamese",
]

private func allForeignCalendars() -> [Calendar] {
    foreignCalendars.map { Calendar(identifier: $0) }
        + newerCalendarKeywords.map { Locale(identifier: "en_US@calendar=\($0)").calendar }
}

final class DayKeyTests: XCTestCase {

    func test_keys_and_formatters_are_gregorian_and_posix() throws {
        XCTAssertEqual(DayKey.string(from: instant, in: TimeZone(identifier: "Asia/Tokyo")!), "2026-09-17")
        XCTAssertEqual(DayKey.string(from: instant, in: TimeZone(identifier: "Pacific/Honolulu")!), "2026-09-16")

        let f = DayKey.formatter(in: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(f.calendar.identifier, .gregorian)
        XCTAssertEqual(f.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(f.date(from: "2026-09-17"), isoFormatter.date(from: "2026-09-17T00:00:00Z"))
        XCTAssertEqual(DayKey.calendar(in: TimeZone(identifier: "UTC")!).identifier, .gregorian)
    }

    func test_date_from_key_only_accepts_days_that_exist() {
        XCTAssertEqual(DayKey.date(from: "2026-09-17", hour: 12, in: TimeZone(identifier: "Asia/Tokyo")!), instant)
        XCTAssertNil(DayKey.date(from: "2026-02-29"), "2026 is not a leap year; a lenient calendar says March 1")
        XCTAssertNil(DayKey.date(from: "2026-13-01"))
        XCTAssertNil(DayKey.date(from: "2026-9-17"))
        XCTAssertNil(DayKey.date(from: "not-a-date"))
    }

    /// The window is a fixed range of years, so it has to reject a key written
    /// in any calendar Foundation offers on every day it accepts, not just
    /// today: the first of every month from 2020 through 2075, and 2075-12-31.
    /// Ethiopic is the one known exception, from its year 2020, which starts in
    /// September 2027 (see `DayKey.earliestPlausibleYear`). The keys at the end
    /// pin the window itself.
    func test_plausible_rejects_every_foreign_calendars_numbering() throws {
        let utc = TimeZone(identifier: "UTC")!
        let first = try XCTUnwrap(DayKey.date(from: "2020-01-01", hour: 12, in: utc))
        let months = (DayKey.latestPlausibleYear - DayKey.earliestPlausibleYear + 1) * 12
        var days = (0..<months).compactMap { DayKey.calendar(in: utc).date(byAdding: .month, value: $0, to: first) }
        days.append(try XCTUnwrap(DayKey.date(from: "\(DayKey.latestPlausibleYear)-12-31", hour: 12, in: utc)))

        var numberedDifferently: Set<String> = []
        var ethiopicEntersWindow: String?
        for var cal in allForeignCalendars() {
            cal.timeZone = utc
            for day in days {
                let key = legacyKey(day, in: cal)
                let gregorianKey = DayKey.string(from: day, in: utc)
                // Some OS versions number a calendar exactly like Gregorian (macOS 15
                // does for .ethiopicAmeteAlem). A key written in it was already right,
                // and keeping it is what isPlausible should do.
                if key == gregorianKey { continue }
                numberedDifferently.insert("\(cal.identifier)")
                guard DayKey.isPlausible(key) else { continue }
                if cal.identifier == .ethiopicAmeteMihret {
                    if ethiopicEntersWindow == nil { ethiopicEntersWindow = gregorianKey }
                } else {
                    XCTFail("\(cal.identifier) wrote \(key) on \(gregorianKey)")
                    break
                }
            }
        }
        XCTAssertGreaterThanOrEqual(ethiopicEntersWindow ?? "never", "2027-09-01")

        // The skip above must not empty the check: these are the calendars that
        // broke usage data, and they number years differently on every OS.
        XCTAssertTrue(numberedDifferently.isSuperset(of: ["japanese", "roc", "buddhist", "persian", "hebrew"]),
                      "\(numberedDifferently.sorted())")
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) {
            XCTAssertTrue(numberedDifferently.isSuperset(of: ["vikram", "gujarati"]), "\(numberedDifferently.sorted())")
        }

        for key in ["2020-01-01", "2025-02-24", "2026-09-17", "2028-01-01", "2051-09-16", "2075-12-31"] {
            XCTAssertTrue(DayKey.isPlausible(key), key)
        }
        for key in ["2019-12-31", "2076-01-01", "2083-06-22", "2569-09-17", "2026-02-29", "2026-9-17", ""] {
            XCTAssertFalse(DayKey.isPlausible(key), key)
        }
    }

    /// A key read back in the calendar that wrote it names the right day — or,
    /// when it cannot be read back, no day at all. Never a wrong day.
    func test_stored_keys_convert_back_from_the_calendar_that_wrote_them() {
        XCTAssertEqual(DayKey.normalizedStoredKey("0008-09-17", writtenIn: calendar(.japanese)), "2026-09-17")
        XCTAssertEqual(DayKey.normalizedStoredKey("0115-09-17", writtenIn: calendar(.republicOfChina, "Asia/Taipei")), "2026-09-17")
        XCTAssertEqual(DayKey.normalizedStoredKey("2569-09-17", writtenIn: calendar(.buddhist, "Asia/Bangkok")), "2026-09-17")

        for id in foreignCalendars {
            let cal = calendar(id)
            let converted = DayKey.normalizedStoredKey(legacyKey(instant, in: cal), writtenIn: cal)
            if id == .chinese {
                // Its year field is a 60-year cycle with no era in the key; losing
                // the day is acceptable, inventing one is not.
                XCTAssertTrue(converted == nil || converted == "2026-09-17", "\(id): \(converted ?? "nil")")
            } else {
                XCTAssertEqual(converted, "2026-09-17", "\(id)")
            }
        }

        // Already Gregorian: untouched even though the device calendar is Japanese.
        XCTAssertEqual(DayKey.normalizedStoredKey("2026-09-16", writtenIn: calendar(.japanese)), "2026-09-16")
        // The device is Gregorian again, so nothing can read year 8 back: drop it.
        XCTAssertNil(DayKey.normalizedStoredKey("0008-09-17", writtenIn: calendar(.gregorian)))
        XCTAssertNil(DayKey.normalizedStoredKey("0008-13-40", writtenIn: calendar(.japanese)))
    }

    #if canImport(PDFKit) && !os(watchOS)
    func test_pdf_report_base_name_uses_the_gregorian_day() {
        XCTAssertEqual(PDFReportGenerator.reportBaseName(for: instant, in: TimeZone(identifier: "Asia/Tokyo")!),
                       "cli-pulse-report-2026-09-17")
    }
    #endif
}

/// Data written while keys followed the device calendar has to be read back in
/// Gregorian, or it sits beside the new keys forever — and under the Buddhist
/// calendar, which sorts after every real day, it wedges whatever orders by key.
final class DayKeyStoredDataMigrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayKeyStoredData-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: Cloud rows

    /// Rows this Mac uploaded as 0008-… or 2569-… stay on the server until
    /// someone deletes them; they must not come back in.
    func test_cloud_rows_dated_in_another_calendar_are_skipped() {
        func row(_ date: String) -> [String: Any] {
            ["metric_date": date, "provider": "Claude", "model": "m", "input_tokens": 5, "cost": 1.0]
        }
        let rows = APIClient.dailyUsageRows(from: [row("2026-09-17"), row("0008-09-17"), row("2569-09-17"), row("0115-09-16")])
        XCTAssertEqual(rows.map(\.date), ["2026-09-17"])
        XCTAssertEqual(rows.first?.inputTokens, 5)
    }

    // MARK: Scanner cache

    #if os(macOS)
    /// Each file's entry keeps its old keys and its parsed offset, so an
    /// unchanged file would never be re-read and its usage would stay missing.
    func test_scanner_cache_with_non_gregorian_keys_is_rebuilt() {
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 42
        cache.days = ["2026-09-16": ["gpt-5": [1, 0, 1]]]
        cache.files = ["/f.jsonl": CostUsageFileUsage(mtimeUnixMs: 1, size: 10, days: ["0008-09-17": ["gpt-5": [1, 0, 1]]],
                                                        parsedBytes: 10, lastModel: nil, lastTotals: nil, sessionId: nil)]
        CostUsageCacheIO.save(provider: "codex", cache: cache, cacheRoot: tempDir)
        let loaded = CostUsageCacheIO.load(provider: "codex", cacheRoot: tempDir)
        XCTAssertEqual(loaded.lastScanUnixMs, 0, "a cache holding 0008-09-17 must start over")
        XCTAssertTrue(loaded.files.isEmpty)

        cache.files["/f.jsonl"]?.days = ["2026-09-17": ["gpt-5": [1, 0, 1]]]
        CostUsageCacheIO.save(provider: "codex", cache: cache, cacheRoot: tempDir)
        XCTAssertEqual(CostUsageCacheIO.load(provider: "codex", cacheRoot: tempDir).lastScanUnixMs, 42,
                       "a Gregorian cache is kept")
    }
    #endif

    // MARK: Usage archive

    func test_archive_keys_are_read_back_in_the_calendar_that_wrote_them() {
        let local15 = DayRollup(tokens: 15)
        let local17 = DayRollup(tokens: 17)
        let cloud17 = DayRollup(tokens: 1)
        let archive = DailyUsageArchive(
            days: ["0008-09-15": local15, "0008-09-17": local17, "2026-09-17": cloud17],
            months: ["0008-08": MonthRollup(tokens: 100), "2026-08": MonthRollup(tokens: 7)],
            foldedThroughDay: "0008-08-31")

        let n = archive.normalizingDayKeys(writtenIn: calendar(.japanese))
        XCTAssertEqual(n.days, ["2026-09-15": local15, "2026-09-17": local17],
                       "the local day replaces the cloud-filled copy of the same day")
        XCTAssertEqual(n.months, ["2026-08": MonthRollup(tokens: 107)])
        XCTAssertEqual(n.foldedThroughDay, "2026-08-31")
    }

    /// `foldedThroughDay = "2569-…"` sorts after every real day, so every later
    /// merge would skip its day as already folded.
    func test_buddhist_fold_marker_no_longer_blocks_new_days() {
        var archive = DailyUsageArchive(days: ["2569-09-16": DayRollup(tokens: 3)],
                                        months: ["2569-08": MonthRollup(tokens: 9)],
                                        foldedThroughDay: "2569-08-31")
            .normalizingDayKeys(writtenIn: calendar(.buddhist, "Asia/Bangkok"))
        archive.mergeScanEntries([ScanEntry(date: "2026-09-17", provider: "Codex", model: "gpt-5",
                                            inputTokens: 40, cachedTokens: 0, outputTokens: 2, cost: 1, messages: 0)])
        XCTAssertEqual(archive.days["2026-09-17"]?.tokens, 42)
        XCTAssertEqual(archive.days["2026-09-16"]?.tokens, 3)
    }

    /// Loading applies the device calendar (see the pet ledger test below):
    /// either way the year-8 key is gone and the real day stays.
    func test_archive_load_leaves_no_era_keys() throws {
        let json = #"{"version":1,"days":{"0008-09-17":{"tokens":8,"cost":0,"messages":0,"perProvider":{},"perModel":{}},"2026-09-16":{"tokens":16,"cost":0,"messages":0,"perProvider":{},"perModel":{}}},"months":{},"lastUpdatedUnixMs":0}"#
        try Data(json.utf8).write(to: DailyUsageArchiveIO.fileURL(root: tempDir))
        let loaded = DailyUsageArchiveIO.load(root: tempDir)
        XCTAssertNil(loaded.days["0008-09-17"])
        XCTAssertEqual(loaded.days["2026-09-16"]?.tokens, 16)
    }

    // MARK: Pet

    /// `prune` keeps the lexically newest keys: 2569-… days would outlive every
    /// real one and push the hatch window's trailing week out.
    func test_pet_ledger_keeps_new_days_after_buddhist_keys_are_converted() {
        func day(_ tokens: Int) -> PetDayRollup {
            PetDayRollup(providers: ["Claude": PetProviderSlice(tokens: tokens, confidence: .high, observedAtUnixMs: 1)])
        }
        var ledger = PetDailyLedger(days: ["2569-09-15": day(15), "2569-09-16": day(16)])
            .normalizingDayKeys(writtenIn: calendar(.buddhist, "Asia/Bangkok"))
        XCTAssertEqual(ledger.days.keys.sorted(), ["2026-09-15", "2026-09-16"])

        ledger.ingest([PetObservation(providerRaw: "Claude", tokens: 17, messages: 0, costUSD: 0,
                                      sourceTimestampUnixMs: 2, dayKey: "2026-09-17",
                                      confidence: .high, semantics: .cumulativeToday)],
                      retainDays: 2)
        XCTAssertEqual(ledger.days.keys.sorted(), ["2026-09-16", "2026-09-17"])
    }

    /// Loading applies the device calendar: on a Gregorian device year 8 is
    /// dropped, under Japanese numbering it becomes 2026-09-17. Either way the
    /// era key is gone and the real day stays.
    func test_pet_ledger_load_leaves_no_era_keys() throws {
        let ledger = PetDailyLedger(days: ["0008-09-17": PetDayRollup(), "2026-09-16": PetDayRollup()])
        XCTAssertTrue(PetDailyLedgerIO.save(ledger, root: tempDir))
        let keys = PetDailyLedgerIO.load(root: tempDir).days.keys
        XCTAssertFalse(keys.contains("0008-09-17"))
        XCTAssertTrue(keys.contains("2026-09-16"))
    }

    /// The event log is append-only, so an old hatch keeps its Buddhist key.
    /// Compared with a Gregorian today it would block the next hatch for 543 years.
    func test_pet_hatch_logged_in_buddhist_numbering_does_not_block_the_next_hatch() {
        let events = [PetEvent(kind: .hatch, dayKey: "2569-07-11", timestampUnixMs: 1, form: "loaf")]
        let state = PetCoordinator.rebuild(from: events, writtenIn: calendar(.buddhist, "Asia/Bangkok"))
        XCTAssertEqual(state.lastHatchDayKey, "2026-07-11")
        XCTAssertEqual(state.ownedDayKeys["loaf"], "2026-07-11")
        XCTAssertTrue(PetEngine.timingAllows(lastHatchDayKey: state.lastHatchDayKey, todayKey: "2026-09-17"))
    }

    // MARK: A device clock set years behind

    /// With the device clock set years behind, today's keys lie years in the
    /// clock's future. The first version of this migration accepted keys up to
    /// "next year" by the clock, so with the clock at 2024-06-01 or 2001-01-01
    /// `normalizedStoredKey("2026-09-16")` returned nil: every load dropped the
    /// archive's days, months and fold marker and the pet ledger's days, the
    /// next save made that permanent, and the scanner cache started over on
    /// every scan. Nothing reads the clock now, so there is no clock to set
    /// here; the keys move instead. Against a 2026 clock, keys from 2028 and
    /// 2051 are those two clocks, and 2075 is the window's last year.
    private static let yearsAfterTheClock = [2028, 2051, 2075]

    func test_archive_load_keeps_days_years_after_the_clock() {
        for year in Self.yearsAfterTheClock {
            let archive = DailyUsageArchive(
                days: ["\(year)-09-15": DayRollup(tokens: 15), "\(year)-09-16": DayRollup(tokens: 16)],
                months: ["\(year)-08": MonthRollup(tokens: 100)],
                foldedThroughDay: "\(year)-08-31")
            XCTAssertTrue(DailyUsageArchiveIO.save(archive, root: tempDir))
            let loaded = DailyUsageArchiveIO.load(root: tempDir)
            XCTAssertEqual(loaded.days, archive.days, "\(year)")
            XCTAssertEqual(loaded.months, archive.months, "\(year)")
            XCTAssertEqual(loaded.foldedThroughDay, archive.foldedThroughDay, "\(year)")
        }
    }

    func test_pet_ledger_load_keeps_days_years_after_the_clock() {
        for year in Self.yearsAfterTheClock {
            let ledger = PetDailyLedger(days: ["\(year)-09-15": PetDayRollup(), "\(year)-09-16": PetDayRollup()])
            XCTAssertTrue(PetDailyLedgerIO.save(ledger, root: tempDir))
            XCTAssertEqual(PetDailyLedgerIO.load(root: tempDir).days.keys.sorted(), ["\(year)-09-15", "\(year)-09-16"])
        }
    }

    #if os(macOS)
    func test_scanner_cache_keeps_keys_years_after_the_clock() {
        for year in Self.yearsAfterTheClock {
            var cache = CostUsageCache()
            cache.lastScanUnixMs = 42
            cache.days = ["\(year)-09-16": ["gpt-5": [1, 0, 1]]]
            cache.files = ["/f.jsonl": CostUsageFileUsage(mtimeUnixMs: 1, size: 10, days: ["\(year)-09-16": ["gpt-5": [1, 0, 1]]],
                                                            parsedBytes: 10, lastModel: nil, lastTotals: nil, sessionId: nil)]
            CostUsageCacheIO.save(provider: "codex", cache: cache, cacheRoot: tempDir)
            let loaded = CostUsageCacheIO.load(provider: "codex", cacheRoot: tempDir)
            XCTAssertEqual(loaded.lastScanUnixMs, 42, "\(year): the cache was thrown away")
            XCTAssertEqual(loaded.files["/f.jsonl"]?.days.keys.sorted(), ["\(year)-09-16"])
        }
    }
    #endif

    func test_cloud_rows_years_after_the_clock_are_kept() {
        let rows = APIClient.dailyUsageRows(from: Self.yearsAfterTheClock.map {
            ["metric_date": "\($0)-09-16", "provider": "Claude", "model": "m", "input_tokens": 5, "cost": 1.0]
        })
        XCTAssertEqual(rows.map(\.date), Self.yearsAfterTheClock.map { "\($0)-09-16" })
    }
}

/// Reference guard: every machine day key goes through `DayKey`. A comparison
/// of the fixed sites cannot see the next site someone adds with
/// `DateFormatter()` or `Calendar.current`, so this reads the sources.
final class DayKeySourceGuardTests: XCTestCase {

    private static let patterns: [(name: String, regex: String)] = [
        ("a yyyy-MM-dd formatter", #"dateFormat\s*=\s*"[yY]{4}-MM-dd""#),
        ("a %04d-%02d-%02d key", #"%04d-%02d-%02d"#),
        ("year/month/day components for a key", #"dateComponents\(\[\.year, \.month, \.day\]"#),
    ]

    func test_day_keys_are_only_built_in_DayKey_swift() throws {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
        let apple = core.deletingLastPathComponent()   // CLI Pulse Bar
        let roots = [core.appendingPathComponent("Sources")] + [
            "CLI Pulse Bar", "CLI Pulse Bar iOS", "CLI Pulse Bar Watch", "CLI Pulse Widgets", "CLIPulseHelper",
        ].map { apple.appendingPathComponent($0) }

        let regexes = try Self.patterns.map { try NSRegularExpression(pattern: $0.regex) }
        var scanned = 0
        var violations: [String] = []
        var dayKeySource: String?
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                if file.lastPathComponent == "DayKey.swift" { dayKeySource = text; continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    for (p, regex) in zip(Self.patterns, regexes) where regex.firstMatch(in: line, range: range) != nil {
                        violations.append("\(file.path.replacingOccurrences(of: apple.path + "/", with: "")):\(index + 1): \(p.name)")
                    }
                }
            }
        }

        XCTAssertTrue(violations.isEmpty,
                      "Build day keys with DayKey (Gregorian, POSIX) — the device calendar numbers years 8, 115 or 2569:\n"
                      + violations.joined(separator: "\n"))

        // Positive controls: a wrong root or a pattern that matches nothing
        // would make the assertion above pass vacuously.
        XCTAssertGreaterThan(scanned, 300, "scan roots are wrong")
        let source = try XCTUnwrap(dayKeySource, "DayKey.swift not found")
        for (p, regex) in zip(Self.patterns, regexes) {
            XCTAssertNotNil(regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                            "pattern for \(p.name) matches nothing even in DayKey.swift")
        }
    }
}

import XCTest
@testable import CLIPulseCore

/// The dated note that says Codex figures changed, and why.
///
/// What it must never do: show to someone who never saw the old figures, say
/// something that is not true of the build showing it, outstay its month, come
/// back after "Got it", or fall back to English. Text is asserted in zh-Hans,
/// where a broken lookup cannot pass by returning the English fallback.
final class CodexEstimateChangeNoteTests: XCTestCase {

    private var savedOverride: String?
    private var savedSystemLocale: (() -> Locale)!

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        savedSystemLocale = LocaleOverrideStore.systemLocale
        // Gregorian, whatever calendar CI runs this bundle under: these tests
        // are about the words, and the dates are only checked to be there.
        LocaleOverrideStore.systemLocale = { Locale(identifier: "en_US") }
    }

    override func tearDown() {
        LocaleOverrideStore.systemLocale = savedSystemLocale
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    private func archive(_ days: [(String, String, Int)]) -> DailyUsageArchive {
        var a = DailyUsageArchive()
        a.mergeScanEntries(days.map { day, provider, tokens in
            ScanEntry(date: day, provider: provider, model: "m", inputTokens: tokens,
                      cachedTokens: 0, outputTokens: 0, cost: 0, messages: 0)
        })
        return a
    }

    private func catalogue(_ localization: String) throws -> [String: String] {
        let bundle = try XCTUnwrap(LocaleOverrideStore.bundle(forLocalization: localization))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    // MARK: - Who sees it

    func testOnlyAMacThatHadCodexFiguresGetsTheNote() {
        let codex = CodexEstimateChangeNote.started(
            before: archive([("2026-08-01", "Codex", 10), ("2026-08-01", "Claude", 5)]), on: "2026-10-20")
        XCTAssertTrue(codex.hadCodexHistory)
        XCTAssertEqual(codex.changedOn, "2026-10-20")

        let fresh = CodexEstimateChangeNote.started(before: DailyUsageArchive(), on: "2026-10-20")
        XCTAssertFalse(fresh.hadCodexHistory, "a new install never saw the old figures")
        XCTAssertNil(fresh.presentation(todayKey: "2026-10-20", dismissed: false))

        let claudeOnly = CodexEstimateChangeNote.started(
            before: archive([("2026-08-01", "Claude", 5)]), on: "2026-10-20")
        XCTAssertFalse(claudeOnly.hadCodexHistory, "nothing about Claude changed")
        XCTAssertNil(claudeOnly.presentation(todayKey: "2026-10-20", dismissed: false))
    }

    // MARK: - How long

    func testShownForAMonthUnlessDismissed() {
        let note = CodexEstimateChangeNote(changedOn: "2026-10-20", hadCodexHistory: true)
        XCTAssertTrue(note.isVisible(todayKey: "2026-10-20", dismissed: false), "the day it changed")
        XCTAssertTrue(note.isVisible(todayKey: "2026-11-18", dismissed: false), "day 29")
        XCTAssertFalse(note.isVisible(todayKey: "2026-11-19", dismissed: false), "day 30: gone by itself")
        XCTAssertFalse(note.isVisible(todayKey: "2026-10-21", dismissed: true), "Got it is for good")
        XCTAssertFalse(note.isVisible(todayKey: "2026-10-19", dismissed: false),
                       "a clock set back would make \"since\" a day that has not come")
    }

    // MARK: - Which older days keep the old figures

    func testRecountSaysWhichOlderDaysKeepTheOldFigures() {
        var a = archive([("2026-06-01", "Codex", 10), ("2026-09-25", "Codex", 10), ("2026-09-26", "Claude", 3)])
        var note = CodexEstimateChangeNote.started(before: a, on: "2026-10-20")

        // The first routine scan after the update covers the last month.
        a.mergeScanEntries([ScanEntry(date: "2026-09-20", provider: "Codex", model: "m", inputTokens: 1,
                                      cachedTokens: 0, outputTokens: 0, cost: 0, messages: 0)])
        note.recordRecount(ofDays: ["2026-09-20", "2026-10-20", "2026-10-01"], in: a)
        XCTAssertEqual(note.recountedFrom, "2026-09-20")
        XCTAssertTrue(note.olderDaysKeepOldCount, "June still holds Codex counted the old way")

        // A later scan that starts later does not move the line forward.
        note.recordRecount(ofDays: ["2026-09-28"], in: a)
        XCTAssertEqual(note.recountedFrom, "2026-09-20")

        // The year-long read recounts everything this Mac has logs for.
        note.recordRecount(ofDays: ["2025-10-21", "2026-06-01"], in: a)
        XCTAssertEqual(note.recountedFrom, "2025-10-21")
        XCTAssertFalse(note.olderDaysKeepOldCount, "nothing older is left")
    }

    func testOlderClaudeDaysAloneDoNotCallForTheLine() {
        let a = archive([("2026-06-01", "Claude", 10), ("2026-09-25", "Codex", 10)])
        var note = CodexEstimateChangeNote.started(before: a, on: "2026-10-20")
        note.recordRecount(ofDays: ["2026-09-20"], in: a)
        XCTAssertFalse(note.olderDaysKeepOldCount, "Claude was counted the same way before")
    }

    // MARK: - What it says (zh-Hans: a broken lookup cannot pass here)

    func testTheNoteReadsInChineseWithTheDateAndTheReasonsThisBuildShips() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let note = CodexEstimateChangeNote(changedOn: "2026-10-20", hadCodexHistory: true,
                                           recountedFrom: "2026-09-20", olderDaysKeepOldCount: true)
        let p = try XCTUnwrap(note.presentation(todayKey: "2026-10-21", dismissed: false))

        XCTAssertEqual(p.title, "自2026年10月20日起，Codex 的数字有变化")
        XCTAssertEqual(p.lines.count, CodexEstimateChangeNote.Reason.shipped.count + 1)
        XCTAssertEqual(Array(p.lines.prefix(CodexEstimateChangeNote.Reason.shipped.count)),
                       CodexEstimateChangeNote.Reason.shipped.map(\.text))
        XCTAssertEqual(p.lines.last, "用量仪表盘中2026年9月20日之前的日期保留旧的数字。")
        XCTAssertEqual(p.footer, "费用是以 API 按量付费价格算出的预估值，不是真实账单。")
        XCTAssertEqual(p.dismiss, "知道了")
    }

    func testTheCachedInputLineSaysOnceAndLowerInChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let line = CodexEstimateChangeNote.Reason.cachedInputCountedOnce.text
        XCTAssertTrue(line.contains("只计一次"), line)
        XCTAssertTrue(line.contains("变少"), line)
        XCTAssertTrue(line.contains("用量仪表盘"), "names the screen where the totals are: \(line)")
    }

    func testNoHistoryLineWithoutOlderDays() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let recountedEverything = CodexEstimateChangeNote(
            changedOn: "2026-10-20", hadCodexHistory: true, recountedFrom: "2025-10-21", olderDaysKeepOldCount: false)
        let p = try XCTUnwrap(recountedEverything.presentation(todayKey: "2026-10-20", dismissed: false))
        XCTAssertEqual(p.lines, CodexEstimateChangeNote.Reason.shipped.map(\.text))

        let noScanYet = CodexEstimateChangeNote(changedOn: "2026-10-20", hadCodexHistory: true)
        XCTAssertEqual(try XCTUnwrap(noScanYet.presentation(todayKey: "2026-10-20", dismissed: false)).lines,
                       CodexEstimateChangeNote.Reason.shipped.map(\.text),
                       "no scan yet: nothing is known about older days, so nothing is said")
    }

    func testEveryReasonShowsInItsOwnOrder() throws {
        let note = CodexEstimateChangeNote(changedOn: "2026-10-20", hadCodexHistory: true)
        let all = CodexEstimateChangeNote.Reason.allCases
        let p = try XCTUnwrap(note.presentation(todayKey: "2026-10-20", dismissed: false, reasons: all))
        XCTAssertEqual(p.lines, all.map(\.text))
        XCTAssertNil(note.presentation(todayKey: "2026-10-20", dismissed: false, reasons: []),
                     "a card with no reason would say something changed without saying what")
    }

    /// Spanish, in a US region, writes the month first ("oct 20, 2026"), which
    /// reads wrong after "el". Both date lines put the date after a colon, so
    /// any region's form reads.
    func testSpanishPutsTheDateWhereAnyRegionsFormReads() throws {
        let values = try catalogue("es")
        for key in ["codex_estimate_note.title", "codex_estimate_note.history_before"] {
            let value = try XCTUnwrap(values[key], key)
            XCTAssertTrue(value.hasSuffix(": %@"), "\(key): \(value)")
        }
    }

    func testEveryLineIsTranslatedInEveryLanguage() throws {
        let english = try catalogue("en")
        let keys = english.keys.filter { $0.hasPrefix("codex_estimate_note.") }.sorted()
        XCTAssertEqual(keys.count, 5)
        for localization in LocaleOverrideStore.shippedLocalizations where localization != "en" {
            let values = try catalogue(localization)
            for key in keys {
                let value = try XCTUnwrap(values[key], "\(localization) is missing \(key)")
                XCTAssertNotEqual(value, english[key], "\(localization): \(key) is still English")
                XCTAssertTrue(value.contains("Codex") || key.hasSuffix("history_before"),
                              "\(localization): \(key) must name Codex: \(value)")
            }
        }
    }

    // MARK: - Storage

    func testRoundTripsThroughDefaults() throws {
        let suite = "codex-note-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(CodexEstimateChangeNote.load(from: defaults))
        let note = CodexEstimateChangeNote(changedOn: "2026-10-20", hadCodexHistory: true,
                                           recountedFrom: "2026-09-20", olderDaysKeepOldCount: true)
        note.save(to: defaults)
        XCTAssertEqual(CodexEstimateChangeNote.load(from: defaults), note)
        XCTAssertNotEqual(CodexEstimateChangeNote.defaultsKey, CodexEstimateChangeNote.dismissedKey,
                          "the view's Got it and the archive's bookkeeping must not overwrite each other")
    }
}

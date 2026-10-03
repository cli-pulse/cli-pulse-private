import XCTest
@testable import CLIPulseCore

/// The dated note that says Codex figures changed, and why, and the Usage
/// Dashboard's line about the days still counted the old way.
///
/// What they must never do: show to someone who never saw the old figures,
/// say something that is not true of the build showing it, outstay the card's
/// month, come back after "Got it", miss a reason that ships later, say old
/// days are gone while some remain, or fall back to English. Text is asserted
/// in zh-Hans, where a broken lookup cannot pass by returning the English
/// fallback.
final class CodexEstimateChangeNoteTests: XCTestCase {

    private typealias Note = CodexEstimateChangeNote
    private typealias Reason = CodexEstimateChangeNote.Reason

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

    private func codex(_ day: String) -> ScanEntry {
        ScanEntry(date: day, provider: "Codex", model: "m", inputTokens: 1,
                  cachedTokens: 0, outputTokens: 0, cost: 0, messages: 0)
    }

    private func claude(_ day: String, _ tokens: Int) -> ScanEntry {
        ScanEntry(date: day, provider: "Claude", model: "claude-sonnet-4-5", inputTokens: tokens,
                  cachedTokens: 0, outputTokens: 0, cost: 0, messages: 0)
    }

    private func started(_ a: DailyUsageArchive, on day: String = "2026-10-20",
                         shipped: [Reason] = Reason.shipped) throws -> Note {
        try XCTUnwrap(Note.next(after: nil, before: a, on: day, shipped: shipped))
    }

    private func catalogue(_ localization: String) throws -> [String: String] {
        let bundle = try XCTUnwrap(LocaleOverrideStore.bundle(forLocalization: localization))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    // MARK: - Who sees it

    func testOnlyAMacThatHadCodexFiguresGetsTheNote() throws {
        let codex = try started(archive([("2026-08-01", "Codex", 10), ("2026-08-01", "Claude", 5),
                                         ("2026-08-02", "Claude", 5)]))
        XCTAssertTrue(codex.hadCodexHistory)
        XCTAssertEqual(codex.changedOn, "2026-10-20")
        XCTAssertEqual(codex.reasons, Reason.shipped.map(\.rawValue))
        XCTAssertEqual(codex.oldCodexDays, ["2026-08-01"], "the Codex days, not every day")

        let fresh = try started(DailyUsageArchive())
        XCTAssertFalse(fresh.hadCodexHistory, "a new install never saw the old figures")
        XCTAssertNil(fresh.presentation(todayKey: "2026-10-20", dismissed: false))
        XCTAssertNil(fresh.dashboardLine())

        let claudeOnly = try started(archive([("2026-08-01", "Claude", 5)]))
        XCTAssertFalse(claudeOnly.hadCodexHistory, "nothing about Claude changed")
        XCTAssertNil(claudeOnly.presentation(todayKey: "2026-10-20", dismissed: false))
        XCTAssertNil(claudeOnly.dashboardLine())
    }

    func testTheStoredNoteIsKeptWhileNoNewReasonShips() throws {
        let first = try started(archive([("2026-08-01", "Codex", 10)]))
        XCTAssertNil(Note.next(after: first, before: archive([("2026-10-20", "Codex", 3)]), on: "2026-10-25"),
                     "the same reasons: the day and the old days were decided on the first write")
    }

    // MARK: - A reason that ships in a later version

    /// If a change behind a reason slips to a later version, the people who
    /// dismissed the first note, or whose month ran out, still hear about it,
    /// and nobody sees it under the first note's date.
    func testAReasonThatShipsLaterStartsANoteOfItsOwn() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let first = try started(archive([("2026-08-01", "Codex", 10)]), shipped: [.cachedInputCountedOnce])

        let later: [Reason] = [.cachedInputCountedOnce, .subagentSessionsCounted]
        let second = try XCTUnwrap(
            Note.next(after: first, before: archive([("2026-08-01", "Codex", 10), ("2026-11-20", "Codex", 5)]),
                      on: "2026-12-01", shipped: later),
            "a reason the stored note never told must start a note")
        XCTAssertEqual(second.changedOn, "2026-12-01")
        XCTAssertEqual(second.reasons, [Reason.subagentSessionsCounted.rawValue])
        XCTAssertEqual(Set(second.toldReasons), Set(later.map(\.rawValue)))
        XCTAssertNotEqual(second.id, first.id, "an earlier Got it must not hide it")
        XCTAssertEqual(second.oldCodexDays, ["2026-08-01", "2026-11-20"],
                       "every Codex day so far was counted without the new reason")

        let p = try XCTUnwrap(second.presentation(todayKey: "2026-12-01", dismissed: false, shipped: later))
        XCTAssertEqual(p.title, "自2026年12月1日起，Codex 的数字有所变化")
        XCTAssertEqual(p.lines.first, Reason.subagentSessionsCounted.text)
        XCTAssertFalse(p.lines.contains(Reason.cachedInputCountedOnce.text), "that one changed on another day")

        XCTAssertNil(Note.next(after: second, before: DailyUsageArchive(), on: "2026-12-02", shipped: later))
    }

    func testANewInstallAtTheFirstChangeHearsOfALaterOneOnceItHasCodexFigures() throws {
        let first = try started(DailyUsageArchive(), shipped: [.cachedInputCountedOnce])
        XCTAssertFalse(first.hadCodexHistory)
        let second = try XCTUnwrap(Note.next(
            after: first, before: archive([("2026-11-02", "Codex", 5)]), on: "2026-12-01",
            shipped: [.cachedInputCountedOnce, .publishedPrices]))
        XCTAssertTrue(second.hadCodexHistory, "its Codex figures were priced the old way")
    }

    // MARK: - How long the card stays

    func testShownForAMonthUnlessDismissed() {
        let note = Note(changedOn: "2026-10-20", hadCodexHistory: true)
        XCTAssertTrue(note.isVisible(todayKey: "2026-10-20", dismissed: false), "the day it changed")
        XCTAssertTrue(note.isVisible(todayKey: "2026-11-18", dismissed: false), "day 29")
        XCTAssertFalse(note.isVisible(todayKey: "2026-11-19", dismissed: false), "day 30: gone by itself")
        XCTAssertFalse(note.isVisible(todayKey: "2026-10-21", dismissed: true), "Got it is for good")
        XCTAssertFalse(note.isVisible(todayKey: "2026-10-19", dismissed: false),
                       "a clock set back would make \"since\" a day that has not come")
    }

    // MARK: - Which days keep the old figures

    func testTheDaysAWriteReplacesAreNoLongerOld() throws {
        var a = archive([("2026-06-01", "Codex", 10), ("2026-09-25", "Codex", 10), ("2026-09-26", "Claude", 3)])
        var note = try started(a)
        XCTAssertEqual(note.oldCodexDays, ["2026-06-01", "2026-09-25"])

        // The routine month after the update recounts Sep 25.
        note.recordWrite(of: a.mergeScanEntries([codex("2026-09-25"), codex("2026-10-20")]), in: a)
        XCTAssertEqual(note.oldCodexDays, ["2026-06-01"], "June was not recounted")
        XCTAssertFalse(note.newDaysAmongOld, "no Codex day up to June 1 is counted the new way")
    }

    /// A scan replaces only the days it has entries for. A stored Codex day it
    /// has none for (its log deleted, or in the App Store build a Codex folder
    /// it cannot read while the Claude one works) keeps its old figure, however
    /// far back the scan reaches.
    func testAStoredCodexDayAScanHasNoEntryForKeepsItsOldFigure() throws {
        var a = archive([("2026-06-01", "Codex", 10), ("2026-09-25", "Codex", 10)])
        var note = try started(a)

        note.recordWrite(of: a.mergeScanEntries([codex("2026-09-20"), codex("2026-10-20")]), in: a)
        XCTAssertEqual(note.oldCodexDays, ["2026-06-01", "2026-09-25"])
        XCTAssertTrue(note.newDaysAmongOld, "Sep 20 is counted the new way and lies before Sep 25")

        // A year-long read that starts before every old day, but has entries
        // for neither.
        note.recordWrite(of: a.mergeScanEntries([codex("2025-11-02")]), in: a)
        XCTAssertEqual(note.oldCodexDays, ["2026-06-01", "2026-09-25"],
                       "reaching further back recounts nothing it has no entries for")
        XCTAssertEqual(a.days["2026-09-25"]?.perProvider["Codex"]?.tokens, 10,
                       "control: the archive still holds the old figure")
        XCTAssertNotNil(note.dashboardLine())
    }

    /// Where a read merges a day provider by provider (the year-long read, and
    /// the routine read's oldest day), a day it has entries for but no Codex
    /// entries keeps its stored Codex slice, and with it the old figure. Only
    /// a day whose Codex share came from the read is counted the new way.
    func testADayMergedByProviderWithoutCodexEntriesKeepsItsOldCodexFigure() throws {
        var a = archive([("2026-06-01", "Codex", 10), ("2026-06-01", "Claude", 3), ("2026-06-02", "Codex", 10)])
        var note = try started(a)
        XCTAssertEqual(note.oldCodexDays, ["2026-06-01", "2026-06-02"])

        let codexFromRead = a.mergeScanEntriesByProvider([claude("2026-06-01", 30), codex("2026-06-02")])
        XCTAssertEqual(a.days["2026-06-01"]?.perProvider["Claude"]?.tokens, 30, "control: the read wrote June 1")
        XCTAssertEqual(a.days["2026-06-01"]?.perProvider["Codex"]?.tokens, 10,
                       "control: and June 1 kept its stored Codex slice")
        XCTAssertEqual(codexFromRead, ["2026-06-02"])

        note.recordWrite(of: codexFromRead, in: a)
        XCTAssertEqual(note.oldCodexDays, ["2026-06-01"], "June 2's Codex share came from the read; June 1's did not")
        XCTAssertNotNil(note.dashboardLine())
    }

    /// The routine read merges provider by provider only up to Claude Code's
    /// cleanup reach, and replaces later days whole. A Claude-only read (the
    /// App Store build with the Codex folder unreadable) leaves the reach's
    /// stored Codex slice, so that day stays old; the day after loses its
    /// Codex share with the rest of the day, so it holds no old figure.
    func testTheRoutineReadsOldestDayKeepsItsOldCodexFigureWithoutCodexEntries() throws {
        var a = archive([("2026-09-20", "Codex", 10), ("2026-09-20", "Claude", 3),
                         ("2026-09-21", "Codex", 10), ("2026-09-21", "Claude", 3)])
        var note = try started(a)

        let codexFromRead = a.mergeScanEntries([claude("2026-09-20", 30), claude("2026-09-21", 30)],
                                               claudeCleanupReach: "2026-09-20")
        XCTAssertEqual(a.days["2026-09-20"]?.perProvider["Codex"]?.tokens, 10, "control: merged by provider")
        XCTAssertNil(a.days["2026-09-21"]?.perProvider["Codex"], "control: replaced whole")
        XCTAssertEqual(codexFromRead, ["2026-09-21"])

        note.recordWrite(of: codexFromRead, in: a)
        XCTAssertEqual(note.oldCodexDays, ["2026-09-20"])
        XCTAssertFalse(note.newDaysAmongOld)
    }

    func testOldClaudeDaysDoNotCount() throws {
        var a = archive([("2026-06-01", "Claude", 10), ("2026-09-25", "Codex", 10)])
        var note = try started(a)
        XCTAssertEqual(note.oldCodexDays, ["2026-09-25"], "Claude was counted the same way before")
        note.recordWrite(of: a.mergeScanEntries([codex("2026-09-25")]), in: a)
        XCTAssertEqual(note.oldCodexDays, [])
        XCTAssertNil(note.dashboardLine())
    }

    func testACodexDayFilledFromTheCloudAmongOldOnesMakesItSome() throws {
        var a = archive([("2026-06-01", "Codex", 10), ("2026-06-10", "Codex", 10)])
        var note = try started(a)
        let filled = a.mergeCloudDays([CloudEntry(date: "2026-06-05", provider: "Codex", model: "m",
                                                  inputTokens: 5, cachedTokens: 0, outputTokens: 0, cost: 0)])
        XCTAssertEqual(filled, ["2026-06-05"])
        note.recordWrite(of: filled, in: a)
        XCTAssertEqual(note.oldCodexDays, ["2026-06-01", "2026-06-10"])
        XCTAssertTrue(note.newDaysAmongOld, "Jun 5 came in counted the new way")
    }

    /// Folded into a month's total, an old day's figure is still there, still
    /// counted the old way, in the lifetime totals.
    func testAnOldDayFoldedIntoItsMonthStaysOld() throws {
        var a = archive([("2026-06-01", "Codex", 10), ("2026-06-02", "Codex", 10), ("2026-06-03", "Codex", 10)])
        var note = try started(a)
        note.recordWrite(of: a.mergeScanEntries([codex("2026-10-20")], retainDays: 3), in: a)
        XCTAssertNil(a.days["2026-06-01"], "control: June 1 was folded into June")
        XCTAssertEqual(note.oldCodexDays, ["2026-06-01", "2026-06-02", "2026-06-03"])
    }

    // MARK: - The dashboard's line

    /// The card goes after a month or "Got it"; the old days do not. The line
    /// stays for as long as any remain, and says which.
    func testTheDashboardLineOutlastsTheCard() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let note = Note(changedOn: "2026-10-20", hadCodexHistory: true,
                        oldCodexDays: ["2026-09-19", "2026-06-01"])
        XCTAssertNil(note.presentation(todayKey: "2026-12-01", dismissed: false), "control: the month is over")
        XCTAssertNil(note.presentation(todayKey: "2026-10-21", dismissed: true), "control: dismissed")

        XCTAssertEqual(note.dashboardLine(),
                       "2026年9月19日及之前各天的 Codex 数字由旧版本计算，无法与之后各天直接比较。")
        var some = note
        some.newDaysAmongOld = true
        XCTAssertEqual(some.dashboardLine(),
                       "2026年9月19日及之前部分日子的 Codex 数字由旧版本计算，无法与之后各天直接比较。")

        var recounted = note
        recounted.oldCodexDays = []
        XCTAssertNil(recounted.dashboardLine(), "nothing old is left, so nothing is said")
        XCTAssertNil(note.dashboardLine(shipped: []), "no reason shipped: nothing changed")
    }

    // MARK: - What the card says (zh-Hans: a broken lookup cannot pass here)

    func testTheNoteReadsInChineseWithTheDateAndTheReasonsThisBuildShips() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let note = Note(changedOn: "2026-10-20", hadCodexHistory: true, oldCodexDays: ["2026-09-19"])
        let p = try XCTUnwrap(note.presentation(todayKey: "2026-10-21", dismissed: false))

        XCTAssertEqual(p.title, "自2026年10月20日起，Codex 的数字有所变化")
        let reasonLines = Reason.shipped.flatMap(\.lines)
        XCTAssertEqual(p.lines.count, reasonLines.count + 1)
        XCTAssertEqual(Array(p.lines.prefix(reasonLines.count)), reasonLines)
        XCTAssertEqual(p.lines.last, "用量仪表盘中，2026年9月19日及之前各天的 Codex 数字仍按旧方式计算。")
        XCTAssertEqual(p.footer, "费用是以 API 按量付费价格算出的预估值，不是真实账单。")
        XCTAssertEqual(p.dismiss, "知道了")

        var some = note
        some.newDaysAmongOld = true
        XCTAssertEqual(some.presentation(todayKey: "2026-10-21", dismissed: false)?.lines.last,
                       "用量仪表盘中，2026年9月19日及之前部分日子的 Codex 数字仍按旧方式计算。")
    }

    /// The subagent line is followed by what is still counted by simplified
    /// rules, and only that line has such a follow-up.
    func testTheSubagentLineIsFollowedByWhatItLeavesOutInChinese() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(Reason.subagentSessionsCounted.lines, [
            "Codex 的子 Agent 会话现在也会计入。之前它们被漏掉了，所以 Codex 的用量和费用会变高。",
            "从另一个会话分叉出来的 Codex 会话，以及部分 Codex 版本写下的子 Agent 会话，按简化规则计算，所以从原会话复制过来的请求可能会被再计一次。",
        ])
        XCTAssertNil(Reason.cachedInputCountedOnce.caveat)
        XCTAssertNil(Reason.publishedPrices.caveat)
        let note = Note(changedOn: "2026-10-20", hadCodexHistory: true, reasons: [.subagentSessionsCounted, .publishedPrices])
        let p = try XCTUnwrap(note.presentation(todayKey: "2026-10-20", dismissed: false))
        XCTAssertEqual(p.lines, [Reason.subagentSessionsCounted.text, Reason.subagentSessionsCounted.caveat!,
                                 Reason.publishedPrices.text], "the caveat sits right after its own reason")
    }

    func testTheCachedInputLineSaysOnceAndLowerInChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let line = Reason.cachedInputCountedOnce.text
        XCTAssertTrue(line.contains("只计一次"), line)
        XCTAssertTrue(line.contains("变少"), line)
        XCTAssertTrue(line.contains("用量仪表盘"), "names the screen where the totals are: \(line)")
    }

    func testNoHistoryLineWithoutOldDays() throws {
        let recountedEverything = Note(changedOn: "2026-10-20", hadCodexHistory: true, oldCodexDays: [])
        let p = try XCTUnwrap(recountedEverything.presentation(todayKey: "2026-10-20", dismissed: false))
        XCTAssertEqual(p.lines, Reason.shipped.flatMap(\.lines))
    }

    func testEveryReasonShowsInItsOwnOrder() throws {
        let all = Reason.allCases
        let note = Note(changedOn: "2026-10-20", hadCodexHistory: true, reasons: all)
        let p = try XCTUnwrap(note.presentation(todayKey: "2026-10-20", dismissed: false, shipped: all))
        XCTAssertEqual(p.lines, all.flatMap(\.lines))
        XCTAssertNil(note.presentation(todayKey: "2026-10-20", dismissed: false, shipped: []),
                     "a card with no reason would say something changed without saying what")

        let notShipped = Note(changedOn: "2026-10-20", hadCodexHistory: true, reasons: [.publishedPrices])
        XCTAssertNil(notShipped.presentation(todayKey: "2026-10-20", dismissed: false,
                                             shipped: [.cachedInputCountedOnce]),
                     "a line is shown only for a reason the build ships")
    }

    /// Spanish, in a US region, writes the month first ("oct 20, 2026"), which
    /// reads wrong after "el". Every dated line puts the date after a colon, so
    /// any region's form reads.
    func testSpanishPutsTheDateWhereAnyRegionsFormReads() throws {
        let values = try catalogue("es")
        for key in ["title", "history_through", "history_some_through", "dashboard_through", "dashboard_some_through"] {
            let value = try XCTUnwrap(values["codex_estimate_note." + key], key)
            XCTAssertTrue(value.hasSuffix(": %@"), "\(key): \(value)")
        }
    }

    func testEveryLineIsTranslatedInEveryLanguage() throws {
        let english = try catalogue("en")
        let keys = english.keys.filter { $0.hasPrefix("codex_estimate_note.") }.sorted()
        XCTAssertEqual(keys.count, 9)
        for localization in LocaleOverrideStore.shippedLocalizations where localization != "en" {
            let values = try catalogue(localization)
            for key in keys {
                let value = try XCTUnwrap(values[key], "\(localization) is missing \(key)")
                XCTAssertNotEqual(value, english[key], "\(localization): \(key) is still English")
                XCTAssertTrue(value.contains("Codex"), "\(localization): \(key) must name Codex: \(value)")
            }
        }
    }

    // MARK: - Storage

    func testRoundTripsThroughDefaults() throws {
        let suite = "codex-note-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(Note.load(from: defaults))
        let note = Note(changedOn: "2026-10-20", hadCodexHistory: true, reasons: [.cachedInputCountedOnce],
                        toldReasons: [.cachedInputCountedOnce, .publishedPrices],
                        oldCodexDays: ["2026-09-19", "2026-06-01"], newDaysAmongOld: true)
        XCTAssertEqual(note.oldCodexDays, ["2026-06-01", "2026-09-19"], "kept in order")
        note.save(to: defaults)
        XCTAssertEqual(Note.load(from: defaults), note)
        XCTAssertNotEqual(Note.defaultsKey, Note.dismissedKey,
                          "the view's Got it and the archive's bookkeeping must not overwrite each other")
    }
}

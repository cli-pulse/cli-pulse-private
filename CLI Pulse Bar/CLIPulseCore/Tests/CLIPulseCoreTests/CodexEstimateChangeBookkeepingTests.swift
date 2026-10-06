// The archive manager decides, before the first write, whether this Mac gets
// the note that Codex figures changed, and keeps its list of days still counted
// the old way true afterwards. macOS-gated: the manager is macOS-only.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CodexEstimateChangeBookkeepingTests: XCTestCase {

    private typealias Note = CodexEstimateChangeNote
    private typealias Reason = CodexEstimateChangeNote.Reason

    private var root: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-note-\(UUID().uuidString)", isDirectory: true)
        suite = "codex-note-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// Noon on `key` in this Mac's zone, so the manager's "today" is `key`.
    private func noon(_ key: String) -> Date {
        DayKey.date(from: key, hour: 12)!
    }

    /// `yearLongRead` is what the year-long read finds: Codex days this Mac
    /// still has logs for.
    private func manager(
        today key: String,
        reasons: [Reason] = Reason.shipped,
        yearLongRead: [String] = ["2025-11-02"]
    ) -> DailyUsageArchiveManager {
        let date = noon(key)
        let found = yearLongRead
        return DailyUsageArchiveManager(
            root: root, defaults: defaults, now: { date }, codexNoteReasons: reasons,
            backfillScan: { _ in
                CostUsageScanResult(entries: found.map {
                    .init(date: $0, provider: "Codex", model: "gpt-5",
                          inputTokens: 40, cachedTokens: 30, outputTokens: 2, costUSD: 0.02)
                })
            })
    }

    /// What the previous version left on disk: days counted the old way.
    private func previousVersionLeft(_ days: [(String, String)]) {
        var a = DailyUsageArchive()
        a.mergeScanEntries(days.map { day, provider in
            ScanEntry(date: day, provider: provider, model: "m", inputTokens: 1_000,
                      cachedTokens: 800, outputTokens: 50, cost: 1, messages: 0)
        })
        XCTAssertTrue(DailyUsageArchiveIO.save(a, root: root))
    }

    private func scan(_ days: [String], provider: String = "Codex") -> CostUsageScanResult {
        CostUsageScanResult(entries: days.map {
            .init(date: $0, provider: provider, model: "gpt-5.5",
                  inputTokens: 1_000, cachedTokens: 800, outputTokens: 50, costUSD: 1)
        })
    }

    private var note: Note? { Note.load(from: defaults) }

    // MARK: - Who gets it

    func testAnUpdatedMacWithCodexHistoryGetsADatedNote() async throws {
        previousVersionLeft([("2026-06-01", "Codex"), ("2026-09-25", "Codex")])

        await manager(today: "2026-10-20").record(scan(["2026-09-25", "2026-10-20"]))

        let n = try XCTUnwrap(note)
        XCTAssertEqual(n.changedOn, "2026-10-20")
        XCTAssertTrue(n.hadCodexHistory)
        XCTAssertEqual(n.oldCodexDays, ["2026-06-01"], "Sep 25 was recounted; June was not")
        XCTAssertFalse(n.newDaysAmongOld)
        XCTAssertNotNil(n.presentation(todayKey: "2026-10-20", dismissed: false))
        XCTAssertNotNil(n.dashboardLine())
    }

    func testANewInstallGetsNoNote() async throws {
        await manager(today: "2026-10-20").record(scan(["2026-10-20"]))
        let n = try XCTUnwrap(note, "decided once, so it is not asked again later")
        XCTAssertFalse(n.hadCodexHistory)
        XCTAssertNil(n.presentation(todayKey: "2026-10-20", dismissed: false))
        XCTAssertNil(n.dashboardLine())
    }

    func testAMacThatOnlyEverHadClaudeGetsNoNote() async throws {
        previousVersionLeft([("2026-09-25", "Claude")])
        await manager(today: "2026-10-20").record(scan(["2026-10-20"]))
        XCTAssertEqual(note?.hadCodexHistory, false)
        XCTAssertNil(note?.dashboardLine())
    }

    /// Decided before the first write, whichever path writes first: a cloud
    /// fill that brings Codex days must not make a new install look updated.
    func testTheDecisionIsMadeBeforeTheFirstWriteAndOnlyOnce() async throws {
        await manager(today: "2026-10-20").mergeCloud([
            DailyUsage(date: "2026-09-01", provider: "Codex", model: "gpt-5.5",
                       inputTokens: 1_000, cachedTokens: 800, outputTokens: 50, cost: 1),
        ])
        await manager(today: "2026-10-22").record(scan(["2026-10-22"]))

        let n = try XCTUnwrap(note)
        XCTAssertFalse(n.hadCodexHistory, "the archive was empty before this version wrote to it")
        XCTAssertEqual(n.changedOn, "2026-10-20", "the first write set the day; later ones do not move it")
    }

    // MARK: - The days that keep the old figures

    /// Every Mac that used the year-long read before 1.55 has it marked done,
    /// and it does not run again. Its Codex days older than the routine month
    /// keep the old figures, and the dashboard keeps saying so after the card
    /// is gone.
    func testAMacWhoseYearLongReadAlreadyRanKeepsItsOlderDaysOld() async throws {
        defaults.set(true, forKey: DailyUsageArchiveManager.defaultBackfillKey)
        previousVersionLeft([("2026-06-01", "Codex"), ("2026-09-25", "Codex")])
        let m = manager(today: "2026-10-20", yearLongRead: ["2026-06-01"])
        await m.record(scan(["2026-09-25", "2026-10-20"]))
        await m.runBackfillIfNeeded(historyReadAllowed: true)

        let snapshot = await m.snapshot()
        XCTAssertEqual(snapshot.days["2026-06-01"]?.tokens, 1_850, "control: the read did not run again")
        XCTAssertEqual(note?.oldCodexDays, ["2026-06-01"])

        // Six weeks on: the card's month is over, the old day is not.
        await manager(today: "2026-12-01").record(scan(["2026-12-01"]))
        let n = try XCTUnwrap(note)
        XCTAssertNil(n.presentation(todayKey: "2026-12-01", dismissed: false))
        XCTAssertNotNil(n.dashboardLine(), "June still holds a figure counted the old way")
    }

    /// Only the days a read has entries for are recounted. A read that starts
    /// a year back, but finds nothing for June or Sep 25, leaves both old.
    func testTheYearLongReadRecountsOnlyTheDaysItHasEntriesFor() async throws {
        previousVersionLeft([("2026-06-01", "Codex"), ("2026-09-25", "Codex")])
        let m = manager(today: "2026-10-20", yearLongRead: ["2025-11-02"])
        await m.record(scan(["2026-09-20"]))
        XCTAssertEqual(note?.oldCodexDays, ["2026-06-01", "2026-09-25"])
        XCTAssertEqual(note?.newDaysAmongOld, true, "Sep 20 is counted the new way, before Sep 25")

        await m.runBackfillIfNeeded(historyReadAllowed: true)
        let snapshot = await m.snapshot()
        XCTAssertNotNil(snapshot.days["2025-11-02"], "control: the read ran")
        XCTAssertEqual(snapshot.days["2026-09-25"]?.tokens, 1_850, "control: Sep 25 still holds the old figure")
        XCTAssertEqual(note?.oldCodexDays, ["2026-06-01", "2026-09-25"])
        XCTAssertNotNil(note?.dashboardLine())
    }

    /// The year-long read merges each stored day provider by provider. On a
    /// day where it finds Claude but no Codex, the day keeps its stored Codex
    /// slice, so it still holds the old Codex figure even though the read
    /// wrote it.
    func testAYearLongReadThatFindsNoCodexOnADayLeavesItsCodexFigureOld() async throws {
        previousVersionLeft([("2026-06-01", "Codex"), ("2026-06-01", "Claude"), ("2026-06-02", "Codex")])
        let date = noon("2026-10-20")
        let m = DailyUsageArchiveManager(
            root: root, defaults: defaults, now: { date },
            backfillScan: { _ in
                CostUsageScanResult(entries: [
                    .init(date: "2026-06-01", provider: "Claude", model: "claude-sonnet-4-5",
                          inputTokens: 3_000, cachedTokens: 0, outputTokens: 10, costUSD: 0.05),
                    .init(date: "2026-06-02", provider: "Codex", model: "gpt-5",
                          inputTokens: 40, cachedTokens: 30, outputTokens: 2, costUSD: 0.02),
                ])
            })
        await m.record(scan(["2026-10-20"]))
        XCTAssertEqual(note?.oldCodexDays, ["2026-06-01", "2026-06-02"])

        await m.runBackfillIfNeeded(historyReadAllowed: true)
        let june1 = await m.snapshot().days["2026-06-01"]
        XCTAssertEqual(june1?.perProvider["Claude"]?.tokens, 3_010, "control: the read wrote June 1")
        XCTAssertEqual(june1?.perProvider["Codex"]?.tokens, 1_850, "control: June 1 kept the old Codex figure")
        XCTAssertEqual(note?.oldCodexDays, ["2026-06-01"], "June 2 was recounted for Codex; June 1 was not")
        XCTAssertNotNil(note?.dashboardLine())
    }

    func testAYearLongReadThatReachesEveryOldDayClearsTheLine() async throws {
        previousVersionLeft([("2025-11-02", "Codex"), ("2026-06-01", "Codex")])
        let m = manager(today: "2026-10-20", yearLongRead: ["2025-11-02", "2026-06-01"])
        await m.record(scan(["2026-10-20"]))
        XCTAssertEqual(note?.oldCodexDays, ["2025-11-02", "2026-06-01"])

        await m.runBackfillIfNeeded(historyReadAllowed: true)
        let n = try XCTUnwrap(note)
        XCTAssertEqual(n.oldCodexDays, [])
        XCTAssertNil(n.dashboardLine())
        XCTAssertEqual(n.presentation(todayKey: "2026-10-20", dismissed: false)?.lines,
                       n.shownReasons().flatMap(\.lines), "no line about old days")
    }

    /// The App Store build reads each folder through its own bookmark. With the
    /// Claude one working and the Codex one not, scans carry Claude rows only:
    /// a day they replace loses its Codex share, and a Codex-only day keeps its
    /// old figure.
    func testScansWithoutCodexRowsLeaveCodexOnlyDaysOld() async throws {
        previousVersionLeft([("2026-09-25", "Codex"), ("2026-09-26", "Codex"), ("2026-09-26", "Claude")])
        await manager(today: "2026-10-20").record(scan(["2026-09-26", "2026-10-20"], provider: "Claude"))
        XCTAssertEqual(note?.oldCodexDays, ["2026-09-25"])
        XCTAssertEqual(note?.newDaysAmongOld, false, "no Codex day up to Sep 25 is counted the new way")
    }

    /// `record` without a `now` takes Claude Code's cleanup reach from the
    /// manager's clock, the one the note is dated by. On that day a read with
    /// Claude rows only (the App Store build with the Codex folder unreadable)
    /// merges provider by provider, so the stored Codex slice, and its old
    /// figure, stay.
    func testRecordTakesTheCleanupReachFromTheManagersClock() async throws {
        XCTAssertEqual(DailyUsageArchive.claudeCleanupReach(now: noon("2026-10-20")), "2026-09-20", "control")
        previousVersionLeft([("2026-09-20", "Codex"), ("2026-09-20", "Claude")])
        let m = manager(today: "2026-10-20")
        await m.record(scan(["2026-09-20"], provider: "Claude"))

        let day = await m.snapshot().days["2026-09-20"]
        XCTAssertEqual(day?.perProvider["Codex"]?.tokens, 1_850, "merged provider by provider on the reach")
        XCTAssertEqual(note?.oldCodexDays, ["2026-09-20"])
    }

    // MARK: - A reason that ships in a later version

    func testAReasonThatShipsLaterStartsANoteEvenAfterGotIt() async throws {
        previousVersionLeft([("2026-06-01", "Codex")])
        await manager(today: "2026-10-20", reasons: [.cachedInputCountedOnce]).record(scan(["2026-10-20"]))
        let first = try XCTUnwrap(note)
        defaults.set(first.id, forKey: Note.dismissedKey)   // the user's "Got it"

        let later: [Reason] = [.cachedInputCountedOnce, .subagentSessionsCounted]
        await manager(today: "2026-12-01", reasons: later).record(scan(["2026-12-01"]))
        let second = try XCTUnwrap(note)
        XCTAssertEqual(second.changedOn, "2026-12-01")
        XCTAssertEqual(second.reasons, [Reason.subagentSessionsCounted.rawValue])
        XCTAssertTrue(second.hadCodexHistory)
        let dismissed = defaults.string(forKey: Note.dismissedKey) == second.id
        XCTAssertFalse(dismissed, "the first note's Got it does not hide the second")
        XCTAssertNotNil(second.presentation(todayKey: "2026-12-01", dismissed: dismissed, shipped: later))

        await manager(today: "2026-12-03", reasons: later).record(scan(["2026-12-03"]))
        XCTAssertEqual(note?.id, second.id, "the same reasons do not start a third")
    }

    func testTheManagerNeverTouchesTheUsersGotIt() async {
        previousVersionLeft([("2026-09-25", "Codex")])
        defaults.set("a-note", forKey: Note.dismissedKey)
        let m = manager(today: "2026-10-20")
        await m.record(scan(["2026-09-20"]))
        await m.record(scan(["2026-10-20"]))
        XCTAssertEqual(defaults.string(forKey: Note.dismissedKey), "a-note")
    }
}
#endif

// The archive manager decides, once, whether this Mac gets the note that
// Codex figures changed, and keeps its "older days" line true afterwards.
// macOS-gated: the manager is macOS-only.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CodexEstimateChangeBookkeepingTests: XCTestCase {

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

    private func manager(today key: String) -> DailyUsageArchiveManager {
        let date = noon(key)
        return DailyUsageArchiveManager(
            root: root, defaults: defaults, now: { date },
            backfillScan: { _ in
                CostUsageScanResult(entries: [
                    .init(date: "2025-11-02", provider: "Codex", model: "gpt-5",
                          inputTokens: 40, cachedTokens: 30, outputTokens: 2, costUSD: 0.02),
                ])
            })
    }

    /// What the previous version left on disk: Codex days counted the old way.
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

    private var note: CodexEstimateChangeNote? { CodexEstimateChangeNote.load(from: defaults) }

    // MARK: -

    func testAnUpdatedMacWithCodexHistoryGetsADatedNote() async throws {
        previousVersionLeft([("2026-06-01", "Codex"), ("2026-09-25", "Codex")])

        await manager(today: "2026-10-20").record(scan(["2026-09-20", "2026-10-20"]))

        let n = try XCTUnwrap(note)
        XCTAssertEqual(n.changedOn, "2026-10-20")
        XCTAssertTrue(n.hadCodexHistory)
        XCTAssertEqual(n.recountedFrom, "2026-09-20")
        XCTAssertTrue(n.olderDaysKeepOldCount, "June was not recounted")
        XCTAssertNotNil(n.presentation(todayKey: "2026-10-20", dismissed: false))
    }

    func testANewInstallGetsNoNote() async throws {
        await manager(today: "2026-10-20").record(scan(["2026-10-20"]))
        let n = try XCTUnwrap(note, "decided once, so it is not asked again later")
        XCTAssertFalse(n.hadCodexHistory)
        XCTAssertNil(n.presentation(todayKey: "2026-10-20", dismissed: false))
    }

    func testAMacThatOnlyEverHadClaudeGetsNoNote() async throws {
        previousVersionLeft([("2026-09-25", "Claude")])
        await manager(today: "2026-10-20").record(scan(["2026-10-20"]))
        XCTAssertEqual(note?.hadCodexHistory, false)
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

    func testTheYearLongReadRecountsTheOlderDays() async throws {
        previousVersionLeft([("2026-06-01", "Codex"), ("2026-09-25", "Codex")])
        let m = manager(today: "2026-10-20")
        await m.record(scan(["2026-09-20"]))
        XCTAssertEqual(note?.olderDaysKeepOldCount, true)

        await m.runBackfillIfNeeded(historyReadAllowed: true)
        // The year-long read starts a year back, so the line moves to its
        // first day, and no Codex day older than that is left.
        XCTAssertEqual(note?.recountedFrom, "2025-11-02")
        XCTAssertEqual(note?.olderDaysKeepOldCount, false)
    }

    func testTheManagerNeverTouchesTheUsersGotIt() async {
        previousVersionLeft([("2026-09-25", "Codex")])
        defaults.set(true, forKey: CodexEstimateChangeNote.dismissedKey)
        let m = manager(today: "2026-10-20")
        await m.record(scan(["2026-09-20"]))
        await m.record(scan(["2026-10-20"]))
        XCTAssertTrue(defaults.bool(forKey: CodexEstimateChangeNote.dismissedKey))
    }
}
#endif

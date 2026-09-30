// Unit tests for the v1.40 PR-4 DailyUsageArchiveManager glue: correct mapping
// of CostUsageScanResult → archive (incl. __claude_msg__ handling) with an
// injected temp root + isolated UserDefaults, persistence, and the cloud
// __claude_msg__ filter. macOS-gated (manager is macOS-only).

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class DailyUsageArchiveManagerTests: XCTestCase {

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dua-mgr-\(UUID().uuidString)", isDirectory: true)
    }

    func test_record_maps_scanResult_and_persists() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "dua-\(UUID().uuidString)")!
        let mgr = DailyUsageArchiveManager(root: root, defaults: defaults)

        let scan = CostUsageScanResult(entries: [
            .init(date: "2026-07-01", provider: "Claude", model: "claude-sonnet-4-5",
                  inputTokens: 100, cachedTokens: 0, outputTokens: 50, costUSD: 0.30, messageCount: 0),
            .init(date: "2026-07-01", provider: "Claude", model: "__claude_msg__",
                  inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 0, messageCount: 7),
            .init(date: "2026-07-01", provider: "Codex", model: "gpt-5",
                  inputTokens: 200, cachedTokens: 0, outputTokens: 20, costUSD: 0.10, messageCount: 0),
        ])
        await mgr.record(scan)

        let a = await mgr.snapshot()
        XCTAssertEqual(a.days["2026-07-01"]?.tokens, 370)
        XCTAssertEqual(a.days["2026-07-01"]?.messages, 7)
        XCTAssertNil(a.days["2026-07-01"]?.perModel["__claude_msg__"])
        XCTAssertGreaterThan(a.lastUpdatedUnixMs, 0)

        // Persisted to the injected root.
        let reloaded = DailyUsageArchiveIO.load(root: root)
        XCTAssertEqual(reloaded.days["2026-07-01"]?.tokens, 370)
    }

    func test_record_empty_scan_is_noop() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = DailyUsageArchiveManager(root: root, defaults: UserDefaults(suiteName: "dua-\(UUID().uuidString)")!)
        await mgr.record(CostUsageScanResult(entries: []))
        let a = await mgr.snapshot()
        XCTAssertTrue(a.days.isEmpty)
    }

    func test_mergeCloud_filters_msgBucket() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = DailyUsageArchiveManager(root: root, defaults: UserDefaults(suiteName: "dua-\(UUID().uuidString)")!)
        await mgr.mergeCloud([
            DailyUsage(date: "2026-06-01", provider: "Claude", model: "__claude_msg__",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 0),
            DailyUsage(date: "2026-06-01", provider: "Codex", model: "gpt-5",
                       inputTokens: 50, cachedTokens: 0, outputTokens: 0, cost: 0.5),
        ])
        let a = await mgr.snapshot()
        XCTAssertNil(a.days["2026-06-01"]?.perModel["__claude_msg__"])
        XCTAssertEqual(a.days["2026-06-01"]?.perModel["gpt-5"]?.tokens, 50)
    }

    // MARK: - v1.55: the one-year backfill waits for disclosure v2

    /// Counts the backfill's scans and the window each asked for. It stands in
    /// for `CostUsageScanner`, so these tests never walk the real `~/.codex`
    /// and `~/.claude` of whoever runs them.
    private actor BackfillScanSpy {
        private(set) var windows: [Int] = []
        func scanned(_ days: Int) { windows.append(days) }
    }

    private func backfillManager(
        root: URL, defaults: UserDefaults, spy: BackfillScanSpy
    ) -> DailyUsageArchiveManager {
        DailyUsageArchiveManager(
            root: root, defaults: defaults, backfillKey: "backfilled",
            backfillScan: { options in
                await spy.scanned(options.daysToScan)
                return CostUsageScanResult(entries: [
                    .init(date: "2025-11-02", provider: "Codex", model: "gpt-5",
                          inputTokens: 40, cachedTokens: 0, outputTokens: 2,
                          costUSD: 0.02, messageCount: 0),
                ])
            })
    }

    /// The one-year backfill waits for the v2 answer: without a v2 yes, it
    /// does not run — no scan, nothing merged — and the refusal is not
    /// recorded as "done", or a later yes would find nothing left to do.
    func test_backfill_does_not_run_without_v2_consent() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "dua-\(UUID().uuidString)")!
        let spy = BackfillScanSpy()
        let mgr = backfillManager(root: root, defaults: defaults, spy: spy)

        await mgr.runBackfillIfNeeded(historyReadAllowed: false)

        let windows = await spy.windows
        XCTAssertEqual(windows, [], "the one-year read ran without an answer to v2")
        XCTAssertFalse(defaults.bool(forKey: "backfilled"),
                       "a refusal was recorded as a finished backfill")
        let a = await mgr.snapshot()
        XCTAssertTrue(a.days.isEmpty)
    }

    /// The other half, so the test above cannot pass on a backfill that never
    /// runs: after a yes it runs, over the window the disclosure names, once.
    func test_backfill_runs_once_after_v2_consent_even_after_a_refusal() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "dua-\(UUID().uuidString)")!
        let spy = BackfillScanSpy()
        let mgr = backfillManager(root: root, defaults: defaults, spy: spy)

        await mgr.runBackfillIfNeeded(historyReadAllowed: false)
        await mgr.runBackfillIfNeeded(historyReadAllowed: true)
        await mgr.runBackfillIfNeeded(historyReadAllowed: true)

        let windows = await spy.windows
        XCTAssertEqual(windows, [LocalScanDisclosure.historyWindowDays])
        XCTAssertTrue(defaults.bool(forKey: "backfilled"))
        let a = await mgr.snapshot()
        XCTAssertEqual(a.days["2025-11-02"]?.tokens, 42)
    }

    /// "Last 30 days only" deletes nothing. History an earlier yes (or a
    /// version before 1.55) already built stays, through a refused history read
    /// and through the routine 30-day scans that follow it; the consent screen
    /// and the Settings switch both say so.
    func test_refusing_the_history_read_keeps_history_already_built() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "dua-\(UUID().uuidString)")!
        let old = DayKey.string(from: Date().addingTimeInterval(-200 * 86_400))
        let recent = DayKey.string(from: Date().addingTimeInterval(-2 * 86_400))
        let spy = BackfillScanSpy()
        let mgr = DailyUsageArchiveManager(
            root: root, defaults: defaults, backfillKey: "backfilled",
            backfillScan: { options in
                await spy.scanned(options.daysToScan)
                return CostUsageScanResult(entries: [
                    .init(date: old, provider: "Codex", model: "gpt-5",
                          inputTokens: 40, cachedTokens: 0, outputTokens: 2,
                          costUSD: 0.02, messageCount: 0),
                ])
            })

        // Built while the history read was allowed.
        await mgr.runBackfillIfNeeded(historyReadAllowed: true)
        // Then "Last 30 days only": refused from here on, and routine scans.
        await mgr.runBackfillIfNeeded(historyReadAllowed: false)
        await mgr.record(CostUsageScanResult(entries: [
            .init(date: recent, provider: "Claude", model: "claude-sonnet-4-5",
                  inputTokens: 10, cachedTokens: 0, outputTokens: 5,
                  costUSD: 0.01, messageCount: 0),
        ]))

        let a = await mgr.snapshot()
        XCTAssertEqual(a.days[old]?.tokens, 42, "history already built was dropped")
        XCTAssertEqual(a.days[recent]?.tokens, 15)
        XCTAssertEqual(DailyUsageArchiveIO.load(root: root).days[old]?.tokens, 42,
                       "history already built is gone from disk")
        let windows = await spy.windows
        XCTAssertEqual(windows, [LocalScanDisclosure.historyWindowDays], "read again after the refusal")
    }

    // MARK: - v1.55: a yes that comes after months of "Last 30 days only"

    private static func claudeRows(_ date: String) -> [CostUsageScanResult.DailyEntry] {
        [.init(date: date, provider: "Claude", model: "claude-sonnet-4-5",
               inputTokens: 100, cachedTokens: 0, outputTokens: 50, costUSD: 0.30, messageCount: 0),
         .init(date: date, provider: "Claude", model: "__claude_msg__",
               inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 0, messageCount: 7)]
    }

    private static func codexRows(_ date: String, input: Int) -> [CostUsageScanResult.DailyEntry] {
        [.init(date: date, provider: "Codex", model: "gpt-5",
               inputTokens: input, cachedTokens: 0, outputTokens: 20, costUSD: 0.10, messageCount: 0)]
    }

    /// The routine reads stored a day with both providers while only the last
    /// 30 days were allowed. Months later the user allows older history, and
    /// the year-long read finds only what is left of that day's logs.
    private func historyReadAfterThirtyDaysOnly(
        finds found: @escaping @Sendable (String) -> [CostUsageScanResult.DailyEntry]
    ) async -> (archive: DailyUsageArchive, onDisk: DailyUsageArchive, day: String) {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "dua-\(UUID().uuidString)")!
        let day = DayKey.string(from: Date().addingTimeInterval(-200 * 86_400))
        let mgr = DailyUsageArchiveManager(
            root: root, defaults: defaults, backfillKey: "backfilled",
            backfillScan: { _ in CostUsageScanResult(entries: found(day)) })

        await mgr.record(CostUsageScanResult(entries: Self.claudeRows(day) + Self.codexRows(day, input: 200)))
        await mgr.runBackfillIfNeeded(historyReadAllowed: false)   // "Last 30 days only"
        await mgr.runBackfillIfNeeded(historyReadAllowed: true)    // "Choose again…" → older history

        return (await mgr.snapshot(), DailyUsageArchiveIO.load(root: root), day)
    }

    /// Claude Code has deleted the day's transcripts; Codex's log is still
    /// there and is counted anew.
    func test_the_history_read_keeps_the_claude_share_of_a_day_whose_transcripts_are_gone() async {
        let (a, onDisk, day) = await historyReadAfterThirtyDaysOnly { Self.codexRows($0, input: 300) }

        let claude = ProviderDaySlice(tokens: 150, cost: 0.30, messages: 7)
        XCTAssertEqual(a.days[day]?.perProvider["Claude"], claude, "Claude's share of the day was dropped")
        XCTAssertEqual(a.days[day]?.perProvider["Codex"]?.tokens, 320, "the Codex log it read was not counted")
        XCTAssertEqual(a.days[day]?.tokens, 470)
        XCTAssertEqual(DailyUsageStats.totalMessages(a), 7)
        XCTAssertEqual(onDisk.days[day]?.perProvider["Claude"], claude, "Claude's share is gone from disk")
    }

    /// The reverse: the Codex logs were deleted and the Claude transcripts
    /// are read again.
    func test_the_history_read_keeps_the_codex_share_of_a_day_whose_logs_are_gone() async {
        let (a, onDisk, day) = await historyReadAfterThirtyDaysOnly { Self.claudeRows($0) }

        let codex = ProviderDaySlice(tokens: 220, cost: 0.10, messages: 0)
        XCTAssertEqual(a.days[day]?.perProvider["Codex"], codex, "Codex's share of the day was dropped")
        XCTAssertEqual(a.days[day]?.perProvider["Claude"]?.tokens, 150)
        XCTAssertEqual(a.days[day]?.tokens, 370)
        XCTAssertEqual(onDisk.days[day]?.perProvider["Codex"], codex, "Codex's share is gone from disk")
    }
}
#endif

// v1.55: the day Claude Code's cleanup is working through.
//
// The routine read covers 31 days, from the day of `now − 30 days` through
// today. Claude Code's cleanup (default `cleanupPeriodDays` 30, run when a
// session starts) deletes transcripts last active before `now − 30 days`, a
// moment inside that oldest day. The scanner's cache then drops the deleted
// files' share, and the read reports what is left of the day. Rewriting the
// day from that lowered it in the archive (`record`) and, through
// `upsert_daily_usage`, in the cloud copy the iPhone reads.
//
// macOS-gated: the manager, the real scanner and `syncDailyUsage` are macOS-only.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class DailyUsageClaudeCleanupEdgeTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("claude/-Users-someone-project", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("codex", isDirectory: true), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func manager(_ name: String = "archive") -> DailyUsageArchiveManager {
        DailyUsageArchiveManager(
            root: tmp.appendingPathComponent(name, isDirectory: true),
            defaults: UserDefaults(suiteName: "cleanup-edge-\(UUID().uuidString)")!,
            backfillKey: "backfilled")
    }

    private static func row(_ date: String, _ provider: String, _ model: String,
                            input: Int, output: Int = 0, cost: Double = 0, messages: Int = 0)
        -> CostUsageScanResult.DailyEntry
    {
        .init(date: date, provider: provider, model: model, inputTokens: input, cachedTokens: 0,
              outputTokens: output, costUSD: cost, messageCount: messages)
    }

    // MARK: - The archive, with the real scanner

    private func writeSession(_ name: String, at t: Date, input: Int, output: Int) throws -> URL {
        let url = tmp.appendingPathComponent("claude/-Users-someone-project/\(name).jsonl")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
        {"type":"assistant","timestamp":"\(iso.string(from: t))","requestId":"req-\(name)","message":{"id":"msg-\(name)","model":"claude-sonnet-4-5","usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: url.path)
        return url
    }

    /// The scanner with production's window (`daysToScan` left at its default).
    private func routineScan() -> CostUsageScanResult {
        var o = CostUsageScanner.Options(
            codexSessionsRoot: tmp.appendingPathComponent("codex", isDirectory: true),
            claudeProjectsRoots: [tmp.appendingPathComponent("claude", isDirectory: true)],
            cacheRoot: tmp.appendingPathComponent("cache", isDirectory: true))
        o.refreshMinIntervalSeconds = 0
        return CostUsageScanner.scan(options: o)
    }

    func test_the_routine_read_does_not_shrink_the_day_claude_code_is_cleaning_up() async throws {
        let now = Date()
        let cutoff = DayKey.calendar().date(byAdding: .day, value: -30, to: now)!
        let edgeDay = DayKey.string(from: cutoff)
        XCTAssertEqual(edgeDay, DailyUsageArchive.claudeCleanupReach(now: now))
        let startOfEdgeDay = DayKey.calendar().startOfDay(for: cutoff)
        let before = startOfEdgeDay.addingTimeInterval(cutoff.timeIntervalSince(startOfEdgeDay) / 2)
        let after = cutoff.addingTimeInterval(60)
        try XCTSkipIf(cutoff.timeIntervalSince(startOfEdgeDay) < 120 || DayKey.string(from: after) != edgeDay,
                      "too close to midnight for this fixture")

        let deleted = try writeSession("morning", at: before, input: 200, output: 100)  // last active before the cutoff
        _ = try writeSession("evening", at: after, input: 20, output: 10)               // last active after it

        let mgr = manager()
        let first = routineScan()
        XCTAssertEqual(first.entries.filter { $0.date == edgeDay && $0.provider == "Claude" }
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }, 330,
                       "the routine window reports \(edgeDay), the day cleanup cuts through")
        await mgr.record(first)

        // Claude Code starts a session; its cleanup deletes the transcript last
        // active before now − 30 days.
        try FileManager.default.removeItem(at: deleted)
        let second = routineScan()
        XCTAssertEqual(second.entries.filter { $0.date == edgeDay && $0.provider == "Claude" }
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }, 30, "the fixture no longer shows the cleanup")
        await mgr.record(second)

        let stored = await mgr.snapshot().days[edgeDay]?.perProvider["Claude"]?.tokens
        XCTAssertEqual(stored, 330, "record rewrote \(edgeDay) from what Claude Code's cleanup left")
        XCTAssertEqual(DailyUsageArchiveIO.load(root: tmp.appendingPathComponent("archive", isDirectory: true))
            .days[edgeDay]?.perProvider["Claude"]?.tokens, 330)
        XCTAssertEqual(DailyUsageArchive.dayRollups(of: second.entries.map(DailyUsageArchiveManager.scanEntry))[edgeDay]?
            .perProvider["Claude"]?.tokens, 30, "negative control: the whole-day rule would have stored 30")
    }

    // MARK: - The archive, with a fixed clock

    func test_record_merges_by_provider_only_up_to_the_cleanup_reach() async {
        let now = ISO8601DateFormatter().date(from: "2026-10-01T18:00:00Z")!
        let reach = DailyUsageArchive.claudeCleanupReach(now: now)
        let inside = DayKey.string(from: now.addingTimeInterval(-10 * 86_400))
        let mgr = manager()

        await mgr.record(CostUsageScanResult(entries: [
            Self.row(reach, "Claude", "claude-sonnet-4-5", input: 300, cost: 0.9, messages: 12),
            Self.row(reach, "Codex", "gpt-5", input: 200),
            Self.row(inside, "Claude", "claude-sonnet-4-5", input: 300, cost: 0.9, messages: 12),
        ]), now: now)
        await mgr.record(CostUsageScanResult(entries: [
            Self.row(reach, "Claude", "claude-sonnet-4-5", input: 30, cost: 0.09, messages: 2),
            Self.row(reach, "Codex", "gpt-5", input: 150),
            Self.row(inside, "Claude", "claude-sonnet-4-5", input: 30, cost: 0.09, messages: 2),
        ]), now: now)

        let a = await mgr.snapshot()
        XCTAssertEqual(a.days[reach]?.perProvider["Claude"], ProviderDaySlice(tokens: 300, cost: 0.9, messages: 12))
        XCTAssertEqual(a.days[reach]?.perProvider["Codex"]?.tokens, 150, "Codex on the oldest day is still counted anew")
        XCTAssertEqual(a.days[inside]?.perProvider["Claude"]?.tokens, 30, "a day inside the window is replaced whole")
    }

    // MARK: - The history read, over a day only partly cleaned up

    /// The year-long read after months of "Last 30 days only": one of the
    /// day's two Claude sessions was resumed later, so its transcript is still
    /// there and the other's is gone.
    func test_the_history_read_does_not_shrink_a_day_whose_transcripts_are_partly_gone() async {
        let day = DayKey.string(from: Date().addingTimeInterval(-120 * 86_400))
        let mgr = DailyUsageArchiveManager(
            root: tmp.appendingPathComponent("archive", isDirectory: true),
            defaults: UserDefaults(suiteName: "cleanup-edge-\(UUID().uuidString)")!,
            backfillKey: "backfilled",
            backfillScan: { _ in
                CostUsageScanResult(entries: [
                    Self.row(day, "Claude", "claude-sonnet-4-5", input: 100, cost: 0.3),
                    Self.row(day, "Claude", ScanEntry.messageBucketModel, input: 0, messages: 4),
                    Self.row(day, "Codex", "gpt-5", input: 300),
                ])
            })

        await mgr.record(CostUsageScanResult(entries: [
            Self.row(day, "Claude", "claude-sonnet-4-5", input: 1_000, cost: 3.0),
            Self.row(day, "Claude", ScanEntry.messageBucketModel, input: 0, messages: 40),
            Self.row(day, "Codex", "gpt-5", input: 200),
        ]))
        await mgr.runBackfillIfNeeded(historyReadAllowed: false)   // "Last 30 days only"
        await mgr.runBackfillIfNeeded(historyReadAllowed: true)    // older history allowed later

        let a = await mgr.snapshot()
        XCTAssertEqual(a.days[day]?.perProvider["Claude"], ProviderDaySlice(tokens: 1_000, cost: 3.0, messages: 40),
                       "the history read replaced a complete Claude slice with what survived the cleanup")
        XCTAssertEqual(a.days[day]?.perProvider["Codex"]?.tokens, 300)
        XCTAssertEqual(a.days[day]?.tokens, 1_300)
        XCTAssertEqual(DailyUsageStats.totalMessages(a), 40)
    }

    // MARK: - The daily-usage upload

    func test_the_upload_leaves_out_claude_on_the_day_cleanup_is_working_through() {
        let now = ISO8601DateFormatter().date(from: "2026-10-01T18:00:00Z")!
        let reach = DailyUsageArchive.claudeCleanupReach(now: now)
        let inside = DayKey.string(from: now.addingTimeInterval(-10 * 86_400))
        let rows = APIClient.dailyUsageRowsToUpload([
            Self.row(reach, "Claude", "claude-sonnet-4-5", input: 30),
            Self.row(reach, "Codex", "gpt-5", input: 150),
            Self.row(inside, "Claude", "claude-sonnet-4-5", input: 30),
            Self.row(inside, "Claude", ScanEntry.messageBucketModel, input: 0, messages: 3),
        ], now: now)

        XCTAssertEqual(rows.map { "\($0.date) \($0.provider) \($0.model)" }, [
            "\(reach) Codex gpt-5",
            "\(inside) Claude claude-sonnet-4-5",
        ])
    }
}
#endif

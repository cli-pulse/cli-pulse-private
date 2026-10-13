#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.57 (P1-2) acceptance on a real Mac: the day a reader selects in the
/// usage panel's provider mode adds up to the model rows it lists.
///
/// Off unless asked for. It reads this Mac's own `~/.codex` and `~/.claude`
/// logs, which no test may do for whoever happens to run the suite:
///
///     CLIPULSE_LOCAL_PANEL_CHECK=<yyyy-MM-dd> swift test --filter ProviderUsageLocalCheckTests
///
/// The scan writes its cache to a throwaway directory, never the app's. The
/// output is totals only: no model name, path or project leaves the test.
final class ProviderUsageLocalCheckTests: XCTestCase {
    func testTheSelectedDayAddsUpToItsModelRowsOnThisMac() throws {
        guard let dayKey = ProcessInfo.processInfo.environment["CLIPULSE_LOCAL_PANEL_CHECK"],
              DayKey.isPlausible(dayKey) else {
            throw XCTSkip("set CLIPULSE_LOCAL_PANEL_CHECK=<yyyy-MM-dd> to read this Mac's logs")
        }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-panel-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        var options = CostUsageScanner.Options(cacheRoot: cache, daysToScan: 30)
        options.forceRescan = true
        let scan = CostUsageScanner.scan(options: options)
        let today = DayKey.string(from: Date())

        for provider in ["Codex", "Claude"] {
            let days = ProviderUsageDays.fromScan(scan.entries, provider: provider, todayKey: today)
            guard let day = days.day(dayKey) else {
                print("LOCAL_PANEL_CHECK \(provider) \(dayKey): outside the last 30 days")
                continue
            }
            let rowTokens = day.models.reduce(0) { $0 + $1.tokens }
            let rowCost = day.models.reduce(0) { $0 + $1.cost }
            // The same day straight from the scan rows, outside the model.
            // %ld below: counts are 64-bit, and cache reads can take a day past 2^31.
            let raw = scan.entries.filter {
                $0.provider == provider && $0.date == dayKey && $0.model != ScanEntry.messageBucketModel
            }
            let rawTokens = raw.reduce(0) { $0 + ArchiveTokenBasis.tokens(of: $1) }
            let rawCost = raw.reduce(0) { $0 + ($1.costUSD ?? 0) }
            print(String(
                format: "LOCAL_PANEL_CHECK %@ %@: day %ld tokens, rows sum %ld, scan %ld; day $%.6f, rows sum $%.6f, scan $%.6f; %ld rows%@",
                provider, dayKey, day.tokens, rowTokens, rawTokens, day.cost, rowCost, rawCost,
                day.models.count, day.hasUnpriced ? ", some without a rate" : ""))
            XCTAssertEqual(day.tokens, rowTokens, provider)
            XCTAssertEqual(day.cost, rowCost, provider)
            XCTAssertEqual(day.tokens, rawTokens, provider)
            XCTAssertEqual(day.cost, rawCost, accuracy: 1e-6, provider)
        }
    }
}
#endif

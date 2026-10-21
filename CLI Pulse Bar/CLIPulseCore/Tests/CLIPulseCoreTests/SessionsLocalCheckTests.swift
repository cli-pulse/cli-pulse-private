#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.58 (P1-5) acceptance on a real Mac: with the date filter, each
/// provider's sessions add up to its 30-day estimate as the usage panel shows
/// it, with no difference.
///
/// Off unless asked for. It reads this Mac's own `~/.codex` and `~/.claude`
/// logs, which no test may do for whoever happens to run the suite:
///
///     CLIPULSE_LOCAL_SESSIONS_CHECK=1 swift test --filter SessionsLocalCheckTests
///
/// The scan writes its cache to a throwaway directory, never the app's. The
/// output is the two totals and their difference per provider, and how many
/// sessions there are and how many would show no project number with "Hide
/// personal information" on: no session, project name or path leaves the
/// test.
final class SessionsLocalCheckTests: XCTestCase {
    func testSessionsAddUpToEachProvidersEstimateOnThisMac() throws {
        guard ProcessInfo.processInfo.environment["CLIPULSE_LOCAL_SESSIONS_CHECK"] == "1" else {
            throw XCTSkip("set CLIPULSE_LOCAL_SESSIONS_CHECK=1 to read this Mac's logs")
        }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-sessions-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        var options = CostUsageScanner.Options(cacheRoot: cache, daysToScan: 30)
        options.forceRescan = true
        let scan = CostUsageScanner.scan(options: options)
        let today = DayKey.string(from: Date())

        for provider in ["Codex", "Claude"] {
            // The panel's figures: its 30 days, cost and I/O as a card opens it.
            let days = ProviderUsageDays.fromScan(scan.entries, provider: provider, basis: .inputOutput, todayKey: today)
            let rows = SessionUsageRanking.rows(
                scan.sessions, details: scan.sessionDetails, provider: provider, todayKey: today)
            let estimate = days.totalCost
            let sessions = rows.reduce(0) { $0 + $1.cost }
            let difference = sessions - estimate
            let nanodollars = Int((difference * 1e9).rounded())
            let ioDifference = rows.reduce(0) { $0 + $1.ioTokens } - days.totalTokens
            print(String(
                format: "LOCAL_SESSIONS_CHECK %@: 30-day estimate $%.6f, sessions $%.6f, difference $%.9f (%ld nanodollars, %ld I/O tokens)",
                provider, estimate, sessions, difference, nanodollars, ioDifference))
            XCTAssertEqual(nanodollars, 0, provider)
            XCTAssertEqual(ioDifference, 0, provider)

            // With "Hide personal information" on, every session's project
            // has the number Projects gives it: none reads "Project 0".
            let masked = SessionUsageList.build(
                scan.sessions, details: scan.sessionDetails, projects: scan.projects, provider: provider,
                todayKey: today, showsCost: true, hidePersonalInfo: true)
            let unnumbered = masked.lines.filter { $0.title == L10n.projects.anonymous(0) }.count
            print("LOCAL_SESSIONS_CHECK \(provider): \(masked.lines.count) sessions, \(unnumbered) without a project number")
            XCTAssertEqual(unnumbered, 0, provider)
        }
    }
}
#endif

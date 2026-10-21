import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.58 (P1-5): Demo's Mac lists sessions, as a real Mac that scans its logs
/// does, and only as one can: its scan's rows cut into sessions that add up
/// to them, in its own invented folders, none last active after Demo's
/// refresh, and the sessions Demo shows running on this Mac (Codex in
/// `cli-pulse-ios`, Claude in `provider-layer`) last active just before it,
/// as their logs would be.
@MainActor
final class DemoMacSessionsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var previousLocale: String?

    override func setUp() {
        super.setUp()
        suiteName = "DemoMacSessionsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        previousLocale = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(previousLocale)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// An empty Info.plist resolves to the quarantine capabilities, so this
    /// publishes no widget data to the real app group.
    private func demo() -> AppState {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        state.enterDemoMode()
        return state
    }

    /// The sessions add up to the rows, day by day and model by model:
    /// tokens exactly, cost to the cent.
    func testDemosSessionsAddUpToItsRows() throws {
        let scan = try XCTUnwrap(demo().costUsageScanResult)
        XCTAssertFalse(scan.sessions.isEmpty)
        var rows: [String: [Int]] = [:]
        for e in scan.entries where e.model != ScanEntry.messageBucketModel {
            rows[[e.date, e.provider, e.model].joined(separator: "|")] =
                [e.inputTokens, e.cachedTokens, e.outputTokens, Int(((e.costUSD ?? 0) * 100).rounded())]
        }
        var split: [String: [Int]] = [:]
        for s in scan.sessions {
            let key = [s.date, s.provider, s.model].joined(separator: "|")
            let part = [s.inputTokens, s.cachedTokens, s.outputTokens, Int(((s.costUSD ?? 0) * 100).rounded())]
            split[key] = zip(split[key] ?? [0, 0, 0, 0], part).map { $0 + $1 }
        }
        XCTAssertEqual(split, rows)
        // Every session is described, and every description has rows.
        XCTAssertEqual(Set(scan.sessions.map(\.session)), Set(scan.sessionDetails.map(\.key)))
    }

    /// The panel's Sessions for each provider: Demo's folders, a few days
    /// each, none last active after the refresh, the running ones a minute
    /// before it, and the sum the panel's 30-day total.
    ///
    /// Demo's rows are cut into sessions as of noon on the day of its
    /// refresh, not as of the refresh itself: in the first minute after
    /// midnight a minute before the refresh is yesterday, so every session of
    /// today starts at midnight (`DemoDataProvider.sessions` keeps today's
    /// sessions on today) and the running one is no longer the latest.
    func testDemosSessionsAreOnesItsMacCouldShow() throws {
        let state = demo()
        let refresh = try XCTUnwrap(state.lastRefresh)
        let calendar = DayKey.calendar()
        let noon = calendar.startOfDay(for: refresh).addingTimeInterval(12 * 3600)
        let scan = DemoDataProvider.macScan(rows: state.dailyUsage, now: noon)
        // The same rows and sessions the app holds, but for the moment they
        // are cut at.
        let held = try XCTUnwrap(state.costUsageScanResult)
        XCTAssertEqual(scan.sessions, held.sessions)
        let today = DayKey.string(from: refresh)
        let names = Set(DemoDataProvider.macProjects.map(\.name))
        for (provider, running) in [("Codex", "cli-pulse-ios"), ("Claude", "provider-layer")] {
            let rows = SessionUsageRanking.ordered(
                SessionUsageRanking.rows(scan.sessions, details: scan.sessionDetails, provider: provider, todayKey: today),
                by: .latest, showsCost: true)
            XCTAssertGreaterThan(rows.count, 10, provider)
            XCTAssertTrue(rows.allSatisfy { names.contains($0.project.name ?? "") }, provider)
            XCTAssertTrue(rows.allSatisfy { $0.lastActivity <= noon }, provider)
            let latest = try XCTUnwrap(rows.first)
            XCTAssertEqual(latest.project.name, running, provider)
            XCTAssertEqual(latest.lastActivity.timeIntervalSince(noon), -60, accuracy: 1, provider)
            // And in the app's own sessions, cut at the refresh: none later.
            let heldRows = SessionUsageRanking.rows(
                held.sessions, details: held.sessionDetails, provider: provider, todayKey: today)
            XCTAssertTrue(heldRows.allSatisfy { $0.lastActivity <= refresh }, provider)

            let days = ProviderUsageDays.fromScan(scan.entries, provider: provider, basis: .inputOutput, todayKey: today)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.ioTokens }, days.totalTokens, provider)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.cost }, days.totalCost, accuracy: 0.005, provider)
            XCTAssertTrue(rows.contains { $0.subagents > 0 }, provider)
        }
        // No Gemini sessions: Demo's Mac reads Codex and Claude logs only.
        XCTAssertTrue(scan.sessions.allSatisfy { $0.provider == "Codex" || $0.provider == "Claude" })
    }

    /// With the switch on, a session's project is "项目 N", the number the
    /// Overview's Top Projects gives the folder, and no path.
    func testDemosSessionsHideTheirFoldersWithTheSwitch() throws {
        let scan = try XCTUnwrap(demo().costUsageScanResult)
        let today = DayKey.string(from: Date())
        let list = SessionUsageList.build(
            scan.sessions, details: scan.sessionDetails, projects: scan.projects, provider: "Codex",
            todayKey: today, showsCost: true, hidePersonalInfo: true)
        XCTAssertFalse(list.isEmpty)
        let overview = ProjectUsageList.overview(scan.projects, todayKey: today, showsCost: true, hidePersonalInfo: true)
        let numbered = Set(overview.lines.map(\.title))
        XCTAssertTrue(list.lines.allSatisfy { $0.title.hasPrefix("项目 ") && $0.hoverText == nil }, "\(list.lines.map(\.title))")
        XCTAssertFalse(numbered.isDisjoint(with: Set(list.lines.map(\.title))))
    }
}

#endif

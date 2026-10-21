import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.58 (P1-4): Demo's Mac lists projects, as a real Mac that scans its logs
/// does, and only as one can.
///
/// A real Mac's projects come from its own scan (`CostUsageScanResult
/// .projects`), so Demo's Mac has a scan: the account's synced rows, as on a
/// Mac that is the account's only uploading device, with Claude's message
/// counts like every real scan, split across invented folders. The projects
/// add up to the rows, so the Overview's Top Projects, the panel's Projects
/// and the cards all tell one story.
@MainActor
final class DemoMacProjectsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var previousLocale: String?

    override func setUp() {
        super.setUp()
        suiteName = "DemoMacProjectsTests.\(UUID().uuidString)"
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

    func testDemosMacScanIsTheAccountsRowsWithMessages() throws {
        let state = demo()
        let scan = try XCTUnwrap(state.costUsageScanResult, "Demo's Mac has no scan, so it can list no project")
        let models = scan.entries.filter { $0.model != ScanEntry.messageBucketModel }
        XCTAssertEqual(models.count, state.dailyUsage.count)
        for row in state.dailyUsage {
            let entry = try XCTUnwrap(models.first { $0.date == row.date && $0.provider == row.provider && $0.model == row.model })
            XCTAssertEqual(entry.inputTokens, row.inputTokens)
            XCTAssertEqual(entry.cachedTokens, row.cachedTokens)
            XCTAssertEqual(entry.outputTokens, row.outputTokens)
            XCTAssertEqual(try XCTUnwrap(entry.costUSD), row.cost, accuracy: 1e-9)
        }
        // Every real scan of Claude logs counts messages.
        let claudeDays = Set(state.dailyUsage.filter { $0.provider == "Claude" }.map(\.date))
        let messageDays = Set(scan.entries.filter { $0.model == ScanEntry.messageBucketModel && $0.messageCount > 0 }.map(\.date))
        XCTAssertFalse(claudeDays.isEmpty)
        XCTAssertEqual(messageDays, claudeDays)
    }

    /// The projects add up to the rows, day by day and model by model: tokens
    /// exactly, cost to the cent.
    func testDemosProjectsAddUpToItsRows() throws {
        let scan = try XCTUnwrap(demo().costUsageScanResult)
        XCTAssertFalse(scan.projects.isEmpty)
        var rows: [String: (input: Int, cached: Int, output: Int, cents: Int)] = [:]
        for e in scan.entries where e.model != ScanEntry.messageBucketModel {
            let key = [e.date, e.provider, e.model].joined(separator: "|")
            rows[key] = (e.inputTokens, e.cachedTokens, e.outputTokens, Int(((e.costUSD ?? 0) * 100).rounded()))
        }
        var split: [String: (input: Int, cached: Int, output: Int, cents: Int)] = [:]
        for p in scan.projects {
            let key = [p.date, p.provider, p.model].joined(separator: "|")
            let sum = split[key] ?? (0, 0, 0, 0)
            split[key] = (sum.input + p.inputTokens, sum.cached + p.cachedTokens, sum.output + p.outputTokens,
                          sum.cents + Int(((p.costUSD ?? 0) * 100).rounded()))
        }
        XCTAssertEqual(Set(split.keys), Set(rows.keys))
        for (key, row) in rows {
            let parts = try XCTUnwrap(split[key])
            XCTAssertTrue(parts == row, "\(key): projects \(parts) vs row \(row)")
        }
    }

    /// The Overview's Top Projects: five of Demo's six invented folders, the
    /// path on hover under the demo user's folder and nowhere real.
    func testDemosTopProjectsCardListsInventedFolders() throws {
        let state = demo()
        let list = ProjectUsageList.overview(
            state.costUsageScanResult?.projects ?? [],
            todayKey: DayKey.string(from: Date()), showsCost: true, hidePersonalInfo: false)
        let names = DemoDataProvider.macProjects.map(\.name)
        XCTAssertEqual(list.lines.count, 5)
        XCTAssertEqual(list.projectCount, names.count)
        XCTAssertEqual(list.shownOfText, "6 个项目中的前 5 个")
        for line in list.lines {
            XCTAssertTrue(names.contains(line.title), "\(line.title) is not one of Demo's folders")
            XCTAssertTrue(line.hoverText?.hasPrefix(DemoDataProvider.macProjectsFolder + "/") == true,
                          "\(line.title): \(line.hoverText ?? "no path")")
        }
        // Demo's sessions run in folders of its own list.
        let sessionProjects = Set(state.sessions.map(\.project))
        XCTAssertTrue(sessionProjects.isSubset(of: Set(names)), "\(sessionProjects)")

        // With the switch on: numbered, no path.
        let masked = ProjectUsageList.overview(
            state.costUsageScanResult?.projects ?? [],
            todayKey: DayKey.string(from: Date()), showsCost: true, hidePersonalInfo: true)
        XCTAssertEqual(masked.lines.map(\.title), (1...5).map { "项目 \($0)" })
        XCTAssertTrue(masked.lines.allSatisfy { $0.hoverText == nil })
        // With costs hidden too, still in order: the numbers follow the
        // Overview's own ranking.
        let maskedNoCost = ProjectUsageList.overview(
            state.costUsageScanResult?.projects ?? [],
            todayKey: DayKey.string(from: Date()), showsCost: false, hidePersonalInfo: true)
        XCTAssertEqual(maskedNoCost.lines.map(\.title), (1...5).map { "项目 \($0)" })
    }

    /// The Overview's Top Projects sits under the Cost Summary, whose 30
    /// days read "· N I/O tokens". Its rows count tokens the same way, so
    /// together they never read more than that figure, and each line says
    /// "I/O" to VoiceOver. Counting each token once (Claude's cache reads
    /// in), Demo's rows came to more than the figure above them: the
    /// negative control below.
    func testDemosTopProjectsCountTokensAsTheCostSummaryAbove() throws {
        let state = demo()
        let projects = state.costUsageScanResult?.projects ?? []
        let today = DayKey.string(from: Date())
        let summary = state.providerState.costSummary.thirtyDayTokens
        XCTAssertGreaterThan(summary, 0)
        let io = ProjectUsageRanking.rows(projects, basis: ProjectUsageList.overviewBasis, todayKey: today)
        XCTAssertLessThanOrEqual(io.reduce(0) { $0 + $1.tokens }, summary)
        let eachOnce = ProjectUsageRanking.rows(projects, basis: .eachOnce, todayKey: today)
        XCTAssertGreaterThan(eachOnce.reduce(0) { $0 + $1.tokens }, summary,
                             "negative control: counted each once, the rows read more than the total above")
        let list = ProjectUsageList.overview(projects, todayKey: today, showsCost: true, hidePersonalInfo: false)
        XCTAssertTrue(list.lines.allSatisfy { $0.tokensText.hasSuffix(" I/O") }, "\(list.lines.map(\.tokensText))")
    }

    /// The scan is the account's own rows, so the cards read what they read
    /// without it: the larger of two equal days is the same day.
    func testDemosCardsReadTheSameFiguresWithItsScan() throws {
        let state = demo()
        let scan = try XCTUnwrap(state.costUsageScanResult)
        for provider in ["Codex", "Claude"] {
            let usage = state.providers.first { $0.provider == provider }
            func card(_ entries: [CostUsageScanResult.DailyEntry]) -> ProviderCardUsage {
                ProviderCardUsageBuilder.build(
                    provider: provider, usage: usage, scanEntries: entries, cloudRows: state.dailyUsage,
                    readsCloud: true, usesProviderTokenCounts: false)
            }
            let with = card(scan.entries)
            let without = card([])
            for window in ProviderUsageWindow.allCases {
                XCTAssertEqual(with.cell(window).ioTokens, without.cell(window).ioTokens, "\(provider) \(window)")
                XCTAssertEqual(try XCTUnwrap(with.cell(window).cost), try XCTUnwrap(without.cell(window).cost),
                               accuracy: 1e-9, "\(provider) \(window)")
            }
        }
    }
}

#endif

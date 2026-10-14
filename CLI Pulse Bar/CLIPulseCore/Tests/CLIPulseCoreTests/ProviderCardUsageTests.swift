import XCTest
@testable import CLIPulseCore

/// v1.57 P1-1: the provider card's Today · This Week · 30 Days row and its
/// small chart (`ProviderCardUsageBuilder`).
final class ProviderCardUsageTests: XCTestCase {

    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    /// 2026-10-07 12:00 in Tokyo.
    private var now: Date { Date(timeIntervalSince1970: 1_791_342_000) }
    private var windows: ProviderUsageWindows { ProviderUsageWindows(now: now, timeZone: tokyo) }

    private func key(_ daysAgo: Int) -> String {
        let calendar = DayKey.calendar(in: tokyo)
        return DayKey.string(from: calendar.date(byAdding: .day, value: -daysAgo, to: now)!, in: tokyo)
    }

    private func scan(
        _ daysAgo: Int, _ provider: String = "Codex", model: String = "gpt-5.5",
        io: Int, cost: Double?, messages: Int = 0, approximate: Bool = false
    ) -> CostUsageScanResult.DailyEntry {
        CostUsageScanResult.DailyEntry(
            date: key(daysAgo), provider: provider, model: model,
            inputTokens: io - io / 10, cachedTokens: io / 2, outputTokens: io / 10,
            costUSD: cost, priceIsApproximate: approximate, messageCount: messages)
    }

    private func row(_ daysAgo: Int, _ provider: String = "Codex", model: String = "gpt-5.5",
                     io: Int, cost: Double) -> DailyUsage {
        DailyUsage(date: key(daysAgo), provider: provider, model: model,
                   inputTokens: io - io / 10, cachedTokens: io / 2, outputTokens: io / 10, cost: cost)
    }

    private func usage(
        _ provider: String = "Codex", today: Double = 0, week: Double = 0, thirty: Double = 0,
        status: String = "Estimated", todayUsage: Int = 0, weekUsage: Int = 0
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider, today_usage: todayUsage, week_usage: weekUsage,
            estimated_cost_today: today, estimated_cost_week: week, estimated_cost_30_day: thirty,
            cost_status_today: status, cost_status_week: status,
            quota: nil, remaining: nil, status_text: "", trend: [], recent_sessions: [], recent_errors: [])
    }

    // MARK: - Windows

    /// The server's windows (`v_today - 6`, `v_today - 29`): 7 and 30 day
    /// keys ending today, not the scan's 31.
    func testTheWindowsAreTheServers() {
        let w = windows
        XCTAssertEqual(w.dayKeys.count, 30)
        XCTAssertEqual(w.todayKey, "2026-10-07")
        XCTAssertEqual(w.startKey(.today), "2026-10-07")
        XCTAssertEqual(w.startKey(.week), "2026-10-01")
        XCTAssertEqual(w.startKey(.thirtyDays), "2026-09-08")
        XCTAssertTrue(w.contains("2026-09-08", in: .thirtyDays))
        XCTAssertFalse(w.contains("2026-09-07", in: .thirtyDays), "the 31st day back is outside")
        XCTAssertFalse(w.contains("2026-10-08", in: .thirtyDays), "tomorrow is outside")
        XCTAssertFalse(w.contains("2026-09-30", in: .week))
        XCTAssertEqual(w.dayKeys, w.dayKeys.sorted(), "oldest first")
    }

    // MARK: - Signed out: this Mac

    func testSignedOutReadsThisMacsScanAndNothingElse() {
        let entries = [
            scan(0, io: 1_000, cost: 1.0),
            scan(3, io: 2_000, cost: 2.0),
            scan(20, io: 4_000, cost: 4.0),
            scan(30, io: 99_000, cost: 99.0),            // the 31st day key
            scan(0, "Claude", io: 500, cost: 0.5),       // another provider
        ]
        // Rows from an account are ignored when the card does not read it.
        let rows = [row(0, io: 50_000, cost: 50)]
        let u = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil, scanEntries: entries, cloudRows: rows,
            readsCloud: false, windows: windows)
        XCTAssertEqual(u.scope, .thisMac)
        XCTAssertEqual(u.today.cost, 1.0)
        XCTAssertEqual(u.today.ioTokens, 1_000)
        XCTAssertEqual(u.week.cost, 3.0)
        XCTAssertEqual(u.week.ioTokens, 3_000)
        XCTAssertEqual(u.thirtyDays.cost, 7.0)
        XCTAssertEqual(u.thirtyDays.ioTokens, 7_000)
        XCTAssertEqual(u.thisMac.days.count, 30)
        XCTAssertEqual(u.thisMac.days.map(\.dateKey), windows.dayKeys)
        XCTAssertNil(u.account, "signed out, the account's days are not read")
        XCTAssertEqual(u.chartDays(.tokens), u.thisMac.days)
        XCTAssertEqual(u.chartDays(.tokens).last?.tokens, 1_000)
        XCTAssertEqual(u.chartDays(.tokens).map(\.tokens).reduce(0, +), 7_000)
        XCTAssertEqual(u.chartDays(.cost).map(\.cost).reduce(0, +), 7.0, accuracy: 0.0001)
        XCTAssertFalse(u.messagesAreThisMacOnly)
    }

    // MARK: - Signed in: the larger of this Mac's and the account's

    func testSignedInTakesTheLargerOfThisMacAndTheAccount() {
        // This Mac counted $2 today; the account holds $4.50 (this Mac's
        // earlier upload and another Mac's). Last week this Mac counted more
        // than it had uploaded yet.
        let entries = [scan(0, io: 10_000, cost: 2.0), scan(2, io: 30_000, cost: 6.0)]
        let rows = [row(0, io: 25_000, cost: 4.5), row(2, io: 20_000, cost: 4.0), row(12, io: 8_000, cost: 1.0)]
        let u = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: usage(today: 4.5, week: 8.5, thirty: 9.5),
            scanEntries: entries, cloudRows: rows, readsCloud: true, windows: windows)
        XCTAssertEqual(u.scope, .allDevices)
        XCTAssertEqual(u.today.cost, 4.5)
        XCTAssertEqual(u.today.ioTokens, 25_000)
        XCTAssertEqual(u.week.cost, 8.5, "the account's week is larger than this Mac's $8")
        XCTAssertEqual(u.week.ioTokens, 45_000)
        XCTAssertEqual(u.thirtyDays.cost, 9.5)
        XCTAssertEqual(u.thirtyDays.ioTokens, 53_000)
        // Day by day: day 2 is this Mac's 30K (more than the 20K synced),
        // today the account's, and day 12 only the account has.
        let tokenDays = u.chartDays(.tokens)
        XCTAssertEqual(tokenDays.count, 30)
        XCTAssertEqual(tokenDays.first { $0.dateKey == key(2) }?.tokens, 30_000)
        XCTAssertEqual(tokenDays.first { $0.dateKey == key(2) }?.cost, 6.0, "one source's day, not a mix")
        XCTAssertEqual(tokenDays.last?.tokens, 25_000)
        XCTAssertEqual(tokenDays.first { $0.dateKey == key(12) }?.tokens, 8_000)
        XCTAssertEqual(u.chartDays(.cost).last?.cost, 4.5)
        XCTAssertEqual(u.chartMaximum(.tokens), 30_000)
        XCTAssertTrue(u.chartHasData(.cost))
        // Today's bar is the Today figure, in either measure.
        XCTAssertEqual(tokenDays.last.map { Double($0.tokens) }, u.today.ioTokens.map(Double.init))
        XCTAssertEqual(u.chartDays(.cost).last?.cost, u.today.cost)
    }

    func testTheLargerIsTakenNeverTheSum() {
        let u = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: usage(today: 3),
            scanEntries: [scan(0, io: 1_000, cost: 3)], cloudRows: [row(0, io: 1_000, cost: 3)],
            readsCloud: true, windows: windows)
        XCTAssertEqual(u.today.cost, 3, "the account's figure already holds this Mac's upload")
        XCTAssertEqual(u.today.ioTokens, 1_000)
    }

    // MARK: - Messages

    func testClaudesMessagesAreThisMacsAloneBesideTheAccountsTokens() {
        let entries = [
            scan(0, "Claude", model: "claude-opus-5", io: 1_000, cost: 1),
            scan(0, "Claude", model: ScanEntry.messageBucketModel, io: 0, cost: nil, messages: 40),
        ]
        let signedIn = ProviderCardUsageBuilder.build(
            provider: "Claude", usage: usage("Claude", today: 1), scanEntries: entries,
            cloudRows: [row(0, "Claude", io: 5_000, cost: 4)], readsCloud: true, windows: windows)
        XCTAssertEqual(signedIn.today.messages, 40)
        XCTAssertEqual(signedIn.today.ioTokens, 5_000)
        XCTAssertTrue(signedIn.messagesAreThisMacOnly)
        let signedOut = ProviderCardUsageBuilder.build(
            provider: "Claude", usage: nil, scanEntries: entries, cloudRows: [],
            readsCloud: false, windows: windows)
        XCTAssertEqual(signedOut.today.messages, 40)
        XCTAssertFalse(signedOut.messagesAreThisMacOnly, "signed out, everything is this Mac's")
    }

    /// The message bucket is not a model: no tokens from it, and none from a
    /// synced row that carries its name.
    func testTheMessageBucketCountsNoTokens() {
        let u = ProviderCardUsageBuilder.build(
            provider: "Claude", usage: nil, scanEntries: [],
            cloudRows: [row(0, "Claude", model: ScanEntry.messageBucketModel, io: 9_999, cost: 0)],
            readsCloud: true, windows: windows)
        XCTAssertNil(u.today.ioTokens)
        XCTAssertFalse(u.chartHasData(.tokens))
    }

    // MARK: - Cost

    /// Gemini reports quota and no cost: "—", not a "$0.00" that reads as
    /// free.
    func testAProviderWithNoCostSourceHasNoCost() {
        let gemini = ProviderCardUsageBuilder.build(
            provider: "Gemini", usage: usage("Gemini", status: "Unavailable"),
            scanEntries: [], cloudRows: [], readsCloud: true, windows: windows)
        XCTAssertNil(gemini.today.cost)
        XCTAssertNil(gemini.thirtyDays.cost)
        XCTAssertFalse(gemini.hasAnyFigure)
        // A provider whose cost is counted and came to nothing says $0.
        let quietCodex = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: usage(status: "Estimated"),
            scanEntries: [], cloudRows: [], readsCloud: true, windows: windows)
        XCTAssertEqual(quietCodex.today.cost, 0)
        // And so does one with log entries this month, whatever its status.
        let scanned = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: usage(status: "Unavailable"),
            scanEntries: [scan(9, io: 10, cost: 0.01)], cloudRows: [], readsCloud: false, windows: windows)
        XCTAssertEqual(scanned.today.cost, 0)
        XCTAssertEqual(scanned.thirtyDays.cost, 0.01)
    }

    func testABorrowedRateMarksOnlyTheWindowsItIsIn() {
        let u = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil,
            scanEntries: [scan(0, io: 1, cost: 1), scan(10, io: 1, cost: 1, approximate: true)],
            cloudRows: [], readsCloud: false, windows: windows)
        XCTAssertFalse(u.today.costIsApproximate)
        XCTAssertFalse(u.week.costIsApproximate)
        XCTAssertTrue(u.thirtyDays.costIsApproximate)
    }

    /// A collector that reports its own token count (no quota windows) keeps
    /// it for today and the week.
    func testAProvidersOwnTokenCountJoinsTheRule() {
        let u = ProviderCardUsageBuilder.build(
            provider: "OpenRouter", usage: usage("OpenRouter", todayUsage: 1_200, weekUsage: 9_000),
            scanEntries: [], cloudRows: [], readsCloud: true, usesProviderTokenCounts: true,
            windows: windows)
        XCTAssertEqual(u.today.ioTokens, 1_200)
        XCTAssertEqual(u.week.ioTokens, 9_000)
        XCTAssertNil(u.thirtyDays.ioTokens, "nothing counts 30 days for it")
        let quota = ProviderCardUsageBuilder.build(
            provider: "OpenRouter", usage: usage("OpenRouter", todayUsage: 37),
            scanEntries: [], cloudRows: [], readsCloud: true, windows: windows)
        XCTAssertNil(quota.today.ioTokens, "a quota provider's today_usage is a percentage, not tokens")
    }

    // MARK: - The chart's measure

    /// The chart follows the panel's Token/Cost choice, but never shows cost
    /// while costs are hidden.
    func testTheChartFollowsThePanelUnlessCostsAreHidden() {
        XCTAssertEqual(ProviderCardUsage.chartMetric(storedMetric: "cost", showsCost: true), .cost)
        XCTAssertEqual(ProviderCardUsage.chartMetric(storedMetric: "tokens", showsCost: true), .tokens)
        XCTAssertEqual(ProviderCardUsage.chartMetric(storedMetric: nil, showsCost: true), .tokens)
        XCTAssertEqual(ProviderCardUsage.chartMetric(storedMetric: "cost", showsCost: false), .tokens)
    }

    /// The card reads the choice where the panel writes it, by values that
    /// do not change: a rename would reset everyone's choice.
    func testTheCardReadsThePanelsStoredChoice() {
        XCTAssertEqual(UsageChartMetric.allCases.map(\.rawValue), ["tokens", "cost"])
        XCTAssertEqual(UsageChartMetric.defaultsKey, "cli_pulse_usage_chart_metric")
        XCTAssertTrue(UnsandboxedDataMigration.appOwnedKeyPrefixes.contains {
            UsageChartMetric.defaultsKey.hasPrefix($0)
        })
        XCTAssertEqual(ProviderCardUsage.chartMetric(storedMetric: "dollars", showsCost: true), .tokens)
    }

    // MARK: - The panel's days

    /// The chart is drawn from the usage panel's own days
    /// (`ProviderUsageDays`), so the card and the panel it opens cannot
    /// disagree about which rows make up a day: the same 30 day keys, and
    /// each bar the same cost and models as that day in the panel's view of
    /// the same source. Codex's tokens are the same as well (each once is
    /// input + output for Codex); Claude's differ by its cache, which the
    /// panel counts and the card's I/O leaves out, each saying which.
    func testTheChartsDaysAreThePanelsDays() {
        let entries = [
            scan(0, io: 10_000, cost: 2.0),
            scan(0, model: "gpt-5.5-mini", io: 4_000, cost: 0.4),
            scan(2, io: 30_000, cost: 6.0),
            scan(2, "Claude", model: "claude-opus-5", io: 9_000, cost: 3.0),
            scan(29, io: 1_000, cost: 0.1),
            scan(30, io: 7_000, cost: 0.7),               // the 31st day back
        ]
        let rows = [row(0, io: 25_000, cost: 4.5), row(2, io: 20_000, cost: 4.0), row(12, io: 8_000, cost: 1.0),
                    row(2, "Claude", model: "claude-opus-5", io: 12_000, cost: 3.5)]
        for provider in ["Codex", "Claude"] {
            let card = ProviderCardUsageBuilder.build(
                provider: provider, usage: nil, scanEntries: entries, cloudRows: rows,
                readsCloud: true, windows: windows)
            // What the panel shows for each scope (`UsagePanelModel.days`).
            let panelThisMac = ProviderUsageDays.fromScan(
                entries, provider: provider, todayKey: windows.todayKey, timeZone: tokyo)
            let panelAllDevices = ProviderUsageDays.fromCloud(
                rows, provider: provider, todayKey: windows.todayKey, timeZone: tokyo)
            XCTAssertEqual(panelThisMac.days.map(\.dateKey), windows.dayKeys, provider)
            for metric in UsageChartMetric.allCases {
                let bars = card.chartDays(metric)
                XCTAssertEqual(bars.map(\.dateKey), windows.dayKeys, "\(provider) \(metric)")
                for bar in bars {
                    let thisMac = panelThisMac.day(bar.dateKey)
                    let allDevices = panelAllDevices.day(bar.dateKey)
                    let localBar = card.thisMac.day(bar.dateKey)
                    // The bar is one of the two sources' days, as the panel
                    // lists it: its cost and its models.
                    let source = bar == localBar ? thisMac : allDevices
                    XCTAssertEqual(bar.cost, source?.cost ?? -1, accuracy: 0.0001, "\(provider) \(bar.dateKey)")
                    XCTAssertEqual(bar.models.map(\.model), source?.models.map(\.model), "\(provider) \(bar.dateKey)")
                    if provider == "Codex" {
                        XCTAssertEqual(bar.tokens, source?.tokens, "\(provider) \(bar.dateKey)")
                    }
                }
            }
        }
        // The fixture holds a day each source wins, and Claude's cache.
        let codex = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil, scanEntries: entries, cloudRows: rows, readsCloud: true, windows: windows)
        XCTAssertEqual(codex.chartDays(.tokens).first { $0.dateKey == key(2) }?.tokens, 30_000, "this Mac's day")
        XCTAssertEqual(codex.chartDays(.tokens).last?.tokens, 25_000, "the account's day")
        let claudePanel = ProviderUsageDays.fromScan(entries, provider: "Claude", todayKey: windows.todayKey, timeZone: tokyo)
        let claudeCard = ProviderCardUsageBuilder.build(
            provider: "Claude", usage: nil, scanEntries: entries, cloudRows: [], readsCloud: false, windows: windows)
        XCTAssertEqual(claudeCard.chartDays(.tokens).first { $0.dateKey == key(2) }?.tokens, 9_000, "I/O")
        XCTAssertEqual(claudePanel.day(key(2))?.tokens, 13_500, "each once: I/O and the cache")
    }

    /// The card opens the panel from one place at a time: its chart while it
    /// draws one, else a button in its header while the panel has days to
    /// show, else nowhere.
    func testThePanelOpensFromTheChartOrElseTheHeader() {
        XCTAssertEqual(ProviderCardUsage.panelEntry(chartDrawn: true, panelHasHistory: true), .chart)
        XCTAssertEqual(ProviderCardUsage.panelEntry(chartDrawn: true, panelHasHistory: false), .chart)
        XCTAssertEqual(ProviderCardUsage.panelEntry(chartDrawn: false, panelHasHistory: true), .headerButton)
        XCTAssertEqual(ProviderCardUsage.panelEntry(chartDrawn: false, panelHasHistory: false), .none)
    }

    // MARK: - Words

    /// Asserted in Chinese: the English fallback of a missing key reads like
    /// a translation, so an English assertion passes with the lookup broken.
    func testTheScopeAndSectionNamesAreTranslated() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("zh-Hans")
        // The scope's name is the panel's (`UsageDataScope`), one string.
        XCTAssertEqual(UsageDataScope.thisMac.label, "这台 Mac")
        XCTAssertEqual(UsageDataScope.allDevices.label, "所有设备")
        XCTAssertEqual(ProviderCardUsage.scopeHelp(.thisMac), "根据这台 Mac 的会话日志统计。")
        XCTAssertEqual(L10n.providerCard.thirtyDays, "30 天")
        XCTAssertEqual(ProviderCardSection.dailyChart.title, "每日图表")
        XCTAssertEqual(L10n.providerCard.sectionsHiddenCount(2), "已隐藏 2 项")
        XCTAssertTrue(L10n.providerCard.chartTokensHelp("12K").contains("12K"))
        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(UsageDataScope.allDevices.label, "すべてのデバイス")
    }
}

/// v1.57: one Today, and one 30 days, on the provider card, the Providers
/// tab's cost bar and the Overview, for an account used on two Macs.
///
/// Before, the bar and the Overview took this Mac's own figure whenever it had
/// one, while the card beside them took the larger of this Mac's and the
/// account's: on a second Mac the card said both Macs' $4.50 and the bar said
/// this Mac's $2.00.
@MainActor
final class ProviderCardTodayAgreesTests: XCTestCase {

    private func key(_ daysAgo: Int) -> String {
        let calendar = DayKey.calendar()
        return DayKey.string(from: calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date())
    }

    private func entry(_ daysAgo: Int, _ provider: String = "Codex", io: Int, cost: Double) -> CostUsageScanResult.DailyEntry {
        CostUsageScanResult.DailyEntry(
            date: key(daysAgo), provider: provider, model: provider == "Codex" ? "gpt-5.5" : "claude-opus-5",
            inputTokens: io, cachedTokens: 0, outputTokens: 0, costUSD: cost)
    }

    private func row(_ daysAgo: Int, _ provider: String = "Codex", io: Int, cost: Double) -> DailyUsage {
        DailyUsage(date: key(daysAgo), provider: provider, model: provider == "Codex" ? "gpt-5.5" : "claude-opus-5",
                   inputTokens: io, cachedTokens: 0, outputTokens: 0, cost: cost)
    }

    /// What the cloud route hands the app: the account's `provider_summary`
    /// figures, then `applyCostScan` with this Mac's scan.
    private func cloudProvider(_ name: String, today: Double, week: Double, thirty: Double,
                               scan: CostUsageScanResult) -> ProviderUsage {
        let raw = ProviderUsage(
            provider: name, today_usage: 0, week_usage: 0,
            estimated_cost_today: today, estimated_cost_week: week, estimated_cost_30_day: thirty,
            cost_status_today: "Estimated", cost_status_week: "Estimated",
            quota: 100, remaining: 50, status_text: "", trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: name, category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return DataRefreshManager.applyCostScan(to: [raw], scan: scan)[0]
    }

    private func dashboard(today: Double, tokens: Int) -> DashboardSummary {
        DashboardSummary(
            total_usage_today: tokens, total_estimated_cost_today: today, cost_status: "Estimated",
            total_requests_today: 0, active_sessions: 0, online_devices: 2, unresolved_alerts: 0,
            provider_breakdown: [], top_projects: [], trend: [], recent_activity: [], risk_signals: [],
            alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0))
    }

    private struct Shown: Equatable {
        let cardToday: Double
        let barToday: Double
        let overviewTopToday: Double
        let cardTodayTokens: Int?
        let overviewTodayTokens: Int
        let overviewTopTokens: Int
        let card30: Double
        let overview30Row: Double
        let byModelIsThisMacOnly: Bool
        let fidelity: CostCoverage.Fidelity
    }

    private func shown(scan: CostUsageScanResult, rows: [DailyUsage],
                       accountToday: Double, accountWeek: Double, account30: Double,
                       authenticated: Bool = true) -> Shown {
        let state = AppState()
        state.isAuthenticated = authenticated
        state.costUsageScanResult = scan
        state.dailyUsage = rows
        state.providers = [cloudProvider("Codex", today: accountToday, week: accountWeek, thirty: account30, scan: scan)]
        state.dashboard = dashboard(today: accountToday, tokens: 1)
        state.updateCostSummary()
        state.applyCostSummaryToDashboard()
        // The card, built the way `EnhancedProviderCard.cardUsage` builds it.
        let card = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: state.providers[0], scanEntries: scan.entries,
            cloudRows: state.dailyUsage, readsCloud: state.isAuthenticated)
        let summary = state.costSummary
        return Shown(
            cardToday: card.today.cost ?? -1,
            barToday: summary.todayTotal,
            overviewTopToday: state.dashboard?.total_estimated_cost_today ?? -1,
            cardTodayTokens: card.today.ioTokens,
            overviewTodayTokens: summary.todayTokens,
            overviewTopTokens: state.dashboard?.total_usage_today ?? -1,
            card30: card.thirtyDays.cost ?? -1,
            overview30Row: summary.thirtyDayByProvider.first { $0.provider == "Codex" }?.cost ?? -1,
            byModelIsThisMacOnly: summary.thirtyDayIncludesOtherDevices,
            fidelity: summary.fidelity)
    }

    /// This Mac counted $2.00 today; the account, with the other Mac's
    /// upload, holds $4.50.
    func testTheOtherMacsUsageShowsTheSameEverywhere() {
        let scan = CostUsageScanResult(entries: [entry(0, io: 10_000, cost: 2.0), entry(5, io: 40_000, cost: 8.0)])
        let rows = [row(0, io: 25_000, cost: 4.5), row(5, io: 40_000, cost: 8.0), row(14, io: 9_000, cost: 1.5)]
        let s = shown(scan: scan, rows: rows, accountToday: 4.5, accountWeek: 12.5, account30: 14.0)
        XCTAssertEqual(s.cardToday, 4.5, accuracy: 0.0001)
        XCTAssertEqual(s.barToday, s.cardToday, accuracy: 0.0001, "Providers tab's cost bar")
        XCTAssertEqual(s.overviewTopToday, s.cardToday, accuracy: 0.0001, "Overview's Cost Today")
        XCTAssertEqual(s.cardTodayTokens, 25_000)
        XCTAssertEqual(s.overviewTodayTokens, 25_000, "Overview's Cost Summary tokens")
        XCTAssertEqual(s.overviewTopTokens, 25_000, "Overview's Usage Today")
        XCTAssertEqual(s.card30, 14.0, accuracy: 0.0001)
        XCTAssertEqual(s.overview30Row, s.card30, accuracy: 0.0001)
        // The By Model rows are this Mac's $10 under a 30-day figure of $14:
        // they say whose they are, and the figure is not called exact.
        XCTAssertTrue(s.byModelIsThisMacOnly)
        XCTAssertEqual(s.fidelity, .estimated)
        // The fixture tells the two rules apart: this Mac's own today differs.
        XCTAssertNotEqual(scan.totalCost(for: key(0)), s.barToday)
    }

    /// This Mac has counted more than it has uploaded yet: its own figure,
    /// everywhere.
    func testThisMacsNewerCountShowsTheSameEverywhere() {
        let scan = CostUsageScanResult(entries: [entry(0, io: 60_000, cost: 6.0)])
        let rows = [row(0, io: 25_000, cost: 4.5)]
        let s = shown(scan: scan, rows: rows, accountToday: 4.5, accountWeek: 4.5, account30: 4.5)
        XCTAssertEqual(s.cardToday, 6.0, accuracy: 0.0001)
        XCTAssertEqual(s.barToday, 6.0, accuracy: 0.0001)
        XCTAssertEqual(s.overviewTopToday, 6.0, accuracy: 0.0001)
        XCTAssertEqual(s.cardTodayTokens, 60_000)
        XCTAssertEqual(s.overviewTodayTokens, 60_000)
        XCTAssertEqual(s.overview30Row, s.card30, accuracy: 0.0001)
        XCTAssertFalse(s.byModelIsThisMacOnly, "every figure is this Mac's own")
        XCTAssertEqual(s.fidelity, .exact)
    }

    /// Signed out there is no account: this Mac's own figures, and synced
    /// rows left over from an account are not read.
    func testSignedOutShowsThisMacEverywhere() {
        let scan = CostUsageScanResult(entries: [entry(0, io: 10_000, cost: 2.0)])
        let s = shown(scan: scan, rows: [row(0, io: 99_000, cost: 99)],
                      accountToday: 0, accountWeek: 0, account30: 0, authenticated: false)
        XCTAssertEqual(s.cardToday, 2.0, accuracy: 0.0001)
        XCTAssertEqual(s.barToday, 2.0, accuracy: 0.0001)
        XCTAssertEqual(s.overviewTopToday, 2.0, accuracy: 0.0001)
        XCTAssertEqual(s.cardTodayTokens, 10_000)
        XCTAssertEqual(s.overviewTodayTokens, 10_000)
        XCTAssertFalse(s.byModelIsThisMacOnly)
    }

    /// "30-Day" is 30 days: the scan reaches back to a 31st day key, which
    /// the Cost Summary used to add in.
    func testTheThirtyDaysLeaveOutTheScansThirtyFirstDay() {
        let scan = CostUsageScanResult(entries: [entry(0, io: 1, cost: 1), entry(30, io: 1, cost: 100)])
        let state = AppState()
        state.costUsageScanResult = scan
        state.updateCostSummary()
        XCTAssertEqual(state.costSummary.thirtyDayTotal, 1, accuracy: 0.0001)
        XCTAssertEqual(state.costSummary.thirtyDayTokens, 1)
        XCTAssertFalse(state.costSummary.costByModel.contains { $0.cost >= 100 })
    }

    /// Signing out drops the account's daily rows with the rest of its data.
    func testSigningOutDropsTheAccountsDailyRows() {
        let state = AppState()
        state.dailyUsage = [row(0, io: 1, cost: 1)]
        state.applySignedOutState()
        XCTAssertTrue(state.dailyUsage.isEmpty)
    }
}

/// Demo's account rows behind the Mac cards add up to the figures Demo gives
/// each provider, as a real account's do (`provider_summary` sums the same
/// rows over the same windows).
final class DemoProviderCardHistoryTests: XCTestCase {

    private func cents(_ value: Double) -> Int { Int((value * 100).rounded()) }

    func testTheRowsAddUpToEachProvidersFigures() throws {
        let now = Date(timeIntervalSince1970: 1_791_342_000)
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let providers = DemoDataProvider.generate().providers
        let rows = DemoDataProvider.providerCardHistory(providers: providers, now: now, timeZone: tz)
        let windows = ProviderUsageWindows(now: now, timeZone: tz)
        var checked = 0
        for usage in providers where usage.estimated_cost_30_day > 0 {
            let card = ProviderCardUsageBuilder.build(
                provider: usage.provider, usage: usage, scanEntries: [], cloudRows: rows,
                readsCloud: true, windows: windows)
            let own = rows.filter { $0.provider == usage.provider }
            func rowCents(_ w: ProviderUsageWindow) -> Int {
                own.filter { windows.contains($0.date, in: w) }.reduce(0) { $0 + cents($1.cost) }
            }
            XCTAssertEqual(rowCents(.today), cents(usage.estimated_cost_today), usage.provider)
            XCTAssertEqual(rowCents(.week), cents(usage.estimated_cost_week), usage.provider)
            XCTAssertEqual(rowCents(.thirtyDays), cents(usage.estimated_cost_30_day), usage.provider)
            XCTAssertEqual(card.today.ioTokens, usage.today_usage, usage.provider)
            XCTAssertEqual(card.week.ioTokens, usage.week_usage, usage.provider)
            let thirty = try XCTUnwrap(card.thirtyDays.ioTokens)
            XCTAssertGreaterThan(thirty, usage.week_usage)
            XCTAssertTrue(card.chartHasData(.tokens))
            XCTAssertTrue(Set(own.map(\.date)).isSubset(of: Set(windows.dayKeys)))
            checked += 1
        }
        XCTAssertEqual(checked, 2, "Codex and Claude")
        // Gemini is quota-only: no rows.
        XCTAssertFalse(rows.contains { $0.provider == "Gemini" })
        // The same rows every time.
        XCTAssertEqual(rows.map(\.id), DemoDataProvider.providerCardHistory(
            providers: providers, now: now, timeZone: tz).map(\.id))
    }

    /// The card's days are Demo's own history (`dailyUsage`, what the usage
    /// dashboard draws) scaled to the provider's figures: no bar on a day the
    /// history has idle, and within the week and within the rest of the month
    /// a busier history day is never a shorter bar.
    func testTheDaysHaveTheShapeOfDemosHistory() {
        let now = Date(timeIntervalSince1970: 1_791_342_000)
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let providers = DemoDataProvider.generate().providers
        let rows = DemoDataProvider.providerCardHistory(providers: providers, now: now, timeZone: tz)
        let year = DemoDataProvider.dailyUsage(days: 365, today: now, calendar: DayKey.calendar(in: tz))
        let keys = Array(ProviderUsageWindows(now: now, timeZone: tz).dayKeys.reversed())   // offset 0 = today
        var compared = 0
        for provider in ["Codex", "Claude"] {
            var history: [String: Int] = [:]
            for row in year where row.provider == provider {
                history[row.date, default: 0] += row.inputTokens + row.cachedTokens + row.outputTokens
            }
            var card: [String: Int] = [:]
            for row in rows where row.provider == provider {
                card[row.date, default: 0] += row.inputTokens + row.outputTokens
            }
            for key in keys.dropFirst() where history[key] == nil {
                XCTAssertNil(card[key], "\(provider) has a bar on \(key), an idle day in Demo's history")
            }
            for span in [1..<7, 7..<keys.count] {
                for i in span {
                    for j in span where (history[keys[i]] ?? 0) > (history[keys[j]] ?? 0) {
                        XCTAssertGreaterThanOrEqual(card[keys[i]] ?? 0, card[keys[j]] ?? 0,
                                                    "\(provider): \(keys[i]) against \(keys[j])")
                        compared += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 100, "the history has busy and quiet days to compare")
    }

    /// Demo on the Mac is a signed-in account, so its cards read these rows.
    @MainActor
    func testDemoOnTheMacGivesTheCardsTheAccountsRows() {
        let suite = "DemoProviderCardHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        state.enterDemoMode()
        XCTAssertEqual(Set(state.dailyUsage.map(\.provider)), ["Codex", "Claude"])
        let codex = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: state.providers.first { $0.provider == "Codex" },
            scanEntries: [], cloudRows: state.dailyUsage, readsCloud: state.isAuthenticated)
        XCTAssertEqual(codex.scope, .allDevices)
        XCTAssertTrue(codex.chartHasData(.tokens))
        XCTAssertEqual(codex.today.cost ?? -1, 1.03, accuracy: 0.0001)
    }

    func testApportionAddsUpExactly() {
        XCTAssertEqual(DemoDataProvider.apportion(10, by: [1, 1, 1]).reduce(0, +), 10)
        XCTAssertEqual(DemoDataProvider.apportion(7, by: [0, 2, 1]), [0, 5, 2])
        XCTAssertEqual(DemoDataProvider.apportion(0, by: [1, 2]), [0, 0])
        XCTAssertEqual(DemoDataProvider.apportion(5, by: [0, 0]), [0, 0])
    }
}

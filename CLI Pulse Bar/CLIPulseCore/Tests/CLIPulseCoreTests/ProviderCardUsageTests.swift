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
        // Day by day: today the account's $4.50, day 2 this Mac's $6 (it
        // has not synced all of it). The account's own week ($8.50) is less.
        XCTAssertEqual(u.week.cost ?? -1, 10.5, accuracy: 0.0001)
        XCTAssertEqual(u.week.ioTokens, 55_000)
        XCTAssertEqual(u.thirtyDays.cost ?? -1, 11.5, accuracy: 0.0001)
        XCTAssertEqual(u.thirtyDays.ioTokens, 63_000)
        // Day by day: day 2 is this Mac's 30K (more than the 20K synced),
        // today the account's, and day 12 only the account has.
        let tokenDays = u.chartDays(.tokens)
        XCTAssertEqual(tokenDays.count, 30)
        XCTAssertEqual(tokenDays.first { $0.dateKey == key(2) }?.tokens, 30_000)
        XCTAssertEqual(tokenDays.first { $0.dateKey == key(2) }?.cost, 6.0, "one source's day, not a mix")
        XCTAssertEqual(tokenDays.last?.tokens, 25_000)
        XCTAssertEqual(tokenDays.first { $0.dateKey == key(12) }?.tokens, 8_000)
        XCTAssertEqual(u.chartDays(.cost).last?.cost, 4.5)
        // The chart the card draws: these bars, scaled to the tallest.
        XCTAssertEqual(u.chart(.tokens).bars, tokenDays)
        XCTAssertEqual(u.chart(.tokens).highest, 30_000)
        XCTAssertEqual(u.chart(.cost).highest, 6.0)
        XCTAssertTrue(u.chart(.cost).hasData)
        // Today's bar is the Today figure, in either measure.
        XCTAssertEqual(tokenDays.last.map { Double($0.tokens) }, u.today.ioTokens.map(Double.init))
        XCTAssertEqual(u.chartDays(.cost).last?.cost, u.today.cost)
    }

    /// Tokens and cost each take their own larger source (the builder's
    /// doc): today this Mac has counted tokens it has not synced yet, while
    /// another device's pricier model makes the account's day cost more.
    func testTokensAndCostEachTakeTheirOwnLargerSource() {
        let u = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil,
            scanEntries: [scan(0, io: 30_000, cost: 2.0)],
            cloudRows: [row(0, io: 25_000, cost: 4.5)],
            readsCloud: true, windows: windows)
        XCTAssertEqual(u.today.ioTokens, 30_000, "this Mac's tokens")
        XCTAssertEqual(u.today.cost, 4.5, "the account's cost")
        XCTAssertEqual(u.week.ioTokens, 30_000)
        XCTAssertEqual(u.week.cost, 4.5)
        // Each bar is still one source's whole day.
        XCTAssertEqual(u.chart(.tokens).bars.last?.cost, 2.0)
        XCTAssertEqual(u.chart(.cost).bars.last?.tokens, 25_000)
    }

    /// The figures are the chart's bars added up. A window taken whole (the
    /// larger of this Mac's month and the account's) dropped this Mac's
    /// unsynced days whenever the account held more over the month: This
    /// Week read 120 beside seven bars adding up to 170.
    func testTheFiguresAreTheBarsAddedUp() {
        // This Mac's last three days have not synced (an upload failed);
        // the account holds another Mac's busy month.
        let entries = [
            scan(0, io: 50, cost: 5), scan(1, io: 30, cost: 3), scan(2, io: 40, cost: 4),
            scan(4, io: 10, cost: 1),
        ]
        let rows = [
            row(0, io: 20, cost: 2), row(4, io: 60, cost: 6), row(5, io: 10, cost: 1),
            row(9, io: 300, cost: 30), row(20, io: 160, cost: 16),
        ]
        let u = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: usage(today: 5, week: 9, thirty: 55),
            scanEntries: entries, cloudRows: rows, readsCloud: true, windows: windows)
        for metric in UsageChartMetric.allCases {
            let bars = u.chartDays(metric)
            func sum(_ window: ProviderUsageWindow) -> Double {
                bars.filter { windows.contains($0.dateKey, in: window) }.reduce(0) { $0 + $1.value(metric) }
            }
            func figure(_ window: ProviderUsageWindow) -> Double {
                metric == .cost ? u.cell(window).cost ?? -1 : Double(u.cell(window).ioTokens ?? -1)
            }
            for window in ProviderUsageWindow.allCases {
                XCTAssertEqual(figure(window), sum(window), accuracy: 0.0001, "\(metric) \(window)")
            }
        }
        XCTAssertEqual(u.today.ioTokens, 50)
        XCTAssertEqual(u.week.ioTokens, 190, "50 + 30 + 40 + 60 + 10: every unsynced day of this Mac's")
        XCTAssertEqual(u.thirtyDays.ioTokens, 650)
        XCTAssertEqual(u.thirtyDays.cost ?? -1, 65, accuracy: 0.0001, "more than the account's $55")
        // The account's own figure is a floor: before its rows arrive, the
        // card shows it rather than this Mac's alone.
        let early = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: usage(today: 5, week: 9, thirty: 55),
            scanEntries: entries, cloudRows: [], readsCloud: true, windows: windows)
        XCTAssertEqual(early.thirtyDays.cost ?? -1, 55, accuracy: 0.0001)
        XCTAssertEqual(early.week.cost ?? -1, 13, accuracy: 0.0001, "this Mac's $13 is more than the account's $9")
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
        XCTAssertFalse(u.chart(.tokens).hasData)
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
        // Its figures are the API's count for the key, wherever it was
        // used: neither "This Mac" nor "All devices".
        XCTAssertFalse(u.hasScope)
        // A count of 0 is a count: "0", not the "—" of nothing counting.
        let quiet = ProviderCardUsageBuilder.build(
            provider: "OpenRouter", usage: usage("OpenRouter", todayUsage: 0, weekUsage: 40),
            scanEntries: [], cloudRows: [], readsCloud: true, usesProviderTokenCounts: true,
            windows: windows)
        XCTAssertEqual(quiet.today.ioTokens, 0)
        // Its cost: today and the week are the collector's; nothing covers 30
        // days (signed out, no 30-day figure), so that cost is "—", not a
        // $0.00 below Today's $1.20.
        let costed = ProviderCardUsageBuilder.build(
            provider: "OpenRouter",
            usage: usage("OpenRouter", today: 1.2, week: 5.0, thirty: 0, todayUsage: 12_000, weekUsage: 40_000),
            scanEntries: [], cloudRows: [], readsCloud: false, usesProviderTokenCounts: true,
            windows: windows)
        XCTAssertEqual(costed.today.cost, 1.2)
        XCTAssertEqual(costed.week.cost, 5.0)
        XCTAssertNil(costed.thirtyDays.cost)
        XCTAssertNil(costed.thirtyDays.ioTokens)
        // With a 30-day figure from the account, it has one.
        let synced = ProviderCardUsageBuilder.build(
            provider: "OpenRouter", usage: usage("OpenRouter", today: 1.2, week: 5.0, thirty: 18),
            scanEntries: [], cloudRows: [], readsCloud: true, usesProviderTokenCounts: true,
            windows: windows)
        XCTAssertEqual(synced.thirtyDays.cost, 18)
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

    // MARK: - The iPhone and iPad card

    /// A row as the server keeps it (`daily_usage_metrics`).
    private func account(
        _ daysAgo: Int, _ provider: String = "Codex", model: String = "gpt-5.5",
        input: Int, cached: Int, output: Int, cost: Double
    ) -> DailyUsage {
        DailyUsage(date: key(daysAgo), provider: provider, model: model,
                   inputTokens: input, cachedTokens: cached, outputTokens: output, cost: cost)
    }

    /// The iPhone card's Today and This Week are its chart's rows added up,
    /// in I/O. Codex's input already holds its cached input, so the cached
    /// input is in the figure once; `provider_summary`, which the card used
    /// to show, added it again (input + cached + output) until migrate_v0.86.
    /// Asserted in Chinese, where the unit's help is not the English fallback.
    func testTheIPhoneCardCountsCodexsCachedInputOnceInZhHans() throws {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("zh-Hans")
        let rows = [
            account(0, input: 100_000, cached: 80_000, output: 10_000, cost: 0.50),
            account(3, input: 40_000, cached: 30_000, output: 5_000, cost: 0.20),
            // In the 30 days, not the week.
            account(12, input: 900_000, cached: 800_000, output: 50_000, cost: 3.00),
            // Another provider's day.
            account(0, "Claude", model: "claude-sonnet-4-5", input: 7_000, cached: 0, output: 0, cost: 9),
        ]
        // `provider_summary` over the same rows before migrate_v0.86: input +
        // cached + output. The figures below are the rows' either way.
        let summary = usage(today: 0.50, week: 0.70, thirty: 3.70, todayUsage: 190_000, weekUsage: 265_000)
        let figures = ProviderCardAccountFigures(provider: summary, cloudRows: rows, windows: windows)

        XCTAssertTrue(figures.today.countsRows)
        XCTAssertEqual(figures.today.tokensText, "110K I/O", "Codex's cached input counted twice")
        XCTAssertEqual(figures.today.tokensValue, "110K")
        XCTAssertEqual(figures.week.tokensText, "155K I/O", "Codex's cached input counted twice in the week")
        XCTAssertEqual(figures.today.cost ?? -1, 0.50, accuracy: 1e-9)
        XCTAssertEqual(figures.week.cost ?? -1, 0.70, accuracy: 1e-9)
        XCTAssertEqual(figures.today.tokensHelp,
                       "输入 + 输出 token。输入已包含缓存输入，与 OpenAI 的统计口径一致。费用预估中，缓存输入按缓存输入的单价计算。")
        XCTAssertEqual(figures.week.tokensHelp, figures.today.tokensHelp)

        // The chart beside them draws those days: today's bar is Today, the
        // last seven bars are This Week, and the day a tap opens says so.
        let days = try XCTUnwrap(figures.chartDays)
        XCTAssertEqual(days.basis, .inputOutput)
        XCTAssertEqual(days.scope, .allDevices)
        XCTAssertEqual(days.days.last?.dateKey, key(0))
        XCTAssertEqual(days.day(key(0))?.tokens, 110_000)
        XCTAssertEqual(days.days.suffix(7).reduce(0) { $0 + $1.tokens }, 155_000)
        let today = try XCTUnwrap(days.day(key(0)))
        XCTAssertEqual(today.summary(basis: days.basis, showsCost: false), today.dateText + "：110K I/O token")
        XCTAssertEqual(figures.rows?.thirtyDays.ioTokens, 1_105_000)
    }

    /// Claude's I/O leaves its cache out, which is most of a Claude user's
    /// tokens and all of the summary's surplus.
    func testTheIPhoneCardsClaudeFiguresLeaveCacheOut() {
        let rows = [account(0, "Claude", model: "claude-sonnet-4-5",
                            input: 2_000, cached: 500_000, output: 1_000, cost: 0.40)]
        let summary = usage("Claude", today: 0.40, week: 0.40, thirty: 0.40, todayUsage: 503_000, weekUsage: 503_000)
        let figures = ProviderCardAccountFigures(provider: summary, cloudRows: rows, windows: windows)
        XCTAssertEqual(figures.today.tokensText, ProviderCardUsage.tokenBasis.tokensText(3_000))
        XCTAssertEqual(figures.week.tokensText, ProviderCardUsage.tokenBasis.tokensText(3_000))
        XCTAssertEqual(figures.today.tokensHelp, L10n.providers.claudeIOTokensHelp)
    }

    /// The cost is the rows' cost with the summary's as a floor, as on the
    /// Mac: rows that arrived after the summary was built raise it; a
    /// summary built after the last rows keeps it.
    func testTheIPhoneCardsCostKeepsTheSummaryAsAFloor() {
        let rows = [
            account(0, input: 10_000, cached: 0, output: 1_000, cost: 0.30),
            account(2, input: 10_000, cached: 0, output: 1_000, cost: 0.60),
        ]
        let summary = usage(today: 0.50, week: 0.60, thirty: 0.60, todayUsage: 11_000, weekUsage: 22_000)
        let figures = ProviderCardAccountFigures(provider: summary, cloudRows: rows, windows: windows)
        XCTAssertEqual(figures.today.cost ?? -1, 0.50, accuracy: 1e-9, "the summary is the floor")
        XCTAssertEqual(figures.week.cost ?? -1, 0.90, accuracy: 1e-9, "the rows add up to more")
    }

    /// Without rows for the provider in the 30 days (none uploaded, or only
    /// another provider's, or older ones) the card keeps the summary's
    /// figures as it showed them before, unlabelled, and draws no chart.
    func testTheIPhoneCardWithoutRowsKeepsTheSummarysFigures() {
        let summary = usage(today: 0.50, week: 0.70, thirty: 3.70, todayUsage: 190_000, weekUsage: 265_000)
        for rows in [
            [],
            [account(0, "Claude", model: "claude-sonnet-4-5", input: 7_000, cached: 0, output: 0, cost: 9)],
            [account(30, input: 100_000, cached: 80_000, output: 10_000, cost: 0.50)],   // the 31st day back
        ] {
            let figures = ProviderCardAccountFigures(provider: summary, cloudRows: rows, windows: windows)
            XCTAssertNil(figures.rows, "\(rows.map(\.date))")
            XCTAssertNil(figures.chartDays)
            XCTAssertFalse(figures.today.countsRows)
            XCTAssertEqual(figures.today.tokensText, CostFormatter.formatUsage(190_000), "the summary's Today")
            XCTAssertEqual(figures.today.tokensValue, figures.today.tokensText)
            XCTAssertEqual(figures.week.tokensText, CostFormatter.formatUsage(265_000), "the summary's This Week")
            XCTAssertEqual(figures.today.tokensHelp, "")
            XCTAssertEqual(figures.today.cost, 0.50)
            XCTAssertEqual(figures.week.cost, 0.70)
        }
    }

    /// Rows this month and none today: Today is the Mac card's dash, not the
    /// summary's count on its other basis.
    func testTheIPhoneCardsTodayWithNoRowToday() {
        let rows = [account(4, input: 20_000, cached: 15_000, output: 2_000, cost: 0.25)]
        let summary = usage(today: 0, week: 0.25, thirty: 0.25, todayUsage: 0, weekUsage: 37_000)
        let figures = ProviderCardAccountFigures(provider: summary, cloudRows: rows, windows: windows)
        XCTAssertTrue(figures.today.countsRows)
        XCTAssertEqual(figures.today.tokensText, "—")
        XCTAssertNil(figures.today.tokensValue)
        XCTAssertEqual(figures.today.cost, 0)
        XCTAssertEqual(figures.week.tokensText, ProviderCardUsage.tokenBasis.tokensText(22_000))
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
        // This Mac reads as the panel's This Mac (one string); All devices is
        // the card's own, with its day-by-day rule.
        XCTAssertEqual(ProviderCardUsage.scopeHelp(.thisMac), "根据这台 Mac 上的日志统计。")
        XCTAssertEqual(ProviderCardUsage.scopeHelp(.thisMac), L10n.providerPanel.scopeThisMacHelp)
        XCTAssertEqual(ProviderCardUsage.scopeHelp(.allDevices),
                       "同步自登录了你账户的所有设备。如果这台 Mac 统计到的比已同步的多，则显示这台 Mac 的统计。")
        XCTAssertEqual(L10n.providerCard.sectionsAllShown, "已全部显示")
        XCTAssertEqual(L10n.providerCard.thirtyDays, "30 天")
        XCTAssertEqual(ProviderCardSection.dailyChart.title, "每日图表")
        XCTAssertEqual(L10n.providerCard.sectionsHiddenCount(2), "已隐藏 2 项")
        XCTAssertTrue(L10n.providerCard.chartTokensHelp("12K").contains("12K"))
        XCTAssertEqual(L10n.providerCard.chartCostHelp("$3"), "最近 30 天每天的预估费用。单日最高：$3。")
        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(UsageDataScope.allDevices.label, "すべてのデバイス")
    }

    /// The card's unit is the panel's: "I/O", which Spanish calls "E/S".
    func testTheCardsTokenUnitIsThePanels() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        XCTAssertEqual(ProviderCardUsage.tokenBasis, .inputOutput)
        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(ProviderCardUsage.tokenBasis.tokensText(85_900), CostFormatter.formatUsage(85_900) + " E/S")
        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(ProviderCardUsage.tokenBasis.tokensText(85_900), "85.9K I/O")
    }

    /// The card names a scope only for figures from days the panel shows.
    func testTheScopeIsNamedOnlyForTheScansOrTheAccountsDays() {
        let signedOut = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil, scanEntries: [scan(3, io: 10, cost: 1)], cloudRows: [],
            readsCloud: false, windows: windows)
        XCTAssertTrue(signedOut.hasScope)
        let accountOnly = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil, scanEntries: [], cloudRows: [row(3, io: 10, cost: 1)],
            readsCloud: true, windows: windows)
        XCTAssertTrue(accountOnly.hasScope)
        let collectorOnly = ProviderCardUsageBuilder.build(
            provider: "Mistral", usage: usage("Mistral", today: 1, week: 2, todayUsage: 10, weekUsage: 20),
            scanEntries: [], cloudRows: [], readsCloud: true, usesProviderTokenCounts: true, windows: windows)
        XCTAssertTrue(collectorOnly.hasAnyFigure)
        XCTAssertFalse(collectorOnly.hasScope)
    }

    /// West of UTC in the evening, `get_daily_usage`'s 30 days, counted back
    /// from the server's UTC date, start a day after the user's 30 do. The
    /// app asks for one more, and the card keeps the user's own 30 days.
    func testTheAccountsRowsCoverTheUsersOldestDayWestOfUTC() {
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        // 2026-10-14 20:00 in California, 2026-10-15 03:00 UTC.
        let evening = Date(timeIntervalSince1970: 1_792_033_200)
        let w = ProviderUsageWindows(now: evening, timeZone: pacific)
        XCTAssertEqual(w.todayKey, "2026-10-14")
        XCTAssertEqual(w.startKey(.thirtyDays), "2026-09-15")
        // The server's first day for a fetch of `days`, from its UTC date.
        let utc = TimeZone(identifier: "UTC")!
        func serverFirstDay(_ days: Int) -> String {
            let calendar = DayKey.calendar(in: utc)
            let first = calendar.date(byAdding: .day, value: -(days - 1), to: evening)!
            return DayKey.string(from: first, in: utc)
        }
        XCTAssertEqual(serverFirstDay(30), "2026-09-16", "30 days from the UTC date miss the oldest day")
        XCTAssertLessThanOrEqual(serverFirstDay(AppState.dailyUsageFetchDays), w.startKey(.thirtyDays))
        // Every zone, at every hour: the fetch reaches the user's oldest day.
        for offsetHours in -12...14 {
            let zone = TimeZone(secondsFromGMT: offsetHours * 3_600)!
            for hour in stride(from: 0, to: 24, by: 1) {
                let instant = evening.addingTimeInterval(Double(hour) * 3_600)
                let zoneWindows = ProviderUsageWindows(now: instant, timeZone: zone)
                let calendar = DayKey.calendar(in: utc)
                let first = calendar.date(byAdding: .day, value: -(AppState.dailyUsageFetchDays - 1), to: instant)!
                XCTAssertLessThanOrEqual(DayKey.string(from: first, in: utc), zoneWindows.startKey(.thirtyDays),
                                         "UTC\(offsetHours) +\(hour)h")
            }
        }
        // The rows such a fetch returns: the oldest day counts, a day before
        // it (a fetch reaching further) does not.
        let rows = [
            DailyUsage(date: "2026-09-14", provider: "Codex", model: "gpt-5.5",
                       inputTokens: 900, cachedTokens: 0, outputTokens: 0, cost: 9),
            DailyUsage(date: "2026-09-15", provider: "Codex", model: "gpt-5.5",
                       inputTokens: 100, cachedTokens: 0, outputTokens: 0, cost: 1),
            DailyUsage(date: "2026-10-14", provider: "Codex", model: "gpt-5.5",
                       inputTokens: 20, cachedTokens: 0, outputTokens: 0, cost: 0.2),
        ]
        let u = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil, scanEntries: [], cloudRows: rows, readsCloud: true, windows: w)
        XCTAssertEqual(u.thirtyDays.ioTokens, 120)
        XCTAssertEqual(u.thirtyDays.cost ?? -1, 1.2, accuracy: 0.0001)
        XCTAssertEqual(u.chartDays(.tokens).first?.dateKey, "2026-09-15")
        XCTAssertEqual(u.chartDays(.tokens).first?.tokens, 100)
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

    /// This Mac has counted days the account has not received (an upload
    /// failed) while the account holds more over the month: the card, the
    /// cost bar and the Overview all count those days, and the 30 days are
    /// the card's bars added up.
    func testThisMacsUnsyncedDaysCountEverywhere() {
        let scan = CostUsageScanResult(entries: [
            entry(0, io: 5_000, cost: 1.0), entry(1, io: 30_000, cost: 3.0), entry(2, io: 40_000, cost: 4.0),
        ])
        let rows = [row(0, io: 2_000, cost: 0.5), row(4, io: 60_000, cost: 6.0), row(9, io: 300_000, cost: 30.0)]
        let s = shown(scan: scan, rows: rows, accountToday: 0.5, accountWeek: 6.5, account30: 36.5)
        XCTAssertEqual(s.cardToday, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.barToday, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.card30, 44.0, accuracy: 0.0001, "1 + 3 + 4 + 6 + 30, more than the account's $36.50")
        XCTAssertEqual(s.overview30Row, s.card30, accuracy: 0.0001)
        XCTAssertEqual(s.cardTodayTokens, 5_000)
        XCTAssertEqual(s.overviewTodayTokens, 5_000)

        let state = AppState()
        state.isAuthenticated = true
        state.costUsageScanResult = scan
        state.dailyUsage = rows
        state.providers = [cloudProvider("Codex", today: 0.5, week: 6.5, thirty: 36.5, scan: scan)]
        state.updateCostSummary()
        XCTAssertEqual(state.costSummary.thirtyDayTokens, 435_000, "5K + 30K + 40K + 60K + 300K")
        let card = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: state.providers[0], scanEntries: scan.entries,
            cloudRows: rows, readsCloud: true)
        XCTAssertEqual(card.chartDays(.cost).reduce(0) { $0 + $1.cost }, s.card30, accuracy: 0.0001)
    }

    /// A failed fetch of the account's rows keeps the last good ones: the
    /// cards would otherwise drop to this Mac's figures under "All devices"
    /// until the next refresh. An answer with no rows replaces them.
    func testAFailedFetchKeepsTheAccountsRows() {
        let suite = "ProviderCardTodayAgreesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Not the app's bundle: quarantined, so nothing reaches the real
        // widgets' data.
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(
                infoDictionary: ["CFBundleIdentifier": "com.example.clipulse"], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        XCTAssertFalse(state.runtimeEnvironment.capabilities.allowsWidgetPublishing)
        state.isAuthenticated = true
        let rows = [row(0, io: 25_000, cost: 4.5)]
        state.adoptFetchedDailyUsage(rows)
        XCTAssertEqual(state.dailyUsage.map(\.id), rows.map(\.id))
        XCTAssertEqual(state.adoptFetchedDailyUsage(nil).map(\.id), rows.map(\.id))
        XCTAssertEqual(state.dailyUsage.map(\.id), rows.map(\.id), "a failed fetch is not an empty account")
        state.adoptFetchedDailyUsage([])
        XCTAssertTrue(state.dailyUsage.isEmpty)
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

/// Demo's account rows behind the provider cards (the Mac's, and the iPhone
/// and iPad's chart) add up to the figures Demo gives each provider: the cost
/// as a real account's does (`provider_summary` sums the same rows' cost over
/// the same windows), the tokens as the Mac card counts them (the rows' I/O).
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
            XCTAssertTrue(card.chart(.tokens).hasData)
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
        let usage = state.providers.first { $0.provider == "Codex" }
        // As `EnhancedProviderCard.cardUsage` builds it.
        let codex = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: usage,
            scanEntries: [], cloudRows: state.dailyUsage, readsCloud: state.isAuthenticated,
            usesProviderTokenCounts: !(usage?.metadata?.supports_quota ?? false))
        XCTAssertEqual(codex.scope, .allDevices)
        XCTAssertTrue(codex.hasScope)
        XCTAssertTrue(codex.chart(.tokens).hasData)
        XCTAssertEqual(codex.today.cost ?? -1, 1.03, accuracy: 0.0001)
        XCTAssertEqual(codex.today.ioTokens, 85_900)
    }

    /// Try Demo on an iPhone or iPad (the Demo App Review uses) is the same
    /// signed-in account, so its cards get the same rows, and draw them the
    /// way `iOSEnhancedProviderCard` does (`ProviderCardAccountFigures`): the
    /// chart and a tapped day from the rows in I/O, and Today and This Week
    /// those rows added up, as a real account's card adds up its own. Their
    /// cost agrees with the card's figures and with the 30-Day figure above
    /// the cards, as a real account's rows do. Only Codex and Claude have
    /// rows: nothing records Gemini's usage, so its card keeps the summary's
    /// figures.
    @MainActor
    func testDemoGivesTheIPhoneCardsTheSameRows() throws {
        let state = demoState()
        let now = Date()
        let todayKey = DayKey.string(from: now)
        let windows = ProviderUsageWindows(now: now)
        var drawn: [String] = []
        for usage in state.providers {
            // As `iOSEnhancedProviderCard` builds it.
            let figures = ProviderCardAccountFigures(provider: usage, cloudRows: state.dailyUsage, windows: windows)
            guard usage.estimated_cost_30_day > 0 else {
                XCTAssertNil(figures.chartDays, "\(usage.provider) has a chart no real account's rows draw")
                XCTAssertFalse(figures.today.countsRows, usage.provider)
                XCTAssertEqual(figures.today.tokensText, CostFormatter.formatUsage(usage.today_usage), usage.provider)
                continue
            }
            let days = try XCTUnwrap(figures.chartDays, usage.provider)
            XCTAssertTrue(days.hasUsage, usage.provider)
            XCTAssertEqual(days.scope, .allDevices, usage.provider)
            XCTAssertEqual(days.basis, .inputOutput, usage.provider)
            XCTAssertEqual(days.days.count, 30, usage.provider)
            let today = try XCTUnwrap(days.day(todayKey), usage.provider)
            XCTAssertEqual(today.tokens, usage.today_usage, "\(usage.provider): Demo's rows against Demo's Today")
            XCTAssertEqual(figures.today.tokensText, ProviderCardUsage.tokenBasis.tokensText(today.tokens),
                           "\(usage.provider): the card's Today is not its chart's day")
            XCTAssertEqual(cents(today.cost), cents(usage.estimated_cost_today), usage.provider)
            XCTAssertEqual(cents(figures.today.cost ?? -1), cents(today.cost), usage.provider)
            let week = days.days.filter { windows.contains($0.dateKey, in: .week) }
            XCTAssertEqual(week.count, 7, usage.provider)
            let weekTokens = week.reduce(0) { $0 + $1.tokens }
            XCTAssertEqual(weekTokens, usage.week_usage, "\(usage.provider): Demo's rows against Demo's This Week")
            XCTAssertEqual(figures.week.tokensText, ProviderCardUsage.tokenBasis.tokensText(weekTokens),
                           "\(usage.provider): the card's This Week is not its chart's last seven days")
            XCTAssertEqual(cents(week.reduce(0) { $0 + $1.cost }), cents(usage.estimated_cost_week), usage.provider)
            XCTAssertEqual(cents(figures.week.cost ?? -1), cents(usage.estimated_cost_week), usage.provider)
            XCTAssertEqual(cents(days.days.reduce(0) { $0 + $1.cost }), cents(usage.estimated_cost_30_day),
                           usage.provider)
            for day in days.days where day.hasUsage {
                // A tapped day lists its one model, priced, as a real
                // account's priced model is: never the dash of a synced row
                // that arrived with no cost.
                XCTAssertEqual(day.models.count, 1, "\(usage.provider) \(day.dateKey)")
                XCTAssertFalse(day.hasUnknownCost, "\(usage.provider) \(day.dateKey) has tokens and no cost")
                XCTAssertGreaterThan(day.tokens, 0, "\(usage.provider) \(day.dateKey) has a cost and no tokens")
            }
            drawn.append(usage.provider)
        }
        XCTAssertEqual(Set(drawn), ["Codex", "Claude"])
        // The Providers tab's Today and 30-Day Est. above the cards are the
        // same rows added up.
        func rowCents(_ window: ProviderUsageWindow) -> Int {
            cents(state.dailyUsage.filter { windows.contains($0.date, in: window) }.reduce(0) { $0 + $1.cost })
        }
        XCTAssertEqual(cents(state.costSummary.todayTotal), rowCents(.today))
        XCTAssertEqual(cents(state.costSummary.thirtyDayTotal), rowCents(.thirtyDays))
    }

    /// No day of Demo's rows, whenever Demo is entered, has tokens with no
    /// cost or a cost with no tokens: the iPhone's day detail would show it
    /// as a synced row whose cost is unknown, which a priced model's row
    /// never is. Checked over two months of days, since each day's cents are
    /// the month's shared out by that day's weight.
    func testNoDayHasTokensWithoutACost() {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let providers = DemoDataProvider.generate().providers
        for day in 0..<60 {
            let now = Date(timeIntervalSince1970: 1_791_342_000 + Double(day) * 86_400)
            for row in DemoDataProvider.providerCardHistory(providers: providers, now: now, timeZone: tz) {
                let io = row.inputTokens + row.outputTokens
                XCTAssertEqual(io > 0, row.cost > 0, "\(row.provider) \(row.date) entered \(now)")
            }
        }
    }

    /// The card's chart in zh-Hans, as Try Demo draws it: the section title
    /// and the day a tap selects, with Demo's own figures.
    @MainActor
    func testDemosIPhoneCardInZhHans() throws {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("zh-Hans")
        let state = demoState()
        let todayKey = DayKey.string(from: Date())
        let codex = try XCTUnwrap(state.providers.first { $0.provider == "Codex" })
        let figures = ProviderCardAccountFigures(provider: codex, cloudRows: state.dailyUsage)
        let days = try XCTUnwrap(figures.chartDays)
        // Today above the chart, in the chart's unit, and what VoiceOver
        // hints it counts.
        XCTAssertEqual(figures.today.tokensText, "85.9K I/O")
        XCTAssertEqual(figures.today.tokensHelp,
                       "输入 + 输出 token。输入已包含缓存输入，与 OpenAI 的统计口径一致。费用预估中，缓存输入按缓存输入的单价计算。")
        // `ProviderUsageHistorySection`'s title.
        XCTAssertEqual(L10n.widget.usageTitle + " · " + days.scope.label, "用量 · 所有设备")
        let today = try XCTUnwrap(days.day(todayKey))
        XCTAssertTrue(today.dateText.hasSuffix("日"), today.dateText)
        XCTAssertEqual(today.summary(basis: days.basis, showsCost: true),
                       today.dateText + "：" + CostFormatter.format(1.03) + " · 85.9K I/O token")
        XCTAssertEqual(today.summary(basis: days.basis, showsCost: false),
                       today.dateText + "：85.9K I/O token")
        // The Token / Cost picker beside the title.
        XCTAssertEqual(UsageChartMetric.tokens.label, "token")
        XCTAssertEqual(UsageChartMetric.cost.label, "费用")
        XCTAssertEqual(L10n.providerPanel.closeDay, "隐藏当天明细")
    }

    /// The tests above run on the Mac, the only place `swift test` runs. They
    /// speak for the iPhone and iPad only while Demo gives the rows on every
    /// platform alike, and while the iPhone and iPad card read them as the
    /// tests do. Both are read from the sources here.
    func testTheIPhoneReadsDemosRowsAsTheseTestsDo() throws {
        let demo = try String(
            contentsOf: Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore/DemoDataProvider.swift"),
            encoding: .utf8)
        let lines = demo.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("public func enterDemoMode()") },
                                  "enterDemoMode moved; recheck where Demo gives the rows")
        let end = try XCTUnwrap(lines[start...].firstIndex { $0 == "    }" }, "enterDemoMode has no end")
        let body = lines[start..<end]
        let assignment = try XCTUnwrap(
            body.firstIndex { $0.contains("dailyUsage = DemoDataProvider.providerCardHistory(providers: demo.providers)") },
            "enterDemoMode no longer gives the cards Demo's rows")
        var depth = 0
        for line in lines[start..<assignment] {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("#if") { depth += 1 }
            if code.hasPrefix("#endif") { depth -= 1 }
        }
        XCTAssertEqual(depth, 0, "Demo's rows are behind a compile-time check: not every platform's Demo gets them")

        let tab = Self.codeOnly(try String(
            contentsOf: Self.coreRoot.deletingLastPathComponent()
                .appendingPathComponent("CLI Pulse Bar iOS/iOSProvidersTab.swift"),
            encoding: .utf8))
        // The iPad grid's card and the iPhone list's card.
        XCTAssertEqual(tab.components(separatedBy: "dailyUsage: state.dailyUsage").count - 1, 2,
                       "an iPhone or iPad provider card no longer gets the account's rows")
        // Its figures and its chart, one build of the rows.
        XCTAssertEqual(tab.components(separatedBy: "ProviderCardAccountFigures(provider: provider, cloudRows: dailyUsage)").count - 1, 1,
                       "the iPhone card reads its rows another way; make these tests read them that way")
        XCTAssertTrue(tab.contains("if let usageDays = figures.chartDays {"),
                      "the iPhone card's chart no longer draws the days its figures add up")
        XCTAssertTrue(tab.contains("usageFigure(L10n.dashboard.today, figures.today,"),
                      "the iPhone card's Today is no longer the rows' figure")
        XCTAssertTrue(tab.contains("usageFigure(L10n.providers.thisWeek, figures.week,"),
                      "the iPhone card's This Week is no longer the rows' figure")
        // Nothing on the card prints the summary's token counts past them.
        for summary in ["provider.today_usage", "provider.week_usage", "ProviderUsageDays.fromCloud("] {
            XCTAssertFalse(tab.contains(summary), "iOSProvidersTab reads \(summary) again")
        }
    }

    @MainActor
    private func demoState() -> AppState {
        let suite = "DemoProviderCardHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        state.enterDemoMode()
        return state
    }

    /// `CLI Pulse Bar/CLIPulseCore`.
    private static var coreRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
    }

    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// On the Mac, Demo's providers carry the metadata their collectors
    /// attach, as a real Mac's do, so the card draws what production draws:
    /// a quota provider's I/O ("85.9K I/O"), not an API's own count.
    func testDemoOnTheMacCarriesItsCollectorsMetadata() throws {
        let providers = DemoDataProvider.generate().providers
        for name in ["Codex", "Claude", "Gemini"] {
            let metadata = try XCTUnwrap(providers.first { $0.provider == name }?.metadata, name)
            XCTAssertEqual(metadata.display_name, name)
            XCTAssertEqual(metadata.category, "cloud", name)
            XCTAssertTrue(metadata.supports_quota, name)
            XCTAssertFalse(metadata.supports_exact_cost, name)
        }
    }

    func testApportionAddsUpExactly() {
        XCTAssertEqual(DemoDataProvider.apportion(10, by: [1, 1, 1]).reduce(0, +), 10)
        XCTAssertEqual(DemoDataProvider.apportion(7, by: [0, 2, 1]), [0, 5, 2])
        XCTAssertEqual(DemoDataProvider.apportion(0, by: [1, 2]), [0, 0])
        XCTAssertEqual(DemoDataProvider.apportion(5, by: [0, 0]), [0, 0])
    }
}

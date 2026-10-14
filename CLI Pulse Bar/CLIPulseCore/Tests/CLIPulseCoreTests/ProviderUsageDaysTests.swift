import XCTest
@testable import CLIPulseCore

/// v1.57 (P1-2): one provider's last 30 days by day and model, the data of
/// the usage panel's provider mode and of the iPhone card's day detail.
///
/// Text is asserted in zh-Hans: the English fallback of a missing key reads
/// as English, so an English assertion passes with the lookup broken.
final class ProviderUsageDaysTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let today = "2026-10-07"
    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    private func entry(
        _ date: String, _ provider: String, _ model: String,
        input: Int, cached: Int = 0, output: Int, cost: Double?, approximate: Bool = false, messages: Int = 0
    ) -> CostUsageScanResult.DailyEntry {
        .init(date: date, provider: provider, model: model,
              inputTokens: input, cachedTokens: cached, outputTokens: output,
              costUSD: cost, priceIsApproximate: approximate, messageCount: messages)
    }

    // MARK: - The acceptance: a day's figure is the sum of its model rows

    /// Selecting Sep 24 lists that day's models, and the day's total is
    /// exactly the sum of the rows it lists, for tokens and for cost.
    func testSelectedDayTotalIsTheSumOfItsModelRows() {
        let entries = [
            entry("2026-09-24", "Codex", "gpt-5.1-codex", input: 9_000_000, cached: 8_100_000, output: 52_000, cost: 21.37),
            entry("2026-09-24", "Codex", "gpt-5-codex", input: 3_400_000, cached: 3_000_000, output: 18_000, cost: 6.81),
            entry("2026-09-24", "Codex", "gpt-5.1-codex-mini", input: 900_000, cached: 700_000, output: 9_000, cost: 0.43,
                  approximate: true),
            entry("2026-09-28", "Codex", "gpt-5.1-codex", input: 1_000_000, cached: 900_000, output: 1_000, cost: 2.0),
            entry("2026-09-24", "Claude", "claude-sonnet-4-5", input: 5_000, cached: 90_000, output: 4_000, cost: 1.0),
        ]
        let days = ProviderUsageDays.fromScan(entries, provider: "Codex", todayKey: today, timeZone: utc)
        guard let day = days.day("2026-09-24") else { return XCTFail("Sep 24 is in the window") }

        XCTAssertEqual(day.models.map(\.model), ["gpt-5.1-codex", "gpt-5-codex", "gpt-5.1-codex-mini"])
        XCTAssertEqual(day.tokens, day.models.reduce(0) { $0 + $1.tokens })
        XCTAssertEqual(day.cost, day.models.reduce(0) { $0 + $1.cost })
        // And both match the rows as they came: Codex's input already holds
        // its cached input, so each row is input + output.
        XCTAssertEqual(day.tokens, 9_052_000 + 3_418_000 + 909_000)
        XCTAssertEqual(day.cost, 21.37 + 6.81 + 0.43, accuracy: 1e-9)
        // Claude's row that day is Claude's, not Codex's.
        XCTAssertFalse(day.models.contains { $0.model.hasPrefix("claude") })
    }

    /// The same for the synced rows the iPhone card reads.
    func testCloudDayTotalIsTheSumOfItsModelRows() {
        let rows = [
            DailyUsage(date: "2026-09-24", provider: "Codex", model: "gpt-5.1-codex",
                       inputTokens: 2_000, cachedTokens: 1_500, outputTokens: 100, cost: 0.75),
            DailyUsage(date: "2026-09-24", provider: "Codex", model: "gpt-5-codex",
                       inputTokens: 800, cachedTokens: 0, outputTokens: 40, cost: 0.25),
            DailyUsage(date: "2026-09-24", provider: "Gemini", model: "gemini-2.5-pro",
                       inputTokens: 9_999, cachedTokens: 0, outputTokens: 1, cost: 9.0),
        ]
        let days = ProviderUsageDays.fromCloud(rows, provider: "Codex", basis: .inputOutput,
                                               todayKey: today, timeZone: utc)
        let day = days.day("2026-09-24")
        XCTAssertEqual(day?.tokens, 2_100 + 840)
        XCTAssertEqual(day?.tokens, day?.models.reduce(0) { $0 + $1.tokens })
        XCTAssertEqual(day?.cost ?? 0, 1.0, accuracy: 1e-12)
        XCTAssertEqual(days.scope, .allDevices)
    }

    // MARK: - Window

    func testWindowIsThirtyContiguousDaysEndingToday() {
        let entries = [
            entry("2026-09-07", "Codex", "gpt-5-codex", input: 10, output: 1, cost: 1),   // 31 days back
            entry("2026-09-08", "Codex", "gpt-5-codex", input: 20, output: 2, cost: 2),   // first day
            entry("2026-10-07", "Codex", "gpt-5-codex", input: 30, output: 3, cost: 3),   // today
            entry("2026-10-08", "Codex", "gpt-5-codex", input: 40, output: 4, cost: 4),   // tomorrow
        ]
        let days = ProviderUsageDays.fromScan(entries, provider: "Codex", todayKey: today, timeZone: utc)
        XCTAssertEqual(days.days.count, 30)
        XCTAssertEqual(days.days.first?.dateKey, "2026-09-08")
        XCTAssertEqual(days.days.last?.dateKey, "2026-10-07")
        XCTAssertEqual(Set(days.days.map(\.dateKey)).count, 30)
        XCTAssertEqual(days.totalTokens, 22 + 33)
        XCTAssertEqual(days.totalCost, 5, accuracy: 1e-12)
        // Idle days are there, with nothing in them.
        XCTAssertEqual(days.days.filter(\.hasUsage).count, 2)
        XCTAssertEqual(days.day("2026-09-20")?.models, [])
    }

    func testWindowCrossesAMonthAndAYearBoundary() {
        let keys = ProviderUsageDays.dayKeys(count: 3, endingAt: "2027-01-01", timeZone: utc)
        XCTAssertEqual(keys, ["2026-12-30", "2026-12-31", "2027-01-01"])
        XCTAssertEqual(ProviderUsageDays.dayKeys(count: 3, endingAt: "not a day", timeZone: utc), [])
    }

    /// The provider card asks `hasUsage` before it offers the panel; it must
    /// say what the panel's days would say, for every kind of row.
    func testTheCardsQuickCheckAgreesWithTheDays() {
        let scans: [[CostUsageScanResult.DailyEntry]] = [
            [],
            [entry("2026-10-06", "Codex", ScanEntry.messageBucketModel, input: 0, output: 0, cost: nil, messages: 9)],
            [entry("2026-09-01", "Codex", "gpt-5-codex", input: 10, output: 1, cost: 1)],   // before the window
            [entry("2026-10-06", "Claude", "claude-sonnet-4-5", input: 10, output: 1, cost: 1)],
            [entry("2026-10-06", "Codex", "gpt-5-codex", input: 0, output: 0, cost: 0)],
            [entry("2026-10-06", "Codex", "gpt-5-codex", input: 0, output: 0, cost: 0.4)],
            [entry("2026-10-06", "Codex", "gpt-5-codex", input: 12, output: 0, cost: nil)],
        ]
        let clouds: [[DailyUsage]] = [
            [],
            [DailyUsage(date: "2026-10-06", provider: "Codex", model: "gpt-5-codex",
                        inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 0)],
            [DailyUsage(date: "2026-10-06", provider: "Codex", model: "gpt-5-codex",
                        inputTokens: 0, cachedTokens: 30, outputTokens: 0, cost: 0)],
            [DailyUsage(date: "2026-10-08", provider: "Codex", model: "gpt-5-codex",
                        inputTokens: 5, cachedTokens: 0, outputTokens: 5, cost: 1)],   // tomorrow
        ]
        var sawBoth = (yes: false, no: false)
        for scan in scans {
            for cloud in clouds {
                let built = ProviderUsageDays.fromScan(scan, provider: "Codex", todayKey: today, timeZone: utc).hasUsage
                    || ProviderUsageDays.fromCloud(cloud, provider: "Codex", todayKey: today, timeZone: utc).hasUsage
                let quick = ProviderUsageDays.hasUsage(provider: "Codex", scan: scan, cloud: cloud,
                                                       todayKey: today, timeZone: utc)
                XCTAssertEqual(quick, built, "scan \(scan.map(\.model)) cloud \(cloud.map(\.date))")
                if built { sawBoth.yes = true } else { sawBoth.no = true }
            }
        }
        XCTAssertTrue(sawBoth.yes && sawBoth.no, "the fixtures cover both answers")
    }

    func testOtherProvidersAndTheMessageBucketAreLeftOut() {
        let entries = [
            entry("2026-10-06", "Claude", "claude-sonnet-4-5", input: 100, cached: 1_000, output: 50, cost: 0.5),
            entry("2026-10-06", "Claude", ScanEntry.messageBucketModel, input: 0, output: 0, cost: nil, messages: 42),
            entry("2026-10-06", "Codex", "gpt-5-codex", input: 999, output: 9, cost: 9),
        ]
        let days = ProviderUsageDays.fromScan(entries, provider: "Claude", todayKey: today, timeZone: utc)
        XCTAssertEqual(days.day("2026-10-06")?.models.map(\.model), ["claude-sonnet-4-5"])
        // The bucket has no rate; left in, it would mark the day partial.
        XCTAssertFalse(days.hasUnpriced)
        XCTAssertEqual(days.totalTokens, 1_150)
    }

    // MARK: - Token basis

    func testEachOnceCountsCodexCachedInputOnceAndClaudeCacheIn() {
        let entries = [
            entry("2026-10-06", "Codex", "gpt-5-codex", input: 1_000, cached: 900, output: 10, cost: 1),
            entry("2026-10-06", "Claude", "claude-sonnet-4-5", input: 100, cached: 900, output: 10, cost: 1),
        ]
        let codex = ProviderUsageDays.fromScan(entries, provider: "Codex", todayKey: today, timeZone: utc)
        let claude = ProviderUsageDays.fromScan(entries, provider: "Claude", todayKey: today, timeZone: utc)
        XCTAssertEqual(codex.totalTokens, 1_010, "Codex's cached input is part of its input")
        XCTAssertEqual(claude.totalTokens, 1_010, "Claude's cache reads and writes are tokens too")
        XCTAssertEqual(codex.totalTokens, ArchiveTokenBasis.tokens(of: entries[0]))
    }

    func testInputOutputIsTheCardsIO() {
        let entries = [
            entry("2026-10-06", "Codex", "gpt-5-codex", input: 1_000, cached: 900, output: 10, cost: 1),
            entry("2026-10-06", "Claude", "claude-sonnet-4-5", input: 100, cached: 900, output: 10, cost: 1),
        ]
        XCTAssertEqual(ProviderUsageDays.fromScan(entries, provider: "Codex", basis: .inputOutput,
                                                  todayKey: today, timeZone: utc).totalTokens, 1_010)
        XCTAssertEqual(ProviderUsageDays.fromScan(entries, provider: "Claude", basis: .inputOutput,
                                                  todayKey: today, timeZone: utc).totalTokens, 110)
    }

    // MARK: - Order, selection, top model

    func testModelsOrderByCostThenTokensThenName() {
        let rows = [
            ProviderUsageDays.ModelRow(model: "b", tokens: 10, cost: 1),
            ProviderUsageDays.ModelRow(model: "a", tokens: 10, cost: 1),
            ProviderUsageDays.ModelRow(model: "c", tokens: 99, cost: 1),
            ProviderUsageDays.ModelRow(model: "d", tokens: 1, cost: 5),
            ProviderUsageDays.ModelRow(model: "e", tokens: 500, cost: 0, unpricedTokens: 500),
        ]
        XCTAssertEqual(ProviderUsageDays.Day(dateKey: today, models: rows).models.map(\.model),
                       ["d", "c", "a", "b", "e"])
    }

    func testTheLatestDayWithUsageIsSelectedByDefault() {
        let entries = [
            entry("2026-10-01", "Codex", "gpt-5-codex", input: 10, output: 1, cost: 1),
            entry("2026-10-04", "Codex", "gpt-5-codex", input: 10, output: 1, cost: 1),
        ]
        let days = ProviderUsageDays.fromScan(entries, provider: "Codex", todayKey: today, timeZone: utc)
        XCTAssertEqual(days.latestActiveDayKey, "2026-10-04")
        XCTAssertNil(ProviderUsageDays.fromScan([], provider: "Codex", todayKey: today, timeZone: utc).latestActiveDayKey)
    }

    func testTopModelIsTheMostExpensiveOverTheWindow() {
        let entries = [
            entry("2026-10-01", "Codex", "gpt-5-codex", input: 5_000, output: 10, cost: 3),
            entry("2026-10-02", "Codex", "gpt-5-codex", input: 5_000, output: 10, cost: 3),
            entry("2026-10-02", "Codex", "gpt-5.1-codex", input: 100, output: 10, cost: 5),
        ]
        let days = ProviderUsageDays.fromScan(entries, provider: "Codex", todayKey: today, timeZone: utc)
        XCTAssertEqual(days.topModelByCost, "gpt-5-codex")
    }

    // MARK: - Unpriced and approximate

    func testAModelWithNoRateMakesTheDayALowerBoundAndNamesNoTopModel() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let entries = [
            entry("2026-10-06", "Claude", "claude-sonnet-4-5", input: 100, cached: 900, output: 10, cost: 2.5),
            entry("2026-10-06", "Claude", "glm-4.6", input: 400, cached: 0, output: 20, cost: nil),
        ]
        let days = ProviderUsageDays.fromScan(entries, provider: "Claude", todayKey: today, timeZone: utc)
        guard let day = days.day("2026-10-06") else { return XCTFail("no day") }
        let unpriced = day.models.first { $0.model == "glm-4.6" }
        XCTAssertEqual(unpriced?.hasNoRate, true)
        XCTAssertEqual(unpriced?.costText, "无单价")
        XCTAssertTrue(day.hasUnpriced)
        XCTAssertTrue(day.costText.hasPrefix(CostFormatter.atLeastMark), day.costText)
        XCTAssertTrue(days.totalCostText.hasPrefix(CostFormatter.atLeastMark))
        // Its tokens still count; only the cost is missing.
        XCTAssertEqual(day.tokens, 1_010 + 420)
        XCTAssertEqual(day.cost, 2.5, accuracy: 1e-12)
        XCTAssertNil(days.topModelByCost, "no ranking is claimed while a model has no rate")
        XCTAssertTrue(days.coverage.shouldDisclose)
        XCTAssertEqual(days.coverage.unpricedModels, ["glm-4.6"])
    }

    func testABorrowedRateIsMarkedApproximate() {
        let entries = [
            entry("2026-10-06", "Codex", "gpt-5.1-codex-mini", input: 100, output: 10, cost: 0.2, approximate: true),
        ]
        let days = ProviderUsageDays.fromScan(entries, provider: "Codex", todayKey: today, timeZone: utc)
        let day = days.day("2026-10-06")
        XCTAssertEqual(day?.isApproximate, true)
        XCTAssertTrue(day?.costText.hasPrefix(CostFormatter.approximateMark) ?? false)
        XCTAssertTrue(day?.models.first?.costText.hasPrefix(CostFormatter.approximateMark) ?? false)
        XCTAssertTrue(days.coverage.hasApproximatePrices)
    }

    /// A synced row arrives with a cost of 0 both when the device that
    /// uploaded it had no rate (`APIClient.syncDailyUsage` sends a missing
    /// cost as 0) and when the model is priced at 0. Which one is not in the
    /// row, so its cost is shown as unknown, never as "$0.00", and the day
    /// and the window are marked as lower bounds. Asserted in zh-Hans.
    func testASyncedRowWithTokensAndNoCostIsNotShownAsAPrice() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let rows = [
            DailyUsage(date: "2026-10-05", provider: "Claude", model: "claude-sonnet-4-5",
                       inputTokens: 400, cachedTokens: 0, outputTokens: 100, cost: 2.5),
            DailyUsage(date: "2026-10-05", provider: "Claude", model: "glm-4.6",
                       inputTokens: 300, cachedTokens: 0, outputTokens: 50, cost: 0),
            // The same model on two devices: one priced it, one sent 0.
            DailyUsage(date: "2026-10-06", provider: "Claude", model: "claude-opus-4-1",
                       inputTokens: 100, cachedTokens: 0, outputTokens: 10, cost: 1.25),
            DailyUsage(date: "2026-10-06", provider: "Claude", model: "claude-opus-4-1",
                       inputTokens: 60, cachedTokens: 0, outputTokens: 5, cost: 0),
            // A day with nothing but an unknown cost.
            DailyUsage(date: "2026-10-07", provider: "Claude", model: "glm-4.6",
                       inputTokens: 70, cachedTokens: 0, outputTokens: 7, cost: 0),
        ]
        let days = ProviderUsageDays.fromCloud(rows, provider: "Claude", basis: .inputOutput,
                                               todayKey: today, timeZone: utc)
        guard let mixed = days.day("2026-10-05"), let split = days.day("2026-10-06"),
              let unknown = days.day("2026-10-07") else { return XCTFail("days in the window") }

        let glm = mixed.models.first { $0.model == "glm-4.6" }
        XCTAssertEqual(glm?.costIsUnknown, true)
        XCTAssertEqual(glm?.costText, ProviderUsageDays.unknownCostText)
        XCTAssertNotEqual(glm?.costText, CostFormatter.format(0), "never a confident $0.00")
        XCTAssertEqual(glm?.hasNoRate, false, "no rate is not known either: the model may be priced at 0")
        XCTAssertEqual(glm?.costHelp, "同步自登录了你账户的所有设备。同步数据不记录哪些 token 没有单价，因此这里的费用可能少算。")
        XCTAssertEqual(glm?.tokens, 350, "its tokens still count")
        XCTAssertEqual(mixed.costText, CostFormatter.atLeastMark + CostFormatter.format(2.5))
        XCTAssertEqual(mixed.costHelp, L10n.providerPanel.scopeAllDevicesHelp)
        XCTAssertEqual(mixed.summary(basis: .inputOutput, showsCost: true),
                       mixed.dateText + "：" + CostFormatter.atLeastMark + CostFormatter.format(2.5) + " · 850 I/O token")

        let opus = split.models.first
        XCTAssertEqual(opus?.tokens, 175)
        XCTAssertEqual(opus?.costIsUnknown, false)
        XCTAssertEqual(opus?.costText, CostFormatter.atLeastMark + CostFormatter.format(1.25),
                       "one device's share is unknown: the row is a lower bound")

        XCTAssertEqual(unknown.costText, ProviderUsageDays.unknownCostText)
        XCTAssertEqual(days.totalCostText, CostFormatter.atLeastMark + CostFormatter.format(3.75))
        XCTAssertEqual(days.totalCostHelp, L10n.providerPanel.scopeAllDevicesHelp)
        XCTAssertNil(days.topModelByCost)

        // This Mac's scan knows a price of 0 from a missing one: $0.00 there
        // is a price.
        let free = ProviderUsageDays.fromScan(
            [entry("2026-10-05", "Codex", "gpt-5.3-codex-spark", input: 900, output: 100, cost: 0)],
            provider: "Codex", todayKey: today, timeZone: utc)
        XCTAssertEqual(free.day("2026-10-05")?.models.first?.costText, CostFormatter.format(0))
        XCTAssertEqual(free.day("2026-10-05")?.costText, CostFormatter.format(0))
    }

    /// The synced rows' each-once basis counts Codex's cached input once,
    /// as the scan's does: it is already part of Codex's input.
    func testEachOnceCountsCodexCachedInputOnceInSyncedRows() {
        let rows = [
            DailyUsage(date: "2026-10-06", provider: "Codex", model: "gpt-5-codex",
                       inputTokens: 1_000, cachedTokens: 900, outputTokens: 10, cost: 1),
            DailyUsage(date: "2026-10-06", provider: "Claude", model: "claude-sonnet-4-5",
                       inputTokens: 100, cachedTokens: 900, outputTokens: 10, cost: 1),
        ]
        let codex = ProviderUsageDays.fromCloud(rows, provider: "Codex", todayKey: today, timeZone: utc)
        let claude = ProviderUsageDays.fromCloud(rows, provider: "Claude", todayKey: today, timeZone: utc)
        XCTAssertEqual(codex.totalTokens, 1_010, "Codex's cached input is part of its input")
        XCTAssertEqual(claude.totalTokens, 1_010, "Claude's cache reads and writes are tokens too")
    }

    /// With costs hidden, a day's models are listed by tokens: the order of
    /// a cost the reader chose not to see is neither followed nor shown.
    func testWithCostsHiddenTheRowsAreInTokenOrder() {
        let day = ProviderUsageDays.Day(dateKey: today, models: [
            .init(model: "opus", tokens: 4_800_000, cost: 13.04),
            .init(model: "sonnet", tokens: 17_600_000, cost: 9.67),
            .init(model: "haiku", tokens: 1_600_000, cost: 0.28),
            .init(model: "glm", tokens: 2_300_000, cost: 0, unpricedTokens: 2_300_000),
            .init(model: "aaa", tokens: 1_600_000, cost: 0.5),
        ])
        XCTAssertEqual(ProviderUsageDays.displayOrder(day.models, showsCost: true).map(\.model),
                       ["opus", "sonnet", "aaa", "haiku", "glm"], "by cost while costs are shown")
        XCTAssertEqual(ProviderUsageDays.displayOrder(day.models, showsCost: false).map(\.model),
                       ["sonnet", "opus", "glm", "aaa", "haiku"], "by tokens, then name, while hidden")
    }

    /// The window moves with today: built once per day and reused, never
    /// reused for another day.
    func testTheWindowMovesWithToday() {
        let entries = [entry("2026-09-08", "Codex", "gpt-5-codex", input: 10, output: 1, cost: 1)]
        XCTAssertTrue(ProviderUsageDays.hasUsage(provider: "Codex", scan: entries, cloud: [],
                                                 todayKey: "2026-10-07", timeZone: utc))
        XCTAssertFalse(ProviderUsageDays.hasUsage(provider: "Codex", scan: entries, cloud: [],
                                                  todayKey: "2026-10-08", timeZone: utc),
                       "a day later, Sep 8 is out of the window")
        XCTAssertEqual(ProviderUsageDays.dayKeys(count: 30, endingAt: "2026-10-08", timeZone: utc).first, "2026-09-09")
        XCTAssertEqual(ProviderUsageDays.dayKeys(count: 30, endingAt: "2026-10-07", timeZone: utc).first, "2026-09-08")
        XCTAssertEqual(ProviderUsageDays.dayKeys(count: 2, endingAt: "2026-10-07", timeZone: utc),
                       ["2026-10-06", "2026-10-07"])
    }

    func testSyncedRowsHaveUnknownCoverageAndNoTopModel() {
        let rows = [
            DailyUsage(date: "2026-10-06", provider: "Codex", model: "gpt-5-codex",
                       inputTokens: 100, cachedTokens: 0, outputTokens: 10, cost: 1),
        ]
        let days = ProviderUsageDays.fromCloud(rows, provider: "Codex", todayKey: today, timeZone: utc)
        XCTAssertEqual(days.coverage, .unknown)
        XCTAssertFalse(days.hasUnpriced)
        XCTAssertNil(days.topModelByCost, "which synced tokens had a rate is not known here")
    }

    // MARK: - Text, in zh-Hans

    func testDaySummaryInZhHans() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let entries = [entry("2026-10-03", "Codex", "gpt-5-codex", input: 6_500_000, output: 0, cost: 11.42)]
        let days = ProviderUsageDays.fromScan(entries, provider: "Codex", todayKey: today, timeZone: utc)
        guard let day = days.day("2026-10-03") else { return XCTFail("no day") }
        let summary = day.summary(basis: .eachOnce, showsCost: true)
        XCTAssertEqual(summary, day.dateText + "：" + CostFormatter.format(11.42) + " · 6.5M token")
        XCTAssertEqual(day.dateText, "10月3日")
        XCTAssertEqual(day.summary(basis: .inputOutput, showsCost: false), day.dateText + "：6.5M I/O token")
        XCTAssertEqual(days.day("2026-10-04")?.summary(basis: .eachOnce, showsCost: true),
                       (days.day("2026-10-04")?.dateText ?? "") + "：无用量")
        XCTAssertEqual(L10n.providerPanel.estTotal(30), "预估合计 · 最近 30 天")
        XCTAssertEqual(L10n.providerPanel.total(30), "合计 · 最近 30 天")
        XCTAssertEqual(UsageChartMetric.cost.label, "费用")
        XCTAssertEqual(UsageDataScope.thisMac.label, "这台 Mac")
        // The provider card's chart button, as VoiceOver names it.
        XCTAssertEqual(L10n.providerPanel.openFor("Codex"), "Codex 用量历史")
    }

    func testMetricIsReadFromItsStoredValue() {
        XCTAssertEqual(UsageChartMetric.stored("cost"), .cost)
        XCTAssertEqual(UsageChartMetric.stored("tokens"), .tokens)
        XCTAssertEqual(UsageChartMetric.stored(nil), .tokens)
        XCTAssertEqual(UsageChartMetric.stored("bogus"), .tokens)
    }

    func testAtLeastWinsOverApproximate() {
        XCTAssertEqual(CostFormatter.format(1, approximate: true, atLeast: true),
                       CostFormatter.atLeastMark + CostFormatter.format(1))
        XCTAssertEqual(CostFormatter.format(1, approximate: true, atLeast: false),
                       CostFormatter.approximateMark + CostFormatter.format(1))
        XCTAssertEqual(CostFormatter.format(1, approximate: false, atLeast: false), CostFormatter.format(1))
    }

    // MARK: - The chart's columns

    #if !os(watchOS)
    func testABarIsSelectedAnywhereOverItsColumn() {
        let plot = CGRect(x: 40, y: 0, width: 300, height: 100)   // 30 columns of 10 pt
        XCTAssertEqual(UsageDayBarsChart.dayIndex(atX: 40, plot: plot, count: 30), 0)
        XCTAssertEqual(UsageDayBarsChart.dayIndex(atX: 49.9, plot: plot, count: 30), 0)
        XCTAssertEqual(UsageDayBarsChart.dayIndex(atX: 50, plot: plot, count: 30), 1)
        XCTAssertEqual(UsageDayBarsChart.dayIndex(atX: 335, plot: plot, count: 30), 29)
        XCTAssertEqual(UsageDayBarsChart.dayIndex(atX: 340, plot: plot, count: 30), 29)
        XCTAssertNil(UsageDayBarsChart.dayIndex(atX: 39, plot: plot, count: 30), "the y axis is not a day")
        XCTAssertNil(UsageDayBarsChart.dayIndex(atX: 341, plot: plot, count: 30))
        XCTAssertNil(UsageDayBarsChart.dayIndex(atX: 100, plot: plot, count: 0))
    }

    func testVoiceOverMovesTheSelectionADayAtATime() {
        XCTAssertEqual(UsageDayBarsChart.adjustedIndex(from: nil, count: 30, forward: false), 29, "starts on the newest")
        XCTAssertEqual(UsageDayBarsChart.adjustedIndex(from: 10, count: 30, forward: true), 11)
        XCTAssertEqual(UsageDayBarsChart.adjustedIndex(from: 10, count: 30, forward: false), 9)
        XCTAssertEqual(UsageDayBarsChart.adjustedIndex(from: 29, count: 30, forward: true), 29)
        XCTAssertEqual(UsageDayBarsChart.adjustedIndex(from: 0, count: 30, forward: false), 0)
        XCTAssertNil(UsageDayBarsChart.adjustedIndex(from: nil, count: 0, forward: true))
    }
    #endif
}

import XCTest
@testable import CLIPulseCore

/// v1.58: in Cost, a day with usage and no known cost is drawn as a short,
/// outlined grey stub, not as an empty slot that reads like a day with
/// nothing, on the provider panel's chart, the iPhone card's, the Mac card's
/// small one and the Usage Dashboard's Trends; the charts say what the stub
/// is, and the day's line says "cost unknown" in words.
///
/// Text is asserted in zh-Hans: the English fallback of a missing key reads
/// as English, so an English assertion passes with the lookup broken.
final class UnknownCostStubTests: XCTestCase {
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

    private func synced(_ date: String, _ model: String = "claude-sonnet-4-5",
                        input: Int, output: Int, cost: Double) -> DailyUsage {
        DailyUsage(date: date, provider: "Claude", model: model,
                   inputTokens: input, cachedTokens: 0, outputTokens: output, cost: cost)
    }

    private func scanned(_ date: String, _ model: String, input: Int, output: Int,
                         cost: Double?) -> CostUsageScanResult.DailyEntry {
        .init(date: date, provider: "Codex", model: model,
              inputTokens: input, cachedTokens: 0, outputTokens: output, costUSD: cost)
    }

    /// The rows: Oct 3 priced; Oct 4 nothing; Oct 5 a day whose every row
    /// arrived with a cost of 0; Oct 6 a priced model beside one whose cost
    /// is not known.
    private var rows: [DailyUsage] {
        [
            synced("2026-10-03", input: 4_000, output: 1_000, cost: 2.5),
            synced("2026-10-05", input: 3_000, output: 500, cost: 0),
            synced("2026-10-05", "claude-haiku-4-5", input: 700, output: 70, cost: 0),
            synced("2026-10-06", input: 1_000, output: 100, cost: 1.25),
            synced("2026-10-06", "glm-4.6", input: 600, output: 60, cost: 0),
        ]
    }

    // MARK: - Which days

    func testOnlyADayWithUsageAndNoKnownCostIsAStub() throws {
        let days = ProviderUsageDays.fromCloud(rows, provider: "Claude", basis: .inputOutput,
                                               todayKey: today, timeZone: utc)
        XCTAssertEqual(days.day("2026-10-05")?.costIsUnknown, true, "every row arrived with no cost")
        XCTAssertEqual(days.day("2026-10-03")?.costIsUnknown, false, "a priced day")
        XCTAssertEqual(days.day("2026-10-04")?.costIsUnknown, false, "no usage: an empty slot, as before")
        XCTAssertEqual(days.day("2026-10-06")?.costIsUnknown, false,
                       "part of its cost is known: a bar of that cost, marked ≥ in the detail")
        // The panel's and the iPhone card's charts say what a grey bar is
        // while they draw one: in Cost.
        XCTAssertTrue(days.drawsUnknownCostStub(.cost))
        XCTAssertFalse(days.drawsUnknownCostStub(.tokens))
        let priced = ProviderUsageDays.fromCloud(rows.filter { $0.date == "2026-10-03" }, provider: "Claude",
                                                 basis: .inputOutput, todayKey: today, timeZone: utc)
        XCTAssertFalse(priced.drawsUnknownCostStub(.cost))

        // This Mac's scan: tokens with no rate are not known either; a model
        // priced at $0 is a known $0.
        let scan = ProviderUsageDays.fromScan(
            [scanned("2026-10-05", "glm-4.6", input: 900, output: 90, cost: nil),
             scanned("2026-10-06", "gpt-5.3-codex-spark", input: 900, output: 100, cost: 0)],
            provider: "Codex", todayKey: today, timeZone: utc)
        XCTAssertEqual(scan.day("2026-10-05")?.costIsUnknown, true)
        XCTAssertEqual(scan.day("2026-10-06")?.costIsUnknown, false, "priced at $0 is a cost")

        // Synced, the same model arrives with a cost of 0 too, and the
        // tables rate it at $0: a known $0, as This Mac's scan has it, not a
        // stub in All devices beside a $0.00 day in This Mac.
        let synced = ProviderUsageDays.fromCloud(
            [DailyUsage(date: "2026-10-06", provider: "Codex", model: "gpt-5.3-codex-spark",
                        inputTokens: 900, cachedTokens: 0, outputTokens: 100, cost: 0),
             DailyUsage(date: "2026-10-05", provider: "Codex", model: "glm-4.6",
                        inputTokens: 900, cachedTokens: 0, outputTokens: 90, cost: 0)],
            provider: "Codex", todayKey: today, timeZone: utc)
        let spark = try XCTUnwrap(synced.day("2026-10-06"))
        XCTAssertFalse(spark.costIsUnknown)
        XCTAssertEqual(spark.costText, CostFormatter.format(0))
        XCTAssertEqual(spark.models.first?.costText, CostFormatter.format(0))
        XCTAssertEqual(synced.day("2026-10-05")?.costIsUnknown, true, "a model with no rate: not known")
        XCTAssertTrue(ZeroRatedModel.contains("gpt-5.3-codex-spark"))
        XCTAssertFalse(ZeroRatedModel.contains("gpt-5-codex"))
        XCTAssertFalse(ZeroRatedModel.contains("claude-sonnet-4-5"))
        XCTAssertFalse(ZeroRatedModel.contains("glm-4.6"), "no rate is not a rate of $0")
        XCTAssertFalse(ZeroRatedModel.contains(""))
    }

    /// The charts draw the stub in Cost only. Its bar is empty, as a day with
    /// nothing has (no cost is plotted for it); the stub is drawn over its
    /// slot: on the baseline, as wide as a bar, tall enough to show its
    /// outline round a hollow middle and short enough not to be read as a
    /// cost. In Tokens the day is its tokens.
    func testTheStubIsDrawnInCostOnlyAndShort() throws {
        let days = ProviderUsageDays.fromCloud(rows, provider: "Claude", basis: .inputOutput,
                                               todayKey: today, timeZone: utc)
        let unknown = try XCTUnwrap(days.day("2026-10-05"))
        let priced = try XCTUnwrap(days.day("2026-10-03"))
        let empty = try XCTUnwrap(days.day("2026-10-04"))

        XCTAssertTrue(UsageChartMetric.cost.drawsUnknownCostStub(unknown))
        XCTAssertFalse(UsageChartMetric.tokens.drawsUnknownCostStub(unknown))
        XCTAssertFalse(UsageChartMetric.cost.drawsUnknownCostStub(priced))
        XCTAssertFalse(UsageChartMetric.cost.drawsUnknownCostStub(empty))
        XCTAssertEqual(unknown.value(.cost), 0, "no cost is plotted for it")
        XCTAssertEqual(unknown.value(.tokens), Double(unknown.tokens))

        // The provider panel's chart: 30 columns over a plot 110 points tall.
        let plot = CGRect(x: 30, y: 4, width: 300, height: 110)
        let column = plot.width / 30
        let stub = UnknownCostStub.rect(centerX: plot.minX + column * 4.5, columns: 30, plot: plot)
        XCTAssertGreaterThan(stub.height, 0, "an empty slot reads as a day with nothing")
        XCTAssertEqual(stub.maxY, plot.maxY, accuracy: 1e-9, "on the baseline")
        XCTAssertEqual(stub.midX, plot.minX + column * 4.5, accuracy: 1e-9, "on its day")
        XCTAssertEqual(stub.width, column * UnknownCostStub.columnShare, accuracy: 1e-9, "as wide as a bar")
        XCTAssertLessThan(stub.width, column)
        for height: CGFloat in [40, 70, 110, 130, 400] {
            let drawn = UnknownCostStub.height(plotHeight: height)
            XCTAssertGreaterThanOrEqual(drawn, 2 * UnknownCostStub.lineWidth + 3, "\(height): no hollow middle")
            XCTAssertLessThanOrEqual(drawn, 8, "\(height): tall enough to read as a cost")
        }
        // The Mac card's small chart, 28 points: at least 3 points tall.
        XCTAssertGreaterThanOrEqual(ProviderUsageSparkline.stubHeight(available: 28), 3)
        XCTAssertLessThanOrEqual(ProviderUsageSparkline.stubHeight(available: 28), 28 * 0.2)
        XCTAssertEqual(ProviderUsageSparkline.stubHeight(available: 2), 2, "never taller than its chart")
    }

    // MARK: - The Mac card's small chart

    /// The account's day with no known cost reaches the card's chart. The
    /// card takes, day by day, the larger of this Mac's day and the
    /// account's; in Cost both are 0 when this Mac has nothing that day, and
    /// the tie went to this Mac's empty day, so the stub never showed.
    func testTheCardsChartKeepsTheAccountsUnknownCostDay() throws {
        let card = ProviderCardUsageBuilder.build(
            provider: "Claude", usage: nil, scanEntries: [], cloudRows: rows, readsCloud: true,
            windows: ProviderUsageWindows(now: DayKey.date(from: today, hour: 12) ?? Date(), timeZone: utc))
        let chart = card.chart(.cost)
        let bar = try XCTUnwrap(chart.bars.first { $0.dateKey == "2026-10-05" })
        XCTAssertTrue(bar.costIsUnknown, "the account's day, not this Mac's empty one")
        XCTAssertTrue(chart.hasUnknownCostDays)
        XCTAssertFalse(card.chart(.tokens).hasUnknownCostDays, "Tokens draws the day's tokens")
        // The figures are unchanged: the tie is on cost, and the cost added
        // up is the same whichever day is drawn.
        XCTAssertEqual(card.thirtyDays.cost ?? -1, 3.75, accuracy: 1e-9)
    }

    /// A chart whose only usage has no known cost is still drawn (its
    /// stubs), and its help says what a grey bar is, with no "highest day".
    func testTheCardsChartHelpSaysWhatTheGreyBarIs() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let onlyUnknown = rows.filter { $0.date == "2026-10-05" }
        let card = ProviderCardUsageBuilder.build(
            provider: "Claude", usage: nil, scanEntries: [], cloudRows: onlyUnknown, readsCloud: true,
            windows: ProviderUsageWindows(now: DayKey.date(from: today, hour: 12) ?? Date(), timeZone: utc))
        let chart = card.chart(.cost)
        XCTAssertEqual(chart.highest, 0)
        XCTAssertTrue(chart.hasData, "a chart of stubs is drawn")
        XCTAssertEqual(ProviderCardUsage.chartHelp(chart), "最近 30 天每天的预估费用。\n灰色短柱表示该日有用量，但费用未知。")

        let mixed = ProviderCardUsageBuilder.build(
            provider: "Claude", usage: nil, scanEntries: [], cloudRows: rows, readsCloud: true,
            windows: ProviderUsageWindows(now: DayKey.date(from: today, hour: 12) ?? Date(), timeZone: utc))
        XCTAssertEqual(ProviderCardUsage.chartHelp(mixed.chart(.cost)),
                       L10n.providerCard.chartCostHelp(CostFormatter.format(2.5)) + "\n" + "灰色短柱表示该日有用量，但费用未知。")
        XCTAssertEqual(ProviderCardUsage.chartHelp(mixed.chart(.tokens)),
                       L10n.providerCard.chartTokensHelp(CostFormatter.formatUsage(5_000)),
                       "Tokens draws no stub and says nothing about one")
    }

    // MARK: - The day's line

    /// The selected day's line says "cost unknown" in words, on screen and to
    /// VoiceOver, for a day none of whose cost is known: synced rows that
    /// arrived with no cost (the dash) and models with no rate on this Mac
    /// ("≥$0.00", read as about free). A day with a known part reads as
    /// before.
    func testTheDaysLineSaysCostUnknownInWords() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let days = ProviderUsageDays.fromCloud(rows, provider: "Claude", basis: .inputOutput,
                                               todayKey: today, timeZone: utc)
        let unknown = try XCTUnwrap(days.day("2026-10-05"))
        XCTAssertEqual(unknown.summary(basis: .inputOutput, showsCost: true), "10月5日：费用未知 · 4.3K I/O token")
        XCTAssertEqual(unknown.summary(basis: .inputOutput, showsCost: false), "10月5日：4.3K I/O token")
        XCTAssertEqual(unknown.costText, ProviderUsageDays.unknownCostText, "the cost alone is still the dash")
        let partly = try XCTUnwrap(days.day("2026-10-06"))
        XCTAssertEqual(partly.summary(basis: .inputOutput, showsCost: true),
                       "10月6日：" + CostFormatter.atLeastMark + CostFormatter.format(1.25) + " · 1.8K I/O token")

        let scan = ProviderUsageDays.fromScan(
            [scanned("2026-10-05", "glm-4.6", input: 900, output: 90, cost: nil)],
            provider: "Codex", basis: .inputOutput, todayKey: today, timeZone: utc)
        let noRate = try XCTUnwrap(scan.day("2026-10-05"))
        XCTAssertEqual(noRate.costText, CostFormatter.atLeastMark + CostFormatter.format(0))
        XCTAssertEqual(noRate.summary(basis: .inputOutput, showsCost: true), "10月5日：费用未知 · 990 I/O token")
    }

    // MARK: - The Usage Dashboard's Trends

    #if os(macOS)
    /// Trends adds the providers of a day: a day is a stub when it has
    /// tokens and none of its providers has a cost, unless every model it
    /// used is rated at $0, whose cost is known.
    func testTrendsDrawsAStubForADayNoProviderHasACostFor() {
        let days: [(key: String, day: DayRollup)] = [
            ("2026-10-01", DayRollup(tokens: 10, cost: 0, perProvider: [
                "Codex": ProviderDaySlice(tokens: 10, cost: 0)],
                perModel: ["gpt-5.3-codex-spark": ModelDaySlice(tokens: 10, cost: 0)])),
            ("2026-10-02", DayRollup(tokens: 30, cost: 0, perProvider: [
                "Codex": ProviderDaySlice(tokens: 30, cost: 0)],
                perModel: ["gpt-5.3-codex-spark": ModelDaySlice(tokens: 10, cost: 0),
                           "glm-4.6": ModelDaySlice(tokens: 20, cost: 0)])),
            ("2026-10-03", DayRollup(tokens: 10, cost: 1, perProvider: [
                "Claude": ProviderDaySlice(tokens: 10, cost: 1)])),
            ("2026-10-04", DayRollup(tokens: 30, cost: 0, perProvider: [
                "Claude": ProviderDaySlice(tokens: 10, cost: 0), "Codex": ProviderDaySlice(tokens: 20, cost: 0)])),
            ("2026-10-05", DayRollup(tokens: 30, cost: 2, perProvider: [
                "Claude": ProviderDaySlice(tokens: 10, cost: 0), "Codex": ProviderDaySlice(tokens: 20, cost: 2)])),
            ("2026-10-06", DayRollup()),
        ]
        XCTAssertEqual(DashboardTrends.unknownCostDays(in: days), ["2026-10-02", "2026-10-04"],
                       "Oct 1 is $0 (rated at $0); Oct 4 has no model breakdown, so it is not known to be")
    }

    /// Trends covers calendar days: a day with no usage keeps its empty slot,
    /// as the provider charts keep it, and "30D" is the last 30 days, not the
    /// last 30 that have records.
    func testTrendsCoversCalendarDays() {
        let now = DayKey.date(from: today, hour: 12) ?? Date()
        let archived = ["2026-09-01", "2026-10-01", "2026-10-05"]
        let week = DashboardTrends.windowKeys(rangeDays: 7, archiveKeys: archived, today: now, timeZone: utc)
        XCTAssertEqual(week, ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04",
                              "2026-10-05", "2026-10-06", "2026-10-07"])
        let month = DashboardTrends.windowKeys(rangeDays: 30, archiveKeys: archived, today: now, timeZone: utc)
        XCTAssertEqual(month.count, 30)
        XCTAssertEqual(month.first, "2026-09-08")
        XCTAssertEqual(month.last, today)
        XCTAssertFalse(month.contains("2026-09-01"), "older than 30 days")
        // All: from the first archived day to today.
        let all = DashboardTrends.windowKeys(rangeDays: -1, archiveKeys: archived, today: now, timeZone: utc)
        XCTAssertEqual(all.first, "2026-09-01")
        XCTAssertEqual(all.last, today)
        XCTAssertEqual(all.count, 37)
        XCTAssertEqual(DashboardTrends.windowKeys(rangeDays: -1, archiveKeys: [], today: now, timeZone: utc), [])
        // A day another device wrote ahead of this Mac's time zone is kept.
        let ahead = DashboardTrends.windowKeys(rangeDays: 7, archiveKeys: ["2026-10-08"], today: now, timeZone: utc)
        XCTAssertEqual(ahead.last, "2026-10-08")
        XCTAssertEqual(ahead.count, 7)
    }
    #endif

    // MARK: - The words

    func testTheWordsAreTranslated() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(L10n.providerPanel.costUnknown, "费用未知")
        XCTAssertEqual(L10n.providerPanel.costUnknownHelp, "灰色短柱表示该日有用量，但费用未知。")
        XCTAssertEqual(L10n.providerCard.chartCostUnknownHelp, L10n.providerPanel.costUnknownHelp)
        LocaleOverrideStore.shared.set("zh-Hant")
        XCTAssertEqual(L10n.providerPanel.costUnknownHelp, "灰色短柱表示該日有用量，但費用未知。")
        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(L10n.providerPanel.costUnknown, "コスト不明")
        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(L10n.providerPanel.costUnknown, "costo desconocido")
        XCTAssertEqual(L10n.providerPanel.costUnknownHelp,
                       "Una barra gris corta indica un día con uso cuyo costo se desconoce.")
    }

    // MARK: - The QA render's sample

    /// `chart-cost-unknown-days` draws from the synced Claude sample with two
    /// days zeroed: the same rows on every run, and those two days, and only
    /// they, are unknown.
    func testTheRendersSampleHasTwoUnknownDays() {
        let now = DayKey.date(from: today, hour: 12) ?? Date()
        let sample = QARenderSnapshot.costUnknownSample(today: now, timeZone: utc)
        let again = QARenderSnapshot.costUnknownSample(today: now, timeZone: utc)
        XCTAssertEqual(sample.unknownDays.count, 2)
        XCTAssertEqual(sample.unknownDays, again.unknownDays)
        XCTAssertEqual(sample.rows.map(\.cost), again.rows.map(\.cost))
        let days = ProviderUsageDays.fromCloud(sample.rows, provider: "Claude", basis: .inputOutput,
                                               todayKey: today, timeZone: utc)
        XCTAssertEqual(days.days.filter(\.costIsUnknown).map(\.dateKey).sorted(), sample.unknownDays.sorted())
        XCTAssertTrue(days.days.contains { $0.cost > 0 }, "the stubs stand beside real bars")
    }
}

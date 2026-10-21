import XCTest
@testable import CLIPulseCore

/// v1.58: in Cost, a day with usage and no known cost is drawn as a short
/// grey stub, not as an empty slot that reads like a day with nothing, on the
/// provider panel's chart, the iPhone card's, the Mac card's small one and
/// the Usage Dashboard's Trends; the charts say what the stub is, and
/// VoiceOver reads "cost unknown".
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

    func testOnlyADayWithUsageAndNoKnownCostIsAStub() {
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
    }

    /// The charts draw the stub in Cost only, a few percent of the tallest
    /// known day, never as tall as the smallest real bar could suggest a
    /// cost; in Tokens the day is its tokens.
    func testTheStubIsDrawnInCostOnlyAndShort() throws {
        let days = ProviderUsageDays.fromCloud(rows, provider: "Claude", basis: .inputOutput,
                                               todayKey: today, timeZone: utc)
        let unknown = try XCTUnwrap(days.day("2026-10-05"))
        let priced = try XCTUnwrap(days.day("2026-10-03"))
        let empty = try XCTUnwrap(days.day("2026-10-04"))
        let top = days.days.map { $0.value(.cost) }.max() ?? 0
        XCTAssertEqual(top, 2.5, accuracy: 1e-12)

        XCTAssertTrue(UsageChartMetric.cost.drawsUnknownCostStub(unknown))
        XCTAssertFalse(UsageChartMetric.tokens.drawsUnknownCostStub(unknown))
        XCTAssertFalse(UsageChartMetric.cost.drawsUnknownCostStub(priced))
        XCTAssertFalse(UsageChartMetric.cost.drawsUnknownCostStub(empty))

        let stub = UsageChartMetric.cost.plottedValue(unknown, top: top)
        XCTAssertGreaterThan(stub, 0, "an empty slot reads as a day with nothing")
        XCTAssertEqual(stub, top * UsageChartMetric.unknownCostStubShare, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(UsageChartMetric.unknownCostStubShare, 0.05)
        XCTAssertEqual(UsageChartMetric.tokens.plottedValue(unknown, top: top), Double(unknown.tokens))
        XCTAssertEqual(UsageChartMetric.cost.plottedValue(priced, top: top), 2.5, accuracy: 1e-12)
        XCTAssertEqual(UsageChartMetric.cost.plottedValue(empty, top: top), 0)
        // Nothing known at all: the stub stands on an axis of 1.
        XCTAssertEqual(UsageChartMetric.cost.plottedValue(unknown, top: 0), UsageChartMetric.unknownCostStubShare)
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
        XCTAssertEqual(ProviderCardUsage.chartHelp(chart), "灰色短条表示当天有用量，但费用未知。")

        let mixed = ProviderCardUsageBuilder.build(
            provider: "Claude", usage: nil, scanEntries: [], cloudRows: rows, readsCloud: true,
            windows: ProviderUsageWindows(now: DayKey.date(from: today, hour: 12) ?? Date(), timeZone: utc))
        XCTAssertEqual(ProviderCardUsage.chartHelp(mixed.chart(.cost)),
                       L10n.providerCard.chartCostHelp(CostFormatter.format(2.5)) + "\n" + "灰色短条表示当天有用量，但费用未知。")
        XCTAssertEqual(ProviderCardUsage.chartHelp(mixed.chart(.tokens)),
                       L10n.providerCard.chartTokensHelp(CostFormatter.formatUsage(5_000)),
                       "Tokens draws no stub and says nothing about one")
    }

    // MARK: - What VoiceOver reads

    func testVoiceOverReadsCostUnknownWhereTheScreenHasADash() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let days = ProviderUsageDays.fromCloud(rows, provider: "Claude", basis: .inputOutput,
                                               todayKey: today, timeZone: utc)
        let unknown = try XCTUnwrap(days.day("2026-10-05"))
        XCTAssertEqual(unknown.summary(basis: .inputOutput, showsCost: true), "10月5日：— · 4.3K I/O token")
        XCTAssertEqual(unknown.spokenSummary(basis: .inputOutput, showsCost: true), "10月5日：费用未知 · 4.3K I/O token")
        XCTAssertEqual(unknown.spokenSummary(basis: .inputOutput, showsCost: false), "10月5日：4.3K I/O token")
        let partly = try XCTUnwrap(days.day("2026-10-06"))
        XCTAssertEqual(partly.spokenSummary(basis: .inputOutput, showsCost: true),
                       partly.summary(basis: .inputOutput, showsCost: true), "a known part is read as the screen shows it")
    }

    // MARK: - The Usage Dashboard's Trends

    #if os(macOS)
    /// Trends adds the providers of a day: a day is a stub when it has
    /// tokens and none of its providers has a cost.
    func testTrendsDrawsAStubForADayNoProviderHasACostFor() {
        let days: [(key: String, day: DayRollup)] = [
            ("2026-10-03", DayRollup(tokens: 10, cost: 1, perProvider: [
                "Claude": ProviderDaySlice(tokens: 10, cost: 1)])),
            ("2026-10-04", DayRollup(tokens: 30, cost: 0, perProvider: [
                "Claude": ProviderDaySlice(tokens: 10, cost: 0), "Codex": ProviderDaySlice(tokens: 20, cost: 0)])),
            ("2026-10-05", DayRollup(tokens: 30, cost: 2, perProvider: [
                "Claude": ProviderDaySlice(tokens: 10, cost: 0), "Codex": ProviderDaySlice(tokens: 20, cost: 2)])),
            ("2026-10-06", DayRollup()),
        ]
        XCTAssertEqual(DashboardTrends.unknownCostDays(in: days), ["2026-10-04"])
    }
    #endif

    // MARK: - The words

    func testTheWordsAreTranslated() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(L10n.providerPanel.costUnknown, "费用未知")
        XCTAssertEqual(L10n.providerPanel.costUnknownHelp, "灰色短条表示当天有用量，但费用未知。")
        XCTAssertEqual(L10n.providerCard.chartCostUnknownHelp, L10n.providerPanel.costUnknownHelp)
        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(L10n.providerPanel.costUnknown, "コスト不明")
        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(L10n.providerPanel.costUnknown, "costo desconocido")
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

import XCTest
@testable import CLIPulseCore

/// v1.56 — a cost charged at a rate borrowed from a neighbouring model is
/// approximate, and the card says so.
///
/// A model with no price of its own has been charged at the closest listed
/// model's rate since August (Claude since May): better than the $0 it read
/// before. But the scanner knew, at the moment it chose the rate, that the
/// rate was borrowed, and threw that away. The figure reached the card looking
/// exactly like a listed price, under a badge that said "Exact".
///
/// Text is asserted in zh-Hans: the English fallback of a missing key reads
/// like a translation, so an English-only assertion passes with the lookup
/// broken.
final class ApproximatePriceCoverageTests: XCTestCase {

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
        _ model: String,
        provider: String = "Codex",
        tokens: Int,
        cost: Double?,
        approximate: Bool = false
    ) -> CostUsageScanResult.DailyEntry {
        CostUsageScanResult.DailyEntry(
            date: "2026-09-30", provider: provider, model: model,
            inputTokens: tokens, cachedTokens: 0, outputTokens: 0,
            costUSD: cost, priceIsApproximate: approximate
        )
    }

    // MARK: - The class

    /// A borrowed rate goes to `approximate`, not `priced`: the load-bearing
    /// assertion. If it lands in `pricedTokens`, nothing downstream can tell a
    /// borrowed rate from a listed one again.
    func testABorrowedRateIsApproximateNotPriced() {
        let coverage = CostCoverage.from(entries: [
            entry("gpt-6-astra", tokens: 700, cost: 7),
            entry("gpt-5.7", tokens: 300, cost: 1.2, approximate: true),
        ])
        XCTAssertEqual(coverage.pricedTokens, 700)
        XCTAssertEqual(coverage.approximateTokens, 300)
        XCTAssertEqual(coverage.unpricedTokens, 0)
        XCTAssertEqual(coverage.approximateModels, ["gpt-5.7"])
        XCTAssertTrue(coverage.hasApproximatePrices)
    }

    /// It still carried a rate, so it does not make the "Priced N% of tokens"
    /// line appear: that line is about tokens counted as $0.
    func testABorrowedRateStillCountsAsHavingARate() {
        let coverage = CostCoverage.from(entries: [
            entry("gpt-6-astra", tokens: 700, cost: 7),
            entry("gpt-5.7", tokens: 300, cost: 1.2, approximate: true),
        ])
        XCTAssertEqual(coverage.pricedPercent, 100)
        XCTAssertFalse(coverage.shouldDisclose)
    }

    func testApproximateModelsAreMostTokensFirstAndNamedOnce() {
        let coverage = CostCoverage.from(entries: [
            entry("small", tokens: 10, cost: 0.1, approximate: true),
            entry("big", tokens: 500, cost: 1, approximate: true),
            entry("big", provider: "Codex", tokens: 500, cost: 1, approximate: true),
            entry("claude-opus-6", provider: "Claude", tokens: 50, cost: 0.5, approximate: true),
        ])
        XCTAssertEqual(coverage.approximateModels, ["big", "claude-opus-6", "small"])
        XCTAssertEqual(coverage.approximateProviders, ["Codex", "Claude"])
    }

    /// A cost of nil is unpriced, whatever the flag says: an entry cannot be
    /// both $0-by-omission and approximately priced.
    func testAnUnpricedEntryIsNeverApproximate() {
        let e = entry("mystery", tokens: 100, cost: nil, approximate: true)
        XCTAssertFalse(e.priceIsApproximate)
        let coverage = CostCoverage.from(entries: [e])
        XCTAssertEqual(coverage.unpricedModels, ["mystery"])
        XCTAssertFalse(coverage.hasApproximatePrices)
    }

    /// A server figure's composition is unknown: it never claims approximate
    /// prices any more than it claims full coverage.
    func testAServerEstimateSaysNothingAboutApproximatePrices() {
        XCTAssertFalse(CostCoverage.unknown.hasApproximatePrices)
        XCTAssertFalse(CostCoverage(basis: .serverEstimate, approximateTokens: 10).hasApproximatePrices)
    }

    // MARK: - The badge

    func testAScanWithABorrowedRateIsNotBadgedExact() {
        let summary = CostSummary(isPrecise: true, coverage: CostCoverage.from(entries: [
            entry("gpt-6-astra", tokens: 700, cost: 7),
            entry("gpt-5.7", tokens: 300, cost: 1.2, approximate: true),
        ]))
        XCTAssertEqual(summary.fidelity, .approximate)
    }

    /// $0-by-omission is the bigger error, so it wins the badge; the card still
    /// shows both lines.
    func testMissingPricesOutrankBorrowedOnes() {
        let summary = CostSummary(isPrecise: true, coverage: CostCoverage.from(entries: [
            entry("gpt-5.7", tokens: 300, cost: 1.2, approximate: true),
            entry("mystery", tokens: 300, cost: nil),
        ]))
        XCTAssertEqual(summary.fidelity, .partial)
        XCTAssertTrue(summary.coverage.hasApproximatePrices)
    }

    func testTodayHasItsOwnCoverage() {
        let summary = CostSummary(
            isPrecise: true,
            coverage: CostCoverage.from(entries: [entry("gpt-5.7", tokens: 1, cost: 1, approximate: true)]),
            todayCoverage: CostCoverage.from(entries: [entry("gpt-6-astra", tokens: 1, cost: 1)])
        )
        XCTAssertTrue(summary.coverage.hasApproximatePrices)
        XCTAssertFalse(summary.todayCoverage.hasApproximatePrices,
                       "a borrowed rate last week says nothing about today's figure")
        XCTAssertFalse(CostSummary().todayCoverage.hasApproximatePrices)
    }

    // MARK: - What it looks like

    func testAnApproximateFigureIsMarked() {
        XCTAssertEqual(CostFormatter.format(12.5, approximate: true), "≈" + CostFormatter.format(12.5))
        XCTAssertEqual(CostFormatter.format(12.5, approximate: false), CostFormatter.format(12.5))
    }

    func testTheTextInChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(L10n.cost.fidelityLabel(.approximate), "近似")
        XCTAssertEqual(L10n.cost.approximateSummary(2), "≈ 部分按近似价估算 · 2 个模型")
        XCTAssertEqual(
            L10n.cost.approximateHelp("gpt-5.7, claude-opus-6"),
            "这些模型还没有自己的价格，按最接近的已列出模型的单价计算。标有 ≈ 的金额包含它们：gpt-5.7, claude-opus-6"
        )
        // The other three badge states are unchanged.
        XCTAssertEqual(L10n.cost.fidelityLabel(.exact), "精确")
        XCTAssertEqual(L10n.cost.fidelityLabel(.partial), "部分")
        XCTAssertEqual(L10n.cost.fidelityLabel(.estimated), "估算")
    }

    /// Every shipped language has the three strings, the "≈" the figures carry,
    /// and the model list in the help.
    func testEveryLanguageCarriesTheMarkAndTheModels() {
        for language in ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"] {
            LocaleOverrideStore.shared.set(language)
            XCTAssertFalse(L10n.cost.approximate.isEmpty, language)
            XCTAssertNotEqual(L10n.cost.approximate, "cost.approximate", language)
            XCTAssertTrue(L10n.cost.approximateSummary(3).hasPrefix("≈"), language)
            XCTAssertTrue(L10n.cost.approximateSummary(3).contains("3"), language)
            XCTAssertTrue(L10n.cost.approximateHelp("gpt-5.7").contains("gpt-5.7"), language)
            XCTAssertTrue(L10n.cost.approximateHelp("gpt-5.7").contains("≈"), language)
        }
    }
}

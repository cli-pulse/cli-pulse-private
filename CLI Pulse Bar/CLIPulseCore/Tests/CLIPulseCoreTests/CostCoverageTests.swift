import XCTest
@testable import CLIPulseCore

/// v1.51 §4 — pricing coverage.
///
/// `DailyEntry.costUSD` is optional and every consumer sums it with
/// `if let cost { total += cost }`, so an unpriced model contributes $0 and
/// leaves no trace. `claude-opus-5` was absent from the total for 25 days across
/// 15.47 billion tokens and the number looked complete throughout.
///
/// The load-bearing test in this file is
/// `testServerEstimateNeverClaimsCoverage`. Everything else pins arithmetic;
/// that one pins the honesty property — that a figure whose composition we
/// cannot see reports NOTHING rather than "100% priced".
final class CostCoverageTests: XCTestCase {

    private func entry(
        model: String,
        input: Int = 0,
        cached: Int = 0,
        output: Int = 0,
        cost: Double?
    ) -> CostUsageScanResult.DailyEntry {
        CostUsageScanResult.DailyEntry(
            date: "2026-08-26",
            provider: "Claude",
            model: model,
            inputTokens: input,
            cachedTokens: cached,
            outputTokens: output,
            costUSD: cost
        )
    }

    // MARK: - The honesty property

    /// A cloud-estimate figure arrives pre-summed from the backend. Its
    /// composition is unknowable from the client, so the ONLY correct report is
    /// silence.
    ///
    /// If this ever fails, the app has started telling users a number is fully
    /// priced when it has no idea — a new false claim of exactly the kind this
    /// whole workstream exists to remove.
    func testServerEstimateNeverClaimsCoverage() {
        let unknown = CostCoverage.unknown
        XCTAssertEqual(unknown.basis, .serverEstimate)
        XCTAssertNil(unknown.pricedFraction,
                     "a figure we cannot see into has no coverage fraction")
        XCTAssertNil(unknown.pricedPercent)
        XCTAssertFalse(unknown.shouldDisclose,
                       "must render nothing rather than a percentage")
        XCTAssertFalse(unknown.isFullyPriced,
                       "unknown is NOT the same as complete — this is the whole point")
    }

    /// `CostSummary`'s default must be the silent one. Every call site that does
    /// not explicitly set coverage is one whose composition we cannot see, so
    /// the default has to fail safe.
    func testCostSummaryDefaultsToUnknownCoverage() {
        XCTAssertEqual(CostSummary().coverage, CostCoverage.unknown)
        XCTAssertFalse(CostSummary().coverage.shouldDisclose)
    }

    // MARK: - Silence when there is nothing to say

    /// A complete scan says nothing. A banner on every launch is a banner
    /// people stop reading.
    func testFullyPricedScanDisclosesNothing() {
        let coverage = CostCoverage.from(entries: [
            entry(model: "claude-sonnet-5", input: 100, output: 50, cost: 0.02),
            entry(model: "claude-opus-5", input: 200, output: 90, cost: 0.9)
        ])
        XCTAssertTrue(coverage.isFullyPriced)
        XCTAssertEqual(coverage.pricedFraction, 1.0)
        XCTAssertFalse(coverage.shouldDisclose)
        XCTAssertTrue(coverage.unpricedModels.isEmpty)
    }

    /// An empty account must not read as "0% priced" — that is a false alarm on
    /// a user who has simply not used anything yet.
    func testEmptyScanDisclosesNothing() {
        let coverage = CostCoverage.from(entries: [])
        XCTAssertNil(coverage.pricedFraction)
        XCTAssertFalse(coverage.shouldDisclose)
        XCTAssertEqual(coverage.totalTokens, 0)
    }

    /// A model priced at exactly zero — a local Ollama model, say — is PRICED.
    /// We knew its rate and the rate was zero. Treating `0` as "unpriced" would
    /// nag every local-model user forever.
    func testZeroCostIsPricedNotUnpriced() {
        let coverage = CostCoverage.from(entries: [
            entry(model: "llama-3-local", input: 1_000, output: 500, cost: 0)
        ])
        XCTAssertTrue(coverage.isFullyPriced)
        XCTAssertEqual(coverage.pricedTokens, 1_500)
        XCTAssertEqual(coverage.unpricedTokens, 0)
        XCTAssertFalse(coverage.shouldDisclose)
    }

    // MARK: - The case it was built for

    /// The shape of the incident: one very large unpriced model beside a small
    /// priced one.
    func testUnpricedModelIsCountedAndNamed() {
        let coverage = CostCoverage.from(entries: [
            entry(model: "claude-sonnet-5", input: 100, output: 100, cost: 0.05),
            entry(model: "claude-opus-5", input: 700, output: 100, cost: nil)
        ])
        XCTAssertEqual(coverage.pricedTokens, 200)
        XCTAssertEqual(coverage.unpricedTokens, 800)
        XCTAssertEqual(coverage.unpricedModels, ["claude-opus-5"])
        XCTAssertTrue(coverage.shouldDisclose)
        XCTAssertFalse(coverage.isFullyPriced)
        XCTAssertEqual(coverage.pricedPercent, 20)
    }

    /// Cached tokens count. They dominate real archives (~98% of volume), and
    /// excluding them would make coverage look far healthier than it is —
    /// matching `CostUsageScanner.reportUnpricedModels`, so the log line and the
    /// UI can never disagree about the same scan.
    func testCachedTokensCountTowardCoverage() {
        let coverage = CostCoverage.from(entries: [
            entry(model: "mystery-model", input: 1, cached: 9_998, output: 1, cost: nil)
        ])
        XCTAssertEqual(coverage.unpricedTokens, 10_000)
        XCTAssertEqual(coverage.totalTokens, 10_000)
    }

    /// Entries for the same model on different days aggregate into ONE named
    /// model, not one per day — otherwise a month of an unpriced model reports
    /// "30 models have no rate".
    func testSameModelAcrossDaysAggregates() {
        let coverage = CostCoverage.from(entries: (1...30).map { day in
            CostUsageScanResult.DailyEntry(
                date: String(format: "2026-08-%02d", day),
                provider: "Claude", model: "claude-opus-5",
                inputTokens: 10, cachedTokens: 0, outputTokens: 10,
                costUSD: nil
            )
        })
        XCTAssertEqual(coverage.unpricedModels, ["claude-opus-5"],
                       "30 days of one model is one model, not thirty")
        XCTAssertEqual(coverage.unpricedTokens, 600)
    }

    /// Most tokens first, so the tooltip's truncated list names the model that
    /// actually matters.
    func testUnpricedModelsSortedByTokensDescending() {
        let coverage = CostCoverage.from(entries: [
            entry(model: "small", input: 10, cost: nil),
            entry(model: "huge", input: 10_000, cost: nil),
            entry(model: "medium", input: 500, cost: nil)
        ])
        XCTAssertEqual(coverage.unpricedModels, ["huge", "medium", "small"])
    }

    /// Ties break by name so the order is stable rather than dictionary-random.
    func testEqualTokenCountsSortStably() {
        let coverage = CostCoverage.from(entries: [
            entry(model: "zeta", input: 100, cost: nil),
            entry(model: "alpha", input: 100, cost: nil)
        ])
        XCTAssertEqual(coverage.unpricedModels, ["alpha", "zeta"])
    }

    // MARK: - Rounding

    /// Rounds DOWN. 99.6% priced must not render as "100%", which would restate
    /// the exact claim this type exists to prevent.
    func testPercentRoundsDownSoItNeverReadsAsComplete() {
        let coverage = CostCoverage.from(entries: [
            entry(model: "priced", input: 996, cost: 1.0),
            entry(model: "unpriced", input: 4, cost: nil)
        ])
        XCTAssertEqual(coverage.pricedPercent, 99,
                       "99.6% must render as 99%, never 100%")
        XCTAssertTrue(coverage.shouldDisclose,
                      "a nearly-complete scan is still incomplete and must say so")
    }

    /// The other end: a tiny priced share must not round up to something
    /// reassuring either.
    func testMostlyUnpricedReportsSmallPercent() {
        let coverage = CostCoverage.from(entries: [
            entry(model: "priced", input: 1, cost: 1.0),
            entry(model: "unpriced", input: 999, cost: nil)
        ])
        XCTAssertEqual(coverage.pricedPercent, 0)
        XCTAssertTrue(coverage.shouldDisclose)
    }
}

import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.50. `claude-opus-5` displayed $0 for **25 days** across 15.47 billion
/// tokens, and nothing in the app said so.
///
/// The pricing bug itself is fixed in the table. This is about the second
/// failure, which is the one that will happen again: the scanner **knew**, at
/// the moment it computed each entry, that it had no rate for that model — and
/// threw the knowledge away. `costUSD` is optional and every consumer sums it
/// with `if let cost { total += cost }`, so an unpriced model contributes
/// nothing and leaves no trace. The total that reaches the UI looks complete.
///
/// Borrowed from CodexBar's framing: *"estimates are labeled, partial totals
/// show their coverage, and nothing unpriced masquerades as a real bill."*
final class UnpricedCoverageTests: XCTestCase {

    private func entry(
        model: String,
        provider: String = "Claude",
        tokens: Int,
        cost: Double?
    ) -> CostUsageScanResult.DailyEntry {
        .init(
            date: "2026-08-24",
            provider: provider,
            model: model,
            inputTokens: tokens,
            cachedTokens: 0,
            outputTokens: 0,
            costUSD: cost
        )
    }

    /// The scan that shipped the bug, in miniature: real tokens, no rate.
    /// One line, naming the model and the token count, is the difference
    /// between "noticed on day one" and "noticed on day 25 because the owner
    /// happened to ask".
    func testUnpricedModelsAreReported() {
        var lines: [String] = []
        CostUsageScanner.reportUnpricedModels(
            [
                entry(model: "claude-opus-5", tokens: 11_289_970_347, cost: nil),
                entry(model: "claude-opus-4-8", tokens: 500, cost: 1.23),
            ],
            log: { lines.append($0) }
        )

        XCTAssertEqual(lines.count, 1, "one summary line per scan, not one per entry")
        let line = try? XCTUnwrap(lines.first)
        XCTAssertTrue(line?.contains("claude-opus-5") ?? false, "must name the model")
        XCTAssertTrue(line?.contains("11289970347") ?? false, "must say how much was unpriced")
        XCTAssertFalse(
            line?.contains("claude-opus-4-8") ?? true,
            "a priced model is not a finding and must not dilute the line"
        )
    }

    /// Silence when everything is priced. A diagnostic that fires on every
    /// healthy scan is one people learn to scroll past — which is how the
    /// SwiftLint output got to 3,104 warnings.
    func testNothingIsLoggedWhenEverythingIsPriced() {
        var lines: [String] = []
        CostUsageScanner.reportUnpricedModels(
            [
                entry(model: "claude-opus-5", tokens: 1_000, cost: 5.0),
                entry(model: "gpt-5.4", provider: "Codex", tokens: 2_000, cost: 0.5),
            ],
            log: { lines.append($0) }
        )
        XCTAssertTrue(lines.isEmpty)
    }

    /// A genuinely free model is priced at zero, not unpriced. `gpt-5.3-codex-spark`
    /// really does cost nothing, and conflating "free" with "we have no rate"
    /// would make the diagnostic cry wolf on a correct row — the same
    /// distinction CodexBar draws by "preserving missing fields as unknown and
    /// explicit zero rates as free".
    func testAnExplicitZeroRateIsNotReportedAsUnpriced() {
        var lines: [String] = []
        CostUsageScanner.reportUnpricedModels(
            [entry(model: "gpt-5.3-codex-spark", provider: "Codex", tokens: 9_000, cost: 0.0)],
            log: { lines.append($0) }
        )
        XCTAssertTrue(lines.isEmpty, "cost 0.0 is a rate; cost nil is the absence of one")
    }

    /// Tokens for one model are summed across days rather than reported per
    /// entry — a 30-day scan of a new model would otherwise emit 30 lines.
    func testTokensAreAggregatedPerModel() {
        var lines: [String] = []
        CostUsageScanner.reportUnpricedModels(
            [
                entry(model: "claude-opus-6", tokens: 100, cost: nil),
                entry(model: "claude-opus-6", tokens: 250, cost: nil),
            ],
            log: { lines.append($0) }
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("claude-opus-6=350") ?? false)
    }

    /// The real table, as a live check rather than a fixture: every model this
    /// build ships a row for must actually price. Catches a typo'd key, which
    /// would otherwise present as a silent $0 for exactly one model.
    func testEveryShippedClaudeModelPrices() {
        for model in ["claude-opus-5", "claude-sonnet-5", "claude-fable-5",
                      "claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-4-6",
                      "claude-haiku-4-5"] {
            XCTAssertNotNil(
                CostUsageScanner.Pricing.claudeCostUSD(
                    model: model, inputTokens: 1, cacheReadInputTokens: 0,
                    cacheCreationInputTokens: 0, outputTokens: 0
                ),
                "\(model) ships a pricing row but does not price"
            )
        }
    }
}

#endif

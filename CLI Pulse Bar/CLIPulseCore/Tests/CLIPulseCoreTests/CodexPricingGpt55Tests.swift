#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// H-10 (2026-06-07 review): the Rust desktop `pricing.rs` table carried
/// the gpt-5.5 Codex family, but the Swift `codexModels` table stopped at
/// `gpt-5.4-pro`. Codex emitted `model="gpt-5.5"` in the wild, so macOS
/// rendered those sessions at $0.00 (`codexCostUSD` returned nil →
/// dropped via compactMap) while Windows/Linux priced them — a silent
/// cross-runtime under-report on Today/Week/forecast/budget on Mac.
///
/// The fix then priced the whole 5.5 family at gpt-5.4's rates, because OpenAI
/// had published none. 1.56 replaces that: `gpt-5.5` and `gpt-5.5-pro` have
/// OpenAI's published rates, and the three rows OpenAI never listed
/// (`gpt-5.5-codex`, `-mini`, `-nano`) are gone, so those names borrow a
/// neighbour's rate and are marked approximate instead of passing for listed.
final class CodexPricingGpt55Tests: XCTestCase {

    private typealias P = CostUsageScanner.Pricing

    private func codexCost(_ model: String, input: Int = 1_000_000, cached: Int = 0, output: Int = 0) -> Double? {
        P.codexCostUSD(model: model, inputTokens: input, cachedInputTokens: cached, outputTokens: output)
    }

    func testGpt55_isPricedNonZero_wasTheBug() {
        let cost = codexCost("gpt-5.5")
        XCTAssertNotNil(cost, "gpt-5.5 must NOT return nil — that was the macOS $0 bug")
        XCTAssertGreaterThan(cost ?? 0, 0)
    }

    /// OpenAI's list price, per 1M tokens: $5 input, $0.50 cached, $30 output.
    /// The old row charged $2.50 / $0.25 / $15, half of each.
    func testGpt55_chargesOpenAIsPublishedRate() {
        XCTAssertEqual(codexCost("gpt-5.5") ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(codexCost("gpt-5.5", cached: 1_000_000) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(codexCost("gpt-5.5", input: 0, output: 1_000_000) ?? -1, 30, accuracy: 1e-9)
        XCTAssertNotEqual(codexCost("gpt-5.5") ?? -1, codexCost("gpt-5.4") ?? -1, accuracy: 1e-9,
                          "gpt-5.5 is no longer gpt-5.4's rate")
    }

    func testGpt55Pro_cacheReadFallsBackToInputRate() {
        // -pro carries no cache-read rate (nil) → cached input bills at the
        // input rate, same as gpt-5.4-pro.
        XCTAssertEqual(codexCost("gpt-5.5-pro", cached: 1_000_000) ?? -1, 30, accuracy: 1e-9)
    }

    /// The unlisted names still get a non-zero rate, and say it is borrowed.
    func testUnlistedGpt55VariantsBorrowARateAndSaySo() {
        let expected: [(model: String, borrowedFrom: String)] = [
            ("gpt-5.5-codex", "gpt-5.5"),
            ("gpt-5.5-mini", "gpt-5.4-mini"),
            ("gpt-5.5-nano", "gpt-5.4-nano"),
        ]
        for row in expected {
            XCTAssertEqual(P.codexPriceResolution(row.model),
                           P.PriceResolution(key: row.borrowedFrom, isApproximate: true), row.model)
            XCTAssertEqual(codexCost(row.model) ?? -1, codexCost(row.borrowedFrom) ?? -2, accuracy: 1e-9, row.model)
        }
    }
}
#endif

import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.50. The Claude 5 generation, and every unrecognised model after it, read
/// **$0**.
///
/// Found by reading the owner's own `usage-history-v1.json`: token counts were
/// perfect, `cost` was `0` on every day since 2026-07-30 and on every model in
/// the Claude 5 / GPT-5.6 generation — **15,473,169,404 tokens priced at
/// nothing**.
///
/// The mechanism is the interesting part, because a guard for exactly this
/// already existed and its comment says so: *"Without this, the next minor
/// release silently regresses Today/Week cost to $0 the day it ships."* It
/// matched `claude-(opus|sonnet|haiku)-N-M`. The next release was not a minor —
/// `claude-opus-5` has no `-M`, and `claude-fable-5` is not one of the three
/// families — so the net caught nothing. A guard written against the shape of
/// the last incident.
final class Claude5PricingTests: XCTestCase {

    private typealias P = CostUsageScanner.Pricing

    // MARK: - The defect

    /// One assertion per model that was reading zero. Each is a real model the
    /// owner's archive has real tokens for.
    func testClaude5GenerationIsPriced() {
        for model in ["claude-opus-5", "claude-sonnet-5", "claude-fable-5"] {
            let cost = P.claudeCostUSD(
                model: model,
                inputTokens: 1_000_000,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0,
                outputTokens: 0
            )
            XCTAssertNotNil(cost, "\(model) must be priced")
            XCTAssertGreaterThan(cost ?? 0, 0, "\(model) must not cost zero")
        }
    }

    func testGPT56IsPriced() {
        for model in ["gpt-5.6-sol", "gpt-5.6-terra"] {
            let cost = P.codexCostUSD(
                model: model,
                inputTokens: 1_000_000,
                cachedInputTokens: 0,
                outputTokens: 0
            )
            XCTAssertNotNil(cost, "\(model) must be priced")
            XCTAssertGreaterThan(cost ?? 0, 0, "\(model) must not cost zero")
        }
    }

    // MARK: - The published rates

    /// Anthropic's first-party API prices, per 1M tokens. If a rate is ever
    /// edited by accident, this is the test that notices.
    func testPublishedRatesPerMillionTokens() {
        let expected: [(model: String, input: Double, output: Double)] = [
            ("claude-opus-5", 5, 25),
            ("claude-sonnet-5", 3, 15),
            ("claude-fable-5", 10, 50),
            ("claude-opus-4-8", 5, 25),
            ("claude-haiku-4-5", 1, 5),
        ]
        for row in expected {
            let input = P.claudeCostUSD(
                model: row.model, inputTokens: 1_000_000,
                cacheReadInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0
            )
            let output = P.claudeCostUSD(
                model: row.model, inputTokens: 0,
                cacheReadInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 1_000_000
            )
            XCTAssertEqual(input ?? -1, row.input, accuracy: 0.001, "\(row.model) input")
            XCTAssertEqual(output ?? -1, row.output, accuracy: 0.001, "\(row.model) output")
        }
    }

    /// Cache rates follow the convention documented on the Opus 4.7 row and
    /// used by every entry in the table: read is 10% of input, write is 1.25x.
    /// Worth pinning because cache tokens dominate real Claude Code traffic —
    /// the archive that surfaced this bug is mostly cache reads.
    func testCacheRatesFollowTheDocumentedMultipliers() {
        for model in ["claude-opus-5", "claude-sonnet-5", "claude-fable-5"] {
            let input = P.claudeCostUSD(model: model, inputTokens: 1_000_000, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0) ?? 0
            let read = P.claudeCostUSD(model: model, inputTokens: 0, cacheReadInputTokens: 1_000_000, cacheCreationInputTokens: 0, outputTokens: 0) ?? 0
            let write = P.claudeCostUSD(model: model, inputTokens: 0, cacheReadInputTokens: 0, cacheCreationInputTokens: 1_000_000, outputTokens: 0) ?? 0
            XCTAssertEqual(read, input * 0.1, accuracy: 1e-9, "\(model) cache read")
            XCTAssertEqual(write, input * 1.25, accuracy: 1e-9, "\(model) cache write")
        }
    }

    // MARK: - The name is not the rate

    /// The regression that made the old design costly in the other direction.
    /// `normalize` used to apply the family fallback, and `ScanEntry.model`
    /// stores whatever it returns — so an unpriced model was silently
    /// RELABELLED as the sibling it borrowed a rate from, and the By-Model
    /// breakdown attributed its tokens to a model the user never ran.
    func testAnUnknownModelKeepsItsOwnNameWhileBorrowingARate() {
        XCTAssertEqual(
            P.normalizeClaudeModel("claude-opus-6"), "claude-opus-6",
            "display name must survive an unpriced model"
        )
        XCTAssertEqual(
            P.claudePricingKey("claude-opus-6"), "claude-opus-5",
            "…while still being charged at the newest priced sibling's rate"
        )
        XCTAssertEqual(P.normalizeCodexModel("gpt-5.6-sol"), "gpt-5.6-sol")
        XCTAssertEqual(P.codexPricingKey("gpt-5.6-sol"), "gpt-5.5")
    }

    /// Dated and prefixed spellings still resolve, unchanged by the split.
    func testExistingNormalizationIsUnchanged() {
        XCTAssertEqual(P.normalizeClaudeModel("claude-opus-4-8-20260714"), "claude-opus-4-8")
        XCTAssertEqual(P.normalizeClaudeModel("anthropic.claude-opus-4-8"), "claude-opus-4-8")
        XCTAssertEqual(P.normalizeCodexModel("openai/gpt-5.4"), "gpt-5.4")
    }

    // MARK: - The fallback's ordering

    /// A generation bump must outrank any minor: `claude-opus-5` (5, 0) beats
    /// `claude-opus-4-8` (4, 8). Getting this backwards is subtle and cheap to
    /// pin.
    func testGenerationOutranksMinor() {
        XCTAssertEqual(P.claudePricingKey("claude-opus-6"), "claude-opus-5")
    }

    /// Never charge an old model at a newer model's rate. `claude-opus-4-9`
    /// falls back down to `4-8`, not up to `5`.
    func testFallbackNeverGoesForward() {
        XCTAssertEqual(P.claudePricingKey("claude-opus-4-9"), "claude-opus-4-8")
    }

    /// A date masquerading as a minor (`claude-sonnet-4-20250514`) must not win
    /// the comparison against real minors. This trap is called out in the
    /// original code and is preserved.
    func testDatedLegacyKeyCannotWinTheFallback() {
        XCTAssertEqual(P.claudePricingKey("claude-sonnet-9"), "claude-sonnet-5")
    }

    /// A family that has never been priced gets nothing, and that is correct.
    /// Fable is $10/$50 — 2x Opus — so borrowing an Opus rate would have
    /// under-reported it by half. There is no honest guess for a tier that has
    /// never existed; it needs a row, which is why it has one.
    func testAnUnknownFamilyGetsNoRateRatherThanAWrongOne() {
        XCTAssertNil(P.claudePricingKey("claude-brandnew-1"))
    }

    // MARK: - Codex tiering

    /// The expensive mistake on the Codex side. `gpt-5.4-pro` is 12x
    /// `gpt-5.4`, so an unknown `-pro` must never fall back to a base row.
    func testProTierNeverFallsBackToBaseRates() {
        XCTAssertEqual(P.codexPricingKey("gpt-5.6-pro"), "gpt-5.5-pro")
        let pro = P.codexCostUSD(model: "gpt-5.6-pro", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0) ?? 0
        let base = P.codexCostUSD(model: "gpt-5.6-sol", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0) ?? 0
        XCTAssertGreaterThan(pro, base * 5, "a pro-tier model must not be charged base rates")
    }

    func testMiniAndNanoKeepTheirOwnTier() {
        XCTAssertEqual(P.codexPricingKey("gpt-5.6-mini"), "gpt-5.5-mini")
        XCTAssertEqual(P.codexPricingKey("gpt-5.6-nano"), "gpt-5.5-nano")
    }

    /// An unrecognised suffix is base tier — where every non-suffixed Codex
    /// model has sat. `-codex-max` already relies on this shape.
    func testUnknownSuffixIsTreatedAsBaseTier() {
        XCTAssertEqual(P.codexVersionTier("gpt-5.6-sol")?.1, "base")
        XCTAssertEqual(P.codexVersionTier("gpt-5.1-codex-max")?.1, "base")
        XCTAssertEqual(P.codexVersionTier("gpt-5.4-pro")?.1, "pro")
    }

    /// `gpt-5.5` and `gpt-5.5-codex` are both (5,5) base tier, and "highest
    /// version wins" alone left the winner to Swift's unspecified dictionary
    /// order — this test failed intermittently against the first draft, picking
    /// `gpt-5.5-codex` on one run and `gpt-5.5` on the next. Their rates are
    /// identical, so nothing visible moved and it would have shipped; the next
    /// pair of same-version rows that disagree on price would have made it a
    /// real bug that reproduces once in a while.
    ///
    /// Repeated because a flaky assertion that runs once proves nothing.
    func testFallbackTieBreakIsDeterministic() {
        for _ in 0..<50 {
            XCTAssertEqual(P.codexPricingKey("gpt-5.6-sol"), "gpt-5.5")
            XCTAssertEqual(P.claudePricingKey("claude-opus-6"), "claude-opus-5")
        }
    }

    func testShorterKeyWinsATie() {
        XCTAssertTrue(
            P.isBetterFallback(
                candidate: ("gpt-5.5", (5, 5)),
                than: ("gpt-5.5-codex", (5, 5))
            ),
            "the plain family row is the more conservative base to borrow from"
        )
        XCTAssertTrue(
            P.isBetterFallback(
                candidate: ("gpt-5.5-codex", (5, 5)),
                than: ("gpt-5.4", (5, 4))
            ),
            "…but version still beats key length"
        )
    }

    // MARK: - The cache has to be invalidated too

    /// Without this bump the fix reaches only logs written from here on, and
    /// every historical day keeps its stored `costNanos=0`. The version is what
    /// makes a normal refresh — not a manual Force Rescan — re-parse and
    /// re-price existing logs.
    func testPricingVersionWasBumpedForThisChange() {
        XCTAssertGreaterThanOrEqual(
            costUsageCachePricingVersion, 4,
            "priced-model changes must invalidate caches computed under the old table"
        )
    }

    // MARK: - The shape that defeated the old guard

    /// The old fallback required four components and three families. This is
    /// the parser that replaced it, checked against every shape in play.
    func testFamilyVersionParsingCoversBothVersionShapes() {
        XCTAssertEqual(P.claudeFamilyVersion("claude-opus-5")?.0, "opus")
        XCTAssertEqual(P.claudeFamilyVersion("claude-opus-5")?.1.0, 5)
        XCTAssertEqual(P.claudeFamilyVersion("claude-opus-5")?.1.1, 0)
        XCTAssertEqual(P.claudeFamilyVersion("claude-opus-4-8")?.1.0, 4)
        XCTAssertEqual(P.claudeFamilyVersion("claude-opus-4-8")?.1.1, 8)
        XCTAssertEqual(P.claudeFamilyVersion("claude-fable-5")?.0, "fable")
        XCTAssertNil(P.claudeFamilyVersion("gpt-5.4"))
        XCTAssertNil(P.claudeFamilyVersion("claude-opus"))
    }
}

#endif

#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Locks down the two money-math paths that were unit-test-blind:
///   1. Claude long-context pricing (the 200K tier on the Sonnet 4 and 4.5
///      rows, and on Sonnet 4.6 and Opus 4.6 before 2026-03-13).
///   2. Codex `codexCostUSD` edge cases — cache-token capping, the pro variant's
///      nil cache-rate fallback, zero-cost research previews, and unknown models.
///
/// Every expected value here was computed independently from the rate table,
/// not by eye.
///
/// The tier is Anthropic's rule, read from its pricing page as it stood while
/// the tier applied (archived 2026-03-01,
/// https://web.archive.org/web/20260301150515/https://platform.claude.com/docs/en/about-claude/pricing):
/// "If your request exceeds 200K input tokens, all tokens incur premium
/// pricing", and "the 200K threshold is based solely on input tokens
/// (including cache reads/writes)". Until 1.56 these tests pinned a different
/// rule, each token kind split at 200K on its own, which was written for
/// pricing a day's sum; the scanner has priced each response since then
/// (`parseClaudeFile`), and a sum is now priced without the tier
/// (`ClaudePricingTable.aggregateCostUSD`).
final class ClaudeTieredAndCodexEdgeCostTests: XCTestCase {

    // MARK: - Claude tiered (Sonnet 200K threshold)

    private func sonnet(input: Int = 0, cacheRead: Int = 0, cacheCreate: Int = 0, output: Int = 0) -> Double {
        CostUsageScanner.Pricing.claudeCostUSD(
            model: "claude-sonnet-4-5",
            inputTokens: input, cacheReadInputTokens: cacheRead,
            cacheCreationInputTokens: cacheCreate, outputTokens: output) ?? .nan
    }

    func test_sonnet_input_below_threshold_uses_base_rate() {
        XCTAssertEqual(sonnet(input: 100_000), 0.30, accuracy: 1e-9)   // 100k × 3e-6
    }

    func test_sonnet_input_at_threshold_is_all_base() {
        XCTAssertEqual(sonnet(input: 200_000), 0.60, accuracy: 1e-9)   // exactly at threshold, not "exceeds"
    }

    func test_sonnet_input_above_threshold_pays_the_long_context_rate_on_all_of_it() {
        // 300k × 6e-6 = 1.80, not 200k × 3e-6 + 100k × 6e-6 = 1.20.
        XCTAssertEqual(sonnet(input: 300_000), 1.80, accuracy: 1e-9)
    }

    func test_sonnet_cache_reads_count_toward_the_threshold() {
        // 10k input + 250k cache reads + 1k writes = 261k > 200K, so every
        // token pays the long-context rate:
        // 10k × 6e-6 + 250k × 6e-7 + 1k × 7.5e-6 + 2k × 2.25e-5
        // = 0.06 + 0.15 + 0.0075 + 0.045
        XCTAssertEqual(sonnet(input: 10_000, cacheRead: 250_000, cacheCreate: 1_000, output: 2_000),
                       0.2625, accuracy: 1e-9)
    }

    func test_sonnet_output_does_not_decide_the_tier() {
        // 300k output with no prompt: standard rate, 300k × 1.5e-5.
        XCTAssertEqual(sonnet(output: 300_000), 4.50, accuracy: 1e-9)
    }

    func test_sonnet_a_prompt_of_exactly_200K_pays_standard_rates() {
        // 40k + 150k + 10k = 200k, which does not exceed the threshold:
        // 40k×3e-6 + 150k×3e-7 + 10k×3.75e-6 + 5k×1.5e-5
        XCTAssertEqual(sonnet(input: 40_000, cacheRead: 150_000, cacheCreate: 10_000, output: 5_000),
                       0.2775, accuracy: 1e-9)
        // One token more and every token pays the long-context rate:
        // 40,001×6e-6 + 150k×6e-7 + 10k×7.5e-6 + 5k×2.25e-5
        XCTAssertEqual(sonnet(input: 40_001, cacheRead: 150_000, cacheCreate: 10_000, output: 5_000),
                       0.517506, accuracy: 1e-9)
    }

    func test_opus_has_no_threshold_and_stays_linear() {
        // Opus 4.7 has no tier → 300k × 5e-6 = 1.50.
        let cost = CostUsageScanner.Pricing.claudeCostUSD(
            model: "claude-opus-4-7",
            inputTokens: 300_000, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0)
        XCTAssertEqual(cost ?? .nan, 1.50, accuracy: 1e-9)
    }

    func test_claude_negative_tokens_clamped_to_zero() {
        XCTAssertEqual(sonnet(input: -100_000, output: -5), 0.0, accuracy: 1e-12)
    }

    // MARK: - Codex edge cases

    func test_codex_cached_tokens_capped_at_input() {
        // i=50, cached=100 (impossible) → cached capped to 50, nonCached 0.
        // 50 × 2.5e-7 (cacheRead) + 10 × 1.5e-5 (output) = 1.625e-4
        let cost = CostUsageScanner.Pricing.codexCostUSD(
            model: "gpt-5.4", inputTokens: 50, cachedInputTokens: 100, outputTokens: 10)
        XCTAssertEqual(cost ?? .nan, 0.0001625, accuracy: 1e-12)
    }

    func test_codex_normal_split_cached_noncached() {
        // i=1000 (c=400), o=200 → 600×2.5e-6 + 400×2.5e-7 + 200×1.5e-5 = 0.0046
        let cost = CostUsageScanner.Pricing.codexCostUSD(
            model: "gpt-5.4", inputTokens: 1000, cachedInputTokens: 400, outputTokens: 200)
        XCTAssertEqual(cost ?? .nan, 0.0046, accuracy: 1e-9)
    }

    func test_codex_pro_nil_cache_rate_falls_back_to_input_rate() {
        // gpt-5.4-pro has cacheReadCostPerToken=nil → cached billed at input rate 3e-5.
        // i=100 (c=50), o=10 → 50×3e-5 + 50×3e-5 + 10×1.8e-4 = 0.0048
        let cost = CostUsageScanner.Pricing.codexCostUSD(
            model: "gpt-5.4-pro", inputTokens: 100, cachedInputTokens: 50, outputTokens: 10)
        XCTAssertEqual(cost ?? .nan, 0.0048, accuracy: 1e-9)
    }

    func test_codex_zero_cost_research_preview_is_zero_not_nil() {
        // gpt-5.3-codex-spark is priced at $0 — must return 0 (counts as a real
        // entry in aggregation), NOT nil (which would drop the entry).
        let cost = CostUsageScanner.Pricing.codexCostUSD(
            model: "gpt-5.3-codex-spark", inputTokens: 1000, cachedInputTokens: 0, outputTokens: 500)
        XCTAssertEqual(cost, 0.0)
    }

    func test_codex_unknown_model_returns_nil() {
        XCTAssertNil(CostUsageScanner.Pricing.codexCostUSD(
            model: "totally-unknown-model-9000", inputTokens: 1000, cachedInputTokens: 0, outputTokens: 500))
    }

    func test_codex_negative_tokens_clamped_to_zero() {
        let cost = CostUsageScanner.Pricing.codexCostUSD(
            model: "gpt-5.4", inputTokens: -10, cachedInputTokens: -5, outputTokens: -3)
        XCTAssertEqual(cost ?? .nan, 0.0, accuracy: 1e-12)
    }
}
#endif

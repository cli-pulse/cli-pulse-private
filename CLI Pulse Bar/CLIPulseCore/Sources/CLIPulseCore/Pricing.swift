import Foundation

/// Public pricing API for token cost calculations.
/// Delegates to CostUsageScanner.Pricing on macOS; returns nil on other platforms.
public enum TokenPricing {

    /// Calculate cost for Codex (OpenAI) model usage.
    public static func codexCost(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> Double? {
        #if os(macOS)
        return CostUsageScanner.Pricing.codexCostUSD(model: model, inputTokens: inputTokens, cachedInputTokens: cachedInputTokens, outputTokens: outputTokens)
        #else
        return nil
        #endif
    }

    /// Calculate cost for Claude (Anthropic) model usage.
    public static func claudeCost(model: String, inputTokens: Int, cacheReadInputTokens: Int, cacheCreationInputTokens: Int, outputTokens: Int) -> Double? {
        #if os(macOS)
        return CostUsageScanner.Pricing.claudeCostUSD(model: model, inputTokens: inputTokens, cacheReadInputTokens: cacheReadInputTokens, cacheCreationInputTokens: cacheCreationInputTokens, outputTokens: outputTokens)
        #else
        return nil
        #endif
    }

    /// Format a raw USD cost value (4-decimal sub-cent precision). NOT routed
    /// through the display-currency converter — this is an internal/diagnostic
    /// USD formatter (per-token estimates); owner-facing costs use
    /// `CostFormatter.format`, which converts. (v1.40 PR-7.)
    public static func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return cost > 0 ? String(format: "$%.4f", cost) : "$0.00"
        }
        return String(format: "$%.2f", cost)
    }
}

/// v1.58: models the pricing tables rate at $0 (Codex's
/// `gpt-5.3-codex-spark`, a research preview with no API price), by the
/// row name the scanner records and syncs. Their usage has a known cost,
/// $0, so a day of nothing else is not "cost unknown": the usage charts draw
/// it as a day of $0 (`ProviderUsageDays.fromCloud`, the Usage Dashboard's
/// Trends), as This Mac's scan does, where such a model's cost is 0 and not
/// missing. Cross-platform: the iPhone card reads synced rows too.
public enum ZeroRatedModel {
    public static func contains(_ model: String) -> Bool {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let million = 1_000_000
        if let rates = CodexPricingTable.rates(forKey: CodexPricingTable.aliasTarget(name) ?? name, at: nil) {
            return CodexPricingTable.aggregateCostUSD(
                rates: rates, inputTokens: million, cachedInputTokens: million / 2, outputTokens: million) == 0
        }
        if let rates = ClaudePricingTable.rates(forKey: name, at: nil) {
            return ClaudePricingTable.aggregateCostUSD(
                rates: rates, inputTokens: million, cacheReadTokens: million,
                cacheWriteTokens: million, outputTokens: million) == 0
        }
        return false
    }
}

import Foundation

/// Anthropic API list prices for the models Claude Code writes into its logs,
/// in US dollars per token, and the prices some of them had before.
///
/// The cost this feeds is an API-equivalent estimate, not a bill: a Claude
/// plan does not charge per token. The table exists so that the estimate uses
/// the rate Anthropic lists for the model, on the day it was used.
///
/// Source: Anthropic's pricing page,
/// https://platform.claude.com/docs/en/about-claude/pricing, read on
/// 2026-10-03 ("Model pricing", "Prompt caching" and "Long context pricing"),
/// and the API release notes, https://platform.claude.com/docs/en/release-notes/api,
/// for the dates. Each row is written in the page's column order, per million
/// tokens: base input, 5-minute cache write, 1-hour cache write, cache hit,
/// output (`row`).
///
/// Until 1.56 the Mac table stopped at Claude Opus 5, Sonnet 5 and Fable 5.
/// Claude Opus 5.5 ($4 / $20, cache hits $0.20) borrowed Opus 5's $5 / $25
/// and $0.50, and Fable 5.1 (cache hits $0.25) borrowed Fable 5's $1, so the
/// cache reads that make up most of a Claude Code day were charged 2.5x and
/// 4x their price; Sonnet 5 was charged $3 / $15, a rate it never had; and
/// every cache write was charged at the 5-minute rate, although Claude Code
/// writes much of its cache for an hour, at 2x input instead of 1.25x.
public enum ClaudePricingTable {

    /// One price list, USD per token.
    public struct TokenRates: Sendable, Equatable {
        public let input: Double
        /// Writing to the 5-minute cache: 1.25x input.
        public let cacheWrite5m: Double
        /// Writing to the 1-hour cache: 2x input.
        public let cacheWrite1h: Double
        /// A cache hit (which also refreshes the entry): 0.1x input, except
        /// 0.05x on Claude Opus 5.5 and 0.025x on Claude Fable 5.1 and
        /// Mythos 5.1.
        public let cacheRead: Double
        public let output: Double

        public init(input: Double, cacheWrite5m: Double, cacheWrite1h: Double, cacheRead: Double, output: Double) {
            self.input = input
            self.cacheWrite5m = cacheWrite5m
            self.cacheWrite1h = cacheWrite1h
            self.cacheRead = cacheRead
            self.output = output
        }
    }

    /// One model's rates.
    public struct Rates: Sendable, Equatable {
        public let standard: TokenRates
        /// A request whose prompt (uncached input, cache reads and cache
        /// writes together) is MORE than this many tokens pays `longContext`
        /// on every token, output included. nil: no tier.
        public let longContextThreshold: Int?
        public let longContext: TokenRates?

        public init(standard: TokenRates, longContextThreshold: Int? = nil, longContext: TokenRates? = nil) {
            self.standard = standard
            self.longContextThreshold = longContextThreshold
            self.longContext = longContext
        }
    }

    /// The page's columns, in its order, in USD per million tokens.
    static func row(_ input: Double, _ cacheWrite5m: Double, _ cacheWrite1h: Double, _ cacheRead: Double, _ output: Double) -> TokenRates {
        TokenRates(
            input: input / 1_000_000,
            cacheWrite5m: cacheWrite5m / 1_000_000,
            cacheWrite1h: cacheWrite1h / 1_000_000,
            cacheRead: cacheRead / 1_000_000,
            output: output / 1_000_000
        )
    }

    /// Anthropic's long-context boundary: "If your request exceeds 200K input
    /// tokens, all tokens incur premium pricing", where input counts cache
    /// reads and writes and output does not.
    public static let longContextThreshold = 200_000

    /// A row with the 200K tier: Sonnet 4 and 4.5 throughout, Sonnet 4.6 and
    /// Opus 4.6 until 2026-03-13. Above 200K the page charged 2x input and
    /// 1.5x output ("Long context pricing" before 2026-03-13, archived at
    /// https://web.archive.org/web/20260301150515/https://platform.claude.com/docs/en/about-claude/pricing:
    /// Opus 4.6 $10 / $37.50, Sonnet 4.6 / 4.5 / 4 $6 / $22.50), with
    /// "prompt caching multipliers ... on top of long context pricing".
    private static func tiered(_ standard: TokenRates, above: TokenRates) -> Rates {
        Rates(standard: standard, longContextThreshold: longContextThreshold, longContext: above)
    }

    private static let opus4 = row(5, 6.25, 10, 0.50, 25)
    private static let opus4LongContext = row(10, 12.50, 20, 1, 37.50)
    private static let sonnet4 = row(3, 3.75, 6, 0.30, 15)
    private static let sonnet4LongContext = row(6, 7.50, 12, 0.60, 22.50)
    private static let opus41 = row(15, 18.75, 30, 1.50, 75)
    private static let haiku45 = row(1, 1.25, 2, 0.10, 5)

    // MARK: - Rates in force today

    /// Today's rates, keyed by the name Claude Code writes (after
    /// `CostUsageScanner.Pricing.normalizeClaudeModel` drops a provider prefix
    /// or a date suffix the base of which has a row).
    ///
    /// Every row matches the page's "Model pricing" table on 2026-10-03. The
    /// page lists no long-context tier for any current model: "Claude 4.6 and
    /// later models ... include the full 1M token context window at standard
    /// pricing."
    public static let current: [String: Rates] = [
        // Fable and Mythos 5.1 (released 2026-09-01): Fable 5's prices, with
        // cache hits at 0.025x input ($0.25), "a quarter of Claude Fable 5's".
        "claude-fable-5-1": Rates(standard: row(10, 12.50, 20, 0.25, 50)),
        "claude-mythos-5-1": Rates(standard: row(10, 12.50, 20, 0.25, 50)),
        "claude-fable-5": Rates(standard: row(10, 12.50, 20, 1, 50)),
        "claude-mythos-5": Rates(standard: row(10, 12.50, 20, 1, 50)),
        // Opus 5.5 (released 2026-09-22): $4 / $20, cache hits at 0.05x
        // input ($0.20).
        "claude-opus-5-5": Rates(standard: row(4, 5, 8, 0.20, 20)),
        "claude-opus-5": Rates(standard: opus4),
        "claude-opus-4-8": Rates(standard: opus4),
        "claude-opus-4-7": Rates(standard: opus4),
        "claude-opus-4-6": Rates(standard: opus4),
        "claude-opus-4-6-20260205": Rates(standard: opus4),
        "claude-opus-4-5": Rates(standard: opus4),
        "claude-opus-4-5-20251101": Rates(standard: opus4),
        "claude-opus-4-1": Rates(standard: opus41),
        "claude-opus-4-20250514": Rates(standard: opus41),
        // Sonnet 5.5 (released 2026-09-28): Sonnet 5's prices.
        "claude-sonnet-5-5": Rates(standard: row(2, 2.50, 4, 0.20, 10)),
        // Sonnet 5 launched on 2026-06-30 at $2 / $10, "introductory" through
        // 2026-08-31; on 2026-08-10 that became the standard price and "the
        // previously scheduled increase to $3 / $15 ... on September 1, 2026
        // will not occur" (pricing page, footnote 3). So $2 / $10 is the only
        // rate it ever had. The old row was the $3 / $15 that never happened.
        "claude-sonnet-5": Rates(standard: row(2, 2.50, 4, 0.20, 10)),
        // Sonnet 4.6's 1M window has been at standard pricing since 2026-03-13;
        // its tier before that is in `superseded`.
        "claude-sonnet-4-6": Rates(standard: sonnet4),
        // The 1M beta for Sonnet 4.5 and 4 kept the tier until it was retired
        // on 2026-04-30; since then a request over 200K is an error, so the
        // tier can only apply to requests made before.
        "claude-sonnet-4-5": tiered(sonnet4, above: sonnet4LongContext),
        "claude-sonnet-4-5-20250929": tiered(sonnet4, above: sonnet4LongContext),
        "claude-sonnet-4-20250514": tiered(sonnet4, above: sonnet4LongContext),
        "claude-haiku-4-5": Rates(standard: haiku45),
        "claude-haiku-4-5-20251001": Rates(standard: haiku45),
    ]

    // MARK: - Rates a model had before

    /// "The 1M token context window is out of beta for Claude Opus 4.6 and
    /// Sonnet 4.6, at standard pricing" (API release notes, March 13, 2026).
    /// Dated 00:00 UTC, the convention of `CodexPricingTable`'s dates.
    public static let longContextAtStandardPricing = Date(timeIntervalSince1970: 1_773_360_000)

    /// A rate that applied until `until` (exclusive).
    public struct DatedRates: Sendable {
        public let until: Date
        public let rates: Rates
    }

    /// Earlier rates per model, oldest first. A response before `until` is
    /// charged `rates`; from `until` on, the next entry or `current`. The same
    /// two rules as `CodexPricingTable.superseded`, both tested: each list is
    /// in ascending `until` order, and every model here has a `current` row.
    ///
    /// Opus 4.6 (1M beta from 2026-02-05) and Sonnet 4.6 (from its release on
    /// 2026-02-17) paid the long-context tier above 200K until 2026-03-13.
    public static let superseded: [String: [DatedRates]] = [
        "claude-opus-4-6": [DatedRates(until: longContextAtStandardPricing, rates: tiered(opus4, above: opus4LongContext))],
        "claude-opus-4-6-20260205": [DatedRates(until: longContextAtStandardPricing, rates: tiered(opus4, above: opus4LongContext))],
        "claude-sonnet-4-6": [DatedRates(until: longContextAtStandardPricing, rates: tiered(sonnet4, above: sonnet4LongContext))],
    ]

    // MARK: - Lookup

    /// The rates `key` was charged at `date`; today's when `date` is nil.
    /// `key` is a row name (`current`), not a raw model name.
    public static func rates(forKey key: String, at date: Date?) -> Rates? {
        if let date, let history = superseded[key] {
            for entry in history where date < entry.until {
                return entry.rates
            }
        }
        return current[key]
    }

    // MARK: - Cost

    /// Cost of ONE response.
    ///
    /// Anthropic's `input_tokens` is only the uncached part of the prompt;
    /// cache reads and cache writes are counted beside it, not inside it.
    /// `cacheWrite1hTokens` is the part of `cacheWriteTokens` written to the
    /// 1-hour cache (Claude Code's `usage.cache_creation.ephemeral_1h_input_tokens`),
    /// clamped to it; the rest is charged as 5-minute writes, which is also
    /// how a log that does not split its writes is charged.
    ///
    /// A request whose prompt is over the row's threshold pays the
    /// long-context rates on every token, output included, not only on the
    /// excess.
    public static func requestCostUSD(
        rates: Rates,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        cacheWrite1hTokens: Int = 0,
        outputTokens: Int
    ) -> Double {
        let prompt = max(0, inputTokens) + max(0, cacheReadTokens) + max(0, cacheWriteTokens)
        let longContext = rates.longContextThreshold.map { prompt > $0 } ?? false
        return cost(
            rates: longContext ? rates.longContext ?? rates.standard : rates.standard,
            inputTokens: inputTokens, cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens, cacheWrite1hTokens: cacheWrite1hTokens,
            outputTokens: outputTokens
        )
    }

    /// Cost of a SUM of responses, at standard rates.
    ///
    /// The size of each request in a sum is unknown, and testing the threshold
    /// against the total would put every busy day on long-context rates, so a
    /// sum never takes the tier. A sum does not carry the 1-hour split either,
    /// so its writes are charged at the 5-minute rate.
    public static func aggregateCostUSD(
        rates: Rates,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int
    ) -> Double {
        cost(
            rates: rates.standard,
            inputTokens: inputTokens, cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens, cacheWrite1hTokens: 0,
            outputTokens: outputTokens
        )
    }

    private static func cost(
        rates: TokenRates,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        cacheWrite1hTokens: Int,
        outputTokens: Int
    ) -> Double {
        let writes = max(0, cacheWriteTokens)
        let writes1h = min(max(0, cacheWrite1hTokens), writes)
        return Double(max(0, inputTokens)) * rates.input
            + Double(max(0, cacheReadTokens)) * rates.cacheRead
            + Double(writes - writes1h) * rates.cacheWrite5m
            + Double(writes1h) * rates.cacheWrite1h
            + Double(max(0, outputTokens)) * rates.output
    }
}

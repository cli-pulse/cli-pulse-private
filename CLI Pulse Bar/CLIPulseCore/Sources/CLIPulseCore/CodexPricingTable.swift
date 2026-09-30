// Derived from steipete/CodexBar
// Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift (the Codex
// rate rows, the GPT-5.6 Sol/Terra/Luna rates in force before their repricing,
// the pricing aliases in `normalizeCodexModel`, and `codexCostUSD(pricing:…)`,
// taken at upstream commit 25bba9b7, 2026-09-28)
// (https://github.com/steipete/CodexBar).
//
// Not verbatim:
//   * Rows are `Rates` values in one table instead of upstream's
//     `CodexPricing` initialisers and its `gpt56Pricing` helper. The numbers
//     are upstream's, re-checked on 2026-09-30 against OpenAI's pricing page
//     and model pages for every model the page lists
//     (https://developers.openai.com/api/docs/pricing).
//   * Rows that are ours, not upstream's, say so where they sit: `gpt-6-sol`,
//     `gpt-6-luna` and `gpt-6.1-sol` (released after 25bba9b7), and the
//     long-context tier on the two `-pro` rows, which OpenAI's page lists and
//     upstream's table leaves out.
//   * Upstream applies an alias inside `normalizeCodexModel`, so the alias
//     also becomes the model's stored and displayed name. Here an alias only
//     chooses the price row: `CostUsageScanner.Pricing.normalizeCodexModel`
//     is unchanged, so every cached day keeps the key it was stored under and
//     a model is shown under the name Codex wrote.
//   * Dated rates are a list per model (`superseded`), not one cutoff each.
//   * `aggregateCostUSD` is ours. The scanner still sums Codex usage per day
//     and model before pricing it, and a per-request tier cannot be applied to
//     a sum; see that function.
//   * Not ported: models.dev lookups, the custom-pricing overlay, API Fast
//     (priority) multipliers, and the pricing fingerprint.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import Foundation

/// OpenAI API list prices for the models Codex writes into its session logs,
/// in US dollars per token, and the prices some of them had before.
///
/// The cost this feeds is an API-equivalent estimate, not a bill: a ChatGPT
/// plan does not charge per token. The table exists so that the estimate uses
/// the rate OpenAI actually lists for the model, on the day it was used.
///
/// Until 1.56 the Mac table stopped at `gpt-5.5`, which it priced at
/// `gpt-5.4`'s $2.50 / $15 with a note to replace the row "when official".
/// Every newer model fell back to that row, so `gpt-6-astra` ($10 / $50) and
/// `gpt-5.6-sol` ($4 / $20) were charged $2.50 / $15, and nothing on screen
/// said the rate was borrowed.
public enum CodexPricingTable {

    /// One model's rates, USD per token.
    public struct Rates: Sendable, Equatable {
        public let input: Double
        public let output: Double
        /// Cached input. nil: OpenAI lists none (the `-pro` rows), so cached
        /// input is charged at `input`.
        public let cachedInput: Double?
        /// Cache writes. nil: charged at `input`. Codex's logs do not report
        /// cache writes separately today, so this rate is carried for fidelity
        /// with the published row rather than used.
        public let cacheWrite: Double?
        /// A request with MORE than this many input tokens is charged the
        /// `…AboveThreshold` rates for the whole request. nil: no tier.
        public let longContextThreshold: Int?
        public let inputAboveThreshold: Double?
        public let outputAboveThreshold: Double?
        public let cachedInputAboveThreshold: Double?
        public let cacheWriteAboveThreshold: Double?

        public init(
            input: Double,
            output: Double,
            cachedInput: Double?,
            cacheWrite: Double? = nil,
            longContextThreshold: Int? = nil,
            inputAboveThreshold: Double? = nil,
            outputAboveThreshold: Double? = nil,
            cachedInputAboveThreshold: Double? = nil,
            cacheWriteAboveThreshold: Double? = nil
        ) {
            self.input = input
            self.output = output
            self.cachedInput = cachedInput
            self.cacheWrite = cacheWrite
            self.longContextThreshold = longContextThreshold
            self.inputAboveThreshold = inputAboveThreshold
            self.outputAboveThreshold = outputAboveThreshold
            self.cachedInputAboveThreshold = cachedInputAboveThreshold
            self.cacheWriteAboveThreshold = cacheWriteAboveThreshold
        }
    }

    /// OpenAI's long-context boundary: "Short context: ≤272K input tokens.
    /// Long context: >272K input tokens" (pricing page), and the whole request
    /// moves to the long-context rates (every model page).
    public static let longContextThreshold = 272_000

    /// The GPT-5.6 and GPT-6 rows share one shape: cached input is 10% of
    /// input, a cache write 1.25x, and above 272K the request pays 2x input
    /// and cache rates and 1.5x output (OpenAI's model pages). Written out as
    /// numbers, not multiplied, so each row can be read against the page.
    private static func tiered(
        standard: (input: Double, cached: Double, write: Double, output: Double),
        longContext: (input: Double, cached: Double, write: Double, output: Double)
    ) -> Rates {
        Rates(
            input: standard.input,
            output: standard.output,
            cachedInput: standard.cached,
            cacheWrite: standard.write,
            longContextThreshold: longContextThreshold,
            inputAboveThreshold: longContext.input,
            outputAboveThreshold: longContext.output,
            cachedInputAboveThreshold: longContext.cached,
            cacheWriteAboveThreshold: longContext.write
        )
    }

    // MARK: - Rates in force today

    /// Today's rates, keyed by the name Codex writes (after
    /// `normalizeCodexModel` drops an `openai/` prefix or a date suffix).
    ///
    /// Source: https://developers.openai.com/api/docs/pricing (standard tier),
    /// checked 2026-09-30, plus the model page named on a row where it adds
    /// something. The page no longer lists the older `-codex` variants
    /// (`gpt-5-codex`, `gpt-5.1-codex`, `-codex-max`, `-codex-mini`,
    /// `gpt-5.2-codex`); their rows are upstream's and equal their base model.
    public static let current: [String: Rates] = [
        "gpt-5": Rates(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5-codex": Rates(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5-mini": Rates(input: 2.5e-7, output: 2e-6, cachedInput: 2.5e-8),
        "gpt-5-nano": Rates(input: 5e-8, output: 4e-7, cachedInput: 5e-9),
        "gpt-5-pro": Rates(input: 1.5e-5, output: 1.2e-4, cachedInput: nil),
        "gpt-5.1": Rates(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5.1-codex": Rates(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5.1-codex-max": Rates(input: 1.25e-6, output: 1e-5, cachedInput: 1.25e-7),
        "gpt-5.1-codex-mini": Rates(input: 2.5e-7, output: 2e-6, cachedInput: 2.5e-8),
        "gpt-5.2": Rates(input: 1.75e-6, output: 1.4e-5, cachedInput: 1.75e-7),
        "gpt-5.2-codex": Rates(input: 1.75e-6, output: 1.4e-5, cachedInput: 1.75e-7),
        "gpt-5.2-pro": Rates(input: 2.1e-5, output: 1.68e-4, cachedInput: nil),
        "gpt-5.3-codex": Rates(input: 1.75e-6, output: 1.4e-5, cachedInput: 1.75e-7),
        // A research preview with no API price. Upstream shows it as
        // "Research Preview"; here it is simply free, as it was before.
        "gpt-5.3-codex-spark": Rates(input: 0, output: 0, cachedInput: 0),
        "gpt-5.4": Rates(
            input: 2.5e-6, output: 1.5e-5, cachedInput: 2.5e-7,
            longContextThreshold: longContextThreshold,
            inputAboveThreshold: 5e-6, outputAboveThreshold: 2.25e-5, cachedInputAboveThreshold: 5e-7
        ),
        "gpt-5.4-mini": Rates(input: 7.5e-7, output: 4.5e-6, cachedInput: 7.5e-8),
        "gpt-5.4-nano": Rates(input: 2e-7, output: 1.25e-6, cachedInput: 2e-8),
        // Long-context tier ours: OpenAI lists $60 / $270 above 272K for both
        // `-pro` rows; upstream's table has no tier on them.
        "gpt-5.4-pro": Rates(
            input: 3e-5, output: 1.8e-4, cachedInput: nil,
            longContextThreshold: longContextThreshold,
            inputAboveThreshold: 6e-5, outputAboveThreshold: 2.7e-4
        ),
        // $5 / $30, $0.50 cached; $10 / $45 / $1 above 272K. The old row was
        // gpt-5.4's rates, written before OpenAI published these.
        "gpt-5.5": Rates(
            input: 5e-6, output: 3e-5, cachedInput: 5e-7,
            longContextThreshold: longContextThreshold,
            inputAboveThreshold: 1e-5, outputAboveThreshold: 4.5e-5, cachedInputAboveThreshold: 1e-6
        ),
        "gpt-5.5-pro": Rates(
            input: 3e-5, output: 1.8e-4, cachedInput: nil,
            longContextThreshold: longContextThreshold,
            inputAboveThreshold: 6e-5, outputAboveThreshold: 2.7e-4
        ),
        // https://developers.openai.com/api/docs/models/gpt-6-astra
        "gpt-6-astra": tiered(
            standard: (input: 1e-5, cached: 1e-6, write: 1.25e-5, output: 5e-5),
            longContext: (input: 2e-5, cached: 2e-6, write: 2.5e-5, output: 7.5e-5)
        ),
        // GPT-5.6. Sol's rate is the one in force since 2026-08-21 (see
        // `superseded`); OpenAI's page calls it promotional "at least through
        // November 21, 2026". Terra and Luna since 2026-07-30.
        "gpt-5.6-sol": tiered(
            standard: (input: 4e-6, cached: 4e-7, write: 5e-6, output: 2e-5),
            longContext: (input: 8e-6, cached: 8e-7, write: 1e-5, output: 3e-5)
        ),
        "gpt-5.6-terra": tiered(
            standard: (input: 2e-6, cached: 2e-7, write: 2.5e-6, output: 1.2e-5),
            longContext: (input: 4e-6, cached: 4e-7, write: 5e-6, output: 1.8e-5)
        ),
        "gpt-5.6-luna": tiered(
            standard: (input: 2e-7, cached: 2e-8, write: 2.5e-7, output: 1.2e-6),
            longContext: (input: 4e-7, cached: 4e-8, write: 5e-7, output: 1.8e-6)
        ),
        // Daybreak Cyber. OpenAI lists no long-context tier for either, and no
        // cache-write rate for gpt-5.5-cyber.
        "gpt-5.6-cyber": Rates(input: 1.25e-5, output: 7.5e-5, cachedInput: 1.25e-6, cacheWrite: 1.5625e-5),
        "gpt-5.5-cyber": Rates(input: 1.25e-5, output: 7.5e-5, cachedInput: 1.25e-6),
        // Ours, not upstream's: released after 25bba9b7 (OpenAI changelog,
        // 2026-09-22 and 2026-09-29). Without rows they would borrow
        // gpt-6-astra's rate, five times theirs.
        // https://developers.openai.com/api/docs/models/gpt-6-sol
        "gpt-6-sol": tiered(
            standard: (input: 2e-6, cached: 2e-7, write: 2.5e-6, output: 1e-5),
            longContext: (input: 4e-6, cached: 4e-7, write: 5e-6, output: 1.5e-5)
        ),
        // https://developers.openai.com/api/docs/models/gpt-6-luna
        "gpt-6-luna": tiered(
            standard: (input: 1e-7, cached: 1e-8, write: 1.25e-7, output: 5e-7),
            longContext: (input: 2e-7, cached: 2e-8, write: 2.5e-7, output: 7.5e-7)
        ),
        // https://developers.openai.com/api/docs/models/gpt-6.1-sol — cached
        // input is 5% of input on this one, not 10%.
        "gpt-6.1-sol": tiered(
            standard: (input: 2e-6, cached: 1e-7, write: 2.5e-6, output: 1e-5),
            longContext: (input: 4e-6, cached: 2e-7, write: 5e-6, output: 1.5e-5)
        ),
    ]

    // MARK: - Rates a model had before

    /// GPT-5.6 Terra and Luna were repriced from 2026-07-30: "Starting July 30,
    /// GPT-5.6 Luna costs 80% less, while GPT-5.6 Terra costs 20% less" (OpenAI
    /// changelog). Upstream dates it 00:00 UTC (Unix 1785369600).
    public static let terraLunaRepricing = Date(timeIntervalSince1970: 1_785_369_600)

    /// GPT-5.6 Sol went from $5 / $30 to $4 / $20 on 2026-08-21 (OpenAI
    /// changelog, "August 21, 2026"). Upstream dates it 00:00 UTC
    /// (Unix 1787270400).
    public static let solRepricing = Date(timeIntervalSince1970: 1_787_270_400)

    /// A rate that applied until `until` (exclusive).
    public struct DatedRates: Sendable {
        public let until: Date
        public let rates: Rates
    }

    /// Earlier rates per model, oldest first. A usage moment before `until`
    /// is charged `rates`; from `until` on, the next entry or `current`.
    public static let superseded: [String: [DatedRates]] = [
        "gpt-5.6-sol": [DatedRates(until: solRepricing, rates: tiered(
            standard: (input: 5e-6, cached: 5e-7, write: 6.25e-6, output: 3e-5),
            longContext: (input: 1e-5, cached: 1e-6, write: 1.25e-5, output: 4.5e-5)
        ))],
        "gpt-5.6-terra": [DatedRates(until: terraLunaRepricing, rates: tiered(
            standard: (input: 2.5e-6, cached: 2.5e-7, write: 3.125e-6, output: 1.5e-5),
            longContext: (input: 5e-6, cached: 5e-7, write: 6.25e-6, output: 2.25e-5)
        ))],
        // Five times today's rate: the July cut was 80%.
        "gpt-5.6-luna": [DatedRates(until: terraLunaRepricing, rates: tiered(
            standard: (input: 1e-6, cached: 1e-7, write: 1.25e-6, output: 6e-6),
            longContext: (input: 2e-6, cached: 2e-7, write: 2.5e-6, output: 9e-6)
        ))],
    ]

    // MARK: - Names that are another model's price

    /// Names Codex can write that OpenAI bills as another listed model.
    /// Upstream's `normalizeCodexModel`: "OpenAI routes the unsuffixed gpt-5.6
    /// alias to Sol", "Codex uses gpt-reserve for the Luna Reserve quota
    /// bucket", and "OpenAI's Daybreak aliases currently point to Sol (blue)
    /// and Cyber (red)". An alias is an exact price, not an approximation.
    public static let aliases: [String: String] = [
        "gpt-5.6": "gpt-5.6-sol",
        "gpt-reserve": "gpt-5.6-luna",
        "gpt-daybreak-blue-latest": "gpt-5.6-sol",
        "gpt-daybreak-red-latest": "gpt-5.6-cyber",
    ]

    // MARK: - Lookup

    /// The rates `key` was charged at `date`; today's when `date` is nil.
    /// `key` is a row name (`current`), not an alias or a raw model name.
    public static func rates(forKey key: String, at date: Date?) -> Rates? {
        if let date, let history = superseded[key] {
            for entry in history where date < entry.until {
                return entry.rates
            }
        }
        return current[key]
    }

    // MARK: - Cost

    /// Cost of ONE request. Upstream's `codexCostUSD(pricing:…)`.
    ///
    /// OpenAI's `input_tokens` is the whole prompt; cached reads are a subset
    /// of it, and cache writes a subset of the rest. Both are clamped so no
    /// token is invented or charged twice. A request over the threshold pays
    /// the long-context rates on every token, not only on the excess.
    public static func requestCostUSD(
        rates: Rates,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int
    ) -> Double {
        let longContext = rates.longContextThreshold.map { max(0, inputTokens) > $0 } ?? false
        return cost(
            rates: rates, longContext: longContext,
            inputTokens: inputTokens, cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens, outputTokens: outputTokens
        )
    }

    /// Cost of a SUM of requests, at standard rates.
    ///
    /// The scanner adds Codex usage up per day and model before pricing it, so
    /// the size of each request is gone by the time a price is chosen. Testing
    /// the threshold against a day's total would put every busy day on
    /// long-context rates, so a sum never takes the tier. Requests over 272K
    /// are therefore under-counted until usage is priced request by request.
    public static func aggregateCostUSD(
        rates: Rates,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Double {
        cost(
            rates: rates, longContext: false,
            inputTokens: inputTokens, cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: 0, outputTokens: outputTokens
        )
    }

    private static func cost(
        rates: Rates,
        longContext: Bool,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int,
        outputTokens: Int
    ) -> Double {
        let totalInput = max(0, inputTokens)
        let cached = min(max(0, cachedInputTokens), totalInput)
        let remainingAfterCache = totalInput - cached
        let cacheWrite = min(max(0, cacheWriteInputTokens), remainingAfterCache)
        let nonCached = remainingAfterCache - cacheWrite

        let inputRate = longContext ? rates.inputAboveThreshold ?? rates.input : rates.input
        let cachedRate = longContext
            ? rates.cachedInputAboveThreshold ?? rates.cachedInput ?? inputRate
            : rates.cachedInput ?? rates.input
        let cacheWriteRate = longContext
            ? rates.cacheWriteAboveThreshold ?? rates.cacheWrite ?? inputRate
            : rates.cacheWrite ?? inputRate
        let outputRate = longContext ? rates.outputAboveThreshold ?? rates.output : rates.output

        return Double(nonCached) * inputRate
            + Double(cached) * cachedRate
            + Double(cacheWrite) * cacheWriteRate
            + Double(max(0, outputTokens)) * outputRate
    }
}

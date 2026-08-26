import Foundation

/// How much of a cost figure the app was actually able to price.
///
/// WHY THIS EXISTS
/// ---------------
/// `CostUsageScanResult.DailyEntry.costUSD` is optional, and every consumer
/// sums it with `if let cost { total += cost }`. An unpriced model therefore
/// contributes nothing and leaves no trace: the total that reaches the UI looks
/// complete, and there is no way to tell that it is not.
///
/// That is how `claude-opus-5` displayed $0 for 25 days across 15.47 billion
/// tokens. Nothing was wrong with the number the app printed — the number simply
/// omitted most of the bill. v1.50 (#456) started logging it; the log is only
/// read by whoever already suspects the total is wrong, which is nobody, because
/// the total looks fine.
///
/// This is the same fact as a value the UI can render. The app already tells the
/// truth in words next to this number — "NOT a real bill" — so admitting which
/// portion of it is unpriced is baseline honesty rather than a paid feature, and
/// it ships to every tier.
///
/// THE PART THAT IS EASY TO GET WRONG
/// ----------------------------------
/// Coverage is only knowable on the local-scan path, where the app counted the
/// tokens itself and knows which models it had rates for. On the cloud-estimate
/// path the number arrives pre-summed from the backend and its composition is
/// unknowable from here.
///
/// So `.serverEstimate` deliberately reports NOTHING rather than 100%. A
/// confident wrong label is worse than silence — claiming full coverage of a
/// figure whose coverage we cannot see would be a new false statement about the
/// product, which is precisely what this work exists to remove.
public struct CostCoverage: Sendable, Equatable {

    /// Where the cost figure came from, which decides whether coverage is
    /// knowable at all.
    public enum Basis: Sendable, Equatable {
        /// The app scanned local JSONL logs and priced each entry itself.
        case localScan
        /// The figure came pre-summed from the backend. Composition unknown.
        case serverEstimate
    }

    public let basis: Basis
    /// Tokens belonging to entries the app had a rate for.
    public let pricedTokens: Int
    /// Tokens belonging to entries with no rate. These contributed $0.
    public let unpricedTokens: Int
    /// Model identifiers with no rate, most tokens first. Never rendered in a
    /// primary label — it is for the tooltip and the bug report.
    public let unpricedModels: [String]

    public init(
        basis: Basis,
        pricedTokens: Int = 0,
        unpricedTokens: Int = 0,
        unpricedModels: [String] = []
    ) {
        self.basis = basis
        self.pricedTokens = pricedTokens
        self.unpricedTokens = unpricedTokens
        self.unpricedModels = unpricedModels
    }

    /// The default for any figure whose composition we cannot see.
    public static let unknown = CostCoverage(basis: .serverEstimate)

    public var totalTokens: Int { pricedTokens + unpricedTokens }

    /// Fraction of counted tokens that carried a rate.
    ///
    /// `nil` when coverage is not knowable (`.serverEstimate`) or when there is
    /// nothing to divide (no tokens at all). Both cases must render as silence,
    /// not as 0% — "0% priced" on an empty account is a false alarm.
    public var pricedFraction: Double? {
        guard basis == .localScan, totalTokens > 0 else { return nil }
        return Double(pricedTokens) / Double(totalTokens)
    }

    /// True only when we looked AND everything carried a rate. A
    /// `.serverEstimate` is never "complete" — it is unknown.
    public var isFullyPriced: Bool {
        basis == .localScan && unpricedTokens == 0
    }

    /// Whether the UI has anything worth saying. Silence is correct for a
    /// complete local scan, an empty account, and any server estimate.
    public var shouldDisclose: Bool {
        guard let fraction = pricedFraction else { return false }
        return fraction < 1.0
    }

    /// Whole-percent priced share, rounded DOWN so the app never rounds 99.6%
    /// up to "100%" and re-tells the exact lie this type exists to prevent.
    public var pricedPercent: Int? {
        guard let fraction = pricedFraction else { return nil }
        return Int((fraction * 100).rounded(.down))
    }

    // MARK: - Derivation

    /// Compute coverage from scanned entries.
    ///
    /// An entry is unpriced when `costUSD == nil` — the same discriminator the
    /// scanner's own diagnostic uses. A model that genuinely costs nothing (a
    /// local Ollama model, say) reports `costUSD == 0` and counts as priced,
    /// which is correct: we knew its rate and the rate was zero.
    ///
    /// Token basis is `input + cached + output`, matching
    /// `CostUsageScanner.reportUnpricedModels` so the log line and the UI can
    /// never disagree about the same scan.
    public static func from(
        entries: [CostUsageScanResult.DailyEntry]
    ) -> CostCoverage {
        var priced = 0
        var unpricedByModel: [String: Int] = [:]

        for entry in entries {
            let tokens = entry.inputTokens + entry.cachedTokens + entry.outputTokens
            if entry.costUSD == nil {
                unpricedByModel[entry.model, default: 0] += tokens
            } else {
                priced += tokens
            }
        }

        return CostCoverage(
            basis: .localScan,
            pricedTokens: priced,
            unpricedTokens: unpricedByModel.values.reduce(0, +),
            unpricedModels: unpricedByModel
                .sorted { lhs, rhs in
                    // Token count descending, then name, so the order is stable
                    // for two models with identical totals (which happens in
                    // tests and on quiet days).
                    lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
                }
                .map(\.key)
        )
    }
}

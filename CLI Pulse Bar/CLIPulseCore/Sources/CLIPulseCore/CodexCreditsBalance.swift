import Foundation

/// Codex's credits balance. It travels in the quota tier list as "Credits", but
/// it is not a window and not an amount of money.
///
/// `GET /wham/usage` reports `credits.balance` in Codex credits, the unit OpenAI
/// sells them in, and as a JSON string ("0", "125.5"): the desktop app's Codex
/// collector hit that against a live account, and the Codex CLI writes the same
/// field as a string into its session logs. Nothing in that response says the
/// number is dollars, so it is shown as "N credits left": no currency sign, and no
/// percentage, because a balance has no allocation to be a percentage of.
///
/// The tier used to be read as a window whose quota was its own remaining value,
/// which can only ever say "100% left", and a balance of 0 made the row vanish.
///
/// Two producers write this tier, at the same scale of `unitsPerCredit` Int units
/// per credit: the Mac app's `CodexCollector` (quota 0, the balance in
/// `remaining`) and the desktop app's Codex collector (`CREDITS_SCALE`, quota =
/// remaining). Readers take `remaining` and ignore `quota`, so both read the same.
/// The Mac leaves quota at 0 on purpose: every reader that works in percentages
/// (quota alerts, the Watch rings, the most-constrained account, and app
/// versions that predate this type) skips a tier whose quota is 0, so none of
/// them can turn a balance back into "100% left".
public enum CodexCreditsBalance {

    /// The stored tier name. English, like every tier name: it is a dedup key
    /// and is translated only when drawn (`L10n.quotaTier.localized`).
    public static let tierName = "Credits"

    /// Int units per credit in the tier's `remaining`. Shared with the desktop
    /// app's collector; changing it misreads every row that app uploads.
    public static let unitsPerCredit: Double = 100_000

    /// Whether a tier is Codex's credits balance rather than a window.
    ///
    /// Keyed on the provider as well as the role: `.credits` is not reserved for
    /// Codex, and another provider's credits may be a real allocation, in its own
    /// unit. The name covers the rows that arrive without a role: the desktop
    /// app writes none, and the provider-level cloud upload drops it.
    public static func isBalance(provider: String, name: String, role: TierRole?) -> Bool {
        guard provider == ProviderKind.codex.rawValue else { return false }
        return role == .credits || name == tierName
    }

    public static func isBalance(_ tier: TierDTO, provider: String) -> Bool {
        isBalance(provider: provider, name: tier.name, role: tier.role)
    }

    /// The tier for a balance read from `/wham/usage`.
    public static func tier(balance: Double) -> TierDTO {
        TierDTO(
            name: tierName,
            quota: 0,
            remaining: units(forBalance: balance),
            reset_time: nil,
            role: .credits
        )
    }

    /// Rounded to the nearest unit; a negative or non-finite balance is 0.
    public static func units(forBalance balance: Double) -> Int {
        guard balance.isFinite, balance > 0 else { return 0 }
        let scaled = (balance * unitsPerCredit).rounded()
        return scaled >= Double(Int.max) ? Int.max : Int(scaled)
    }

    public static func credits(fromUnits units: Int) -> Double {
        Double(max(0, units)) / unitsPerCredit
    }

    /// "1,250 credits left", "1 credit left", "0 credits left".
    public static func leftText(units: Int) -> String {
        L10n.quotaTier.creditsLeft(credits(fromUnits: units))
    }

    /// The row text for a balance tier, or nil when `tier` is a window.
    public static func leftText(for tier: TierDTO, provider: String) -> String? {
        guard isBalance(tier, provider: provider) else { return nil }
        return leftText(units: tier.remaining)
    }

    /// The tiers a quota list draws: the windows that have a quota, and the
    /// balance even at 0, which is when it matters most.
    public static func displayedTiers(_ tiers: [TierDTO], provider: String) -> [TierDTO] {
        tiers.filter { $0.quota > 0 || isBalance($0, provider: provider) }
    }
}

import Foundation

/// Account-aware quota value used by watch glance surfaces. It carries the
/// provider aggregate for identity/cost plus the exact account-derived quota
/// pressure, so Rings and provider cards cannot select different accounts.
public struct WatchProviderQuotaSnapshot:
    Identifiable,
    Sendable
{
    public let provider: ProviderUsage
    public let accountID: UUID?
    public let remainingFraction: Double
    public let isStale: Bool

    public var id: String { provider.id }
    public var usagePercent: Double { 1 - remainingFraction }
    public var remainingPercent: Int {
        Int(remainingFraction * 100)
    }

    public init(
        provider: ProviderUsage,
        accountID: UUID?,
        remainingFraction: Double,
        isStale: Bool
    ) {
        self.provider = provider
        self.accountID = accountID
        self.remainingFraction =
            remainingFraction.clamped(to: 0...1)
        self.isStale = isStale
    }
}

/// Pure quota-window math for the watchOS redesign's Quota rings page and
/// Pulse-home glance. Lives in CLIPulseCore so it is exercised by
/// `swift test` (the watch app target cannot be built or run locally —
/// CI is the only compile path), keeping the app-target SwiftUI thin.
///
/// **Single source of truth (review R4).** Legacy rows derive from
/// `ProviderUsage`; v2 rows derive from the exact most-constrained enabled
/// account selected by `ProviderAccountPresentation`. The resulting snapshot
/// is shared by Rings, cards, and detail views so those surfaces cannot choose
/// different accounts.
///
/// **Window math (review R6).** "Used" is window consumption
/// (`quota - remaining`), NOT `today_usage` — `today_usage` is 0 when
/// the user hasn't run anything yet today even though the rolling window
/// may be 28% consumed. This mirrors the established
/// `WatchProviderCard.displayedUsage` logic, extracted here so the rings,
/// the legend, and the detail views share one definition.
public enum WatchRingMath {

    /// Window-consumption "used" count for a provider.
    ///
    /// When a quota window is present, this is `max(0, quota - remaining)`
    /// — what's been consumed in the current rolling window. With no
    /// quota window we fall back to `today_usage`, which is the only
    /// usage figure available for unmetered providers.
    public static func windowUsed(quota: Int?, remaining: Int?, todayUsage: Int) -> Int {
        if let quota, let remaining {
            return max(0, quota - remaining)
        }
        return todayUsage
    }

    /// Remaining fraction in `0...1`, derived from the canonical
    /// `usagePercent`. `usagePercent` is consumption; remaining is its
    /// complement. Clamped so a momentarily out-of-range input can never
    /// produce a negative arc.
    public static func remainingFraction(usagePercent: Double) -> Double {
        (1.0 - usagePercent).clamped(to: 0...1)
    }

    /// Remaining percent as an integer `0...100` for the ring centre
    /// label ("38%"). Uses the same rounding as the complication
    /// (`Int(remaining * 100)`, i.e. truncation) so the two surfaces
    /// always show the identical number for the same provider.
    public static func remainingPercentInt(usagePercent: Double) -> Int {
        Int(remainingFraction(usagePercent: usagePercent) * 100)
    }

    // MARK: - Per-tier math (5h / Weekly / model windows)

    // `TierDTO` (5h Window, Weekly, …) carries raw `quota`/`remaining`
    // counts but no `usagePercent`, so these derive both the bar fill
    // (remaining, counting down like macOS/iOS) and the colour tier from
    // those counts — the tier-level analogue of `ProviderUsage.usagePercent`.

    /// Remaining fraction `0...1` for a quota/remaining pair (bar fill).
    public static func remainingFraction(quota: Int, remaining: Int) -> Double {
        guard quota > 0 else { return 0 }
        return (Double(remaining) / Double(quota)).clamped(to: 0...1)
    }

    /// Consumption fraction `0...1` for a quota/remaining pair (colour tier).
    public static func usagePercent(quota: Int, remaining: Int) -> Double {
        guard quota > 0 else { return 0 }
        return (Double(max(0, quota - remaining)) / Double(quota)).clamped(to: 0...1)
    }

    /// Remaining percent `0...100` for a quota/remaining pair (bar label).
    public static func remainingPercentInt(quota: Int, remaining: Int) -> Int {
        Int(remainingFraction(quota: quota, remaining: remaining) * 100)
    }

    // MARK: - Account-aware quota snapshots

    public static func quotaSnapshot(
        for provider: ProviderUsage,
        accounts: [ProviderAccountUsage],
        now: Date = Date()
    ) -> WatchProviderQuotaSnapshot? {
        let providerAccounts: [ProviderAccountUsage]
        if let kind = ProviderKind(rawValue: provider.provider) {
            providerAccounts =
                ProviderAccountPresentation.enabledAccounts(
                    accounts
                )
                .filter { $0.provider == kind }
        } else {
            providerAccounts = []
        }

        if !providerAccounts.isEmpty {
            guard
                let account = ProviderAccountPresentation
                    .mostConstrainedEnabledAccount(
                        in: providerAccounts
                    ),
                let fraction = ProviderState.remainingFraction(
                    for: account
                )
            else {
                return nil
            }
            return WatchProviderQuotaSnapshot(
                provider: provider,
                accountID: account.id,
                remainingFraction: fraction,
                isStale:
                    ProviderAccountPresentation.isStale(
                        account,
                        now: now
                    )
            )
        }

        guard provider.quota != nil else { return nil }
        return WatchProviderQuotaSnapshot(
            provider: provider,
            accountID: nil,
            remainingFraction: remainingFraction(
                usagePercent: weeklyUsagePercent(provider)
            ),
            isStale: false
        )
    }

    /// Canonical provider pressure order for every watch quota surface.
    /// Fresh snapshots come before stale last-known values, then least
    /// remaining headroom first. Activity and provider name only break ties.
    public static func orderedQuotaSnapshots(
        _ providers: [ProviderUsage],
        accounts: [ProviderAccountUsage],
        now: Date = Date()
    ) -> [WatchProviderQuotaSnapshot] {
        providers.compactMap { provider in
            quotaSnapshot(
                for: provider,
                accounts: accounts,
                now: now
            )
        }
        .sorted { lhs, rhs in
            if lhs.isStale != rhs.isStale {
                return !lhs.isStale
            }
            if lhs.remainingFraction
                != rhs.remainingFraction {
                return lhs.remainingFraction
                    < rhs.remainingFraction
            }
            if lhs.provider.today_usage
                != rhs.provider.today_usage {
                return lhs.provider.today_usage
                    > rhs.provider.today_usage
            }
            if lhs.provider.estimated_cost_today
                != rhs.provider.estimated_cost_today {
                return lhs.provider.estimated_cost_today
                    > rhs.provider.estimated_cost_today
            }
            return lhs.provider.provider
                < rhs.provider.provider
        }
    }

    /// Only fresh snapshots earn an activity ring. Stale values remain
    /// available in provider/account cards as explicitly labelled last-known
    /// data, but never drive the live glance or urgency ordering.
    public static func liveRingSnapshots(
        _ providers: [ProviderUsage],
        accounts: [ProviderAccountUsage],
        now: Date = Date(),
        limit: Int = 3
    ) -> [WatchProviderQuotaSnapshot] {
        let fresh = orderedQuotaSnapshots(
            providers,
            accounts: accounts,
            now: now
        )
        .filter { !$0.isStale }
        return Array(fresh.prefix(max(0, limit)))
    }

    // MARK: - Threshold tiers

    /// Colour tier for a consumption fraction. The boundaries match the
    /// shipped gauge/card thresholds exactly (`> 0.9` red, `> 0.7`
    /// amber) so migrating the existing views onto this helper introduces
    /// zero behavioural change at the boundary (review R6 — reuse
    /// existing thresholds).
    public enum RingTier: String, Sendable, Equatable {
        case normal
        case warning
        case critical
    }

    public static func tier(usagePercent: Double) -> RingTier {
        if usagePercent > 0.9 { return .critical }
        if usagePercent > 0.7 { return .warning }
        return .normal
    }

    // MARK: - Ring selection

    /// The providers that earn a concentric ring on the Quota page.
    ///
    /// Only providers with a real quota window can render a meaningful
    /// ring (no quota → `usagePercent == 0` → an empty ring that says
    /// nothing), so unmetered providers are filtered out. The survivors
    /// are ordered by **today's token usage** (most-active first) — the
    /// same "main" provider the Pulse-home teaser features — so it gets the
    /// outermost ring and the centre label, capped at `limit` (default 3)
    /// for legibility at 41/45/49 mm.
    ///
    /// The sort is deterministic: ties on `today_usage` break on cost, then
    /// `provider` name, so the ring order is stable across refreshes.
    public static func ringProviders(_ providers: [ProviderUsage], limit: Int = 3) -> [ProviderUsage] {
        let metered = providers.filter { $0.quota != nil }
        let sorted = metered.sorted { a, b in
            if a.today_usage != b.today_usage {
                return a.today_usage > b.today_usage
            }
            if a.estimated_cost_today != b.estimated_cost_today {
                return a.estimated_cost_today > b.estimated_cost_today
            }
            return a.provider < b.provider
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// The most-active metered provider — the one with the most token usage
    /// today (the user's real "main" provider). Drives the Pulse-home quota
    /// teaser. Filtered to providers with a quota window so the teaser can
    /// show a "% left". `nil` when none is metered. Ties resolve on name.
    public static func mostActive(_ providers: [ProviderUsage]) -> ProviderUsage? {
        providers
            .filter { $0.quota != nil }
            .max { a, b in
                if a.today_usage != b.today_usage { return a.today_usage < b.today_usage }
                return a.provider > b.provider
            }
    }

    // MARK: - Weekly window

    /// The provider's **Weekly** window tier, if it reports one. Prefers an
    /// explicit `role == .secondary`, else falls back to a tier whose name
    /// contains "week" (both Claude and Codex name it "Weekly"). `nil` when
    /// the provider has no weekly window.
    public static func weeklyTier(_ provider: ProviderUsage) -> TierDTO? {
        provider.tiers.first { $0.role == .secondary }
            ?? provider.tiers.first { $0.name.localizedCaseInsensitiveContains("week") }
    }

    /// Consumption fraction `0...1` for the provider's **Weekly** window,
    /// falling back to the provider's primary `usagePercent` when there is
    /// no weekly tier. The Quota rings use this so the arc tracks the slower
    /// weekly budget rather than the fast 5h/session window.
    public static func weeklyUsagePercent(_ provider: ProviderUsage) -> Double {
        if let w = weeklyTier(provider) {
            return usagePercent(quota: w.quota, remaining: w.remaining)
        }
        return provider.usagePercent
    }

    /// Remaining percent `0...100` for the provider's Weekly window.
    public static func weeklyRemainingPercentInt(_ provider: ProviderUsage) -> Int {
        remainingPercentInt(usagePercent: weeklyUsagePercent(provider))
    }
}

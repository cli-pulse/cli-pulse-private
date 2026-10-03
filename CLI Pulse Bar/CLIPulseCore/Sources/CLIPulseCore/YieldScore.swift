import Foundation

/// One day's worth of yield data for a single provider, decoded directly
/// from the `yield_score_daily` rollup table in Supabase.
public struct YieldScoreRow: Codable, Sendable, Hashable {
    public let provider: String
    public let day: String              // ISO date (YYYY-MM-DD)
    public let total_cost: Double
    public let weighted_commit_count: Double
    public let raw_commit_count: Int
    public let ambiguous_commit_count: Int

    public var providerKind: ProviderKind? { ProviderKind(rawValue: provider) }
    /// UTC midnight of `day`. Parsed in Gregorian numbering whatever the
    /// device calendar: a bare formatter under the Japanese calendar read
    /// "2026-09-17" as the year 4044, and every row fell outside the window.
    public var dayDate: Date? {
        DayKey.formatter(in: DayKey.utc).date(from: day)
    }
}

/// A per-provider yield summary aggregated over a user-chosen window
/// (e.g. last 7/30/90 days). Computed client-side from `YieldScoreRow`s.
public struct YieldScoreSummary: Identifiable, Sendable, Hashable {
    public let id: String                    // provider name doubles as identifier
    public let provider: String
    public let totalCost: Double
    /// Sum of normalized weights across the window. May be fractional when
    /// commits are co-attributed across multiple overlapping sessions.
    public let weightedCommits: Double
    /// Total commit count, ignoring weighting (informational only).
    public let rawCommits: Int
    public let ambiguousCommits: Int
    public let rangeStart: Date
    public let rangeEnd: Date

    /// Cost per weighted commit, or nil when no commits attributed.
    public var costPerCommit: Double? {
        guard weightedCommits > 0 else { return nil }
        return totalCost / weightedCommits
    }

    public var providerKind: ProviderKind? { ProviderKind(rawValue: provider) }

    public init(
        provider: String, totalCost: Double, weightedCommits: Double,
        rawCommits: Int, ambiguousCommits: Int,
        rangeStart: Date, rangeEnd: Date
    ) {
        self.id = provider
        self.provider = provider
        self.totalCost = totalCost
        self.weightedCommits = weightedCommits
        self.rawCommits = rawCommits
        self.ambiguousCommits = ambiguousCommits
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }
}

public enum YieldScoreRange: String, CaseIterable, Identifiable, Sendable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        }
    }

    public var label: String {
        switch self {
        case .sevenDays: return L10n.yield.rangeLast7Days
        case .thirtyDays: return L10n.yield.rangeLast30Days
        case .ninetyDays: return L10n.yield.rangeLast90Days
        }
    }
}

public enum YieldScoreAggregator {
    /// Aggregate raw daily rows into per-provider summaries over a date window.
    /// `now` defaults to the current date so callers in tests can pin time.
    public static func summarize(
        rows: [YieldScoreRow],
        range: YieldScoreRange,
        now: Date = Date()
    ) -> [YieldScoreSummary] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.days, to: now) ?? now
        let windowStart = Calendar.current.startOfDay(for: cutoff)
        let windowEnd = now

        // Bucket by provider, summing weights/cost within the window
        var buckets: [String: (cost: Double, weighted: Double, raw: Int, ambiguous: Int)] = [:]
        for row in rows {
            guard let day = row.dayDate, day >= windowStart, day <= windowEnd else { continue }
            var entry = buckets[row.provider] ?? (0, 0, 0, 0)
            entry.cost += row.total_cost
            entry.weighted += row.weighted_commit_count
            entry.raw += row.raw_commit_count
            entry.ambiguous += row.ambiguous_commit_count
            buckets[row.provider] = entry
        }

        return buckets.map { (provider, data) in
            YieldScoreSummary(
                provider: provider,
                totalCost: data.cost,
                weightedCommits: data.weighted,
                rawCommits: data.raw,
                ambiguousCommits: data.ambiguous,
                rangeStart: windowStart,
                rangeEnd: windowEnd
            )
        }.sorted { ($0.costPerCommit ?? .infinity) < ($1.costPerCommit ?? .infinity) }
    }
}

/// What the Overview's Yield Score card shows, if anything.
///
/// Its rows come from `yield_score_daily`, which only the `.pkg` helper's git
/// collector feeds (`helper/cli_pulse_helper.py`), and the prompt it shows with
/// tracking off sends people to a switch in Settings › Advanced that only a
/// paired account has (from 1.56 Advanced itself is shown without one, but
/// that switch is not: `SettingsAccountSections.Advanced.showsAccountControls`).
/// So the prompt appears only on a paired Mac with a helper on it
/// (the owner's call for the Mac App Store build, 2026-09-30). Anywhere else it
/// pointed at a switch that was not there, for a number that could not arrive:
/// the Mac App Store build in local mode, and Demo mode, whose Overview is what
/// the store screenshots draw.
///
/// "A helper" is `HelperInstaller.helperPresent`, which also counts the
/// Developer ID build's built-in Swift helper (`.bundled`). That helper has no
/// git collector, so on a Developer ID Mac running only the built-in helper the
/// prompt shows although this Mac cannot supply rows: the switch is the
/// account's, and rows arrive only if another Mac on the account runs the
/// `.pkg` helper. The App Store build does not ship the built-in helper, so
/// there "a helper" is always the `.pkg` one. Before #609 the prompt showed
/// everywhere, so no Mac shows it where it did not before.
public enum YieldScoreCardContent: Equatable, Sendable {
    /// No card.
    case hidden
    /// Tracking is off: say what the score is and where to turn it on.
    case turnOnTracking
    /// Tracking is on, and no commit in the window has been attributed yet.
    case noAttribution
    /// Per-provider cost per commit.
    case summaries

    /// - Parameters:
    ///   - isDemoMode: Demo mode, which has no yield data and no Settings for it.
    ///   - thisMacIsPaired: `AuthState.isThisMacSyncing`, what the account card
    ///     calls paired.
    ///   - helperPresent: `HelperInstaller.helperPresent`.
    ///   - trackingEnabled: the account's `track_git_activity`.
    ///   - hasSummaries: whether the selected window has any rows.
    public static func resolve(
        isDemoMode: Bool,
        thisMacIsPaired: Bool,
        helperPresent: Bool,
        trackingEnabled: Bool,
        hasSummaries: Bool
    ) -> Self {
        if isDemoMode { return .hidden }
        if trackingEnabled { return hasSummaries ? .summaries : .noAttribution }
        if thisMacIsPaired && helperPresent { return .turnOnTracking }
        // Someone who tracked before keeps the numbers they have, rather than a
        // prompt for a switch this Mac cannot show them.
        return hasSummaries ? .summaries : .hidden
    }
}

#if os(macOS)
extension YieldScoreCardContent {
    /// What the card shows for the app's live state. `YieldScoreCard` calls
    /// this, so the choice of flags lives where a test can see it: this Mac's
    /// pairing (`isThisMacSyncing`), not the account's (`isPaired`, true while
    /// any of its devices is paired), and the installer's `helperPresent`,
    /// which holds through the `.checking` of each re-probe.
    @MainActor
    public static func resolve(
        state: AppState, auth: AuthState, installer: HelperInstaller
    ) -> Self {
        resolve(
            isDemoMode: state.isDemoMode,
            thisMacIsPaired: auth.isThisMacSyncing,
            helperPresent: installer.helperPresent,
            trackingEnabled: state.gitTrackingEnabled,
            hasSummaries: !state.yieldScoreSummaries.isEmpty
        )
    }
}
#endif

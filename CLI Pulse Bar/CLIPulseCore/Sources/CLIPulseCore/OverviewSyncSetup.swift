import Foundation

// The iPhone's and iPad's "Waiting for data" card (`iOSSyncOnboardingCard`,
// in the iOS target): when the Overview draws it above a dashboard that has
// arrived.
//
// 1.59. Up to 1.58 the Overview drew the card only while it had no dashboard
// at all, that is before the first cloud refresh or after a failed one. But
// `dashboard_summary` answers an account with nothing synced with zeros, so
// after any refresh that worked the dashboard is there. A signed-in iPhone
// whose account had nothing synced opened on zero tiles, "No synced usage
// history yet" and "No enabled providers with data": no reason, and no step
// to take on the Mac. The card now draws above those zeros as well, until
// anything synced arrives. It says what it always said; no new text.

public enum OverviewSyncSetup {
    /// Whether the account behind a dashboard that has arrived has nothing
    /// synced, so the Overview draws the setup card above its zeros.
    ///
    /// Anything synced hides the card:
    /// - a provider row. `provider_summary` returns one for every provider
    ///   with a daily row in the last 30 days or a quota row, and none for an
    ///   account with neither;
    /// - a provider account;
    /// - a daily row in the fetched window (`dailyUsage`), or a day in the
    ///   year's archive (`archive`, which the Activity card loads);
    /// - a session;
    /// - a figure for today, or a provider row, on the dashboard itself.
    ///
    /// An online Mac, or an alert, does not hide it. A Mac that is paired and
    /// online but uploads nothing is the account the card is for.
    ///
    /// Never in Demo: it is not an account, and every screenshot is drawn
    /// from it.
    public static func accountHasNothingSynced(
        isDemoMode: Bool,
        dashboard: DashboardSummary,
        providers: [ProviderUsage],
        providerAccounts: [ProviderAccountUsage],
        dailyUsage: [DailyUsage],
        archive: DailyUsageArchive,
        sessions: [SessionRecord]
    ) -> Bool {
        guard !isDemoMode else { return false }
        let dashboardHasData = dashboard.total_usage_today > 0
            || dashboard.total_estimated_cost_today > 0
            || dashboard.total_requests_today > 0
            || dashboard.active_sessions > 0
            || !dashboard.provider_breakdown.isEmpty
        return !dashboardHasData
            && providers.isEmpty
            && providerAccounts.isEmpty
            && dailyUsage.isEmpty
            && archive.days.isEmpty
            && sessions.isEmpty
    }
}

public extension AppState {
    /// `OverviewSyncSetup.accountHasNothingSynced` for this state's account.
    /// False while no dashboard has arrived: the Overview then draws the card
    /// in place of the dashboard, as it always has.
    var overviewAccountHasNothingSynced: Bool {
        guard let dashboard else { return false }
        return OverviewSyncSetup.accountHasNothingSynced(
            isDemoMode: isDemoMode,
            dashboard: dashboard,
            providers: providers,
            providerAccounts: providerAccounts,
            dailyUsage: dailyUsage,
            archive: usageArchive,
            sessions: sessions
        )
    }
}

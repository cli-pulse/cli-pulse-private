import Foundation

// The Overview's two optional cards, Top Projects and Risk Signals: when they
// draw, and where their rows come from. One rule for the Mac, iPhone and Watch
// Overviews, and one path for Demo and a real account.
//
// Every App Store screenshot is drawn from Demo, and Demo used to fill both
// cards (three projects; a low-quota and a device-offline signal) while no real
// account could see either: nothing fills `top_projects`, and the only risk
// signal anything raises is "No AI tools detected". So each localized set sold
// two cards no customer had. Demo now leaves `top_projects` empty, as every
// real producer does, and takes its risk signals from the local refresh's
// producer with its own facts; the cards follow the rule below, so they hide
// in Demo exactly as they do for everyone else.

public extension DashboardSummary {
    /// The Top Projects card draws only with projects to list. Nothing fills
    /// `top_projects` today: the cloud's `dashboard_summary` has no project
    /// column (`APIClient.dashboardSummary(from:)`) and the local refresh
    /// keeps no per-project totals (`DataRefreshManager`). Until 1.55 the card
    /// drew anyway, telling everyone "No projects tracked yet".
    var showsTopProjectsCard: Bool { !top_projects.isEmpty }

    /// The Risk Signals card draws only with a signal to show.
    var showsRiskSignalsCard: Bool { !risk_signals.isEmpty }
}

/// The risk signals a real account can see. They are display text that
/// `RiskSignalsList` shows verbatim, held in memory and never synced, so they
/// are resolved here in the active language.
public enum DashboardRiskSignals {
    /// The local refresh's only signal: "No AI tools detected", when neither
    /// the session scan nor any provider collector found anything. The cloud
    /// dashboard sends none. Demo calls this with its own sessions and
    /// providers, so it raises exactly what an account in its state would.
    public static func local(foundSessions: Bool, foundProviderData: Bool) -> [String] {
        foundSessions || foundProviderData ? [] : [L10n.dashboard.noAiToolsDetected]
    }
}

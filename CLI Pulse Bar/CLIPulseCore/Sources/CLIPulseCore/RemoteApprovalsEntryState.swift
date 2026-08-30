import Foundation

/// Pure-derived UI state for "should we show the Remote Approvals entry,
/// and if so does it carry a count badge?". Extracted from MenuBarView /
/// iOSSettingsTab / iOSOverviewTab so the visibility logic is testable
/// without spinning up SwiftUI.
///
/// **Why this exists.** v1.11.0 shipped with the Mac footer pill only
/// visible when `remotePendingApprovals.count > 0`. That created a
/// dead-loop: the slow background refresh hadn't picked up a fresh
/// pending row yet, so the pill was hidden, so the user couldn't open
/// the sheet, so the active 3s polling never started, so the hook
/// timed out into deny+message. Always-on entry breaks that cycle.
public enum RemoteApprovalsEntryState: Equatable, Sendable {
    /// Hide the entry. Used when the remote session plane is off.
    case hidden

    /// Show the entry without a count badge. Tapping opens the sheet,
    /// which kicks off active 3s polling. Used when Remote Control is
    /// enabled but no pending requests are currently visible (could be
    /// because there genuinely are none, or because the slow background
    /// refresh hasn't picked up the latest yet).
    case visibleNoBadge

    /// Show the entry with a count badge. Tapping opens the sheet.
    case visibleWithBadge(count: Int)

    /// `true` when the entry should be rendered at all.
    public var isVisible: Bool {
        switch self {
        case .hidden:                   return false
        case .visibleNoBadge:           return true
        case .visibleWithBadge:         return true
        }
    }

    /// `nil` when no badge should render. Always positive when non-nil.
    public var badgeCount: Int? {
        switch self {
        case .hidden, .visibleNoBadge:  return nil
        case .visibleWithBadge(let c):  return c
        }
    }

    /// Always-visible entry (footer pill on Mac, NavigationLink in iOS
    /// Settings), with an optional pending-count badge.
    ///
    /// The parameter is the SESSION plane, not the `remote_control_enabled`
    /// setting. Approvals are tool-permission prompts from a remotely-driven
    /// CLI session; with that plane retired there is nothing to approve. The
    /// setting itself lives on — it still authorises machine controls.
    public static func footer(remoteSessionsEnabled: Bool, pendingCount: Int) -> RemoteApprovalsEntryState {
        guard remoteSessionsEnabled else { return .hidden }
        if pendingCount > 0 {
            return .visibleWithBadge(count: pendingCount)
        }
        return .visibleNoBadge
    }

    /// Pending-only banner (iOS Overview). Visible only when there is
    /// something to act on. The footer entry handles the always-visible
    /// affordance separately.
    public static func banner(remoteSessionsEnabled: Bool, pendingCount: Int) -> RemoteApprovalsEntryState {
        guard remoteSessionsEnabled, pendingCount > 0 else { return .hidden }
        return .visibleWithBadge(count: pendingCount)
    }
}

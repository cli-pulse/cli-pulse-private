import Foundation

/// Which alerts are allowed to raise a user-visible notification.
///
/// Extracted from `DataRefreshManager`'s refresh loop so it can be tested
/// without driving a full refresh — the same reason `SessionControlPredicates`
/// exists. The loop is thousands of lines and reachable only through network
/// and disk state; a policy this small should not need any of that to pin.
///
/// **Why it exists at all.** Until 2026-08-31 the "Session quota notifications"
/// setting had NO reader. The toggle rendered, persisted to
/// `cli_pulse_session_quota_notifications`, and carried the hint "Notify when
/// 5-hour session quota is depleted" — while the dispatch consulted only the
/// master switch. A user who turned it off kept getting quota banners, and the
/// only way to stop them was to silence every notification.
public enum AlertNotificationPolicy {

    /// The alert type `AlertGenerator` emits for a depleted 5-hour window.
    ///
    /// Duplicated from the generator's payload literal on purpose — they are in
    /// different modules — so `test_theQuotaTypeMatchesWhatTheGeneratorEmits`
    /// reads the generator's source and fails if either side moves. A copied
    /// constant without a drift gate is how these two silently stop agreeing.
    public static let quotaWarningType = "Quota Warning"

    /// `true` when this alert may raise a notification.
    ///
    /// The master switch is a hard gate; the quota switch is a per-type filter
    /// *underneath* it. So: master off silences everything, quota off silences
    /// only quota warnings, and neither can re-enable what the other blocked.
    public static func shouldNotify(
        alertType: String,
        notificationsEnabled: Bool,
        sessionQuotaNotificationsEnabled: Bool
    ) -> Bool {
        guard notificationsEnabled else { return false }
        if alertType == quotaWarningType {
            return sessionQuotaNotificationsEnabled
        }
        return true
    }
}

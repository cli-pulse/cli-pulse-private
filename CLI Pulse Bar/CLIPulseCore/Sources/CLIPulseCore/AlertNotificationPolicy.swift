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

    /// Whether *now* is a moment to ask the system for notification
    /// authorization.
    ///
    /// **The bug this exists to prevent.** Until v1.52.1 the only production
    /// caller of `requestNotificationPermission()` was
    /// `setRemoteControlEnabled(true)`. That was correct when it was written:
    /// remote **approvals** were the sole notification consumer, and the
    /// Remote Control switch was the opt-in for them. Approvals were retired,
    /// the switch now gates machine controls only (fan target, low-power mode,
    /// keep-awake) and sends no notification of any kind — while alerts, which
    /// DO notify and whose master switch defaults to ON, had no trigger at all.
    ///
    /// Net effect on a real user: enable nothing, touch nothing, receive
    /// nothing. `notificationsEnabled` reads `true` in Settings, the dispatch
    /// path runs, and every alert notification is dropped by the system
    /// because authorization was never requested. Silent, and invisible from
    /// inside the app.
    ///
    /// **Why it is a predicate and not just an `if`.** The two conditions are
    /// load-bearing in opposite directions and each has already been got wrong
    /// once:
    ///
    /// - `isAuthenticated` — the iter8 hotfix. An unconditional prompt at
    ///   launch fired before sign-in, so `syncPushToken` hit the server with
    ///   no JWT and printed "Session expired" onto the login screen.
    /// - `notificationsEnabled` — asking a user who has explicitly silenced
    ///   notifications is a prompt we can never honour. iOS only ever shows
    ///   the system dialog once; spending it here means the user who later
    ///   turns the switch back on can never be asked again.
    ///
    /// Callers additionally rely on `requestNotificationPermission()`'s own
    /// `.notDetermined` check, so this may be consulted on every appearance
    /// without nagging.
    public static func shouldRequestAuthorization(
        isAuthenticated: Bool,
        notificationsEnabled: Bool
    ) -> Bool {
        isAuthenticated && notificationsEnabled
    }
}

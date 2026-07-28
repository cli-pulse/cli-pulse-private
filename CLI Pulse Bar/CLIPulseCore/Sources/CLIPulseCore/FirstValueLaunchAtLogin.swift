#if os(macOS)
import Foundation

/// v1.44 W5 — turn on "start at login" the first time the app produces data.
///
/// `SMAppService.mainApp.register()` has exactly one caller in the repo: a
/// toggle in Settings → Advanced that is off by default and that almost nobody
/// opens. A background menu-bar app that does not start at login cannot have
/// weekly actives, and the numbers say exactly that: 23 devices active over 30
/// days collapse to ~7 over 7 days; 16 MAU to 2 WAU. Retention here is mostly
/// "is the process running", not "did the user feel like opening it".
///
/// Two rules make this acceptable rather than sneaky, and both are load-bearing
/// for App Review as much as for honesty:
///
///  1. **Only at first value.** Enabling at launch would be a background app
///     making itself permanent before it has shown the user anything. Waiting
///     until a collector actually produced numbers means the app has earned the
///     slot, and a user who never gets data never gets a login item.
///  2. **Say so, and make undo one tap.** The caller pairs this with a visible
///     notice. A silent registration is the version of this feature that
///     deserves to be rejected.
///
/// The user's own choice always wins: once they have touched the Settings
/// toggle in either direction, this never fires again.
public enum FirstValueLaunchAtLogin {

    /// Set once the automatic enable has happened (or been declined), so it is
    /// a one-shot for the lifetime of the install.
    public static let didAutoEnableKey = "cli_pulse_did_auto_enable_login_item"
    /// Set when the user touches the Settings toggle themselves. Their explicit
    /// choice outranks our automatic one, in both directions.
    public static let userTouchedToggleKey = "cli_pulse_user_set_login_item"

    public enum Decision: Equatable {
        /// Register the login item and show the notice.
        case enableAndNotify
        /// Do nothing.
        case skip
        /// Do nothing, AND record that the user has expressed a preference, so
        /// this never re-evaluates. Used when we can see they turned the login
        /// item off themselves.
        case skipAndRememberUserChoice
    }

    /// The three login-item states that matter here, because `== .enabled` is
    /// not enough to answer "may we turn this on?".
    ///
    /// `SMAppService.Status.requiresApproval` means the item IS registered but
    /// the user switched it off in System Settings. A naive `status == .enabled`
    /// check reads that as false — the same answer it gives for "never
    /// registered" — so the app would cheerfully re-enable something the user
    /// had just deliberately turned off. `FanDaemonInstaller.state()` in this
    /// same package already distinguishes all four cases; this mirrors it.
    public enum LoginItemState: Equatable {
        /// Registered and permitted to run.
        case enabled
        /// Registered, but the user disabled it in System Settings.
        case userDisabled
        /// Never registered, or unregistered.
        case notRegistered
    }

    /// Pure decision. Every input is injected so all five reasons to skip are
    /// testable without a real `SMAppService`, which cannot be driven from a
    /// unit test.
    ///
    /// - Parameters:
    ///   - producedValue: a collector returned real numbers on this pass.
    ///   - alreadyEnabled: the login item is already registered.
    ///   - alreadyAutoEnabled: we have already done this once.
    ///   - userTouchedToggle: the user has set the toggle themselves.
    public static func decide(
        producedValue: Bool,
        loginItem: LoginItemState,
        alreadyAutoEnabled: Bool,
        userTouchedToggle: Bool
    ) -> Decision {
        // The user's explicit choice is final — including an explicit OFF,
        // which is the case that makes this feature respectful rather than
        // merely legal. Re-enabling something someone deliberately switched off
        // is how an app earns a one-star review.
        guard !userTouchedToggle else { return .skip }

        // Checked BEFORE `alreadyAutoEnabled`, and it is the whole point of
        // this fix. `userTouchedToggle` is a v1.44 key, so NOBODY upgrading
        // from v1.43 has it — an existing user who had turned the login item
        // off in System Settings would otherwise sail through every remaining
        // guard and have it switched back on. Same shape as the bug in #382:
        // a new flag cannot speak for the install base that predates it, so
        // the state has to be read from the system instead.
        if loginItem == .userDisabled { return .skipAndRememberUserChoice }

        guard !alreadyAutoEnabled else { return .skip }
        guard loginItem == .notRegistered else { return .skip }
        guard producedValue else { return .skip }
        return .enableAndNotify
    }

    /// Map `SMAppService.Status` to the three cases that matter. Kept separate
    /// from `decide` so the mapping is testable without a live SMAppService.
    public static func loginItemState(isEnabled: Bool, requiresApproval: Bool) -> LoginItemState {
        if isEnabled { return .enabled }
        if requiresApproval { return .userDisabled }
        return .notRegistered
    }

    /// Did this pass produce real numbers? Reuses the W3 outcome taxonomy so
    /// "first value" means the same thing here as it does in the provider rows
    /// and in the telemetry — one definition, not three.
    ///
    /// Note `ranButEmpty` deliberately does NOT count: a collector that ran and
    /// returned nothing is exactly the silent-zero case, and treating it as
    /// value would make a login item out of an app that is showing the user
    /// nothing at all.
    public static func producedValue(_ outcomes: [ProviderKind: CollectorOutcome]) -> Bool {
        outcomes.values.contains { $0 == .producedData }
    }
}
#endif

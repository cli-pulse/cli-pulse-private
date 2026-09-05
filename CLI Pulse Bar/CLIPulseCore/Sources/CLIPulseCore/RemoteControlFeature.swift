import Foundation

/// Whether this build offers remote control (phone → Mac) at all.
///
/// ── Why this exists (plan M3, "dark-ship") ──
/// Remote control shipped to `main` across #527–#532 and is verified on
/// hardware, but until #531 it reached every Developer ID user the moment a
/// release went out, with no way to hold it back. This is that way: the
/// CODE ships, the FEATURE stays dormant, and it is turned on deliberately
/// — for the owner's own machine, or for a small internal group — while the
/// plan's §8 counters decide whether the self-built transport is worth
/// keeping at all.
///
/// ── This is NOT the user's switch ──
/// `LANLinkAgent.isEnabled` is the user-facing "let paired iPhones watch and
/// control sessions" toggle in Settings. THIS is a build-level gate above
/// it: when it is off, that toggle is not rendered, the agent never opens a
/// listener, and nothing is advertised on Bonjour. Conflating the two is the
/// "one switch, two features" mistake this repo has already paid for once.
///
/// ── Turning it on ──
/// ```
/// defaults write ~/Library/Preferences/yyh.CLI-Pulse.plist \
///     cli_pulse_remote_control_feature_enabled -bool true
/// ```
/// (Write by PATH. Writing to the bare domain lands in the MAS container's
/// shadow copy and the app will not see it.)
public enum RemoteControlFeature {

    /// The override key. Absent ⇒ `shippedDefault`.
    public static let overrideDefaultsKey = "cli_pulse_remote_control_feature_enabled"

    /// What a fresh install gets. **False on purpose**: a release must not
    /// expose remote control until that is a decision someone made.
    /// `RemoteControlFeatureTests` pins this value, so flipping it is a
    /// visible, deliberate act rather than a drive-by edit.
    public static let shippedDefault = false

    /// Only a real boolean counts. `UserDefaults.bool(forKey:)` reads "1",
    /// "YES" and 1 as true, so a stray string in the plist could otherwise
    /// ship the feature by accident.
    public static func isAvailable(in defaults: UserDefaults = .standard) -> Bool {
        guard let raw = defaults.object(forKey: overrideDefaultsKey) else { return shippedDefault }
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return shippedDefault }
        return n.boolValue
    }
}

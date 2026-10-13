import Foundation

/// The remote off switch for reading Codex's limit reset credits.
///
/// Reset credits come from `GET /wham/rate-limit-reset-credits`, an endpoint
/// OpenAI does not document. If it starts misbehaving, or OpenAI asks us to
/// stop calling it, the Developer ID build can be told to stop through the
/// update manifest it already fetches: `"reset_credits_enabled": false` in
/// `latest.json` (`AppUpdater.Manifest.resetCreditsEnabled`). The App Store
/// build has no such channel and relies on the read being fail-isolated: a 4 s
/// budget, nothing kept from a failed read, the quota read untouched.
///
/// **An absent key means enabled.** It is a kill switch for a read-only
/// display, not a staged rollout:
///
/// - the feature ships on in both builds; the App Store build, which cannot
///   be switched, runs it unconditionally, and "absent = off" would make the
///   Developer ID build the odd one out for no reason;
/// - every manifest published before 1.57 lacks the key, so "absent = off"
///   would leave the feature off for every direct-download user until each
///   release script learnt to write it;
/// - the most a forged manifest can do with it is hide a row. Compare
///   `remote_control_enabled`, whose absence means off because that feature
///   acts on the Mac and ships dark (`RemoteControlFeature`).
///
/// **A `false` sticks.** It is kept until a manifest that passed the updater's
/// checks no longer says false, and never decays with age: off is the safe
/// direction here, so a Mac that cannot reach the manifest keeps the last
/// answer that said stop. Only a real boolean `true` is stored as "disabled",
/// so a stray value in the defaults cannot switch it off or on by accident.
public enum CodexResetCreditsFeature {
    /// `true` (a real CFBoolean) while the manifest says stop. Never written by
    /// anything but `recordRemoteSwitch`.
    static let remoteDisabledKey = "cli_pulse_codex_reset_credits_remote_disabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard let number = defaults.object(forKey: remoteDisabledKey) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return true }
        return !number.boolValue
    }

    /// Record what a verified manifest said: `false` switches the read off;
    /// `true`, or no key at all, switches it back on.
    public static func recordRemoteSwitch(_ enabled: Bool?, in defaults: UserDefaults = .standard) {
        if enabled == false {
            defaults.set(true, forKey: remoteDisabledKey)
        } else {
            defaults.removeObject(forKey: remoteDisabledKey)
        }
    }
}

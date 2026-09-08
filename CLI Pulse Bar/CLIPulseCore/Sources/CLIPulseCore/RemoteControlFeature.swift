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

    /// What a fresh install gets — and it is deliberately ASYMMETRIC.
    ///
    /// **macOS: false.** A release must not expose remote control until that
    /// is a decision someone made. This is the half with the security weight:
    /// it is the Mac that opens a listener and advertises on Bonjour, and the
    /// half the manifest allowance can turn back on or off without a release.
    ///
    /// **iOS: true.** The phone is a client. It opens nothing, listens on
    /// nothing, and can do nothing at all unless some Mac is already
    /// advertising — which only happens when that Mac's owner has both been
    /// allowed AND flipped their own switch. Keeping it false there does not
    /// protect anything; it only makes the feature unusable end to end,
    /// because iOS has no `defaults write` escape hatch, no manifest fetch and
    /// no telemetry channel, so there is NO way to turn the phone half on.
    /// The adversarial review of the rollout design called this out as a
    /// blocker: remoting only the Mac would open a listener that no phone
    /// could ever reach, and the §8 latches would stay at zero for a second,
    /// equally meaningless round.
    ///
    /// The cost is honest and bounded: an iPhone whose Mac is not enabled sees
    /// the Nearby Macs row and, inside it, `remote.no_macs` — "No Macs found
    /// on this Wi-Fi. On the Mac, turn on Settings › Remote Control." — in all
    /// six languages. Browsing starts on that screen's `.onAppear`
    /// (LANRemoteScreens.swift:112), so merely shipping this does NOT raise
    /// the local-network permission prompt for anyone who does not go looking.
    ///
    /// `RemoteControlKillSwitchTests` pins BOTH values as a source guard,
    /// because `swift test` compiles macOS only and would never see an
    /// accidental change to the iOS arm.
    #if os(iOS)
    public static let shippedDefault = true
    #else
    public static let shippedDefault = false
    #endif

    // MARK: - Remote allowance (the kill switch)

    /// What the update manifest last said, and when it said it. Written only
    /// by `recordRemoteAllowance`; read only by `isAvailable`.
    static let remoteAllowanceKey = "cli_pulse_remote_control_remote_allowance"
    static let remoteAllowanceStampKey = "cli_pulse_remote_control_remote_allowance_at"

    /// How long a cached allowance is honoured without being re-confirmed.
    ///
    /// A kill switch a permanently offline machine can ignore forever is not a
    /// kill switch. Past this the cached value decays to `shippedDefault` —
    /// which is the safe direction, since `shippedDefault` is false.
    static let allowanceCeiling: TimeInterval = 7 * 24 * 60 * 60

    /// Resolution order, and the reason for it:
    ///
    ///   localOverride  ??  remoteAllowance (fresh)  ??  shippedDefault
    ///
    /// The local override stays FIRST and unchanged. It is how the owner turns
    /// this on with no network, and how anyone debugging forces either answer.
    /// A rollout that could override it would be a rollout that can lock the
    /// owner out of their own machine.
    ///
    /// Only a real boolean counts, for the cache as much as for the override:
    /// `UserDefaults.bool(forKey:)` reads "1", "YES" and 1 as true, so a stray
    /// string could otherwise ship the feature by accident.
    ///
    /// ⚠️ What this gate does NOT do. It decides whether the feature is
    /// OFFERED, never whether it runs. `AppState` starts the agent only on
    /// `isAvailable() && lanAgent.isEnabled`, and that second switch is the
    /// user's own, persisted, default-OFF. That layering is what makes an
    /// UNSIGNED transport acceptable here: the worst a manifest attacker can
    /// do is make a Settings row appear. Do not reuse this mechanism for
    /// anything that is sufficient on its own.
    public static func isAvailable(in defaults: UserDefaults = .standard,
                                   now: Date = Date()) -> Bool {
        if let override = strictBool(defaults.object(forKey: overrideDefaultsKey)) {
            return override
        }
        if let allowed = strictBool(defaults.object(forKey: remoteAllowanceKey)),
           let stamped = defaults.object(forKey: remoteAllowanceStampKey) as? Date,
           isFresh(stamped, now: now) {
            return allowed
        }
        return shippedDefault
    }

    /// A cached allowance is honoured only inside the ceiling AND only if it
    /// was not stamped in the future. Both directions matter: a clock pushed
    /// forward would expire a good allowance (harmless, fail-closed), and a
    /// clock pushed backward would make a stale one look fresh forever — which
    /// is the direction that defeats the kill switch, so it is refused.
    private static func isFresh(_ stamped: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(stamped)
        return age >= 0 && age <= allowanceCeiling
    }

    private static func strictBool(_ raw: Any?) -> Bool? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// Record what the update manifest said.
    ///
    /// `allowed == nil` means the manifest carried no opinion, and that CLEARS
    /// the cache rather than leaving the last answer standing. Removing the
    /// field is therefore an effective off-switch, and a manifest that loses
    /// the field for any reason — a regenerated file, a rolled-back release —
    /// fails closed instead of silently keeping a feature enabled. The cost is
    /// that the field must be present on every manifest that wants the feature
    /// on; that is the correct direction to be wrong in.
    ///
    /// Called only after the manifest has passed the updater's own validation,
    /// so a manifest being rejected for any other reason also lets the
    /// allowance go stale and decay.
    public static func recordRemoteAllowance(_ allowed: Bool?,
                                             at stamped: Date = Date(),
                                             in defaults: UserDefaults = .standard) {
        guard let allowed else {
            defaults.removeObject(forKey: remoteAllowanceKey)
            defaults.removeObject(forKey: remoteAllowanceStampKey)
            return
        }
        // `set(_: Bool, forKey:)` stores a real CFBoolean, which is what
        // `strictBool` above requires. Storing an Int here would silently
        // disable the mechanism.
        defaults.set(allowed, forKey: remoteAllowanceKey)
        defaults.set(stamped, forKey: remoteAllowanceStampKey)
    }
}

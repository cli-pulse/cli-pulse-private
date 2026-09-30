import Foundation

/// Settings › Privacy's two Claude keychain switches, as the app copies them
/// for the processes that are not the app.
///
/// "Strict privacy mode" says CLI Pulse won't read Claude Code's keychain item
/// on its own, and "Skip Claude Code keychain access" says it stops reading
/// it. Both are saved in the app's `UserDefaults.standard` (`PrivacySettings`),
/// which no other process can read. Until 1.55 that made both switches a no-op
/// in the two other processes that read the item on a timer:
///
/// - the LoginItem helper (`CLIPulseHelper`), which runs the same collectors as
///   the app, so its `PrivacySettings.shared` read its own, never-written
///   defaults and always said "read";
/// - the Companion CLI (`helper/`), which never looked at them.
///
/// So the app copies both into the app group (`HelperIPC.suiteName`), where
/// both helpers already read what the app tells them: the same place and the
/// same rule as the local-scan answer's copy (`LocalScanConsentStore.mirror`,
/// PR #626). Every write writes both keys, so a missing key means the app has
/// not written a copy, never "off".
///
/// What a missing copy means differs on purpose:
/// - The LoginItem helper ships inside the app, whose launch writes the copy,
///   so a missing copy is only the moment before that launch. It skips the
///   item until the app says (`ClaudeKeychainAccess.skippedAwaitingApp`).
/// - The Companion CLI can be paired with an app older than 1.55, which never
///   writes one, so it reads as it did before (`helper/privacy_switches.py`).
public struct HelperPrivacyInputs: Equatable, Sendable {
    /// `PrivacySettings.skipClaudeKeychain`, as stored (Strict privacy mode
    /// already forces it on in the app).
    public var skipClaudeKeychain: Bool
    /// `PrivacySettings.localOnlyMode`: Strict privacy mode.
    public var localOnlyMode: Bool

    public init(skipClaudeKeychain: Bool, localOnlyMode: Bool) {
        self.skipClaudeKeychain = skipClaudeKeychain
        self.localOnlyMode = localOnlyMode
    }

    /// App-group keys (Bool). `helper/privacy_switches.py` spells them too.
    public static let skipClaudeKeychainKey = "cli_pulse_privacy_skip_claude_keychain"
    public static let localOnlyModeKey = "cli_pulse_privacy_local_only_mode"

    /// Writes both switches to the app group.
    /// - Returns: whether that changed what a helper would read, so the app
    ///   tells the helpers only about a change, not on every launch.
    @discardableResult
    public static func mirror(_ inputs: HelperPrivacyInputs, to defaults: UserDefaults) -> Bool {
        let changed = load(defaults) != inputs
        defaults.set(inputs.skipClaudeKeychain, forKey: skipClaudeKeychainKey)
        defaults.set(inputs.localOnlyMode, forKey: localOnlyModeKey)
        return changed
    }

    /// The switches as the app last copied them, or nil when it has not.
    /// Nil too when only one key is there: the app always writes both, so half
    /// a copy is not one this build wrote.
    public static func load(_ defaults: UserDefaults) -> HelperPrivacyInputs? {
        guard let skip = defaults.object(forKey: skipClaudeKeychainKey) as? Bool,
              let localOnly = defaults.object(forKey: localOnlyModeKey) as? Bool
        else { return nil }
        return HelperPrivacyInputs(skipClaudeKeychain: skip, localOnlyMode: localOnly)
    }
}

/// What a process does with Claude Code's keychain item
/// ("Claude Code-credentials") when nobody has just asked it to read it.
///
/// The raw values are tokens: the LoginItem helper writes one to the app group
/// (`HelperPrivacyInputs.reportKey`) and the app words it in its own language.
public enum ClaudeKeychainAccess: String, Equatable, Sendable, CaseIterable {
    /// Neither switch is on: reads it as it always has.
    case read
    /// Strict privacy mode is on.
    case skippedStrictPrivacyMode = "skipped_strict_privacy_mode"
    /// "Skip Claude Code keychain access" is on.
    case skippedBySetting = "skipped_setting"
    /// A helper that has no copy of the switches yet (see `HelperPrivacyInputs`).
    case skippedAwaitingApp = "skipped_awaiting_app"

    public var skips: Bool { self != .read }

    /// The decision for a set of switches. Strict privacy mode is named first
    /// because it is the one that also forces the other on.
    public static func decide(_ inputs: HelperPrivacyInputs?) -> ClaudeKeychainAccess {
        guard let inputs else { return .skippedAwaitingApp }
        if inputs.localOnlyMode { return .skippedStrictPrivacyMode }
        if inputs.skipClaudeKeychain { return .skippedBySetting }
        return .read
    }
}

extension HelperPrivacyInputs {
    /// Where the LoginItem helper records what it does with Claude Code's
    /// keychain item (`ClaudeKeychainAccess.rawValue`): when it starts, every
    /// cycle it collects, and whenever the app changes a switch or asks
    /// (`reportRequestNotificationName`). Written by the helper, read by the
    /// app for Settings › Privacy.
    ///
    /// The app removes it at every launch (`clearHelperReport`) and then asks
    /// the running helper for a new one, so what Settings reads was written by
    /// a helper running since this launch of the app. Without that, a report
    /// left by an earlier 1.55 helper (before a downgrade and an in-place
    /// upgrade, say) would read as a confirmation while the helper actually
    /// running is one from before 1.55, which never reads the switches and
    /// never answers.
    public static let reportKey = "cli_pulse_helper_claude_keychain"

    /// Posted by the app at launch, after `clearHelperReport`, asking a running
    /// helper to report now rather than at its next collecting cycle.
    public static let reportRequestNotificationName =
        Notification.Name("CLIPulseHelperClaudeKeychainReportRequested")

    /// Posted by the helper after it reported on request or on a switch change,
    /// so Settings › Privacy reads the report again at once. Not posted by the
    /// per-cycle report, which the cycle's `HelperIPC.didSyncNotificationName`
    /// already covers.
    public static let didReportNotificationName =
        Notification.Name("CLIPulseHelperDidReportClaudeKeychain")

    /// Removes the helper's last report (see `reportKey`).
    public static func clearHelperReport(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: reportKey)
    }

    /// - Returns: whether it changed, so the helper logs a change once.
    @discardableResult
    public static func recordHelperReport(_ access: ClaudeKeychainAccess, to defaults: UserDefaults) -> Bool {
        let changed = defaults.string(forKey: reportKey) != access.rawValue
        defaults.set(access.rawValue, forKey: reportKey)
        return changed
    }

    /// The helper's last report, or nil when it has not made one (a helper
    /// older than this key, or one that has not collected since). A token this
    /// build does not know is nil too: it cannot be shown as a confirmation.
    public static func loadHelperReport(_ defaults: UserDefaults) -> ClaudeKeychainAccess? {
        defaults.string(forKey: reportKey).flatMap(ClaudeKeychainAccess.init(rawValue:))
    }
}

/// What Settings › Privacy says about the LoginItem helper under the Claude
/// keychain switches. The helper is a separate process: until it has said it
/// skips the item, the app does not say it does.
public enum HelperClaudeKeychainConfirmation: Equatable, Sendable {
    /// The helper has said, since this launch of the app, that it skips the
    /// item for one of the switches.
    case confirmed
    /// A switch is on and the helper runs, but it has not said so since this
    /// launch of the app: it has not answered yet, or it is a helper from
    /// before 1.55 that macOS has not restarted since the app was updated,
    /// which never answers.
    case notConfirmed

    /// Nil when there is nothing to say: both switches off, or no helper running.
    public static func make(
        appSkips: Bool,
        helperStatus: HelperIPC.Status?,
        helperReport: ClaudeKeychainAccess?
    ) -> HelperClaudeKeychainConfirmation? {
        guard appSkips, let helperStatus, helperStatus.state != .idle else { return nil }
        switch helperReport {
        case .skippedStrictPrivacyMode?, .skippedBySetting?:
            return .confirmed
        case .read?, .skippedAwaitingApp?, nil:
            return .notConfirmed
        }
    }
}

/// The notification that tells the helpers something they read in the app
/// group changed, so they act on it now rather than at their next cycle. A
/// hint, like the others: the helpers read the values themselves.
///
/// The app posts it when any of its copies for the helpers changes:
/// - Settings › Privacy's switches (`HelperPrivacyInputs.mirror`). The
///   LoginItem helper's delegate answers by recording what it now does with
///   Claude Code's keychain item (`HelperPrivacyInputs.reportKey`) and posting
///   `HelperPrivacyInputs.didReportNotificationName`, so Settings › Privacy
///   says so at once. No cycle is needed for that: the collectors read the
///   copy at every decision.
/// - the local-scan answers (`LocalScanConsentStore.mirror`) or the account
///   (`HelperIPC.appAccountKey`). The helper's daemon asks the cycle question
///   again at once, so a "Not now" or a sign-out pauses it, and a yes or a
///   sign-in resumes it, without waiting for its timer; it starts a cycle
///   only when that changes whether it reads at all.
///
/// One constant for all of them (#626 and #630 each defined one while neither
/// had merged). A helper keeps running across an app update, so the string is
/// a protocol: `HelperPrivacyInputsTests` pins it and fails if a second
/// definition of it appears.
public enum HelperInputs {
    public static let didChangeNotificationName =
        Notification.Name("CLIPulseHelperInputsDidChange")

    #if os(macOS)
    public static func postDidChange() {
        post(didChangeNotificationName)
    }

    /// `HelperPrivacyInputs.reportRequestNotificationName`, from the app.
    public static func postReportRequest() {
        post(HelperPrivacyInputs.reportRequestNotificationName)
    }

    /// `HelperPrivacyInputs.didReportNotificationName`, from the helper.
    public static func postDidReport() {
        post(HelperPrivacyInputs.didReportNotificationName)
    }

    private static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil,
            deliverImmediately: true
        )
    }
    #endif
}

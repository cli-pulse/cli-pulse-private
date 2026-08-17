// macOS-only: this reasons about `UnsandboxedDataMigration` (itself
// `#if os(macOS)`) and about a menu-bar app's first launch. Leaving it
// unguarded compiled fine on macOS and broke the iOS and watchOS targets,
// which the SwiftPM macOS test run never exercises.
#if os(macOS)
import Foundation

/// Decides whether this launch is the one that must SHOW the app to its new
/// owner, rather than merely start it.
///
/// WHY THIS EXISTS
/// ---------------
/// CLI Pulse is `LSUIElement` with a `MenuBarExtra` and nothing else. On a
/// genuinely first launch the entire visible result is a small icon appearing
/// in a crowded menu bar. If the user does not notice it, the app looks like it
/// did nothing — and the two numbers we have are both consistent with exactly
/// that:
///
///   * App Store Connect's install/deletion report puts the MEDIAN time from
///     download to deletion at 0 days, with 74 % deleted inside one day.
///   * `anonymous_installs` only ever hears from someone who opened the popover
///     and acknowledged the disclosure card, and it has heard from 10–26 % of
///     known installs.
///
/// One mechanism explains both, and it is not a funnel leak further down: the
/// app never made itself visible, so the user never had the chance to keep it.
/// Every prior plan proposed *measuring* that step harder. The instrument sits
/// BEHIND the hurdle, so it is structurally blind to the people the hurdle
/// removes — measuring it again could not have worked.
///
/// So this ships the removal instead of another measurement, and the existing
/// install-report rate becomes the test: if a first-run window gets more people
/// to the menu, more installs report. No new telemetry, no new field, nothing
/// extra leaving the machine.
///
/// NEW INSTALL vs UPGRADE — the part that is easy to get wrong
/// ----------------------------------------------------------
/// An absent "already shown" flag does NOT mean a new install. Everyone
/// upgrading from 1.47 also lacks it, and showing them a "here is where the app
/// lives" window would be both wrong and noisy — and it would contaminate the
/// measurement above, since an upgrader nudged into the menu reports an install
/// too (anyone below 1.45 has never reported one).
///
/// A field added now cannot identify installs that predate it; that is the
/// lesson of the v1.44 device-identification work, which had to fall back to an
/// app-version sentinel for the same reason. So this uses two independent
/// signals, and requires BOTH to say "new":
///
///   1. `lastSeenAppVersionKey` absent — no 1.49+ launch has happened here.
///   2. No app-owned preference exists at all — nothing from ANY earlier
///      version, which covers the installs the sentinel itself cannot see.
///
/// ORDERING IS LOAD-BEARING
/// ------------------------
/// Signal 2 only works if it is read before the app writes its own defaults,
/// and the app writes some almost immediately:
/// `UserDefaultsAnonymousTelemetryStore.init` sets
/// `privacy.anonymousTelemetryEnabled`, and `AppState.init` reads and writes
/// provider state. `decide` must therefore be called at the TOP of
/// `CLIPulseBarApp.init`, before `AppState` and before the telemetry
/// coordinator. `FirstRunPresentationOrderingTests` pins that.
///
/// `UnsandboxedDataMigration` is the one deliberate exception, and it runs
/// earlier by design. It writes `migrationDoneKey` even when there was nothing
/// to migrate, so a genuinely fresh Developer ID install carries that key at
/// this point through no fault of its own — hence `ignoredKeys`. Its OTHER
/// effect is correct and wanted: a user moving from the Mac App Store build to
/// the Developer ID one arrives with their real preferences copied in, is not a
/// new user, and must not see this window.
public enum FirstRunPresentation {
    /// Both keys carry an app-owned prefix on purpose.
    /// `UnsandboxedDataMigration.appOwnedKeyPrefixes` is a strict allowlist and
    /// anything outside it is DROPPED when a user moves from the sandboxed Mac
    /// App Store build to the Developer ID one. A dropped "already shown" flag
    /// would re-show the welcome window to an established user after what looks
    /// to them like an ordinary update.
    /// `FirstRunPresentationTests` pins the prefixes.
    public static let shownKey = "cli_pulse_first_run_welcome_shown"

    /// The app-version sentinel. Written on EVERY launch from 1.49 onward, so
    /// future work has a real "is this an upgrade, and from what" signal
    /// instead of having to invent one again.
    public static let lastSeenAppVersionKey = "cli_pulse_last_seen_app_version"

    /// Keys whose presence does NOT prove prior use.
    ///
    /// `migrationDoneKey` is written unconditionally by
    /// `UnsandboxedDataMigration.runIfNeeded()` — including on the
    /// nothing-to-migrate path — and that runs before this decision. Treating
    /// it as evidence of prior use would suppress the welcome window on every
    /// fresh Developer ID and Homebrew install, i.e. on two of the three
    /// channels, silently.
    public static let ignoredKeys: Set<String> = [
        UnsandboxedDataMigration.migrationDoneKey
    ]

    /// True when this launch should present the first-run window.
    ///
    /// Pure and total: no side effects, so a caller can ask twice and a test can
    /// enumerate the cases. `recordLaunch` does the writing.
    public static func shouldPresent(
        existingKeys: some Sequence<String>,
        alreadyShown: Bool,
        hasSentinel: Bool
    ) -> Bool {
        if alreadyShown { return false }
        // A sentinel means 1.49+ has run here before, so this is not the first
        // launch even if the window was dismissed without being marked (a crash
        // between presenting and recording, say). Erring toward NOT showing is
        // the right direction: a missed window costs one user one nudge, a
        // repeated window looks broken to everyone.
        if hasSentinel { return false }
        return !hasPriorUse(existingKeys: existingKeys)
    }

    /// Whether any preference from any earlier version of this app exists.
    static func hasPriorUse(existingKeys: some Sequence<String>) -> Bool {
        for key in existingKeys where !ignoredKeys.contains(key) {
            for prefix in UnsandboxedDataMigration.appOwnedKeyPrefixes
            where key.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    /// Reads the decision from a real defaults store, then records this launch.
    ///
    /// Returns the decision. The sentinel is written whether or not the window
    /// is shown, because its job is to describe launches, not presentations.
    @discardableResult
    public static func evaluateAndRecordLaunch(
        defaults: UserDefaults = .standard,
        appVersion: String
    ) -> Bool {
        let decision = shouldPresent(
            existingKeys: defaults.dictionaryRepresentation().keys,
            alreadyShown: defaults.bool(forKey: shownKey),
            hasSentinel: defaults.string(forKey: lastSeenAppVersionKey) != nil
        )
        defaults.set(appVersion, forKey: lastSeenAppVersionKey)
        return decision
    }

    /// Called once the window has actually been presented, so it never returns.
    public static func markShown(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: shownKey)
    }
}
#endif

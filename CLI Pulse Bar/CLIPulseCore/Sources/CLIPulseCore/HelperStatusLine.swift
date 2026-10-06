import Foundation

/// The line under Settings › Advanced › Background Sync: a dot and a few words
/// from the helper's last status (`HelperIPC.readStatus()`).
///
/// In CLIPulseCore so it is tested; the app target has no unit tests.
///
/// The helper cannot tell whether it syncs the signed-in account. With no
/// pairing it only collects locally, and a helper paired to another account
/// syncs that one; both write `.running` with a `lastSync`. On a Mac that
/// `ThisMacPairing` found not set up, that read "Synced just now" in green right
/// below "This Mac isn't paired with your account yet". Helpers already
/// installed keep writing it, so the app is where it has to be decided.
public struct HelperStatusLine: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Running (green).
        case good
        /// Running, but not syncing this account (orange).
        case attention
        /// The last sync failed (red).
        case failure
        /// Stopped, or nothing to report (gray).
        case inactive
    }

    /// The dot.
    public let tone: Tone
    public let text: String
    /// Whether `text` describes a failure (drawn in red).
    public let isError: Bool

    public init(tone: Tone, text: String, isError: Bool) {
        self.tone = tone
        self.text = text
        self.isError = isError
    }

    /// v1.56 — the line Settings › Advanced draws under "Enable background
    /// sync", or nil for none. What Settings calls; `make` words a status.
    ///
    /// - **Nothing while background sync is off.** Turning it off unregisters
    ///   the helper, and its last status stays in the app group: a Mac whose
    ///   background sync had been off for weeks would read a green "Synced
    ///   36000m ago" under a switch that reads Off. With the helper gone the
    ///   status describes nothing that runs, and the switch already says Off.
    /// - **"Not Synced" (`settings.not_paired`) on a Mac signed in to an account that is not paired**,
    ///   first, as on a paired account this Mac is not part of
    ///   (`ThisMacPairing.State.notSetUp`): nothing this helper does syncs to
    ///   this account, whatever it last wrote. `ThisMacPairing` leaves this
    ///   case out because Settings already shows the pairing flow there; the
    ///   line sits under the background sync switch, below that flow, and
    ///   until 1.56 that Mac had no Advanced to draw it in.
    ///
    /// - Parameters:
    ///   - backgroundSyncOn: the switch (`HelperLogin.isEnabled`).
    ///   - isPaired: the account's flag (`AuthState.isPaired`).
    ///   - appAccount: the account as the helper is told it
    ///     (`AppState.accountRecordForHelper`).
    public static func forSettings(
        status: HelperIPC.Status?,
        backgroundSyncOn: Bool,
        isPaired: Bool,
        thisMacPairing: ThisMacPairing.State,
        pairedDeviceId: String?,
        appAccount: HelperAccountRecord,
        helperShouldBePaused: Bool,
        appBuild: String?,
        now: Date = Date()
    ) -> HelperStatusLine? {
        guard backgroundSyncOn, let status else { return nil }
        var pairing = thisMacPairing
        if case .signedIn = appAccount, !isPaired {
            pairing = .notSetUp
        }
        return make(
            status: status,
            thisMacPairing: pairing,
            pairedDeviceId: pairedDeviceId,
            helperShouldBePaused: helperShouldBePaused,
            appBuild: appBuild,
            appAccount: appAccount,
            now: now
        )
    }

    /// - Parameters:
    ///   - pairedDeviceId: the device this Mac is paired as for the signed-in
    ///     account (`HelperConfig.pairedDeviceId`), or nil.
    ///   - helperShouldBePaused: whether, given the app's answer and account,
    ///     the helper should be reading nothing (`AppState.helperShouldBePaused`).
    ///   - appBuild: this app's `CFBundleVersion` (`HelperIPC.runningBuild`).
    ///   - appAccount: the account as the helper is told it
    ///     (`AppState.accountRecordForHelper`), or nil when not known, which
    ///     takes every pause code at its word.
    public static func make(
        status: HelperIPC.Status,
        thisMacPairing: ThisMacPairing.State,
        pairedDeviceId: String?,
        helperShouldBePaused: Bool = false,
        appBuild: String? = nil,
        appAccount: HelperAccountRecord? = nil,
        now: Date = Date()
    ) -> HelperStatusLine {
        if thisMacPairing == .notSetUp {
            // The words the account card's badge uses for the same fact.
            return HelperStatusLine(tone: .attention, text: L10n.settings.notPaired, isError: false)
        }
        if ThisMacPairing.isAboutAReplacedDevice(status, pairedDeviceId: pairedDeviceId) {
            // Written for the pairing this Mac has just replaced: a sync, or
            // "no longer paired" in red while the account card, which ignores
            // it (`ThisMacPairing`), says "Synced". Until the helper writes one
            // for the current pairing, only whether it runs is known.
            return status.state == .idle
                ? HelperStatusLine(tone: .inactive, text: L10n.advanced.helperNotRunning, isError: false)
                : HelperStatusLine(tone: .good, text: L10n.advanced.helperRunning, isError: false)
        }
        if helperShouldBePaused, status.state != .idle,
           let appBuild, status.helperBuild != appBuild {
            // The helper should be reading nothing, and the one running was
            // built before this app: macOS does not restart a LoginItem when
            // its app updates in place, and a helper from before 1.55 honours
            // no answer at all. The app restarts it once per update
            // (`HelperLoginItemRestart`); this is what is left if that failed.
            return HelperStatusLine(tone: .attention, text: L10n.advanced.helperRestartNeeded, isError: false)
        }
        // A helper that runs and does nothing, because the answer or a
        // sign-out does not allow it. "Running" in green, under a hint that
        // says it syncs, would read as syncing.
        if status.pauseCode == HelperIPC.PauseCode.localScanOff {
            return HelperStatusLine(tone: .inactive, text: L10n.advanced.helperPausedLocalScanOff, isError: false)
        }
        // "Paused: signed out" only while the app is signed out. The helper
        // writes it then, and it stays until the helper's next cycle; after
        // signing back in, or switching to local mode, it is about a state
        // the app has left. The helper is running (it wrote the code), so it
        // reads as running until it reports again.
        if status.pauseCode == HelperIPC.PauseCode.signedOut,
           appAccount == nil || appAccount == .signedOut {
            return HelperStatusLine(tone: .inactive, text: L10n.advanced.helperPausedSignedOut, isError: false)
        }
        let tone: Tone
        switch status.state {
        case .running: tone = .good
        case .error: tone = .failure
        case .idle: tone = .inactive
        }
        if let lastSync = status.lastSync {
            let ago = Int(now.timeIntervalSince(lastSync))
            return HelperStatusLine(
                tone: tone,
                text: ago < 60 ? L10n.advanced.syncJustNow : L10n.advanced.syncMinutesAgo(ago / 60),
                isError: false
            )
        }
        if let error = HelperSyncFailure.displayText(code: status.errorCode, storedText: status.error) {
            return HelperStatusLine(tone: tone, text: error, isError: true)
        }
        return HelperStatusLine(
            tone: tone,
            text: status.state == .running ? L10n.advanced.helperRunning : L10n.advanced.helperNotRunning,
            isError: false
        )
    }
}

import Foundation

/// v1.56 — the lines in Settings › Advanced that say what leaves this Mac,
/// worded for the account the app is in.
///
/// 1.56 draws Advanced in local mode for the first time
/// (`SettingsAccountSections.Advanced.thisMac`). Three of its lines were
/// written for an account and are false there:
///
/// - the hint under "Enable background sync", "Syncs usage data to the cloud
///   for iPhone, Apple Watch, and Android", above a green "Running";
/// - Where Your Data Goes › Usage metrics, "Synced to your CLI Pulse account
///   for iPhone and Apple Watch", with an upload icon;
/// - Where Your Data Goes › Your login email, "Sent to our sign-in service".
///
/// Local mode has no account and no sign-in. Its helper uploads nothing
/// (`HelperAccountRecord.localMode`), and the app uploads only with an
/// authorization lease, which local mode never has. The welcome screen
/// promises "no account, nothing uploaded" (`welcome_choice.local_mode_body`).
///
/// Every other account keeps the account's wording, which is true there.
/// Signed in to an account that is not paired, the app syncs daily usage
/// itself. Signed out, the hint sits above "Paused: signed out", and Where
/// Your Data Goes is not drawn. Demo shows an account
/// (`AppState.accountRecordForHelper` is `.signedOut` there).
///
/// The rows this leaves alone are true in local mode: API keys and session
/// logs stay on this Mac, and running sessions are synced only "while you are
/// signed in and background sync is on".
public struct AdvancedUploadCopy: Equatable, Sendable {
    /// Under "Enable background sync".
    public let backgroundSyncHint: String
    /// Whether usage metrics leave this Mac, which picks the Usage metrics
    /// row's icon: an upload in blue, or this Mac's drive in green, the
    /// colours the other rows use for the same two facts.
    public let usageMetricsLeaveThisMac: Bool
    /// The Usage metrics row's detail.
    public let usageMetricsDetail: String
    /// Whether "Your login email" is listed. Without a sign-in there is none.
    public let showsLoginEmail: Bool

    /// - Parameter appAccount: the account as the helper is told it
    ///   (`AppState.accountRecordForHelper`), the same value the status line
    ///   below the switch is worded for.
    public init(appAccount: HelperAccountRecord) {
        let localMode = appAccount == .localMode
        backgroundSyncHint = localMode
            ? L10n.advanced.backgroundSyncHintLocalMode
            : L10n.advanced.backgroundSyncHint
        usageMetricsLeaveThisMac = !localMode
        // An existing string, already true here in every language: "Your
        // usage stays on this Mac unless you sign in later."
        usageMetricsDetail = localMode
            ? L10n.onboardingWizard.finishLocalBody
            : L10n.advanced.privacyMetricsDetail
        showsLoginEmail = !localMode
    }
}

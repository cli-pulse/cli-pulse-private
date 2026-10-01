import Foundation

/// v1.55 — which of the Mac's Settings sections depend on the account, and
/// whether each is shown.
///
/// Settings › Privacy is where the popover's answers are changed: the
/// older-logs switch ("Include older usage history"), and "Choose again…"
/// after "Not now". Each Mac that scans can be asked those questions: local
/// mode, and every signed-in Mac, whether or not its account is paired. A
/// signed-in Mac that is not paired scans on the local route
/// (`RefreshRouter.decide`), and `LocalCollectionPolicy.shouldPresentV2Disclosure`
/// and `offersChoosingAgain` do not check pairing. Until this type, Settings
/// rendered Privacy only in local mode and for a paired account. On a
/// signed-in Mac that had not set up cloud sync, the older-logs question,
/// the first ask's signed-in caption (`local_scan_consent.first_ask_hint_signed_in`)
/// and the telemetry card all pointed to a section that was not there.
///
/// Settings › Companion CLI goes wherever Privacy goes, where the runtime
/// offers it: the note under the answer and under the Claude keychain switches
/// (`CompanionNotCoveredNote`) sends people there to update or uninstall a
/// Companion that ignores them.
///
/// The rest needs a paired account and stays with it: the subscription, the
/// Developer ID updater, Remote Control, and the General / Display / Providers
/// / Advanced picker.
///
/// What Privacy shows inside is its own business (`PrivacySettingsSection`):
/// the scan switch only in local mode, since signing in implies the scan,
/// whether or not the account is paired.
public struct SettingsAccountSections: Equatable, Sendable {
    /// Subscription, the Developer ID updater, Remote Control and the section
    /// picker.
    public let pairedAccountSettings: Bool
    /// Settings › Companion CLI.
    public let companionCLI: Bool
    /// Settings › Privacy.
    public let privacy: Bool

    /// - Parameters:
    ///   - isPaired: the account's flag (`AuthState.isPaired`), true while any
    ///     of its devices is paired. Ignored while signed out.
    ///   - runtimeOffersCompanionCLI: `allowsHelperManifestRefresh`, true in
    ///     production for the App Store and Developer ID builds alike.
    public init(
        isAuthenticated: Bool,
        isPaired: Bool,
        isLocalMode: Bool,
        runtimeOffersCompanionCLI: Bool
    ) {
        // Wherever this Mac scans or can be asked to: signed in, paired or
        // not, or in local mode. A signed-out Mac that is not in local mode
        // shows the sign-in form alone; it reads nothing and is asked nothing.
        let scans = isAuthenticated || isLocalMode
        pairedAccountSettings = isAuthenticated && isPaired
        privacy = scans
        companionCLI = scans && runtimeOffersCompanionCLI
    }
}

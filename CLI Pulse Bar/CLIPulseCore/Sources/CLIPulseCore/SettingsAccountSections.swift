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
/// The rest needs a paired account and stays with it: the subscription, Remote
/// Control, and the General / Display / Providers / Advanced picker.
///
/// v1.56: two things no longer wait for a paired account.
///
/// - **The Developer ID updater** (`AppUpdaterSection`, `#if DEVID_BUILD`) is
///   in every state, the sign-in form included. It is the only place that
///   build shows an available update and installs it, and it needs no
///   account: the manifest it reads is public and carries no identifier, and
///   the DMG it installs is verified the same way whoever is signed in. Shown
///   only to a paired account, a signed-out Developer ID Mac was never offered
///   an update in the app, and needed Homebrew or a download by hand. It did
///   fetch the manifest: the popover's focus hook (`MenuBarView`,
///   `AppUpdater.refreshIfStale`) checks at most once a day whatever the
///   account, so showing the result signed out adds no request. Not a flag
///   here: there is nothing to decide.
/// - **Settings › Advanced**, without the picker where the account is not
///   paired, holding what works on this Mac alone (`advanced`). Background
///   sync's status line is there, so "Paused: signed out" can be seen while it
///   is true, which 1.55's notes promised and its Settings could not show.
///
/// What Privacy shows inside is its own business (`PrivacySettingsSection`):
/// the scan switch only in local mode, since signing in implies the scan,
/// whether or not the account is paired.
public struct SettingsAccountSections: Equatable, Sendable {
    /// Subscription, Remote Control and the section picker, whose Advanced is
    /// `Advanced.full`.
    public let pairedAccountSettings: Bool
    /// Settings › Companion CLI.
    public let companionCLI: Bool
    /// Settings › Privacy.
    public let privacy: Bool
    /// Settings › Advanced: what it holds, or nil for no Advanced at all.
    /// `.full` is the picker's; the others are drawn without a picker.
    public let advanced: Advanced?

    /// What Settings › Advanced holds (`AdvancedSection`).
    ///
    /// The line between them is whether a control acts through the account.
    /// Tracking git activity is the account's switch, and only a Companion
    /// paired to it collects; Mac control requests and remote machine control
    /// come from the account's other devices. Those need a paired account.
    /// Everything else acts on this Mac alone.
    public enum Advanced: Equatable, Sendable {
        /// A paired account: every control, under the section picker.
        case full
        /// Signed in to an account that is not paired, or local mode: this
        /// Mac's own settings. Startup, background sync and its status, CLI
        /// Tool Access (the folders the scan reads), Where Your Data Goes,
        /// Hide personal information, Machine controls and Debug.
        case thisMac
        /// Signed out, outside local mode: startup and background sync with
        /// its status. The app reads nothing here, so the folders it would
        /// read are not asked about; a helper still registered from before
        /// the sign-out says "Paused: signed out", and can be turned off.
        case backgroundSync

        /// Launch at login, "Enable background sync" and the helper's status
        /// line, wherever the runtime can register the helper.
        public var showsBackgroundSync: Bool { true }

        /// CLI Tool Access (`FolderAccessView`), where the runtime collects
        /// live: the folders a Mac that scans reads.
        public var showsCLIToolAccess: Bool { self != .backgroundSync }

        /// Where Your Data Goes, Hide personal information, Machine controls
        /// (Developer ID) and Debug.
        public var showsThisMacSettings: Bool { self != .backgroundSync }

        /// Track git activity, Mac control requests, Remote Control
        /// diagnostics and remote machine control.
        public var showsAccountControls: Bool { self == .full }
    }

    /// - Parameters:
    ///   - isPaired: the account's flag (`AuthState.isPaired`), true while any
    ///     of its devices is paired. Ignored while signed out.
    ///   - runtimeOffersCompanionCLI: `allowsHelperManifestRefresh`, true in
    ///     production for the App Store and Developer ID builds alike.
    ///   - runtimeOffersBackgroundSync: `allowsHelperRegistration`, true in
    ///     production for both builds; false in QA, where a signed-out Mac's
    ///     Advanced would be empty.
    public init(
        isAuthenticated: Bool,
        isPaired: Bool,
        isLocalMode: Bool,
        runtimeOffersCompanionCLI: Bool,
        runtimeOffersBackgroundSync: Bool
    ) {
        // Wherever this Mac scans or can be asked to: signed in, paired or
        // not, or in local mode. A signed-out Mac that is not in local mode
        // shows the sign-in form, the updater and background sync; it reads
        // nothing and is asked nothing.
        let scans = isAuthenticated || isLocalMode
        pairedAccountSettings = isAuthenticated && isPaired
        privacy = scans
        companionCLI = scans && runtimeOffersCompanionCLI
        if pairedAccountSettings {
            advanced = .full
        } else if scans {
            advanced = .thisMac
        } else {
            advanced = runtimeOffersBackgroundSync ? .backgroundSync : nil
        }
    }
}

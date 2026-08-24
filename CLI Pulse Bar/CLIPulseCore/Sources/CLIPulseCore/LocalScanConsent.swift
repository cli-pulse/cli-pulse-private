import Foundation

/// v1.50 W-C — whether the user has agreed to CLI Pulse reading this Mac.
///
/// WHY THIS IS SEPARATE FROM `cli_pulse_local_mode_enabled`
/// -------------------------------------------------------
/// That key means "the user chose to run without an account". It is set by the
/// onboarding wizard's close button, which sits on **step 0** — two steps before
/// the card that explains what the app reads. So it records a decision about
/// *accounts*, taken by someone who has not yet been told anything about *data*.
/// Reading it as consent would be reading an answer to a different question, and
/// the plan is explicit that "chose" must stay separable from "defaulted".
///
/// WHY THREE STATES
/// ----------------
/// Because absence is not a decision, and this repository has been bitten by
/// treating it as one. `AuthManager.applySignedOutState()` deletes the local-mode
/// marker on purpose — "signing out is a request for the Sign-In form" — so a
/// missing key there means "signed out", "never chose", and "chose and then
/// signed out" all at once. `FirstRunPresentation.swift:36` writes down the same
/// lesson from the other direction. A two-valued `Bool` here would repeat it:
/// "no" and "not asked yet" have to stay distinguishable, because one of them
/// must never be overridden and the other must produce a prompt.
public enum LocalScanConsent: String, Equatable, Sendable, CaseIterable {
    /// Never asked, or asked and dismissed without answering. Produces the
    /// disclosure sheet; produces no reads.
    case undecided
    /// "Start local scan" — the user read the disclosure and said yes.
    case granted
    /// "Not now" — the user read the disclosure and said no. Sticky, and
    /// deliberately not overridable by any later implicit signal.
    case declined
}

public enum LocalScanConsentStore {
    /// `cli_pulse_` prefix is load-bearing, not cosmetic:
    /// `UnsandboxedDataMigration.appOwnedKeyPrefixes` is a strict allowlist and
    /// anything outside it is DROPPED when a user moves from the Mac App Store
    /// build to the Developer ID one. A dropped consent record would silently
    /// re-open the sheet for someone who already answered — or, worse, drop a
    /// `declined` back to `undecided`.
    public static let key = "cli_pulse_local_scan_consent"

    public static func load(_ defaults: UserDefaults = .standard) -> LocalScanConsent {
        guard let raw = defaults.string(forKey: key) else { return .undecided }
        return LocalScanConsent(rawValue: raw) ?? .undecided
    }

    public static func save(
        _ value: LocalScanConsent,
        to defaults: UserDefaults = .standard
    ) {
        // `.undecided` is the absence of a record, not a value to write. Storing
        // it would make "reset the question" and "answered undecided" the same
        // state on disk.
        if value == .undecided {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value.rawValue, forKey: key)
        }
    }
}

/// The single question `refreshLocal` asks before it reads anything.
///
/// Kept as a free function over plain values so it can be exercised without a
/// Keychain, a bookmark, a refresh loop or an `AppState` — all of which have
/// wedged this repository's test runs before.
public enum LocalCollectionPolicy {

    /// May this refresh read the user's files, run provider collectors, spawn a
    /// CLI, touch the Keychain, or write to `~/.codex/auth.json`?
    ///
    /// `.declined` wins over everything, including a later sign-in. A user who
    /// read the disclosure and said no has said no; letting authentication
    /// quietly re-grant it would make the button a suggestion. Settings is where
    /// they change their mind, visibly.
    ///
    /// `.undecided` defers to authentication, and that is the migration story
    /// for everyone already using the app. Signing in means passing through the
    /// wizard's privacy card (step 2) on the way to the sign-in card (step 3),
    /// and it means opting into cloud sync, which is the same disclosure with a
    /// stronger commitment. So this release shows existing signed-in users
    /// nothing new. Existing *local-mode* users are asked once — they are
    /// precisely the population that reached collection without ever seeing the
    /// disclosure, which is the defect.
    public static func allowsCollection(
        isAuthenticated: Bool,
        consent: LocalScanConsent
    ) -> Bool {
        switch consent {
        case .declined:
            return false
        case .granted:
            return true
        case .undecided:
            return isAuthenticated
        }
    }

    /// Should the popover show the disclosure instead of the dashboard?
    ///
    /// Only for the unauthenticated local-mode user with no answer on file.
    /// Not for `.declined` — they answered, and re-showing a sheet somebody
    /// already dismissed is how a consent prompt becomes a nag that people learn
    /// to click through.
    public static func shouldPresentDisclosure(
        isAuthenticated: Bool,
        isLocalMode: Bool,
        consent: LocalScanConsent
    ) -> Bool {
        guard !isAuthenticated, isLocalMode else { return false }
        return consent == .undecided
    }
}

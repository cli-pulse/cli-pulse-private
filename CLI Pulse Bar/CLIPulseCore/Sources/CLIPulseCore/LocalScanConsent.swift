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
    ///
    /// This key carries no version because until 1.55 there was only one
    /// disclosure. Every answer stored under it was given to v1, which said
    /// "Session logs, last 30 days". See `LocalScanDisclosure`.
    public static let key = "cli_pulse_local_scan_consent"

    /// v1.55 — the answer to disclosure v2: may CLI Pulse read session logs
    /// older than the routine window, to fill in the usage history?
    ///
    /// A key of its own rather than a new value under `key`, so that the v1
    /// answer survives untouched. Refusing v2 must leave a v1 "yes" meaning
    /// what it meant — the 30-day scan keeps running — and a single field
    /// holding "granted-v1" or "declined-v2" could not say both at once.
    public static let v2Key = "cli_pulse_local_scan_consent_v2"

    public static func load(_ defaults: UserDefaults = .standard) -> LocalScanConsent {
        read(key, from: defaults)
    }

    public static func save(
        _ value: LocalScanConsent,
        to defaults: UserDefaults = .standard
    ) {
        write(value, key, to: defaults)
    }

    public static func loadV2(_ defaults: UserDefaults = .standard) -> LocalScanConsent {
        read(v2Key, from: defaults)
    }

    public static func saveV2(
        _ value: LocalScanConsent,
        to defaults: UserDefaults = .standard
    ) {
        write(value, v2Key, to: defaults)
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> LocalScanConsent {
        guard let raw = defaults.string(forKey: key) else { return .undecided }
        return LocalScanConsent(rawValue: raw) ?? .undecided
    }

    private static func write(
        _ value: LocalScanConsent,
        _ key: String,
        to defaults: UserDefaults
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

/// v1.55 — what each version of the disclosure told people, as numbers the
/// code reads.
///
/// v1 (1.50–1.54) said "Session logs, last 30 days". It was incomplete: since
/// v1.40 the first successful scan also ran a one-time backfill over up to a
/// year of logs to build the usage history, so everyone who agreed to "30 days"
/// had a year read once. v2 says both, and the part beyond 30 days waits for its
/// own answer (`LocalScanConsentStore.v2Key`).
///
/// The windows live here, not only in the copy, so that the copy cannot drift
/// from the reads again: `LocalScanConsentCopyTests` pins the scanner's default
/// window and the backfill's window to these numbers, and the catalogue text to
/// the same numbers in every language.
public enum LocalScanDisclosure {
    /// The version the app currently shows.
    public static let currentVersion = 2
    /// How far back an ordinary refresh reads (`CostUsageScanner.Options`).
    public static let routineWindowDays = 30
    /// How far back the one-time history read goes
    /// (`DailyUsageArchiveManager.backfillDays`).
    public static let historyWindowDays = 365
}

/// The buttons on the disclosure, as answers. Kept apart from the view so the
/// state each one leaves behind can be tested without a window.
public enum LocalScanChoice: Equatable, Sendable {
    /// "Start local scan" on the first ask, "Include older history" on the v2
    /// ask: the routine scan and the one-time read of older logs.
    case scanWithHistory
    /// "Last 30 days only": the routine scan, and an explicit no to anything
    /// older.
    case last30DaysOnly
    /// "Not now": nothing at all. Offered only where there is no v1 "yes" to
    /// keep — the first ask.
    case notNow
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
    /// This is the routine window only — the last
    /// `LocalScanDisclosure.routineWindowDays`. Anything older is a second
    /// question: `allowsReadingBeyondRoutineWindow`.
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
    /// stronger commitment. So v1.50 showed existing signed-in users nothing
    /// new. Existing *local-mode* users were asked once — they are precisely the
    /// population that reached collection without ever seeing the disclosure,
    /// which is the defect. (1.55 does show signed-in users the disclosure once,
    /// with the v2 question; their 30-day scan keeps running while it waits.
    /// See `shouldPresentV2Disclosure`.)
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

    // MARK: - v1.55: disclosure v2

    /// May CLI Pulse read session logs older than the routine window — the
    /// one-time backfill that builds the usage history, and any later rebuild
    /// of it?
    ///
    /// Only after an explicit yes to disclosure v2, and never when the routine
    /// scan itself is not allowed. The v2 answer is not a substitute for the v1
    /// one: a `.declined` v1 with a `.granted` v2 still reads nothing, because
    /// "no" to the scan has to mean no to all of it.
    ///
    /// `.undecided` is a no here, including for signed-in users. Signing in was
    /// taken as consent to the 30-day scan the old disclosure described; it was
    /// never consent to a year, since nothing on screen ever said a year.
    public static func allowsReadingBeyondRoutineWindow(
        isAuthenticated: Bool,
        consent: LocalScanConsent,
        consentV2: LocalScanConsent
    ) -> Bool {
        guard allowsCollection(isAuthenticated: isAuthenticated, consent: consent) else {
            return false
        }
        return consentV2 == .granted
    }

    /// Should the popover ask the v2 question — the full disclosure, with the
    /// choice between "Include older history" and "Last 30 days only"?
    ///
    /// Asked once, of the two groups whose routine scan is already running
    /// without a v2 answer:
    ///   * people who said yes to v1, whose "30 days" was incomplete;
    ///   * signed-in users with no answer at all, who were let through on the
    ///     strength of the account and have never seen what the scan reads
    ///     (file paths, project folders, session IDs).
    ///
    /// Not asked of someone who declined — they read the disclosure and said
    /// no, and a second sheet is how a prompt becomes a nag. Not asked in Demo
    /// mode, which reads nothing and is what the screenshots are drawn from. Not
    /// asked of a signed-out Mac that is not in local mode, which is not
    /// scanning. And not asked where the first ask applies
    /// (`shouldPresentDisclosure`): that screen already carries the v2 choice.
    public static func shouldPresentV2Disclosure(
        isAuthenticated: Bool,
        isLocalMode: Bool,
        isDemoMode: Bool,
        consent: LocalScanConsent,
        consentV2: LocalScanConsent
    ) -> Bool {
        guard !isDemoMode, consentV2 == .undecided else { return false }
        guard isAuthenticated || isLocalMode else { return false }
        switch consent {
        case .granted:
            return true
        case .undecided:
            return isAuthenticated
        case .declined:
            return false
        }
    }

    /// The two answers a choice leaves on file.
    ///
    /// Both scanning choices record a v1 `.granted`. On the first ask that is
    /// the plain meaning of the button. On the v2 ask it matters for the signed-in
    /// user with nothing on file: they have now read the whole disclosure and
    /// chosen to keep scanning, and recording it means a later sign-out into
    /// local mode does not put the same questions to them a second time.
    ///
    /// "Not now" leaves v2 as it was. Its meaning is "read nothing", and while
    /// v1 is `.declined` the v2 answer is not consulted; if they turn the scan
    /// back on later, the v2 question is asked then, with the disclosure in
    /// front of them.
    public static func answering(
        _ choice: LocalScanChoice,
        consentV2: LocalScanConsent
    ) -> (consent: LocalScanConsent, consentV2: LocalScanConsent) {
        switch choice {
        case .scanWithHistory:
            return (.granted, .granted)
        case .last30DaysOnly:
            return (.granted, .declined)
        case .notNow:
            return (.declined, consentV2)
        }
    }
}

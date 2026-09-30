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

    // MARK: - The copy the LoginItem helper reads

    /// Copies both answers into the app group (`HelperIPC.suiteName`), the
    /// only defaults the LoginItem helper can read. The answers themselves
    /// live in the app's `UserDefaults.standard`; until 1.55 they were saved
    /// only there, and the helper collected on its timer whatever the user
    /// had answered. `AppState` calls this whenever it saves an answer and
    /// once at launch, so answers given before the copy existed reach the
    /// helper too.
    ///
    /// Under the same keys, with one difference: every answer is written,
    /// `.undecided` included. Here a missing key has to mean "the app has not
    /// said", which the helper treats as no (`LocalCollectionPolicy.helperCycle`),
    /// so it cannot also mean "no answer yet", which for a paired Mac is a yes.
    ///
    /// v2 first, so a reader that sees the new v1 answer also sees the v2 one
    /// it was given with. Nothing the helper runs reads beyond the routine
    /// window today, so it decides on v1 alone; v2 is copied so the app group
    /// holds the whole answer rather than half of it.
    ///
    /// - Returns: whether the copy differed from what was there, so the
    ///   helper is told only about a change (and not on every launch).
    @discardableResult
    public static func mirror(
        consent: LocalScanConsent,
        consentV2: LocalScanConsent,
        to helperDefaults: UserDefaults
    ) -> Bool {
        let changed = helperDefaults.string(forKey: v2Key) != consentV2.rawValue
            || helperDefaults.string(forKey: key) != consent.rawValue
        helperDefaults.set(consentV2.rawValue, forKey: v2Key)
        helperDefaults.set(consent.rawValue, forKey: key)
        return changed
    }

    /// The answers as the app last copied them (`mirror`), or nil when it has
    /// not: a helper that starts before the app has run since the update that
    /// added the copy. A value this build does not recognise is also nil, not
    /// `.undecided`, since for a paired Mac `.undecided` would let it collect.
    public static func loadMirror(
        _ helperDefaults: UserDefaults
    ) -> (consent: LocalScanConsent, consentV2: LocalScanConsent)? {
        guard let raw = helperDefaults.string(forKey: key),
              let consent = LocalScanConsent(rawValue: raw)
        else { return nil }
        return (consent, read(v2Key, from: helperDefaults))
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
    /// How far back an ordinary refresh uses (`CostUsageScanner.Options`).
    ///
    /// "Uses", precisely: Codex logs are listed only from the date folders
    /// inside the window, and a Claude log last written before it is not
    /// opened. A Claude log still being written to is parsed from its start,
    /// and its lines older than the window are dropped, not kept. The policy
    /// words it the same way.
    public static let routineWindowDays = 30
    /// How far back the one-time history read goes
    /// (`DailyUsageArchiveManager.backfillDays`).
    public static let historyWindowDays = 365
}

/// Which question the disclosure is asking, i.e. which screen the answer came
/// from. The same button leaves different answers on file depending on it: see
/// `LocalCollectionPolicy.answering(_:to:consent:consentV2:)`.
public enum LocalScanQuestion: Equatable, Sendable {
    /// Nothing on file for the scan itself: may CLI Pulse read this Mac at all,
    /// and how far back. Three answers. Also what "Choose again…" in Settings
    /// reopens for a signed-in Mac whose answer is "Not now".
    case firstAsk
    /// The routine scan is already running (a v1 yes, or a signed-in account)
    /// and only the older logs are asked about. Two answers, both keeping the
    /// 30-day scan.
    case olderLogs
}

extension LocalScanQuestion {
    /// The caption under the screen's answers.
    ///
    /// The first ask's usual caption ends "Whichever you choose, you can change
    /// it any time in Settings › Privacy". Without an account that holds: the
    /// scan switch is there. A signed-in Mac sees the first ask only through
    /// "Choose again…", and while signed in there is no scan switch (the account
    /// stands in for a yes), so after a yes Settings changes only the older-logs
    /// answer and signing out is what stops the scan. It gets a caption that
    /// says so.
    public func caption(isAuthenticated: Bool) -> String {
        switch self {
        case .firstAsk:
            return isAuthenticated
                ? L10n.localScanConsent.firstAskHintSignedIn
                : L10n.localScanConsent.firstAskHint
        case .olderLogs:
            return L10n.localScanConsent.changeLater
        }
    }
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

/// What the disclosure's buttons and "Choose again…" act on, as one value:
/// both answers and the open request from Settings. `AppState` keeps each part
/// as its own published property and applies a change through this, so what an
/// answer leaves behind — including that it ends a "Choose again…" — can be
/// tested without an `AppState`.
public struct LocalScanConsentState: Equatable, Sendable {
    public var consent: LocalScanConsent
    public var consentV2: LocalScanConsent
    /// "Choose again…" was pressed and the reopened first ask has not been
    /// answered yet. Not persisted.
    public var isChoosingAgain: Bool

    public init(
        consent: LocalScanConsent,
        consentV2: LocalScanConsent,
        isChoosingAgain: Bool = false
    ) {
        self.consent = consent
        self.consentV2 = consentV2
        self.isChoosingAgain = isChoosingAgain
    }

    /// Records `choice`, given on the screen that asked `question`. Any answer
    /// ends a "Choose again…": "Not now" leaves the scan off as it was, and
    /// without this the reopened screen would stay up, since nothing else
    /// about the state changes.
    public mutating func answer(_ choice: LocalScanChoice, to question: LocalScanQuestion) {
        let answers = LocalCollectionPolicy.answering(
            choice,
            to: question,
            consent: consent,
            consentV2: consentV2
        )
        consent = answers.consent
        consentV2 = answers.consentV2
        isChoosingAgain = false
    }

    /// "Choose again…". Ignored where Settings does not offer it
    /// (`LocalCollectionPolicy.offersChoosingAgain`), so a stray call cannot
    /// put the question to anyone else.
    public mutating func requestChoosingAgain(isAuthenticated: Bool, isDemoMode: Bool) {
        guard LocalCollectionPolicy.offersChoosingAgain(
            isAuthenticated: isAuthenticated,
            isDemoMode: isDemoMode,
            consent: consent
        ) else { return }
        isChoosingAgain = true
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
    /// Each answer is stored only for the question the screen asked:
    ///
    ///   * The first ask asks both, so its scanning choices record a v1
    ///     `.granted` and the v2 answer that goes with the button. That is the
    ///     plain meaning of the buttons, including when a signed-in Mac reopens
    ///     this screen from Settings after "Not now" — they answered it again.
    ///   * The older-logs ask asks only about the older logs, so only v2 is
    ///     written and the v1 answer stays as it was. For a v1 yes that changes
    ///     nothing. For a signed-in user with nothing on file it means no v1 yes
    ///     is recorded on their behalf: signing in stands in for it while they
    ///     are signed in (`allowsCollection`), and if they later sign out into
    ///     local mode they are asked the first question, as a local-mode user
    ///     with nothing on file always is. (As first written for 1.55, this
    ///     screen recorded a v1 yes too, so that a sign-out did not ask again.)
    ///     The Settings switch for older history already left exactly this
    ///     state, a v2 answer without a v1 one, and every reader handles it:
    ///     the gates go through `allowsCollection`, and a v2 answer alone
    ///     counts as prior use (`AgentSetupStateStore.hasUsedThisAppBefore`).
    ///
    /// Which also means the older-logs screen offers a signed-in user no way to
    /// refuse the 30-day scan itself. That is the 1.50 rule — signing in implies
    /// the scan, and the scan switch is shown only in local mode — not a new
    /// one: while signed in, signing out is what stops it, and the policy says
    /// so.
    ///
    /// "Not now" (first ask only) leaves v2 as it was. Its meaning is "read
    /// nothing", and while v1 is `.declined` the v2 answer is not consulted; if
    /// they turn the scan back on later, the v2 question is asked then, with
    /// the disclosure in front of them.
    public static func answering(
        _ choice: LocalScanChoice,
        to question: LocalScanQuestion,
        consent: LocalScanConsent,
        consentV2: LocalScanConsent
    ) -> (consent: LocalScanConsent, consentV2: LocalScanConsent) {
        switch (question, choice) {
        case (.firstAsk, .scanWithHistory):
            return (.granted, .granted)
        case (.firstAsk, .last30DaysOnly):
            return (.granted, .declined)
        case (.olderLogs, .scanWithHistory):
            return (consent, .granted)
        case (.olderLogs, .last30DaysOnly):
            return (consent, .declined)
        case (_, .notNow):
            // The older-logs screen has no "Not now"; were one ever wired to
            // it, it would mean what it means everywhere: read nothing.
            return (.declined, consentV2)
        }
    }

    // MARK: - v1.55: choosing again after "Not now", while signed in

    /// Does Settings › Privacy offer "Choose again…"?
    ///
    /// For a signed-in Mac whose answer is "Not now". In local mode the scan
    /// switch and the Overview's declined card are the way back; a signed-in
    /// user has neither — the switch is local-mode only, because the account
    /// implies the scan — so until 1.55 their only way back was signing out.
    /// Not in Demo mode, which reads nothing.
    public static func offersChoosingAgain(
        isAuthenticated: Bool,
        isDemoMode: Bool,
        consent: LocalScanConsent
    ) -> Bool {
        isAuthenticated && !isDemoMode && consent == .declined
    }

    /// Should the popover show the first ask again, because the user asked for
    /// it from Settings?
    ///
    /// Only while the request is still the right one to honour: once the
    /// answer is no longer "Not now", or the Mac is signed out (where the
    /// first ask has its own rule, `shouldPresentDisclosure`), a stale request
    /// shows nothing.
    public static func shouldPresentDisclosureAgain(
        requested: Bool,
        isAuthenticated: Bool,
        isDemoMode: Bool,
        consent: LocalScanConsent
    ) -> Bool {
        requested && offersChoosingAgain(
            isAuthenticated: isAuthenticated,
            isDemoMode: isDemoMode,
            consent: consent
        )
    }

    // MARK: - The LoginItem helper

    /// What the helper's cycle may do.
    public enum HelperCycle: Equatable, Sendable {
        /// Scan, run the collectors, and sync if this Mac is paired.
        case collect
        /// The answer does not allow reading this Mac. Nothing is read and
        /// nothing is sent, not even a heartbeat (see `HelperDaemon`).
        case paused
        /// The app has not copied the answer to the app group yet
        /// (`LocalScanConsentStore.loadMirror` is nil). Treated like `.paused`:
        /// the helper cannot tell a "Not now" from a yes, and the app copies
        /// the answer as it starts, so the wait ends when the app next runs.
        case awaitingAnswer
    }

    /// The helper's version of `allowsCollection`, asked at the start of every
    /// cycle and again before anything it collected is written or uploaded.
    ///
    /// The helper has no sign-in of its own. What stands in for one is a
    /// pairing (`HelperConfig`): without it the helper only collects for the
    /// app on this Mac, which is local mode.
    ///
    /// `isPaired` is evaluated only for `.undecided`, the one answer the
    /// account decides (`allowsCollection`). In the helper it reads the
    /// pairing secret from the Keychain, and a "Not now" should not cost even
    /// that. `LocalScanConsentHelperTests` checks the result against
    /// `allowsCollection` for every answer, paired and not.
    public static func helperCycle(
        mirroredConsent: LocalScanConsent?,
        isPaired: @autoclosure () -> Bool
    ) -> HelperCycle {
        guard let consent = mirroredConsent else { return .awaitingAnswer }
        let isAuthenticated = consent == .undecided ? isPaired() : false
        return allowsCollection(isAuthenticated: isAuthenticated, consent: consent)
            ? .collect
            : .paused
    }
}

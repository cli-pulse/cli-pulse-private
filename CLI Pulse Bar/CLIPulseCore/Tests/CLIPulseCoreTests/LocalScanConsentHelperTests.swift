import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// The LoginItem helper and the local-scan answer.
///
/// The answer is saved in the app's `UserDefaults.standard`, which the helper
/// cannot read, and until 1.55 nothing else held it: the helper ran the
/// scanner and every enabled collector on its timer whatever the user had
/// answered, and on a paired Mac uploaded the results. The app now copies the
/// answer to the app group (`LocalScanConsentStore.mirror`) and the helper
/// decides from the copy (`LocalCollectionPolicy.helperCycle`).
///
/// The helper target has no tests, so the decision lives in CLIPulseCore and
/// is tested here on plain values, the way `LocalScanConsentTests` tests the
/// app's gate.
final class LocalScanConsentHelperTests: XCTestCase {

    private var suiteName: String!
    private var helperDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.clipulse.tests.consent-helper.\(UUID().uuidString)"
        helperDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        helperDefaults.removePersistentDomain(forName: suiteName)
        helperDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - The decision

    private func cycle(
        _ consent: LocalScanConsent?,
        _ account: HelperAccountRecord?,
        pairedTo pairedUserId: String? = nil
    ) -> LocalCollectionPolicy.HelperCycle {
        LocalCollectionPolicy.helperCycle(
            mirroredConsent: consent,
            account: account,
            pairedUserId: { pairedUserId }
        )
    }

    /// The defect, stated as a test: "Not now" on a paired Mac. Before 1.55
    /// the helper collected here, and pairing is what turns the helper on.
    func testNotNowPausesAPairedHelper() {
        XCTAssertEqual(cycle(.declined, .signedIn(userId: "u1"), pairedTo: "u1"), .paused(.answer))
        XCTAssertEqual(cycle(.declined, nil, pairedTo: "u1"), .paused(.answer),
                       "nor before the app has recorded an account")
    }

    /// Signed in, the helper asks the app's question with the account
    /// standing in for a yes, as `allowsCollection` does, and uploads with a
    /// pairing made for that account.
    func testSignedInTheHelperDecidesAsTheAppDoes() {
        for consent in LocalScanConsent.allCases {
            let expected: LocalCollectionPolicy.HelperCycle =
                LocalCollectionPolicy.allowsCollection(isAuthenticated: true, consent: consent)
                    ? .collectAndSync
                    : .paused(.answer)
            XCTAssertEqual(cycle(consent, .signedIn(userId: "u1"), pairedTo: "u1"), expected, "\(consent)")
        }
    }

    /// In local mode a yes lets the helper read for the app; it uploads
    /// nothing, even with a pairing left from an account.
    func testInLocalModeTheHelperReadsOnlyForTheApp() {
        for consent in LocalScanConsent.allCases {
            let expected: LocalCollectionPolicy.HelperCycle =
                LocalCollectionPolicy.allowsCollection(isAuthenticated: false, consent: consent)
                    ? .collectLocally
                    : .paused(.answer)
            XCTAssertEqual(cycle(consent, .localMode, pairedTo: "u1"), expected, "\(consent)")
        }
    }

    /// "Signing out stops the scan": signed out and not in local mode, the app
    /// reads nothing, so the helper reads nothing, whatever the answer —
    /// including after "Start local scan" or "Last 30 days only", which are
    /// the answers the sign-in caption sits next to.
    func testSignedOutTheHelperReadsNothingWhateverTheAnswer() {
        for consent in LocalScanConsent.allCases {
            XCTAssertEqual(cycle(consent, .signedOut, pairedTo: "u1"), .paused(.signedOut), "\(consent)")
        }
    }

    /// An account switch: the pairing was made for u1 and the app is signed in
    /// as u2. The helper may read for the app, and must not upload to u1.
    func testAPairingForAnotherAccountIsNotUploadedTo() {
        XCTAssertEqual(cycle(.undecided, .signedIn(userId: "u2"), pairedTo: "u1"), .collectLocally)
        XCTAssertEqual(cycle(.granted, .signedIn(userId: "u2"), pairedTo: "u1"), .collectLocally)
        XCTAssertEqual(cycle(.granted, .signedIn(userId: "u2"), pairedTo: nil), .collectLocally)
        XCTAssertEqual(cycle(.declined, .signedIn(userId: "u2"), pairedTo: "u1"), .paused(.answer))
    }

    /// Nothing recorded yet (the app has not run on this version): the pairing
    /// is trusted as it was before the record existed.
    func testWithNothingRecordedThePairingIsTrustedAsBefore() {
        XCTAssertEqual(cycle(.undecided, nil, pairedTo: "u1"), .collectAndSync)
        XCTAssertEqual(cycle(.granted, nil, pairedTo: "u1"), .collectAndSync)
        XCTAssertEqual(cycle(.granted, nil), .collectLocally)
        XCTAssertEqual(cycle(.undecided, nil), .paused(.answer))
        XCTAssertEqual(cycle(.declined, nil), .paused(.answer))
    }

    /// No copy yet — a helper that starts before the app has run since the
    /// update — is not taken for "no answer", which on a paired Mac collects.
    func testWithoutTheAppsCopyTheHelperReadsNothing() {
        let accounts: [HelperAccountRecord?] = [nil, .signedOut, .localMode, .signedIn(userId: "u1")]
        for account in accounts {
            XCTAssertEqual(cycle(nil, account, pairedTo: "u1"), .awaitingAnswer)
        }
    }

    /// In the helper, the pairing is a Keychain read. It is read only when the
    /// answer and the account could lead to an upload.
    func testThePairingIsReadOnlyWhenItCouldBeUploadedTo() {
        func reads(_ consent: LocalScanConsent?, _ account: HelperAccountRecord?) -> Int {
            var count = 0
            _ = LocalCollectionPolicy.helperCycle(
                mirroredConsent: consent,
                account: account,
                pairedUserId: { count += 1; return "u1" }
            )
            return count
        }
        XCTAssertEqual(reads(nil, .signedIn(userId: "u1")), 0)
        XCTAssertEqual(reads(.declined, .signedIn(userId: "u1")), 0)
        XCTAssertEqual(reads(.declined, nil), 0)
        for consent in LocalScanConsent.allCases {
            XCTAssertEqual(reads(consent, .signedOut), 0)
            XCTAssertEqual(reads(consent, .localMode), 0)
        }
        XCTAssertEqual(reads(.granted, .signedIn(userId: "u1")), 1)
        XCTAssertEqual(reads(.undecided, nil), 1)
    }

    // MARK: - The copy

    func testNoCopyReadsAsNoCopy() {
        XCTAssertNil(LocalScanConsentStore.loadMirror(helperDefaults))
    }

    /// Every answer is written, `.undecided` included: in the copy a missing
    /// key means "the app has not said", so it cannot also mean "no answer".
    func testEveryAnswerIsCopiedIncludingNoAnswer() throws {
        for consent in LocalScanConsent.allCases {
            for consentV2 in LocalScanConsent.allCases {
                LocalScanConsentStore.mirror(consent: consent, consentV2: consentV2, to: helperDefaults)
                let copy = try XCTUnwrap(LocalScanConsentStore.loadMirror(helperDefaults))
                XCTAssertEqual(copy.consent, consent)
                XCTAssertEqual(copy.consentV2, consentV2)
                XCTAssertEqual(helperDefaults.string(forKey: LocalScanConsentStore.key), consent.rawValue)
                XCTAssertEqual(helperDefaults.string(forKey: LocalScanConsentStore.v2Key), consentV2.rawValue)
            }
        }
    }

    /// Read as `.undecided`, a value this build does not know would let a
    /// paired helper collect. It reads as no copy, which collects nothing.
    func testAnUnrecognisedCopyIsNoCopy() {
        helperDefaults.set("yes-please", forKey: LocalScanConsentStore.key)
        XCTAssertNil(LocalScanConsentStore.loadMirror(helperDefaults))
    }

    /// The app tells the helper only when the copy changed, not on every
    /// launch.
    func testCopyingReportsWhetherAnythingChanged() {
        XCTAssertTrue(LocalScanConsentStore.mirror(consent: .undecided, consentV2: .undecided, to: helperDefaults),
                      "a first copy of no answer is still news: the helper was waiting for it")
        XCTAssertFalse(LocalScanConsentStore.mirror(consent: .undecided, consentV2: .undecided, to: helperDefaults))
        XCTAssertTrue(LocalScanConsentStore.mirror(consent: .declined, consentV2: .undecided, to: helperDefaults))
        XCTAssertFalse(LocalScanConsentStore.mirror(consent: .declined, consentV2: .undecided, to: helperDefaults))
        XCTAssertTrue(LocalScanConsentStore.mirror(consent: .declined, consentV2: .granted, to: helperDefaults))
    }

    /// From the app's copy to the helper's decision, the way the helper reads
    /// it: the copy's v1 answer, not its v2 one.
    func testTheHelperDecidesOnTheCopy() {
        LocalScanConsentStore.mirror(consent: .declined, consentV2: .granted, to: helperDefaults)
        XCTAssertEqual(
            cycle(LocalScanConsentStore.loadMirror(helperDefaults)?.consent, .signedIn(userId: "u1"), pairedTo: "u1"),
            .paused(.answer),
            "a yes to older logs is not a yes to the scan"
        )
        LocalScanConsentStore.mirror(consent: .undecided, consentV2: .undecided, to: helperDefaults)
        XCTAssertEqual(
            cycle(LocalScanConsentStore.loadMirror(helperDefaults)?.consent, .signedIn(userId: "u1"), pairedTo: "u1"),
            .collectAndSync
        )
    }

    // MARK: - The account record

    func testNothingRecordedReadsAsNoRecord() {
        XCTAssertNil(HelperIPC.loadAppAccount(helperDefaults))
    }

    func testTheAccountRecordRoundTripsAndReportsChanges() {
        let records: [HelperAccountRecord] = [
            .signedIn(userId: "u1"), .signedIn(userId: "u2"), .localMode, .signedOut, .signedIn(userId: "u1"),
        ]
        for record in records {
            XCTAssertTrue(HelperIPC.recordAppAccount(record, to: helperDefaults), "\(record) is a change")
            XCTAssertEqual(HelperIPC.loadAppAccount(helperDefaults), record)
            XCTAssertFalse(HelperIPC.recordAppAccount(record, to: helperDefaults), "\(record) again is not")
        }
    }

    /// A value this build does not recognise reads as signed out: nothing is
    /// read or sent, rather than a pairing trusted on a guess.
    func testAnUnrecognisedAccountRecordReadsAsSignedOut() {
        for value in ["signed-in", "signed_in:", "", "LOCAL_MODE"] {
            helperDefaults.set(value, forKey: HelperIPC.appAccountKey)
            XCTAssertEqual(HelperIPC.loadAppAccount(helperDefaults), .signedOut, value)
        }
    }
}

/// A runtime that may register a helper, and nothing else: no StoreKit, no
/// cloud, no Keychain namespace of the real app. Only such a runtime writes to
/// the helper's app group (`AppState.helperDefaultsForThisRuntime`), and the
/// production one would also sign the shared `SubscriptionManager` out.
enum HelperRegisteringTestRuntime {
    static var runtime: CLIPulseRuntimeEnvironment {
        CLIPulseRuntimeEnvironment(
            channel: .production,
            bundleIdentifier: "com.clipulse.tests.helper-registering",
            fixedUserHome: nil,
            resolvedFixedUserHome: nil,
            capabilities: CLIPulseRuntimeEnvironment.Capabilities(
                allowsTelemetry: false,
                allowsUnsandboxedMigration: false,
                allowsHelperRegistration: true,
                allowsPermissionSnapshot: false,
                allowsStoreKitBootstrap: false,
                allowsLiveCollection: false,
                allowsWidgetPublishing: false,
                allowsProductionCloudEndpoints: false,
                allowsPassiveDiscovery: false,
                allowsInMemoryDemoRendering: false,
                allowsBookmarkRestoration: false,
                allowsPetRestoration: false,
                allowsHelperManifestRefresh: false,
                allowsAppUpdateRefresh: false,
                allowsCurrencyNetworkRefresh: false,
                allowsCloudSessionRestore: false,
                allowsBackgroundActivityAssertion: false
            ),
            allowsProductionCloudEndpoints: false,
            shouldResetQAExperience: false
        )
    }
}

/// The `AppState` half: the copy is written where the answers are saved, and
/// at launch, so an answer given before 1.55 reaches the helper without being
/// given again.
///
/// A real `AppState` reads and writes the two answers in
/// `UserDefaults.standard` (`LocalScanConsentStore`'s default), so each test
/// puts back what was there. The app group is a throwaway suite.
@MainActor
final class LocalScanConsentMirrorAppStateTests: XCTestCase {

    private var suiteName = ""
    private var helperSuiteName = ""
    private var defaults: UserDefaults!
    private var helperDefaults: UserDefaults!
    private var savedConsent: [String: Any] = [:]
    private var notifications = 0

    private static let consentKeys = [LocalScanConsentStore.key, LocalScanConsentStore.v2Key]

    override func setUp() {
        super.setUp()
        notifications = 0
        suiteName = "com.clipulse.tests.consent-mirror.\(UUID().uuidString)"
        helperSuiteName = "com.clipulse.tests.consent-mirror.group.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        helperDefaults = UserDefaults(suiteName: helperSuiteName)
        savedConsent = [:]
        for key in Self.consentKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedConsent[key] = value }
        }
    }

    override func tearDown() {
        for key in Self.consentKeys {
            if let value = savedConsent[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        defaults.removePersistentDomain(forName: suiteName)
        helperDefaults.removePersistentDomain(forName: helperSuiteName)
        defaults = nil
        helperDefaults = nil
        super.tearDown()
    }

    private func makeState() -> AppState {
        AppState(
            runtimeEnvironment: HelperRegisteringTestRuntime.runtime,
            defaults: defaults,
            helperDefaults: helperDefaults,
            notifyHelper: { [weak self] in self?.notifications += 1 },
            performLaunchSetup: false
        )
    }

    private var mirrored: (consent: LocalScanConsent, consentV2: LocalScanConsent)? {
        LocalScanConsentStore.loadMirror(helperDefaults)
    }

    /// An answer given before the copy existed: without this the helper would
    /// wait for an answer the user already gave.
    func testLaunchCopiesTheAnswersAlreadyOnFile() throws {
        LocalScanConsentStore.save(.declined)
        LocalScanConsentStore.saveV2(.undecided)
        _ = makeState()
        let copy = try XCTUnwrap(mirrored, "launch left the helper without an answer")
        XCTAssertEqual(copy.consent, .declined)
        XCTAssertEqual(copy.consentV2, .undecided)
    }

    /// No answer on file is copied too: for a paired Mac that is the answer
    /// that lets the helper run.
    func testLaunchCopiesNoAnswerAsNoAnswer() throws {
        LocalScanConsentStore.save(.undecided)
        LocalScanConsentStore.saveV2(.undecided)
        _ = makeState()
        let copy = try XCTUnwrap(mirrored)
        XCTAssertEqual(copy.consent, .undecided)
        XCTAssertEqual(copy.consentV2, .undecided)
    }

    /// Saving an answer is copying it: the helper reads the new one on its
    /// next cycle, not the one from launch.
    func testSavingAnAnswerCopiesItForTheHelper() throws {
        LocalScanConsentStore.save(.undecided)
        LocalScanConsentStore.saveV2(.undecided)
        let state = makeState()

        state.localScanConsent = .declined
        XCTAssertEqual(LocalScanConsentStore.load(), .declined)
        XCTAssertEqual(try XCTUnwrap(mirrored).consent, .declined)

        state.localScanConsentV2 = .granted
        XCTAssertEqual(try XCTUnwrap(mirrored).consentV2, .granted)
        XCTAssertEqual(try XCTUnwrap(mirrored).consent, .declined)

        state.localScanConsent = .granted
        XCTAssertEqual(try XCTUnwrap(mirrored).consent, .granted)
    }

    /// The helper is told when the copy changes, so it acts on a "Not now"
    /// at once, and not when it does not, so a launch does not wake it.
    func testTheHelperIsToldOnlyWhenTheCopyChanges() {
        LocalScanConsentStore.save(.undecided)
        LocalScanConsentStore.saveV2(.undecided)
        let state = makeState()
        XCTAssertEqual(notifications, 1, "a first copy is news to a helper waiting for one")
        _ = makeState()
        XCTAssertEqual(notifications, 1, "a relaunch with the same answers is not")

        state.localScanConsent = .declined
        XCTAssertEqual(notifications, 2)
        state.localScanConsentV2 = .granted
        XCTAssertEqual(notifications, 3)
    }

    /// "Not now" from the disclosure, the button the defect was about, goes
    /// through the same save.
    func testNotNowFromTheDisclosureReachesTheHelper() throws {
        LocalScanConsentStore.save(.undecided)
        LocalScanConsentStore.saveV2(.undecided)
        let state = makeState()
        state.isAuthenticated = true

        state.answerLocalScanDisclosure(.notNow, to: .firstAsk)

        XCTAssertEqual(try XCTUnwrap(mirrored).consent, .declined)
        XCTAssertEqual(
            LocalCollectionPolicy.helperCycle(
                mirroredConsent: mirrored?.consent,
                account: .signedIn(userId: "u1"),
                pairedUserId: { "u1" }
            ),
            .paused(.answer)
        )
    }

    /// Where no helper runs (iOS), there is no app group to copy to.
    func testWithoutAnAppGroupNothingIsCopied() {
        LocalScanConsentStore.save(.declined)
        let state = AppState(
            runtimeEnvironment: HelperRegisteringTestRuntime.runtime,
            defaults: defaults,
            helperDefaults: nil,
            notifyHelper: { [weak self] in self?.notifications += 1 },
            performLaunchSetup: false
        )
        state.localScanConsent = .granted
        XCTAssertNil(mirrored)
        XCTAssertEqual(notifications, 0)
    }

    /// A runtime that registers no helper (QA, a quarantined launch) writes
    /// nothing to the app group even when handed one, like the provider
    /// configs (`QARuntimeSideEffectPolicyTests`).
    func testARuntimeWithoutAHelperWritesNothingToItsAppGroup() {
        LocalScanConsentStore.save(.declined)
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            helperDefaults: helperDefaults,
            notifyHelper: { [weak self] in self?.notifications += 1 },
            performLaunchSetup: false
        )
        XCTAssertFalse(state.runtimeEnvironment.capabilities.allowsHelperRegistration)
        state.localScanConsent = .granted
        state.applySignedOutState()
        XCTAssertEqual(helperDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("cli_pulse_") }, [])
        XCTAssertEqual(notifications, 0)
    }
}

/// The helper's pairing (`HelperConfig`) survives a sign-out and an account
/// switch: nothing removes it. Taken alone as "signed in", it kept a
/// signed-out Mac scanning and uploading to the account it had left, and after
/// a switch uploaded to the first account. The app now records which account
/// it is in (`HelperIPC.appAccountKey`) where it applies each state.
@MainActor
final class HelperAccountRecordAppStateTests: XCTestCase {

    private var suiteName = ""
    private var helperSuiteName = ""
    private var defaults: UserDefaults!
    private var helperDefaults: UserDefaults!
    private var savedConsent: [String: Any] = [:]
    private var savedLocalModeMarker: Any?

    private static let consentKeys = [LocalScanConsentStore.key, LocalScanConsentStore.v2Key]

    override func setUp() {
        super.setUp()
        suiteName = "com.clipulse.tests.helper-account.\(UUID().uuidString)"
        helperSuiteName = "com.clipulse.tests.helper-account.group.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        helperDefaults = UserDefaults(suiteName: helperSuiteName)
        savedConsent = [:]
        for key in Self.consentKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedConsent[key] = value }
        }
        // Signing in and out write the local-mode marker in `.standard` too.
        savedLocalModeMarker = UserDefaults.standard.object(forKey: AppState.localModeEnabledKey)
    }

    override func tearDown() {
        for key in Self.consentKeys {
            if let value = savedConsent[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let savedLocalModeMarker {
            UserDefaults.standard.set(savedLocalModeMarker, forKey: AppState.localModeEnabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppState.localModeEnabledKey)
        }
        defaults.removePersistentDomain(forName: suiteName)
        helperDefaults.removePersistentDomain(forName: helperSuiteName)
        defaults = nil
        helperDefaults = nil
        super.tearDown()
    }

    /// No provider configs: signing in binds unowned ones to the account and
    /// saves them, which in a helper-registering runtime also writes the real
    /// app group's shared-credential owners.
    private func makeState() -> AppState {
        let state = AppState(
            runtimeEnvironment: HelperRegisteringTestRuntime.runtime,
            defaults: defaults,
            helperDefaults: helperDefaults,
            performLaunchSetup: false
        )
        state.providerConfigs = []
        return state
    }

    private func signIn(_ state: AppState, as userId: String) {
        state.applyAuthenticatedState(
            AuthSessionState(userId: userId, userName: "n", userEmail: "e@x.test", isPaired: false)
        )
    }

    private var recorded: HelperAccountRecord? { HelperIPC.loadAppAccount(helperDefaults) }

    func testSigningInRecordsWhoSignedIn() {
        let state = makeState()
        signIn(state, as: "u1")
        XCTAssertEqual(recorded, .signedIn(userId: "u1"))
    }

    /// "Signing out stops the scan", including after a yes: the helper is
    /// paused whatever the answer.
    func testSigningOutIsRecordedAndPausesTheHelperWhateverTheAnswer() {
        let state = makeState()
        signIn(state, as: "u1")
        state.applySignedOutState()
        XCTAssertEqual(recorded, .signedOut, "the sign-out never reached the helper")
        for consent in LocalScanConsent.allCases {
            XCTAssertEqual(
                LocalCollectionPolicy.helperCycle(
                    mirroredConsent: consent, account: recorded, pairedUserId: { "u1" }
                ),
                .paused(.signedOut),
                "\(consent)"
            )
        }
    }

    /// Signed in as u1, out, in as u2, with the pairing still u1's: the helper
    /// reads for the app and uploads nothing to u1.
    func testAnAccountSwitchDoesNotUploadToThePreviousAccount() {
        let state = makeState()
        signIn(state, as: "u1")
        state.applySignedOutState()
        signIn(state, as: "u2")
        XCTAssertEqual(recorded, .signedIn(userId: "u2"))
        for consent in [LocalScanConsent.undecided, .granted] {
            XCTAssertEqual(
                LocalCollectionPolicy.helperCycle(
                    mirroredConsent: consent, account: recorded, pairedUserId: { "u1" }
                ),
                .collectLocally,
                "\(consent)"
            )
        }
    }

    func testUsingCLIPulseWithoutAnAccountIsRecordedAsLocalMode() {
        let state = makeState()
        state.continueWithoutAccount(defaults: defaults, startRefreshing: false)
        XCTAssertEqual(recorded, .localMode)
    }

    /// Demo mode shows an account and reads nothing.
    func testDemoModeIsRecordedAsSignedOut() {
        let state = makeState()
        signIn(state, as: "u1")
        state.enterDemoMode()
        XCTAssertEqual(recorded, .signedOut)
    }

    /// What Settings compares the helper's status with.
    func testTheAppKnowsWhenTheHelperShouldBePaused() {
        LocalScanConsentStore.save(.undecided)
        let state = makeState()
        XCTAssertTrue(state.helperShouldBePaused, "signed out on the Sign-In form")
        signIn(state, as: "u1")
        XCTAssertFalse(state.helperShouldBePaused, "signed in with no answer")
        state.localScanConsent = .declined
        XCTAssertTrue(state.helperShouldBePaused, "Not now")
    }
}

/// Settings › Advanced › Background Sync for a helper the answer has paused,
/// read in zh-Hans (a broken lookup would still produce English and pass
/// under en).
final class HelperPausedStatusLineTests: XCTestCase {
    private var previousOverride: String?
    private let device = "8f0c3a52-1111-4c1e-9d7e-3b1f5d0a2c44"

    override func setUp() {
        super.setUp()
        previousOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(previousOverride)
        super.tearDown()
    }

    private var paused: HelperIPC.Status {
        HelperIPC.Status(
            state: .running, helperVersion: "1.0.0",
            pauseCode: HelperIPC.PauseCode.localScanOff
        )
    }

    /// What the paused helper writes. Without the pause code this read
    /// "Running" in green, under a hint saying the helper syncs.
    func testAPausedHelperIsNotShownAsRunning() {
        let line = HelperStatusLine.make(status: paused, thisMacPairing: .notNeeded, pairedDeviceId: device)
        XCTAssertEqual(line, HelperStatusLine(tone: .inactive, text: "已暂停：本地扫描已关闭", isError: false))
        XCTAssertEqual(line.text, L10n.advanced.helperPausedLocalScanOff)
    }

    func testASignedOutHelperSaysSo() {
        let status = HelperIPC.Status(
            state: .running, helperVersion: "1.0.0",
            pauseCode: HelperIPC.PauseCode.signedOut, helperBuild: "107"
        )
        XCTAssertEqual(
            HelperStatusLine.make(
                status: status, thisMacPairing: .notNeeded, pairedDeviceId: nil,
                helperShouldBePaused: true, appBuild: "107"
            ),
            HelperStatusLine(tone: .inactive, text: "已暂停：未登录", isError: false)
        )
        XCTAssertEqual(
            HelperIPC.PauseCode.code(for: .signedOut), HelperIPC.PauseCode.signedOut
        )
        XCTAssertEqual(
            HelperIPC.PauseCode.code(for: .answer), HelperIPC.PauseCode.localScanOff
        )
    }

    /// A helper left running from before an update: macOS does not restart a
    /// LoginItem when its app updates in place, and one from before 1.55
    /// honours no answer. When the app expects a pause and the helper's build
    /// is not the app's, Settings says a restart is needed instead of
    /// "Synced just now".
    func testAHelperFromBeforeTheUpdateIsNotShownAsSyncing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldHelper = HelperIPC.Status(
            state: .running, lastSync: now, helperVersion: "1.0.0", deviceId: device
        )
        let restartNeeded = HelperStatusLine(
            tone: .attention, text: L10n.advanced.helperRestartNeeded, isError: false
        )
        XCTAssertEqual(L10n.advanced.helperRestartNeeded, "需要重启：请关闭后台同步再重新打开")
        XCTAssertEqual(
            HelperStatusLine.make(
                status: oldHelper, thisMacPairing: .notNeeded, pairedDeviceId: device,
                helperShouldBePaused: true, appBuild: "107", now: now
            ),
            restartNeeded
        )
        let otherBuild = HelperIPC.Status(
            state: .running, lastSync: now, helperVersion: "1.0.0", deviceId: device, helperBuild: "106"
        )
        XCTAssertEqual(
            HelperStatusLine.make(
                status: otherBuild, thisMacPairing: .notNeeded, pairedDeviceId: device,
                helperShouldBePaused: true, appBuild: "107", now: now
            ),
            restartNeeded
        )
        // Where the app expects the helper to run, an old one doing so is
        // what it would do anyway; and one that is not running is not.
        XCTAssertEqual(
            HelperStatusLine.make(
                status: oldHelper, thisMacPairing: .notNeeded, pairedDeviceId: device,
                helperShouldBePaused: false, appBuild: "107", now: now
            ).text,
            L10n.advanced.syncJustNow
        )
        XCTAssertEqual(
            HelperStatusLine.make(
                status: HelperIPC.Status(state: .idle, helperVersion: "1.0.0"),
                thisMacPairing: .notNeeded, pairedDeviceId: device,
                helperShouldBePaused: true, appBuild: "107", now: now
            ).text,
            L10n.advanced.helperNotRunning
        )
        // The current helper, paused as expected.
        XCTAssertEqual(
            HelperStatusLine.make(
                status: HelperIPC.Status(
                    state: .running, helperVersion: "1.0.0",
                    pauseCode: HelperIPC.PauseCode.localScanOff, helperBuild: "107"
                ),
                thisMacPairing: .notNeeded, pairedDeviceId: device,
                helperShouldBePaused: true, appBuild: "107", now: now
            ).text,
            L10n.advanced.helperPausedLocalScanOff
        )
    }

    /// A Mac not set up for this account says so first, as for any status.
    func testNotPairedStillComesFirst() {
        XCTAssertEqual(
            HelperStatusLine.make(status: paused, thisMacPairing: .notSetUp, pairedDeviceId: nil),
            HelperStatusLine(tone: .attention, text: L10n.settings.notPaired, isError: false)
        )
    }

    /// A status from a helper that predates the fields decodes, without them;
    /// the fields round-trip.
    func testThePauseCodeIsOptionalOnTheWire() throws {
        let legacy = Data(#"{"state":"running","helperVersion":"1.0.0"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(HelperIPC.Status.self, from: legacy).pauseCode)
        let legacyStatus = try JSONDecoder().decode(HelperIPC.Status.self, from: legacy)
        XCTAssertNil(legacyStatus.helperBuild)
        let current = HelperIPC.Status(
            state: .running, helperVersion: "1.0.0",
            pauseCode: HelperIPC.PauseCode.localScanOff, helperBuild: "107"
        )
        let roundTripped = try JSONDecoder().decode(
            HelperIPC.Status.self, from: JSONEncoder().encode(current)
        )
        XCTAssertEqual(roundTripped.pauseCode, HelperIPC.PauseCode.localScanOff)
        XCTAssertEqual(roundTripped.helperBuild, "107")
    }
}

#endif

import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.50 W-C. The consent gate, pinned at the level where it decides things.
///
/// These use an isolated `UserDefaults` suite and plain values only — no
/// `AppState`, no Keychain, no bookmarks, no refresh loop. That is not
/// fastidiousness: constructing `AppState` in a test has wedged this
/// repository's `swift test` for seventeen hours by walking into a real
/// cross-app Keychain read that blocks in `mach_msg` with nobody to click the
/// dialog. A consent gate that cannot be tested without the thing it gates
/// would be a gate nobody re-tests.
final class LocalScanConsentTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.clipulse.tests.consent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - The gate

    /// The defect, stated as a test. Someone who pressed the wizard's close
    /// button on step 0 is in local mode and has been told nothing; nothing may
    /// be read for them.
    func testUndecidedAndUnauthenticatedCollectsNothing() {
        XCTAssertFalse(
            LocalCollectionPolicy.allowsCollection(
                isAuthenticated: false,
                consent: .undecided
            )
        )
    }

    /// The migration story. Existing signed-in users see nothing new in this
    /// release: reaching sign-in means passing the wizard's privacy card, and an
    /// account means cloud sync, which is the same disclosure with more in it.
    func testUndecidedButAuthenticatedKeepsCollecting() {
        XCTAssertTrue(
            LocalCollectionPolicy.allowsCollection(
                isAuthenticated: true,
                consent: .undecided
            )
        )
    }

    /// "Not now" is sticky, and a later sign-in must not quietly overturn it.
    /// If this ever goes green with `isAuthenticated: true`, the button has
    /// become a suggestion.
    func testDeclinedSurvivesSigningIn() {
        XCTAssertFalse(
            LocalCollectionPolicy.allowsCollection(
                isAuthenticated: false,
                consent: .declined
            )
        )
        XCTAssertFalse(
            LocalCollectionPolicy.allowsCollection(
                isAuthenticated: true,
                consent: .declined
            ),
            "an explicit no must not be overridden by authenticating"
        )
    }

    func testGrantedCollectsWithOrWithoutAnAccount() {
        XCTAssertTrue(
            LocalCollectionPolicy.allowsCollection(
                isAuthenticated: false,
                consent: .granted
            )
        )
        XCTAssertTrue(
            LocalCollectionPolicy.allowsCollection(
                isAuthenticated: true,
                consent: .granted
            )
        )
    }

    // MARK: - When the disclosure appears

    func testDisclosureAppearsOnlyForTheUndecidedLocalModeUser() {
        XCTAssertTrue(
            LocalCollectionPolicy.shouldPresentDisclosure(
                isAuthenticated: false, isLocalMode: true, consent: .undecided
            )
        )
        XCTAssertFalse(
            LocalCollectionPolicy.shouldPresentDisclosure(
                isAuthenticated: true, isLocalMode: true, consent: .undecided
            ),
            "a signed-in user is not asked"
        )
        XCTAssertFalse(
            LocalCollectionPolicy.shouldPresentDisclosure(
                isAuthenticated: false, isLocalMode: false, consent: .undecided
            ),
            "someone who has not chosen local mode has nothing to consent to yet"
        )
    }

    /// Re-showing a sheet somebody already dismissed is how a consent prompt
    /// becomes a nag, and how people learn to click the tinted button without
    /// reading it. `.declined` gets the Overview card instead.
    func testDisclosureIsNotRepresentedAfterAnAnswer() {
        for answered in [LocalScanConsent.granted, .declined] {
            XCTAssertFalse(
                LocalCollectionPolicy.shouldPresentDisclosure(
                    isAuthenticated: false, isLocalMode: true, consent: answered
                ),
                "\(answered) has already been answered"
            )
        }
    }

    // MARK: - Storage

    func testAbsentKeyReadsAsUndecided() {
        XCTAssertEqual(LocalScanConsentStore.load(defaults), .undecided)
    }

    /// Reading must not write. `AppState` initializes `localScanConsent` from
    /// this call, and `FirstRunPresentation.decide` — which asks whether ANY
    /// app-owned preference exists — has to run before the app writes its own.
    /// A `load` that materialised a default would make every fresh install look
    /// like an upgrade and the v1.49 welcome window would never appear again.
    func testLoadingDoesNotCreateTheKey() {
        _ = LocalScanConsentStore.load(defaults)
        XCTAssertNil(
            defaults.object(forKey: LocalScanConsentStore.key),
            "reading consent must leave a fresh install indistinguishable from fresh"
        )
    }

    func testAnswersRoundTrip() {
        for answer in [LocalScanConsent.granted, .declined] {
            LocalScanConsentStore.save(answer, to: defaults)
            XCTAssertEqual(LocalScanConsentStore.load(defaults), answer)
        }
    }

    /// `.undecided` is the absence of a record, not a value to write — otherwise
    /// "reset the question" and "answered undecided" become the same state on
    /// disk, and `hasUsedThisAppBefore` (which asks whether the key exists at
    /// all) would start calling a reset user an existing one.
    func testSavingUndecidedRemovesTheKey() {
        LocalScanConsentStore.save(.granted, to: defaults)
        XCTAssertNotNil(defaults.object(forKey: LocalScanConsentStore.key))
        LocalScanConsentStore.save(.undecided, to: defaults)
        XCTAssertNil(defaults.object(forKey: LocalScanConsentStore.key))
        XCTAssertEqual(LocalScanConsentStore.load(defaults), .undecided)
    }

    func testUnrecognisedValueReadsAsUndecidedRatherThanCrashing() {
        defaults.set("yes-please", forKey: LocalScanConsentStore.key)
        XCTAssertEqual(LocalScanConsentStore.load(defaults), .undecided)
    }

    /// The `cli_pulse_` prefix is what carries this key through the MAS →
    /// Developer ID migration. `UnsandboxedDataMigration.appOwnedKeyPrefixes` is
    /// a strict allowlist; a key outside it is dropped, and a dropped consent
    /// record would silently re-open the sheet — or reset a `declined` to
    /// `undecided`, which is the direction that matters.
    func testKeyCarriesAMigratableAppOwnedPrefix() {
        XCTAssertTrue(
            UnsandboxedDataMigration.appOwnedKeyPrefixes.contains(where: {
                LocalScanConsentStore.key.hasPrefix($0)
            }),
            "\(LocalScanConsentStore.key) would be dropped on MAS → DEVID"
        )
    }

    // MARK: - Prior-use detection

    /// `AgentSetupStateStore.hasUsedThisAppBefore` decides whether someone is
    /// routed to the app or captured by the onboarding wizard. A key it does not
    /// know about makes a returning user look new on every launch.
    ///
    /// Both answers count, which is why the store reads `object(forKey:)` and
    /// not `bool(forKey:)` — "declined" is an answer, and a bool read would file
    /// it as absence.
    func testAnsweringTheDisclosureCountsAsPriorUse() {
        XCTAssertFalse(AgentSetupStateStore.hasUsedThisAppBefore(defaults))
        for answer in [LocalScanConsent.granted, .declined] {
            LocalScanConsentStore.save(.undecided, to: defaults)
            XCTAssertFalse(
                AgentSetupStateStore.hasUsedThisAppBefore(defaults),
                "no answer on file is not prior use"
            )
            LocalScanConsentStore.save(answer, to: defaults)
            XCTAssertTrue(
                AgentSetupStateStore.hasUsedThisAppBefore(defaults),
                "\(answer) is an answer, and answering means having been here"
            )
        }
    }

    // MARK: - The gate where it actually runs

    /// Everything above tests the decision. This tests the *placement*, which is
    /// the part rev1 and rev3 of the plan each got wrong — both nominated a
    /// guard that runs after the collectors, the JSONL scan and the durable
    /// writes have already happened.
    ///
    /// So this drives a real `refreshAll` down the `.localOnly` route with a
    /// runtime that records every side effect, and asserts the recorder is
    /// empty. Move the gate below any of these calls and the counts come back
    /// non-zero.
    @MainActor
    func testRefreshCollectsNothingWithoutConsent() async {
        let recorder = LocalRuntimeRecorder()
        let manager = DataRefreshManager(
            api: APIClient(
                supabaseURL: "https://stub.cli-pulse.test",
                supabaseAnonKey: "anon"
            ),
            localRuntime: .recording(recorder)
        )

        await manager.refreshAll(
            context: Self.localModeContext(consent: .undecided),
            callbacks: Self.inertCallbacks()
        )
        var counts = await recorder.counts
        XCTAssertEqual(counts, [:], "undecided must read nothing at all")

        await manager.refreshAll(
            context: Self.localModeContext(consent: .declined),
            callbacks: Self.inertCallbacks()
        )
        counts = await recorder.counts
        XCTAssertEqual(counts, [:], "declined must read nothing at all")
    }

    /// The other half, without which the test above would pass on a refresh that
    /// is simply broken. Granting consent must let the same call through.
    @MainActor
    func testRefreshCollectsOnceConsentIsGranted() async {
        let recorder = LocalRuntimeRecorder()
        let manager = DataRefreshManager(
            api: APIClient(
                supabaseURL: "https://stub.cli-pulse.test",
                supabaseAnonKey: "anon"
            ),
            localRuntime: .recording(recorder)
        )

        await manager.refreshAll(
            context: Self.localModeContext(consent: .granted),
            callbacks: Self.inertCallbacks()
        )

        let counts = await recorder.counts
        XCTAssertEqual(counts["collectAccountPass"], 1)
        XCTAssertEqual(counts["scanCostUsage"], 1)
        XCTAssertEqual(counts["scanLocal"], 1)
    }

    private static func localModeContext(
        consent: LocalScanConsent
    ) -> DataRefreshManager.Context {
        DataRefreshManager.Context(
            isAuthenticated: false,
            isDemoMode: false,
            isPaired: false,
            isLoading: false,
            notificationsEnabled: false,
            authenticatedUserID: "",
            providerConfigs: [],
            providers: [],
            maxProviders: 100,
            currentTierName: "Free",
            tierResolutionState: .resolvedConfirmed,
            isLocalMode: true,
            localScanConsent: consent
        )
    }

    private static func inertCallbacks() -> DataRefreshManager.Callbacks {
        DataRefreshManager.Callbacks(
            isAuthenticated: { false },
            setLoading: { _ in },
            setLastError: { _ in },
            setServerOnline: { _ in },
            applyPayload: { _ in },
            sendNotification: { _ in },
            afterRefresh: {},
            handleTokenExpired: { _ in },
            activeSuppressedAlertIDs: { [] },
            setNeedsFolderAccess: { _ in },
            setCollectorOutcomes: { _ in }
        )
    }
}

/// Counts the side effects `refreshLocal` would perform. Every closure here is
/// something that touches the user's machine — provider APIs and OAuth token
/// rewrites, another app's Keychain, up to 30 days of JSONL — so "the recorder
/// is empty" is the same sentence as "nothing was read".
actor LocalRuntimeRecorder {
    private(set) var counts: [String: Int] = [:]

    func record(_ name: String) {
        counts[name, default: 0] += 1
    }
}

extension DataRefreshManager.LocalRefreshRuntime {
    static func recording(_ recorder: LocalRuntimeRecorder) -> Self {
        Self(
            prepareCredentials: {},
            collectAccountPass: { _ in
                await recorder.record("collectAccountPass")
                return .empty
            },
            readHelperSnapshot: { _ in .empty },
            scanLocal: {
                await recorder.record("scanLocal")
                return LocalScanResult(
                    sessions: [],
                    providers: [],
                    totalUsage: 0,
                    totalCost: 0,
                    activeSessionCount: 0
                )
            },
            scanCostUsage: {
                await recorder.record("scanCostUsage")
                return CostUsageScanResult(entries: [])
            },
            needsFolderAccessNudge: { _ in false },
            syncLegacyQuotas: { _, _ in await recorder.record("syncLegacyQuotas") },
            syncDailyUsage: { _, _ in await recorder.record("syncDailyUsage") },
            syncAccountQuotas: { _, _ in await recorder.record("syncAccountQuotas") }
        )
    }
}

#endif

import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.55 — disclosure v2.
///
/// The consent screen said "Session logs, last 30 days". Since the usage
/// history arrived, the first successful scan also ran a one-time backfill over
/// up to a year of logs, for everyone, whatever the screen had said. v2 makes the
/// read beyond 30 days its own answer, stored under its own key, so that:
///
///   * a v1 "yes" with no v2 answer reads 30 days and nothing older;
///   * a v2 "yes" lets the backfill run;
///   * "no" to the scan reads nothing, whatever v2 says;
///   * refusing v2 is not taking back v1 — the 30-day scan keeps running.
///
/// Like `LocalScanConsentTests`, these use plain values and an isolated
/// `UserDefaults` suite, never an `AppState`.
final class LocalScanConsentV2Tests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.clipulse.tests.consent-v2.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func beyond(
        _ isAuthenticated: Bool,
        _ consent: LocalScanConsent,
        _ consentV2: LocalScanConsent
    ) -> Bool {
        LocalCollectionPolicy.allowsReadingBeyondRoutineWindow(
            isAuthenticated: isAuthenticated,
            consent: consent,
            consentV2: consentV2
        )
    }

    private func asksV2(
        isAuthenticated: Bool,
        isLocalMode: Bool = true,
        isDemoMode: Bool = false,
        _ consent: LocalScanConsent,
        _ consentV2: LocalScanConsent
    ) -> Bool {
        LocalCollectionPolicy.shouldPresentV2Disclosure(
            isAuthenticated: isAuthenticated,
            isLocalMode: isLocalMode,
            isDemoMode: isDemoMode,
            consent: consent,
            consentV2: consentV2
        )
    }

    // MARK: - The state machine

    /// The defect, stated as a test: the people who agreed to "30 days".
    func testAV1YesWithNoV2AnswerReadsOnlyTheRoutineWindow() {
        for signedIn in [false, true] {
            XCTAssertTrue(
                LocalCollectionPolicy.allowsCollection(
                    isAuthenticated: signedIn, consent: .granted
                ),
                "the 30-day scan they agreed to keeps running"
            )
            XCTAssertFalse(
                beyond(signedIn, .granted, .undecided),
                "nothing older than 30 days without an answer to v2 (signed in: \(signedIn))"
            )
        }
    }

    func testAV2YesLetsTheHistoryReadRun() {
        XCTAssertTrue(beyond(false, .granted, .granted))
        XCTAssertTrue(beyond(true, .granted, .granted))
        // A signed-in user can answer v2 from Settings without ever having
        // answered v1: the account stands in for v1, the switch is the v2 yes.
        XCTAssertTrue(beyond(true, .undecided, .granted))
    }

    /// "No" to the scan is no to all of it. A v2 yes left over from before
    /// must not reopen the year.
    func testDeclinedReadsNothingWhateverV2Says() {
        for signedIn in [false, true] {
            XCTAssertFalse(
                LocalCollectionPolicy.allowsCollection(
                    isAuthenticated: signedIn, consent: .declined
                )
            )
            for consentV2 in LocalScanConsent.allCases {
                XCTAssertFalse(
                    beyond(signedIn, .declined, consentV2),
                    "declined + v2 \(consentV2) (signed in: \(signedIn)) read beyond 30 days"
                )
            }
        }
    }

    /// Signing in was taken as consent to the scan v1 described. It was never
    /// consent to a year, because nothing on screen ever said a year.
    func testSigningInIsNotConsentToAYear() {
        XCTAssertTrue(
            LocalCollectionPolicy.allowsCollection(
                isAuthenticated: true, consent: .undecided
            )
        )
        XCTAssertFalse(beyond(true, .undecided, .undecided))
        XCTAssertFalse(beyond(true, .undecided, .declined))
    }

    func testNobodyUnansweredAndSignedOutReadsAnything() {
        for consentV2 in LocalScanConsent.allCases {
            XCTAssertFalse(beyond(false, .undecided, consentV2))
        }
    }

    // MARK: - What each button leaves behind

    /// Refusing v2 is not taking back v1.
    func testLast30DaysOnlyKeepsTheScanAndRefusesTheYear() {
        for priorV2 in LocalScanConsent.allCases {
            let answer = LocalCollectionPolicy.answering(.last30DaysOnly, consentV2: priorV2)
            XCTAssertEqual(answer.consent, .granted)
            XCTAssertEqual(answer.consentV2, .declined)
            for signedIn in [false, true] {
                XCTAssertTrue(
                    LocalCollectionPolicy.allowsCollection(
                        isAuthenticated: signedIn, consent: answer.consent
                    ),
                    "refusing v2 stopped the 30-day scan"
                )
                XCTAssertFalse(beyond(signedIn, answer.consent, answer.consentV2))
            }
        }
    }

    func testScanWithHistoryGrantsBoth() {
        let answer = LocalCollectionPolicy.answering(.scanWithHistory, consentV2: .undecided)
        XCTAssertEqual(answer.consent, .granted)
        XCTAssertEqual(answer.consentV2, .granted)
        XCTAssertTrue(beyond(false, answer.consent, answer.consentV2))
    }

    /// "Not now" reads nothing, and leaves the v2 question for the day the scan
    /// is turned back on — when it will be asked with the disclosure in view.
    func testNotNowReadsNothingAndLeavesV2Alone() {
        for priorV2 in LocalScanConsent.allCases {
            let answer = LocalCollectionPolicy.answering(.notNow, consentV2: priorV2)
            XCTAssertEqual(answer.consent, .declined)
            XCTAssertEqual(answer.consentV2, priorV2)
            XCTAssertFalse(
                LocalCollectionPolicy.allowsCollection(
                    isAuthenticated: false, consent: answer.consent
                )
            )
            XCTAssertFalse(beyond(false, answer.consent, answer.consentV2))
        }
    }

    // MARK: - Who is asked, and how often

    func testV2IsAskedOfEveryV1Yes() {
        XCTAssertTrue(asksV2(isAuthenticated: false, .granted, .undecided))
        XCTAssertTrue(asksV2(isAuthenticated: true, isLocalMode: false, .granted, .undecided))
    }

    /// The signed-in users 1.50 let through on the strength of the account.
    /// They have never been shown what the scan reads.
    func testV2IsAskedOfSignedInUsersWithNothingOnFile() {
        XCTAssertTrue(asksV2(isAuthenticated: true, isLocalMode: false, .undecided, .undecided))
        XCTAssertTrue(asksV2(isAuthenticated: true, isLocalMode: true, .undecided, .undecided))
    }

    func testV2IsNotAskedOfSomeoneWhoDeclined() {
        for signedIn in [false, true] {
            XCTAssertFalse(asksV2(isAuthenticated: signedIn, .declined, .undecided))
        }
    }

    /// Demo mode is signed in with nothing on file — exactly the shape that is
    /// asked — but reads nothing, and it is what the screenshots are drawn from.
    func testV2IsNotAskedInDemoMode() {
        XCTAssertFalse(asksV2(isAuthenticated: true, isDemoMode: true, .undecided, .undecided))
        XCTAssertFalse(asksV2(isAuthenticated: true, isDemoMode: true, .granted, .undecided))
    }

    func testV2IsNotAskedOfASignedOutMacThatIsNotScanning() {
        XCTAssertFalse(asksV2(isAuthenticated: false, isLocalMode: false, .granted, .undecided))
    }

    /// Where the first ask applies, it already carries the v2 choice.
    func testTheFirstAskComesFirst() {
        XCTAssertTrue(
            LocalCollectionPolicy.shouldPresentDisclosure(
                isAuthenticated: false, isLocalMode: true, consent: .undecided
            )
        )
        XCTAssertFalse(asksV2(isAuthenticated: false, .undecided, .undecided))
    }

    /// Once: every answer, on either screen, ends the questions. A prompt that
    /// comes back after it was answered is how people learn to click the tinted
    /// button without reading.
    func testEveryAnswerOnEitherScreenIsTheLastQuestion() {
        // (signed in, v1, v2) for each screen a user can be shown.
        let screens: [(Bool, LocalScanConsent, LocalScanConsent)] = [
            (false, .undecided, .undecided),   // first ask, local mode
            (false, .granted, .undecided),     // v2 ask, a v1 yes
            (true, .undecided, .undecided),    // v2 ask, signed in, nothing on file
            (true, .granted, .undecided),      // v2 ask, signed in with a v1 yes
        ]
        for (signedIn, consent, consentV2) in screens {
            let firstAsk = LocalCollectionPolicy.shouldPresentDisclosure(
                isAuthenticated: signedIn, isLocalMode: true, consent: consent
            )
            XCTAssertTrue(
                firstAsk || asksV2(isAuthenticated: signedIn, consent, consentV2),
                "precondition: \((signedIn, consent, consentV2)) is shown a screen"
            )
            let choices: [LocalScanChoice] = firstAsk
                ? [.scanWithHistory, .last30DaysOnly, .notNow]
                : [.scanWithHistory, .last30DaysOnly]
            for choice in choices {
                let answer = LocalCollectionPolicy.answering(choice, consentV2: consentV2)
                XCTAssertFalse(
                    LocalCollectionPolicy.shouldPresentDisclosure(
                        isAuthenticated: signedIn, isLocalMode: true, consent: answer.consent
                    ),
                    "\(choice) from \((signedIn, consent, consentV2)) re-shows the first ask"
                )
                XCTAssertFalse(
                    asksV2(isAuthenticated: signedIn, answer.consent, answer.consentV2),
                    "\(choice) from \((signedIn, consent, consentV2)) re-shows the v2 ask"
                )
            }
        }
    }

    // MARK: - Storage

    func testV2AbsentReadsAsUndecidedAndReadingDoesNotWrite() {
        XCTAssertEqual(LocalScanConsentStore.loadV2(defaults), .undecided)
        XCTAssertNil(defaults.object(forKey: LocalScanConsentStore.v2Key))
    }

    func testV2AnswersRoundTripAndUndecidedRemovesTheKey() {
        for answer in [LocalScanConsent.granted, .declined] {
            LocalScanConsentStore.saveV2(answer, to: defaults)
            XCTAssertEqual(LocalScanConsentStore.loadV2(defaults), answer)
        }
        LocalScanConsentStore.saveV2(.undecided, to: defaults)
        XCTAssertNil(defaults.object(forKey: LocalScanConsentStore.v2Key))
    }

    /// The whole point of a second key: the v2 answer cannot overwrite the v1
    /// one, in either direction.
    func testTheTwoAnswersAreStoredApart() {
        XCTAssertNotEqual(LocalScanConsentStore.key, LocalScanConsentStore.v2Key)
        LocalScanConsentStore.save(.granted, to: defaults)
        LocalScanConsentStore.saveV2(.declined, to: defaults)
        XCTAssertEqual(LocalScanConsentStore.load(defaults), .granted)
        XCTAssertEqual(LocalScanConsentStore.loadV2(defaults), .declined)
        LocalScanConsentStore.save(.declined, to: defaults)
        XCTAssertEqual(LocalScanConsentStore.loadV2(defaults), .declined)
    }

    /// An existing v1 record is read as an answer to v1 and nothing more — the
    /// migration for everyone who agreed before 1.55 is "not asked v2 yet".
    func testAnExistingV1RecordIsNotAV2Answer() {
        defaults.set("granted", forKey: LocalScanConsentStore.key)
        XCTAssertEqual(LocalScanConsentStore.load(defaults), .granted)
        XCTAssertEqual(LocalScanConsentStore.loadV2(defaults), .undecided)
    }

    func testV2KeyCarriesAMigratableAppOwnedPrefix() {
        XCTAssertTrue(
            UnsandboxedDataMigration.appOwnedKeyPrefixes.contains(where: {
                LocalScanConsentStore.v2Key.hasPrefix($0)
            }),
            "\(LocalScanConsentStore.v2Key) would be dropped on MAS → DEVID"
        )
    }

    func testAnsweringV2CountsAsPriorUse() {
        XCTAssertFalse(AgentSetupStateStore.hasUsedThisAppBefore(defaults))
        LocalScanConsentStore.saveV2(.declined, to: defaults)
        XCTAssertTrue(AgentSetupStateStore.hasUsedThisAppBefore(defaults))
    }

    // MARK: - Where the refresh acts on it

    /// The placement test. A real `refreshAll` down the `.localOnly` route, a
    /// successful scan, and a runtime that records which answer the refresh
    /// handed to the durable stores and the backfill.
    @MainActor
    private func historyReadDecisions(
        consent: LocalScanConsent,
        consentV2: LocalScanConsent
    ) async -> [Bool] {
        let log = LocalHistoryCallLog()
        let manager = DataRefreshManager(
            api: APIClient(
                supabaseURL: "https://stub.cli-pulse.test",
                supabaseAnonKey: "anon"
            ),
            localRuntime: .recording(
                LocalRuntimeRecorder(),
                historyLog: log,
                costEntries: [Self.oneDay]
            )
        )
        await manager.refreshAll(
            context: LocalScanConsentTests.localModeContext(
                consent: consent,
                consentV2: consentV2
            ),
            callbacks: LocalScanConsentTests.inertCallbacks()
        )
        return log.historyReadAllowed
    }

    @MainActor
    func testRefreshWithOnlyAV1YesKeepsTheYearClosed() async {
        let undecided = await historyReadDecisions(consent: .granted, consentV2: .undecided)
        XCTAssertEqual(undecided, [false], "a v1 yes alone opened the one-year read")
        let refused = await historyReadDecisions(consent: .granted, consentV2: .declined)
        XCTAssertEqual(refused, [false], "a v2 no opened the one-year read")
    }

    /// The other half: without it, the test above would pass on a refresh that
    /// never lets the backfill run at all.
    @MainActor
    func testRefreshWithAV2YesOpensTheYear() async {
        let granted = await historyReadDecisions(consent: .granted, consentV2: .granted)
        XCTAssertEqual(granted, [true])
    }

    @MainActor
    func testRefreshWithoutConsentReachesNoStoreAtAll() async {
        for consentV2 in LocalScanConsent.allCases {
            let declined = await historyReadDecisions(consent: .declined, consentV2: consentV2)
            XCTAssertEqual(declined, [], "declined + v2 \(consentV2) reached the stores")
        }
    }

    private static let oneDay = CostUsageScanResult.DailyEntry(
        date: "2026-09-01", provider: "Codex", model: "gpt-5",
        inputTokens: 100, cachedTokens: 0, outputTokens: 10,
        costUSD: 0.01, messageCount: 0
    )
}

#endif

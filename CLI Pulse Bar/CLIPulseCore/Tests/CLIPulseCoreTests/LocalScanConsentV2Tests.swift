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

    private func reply(
        _ choice: LocalScanChoice,
        to question: LocalScanQuestion = .firstAsk,
        consent: LocalScanConsent = .undecided,
        consentV2: LocalScanConsent
    ) -> (consent: LocalScanConsent, consentV2: LocalScanConsent) {
        LocalCollectionPolicy.answering(choice, to: question, consent: consent, consentV2: consentV2)
    }

    /// Refusing v2 is not taking back v1.
    func testLast30DaysOnlyKeepsTheScanAndRefusesTheYear() {
        for priorV2 in LocalScanConsent.allCases {
            let answer = reply(.last30DaysOnly, consentV2: priorV2)
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
        let answer = reply(.scanWithHistory, consentV2: .undecided)
        XCTAssertEqual(answer.consent, .granted)
        XCTAssertEqual(answer.consentV2, .granted)
        XCTAssertTrue(beyond(false, answer.consent, answer.consentV2))
    }

    /// The older-logs screen asks only about the older logs, so only that answer
    /// is stored: the v1 answer is left as it was, whatever it was.
    func testTheOlderLogsScreenStoresOnlyTheOlderLogsAnswer() {
        for prior in LocalScanConsent.allCases {
            for priorV2 in LocalScanConsent.allCases {
                let yes = reply(.scanWithHistory, to: .olderLogs, consent: prior, consentV2: priorV2)
                XCTAssertEqual(yes.consent, prior, "the older-logs yes rewrote v1 (\(prior))")
                XCTAssertEqual(yes.consentV2, .granted)
                let no = reply(.last30DaysOnly, to: .olderLogs, consent: prior, consentV2: priorV2)
                XCTAssertEqual(no.consent, prior, "the older-logs no rewrote v1 (\(prior))")
                XCTAssertEqual(no.consentV2, .declined)
            }
        }
    }

    /// The signed-in user with nothing on file: no v1 yes is recorded for them.
    /// While signed in the account stands in for it, exactly as before they
    /// answered; signed out into local mode, they are asked the first question.
    func testASignedInAnswerAboutOlderLogsIsNotRecordedAsAYesToTheScan() {
        for choice in [LocalScanChoice.scanWithHistory, .last30DaysOnly] {
            let answer = reply(choice, to: .olderLogs, consent: .undecided, consentV2: .undecided)
            XCTAssertEqual(answer.consent, .undecided, "\(choice) recorded a v1 answer they never gave")
            XCTAssertNil(
                storedV1(after: answer),
                "\(choice) wrote the v1 key"
            )

            // Signed in: scanning as before, the year as answered, not asked again.
            XCTAssertTrue(LocalCollectionPolicy.allowsCollection(isAuthenticated: true, consent: answer.consent))
            XCTAssertEqual(beyond(true, answer.consent, answer.consentV2), choice == .scanWithHistory)
            XCTAssertFalse(asksV2(isAuthenticated: true, isLocalMode: false, answer.consent, answer.consentV2))

            // Signed out into local mode: nothing is read until they answer the
            // first ask, which they have never been shown.
            XCTAssertFalse(LocalCollectionPolicy.allowsCollection(isAuthenticated: false, consent: answer.consent))
            XCTAssertTrue(
                LocalCollectionPolicy.shouldPresentDisclosure(
                    isAuthenticated: false, isLocalMode: true, consent: answer.consent
                ),
                "signed out into local mode with no v1 answer, and not asked"
            )
        }
    }

    /// Writes an answer the way `AppState` does and reads back the v1 key.
    private func storedV1(
        after answer: (consent: LocalScanConsent, consentV2: LocalScanConsent)
    ) -> Any? {
        LocalScanConsentStore.saveV2(answer.consentV2, to: defaults)
        LocalScanConsentStore.save(answer.consent, to: defaults)
        defer {
            defaults.removeObject(forKey: LocalScanConsentStore.key)
            defaults.removeObject(forKey: LocalScanConsentStore.v2Key)
        }
        return defaults.object(forKey: LocalScanConsentStore.key)
    }

    /// "Not now" reads nothing, and leaves the v2 question for the day the scan
    /// is turned back on — when it will be asked with the disclosure in view.
    func testNotNowReadsNothingAndLeavesV2Alone() {
        for priorV2 in LocalScanConsent.allCases {
            let answer = reply(.notNow, consentV2: priorV2)
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
            let question: LocalScanQuestion = firstAsk ? .firstAsk : .olderLogs
            let choices: [LocalScanChoice] = firstAsk
                ? [.scanWithHistory, .last30DaysOnly, .notNow]
                : [.scanWithHistory, .last30DaysOnly]
            for choice in choices {
                let answer = reply(choice, to: question, consent: consent, consentV2: consentV2)
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

    // MARK: - Choosing again after "Not now", while signed in

    /// The way back from "Not now" for a signed-in Mac, and for nobody else:
    /// local mode has its scan switch and the Overview's card, a signed-in Mac
    /// that has not declined has nothing to choose again, and Demo reads nothing.
    func testChooseAgainIsOfferedOnlyToASignedInNotNow() {
        for signedIn in [false, true] {
            for demo in [false, true] {
                for consent in LocalScanConsent.allCases {
                    XCTAssertEqual(
                        LocalCollectionPolicy.offersChoosingAgain(
                            isAuthenticated: signedIn, isDemoMode: demo, consent: consent
                        ),
                        signedIn && !demo && consent == .declined,
                        "signed in: \(signedIn), demo: \(demo), consent: \(consent)"
                    )
                }
            }
        }
    }

    /// Pressing it reopens the first ask. Before, and wherever it is not
    /// offered, a signed-in "Not now" is shown no question at all.
    func testChooseAgainReopensTheFirstAsk() {
        var state = LocalScanConsentState(consent: .declined, consentV2: .undecided)
        XCTAssertFalse(presentsAgain(state), "the question came back without being asked for")
        XCTAssertFalse(
            LocalCollectionPolicy.shouldPresentDisclosure(
                isAuthenticated: true, isLocalMode: false, consent: state.consent
            )
        )

        state.requestChoosingAgain(isAuthenticated: true, isDemoMode: false)
        XCTAssertTrue(state.isChoosingAgain)
        XCTAssertTrue(presentsAgain(state))

        // Not where Settings does not offer it: (signed in, demo, v1).
        let notOffered: [(Bool, Bool, LocalScanConsent)] = [
            (false, false, .declined),
            (true, true, .declined),
            (true, false, .undecided),
            (true, false, .granted),
        ]
        for (signedIn, demo, consent) in notOffered {
            var other = LocalScanConsentState(consent: consent, consentV2: .undecided)
            other.requestChoosingAgain(isAuthenticated: signedIn, isDemoMode: demo)
            XCTAssertFalse(other.isChoosingAgain, "\((signedIn, demo, consent)) was put the question")
        }
    }

    /// Every answer on the reopened screen is the last question, "Not now"
    /// included: it leaves the scan off as it was, and the request must end
    /// with it or the screen never goes away.
    func testEveryAnswerOnTheReopenedScreenEndsIt() {
        for priorV2 in LocalScanConsent.allCases {
            for choice in [LocalScanChoice.scanWithHistory, .last30DaysOnly, .notNow] {
                var state = LocalScanConsentState(consent: .declined, consentV2: priorV2)
                state.requestChoosingAgain(isAuthenticated: true, isDemoMode: false)
                XCTAssertTrue(presentsAgain(state), "precondition")

                state.answer(choice, to: .firstAsk)
                XCTAssertFalse(state.isChoosingAgain, "\(choice) left the request open")
                XCTAssertFalse(presentsAgain(state), "\(choice) re-shows the reopened ask")
                XCTAssertFalse(
                    asksV2(isAuthenticated: true, isLocalMode: false, state.consent, state.consentV2),
                    "\(choice) is followed by the older-logs ask"
                )
            }
        }
    }

    /// What the answers mean there is what they mean on the first ask: they
    /// are the user's own answer to the scan, so v1 is recorded.
    func testTheReopenedScreenRecordsTheAnswerGiven() {
        func answered(_ choice: LocalScanChoice) -> LocalScanConsentState {
            var state = LocalScanConsentState(consent: .declined, consentV2: .declined)
            state.requestChoosingAgain(isAuthenticated: true, isDemoMode: false)
            state.answer(choice, to: .firstAsk)
            return state
        }
        let all = answered(.scanWithHistory)
        XCTAssertEqual([all.consent, all.consentV2], [.granted, .granted])
        XCTAssertTrue(beyond(true, all.consent, all.consentV2))

        let recent = answered(.last30DaysOnly)
        XCTAssertEqual([recent.consent, recent.consentV2], [.granted, .declined])
        XCTAssertTrue(LocalCollectionPolicy.allowsCollection(isAuthenticated: true, consent: recent.consent))
        XCTAssertFalse(beyond(true, recent.consent, recent.consentV2))

        let none = answered(.notNow)
        XCTAssertEqual([none.consent, none.consentV2], [.declined, .declined])
        XCTAssertFalse(LocalCollectionPolicy.allowsCollection(isAuthenticated: true, consent: none.consent))
    }

    /// A request left open is not honoured once it is no longer the right one:
    /// signed out (the first ask has its own rule there), or no longer "Not now".
    func testAStaleRequestShowsNothing() {
        XCTAssertFalse(LocalCollectionPolicy.shouldPresentDisclosureAgain(
            requested: true, isAuthenticated: false, isDemoMode: false, consent: .declined))
        XCTAssertFalse(LocalCollectionPolicy.shouldPresentDisclosureAgain(
            requested: true, isAuthenticated: true, isDemoMode: false, consent: .granted))
        XCTAssertFalse(LocalCollectionPolicy.shouldPresentDisclosureAgain(
            requested: true, isAuthenticated: true, isDemoMode: true, consent: .declined))
        XCTAssertFalse(LocalCollectionPolicy.shouldPresentDisclosureAgain(
            requested: false, isAuthenticated: true, isDemoMode: false, consent: .declined))
    }

    private func presentsAgain(_ state: LocalScanConsentState) -> Bool {
        LocalCollectionPolicy.shouldPresentDisclosureAgain(
            requested: state.isChoosingAgain,
            isAuthenticated: true,
            isDemoMode: false,
            consent: state.consent
        )
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
    /// handed to the durable stores and the backfill. The same decisions on the
    /// paired cloud route are pinned in `DataRefreshManagerProviderAccountBoundaryTests`,
    /// which has the stubbed Supabase that route needs.
    @MainActor
    private func historyReadDecisions(
        consent: LocalScanConsent,
        consentV2: LocalScanConsent
    ) async -> [Bool] {
        await historyCalls(consent: consent, consentV2: consentV2).historyReadAllowed
    }

    @MainActor
    private func historyCalls(
        consent: LocalScanConsent,
        consentV2: LocalScanConsent
    ) async -> LocalHistoryCallLog {
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
        return log
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

    /// v1.56: signed out, the refresh hands the history stores no
    /// authorization lease, so the Codex history rebuild recounts this Mac's
    /// archive and reaches no account's cloud. Its cloud route hands its own
    /// lease (`testCloudRouteHandsTheHistoryItsLease`).
    @MainActor
    func testASignedOutRefreshHandsTheHistoryNoLease() async {
        let log = await historyCalls(consent: .granted, consentV2: .granted)
        XCTAssertEqual(log.historyReadAllowed, [true], "control: the history stores were reached")
        XCTAssertEqual(log.leases, [false], "a signed-out refresh handed over a lease")
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

/// The `AppState` half of "Choose again…". `LocalScanConsentState` decides what
/// each step leaves behind (tested above without an `AppState`); these check
/// that `AppState` copies all of it back. The struct tests alone would pass if
/// `answerLocalScanDisclosure` stopped copying the request back, and the
/// reopened ask would then stay up after "Not now", since no answer changes.
///
/// A real `AppState` writes the two consent keys to `UserDefaults.standard`
/// (`LocalScanConsentStore`'s default), so each test puts back what was there.
/// Everything else it stores goes to a throwaway suite.
@MainActor
final class LocalScanChooseAgainAppStateTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var savedConsent: [String: Any] = [:]

    private static let consentKeys = [LocalScanConsentStore.key, LocalScanConsentStore.v2Key]

    override func setUp() {
        super.setUp()
        suiteName = "com.clipulse.tests.choose-again.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
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
        defaults = nil
        super.tearDown()
    }

    /// Signed in, not Demo, answer "Not now": the one Mac Settings offers
    /// "Choose again…" to.
    private func makeSignedInNotNow() -> AppState {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false
        )
        state.isAuthenticated = true
        state.localScanConsent = .declined
        state.localScanConsentV2 = .undecided
        return state
    }

    private func presentsAgain(_ state: AppState) -> Bool {
        LocalCollectionPolicy.shouldPresentDisclosureAgain(
            requested: state.isChoosingLocalScanAgain,
            isAuthenticated: state.isAuthenticated,
            isDemoMode: state.isDemoMode,
            consent: state.localScanConsent
        )
    }

    func testNotNowOnTheReopenedAskTakesItDown() {
        let state = makeSignedInNotNow()
        state.chooseLocalScanAgain()
        XCTAssertTrue(state.isChoosingLocalScanAgain, "Choose again… did not reopen the first ask")
        XCTAssertTrue(presentsAgain(state))

        state.answerLocalScanDisclosure(.notNow, to: .firstAsk)

        XCTAssertFalse(state.isChoosingLocalScanAgain, "the reopened ask stayed up after Not now")
        XCTAssertFalse(presentsAgain(state))
        XCTAssertEqual(state.localScanConsent, .declined)
        XCTAssertEqual(LocalScanConsentStore.load(), .declined)
        XCTAssertEqual(state.localScanConsentV2, .undecided)
    }

    func testChooseAgainDoesNothingWhereSettingsDoesNotOfferIt() {
        let signedOut = makeSignedInNotNow()
        signedOut.isAuthenticated = false
        signedOut.chooseLocalScanAgain()
        XCTAssertFalse(signedOut.isChoosingLocalScanAgain, "signed out was put the question")

        let scanning = makeSignedInNotNow()
        scanning.localScanConsent = .granted
        scanning.chooseLocalScanAgain()
        XCTAssertFalse(scanning.isChoosingLocalScanAgain, "a yes was put the question")
    }
}

#endif

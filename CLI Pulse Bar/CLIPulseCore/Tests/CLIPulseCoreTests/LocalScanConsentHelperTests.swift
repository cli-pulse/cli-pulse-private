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

    /// The defect, stated as a test: "Not now" on a paired Mac. Before 1.55
    /// the helper collected here, and pairing is what turns the helper on.
    func testNotNowPausesAPairedHelper() {
        XCTAssertEqual(
            LocalCollectionPolicy.helperCycle(mirroredConsent: .declined, isPaired: true),
            .paused
        )
    }

    /// The helper asks the app's question, with its pairing standing in for a
    /// sign-in. Every answer, paired and not, against `allowsCollection`: if
    /// the app's rule changes, the helper's changes with it, or this fails.
    func testTheHelperDecidesAsTheAppDoesForEveryAnswer() {
        for consent in LocalScanConsent.allCases {
            for isPaired in [false, true] {
                let expected: LocalCollectionPolicy.HelperCycle =
                    LocalCollectionPolicy.allowsCollection(isAuthenticated: isPaired, consent: consent)
                        ? .collect
                        : .paused
                XCTAssertEqual(
                    LocalCollectionPolicy.helperCycle(mirroredConsent: consent, isPaired: isPaired),
                    expected,
                    "\(consent), paired: \(isPaired)"
                )
            }
        }
    }

    /// The same table spelled out, so a change to `allowsCollection` that the
    /// test above would follow still has to be made here on purpose.
    func testWhoTheHelperCollectsFor() {
        func cycle(_ consent: LocalScanConsent, paired: Bool) -> LocalCollectionPolicy.HelperCycle {
            LocalCollectionPolicy.helperCycle(mirroredConsent: consent, isPaired: paired)
        }
        XCTAssertEqual(cycle(.granted, paired: true), .collect)
        XCTAssertEqual(cycle(.granted, paired: false), .collect, "local mode with a yes: the helper feeds the app")
        XCTAssertEqual(cycle(.undecided, paired: true), .collect, "signed in with no answer: the account stands in")
        XCTAssertEqual(cycle(.undecided, paired: false), .paused, "local mode with no answer reads nothing")
        XCTAssertEqual(cycle(.declined, paired: true), .paused)
        XCTAssertEqual(cycle(.declined, paired: false), .paused)
    }

    /// No copy yet — a helper that starts before the app has run since the
    /// update — is not taken for "no answer", which on a paired Mac collects.
    func testWithoutTheAppsCopyTheHelperReadsNothing() {
        for isPaired in [false, true] {
            XCTAssertEqual(
                LocalCollectionPolicy.helperCycle(mirroredConsent: nil, isPaired: isPaired),
                .awaitingAnswer
            )
        }
    }

    /// In the helper, "is it paired" reads the pairing secret from the
    /// Keychain. Only `.undecided` depends on it, so only `.undecided` asks.
    func testThePairingIsReadOnlyWhenTheAnswerDependsOnIt() {
        var reads = 0
        func isPaired() -> Bool {
            reads += 1
            return true
        }
        let answersThatDoNotDependOnIt: [LocalScanConsent?] = [.declined, .granted, nil]
        for consent in answersThatDoNotDependOnIt {
            reads = 0
            _ = LocalCollectionPolicy.helperCycle(mirroredConsent: consent, isPaired: isPaired())
            XCTAssertEqual(reads, 0, "\(String(describing: consent)) read the pairing")
        }
        reads = 0
        _ = LocalCollectionPolicy.helperCycle(mirroredConsent: .undecided, isPaired: isPaired())
        XCTAssertEqual(reads, 1)
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
            LocalCollectionPolicy.helperCycle(
                mirroredConsent: LocalScanConsentStore.loadMirror(helperDefaults)?.consent,
                isPaired: true
            ),
            .paused,
            "a yes to older logs is not a yes to the scan"
        )
        LocalScanConsentStore.mirror(consent: .undecided, consentV2: .undecided, to: helperDefaults)
        XCTAssertEqual(
            LocalCollectionPolicy.helperCycle(
                mirroredConsent: LocalScanConsentStore.loadMirror(helperDefaults)?.consent,
                isPaired: true
            ),
            .collect
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

    private static let consentKeys = [LocalScanConsentStore.key, LocalScanConsentStore.v2Key]

    override func setUp() {
        super.setUp()
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
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            helperDefaults: helperDefaults,
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
            LocalCollectionPolicy.helperCycle(mirroredConsent: mirrored?.consent, isPaired: true),
            .paused
        )
    }

    /// Where no helper runs (the QA runtime, iOS), there is no app group to
    /// copy to, and nothing is written anywhere.
    func testWithoutAnAppGroupNothingIsCopied() {
        LocalScanConsentStore.save(.declined)
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            helperDefaults: nil,
            performLaunchSetup: false
        )
        state.localScanConsent = .granted
        XCTAssertNil(mirrored)
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

    /// A Mac not set up for this account says so first, as for any status.
    func testNotPairedStillComesFirst() {
        XCTAssertEqual(
            HelperStatusLine.make(status: paused, thisMacPairing: .notSetUp, pairedDeviceId: nil),
            HelperStatusLine(tone: .attention, text: L10n.settings.notPaired, isError: false)
        )
    }

    /// A status from a helper that predates the field decodes, without one;
    /// the field round-trips.
    func testThePauseCodeIsOptionalOnTheWire() throws {
        let legacy = Data(#"{"state":"running","helperVersion":"1.0.0"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(HelperIPC.Status.self, from: legacy).pauseCode)
        let roundTripped = try JSONDecoder().decode(
            HelperIPC.Status.self, from: JSONEncoder().encode(paused)
        )
        XCTAssertEqual(roundTripped.pauseCode, HelperIPC.PauseCode.localScanOff)
    }
}

#endif

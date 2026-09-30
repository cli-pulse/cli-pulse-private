import XCTest
@testable import CLIPulseCore

/// v1.55: Settings › Privacy's Claude keychain switches reach the processes
/// that are not the app. Before, the LoginItem helper's `PrivacySettings`
/// read its own defaults, which nothing writes, so both switches were a no-op
/// in the process the recurring "CLIPulseHelper wants to use Claude
/// Code-credentials" dialog comes from.
final class HelperPrivacyInputsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suites = []
        super.tearDown()
    }

    private func makeDefaults(_ label: String) -> UserDefaults {
        let name = "HelperPrivacyInputsTests-\(label)-\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - The copy

    func testKeysAreTheOnesTheCompanionCLIReads() {
        // helper/privacy_switches.py spells these; a rename here must fail here.
        XCTAssertEqual(HelperPrivacyInputs.skipClaudeKeychainKey, "cli_pulse_privacy_skip_claude_keychain")
        XCTAssertEqual(HelperPrivacyInputs.localOnlyModeKey, "cli_pulse_privacy_local_only_mode")
        XCTAssertEqual(HelperPrivacyInputs.reportKey, "cli_pulse_helper_claude_keychain")
    }

    func testMirrorWritesBothKeysAndReportsAChangeOnce() {
        let group = makeDefaults("group")
        XCTAssertNil(HelperPrivacyInputs.load(group))

        let off = HelperPrivacyInputs(skipClaudeKeychain: false, localOnlyMode: false)
        XCTAssertTrue(HelperPrivacyInputs.mirror(off, to: group), "a first copy is a change")
        // Both are written even when off: missing must mean "the app has not said".
        XCTAssertEqual(group.object(forKey: HelperPrivacyInputs.skipClaudeKeychainKey) as? Bool, false)
        XCTAssertEqual(group.object(forKey: HelperPrivacyInputs.localOnlyModeKey) as? Bool, false)
        XCTAssertEqual(HelperPrivacyInputs.load(group), off)
        XCTAssertFalse(HelperPrivacyInputs.mirror(off, to: group), "the same copy again is not a change")

        let strict = HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: true)
        XCTAssertTrue(HelperPrivacyInputs.mirror(strict, to: group))
        XCTAssertEqual(HelperPrivacyInputs.load(group), strict)
    }

    func testHalfACopyOrAnotherTypeIsNoCopy() {
        let group = makeDefaults("group")
        group.set(true, forKey: HelperPrivacyInputs.skipClaudeKeychainKey)
        XCTAssertNil(HelperPrivacyInputs.load(group), "the app always writes both keys")
        group.set("true", forKey: HelperPrivacyInputs.localOnlyModeKey)
        XCTAssertNil(HelperPrivacyInputs.load(group))
        group.set(false, forKey: HelperPrivacyInputs.localOnlyModeKey)
        XCTAssertEqual(
            HelperPrivacyInputs.load(group),
            HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: false)
        )
    }

    func testDecisionForEverySwitchPosition() {
        XCTAssertEqual(ClaudeKeychainAccess.decide(nil), .skippedAwaitingApp)
        XCTAssertEqual(ClaudeKeychainAccess.decide(HelperPrivacyInputs(skipClaudeKeychain: false, localOnlyMode: false)), .read)
        XCTAssertEqual(ClaudeKeychainAccess.decide(HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: false)), .skippedBySetting)
        XCTAssertEqual(ClaudeKeychainAccess.decide(HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: true)), .skippedStrictPrivacyMode)
        // Strict mode wins even over a copy that says the other switch is off.
        XCTAssertEqual(ClaudeKeychainAccess.decide(HelperPrivacyInputs(skipClaudeKeychain: false, localOnlyMode: true)), .skippedStrictPrivacyMode)
        XCTAssertEqual(ClaudeKeychainAccess.allCases.filter { !$0.skips }, [.read])
    }

    // MARK: - The app writes the copy

    func testTheAppWritesTheCopyAtLaunchAndOnEveryChange() {
        let own = makeDefaults("app")
        let group = makeDefaults("group")
        var notified = 0
        let settings = PrivacySettings(defaults: own)

        settings.mirrorForHelpers(to: group, notify: { notified += 1 })
        XCTAssertEqual(HelperPrivacyInputs.load(group), HelperPrivacyInputs(skipClaudeKeychain: false, localOnlyMode: false),
                       "switches set before 1.55 reach the helpers at the first launch")
        XCTAssertEqual(notified, 1)

        settings.skipClaudeKeychain = true
        XCTAssertEqual(HelperPrivacyInputs.load(group), HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: false))
        XCTAssertEqual(notified, 2)

        settings.localOnlyMode = true
        XCTAssertEqual(HelperPrivacyInputs.load(group), HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: true))
        XCTAssertEqual(notified, 3)

        // Turning Strict mode off leaves the other switch on (as the app does).
        settings.localOnlyMode = false
        XCTAssertEqual(HelperPrivacyInputs.load(group), HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: false))
        XCTAssertEqual(notified, 4)

        // A launch with nothing changed tells nobody.
        let relaunched = PrivacySettings(defaults: own)
        relaunched.mirrorForHelpers(to: group, notify: { notified += 1 })
        XCTAssertEqual(notified, 4)
    }

    func testStrictModeFromOffWritesTheForcedSwitchToo() {
        let group = makeDefaults("group")
        let settings = PrivacySettings(defaults: makeDefaults("app"))
        settings.mirrorForHelpers(to: group)
        settings.localOnlyMode = true
        XCTAssertEqual(HelperPrivacyInputs.load(group), HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: true))
    }

    func testWithoutTheWriterAHelperSeesNothing() {
        // Negative control: the pre-1.55 behaviour. The switch is saved only
        // in the app's own defaults, and the app group holds no copy.
        let group = makeDefaults("group")
        let settings = PrivacySettings(defaults: makeDefaults("app"))
        settings.localOnlyMode = true
        XCTAssertNil(HelperPrivacyInputs.load(group))
    }

    #if os(macOS)
    func testOnlyARuntimeThatRegistersTheHelperWritesTheCopy() {
        let quarantine = CLIPulseRuntimeEnvironment.resolveForTesting(
            infoDictionary: ["CFBundleIdentifier": "com.example.clipulse"],
            environment: [:]
        )
        XCTAssertFalse(quarantine.capabilities.allowsHelperRegistration)
        let group = makeDefaults("group")
        var notified = false
        PrivacySettings(defaults: makeDefaults("app"))
            .mirrorForHelpers(in: quarantine, helperDefaults: group, notify: { notified = true })
        XCTAssertNil(HelperPrivacyInputs.load(group))
        XCTAssertFalse(notified)

        let production = TestRuntimeFixtures.productionApp
        XCTAssertTrue(production.capabilities.allowsHelperRegistration)
        PrivacySettings(defaults: makeDefaults("app"))
            .mirrorForHelpers(in: production, helperDefaults: group, notify: { notified = true })
        XCTAssertNotNil(HelperPrivacyInputs.load(group))
        XCTAssertTrue(notified)
    }
    #endif

    // MARK: - The helper reads it

    func testTheHelperFollowsTheAppsCopyNotItsOwnDefaults() {
        let helperOwn = makeDefaults("helper")
        let group = makeDefaults("group")
        // The helper's own defaults: nothing the user set. Before 1.55 this is
        // what its collectors asked, so both switches read as off there.
        let helper = PrivacySettings(defaults: helperOwn)
        XCTAssertFalse(helper.skipsClaudeKeychainOnItsOwn, "negative control: its own defaults say read")

        helper.followAppCopy(in: group)
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: false), to: group)
        XCTAssertEqual(helper.claudeKeychainAccess, .skippedBySetting)
        XCTAssertTrue(helper.skipsClaudeKeychainOnItsOwn)

        // Read afresh at every decision: the app changes it while this runs.
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: true), to: group)
        XCTAssertEqual(helper.claudeKeychainAccess, .skippedStrictPrivacyMode)
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: false, localOnlyMode: false), to: group)
        XCTAssertEqual(helper.claudeKeychainAccess, .read)
        XCTAssertFalse(helper.skipsClaudeKeychainOnItsOwn)
    }

    func testTheHelperIgnoresItsOwnDefaultsOnceItFollowsTheApp() {
        let helperOwn = makeDefaults("helper")
        helperOwn.set(true, forKey: "privacy.skipClaudeKeychain")
        let group = makeDefaults("group")
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: false, localOnlyMode: false), to: group)
        let helper = PrivacySettings(defaults: helperOwn)
        helper.followAppCopy(in: group)
        XCTAssertEqual(helper.claudeKeychainAccess, .read, "the app's copy is the only source in the helper")
    }

    func testTheHelperSkipsUntilTheAppHasWrittenACopy() {
        let group = makeDefaults("group")
        let helper = PrivacySettings(defaults: makeDefaults("helper"))
        helper.followAppCopy(in: group)
        XCTAssertEqual(helper.claudeKeychainAccess, .skippedAwaitingApp)
        XCTAssertTrue(helper.skipsClaudeKeychainOnItsOwn)

        let noSuite = PrivacySettings(defaults: makeDefaults("helper"))
        noSuite.followAppCopy(in: nil)
        XCTAssertEqual(noSuite.claudeKeychainAccess, .skippedAwaitingApp)
    }

    func testTheAppDecidesFromItsOwnSwitches() {
        let settings = PrivacySettings(defaults: makeDefaults("app"))
        XCTAssertEqual(settings.claudeKeychainAccess, .read)
        settings.skipClaudeKeychain = true
        XCTAssertEqual(settings.claudeKeychainAccess, .skippedBySetting)
        settings.localOnlyMode = true
        XCTAssertEqual(settings.claudeKeychainAccess, .skippedStrictPrivacyMode)
        XCTAssertTrue(settings.skipsClaudeKeychainOnItsOwn)
    }

    // MARK: - What the helper reports, and what Settings says

    func testReportRoundTripsAndAnUnknownTokenIsNoReport() {
        let group = makeDefaults("group")
        XCTAssertNil(HelperPrivacyInputs.loadHelperReport(group))
        XCTAssertTrue(HelperPrivacyInputs.recordHelperReport(.skippedStrictPrivacyMode, to: group))
        XCTAssertFalse(HelperPrivacyInputs.recordHelperReport(.skippedStrictPrivacyMode, to: group))
        XCTAssertEqual(HelperPrivacyInputs.loadHelperReport(group), .skippedStrictPrivacyMode)
        group.set("skipped_by_a_future_reason", forKey: HelperPrivacyInputs.reportKey)
        XCTAssertNil(HelperPrivacyInputs.loadHelperReport(group))
    }

    func testSettingsSaysTheHelperFollowsOnlyWhenItSaidSo() {
        let running = HelperIPC.Status(state: .running)
        let idle = HelperIPC.Status(state: .idle)
        typealias C = HelperClaudeKeychainConfirmation

        // Nothing to say: switches off, or no helper running.
        XCTAssertNil(C.make(appSkips: false, helperStatus: running, helperReport: .skippedBySetting))
        XCTAssertNil(C.make(appSkips: true, helperStatus: nil, helperReport: .skippedBySetting))
        XCTAssertNil(C.make(appSkips: true, helperStatus: idle, helperReport: .skippedBySetting))

        XCTAssertEqual(C.make(appSkips: true, helperStatus: running, helperReport: .skippedBySetting), .confirmed)
        XCTAssertEqual(C.make(appSkips: true, helperStatus: running, helperReport: .skippedStrictPrivacyMode), .confirmed)
        // A helper from before 1.55 writes no report; one that has not
        // collected since the switch changed still says read.
        XCTAssertEqual(C.make(appSkips: true, helperStatus: running, helperReport: nil), .notConfirmed)
        XCTAssertEqual(C.make(appSkips: true, helperStatus: running, helperReport: .read), .notConfirmed)
        XCTAssertEqual(C.make(appSkips: true, helperStatus: running, helperReport: .skippedAwaitingApp), .notConfirmed)
        XCTAssertEqual(
            C.make(appSkips: true, helperStatus: HelperIPC.Status(state: .error), helperReport: .skippedBySetting),
            .confirmed
        )
    }

    func testTheNotificationIsTheOneTheHelperObserves() {
        // PR #626's `HelperIPC.helperInputsDidChangeNotificationName`, which
        // the LoginItem helper runs a cycle on.
        XCTAssertEqual(HelperInputs.didChangeNotificationName.rawValue, "CLIPulseHelperInputsDidChange")
    }
}

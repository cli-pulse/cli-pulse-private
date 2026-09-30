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
        HelperPrivacyInputs.recordHelperReport(.skippedBySetting, to: group)
        var notified = false
        var requested = 0
        PrivacySettings(defaults: makeDefaults("app"))
            .mirrorForHelpers(
                in: quarantine, helperDefaults: group,
                notify: { notified = true }, requestReport: { requested += 1 }
            )
        XCTAssertNil(HelperPrivacyInputs.load(group))
        XCTAssertFalse(notified)
        XCTAssertEqual(requested, 0)
        XCTAssertEqual(HelperPrivacyInputs.loadHelperReport(group), .skippedBySetting, "nothing written, nothing removed")

        let production = TestRuntimeFixtures.productionApp
        XCTAssertTrue(production.capabilities.allowsHelperRegistration)
        PrivacySettings(defaults: makeDefaults("app"))
            .mirrorForHelpers(
                in: production, helperDefaults: group,
                notify: { notified = true }, requestReport: { requested += 1 }
            )
        XCTAssertNotNil(HelperPrivacyInputs.load(group))
        XCTAssertTrue(notified)
        XCTAssertEqual(requested, 1)
    }

    func testALaunchReplacesTheLastReportWithOneFromTheRunningHelper() {
        // A report an earlier 1.55 helper left (before a downgrade and an
        // in-place upgrade, say) is not this launch's helper speaking. The
        // launch removes it and asks; a helper from before 1.55 never answers,
        // so Settings says it has not confirmed, which is true.
        let group = makeDefaults("group")
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: false), to: group)
        HelperPrivacyInputs.recordHelperReport(.skippedBySetting, to: group)
        let app = PrivacySettings(defaults: makeDefaults("app"))
        app.skipClaudeKeychain = true
        var requested = 0
        app.mirrorForHelpers(
            in: TestRuntimeFixtures.productionApp, helperDefaults: group,
            notify: {}, requestReport: {
                requested += 1
                // The report is already gone when the helper is asked.
                XCTAssertNil(HelperPrivacyInputs.loadHelperReport(group))
            }
        )
        XCTAssertEqual(requested, 1)
        XCTAssertNil(HelperPrivacyInputs.loadHelperReport(group))
        let running = HelperIPC.Status(state: .running)
        XCTAssertEqual(
            HelperClaudeKeychainConfirmation.make(
                appSkips: app.skipsClaudeKeychainOnItsOwn, helperStatus: running,
                helperReport: HelperPrivacyInputs.loadHelperReport(group)
            ),
            .notConfirmed,
            "an old helper that never answers is not shown as following the switch"
        )

        // A 1.55+ helper answers the request from the copy.
        let helper = PrivacySettings(defaults: makeDefaults("helper"))
        helper.followAppCopy(in: group)
        HelperPrivacyInputs.recordHelperReport(helper.claudeKeychainAccess, to: group)
        XCTAssertEqual(
            HelperClaudeKeychainConfirmation.make(
                appSkips: app.skipsClaudeKeychainOnItsOwn, helperStatus: running,
                helperReport: HelperPrivacyInputs.loadHelperReport(group)
            ),
            .confirmed
        )
    }
    #endif

    // MARK: - The one guarded read of Claude Code's keychain item

    private static let keychainCreds = ClaudeCredentials.Creds(accessToken: "sk-ant-oat01-KC", rateLimitTier: "max")

    func testTheGuardedReadNeverCallsTheReaderWhileTheAppsSwitchesSaySkip() {
        let app = PrivacySettings(defaults: makeDefaults("app"))
        var reads = 0
        let reader: () -> ClaudeCredentials.Creds? = {
            reads += 1
            return Self.keychainCreds
        }

        // Negative control: both off, and the item is read.
        XCTAssertEqual(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: app, reader: reader)?.accessToken,
                       "sk-ant-oat01-KC")
        XCTAssertEqual(reads, 1)

        app.skipClaudeKeychain = true
        XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: app, reader: reader))
        app.localOnlyMode = true
        XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: app, reader: reader))
        // Strict mode off leaves "Skip" on, as the app does.
        app.localOnlyMode = false
        XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: app, reader: reader))
        XCTAssertEqual(reads, 1, "the reader ran while a switch said skip")

        app.skipClaudeKeychain = false
        XCTAssertNotNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: app, reader: reader))
        XCTAssertEqual(reads, 2)
    }

    func testTheGuardedReadInTheHelperFollowsTheAppsCopy() {
        let group = makeDefaults("group")
        // The helper's own defaults say read; only the app's copy counts there.
        let helper = PrivacySettings(defaults: makeDefaults("helper"))
        helper.followAppCopy(in: group)
        var reads = 0
        let reader: () -> ClaudeCredentials.Creds? = {
            reads += 1
            return Self.keychainCreds
        }

        // No copy yet: skipped until the app writes one.
        XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: helper, reader: reader))
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: false), to: group)
        XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: helper, reader: reader))
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: true), to: group)
        XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: helper, reader: reader))
        XCTAssertEqual(reads, 0, "the reader ran while the app's copy said skip")

        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: false, localOnlyMode: false), to: group)
        XCTAssertEqual(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: helper, reader: reader)?.rateLimitTier,
                       "max")
        XCTAssertEqual(reads, 1)
    }

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

    func testTheNotificationsAreTheOnesTheHelperAndTheAppObserve() {
        // PR #626's `HelperIPC.helperInputsDidChangeNotificationName`, which
        // its LoginItem helper runs a cycle on; this one's reports on it.
        XCTAssertEqual(HelperInputs.didChangeNotificationName.rawValue, "CLIPulseHelperInputsDidChange")
        // The app asks at launch; the helper says it answered. Two processes,
        // built from one source, but an old helper keeps running after an
        // update, so a rename is a protocol change.
        XCTAssertEqual(HelperPrivacyInputs.reportRequestNotificationName.rawValue,
                       "CLIPulseHelperClaudeKeychainReportRequested")
        XCTAssertEqual(HelperPrivacyInputs.didReportNotificationName.rawValue,
                       "CLIPulseHelperDidReportClaudeKeychain")
    }

    func testClearingTheReportLeavesTheCopy() {
        let group = makeDefaults("group")
        let copy = HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: false)
        HelperPrivacyInputs.mirror(copy, to: group)
        HelperPrivacyInputs.recordHelperReport(.skippedBySetting, to: group)
        HelperPrivacyInputs.clearHelperReport(group)
        XCTAssertNil(HelperPrivacyInputs.loadHelperReport(group))
        XCTAssertEqual(HelperPrivacyInputs.load(group), copy)
        // The next report after a clear counts as a change, so the helper logs it.
        XCTAssertTrue(HelperPrivacyInputs.recordHelperReport(.skippedBySetting, to: group))
    }
}

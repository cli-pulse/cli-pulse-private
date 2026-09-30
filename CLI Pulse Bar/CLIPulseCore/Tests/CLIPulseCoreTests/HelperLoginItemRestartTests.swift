import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Restarting the background-sync LoginItem once after each update
/// (`HelperLoginItemRestart`). macOS leaves the old binary running after an
/// in-place update, and one from before 1.55 honours no local-scan answer.
final class HelperLoginItemRestartTests: XCTestCase {

    private struct RegisterFailed: Error {}

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.clipulse.tests.login-item-restart.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A stand-in for `SMAppService.loginItem`.
    private final class FakeLoginItem {
        var enabled: Bool
        var registerFails = false
        var calls: [String] = []

        init(enabled: Bool) { self.enabled = enabled }

        var service: HelperLoginItemRestart.Service {
            HelperLoginItemRestart.Service(
                isEnabled: { self.enabled },
                unregister: {
                    self.calls.append("unregister")
                    self.enabled = false
                },
                register: {
                    self.calls.append("register")
                    if self.registerFails { throw RegisterFailed() }
                    self.enabled = true
                }
            )
        }
    }

    func testTheDecision() {
        typealias R = HelperLoginItemRestart
        XCTAssertEqual(R.action(isEnabled: true, currentBuild: "107", restartedForBuild: nil, pendingBuild: nil), .restart,
                       "the first launch of a build restarts a running helper")
        XCTAssertEqual(R.action(isEnabled: true, currentBuild: "107", restartedForBuild: "106", pendingBuild: nil), .restart)
        XCTAssertEqual(R.action(isEnabled: true, currentBuild: "107", restartedForBuild: "107", pendingBuild: nil), .none,
                       "once per build")
        XCTAssertEqual(R.action(isEnabled: false, currentBuild: "107", restartedForBuild: nil, pendingBuild: nil), .none,
                       "a helper the user turned off stays off")
        XCTAssertEqual(R.action(isEnabled: true, currentBuild: nil, restartedForBuild: nil, pendingBuild: nil), .none)
        XCTAssertEqual(R.action(isEnabled: false, currentBuild: "107", restartedForBuild: "106", pendingBuild: "107"), .reRegister,
                       "a restart cut off between its halves turns the helper back on")
    }

    func testAnUpdateRestartsTheHelperOnce() async {
        let item = FakeLoginItem(enabled: true)
        let first = await HelperLoginItemRestart.runIfNeeded(service: item.service, defaults: defaults, currentBuild: "107")
        XCTAssertEqual(first, .restarted)
        XCTAssertEqual(item.calls, ["unregister", "register"])
        XCTAssertTrue(item.enabled)
        XCTAssertEqual(defaults.string(forKey: HelperLoginItemRestart.restartedForBuildKey), "107")
        XCTAssertNil(defaults.string(forKey: HelperLoginItemRestart.pendingBuildKey))

        let second = await HelperLoginItemRestart.runIfNeeded(service: item.service, defaults: defaults, currentBuild: "107")
        XCTAssertEqual(second, .notNeeded)
        XCTAssertEqual(item.calls, ["unregister", "register"], "a relaunch of the same build restarted it again")

        let next = await HelperLoginItemRestart.runIfNeeded(service: item.service, defaults: defaults, currentBuild: "108")
        XCTAssertEqual(next, .restarted)
    }

    func testAHelperTurnedOffIsLeftOff() async {
        let item = FakeLoginItem(enabled: false)
        let outcome = await HelperLoginItemRestart.runIfNeeded(service: item.service, defaults: defaults, currentBuild: "107")
        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertEqual(item.calls, [])
    }

    /// If the register half fails, background sync is off because of the app.
    /// The build is not recorded, and the next launch turns it back on.
    func testAFailedRestartIsRepairedOnTheNextLaunch() async {
        let item = FakeLoginItem(enabled: true)
        item.registerFails = true
        let failed = await HelperLoginItemRestart.runIfNeeded(service: item.service, defaults: defaults, currentBuild: "107")
        XCTAssertEqual(failed, .failed)
        XCTAssertFalse(item.enabled)
        XCTAssertNil(defaults.string(forKey: HelperLoginItemRestart.restartedForBuildKey))
        XCTAssertEqual(defaults.string(forKey: HelperLoginItemRestart.pendingBuildKey), "107")

        item.registerFails = false
        item.calls = []
        let repaired = await HelperLoginItemRestart.runIfNeeded(service: item.service, defaults: defaults, currentBuild: "107")
        XCTAssertEqual(repaired, .reRegistered)
        XCTAssertEqual(item.calls, ["register"])
        XCTAssertTrue(item.enabled)
        XCTAssertEqual(defaults.string(forKey: HelperLoginItemRestart.restartedForBuildKey), "107")
        XCTAssertNil(defaults.string(forKey: HelperLoginItemRestart.pendingBuildKey))
    }

    /// The keys live in the app's standard defaults, so they carry the prefix
    /// every key there needs (`UnsandboxedDataMigration.appOwnedKeyPrefixes`).
    func testTheKeysCarryTheAppPrefix() {
        for key in [HelperLoginItemRestart.restartedForBuildKey, HelperLoginItemRestart.pendingBuildKey] {
            XCTAssertTrue(
                UnsandboxedDataMigration.appOwnedKeyPrefixes.contains { key.hasPrefix($0) }, key
            )
        }
    }
}

#endif

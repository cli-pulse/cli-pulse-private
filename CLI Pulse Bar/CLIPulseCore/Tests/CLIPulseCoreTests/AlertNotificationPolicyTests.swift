import XCTest
@testable import CLIPulseCore

/// The "Session quota notifications" setting had no reader until 2026-08-31:
/// the toggle rendered and persisted while the dispatch consulted only the
/// master switch, so turning it off changed nothing and the only way to stop
/// quota banners was to silence every notification.
final class AlertNotificationPolicyTests: XCTestCase {

    private func notify(_ type: String, master: Bool, quota: Bool) -> Bool {
        AlertNotificationPolicy.shouldNotify(
            alertType: type,
            notificationsEnabled: master,
            sessionQuotaNotificationsEnabled: quota
        )
    }

    /// The bug, stated as a test: quota OFF must actually silence quota alerts.
    func test_quotaOffSilencesQuotaAlerts() {
        XCTAssertFalse(notify(AlertNotificationPolicy.quotaWarningType, master: true, quota: false))
    }

    /// …and must silence ONLY those. Without this, "fixing" it by returning
    /// false everywhere would pass the test above.
    func test_quotaOffLeavesEveryOtherAlertAlone() {
        for other in ["Rate Limit", "Error Spike", "Unusual Activity", ""] {
            XCTAssertTrue(notify(other, master: true, quota: false),
                          "\(other) is not a quota alert and must still notify")
        }
    }

    /// The master switch stays a hard gate — the quota switch cannot re-enable
    /// what it blocked.
    func test_masterOffSilencesEverythingIncludingQuota() {
        XCTAssertFalse(notify(AlertNotificationPolicy.quotaWarningType, master: false, quota: true))
        XCTAssertFalse(notify("Rate Limit", master: false, quota: true))
    }

    /// Both on = the default posture; nothing is silenced.
    func test_bothOnNotifiesEverything() {
        XCTAssertTrue(notify(AlertNotificationPolicy.quotaWarningType, master: true, quota: true))
        XCTAssertTrue(notify("Rate Limit", master: true, quota: true))
    }

    /// DRIFT GUARD. The policy's type string is duplicated from
    /// `AlertGenerator`'s payload literal because they live in different
    /// modules. If either side is renamed, the filter silently stops matching
    /// and the setting goes back to doing nothing — the exact failure this
    /// whole file exists to prevent, returning without a symptom.
    func test_theQuotaTypeMatchesWhatTheGeneratorEmits() throws {
        let generator = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .appendingPathComponent("Sources/CLIPulseCore/AlertGenerator.swift")
        let text = try String(contentsOf: generator, encoding: .utf8)

        XCTAssertTrue(
            text.contains("\"type\": \"\(AlertNotificationPolicy.quotaWarningType)\""),
            "AlertGenerator no longer emits \"\(AlertNotificationPolicy.quotaWarningType)\" — "
            + "the per-type filter would silently stop matching"
        )
        // Positive control: a wrong path would make the assertion above vacuous.
        XCTAssertTrue(text.contains("grouping_key"), "not AlertGenerator.swift — scan path is wrong")
    }

    // MARK: - Where the authorization prompt is triggered

    /// Companion bug to the one above, found the same day and worse: the only
    /// production caller of `requestNotificationPermission()` was
    /// `setRemoteControlEnabled(true)`. Remote Control gates machine controls
    /// and pushes nothing; alerts push and default to ON. A user who never
    /// touched that switch was never asked, so every alert notification was
    /// dropped by the system — with `notificationsEnabled` reading `true` in
    /// Settings the whole time.
    func test_shouldRequestAuthorization_requiresBothSignInAndTheMasterSwitch() {
        let ask = AlertNotificationPolicy.shouldRequestAuthorization

        XCTAssertTrue(ask(true, true), "signed in with alerts on is the whole point")

        // iter8 hotfix, restated as a test: prompting before sign-in put
        // "Session expired" on the login screen.
        XCTAssertFalse(ask(false, true), "must never prompt an unauthenticated user")

        // iOS shows the dialog once, ever. Asking a user who has silenced
        // notifications spends it on a request we could not honour, and they
        // can then never be asked again after re-enabling.
        XCTAssertFalse(ask(true, false), "must not spend the one-time dialog while alerts are off")
        XCTAssertFalse(ask(false, false))
    }

    /// Source-level because the trigger IS a call site, and a call site that
    /// silently stops existing is exactly the defect being fixed. The unit
    /// test above would stay green with nothing wired to it.
    func test_bothAlertsTabsAskForAuthorizationOnAppear() throws {
        for (dir, file) in [("CLI Pulse Bar", "AlertsTab.swift"),
                            ("CLI Pulse Bar iOS", "iOSAlertsTab.swift")] {
            let url = Self.appSourceRoot.appendingPathComponent("\(dir)/\(file)")
            let text = try String(contentsOf: url, encoding: .utf8)

            // Positive control: a wrong path makes every assertion vacuous.
            XCTAssertTrue(text.contains("struct"), "\(file): scan path is wrong")
            XCTAssertTrue(text.contains("alertState.alerts"), "\(file): not an alerts tab")

            XCTAssertTrue(
                Self.codeOnly(text).contains("state.alertsTabDidAppear()"),
                "\(file) no longer asks for notification authorization. Alert "
                + "notifications will be silently dropped for anyone who has "
                + "not already granted it."
            )
        }
    }

    /// The other half: the prompt must not drift back onto the Remote Control
    /// switch. Scanned comment-free — the file now carries several paragraphs
    /// explaining this decision, and every one of them contains the symbol.
    func test_theRemoteControlToggleNoLongerAsksForNotificationPermission() throws {
        let url = Self.coreRoot
            .appendingPathComponent("Sources/CLIPulseCore/DataRefreshManager.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("func setRemoteControlEnabled"), "scan path is wrong")

        let code = Self.codeOnly(text)
        // Negative control for the stripper itself: if it silently returned
        // "" every assertion below would pass for the wrong reason.
        XCTAssertTrue(code.contains("func setRemoteControlEnabled"), "comment stripper ate the code")

        let sites = code.components(separatedBy: "requestNotificationPermission").count - 1
        XCTAssertEqual(
            sites, 2,
            "Expected exactly two code references: the declaration and the single "
            + "call from alertsTabDidAppear(). Found \(sites). If you added a "
            + "deliberate new trigger, update this test and record why — the last "
            + "trigger outlived its feature by three months and cost every user "
            + "their alert notifications."
        )
    }

    /// The `CLIPulseCore` package root — three levels up, matching the
    /// existing generator-drift test above.
    private static var coreRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
    }

    /// One further up: the `CLI Pulse Bar/` directory holding both app targets
    /// *and* `CLIPulseCore`. Getting this off by one is why every scan here
    /// carries a positive control — the first version of this test read three
    /// levels and failed with "no such file", not with a wrong verdict.
    private static var appSourceRoot: URL {
        coreRoot.deletingLastPathComponent()
    }

    /// Drop whole-line comments. Blocking on a symbol that appears only inside
    /// the comment explaining its own removal is a mistake already made once.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

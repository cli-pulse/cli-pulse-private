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
}

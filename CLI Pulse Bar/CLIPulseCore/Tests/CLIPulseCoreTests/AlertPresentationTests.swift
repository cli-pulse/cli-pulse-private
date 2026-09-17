#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// `AlertPresentation` recovers an alert's parameters by matching the English
/// template that produced it. That only stays correct while the templates and
/// the matchers agree, and the failure is silent — an edited template stops
/// matching and the row quietly reverts to English in every locale.
///
/// So the primary test here does NOT hand-write alert fixtures. It runs the
/// REAL `AlertGenerator` and asserts every alert it emits is recognized. Edit a
/// template in AlertGenerator.swift and this file goes red.
///
/// The two producers that are not Swift get pinned fixtures instead, each
/// naming the source line it was copied from, because their generators cannot
/// be executed from this test bundle:
///   helper/system_collector.py:391, :410, :439
///   cli-pulse-desktop src-tauri/src/alerts.rs:101, :103, :131, :133, :168
final class AlertPresentationTests: XCTestCase {

    private func withChinese(_ body: () -> Void) {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set("zh-Hans")
        defer { store.set(previous) }
        body()
    }

    private func record(id: String, type: String, title: String, message: String,
                        provider: String? = nil) -> AlertRecord {
        AlertRecord(
            id: id, type: type, severity: "Warning", title: title, message: message,
            created_at: "2026-09-16T10:00:00Z", is_read: false, is_resolved: false,
            acknowledged_at: nil, snoozed_until: nil,
            related_project_id: nil, related_project_name: nil,
            related_session_id: nil, related_session_name: nil,
            related_provider: provider, related_device_name: nil,
            source_kind: nil, source_id: nil, grouping_key: nil, suppression_key: nil)
    }

    // MARK: - Round trip against the real generator

    /// Every alert the Swift generator can emit must be recognized. This is the
    /// guard against template drift.
    func testEveryAlertTheSwiftGeneratorEmitsIsRecognized() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 91, memoryUsage: 40)
        let busy = SessionRecord(
            id: "s1", name: "api-gateway", provider: "Claude", project: "acme",
            device_name: "Mac", started_at: "2026-09-16T09:00:00Z",
            last_active_at: "2026-09-16T10:00:00Z", status: "active",
            total_usage: 100, estimated_cost: 0.01, cost_status: "normal",
            requests: 500, error_count: 0)

        let cores = Double(max(ProcessInfo.processInfo.processorCount, 1)) * 100
        let dicts = AlertGenerator.generate(
            device: snap, sessions: [busy],
            sessionCPU: ["s1": cores * 0.9], deviceID: "mac-1")

        // Device CPU + session CPU + session-too-long.
        XCTAssertEqual(dicts.count, 3, "the generator stopped emitting all three rules: \(dicts)")

        for dict in dicts {
            let alert = try? XCTUnwrap(AlertGenerator.makeAlertRecord(from: dict))
            guard let alert else { continue }
            let shown = AlertPresentation.text(for: alert)
            XCTAssertTrue(
                shown.recognized,
                """
                AlertPresentation no longer recognizes an alert AlertGenerator emits.
                A template was edited without updating the matcher, so this alert now
                renders English in every locale.
                  type:    \(alert.type)
                  id:      \(alert.id)
                  title:   \(alert.title)
                  message: \(alert.message)
                """)
        }
    }

    func testEveryQuotaAlertTheGeneratorEmitsIsRecognized() {
        let provider = ProviderUsage(
            provider: "Claude", today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "normal", cost_status_week: "normal",
            quota: nil, remaining: nil,
            tiers: [TierDTO(name: "Weekly", quota: 100, remaining: 5)],
            status_text: "Operational",
            trend: [], recent_sessions: [], recent_errors: [])

        let dicts = AlertGenerator.evaluateQuotaAlerts(providers: [provider], thresholds: [80, 95])
        XCTAssertFalse(dicts.isEmpty, "no quota alert fired, so this proves nothing")
        for dict in dicts {
            guard let alert = AlertGenerator.makeAlertRecord(from: dict) else {
                XCTFail("quota alert did not decode"); continue
            }
            XCTAssertTrue(AlertPresentation.text(for: alert).recognized,
                          "quota template drifted: \(alert.title) / \(alert.message)")
        }
    }

    // MARK: - The producers this bundle cannot execute

    /// helper/system_collector.py:391, :410, :439
    func testPythonHelperTemplatesAreRecognized() {
        let cases = [
            record(id: "cpu-spike-mac-1", type: "Usage Spike",
                   title: "Device CPU usage is elevated",
                   message: "helper sampled CPU usage at 91%."),
            record(id: "session-spike-s1", type: "Usage Spike",
                   title: "api-gateway is consuming high CPU",
                   message: "Process CPU is 184.5% for Claude."),
            record(id: "session-long-s1", type: "Session Too Long",
                   title: "api-gateway has been running for a long time",
                   message: "Long-running local agent session detected by helper."),
        ]
        for c in cases {
            XCTAssertTrue(AlertPresentation.text(for: c).recognized,
                          "Python helper template unrecognized: \(c.message)")
        }
    }

    /// cli-pulse-desktop src-tauri/src/alerts.rs:101/:103, :131/:133, :168
    func testDesktopTemplatesAreRecognized() {
        let cases = [
            record(id: "session-spike-s1", type: "Usage Spike",
                   title: "api-gateway is consuming high CPU",
                   message: "Process CPU is 184.5% for Claude in acme."),
            record(id: "budget-daily-2026-09-16", type: "Daily Budget Exceeded",
                   title: "Daily budget exceeded — $12.34",
                   message: "Today's spend of $12.34 is above your daily budget of $10.00."),
            record(id: "budget-weekly-2026-W38", type: "Weekly Budget Exceeded",
                   title: "Weekly budget exceeded — $88.20",
                   message: "Last 7 days of spend totals $88.20, above your weekly budget of $50.00."),
        ]
        for c in cases {
            XCTAssertTrue(AlertPresentation.text(for: c).recognized,
                          "desktop template unrecognized: \(c.message)")
        }
    }

    /// The desktop's session-CPU line is the Python one plus " in <project>".
    /// Matched in the wrong order, Python's greedy capture swallows the project
    /// into the provider and the row reads "for Claude in acme" as a provider
    /// name. Ordering is load-bearing, so it gets its own assertion.
    func testTheDesktopProcessLineIsNotParsedAsThePythonOne() {
        withChinese {
            let desktop = record(id: "session-spike-s1", type: "Usage Spike",
                                 title: "api-gateway is consuming high CPU",
                                 message: "Process CPU is 184.5% for Claude in acme.")
            let shown = AlertPresentation.text(for: desktop)
            XCTAssertTrue(shown.recognized)
            XCTAssertTrue(shown.message.contains("acme"), "the project was lost: \(shown.message)")
            XCTAssertFalse(shown.message.contains("Claude in acme"),
                           "the project was swallowed into the provider: \(shown.message)")
        }
    }

    // MARK: - Localization

    func testRecognizedAlertsRenderInTheActiveLanguage() {
        withChinese {
            let a = record(id: "cpu-spike-mac-1", type: "Usage Spike",
                           title: "Device CPU usage is elevated",
                           message: "helper sampled CPU usage at 91%.")
            let shown = AlertPresentation.text(for: a)
            XCTAssertNotEqual(shown.title, a.title, "title still English under zh-Hans")
            XCTAssertNotEqual(shown.message, a.message, "message still English under zh-Hans")
            XCTAssertTrue(shown.message.contains("91"), "the sampled value was lost: \(shown.message)")
            XCTAssertFalse(shown.message.contains("%@"), "an unfilled specifier leaked: \(shown.message)")
            XCTAssertFalse(shown.message.contains("$@"), "a positional specifier leaked: \(shown.message)")
        }
    }

    func testSeverityAndSourceLabelsAreLocalizedAndUnknownValuesPassThrough() {
        withChinese {
            for raw in ["Critical", "Warning", "Info"] {
                XCTAssertNotEqual(AlertPresentation.severityLabel(raw), raw, "\(raw) still English")
            }
            for raw in ["device", "session", "quota", "budget", "provider", "project", "swarm"] {
                XCTAssertNotEqual(AlertPresentation.sourceKindLabel(raw), raw, "\(raw) still English")
            }
            XCTAssertEqual(AlertPresentation.severityLabel("Catastrophic"), "Catastrophic")
            XCTAssertEqual(AlertPresentation.sourceKindLabel("meteor"), "meteor")
        }
    }

    // MARK: - Everything else must degrade to the stored English

    /// Retired kinds, demo rows and anything a newer client invents must render
    /// their stored text rather than a wrong translation.
    func testUnrecognizedAlertsRenderTheirStoredEnglishUnchanged() {
        withChinese {
            let cases = [
                record(id: "a1", type: "Quota Critical", title: "Claude quota almost gone",
                       message: "You have used 96% of your weekly quota."),
                record(id: "swarm-1", type: "Swarm Agent Blocked", title: "Agent blocked",
                       message: "An agent is waiting for input."),
                record(id: "future-1", type: "Something New", title: "A kind from a newer client",
                       message: "Written by a version this one has never seen."),
                // Right kind, drifted template — the exact silent-failure case.
                record(id: "cpu-spike-mac-1", type: "Usage Spike",
                       title: "Device CPU usage is elevated",
                       message: "helper measured CPU at 91 percent."),
            ]
            for c in cases {
                let shown = AlertPresentation.text(for: c)
                XCTAssertFalse(shown.recognized, "unexpectedly matched: \(c.message)")
                XCTAssertEqual(shown.title, c.title)
                XCTAssertEqual(shown.message, c.message)
            }
        }
    }

    /// The quota alert's tier name goes through the same display mapper the
    /// provider cards use, so one window reads the same wherever it appears —
    /// while the STORED name stays English, because it is the suppression key.
    func testQuotaAlertUsesTheSharedTierMapperAndLeavesTheRecordAlone() {
        withChinese {
            let a = record(id: "quota-Claude-Weekly-80", type: "Quota Warning",
                           title: "Claude Weekly at 85%",
                           message: "Quota window 'Weekly' is 85% used (15% remaining).",
                           provider: "Claude")
            let shown = AlertPresentation.text(for: a)
            XCTAssertTrue(shown.recognized)
            let tier = L10n.quotaTier.localized("Weekly")
            XCTAssertNotEqual(tier, "Weekly", "zh-Hans override is not in effect")
            XCTAssertTrue(shown.message.contains(tier), "tier not localized: \(shown.message)")
            XCTAssertTrue(shown.title.contains("Claude"), "provider lost: \(shown.title)")
            XCTAssertEqual(a.id, "quota-Claude-Weekly-80", "the record was mutated")
            XCTAssertEqual(a.message, "Quota window 'Weekly' is 85% used (15% remaining).")
        }
    }

    /// The reset used to reach the sentence as the stored UTC timestamp:
    /// "配额窗口「5 小时窗口」已使用 96%（剩余 4%，2026-09-16T14:00:00Z 重置）。"
    /// It is shown as a local date and time now, while the record keeps the ISO.
    func testQuotaAlertShowsTheResetAsALocalDateAndTime() {
        withChinese {
            let message = "Quota window '5h Window' is 96% used (4% remaining) (resets 2026-09-16T14:00:00.000Z)."
            let a = record(id: "quota-Codex-5h Window-95", type: "Quota Warning",
                           title: "Codex 5h Window at 96%", message: message, provider: "Codex")
            let shown = AlertPresentation.text(for: a)
            XCTAssertTrue(shown.recognized)
            XCTAssertFalse(shown.message.contains("2026-09-16T14"), "raw timestamp shown: \(shown.message)")
            let reset = ISO8601DateFormatter().date(from: "2026-09-16T14:00:00Z")!
            let local = DisplayFormat.dateTime(reset)
            XCTAssertTrue(local.contains("9月16日") || local.contains("9月17日"),
                          "not a Chinese date: \(local)")
            XCTAssertTrue(shown.message.contains("\(local) 重置"), "reset not shown as a date: \(shown.message)")
            XCTAssertEqual(a.message, message, "the stored English was changed")
        }
    }

    /// A reset that is not ISO-8601 is a vendor's own wording: kept, not dropped.
    func testQuotaAlertKeepsANonISOResetAsWritten() {
        withChinese {
            let a = record(id: "quota-Claude-Weekly-80", type: "Quota Warning",
                           title: "Claude Weekly at 85%",
                           message: "Quota window 'Weekly' is 85% used (15% remaining) (resets Friday).",
                           provider: "Claude")
            let shown = AlertPresentation.text(for: a)
            XCTAssertTrue(shown.recognized)
            XCTAssertTrue(shown.message.contains("Friday 重置"), "the reset text was lost: \(shown.message)")
        }
    }
}
#endif

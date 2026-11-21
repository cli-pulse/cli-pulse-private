import XCTest
@testable import CLIPulseCore

/// The Overview widget's "5h" row. Claude's weekly-only plans have no 5-hour
/// window and their headline is the week, so a row drawn from the headline
/// repeated the week under a 5-hour label (2026-11-22).
@MainActor
final class WidgetSessionWindowTests: XCTestCase {

    private func payload(_ providers: [ProviderUsage]) -> PublishedWidgetData {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UserDefaults(suiteName: "WidgetSessionWindowTests.\(UUID().uuidString)")!,
            performLaunchSetup: false)
        state.providers = providers
        return state.widgetPayload(converter: CurrencyConverter(
            defaults: UserDefaults(suiteName: "fx-\(UUID().uuidString)")!))
    }

    func testWeeklyOnlyClaudeSaysItHasNoFiveHourWindow() throws {
        let usage = ClaudeResultBuilder.build(from: ClaudeSnapshot(weeklyUsed: 40, sourceLabel: "oauth")).usage
        let claude = try XCTUnwrap(payload([usage]).providers.first)
        XCTAssertEqual(claude.hasSessionWindow, false)
        XCTAssertNil(claude.sessionPercent)
        XCTAssertEqual(try XCTUnwrap(claude.weeklyPercent), 0.4, accuracy: 1e-9)
    }

    func testAFiveHourWindowIsSentWithItsOwnFraction() throws {
        let usage = ClaudeResultBuilder.build(from: ClaudeSnapshot(
            sessionUsed: 10, weeklyUsed: 40, sourceLabel: "oauth")).usage
        let claude = try XCTUnwrap(payload([usage]).providers.first)
        XCTAssertEqual(claude.hasSessionWindow, true)
        XCTAssertEqual(try XCTUnwrap(claude.sessionPercent), 0.1, accuracy: 1e-9)
    }

    /// A tier marked as a 300-minute window counts whatever its name.
    func testAThreeHundredMinuteTierIsTheFiveHourWindow() {
        let usage = ProviderUsage(
            provider: "Codex", today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0, cost_status_today: "", cost_status_week: "",
            quota: 100, remaining: 65, plan_type: nil, reset_time: nil,
            tiers: [TierDTO(name: "Session", quota: 100, remaining: 65, reset_time: nil, windowMinutes: 300, role: .primary)],
            status_text: "", trend: [], recent_sessions: [], recent_errors: [])
        XCTAssertNotNil(WatchRingMath.fiveHourTier(usage))
    }
}

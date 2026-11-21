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

    private func usage(_ name: String, _ tiers: [TierDTO]) -> ProviderUsage {
        ProviderUsage(
            provider: name, today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0, cost_status_today: "", cost_status_week: "",
            quota: 100, remaining: 65, plan_type: nil, reset_time: nil, tiers: tiers,
            status_text: "", trend: [], recent_sessions: [], recent_errors: [])
    }

    func testFiveHourWindowsAreFoundByLengthOrByName() {
        let byLength = usage("Codex", [TierDTO(name: "Session", quota: 100, remaining: 65, windowMinutes: 300, role: .primary)])
        let kimi = usage("Kimi", [TierDTO(name: "5h Rate Limit", quota: 100, remaining: 80),
                                  TierDTO(name: "Weekly", quota: 100, remaining: 50)])
        let openCodeGo = usage("OpenCode Go", [TierDTO(name: "Rolling", quota: 100, remaining: 70),
                                              TierDTO(name: "Weekly", quota: 100, remaining: 40)])
        for provider in [byLength, kimi, openCodeGo] {
            XCTAssertEqual(WatchRingMath.hasFiveHourWindow(provider), true, provider.provider)
        }
        XCTAssertEqual(try XCTUnwrap(payload([kimi]).providers.first?.sessionPercent), 0.2, accuracy: 1e-9)
    }

    /// Only a weekly window with no 5-hour one hides the row; a provider whose
    /// tiers are neither (Cursor's plan, Gemini's families) keeps it as it was.
    func testOnlyAWeeklyWindowWithoutAFiveHourOneHidesTheRow() {
        XCTAssertEqual(WatchRingMath.hasFiveHourWindow(usage("Claude", [TierDTO(name: "Weekly", quota: 100, remaining: 60)])), false)
        XCTAssertNil(WatchRingMath.hasFiveHourWindow(usage("Cursor", [TierDTO(name: "Plan", quota: 100, remaining: 60)])))
        XCTAssertNil(WatchRingMath.hasFiveHourWindow(usage("Copilot", [])))
    }

    /// Older Codex rows named a weekly-only account's one window "5h Window"
    /// and marked it secondary: not taken for a 5-hour window.
    func testASecondaryTierIsNotTakenForTheFiveHourWindowByItsName() {
        let legacy = usage("Codex", [TierDTO(name: "5h Window", quota: 100, remaining: 60, role: .secondary)])
        XCTAssertNil(WatchRingMath.fiveHourTier(legacy))
        XCTAssertEqual(WatchRingMath.hasFiveHourWindow(legacy), false)
    }

    /// The widget decodes these keys (`WidgetProviderData` in the widget
    /// target, which SwiftPM does not build): what the app writes must decode
    /// under the widget's names.
    func testTheWidgetsKeysReadWhatTheAppWrites() throws {
        struct WidgetSide: Decodable {
            struct Provider: Decodable { var hasSessionWindow: Bool?; var sessionPercent: Double? }
            var providers: [Provider]
        }
        let usage = ClaudeResultBuilder.build(from: ClaudeSnapshot(sessionUsed: 10, weeklyUsed: 40, sourceLabel: "oauth")).usage
        let decoded = try JSONDecoder().decode(WidgetSide.self, from: JSONEncoder().encode(payload([usage])))
        XCTAssertEqual(decoded.providers.first?.hasSessionWindow, true)
        XCTAssertEqual(try XCTUnwrap(decoded.providers.first?.sessionPercent), 0.1, accuracy: 1e-9)

        let widgetSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CLI Pulse Widgets/WidgetDataProvider.swift"),
            encoding: .utf8)
        XCTAssertTrue(widgetSource.contains("var hasSessionWindow: Bool?"), "the widget no longer reads hasSessionWindow")
        XCTAssertTrue(widgetSource.contains("var sessionPercent: Double?"), "the widget no longer reads sessionPercent")
    }
}

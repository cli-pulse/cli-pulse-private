import XCTest
@testable import CLIPulseCore

@MainActor
final class ProviderStateEnabledProviderCountTests: XCTestCase {
    func testEnabledProviderCountCountsUniqueEnabledKinds() {
        let state = ProviderState()
        state.providerConfigs = [
            ProviderConfig(
                kind: .codex,
                isEnabled: true,
                accountLabel: "Personal"
            ),
            ProviderConfig(
                kind: .codex,
                isEnabled: true,
                accountLabel: "Work"
            ),
            ProviderConfig(
                kind: .claude,
                isEnabled: false
            ),
            ProviderConfig(
                kind: .gemini,
                isEnabled: false
            ),
        ]
        state.providers = [
            usage(.codex),
            usage(.codex),
            usage(.claude),
            usage(.gemini),
        ]

        XCTAssertEqual(state.enabledProviderCount, 1)

        state.providerConfigs[2].isEnabled = true

        XCTAssertEqual(state.enabledProviderCount, 2)
    }

    func testEnabledProviderCountIgnoresDefaultTogglesWithoutUsageRows() {
        let state = ProviderState()
        state.providerConfigs = ProviderConfig.defaults()
        state.providers = [
            usage(.codex),
            usage(.claude),
        ]

        XCTAssertEqual(state.enabledProviderCount, 2)
    }

    private func usage(_ kind: ProviderKind) -> ProviderUsage {
        ProviderUsage(
            provider: kind.rawValue,
            today_usage: 0,
            week_usage: 0,
            estimated_cost_today: 0,
            estimated_cost_week: 0,
            estimated_cost_30_day: 0,
            cost_status_today: "Unavailable",
            cost_status_week: "Unavailable",
            quota: nil,
            remaining: nil,
            tiers: [],
            status_text: "",
            trend: [],
            recent_sessions: [],
            recent_errors: []
        )
    }
}

import XCTest
@testable import CLIPulseCore

/// The Overview's Top Projects and Risk Signals cards: one rule decides when
/// they draw (Mac, iPhone, Watch), and Demo builds its dashboard from the same
/// producers a real account does. Every App Store screenshot is drawn from
/// Demo, and until 1.55 it showed both cards filled in six languages while no
/// customer could see either.
///
/// Runs in Simplified Chinese: risk signals are text resolved when they are
/// made, and under English a broken lookup still passes, because the fallback
/// copy is English.
final class OverviewOptionalCardsTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    private func dashboard(projects: [TopProject], signals: [String]) -> DashboardSummary {
        DashboardSummary(
            total_usage_today: 1, total_estimated_cost_today: 1, cost_status: "Estimated",
            total_requests_today: 1, active_sessions: 1, online_devices: 1, unresolved_alerts: 0,
            provider_breakdown: [], top_projects: projects, trend: [], recent_activity: [],
            risk_signals: signals, alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0))
    }

    /// Every risk signal the local refresh can raise, over every input it takes.
    private var producibleRiskSignals: Set<String> {
        var all = Set<String>()
        for sessions in [false, true] {
            for providerData in [false, true] {
                all.formUnion(DashboardRiskSignals.local(foundSessions: sessions, foundProviderData: providerData))
            }
        }
        return all
    }

    // MARK: - The rule

    func testTheCardsDrawOnlyWithRows() {
        let empty = dashboard(projects: [], signals: [])
        XCTAssertFalse(empty.showsTopProjectsCard, "an empty Top Projects card is drawn")
        XCTAssertFalse(empty.showsRiskSignalsCard, "an empty Risk Signals card is drawn")

        let filled = dashboard(
            projects: [TopProject(id: "p", name: "app", usage: 1, estimated_cost: 0.01, cost_status: "Estimated")],
            signals: [L10n.dashboard.noAiToolsDetected])
        XCTAssertTrue(filled.showsTopProjectsCard, "a Top Projects card with rows is hidden")
        XCTAssertTrue(filled.showsRiskSignalsCard, "a Risk Signals card with a signal is hidden")
    }

    // MARK: - Production

    /// The cloud dashboard has no project or risk column, whatever the row holds.
    func testTheCloudDashboardFillsNeitherCard() throws {
        let row = Data("""
            {"today_usage": 120000, "today_cost": 3.5, "active_sessions": 4,
             "online_devices": 2, "unresolved_alerts": 3, "today_sessions": 9}
            """.utf8)
        let payload = try JSONDecoder().decode(APIClient.DashboardSummaryPayload.self, from: row)
        let dash = APIClient.dashboardSummary(from: payload)

        XCTAssertEqual(dash.total_usage_today, 120000, "the row did not decode, so this proves nothing")
        XCTAssertFalse(dash.showsTopProjectsCard)
        XCTAssertFalse(dash.showsRiskSignalsCard)
    }

    /// The local refresh raises one signal, only when it found nothing at all,
    /// and raises it in the user's language.
    func testTheLocalRefreshRaisesOnlyNoAIToolsDetectedInTheUsersLanguage() throws {
        XCTAssertEqual(DashboardRiskSignals.local(foundSessions: false, foundProviderData: false),
                       [L10n.dashboard.noAiToolsDetected])
        XCTAssertEqual(DashboardRiskSignals.local(foundSessions: true, foundProviderData: false), [])
        XCTAssertEqual(DashboardRiskSignals.local(foundSessions: false, foundProviderData: true), [])
        XCTAssertEqual(DashboardRiskSignals.local(foundSessions: true, foundProviderData: true), [])

        let chinese = try XCTUnwrap(DashboardRiskSignals.local(foundSessions: false, foundProviderData: false).first)
        LocaleOverrideStore.shared.set("en")
        let english = try XCTUnwrap(DashboardRiskSignals.local(foundSessions: false, foundProviderData: false).first)
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertNotEqual(chinese, english, "the risk signal is not localized: \(chinese)")
        XCTAssertNil(chinese.range(of: "[A-Za-z]{3,}", options: .regularExpression),
                     "English words in the Chinese risk signal: \(chinese)")
    }

    // MARK: - Demo

    /// No real producer fills `top_projects`, so Demo must not either: the
    /// card would appear in every screenshot and on no customer's Mac.
    func testDemoShowsNoTopProjectsCard() {
        let demo = DemoDataProvider.generate().dashboard
        XCTAssertFalse(demo.showsTopProjectsCard, """
            Demo fills Top Projects (\(demo.top_projects.map(\.name))), which no real account can see. \
            Restore the rows only with a real producer.
            """)
    }

    /// Demo's risk signals are the local refresh's, for Demo's own state: it
    /// has sessions and provider data, so it raises none and the card hides.
    func testDemoRaisesOnlyTheRiskSignalsARealAccountCan() {
        let demo = DemoDataProvider.generate()
        let producible = producibleRiskSignals
        XCTAssertEqual(producible, [L10n.dashboard.noAiToolsDetected],
                       "the local refresh's signals changed; recheck Demo against them")

        for signal in demo.dashboard.risk_signals {
            XCTAssertTrue(producible.contains(signal), "Demo raises a risk signal nothing real raises: \(signal)")
        }
        XCTAssertEqual(
            demo.dashboard.risk_signals,
            DashboardRiskSignals.local(foundSessions: !demo.sessions.isEmpty,
                                       foundProviderData: !demo.providers.isEmpty),
            "Demo's risk signals are not what an account with its sessions and providers would see")
        XCTAssertFalse(demo.sessions.isEmpty, "Demo has no sessions, so this proves less than it says")
        XCTAssertFalse(demo.dashboard.showsRiskSignalsCard)
    }
}

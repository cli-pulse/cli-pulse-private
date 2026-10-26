import XCTest
@testable import CLIPulseCore

/// The iPhone's and iPad's Overview draws its "Waiting for data" card above
/// a dashboard that has arrived when the account has nothing synced (1.59).
/// Up to 1.58 the card drew only with no dashboard at all, and the cloud
/// answers an empty account with zeros, so a signed-in iPhone with nothing
/// synced opened on zero tiles with no reason and no step on the Mac.
///
/// Runs in Simplified Chinese: the card is reused as it is, with no new text,
/// and under English a broken lookup of its copy would still pass, because
/// the fallback copy is English.
@MainActor
final class OverviewSyncSetupTests: XCTestCase {

    private var savedOverride: String?
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
        suiteName = "OverviewSyncSetupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// What `dashboard_summary` returns for an account with nothing synced,
    /// through the app's own mapping: an online Mac and nothing else.
    private func emptyAccountDashboard(onlineDevices: Int = 1, unresolvedAlerts: Int = 0) throws -> DashboardSummary {
        let row = Data("""
            {"today_usage": 0, "today_cost": 0, "active_sessions": 0,
             "online_devices": \(onlineDevices), "unresolved_alerts": \(unresolvedAlerts), "today_sessions": 0}
            """.utf8)
        let payload = try JSONDecoder().decode(APIClient.DashboardSummaryPayload.self, from: row)
        return APIClient.dashboardSummary(from: payload)
    }

    private func dashboard(usage: Int = 0, cost: Double = 0, requests: Int = 0, sessions: Int = 0,
                           breakdown: [ProviderBreakdown] = []) -> DashboardSummary {
        DashboardSummary(
            total_usage_today: usage, total_estimated_cost_today: cost, cost_status: "Estimated",
            total_requests_today: requests, active_sessions: sessions, online_devices: 1, unresolved_alerts: 0,
            provider_breakdown: breakdown, top_projects: [], trend: [], recent_activity: [],
            risk_signals: [], alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0))
    }

    private var oneDailyRow: DailyUsage {
        DailyUsage(date: DailyUsageStats.localDayKey(), provider: "Claude", model: "claude-sonnet-4-5",
                   inputTokens: 100, cachedTokens: 0, outputTokens: 50, cost: 0.01)
    }

    private var oneArchivedDay: DailyUsageArchive {
        var archive = DailyUsageArchive()
        archive.mergeCloudDays([CloudEntry(archiving: oneDailyRow)])
        return archive
    }

    private var oneProviderAccount: ProviderAccountUsage {
        ProviderAccountUsage(
            id: UUID(), provider: .claude, accountLabel: nil,
            planEvidence: ProviderPlanEvidence(rawValue: "pro", displayValue: "Pro", source: .providerAPI,
                                               confidence: .high, observedAt: nil),
            quota: 100, remaining: 50, tiers: [], resetTime: nil,
            observedAt: nil, sourceDeviceID: nil, statusText: "Operational")
    }

    private func nothingSynced(
        isDemoMode: Bool = false,
        dashboard: DashboardSummary,
        providers: [ProviderUsage] = [],
        providerAccounts: [ProviderAccountUsage] = [],
        dailyUsage: [DailyUsage] = [],
        archive: DailyUsageArchive = DailyUsageArchive(),
        sessions: [SessionRecord] = []
    ) -> Bool {
        OverviewSyncSetup.accountHasNothingSynced(
            isDemoMode: isDemoMode, dashboard: dashboard, providers: providers,
            providerAccounts: providerAccounts, dailyUsage: dailyUsage, archive: archive, sessions: sessions)
    }

    /// A signed-in state with no network, its widget data kept out of the
    /// real app group (an empty Info.plist resolves to the quarantine
    /// capabilities).
    private func signedInState() -> AppState {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        state.isAuthenticated = true
        return state
    }

    // MARK: - The rule

    /// The case 1.59 is for: the dashboard is there, every figure is zero,
    /// the Activity card's archive is empty, and a Mac is online.
    func testAnEmptyAccountsDashboardDrawsTheCard() throws {
        let dash = try emptyAccountDashboard()
        XCTAssertEqual(dash.online_devices, 1, "the row did not decode, so this proves nothing")
        XCTAssertTrue(nothingSynced(dashboard: dash),
                      "an account with nothing synced opens on zeros with no reason again")
    }

    /// A paired Mac that is online but uploads nothing, or an alert, is not
    /// synced usage: the card stays, since what to do is still on the Mac.
    func testAnOnlineMacOrAnAlertDoesNotHideTheCard() throws {
        XCTAssertTrue(nothingSynced(dashboard: try emptyAccountDashboard(onlineDevices: 3, unresolvedAlerts: 2)))
        XCTAssertTrue(nothingSynced(dashboard: try emptyAccountDashboard(onlineDevices: 0)))
    }

    /// Anything synced hides it, each on its own.
    func testAnythingSyncedHidesTheCard() throws {
        let demo = DemoDataProvider.generate()
        let provider = try XCTUnwrap(demo.providers.first, "Demo has no provider row to sync")
        let session = try XCTUnwrap(demo.sessions.first, "Demo has no session to sync")
        let empty = try emptyAccountDashboard()
        let breakdown = ProviderBreakdown(provider: "Claude", usage: 1, estimated_cost: 0,
                                          cost_status: "Estimated", remaining: nil)

        let cases: [(String, Bool)] = [
            ("a provider row", nothingSynced(dashboard: empty, providers: [provider])),
            ("a provider account", nothingSynced(dashboard: empty, providerAccounts: [oneProviderAccount])),
            ("a daily row in the window", nothingSynced(dashboard: empty, dailyUsage: [oneDailyRow])),
            ("a day in the year's archive", nothingSynced(dashboard: empty, archive: oneArchivedDay)),
            ("a session", nothingSynced(dashboard: empty, sessions: [session])),
            ("usage today", nothingSynced(dashboard: dashboard(usage: 1))),
            ("cost today", nothingSynced(dashboard: dashboard(cost: 0.01))),
            ("requests today", nothingSynced(dashboard: dashboard(requests: 1))),
            ("an active session", nothingSynced(dashboard: dashboard(sessions: 1))),
            ("a provider in the dashboard", nothingSynced(dashboard: dashboard(breakdown: [breakdown]))),
        ]
        // Positive control: the fixtures above start from an empty account.
        XCTAssertTrue(nothingSynced(dashboard: empty))
        XCTAssertTrue(nothingSynced(dashboard: dashboard()))
        for (what, drawsCard) in cases {
            XCTAssertFalse(drawsCard, "an account with \(what) still gets \"\(L10n.onboarding.iosWaiting)\"")
        }
        XCTAssertFalse(oneArchivedDay.days.isEmpty, "the archive fixture holds no day, so its case proves nothing")
    }

    // MARK: - Demo

    /// Try Demo is not an account, and every screenshot is drawn from it:
    /// never the card, not even if Demo's data were all gone.
    func testDemoNeverDrawsTheCard() throws {
        XCTAssertFalse(nothingSynced(isDemoMode: true, dashboard: try emptyAccountDashboard()))

        let state = signedInState()
        state.enterDemoMode()
        XCTAssertTrue(state.isDemoMode)
        XCTAssertNotNil(state.dashboard, "Demo has no dashboard, so this proves nothing")
        XCTAssertFalse(state.overviewAccountHasNothingSynced, "Try Demo draws the setup card")

        state.dashboard = try emptyAccountDashboard()
        state.providers = []
        state.providerAccounts = []
        state.sessions = []
        state.dailyUsage = []
        state.usageArchive = DailyUsageArchive()
        XCTAssertFalse(state.overviewAccountHasNothingSynced, "an emptied Try Demo draws the setup card")
    }

    // MARK: - The app's state

    /// Through `AppState`, as the Overview reads it: no dashboard leaves the
    /// card to the Overview's own branch; an empty account's dashboard draws
    /// it; a daily row, or a day in the archive, arriving after the dashboard
    /// takes it away.
    func testTheAppStateReadsItsOwnAccount() throws {
        let state = signedInState()
        XCTAssertFalse(state.isDemoMode)
        XCTAssertNil(state.dashboard)
        XCTAssertFalse(state.overviewAccountHasNothingSynced,
                       "with no dashboard the Overview already draws the card in its place; twice is wrong")

        state.dashboard = try emptyAccountDashboard()
        XCTAssertTrue(state.overviewAccountHasNothingSynced)

        state.dailyUsage = [oneDailyRow]
        XCTAssertFalse(state.overviewAccountHasNothingSynced, "a daily row arrived and the card stayed")

        state.dailyUsage = []
        state.usageArchive = oneArchivedDay
        XCTAssertFalse(state.overviewAccountHasNothingSynced, "the archive has a day and the card stayed")
    }

    // MARK: - Copy

    /// The card is reused, so its copy is its own: each line resolves in
    /// Simplified Chinese, and none is the English fallback.
    func testTheCardsCopyIsInTheUsersLanguage() {
        let lines: [(String, () -> String)] = [
            ("onboarding.ios_waiting", { L10n.onboarding.iosWaiting }),
            ("onboarding.ios_waiting_desc", { L10n.onboarding.iosWaitingDesc }),
            ("onboarding.how_it_works", { L10n.onboarding.howItWorks }),
            ("onboarding.cloud_sync_desc", { L10n.onboarding.cloudSyncDesc }),
            ("onboarding.step1_mac", { L10n.onboarding.step1Mac }),
            ("onboarding.step2_helper", { L10n.onboarding.step2Helper }),
            ("onboarding.step3_phone", { L10n.onboarding.step3Phone }),
            ("onboarding.not_bluetooth", { L10n.onboarding.notBluetooth }),
            ("onboarding.check_sync", { L10n.onboarding.checkSync }),
        ]
        let chinese = lines.map { ($0.0, $0.1()) }
        LocaleOverrideStore.shared.set("en")
        let english = lines.map { $0.1() }
        LocaleOverrideStore.shared.set("zh-Hans")

        XCTAssertEqual(L10n.onboarding.iosWaiting, "等待数据", "the zh-Hans override is not in effect")
        for ((key, zh), en) in zip(chinese, english) {
            XCTAssertNotEqual(zh, key, "\(key) has no zh-Hans entry")
            XCTAssertNotEqual(zh, en, "\(key) is English under zh-Hans: \(zh)")
            XCTAssertNotNil(zh.range(of: "\\p{Han}", options: .regularExpression),
                            "\(key) has no Chinese in it: \(zh)")
        }
    }

    // MARK: - Wiring

    /// Source-level, because the Overview is a view. The card is drawn inside
    /// the dashboard branch, just under the rule, and above the metric tiles;
    /// the branch with no dashboard keeps its own card.
    func testTheOverviewDrawsTheCardAboveTheDashboardUnderTheRule() throws {
        let path = "CLI Pulse Bar iOS/iOSOverviewTab.swift"
        let text = try String(contentsOf: Self.appSourceRoot.appendingPathComponent(path), encoding: .utf8)
        let lines = Self.codeOnly(text).components(separatedBy: "\n")

        let dashboardBranch = try XCTUnwrap(lines.firstIndex { $0.contains("if let dash = state.dashboard {") },
                                            "\(path) no longer opens a dashboard branch")
        let tiles = try XCTUnwrap(lines.firstIndex { $0.contains("metricsGrid(dash)") },
                                  "\(path) no longer draws the metric tiles")
        let cards = lines.indices.filter { lines[$0].contains("iOSSyncOnboardingCard()") }
        XCTAssertEqual(cards.count, 2, "\(path) draws the setup card \(cards.count) times; expected two")

        let underRule = cards.filter { line in
            lines[max(0, line - 3)..<line].contains { $0.contains("if state.overviewAccountHasNothingSynced {") }
        }
        XCTAssertEqual(underRule.count, 1, """
            \(path): the setup card is not drawn under `if state.overviewAccountHasNothingSynced {`, so an \
            account with nothing synced opens on zeros with no reason again.
            """)
        if let card = underRule.first {
            XCTAssertTrue(dashboardBranch < card && card < tiles, """
                \(path): the setup card under the rule is not inside the dashboard branch above the metric \
                tiles (branch \(dashboardBranch), card \(card), tiles \(tiles)).
                """)
        }
        // The branch with no dashboard keeps its card, after the tiles.
        XCTAssertTrue(cards.contains { $0 > tiles }, "\(path) lost the card it draws with no dashboard")
    }

    // MARK: - Source helpers

    /// `CLI Pulse Bar/`, which holds the app targets and `CLIPulseCore`.
    private static var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .deletingLastPathComponent()   // CLI Pulse Bar
    }

    /// Whole-line comments dropped: the comment above the call site names
    /// the very symbols this scan looks for.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

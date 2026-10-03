import XCTest
@testable import CLIPulseCore

/// Demo draws every App Store screenshot, so each figure in it must be one a
/// real account can see. These are the figures the 1.55 screenshot review
/// traced to their producers and found no producer for: Gemini tokens and
/// cost, a Requests count on the signed-in dashboard, a failed session with
/// errors, a provider card's recent-sessions line, and a session's cost and
/// usage that no process scan writes. Each test pairs Demo
/// with the production fact it follows, so the two change together.
final class DemoMatchesProductionTests: XCTestCase {

    // MARK: - Gemini is quota-only

    /// GeminiCollector reports a quota and no cost ("Unavailable"), and
    /// nothing records Gemini tokens (CostUsageScanner reads Codex and Claude
    /// logs, and the cloud's tokens and cost come from that scanner). Demo gave
    /// Gemini 43.4K tokens and $0.35 today, which reached the totals, the Cost
    /// Summary and Provider Usage of six panels.
    func testDemoGivesGeminiNoTokensOrCost() throws {
        let demo = DemoDataProvider.generate()
        let gemini = try XCTUnwrap(demo.providers.first { $0.provider == "Gemini" },
                                   "Demo has no Gemini; is this still the Demo the screenshots draw?")
        XCTAssertEqual(gemini.today_usage, 0)
        XCTAssertEqual(gemini.week_usage, 0)
        XCTAssertEqual(gemini.estimated_cost_today, 0)
        XCTAssertEqual(gemini.estimated_cost_week, 0)
        XCTAssertEqual(gemini.cost_status_today, "Unavailable")
        XCTAssertEqual(gemini.cost_status_week, "Unavailable")
        // Positive control: Gemini still has the quota the collector reports.
        XCTAssertFalse(gemini.tiers.isEmpty, "Demo's Gemini lost its quota window too")

        XCTAssertFalse(DemoDataProvider.dailyUsage(days: 365).contains { $0.provider == "Gemini" },
                       "the heatmap and the 30-day figure count Gemini usage nothing records")

        let enabled = Set(demo.providers.map(\.provider))
        let usageRows = OverviewFormatters.rankedProviderBreakdown(demo.dashboard.provider_breakdown,
                                                                   enabledNames: enabled)
        XCTAssertEqual(usageRows.map(\.provider), ["Codex", "Claude"],
                       "Provider Usage draws a row no real account has")

        let others = demo.providers.filter { $0.provider != "Gemini" }
        XCTAssertEqual(demo.dashboard.total_usage_today, others.reduce(0) { $0 + $1.today_usage })
        XCTAssertEqual(demo.dashboard.total_estimated_cost_today,
                       others.reduce(0) { $0 + $1.estimated_cost_today }, accuracy: 0.0001)
    }

    /// The production half of the test above, read from the sources: the
    /// collector reports no Gemini cost, and the scanner has no Gemini at all.
    /// If either changes, Demo may show Gemini tokens or cost again, in the
    /// same change.
    func testNoProducerGivesGeminiTokensOrCost() throws {
        let sources = Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore")
        let collector = Self.codeOnly(try String(
            contentsOf: sources.appendingPathComponent("Collectors/GeminiCollector.swift"), encoding: .utf8))
        XCTAssertTrue(collector.contains("estimated_cost_today: 0,"), "GeminiCollector now reports a cost")
        XCTAssertTrue(collector.contains(#"cost_status_today: "Unavailable","#),
                      "GeminiCollector's cost is no longer Unavailable")
        XCTAssertFalse(collector.contains("estimated_cost_today: Double"), "GeminiCollector now computes a cost")

        let scanner = Self.codeOnly(try String(
            contentsOf: sources.appendingPathComponent("CostUsageScanner.swift"), encoding: .utf8))
        // Positive control: the scanner still records the two it does.
        XCTAssertTrue(scanner.contains(#""Codex""#) && scanner.contains(#""Claude""#),
                      "CostUsageScanner no longer names Codex and Claude; is this still the scanner?")
        XCTAssertNil(scanner.range(of: "gemini", options: .caseInsensitive),
                     "CostUsageScanner now reads Gemini; give Demo's Gemini tokens and cost in the same change")
    }

    // MARK: - Requests

    /// The cloud dashboard has no request count: `dashboard_summary` has no
    /// such column and `APIClient.dashboardSummary(from:)` carries 0. Only the
    /// local refresh fills one, so the figure shows on that route alone. The
    /// cases pin the premise through the real router, not the predicate's
    /// body: a signed-in Mac with no paired helper takes the local refresh
    /// (and has a count) just as local mode does; signed in and paired, Demo,
    /// and the iPhone (whose route the Watch also decides) do not.
    func testTheRequestsTileShowsOnlyWhereSomethingCountsRequests() throws {
        func shows(signedIn: Bool, demo: Bool = false, paired: Bool,
                   localMode: Bool = false, mac: Bool) -> Bool {
            OverviewFormatters.showsRequestsMetric(route: RefreshRouter.decide(
                isAuthenticated: signedIn, isDemoMode: demo, isPaired: paired,
                isLocalMode: localMode, isMacOS: mac))
        }
        XCTAssertTrue(shows(signedIn: false, paired: false, localMode: true, mac: true),
                      "local mode counts requests and lost its tile")
        XCTAssertTrue(shows(signedIn: true, paired: false, mac: true),
                      "a signed-in Mac with no paired helper refreshes locally and counts requests")
        XCTAssertFalse(shows(signedIn: true, paired: true, mac: true),
                       "a paired Mac draws the cloud dashboard, whose count is 0")
        XCTAssertFalse(shows(signedIn: true, demo: true, paired: true, mac: true),
                       "Demo draws the Requests tile")
        XCTAssertFalse(shows(signedIn: true, paired: false, mac: false),
                       "the iPhone (and the Watch) draw the cloud dashboard, whose count is 0")

        let row = Data("""
            {"today_usage": 120000, "today_cost": 3.5, "active_sessions": 4,
             "online_devices": 2, "unresolved_alerts": 3, "today_sessions": 9}
            """.utf8)
        let cloud = APIClient.dashboardSummary(
            from: try JSONDecoder().decode(APIClient.DashboardSummaryPayload.self, from: row))
        XCTAssertEqual(cloud.total_usage_today, 120000, "the row did not decode, so this proves nothing")
        XCTAssertEqual(cloud.total_requests_today, 0,
                       "the cloud dashboard now counts requests; show the tile on the cloud route")

        XCTAssertEqual(DemoDataProvider.generate().dashboard.total_requests_today,
                       cloud.total_requests_today, "Demo draws the signed-in dashboard, so its count is the cloud's")
    }

    /// Every read of the dashboard's request count in an app target sits under
    /// the rule: the Mac, iPhone and Watch Overviews, and anything added later
    /// to any of the four targets. Keyed on the field, not the label: session
    /// details use the same label for `session.requests`, which is not this.
    func testEveryReadOfTheRequestCountIsUnderTheRule() throws {
        let fileManager = FileManager.default
        var reads: [String] = []
        for target in ["CLI Pulse Bar", "CLI Pulse Bar iOS", "CLI Pulse Bar Watch", "CLI Pulse Widgets"] {
            let root = Self.appSourceRoot.appendingPathComponent(target)
            guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
                XCTFail("\(target) is gone; is this still the list of app targets?"); continue
            }
            var swiftFiles = 0
            for case let url as URL in walker where url.pathExtension == "swift" {
                swiftFiles += 1
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                // Code lines only, numbered as in the file: comments name the
                // very symbols this scan looks for.
                let code = lines.indices.filter {
                    !lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("//")
                }
                for (position, index) in code.enumerated() where lines[index].contains("total_requests_today") {
                    let place = "\(target)/\(url.lastPathComponent):\(index + 1)"
                    reads.append(place)
                    let above = code[max(0, position - 3)..<position].map { lines[$0] }
                    XCTAssertTrue(above.contains { $0.contains("showsRequestsMetric(") }, """
                        \(place) reads the dashboard's request count without \
                        `OverviewFormatters.showsRequestsMetric` in the three lines above it; \
                        on the cloud route it reads 0 for everyone.
                        """)
                }
            }
            XCTAssertGreaterThan(swiftFiles, 0, "\(target) has no Swift files; is this still an app target?")
        }
        // Positive control: the scan still finds the Mac Overview's tile.
        XCTAssertTrue(reads.contains { $0.hasPrefix("CLI Pulse Bar/OverviewTab.swift:") },
                      "the scan no longer finds the Mac Overview's Requests tile: \(reads)")
    }

    // MARK: - Sessions and provider cards

    /// Every session producer (both helpers, the local scanners, the desktop
    /// app) writes error_count 0 and a live status, so no real Sessions tab
    /// draws the red Errors figure or the red "failed" border.
    func testDemoSessionsHaveNoErrorsAndNoFailedStatus() {
        for session in DemoDataProvider.generate().sessions {
            XCTAssertEqual(session.error_count, 0, "\(session.name) shows Errors, which no producer writes")
            XCTAssertNotEqual(session.status.lowercased(), "failed",
                              "\(session.name) is failed, which no producer writes")
        }
    }

    /// A session's status is "Running" as every process scan writes it, or
    /// "Ended", which helper_sync sets ten minutes after the process is gone,
    /// when the app's five-minute freshness filter no longer lists the row.
    /// So a listed session reads Running. Demo had "syncing" and "idle", which
    /// the iPad's session list drew as badges.
    func testDemoSessionsReadRunningAsProducersWriteIt() throws {
        for session in DemoDataProvider.generate().sessions {
            XCTAssertEqual(session.status, "Running", "\(session.name) has a status no producer writes")
        }
        let repoRoot = Self.appSourceRoot.deletingLastPathComponent()
        let scanner = Self.codeOnly(try String(
            contentsOf: Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore/LocalScanner.swift"),
            encoding: .utf8))
        XCTAssertTrue(scanner.contains(#"status: "Running","#), "LocalScanner writes another status")
        let python = try String(
            contentsOf: repoRoot.appendingPathComponent("helper/system_collector.py"), encoding: .utf8)
        let statuses = python.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("status=") }
        XCTAssertFalse(statuses.isEmpty, "the Python helper builds no session with a status; is this still its scan?")
        XCTAssertEqual(Set(statuses), [#"status="Running","#], "the Python helper writes another session status")
        let sync = try String(
            contentsOf: repoRoot.appendingPathComponent("backend/supabase/helper_rpc.sql"), encoding: .utf8)
        XCTAssertTrue(sync.contains("and last_active_at < now() - interval '10 minutes'"),
                      "helper_sync ends sessions on another schedule")
        XCTAssertEqual(SessionFreshnessFilter.freshnessWindow, 300,
                       "the freshness filter's window changed; can a listed row now read Ended?")
    }

    /// The iPhone and the iPad draw sessions from the cloud, and every
    /// session there comes from a process scan: the Mac helper's LocalScanner,
    /// the desktop app's, or the Python helper's both were ported from. All of
    /// them count a request per 45 s of runtime and usage as runtime times
    /// max(1.5, CPU% + 1), so no session has under 67.5 usage per request.
    /// Demo's helper-heartbeat had 12.8K over 560 requests (seven hours).
    func testDemoSessionsKeepTheProcessScanFloor() {
        for session in DemoDataProvider.generate().sessions {
            XCTAssertGreaterThanOrEqual(
                Double(session.total_usage), Double(session.requests) * 45 * 1.5,
                "\(session.name): \(session.total_usage) usage over \(session.requests) requests is under what a process scan writes")
        }
    }

    /// Off a Mac, sessions come from the desktop app's process scan, which
    /// sends `exact_cost` null (as the Python helper does), and helper_sync
    /// stores a missing cost as 0: such a session shows $0.00. Demo's Gemini
    /// session, on a Linux server, showed $0.10.
    func testASessionOffAMacCarriesNoCost() throws {
        let demo = DemoDataProvider.generate()
        let systems = Dictionary(uniqueKeysWithValues: demo.devices.map { ($0.name, $0.system) })
        var offMac: [String] = []
        for session in demo.sessions {
            let system = try XCTUnwrap(systems[session.device_name],
                                       "\(session.name) is on \(session.device_name), which is no Demo device")
            guard !system.hasPrefix("macOS") else { continue }
            offMac.append(session.name)
            XCTAssertEqual(session.estimated_cost, 0,
                           "\(session.name) on \(system) has a cost no producer there writes")
        }
        // Positive control: the rule still covers a session (the Gemini one).
        XCTAssertFalse(offMac.isEmpty, "no Demo session is off a Mac any more; this test checks nothing")
    }

    /// The production half of the two tests above, read from the sources:
    /// LocalScanner and the Python helper count usage and requests the same
    /// way, the Python helper sends no cost, and helper_sync turns a missing
    /// cost into 0. (The desktop app, in its own repository, ports the Python
    /// helper's scan and sends `exact_cost: None` too.)
    func testTheProcessScansCountAndCostSessionsAsDemoAssumes() throws {
        let repoRoot = Self.appSourceRoot.deletingLastPathComponent()
        let scanner = Self.codeOnly(try String(
            contentsOf: Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore/LocalScanner.swift"),
            encoding: .utf8))
        XCTAssertTrue(scanner.contains("max(1.5, cpu + 1.0)"), "LocalScanner counts usage another way")
        XCTAssertTrue(scanner.contains("max(1, elapsed / 45)"), "LocalScanner counts requests another way")

        let python = try String(
            contentsOf: repoRoot.appendingPathComponent("helper/system_collector.py"), encoding: .utf8)
        XCTAssertTrue(python.contains("max(1.5, cpu + 1.0)"), "the Python helper counts usage another way")
        XCTAssertTrue(python.contains("max(1, elapsed_seconds // 45)"), "the Python helper counts requests another way")
        let costs = python.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("exact_cost=") }
        XCTAssertFalse(costs.isEmpty, "the Python helper builds no session with exact_cost; is this still its scan?")
        XCTAssertEqual(Set(costs), ["exact_cost=None,"], "the Python helper now sends a session cost")

        let sync = try String(
            contentsOf: repoRoot.appendingPathComponent("backend/supabase/helper_rpc.sql"), encoding: .utf8)
        XCTAssertTrue(sync.contains("coalesce((v_session->>'exact_cost')::numeric, 0)"),
                      "helper_sync no longer stores a missing session cost as 0")
    }

    /// Only OllamaCollector fills `recent_sessions`, so a Codex, Gemini or
    /// Claude card never draws the recent-sessions line for a real account.
    func testDemoProvidersListNoRecentSessions() throws {
        for provider in DemoDataProvider.generate().providers {
            XCTAssertTrue(provider.recent_sessions.isEmpty,
                          "\(provider.provider) lists recent sessions: \(provider.recent_sessions)")
        }
        let sources = Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore")
        let ollama = Self.codeOnly(try String(
            contentsOf: sources.appendingPathComponent("Collectors/OllamaCollector.swift"), encoding: .utf8))
        XCTAssertTrue(ollama.contains("recent_sessions: running"),
                      "OllamaCollector no longer fills recent_sessions; recheck who does")
        for name in ["CodexCollector.swift", "ClaudeCollector.swift", "GeminiCollector.swift"] {
            let url = sources.appendingPathComponent("Collectors/\(name)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("\(name) is gone; is this list still the Demo's providers?"); continue
            }
            let fills = Self.codeOnly(text).components(separatedBy: "\n")
                .filter { $0.contains("recent_sessions:") && !$0.contains("recent_sessions: []") }
            XCTAssertEqual(fills, [], "\(name) now fills recent_sessions; Demo may list some again")
        }
    }

    // MARK: - Source helpers

    /// The `CLIPulseCore` package root.
    private static var coreRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
    }

    /// `CLI Pulse Bar/`, which holds the app targets and `CLIPulseCore`.
    private static var appSourceRoot: URL {
        coreRoot.deletingLastPathComponent()
    }

    /// Whole-line comments dropped: comments name the very symbols the scans
    /// look for.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

/// The Cost Summary's per-provider rows, through the real `enterDemoMode`
/// and the cost summary every client without a local scan builds (the
/// iPhone, and Demo on both platforms).
@MainActor
final class DemoCostSummaryRowsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DemoCostSummaryRowsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A provider with no cost gets no row: Gemini is quota-only, and its
    /// "$0.00" row read as "Gemini costs nothing". An empty Info.plist
    /// resolves to the quarantine capabilities, so this publishes no widget
    /// data to the real app group.
    func testTheCostSummaryListsOnlyProvidersWithACost() {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        state.enterDemoMode()
        let summary = state.providerState.costSummary
        XCTAssertEqual(Set(summary.todayByProvider.map(\.provider)), ["Codex", "Claude"],
                       "today's rows: \(summary.todayByProvider)")
        XCTAssertEqual(Set(summary.thirtyDayByProvider.map(\.provider)), ["Codex", "Claude"],
                       "30-day rows: \(summary.thirtyDayByProvider)")
        XCTAssertFalse(summary.todayByProvider.contains { $0.cost <= 0 })
        XCTAssertFalse(summary.thirtyDayByProvider.contains { $0.cost <= 0 })
        // Positive control: the totals still add up to the rows.
        XCTAssertEqual(summary.todayTotal, summary.todayByProvider.reduce(0) { $0 + $1.cost }, accuracy: 0.0001)
        XCTAssertGreaterThan(summary.todayTotal, 0)
    }
}

/// `AppState.refreshRoute`, which the Overviews key the Requests tile on, is
/// the route `refreshAll` takes: the same four flags `refreshContext()` hands
/// it, through the same router. Demo mode is left as the defaults have it
/// (`@AppStorage` on the standard store); both sides read the same value.
@MainActor
final class AppStateRefreshRouteTests: XCTestCase {
    func testTheOverviewsRouteIsTheRefreshRoute() {
        let suiteName = "AppStateRefreshRouteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        #if os(macOS)
        let onMacOS = true
        #else
        let onMacOS = false
        #endif
        var routes: Set<String> = []
        for signedIn in [false, true] {
            for paired in [false, true] {
                for localMode in [false, true] {
                    state.isAuthenticated = signedIn
                    state.isPaired = paired
                    state.isLocalMode = localMode
                    let context = state.refreshContext()
                    let refreshed = RefreshRouter.decide(
                        isAuthenticated: context.isAuthenticated, isDemoMode: context.isDemoMode,
                        isPaired: context.isPaired, isLocalMode: context.isLocalMode,
                        isMacOS: onMacOS)
                    XCTAssertEqual(state.refreshRoute, refreshed,
                                   "signed in \(signedIn), paired \(paired), local mode \(localMode)")
                    routes.insert("\(state.refreshRoute)")
                }
            }
        }
        // Positive control (outside Demo): the flags reached the route.
        if !state.isDemoMode && onMacOS {
            XCTAssertEqual(routes, ["noOp", "localOnly", "cloud"], "the flags did not reach the route")
        }
    }
}

/// The iPhone Overview's metric tiles never include Requests (the iPhone is
/// never on the local refresh route), which leaves five; they are laid out so none sits alone next to an empty slot.
final class MetricRowsTests: XCTestCase {
    func testTilesPairUpAndAnOddCountEndsInARowOfThree() {
        XCTAssertEqual(OverviewFormatters.metricRows(count: 0), [])
        XCTAssertEqual(OverviewFormatters.metricRows(count: 1), [0..<1])
        XCTAssertEqual(OverviewFormatters.metricRows(count: 2), [0..<2])
        XCTAssertEqual(OverviewFormatters.metricRows(count: 3), [0..<3])
        XCTAssertEqual(OverviewFormatters.metricRows(count: 5), [0..<2, 2..<5])
        XCTAssertEqual(OverviewFormatters.metricRows(count: 6), [0..<2, 2..<4, 4..<6])
        XCTAssertEqual(OverviewFormatters.metricRows(count: 7), [0..<2, 2..<4, 4..<7])
        for count in 1...9 {
            let rows = OverviewFormatters.metricRows(count: count)
            XCTAssertEqual(rows.flatMap { Array($0) }, Array(0..<count), "\(count) tiles, each once, in order")
            XCTAssertTrue(rows.allSatisfy { $0.count == 2 || $0.count == 3 || count == 1 }, "\(count): \(rows)")
        }
    }
}

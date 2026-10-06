import XCTest
@testable import CLIPulseCore

/// Demo draws every App Store screenshot, so each figure in it must be one a
/// real account can see. These are the figures the 1.55 screenshot review
/// traced to their producers and found no producer for: Gemini tokens and
/// cost, a Requests count on the signed-in dashboard, a failed session with
/// errors, a provider card's recent-sessions line, a session's cost and
/// usage that no process scan writes, Recent sessions no single refresh
/// keeps, a CPU alert its session could not have raised, a Claude quota with
/// no windows, Codex and Gemini quotas counted in tokens, a device status the
/// cloud never stores, and a 30-day figure production no longer computes.
/// Each test pairs Demo with the production fact it follows, so the two
/// change together.
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
    /// the Companion CLI's SessionDetector, the desktop app's, or the Python
    /// helper's they were ported from. Each writes, for a process alive
    /// `runtime` seconds, started_at = scan time - runtime and last_active_at
    /// = scan time, a request per 45 s of it, and usage of runtime times
    /// max(1.5, CPU% + 1), at least 500. So a row's own timestamps bound its
    /// figures from below: requests >= runtime / 45, usage >= runtime x 1.5.
    ///
    /// Until 1.55 this compared usage with requests x 67.5, which takes the
    /// request count as a stand-in for runtime: four of Demo's five sessions
    /// had fewer requests than their runtime gives (ios-dashboard 142 over two
    /// hours, where a scan counts 160), and api-gateway 8.4K usage over 100
    /// minutes, under the 9K floor; all of them passed. Before that, Demo's
    /// helper-heartbeat had 12.8K over seven hours.
    func testDemoSessionsKeepTheProcessScanFloors() throws {
        let sessions = DemoDataProvider.generate().sessions
        XCTAssertFalse(sessions.isEmpty, "Demo has no sessions; this test checks nothing")
        for session in sessions {
            let started = try XCTUnwrap(sharedISO8601Parse(session.started_at), "\(session.name) started_at")
            let lastActive = try XCTUnwrap(sharedISO8601Parse(session.last_active_at), "\(session.name) last_active_at")
            let runtime = lastActive.timeIntervalSince(started).rounded()
            XCTAssertGreaterThan(runtime, 0, "\(session.name) was last active before it started")
            XCTAssertGreaterThanOrEqual(
                session.requests, Int(runtime) / 45,
                "\(session.name): \(session.requests) requests over \(Int(runtime)) s; a process scan counts \(Int(runtime) / 45)")
            XCTAssertGreaterThanOrEqual(
                Double(session.total_usage), max(500, runtime * 1.5),
                "\(session.name): \(session.total_usage) usage over \(Int(runtime)) s is under what a process scan writes")
        }
    }

    /// On a Mac a session's cost comes from the LoginItem helper, whose
    /// LocalScanner charges usage / 1000 x the provider's default rate
    /// (`ProviderKind.defaultCostRate`: HelperDaemon scans with no rate
    /// lookup), or from the Companion CLI, which sends none (stored as 0).
    /// Production's helper rows match the flat rates. Demo's Mac sessions cost
    /// about six times that: ios-dashboard showed $0.29 for 24.5K Codex usage,
    /// where the helper writes $0.05.
    func testASessionOnAMacCostsTheHelpersFlatRateOrNothing() throws {
        let demo = DemoDataProvider.generate()
        let systems = Dictionary(uniqueKeysWithValues: demo.devices.map { ($0.name, $0.system) })
        var onMac: [String] = []
        for session in demo.sessions {
            let system = try XCTUnwrap(systems[session.device_name],
                                       "\(session.name) is on \(session.device_name), which is no Demo device")
            guard system.hasPrefix("macOS") else { continue }
            onMac.append(session.name)
            let kind = try XCTUnwrap(ProviderKind(rawValue: session.provider), "\(session.provider) is no provider")
            let flat = Double(session.total_usage) / 1000 * kind.defaultCostRate
            XCTAssertTrue(session.estimated_cost == 0 || abs(session.estimated_cost - flat) < 0.0005, """
                \(session.name): $\(session.estimated_cost) for \(session.total_usage) \(session.provider) usage; \
                the helper writes $\(flat), the Companion CLI nothing
                """)
        }
        // Positive control: the rule still covers sessions.
        XCTAssertGreaterThanOrEqual(onMac.count, 3, "Demo's Mac sessions: \(onMac)")

        let daemon = Self.codeOnly(try String(
            contentsOf: Self.appSourceRoot.appendingPathComponent("CLIPulseHelper/HelperDaemon.swift"), encoding: .utf8))
        XCTAssertTrue(daemon.contains("LocalScanner.shared.scan()"),
                      "the helper now scans with a rate lookup (or not at all); recheck Demo's Mac session costs")
        let scanner = Self.codeOnly(try String(
            contentsOf: Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore/LocalScanner.swift"),
            encoding: .utf8))
        XCTAssertTrue(scanner.contains("?? ProviderKind(rawValue: provider)?.defaultCostRate"),
                      "LocalScanner prices a session another way")
        XCTAssertTrue(scanner.contains("return Double(usage) / 1000.0 * rate"),
                      "LocalScanner prices a session another way")
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

    /// The production half of the tests above, read from the sources:
    /// LocalScanner, the Companion CLI and the Python helper count usage and
    /// requests the same way and stamp a session's runtime into its
    /// timestamps, the Companion CLI and the Python helper send no cost, and
    /// helper_sync turns a missing cost into 0. (The desktop app, in its own
    /// repository, ports the Python helper's scan and sends
    /// `exact_cost: None` too.)
    func testTheProcessScansCountAndCostSessionsAsDemoAssumes() throws {
        let repoRoot = Self.appSourceRoot.deletingLastPathComponent()
        let scanner = Self.codeOnly(try String(
            contentsOf: Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore/LocalScanner.swift"),
            encoding: .utf8))
        XCTAssertTrue(scanner.contains("max(1.5, cpu + 1.0)"), "LocalScanner counts usage another way")
        XCTAssertTrue(scanner.contains("max(1, elapsed / 45)"), "LocalScanner counts requests another way")
        XCTAssertTrue(scanner.contains("started_at: sharedISO8601Formatter.string(from: Date().addingTimeInterval(-Double(elapsed)))"),
                      "LocalScanner dates a session's start another way")
        XCTAssertTrue(scanner.contains("last_active_at: now,"), "LocalScanner dates a session's last activity another way")

        let companion = Self.codeOnly(try String(
            contentsOf: repoRoot.appendingPathComponent("HelperSwift/Sources/HelperKit/SystemCollection/SessionDetector.swift"),
            encoding: .utf8))
        XCTAssertTrue(companion.contains("max(1.5, cpu + 1.0)"), "the Companion CLI counts usage another way")
        XCTAssertTrue(companion.contains("max(1, elapsedSeconds / 45)"), "the Companion CLI counts requests another way")
        XCTAssertTrue(companion.contains("nowDate.addingTimeInterval(-Double(elapsedSeconds))"),
                      "the Companion CLI dates a session's start another way")
        XCTAssertTrue(companion.contains("exactCost: nil,"), "the Companion CLI now sends a session cost")

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

    // MARK: - One refresh

    /// Every route runs its sessions through `SessionFreshnessFilter
    /// .filterCurrent` as it refreshes, which keeps a row only if it was last
    /// active within five minutes of the refresh. So the Sessions tab's Recent
    /// rows (five to thirty minutes old) are rows a refresh kept that have
    /// aged since. Demo's were 12 and 20 minutes old beside rows written "just
    /// now", which no refresh leaves. Demo is now one refresh, a little in the
    /// past: everything it shows is dated at or before it, each device synced
    /// no earlier than the sessions its sync wrote, and the filter at that
    /// moment keeps every session.
    func testDemoIsOneRefreshTheCloudRouteCouldHaveKept() throws {
        let demo = DemoDataProvider.generate()
        let refreshed = demo.refreshedAt
        XCTAssertLessThan(refreshed, Date(), "Demo's refresh has not happened yet")
        XCTAssertEqual(SessionFreshnessFilter.filterCurrent(demo.sessions, now: refreshed).map(\.id),
                       demo.sessions.map(\.id),
                       "Demo lists a session its own refresh would have dropped")

        func date(_ iso: String, _ what: String) throws -> Date {
            try XCTUnwrap(sharedISO8601Parse(iso), "\(what) is not a date: \(iso)")
        }
        // Timestamps are written to the second.
        let latest = refreshed.addingTimeInterval(1)
        let lastSync = try Dictionary(uniqueKeysWithValues: demo.devices.map {
            ($0.name, try date(try XCTUnwrap($0.last_sync_at, "\($0.name) never synced"), "\($0.name) last sync"))
        })
        for device in demo.devices {
            XCTAssertLessThanOrEqual(try XCTUnwrap(lastSync[device.name]), latest,
                                     "\(device.name) synced after the refresh that shows it")
        }
        for session in demo.sessions {
            let started = try date(session.started_at, "\(session.name) started_at")
            let lastActive = try date(session.last_active_at, "\(session.name) last_active_at")
            XCTAssertLessThanOrEqual(started, lastActive, "\(session.name) was last active before it started")
            XCTAssertLessThanOrEqual(lastActive, latest, "\(session.name) was written after the refresh that shows it")
            let synced = try XCTUnwrap(lastSync[session.device_name], "\(session.name) is on no Demo device")
            XCTAssertGreaterThanOrEqual(synced, lastActive,
                                        "\(session.name) was written after \(session.device_name)'s last sync, which wrote it")
        }
        for alert in demo.alerts {
            XCTAssertLessThanOrEqual(try date(alert.created_at, alert.id), latest,
                                     "\(alert.id) was raised after the refresh that shows it")
        }

        // Positive control: the case this is about. Demo still has Recent rows
        // now, so the Sessions screens keep their second section.
        let recent = SessionFreshnessTierClassifier.partition(demo.sessions, now: Date()).recent
        XCTAssertFalse(recent.isEmpty, "Demo has no Recent session; this test checks less than it says")
    }

    /// The refresh is recent enough that the rows written at it are still
    /// Active, and no older than the iPhone's default refresh interval, so a
    /// real iPhone is in this state between two automatic refreshes.
    func testDemosRefreshIsOneARealIPhoneIsBetween() throws {
        XCTAssertGreaterThan(DemoDataProvider.refreshAge, 0)
        XCTAssertLessThan(DemoDataProvider.refreshAge, SessionFreshnessTierClassifier.jsonlActiveWindow,
                          "the rows written at Demo's refresh are no longer Active")
        let appState = Self.codeOnly(try String(
            contentsOf: Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore/AppState.swift"), encoding: .utf8))
        let declaration = try NSRegularExpression(
            pattern: #"@AppStorage\("cli_pulse_refresh_interval"\) public var refreshInterval: Int = (\d+)"#)
        let match = try XCTUnwrap(
            declaration.firstMatch(in: appState, range: NSRange(appState.startIndex..., in: appState)),
            "AppState's refresh interval is declared another way; recheck Demo's refresh against it")
        let interval = try XCTUnwrap(Range(match.range(at: 1), in: appState).flatMap { Double(appState[$0]) })
        XCTAssertLessThanOrEqual(DemoDataProvider.refreshAge, interval,
                                 "Demo's refresh is older than a default refresh interval")
    }

    // MARK: - Alerts and the sessions they name

    /// The Swift helper's session-CPU rule fires when a session reaches 40% of
    /// the machine, by LocalScanner's figure: the session's CPU time over its
    /// whole life. The same figure sets the session's usage, runtime x
    /// (CPU% + 1), which is 100 per CPU-second plus one per second. And
    /// helper_sync keeps an alert's first created_at, rewriting only its text.
    /// So a session the rule caught at P% of N cores, T seconds into its life,
    /// had burned P/100 x N x T CPU-seconds by then and shows at least
    /// P x N x T usage on top of its runtime. Demo's alert, dated 30 minutes
    /// before the refresh on ios-dashboard 90 minutes into its life, implied
    /// 2.5M; the session showed 24.5K.
    func testTheSessionCPUAlertComesFromASessionThatCouldRaiseIt() throws {
        let demo = DemoDataProvider.generate()
        let systems = Dictionary(uniqueKeysWithValues: demo.devices.map { ($0.name, $0.system) })
        let template = try NSRegularExpression(
            pattern: #"^Using ~(\d+)% of total system CPU \((\d+) cores\) for (.+)\.$"#)
        let raised = demo.alerts.filter { $0.type == "Usage Spike" && $0.source_kind == "session" }
        XCTAssertFalse(raised.isEmpty, "Demo has no session-CPU alert; this test checks nothing")
        for alert in raised {
            let session = try XCTUnwrap(demo.sessions.first { $0.id == alert.related_session_id },
                                        "\(alert.id) names no Demo session")
            let text = alert.message
            let match = try XCTUnwrap(template.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                      "\(alert.id): \"\(text)\" is not the Swift helper's template")
            func group(_ index: Int) throws -> String {
                try XCTUnwrap(Range(match.range(at: index), in: text).map { String(text[$0]) })
            }
            let percent = try XCTUnwrap(Double(try group(1)))
            let cores = try XCTUnwrap(Double(try group(2)))
            XCTAssertEqual(try group(3), session.provider, "\(alert.id) names another provider than its session's")
            XCTAssertGreaterThanOrEqual(percent, 40, "\(alert.id) is under the rule's 40%")
            // Only the LoginItem helper writes this template, and it runs on a Mac.
            XCTAssertTrue(systems[session.device_name]?.hasPrefix("macOS") == true,
                          "\(session.name) is on \(session.device_name), where no producer writes \"\(text)\"")

            let started = try XCTUnwrap(sharedISO8601Parse(session.started_at))
            let lastActive = try XCTUnwrap(sharedISO8601Parse(session.last_active_at))
            let raisedAt = try XCTUnwrap(sharedISO8601Parse(alert.created_at))
            let firstSeen = raisedAt.timeIntervalSince(started)
            let runtime = lastActive.timeIntervalSince(started)
            XCTAssertGreaterThan(firstSeen, 0, "\(alert.id) was raised before \(session.name) started")
            XCTAssertLessThanOrEqual(raisedAt, lastActive, "\(alert.id) was raised after \(session.name) was last seen")
            // The rounding the figures go through: the percentage to a whole
            // number (so at least P - 0.5), and the CPU% that sets the usage
            // to one decimal (up to 0.05 x runtime less).
            let least = (percent - 0.5) * cores * firstSeen + 0.95 * runtime - 1
            XCTAssertGreaterThanOrEqual(Double(session.total_usage), least, """
                \(session.name): \(session.total_usage) usage, but the rule caught it at \(Int(percent))% of \
                \(Int(cores)) cores \(Int(firstSeen)) s into its life, which leaves at least \(Int(least))
                """)
        }
    }

    /// The long-running rule fires once a session has 400 requests, a
    /// request per 45 s of runtime, so it is dated no earlier than five hours
    /// into its session's life (helper_sync keeps that first date).
    func testTheLongRunningAlertComesFromASessionThatCrossed400Requests() throws {
        let demo = DemoDataProvider.generate()
        let raised = demo.alerts.filter { $0.type == "Session Too Long" }
        XCTAssertFalse(raised.isEmpty, "Demo has no long-running alert; this test checks nothing")
        for alert in raised {
            let session = try XCTUnwrap(demo.sessions.first { $0.id == alert.related_session_id },
                                        "\(alert.id) names no Demo session")
            XCTAssertGreaterThanOrEqual(session.requests, 400, "\(session.name) never reached the rule's 400 requests")
            let started = try XCTUnwrap(sharedISO8601Parse(session.started_at))
            let raisedAt = try XCTUnwrap(sharedISO8601Parse(alert.created_at))
            XCTAssertGreaterThanOrEqual(raisedAt.timeIntervalSince(started), 400 * 45,
                                        "\(alert.id) was raised before \(session.name) had 400 requests")
        }
    }

    /// The production half of the two tests above, read from the sources.
    func testTheHelpersRaiseAndKeepSessionAlertsAsDemoAssumes() throws {
        let repoRoot = Self.appSourceRoot.deletingLastPathComponent()
        let sources = Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore")
        let generator = Self.codeOnly(try String(
            contentsOf: sources.appendingPathComponent("AlertGenerator.swift"), encoding: .utf8))
        XCTAssertTrue(generator.contains("let systemFractionThreshold = 0.4"), "the session-CPU rule fires elsewhere")
        XCTAssertTrue(generator.contains("if let cpu = sessionCPU[session.id], cpu / systemCapacity >= systemFractionThreshold"),
                      "the session-CPU rule reads another figure")
        XCTAssertTrue(generator.contains(
            #""message": "Using ~\(systemPct)% of total system CPU (\(cpuCount) cores) for \(session.provider).","#),
                      "the session-CPU rule writes another message")
        XCTAssertTrue(generator.contains("if !isProcessDetected, session.requests >= 400 {"),
                      "the long-running rule fires elsewhere")

        let daemon = Self.codeOnly(try String(
            contentsOf: Self.appSourceRoot.appendingPathComponent("CLIPulseHelper/HelperDaemon.swift"), encoding: .utf8))
        XCTAssertTrue(daemon.contains("sessionCPU: scanResult.sessionCPU,"),
                      "the helper's alerts read another CPU figure than its scan's")
        let scanner = Self.codeOnly(try String(
            contentsOf: sources.appendingPathComponent("LocalScanner.swift"), encoding: .utf8))
        XCTAssertTrue(scanner.contains("pcpu = min(max(cpuNanos / elapsedNanos * 100.0, 0), 10_000)"),
                      "LocalScanner's CPU figure is no longer the session's lifetime average")
        XCTAssertTrue(scanner.contains("let usage = max(500, Int(Double(elapsed) * max(1.5, cpu + 1.0)))"),
                      "LocalScanner's usage no longer follows its CPU figure")
        XCTAssertTrue(scanner.contains("sessionCPU[session.id] = cpu"),
                      "the alert and the usage read different CPU figures")

        let sync = try String(
            contentsOf: repoRoot.appendingPathComponent("backend/supabase/helper_rpc.sql"), encoding: .utf8)
        let insert = try XCTUnwrap(sync.range(of: "insert into public.alerts"), "helper_sync stores no alerts")
        let rest = sync[insert.upperBound...]
        let upsert = try XCTUnwrap(rest.range(of: "on conflict (id, user_id) do update set"),
                                   "helper_sync no longer updates an alert it has")
        let end = try XCTUnwrap(rest.range(of: ";", range: upsert.upperBound..<rest.endIndex))
        let update = rest[upsert.upperBound..<end.lowerBound]
        XCTAssertTrue(update.contains("message = excluded.message"), "helper_sync no longer rewrites an alert's text")
        XCTAssertFalse(update.contains("created_at"),
                       "helper_sync now moves an alert's created_at; recheck Demo's alert dates")
    }

    // MARK: - Quota and cost

    /// Claude's quota is the windows ClaudeResultBuilder reports: each a
    /// percentage, and the provider's quota and remaining taken from the
    /// 5-hour one. Demo gave Claude a token quota (250K, 118K left) and no
    /// window, which no producer sends: the Mac card drew no bar for it, and
    /// the iPhone and iPad their legacy bar, filled the other way from every
    /// other bar.
    func testDemoClaudeReportsTheWindowsItsCollectorBuilds() throws {
        #if os(macOS)
        let claude = try XCTUnwrap(DemoDataProvider.generate().providers.first { $0.provider == "Claude" })
        let fiveHour = try XCTUnwrap(claude.tiers.first { $0.name == "5h Window" }, "Demo's Claude has no 5-hour window")
        let weekly = try XCTUnwrap(claude.tiers.first { $0.name == "Weekly" }, "Demo's Claude has no weekly window")
        let built = ClaudeResultBuilder.build(from: ClaudeSnapshot(
            sessionUsed: fiveHour.quota - fiveHour.remaining,
            weeklyUsed: weekly.quota - weekly.remaining,
            sourceLabel: "Demo")).usage
        XCTAssertEqual(claude.tiers.map(\.name), built.tiers.map(\.name))
        XCTAssertEqual(claude.tiers.map(\.quota), built.tiers.map(\.quota))
        XCTAssertEqual(claude.tiers.map(\.remaining), built.tiers.map(\.remaining))
        XCTAssertEqual(claude.quota, built.quota)
        XCTAssertEqual(claude.remaining, built.remaining)
        XCTAssertEqual(claude.status_text, built.status_text)
        #endif
    }

    /// Every quota bar on the Providers tabs fills to the share left: the
    /// window bars (1 - used), the account bars (`remainingFraction`), and
    /// the legacy bar a Claude without windows gets, which filled to the
    /// share used beside its own "remaining" figure.
    func testEveryQuotaBarOnTheProvidersTabsFillsTheShareLeft() throws {
        for file in ["CLI Pulse Bar/ProvidersTab.swift", "CLI Pulse Bar iOS/iOSProvidersTab.swift"] {
            let code = Self.codeOnly(try String(
                contentsOf: Self.appSourceRoot.appendingPathComponent(file), encoding: .utf8))
            var values: [String] = []
            var from = code.startIndex
            while let bar = code.range(of: "UsageBar(", range: from..<code.endIndex) {
                let call = code[bar.upperBound...]
                let label = try XCTUnwrap(call.range(of: "value:"), "\(file): a UsageBar without a value")
                let line = call[label.upperBound...].prefix { $0 != "\n" }
                values.append(line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ","))))
                from = bar.upperBound
            }
            XCTAssertGreaterThanOrEqual(values.count, 4, "\(file): the scan found \(values)")
            let shareLeft: Set = ["1.0 - tier.usagePercent", "1.0 - provider.usagePercent", "fraction"]
            for value in values {
                XCTAssertTrue(shareLeft.contains(value), "\(file): a quota bar filled to \(value)")
            }
            // Every `fraction` there is a share left.
            for definition in code.components(separatedBy: "let fraction =").dropFirst() {
                let source = definition.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertTrue(source.hasPrefix("remainingFraction(") || source.hasPrefix("ProviderState.remainingFraction("),
                              "\(file): a bar's fraction is \(source.prefix(60))")
            }
            XCTAssertTrue(code.contains("min(max(Double(remaining) / Double(quota), 0), 1)"),
                          "\(file): remainingFraction is no longer the share left")
        }
    }

    /// CodexCollector and GeminiCollector, like ClaudeResultBuilder, report
    /// every window and the provider's own quota and remaining as
    /// percentages: quota 100, the share left. The cloud keeps what the Mac
    /// uploads. Demo gave Codex and Gemini token counts (500K with 38K left,
    /// 300K with 86K left), which the Watch's provider screen printed as its
    /// Quota and Remaining rows, where a real Codex reads 100 and 8.
    func testDemoCodexAndGeminiReportTheWindowsTheirCollectorsBuild() throws {
        let providers = DemoDataProvider.generate().providers
        for provider in providers {
            XCTAssertEqual(provider.quota, 100, "\(provider.provider)'s quota is not a percentage")
            XCTAssertFalse(provider.tiers.isEmpty, "\(provider.provider) has no window")
            for tier in provider.tiers {
                XCTAssertEqual(tier.quota, 100, "\(provider.provider) \(tier.name) is not a percentage")
            }
        }
        #if os(macOS)
        func assertBuilt(_ demo: ProviderUsage, _ built: ProviderUsage) {
            XCTAssertEqual(demo.tiers.map(\.name), built.tiers.map(\.name), demo.provider)
            XCTAssertEqual(demo.tiers.map(\.quota), built.tiers.map(\.quota), demo.provider)
            XCTAssertEqual(demo.tiers.map(\.remaining), built.tiers.map(\.remaining), demo.provider)
            XCTAssertEqual(demo.quota, built.quota, demo.provider)
            XCTAssertEqual(demo.remaining, built.remaining, demo.provider)
            XCTAssertEqual(demo.status_text, built.status_text, demo.provider)
        }

        // A weekly-only account: /wham/usage sends its one window in the
        // primary slot, and the collector files it by its length.
        let codex = try XCTUnwrap(providers.first { $0.provider == "Codex" })
        let weekly = try XCTUnwrap(codex.tiers.first { $0.name == "Weekly" }, "Demo's Codex has no weekly window")
        let usage = try CodexCollector.parseUsage(Data("""
            {"plan_type": "plus", "rate_limit": {"primary_window":
             {"used_percent": \(weekly.quota - weekly.remaining), "limit_window_seconds": 604800}}}
            """.utf8))
        assertBuilt(codex, CodexCollector().buildResult(usage: usage, accountHadCredits: false).usage)

        // Google sends a fraction left, which the collector truncates to a
        // whole percent; a Pro bucket 0.3 points above Demo's.
        let gemini = try XCTUnwrap(providers.first { $0.provider == "Gemini" })
        let pro = try XCTUnwrap(gemini.tiers.first { $0.name == "Pro" }, "Demo's Gemini has no Pro window")
        let buckets = try GeminiCollector.parseQuota(Data("""
            {"buckets": [{"modelId": "gemini-2.5-pro", "remainingFraction": \((Double(pro.remaining) + 0.3) / 100)}]}
            """.utf8))
        assertBuilt(gemini, GeminiCollector().buildResult(buckets: buckets, tierInfo: nil).usage)
        #endif
    }

    // MARK: - Devices

    /// The cloud stores one device status, "Online": register_helper and the
    /// desktop's sign-in insert it, every heartbeat and sync sets it, and no
    /// SQL writes another. So a device that has stopped syncing still reads
    /// Online, and `dashboard_summary`'s Online Devices counts every device.
    /// Demo had build-box "offline", a status only the retired backend wrote,
    /// and the others in lower case, which `DeviceStatus` (the Watch's
    /// machine card) does not read as online.
    func testDemoDevicesReadOnlineAsTheCloudStoresThem() throws {
        let demo = DemoDataProvider.generate()
        for device in demo.devices {
            XCTAssertEqual(device.status, "Online", "\(device.name) has a status the cloud never stores")
            XCTAssertEqual(device.deviceStatus, .online, device.name)
        }
        XCTAssertEqual(demo.dashboard.online_devices, demo.devices.count,
                       "the Online Devices tile leaves out a device dashboard_summary counts")
        // Positive control: the case this is about. A device has stopped
        // syncing well before the others, and still reads Online.
        let syncs = try demo.devices.map {
            try XCTUnwrap(sharedISO8601Parse($0.last_sync_at ?? ""), "\($0.name) never synced")
        }
        let spread = try XCTUnwrap(syncs.max()).timeIntervalSince(try XCTUnwrap(syncs.min()))
        XCTAssertGreaterThanOrEqual(spread, 240, "no Demo device has stopped syncing; this test checks less than it says")

        // The production half, from every SQL file the cloud is built from.
        let supabase = Self.appSourceRoot.deletingLastPathComponent().appendingPathComponent("backend/supabase")
        let files = try FileManager.default.contentsOfDirectory(at: supabase, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sql" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 50, "found \(files.count) SQL files; is this still the cloud's schema?")
        // Read with any line ending, so a CRLF checkout compares the same lines.
        func sql(_ url: URL) throws -> String {
            try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        }
        var otherStatuses: [String] = []
        for file in files {
            for line in try sql(file).components(separatedBy: "\n") {
                let lowered = line.lowercased()
                if lowered.contains("'offline'") || lowered.contains("'degraded'") || line.contains("'online'") {
                    otherStatuses.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(otherStatuses, ["schema.sql: status text not null default 'Offline',"],
                       "SQL writes a device status other than 'Online'; Demo may show one again")
        let helper = try sql(supabase.appendingPathComponent("helper_rpc.sql"))
        XCTAssertTrue(helper.contains("left(p_helper_version, 20), 'Online',"),
                      "register_helper inserts its device with another status")
        XCTAssertTrue(helper.contains("status = 'Online', cpu_usage = p_cpu_usage,"),
                      "the helper's heartbeat no longer marks its device Online")
        for name in ["app_rpc.sql", "migrate_v0.44_user_tz_today.sql"] {
            let summary = try sql(supabase.appendingPathComponent(name))
            XCTAssertTrue(summary.contains("from public.devices\n      where user_id = v_user_id and status = 'Online'"),
                          "\(name): dashboard_summary counts Online Devices another way")
        }
    }

    /// The server's 30-day figure (`provider_summary`,
    /// `provider_account_summary`) sums the last 30 days of
    /// `daily_usage_metrics`, a window that holds the week's and today's, so
    /// a provider's 30-day figure is at least its week's, which is at least
    /// today's; and a provider with a cost this week has one. Demo had none,
    /// so the app took week x 4.3, a fallback for servers that predate it.
    func testDemoCarriesTheServers30DayFigure() throws {
        for provider in DemoDataProvider.generate().providers {
            XCTAssertGreaterThanOrEqual(provider.estimated_cost_week, provider.estimated_cost_today, provider.provider)
            XCTAssertGreaterThanOrEqual(provider.estimated_cost_30_day, provider.estimated_cost_week, provider.provider)
            if provider.estimated_cost_week > 0 {
                XCTAssertGreaterThan(provider.estimated_cost_30_day, 0,
                                     "\(provider.provider) has no 30-day figure, so the app falls back to week x 4.3")
            }
        }
        let supabase = Self.appSourceRoot.deletingLastPathComponent().appendingPathComponent("backend/supabase")
        let accounts = try String(
            contentsOf: supabase.appendingPathComponent("migrate_v0.72_provider_accounts.sql"), encoding: .utf8)
        XCTAssertTrue(accounts.contains("v_week_start date := v_today - 6;")
                      && accounts.contains("v_month_start date := v_today - 29;"),
                      "provider_account_summary's windows changed")
        XCTAssertTrue(accounts.contains("'estimated_cost_30_day', coalesce(u.month_cost, 0)"),
                      "provider_account_summary sends another 30-day figure")
        let legacy = try String(
            contentsOf: supabase.appendingPathComponent("migrate_v0.44_user_tz_today.sql"), encoding: .utf8)
        XCTAssertTrue(legacy.contains("v_week_start date := v_today - interval '6 days';")
                      && legacy.contains("v_month_start date := v_today - interval '29 days';"),
                      "provider_summary's windows changed")
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

    /// The card prints each row and the total to the cent, so the rows as
    /// printed must add up to the total as printed. Demo's providers had no
    /// 30-day figure, the app took week x 4.3, and $23.82 + $8.51 sat under
    /// a total of $32.34.
    func testTheCostSummaryRowsAddUpToItsTotals() throws {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        state.enterDemoMode()
        let summary = state.providerState.costSummary
        func printed(_ usd: Double) throws -> Decimal {
            let text = CurrencyConverter.shared.format(usd, as: .usd, locale: Locale(identifier: "en_US"))
            let digits = text.filter { $0.isNumber || $0 == "." }
            return try XCTUnwrap(Decimal(string: digits), "\(text) is not an amount")
        }
        let thirtyDayRows = try summary.thirtyDayByProvider.map { try printed($0.cost) }
        XCTAssertEqual(thirtyDayRows.reduce(0, +), try printed(summary.thirtyDayTotal),
                       "30-day rows \(thirtyDayRows) do not add up to the total printed above them")
        let todayRows = try summary.todayByProvider.map { try printed($0.cost) }
        XCTAssertEqual(todayRows.reduce(0, +), try printed(summary.todayTotal),
                       "today's rows \(todayRows) do not add up to the total printed above them")
        // Positive control: there are rows to add.
        XCTAssertEqual(thirtyDayRows.count, 2, "\(summary.thirtyDayByProvider)")
    }

    /// Demo shows its own refresh as the last one ("Updated 1 min ago"), not
    /// the moment it was entered: its Recent sessions are older than a
    /// refresh keeps, so only an earlier refresh can have left them.
    func testDemoShowsItsRefreshAsTheLastOne() throws {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        state.enterDemoMode()
        let lastRefresh = try XCTUnwrap(state.lastRefresh, "Demo shows no refresh")
        XCTAssertEqual(Date().timeIntervalSince(lastRefresh), DemoDataProvider.refreshAge, accuracy: 30,
                       "Demo's last refresh is not the refresh its data came from")
        XCTAssertEqual(SessionFreshnessFilter.filterCurrent(state.sessions, now: lastRefresh).count,
                       state.sessions.count, "a session the refresh shown would have dropped")
        // Positive control: there are Recent rows for it to explain.
        XCTAssertFalse(SessionFreshnessTierClassifier.partition(state.sessions, now: Date()).recent.isEmpty)
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

#if DEBUG
import XCTest
@testable import CLIPulseCore

/// The Apple Watch App Store screenshot capture (`WatchScreenshotLaunch`): how
/// it reads its arguments, what the Watch holds in a capture, and that the
/// Watch app and the capture script agree on the pages. That none of it ships
/// in Release is `ScreenshotLaunchTests.test_everyUseIsInsideIfDebug`, whose
/// scan covers the Watch target and matches `WatchScreenshotLaunch`.
final class WatchScreenshotLaunchTests: XCTestCase {

    private typealias Launch = WatchScreenshotLaunch

    private func parse(_ args: String...) -> Launch.Parsed {
        Launch.parse(["/path/to/CLI Pulse Watch.app/CLI Pulse Watch"] + args)
    }

    private func assertInvalid(_ parsed: Launch.Parsed, mentioning needle: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .invalid(let reason) = parsed else {
            return XCTFail("expected .invalid, got \(parsed)", file: file, line: line)
        }
        XCTAssertTrue(reason.contains(needle), "\(reason) does not mention \(needle)", file: file, line: line)
    }

    // MARK: - Parsing

    func test_theArgumentsAreTheIPhoneCapturesAndReadTheSameWay() {
        XCTAssertEqual(Launch.demoArgument, ScreenshotLaunch.demoArgument)
        XCTAssertEqual(Launch.screenArgument, ScreenshotLaunch.screenArgument)
        XCTAssertEqual(Launch.readyMarker, ScreenshotLaunch.readyMarker)
        XCTAssertEqual(Launch.errorMarker, ScreenshotLaunch.errorMarker)

        XCTAssertEqual(parse(), .notRequested)
        XCTAssertEqual(parse("-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"), .notRequested)
        for screen in Launch.Screen.allCases {
            XCTAssertEqual(parse("-AppleLanguages", "(ko)", "-CLIPulseScreenshotDemo", "YES",
                                 "-CLIPulseScreenshotScreen", screen.rawValue), .request(screen))
            XCTAssertEqual(parse("-CLIPulseScreenshotScreen", screen.rawValue, "-CLIPulseScreenshotDemo", "1"),
                           .request(screen))
        }
        for yes in ["YES", "yes", "true", "1"] {
            XCTAssertEqual(parse("-CLIPulseScreenshotDemo", yes), .request(.pulse), yes)
        }
        for no in ["NO", "false", "0"] {
            XCTAssertEqual(parse("-CLIPulseScreenshotDemo", no), .notRequested, no)
        }
    }

    func test_argumentsThatCannotBeHonouredAreErrors() {
        assertInvalid(parse("-CLIPulseScreenshotDemo"), mentioning: "needs a value")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "YES", "-CLIPulseScreenshotScreen"), mentioning: "needs a value")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "maybe"), mentioning: "'maybe'")
        // An iPhone screen name is not a Watch page.
        assertInvalid(parse("-CLIPulseScreenshotDemo", "YES", "-CLIPulseScreenshotScreen", "overview"),
                      mentioning: "pulse, quota, live, alerts")
        assertInvalid(parse("-CLIPulseScreenshotScreen", "quota"), mentioning: "needs -CLIPulseScreenshotDemo YES")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "NO", "-CLIPulseScreenshotScreen", "quota"),
                      mentioning: "needs -CLIPulseScreenshotDemo YES")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "YES", "-CLIPulseScreenshotDemo", "YES"), mentioning: "twice")
        assertInvalid(parse("-CLIPulseScreenshotDemo", "YES", "-CLIPulseScreenshotScreen", "live",
                            "-CLIPulseScreenshotScreen", "alerts"), mentioning: "twice")
    }

    // MARK: - What the Watch holds in a capture

    /// A Watch's dashboard is only ever the cloud's `dashboard_summary` row,
    /// so the capture's carries Demo's five figures and nothing that row
    /// lacks: no requests, no hourly trend, no recent activity, no top
    /// projects, no risk signals.
    func test_theDashboardIsDemosFiguresThroughTheCloudMapping() {
        let demo = DemoDataProvider.generate()
        let dash = Launch.watchSnapshot(of: demo).dashboard
        XCTAssertEqual(dash.total_usage_today, demo.dashboard.total_usage_today)
        XCTAssertEqual(dash.total_estimated_cost_today, demo.dashboard.total_estimated_cost_today)
        XCTAssertEqual(dash.active_sessions, demo.dashboard.active_sessions)
        XCTAssertEqual(dash.online_devices, demo.dashboard.online_devices)
        XCTAssertEqual(dash.unresolved_alerts, demo.dashboard.unresolved_alerts)
        XCTAssertEqual(dash.total_requests_today, 0)
        XCTAssertTrue(dash.trend.isEmpty && dash.recent_activity.isEmpty && dash.top_projects.isEmpty
                      && dash.risk_signals.isEmpty && dash.provider_breakdown.isEmpty)
        // Positive control: Demo's figures are not zero, so the equalities above say something.
        XCTAssertGreaterThan(dash.total_usage_today, 0)
        XCTAssertGreaterThan(dash.total_estimated_cost_today, 0)
        XCTAssertGreaterThan(dash.active_sessions, 0)
        XCTAssertGreaterThan(dash.unresolved_alerts, 0)
    }

    func test_theListsAreInTheOrderTheWatchGetsThem() throws {
        let demo = DemoDataProvider.generate()
        let snap = Launch.watchSnapshot(of: demo)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(snap.providers),
                       try encoder.encode(QuotaBindingCap.projectedForDisplay(demo.providers)),
                       "the providers as the Watch projects them")
        XCTAssertEqual(Set(snap.sessions.map(\.id)), Set(demo.sessions.map(\.id)))
        func times(_ values: [String]) throws -> [Date] { try values.map { try XCTUnwrap(sharedISO8601Parse($0)) } }
        let sessionTimes = try times(snap.sessions.map(\.last_active_at))
        XCTAssertEqual(sessionTimes, sessionTimes.sorted(by: >), "sessions: last_active_at.desc")
        // The alerts as the iPhone relays them: its own list, the cloud's rows
        // newest first and then the quota alert it raised, which only the relay
        // brings to a Watch (DemoMatchesProductionTests holds Demo to that order).
        XCTAssertEqual(snap.alerts.map(\.id), demo.alerts.map(\.id), "alerts: the iPhone's order")
        XCTAssertTrue(snap.alerts.last?.id.hasPrefix("quota-") == true,
                      "the quota alert the iPhone appends is not last")
        XCTAssertEqual(snap.refreshedAt, demo.refreshedAt)
    }

    /// The Watch draws a machine card only for a device that reports machine
    /// health (`WatchDeviceTrim`). Demo's devices report none, so a capture
    /// draws no machine card, as a real account with such devices sees it.
    func test_theDevicesAreTheOnesTheWatchTrimKeeps() {
        let demo = DemoDataProvider.generate()
        let snap = Launch.watchSnapshot(of: demo)
        XCTAssertEqual(snap.devices, WatchDeviceTrim.summaries(from: demo.devices))
        XCTAssertTrue(snap.devices.isEmpty, "a Demo device now reports machine health; check the Pulse page's cards")
        XCTAssertFalse(demo.devices.isEmpty, "positive control")
    }

    func test_readyOnlyWhenTheRequestedPageIsSelectedAndHasAppeared() {
        XCTAssertEqual(Launch.readinessLine(for: .quota, selected: .quota, appeared: [.pulse, .quota]),
                       "CLIPULSE_SCREENSHOT_READY quota")
        let wrongPage = Launch.readinessLine(for: .quota, selected: .pulse, appeared: [.pulse])
        XCTAssertTrue(wrongPage.hasPrefix("CLIPULSE_SCREENSHOT_ERROR quota:"), wrongPage)
        XCTAssertTrue(wrongPage.contains("on pulse") && wrongPage.contains("never appeared"), wrongPage)
        XCTAssertTrue(Launch.readinessLine(for: .live, selected: .live, appeared: [])
            .hasPrefix("CLIPULSE_SCREENSHOT_ERROR live:"))
    }

    // MARK: - The Watch app and the capture script

    /// The pager's pages, in order, are the set's pages: each tagged with its
    /// `WatchTab` and marked for the READY check.
    func test_theWatchPagerShowsTheSetsPagesInOrder() throws {
        let main = try String(contentsOf: Self.appSourceRoot
            .appendingPathComponent("CLI Pulse Bar Watch/WatchMainView.swift"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"\.screenshotPage\(\.(\w+)\)\s*\.tag\(WatchTab\.(\w+)\)"#)
        let pairs = regex.matches(in: main, range: NSRange(main.startIndex..., in: main)).map { m in
            (String(main[Range(m.range(at: 1), in: main)!]), String(main[Range(m.range(at: 2), in: main)!]))
        }
        XCTAssertEqual(pairs.map(\.0), Launch.Screen.allCases.map(\.rawValue))
        XCTAssertEqual(pairs.map(\.1), Launch.Screen.allCases.map(\.rawValue))
        XCTAssertTrue(main.contains("WatchMainView.initialTab"), "the pager no longer starts on the requested page")

        let state = try String(contentsOf: Self.appSourceRoot
            .appendingPathComponent("CLI Pulse Bar Watch/WatchAppState.swift"), encoding: .utf8)
        for function in ["func refreshAll() async {", "func startRefreshLoop() {"] {
            let start = try XCTUnwrap(state.range(of: function), function)
            let head = state[start.upperBound...].prefix(160)
            XCTAssertTrue(head.contains("WatchScreenshotLaunch.activeScreen != nil { return }"),
                          "\(function) reaches the network in a capture")
        }
        let initBody = try XCTUnwrap(state.range(of: "applyScreenshotDemo(WatchScreenshotLaunch.demoSnapshot())"))
        let restore = try XCTUnwrap(state.range(of: "Task { await restoreSession() }"))
        XCTAssertLessThan(initBody.lowerBound, restore.lowerBound, "the capture restores a session first")
    }

    func test_theCaptureScriptNamesTheSamePages() throws {
        let script = try String(contentsOf: Self.appSourceRoot
            .appendingPathComponent("scripts/capture_ios_screenshots.sh"), encoding: .utf8)
        let line = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix("WATCH_SCREENS=(") },
                                 "no WATCH_SCREENS=( … ) line in capture_ios_screenshots.sh")
        let names = line.dropFirst("WATCH_SCREENS=(".count).prefix { $0 != ")" }
            .split(separator: " ").map(String.init)
        XCTAssertEqual(names, Launch.Screen.allCases.map(\.rawValue))
    }

    /// `CLI Pulse Bar/`, which holds the package and every app target.
    private static var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .deletingLastPathComponent()   // CLI Pulse Bar
    }
}
#endif

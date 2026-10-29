// 1.60 (59-05): the Overview, the exports, the widgets, Siri and the Watch
// count active sessions and online devices from the rows, at the time they
// show them (`DashboardCounts`).
//
// The acceptance case: a widget drawn 301 s after the app published one
// running session shows 0. Reading the payload's frozen figure shows 1 there,
// which is what `testAWidgetDrawn301SecondsAfterThePublishCountsNoSession`
// exists to catch.

import Foundation
#if canImport(PDFKit) && !os(watchOS)
import PDFKit
#endif
import XCTest
@testable import CLIPulseCore

final class DashboardCountsTests: XCTestCase {

    private static let iso = ISO8601DateFormatter()
    /// A whole second, so the ISO 8601 strings (no fraction) round-trip exactly.
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func session(_ id: String, lastActive: Date, status: String = "Running") -> SessionRecord {
        SessionRecord(
            id: id, name: "Claude", provider: "Claude", project: "p",
            device_name: "Mac", started_at: iso.string(from: lastActive.addingTimeInterval(-600)),
            last_active_at: iso.string(from: lastActive), status: status,
            total_usage: 0, estimated_cost: 0, cost_status: "Estimated", requests: 0, error_count: 0)
    }

    static func device(_ id: String, status: String = "Online", lastSeen: Date?) -> DeviceRecord {
        DeviceRecord(
            id: id, name: id, type: "macOS", system: "macOS", status: status,
            last_sync_at: lastSeen.map(iso.string(from:)), helper_version: "1.0",
            current_session_count: 0, cpu_usage: nil, memory_usage: nil)
    }

    // MARK: - Sessions

    /// The tile counts what the Sessions tab lists under Active, at any time.
    func testActiveSessionsAreTheSessionsTabsActiveRows() {
        let sessions = [
            Self.session("local-1", lastActive: Self.t0),
            Self.session("proc-2", lastActive: Self.t0.addingTimeInterval(-200)),
            Self.session("jsonl-claude-a", lastActive: Self.t0.addingTimeInterval(-100)),
            Self.session("jsonl-claude-b", lastActive: Self.t0.addingTimeInterval(-900)),   // Recent, not Active
            Self.session("local-3", lastActive: Self.t0.addingTimeInterval(-3600)),         // a zombie Running row
        ]
        for offset in stride(from: 0.0, through: 1200, by: 50) {
            let now = Self.t0.addingTimeInterval(offset)
            XCTAssertEqual(DashboardCounts.activeSessions(sessions, now: now),
                           SessionFreshnessTierClassifier.partition(sessions, now: now).active.count,
                           "at +\(offset) s")
        }
        XCTAssertEqual(DashboardCounts.activeSessions(sessions, now: Self.t0), 3)
    }

    /// The times the payload carries, counted again later, give what the rows
    /// themselves would give then: one window serves both kinds of Active row.
    func testOneWindowRecountsEveryActiveTier() {
        XCTAssertEqual(SessionFreshnessTierClassifier.processFreshnessWindow,
                       SessionFreshnessTierClassifier.jsonlActiveWindow,
                       "a scan row and a log row leave Active at different ages; one window cannot recount both")
        XCTAssertEqual(DashboardCounts.sessionActiveWindow, SessionFreshnessTierClassifier.processFreshnessWindow)
        for id in ["local-7", "proc-8", "jsonl-codex-9"] {
            let row = [Self.session(id, lastActive: Self.t0)]
            let times = DashboardCounts.activeSessionTimes(row, now: Self.t0)
            XCTAssertEqual(times, [Self.t0], id)
            for later in [-1.0, 0, 1, 299, 300, 301, 1000] {
                let now = Self.t0.addingTimeInterval(later)
                XCTAssertEqual(DashboardCounts.activeSessions(lastActiveAt: times, now: now),
                               DashboardCounts.activeSessions(row, now: now),
                               "\(id) at +\(later) s")
            }
        }
    }

    func testOnlyActiveRowsAreTimedAndTheyComeOldestFirst() {
        let rows = [
            Self.session("local-1", lastActive: Self.t0),
            Self.session("jsonl-claude-b", lastActive: Self.t0.addingTimeInterval(-900)),   // Recent
            Self.session("proc-2", lastActive: Self.t0.addingTimeInterval(-120)),
        ]
        XCTAssertEqual(DashboardCounts.activeSessionTimes(rows, now: Self.t0),
                       [Self.t0.addingTimeInterval(-120), Self.t0])
    }

    /// A payload without times (one from before 1.60, or Demo's) keeps its
    /// figure.
    func testWithoutTimesThePublishedFigureStands() {
        XCTAssertEqual(DashboardCounts.activeSessions(published: 3, lastActiveAt: nil, now: Self.t0), 3)
        XCTAssertEqual(DashboardCounts.activeSessions(published: 3, lastActiveAt: [], now: Self.t0), 0,
                       "an empty list is a count of none, not a missing one")
    }

    // MARK: - The acceptance case: the widget payload, published then drawn

    /// What the widget extension and Siri decode: the keys of `WidgetData`
    /// and `CLIPulseIntentCache.Snapshot` that the count needs.
    /// `DashboardCountsSourceScanTests` holds both declarations to them.
    private struct DecodedLikeTheWidget: Decodable {
        let activeSessions: Int
        let activeSessionLastActiveAt: [Date]?
    }

    @MainActor
    func testAWidgetDrawn301SecondsAfterThePublishCountsNoSession() throws {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UserDefaults(suiteName: "DashboardCountsTests.\(UUID().uuidString)")!,
            performLaunchSetup: false)
        // The publish happens now: a scan row its producer just rewrote, and
        // a log row written a minute earlier.
        let published = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        state.sessions = [
            Self.session("local-4242", lastActive: published),
            Self.session("jsonl-claude-x", lastActive: published.addingTimeInterval(-60)),
        ]
        let payload = state.widgetPayload(converter: CurrencyConverter(
            defaults: UserDefaults(suiteName: "fx-\(UUID().uuidString)")!))
        XCTAssertEqual(payload.activeSessions, 2)

        let widget = try JSONDecoder().decode(DecodedLikeTheWidget.self, from: JSONEncoder().encode(payload))
        func drawn(_ after: TimeInterval) -> Int {
            DashboardCounts.activeSessions(
                published: widget.activeSessions, lastActiveAt: widget.activeSessionLastActiveAt,
                now: published.addingTimeInterval(after))
        }
        XCTAssertEqual(drawn(0), 2)
        XCTAssertEqual(drawn(240), 2)
        XCTAssertEqual(drawn(241), 1, "the log row is 301 s old by now")
        XCTAssertEqual(drawn(300), 1)
        XCTAssertEqual(drawn(301), 0, "a widget drawn 301 s after the publish still counts the sessions it was given")
    }

    /// A rewritten row moves the time its session stops counting, so the
    /// publish that carries it is not skipped as unchanged.
    func testANewLastActiveTimeIsANewPayload() {
        func payload(_ times: [Date]?) -> PublishedWidgetData {
            PublishedWidgetData(
                totalUsageToday: 1, totalCostToday: 1, activeSessions: 1, unresolvedAlerts: 0,
                providers: [], lastUpdated: Self.t0, isPro: true,
                activeSessionLastActiveAt: times)
        }
        XCTAssertFalse(payload([Self.t0]).hasSameContent(as: payload([Self.t0.addingTimeInterval(120)])))
        XCTAssertTrue(payload([Self.t0]).hasSameContent(as: payload([Self.t0])))
    }

    // MARK: - Devices

    func testADeviceIsOnlineWhenStoredOnlineAndSeenWithinTheGrace() {
        let now = Self.t0
        func online(_ status: String, _ seenAgo: TimeInterval?) -> Bool {
            Self.device("d", status: status, lastSeen: seenAgo.map { now.addingTimeInterval(-$0) }).isOnline(now: now)
        }
        XCTAssertTrue(online("Online", 0))
        XCTAssertTrue(online("Online", 1800))
        XCTAssertFalse(online("Online", 1801), "seen over 30 minutes ago")
        XCTAssertFalse(online("Online", nil), "never seen")
        XCTAssertTrue(online("online", 60), "this Mac's own row in local mode")
        XCTAssertFalse(online("Offline", 0))
        XCTAssertFalse(online("Degraded", 0))
        XCTAssertEqual(DashboardCounts.deviceOnlineGrace, 1800)

        let devices = [
            Self.device("a", lastSeen: now.addingTimeInterval(-60)),
            Self.device("b", lastSeen: now.addingTimeInterval(-7 * 86_400)),   // paired once, long gone
            Self.device("c", lastSeen: now.addingTimeInterval(-1799)),
        ]
        XCTAssertEqual(DashboardCounts.onlineDevices(devices, now: now), 2)
    }

    /// The device list's word: Online only while the device counts as online.
    func testTheListSaysOfflineForADeviceNotSeenWithinTheGrace() {
        let now = Self.t0
        let gone = WatchDeviceSummary(from: Self.device("b", lastSeen: now.addingTimeInterval(-7200)))
        let here = WatchDeviceSummary(from: Self.device("a", lastSeen: now.addingTimeInterval(-30)))
        XCTAssertEqual(gone.displayStatus(now: now), "Offline")
        XCTAssertFalse(gone.isOnline(now: now))
        XCTAssertEqual(here.displayStatus(now: now), "Online")
        XCTAssertTrue(here.isOnline(now: now))
        XCTAssertEqual(DashboardCounts.displayStatus(status: "Degraded", lastSeenAt: nil, now: now), "Degraded",
                       "a status other than Online is shown as stored")
    }

    /// The iPhone sends the time to the Watch; a payload from an iPhone that
    /// predates it still decodes.
    func testTheWatchSummaryCarriesWhenTheDeviceWasLastSeen() throws {
        let seen = Self.t0.addingTimeInterval(-42)
        let summary = WatchDeviceSummary(from: Self.device("a", lastSeen: seen))
        XCTAssertEqual(summary.lastSyncAt, Self.iso.string(from: seen))
        let roundTrip = try JSONDecoder().decode(WatchDeviceSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(roundTrip.lastSyncAt, summary.lastSyncAt)

        let old = #"{"id":"a","name":"Mac","status":"Online"}"#
        let decoded = try JSONDecoder().decode(WatchDeviceSummary.self, from: Data(old.utf8))
        XCTAssertNil(decoded.lastSyncAt)
        XCTAssertFalse(decoded.isOnline(now: Self.t0), "no time, so not known to be online")
    }

    // MARK: - The Mac: no more raising the figure to the list

    /// A dashboard that still counts rows the list has dropped (the server's
    /// figure from before v0.87, or one fixed at a refresh) no longer decides
    /// the tile.
    @MainActor
    func testTheTileCountsTheRowsNotTheDashboardsFigure() {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UserDefaults(suiteName: "DashboardCountsTests.\(UUID().uuidString)")!,
            performLaunchSetup: false)
        let now = Date()
        state.dashboard = Self.dashboard(activeSessions: 82, onlineDevices: 94)
        state.sessions = [
            Self.session("local-1", lastActive: now.addingTimeInterval(-30)),
            Self.session("local-2", lastActive: now.addingTimeInterval(-86_400)),
        ]
        state.devices = [
            Self.device("a", lastSeen: now.addingTimeInterval(-30)),
            Self.device("b", lastSeen: now.addingTimeInterval(-86_400)),
        ]
        XCTAssertEqual(state.dashboardCounts(now: now), DashboardCounts(activeSessions: 1, onlineDevices: 1))
    }

    static func dashboard(activeSessions: Int, onlineDevices: Int) -> DashboardSummary {
        DashboardSummary(
            total_usage_today: 1, total_estimated_cost_today: 1, cost_status: "Estimated",
            total_requests_today: 0, active_sessions: activeSessions, online_devices: onlineDevices,
            unresolved_alerts: 0, provider_breakdown: [], top_projects: [], trend: [],
            recent_activity: [], risk_signals: [], alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0))
    }

    // MARK: - Both exports

    func testTheCostReportCSVPrintsTheCountsNotTheDashboardsFigures() {
        let csv = ExportService.costReportCSV(
            dashboard: Self.dashboard(activeSessions: 7777, onlineDevices: 8888),
            counts: DashboardCounts(activeSessions: 4242, onlineDevices: 4343),
            providers: [], sessions: [], hidePersonalInfo: false, projectNumbers: .none)
        XCTAssertTrue(csv.contains(",4242\n"), csv)
        XCTAssertTrue(csv.contains(",4343\n"), csv)
        XCTAssertFalse(csv.contains("7777") || csv.contains("8888"), "the export printed the dashboard's figures")
    }

    #if canImport(PDFKit) && !os(watchOS)
    func testThePDFReportPrintsTheCountsNotTheDashboardsFigures() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-counts.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let written = PDFReportGenerator.generateReport(
            dashboard: Self.dashboard(activeSessions: 7777, onlineDevices: 8888),
            counts: DashboardCounts(activeSessions: 4242, onlineDevices: 4343),
            providers: [], sessions: [], dailyUsage: [], costForecast: nil,
            hidePersonalInfo: false, projectNumbers: .none, destinationURL: url)
        let text = try XCTUnwrap(written.flatMap(PDFDocument.init(url:))?.string)
        XCTAssertTrue(text.contains("4242") && text.contains("4343"), text)
        XCTAssertFalse(text.contains("7777") || text.contains("8888"), "the PDF printed the dashboard's figures")
    }
    #endif

    // MARK: - The clock

    func testTheSessionsClockIsNowExceptInDemo() {
        let now = Self.t0
        XCTAssertEqual(SessionsClock.at(now, demoRefresh: nil), now)
        let refresh = now.addingTimeInterval(-3600)
        XCTAssertEqual(SessionsClock.at(now, demoRefresh: refresh),
                       refresh.addingTimeInterval(DemoDataProvider.refreshAge))
        XCTAssertEqual(SessionsClock.at(now, demoRefresh: now), now, "never later than now")
    }
}

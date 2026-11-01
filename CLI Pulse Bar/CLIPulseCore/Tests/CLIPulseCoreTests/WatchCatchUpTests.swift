// 1.61 (B4, 59-09): the Watch's Live page and Devices chip count on the rule
// and clock the iPhone, the Mac and the widgets use (`DashboardCounts`,
// `SessionsClock`), and Demo still gives a truthful Live page and Pulse chips
// under it (the 03_live and 04_alerts store panels are captured from Demo).

import Foundation
import XCTest
@testable import CLIPulseCore

final class WatchCatchUpTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ offset: TimeInterval) -> String {
        sharedISO8601Formatter.string(from: now.addingTimeInterval(offset))
    }

    private func session(_ id: String, lastActive: TimeInterval, status: String = "Running") -> SessionRecord {
        SessionRecord(id: id, name: "claude", provider: "Claude", project: "p", device_name: "Mac",
                      started_at: iso(-3_600), last_active_at: iso(lastActive), status: status,
                      total_usage: 0, estimated_cost: 0, cost_status: "Estimated", requests: 0,
                      error_count: 0, collection_confidence: "high")
    }

    // MARK: - Live page

    /// A row the cloud still stores as Running, whose device stopped rewriting
    /// it, is not live; a log row inside 30 minutes is Recent; the page's live
    /// rows are the chip's figure at every moment.
    func test_the_Live_page_lists_what_the_chip_counts_by_freshness_not_stored_status() {
        let sessions = [
            session("local-1", lastActive: -60),                     // scan row, rewritten a minute ago
            session("local-2", lastActive: -400),                    // scan row its Mac stopped rewriting
            session("proc-3", lastActive: -30, status: "Ended"),     // fresh scan row, stale status
            session("jsonl-4", lastActive: -100),                    // a log written recently
            session("jsonl-5", lastActive: -900),                    // a log from 15 minutes ago
            session("jsonl-6", lastActive: -2_000),                  // older than 30 minutes
        ]
        let page = WatchLivePage.sections(sessions, now: now)
        XCTAssertEqual(page.live.map(\.id), ["proc-3", "local-1", "jsonl-4"])
        XCTAssertEqual(page.recent.map(\.id), ["jsonl-5"])
        for offset in stride(from: 0.0, through: 2_400, by: 60) {
            let at = now.addingTimeInterval(offset)
            XCTAssertEqual(WatchLivePage.sections(sessions, now: at).live.count,
                           DashboardCounts.activeSessions(sessions, now: at), "+\(offset) s")
        }
    }

    // MARK: - Devices chip

    func test_the_Devices_chip_counts_every_device_on_the_1800_second_rule() {
        let presence = [
            WatchDevicePresence(status: "Online", lastSyncAt: iso(-60)),
            WatchDevicePresence(status: "Online", lastSyncAt: iso(-1_800)),      // at the grace: online
            WatchDevicePresence(status: "Online", lastSyncAt: iso(-1_801)),      // past it
            WatchDevicePresence(status: "online", lastSyncAt: iso(-5)),          // local mode's lower case
            WatchDevicePresence(status: "Offline", lastSyncAt: iso(-5)),
            WatchDevicePresence(status: "Online", lastSyncAt: nil),
        ]
        func chip(_ list: [WatchDevicePresence]?, listAt: Date? = nil) -> Int {
            DashboardCounts.watchOnlineDevices(presence: list, presenceAt: listAt ?? now,
                                               dashboardFigure: 9, dashboardAt: now, now: now)
        }
        XCTAssertEqual(chip(presence), 3)
        XCTAssertEqual(chip([]), 0, "an empty list is a count of zero, not the server's figure")
        XCTAssertEqual(chip(nil), 9, "no list at all (an iPhone before 1.61): the server's figure")
        // The Watch's device fetch kept failing while its dashboard refreshed:
        // a list more than the grace older than the dashboard gives way to it.
        XCTAssertEqual(chip(presence, listAt: now.addingTimeInterval(-1_801)), 9)
        XCTAssertEqual(chip(presence, listAt: now.addingTimeInterval(-1_800)), 3)
    }

    /// Only devices stored as Online travel: no other status can count.
    func test_the_presence_list_carries_only_devices_that_can_count() {
        let devices = ["Online", "online", "Offline", "Retired"].enumerated().map { index, status in
            DeviceRecord(id: "d\(index)", name: "box", type: "server", system: "macOS",
                         status: status, last_sync_at: iso(-60), helper_version: "1",
                         current_session_count: 0, cpu_usage: nil, memory_usage: nil)
        }
        let presence = WatchDevicePresence.list(from: devices)
        XCTAssertEqual(presence.map(\.status), ["Online", "online"])
        XCTAssertEqual(DashboardCounts.onlineDevices(presence, now: now), DashboardCounts.onlineDevices(devices, now: now))
    }

    /// Every device counts, not only the ones that report machine health and
    /// reach the Watch's cards (`WatchDeviceTrim`, at most four).
    func test_the_presence_list_covers_devices_the_cards_leave_out() {
        let devices = (1...6).map { index in
            DeviceRecord(id: "d\(index)", name: "box \(index)", type: "server", system: "macOS",
                         status: "Online", last_sync_at: iso(-60), helper_version: "1",
                         current_session_count: 0, cpu_usage: nil, memory_usage: nil)
        }
        XCTAssertTrue(WatchDeviceTrim.summaries(from: devices).isEmpty, "positive control: no card")
        let presence = WatchDevicePresence.list(from: devices)
        XCTAssertEqual(presence.count, 6)
        XCTAssertEqual(DashboardCounts.onlineDevices(presence, now: now),
                       DashboardCounts.onlineDevices(devices, now: now))
        let data = try? JSONEncoder().encode(presence)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode([WatchDevicePresence].self, from: $0) }, presence)
    }

    // MARK: - Demo

    /// The store's 03_live panel and the Pulse chips are captured from Demo.
    /// Under the freshness rule every Demo session is live (written within the
    /// scan-row window of Demo's clock), none is Recent, and the Devices chip
    /// counts every Demo device online, the figure Demo's dashboard states.
    /// The capture's clock stands still at Demo's refresh, so a capture taken
    /// minutes after the data was generated shows the same.
    func test_Demo_gives_a_truthful_Live_page_and_chips_under_the_new_rule() throws {
        let demo = DemoDataProvider.generate()
        let snap = WatchScreenshotLaunch.watchSnapshot(of: demo)
        for lateBy in [0.0, 600, 3_600] {
            let clock = SessionsClock.at(Date().addingTimeInterval(lateBy), demoRefresh: snap.refreshedAt)
            let page = WatchLivePage.sections(snap.sessions, now: clock)
            XCTAssertEqual(page.live.count, snap.sessions.count, "every Demo session is live (+\(lateBy) s)")
            XCTAssertTrue(page.recent.isEmpty)
            for session in snap.sessions {
                let age = try clock.timeIntervalSince(XCTUnwrap(session.lastActiveDate))
                XCTAssertGreaterThanOrEqual(age, 0)
                XCTAssertLessThanOrEqual(age, SessionFreshnessTierClassifier.processFreshnessWindow, session.id)
                XCTAssertLessThanOrEqual(age, DashboardCounts.deviceOnlineGrace)
            }
            XCTAssertEqual(DashboardCounts.activeSessions(snap.sessions, now: clock), snap.sessions.count)
            let devicesOnline = DashboardCounts.watchOnlineDevices(
                presence: snap.devicePresence, presenceAt: snap.refreshedAt,
                dashboardFigure: -1, dashboardAt: snap.refreshedAt, now: clock)
            XCTAssertEqual(devicesOnline, demo.devices.count)
            XCTAssertEqual(devicesOnline, snap.dashboard.online_devices, "the chip and Demo's dashboard agree")
        }
        XCTAssertFalse(snap.sessions.isEmpty, "positive control")
    }

    // MARK: - Wiring (the Watch app has no test target)

    func test_the_Watch_pages_use_the_shared_rule() throws {
        let live = try Self.code("CLI Pulse Bar Watch/WatchSessionsView.swift")
        XCTAssertTrue(live.contains("let sections = state.liveSections(at: now)"))
        XCTAssertFalse(live.contains(".status.caseInsensitiveCompare(\"running\")"),
                       "the Live page no longer lists rows by stored status")
        XCTAssertFalse(live.contains("ActivitySpark"), "C6: the decorative spark is gone")
        XCTAssertTrue(live.contains("SessionFreshnessTierClassifier.classify(session, now: now).badge"))

        let state = try Self.code("CLI Pulse Bar Watch/WatchAppState.swift")
        XCTAssertTrue(state.contains("WatchLivePage.sections(sessions, now: clock)"))
        XCTAssertTrue(state.contains("fetchedPresence = WatchDevicePresence.list(from: rawDevices)"),
                      "the Watch's own device fetch keeps every device's presence")

        let pulse = try Self.code("CLI Pulse Bar Watch/PulseHomeView.swift")
        XCTAssertTrue(pulse.contains("DashboardCounts.watchOnlineDevices("))
        XCTAssertTrue(pulse.contains(#"value: "\(devicesOnline)","#))

        let phone = try Self.code("CLI Pulse Bar iOS/PhoneSessionManager.swift")
        XCTAssertTrue(phone.contains("context[WatchDevicePresence.contextKey]"),
                      "the iPhone sends every device's presence with its snapshot")
    }

    /// C27: a row whose label and value do not both fit puts the value under
    /// the label rather than cutting it; on one line the value outranks the label.
    func test_a_detail_rows_value_is_never_cut_for_its_label() throws {
        let components = try Self.code("CLI Pulse Bar Watch/WatchComponents.swift")
        let start = try XCTUnwrap(components.range(of: "struct WatchMetricRow: View {"))
        let end = try XCTUnwrap(components.range(of: "private var valueText", range: start.upperBound..<components.endIndex))
        let body = String(components[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertNotNil(body.range(of: #"valueText\s*\.lineLimit\(1\)\s*\.layoutPriority\(1\)"#, options: .regularExpression),
                        "on one line the value outranks the label")
        XCTAssertNotNil(body.range(of: #"VStack\(alignment: \.leading[^)]*\) \{\s*Text\(label\)[\s\S]*valueText\s*\.lineLimit\(3\)"#,
                                   options: .regularExpression), "stacked, the value wraps under the label")
    }

    private static func code(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }   // -> "CLI Pulse Bar"
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

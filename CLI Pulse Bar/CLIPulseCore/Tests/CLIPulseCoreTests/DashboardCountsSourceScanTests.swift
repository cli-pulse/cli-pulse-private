// 1.60 (59-05): every read of `dashboard_summary`'s two figures, and of the
// widget payload's frozen session figure, is on an allowlist with its reason.
//
// The figures are fixed when they are fetched or published; a screen that
// shows one goes on showing it after the rows it counted have gone. The
// screens count the rows instead (`DashboardCounts`). A new read of the
// figures has to be added below, with a reason it is not shown, or it fails.
// `testTheScanFindsWhatItIsFor` is the negative control: a read deliberately
// added to a source is found.
//
// The reference half of the payload contract is here too: the widget and
// Siri declare the times the app publishes, under the key it writes.

import Foundation
import XCTest
@testable import CLIPulseCore

final class DashboardCountsSourceScanTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar
        .deletingLastPathComponent()   // repository root

    /// Every app target, and the package they share (the exports live there).
    private static let scannedRoots = [
        "CLI Pulse Bar/CLI Pulse Bar",
        "CLI Pulse Bar/CLI Pulse Bar iOS",
        "CLI Pulse Bar/CLI Pulse Bar Watch",
        "CLI Pulse Bar/CLI Pulse Widgets",
        "CLI Pulse Bar/CLIPulseHelper",
        "CLI Pulse Bar/CLIPulseCore/Sources",
    ]

    /// `dashboard.active_sessions`, `dash.online_devices` and the like; and
    /// the payload's `activeSessions` read off the decoded payload itself
    /// (`data.` in the widgets, `snapshot.` in Siri).
    static let patterns: [NSRegularExpression] = [
        #"\.active_sessions\b"#,
        #"\.online_devices\b"#,
        #"\b(?:data|snapshot)\.activeSessions\b(?!\s*\()"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    struct Allowed: Hashable {
        let file: String
        let code: String
    }

    private static let core = "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/"

    /// Each remaining read, with why it may stay.
    static let allowlist: [Allowed: String] = [
        Allowed(file: core + "APIClient.swift", code: "let activeSessions = summary.active_sessions ?? 0"):
            "Decodes dashboard_summary's answer into DashboardSummary; shows nothing.",
        Allowed(file: core + "APIClient.swift", code: "let onlineDevices = summary.online_devices ?? 0"):
            "Decodes dashboard_summary's answer into DashboardSummary; shows nothing.",
        Allowed(file: core + "Models.swift", code: "self.active_sessions = active_sessions"):
            "DashboardSummary's initializer.",
        Allowed(file: core + "Models.swift", code: "self.online_devices = online_devices"):
            "DashboardSummary's initializer.",
        Allowed(file: core + "DataRefreshManager.swift", code: "active_sessions: dash.active_sessions,"):
            "Copies the dashboard when the cost summary rebuilds it; shows nothing.",
        Allowed(file: core + "DataRefreshManager.swift", code: "online_devices: dash.online_devices,"):
            "Copies the dashboard when the cost summary rebuilds it; shows nothing.",
        Allowed(file: core + "WatchScreenshotLaunch.swift", code: "active_sessions: d.active_sessions,"):
            "Puts Demo's dashboard through the cloud mapping for the Watch capture; shows nothing.",
        Allowed(file: core + "WatchScreenshotLaunch.swift", code: "online_devices: d.online_devices,"):
            "Puts Demo's dashboard through the cloud mapping for the Watch capture; shows nothing.",
        Allowed(file: core + "OverviewSyncSetup.swift", code: "|| dashboard.active_sessions > 0"):
            "Decides only whether the account has synced anything; no figure is shown.",
        Allowed(file: "CLI Pulse Bar/CLI Pulse Widgets/WidgetDataProvider.swift",
                code: "published: data.activeSessions, lastActiveAt: data.activeSessionLastActiveAt, now: date)"):
            "The widgets' one read: counted again at the entry's date; the figure only when no times came.",
        Allowed(file: "CLI Pulse Bar/CLI Pulse Bar Watch/PulseHomeView.swift",
                code: #"value: "\(dash.online_devices)","#):
            "The Watch holds only the devices that report machine health (WatchDeviceTrim, at most four), "
            + "so it cannot count them; dashboard_summary's figure is windowed (1800 s) since v0.87.",
        Allowed(file: "CLI Pulse Bar/CLI Pulse Bar Watch/PulseHomeView.swift",
                code: "accessibilityText: L10n.watch.devicesCount(dash.online_devices)"):
            "As above: the same figure, spoken.",
    ]

    /// A string literal with no interpolation in it: a catalog key such as
    /// "dashboard.active_sessions" names the figure without reading it.
    private static let plainStringLiteral = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\[^(])*""#)

    /// The code lines in `source` that read a figure, comments removed and
    /// whitespace trimmed. Same known gap as `HostNameSourceScanTests`: a line
    /// is cut at its first `//`.
    static func reads(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            var line = Substring(raw)
            if let comment = line.range(of: "//") { line = line[..<comment.lowerBound] }
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { return nil }
            let stripped = plainStringLiteral.stringByReplacingMatches(
                in: code, range: NSRange(code.startIndex..., in: code), withTemplate: #""""#)
            let range = NSRange(stripped.startIndex..., in: stripped)
            return patterns.contains { $0.firstMatch(in: stripped, range: range) != nil } ? code : nil
        }
    }

    /// Every read not on the allowlist, and every allowlist entry that no
    /// longer matches a read (a stale entry would allow its next occupant).
    static func problems(found: [Allowed]) -> [String] {
        var problems: [String] = []
        for read in found where allowlist[read] == nil {
            problems.append("not allowed: \(read.file): \(read.code)")
        }
        for entry in allowlist.keys where !found.contains(entry) {
            problems.append("stale allowlist entry: \(entry.file): \(entry.code)")
        }
        return problems.sorted()
    }

    private static func scan() throws -> (found: [Allowed], files: Int) {
        var found: [Allowed] = []
        var files = 0
        for root in scannedRoots {
            let base = repoRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                throw NSError(domain: "DashboardCountsSourceScanTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "cannot read \(root)"])
            }
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                if file.path.contains("/.build/") { continue }
                files += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                let relative = String(file.path.dropFirst(repoRoot.path.count + 1))
                found += reads(in: source).map { Allowed(file: relative, code: $0) }
            }
        }
        return (found, files)
    }

    func testEveryReadOfTheDashboardsFiguresIsOnTheAllowlist() throws {
        let (found, files) = try Self.scan()
        XCTAssertGreaterThan(files, 300, "the scan did not reach the app sources")
        XCTAssertEqual(Self.problems(found: found), [],
                       "count the rows with DashboardCounts, or add the read to the allowlist with its reason")
    }

    /// Negative control: the reads this exists for are found (the ones the
    /// Overview, the exports, the widgets and Siri used to make), comments
    /// are not, and the counts that replace them are not.
    func testTheScanFindsWhatItIsFor() {
        let source = """
        // dash.active_sessions in a comment is not a read
        value: DisplayFormat.count(dash.active_sessions),
        value: DisplayFormat.count(dash.online_devices),
        csv += row([esc(L10n.pdf.activeSessions), "\\(d.active_sessions)"])
        Text(L10n.watch.sessionsCount(entry.data.activeSessions))
        sessions: snapshot.activeSessions,
        value: DisplayFormat.count(counts.activeSessions),
        let counts = state.dashboardCounts()
        sessions: snapshot.activeSessions(at: Date()),
        Text(L10n.dashboard.activeSessions)
        public static var activeSessions: String { tr("dashboard.active_sessions") }
        """
        XCTAssertEqual(Self.reads(in: source), [
            "value: DisplayFormat.count(dash.active_sessions),",
            "value: DisplayFormat.count(dash.online_devices),",
            #"csv += row([esc(L10n.pdf.activeSessions), "\(d.active_sessions)"])"#,
            "Text(L10n.watch.sessionsCount(entry.data.activeSessions))",
            "sessions: snapshot.activeSessions,",
        ])
        // A read added to a real source, outside the allowlist, is reported.
        let added = Allowed(file: "CLI Pulse Bar/CLI Pulse Bar/OverviewTab.swift",
                            code: "value: DisplayFormat.count(dash.active_sessions),")
        XCTAssertEqual(Self.problems(found: Array(Self.allowlist.keys) + [added]),
                       ["not allowed: \(added.file): \(added.code)"])
    }

    /// The reference half of the payload contract: the app writes the times
    /// under `activeSessionLastActiveAt` (PublishedWidgetData), and each
    /// reader declares that key as an optional list of dates. A comparison of
    /// the copies alone would pass if all of them dropped it.
    func testTheWidgetAndSiriDeclareTheKeyTheAppWrites() throws {
        let payload = PublishedWidgetData(
            totalUsageToday: 0, totalCostToday: 0, activeSessions: 1, unresolvedAlerts: 0,
            providers: [], lastUpdated: Date(timeIntervalSince1970: 0), isPro: true,
            activeSessionLastActiveAt: [Date(timeIntervalSince1970: 1)])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        XCTAssertNotNil(object?["activeSessionLastActiveAt"], "the app no longer writes the key")

        for reader in ["CLI Pulse Bar/CLI Pulse Widgets/WidgetDataProvider.swift",
                       "CLI Pulse Bar/CLI Pulse Bar iOS/Intents/CLIPulseIntentCache.swift"] {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(reader), encoding: .utf8)
            XCTAssertTrue(source.contains("var activeSessionLastActiveAt: [Date]? = nil"),
                          "\(reader) does not decode the times the app publishes")
            XCTAssertTrue(source.contains("DashboardCounts.activeSessions("),
                          "\(reader) does not count the sessions again")
        }
        // Every widget and Siri figure goes through the recount.
        for (reader, uses) in [
            ("CLI Pulse Bar/CLI Pulse Widgets/LockScreenWidget.swift", 2),
            ("CLI Pulse Bar/CLI Pulse Widgets/UsageOverviewWidget.swift", 3),
            ("CLI Pulse Bar/CLI Pulse Bar iOS/Intents/GetStatusIntent.swift", 1),
        ] {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(reader), encoding: .utf8)
            let recounts = source.components(separatedBy: "entry.activeSessions").count - 1
                + source.components(separatedBy: "snapshot.activeSessions(at: Date())").count - 1
            XCTAssertEqual(recounts, uses, "\(reader) shows the session figure \(uses) times, all recounted")
        }
    }
}

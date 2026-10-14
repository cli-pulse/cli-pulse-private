import XCTest
@testable import CLIPulseCore

/// Every session in the cloud is a process-scan row: `local-<pid>` from
/// LocalScanner (the Developer ID app's own scan and the LoginItem helper,
/// which uploads it) and `proc-<pid>` from the Companion CLI and the desktop
/// app. `hasProcessHeuristicMetrics` and the Sessions tab's tier tested for
/// `proc-` alone, so on a Developer ID or Homebrew Mac, and on the iPhone and
/// iPad of such an account, a running process read "Recent activity", was left
/// out of "N running", and showed Usage, Cost and Requests that are only its
/// runtime run through a formula ("Requests 640" for an app open 8 hours).
final class ProcessScanRowTests: XCTestCase {
    private typealias C = SessionFreshnessTierClassifier
    private let isoFormatter = ISO8601DateFormatter()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(_ id: String, age: TimeInterval = 30, project: String = "cli-pulse",
                     requests: Int = 640) -> SessionRecord {
        let lastActive = now.addingTimeInterval(-age)
        return SessionRecord(
            id: id, name: "claude", provider: "Claude", project: project,
            device_name: "MacBook Pro",
            started_at: isoFormatter.string(from: lastActive.addingTimeInterval(-28_800)),
            last_active_at: isoFormatter.string(from: lastActive),
            status: "Running", total_usage: 43_200, estimated_cost: 0.13,
            cost_status: "Estimated", requests: requests, error_count: 0)
    }

    private func withLocale(_ id: String, _ body: () throws -> Void) rethrows {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set(id)
        defer { store.set(previous) }
        try body()
    }

    // MARK: - One test for both prefixes

    func testBothScanPrefixesAreScanRowsAndNothingElseIs() {
        XCTAssertEqual(SessionRecord.localScanIDPrefix, "local-")
        XCTAssertEqual(SessionRecord.companionScanIDPrefix, "proc-")
        for id in ["local-4242", "proc-4242"] {
            XCTAssertTrue(SessionRecord.isProcessScanID(id), id)
            XCTAssertTrue(row(id).isProcessScanRow, id)
        }
        for id in ["jsonl-claude-abc", "jsonl-codex-abc", "0b6f2f0e-2b1c-4d55-9a57-3f1c2d4e5f60",
                   "s1", "localhost-1", "process-1", "procedure"] {
            XCTAssertFalse(SessionRecord.isProcessScanID(id), id)
        }
    }

    #if os(macOS)
    /// LocalScanner names its rows with the shared prefix, so the helper's
    /// uploads and the app's own scan are recognised the same way.
    func testLocalScannerWritesTheSharedPrefix() {
        XCTAssertEqual(LocalScanner.sessionIDPrefix, SessionRecord.localScanIDPrefix)
        XCTAssertTrue(SessionRecord.isProcessScanID("\(LocalScanner.sessionIDPrefix)99"))
    }
    #endif

    // MARK: - The Sessions tab

    /// The row a Developer ID Mac's helper uploads reads Running, counts in
    /// "N running", and hides its heuristic figures, as a Companion CLI row does.
    func testALocalScannerRowReadsAsAProcessRow() {
        for id in ["local-4242", "proc-4242"] {
            let session = row(id)
            XCTAssertEqual(C.classify(session, now: now), .activeProcess, id)
            XCTAssertTrue(session.hasProcessHeuristicMetrics, id)
            XCTAssertFalse(session.hasMeaningfulRequestCount, id)
        }
        let rows = [row("local-1"), row("proc-2"), row("jsonl-claude-a", age: 60)]
        let running = rows.filter { C.classify($0, now: now) == .activeProcess }.map(\.id)
        XCTAssertEqual(running, ["local-1", "proc-2"], "the header's \"N running\" count")
    }

    /// The badge a row shows, in a language other than English: a scan row
    /// shows its status, "运行中", never the log-activity chip "最近活动".
    func testAScanRowsBadgeReadsRunningInZhHans() {
        withLocale("zh-Hans") {
            for id in ["local-4242", "proc-4242"] {
                let tier = C.classify(row(id), now: now)
                XCTAssertEqual(tier, .activeProcess, id)
                // The views show `L10n.status.localized(status)` for
                // `.activeProcess` and `tier.badge` for every other tier.
                XCTAssertEqual(L10n.status.localized(row(id).status), "运行中", id)
                XCTAssertEqual(tier.badge, "运行中", id)
                XCTAssertNotEqual(tier.badge, FreshnessTier.activeJsonl.badge, id)
            }
            // Positive control: the chip it used to show is translated, so
            // the comparison above is between two Chinese words.
            XCTAssertEqual(FreshnessTier.activeJsonl.badge, "最近活动")
        }
    }

    /// The title is the provider and project, translated where it falls
    /// back, and LocalScanner's "unknown" project is not shown as a name.
    func testAScanRowsTitleIsItsProviderAndProject() {
        withLocale("zh-Hans") {
            XCTAssertEqual(row("local-4242").displayName, "Claude · cli-pulse")
            XCTAssertEqual(row("local-4242", project: SessionRecord.scanRowUnknownProject).displayName,
                           "Claude 进程")
            XCTAssertEqual(row("proc-4242", project: "").displayName, "Claude 进程")
            XCTAssertEqual(row("jsonl-claude-abc").displayName, "claude", "a log row keeps its name")
        }
        #if os(macOS)
        XCTAssertEqual(LocalScanner.shared.guessProject("claude"), SessionRecord.scanRowUnknownProject,
                       "LocalScanner writes another placeholder for no project")
        #endif
    }

    // MARK: - How long a scan row reads Running

    /// A live row is rewritten every producer cycle (120 s) and the tab is
    /// drawn until the next refresh (120 s by default), so it can be 240 s
    /// old while its process runs. The old 180 s window hid it then.
    func testALiveRowOneCycleAndOneRefreshOldStillReadsRunning() {
        let cycle = C.scanRowRewriteInterval
        XCTAssertEqual(cycle, 120)
        XCTAssertEqual(C.processFreshnessWindow, 300)
        for id in ["local-4242", "proc-4242"] {
            XCTAssertEqual(C.classify(row(id, age: 2 * cycle), now: now), .activeProcess, id)
            XCTAssertEqual(C.classify(row(id, age: C.processFreshnessWindow), now: now), .activeProcess, id)
            XCTAssertEqual(C.classify(row(id, age: C.processFreshnessWindow + 1), now: now), .hidden,
                           "\(id): a scan row past its window is hidden, never Recent")
        }
        // A row the tab calls Running is one the refresh's filter keeps.
        XCTAssertLessThanOrEqual(C.processFreshnessWindow, SessionFreshnessFilter.freshnessWindow)
    }

    /// The production half: the cadences the window is derived from.
    func testTheWindowCoversEveryProducersDefaultCycleAndTheAppsRefresh() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // CLI Pulse Bar/
        let repoRoot = appRoot.deletingLastPathComponent()
        func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

        let daemon = try read(appRoot.appendingPathComponent("CLIPulseHelper/HelperDaemon.swift"))
        XCTAssertTrue(daemon.contains("return stored >= 60 ? stored : 120"),
                      "the LoginItem helper's cycle changed; recheck processFreshnessWindow")
        let companion = try read(repoRoot.appendingPathComponent("helper/cli_pulse_helper.py"))
        XCTAssertTrue(companion.contains(#"daemon_parser.add_argument("--interval", type=int, default=120,"#),
                      "the Companion CLI's cycle changed; recheck processFreshnessWindow")
        XCTAssertTrue(companion.contains("interval = max(args.interval, 60)"),
                      "the Companion CLI's shortest cycle changed")
        let appState = try read(appRoot.appendingPathComponent("CLIPulseCore/Sources/CLIPulseCore/AppState.swift"))
        let refresh = try NSRegularExpression(
            pattern: #"@AppStorage\("cli_pulse_refresh_interval"\) public var refreshInterval: Int = (\d+)"#)
        let match = try XCTUnwrap(refresh.firstMatch(in: appState, range: NSRange(appState.startIndex..., in: appState)),
                                  "AppState's refresh interval is declared another way")
        let interval = try XCTUnwrap(Range(match.range(at: 1), in: appState).flatMap { Double(appState[$0]) })
        XCTAssertGreaterThanOrEqual(C.processFreshnessWindow, C.scanRowRewriteInterval + interval,
                                    "a live row read on a default refresh would drop out between refreshes")
    }

    // MARK: - One helper, everywhere

    /// Each place that tells a scan row from another asks
    /// `SessionRecord.isProcessScanRow`. Three of them tested one prefix,
    /// each the wrong one somewhere.
    func testNothingTestsAScanPrefixButTheSharedHelper() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // CLI Pulse Bar/
        let pattern = try NSRegularExpression(pattern:
            #"hasPrefix\(\s*("(proc|local)-"|(LocalScanner\.|Self\.)?sessionIDPrefix|((SessionRecord|Self)\.)?(localScanIDPrefix|companionScanIDPrefix))\s*\)"#)
        var offenders: [String] = []
        var scanned = 0
        let fm = FileManager.default
        for directory in ["CLIPulseCore/Sources", "CLI Pulse Bar", "CLI Pulse Bar iOS", "CLI Pulse Bar Watch",
                          "CLIPulseHelper", "CLI Pulse Widgets"] {
            let base = appRoot.appendingPathComponent(directory)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                    guard pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                    // The helper itself.
                    if url.lastPathComponent == "Models.swift",
                       line.contains("id.hasPrefix(localScanIDPrefix) || id.hasPrefix(companionScanIDPrefix)") {
                        continue
                    }
                    offenders.append("\(directory)/\(url.lastPathComponent):\(index + 1): \(code)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found too few sources; are the paths right?")
        XCTAssertEqual(offenders, [], "test `SessionRecord.isProcessScanRow`, not one prefix")
    }
}

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
    /// back, and no producer's placeholder project is shown as a name.
    func testAScanRowsTitleIsItsProviderAndProject() {
        withLocale("zh-Hans") {
            XCTAssertEqual(row("local-4242").displayName, "Claude · cli-pulse")
            XCTAssertEqual(row("local-4242", project: SessionRecord.scanRowUnknownProject).displayName,
                           "Claude 进程")
            XCTAssertEqual(row("proc-4242", project: SessionRecord.scanRowWorkspaceProject).displayName,
                           "Claude 进程")
            XCTAssertEqual(row("proc-4242", project: "").displayName, "Claude 进程")
            XCTAssertEqual(row("jsonl-claude-abc").displayName, "claude", "a log row keeps its name")
        }
        #if os(macOS)
        XCTAssertEqual(LocalScanner.shared.guessProject("claude"), SessionRecord.scanRowUnknownProject,
                       "LocalScanner writes another placeholder for no project")
        #endif
    }

    // MARK: - No placeholder under a translated title

    /// The line under a scan row's title, and the detail's Project field, do
    /// not show a producer's English placeholder: the title read "Claude 进程"
    /// with "unknown" under it. The detail says 未知 instead.
    func testNoScanRowShowsAProducersPlaceholderProject() {
        withLocale("zh-Hans") {
            for (id, project) in [("local-4242", "unknown"), ("proc-4242", "local-workspace"),
                                  ("proc-4242", ""), ("local-4242", "  ")] {
                let session = row(id, project: project)
                XCTAssertNil(session.displayProject, "\(id) \"\(project)\"")
                XCTAssertEqual(session.detailProject, "未知", "\(id) \"\(project)\"")
                XCTAssertEqual(session.displayName, "Claude 进程", "\(id) \"\(project)\"")
            }
            let named = row("proc-4242", project: " cli-pulse ")
            XCTAssertEqual(named.displayProject, "cli-pulse")
            XCTAssertEqual(named.detailProject, "cli-pulse")
            // A log row's project is the folder its log names, whatever it is called.
            XCTAssertEqual(row("jsonl-claude-abc", project: "unknown").displayProject, "unknown")
            XCTAssertNil(row("jsonl-claude-abc", project: "").displayProject)
        }
        // Positive control: the field's fallback is translated, so the zh-Hans
        // comparison above is not one an English fallback would pass.
        withLocale("en") { XCTAssertEqual(row("local-4242", project: "unknown").detailProject, "Unknown") }
    }

    /// The production half: the placeholders are the ones the producers write.
    /// (The desktop app's `guess_project` ends in "local-workspace" too; it
    /// lives in another repository.)
    func testThePlaceholdersAreTheOnesTheProducersWrite() throws {
        XCTAssertEqual(SessionRecord.scanRowPlaceholderProjects, ["unknown", "local-workspace"])
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // CLI Pulse Bar/
        let python = try String(contentsOf: appRoot.deletingLastPathComponent()
            .appendingPathComponent("helper/system_collector.py"), encoding: .utf8)
        XCTAssertTrue(python.contains(#"return Path(os.getcwd()).name or "local-workspace""#),
                      "the Companion CLI writes another placeholder for no project")
        XCTAssertTrue(python.contains(#"session_id=f"proc-{row['pid']}","#),
                      "the Companion CLI's rows are no longer proc-, where the placeholder is not shown")
    }

    // MARK: - What the Sessions views draw for a scan row

    /// A scan row's title names its provider and project, so the line under
    /// it does not name them again ("Codex · cli-pulse-ios" over
    /// "Codex  cli-pulse-ios").
    func testAScanRowsTitleNamesItsProviderAndProject() {
        for id in ["local-4242", "proc-4242"] {
            XCTAssertTrue(row(id).titleNamesProviderAndProject, id)
        }
        XCTAssertFalse(row("jsonl-claude-abc").titleNamesProviderAndProject)
    }

    /// Every session view in the four app targets (the Mac, iPhone and iPad,
    /// Watch and widgets) draws a session's usage and cost only inside a block
    /// whose condition asks `hasProcessHeuristicMetrics`, its request count
    /// only inside one that asks `hasMeaningfulRequestCount`, and never its
    /// stored `name` or `project` (a command line, a producer's placeholder).
    /// The Watch drew all three figures for every row after the iPhone stopped.
    /// Keyed on `session.`, the name every one of them gives the row.
    func testEverySessionViewDrawsWhatTheRowShows() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // CLI Pulse Bar/
        let figure = try NSRegularExpression(pattern: #"\bsession\.(total_usage|estimated_cost|requests)\b"#)
        let stored = try NSRegularExpression(pattern: #"\bsession\.(name|project)\b"#)
        var offenders: [String] = []
        var figureFiles: Set<String> = []
        var gatedReads = 0
        for target in ["CLI Pulse Bar", "CLI Pulse Bar iOS", "CLI Pulse Bar Watch", "CLI Pulse Widgets"] {
            let root = appRoot.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                XCTFail("\(target) is gone; is this still the list of app targets?"); continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                // The line that opened each enclosing block, innermost last.
                var openers: [String] = []
                for (index, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    let place = "\(target)/\(url.lastPathComponent):\(index + 1)"
                    if stored.firstMatch(in: line, range: range) != nil {
                        offenders.append("\(place) draws a stored name or project: \(trimmed)")
                    }
                    if let match = figure.firstMatch(in: line, range: range),
                       let field = Range(match.range(at: 1), in: line) {
                        figureFiles.insert(url.lastPathComponent)
                        let gate = line[field] == "requests" ? "hasMeaningfulRequestCount" : "hasProcessHeuristicMetrics"
                        if (openers + [line]).contains(where: { $0.contains(gate) }) {
                            gatedReads += 1
                        } else {
                            offenders.append("\(place) draws session.\(line[field]) outside a block that asks \(gate)")
                        }
                    }
                    for character in line {
                        if character == "{" { openers.append(line) }
                        if character == "}", !openers.isEmpty { openers.removeLast() }
                    }
                }
            }
        }
        XCTAssertEqual(offenders, [])
        // Positive controls: the scan still finds the three Sessions views,
        // and the gates it looks for (Mac row 3, iPhone row 3 and detail 3,
        // Watch card 3, compact row 1 and detail 3).
        XCTAssertEqual(figureFiles, ["SessionsTab.swift", "iOSSessionsTab.swift", "WatchSessionsView.swift"],
                       "the session views moved or another one draws figures; is the scan still looking at them?")
        XCTAssertGreaterThanOrEqual(gatedReads, 16, "the scan finds fewer gated figures than the views draw")
    }

    // MARK: - The Overview's Requests figure

    /// On the local route (a Mac signed out in local mode, or signed in with
    /// no paired helper) the Overview's Requests tile added up every listed
    /// session's `requests`. A Developer ID Mac lists LocalScanner's rows
    /// whenever an AI tool runs, so the tile summed the runtime / 45 that each
    /// row hides: Claude.app open 8 hours added 640 to an unlabelled figure.
    /// It now adds only the counts the rows show, and shows only when one does.
    func testTheOverviewDoesNotAddUpScanRowsRequests() throws {
        let scanRows = [row("local-1", requests: 640), row("proc-2", requests: 160)]
        XCTAssertNil(OverviewFormatters.requestCount(in: scanRows))
        XCTAssertFalse(OverviewFormatters.showsRequestsMetric(route: .localOnly, sessions: scanRows),
                       "the tile shows the scan rows' runtime as requests")
        let claudeLog = row("jsonl-claude-a", requests: 44)
        let codexLog = row("jsonl-codex-b", requests: 1)   // the parser's floor, which its row hides too
        XCTAssertNil(OverviewFormatters.requestCount(in: [codexLog]))
        let mixed = scanRows + [claudeLog, codexLog]
        XCTAssertEqual(OverviewFormatters.requestCount(in: mixed), 44)
        XCTAssertTrue(OverviewFormatters.showsRequestsMetric(route: .localOnly, sessions: mixed),
                      "a Claude log row's count no longer reaches the tile")
        XCTAssertFalse(OverviewFormatters.showsRequestsMetric(route: .cloud, sessions: mixed),
                       "the cloud dashboard has no request count")
        XCTAssertNil(OverviewFormatters.requestCount(in: []))

        // The production half: the local refresh's dashboard counts this way.
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // CLI Pulse Bar/
        let manager = try String(contentsOf: appRoot.appendingPathComponent(
            "CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift"), encoding: .utf8)
        XCTAssertTrue(manager.contains("let totalRequestsToday = OverviewFormatters.requestCount(in: synthesizedSessions) ?? 0"),
                      "the local refresh counts its dashboard's requests another way")
        XCTAssertTrue(manager.contains("total_requests_today: totalRequestsToday,"),
                      "the local refresh's dashboard takes its request count from somewhere else")
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

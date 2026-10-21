import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.58 (P1-5): the scan's rows split by session, from fixture logs shaped
/// like Codex's and Claude Code's own.
///
/// Codex: a session is the conversation its rollouts name
/// (`session_meta.payload.session_id`); a subagent's rollout names its
/// parent's, so it is folded into the parent's row and counted there as a
/// subagent; a conversation continued in a second file is one session; a copy
/// is counted once. Claude: a session is `<project>/<id>.jsonl` with
/// everything under `<project>/<id>/`. Either way only the days in the window
/// count, and the rows add up to the provider's 30-day estimate, with nothing
/// left over: tokens exactly, cost to the nanodollar.
final class SessionScanTests: XCTestCase {

    private var tmpRoot: URL!
    private var codexRoot: URL!
    private var claudeRoot: URL!
    private var cacheRoot: URL!

    private let home = "/Users/sample"
    /// Noon today, so the morning is today and whole days can be counted back.
    private let now: Date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-sessions-\(UUID().uuidString)", isDirectory: true)
        codexRoot = tmpRoot.appendingPathComponent("codex/sessions", isDirectory: true)
        claudeRoot = tmpRoot.appendingPathComponent("claude-projects", isDirectory: true)
        cacheRoot = tmpRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        tmpRoot = nil
    }

    // MARK: - Fixtures

    private func scan(splitsByProject: Bool = true) -> CostUsageScanResult {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: codexRoot, claudeProjectsRoots: [claudeRoot], cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.splitsByProject = splitsByProject
        options.homeDirectory = home
        options.now = now
        return CostUsageScanner.scan(options: options)
    }

    private var todayKey: String { DayKey.string(from: now) }

    private func ago(days: Int = 0, hours: Double = 0) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return day.addingTimeInterval(-hours * 3600)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private struct Request {
        let at: Date
        let input: Int
        let cached: Int
        let output: Int
    }

    /// A Codex rollout in the date folder of `folderDay`: its session_meta,
    /// the model, and its requests, the cumulative total rising by each.
    /// `parent` makes it a subagent's rollout of that conversation, named as
    /// Codex names one: `session_id` the parent's, `parent_thread_id`, and a
    /// `subagent` source.
    private func codexRollout(
        _ id: String, session: String? = nil, parent: String? = nil, cwd: String?,
        folderDay: Date? = nil, meta: Date, requests: [Request], file: String? = nil
    ) throws {
        var payload: [String: Any] = ["id": id, "session_id": session ?? parent ?? id, "timestamp": stamp(meta)]
        payload["cwd"] = cwd
        if let parent {
            payload["parent_thread_id"] = parent
            payload["source"] = ["subagent": ["other": "review"]]
        }
        var lines = [
            json(["type": "session_meta", "timestamp": stamp(meta), "payload": payload]),
            json(["type": "turn_context", "timestamp": stamp(meta.addingTimeInterval(1)), "payload": ["model": "gpt-5.5"]]),
        ]
        var total = (0, 0, 0)
        for request in requests {
            total = (total.0 + request.input, total.1 + request.cached, total.2 + request.output)
            let last = ["input_tokens": request.input, "cached_input_tokens": request.cached, "output_tokens": request.output]
            let sum = ["input_tokens": total.0, "cached_input_tokens": total.1, "output_tokens": total.2]
            lines.append(json([
                "type": "event_msg", "timestamp": stamp(request.at),
                "payload": ["type": "token_count", "info": ["total_token_usage": sum, "last_token_usage": last]],
            ]))
        }
        let folder = DayKey.string(from: folderDay ?? meta).split(separator: "-")
            .reduce(codexRoot!) { $0.appendingPathComponent(String($1), isDirectory: true) }
        try write(lines, to: folder.appendingPathComponent(file ?? "rollout-\(id).jsonl"))
    }

    /// A Claude transcript at `relativePath` under the projects root, one
    /// response per request, each recording the folder it ran in.
    private func claudeTranscript(_ relativePath: String, cwd: String, requests: [Request]) throws {
        let lines = requests.enumerated().map { index, request in
            json([
                "type": "assistant", "timestamp": stamp(request.at), "sessionId": "s", "cwd": cwd,
                "requestId": "req-\(relativePath)-\(index)",
                "message": ["id": "msg-\(relativePath)-\(index)", "model": "claude-sonnet-4-5", "stop_reason": "end_turn",
                            "usage": ["input_tokens": request.input, "cache_creation_input_tokens": 0,
                                      "cache_read_input_tokens": request.cached, "output_tokens": request.output]],
            ])
        }
        try write(lines, to: claudeRoot.appendingPathComponent(relativePath))
    }

    private let demoApp = "/Users/sample/Projects/demo-app"
    private let api = "/Users/sample/Projects/api-gateway"
    private let demoAppDirectory = "-Users-sample-Projects-demo-app"

    private func rows(_ scan: CostUsageScanResult, _ provider: String) -> [SessionUsageRow] {
        SessionUsageRanking.ordered(
            SessionUsageRanking.rows(scan.sessions, details: scan.sessionDetails, provider: provider, todayKey: todayKey),
            by: .cost, showsCost: true)
    }

    /// The sessions of `provider` against its 30-day estimate as the panel
    /// shows it: I/O and every token once exactly; the cost in nanodollars.
    private func assertAddsUp(_ scan: CostUsageScanResult, _ provider: String, file: StaticString = #filePath, line: UInt = #line) {
        let sessions = rows(scan, provider)
        let io = ProviderUsageDays.fromScan(scan.entries, provider: provider, basis: .inputOutput, todayKey: todayKey)
        let eachOnce = ProviderUsageDays.fromScan(scan.entries, provider: provider, basis: .eachOnce, todayKey: todayKey)
        XCTAssertTrue(io.hasUsage, "\(provider): the fixture has no usage in the window", file: file, line: line)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.ioTokens }, io.totalTokens, "\(provider) I/O", file: file, line: line)
        XCTAssertEqual(
            sessions.reduce(0) { $0 + ArchiveTokenBasis.tokens(
                provider: provider, inputTokens: $1.inputTokens, cachedTokens: $1.cachedTokens,
                outputTokens: $1.outputTokens) },
            eachOnce.totalTokens, "\(provider) every token once", file: file, line: line)
        let difference = sessions.reduce(0) { $0 + $1.cost } - io.totalCost
        XCTAssertEqual(Int((difference * 1e9).rounded()), 0, "\(provider) cost: \(difference)", file: file, line: line)
        XCTAssertGreaterThan(io.totalCost, 0, file: file, line: line)
    }

    // MARK: - Codex

    func testCodexSubagentsFoldIntoTheirParentsSession() throws {
        try codexRollout("parent", cwd: demoApp, meta: ago(hours: 3), requests: [
            Request(at: ago(hours: 2.9), input: 1_000, cached: 200, output: 100),
            Request(at: ago(hours: 2), input: 500, cached: 0, output: 50),
        ])
        // Two subagents of it, one in another folder: the session ran where
        // its own rollout says.
        try codexRollout("child-a", parent: "parent", cwd: demoApp, meta: ago(hours: 1.8), requests: [
            Request(at: ago(hours: 1.7), input: 300, cached: 0, output: 30),
        ])
        try codexRollout("child-b", parent: "parent", cwd: api, meta: ago(hours: 1.6), requests: [
            Request(at: ago(hours: 1.5), input: 2_000, cached: 0, output: 200),
        ])
        try codexRollout("other", cwd: api, meta: ago(hours: 1), requests: [
            Request(at: ago(hours: 0.9), input: 100, cached: 0, output: 10),
        ])

        let result = scan()
        let sessions = rows(result, "Codex")
        XCTAssertEqual(sessions.count, 2, "the subagents are folded into their parent's row: \(sessions.map(\.key))")
        let parent = try XCTUnwrap(sessions.first { $0.subagents > 0 })
        XCTAssertEqual(parent.subagents, 2)
        XCTAssertEqual(parent.project.name, "demo-app")
        XCTAssertEqual(parent.inputTokens, 3_800)
        XCTAssertEqual(parent.cachedTokens, 200)
        XCTAssertEqual(parent.outputTokens, 380)
        XCTAssertEqual(parent.models, ["gpt-5.5"])
        let other = try XCTUnwrap(sessions.first { $0.subagents == 0 })
        XCTAssertEqual(other.project.name, "api-gateway")
        XCTAssertEqual(other.ioTokens, 110)
        assertAddsUp(result, "Codex")
    }

    /// The VS Code shape: a conversation's first file, then a second file of
    /// the same thread that starts its counter again. One session, both
    /// counted.
    func testCodexConversationContinuedInASecondFileIsOneSession() throws {
        try codexRollout("thread", cwd: demoApp, meta: ago(hours: 6), requests: [
            Request(at: ago(hours: 5.5), input: 700, cached: 100, output: 70),
        ], file: "rollout-a-thread.jsonl")
        try codexRollout("thread", cwd: demoApp, meta: ago(hours: 2), requests: [
            Request(at: ago(hours: 1.5), input: 400, cached: 0, output: 40),
        ], file: "rollout-b-thread.jsonl")

        let result = scan()
        let sessions = rows(result, "Codex")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.ioTokens, 1_210)
        XCTAssertEqual(sessions.first?.subagents, 0)
        assertAddsUp(result, "Codex")
    }

    /// A byte-for-byte copy of a rollout under another name is one file's
    /// usage, in the scan and in its session.
    func testCodexCopyIsCountedOnce() throws {
        let requests = [Request(at: ago(hours: 3), input: 900, cached: 0, output: 90)]
        try codexRollout("copied", cwd: demoApp, meta: ago(hours: 4), requests: requests, file: "rollout-a-copied.jsonl")
        try codexRollout("copied", cwd: demoApp, meta: ago(hours: 4), requests: requests, file: "rollout-b-copied.jsonl")

        let result = scan()
        let sessions = rows(result, "Codex")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.ioTokens, 990)
        assertAddsUp(result, "Codex")
    }

    // MARK: - Claude

    func testClaudeSubagentsAndWorkflowRunsFoldIntoTheirSession() throws {
        try claudeTranscript("\(demoAppDirectory)/session-one.jsonl", cwd: demoApp, requests: [
            Request(at: ago(hours: 5), input: 10, cached: 1_000, output: 300),
        ])
        try claudeTranscript("\(demoAppDirectory)/session-one/subagents/agent-a.jsonl", cwd: demoApp, requests: [
            Request(at: ago(hours: 4.5), input: 20, cached: 2_000, output: 200),
        ])
        try claudeTranscript(
            "\(demoAppDirectory)/session-one/subagents/workflows/run-1/agent-b.jsonl", cwd: demoApp, requests: [
                Request(at: ago(hours: 4), input: 30, cached: 3_000, output: 100),
            ])
        try claudeTranscript("\(demoAppDirectory)/session-two.jsonl", cwd: demoApp, requests: [
            Request(at: ago(hours: 1), input: 5, cached: 500, output: 50),
        ])

        let result = scan()
        let sessions = rows(result, "Claude")
        XCTAssertEqual(sessions.count, 2, "\(sessions.map(\.key))")
        let one = try XCTUnwrap(sessions.first { $0.subagents > 0 })
        XCTAssertEqual(one.subagents, 2)
        XCTAssertEqual(one.project.name, "demo-app")
        XCTAssertEqual(one.ioTokens, 660)
        XCTAssertEqual(one.cachedTokens, 6_000)
        let two = try XCTUnwrap(sessions.first { $0.subagents == 0 })
        XCTAssertEqual(two.ioTokens, 55)
        XCTAssertEqual(two.project, one.project)
        assertAddsUp(result, "Claude")
    }

    // MARK: - The window

    /// Logs keep days the window does not show: a Codex rollout begun in the
    /// date folder before the scan's first day, and a Claude transcript that
    /// goes back as far. The scan keeps a session's rows of its own days
    /// only, the panel's 30 days are fewer still, and the sessions add up to
    /// the panel's total for those days, with nothing from the days before.
    func testOnlyTheWindowsDaysCount() throws {
        try codexRollout("long", cwd: demoApp, folderDay: ago(days: 31), meta: ago(days: 31, hours: 2), requests: [
            Request(at: ago(days: 31, hours: 1), input: 50_000, cached: 0, output: 5_000),   // before the scan's days
            Request(at: ago(days: 30, hours: 1), input: 7_000, cached: 0, output: 700),      // the scan's first day, not the panel's
            Request(at: ago(hours: 1), input: 600, cached: 0, output: 60),
        ])
        try claudeTranscript("\(demoAppDirectory)/long.jsonl", cwd: demoApp, requests: [
            Request(at: ago(days: 31, hours: 1), input: 40_000, cached: 0, output: 4_000),
            Request(at: ago(days: 30, hours: 1), input: 3_000, cached: 0, output: 300),
            Request(at: ago(hours: 2), input: 80, cached: 800, output: 8),
        ])

        let result = scan()
        let firstScanned = CostUsageScanner.DayRange(
            since: Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now, until: now).sinceKey
        XCTAssertFalse(result.sessions.contains { $0.date < firstScanned }, "a day before the scan's first is kept")
        XCTAssertTrue(result.sessions.contains { $0.date == firstScanned }, "the fixture misses the scan's first day")

        XCTAssertEqual(rows(result, "Codex").first?.ioTokens, 660)
        XCTAssertEqual(rows(result, "Claude").first?.ioTokens, 88)
        assertAddsUp(result, "Codex")
        assertAddsUp(result, "Claude")
    }

    /// A subagent counts for a window that holds a day of its usage.
    func testASubagentOutsideTheWindowIsNotCounted() throws {
        try codexRollout("parent", cwd: demoApp, meta: ago(days: 30, hours: 3), requests: [
            Request(at: ago(hours: 2), input: 100, cached: 0, output: 10),
        ], file: "rollout-parent.jsonl")
        try codexRollout("old-child", parent: "parent", cwd: demoApp, meta: ago(days: 30, hours: 2), requests: [
            Request(at: ago(days: 30, hours: 1), input: 300, cached: 0, output: 30),
        ])
        let result = scan()
        let session = try XCTUnwrap(rows(result, "Codex").first)
        XCTAssertEqual(session.subagents, 0, "the subagent's only day is the scan's first, outside the panel's 30")
        XCTAssertEqual(session.ioTokens, 110)
        assertAddsUp(result, "Codex")
    }

    /// A session names a project its logs have usage in over the list's
    /// days. Its own rollout ran in demo-app, but only on the scan's first
    /// day, which the panel's 30 leave out; inside them, only its subagent
    /// ran, in api-gateway. So the row names api-gateway, the folder
    /// Projects counts its usage in, and with "Hide personal information"
    /// on it is that folder's number: never "项目 0", the number of a folder
    /// Projects does not list for these days.
    func testASessionNamesAProjectItsLogsHaveUsageInOverTheWindow() throws {
        let previousLocale = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
        defer { LocaleOverrideStore.shared.set(previousLocale) }
        try codexRollout("parent", cwd: demoApp, folderDay: ago(days: 30), meta: ago(days: 30, hours: 3), requests: [
            Request(at: ago(days: 30, hours: 2), input: 5_000, cached: 0, output: 500),
        ], file: "rollout-parent.jsonl")
        try codexRollout("child", parent: "parent", cwd: api, meta: ago(hours: 2), requests: [
            Request(at: ago(hours: 1), input: 300, cached: 0, output: 30),
        ])

        let result = scan()
        let session = try XCTUnwrap(rows(result, "Codex").first)
        XCTAssertEqual(rows(result, "Codex").count, 1)
        XCTAssertEqual(session.subagents, 1)
        XCTAssertEqual(session.project.name, "api-gateway", "the window's row names a folder its logs have no usage in")
        // Over the scan's days, the session still ran where its own log says.
        XCTAssertEqual(result.sessionDetails.first?.project.name, "demo-app")

        let numbers = ProjectUsageRanking.anonymousNumbers(result.projects, todayKey: todayKey)
        let number = try XCTUnwrap(numbers[session.project.key], "Projects does not number the row's folder")
        XCTAssertEqual(numbers.count, 1, "demo-app has no usage in the window, so Projects lists it nowhere")
        let list = SessionUsageList.build(
            result.sessions, details: result.sessionDetails, projects: result.projects, provider: "Codex",
            todayKey: todayKey, showsCost: true, hidePersonalInfo: true)
        XCTAssertEqual(list.lines.map(\.title), ["项目 \(number)"])
        XCTAssertFalse(list.lines.contains { $0.title == "项目 0" })
        assertAddsUp(result, "Codex")
    }

    // MARK: - Off

    /// The year-long reads that fill the usage archive split nothing.
    func testNoSessionsWithoutTheProjectSplit() throws {
        try codexRollout("plain", cwd: demoApp, meta: ago(hours: 2), requests: [
            Request(at: ago(hours: 1), input: 100, cached: 0, output: 10),
        ])
        let result = scan(splitsByProject: false)
        XCTAssertFalse(result.entries.isEmpty)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.sessionDetails.isEmpty)
    }
}

#endif

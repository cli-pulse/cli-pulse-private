import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Log shapes that CodexBar found miscounted (its #3659, #3688, #3753 and
/// #2168), written as fixtures for `CostUsageScanner.scan` and checked against
/// the totals the logs actually hold.
///
/// Only `scan(options:)` and the scan result are used, so this file also builds
/// against a scanner without the fixes; run that way, the tests marked
/// "fails without the fix" fail and the positive controls pass.
///
/// Claude: a response is several lines that repeat its usage so far; it counts
/// once, from its last line, also when its lines arrive across scans and when
/// the log repeats an earlier line further down; a proxy's preliminary
/// estimate is not billed. Codex: a continuation page's first cumulative
/// reading carries the earlier pages (a cross-check of the inherited-baseline
/// rule in `CodexTokenAccountant`). Both: a line still being written is read
/// once it is complete.
final class CostUsageScannerAccountingTests: XCTestCase {

    private var tmpRoot: URL!
    private var claudeProject: URL!
    private var codexDay: URL!
    private var cacheRoot: URL!

    private let stamp: String = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }()

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-accounting-\(UUID().uuidString)", isDirectory: true)
        claudeProject = tmpRoot
            .appendingPathComponent("claude-projects", isDirectory: true)
            .appendingPathComponent("-Users-alice-project", isDirectory: true)
        // sessions/YYYY/MM/DD, the layout the Codex CLI writes.
        codexDay = CostUsageScanner.DayRange.dayKey(from: Date()).split(separator: "-")
            .reduce(tmpRoot.appendingPathComponent("codex/sessions", isDirectory: true)) {
                $0.appendingPathComponent(String($1), isDirectory: true)
            }
        cacheRoot = tmpRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        tmpRoot = nil
    }

    // MARK: - Fixture helpers

    private struct Totals: Equatable, CustomStringConvertible {
        var input = 0
        var cached = 0
        var output = 0
        var description: String { "input \(input), cached \(cached), output \(output)" }
    }

    /// One scan with the cache the previous scan left (an incremental read of
    /// grown logs), or with `force` a full re-read.
    @discardableResult
    private func scan(force: Bool = false) -> [CostUsageScanResult.DailyEntry] {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: tmpRoot.appendingPathComponent("codex/sessions", isDirectory: true),
            claudeProjectsRoots: [tmpRoot.appendingPathComponent("claude-projects", isDirectory: true)],
            cacheRoot: cacheRoot
        )
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = force
        return CostUsageScanner.scan(options: options).entries
    }

    private func totals(_ provider: String, _ entries: [CostUsageScanResult.DailyEntry]) -> Totals {
        entries.filter { $0.provider == provider }.reduce(into: Totals()) {
            $0.input += $1.inputTokens
            $0.cached += $1.cachedTokens
            $0.output += $1.outputTokens
        }
    }

    private func cost(_ provider: String, _ entries: [CostUsageScanResult.DailyEntry]) -> Double {
        entries.filter { $0.provider == provider }.reduce(0) { $0 + ($1.costUSD ?? 0) }
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private enum StopReason {
        case absent
        case null
        case value(String)
    }

    /// An assistant line as Claude Code (or a proxy in front of it) writes it.
    private func claudeLine(
        message: String?,
        request: String? = nil,
        session: String? = "session-1",
        model: String = "claude-sonnet-4-5",
        usage: [String: Int],
        stopReason: StopReason = .absent
    ) -> String {
        var body: [String: Any] = ["model": model, "usage": usage]
        body["id"] = message
        switch stopReason {
        case .absent: break
        case .null: body["stop_reason"] = NSNull()
        case .value(let reason): body["stop_reason"] = reason
        }
        var event: [String: Any] = ["type": "assistant", "timestamp": stamp, "message": body]
        event["requestId"] = request
        event["sessionId"] = session
        return json(event)
    }

    /// Claude Code's own usage block: the two cache fields are always present.
    private func nativeUsage(input: Int = 3, cacheRead: Int = 50_000, output: Int) -> [String: Int] {
        ["input_tokens": input, "cache_creation_input_tokens": 0, "cache_read_input_tokens": cacheRead, "output_tokens": output]
    }

    @discardableResult
    private func write(_ lines: [String], to url: URL, trailingNewline: Bool = true) throws -> URL {
        var text = lines.joined(separator: "\n")
        if trailingNewline, !lines.isEmpty { text += "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func claudeLog(_ name: String = "session-1") -> URL {
        claudeProject.appendingPathComponent("\(name).jsonl")
    }

    private func codexLog(_ name: String) -> URL {
        codexDay.appendingPathComponent("rollout-\(name).jsonl")
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func codexTokenCount(total: (Int, Int, Int), last: (Int, Int, Int)?) -> String {
        func usage(_ t: (Int, Int, Int)) -> [String: Int] {
            ["input_tokens": t.0, "cached_input_tokens": t.1, "output_tokens": t.2]
        }
        var info: [String: Any] = ["total_token_usage": usage(total)]
        if let last { info["last_token_usage"] = usage(last) }
        return json([
            "type": "event_msg", "timestamp": stamp,
            "payload": ["type": "token_count", "info": info],
        ])
    }

    private func codexTurnContext(model: String = "gpt-5.5") -> String {
        json(["type": "turn_context", "timestamp": stamp, "payload": ["model": model]])
    }

    // MARK: - Claude: one response, counted once, from its last line

    /// Fails without the fix (upstream #3659). A proxy that leaves `requestId`
    /// out repeats the same response's usage on each line; the session and
    /// message id still identify it.
    func test_repeatedProxySnapshotsOfOneResponseCountOnce() throws {
        try write([
            claudeLine(message: "response-1", usage: ["input_tokens": 100, "output_tokens": 1]),
            claudeLine(message: "response-1", usage: ["input_tokens": 100, "output_tokens": 5]),
            claudeLine(message: "response-1", usage: ["input_tokens": 100, "output_tokens": 9]),
        ], to: claudeLog())
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 100, cached: 0, output: 9))
    }

    /// Proxies and other writers put the session id in `session_id` or in a
    /// `metadata` object instead of `sessionId`; the snapshots still count once.
    func test_proxySnapshotsCountOnceWhereverTheSessionIdIs() throws {
        func line(_ output: Int, _ place: String) -> String {
            var event: [String: Any] = [
                "type": "assistant", "timestamp": stamp,
                "message": ["id": "response-1", "model": "claude-sonnet-4-5",
                            "usage": ["input_tokens": 100, "output_tokens": output]],
            ]
            switch place {
            case "snake": event["session_id"] = "session-1"
            case "metadata": event["metadata"] = ["sessionId": "session-1"]
            default:
                var message = event["message"] as! [String: Any]
                message["metadata"] = ["sessionId": "session-1"]
                event["message"] = message
            }
            return json(event)
        }
        for place in ["snake", "metadata", "message metadata"] {
            try write([line(1, place), line(5, place), line(9, place)], to: claudeLog())
            XCTAssertEqual(totals("Claude", scan(force: true)), Totals(input: 100, cached: 0, output: 9), place)
        }
    }

    /// Positive control: lines without one exact, non-blank shared identity
    /// are separate responses and all count (upstream's distinct-row cases).
    func test_linesWithoutAnExactSharedIdentityAllCount() throws {
        typealias Identity = (session: String?, message: String?, request: String?)
        let pairs: [(String, Identity, Identity)] = [
            ("request and session identities are separate namespaces",
             ("other", "session-a", "response-b"), ("session-a", "response-b", nil)),
            ("delimiters inside the session fallback", ("session:a", "response", nil), ("session", "a:response", nil)),
            ("delimiters inside explicit request ids", ("session", "response:a", "request"), ("session", "response", "a:request")),
            ("different sessions", ("session-a", "response", nil), ("session-b", "response", nil)),
            ("different messages", ("session", "response-a", nil), ("session", "response-b", nil)),
            ("different explicit requests", ("session", "response", "request-a"), ("session", "response", "request-b")),
            ("missing versus present request id", ("session", "response", nil), ("session", "response", "request")),
            ("session ids are compared exactly", ("session", "response", nil), (" session ", "response", nil)),
            ("message ids are compared exactly", ("session", "response", nil), ("session", " response ", nil)),
            ("missing session ids", (nil, "response", nil), (nil, "response", nil)),
            ("empty session ids", ("", "response", nil), ("", "response", nil)),
            ("blank session ids", (" \n\t", "response", nil), (" \n\t", "response", nil)),
            ("missing message ids", ("session", nil, nil), ("session", nil, nil)),
            ("empty message ids", ("session", "", nil), ("session", "", nil)),
            ("blank message ids", ("session", " \n\t", nil), ("session", " \n\t", nil)),
        ]
        for (index, (name, first, second)) in pairs.enumerated() {
            let url = claudeLog("distinct-\(index)")
            try write([
                claudeLine(message: first.message, request: first.request, session: first.session,
                           usage: ["input_tokens": 10, "output_tokens": 1]),
                claudeLine(message: second.message, request: second.request, session: second.session,
                           usage: ["input_tokens": 20, "output_tokens": 1]),
            ], to: url)
            XCTAssertEqual(totals("Claude", scan(force: true)), Totals(input: 30, cached: 0, output: 2), name)
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Fails without the fix. An explicit request id identifies the response
    /// whatever session the line claims, and the later line counts.
    func test_anExplicitRequestIdIdentifiesTheResponseWhateverTheSession() throws {
        try write([
            claudeLine(message: "response", request: "request", session: "session-a",
                       usage: ["input_tokens": 10, "output_tokens": 1]),
            claudeLine(message: "response", request: "request", session: "session-b",
                       usage: ["input_tokens": 20, "output_tokens": 1]),
        ], to: claudeLog())
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 20, cached: 0, output: 1))
    }

    /// Fails without the fix. Claude Code writes one line per content block,
    /// each with the response's usage so far; the output count grows, and the
    /// last line holds the response's output.
    func test_theLastLineOfAResponseCarriesItsOutput() throws {
        try write([
            claudeLine(message: "msg-1", request: "req-1", usage: nativeUsage(output: 2), stopReason: .null),
            claudeLine(message: "msg-1", request: "req-1", usage: nativeUsage(output: 40), stopReason: .null),
            claudeLine(message: "msg-1", request: "req-1", usage: nativeUsage(output: 311), stopReason: .value("tool_use")),
        ], to: claudeLog())
        let entries = scan()
        XCTAssertEqual(totals("Claude", entries), Totals(input: 3, cached: 50_000, output: 311))
        let priced = try XCTUnwrap(CostUsageScanner.Pricing.claudeCostUSD(
            model: "claude-sonnet-4-5", inputTokens: 3, cacheReadInputTokens: 50_000,
            cacheCreationInputTokens: 0, outputTokens: 311
        ))
        XCTAssertEqual(cost("Claude", entries), priced, accuracy: 1e-9)
    }

    /// Fails without the fix. The first lines of a response are read by one
    /// scan and the rest by the next (a scan runs every minute while a
    /// response streams); the response still counts once, from its last line.
    func test_linesOfAResponseReadByTwoScansCountOnce() throws {
        let log = try write([
            claudeLine(message: "msg-0", request: "req-0", usage: nativeUsage(output: 120), stopReason: .value("end_turn")),
            claudeLine(message: "msg-1", request: "req-1", usage: nativeUsage(output: 2), stopReason: .null),
        ], to: claudeLog())
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 6, cached: 100_000, output: 122))

        try append([
            claudeLine(message: "msg-1", request: "req-1", usage: nativeUsage(output: 40), stopReason: .null),
            claudeLine(message: "msg-1", request: "req-1", usage: nativeUsage(output: 311), stopReason: .value("end_turn")),
        ].joined(separator: "\n") + "\n", to: log)
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 6, cached: 100_000, output: 431))

        // A full re-read of the same log agrees.
        XCTAssertEqual(totals("Claude", scan(force: true)), Totals(input: 6, cached: 100_000, output: 431))
    }

    // MARK: - Claude: a response met again after it left the newest few

    /// `count` finished responses, each adding 1 input, 10 cache reads and 5
    /// output. Enough of them push an earlier response out of the newest few
    /// the cache keeps whole (`claudeOpenRowLimit`).
    private func finishedResponses(_ count: Int, prefix: String = "msg") -> [String] {
        (1...count).map {
            claudeLine(message: "\(prefix)-\($0)", request: "req-\(prefix)-\($0)",
                       usage: nativeUsage(input: 1, cacheRead: 10, output: 5), stopReason: .value("end_turn"))
        }
    }

    private func responseA(output: Int, finished: Bool) -> String {
        claudeLine(message: "msg-a", request: "req-a", usage: nativeUsage(input: 7, cacheRead: 1000, output: output),
                   stopReason: finished ? .value("end_turn") : .null)
    }

    /// Claude Code writes earlier lines of a log again further down it: same
    /// message, request and usage, with their original timestamps, hundreds of
    /// responses later. A read of the whole log counts the response once, and
    /// so must a scan that reads only the copy.
    func test_aLineWrittenAgainFurtherDownALogCountsOnce() throws {
        let log = try write([responseA(output: 90, finished: true)] + finishedResponses(5), to: claudeLog())
        let expected = Totals(input: 12, cached: 1050, output: 115)
        XCTAssertEqual(totals("Claude", scan()), expected)

        try append(responseA(output: 90, finished: true) + "\n", to: log)
        XCTAssertEqual(totals("Claude", scan()), expected)
        // Written again together with a new response.
        try append(([responseA(output: 90, finished: true)] + finishedResponses(1, prefix: "new")).joined(separator: "\n") + "\n", to: log)
        let withNew = Totals(input: 13, cached: 1060, output: 120)
        XCTAssertEqual(totals("Claude", scan()), withNew)
        XCTAssertEqual(totals("Claude", scan(force: true)), withNew)
    }

    /// A response still streaming when five more started is no longer among
    /// the newest few the cache keeps whole. Its last line, read by a later
    /// scan, still replaces its first line instead of adding to it.
    func test_aResponseContinuedAfterItLeftTheNewestFewCountsOnce() throws {
        let log = try write([responseA(output: 2, finished: false)] + finishedResponses(5), to: claudeLog())
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 12, cached: 1050, output: 27))

        try append(responseA(output: 90, finished: true) + "\n", to: log)
        let expected = Totals(input: 12, cached: 1050, output: 115)
        XCTAssertEqual(totals("Claude", scan()), expected)
        XCTAssertEqual(totals("Claude", scan(force: true)), expected)
    }

    /// The newest response carried from one scan continues after the next
    /// scan brought a new one. (The order carried between scans is pinned in
    /// `CostUsageAccountingRulesTests`.)
    func test_theNewestCarriedResponseContinuesAfterANewOneArrives() throws {
        let log = try write(finishedResponses(4) + [responseA(output: 2, finished: false)], to: claudeLog())
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 11, cached: 1040, output: 22))

        try append(finishedResponses(1, prefix: "new")[0] + "\n", to: log)
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 12, cached: 1050, output: 27))

        try append(responseA(output: 90, finished: true) + "\n", to: log)
        let expected = Totals(input: 12, cached: 1050, output: 115)
        XCTAssertEqual(totals("Claude", scan()), expected)
        XCTAssertEqual(totals("Claude", scan(force: true)), expected)
    }

    /// A log idle for longer than `claudeLogStateIdleSeconds` keeps no state.
    /// When it grows it is read from the start, so a response it already
    /// holds still counts once.
    func test_aLogThatGrowsAfterADayIdleIsReadFromTheStart() throws {
        let log = try write([responseA(output: 90, finished: true)], to: claudeLog())
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 7, cached: 1000, output: 90))

        let idle = Date().addingTimeInterval(-(CostUsageScanner.claudeLogStateIdleSeconds + 60))
        try FileManager.default.setAttributes([.modificationDate: idle], ofItemAtPath: log.path)
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 7, cached: 1000, output: 90))

        try append(([responseA(output: 90, finished: true)] + finishedResponses(1)).joined(separator: "\n") + "\n", to: log)
        let expected = Totals(input: 8, cached: 1010, output: 95)
        XCTAssertEqual(totals("Claude", scan()), expected)
        XCTAssertEqual(totals("Claude", scan(force: true)), expected)
    }

    // MARK: - Claude: a proxy's preliminary estimate

    private func preliminaryLine() -> String {
        claudeLine(message: "response", usage: ["input_tokens": 1612, "output_tokens": 0], stopReason: .null)
    }

    private func completedLine() -> String {
        claudeLine(message: "response",
                   usage: ["input_tokens": 191, "cache_read_input_tokens": 1664, "output_tokens": 5],
                   stopReason: .value("end_turn"))
    }

    /// Fails without the fix (upstream #3688). A proxy writes a cache-unaware
    /// input estimate before the response finishes; on its own it is not
    /// billed. The line is still a message.
    func test_aPreliminaryProxyEstimateIsNotBilled() throws {
        try write([preliminaryLine()], to: claudeLog())
        let entries = scan()
        XCTAssertEqual(totals("Claude", entries), Totals())
        XCTAssertEqual(cost("Claude", entries), 0)
        XCTAssertEqual(entries.filter { $0.provider == "Claude" }.reduce(0) { $0 + $1.messageCount }, 1)
    }

    /// Fails without the fix. The completed record counts, whichever order
    /// the two lines are in and whether or not a scan ran between them.
    func test_theCompletedResponseReplacesItsEstimateInEitherOrder() throws {
        let orders = [("estimate first", [preliminaryLine(), completedLine()]),
                      ("completed first", [completedLine(), preliminaryLine()])]
        for (name, lines) in orders {
            for scanBetween in [false, true] {
                try? FileManager.default.removeItem(at: cacheRoot)
                let log = claudeLog()
                if scanBetween {
                    try write([lines[0]], to: log)
                    scan()
                    try append(lines[1] + "\n", to: log)
                } else {
                    try write(lines, to: log)
                }
                XCTAssertEqual(totals("Claude", scan()), Totals(input: 191, cached: 1664, output: 5),
                               "\(name), scan between: \(scanBetween)")
            }
        }
    }

    /// Positive control: lines that share part of that shape but are complete
    /// records still count. An older log has no `stop_reason` at all; Claude
    /// Code's own unfinished lines carry the two cache fields.
    func test_completeRecordsWithZeroOutputStillCount() throws {
        try write([
            claudeLine(message: "legacy", usage: ["input_tokens": 100, "output_tokens": 0]),
            claudeLine(message: "native", request: "req-n",
                       usage: ["input_tokens": 7, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 0],
                       stopReason: .null),
        ], to: claudeLog())
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 107, cached: 0, output: 0))
    }

    // MARK: - A line still being written

    /// Fails without the fix (upstream #2168). A scan that meets half a line
    /// at the end of a log must read that line whole once it is finished.
    func test_aClaudeLineStillBeingWrittenIsReadOnceComplete() throws {
        let second = claudeLine(message: "msg-2", request: "req-2", usage: nativeUsage(output: 70), stopReason: .value("end_turn"))
        let split = second.index(second.startIndex, offsetBy: second.count / 2)
        let log = try write([
            claudeLine(message: "msg-1", request: "req-1", usage: nativeUsage(output: 30), stopReason: .value("end_turn")),
            String(second[..<split]),
        ], to: claudeLog(), trailingNewline: false)
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 3, cached: 50_000, output: 30))

        try append(String(second[split...]) + "\n", to: log)
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 6, cached: 100_000, output: 100))
    }

    /// Fails without the fix. The same for a Codex event; here the half line
    /// is the log's newest cumulative reading.
    func test_aCodexEventStillBeingWrittenIsReadOnceComplete() throws {
        let second = codexTokenCount(total: (5000, 3000, 400), last: (3000, 2000, 300))
        let split = second.index(second.startIndex, offsetBy: second.count / 2)
        let log = try write([
            json(["type": "session_meta", "timestamp": stamp, "payload": ["id": "thread-1"]]),
            codexTurnContext(),
            codexTokenCount(total: (2000, 1000, 100), last: (2000, 1000, 100)),
            String(second[..<split]),
        ], to: codexLog("thread-1"), trailingNewline: false)
        XCTAssertEqual(totals("Codex", scan()), Totals(input: 2000, cached: 1000, output: 100))

        try append(String(second[split...]) + "\n", to: log)
        XCTAssertEqual(totals("Codex", scan()), Totals(input: 5000, cached: 3000, output: 400))
    }

    /// Positive control: a complete last line without a newline is read, and
    /// read once when the log grows after it.
    func test_aCompleteLastLineWithoutANewlineIsReadOnce() throws {
        let log = try write([
            claudeLine(message: "msg-1", request: "req-1", usage: nativeUsage(output: 10), stopReason: .value("end_turn")),
            claudeLine(message: "msg-2", request: "req-2", usage: nativeUsage(output: 20), stopReason: .value("end_turn")),
        ], to: claudeLog(), trailingNewline: false)
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 6, cached: 100_000, output: 30))

        try append("\n" + claudeLine(message: "msg-3", request: "req-3", usage: nativeUsage(output: 40), stopReason: .value("end_turn")) + "\n", to: log)
        XCTAssertEqual(totals("Claude", scan()), Totals(input: 9, cached: 150_000, output: 70))
    }

    // MARK: - Codex: a continuation page

    /// The session meta of a later page of a long Codex Desktop thread: the
    /// same thread id, the original fork parent, and `history_base` naming the
    /// thread itself. Shape and numbers from upstream's
    /// `CodexPaginatedHistoryAccountingTests`.
    private func pageTwoMeta() -> String {
        json([
            "type": "session_meta", "timestamp": stamp,
            "payload": [
                "id": "thread-session", "session_id": "thread-session",
                "forked_from_id": "original-ancestor", "timestamp": stamp,
                "history_mode": "paginated",
                "history_base": ["thread_id": "thread-session", "end_ordinal_exclusive": 38505, "end_byte_offset": 1_149_737_650],
            ],
        ])
    }

    private let pageTwoFirst = (total: (740_012_153, 725_510_144, 1_564_472), last: (188_393, 188_288, 1616))
    private let pageTwoSecond = (total: (757_818_385, 742_942_720, 1_616_068), last: (138_824, 136_192, 1200))

    /// Fails on a scanner without an inherited baseline (upstream #3753). The
    /// page's first reading holds the whole thread so far; only the page's own
    /// requests are new.
    func test_aContinuationPageBillsOnlyItsOwnRequests() throws {
        try write([
            pageTwoMeta(),
            codexTurnContext(),
            codexTokenCount(total: pageTwoFirst.total, last: pageTwoFirst.last),
            codexTokenCount(total: pageTwoSecond.total, last: pageTwoSecond.last),
        ], to: codexLog("page-two"))
        // Last total minus (first total - first last).
        XCTAssertEqual(totals("Codex", scan()), Totals(input: 17_994_625, cached: 17_620_864, output: 53_212))
    }

    /// Fails on a scanner without an inherited baseline. Read in two scans,
    /// the page adds up the same.
    func test_aContinuationPageReadByTwoScansAddsUpTheSame() throws {
        let log = try write([
            pageTwoMeta(),
            codexTurnContext(),
            codexTokenCount(total: pageTwoFirst.total, last: pageTwoFirst.last),
        ], to: codexLog("page-two"))
        XCTAssertEqual(totals("Codex", scan()), Totals(input: 188_393, cached: 188_288, output: 1616))

        try append(codexTokenCount(total: pageTwoSecond.total, last: pageTwoSecond.last) + "\n", to: log)
        XCTAssertEqual(totals("Codex", scan()), Totals(input: 17_994_625, cached: 17_620_864, output: 53_212))
    }

    /// Positive control: a log that starts its own count (its first reading's
    /// total is that request) is counted in full, as before.
    func test_aLogThatStartsItsOwnCountIsCountedInFull() throws {
        try write([
            json(["type": "session_meta", "timestamp": stamp, "payload": ["id": "thread-2"]]),
            codexTurnContext(),
            codexTokenCount(total: (1000, 800, 50), last: (1000, 800, 50)),
            codexTokenCount(total: (1500, 1000, 80), last: (500, 200, 30)),
        ], to: codexLog("thread-2"))
        XCTAssertEqual(totals("Codex", scan()), Totals(input: 1500, cached: 1000, output: 80))
    }
}

#endif

import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.58 (P1-4): the scan's rows split by project, from fixture logs.
///
/// Codex: the folder is `session_meta.payload.cwd`; a log with none is
/// "Unknown"; Codex worktrees and `/private/tmp` fold into the checkout they
/// were made from when the logs alone can tell which (the same repository, by
/// hash), and every other folder is a project of its own. Claude: the folder
/// a transcript's `cwd` leads back to, for every transcript of the project
/// directory, subagents and workflow runs included; the decoded directory
/// name when none recorded one. Either way the projects add up to the scan's
/// rows, and nothing is ever kept of a repository's URL but its hash.
final class ProjectScanTests: XCTestCase {

    private var tmpRoot: URL!
    private var codexDay: URL!
    private var claudeRoot: URL!
    private var cacheRoot: URL!

    private let home = "/Users/sample"

    private let stamp: String = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }()

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-projects-\(UUID().uuidString)", isDirectory: true)
        codexDay = CostUsageScanner.DayRange.dayKey(from: Date()).split(separator: "-")
            .reduce(tmpRoot.appendingPathComponent("codex/sessions", isDirectory: true)) {
                $0.appendingPathComponent(String($1), isDirectory: true)
            }
        claudeRoot = tmpRoot.appendingPathComponent("claude-projects", isDirectory: true)
        cacheRoot = tmpRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        tmpRoot = nil
    }

    // MARK: - Fixtures

    private func scan(force: Bool = false, splitsByProject: Bool = true) -> CostUsageScanResult {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: tmpRoot.appendingPathComponent("codex/sessions", isDirectory: true),
            claudeProjectsRoots: [claudeRoot],
            cacheRoot: cacheRoot
        )
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = force
        options.splitsByProject = splitsByProject
        options.homeDirectory = home
        return CostUsageScanner.scan(options: options)
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// A Codex rollout: its session_meta (with `cwd` and a repository when
    /// given), the model, and one request.
    private func codexRollout(
        _ id: String, cwd: String?, repository: String? = nil, tokens: (Int, Int, Int)
    ) throws {
        var payload: [String: Any] = ["id": id, "timestamp": stamp]
        payload["cwd"] = cwd
        if let repository {
            payload["git"] = ["branch": "main", "commit_hash": "0123abcd", "repository_url": repository]
        }
        let usage: [String: Int] = ["input_tokens": tokens.0, "cached_input_tokens": tokens.1, "output_tokens": tokens.2]
        try write([
            json(["type": "session_meta", "timestamp": stamp, "payload": payload]),
            json(["type": "turn_context", "timestamp": stamp, "payload": ["model": "gpt-5.5"]]),
            json(["type": "event_msg", "timestamp": stamp,
                  "payload": ["type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage]]]),
        ], to: codexDay.appendingPathComponent("rollout-\(id).jsonl"))
    }

    /// A Claude transcript line with its usage, and the working directory
    /// Claude Code records on every conversation line (when given).
    private func claudeLine(_ message: String, cwd: String?, output: Int) -> String {
        var event: [String: Any] = [
            "type": "assistant", "timestamp": stamp, "sessionId": "session-1", "requestId": "req-" + message,
            "message": ["id": message, "model": "claude-sonnet-4-5", "stop_reason": "end_turn",
                        "usage": ["input_tokens": 10, "cache_creation_input_tokens": 0,
                                  "cache_read_input_tokens": 1_000, "output_tokens": output]],
        ]
        event["cwd"] = cwd
        return json(event)
    }

    private func claudeTranscript(_ relativePath: String, cwd: String?, output: Int) throws {
        try write([claudeLine(relativePath, cwd: cwd, output: output)],
                  to: claudeRoot.appendingPathComponent(relativePath))
    }

    private struct Sum: Equatable {
        var input = 0, cached = 0, output = 0
        var cost = 0.0

        static func == (lhs: Sum, rhs: Sum) -> Bool {
            lhs.input == rhs.input && lhs.cached == rhs.cached && lhs.output == rhs.output
                && abs(lhs.cost - rhs.cost) < 1e-9
        }
    }

    /// Each (day, model) row of `provider`, added up from the scan's rows
    /// and from its project rows.
    private func rows(_ result: CostUsageScanResult, _ provider: String) -> (scan: [String: Sum], projects: [String: Sum]) {
        var scan: [String: Sum] = [:]
        for e in result.entries where e.provider == provider && e.model != ScanEntry.messageBucketModel {
            let key = e.date + "|" + e.model
            scan[key, default: Sum()].input += e.inputTokens
            scan[key, default: Sum()].cached += e.cachedTokens
            scan[key, default: Sum()].output += e.outputTokens
            scan[key, default: Sum()].cost += e.costUSD ?? 0
        }
        var projects: [String: Sum] = [:]
        for p in result.projects where p.provider == provider {
            let key = p.date + "|" + p.model
            projects[key, default: Sum()].input += p.inputTokens
            projects[key, default: Sum()].cached += p.cachedTokens
            projects[key, default: Sum()].output += p.outputTokens
            projects[key, default: Sum()].cost += p.costUSD ?? 0
        }
        return (scan, projects)
    }

    private func projects(_ result: CostUsageScanResult, _ provider: String) -> [ProjectUsageRow] {
        ProjectUsageRanking.rows(result.projects, provider: provider, basis: .eachOnce,
                                 todayKey: CostUsageScanner.DayRange.dayKey(from: Date()))
    }

    private func cacheText(_ provider: String) throws -> String {
        try String(contentsOf: CostUsageCacheIO.cacheFileURL(provider: provider, cacheRoot: cacheRoot), encoding: .utf8)
    }

    // MARK: - Codex

    func testCodexProjectsAreTheirWorkingDirectoriesAndAddUpToTheRows() throws {
        try codexRollout("thread-a", cwd: "/Users/sample/Projects/demo-app", tokens: (1_000, 200, 100))
        try codexRollout("thread-b", cwd: "/Users/sample/Projects/other-app", tokens: (500, 0, 50))
        try codexRollout("thread-c", cwd: "/Users/sample/Projects/demo-app/ios", tokens: (300, 0, 30))
        try codexRollout("thread-d", cwd: nil, tokens: (200, 100, 20))
        let result = scan()

        let found = projects(result, "Codex")
        XCTAssertEqual(Set(found.map { $0.project.name ?? "<unknown>" }),
                       ["demo-app", "other-app", "ios", "<unknown>"],
                       "a subfolder is a folder of its own: nothing asks git where the checkout starts")
        XCTAssertEqual(found.first { $0.project.name == "demo-app" }?.project.path, "/Users/sample/Projects/demo-app")
        XCTAssertEqual(found.first { $0.project.name == "demo-app" }?.tokens, 1_100)
        XCTAssertEqual(found.first { $0.project.isUnknown }?.tokens, 220, "a log with no cwd is Unknown")

        let (scanRows, projectRows) = rows(result, "Codex")
        XCTAssertFalse(scanRows.isEmpty)
        XCTAssertEqual(projectRows, scanRows, "the projects do not add up to the Codex rows")
    }

    /// Codex worktrees and `/private/tmp` clones are copies of a checkout,
    /// and count for it when they name its repository; any other folder,
    /// another git worktree included, is a project of its own.
    func testTemporaryCopiesFoldIntoTheirCheckoutAndOtherWorktreesStayApart() throws {
        let repository = "https://x-access-token:s3cret-token@github.example/sample/demo-app.git"
        let other = "git@github.example:sample/lonely.git"
        try codexRollout("thread-1", cwd: "/Users/sample/Projects/demo-app", repository: repository, tokens: (1_000, 0, 100))
        try codexRollout("thread-2", cwd: "/Users/sample/.codex/worktrees/a1b2/demo-app/ios",
                         repository: repository, tokens: (400, 0, 40))
        try codexRollout("thread-3", cwd: "/tmp/clone-7", repository: repository, tokens: (200, 0, 20))
        try codexRollout("thread-4", cwd: "/Users/sample/.codex/worktrees/c3d4/lonely", repository: other, tokens: (300, 0, 30))
        try codexRollout("thread-5", cwd: "/Users/sample/.codex/worktrees/e5f6/lonely", repository: other, tokens: (100, 0, 10))
        try codexRollout("thread-6", cwd: "/private/tmp/scratch", tokens: (50, 0, 5))
        try codexRollout("thread-7", cwd: "/Users/sample/wt/demo-app-feature", repository: repository, tokens: (70, 0, 7))
        let result = scan()

        let found = projects(result, "Codex")
        XCTAssertEqual(Set(found.compactMap(\.project.name)), ["demo-app", "lonely", "scratch", "demo-app-feature"])
        let demo = try XCTUnwrap(found.first { $0.project.name == "demo-app" })
        XCTAssertEqual(demo.project.path, "/Users/sample/Projects/demo-app")
        XCTAssertEqual(demo.tokens, 1_100 + 440 + 220, "the worktree and the clone count for the checkout")
        let lonely = try XCTUnwrap(found.first { $0.project.name == "lonely" })
        XCTAssertEqual(lonely.tokens, 330 + 110, "the worktrees of a repository with no checkout share a line")
        XCTAssertEqual(lonely.project.path, "/Users/sample/.codex/worktrees/c3d4/lonely",
                       "shown under the worktree with the most tokens")
        XCTAssertEqual(found.first { $0.project.name == "scratch" }?.project.path, "/private/tmp/scratch")

        let (scanRows, projectRows) = rows(result, "Codex")
        XCTAssertEqual(projectRows, scanRows)

        // The URL, token and host are nowhere in what the scan keeps.
        let cache = try cacheText("codex")
        for secret in ["s3cret-token", "github.example", "x-access-token", "lonely.git"] {
            XCTAssertNil(cache.range(of: secret), "the Codex cache holds \(secret)")
        }
        XCTAssertNotNil(cache.range(of: try XCTUnwrap(ProjectPathNormalizer.repositoryHash(repository))),
                        "positive control: the cache keeps the repository's hash")
    }

    /// Negative control for the folding: without a repository a clone in
    /// `/private/tmp` cannot be told to be a copy, and keeps its own line.
    func testATemporaryFolderNamingNoRepositoryKeepsItsOwnLine() throws {
        try codexRollout("thread-1", cwd: "/Users/sample/Projects/demo-app",
                         repository: "https://github.example/sample/demo-app.git", tokens: (1_000, 0, 100))
        try codexRollout("thread-2", cwd: "/tmp/demo-app", tokens: (200, 0, 20))
        XCTAssertEqual(projects(scan(), "Codex").map(\.project.path),
                       ["/Users/sample/Projects/demo-app", "/private/tmp/demo-app"])
    }

    /// A cache written before 1.58 has no folder for its logs. The next
    /// refresh reads each log's first line for it once, without reading the
    /// log again for its usage.
    func testALogCachedBefore158GetsItsFolderFromItsFirstLine() throws {
        try codexRollout("thread-a", cwd: "/Users/sample/Projects/demo-app", tokens: (1_000, 200, 100))
        XCTAssertEqual(projects(scan(), "Codex").map(\.project.name), ["demo-app"])

        // The cache as 1.57 wrote it: no `project` in any entry.
        let url = CostUsageCacheIO.cacheFileURL(provider: "codex", cacheRoot: cacheRoot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var files = try XCTUnwrap(object["files"] as? [String: [String: Any]])
        for key in files.keys { files[key]?.removeValue(forKey: "project") }
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertNil(try cacheText("codex").range(of: "\"project\""), "the 1.57-shaped cache still names a project")

        XCTAssertEqual(projects(scan(), "Codex").map(\.project.name), ["demo-app"])
        XCTAssertNotNil(try cacheText("codex").range(of: "demo-app"), "the folder found was not kept")
    }

    // MARK: - Claude

    /// Every transcript of a project directory counts for the folder it was
    /// made from: the session's own, its subagents' (which can run in a
    /// subfolder) and its workflow runs' (which can run in another worktree
    /// entirely).
    func testClaudeSubagentsCountForTheirSessionsProject() throws {
        let dir = "-Users-sample-Projects-demo-app"
        try claudeTranscript("\(dir)/session-1.jsonl", cwd: "/Users/sample/Projects/demo-app", output: 100)
        try claudeTranscript("\(dir)/session-1/subagents/agent-a1.jsonl",
                             cwd: "/Users/sample/Projects/demo-app/ios", output: 40)
        try claudeTranscript("\(dir)/session-1/subagents/workflows/wf-1/agent-b2.jsonl",
                             cwd: "/Users/sample/elsewhere/feature-wt", output: 20)
        try claudeTranscript("-Users-sample-Projects-quiet-app/session-2.jsonl", cwd: nil, output: 10)
        try claudeTranscript("stray.jsonl", cwd: "/Users/sample/Projects/stray", output: 5)
        let result = scan()

        let found = projects(result, "Claude")
        let demo = try XCTUnwrap(found.first { $0.project.name == "demo-app" }, "\(found.map(\.project))")
        XCTAssertEqual(demo.project.path, "/Users/sample/Projects/demo-app")
        XCTAssertEqual(demo.tokens, (10 + 1_000) * 3 + 100 + 40 + 20,
                       "the subagent and the workflow run count for the session's project")
        XCTAssertNil(found.first { $0.project.name == "ios" || $0.project.name == "feature-wt" || $0.project.name == "subagents" })

        // No transcript of the directory recorded a cwd: the decoded name, no path.
        let quiet = try XCTUnwrap(found.first { $0.project.name == "Projects-quiet-app" }, "\(found.map(\.project))")
        XCTAssertNil(quiet.project.path)
        // A transcript directly in the projects root has no directory: Unknown.
        XCTAssertEqual(found.first { $0.project.isUnknown }?.tokens, 1_010 + 5)
        XCTAssertEqual(found.count, 3)

        let (scanRows, projectRows) = rows(result, "Claude")
        XCTAssertFalse(scanRows.isEmpty)
        XCTAssertEqual(projectRows, scanRows, "the projects do not add up to the Claude rows")

        // The folder is kept with the cache, so the transcripts are not opened
        // for it on the next refresh.
        XCTAssertNotNil(try cacheText("claude").range(of: "projectRoots"))
        XCTAssertEqual(projects(scan(), "Claude").first { $0.project.name == "demo-app" }?.tokens, demo.tokens)
    }

    /// The year-long reads that fill the usage archive keep day rows only:
    /// no projects, and no transcript opened to name one.
    func testAScanThatDoesNotSplitByProjectLearnsNoFolder() throws {
        try codexRollout("thread-a", cwd: "/Users/sample/Projects/demo-app", tokens: (1_000, 200, 100))
        try claudeTranscript("-Users-sample-Projects-demo-app/session-1.jsonl",
                             cwd: "/Users/sample/Projects/demo-app", output: 100)
        let result = scan(splitsByProject: false)
        XCTAssertFalse(result.entries.isEmpty, "positive control: the scan read the logs")
        XCTAssertTrue(result.projects.isEmpty)
        XCTAssertNil(try cacheText("claude").range(of: "projectRoots"))

        // Negative control: the same logs, split.
        XCTAssertFalse(scan(splitsByProject: true).projects.isEmpty)
        XCTAssertNotNil(try cacheText("claude").range(of: "projectRoots"))
    }
}

#endif

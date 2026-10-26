import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.59 (59-03): a Codex conversation that keeps writing to a file in a date
/// folder older than the scan's window.
///
/// Codex writes a conversation to the file it started in, under the folder of
/// the day it started. Resumed weeks later (`codex resume`), it writes the
/// window's days into a folder the window does not list. Until 1.59 that file
/// was not read at all. Now a file outside the window's folders is read when
/// it was last written on or after the window's first instant
/// (`CostUsageScanner.listCodexSessionFiles`).
///
/// What each file counts, including the copied-history and copy cases, is
/// pinned in the shared fixtures (`codex-accounting-cases.json`, the cases
/// named for older folders), which the Python replica is held to as well.
/// These tests cover what the fixtures cannot: the live-session candidates,
/// the Sessions and Projects split, and a file leaving the scan once the
/// window has passed its last write.
final class CodexOlderFolderLookbackTests: XCTestCase {

    private var tmpRoot: URL!
    private var codexRoot: URL!
    private var cacheRoot: URL!

    /// Noon today, so whole days can be counted back from it.
    private let now: Date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    private let cwd = "/work/sample-app"

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-codex-lookback-\(UUID().uuidString)", isDirectory: true)
        codexRoot = tmpRoot.appendingPathComponent("codex/sessions", isDirectory: true)
        cacheRoot = tmpRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        tmpRoot = nil
    }

    private func ago(days: Int, hours: Double = 0) -> Date {
        (Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now).addingTimeInterval(-hours * 3600)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func tokenCount(at date: Date, total: Int, last: Int) -> String {
        func usage(_ input: Int) -> [String: Int] {
            ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": input / 10]
        }
        return json([
            "type": "event_msg", "timestamp": stamp(date),
            "payload": ["type": "token_count", "info": ["total_token_usage": usage(total), "last_token_usage": usage(last)]],
        ])
    }

    /// A conversation started `startedDaysAgo` days ago, in that day's folder,
    /// with one request then and one `resumedHoursAgo` hours ago; the file was
    /// last written at `lastWrite`.
    @discardableResult
    private func resumedRollout(
        _ id: String, startedDaysAgo: Int, resumedHoursAgo: Double, lastWrite: Date
    ) throws -> URL {
        let started = ago(days: startedDaysAgo)
        let lines = [
            json(["type": "session_meta", "timestamp": stamp(started),
                  "payload": ["id": id, "session_id": id, "cwd": cwd, "timestamp": stamp(started)]]),
            json(["type": "turn_context", "timestamp": stamp(started), "payload": ["model": "gpt-5.5"]]),
            tokenCount(at: started.addingTimeInterval(60), total: 50_000, last: 50_000),
            tokenCount(at: now.addingTimeInterval(-resumedHoursAgo * 3600), total: 50_700, last: 700),
        ]
        let folder = DayKey.string(from: started).split(separator: "-")
            .reduce(codexRoot!) { $0.appendingPathComponent(String($1), isDirectory: true) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("rollout-\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: lastWrite], ofItemAtPath: url.path)
        return url
    }

    private func scan(at moment: Date? = nil) -> CostUsageScanResult {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: codexRoot, claudeProjectsRoots: [], cacheRoot: cacheRoot,
            daysToScan: LocalScanDisclosure.routineWindowDays)
        options.refreshMinIntervalSeconds = 0
        options.homeDirectory = "/work"
        options.now = moment ?? now
        return CostUsageScanner.scan(options: options)
    }

    /// A temporary path as either spelling of it: the directory listings
    /// return `/private/var/...` for the `/var/...` the test wrote to.
    private func samePath(_ a: String, _ b: String) -> Bool {
        func canonical(_ path: String) -> String {
            path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
        }
        return canonical(a) == canonical(b)
    }

    private func isCached(_ url: URL) -> Bool {
        CostUsageCacheIO.load(provider: "codex", cacheRoot: cacheRoot).files.keys.contains { samePath($0, url.path) }
    }

    private func ioTokens(_ entries: [CostUsageScanResult.DailyEntry]) -> Int {
        entries.filter { $0.provider == "Codex" }.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    /// A conversation resumed from a 90-day-old folder a minute ago is a
    /// running session, as one started today is: the candidates come from
    /// the same listing. Its tokens are the resumed request's only.
    func test_a_conversation_resumed_from_an_older_folder_is_running() throws {
        let url = try resumedRollout("resumed-now", startedDaysAgo: 90, resumedHoursAgo: 0.02,
                                     lastWrite: now.addingTimeInterval(-60))
        let result = scan()
        let candidate = try XCTUnwrap(result.activeSessionCandidates.first { $0.provider == "Codex" },
                                      "a conversation resumed from an older folder is not seen as running")
        XCTAssertTrue(samePath(candidate.filePath, url.path), candidate.filePath)
        XCTAssertEqual(candidate.sessionId, "resumed-now")
        XCTAssertEqual(candidate.projectName, "sample-app")
        XCTAssertEqual(candidate.totalTokens, 770, "the 90-day-old request is not the session's usage this window")
        XCTAssertEqual(ioTokens(result.entries), 770)
    }

    /// Sessions and Projects add up what the day rows add up: the resumed
    /// request, under the conversation and the folder it ran in.
    func test_its_usage_is_in_sessions_and_projects() throws {
        try resumedRollout("resumed-yesterday", startedDaysAgo: 45, resumedHoursAgo: 24, lastWrite: ago(days: 1))
        let result = scan()
        XCTAssertEqual(ioTokens(result.entries), 770)

        let sessions = result.sessions.filter { $0.provider == "Codex" }
        XCTAssertEqual(Set(sessions.map(\.session)), ["codex:resumed-yesterday"])
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }, 770)

        let projects = result.projects.filter { $0.provider == "Codex" }
        XCTAssertEqual(Set(projects.map(\.project.path)), [cwd])
        XCTAssertEqual(projects.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }, 770)
    }

    /// Once the window has moved past a file's last write, the file is no
    /// longer listed: it leaves the cache with its days instead of being
    /// read on every refresh for nothing.
    func test_a_file_leaves_the_scan_once_the_window_passes_its_last_write() throws {
        let url = try resumedRollout("resumed-then-idle", startedDaysAgo: 60, resumedHoursAgo: 48, lastWrite: ago(days: 2))
        XCTAssertEqual(ioTokens(scan().entries), 770)
        XCTAssertTrue(isCached(url))

        let later = Calendar.current.date(byAdding: .day, value: 40, to: now) ?? now
        XCTAssertEqual(ioTokens(scan(at: later).entries), 0)
        XCTAssertFalse(isCached(url), "a file last written before the window is still listed")
    }
}

#endif

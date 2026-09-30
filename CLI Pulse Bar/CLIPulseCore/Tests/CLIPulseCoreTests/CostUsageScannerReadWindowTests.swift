import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.55 — the routine scan does not open a Claude log that was last written
/// before its window.
///
/// Until 1.55 `scanClaudeRoot` parsed every `.jsonl` under the Claude project
/// roots, whatever its age, on a first scan and after every cache reset, and
/// dropped the old lines only once they had been read. The consent screen says
/// the routine scan covers the last 30 days; a log nobody has written to since
/// before that window has nothing in it the scan may use, so it is not opened.
///
/// The fixture is deliberately impossible in real life: a line stamped today in
/// a file whose last write was 40 days ago. That is what makes the test able to
/// tell "skipped" from "opened, and its old lines dropped" — a realistic old log
/// contributes nothing either way, so it could not fail.
final class CostUsageScannerReadWindowTests: XCTestCase {

    private var tmpRoot: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-read-window-\(UUID().uuidString)", isDirectory: true)
        claudeRoot = tmpRoot.appendingPathComponent("claude-projects", isDirectory: true)
        codexRoot = tmpRoot.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeRoot.appendingPathComponent("-Users-someone-project", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        tmpRoot = nil
    }

    /// One assistant line, stamped now, with 300 tokens, in a file whose last
    /// write is `lastWritten`.
    private func writeClaudeLog(lastWritten: Date) throws {
        let url = claudeRoot
            .appendingPathComponent("-Users-someone-project", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
        {"type":"assistant","timestamp":"\(iso.string(from: Date()))","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-5","usage":{"input_tokens":200,"output_tokens":100}}}
        """
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: lastWritten], ofItemAtPath: url.path)
    }

    /// Claude tokens a fresh scan (its own empty cache) reports.
    private func claudeTokens(daysToScan: Int) -> Int {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: codexRoot,
            claudeProjectsRoots: [claudeRoot],
            cacheRoot: tmpRoot.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true),
            daysToScan: daysToScan
        )
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        return CostUsageScanner.scan(options: options).entries
            .filter { $0.provider == "Claude" }
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    private func daysAgo(_ days: Int) -> Date {
        Date().addingTimeInterval(-Double(days) * 86_400)
    }

    func test_aLogLastWrittenBeforeTheRoutineWindowIsNotOpened() throws {
        try writeClaudeLog(lastWritten: daysAgo(40))
        XCTAssertEqual(
            claudeTokens(daysToScan: LocalScanDisclosure.routineWindowDays),
            0,
            "a log last written 40 days ago was opened by the 30-day scan"
        )
    }

    /// Positive control: the same file, last written inside the window, is
    /// read — so a zero above is the skip, not a fixture that never parses.
    func test_aLogWrittenInsideTheWindowIsRead() throws {
        try writeClaudeLog(lastWritten: Date())
        XCTAssertEqual(claudeTokens(daysToScan: LocalScanDisclosure.routineWindowDays), 300)
    }

    /// The bound is the window the scan was given, not a fixed 30 days: the
    /// one-time history read (365 days, after a v2 yes) still opens a log last
    /// written 40 days ago.
    func test_theHistoryReadStillOpensLogsInsideItsOwnWindow() throws {
        try writeClaudeLog(lastWritten: daysAgo(40))
        XCTAssertEqual(claudeTokens(daysToScan: LocalScanDisclosure.historyWindowDays), 300)
    }
}

#endif

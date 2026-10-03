import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// The Codex scanner against the shared fixtures in
/// `Tests/Fixtures/codex-accounting-cases.json`.
///
/// Each case is a set of rollout files shaped like real Codex logs and the
/// per-day, per-model `[input, cached, output]` the app must report for them.
/// `scripts/test_codex_accounting_replica.py` holds the Python replica to the
/// same file, so the two agree on every case — which is what lets the replica
/// check the app on a real machine (`scripts/codex_accounting_replica.py
/// --app-cache`).
///
/// Every case runs three ways: a full scan from an empty cache; the same scan
/// repeated on the saved cache (the day rows are rebuilt, never added twice);
/// and an incremental one, where each file is first scanned half-written and
/// then scanned again after the rest is appended — so the counting state saved
/// with a file resumes exactly where a full parse would have been.
final class CodexAccountingFixtureTests: XCTestCase {

    private struct Fixtures: Decodable {
        let now_utc: String
        let days_to_scan: Int
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let description: String
        let files: [File]
        let expected: [String: [String: [Int]]]
    }

    private struct File: Decodable {
        let path: String
        let lines: [AnyJSON]
    }

    /// A fixture line kept as a JSON value, written back out compactly.
    private struct AnyJSON: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { value = NSNull() }
            else if let b = try? container.decode(Bool.self) { value = b }
            else if let i = try? container.decode(Int.self) { value = i }
            else if let d = try? container.decode(Double.self) { value = d }
            else if let s = try? container.decode(String.self) { value = s }
            else if let a = try? container.decode([AnyJSON].self) { value = a.map(\.value) }
            else { value = try container.decode([String: AnyJSON].self).mapValues(\.value) }
        }
    }

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-accounting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        tmpRoot = nil
    }

    private func loadFixtures() throws -> Fixtures {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // CLIPulseCoreTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/codex-accounting-cases.json")
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }

    private func encodedLines(_ file: File) throws -> [Data] {
        try file.lines.map { try JSONSerialization.data(withJSONObject: $0.value, options: [.sortedKeys]) }
    }

    private func url(for file: File, home: URL) -> URL {
        file.path.split(separator: "/").reduce(home) { $0.appendingPathComponent(String($1)) }
    }

    private func write(_ lines: ArraySlice<Data>, to url: URL, appending: Bool) throws {
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if appending, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    private func scan(home: URL, cache: URL, fixtures: Fixtures, force: Bool) throws -> [String: [String: [Int]]] {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [],
            cacheRoot: cache,
            daysToScan: fixtures.days_to_scan
        )
        options.forceRescan = force
        options.refreshMinIntervalSeconds = 0
        options.now = try XCTUnwrap(ISO8601DateFormatter().date(from: fixtures.now_utc))
        var out: [String: [String: [Int]]] = [:]
        for entry in CostUsageScanner.scan(options: options).entries where entry.provider == "Codex" {
            out[entry.date, default: [:]][entry.model] = [entry.inputTokens, entry.cachedTokens, entry.outputTokens]
        }
        return out
    }

    func test_every_case_full_scan_and_rescan() throws {
        let fixtures = try loadFixtures()
        XCTAssertGreaterThanOrEqual(fixtures.cases.count, 20)
        for testCase in fixtures.cases {
            let home = tmpRoot.appendingPathComponent("full-\(testCase.name)", isDirectory: true)
            let cache = tmpRoot.appendingPathComponent("cache-full-\(testCase.name)", isDirectory: true)
            for file in testCase.files {
                let lines = try encodedLines(file)
                try write(lines[...], to: url(for: file, home: home), appending: false)
            }
            let first = try scan(home: home, cache: cache, fixtures: fixtures, force: true)
            XCTAssertEqual(first, testCase.expected, "\(testCase.name): \(testCase.description)")
            let again = try scan(home: home, cache: cache, fixtures: fixtures, force: false)
            XCTAssertEqual(again, testCase.expected, "\(testCase.name) (rescan on the saved cache)")
        }
    }

    func test_every_case_incremental_scan() throws {
        let fixtures = try loadFixtures()
        for testCase in fixtures.cases {
            let home = tmpRoot.appendingPathComponent("inc-\(testCase.name)", isDirectory: true)
            let cache = tmpRoot.appendingPathComponent("cache-inc-\(testCase.name)", isDirectory: true)
            var rest: [(URL, ArraySlice<Data>)] = []
            for file in testCase.files {
                let lines = try encodedLines(file)
                let half = max(1, lines.count / 2)
                let target = url(for: file, home: home)
                try write(lines[..<half], to: target, appending: false)
                rest.append((target, lines[half...]))
            }
            _ = try scan(home: home, cache: cache, fixtures: fixtures, force: true)
            for (target, lines) in rest where !lines.isEmpty {
                try write(lines, to: target, appending: true)
            }
            let resumed = try scan(home: home, cache: cache, fixtures: fixtures, force: false)
            XCTAssertEqual(resumed, testCase.expected, "\(testCase.name) (resumed from a half-written file)")
        }
    }

    /// Opt-in: scan a real Codex home into a cache directory, so the replica can
    /// compare with the scanner on real logs before a build ships:
    ///
    ///     CLIPULSE_REAL_CODEX_HOME=~/.codex CLIPULSE_REAL_CODEX_CACHE=/some/dir \
    ///       swift test --filter CodexAccountingFixtureTests/test_scan_real_logs_when_asked
    ///     scripts/codex_accounting_replica.py --app-cache /some/dir/cost-usage/codex-v2.json
    ///
    /// Skipped unless both variables are set. It writes only to the given
    /// cache directory; the cache holds file paths, so keep it outside the repo.
    func test_scan_real_logs_when_asked() throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["CLIPULSE_REAL_CODEX_HOME"], let cacheDir = env["CLIPULSE_REAL_CODEX_CACHE"] else {
            throw XCTSkip("set CLIPULSE_REAL_CODEX_HOME and CLIPULSE_REAL_CODEX_CACHE to scan real logs")
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [],
            cacheRoot: URL(fileURLWithPath: cacheDir, isDirectory: true),
            daysToScan: 30
        )
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        let codex = CostUsageScanner.scan(options: options).entries.filter { $0.provider == "Codex" }
        XCTAssertFalse(codex.isEmpty, "no Codex usage found under \(home)")
    }

    /// Codex cost is summed request by request as the events are read, at the
    /// rates of each request's own time (slot 3 of the day row), not priced
    /// once from the day's totals.
    func test_cost_is_the_sum_of_each_requests_cost() throws {
        let fixtures = try loadFixtures()
        let testCase = try XCTUnwrap(fixtures.cases.first { $0.name == "parent_and_two_subagents" })
        let home = tmpRoot.appendingPathComponent("cost", isDirectory: true)
        for file in testCase.files {
            try write(try encodedLines(file)[...], to: url(for: file, home: home), appending: false)
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [],
            cacheRoot: tmpRoot.appendingPathComponent("cache-cost", isDirectory: true),
            daysToScan: fixtures.days_to_scan
        )
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        options.now = ISO8601DateFormatter().date(from: fixtures.now_utc)
        let entry = try XCTUnwrap(CostUsageScanner.scan(options: options).entries.first {
            $0.provider == "Codex" && $0.model == "gpt-5.5"
        })
        let requests = [(1000, 800, 50), (1500, 1200, 70), (1500, 1200, 80)]
        let expected = requests.compactMap {
            CostUsageScanner.Pricing.codexCostUSD(model: "gpt-5.5", inputTokens: $0.0, cachedInputTokens: $0.1, outputTokens: $0.2)
        }.reduce(0, +)
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), expected, accuracy: 1e-9)
    }
}

#endif

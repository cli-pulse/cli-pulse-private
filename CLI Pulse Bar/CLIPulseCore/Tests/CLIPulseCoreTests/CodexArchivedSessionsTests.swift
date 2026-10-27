import CryptoKit
import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// 1.59.1 (N1): the Codex sessions the Codex CLI archives as
/// `rollout-*.jsonl.zst`, deleting the `.jsonl`.
///
/// Until 1.59.1 the scanner listed `.jsonl` only, so an archived session's
/// usage vanished from This Mac, Projects, Sessions and the cloud. These
/// tests hold the scanner to four things:
///
/// * an archive counts exactly what its plain log counts (also every shared
///   accounting fixture with its logs archived:
///   `CodexAccountingFixtureTests.test_every_case_with_its_logs_archived`);
/// * a session whose log and archive are both there is read once, from the
///   log;
/// * a session archived after it was counted keeps its count, also when its
///   archive cannot be read;
/// * an archive that is corrupt or cut off is skipped, and nothing else is.
///
/// The fixture in `Fixtures/codex-archived/` was compressed by the zstd CLI
/// (v1.5.6, `zstd -19`, with a content checksum) from a synthetic rollout:
/// one session_meta, one turn_context, 1,500 token_count events of one
/// fresh counter on 2026-09-20 between 10:00 and 12:55 UTC, and two long
/// response lines (40 KB, over the 32 KB line limit, and 300 KB, over a
/// 256 KB read). Its decoded content is pinned by SHA-256 below.
final class CodexArchivedSessionsTests: XCTestCase {

    private var tmpRoot: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!

    static let fixtureName = "rollout-2026-09-20T10-00-00-a7c1e5d2-0000-4000-8000-0000000000a7.jsonl.zst"
    /// `zstd -dc <fixture> | shasum -a 256`
    static let fixtureContentSHA256 = "5ff37259828cc7d656e7f53604c7f9368121d80a7855d0965dc9e0af88acc8f7"
    static let fixtureContentBytes = 1_002_296
    /// The fixture's final cumulative [input, cached, output], which a fresh
    /// counter counts in full.
    static let fixtureTotals = [5_177_471, 2_629_767, 370_923]

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-archived-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        tmpRoot = nil
    }

    // MARK: - Helpers

    static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // CLIPulseCoreTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/codex-archived/\(fixtureName)")
    }

    private func readAll(_ url: URL) throws -> Data {
        let reader = try LogByteReader(fileURL: url)
        defer { reader.close() }
        var out = Data()
        while true {
            let chunk = try reader.read(upToCount: 100_000)
            if chunk.isEmpty { return out }
            out.append(chunk)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func dayFolder(_ home: URL, _ day: String) -> URL {
        day.split(separator: "-").reduce(home.appendingPathComponent("sessions", isDirectory: true)) {
            $0.appendingPathComponent(String($1), isDirectory: true)
        }
    }

    private func stamp(_ text: String) -> String { "2026-09-\(text)Z" }

    private func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A small rollout: a session_meta and `events` token counts of a fresh
    /// counter on 2026-09-`day`, 1,000 input / 100 output each.
    private func rollout(id: String, day: String, events: Int, cwd: String = "/work/app") -> Data {
        var lines = [
            json(["type": "session_meta", "timestamp": stamp("\(day)T10:00:00.000"),
                  "payload": ["id": id, "session_id": id, "cwd": cwd, "timestamp": stamp("\(day)T10:00:00.000")]]),
            json(["type": "turn_context", "timestamp": stamp("\(day)T10:00:01.000"), "payload": ["model": "gpt-5.5"]]),
        ]
        for i in 1...events {
            func usage(_ n: Int) -> [String: Int] { ["input_tokens": 1_000 * n, "cached_input_tokens": 0, "output_tokens": 100 * n] }
            lines.append(json([
                "type": "event_msg", "timestamp": stamp(String(format: "\(day)T10:%02d:00.000", i)),
                "payload": ["type": "token_count", "info": ["total_token_usage": usage(i), "last_token_usage": usage(1)]],
            ]))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func options(home: URL, cache: URL) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [], cacheRoot: cache, daysToScan: 30)
        options.refreshMinIntervalSeconds = 0
        options.now = now
        options.homeDirectory = "/work"
        return options
    }

    /// Codex [input, cached, output] by day and model.
    private func scan(home: URL, cache: URL) -> [String: [String: [Int]]] {
        var out: [String: [String: [Int]]] = [:]
        for entry in CostUsageScanner.scan(options: options(home: home, cache: cache)).entries where entry.provider == "Codex" {
            out[entry.date, default: [:]][entry.model] = [entry.inputTokens, entry.cachedTokens, entry.outputTokens]
        }
        return out
    }

    private func totals(_ rows: [String: [String: [Int]]]) -> [Int] {
        rows.values.flatMap(\.values).reduce([0, 0, 0]) { sum, row in zip(sum, row).map(+) }
    }

    /// The cached files' names (the temporary folder's path differs by
    /// `/private`, so names are compared).
    private func cachedNames(_ cache: URL) -> Set<String> {
        Set(CostUsageCacheIO.load(provider: "codex", cacheRoot: cache).files.keys.map { ($0 as NSString).lastPathComponent })
    }

    // MARK: - The decoder

    func test_the_cli_compressed_fixture_decodes_to_its_pinned_content() throws {
        let content = try readAll(Self.fixtureURL())
        XCTAssertEqual(content.count, Self.fixtureContentBytes)
        XCTAssertEqual(sha256(content), Self.fixtureContentSHA256)
    }

    func test_raw_frames_of_many_blocks_and_concatenated_frames_decode() throws {
        let content = Data((0..<30_000).map { "line \($0) of a log\n" }.joined().utf8)
        XCTAssertGreaterThan(content.count, 3 * 128 * 1024)
        let one = tmpRoot.appendingPathComponent("one.jsonl.zst")
        try ZstdTestFrames.write(content, to: one)
        XCTAssertEqual(try readAll(one), content)

        // Two frames back to back are one stream (zstd's own rule).
        let half = content.count / 2
        let two = tmpRoot.appendingPathComponent("two.jsonl.zst")
        try (ZstdTestFrames.raw(content.prefix(half)) + ZstdTestFrames.raw(content.dropFirst(half))).write(to: two)
        XCTAssertEqual(try readAll(two), content)

        let empty = tmpRoot.appendingPathComponent("empty.jsonl.zst")
        try ZstdTestFrames.write(Data(), to: empty)
        XCTAssertEqual(try readAll(empty), Data())
    }

    func test_a_cut_off_or_corrupt_archive_is_an_error_not_a_short_read() throws {
        let real = try Data(contentsOf: Self.fixtureURL())
        let cut = tmpRoot.appendingPathComponent("cut.jsonl.zst")
        try real.prefix(real.count / 2).write(to: cut)
        XCTAssertThrowsError(try readAll(cut))

        // Cut at a raw block boundary: every byte read decodes, the frame never ends.
        let rawCut = tmpRoot.appendingPathComponent("raw-cut.jsonl.zst")
        let frame = ZstdTestFrames.raw(Data(repeating: 0x41, count: 300_000))
        try frame.prefix(6 + 3 + 128 * 1024).write(to: rawCut)
        XCTAssertThrowsError(try readAll(rawCut)) { XCTAssertEqual($0 as? LogByteReader.Failure, .truncated) }

        var flipped = real
        for i in stride(from: 200, to: flipped.count - 200, by: 97) { flipped[i] ^= 0x5A }
        let corrupt = tmpRoot.appendingPathComponent("corrupt.jsonl.zst")
        try flipped.write(to: corrupt)
        XCTAssertThrowsError(try readAll(corrupt))

        let notZstd = tmpRoot.appendingPathComponent("plain-text.jsonl.zst")
        try Data("{\"type\":\"session_meta\"}\n".utf8).write(to: notZstd)
        XCTAssertThrowsError(try readAll(notZstd)) { XCTAssertEqual($0 as? LogByteReader.Failure, .corrupt) }

        let zeroBytes = tmpRoot.appendingPathComponent("zero.jsonl.zst")
        try Data().write(to: zeroBytes)
        XCTAssertThrowsError(try readAll(zeroBytes))
    }

    /// The window a frame may ask for is capped at 2^27 (128 MB), set on the
    /// decoder explicitly; a frame asking for 2^28 is refused before any
    /// memory is taken for it.
    func test_a_frame_asking_for_a_window_over_the_cap_is_refused() throws {
        XCTAssertEqual(LogByteReader.windowLogMax, 27)
        let content = Data("{\"type\":\"session_meta\"}\n".utf8)
        let atCap = tmpRoot.appendingPathComponent("window-27.jsonl.zst")
        try ZstdTestFrames.raw(content, windowLog: 27).write(to: atCap)
        XCTAssertEqual(try readAll(atCap), content)
        let overCap = tmpRoot.appendingPathComponent("window-28.jsonl.zst")
        try ZstdTestFrames.raw(content, windowLog: 28).write(to: overCap)
        XCTAssertThrowsError(try readAll(overCap)) { XCTAssertEqual($0 as? LogByteReader.Failure, .corrupt) }
    }

    func test_an_archive_that_decodes_past_the_limit_is_refused() throws {
        XCTAssertEqual(LogByteReader.defaultMaxDecodedBytes, 4 << 30)
        let url = tmpRoot.appendingPathComponent("long.jsonl.zst")
        try ZstdTestFrames.write(Data(repeating: 0x41, count: 300_000), to: url)
        func read(limit: Int64) throws -> Int {
            let reader = try LogByteReader(fileURL: url, maxDecodedBytes: limit)
            var total = 0
            while true {
                let chunk = try reader.read(upToCount: 64 * 1024)
                if chunk.isEmpty { return total }
                total += chunk.count
            }
        }
        XCTAssertEqual(try read(limit: 300_000), 300_000)
        XCTAssertThrowsError(try read(limit: 299_999)) { XCTAssertEqual($0 as? LogByteReader.Failure, .tooLarge) }
    }

    // MARK: - Counting

    /// The signature test of N1: an archive counts what its plain log counts.
    func test_an_archive_counts_exactly_what_its_plain_log_counts() throws {
        let content = try readAll(Self.fixtureURL())
        let plainName = String(Self.fixtureName.dropLast(".zst".count))

        let plainHome = tmpRoot.appendingPathComponent("plain", isDirectory: true)
        try write(content, to: dayFolder(plainHome, "2026-09-20").appendingPathComponent(plainName))
        let plain = scan(home: plainHome, cache: tmpRoot.appendingPathComponent("cache-plain"))

        let archivedHome = tmpRoot.appendingPathComponent("archived", isDirectory: true)
        let archive = dayFolder(archivedHome, "2026-09-20").appendingPathComponent(Self.fixtureName)
        try write(try Data(contentsOf: Self.fixtureURL()), to: archive)
        let archivedCache = tmpRoot.appendingPathComponent("cache-archived")
        let archived = scan(home: archivedHome, cache: archivedCache)

        XCTAssertEqual(totals(plain), Self.fixtureTotals)
        XCTAssertEqual(archived, plain)
        XCTAssertEqual(cachedNames(archivedCache), [Self.fixtureName])
        // Read again from the saved cache: the same, and not added twice.
        XCTAssertEqual(scan(home: archivedHome, cache: archivedCache), plain)
    }

    func test_projects_and_sessions_see_an_archived_session() throws {
        let home = tmpRoot.appendingPathComponent("split", isDirectory: true)
        try write(try Data(contentsOf: Self.fixtureURL()),
                  to: dayFolder(home, "2026-09-20").appendingPathComponent(Self.fixtureName))
        let result = CostUsageScanner.scan(options: options(home: home, cache: tmpRoot.appendingPathComponent("cache-split")))
        let tokens = Self.fixtureTotals[0] + Self.fixtureTotals[2]
        let projects = result.projects.filter { $0.provider == "Codex" }
        XCTAssertEqual(projects.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }, tokens)
        XCTAssertTrue(projects.allSatisfy { $0.project.name == "archived-app" }, "the project comes from the archive's first line")
        let sessions = result.sessions.filter { $0.provider == "Codex" }
        XCTAssertEqual(Set(sessions.map(\.session)).count, 1)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }, tokens)
    }

    func test_both_forms_present_are_read_once_from_the_plain_log() throws {
        let home = tmpRoot.appendingPathComponent("both", isDirectory: true)
        let folder = dayFolder(home, "2026-09-12")
        let data = rollout(id: "11111111-aaaa-4000-8000-000000000001", day: "12", events: 3)
        try write(data, to: folder.appendingPathComponent("rollout-a.jsonl"))
        try ZstdTestFrames.write(data, to: folder.appendingPathComponent("rollout-a.jsonl.zst"))
        let cache = tmpRoot.appendingPathComponent("cache-both")

        let rows = scan(home: home, cache: cache)
        XCTAssertEqual(totals(rows), [3_000, 0, 300])
        XCTAssertEqual(cachedNames(cache), ["rollout-a.jsonl"], "the archive is not decoded while its log is there")

        // An archive with no log beside it, in the same folder, is read.
        try ZstdTestFrames.write(rollout(id: "22222222-aaaa-4000-8000-000000000002", day: "12", events: 2),
                                 to: folder.appendingPathComponent("rollout-b.jsonl.zst"))
        XCTAssertEqual(totals(scan(home: home, cache: cache)), [5_000, 0, 500])
        XCTAssertEqual(cachedNames(cache), ["rollout-a.jsonl", "rollout-b.jsonl.zst"])
    }

    func test_a_session_archived_after_it_was_counted_keeps_its_count() throws {
        let home = tmpRoot.appendingPathComponent("switch", isDirectory: true)
        let folder = dayFolder(home, "2026-09-14")
        let data = rollout(id: "33333333-aaaa-4000-8000-000000000003", day: "14", events: 4)
        let plain = folder.appendingPathComponent("rollout-c.jsonl")
        try write(data, to: plain)
        let cache = tmpRoot.appendingPathComponent("cache-switch")
        let before = scan(home: home, cache: cache)
        XCTAssertEqual(totals(before), [4_000, 0, 400])

        // What Codex does: compress, then delete the log.
        try ZstdTestFrames.write(data, to: folder.appendingPathComponent("rollout-c.jsonl.zst"))
        XCTAssertEqual(scan(home: home, cache: cache), before, "both there: unchanged")
        try FileManager.default.removeItem(at: plain)
        XCTAssertEqual(scan(home: home, cache: cache), before, "archived: unchanged")
        XCTAssertEqual(cachedNames(cache), ["rollout-c.jsonl.zst"], "one entry, the archive's")
        XCTAssertEqual(scan(home: home, cache: cache), before, "and again from the saved cache")
    }

    func test_an_unreadable_archive_keeps_the_count_of_the_log_it_replaced() throws {
        let home = tmpRoot.appendingPathComponent("broken-switch", isDirectory: true)
        let folder = dayFolder(home, "2026-09-15")
        let plain = folder.appendingPathComponent("rollout-d.jsonl")
        try write(rollout(id: "44444444-aaaa-4000-8000-000000000004", day: "15", events: 2), to: plain)
        try write(rollout(id: "55555555-aaaa-4000-8000-000000000005", day: "15", events: 1),
                  to: folder.appendingPathComponent("rollout-e.jsonl"))
        let cache = tmpRoot.appendingPathComponent("cache-broken-switch")
        let before = scan(home: home, cache: cache)
        XCTAssertEqual(totals(before), [3_000, 0, 300])

        // The archive is cut off, and the log is gone.
        let frame = ZstdTestFrames.raw(try Data(contentsOf: plain))
        try frame.prefix(frame.count - 10).write(to: folder.appendingPathComponent("rollout-d.jsonl.zst"))
        try FileManager.default.removeItem(at: plain)
        XCTAssertEqual(scan(home: home, cache: cache), before, "the usage already counted stays")
        XCTAssertEqual(scan(home: home, cache: cache), before, "on every refresh")
        XCTAssertEqual(cachedNames(cache), ["rollout-d.jsonl", "rollout-e.jsonl"])
        XCTAssertEqual(unreadableNames(cache), ["rollout-d.jsonl.zst"], "and the archive is remembered as unreadable")
    }

    private func unreadableNames(_ cache: URL) -> Set<String> {
        Set((CostUsageCacheIO.load(provider: "codex", cacheRoot: cache).unreadableCodexArchives ?? [:]).keys
            .map { ($0 as NSString).lastPathComponent })
    }

    /// An archive that could not be decoded is not decoded again on every
    /// refresh, only once its size or modification date changes.
    func test_an_unreadable_archive_is_tried_again_only_when_it_changes() throws {
        let home = tmpRoot.appendingPathComponent("retry", isDirectory: true)
        let folder = dayFolder(home, "2026-09-17")
        let archive = folder.appendingPathComponent("rollout-i.jsonl.zst")
        var frame = ZstdTestFrames.raw(rollout(id: "99999999-aaaa-4000-8000-000000000009", day: "17", events: 2))
        // Block type 3 is reserved: the same bytes, one bit pair off, do not decode.
        let blockHeader = 6
        let good = frame[blockHeader]
        frame[blockHeader] = good | 0b110
        try write(frame, to: archive)
        let written = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as? Date)
        let cache = tmpRoot.appendingPathComponent("cache-retry")

        XCTAssertEqual(totals(scan(home: home, cache: cache)), [0, 0, 0])
        XCTAssertEqual(unreadableNames(cache), ["rollout-i.jsonl.zst"])

        // Repaired in place, same size and same date: not looked at again.
        frame[blockHeader] = good
        try frame.write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: archive.path)
        XCTAssertEqual(totals(scan(home: home, cache: cache)), [0, 0, 0], "an unchanged archive is not decoded again")

        // Its date changes: decoded, counted, and no longer remembered.
        try FileManager.default.setAttributes([.modificationDate: written.addingTimeInterval(60)], ofItemAtPath: archive.path)
        XCTAssertEqual(totals(scan(home: home, cache: cache)), [2_000, 0, 200])
        XCTAssertEqual(unreadableNames(cache), [])

        // Gone from the folder: nothing about it is kept.
        frame[blockHeader] = good | 0b110
        try frame.write(to: archive)
        XCTAssertEqual(totals(scan(home: home, cache: cache)), [0, 0, 0])
        try FileManager.default.removeItem(at: archive)
        XCTAssertEqual(totals(scan(home: home, cache: cache)), [0, 0, 0])
        XCTAssertEqual(unreadableNames(cache), [])
    }

    func test_a_corrupt_or_cut_off_archive_is_skipped_and_nothing_else_is() throws {
        let home = tmpRoot.appendingPathComponent("corrupt", isDirectory: true)
        let folder = dayFolder(home, "2026-09-16")
        try write(rollout(id: "66666666-aaaa-4000-8000-000000000006", day: "16", events: 2),
                  to: folder.appendingPathComponent("rollout-f.jsonl"))
        try ZstdTestFrames.write(rollout(id: "77777777-aaaa-4000-8000-000000000007", day: "16", events: 3),
                                 to: folder.appendingPathComponent("rollout-g.jsonl.zst"))
        let real = try Data(contentsOf: Self.fixtureURL())
        try real.prefix(real.count / 3).write(to: folder.appendingPathComponent("rollout-cut.jsonl.zst"))
        var flipped = real
        for i in stride(from: 300, to: flipped.count - 300, by: 61) { flipped[i] ^= 0xA5 }
        try flipped.write(to: folder.appendingPathComponent("rollout-flipped.jsonl.zst"))
        try Data("not zstd at all\n".utf8).write(to: folder.appendingPathComponent("rollout-text.jsonl.zst"))
        try Data().write(to: folder.appendingPathComponent("rollout-empty.jsonl.zst"))
        let cache = tmpRoot.appendingPathComponent("cache-corrupt")

        XCTAssertEqual(totals(scan(home: home, cache: cache)), [5_000, 0, 500])
        XCTAssertEqual(cachedNames(cache), ["rollout-f.jsonl", "rollout-g.jsonl.zst"])
    }

    func test_a_fresh_archive_is_a_live_session_candidate_with_its_own_id() throws {
        let home = tmpRoot.appendingPathComponent("live", isDirectory: true)
        let id = "88888888-aaaa-4000-8000-000000000008"
        let archive = dayFolder(home, "2026-09-30").appendingPathComponent("rollout-h.jsonl.zst")
        try ZstdTestFrames.write(rollout(id: id, day: "30", events: 1, cwd: "/work/live-app"), to: archive)
        var options = options(home: home, cache: tmpRoot.appendingPathComponent("cache-live"))
        options.now = Date()
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: archive.path)
        let candidates = CostUsageScanner.scan(options: options).activeSessionCandidates.filter { $0.provider == "Codex" }
        XCTAssertEqual(candidates.map(\.sessionId), [id])
        XCTAssertEqual(candidates.map(\.projectName), ["live-app"])
    }

    // MARK: - Listing

    func test_codex_logs_lists_archives_and_prefers_the_plain_log() {
        let folder = URL(fileURLWithPath: "/x/2026/09/20", isDirectory: true)
        let names = [
            "rollout-a.jsonl", "rollout-a.jsonl.zst",   // both: the log
            "rollout-b.jsonl.zst",                      // archive only
            "rollout-c.JSONL.ZST",                      // any case
            "rollout-g.JSONL", "rollout-g.jsonl.zst",   // a twin in another case is still a twin
            "rollout-d.zst", "rollout-e.json.zst",      // not a JSONL archive
            "rollout-f.jsonl.gz", "notes.txt",
        ]
        let listed = CostUsageScanner.codexLogs(in: names.map { folder.appendingPathComponent($0) })
            .map(\.lastPathComponent)
        XCTAssertEqual(Set(listed), ["rollout-a.jsonl", "rollout-b.jsonl.zst", "rollout-c.JSONL.ZST", "rollout-g.JSONL"])
    }
}

#endif

import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// The rules in `CostUsageAccountingRules`, and the cache state that carries a
/// Claude log's counted responses from one scan to the next
/// (`CostUsageClaudeLogState`). The end-to-end fixtures are in
/// `CostUsageScannerAccountingTests`.
final class CostUsageAccountingRulesTests: XCTestCase {

    private typealias Rules = CostUsageAccountingRules

    // MARK: - claudeResponseKey

    func test_aRequestIdIdentifiesTheResponseWhateverTheSession() {
        XCTAssertEqual(
            Rules.claudeResponseKey(messageId: "msg", requestId: "req", sessionId: "a"),
            Rules.claudeResponseKey(messageId: "msg", requestId: "req", sessionId: "b")
        )
        XCTAssertNotNil(Rules.claudeResponseKey(messageId: "msg", requestId: "req", sessionId: nil))
    }

    func test_withoutARequestIdTheSessionAndMessageIdentifyTheResponse() {
        XCTAssertEqual(
            Rules.claudeResponseKey(messageId: "msg", requestId: nil, sessionId: "s"),
            Rules.claudeResponseKey(messageId: "msg", requestId: nil, sessionId: "s")
        )
        XCTAssertNotEqual(
            Rules.claudeResponseKey(messageId: "msg", requestId: nil, sessionId: "s1"),
            Rules.claudeResponseKey(messageId: "msg", requestId: nil, sessionId: "s2")
        )
    }

    func test_noKeyWithoutAUsableIdentity() {
        XCTAssertNil(Rules.claudeResponseKey(messageId: nil, requestId: "req", sessionId: "s"))
        XCTAssertNil(Rules.claudeResponseKey(messageId: "msg", requestId: nil, sessionId: nil))
        XCTAssertNil(Rules.claudeResponseKey(messageId: "msg", requestId: nil, sessionId: ""))
        XCTAssertNil(Rules.claudeResponseKey(messageId: "msg", requestId: nil, sessionId: " \n\t"))
        XCTAssertNil(Rules.claudeResponseKey(messageId: "", requestId: nil, sessionId: "s"))
        XCTAssertNil(Rules.claudeResponseKey(messageId: " ", requestId: nil, sessionId: "s"))
    }

    /// Two different identities never produce one key, even when the
    /// identifiers contain the characters a naive join would use.
    func test_differentIdentitiesNeverShareAKey() {
        let keys: [String?] = [
            Rules.claudeResponseKey(messageId: "response:a", requestId: "request", sessionId: nil),
            Rules.claudeResponseKey(messageId: "response", requestId: "a:request", sessionId: nil),
            Rules.claudeResponseKey(messageId: "a", requestId: "bc", sessionId: nil),
            Rules.claudeResponseKey(messageId: "ab", requestId: "c", sessionId: nil),
            Rules.claudeResponseKey(messageId: "1", requestId: "0:x", sessionId: nil),
            Rules.claudeResponseKey(messageId: "10", requestId: ":x", sessionId: nil),
            Rules.claudeResponseKey(messageId: "response", requestId: nil, sessionId: "session:a"),
            Rules.claudeResponseKey(messageId: "a:response", requestId: nil, sessionId: "session"),
            // The same two strings as a request identity and as a session one.
            Rules.claudeResponseKey(messageId: "x", requestId: "y", sessionId: nil),
            Rules.claudeResponseKey(messageId: "y", requestId: nil, sessionId: "x"),
        ]
        XCTAssertEqual(keys.compactMap { $0 }.count, keys.count)
        XCTAssertEqual(Set(keys.compactMap { $0 }).count, keys.count)
    }

    // MARK: - claudeSessionId

    /// Claude Code writes `sessionId` on the line; proxies and other writers
    /// use `session_id` or a `metadata` object. The line's own field wins.
    func test_theSessionIdIsReadWhereverAWriterPutsIt() {
        XCTAssertEqual(Rules.claudeSessionId(line: ["sessionId": "a", "session_id": "b"], message: [:]), "a")
        XCTAssertEqual(Rules.claudeSessionId(line: ["session_id": "b"], message: [:]), "b")
        XCTAssertEqual(Rules.claudeSessionId(line: ["metadata": ["sessionId": "c"]], message: [:]), "c")
        XCTAssertEqual(Rules.claudeSessionId(line: [:], message: ["metadata": ["sessionId": "d"]]), "d")
        XCTAssertEqual(
            Rules.claudeSessionId(line: ["session_id": "b", "metadata": ["sessionId": "c"]], message: ["metadata": ["sessionId": "d"]]),
            "b"
        )
        XCTAssertNil(Rules.claudeSessionId(line: ["sessionId": 7], message: [:]))
        XCTAssertNil(Rules.claudeSessionId(line: [:], message: [:]))
    }

    // MARK: - isPreliminaryClaudeProxyUsage

    func test_onlyAProxysPreliminaryShapeIsPreliminary() {
        let null: [String: Any] = ["stop_reason": NSNull()]
        let bare: [String: Int] = ["input_tokens": 1612, "output_tokens": 0]
        XCTAssertTrue(Rules.isPreliminaryClaudeProxyUsage(message: null, usage: bare, input: 1612, output: 0))

        // No stop_reason key at all: an older complete log.
        XCTAssertFalse(Rules.isPreliminaryClaudeProxyUsage(message: [:], usage: bare, input: 1612, output: 0))
        // A finished response.
        XCTAssertFalse(Rules.isPreliminaryClaudeProxyUsage(message: ["stop_reason": "end_turn"], usage: bare, input: 1612, output: 0))
        // Output already counted.
        XCTAssertFalse(Rules.isPreliminaryClaudeProxyUsage(message: null, usage: bare, input: 1612, output: 3))
        // No input to estimate.
        XCTAssertFalse(Rules.isPreliminaryClaudeProxyUsage(message: null, usage: bare, input: 0, output: 0))
        // Claude Code's own lines carry the cache fields, even at zero.
        XCTAssertFalse(Rules.isPreliminaryClaudeProxyUsage(
            message: null, usage: ["input_tokens": 5, "cache_read_input_tokens": 0], input: 5, output: 0))
        XCTAssertFalse(Rules.isPreliminaryClaudeProxyUsage(
            message: null, usage: ["input_tokens": 5, "cache_creation_input_tokens": 0], input: 5, output: 0))
    }

    // MARK: - claudeLineReplaces

    func test_aLaterLineReplacesExceptAnEstimateOverRealUsage() {
        XCTAssertTrue(Rules.claudeLineReplaces(existingIsIncomplete: nil, lineIsIncomplete: false))
        XCTAssertTrue(Rules.claudeLineReplaces(existingIsIncomplete: nil, lineIsIncomplete: true))
        XCTAssertTrue(Rules.claudeLineReplaces(existingIsIncomplete: false, lineIsIncomplete: false))
        XCTAssertTrue(Rules.claudeLineReplaces(existingIsIncomplete: true, lineIsIncomplete: false))
        XCTAssertTrue(Rules.claudeLineReplaces(existingIsIncomplete: true, lineIsIncomplete: true))
        XCTAssertFalse(Rules.claudeLineReplaces(existingIsIncomplete: false, lineIsIncomplete: true))
    }

    // MARK: - CostUsageClaudeLogState

    /// The hash is stored in the cache and compared with one computed by a
    /// later launch, so it must never change without a cache rules bump.
    /// These are FNV-1a 64's published test vectors.
    func test_theStableHashIsFNV1a64() {
        XCTAssertEqual(CostUsageClaudeLogState.stableHash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(CostUsageClaudeLogState.stableHash("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(CostUsageClaudeLogState.stableHash("foobar"), 0x8594_4171_f739_67e8)
    }

    func test_theCountedResponsesRoundTrip() {
        let map: [UInt64: UInt64] = [0: 1, 42: .max, .max: 7, 0x0102_0304_0506_0708: 0x1112_1314_1516_1718]
        let packed = CostUsageClaudeLogState.packCounted(map)
        XCTAssertEqual(packed.count, map.count * 16)
        XCTAssertEqual(CostUsageClaudeLogState(counted: packed).countedFingerprints(), map)
        // Little-endian, sorted by key: the first record is key 0, value 1.
        XCTAssertEqual([UInt8](packed.prefix(16)), [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(CostUsageClaudeLogState().countedFingerprints().isEmpty)
        // A damaged blob reads as nothing counted, never as wrong entries.
        XCTAssertTrue(CostUsageClaudeLogState(counted: packed.dropLast()).countedFingerprints().isEmpty)
    }

    /// Two lines of a response are the same line again when they add the same
    /// tokens to the same day and model. The cost is left out: it follows from
    /// the model and the tokens.
    func test_aFingerprintCoversWhatALineAddsButNotItsCost() {
        let row = CostUsageClaudeOpenRow(key: "k", day: "2026-09-30", model: "m", packed: [1, 2, 3, 4, 5], incomplete: false)
        var sameButCost = row
        sameButCost.packed[4] = 99
        XCTAssertEqual(row.fingerprint, sameButCost.fingerprint)
        var otherKey = row
        otherKey.key = "other"
        XCTAssertEqual(row.fingerprint, otherKey.fingerprint, "the key is stored beside it")

        var changes: [CostUsageClaudeOpenRow] = []
        for slot in 0..<4 {
            var changed = row
            changed.packed[slot] += 1
            changes.append(changed)
        }
        var otherDay = row
        otherDay.day = "2026-10-01"
        var otherModel = row
        otherModel.model = "n"
        var estimate = row
        estimate.incomplete = true
        changes += [otherDay, otherModel, estimate]
        for changed in changes {
            XCTAssertNotEqual(row.fingerprint, changed.fingerprint, "\(changed)")
        }
    }

    // MARK: - Cache: rules version

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-accounting-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A Claude cache written before these rules holds responses counted from
    /// their first line, some of them twice. It is rebuilt once; a cache
    /// written under the current rules loads.
    func test_aClaudeCacheFromBeforeTheseRulesIsRebuilt() throws {
        let url = CostUsageCacheIO.cacheFileURL(provider: "claude", cacheRoot: tempDir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write(_ version: Int) throws {
            let payload: [String: Any] = [
                "version": 1,
                "pricingVersion": version,
                "lastScanUnixMs": 1_700_000_000,
                "files": [String: Any](),
                "days": ["2026-09-20": ["m": [1, 2, 3, 4, 5, 6]]],
            ]
            try JSONSerialization.data(withJSONObject: payload).write(to: url)
        }
        // 4: the last version the Claude and Codex caches shared. 5: the
        // Codex cache's own, which a Claude cache never carries.
        for stale in [4, 5] {
            try write(stale)
            let loaded = CostUsageCacheIO.load(provider: "claude", cacheRoot: tempDir)
            XCTAssertEqual(loaded.lastScanUnixMs, 0, "version \(stale)")
            XCTAssertTrue(loaded.days.isEmpty)
        }
        // Positive control.
        try write(CostUsageCacheRules.version(forProvider: "claude"))
        XCTAssertEqual(CostUsageCacheIO.load(provider: "claude", cacheRoot: tempDir).lastScanUnixMs, 1_700_000_000)
        XCTAssertNotEqual(
            CostUsageCacheRules.version(forProvider: "claude"),
            CostUsageCacheRules.version(forProvider: "codex"),
            "each number names one set of rules"
        )
    }

    // MARK: - Cache: the state of a log being written

    private func claudeLog(_ lines: [String], in project: URL, name: String) throws -> URL {
        let url = project.appendingPathComponent("\(name).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func responseLine(_ index: Int, output: Int) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"req-\#(index)","sessionId":"s","message":{"id":"msg-\#(index)","model":"claude-sonnet-4-5","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}}}"#
    }

    private func userLine() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return #"{"type":"user","timestamp":"\#(stamp)","sessionId":"s","message":{"role":"user","content":"ok"}}"#
    }

    /// The cache entry of the one log a test writes. (The scanner keys it by
    /// the enumerated path, which can be `/private/var/…` for `/var/…`.)
    private func onlyClaudeEntry(_ cacheRoot: URL) throws -> (path: String, usage: CostUsageFileUsage) {
        let files = CostUsageCacheIO.load(provider: "claude", cacheRoot: cacheRoot).files
        XCTAssertEqual(files.count, 1)
        let entry = try XCTUnwrap(files.first)
        return (entry.key, entry.value)
    }

    private func openOutputs(_ cacheRoot: URL) throws -> [Int] {
        try XCTUnwrap(onlyClaudeEntry(cacheRoot).usage.claude).openRows.map { $0.packed[3] }
    }

    private func scanClaude(root: URL, cacheRoot: URL) -> Int {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: tempDir.appendingPathComponent("no-codex", isDirectory: true),
            claudeProjectsRoots: [root],
            cacheRoot: cacheRoot
        )
        options.refreshMinIntervalSeconds = 0
        return CostUsageScanner.scan(options: options).entries
            .filter { $0.provider == "Claude" }
            .reduce(0) { $0 + $1.outputTokens }
    }

    private func projectRoot() throws -> (root: URL, project: URL, cacheRoot: URL) {
        let root = tempDir.appendingPathComponent("projects", isDirectory: true)
        let project = root.appendingPathComponent("-Users-alice-p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, project, tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    /// A log written just now keeps its newest responses (at most the limit,
    /// newest first) and a record of every response it counted. Once it has
    /// been idle for longer than a response takes to write, the next scan
    /// drops both and the totals do not move.
    func test_aLogKeepsItsStateWhileWrittenAndDropsItOnceIdle() throws {
        let (root, project, cacheRoot) = try projectRoot()
        let log = try claudeLog((1...6).map { responseLine($0, output: 10 * $0) }, in: project, name: "active")

        XCTAssertEqual(scanClaude(root: root, cacheRoot: cacheRoot), 210)
        let state = try XCTUnwrap(onlyClaudeEntry(cacheRoot).usage.claude)
        XCTAssertEqual(state.openRows.count, CostUsageScanner.claudeOpenRowLimit)
        XCTAssertEqual(state.openRows.map { $0.packed[3] }, [60, 50, 40, 30])
        XCTAssertEqual(state.countedFingerprints().count, 6)

        let idle = Date().addingTimeInterval(-(CostUsageScanner.claudeLogStateIdleSeconds + 60))
        try FileManager.default.setAttributes([.modificationDate: idle], ofItemAtPath: log.path)
        // A changed mtime alone (same size) is a full re-read, which must also
        // leave no state for an idle log.
        XCTAssertEqual(scanClaude(root: root, cacheRoot: cacheRoot), 210)
        XCTAssertNil(try onlyClaudeEntry(cacheRoot).usage.claude)
    }

    /// The same, when the idle log is unchanged since the scan that stored
    /// its state (the fast path that does not read the log).
    func test_anUnchangedLogDropsItsStateOnceIdle() throws {
        let (root, project, cacheRoot) = try projectRoot()
        let log = try claudeLog([responseLine(1, output: 10)], in: project, name: "quiet")

        XCTAssertEqual(scanClaude(root: root, cacheRoot: cacheRoot), 10)
        let stored = try onlyClaudeEntry(cacheRoot)
        XCTAssertNotNil(stored.usage.claude)

        // Make the stored entry match the log's (backdated) mtime, as if the
        // earlier scan had run while the log was fresh.
        let idle = Date().addingTimeInterval(-(CostUsageScanner.claudeLogStateIdleSeconds + 60))
        try FileManager.default.setAttributes([.modificationDate: idle], ofItemAtPath: log.path)
        // Read the mtime the way the scanner does, from a fresh URL.
        let modified = try XCTUnwrap(URL(fileURLWithPath: log.path)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var cache = CostUsageCacheIO.load(provider: "claude", cacheRoot: cacheRoot)
        cache.files[stored.path]?.mtimeUnixMs = Int64(modified.timeIntervalSince1970 * 1000)
        CostUsageCacheIO.save(provider: "claude", cache: cache, cacheRoot: cacheRoot)

        XCTAssertEqual(scanClaude(root: root, cacheRoot: cacheRoot), 10)
        let after = try onlyClaudeEntry(cacheRoot)
        XCTAssertNil(after.usage.claude)
        // Nothing was re-read: the entry is the stored one, state aside.
        XCTAssertEqual(after.usage.mtimeUnixMs, Int64(modified.timeIntervalSince1970 * 1000))
        XCTAssertEqual(after.usage.days, stored.usage.days)
    }

    /// The responses carried from one scan keep their order in the next: the
    /// newest carried one outranks the older ones, below whatever the new
    /// scan reads. Carried in reverse, the newest carried response would be
    /// the first to drop out when a new one arrives.
    func test_carriedResponsesKeepTheirOrderAcrossScans() throws {
        let (root, project, cacheRoot) = try projectRoot()
        let log = try claudeLog((1...5).map { responseLine($0, output: 10 * $0) }, in: project, name: "busy")

        XCTAssertEqual(scanClaude(root: root, cacheRoot: cacheRoot), 150)
        XCTAssertEqual(try openOutputs(cacheRoot), [50, 40, 30, 20])

        // A new response: it goes first, and the oldest carried one drops out.
        try append([responseLine(6, output: 60)], to: log)
        XCTAssertEqual(scanClaude(root: root, cacheRoot: cacheRoot), 210)
        XCTAssertEqual(try openOutputs(cacheRoot), [60, 50, 40, 30])

        // A scan that reads no response leaves the order as it was.
        try append([userLine()], to: log)
        XCTAssertEqual(scanClaude(root: root, cacheRoot: cacheRoot), 210)
        XCTAssertEqual(try openOutputs(cacheRoot), [60, 50, 40, 30])
        try append([userLine()], to: log)
        XCTAssertEqual(scanClaude(root: root, cacheRoot: cacheRoot), 210)
        XCTAssertEqual(try openOutputs(cacheRoot), [60, 50, 40, 30])
    }
}

#endif

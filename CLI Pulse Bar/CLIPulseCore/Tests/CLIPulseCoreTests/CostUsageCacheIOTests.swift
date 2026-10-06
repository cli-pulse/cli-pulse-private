import XCTest
@testable import CLIPulseCore

#if os(macOS)

final class CostUsageCacheIOTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostUsageCacheIOTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - CostUsageCache defaults

    func testDefaultCacheVersionIsOne() {
        let cache = CostUsageCache()
        XCTAssertEqual(cache.version, 1)
    }

    func testDefaultCacheLastScanIsZero() {
        let cache = CostUsageCache()
        XCTAssertEqual(cache.lastScanUnixMs, 0)
    }

    func testDefaultCacheFilesAndDaysEmpty() {
        let cache = CostUsageCache()
        XCTAssertTrue(cache.files.isEmpty)
        XCTAssertTrue(cache.days.isEmpty)
    }

    // MARK: - cacheFileURL

    func testCacheFileURLContainsCostUsageSubdirectory() {
        let url = CostUsageCacheIO.cacheFileURL(provider: "Claude", cacheRoot: tempDir)
        XCTAssertTrue(url.path.contains("cost-usage"), "URL should be inside cost-usage/")
    }

    func testCacheFileURLLowercasesProviderName() {
        let url = CostUsageCacheIO.cacheFileURL(provider: "Claude", cacheRoot: tempDir)
        XCTAssertEqual(url.lastPathComponent, "claude-v2.json")
    }

    func testCacheFileURLUsesCustomCacheRoot() {
        let url = CostUsageCacheIO.cacheFileURL(provider: "codex", cacheRoot: tempDir)
        XCTAssertTrue(url.path.hasPrefix(tempDir.path))
    }

    func testCacheFileURLDifferentProvidersGetDifferentFiles() {
        let urlA = CostUsageCacheIO.cacheFileURL(provider: "claude", cacheRoot: tempDir)
        let urlB = CostUsageCacheIO.cacheFileURL(provider: "codex", cacheRoot: tempDir)
        XCTAssertNotEqual(urlA, urlB)
    }

    // MARK: - load: missing file

    func testLoadMissingFileReturnsDefault() {
        let cache = CostUsageCacheIO.load(provider: "claude", cacheRoot: tempDir)
        XCTAssertEqual(cache.version, 1)
        XCTAssertTrue(cache.files.isEmpty)
        XCTAssertTrue(cache.days.isEmpty)
    }

    // MARK: - save + load roundtrip

    func testSaveThenLoadRoundtrip() {
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 1_700_000_000
        cache.days = ["2026-04-20": ["gpt-4o": [100, 50, 200]]]
        cache.files = [
            "/path/to/file": CostUsageFileUsage(
                mtimeUnixMs: 999, size: 1024, days: [:],
                parsedBytes: 512, lastModel: "gpt-4o",
                lastTotals: CostUsageCodexTotals(input: 100, cached: 50, output: 200),
                sessionId: "abc"
            )
        ]
        CostUsageCacheIO.save(provider: "codex", cache: cache, cacheRoot: tempDir)
        let loaded = CostUsageCacheIO.load(provider: "codex", cacheRoot: tempDir)

        XCTAssertEqual(loaded.version, 1)
        XCTAssertEqual(loaded.lastScanUnixMs, 1_700_000_000)
        XCTAssertEqual(loaded.days["2026-04-20"]?["gpt-4o"], [100, 50, 200])
        let fu = loaded.files["/path/to/file"]
        XCTAssertNotNil(fu)
        XCTAssertEqual(fu?.mtimeUnixMs, 999)
        XCTAssertEqual(fu?.size, 1024)
        XCTAssertEqual(fu?.lastModel, "gpt-4o")
        XCTAssertEqual(fu?.lastTotals?.input, 100)
        XCTAssertEqual(fu?.lastTotals?.cached, 50)
        XCTAssertEqual(fu?.lastTotals?.output, 200)
        XCTAssertEqual(fu?.sessionId, "abc")
    }

    func testSaveThenLoadPreservesNilOptionals() {
        var cache = CostUsageCache()
        cache.files = [
            "/path": CostUsageFileUsage(
                mtimeUnixMs: 1, size: 1, days: [:],
                parsedBytes: nil, lastModel: nil, lastTotals: nil, sessionId: nil
            )
        ]
        CostUsageCacheIO.save(provider: "claude", cache: cache, cacheRoot: tempDir)
        let loaded = CostUsageCacheIO.load(provider: "claude", cacheRoot: tempDir)
        let fu = loaded.files["/path"]
        XCTAssertNil(fu?.parsedBytes)
        XCTAssertNil(fu?.lastModel)
        XCTAssertNil(fu?.lastTotals)
        XCTAssertNil(fu?.sessionId)
    }

    // MARK: - load: invalid data

    func testLoadCorruptedJSONReturnsDefault() {
        let url = CostUsageCacheIO.cacheFileURL(provider: "gemini", cacheRoot: tempDir)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "not-valid-json".data(using: .utf8)!.write(to: url)

        let cache = CostUsageCacheIO.load(provider: "gemini", cacheRoot: tempDir)
        XCTAssertEqual(cache.version, 1)
        XCTAssertTrue(cache.files.isEmpty)
    }

    func testLoadWrongVersionReturnsDefault() {
        var cache = CostUsageCache()
        cache.version = 99
        CostUsageCacheIO.save(provider: "ollama", cache: cache, cacheRoot: tempDir)

        let url = CostUsageCacheIO.cacheFileURL(provider: "ollama", cacheRoot: tempDir)
        guard var data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Could not read saved cache"); return
        }
        json["version"] = 99
        data = (try? JSONSerialization.data(withJSONObject: json)) ?? data
        try? data.write(to: url)

        let loaded = CostUsageCacheIO.load(provider: "ollama", cacheRoot: tempDir)
        XCTAssertEqual(loaded.version, 1)
        XCTAssertTrue(loaded.files.isEmpty)
    }

    // MARK: - pricing version invalidation (May 2026)

    func testLoadStalePricingVersionReturnsDefaultEvenWhenStructureVersionMatches() {
        // Forge an on-disk cache with a real `version: 1` (current
        // structure version) but `pricingVersion: 1` — i.e. one
        // generation behind whatever this build was compiled with.
        // load() must reject it so the next scan re-parses every
        // JSONL with the current pricing rules.
        let url = CostUsageCacheIO.cacheFileURL(provider: "claude", cacheRoot: tempDir)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "version": 1,
            "pricingVersion": 2,        // <-- one behind costUsageCachePricingVersion (=3)
            "lastScanUnixMs": 1_700_000_000,
            "files": [:],
            "days": [
                "2026-04-20": ["claude-opus-4-7": [0, 1_000_000, 0, 1_000, 0, 1] as [Int]]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [])
        try! data.write(to: url)

        let loaded = CostUsageCacheIO.load(provider: "claude", cacheRoot: tempDir)
        XCTAssertEqual(loaded.lastScanUnixMs, 0, "stale pricingVersion must wipe to default")
        XCTAssertTrue(loaded.days.isEmpty, "stale pricingVersion must wipe day buckets")
    }

    func testSaveStampsPricingVersionEvenWhenCallerOmitsIt() {
        // The dataclass default for pricingVersion is 0 (so legacy
        // on-disk files without the field invalidate themselves).
        // save() must overwrite that with the build-time current
        // value, otherwise a freshly-saved cache would look stale
        // on its very next load.
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 42
        // Note: deliberately leave cache.pricingVersion at 0.
        XCTAssertEqual(cache.pricingVersion, 0)
        CostUsageCacheIO.save(provider: "codex", cache: cache, cacheRoot: tempDir)

        let url = CostUsageCacheIO.cacheFileURL(provider: "codex", cacheRoot: tempDir)
        let raw = try! JSONSerialization.jsonObject(with: try! Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(raw["pricingVersion"] as? Int, costUsageCodexCacheRulesVersion)

        let loaded = CostUsageCacheIO.load(provider: "codex", cacheRoot: tempDir)
        XCTAssertEqual(loaded.lastScanUnixMs, 42, "save→load roundtrip should not be invalidated by the stamping policy")
    }

    func testCurrentPricingVersionIsSeven() {
        // Pin the constant so future bumps land in this test as a
        // grep-able diff. When you change pricing, bump the constant
        // AND this expectation in the same commit so the diff makes
        // the cache-invalidation intent obvious in code review.
        //
        // 4 — v1.50, Claude 5 generation priced. Every cache written under 3
        // holds costNanos=0 for claude-opus-5 / claude-fable-5 /
        // claude-sonnet-5 / gpt-5.6-*, so without the bump the fix would apply
        // only to logs written from here on and every historical day would keep
        // reading $0. This pairing is exactly what the pin is for.
        // 6 — 1.56, Claude responses counted once from their last line (5 is
        // the Codex cache's own). A Claude cache written under 4 counted each
        // response from its first line, some of them twice.
        // 7 — 1.56, Claude prices from `ClaudePricingTable` (Opus 5.5, Fable
        // 5.1 and Sonnet 5.5 rows, Sonnet 5 at $2 / $10, 1-hour cache writes,
        // the long-context tier per request and dated). A cache written under
        // 6 holds each response's cost at the old table.
        XCTAssertEqual(costUsageCachePricingVersion, 7)
    }

    // MARK: - rules version per provider (1.56)

    /// Writes a cache file for `provider` stamped with `version`, bypassing
    /// `save()` (which always stamps the current one).
    private func writeRawCache(provider: String, version: Int) {
        let url = CostUsageCacheIO.cacheFileURL(provider: provider, cacheRoot: tempDir)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "version": 1, "pricingVersion": version, "lastScanUnixMs": 1_700_000_000,
            "files": [:], "days": ["2026-09-20": ["m": [1, 0, 0, 0] as [Int]]],
        ]
        try! JSONSerialization.data(withJSONObject: payload).write(to: url)
    }

    func testCurrentCodexRulesVersionIsEight() {
        // 5 — 1.56: Codex files count on their own (subagents included), a file
        // of one thread is a copy when its events lie within another's (nested
        // spans), the cumulative baseline only rises, a child's copied history
        // is not counted, and each request is priced as it is read. A Codex
        // cache written under 4 holds none of that.
        // 8 — 1.56 (P0-1b): a subagent without a history ordinal is classified
        // whole, and a child's opening repeats and copied snapshots are not
        // usage. 6 and 7 are the Claude cache's. Pinned for the same reason as
        // the Claude version: a bump should be a visible diff.
        XCTAssertEqual(costUsageCodexCacheRulesVersion, 8)
        XCTAssertEqual(CostUsageCacheRules.version(forProvider: "codex"), 8)
        XCTAssertEqual(CostUsageCacheRules.version(forProvider: "Codex"), 8)
        XCTAssertEqual(CostUsageCacheRules.version(forProvider: "claude"), costUsageCachePricingVersion)
    }

    func testCodexCacheFromTheOldRulesIsReadAgainButClaudesIsKept() {
        // The whole point of splitting the version: a Codex rules change
        // re-reads the Codex logs (a hundred-odd files) and leaves a current
        // Claude cache (thousands of files) alone. 4 is the last version the
        // two caches shared.
        writeRawCache(provider: "codex", version: 4)
        writeRawCache(provider: "claude", version: costUsageCachePricingVersion)
        XCTAssertTrue(CostUsageCacheIO.load(provider: "codex", cacheRoot: tempDir).days.isEmpty)
        XCTAssertFalse(CostUsageCacheIO.load(provider: "claude", cacheRoot: tempDir).days.isEmpty)
    }

    func testClaudeCacheStampedWithTheCodexVersionIsRejected() {
        writeRawCache(provider: "claude", version: costUsageCodexCacheRulesVersion)
        XCTAssertTrue(CostUsageCacheIO.load(provider: "claude", cacheRoot: tempDir).days.isEmpty)
    }

    func testCodexFileStateRoundTripsAndIsNilInOlderEntries() throws {
        var cache = CostUsageCache()
        var state = CostUsageCodexFileState()
        state.rolloutId = "r"
        state.isChild = true
        state.metaUnixMs = 5
        state.historyStartOrdinal = 12
        state.copiedPrefix = .interAgentMessage
        state.sawMeta = true
        state.baselineChecked = true
        state.eventCount = 3
        state.firstEventUnixMs = 6
        state.lastEventUnixMs = 9
        // Rules 4 and 5 of `CodexTokenAccountant`: a resumed read needs them
        // back exactly (see CodexSubagentForkRulesTests'
        // test_a_resumed_child_keeps_the_counter_its_copied_events_left).
        state.isSubagent = true
        state.namesForkParent = true
        state.inheritedReference = CostUsageCodexTotals(input: 5000, cached: 4000, output: 300)
        state.openingSettled = true
        cache.files["/a"] = CostUsageFileUsage(
            mtimeUnixMs: 1, size: 1, days: [:], parsedBytes: 1, lastModel: nil,
            lastTotals: nil, sessionId: "s", codex: state
        )
        cache.files["/b"] = CostUsageFileUsage(
            mtimeUnixMs: 1, size: 1, days: [:], parsedBytes: 1, lastModel: nil, lastTotals: nil, sessionId: nil
        )
        CostUsageCacheIO.save(provider: "codex", cache: cache, cacheRoot: tempDir)
        let loaded = CostUsageCacheIO.load(provider: "codex", cacheRoot: tempDir)
        XCTAssertEqual(loaded.files["/a"]?.codex, state)
        XCTAssertEqual(loaded.files["/a"]?.codex?.isSubagent, true)
        XCTAssertEqual(loaded.files["/a"]?.codex?.namesForkParent, true)
        XCTAssertEqual(loaded.files["/a"]?.codex?.inheritedReference,
                       CostUsageCodexTotals(input: 5000, cached: 4000, output: 300))
        XCTAssertEqual(loaded.files["/a"]?.codex?.openingSettled, true)
        XCTAssertNil(loaded.files["/b"]?.codex)

        // An entry written before the field existed decodes with nil.
        let old = #"{"mtimeUnixMs":1,"size":1,"days":{},"sessionId":"s"}"#
        let decoded = try JSONDecoder().decode(CostUsageFileUsage.self, from: Data(old.utf8))
        XCTAssertNil(decoded.codex)

        // Every marker round-trips, and a state without one decodes as undecided.
        for marker in [CodexCopiedPrefix.ancestorMetadata, .interAgentMessage, .noMarker] {
            var s = CostUsageCodexFileState()
            s.copiedPrefix = marker
            XCTAssertEqual(try JSONDecoder().decode(CostUsageCodexFileState.self, from: JSONEncoder().encode(s)), s)
        }
        let undecided = try JSONDecoder().decode(CostUsageCodexFileState.self, from: Data(#"{"isChild":true,"historyStartOrdinal":3,"sawMeta":true,"baselineChecked":false,"eventCount":0}"#.utf8))
        XCTAssertNil(undecided.copiedPrefix)
        // A state written before rules 4 and 5 decodes with none of their fields.
        XCTAssertNil(undecided.isSubagent)
        XCTAssertNil(undecided.namesForkParent)
        XCTAssertNil(undecided.inheritedReference)
        XCTAssertNil(undecided.openingSettled)
    }

    // MARK: - wipeAll

    func testWipeAllRemovesCacheDirectory() {
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 1
        CostUsageCacheIO.save(provider: "codex", cache: cache, cacheRoot: tempDir)
        let costUsageDir = tempDir.appendingPathComponent("cost-usage", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: costUsageDir.path))

        CostUsageCacheIO.wipeAll(cacheRoot: tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: costUsageDir.path))
    }

    func testWipeAllMissingDirectoryDoesNotCrash() {
        let emptyRoot = tempDir.appendingPathComponent("nonexistent", isDirectory: true)
        XCTAssertNoThrow(CostUsageCacheIO.wipeAll(cacheRoot: emptyRoot))
    }

    func testSaveThenWipeAllThenLoadReturnsDefault() {
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 42
        CostUsageCacheIO.save(provider: "claude", cache: cache, cacheRoot: tempDir)
        CostUsageCacheIO.wipeAll(cacheRoot: tempDir)
        let loaded = CostUsageCacheIO.load(provider: "claude", cacheRoot: tempDir)
        XCTAssertEqual(loaded.lastScanUnixMs, 0)
    }

    // MARK: - CostUsageCodexTotals

    func testCostUsageCodexTotalsCodableRoundtrip() throws {
        let totals = CostUsageCodexTotals(input: 1000, cached: 500, output: 2000)
        let data = try JSONEncoder().encode(totals)
        let decoded = try JSONDecoder().decode(CostUsageCodexTotals.self, from: data)
        XCTAssertEqual(decoded.input, 1000)
        XCTAssertEqual(decoded.cached, 500)
        XCTAssertEqual(decoded.output, 2000)
    }
}

#endif

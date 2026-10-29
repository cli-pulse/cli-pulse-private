#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// 1.60 (A4, A5): Codex Fast (priority) turns at the Fast rate,
/// and free Auto-review requests at $0.
///
/// Current Codex records the Fast setting in the rollout: an `event_msg` of
/// type `thread_settings_applied` whose `thread_settings.service_tier` is
/// "priority". A turn runs at the tier set when it started (`task_started`),
/// as upstream CodexBar 0.82.0 latches it. The scanner reads rollouts
/// incrementally by offset, so the setting, and the turn it applies to, can
/// sit before the offset a later read starts at; `CostUsageCodexFileState`
/// carries them across. The same holds for the `creator_account_id` on the
/// first line that makes a session's Auto-review requests free.
final class CodexFastAndAutoReviewPricingTests: XCTestCase {

    private typealias T = CodexPricingTable
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    private var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }

    // MARK: - Rollout lines

    private let iso = ISO8601DateFormatter()
    private var clock = Date().addingTimeInterval(-3_600)
    private var total = 0

    private func stamp(_ at: Date? = nil) -> String {
        if let at { return iso.string(from: at) }
        clock = clock.addingTimeInterval(1)
        return iso.string(from: clock)
    }

    private func meta(_ id: String, creator: String? = nil, at: Date? = nil) -> String {
        let creatorField = creator.map { #","creator_account_id":"\#($0)""# } ?? ""
        return #"{"type":"session_meta","timestamp":"\#(stamp(at))","payload":{"id":"\#(id)","session_id":"\#(id)"\#(creatorField)}}"#
    }

    private func turnContext(_ model: String, at: Date? = nil) -> String {
        #"{"type":"turn_context","timestamp":"\#(stamp(at))","payload":{"model":"\#(model)"}}"#
    }

    private func settings(tier: String) -> String {
        #"{"type":"event_msg","timestamp":"\#(stamp())","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.5","service_tier":"\#(tier)","approval_policy":"on-request"}}}"#
    }

    private func taskStarted(_ turn: String) -> String {
        #"{"type":"event_msg","timestamp":"\#(stamp())","payload":{"type":"task_started","turn_id":"\#(turn)"}}"#
    }

    /// One request of `input` tokens (no cached, no output), with the running total.
    private func tokens(_ input: Int, at: Date? = nil) -> String {
        total += input
        return #"{"type":"event_msg","timestamp":"\#(stamp(at))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":0}}}}"#
    }

    private func write(_ lines: [String], to name: String) throws {
        try (lines.joined(separator: "\n") + "\n").write(
            to: sessions.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Rewrites `old` with `new` (the same length) where it already is, so a
    /// later scan that re-read the file from the start would see the change,
    /// and one that resumes at its offset does not.
    private func overwriteInPlace(_ old: String, with new: String, in name: String) throws {
        precondition(old.utf8.count == new.utf8.count)
        let url = sessions.appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: old).count, 2, "\(old) once in \(name)")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate] as Any], ofItemAtPath: url.path)
    }

    private func append(_ lines: [String], to name: String) throws {
        let handle = try FileHandle(forWritingTo: sessions.appendingPathComponent(name))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Scans incrementally (the cache is kept between scans), far enough back
    /// to reach the day before the Auto-review cutoff whatever today is.
    private func scan() -> [CostUsageScanResult.DailyEntry] {
        let days = Int(Date().timeIntervalSince(beforeCutoff) / 86_400) + 7
        var options = CostUsageScanner.Options(codexSessionsRoot: sessions, claudeProjectsRoots: [],
                                               cacheRoot: cache, daysToScan: max(days, 30))
        options.refreshMinIntervalSeconds = 0
        options.providers = [.codex]
        return CostUsageScanner.scan(options: options).entries.filter { $0.provider == "Codex" }
    }

    private func cost(_ entries: [CostUsageScanResult.DailyEntry], _ model: String) -> Double? {
        let rows = entries.filter { $0.model == model }
        guard !rows.isEmpty else { return -1 }
        var sum = 0.0
        for row in rows {
            guard let c = row.costUSD else { return nil }
            sum += c
        }
        return sum
    }

    private func parsedBytes(_ name: String) -> Int64? {
        // Keyed by the path as the scan listed it (`/private/var/…` or `/var/…`).
        CostUsageCacheIO.load(provider: "codex", cacheRoot: cache)
            .files.first { $0.key.hasSuffix("/" + name) }?.value.parsedBytes
    }

    // MARK: - A4: Fast turns

    /// The brief's fixture: the Fast setting arrives in the first read, and
    /// priority requests arrive in a later incremental read — one in the
    /// turn already started (needs the persisted turn tier), one in a new
    /// turn (needs the persisted setting). gpt-5.5 is $5 per 1M input, and
    /// Fast is 2.5x that.
    func test_fastSettingInFirstRead_pricesLaterIncrementalTurnsAtTheFastRate() throws {
        var lines = [meta("fast-1"), turnContext("gpt-5.5"), settings(tier: "priority"), taskStarted("t1")]
        lines.append(tokens(100_000))
        try write(lines, to: "rollout-fast-1.jsonl")
        XCTAssertEqual(cost(scan(), "gpt-5.5") ?? -1, 100_000 * 5e-6 * 2.5, accuracy: 1e-9, "first read")
        let firstOffset = try XCTUnwrap(parsedBytes("rollout-fast-1.jsonl"))

        // Proof the second scan resumes: a re-read from the start would now
        // see no Fast setting at all.
        try overwriteInPlace(#""service_tier":"priority""#, with: #""service_tier":"prioritX""#, in: "rollout-fast-1.jsonl")
        try append([tokens(100_000), taskStarted("t2"), tokens(100_000)], to: "rollout-fast-1.jsonl")
        let entries = scan()
        XCTAssertGreaterThan(try XCTUnwrap(parsedBytes("rollout-fast-1.jsonl")), firstOffset,
                             "the second scan read on from the first one's offset")
        XCTAssertEqual(cost(entries, "gpt-5.5") ?? -1, 300_000 * 5e-6 * 2.5, accuracy: 1e-9,
                       "every request of both turns at 2.5x")
    }

    /// Switching Fast off takes effect at the next turn, not mid-turn.
    func test_fastOff_appliesFromTheNextTurn() throws {
        var lines = [meta("fast-2"), turnContext("gpt-5.6-sol"), settings(tier: "priority"), taskStarted("t1")]
        lines.append(tokens(100_000))
        try write(lines, to: "rollout-fast-2.jsonl")
        _ = scan()
        try append([settings(tier: "default"), tokens(100_000), taskStarted("t2"), tokens(100_000)],
                   to: "rollout-fast-2.jsonl")
        // Sol is $4 per 1M: two Fast requests at 2x and one standard.
        XCTAssertEqual(cost(scan(), "gpt-5.6-sol") ?? -1, (2 * 2 + 1) * 100_000 * 4e-6, accuracy: 1e-9)
    }

    /// Codex's own order for a session's first turn: task_started, then
    /// turn_context and the settings, then the first request. The setting
    /// applies to that turn.
    func test_firstTurnWithTheSettingAfterTaskStarted_isFast() throws {
        var lines = [meta("fast-first"), taskStarted("t1"), turnContext("gpt-5.5"), settings(tier: "priority")]
        lines.append(tokens(100_000))
        try write(lines, to: "rollout-fast-first.jsonl")
        _ = scan()
        // A setting applied once the turn has made a request waits for the next turn.
        try append([settings(tier: "default"), tokens(100_000)], to: "rollout-fast-first.jsonl")
        XCTAssertEqual(cost(scan(), "gpt-5.5") ?? -1, 200_000 * 5e-6 * 2.5, accuracy: 1e-9)
    }

    /// The same order split across two reads: the turn started in the first,
    /// its setting and request came in the second.
    func test_firstTurnSplitAcrossReads_isFast() throws {
        try write([meta("fast-split"), taskStarted("t1"), turnContext("gpt-5.5")], to: "rollout-fast-split.jsonl")
        _ = scan()
        XCTAssertNotNil(parsedBytes("rollout-fast-split.jsonl"), "the first read was kept")
        try append([settings(tier: "priority"), tokens(100_000)], to: "rollout-fast-split.jsonl")
        XCTAssertEqual(cost(scan(), "gpt-5.5") ?? -1, 100_000 * 5e-6 * 2.5, accuracy: 1e-9)
    }

    /// A setting with no `service_tier` is not Fast.
    func test_settingWithoutATier_isStandard() throws {
        let noTier = #"{"type":"event_msg","timestamp":"\#(stamp())","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.5","service_tier":null}}}"#
        var lines = [meta("no-tier"), turnContext("gpt-5.5"), settings(tier: "priority"), noTier, taskStarted("t1")]
        lines.append(tokens(100_000))
        try write(lines, to: "rollout-no-tier.jsonl")
        XCTAssertEqual(cost(scan(), "gpt-5.5") ?? -1, 100_000 * 5e-6, accuracy: 1e-9)
    }

    /// No Fast setting, or `default`: standard rates, as before.
    func test_defaultTier_isStandard() throws {
        var lines = [meta("std"), turnContext("gpt-5.5"), settings(tier: "default"), taskStarted("t1")]
        lines.append(tokens(100_000))
        try write(lines, to: "rollout-std.jsonl")
        XCTAssertEqual(cost(scan(), "gpt-5.5") ?? -1, 100_000 * 5e-6, accuracy: 1e-9)
    }

    /// A Codex archive (`.jsonl.zst`, the N1 path) is read whole, and its
    /// Fast turns are priced the same as in the plain log.
    func test_archivedSession_pricesFastTurns() throws {
        var lines = [meta("fast-zst"), turnContext("gpt-5.5"), settings(tier: "priority"), taskStarted("t1")]
        lines.append(tokens(100_000))
        lines.append(tokens(50_000))
        try ZstdTestFrames.write(Data((lines.joined(separator: "\n") + "\n").utf8),
                                 to: sessions.appendingPathComponent("rollout-fast-zst.jsonl.zst"))
        XCTAssertEqual(cost(scan(), "gpt-5.5") ?? -1, 150_000 * 5e-6 * 2.5, accuracy: 1e-9)
    }

    /// A session read in part as `.jsonl`, then archived by Codex: the
    /// archive replaces it and is read whole, Fast state and all.
    func test_sessionArchivedAfterAnIncrementalRead_keepsItsFastPricing() throws {
        var lines = [meta("fast-arch"), turnContext("gpt-5.5"), settings(tier: "priority"), taskStarted("t1")]
        lines.append(tokens(100_000))
        try write(lines, to: "rollout-fast-arch.jsonl")
        _ = scan()
        lines.append(tokens(100_000))
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("rollout-fast-arch.jsonl"))
        try ZstdTestFrames.write(Data((lines.joined(separator: "\n") + "\n").utf8),
                                 to: sessions.appendingPathComponent("rollout-fast-arch.jsonl.zst"))
        XCTAssertEqual(cost(scan(), "gpt-5.5") ?? -1, 200_000 * 5e-6 * 2.5, accuracy: 1e-9)
    }

    /// Above 272K input, gpt-5.5 has no Fast rate on OpenAI's page (standard
    /// rates, as upstream), while gpt-5.6-sol's long-context Fast rate is 2x
    /// its long-context standard rate.
    func test_fastAboveTheLongContextLine() throws {
        var a = [meta("lc-55"), turnContext("gpt-5.5"), settings(tier: "priority"), taskStarted("t1")]
        a.append(tokens(300_000))
        try write(a, to: "rollout-lc-55.jsonl")
        total = 0
        var b = [meta("lc-sol"), turnContext("gpt-5.6-sol"), settings(tier: "priority"), taskStarted("t1")]
        b.append(tokens(300_000))
        try write(b, to: "rollout-lc-sol.jsonl")
        let entries = scan()
        XCTAssertEqual(cost(entries, "gpt-5.5") ?? -1, 300_000 * 1e-5, accuracy: 1e-9, "long-context standard")
        XCTAssertEqual(cost(entries, "gpt-5.6-sol") ?? -1, 300_000 * 8e-6 * 2, accuracy: 1e-9, "long-context Fast")
    }

    /// A model priced at a borrowed row (`gpt-5.7` → the version fallback)
    /// takes no Fast multiple: nothing says what its Fast rate is.
    func test_borrowedRow_takesNoFastMultiple() throws {
        var lines = [meta("borrowed"), turnContext("gpt-5.7"), settings(tier: "priority"), taskStarted("t1")]
        lines.append(tokens(100_000))
        try write(lines, to: "rollout-borrowed.jsonl")
        let entries = scan()
        let row = try XCTUnwrap(entries.first { $0.model == "gpt-5.7" })
        XCTAssertTrue(row.priceIsApproximate)
        let key = try XCTUnwrap(CostUsageScanner.Pricing.codexPricingKey("gpt-5.7"))
        let rates = try XCTUnwrap(T.rates(forKey: key, at: Date()))
        XCTAssertEqual(row.costUSD ?? -1, 100_000 * rates.input, accuracy: 1e-9)
    }

    /// The multiples, against OpenAI's pricing page (checked 2026-10-29).
    func test_fastMultipliers_matchTheDocumentedRates() {
        XCTAssertEqual(T.fastMultipliers, [
            "gpt-5.4": 2, "gpt-5.4-mini": 2, "gpt-5.5": 2.5,
            "gpt-5.6-sol": 2, "gpt-5.6-terra": 2, "gpt-5.6-luna": 2,
            "gpt-6-astra": 2, "gpt-6-sol": 2, "gpt-6-luna": 2, "gpt-6.1-sol": 2,
        ])
        for key in T.fastMultipliers.keys {
            XCTAssertNotNil(T.current[key], "\(key) has a standard row to multiply")
        }
        XCTAssertNil(T.fastMultiplier(forKey: "gpt-5.5", requestInputTokens: 272_001))
        XCTAssertEqual(T.fastMultiplier(forKey: "gpt-5.5", requestInputTokens: 272_000), 2.5)
        XCTAssertEqual(T.fastMultiplier(forKey: "gpt-6-astra", requestInputTokens: 500_000), 2)
        XCTAssertNil(T.fastMultiplier(forKey: "gpt-5.2", requestInputTokens: 1))
        XCTAssertTrue(T.fastLongContextRows.isSubset(of: Set(T.fastMultipliers.keys)))
        for key in T.fastLongContextRows {
            XCTAssertNotNil(T.current[key]?.longContextThreshold, "\(key) has a long-context tier to double")
        }
    }

    // MARK: - A5: Auto-review

    private let afterCutoff = Date().addingTimeInterval(-7_200)
    private let beforeCutoff = CodexPricingTable.autoReviewFreeSince.addingTimeInterval(-86_400)

    /// From 2026-10-06, in a session created signed in with ChatGPT, an
    /// Auto-review request is priced at $0: a price, not "no rate".
    func test_autoReview_withCreatorAccount_afterCutoff_isFree() throws {
        var lines = [meta("ar-free", creator: "acct-fixture", at: afterCutoff), turnContext("codex-auto-review", at: afterCutoff)]
        lines.append(tokens(40_000, at: afterCutoff))
        try write(lines, to: "rollout-ar-free.jsonl")
        let row = try XCTUnwrap(scan().first { $0.model == "codex-auto-review" })
        XCTAssertEqual(row.costUSD, 0, "priced at $0")
        XCTAssertEqual(row.inputTokens, 40_000, "its tokens still count")
    }

    /// Before the cutoff, or without a creator account (an API-key session),
    /// it has no rate, as before: the cost stays a lower bound.
    func test_autoReview_beforeCutoff_orWithoutCreator_isUnpriced() throws {
        var a = [meta("ar-early", creator: "acct-fixture", at: beforeCutoff), turnContext("codex-auto-review", at: beforeCutoff)]
        a.append(tokens(40_000, at: beforeCutoff))
        try write(a, to: "rollout-ar-early.jsonl")
        total = 0
        var b = [meta("ar-apikey", creator: "  ", at: afterCutoff), turnContext("codex-auto-review", at: afterCutoff)]
        b.append(tokens(40_000, at: afterCutoff))
        try write(b, to: "rollout-ar-apikey.jsonl")
        let rows = scan().filter { $0.model == "codex-auto-review" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.costUSD == nil }, "no rate")
    }

    /// A day with one free Auto-review request and one with no rate has no
    /// rate as a whole: the cost stays a lower bound, not $0.
    func test_autoReviewDayMixingFreeAndUnpriced_isUnpriced() throws {
        var a = [meta("ar-mix-free", creator: "acct-fixture", at: afterCutoff), turnContext("codex-auto-review", at: afterCutoff)]
        a.append(tokens(40_000, at: afterCutoff))
        try write(a, to: "rollout-ar-mix-free.jsonl")
        total = 0
        var b = [meta("ar-mix-key", at: afterCutoff), turnContext("codex-auto-review", at: afterCutoff)]
        b.append(tokens(40_000, at: afterCutoff))
        try write(b, to: "rollout-ar-mix-key.jsonl")
        let row = try XCTUnwrap(scan().first { $0.model == "codex-auto-review" })
        XCTAssertEqual(row.inputTokens, 80_000)
        XCTAssertNil(row.costUSD)
    }

    /// A row written before slot 4 existed reads as before: no rate.
    func test_rowWithoutSlot4_forAModelWithNoRate_isUnpriced() {
        XCTAssertNil(CostUsageScanner.codexCost(model: "codex-auto-review", packed: [1, 0, 0, 0]))
        XCTAssertEqual(CostUsageScanner.codexCost(model: "codex-auto-review", packed: [1, 0, 0, 0, 0]), 0)
        XCTAssertNil(CostUsageScanner.codexCost(model: "codex-auto-review", packed: [1, 0, 0, 0, 1]))
    }

    /// The creator account is on the first line only; an Auto-review request
    /// read by a later incremental read is still free.
    func test_autoReview_inALaterIncrementalRead_isStillFree() throws {
        var lines = [meta("ar-inc", creator: "acct-fixture", at: afterCutoff), turnContext("codex-auto-review", at: afterCutoff)]
        lines.append(tokens(40_000, at: afterCutoff))
        try write(lines, to: "rollout-ar-inc.jsonl")
        _ = scan()
        let firstOffset = try XCTUnwrap(parsedBytes("rollout-ar-inc.jsonl"))
        // Proof the second scan resumes: a re-read would find no creator.
        try overwriteInPlace(#""creator_account_id":"acct-fixture""#, with: #""creator_account_id":"            ""#, in: "rollout-ar-inc.jsonl")
        try append([tokens(10_000, at: afterCutoff.addingTimeInterval(60))], to: "rollout-ar-inc.jsonl")
        let row = try XCTUnwrap(scan().first { $0.model == "codex-auto-review" })
        XCTAssertGreaterThan(try XCTUnwrap(parsedBytes("rollout-ar-inc.jsonl")), firstOffset)
        XCTAssertEqual(row.inputTokens, 50_000)
        XCTAssertEqual(row.costUSD, 0, "still priced at $0")
    }
}
#endif

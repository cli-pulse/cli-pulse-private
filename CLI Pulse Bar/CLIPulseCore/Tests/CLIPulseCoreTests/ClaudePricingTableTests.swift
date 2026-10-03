import XCTest
@testable import CLIPulseCore

/// v1.56 — the Claude price table, with the rates a model had before.
///
/// Until 1.56 the Mac had no rows for Claude Opus 5.5, Fable 5.1 or Sonnet
/// 5.5, so they borrowed their family's newest row: Opus 5.5 was charged Opus
/// 5's $5 / $25 and $0.50 cache hits (its own are $4 / $20 and $0.20), and
/// Fable 5.1 Fable 5's $1 cache hits (its own are $0.25). Sonnet 5 was charged
/// $3 / $15, a rate it never had, and every cache write was charged at the
/// 5-minute rate although Claude Code writes much of its cache for an hour.
///
/// The rows are Anthropic's, checked against
/// https://platform.claude.com/docs/en/about-claude/pricing on 2026-10-03.
/// Dated rates: Opus 4.6 and Sonnet 4.6 paid the 200K long-context tier until
/// their 1M window went to standard pricing on 2026-03-13 (API release notes).
final class ClaudePricingTableTests: XCTestCase {

    private typealias T = ClaudePricingTable
    private let million = 1_000_000

    private func iso(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    /// USD per million tokens of each kind at standard rates, in the page's
    /// column order: base input, 5-minute cache write, 1-hour cache write,
    /// cache hit, output. Measured on 100K-token requests, under every 200K
    /// tier.
    private func perMillion(_ rates: T.Rates) -> [Double] {
        let n = 100_000
        return [
            T.requestCostUSD(rates: rates, inputTokens: n, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0),
            T.requestCostUSD(rates: rates, inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: n, outputTokens: 0),
            T.requestCostUSD(rates: rates, inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: n,
                             cacheWrite1hTokens: n, outputTokens: 0),
            T.requestCostUSD(rates: rates, inputTokens: 0, cacheReadTokens: n, cacheWriteTokens: 0, outputTokens: 0),
            T.requestCostUSD(rates: rates, inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: n),
        ].map { $0 * 10 }
    }

    // MARK: - Today's rates

    /// The "Model pricing" table on Anthropic's page, 2026-10-03, row by row.
    /// Every row of `current` has to be listed here, so a row added to the
    /// table without being read against the page fails.
    func test_publishedRatesPerMillionTokens() {
        let fable51 = [10, 12.5, 20, 0.25, 50]
        let fable5 = [10, 12.5, 20, 1, 50]
        let opus4 = [5, 6.25, 10, 0.5, 25]
        let opus41 = [15, 18.75, 30, 1.5, 75]
        let sonnet5 = [2, 2.5, 4, 0.2, 10]
        let sonnet4 = [3, 3.75, 6, 0.3, 15]
        let haiku45 = [1, 1.25, 2, 0.1, 5]
        let expected: [String: [Double]] = [
            "claude-fable-5-1": fable51,
            "claude-mythos-5-1": fable51,
            "claude-fable-5": fable5,
            "claude-mythos-5": fable5,
            "claude-opus-5-5": [4, 5, 8, 0.2, 20],
            "claude-opus-5": opus4,
            "claude-opus-4-8": opus4,
            "claude-opus-4-7": opus4,
            "claude-opus-4-6": opus4,
            "claude-opus-4-6-20260205": opus4,
            "claude-opus-4-5": opus4,
            "claude-opus-4-5-20251101": opus4,
            "claude-opus-4-1": opus41,
            "claude-opus-4-20250514": opus41,
            "claude-sonnet-5-5": sonnet5,
            "claude-sonnet-5": sonnet5,
            "claude-sonnet-4-6": sonnet4,
            "claude-sonnet-4-5": sonnet4,
            "claude-sonnet-4-5-20250929": sonnet4,
            "claude-sonnet-4-20250514": sonnet4,
            "claude-haiku-4-5": haiku45,
            "claude-haiku-4-5-20251001": haiku45,
        ]
        XCTAssertEqual(Set(T.current.keys), Set(expected.keys))
        for (model, prices) in expected {
            guard let rates = T.current[model] else { continue }
            let actual = perMillion(rates)
            for (index, column) in ["input", "5m write", "1h write", "cache hit", "output"].enumerated() {
                XCTAssertEqual(actual[index], prices[index], accuracy: 1e-9, "\(model) \(column)")
            }
        }
    }

    /// The page's caching multipliers: a 5-minute write is 1.25x input, a
    /// 1-hour write 2x, a cache hit 0.1x — except 0.05x on Opus 5.5 and 0.025x
    /// on Fable 5.1 and Mythos 5.1. Cache hits are most of a Claude Code day's
    /// tokens, which is why the two exceptions matter.
    func test_cacheRatesFollowThePagesMultipliers() {
        let hitMultiplier: [String: Double] = [
            "claude-opus-5-5": 0.05, "claude-fable-5-1": 0.025, "claude-mythos-5-1": 0.025,
        ]
        for (model, rates) in T.current {
            let tiers: [(String, T.TokenRates?)] = [("standard", rates.standard), ("long context", rates.longContext)]
            for (tier, prices) in tiers {
                guard let prices else { continue }
                XCTAssertEqual(prices.cacheWrite5m, prices.input * 1.25, accuracy: 1e-15, "\(model) \(tier) 5m write")
                XCTAssertEqual(prices.cacheWrite1h, prices.input * 2, accuracy: 1e-15, "\(model) \(tier) 1h write")
                XCTAssertEqual(prices.cacheRead, prices.input * (hitMultiplier[model] ?? 0.1), accuracy: 1e-15,
                               "\(model) \(tier) cache hit")
            }
        }
    }

    /// "Claude 4.6 and later models ... include the full 1M token context
    /// window at standard pricing." Only Sonnet 4 and 4.5, whose 1M beta was
    /// retired on 2026-04-30, keep a tier today, and it is 2x input and 1.5x
    /// output above 200K.
    func test_onlySonnet4And45HaveALongContextTierToday() {
        let tiered = Set(T.current.filter { $0.value.longContextThreshold != nil }.keys)
        XCTAssertEqual(tiered, ["claude-sonnet-4-5", "claude-sonnet-4-5-20250929", "claude-sonnet-4-20250514"])
        for key in tiered {
            let rates = T.current[key]!
            XCTAssertEqual(rates.longContextThreshold, 200_000)
            XCTAssertEqual(rates.longContext?.input ?? 0, rates.standard.input * 2, accuracy: 1e-15, key)
            XCTAssertEqual(rates.longContext?.output ?? 0, rates.standard.output * 1.5, accuracy: 1e-15, key)
        }
    }

    // MARK: - Rates a model had before

    func test_theLongContextDateIsTheOneAnthropicPublished() {
        XCTAssertEqual(T.longContextAtStandardPricing, iso("2026-03-13T00:00:00Z"))
    }

    /// A 300K-token Sonnet 4.6 request paid $6 per 1M until 2026-03-13 and
    /// $3 from then on; Opus 4.6 $10 and $5.
    func test_the46ModelsPayTheTierUntilTheSecondItEnded() throws {
        let before = T.longContextAtStandardPricing.addingTimeInterval(-1)
        let from = T.longContextAtStandardPricing
        for (model, standard, long) in [("claude-sonnet-4-6", 3.0, 6.0), ("claude-opus-4-6", 5.0, 10.0),
                                        ("claude-opus-4-6-20260205", 5.0, 10.0)] {
            func cost(at date: Date) throws -> Double {
                let rates = try XCTUnwrap(T.rates(forKey: model, at: date), model)
                return T.requestCostUSD(rates: rates, inputTokens: 300_000, cacheReadTokens: 0,
                                        cacheWriteTokens: 0, outputTokens: 0)
            }
            XCTAssertEqual(try cost(at: before), 0.3 * long, accuracy: 1e-9, "\(model) before 03-13")
            XCTAssertEqual(try cost(at: from), 0.3 * standard, accuracy: 1e-9, "\(model) from 03-13")
        }
    }

    func test_noDateMeansTodaysRate() {
        XCTAssertEqual(T.rates(forKey: "claude-sonnet-4-6", at: nil), T.current["claude-sonnet-4-6"])
        XCTAssertEqual(T.rates(forKey: "claude-opus-5-5", at: iso("2020-01-01T00:00:00Z")),
                       T.current["claude-opus-5-5"], "a model with no history is charged today's rate at any date")
    }

    /// A model with earlier rates and no row today would never be resolved to
    /// that key, so its history would never be read.
    func test_everyModelWithEarlierRatesHasARowToday() {
        for model in T.superseded.keys {
            XCTAssertNotNil(T.current[model], "\(model) has earlier rates and no row today")
        }
    }

    func test_eachModelsEarlierRatesRunOldestFirst() {
        for (model, history) in T.superseded {
            let ends = history.map(\.until)
            XCTAssertEqual(ends, ends.sorted(), model)
        }
    }

    // MARK: - Cost

    /// 1M tokens written to the 1-hour cache on Opus 5.5 cost $8; to the
    /// 5-minute cache, $5. The split is clamped to the writes it is part of.
    func test_oneHourCacheWritesCostTwiceInput() throws {
        let rates = try XCTUnwrap(T.current["claude-opus-5-5"])
        func writes(_ total: Int, oneHour: Int) -> Double {
            T.requestCostUSD(rates: rates, inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: total,
                             cacheWrite1hTokens: oneHour, outputTokens: 0)
        }
        XCTAssertEqual(writes(million, oneHour: 0), 5, accuracy: 1e-9)
        XCTAssertEqual(writes(million, oneHour: million), 8, accuracy: 1e-9)
        XCTAssertEqual(writes(million, oneHour: million / 2), 6.5, accuracy: 1e-9)
        XCTAssertEqual(writes(million, oneHour: 2 * million), 8, accuracy: 1e-9, "never more 1-hour writes than writes")
        XCTAssertEqual(writes(million, oneHour: -5), 5, accuracy: 1e-9)
    }

    /// A sum of responses never takes the long-context tier: 300K tokens of
    /// Sonnet 4.5 as a day's sum cost $0.90, as one request $1.80.
    func test_aSumNeverTakesTheLongContextTier() throws {
        let rates = try XCTUnwrap(T.current["claude-sonnet-4-5"])
        XCTAssertEqual(T.aggregateCostUSD(rates: rates, inputTokens: 300_000, cacheReadTokens: 0,
                                          cacheWriteTokens: 0, outputTokens: 0), 0.9, accuracy: 1e-9)
        XCTAssertEqual(T.requestCostUSD(rates: rates, inputTokens: 300_000, cacheReadTokens: 0,
                                        cacheWriteTokens: 0, outputTokens: 0), 1.8, accuracy: 1e-9)
    }

    #if os(macOS)

    private typealias P = CostUsageScanner.Pricing

    // MARK: - Which row a model is charged

    /// The three models this change exists for are charged their own rows, not
    /// a borrowed one, in every spelling Claude Code or a cloud provider uses.
    func test_theNewModelsAreChargedTheirOwnRows() {
        let exact: [(name: String, key: String)] = [
            ("claude-opus-5-5", "claude-opus-5-5"),
            ("anthropic.claude-opus-5-5", "claude-opus-5-5"),
            ("claude-opus-5-5-20260922", "claude-opus-5-5"),
            ("claude-fable-5-1", "claude-fable-5-1"),
            ("claude-mythos-5-1", "claude-mythos-5-1"),
            ("claude-sonnet-5-5", "claude-sonnet-5-5"),
            ("us.anthropic.claude-sonnet-5-5-v1:0", "claude-sonnet-5-5"),
        ]
        for (name, key) in exact {
            XCTAssertEqual(P.claudePriceResolution(name), P.PriceResolution(key: key, isApproximate: false), name)
        }
    }

    // MARK: - End to end

    private var tmpRoot: URL?

    override func tearDown() {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        super.tearDown()
    }

    private func makeProjects() throws -> (projects: URL, project: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-pricing-\(UUID().uuidString)", isDirectory: true)
        tmpRoot = root
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("-Users-stub-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions", isDirectory: true),
                                                withIntermediateDirectories: true)
        return (projects, project, root.appendingPathComponent("cache", isDirectory: true))
    }

    /// One assistant line, shaped like Claude Code's. `oneHour` nil leaves out
    /// the `cache_creation` split, as older logs do.
    private func line(_ id: String, model: String, at: Date, input: Int, cacheRead: Int,
                      cacheCreate: Int, oneHour: Int?, output: Int) -> String {
        let ts = ISO8601DateFormatter().string(from: at)
        let split = oneHour.map {
            #","cache_creation":{"ephemeral_5m_input_tokens":\#(cacheCreate - $0),"ephemeral_1h_input_tokens":\#($0)}"#
        } ?? ""
        return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"req-\#(id)","message":{"id":"msg-\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreate)\#(split),"output_tokens":\#(output)}}}"#
    }

    /// Scans `projects` with a window reaching back past February 2026.
    private func scan(_ projects: URL, cache: URL) -> [CostUsageScanResult.DailyEntry] {
        let days = Int(Date().timeIntervalSince(iso("2026-02-01T00:00:00Z")) / 86_400) + 3
        var options = CostUsageScanner.Options(
            codexSessionsRoot: cache.deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [projects], cacheRoot: cache, daysToScan: max(days, 30)
        )
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        return CostUsageScanner.scan(options: options).entries
            .filter { $0.provider == "Claude" && $0.model != CostUsageScanner.claudeMsgBucketModel }
            .sorted { $0.date < $1.date }
    }

    /// One Opus 5.5 response: 1,000 input, 1M cache hits, 100K cache writes
    /// (60K of them for an hour), 10K output. At Opus 5.5's rates:
    /// 1,000 × $4 + 1M × $0.20 + 40K × $5 + 60K × $8 + 10K × $20 per 1M =
    /// $1.084. At the Opus 5 rates it used to borrow, with every write at the
    /// 5-minute rate, $1.38. A second, older log without the split is charged
    /// its writes at the 5-minute rate.
    func test_aScannedOpus55ResponseIsChargedItsOwnRates() throws {
        let (projects, project, cache) = try makeProjects()
        let now = Date().addingTimeInterval(-3_600)
        try (line("split", model: "claude-opus-5-5", at: now, input: 1_000, cacheRead: million,
                  cacheCreate: 100_000, oneHour: 60_000, output: 10_000) + "\n")
            .write(to: project.appendingPathComponent("split.jsonl"), atomically: true, encoding: .utf8)
        try (line("nosplit", model: "claude-sonnet-5-5", at: now, input: 0, cacheRead: 0,
                  cacheCreate: million, oneHour: nil, output: 0) + "\n")
            .write(to: project.appendingPathComponent("nosplit.jsonl"), atomically: true, encoding: .utf8)

        let entries = scan(projects, cache: cache)
        let opus = try XCTUnwrap(entries.first { $0.model == "claude-opus-5-5" })
        XCTAssertEqual(opus.costUSD ?? -1, 1.084, accuracy: 1e-9)
        XCTAssertFalse(opus.priceIsApproximate, "Opus 5.5 has its own row")
        let sonnet = try XCTUnwrap(entries.first { $0.model == "claude-sonnet-5-5" })
        XCTAssertEqual(sonnet.costUSD ?? -1, 2.5, accuracy: 1e-9, "1M 5-minute writes at $2.50")
        XCTAssertFalse(sonnet.priceIsApproximate)
    }

    /// Two Sonnet 4.6 requests of 301K prompt tokens (1K input, 300K cache
    /// hits), two days either side of 2026-03-13. The earlier one pays the
    /// long-context rates on every token ($0.186), the later one standard
    /// rates ($0.093).
    func test_aScannedSonnet46RequestPaysTheTierOnlyBeforeMarch13() throws {
        let (projects, project, cache) = try makeProjects()
        let twoDays: TimeInterval = 2 * 86_400
        let lines = [
            line("before", model: "claude-sonnet-4-6", at: T.longContextAtStandardPricing - twoDays,
                 input: 1_000, cacheRead: 300_000, cacheCreate: 0, oneHour: 0, output: 0),
            line("after", model: "claude-sonnet-4-6", at: T.longContextAtStandardPricing + twoDays,
                 input: 1_000, cacheRead: 300_000, cacheCreate: 0, oneHour: 0, output: 0),
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: project.appendingPathComponent("sonnet46.jsonl"), atomically: true, encoding: .utf8)

        let costs = scan(projects, cache: cache).filter { $0.model == "claude-sonnet-4-6" }.map { $0.costUSD ?? -1 }
        XCTAssertEqual(costs.count, 2)
        guard costs.count == 2 else { return }
        XCTAssertEqual(costs[0], 0.186, accuracy: 1e-9, "before 03-13: 1K × $6 + 300K × $0.60 per 1M")
        XCTAssertEqual(costs[1], 0.093, accuracy: 1e-9, "from 03-13: 1K × $3 + 300K × $0.30 per 1M")
    }

    /// Claude day rows carry each response's cost, priced when it was read
    /// (slot 4, in nanodollars). So a change to this table reaches days
    /// already cached only through a bump of `costUsageCachePricingVersion`;
    /// the two tests below are what force that bump.
    func test_claudeCacheRowsCarryTheirResponsesCost() throws {
        let (projects, project, cache) = try makeProjects()
        try (line("row", model: "claude-fable-5-1", at: Date().addingTimeInterval(-3_600), input: 0,
                  cacheRead: million, cacheCreate: 0, oneHour: 0, output: 0) + "\n")
            .write(to: project.appendingPathComponent("row.jsonl"), atomically: true, encoding: .utf8)
        _ = scan(projects, cache: cache)
        let saved = CostUsageCacheIO.load(provider: "claude", cacheRoot: cache)
        let rows = saved.days.values.compactMap { $0["claude-fable-5-1"] }
        XCTAssertEqual(rows.count, 1, "the fixture must reach the cache, or this checks nothing")
        for packed in rows {
            XCTAssertEqual(Double(packed[4]) / 1e9, 0.25, accuracy: 1e-12, "1M Fable 5.1 cache hits at $0.25")
        }
    }

    /// A cached day row without a stored cost is priced from its sum, and a
    /// sum never takes the long-context tier: 300K Sonnet 4.5 input tokens in
    /// one day's row cost $0.90 (standard rate), not the $1.80 one 300K
    /// request would.
    func test_aCachedDayRowWithoutAStoredCostIsPricedAsASum() throws {
        let (projects, _, cache) = try makeProjects()
        let today = CostUsageScanner.DayRange.dayKey(from: Date())
        var saved = CostUsageCache()
        saved.lastScanUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        saved.days = [today: ["claude-sonnet-4-5": [300_000, 0, 0, 0, 0, 0]]]
        CostUsageCacheIO.save(provider: "claude", cache: saved, cacheRoot: cache)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: cache.deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [projects], cacheRoot: cache, daysToScan: 30
        )
        options.refreshMinIntervalSeconds = 3_600   // read the saved cache as it is
        let row = try XCTUnwrap(CostUsageScanner.scan(options: options).entries.first {
            $0.provider == "Claude" && $0.model == "claude-sonnet-4-5"
        }, "the saved row must come back, or this checks nothing")
        XCTAssertEqual(row.costUSD ?? -1, 0.9, accuracy: 1e-9)
    }

    /// The same for a live session's total, which sums its log's day rows:
    /// a log whose cached rows hold no stored cost is priced as a sum.
    func test_aSessionWhoseRowsHoldNoStoredCostIsPricedAsASum() throws {
        let (projects, project, cache) = try makeProjects()
        let log = project.appendingPathComponent("live.jsonl")
        try "{}\n".write(to: log, atomically: true, encoding: .utf8)
        // The scanner keys a log by the path it enumerates, which is the real
        // one (/private/var/… for a temporary file, not /var/…).
        let path = try XCTUnwrap(log.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        let today = CostUsageScanner.DayRange.dayKey(from: Date())
        var saved = CostUsageCache()
        saved.lastScanUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        saved.files[path] = CostUsageFileUsage(
            mtimeUnixMs: saved.lastScanUnixMs, size: 3,
            days: [today: ["claude-sonnet-4-5": [300_000, 0, 0, 0, 0, 0]]]
        )
        CostUsageCacheIO.save(provider: "claude", cache: saved, cacheRoot: cache)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: cache.deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [projects], cacheRoot: cache, daysToScan: 30
        )
        options.refreshMinIntervalSeconds = 3_600   // read the saved cache as it is
        let session = try XCTUnwrap(CostUsageScanner.scan(options: options).activeSessionCandidates.first {
            $0.provider == "Claude" && $0.sessionId == "live"
        }, "the fresh log must be a candidate, or this checks nothing")
        XCTAssertEqual(session.filePath, path, "the saved rows are keyed by this path")
        XCTAssertEqual(session.totalCost, 0.9, accuracy: 1e-9)
    }

    // MARK: - Rate changes reach stored costs only through a rules bump

    /// Each response's cost is stored when it is read, so a change to
    /// `ClaudePricingTable` (a rate, a tier, a dated rate, a row) — or to
    /// which row a model name resolves to — leaves every day already scanned
    /// at the old price unless `costUsageCachePricingVersion` is bumped. This
    /// pin fails when either changes; bump the version, then update both
    /// numbers here.
    func test_claude_rate_changes_come_with_a_rules_version_bump() {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in P.claudeRatesFingerprint().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        XCTAssertEqual(
            [UInt64(costUsageCachePricingVersion), hash],
            [7, 3_392_943_204_880_634_185],
            "Claude rates changed: bump costUsageCachePricingVersion, then pin the new version and hash"
        )
    }

    /// A repriced row, a new tier, a new row and a dated rate's end each move
    /// the fingerprint, so none of them can ship without the bump that makes
    /// every Mac read its Claude logs again.
    func test_aTableChangeChangesTheClaudeFingerprint() throws {
        let real = P.claudeRatesFingerprint()
        XCTAssertEqual(real, P.claudeRatesFingerprint(current: T.current, superseded: T.superseded))

        let row = try XCTUnwrap(T.current["claude-opus-5-5"])
        func copy(_ r: T.Rates, input: Double? = nil, hit: Double? = nil) -> T.Rates {
            let s = r.standard
            return T.Rates(
                standard: T.TokenRates(input: input ?? s.input, cacheWrite5m: s.cacheWrite5m, cacheWrite1h: s.cacheWrite1h,
                                       cacheRead: hit ?? s.cacheRead, output: s.output),
                longContextThreshold: r.longContextThreshold, longContext: r.longContext
            )
        }
        XCTAssertEqual(P.claudeRatesFingerprint(current: T.current.merging(["claude-opus-5-5": copy(row)]) { $1 }), real,
                       "an unchanged copy is the same table")

        var changes: [(String, String)] = []
        changes.append(("a repriced row", P.claudeRatesFingerprint(
            current: T.current.merging(["claude-opus-5-5": copy(row, input: 5e-6)]) { $1 })))
        changes.append(("a repriced cache hit", P.claudeRatesFingerprint(
            current: T.current.merging(["claude-opus-5-5": copy(row, hit: 5e-7)]) { $1 })))
        changes.append(("a new tier", P.claudeRatesFingerprint(current: T.current.merging([
            "claude-opus-5-5": T.Rates(standard: row.standard, longContextThreshold: 200_000, longContext: row.standard),
        ]) { $1 })))
        changes.append(("a new row", P.claudeRatesFingerprint(current: T.current.merging(["claude-opus-6": row]) { $1 })))
        let sonnetBefore = try XCTUnwrap(T.superseded["claude-sonnet-4-6"]?.first)
        changes.append(("a dated rate's end", P.claudeRatesFingerprint(superseded: T.superseded.merging([
            "claude-sonnet-4-6": [T.DatedRates(until: sonnetBefore.until.addingTimeInterval(86_400), rates: sonnetBefore.rates)],
        ]) { $1 })))
        for (what, fingerprint) in changes {
            XCTAssertNotEqual(fingerprint, real, what)
        }
    }

    #endif
}

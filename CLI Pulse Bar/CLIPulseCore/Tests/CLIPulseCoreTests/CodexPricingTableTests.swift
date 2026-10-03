import XCTest
@testable import CLIPulseCore

/// v1.56 — the Codex price table, with the rates a model had before a
/// repricing.
///
/// Until 1.56 the Mac priced `gpt-6-astra` and `gpt-5.6-sol` at gpt-5.4's
/// $2.50 / $15 (the only row they could fall back to), a quarter and five
/// eighths of OpenAI's list input price. The rows below are OpenAI's, checked
/// against https://developers.openai.com/api/docs/pricing on 2026-09-30.
///
/// Dated rates: GPT-5.6 Sol went from $5 / $30 to $4 / $20 on 2026-08-21, and
/// Terra and Luna were cut 20% and 80% on 2026-07-30 (OpenAI changelog). A day
/// before a cut is charged the old rate. One boundary test per date.
final class CodexPricingTableTests: XCTestCase {

    private typealias T = CodexPricingTable
    private let million = 1_000_000

    private func iso(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    /// USD for one million tokens of each kind, at `rates`.
    private func perMillion(_ rates: T.Rates) -> (input: Double, cached: Double, output: Double) {
        (
            T.aggregateCostUSD(rates: rates, inputTokens: million, cachedInputTokens: 0, outputTokens: 0),
            T.aggregateCostUSD(rates: rates, inputTokens: million, cachedInputTokens: million, outputTokens: 0),
            T.aggregateCostUSD(rates: rates, inputTokens: 0, cachedInputTokens: 0, outputTokens: million)
        )
    }

    // MARK: - Today's rates

    /// OpenAI's standard-tier list prices, per 1M tokens: input, cached input,
    /// output. If a rate is edited by accident, this is the test that notices.
    func test_publishedRatesPerMillionTokens() {
        let expected: [(model: String, input: Double, cached: Double, output: Double)] = [
            ("gpt-5.4", 2.5, 0.25, 15),
            ("gpt-5.5", 5, 0.5, 30),
            ("gpt-6-astra", 10, 1, 50),
            ("gpt-5.6-sol", 4, 0.4, 20),
            ("gpt-5.6-terra", 2, 0.2, 12),
            ("gpt-5.6-luna", 0.2, 0.02, 1.2),
            ("gpt-5.6-cyber", 12.5, 1.25, 75),
            ("gpt-5.5-cyber", 12.5, 1.25, 75),
            ("gpt-6-sol", 2, 0.2, 10),
            ("gpt-6-luna", 0.1, 0.01, 0.5),
            ("gpt-6.1-sol", 2, 0.1, 10),
            ("gpt-5.5-pro", 30, 30, 180),   // no cached rate: cached pays input
        ]
        for row in expected {
            guard let rates = T.rates(forKey: row.model, at: nil) else {
                XCTFail("\(row.model) has no row"); continue
            }
            let got = perMillion(rates)
            XCTAssertEqual(got.input, row.input, accuracy: 1e-9, "\(row.model) input")
            XCTAssertEqual(got.cached, row.cached, accuracy: 1e-9, "\(row.model) cached input")
            XCTAssertEqual(got.output, row.output, accuracy: 1e-9, "\(row.model) output")
        }
    }

    /// OpenAI's model pages for GPT-5.6 and GPT-6: cached input 10% of input
    /// (5% on gpt-6.1-sol), cache writes 1.25x, and above 272K "2x input and
    /// cache rates and 1.5x output for the full request". Pins every tiered
    /// row, including the dated ones, against a mistyped digit.
    func test_tieredRowsFollowOpenAIsDocumentedMultipliers() {
        var rows: [(String, T.Rates)] = []
        for model in ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
                      "gpt-6-sol", "gpt-6-luna", "gpt-6.1-sol"] {
            rows.append((model, T.current[model]!))
        }
        for (model, history) in T.superseded {
            for entry in history { rows.append(("\(model) before \(entry.until)", entry.rates)) }
        }
        XCTAssertEqual(rows.count, 10)
        for (name, r) in rows {
            let cachedShare = name == "gpt-6.1-sol" ? 0.05 : 0.1
            XCTAssertEqual(r.cachedInput ?? -1, r.input * cachedShare, accuracy: 1e-15, "\(name) cached")
            XCTAssertEqual(r.cacheWrite ?? -1, r.input * 1.25, accuracy: 1e-15, "\(name) cache write")
            XCTAssertEqual(r.longContextThreshold, 272_000, name)
            XCTAssertEqual(r.inputAboveThreshold ?? -1, r.input * 2, accuracy: 1e-15, "\(name) long input")
            XCTAssertEqual(r.cachedInputAboveThreshold ?? -1, (r.cachedInput ?? 0) * 2, accuracy: 1e-15, "\(name) long cached")
            XCTAssertEqual(r.cacheWriteAboveThreshold ?? -1, (r.cacheWrite ?? 0) * 2, accuracy: 1e-15, "\(name) long write")
            XCTAssertEqual(r.outputAboveThreshold ?? -1, r.output * 1.5, accuracy: 1e-15, "\(name) long output")
        }
    }

    // MARK: - Rates a model had before

    /// The instants are the ones OpenAI's changelog dates, at 00:00 UTC. A
    /// digit slipped in an epoch literal would move a repricing by days and
    /// every other test here would still pass against the wrong date.
    func test_repricingDatesAreTheOnesOpenAIPublished() {
        XCTAssertEqual(T.solRepricing, iso("2026-08-21T00:00:00Z"))
        XCTAssertEqual(T.terraLunaRepricing, iso("2026-07-30T00:00:00Z"))
    }

    func test_solChargesItsOldRateUntilTheSecondItWasRepriced() {
        let before = perMillion(T.rates(forKey: "gpt-5.6-sol", at: T.solRepricing.addingTimeInterval(-1))!)
        let at = perMillion(T.rates(forKey: "gpt-5.6-sol", at: T.solRepricing)!)
        XCTAssertEqual(before.input, 5, accuracy: 1e-9)
        XCTAssertEqual(before.output, 30, accuracy: 1e-9)
        XCTAssertEqual(at.input, 4, accuracy: 1e-9)
        XCTAssertEqual(at.output, 20, accuracy: 1e-9)
    }

    func test_terraChargesItsOldRateUntilJuly30() {
        let before = perMillion(T.rates(forKey: "gpt-5.6-terra", at: T.terraLunaRepricing.addingTimeInterval(-1))!)
        let at = perMillion(T.rates(forKey: "gpt-5.6-terra", at: T.terraLunaRepricing)!)
        XCTAssertEqual(before.input, 2.5, accuracy: 1e-9)
        XCTAssertEqual(before.output, 15, accuracy: 1e-9)
        XCTAssertEqual(at.input, 2, accuracy: 1e-9)
        XCTAssertEqual(at.output, 12, accuracy: 1e-9)
    }

    /// Luna's July cut was 80%: before it, five times today's rate.
    func test_lunaChargesItsOldRateUntilJuly30() {
        let before = perMillion(T.rates(forKey: "gpt-5.6-luna", at: T.terraLunaRepricing.addingTimeInterval(-1))!)
        let at = perMillion(T.rates(forKey: "gpt-5.6-luna", at: T.terraLunaRepricing)!)
        XCTAssertEqual(before.input, 1, accuracy: 1e-9)
        XCTAssertEqual(before.output, 6, accuracy: 1e-9)
        XCTAssertEqual(at.input, 0.2, accuracy: 1e-9)
        XCTAssertEqual(at.output, 1.2, accuracy: 1e-9)
    }

    /// No date is today's rate, and a model with no history ignores the date.
    func test_noDateMeansTodaysRate() {
        XCTAssertEqual(T.rates(forKey: "gpt-5.6-sol", at: nil), T.current["gpt-5.6-sol"])
        XCTAssertEqual(T.rates(forKey: "gpt-6-astra", at: iso("2026-01-01T00:00:00Z")), T.current["gpt-6-astra"])
        XCTAssertNil(T.rates(forKey: "gpt-5.6", at: nil), "an alias is not a row")
    }

    /// `rates(forKey:at:)` is only ever asked about a key that has a row
    /// today, so a model's history is read only if the model has one.
    func test_everyModelWithEarlierRatesHasARowToday() {
        XCTAssertFalse(T.superseded.isEmpty)
        for model in T.superseded.keys {
            XCTAssertNotNil(T.current[model], "\(model) has earlier rates and no row today")
        }
    }

    /// The lookup takes the first entry the moment is before, so a model's
    /// earlier rates must run oldest first. Out of order, a date before the
    /// older cut would be charged the newer of the two old rates.
    func test_eachModelsEarlierRatesRunOldestFirst() {
        for (model, history) in T.superseded {
            XCTAssertFalse(history.isEmpty, model)
            let untils = history.map(\.until)
            XCTAssertEqual(untils, untils.sorted(), "\(model): earlier rates out of order")
            XCTAssertEqual(Set(untils).count, untils.count, "\(model): two entries end at the same instant")
        }
    }

    // MARK: - Long context

    /// "Prompts with more than 272K input tokens are priced at 2x input and
    /// cache rates and 1.5x output for the full request." 272,000 is still
    /// short context; 272,001 moves every token, not only the excess.
    func test_aLongRequestPaysLongContextRatesOnTheWholeRequest() {
        let sol = T.current["gpt-5.6-sol"]!
        let short = T.requestCostUSD(rates: sol, inputTokens: 272_000, cachedInputTokens: 0, outputTokens: 1_000)
        let long = T.requestCostUSD(rates: sol, inputTokens: 272_001, cachedInputTokens: 0, outputTokens: 1_000)
        XCTAssertEqual(short, 272_000 * 4e-6 + 1_000 * 2e-5, accuracy: 1e-12)
        XCTAssertEqual(long, 272_001 * 8e-6 + 1_000 * 3e-5, accuracy: 1e-12)
    }

    /// A day's total is many requests. Taking the tier on a sum would put every
    /// busy day on long-context rates.
    func test_aSumNeverTakesTheLongContextTier() {
        let sol = T.current["gpt-5.6-sol"]!
        let day = T.aggregateCostUSD(rates: sol, inputTokens: 50_000_000, cachedInputTokens: 0, outputTokens: 0)
        XCTAssertEqual(day, 200, accuracy: 1e-9, "50M input at $4, not $8")
    }

    /// Cached reads are a subset of input and cache writes a subset of the
    /// rest (upstream's clamp): nothing is charged twice or invented.
    func test_cachedAndCacheWriteTokensAreClampedInsideInput() {
        let astra = T.current["gpt-6-astra"]!
        let cost = T.requestCostUSD(rates: astra, inputTokens: 100, cachedInputTokens: 60,
                                    cacheWriteInputTokens: 80, outputTokens: -5)
        // 60 cached, 40 cache-write (clamped from 80), 0 uncached, 0 output.
        XCTAssertEqual(cost, 60 * 1e-6 + 40 * 1.25e-5, accuracy: 1e-15)
    }

    // MARK: - Aliases

    /// An alias names a row that exists and is not itself a row: otherwise the
    /// alias would never be consulted, or would point at nothing and read $0.
    func test_everyAliasPointsAtARow() {
        XCTAssertFalse(T.aliases.isEmpty)
        for (alias, target) in T.aliases {
            XCTAssertNotNil(T.current[target], "\(alias) → \(target), which has no row")
            XCTAssertNil(T.current[alias], "\(alias) is both an alias and a row")
        }
    }

    /// A dated spelling of an alias is the same alias. `normalizeCodexModel`
    /// only drops a date when the rest names a row, and an alias is not one.
    func test_aDatedSpellingOfAnAliasIsTheAlias() {
        XCTAssertEqual(T.aliasTarget("gpt-5.6"), "gpt-5.6-sol")
        XCTAssertEqual(T.aliasTarget("gpt-5.6-2026-08-01"), "gpt-5.6-sol")
        XCTAssertEqual(T.aliasTarget("gpt-reserve-2026-09-15"), "gpt-5.6-luna")
        XCTAssertNil(T.aliasTarget("gpt-5.6-sol"), "a row is not an alias")
        XCTAssertNil(T.aliasTarget("gpt-5.6-20260801"), "only a -YYYY-MM-DD suffix is a date")
    }

    #if os(macOS)

    private typealias P = CostUsageScanner.Pricing

    // MARK: - Exact, alias or borrowed

    func test_aListedModelIsChargedItsOwnRate() {
        for model in ["gpt-6-astra", "gpt-5.6-sol", "openai/gpt-5.6-sol", "gpt-5.3-codex-spark"] {
            XCTAssertEqual(P.codexPriceResolution(model)?.isApproximate, false, model)
        }
        XCTAssertEqual(P.claudePriceResolution("claude-opus-5"),
                       P.PriceResolution(key: "claude-opus-5", isApproximate: false))
    }

    /// An alias is OpenAI billing one name as another model: an exact price,
    /// and the name Codex wrote stays the name shown (upstream renames it;
    /// here the stored cache key would change and split the model's history).
    func test_anAliasIsAnExactPriceAndKeepsItsName() {
        XCTAssertEqual(P.codexPriceResolution("gpt-5.6"),
                       P.PriceResolution(key: "gpt-5.6-sol", isApproximate: false))
        XCTAssertEqual(P.codexPriceResolution("gpt-daybreak-red-latest"),
                       P.PriceResolution(key: "gpt-5.6-cyber", isApproximate: false))
        XCTAssertEqual(P.codexPriceResolution("gpt-reserve")?.key, "gpt-5.6-luna")
        XCTAssertEqual(P.normalizeCodexModel("gpt-5.6"), "gpt-5.6")
        XCTAssertEqual(P.normalizeCodexModel("gpt-reserve"), "gpt-reserve")
    }

    /// A dated alias is the alias's exact price. Without the date dropped,
    /// `gpt-5.6-2026-08-01` borrowed Sol's rate through the version fallback
    /// (the right number, marked "≈") and `gpt-reserve-…` had no rate at all.
    func test_aDatedAliasIsAnExactPriceAndKeepsItsName() {
        XCTAssertEqual(P.codexPriceResolution("gpt-5.6-2026-08-01"),
                       P.PriceResolution(key: "gpt-5.6-sol", isApproximate: false))
        XCTAssertEqual(P.codexPriceResolution("gpt-reserve-2026-09-15"),
                       P.PriceResolution(key: "gpt-5.6-luna", isApproximate: false))
        XCTAssertEqual(P.normalizeCodexModel("gpt-5.6-2026-08-01"), "gpt-5.6-2026-08-01",
                       "the stored name stays the one Codex wrote")
    }

    /// A model with no row of its own borrows the closest one and says so.
    /// Both fallbacks, Codex's by version and Claude's by family.
    func test_aBorrowedRateIsMarkedApproximate() {
        XCTAssertEqual(P.codexPriceResolution("gpt-5.7"),
                       P.PriceResolution(key: "gpt-5.6-sol", isApproximate: true))
        XCTAssertEqual(P.codexPriceResolution("gpt-6.2"),
                       P.PriceResolution(key: "gpt-6.1-sol", isApproximate: true))
        XCTAssertEqual(P.claudePriceResolution("claude-opus-6"),
                       P.PriceResolution(key: "claude-opus-5", isApproximate: true))
        XCTAssertNil(P.codexPriceResolution("o3"), "no neighbour, no rate")
    }

    // MARK: - Which day a day's usage is priced as

    /// A repricing at 00:00 UTC falls partway through a local day; the whole
    /// day takes the rate in force for most of it. 00:00 UTC on 08-21 is 09:00
    /// in Tokyo (15 of Tokyo's 24 hours on 08-21 are after it) and 17:00 on
    /// 08-20 in Los Angeles (17 of LA's hours on 08-20 are before it).
    func test_aDayIsChargedTheRateInForceForMostOfIt() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        func day(_ key: String, _ zone: TimeZone) throws -> Date {
            try XCTUnwrap(P.codexPricingDate(forDayKey: key, in: zone))
        }
        XCTAssertLessThan(try day("2026-08-20", tokyo), T.solRepricing)
        XCTAssertGreaterThanOrEqual(try day("2026-08-21", tokyo), T.solRepricing)
        XCTAssertLessThan(try day("2026-08-20", la), T.solRepricing)
        XCTAssertGreaterThanOrEqual(try day("2026-08-21", la), T.solRepricing)
        XCTAssertNil(P.codexPricingDate(forDayKey: "2026-02-30"))
    }

    func test_codexCostUsesTheRateOfTheDateItIsGiven() {
        let before = P.codexCostUSD(model: "gpt-5.6-sol", inputTokens: million, cachedInputTokens: 0,
                                    outputTokens: 0, pricingDate: iso("2026-08-20T12:00:00Z"))
        let after = P.codexCostUSD(model: "gpt-5.6-sol", inputTokens: million, cachedInputTokens: 0,
                                   outputTokens: 0, pricingDate: iso("2026-08-21T12:00:00Z"))
        XCTAssertEqual(before ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(after ?? -1, 4, accuracy: 1e-9)
        // The alias follows its target's history.
        let aliasBefore = P.codexCostUSD(model: "gpt-5.6", inputTokens: million, cachedInputTokens: 0,
                                         outputTokens: 0, pricingDate: iso("2026-08-20T12:00:00Z"))
        XCTAssertEqual(aliasBefore ?? -1, 5, accuracy: 1e-9)
    }

    // MARK: - Through the scanner

    private var tmpRoot: URL?

    override func tearDownWithError() throws {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        tmpRoot = nil
    }

    /// One Codex session in the flat sessions root (no date in the name, so
    /// the walk picks it up whatever the window), one request at `at`.
    private func writeSession(_ id: String, model: String, at: Date, input: Int,
                              in root: URL) throws {
        let ts = ISO8601DateFormatter().string(from: at)
        let lines = [
            #"{"type":"session_meta","timestamp":"\#(ts)","payload":{"session_id":"\#(id)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(ts)","payload":{"model":"\#(model)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(ts)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":0}}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: root.appendingPathComponent("rollout-\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    /// Scans `sessions` with a window reaching back past July 2026.
    private func scan(_ sessions: URL, cache: URL) -> [CostUsageScanResult.DailyEntry] {
        let daysSinceJuly = Int(Date().timeIntervalSince(iso("2026-07-01T00:00:00Z")) / 86_400) + 3
        var options = CostUsageScanner.Options(codexSessionsRoot: sessions, claudeProjectsRoots: [],
                                               cacheRoot: cache, daysToScan: max(daysSinceJuly, 30))
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        return CostUsageScanner.scan(options: options).entries
            .filter { $0.provider == "Codex" }
            .sorted { $0.date < $1.date }
    }

    private func makeRoots() throws -> (sessions: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pricing-\(UUID().uuidString)", isDirectory: true)
        tmpRoot = root
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return (sessions, root.appendingPathComponent("cache", isDirectory: true))
    }

    /// End to end: the same 1M Sol tokens two days either side of the cut cost
    /// $5 and $4, and Luna either side of July 30 costs $1 and $0.20. Two days
    /// is past any time zone's noon, so this holds wherever it runs.
    func test_aScannedDayIsChargedTheRateInForceThatDay() throws {
        let (sessions, cache) = try makeRoots()
        let twoDays: TimeInterval = 2 * 86_400
        try writeSession("sol-before", model: "gpt-5.6-sol", at: T.solRepricing - twoDays, input: million, in: sessions)
        try writeSession("sol-after", model: "gpt-5.6-sol", at: T.solRepricing + twoDays, input: million, in: sessions)
        try writeSession("luna-before", model: "gpt-5.6-luna", at: T.terraLunaRepricing - twoDays, input: million, in: sessions)
        try writeSession("luna-after", model: "gpt-5.6-luna", at: T.terraLunaRepricing + twoDays, input: million, in: sessions)

        let entries = scan(sessions, cache: cache)
        func cost(_ model: String) -> [Double] {
            entries.filter { $0.model == model }.map { $0.costUSD ?? -1 }
        }
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(cost("gpt-5.6-sol").count, 2)
        XCTAssertEqual(cost("gpt-5.6-sol")[0], 5, accuracy: 1e-9, "Sol before 08-21")
        XCTAssertEqual(cost("gpt-5.6-sol")[1], 4, accuracy: 1e-9, "Sol after 08-21")
        XCTAssertEqual(cost("gpt-5.6-luna").count, 2)
        XCTAssertEqual(cost("gpt-5.6-luna")[0], 1, accuracy: 1e-9, "Luna before 07-30")
        XCTAssertEqual(cost("gpt-5.6-luna")[1], 0.2, accuracy: 1e-9, "Luna after 07-30")
        XCTAssertFalse(entries.contains { $0.priceIsApproximate }, "every one of these has its own row")
    }

    /// End to end: a model with no row is priced at its neighbour's rate, the
    /// entry says so, and so do the coverage and the badge built from it.
    func test_aScannedModelWithNoRowIsPricedApproximatelyAndSaysSo() throws {
        let (sessions, cache) = try makeRoots()
        try writeSession("known", model: "gpt-6-astra", at: Date(), input: million, in: sessions)
        try writeSession("unknown", model: "gpt-5.7", at: Date(), input: million, in: sessions)

        let entries = scan(sessions, cache: cache)
        let unknown = try XCTUnwrap(entries.first { $0.model == "gpt-5.7" }, "keeps the name Codex wrote")
        let known = try XCTUnwrap(entries.first { $0.model == "gpt-6-astra" })
        XCTAssertTrue(unknown.priceIsApproximate)
        XCTAssertEqual(unknown.costUSD ?? -1, 4, accuracy: 1e-9, "Sol's rate today")
        XCTAssertFalse(known.priceIsApproximate)
        XCTAssertEqual(known.costUSD ?? -1, 10, accuracy: 1e-9)

        let coverage = CostCoverage.from(entries: entries)
        XCTAssertEqual(coverage.approximateModels, ["gpt-5.7"])
        XCTAssertEqual(coverage.approximateProviders, ["Codex"])
        XCTAssertEqual(CostSummary(isPrecise: true, coverage: coverage).fidelity, .approximate)
    }

    /// The Claude half of the same path: a model with no row borrows the
    /// newest rate in its family at or below its version, and the entry the
    /// scanner rebuilds from its cache says so. Without this test,
    /// `entriesFromClaudeCache` could stop passing the flag and every other
    /// test would stay green.
    func test_aScannedClaudeModelWithNoRowIsPricedApproximatelyAndSaysSo() throws {
        let (sessions, cache) = try makeRoots()
        let projects = sessions.deletingLastPathComponent().appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("-Users-stub-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86_400))
        func line(_ id: String, _ model: String) -> String {
            #"{"type":"assistant","timestamp":"\#(ts)","requestId":"req-\#(id)","message":{"id":"msg-\#(id)","model":"\#(model)","usage":{"input_tokens":1000000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}"#
        }
        try ([line("1", "claude-opus-6"), line("2", "claude-opus-5")].joined(separator: "\n") + "\n")
            .write(to: project.appendingPathComponent("synthetic.jsonl"), atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(codexSessionsRoot: sessions, claudeProjectsRoots: [projects],
                                               cacheRoot: cache, daysToScan: 30)
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        let entries = CostUsageScanner.scan(options: options).entries.filter { $0.provider == "Claude" }

        let unknown = try XCTUnwrap(entries.first { $0.model == "claude-opus-6" }, "keeps the name Claude Code wrote")
        let known = try XCTUnwrap(entries.first { $0.model == "claude-opus-5" })
        XCTAssertTrue(unknown.priceIsApproximate)
        XCTAssertEqual(unknown.costUSD ?? -1, 5, accuracy: 1e-9, "Opus 5's $5 per 1M input")
        XCTAssertFalse(known.priceIsApproximate)
        XCTAssertEqual(known.costUSD ?? -1, 5, accuracy: 1e-9)

        let coverage = CostCoverage.from(entries: entries)
        XCTAssertEqual(coverage.approximateModels, ["claude-opus-6"])
        XCTAssertEqual(coverage.approximateProviders, ["Claude"])
    }

    /// Codex day rows hold tokens only, `[input, cached, output]`, and are
    /// priced on every read. That is why a change to this table needs no
    /// `costUsageCachePricingVersion` bump. The day a Codex row starts storing
    /// a cost (per-request pricing), this fails: from then on a Codex price
    /// change must bump the version, or cached days keep the old price.
    func test_codexCacheRowsCarryNoCost() throws {
        let (sessions, cache) = try makeRoots()
        try writeSession("row", model: "gpt-5.6-sol", at: Date(), input: 1_000, in: sessions)
        _ = scan(sessions, cache: cache)
        let saved = CostUsageCacheIO.load(provider: "codex", cacheRoot: cache)
        XCTAssertFalse(saved.days.isEmpty, "the fixture must reach the cache, or this checks nothing")
        for (day, models) in saved.days {
            for (model, packed) in models {
                XCTAssertEqual(packed.count, 3, "\(day) \(model): a Codex row now stores more than tokens")
            }
        }
    }

    #endif
}

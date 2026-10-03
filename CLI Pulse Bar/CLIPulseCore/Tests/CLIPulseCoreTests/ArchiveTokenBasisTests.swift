import XCTest
@testable import CLIPulseCore

/// The usage history counts every token once.
///
/// A day's tokens are `input + cached + output`. Claude's `input` leaves cache
/// out, so that is each token once. Codex's `input` already includes its
/// cached input (OpenAI's `input_tokens` does), so the same sum counted Codex's
/// cached input twice, on the Mac's archive and on the iPhone's. Cached input
/// is most of a Codex day, so Codex totals in the history read close to double.
///
/// Every fixture here has cached input, and each test first shows what the old
/// field-by-field copy gave, so none of them can pass without the fix doing
/// something.
final class ArchiveTokenBasisTests: XCTestCase {

    private let day = "2026-09-20"

    private func scanned(_ provider: String, _ model: String,
                         input: Int, cached: Int, output: Int, cost: Double? = 1.25) -> CostUsageScanResult.DailyEntry {
        .init(date: day, provider: provider, model: model,
              inputTokens: input, cachedTokens: cached, outputTokens: output,
              costUSD: cost, messageCount: 0)
    }

    private func fetched(_ date: String, _ provider: String, _ model: String,
                         input: Int, cached: Int, output: Int, cost: Double = 1.25) -> DailyUsage {
        DailyUsage(date: date, provider: provider, model: model,
                   inputTokens: input, cachedTokens: cached, outputTokens: output, cost: cost)
    }

    /// The old adapter: every field copied as it came.
    private func copiedAsItCame(_ e: CostUsageScanResult.DailyEntry) -> ScanEntry {
        ScanEntry(date: e.date, provider: e.provider, model: e.model,
                  inputTokens: e.inputTokens, cachedTokens: e.cachedTokens,
                  outputTokens: e.outputTokens, cost: e.costUSD ?? 0, messages: e.messageCount)
    }

    // MARK: - The Mac's scan

    func testCodexScanRowCountsCachedInputOnce() throws {
        // 1,000 input of which 800 came from cache, 50 output: 1,050 tokens.
        let row = scanned("Codex", "gpt-5.5", input: 1_000, cached: 800, output: 50)

        var old = DailyUsageArchive()
        old.mergeScanEntries([copiedAsItCame(row)])
        XCTAssertEqual(old.days[day]?.tokens, 1_850, "control: the fixture must show the double count")

        var archive = DailyUsageArchive()
        archive.mergeScanEntries([ScanEntry(archiving: row)])
        let rollup = try XCTUnwrap(archive.days[day])
        XCTAssertEqual(rollup.tokens, 1_050, "input already holds the cached 800")
        XCTAssertEqual(rollup.perProvider["Codex"]?.tokens, 1_050)
        XCTAssertEqual(rollup.perModel["gpt-5.5"]?.tokens, 1_050)
        XCTAssertEqual(rollup.cost, 1.25, accuracy: 1e-9, "cost is priced elsewhere and must not move")
    }

    func testClaudeScanRowIsUnchanged() throws {
        // Claude's input excludes cache: 100 input + 900 cache + 50 output.
        let row = scanned("Claude", "claude-sonnet-5", input: 100, cached: 900, output: 50)

        var archive = DailyUsageArchive()
        archive.mergeScanEntries([ScanEntry(archiving: row)])
        XCTAssertEqual(archive.days[day]?.tokens, 1_050)

        var old = DailyUsageArchive()
        old.mergeScanEntries([copiedAsItCame(row)])
        XCTAssertEqual(archive, old, "Claude was right before and must stay byte for byte the same")
    }

    func testTheSplitIsKeptSoTheSumIsTheOnlyChange() {
        let e = ScanEntry(archiving: scanned("Codex", "gpt-5.5", input: 1_000, cached: 800, output: 50))
        XCTAssertEqual(e.inputTokens, 200, "the uncached part of Codex's input")
        XCTAssertEqual(e.cachedTokens, 800)
        XCTAssertEqual(e.outputTokens, 50)
        XCTAssertEqual(e.messages, 0)
    }

    /// Both writers clamp cached to input, but a row that did not must not
    /// add tokens nobody used, and a negative field must not subtract any.
    func testMalformedCodexRowsNeverAddTokens() {
        let over = ScanEntry(archiving: scanned("Codex", "gpt-5.5", input: 100, cached: 400, output: 10))
        XCTAssertEqual(over.inputTokens + over.cachedTokens + over.outputTokens, 110)

        let negative = ScanEntry(archiving: scanned("Codex", "gpt-5.5", input: -5, cached: -7, output: 3))
        XCTAssertEqual(negative.inputTokens, 0)
        XCTAssertEqual(negative.cachedTokens, 0)
    }

    // MARK: - Cloud rows (the Mac's fill and the iPhone's rebuild)

    func testCodexCloudRowCountsCachedInputOnceAndClaudeIsUnchanged() {
        var archive = DailyUsageArchive()
        archive.mergeCloudDays([
            CloudEntry(archiving: fetched(day, "Codex", "gpt-5.5", input: 1_000, cached: 800, output: 50)),
            CloudEntry(archiving: fetched(day, "Claude", "claude-sonnet-5", input: 100, cached: 900, output: 50)),
        ])
        XCTAssertEqual(archive.days[day]?.perProvider["Codex"]?.tokens, 1_050)
        XCTAssertEqual(archive.days[day]?.perProvider["Claude"]?.tokens, 1_050)
        XCTAssertEqual(archive.days[day]?.tokens, 2_100)
    }

    /// The iPhone rebuilds its year from the server's rows on every refresh.
    /// The rows keep the split, so old days are corrected too, not only new
    /// ones.
    func testIPhoneArchiveCountsEachCodexTokenOnceOnEveryDay() {
        let rows = [
            fetched("2025-11-03", "Codex", "gpt-5", input: 4_000, cached: 3_000, output: 100),
            fetched("2026-09-20", "Codex", "gpt-5.5", input: 1_000, cached: 800, output: 50),
            fetched("2026-09-20", "Claude", "claude-sonnet-5", input: 100, cached: 900, output: 50),
            fetched("2026-09-20", "Claude", ScanEntry.messageBucketModel, input: 0, cached: 0, output: 0, cost: 0),
        ]
        let archive = AppState.usageArchive(fromCloudRows: rows)
        XCTAssertEqual(archive.days["2025-11-03"]?.tokens, 4_100, "a day from last year, corrected as well")
        XCTAssertEqual(archive.days["2026-09-20"]?.perProvider["Codex"]?.tokens, 1_050)
        XCTAssertEqual(archive.days["2026-09-20"]?.perProvider["Claude"]?.tokens, 1_050)
        XCTAssertNil(archive.days["2026-09-20"]?.perModel[ScanEntry.messageBucketModel])
        XCTAssertEqual(DailyUsageStats.totalTokens(archive), 4_100 + 2_100)
    }

    // MARK: - The archive's version

    /// Loading an archive whose version differs returns an empty one, which
    /// drops a year of history without a word. Counting each token once must
    /// not be done by bumping it: the adapters change, the stored shape does
    /// not.
    func testTheArchiveVersionIsNotBumped() throws {
        XCTAssertEqual(DailyUsageArchive.currentVersion, 1,
                       "a new version empties every user's history on load")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("basis-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var written = DailyUsageArchive()
        written.mergeScanEntries([copiedAsItCame(scanned("Codex", "gpt-5", input: 1_000, cached: 800, output: 50))])
        XCTAssertTrue(DailyUsageArchiveIO.save(written, root: root))
        XCTAssertEqual(DailyUsageArchiveIO.load(root: root).days[day]?.tokens, 1_850,
                       "a day recorded before the change is kept as it was, not dropped")
    }

    // MARK: - The cost-coverage share

    /// "Priced N% of tokens" weighs each token once too. A priced Codex row of
    /// 1,000 input (800 of it cached) and 50 output is 1,050 tokens; beside an
    /// unpriced 1,050-token row that is half. Adding the cached 800 again made
    /// it 63%.
    func testCoverageCountsCodexCachedInputOnce() {
        let codex = scanned("Codex", "gpt-5.5", input: 1_000, cached: 800, output: 50)
        let unpriced = CostUsageScanResult.DailyEntry(
            date: day, provider: "Claude", model: "claude-next",
            inputTokens: 1_050, cachedTokens: 0, outputTokens: 0, costUSD: nil)
        let oldPriced = codex.inputTokens + codex.cachedTokens + codex.outputTokens
        XCTAssertEqual(Int((Double(oldPriced) / Double(oldPriced + 1_050) * 100).rounded(.down)), 63,
                       "control: the old sum gives a different share")

        let coverage = CostCoverage.from(entries: [codex, unpriced])
        XCTAssertEqual(coverage.pricedTokens, 1_050)
        XCTAssertEqual(coverage.unpricedTokens, 1_050)
        XCTAssertEqual(coverage.pricedPercent, 50)
    }

    func testClaudeCoverageIsUnchanged() {
        let claude = scanned("Claude", "claude-sonnet-5", input: 100, cached: 900, output: 50)
        XCTAssertEqual(CostCoverage.from(entries: [claude]).pricedTokens, 1_050,
                       "Claude's input leaves cache out, so all three add up")
    }

    #if os(macOS)
    /// The scanner's log line and the coverage share must agree about a scan.
    func testTheUnpricedLogLineCountsCodexCachedInputOnce() throws {
        var lines: [String] = []
        CostUsageScanner.reportUnpricedModels(
            [scanned("Codex", "gpt-next", input: 1_000, cached: 800, output: 50, cost: nil)],
            log: { lines.append($0) })
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("gpt-next=1050"), line)
        XCTAssertFalse(line.contains("1850"), line)
    }
    #endif

    // MARK: - The Mac's archive manager

    #if os(macOS)
    func testTheMacRecordsScansAndCloudFillEachTokenOnce() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("basis-mgr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "basis-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DailyUsageArchiveManager(root: root, defaults: defaults)

        await manager.record(CostUsageScanResult(entries: [
            scanned("Codex", "gpt-5.5", input: 1_000, cached: 800, output: 50),
        ]))
        await manager.mergeCloud([
            fetched("2026-08-02", "Codex", "gpt-5.5", input: 2_000, cached: 1_500, output: 20),
        ])

        let archive = await manager.snapshot()
        XCTAssertEqual(archive.days[day]?.tokens, 1_050, "the scan")
        XCTAssertEqual(archive.days["2026-08-02"]?.tokens, 2_020, "the cloud fill")
    }
    #endif
}

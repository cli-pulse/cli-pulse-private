// v1.55: the year-long read merges provider by provider.
//
// Consent v2 lets a user pick "Last 30 days only" and allow older history
// later. The year-long read then meets an archive that already holds months of
// days. Claude Code deletes transcripts after 30 days by default while Codex
// keeps its logs, so an older day comes back from the read with Codex alone.
// `mergeScanEntries` replaces whole days, which erased Claude's share of every
// such day from the heatmap and the lifetime totals (and Codex's share where
// Codex logs were deleted). `mergeScanEntriesByProvider` keeps a provider the
// read did not find, and still takes the read's figures for a provider it did.
//
// Pure and cross-platform; the manager's wiring is tested in
// DailyUsageArchiveManagerTests.

import XCTest
@testable import CLIPulseCore

final class DailyUsageArchiveByProviderMergeTests: XCTestCase {

    private func se(_ date: String, _ provider: String, _ model: String,
                    input: Int = 0, output: Int = 0, cost: Double = 0, msgs: Int = 0) -> ScanEntry {
        ScanEntry(date: date, provider: provider, model: model,
                  inputTokens: input, cachedTokens: 0, outputTokens: output,
                  cost: cost, messages: msgs)
    }

    private let day = "2026-05-04"

    private func claude(_ date: String) -> [ScanEntry] {
        [se(date, "Claude", "claude-sonnet-4-5", input: 100, output: 50, cost: 0.30),
         se(date, "Claude", ScanEntry.messageBucketModel, msgs: 7)]
    }

    private func codex(_ date: String, input: Int = 200, output: Int = 20, cost: Double = 0.10) -> [ScanEntry] {
        [se(date, "Codex", "gpt-5", input: input, output: output, cost: cost)]
    }

    private let claudeSlice = ProviderDaySlice(tokens: 150, cost: 0.30, messages: 7)
    private let codexSlice = ProviderDaySlice(tokens: 220, cost: 0.10, messages: 0)

    /// A day both providers wrote, as the routine 30-day read stored it.
    private func storedBoth() -> DailyUsageArchive {
        var a = DailyUsageArchive()
        a.mergeScanEntries(claude(day) + codex(day))
        return a
    }

    // MARK: - A provider the read did not find

    func test_a_read_that_finds_only_codex_keeps_the_claude_slice() {
        var a = storedBoth()
        a.mergeScanEntriesByProvider(codex(day))

        let d = a.days[day]
        XCTAssertEqual(d?.perProvider["Claude"], claudeSlice, "Claude's share of the day was dropped")
        XCTAssertEqual(d?.perModel["claude-sonnet-4-5"], ModelDaySlice(tokens: 150, cost: 0.30))
        XCTAssertEqual(d?.perProvider["Codex"], codexSlice)
        XCTAssertEqual(d?.tokens, 370)
        XCTAssertEqual(d?.messages, 7, "Claude's messages went with its transcripts")
        XCTAssertEqual(d?.cost ?? 0, 0.40, accuracy: 0.0001)
    }

    func test_a_read_that_finds_only_claude_keeps_the_codex_slice() {
        var a = storedBoth()
        a.mergeScanEntriesByProvider(claude(day))

        let d = a.days[day]
        XCTAssertEqual(d?.perProvider["Codex"], codexSlice, "Codex's share of the day was dropped")
        XCTAssertEqual(d?.perModel["gpt-5"], ModelDaySlice(tokens: 220, cost: 0.10))
        XCTAssertEqual(d?.perProvider["Claude"], claudeSlice)
        XCTAssertEqual(d?.tokens, 370)
        XCTAssertEqual(d?.messages, 7)
        XCTAssertEqual(d?.cost ?? 0, 0.40, accuracy: 0.0001)
    }

    // MARK: - A provider the read found again

    /// Not a "never replace" rule: what the read did find, it counts anew.
    func test_a_provider_the_read_found_again_takes_the_new_figures() {
        var a = storedBoth()
        a.mergeScanEntriesByProvider(codex(day, input: 300, output: 30, cost: 0.15))

        let d = a.days[day]
        XCTAssertEqual(d?.perProvider["Codex"], ProviderDaySlice(tokens: 330, cost: 0.15, messages: 0))
        XCTAssertEqual(d?.perModel["gpt-5"], ModelDaySlice(tokens: 330, cost: 0.15))
        XCTAssertEqual(d?.perProvider["Claude"], claudeSlice)
        XCTAssertEqual(d?.tokens, 150 + 330)
        XCTAssertEqual(d?.cost ?? 0, 0.45, accuracy: 0.0001)
    }

    /// Where the read found every provider the day holds, the rule is the
    /// whole-day rule, down to a model it no longer reports.
    func test_a_day_the_read_covers_completely_is_replaced_as_a_whole() {
        var stored = DailyUsageArchive()
        stored.mergeScanEntries(claude(day) + codex(day) + [se(day, "Codex", "o3", input: 5, cost: 0.01)])
        let read = claude(day) + codex(day, input: 300)

        var byProvider = stored
        byProvider.mergeScanEntriesByProvider(read)
        var wholeDay = stored
        wholeDay.mergeScanEntries(read)

        XCTAssertEqual(byProvider, wholeDay)
        XCTAssertNil(byProvider.days[day]?.perModel["o3"])
    }

    /// A stored day does not say which provider a model is from. On a day that
    /// keeps a provider, the models the read did not report stay with it.
    func test_a_kept_provider_keeps_its_models() {
        var a = DailyUsageArchive()
        a.mergeScanEntries(claude(day) + codex(day) + [se(day, "Claude", "claude-opus-4-1", input: 10, cost: 0.2)])
        a.mergeScanEntriesByProvider(codex(day, input: 300))

        let models = a.days[day]?.perModel
        XCTAssertEqual(models?["claude-sonnet-4-5"], ModelDaySlice(tokens: 150, cost: 0.30))
        XCTAssertEqual(models?["claude-opus-4-1"], ModelDaySlice(tokens: 10, cost: 0.2))
        XCTAssertEqual(models?["gpt-5"]?.tokens, 320)
    }

    // MARK: - Lifetime totals

    /// Over an archive with a month tier and three kinds of day, the totals
    /// move by exactly what the read found again and nothing else.
    func test_lifetime_totals_change_only_by_the_providers_the_read_found() {
        let both = "2026-04-01", claudeOnly = "2026-04-02", codexOnly = "2026-04-03"
        var a = DailyUsageArchive(months: ["2025-03": MonthRollup(tokens: 1_000, cost: 10, messages: 5)],
                                  foldedThroughDay: "2025-03-31")
        a.mergeScanEntries(claude(both) + codex(both) + claude(claudeOnly) + codex(codexOnly))
        let before = a

        // Claude's transcripts for all three days are gone; Codex's logs are
        // read again, one with a new figure.
        a.mergeScanEntriesByProvider(codex(both, input: 300) + codex(codexOnly))

        func claudeRow(_ x: DailyUsageArchive) -> DailyUsageStats.Breakdown? {
            DailyUsageStats.byProvider(x).first { $0.key == "Claude" }
        }
        XCTAssertEqual(claudeRow(a), claudeRow(before), "Claude's lifetime share moved")
        XCTAssertEqual(DailyUsageStats.totalTokens(a) - DailyUsageStats.totalTokens(before), 100)
        XCTAssertEqual(DailyUsageStats.totalMessages(a), DailyUsageStats.totalMessages(before))
        XCTAssertEqual(DailyUsageStats.totalCost(a), DailyUsageStats.totalCost(before), accuracy: 0.0001)
        XCTAssertEqual(a.days[claudeOnly], before.days[claudeOnly], "a day the read found nothing on changed")
        XCTAssertEqual(a.months, before.months)
        XCTAssertEqual(a.foldedThroughDay, before.foldedThroughDay)
    }

    // MARK: - Negative control

    /// The whole-day rule, which the routine read still uses, loses Claude's
    /// share on the same input. So the fixture above can tell the two rules
    /// apart, and a backfill wired back to `mergeScanEntries` shows up.
    func test_negative_control_the_whole_day_rule_drops_the_slice_on_the_same_input() {
        var a = storedBoth()
        a.mergeScanEntries(codex(day))

        XCTAssertNil(a.days[day]?.perProvider["Claude"])
        XCTAssertEqual(a.days[day]?.tokens, 220)
        XCTAssertEqual(DailyUsageStats.totalMessages(a), 0)
    }

    // MARK: - Days the archive does not hold, or has folded

    func test_a_day_absent_from_the_archive_is_written_as_read() {
        var a = storedBoth()
        a.mergeScanEntriesByProvider(codex("2025-11-02"))
        XCTAssertEqual(a.days["2025-11-02"]?.perProvider, ["Codex": codexSlice])
        XCTAssertEqual(a.days[day]?.perProvider["Claude"], claudeSlice)
    }

    func test_a_folded_day_is_not_reintroduced() {
        var a = DailyUsageArchive(months: ["2025-03": MonthRollup(tokens: 1_000, cost: 10, messages: 5)],
                                  foldedThroughDay: "2025-03-31")
        a.mergeScanEntriesByProvider(codex("2025-03-15"))
        XCTAssertNil(a.days["2025-03-15"])
        XCTAssertEqual(a.months["2025-03"], MonthRollup(tokens: 1_000, cost: 10, messages: 5))
    }

    // MARK: - Day keys written in another calendar (#589)

    /// The read and the archive meet by day key. A day an older version
    /// stored under the Japanese calendar is converted on load, so the read's
    /// Codex lands on that day, next to the Claude share it keeps, and not on
    /// a second copy of it.
    func test_a_day_stored_under_the_japanese_calendar_is_the_day_the_read_merges_into() {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let stored = storedBoth().days[day]!
        var a = DailyUsageArchive(days: ["0008-09-15": stored]).normalizingDayKeys(writtenIn: japanese)
        XCTAssertEqual(Array(a.days.keys), ["2026-09-15"])

        a.mergeScanEntriesByProvider(codex("2026-09-15", input: 300))

        XCTAssertEqual(a.days.keys.sorted(), ["2026-09-15"])
        XCTAssertEqual(a.days["2026-09-15"]?.perProvider["Claude"], claudeSlice)
        XCTAssertEqual(a.days["2026-09-15"]?.perProvider["Codex"]?.tokens, 320)
    }
}

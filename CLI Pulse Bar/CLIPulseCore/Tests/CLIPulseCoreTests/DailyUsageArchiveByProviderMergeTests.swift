// v1.55: the year-long read merges provider by provider.
//
// Consent v2 lets a user pick "Last 30 days only" and allow older history
// later. The year-long read then meets an archive that already holds months of
// days. Claude Code deletes transcripts after 30 days by default, file by file,
// while Codex keeps its logs, so an older day comes back from the read with
// Codex alone, or with the share of one Claude session that was resumed later.
// `mergeScanEntries` replaces whole days, which erased or shrank Claude's share
// of every such day in the heatmap and the lifetime totals (and Codex's share
// where Codex logs were deleted). `mergeScanEntriesByProvider` keeps a provider
// the read did not find, never lowers a Claude slice, and takes the read's
// figures for Codex wherever it finds Codex.
//
// The routine 30-day read replaces whole days, except its oldest: the day
// Claude Code's cleanup is working through, merged by the same rule.
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

    /// Claude Code deletes transcripts one at a time, by each session's last
    /// activity. A day where one session outlived the others (it was resumed
    /// later) comes back with that session's share only. The complete Claude
    /// slice the routine read recorded stays; Codex, found again, is counted anew.
    func test_a_partly_deleted_claude_day_keeps_the_claude_slice_the_routine_read_recorded() {
        var a = DailyUsageArchive()
        a.mergeScanEntries([
            se(day, "Claude", "claude-sonnet-4-5", input: 900, output: 100, cost: 3.0),
            se(day, "Claude", ScanEntry.messageBucketModel, msgs: 40),
            se(day, "Codex", "gpt-5", input: 200, output: 20, cost: 0.1),
        ])
        a.mergeScanEntriesByProvider([
            se(day, "Claude", "claude-sonnet-4-5", input: 90, output: 10, cost: 0.3),
            se(day, "Claude", ScanEntry.messageBucketModel, msgs: 4),
            se(day, "Codex", "gpt-5", input: 250, output: 20, cost: 0.12),
        ])

        let d = a.days[day]
        XCTAssertEqual(d?.perProvider["Claude"], ProviderDaySlice(tokens: 1000, cost: 3.0, messages: 40),
                       "the complete Claude slice was replaced by what survived the cleanup")
        XCTAssertEqual(d?.perModel["claude-sonnet-4-5"], ModelDaySlice(tokens: 1000, cost: 3.0))
        XCTAssertEqual(d?.perProvider["Codex"], ProviderDaySlice(tokens: 270, cost: 0.12, messages: 0))
        XCTAssertEqual(d?.perModel["gpt-5"], ModelDaySlice(tokens: 270, cost: 0.12))
        XCTAssertEqual(d?.tokens, 1270)
        XCTAssertEqual(d?.messages, 40)
        XCTAssertEqual(d?.cost ?? 0, 3.12, accuracy: 0.0001)
    }

    /// The same when the read finds only the surviving Claude session: the
    /// stored day comes back unchanged.
    func test_a_read_with_less_claude_and_nothing_else_leaves_the_day_as_stored() {
        var a = storedBoth()
        let before = a
        a.mergeScanEntriesByProvider([se(day, "Claude", "claude-sonnet-4-5", input: 10, output: 5, cost: 0.03),
                                      se(day, "Claude", ScanEntry.messageBucketModel, msgs: 1)])
        XCTAssertEqual(a, before)
    }

    /// A session with no usage lines still counts messages. As many tokens and
    /// fewer messages is a smaller read too.
    func test_equal_claude_tokens_and_fewer_messages_keep_the_stored_messages() {
        var a = storedBoth()
        a.mergeScanEntriesByProvider([se(day, "Claude", "claude-sonnet-4-5", input: 100, output: 50, cost: 0.30),
                                      se(day, "Claude", ScanEntry.messageBucketModel, msgs: 3)] + codex(day))
        XCTAssertEqual(a.days[day]?.perProvider["Claude"], claudeSlice)
        XCTAssertEqual(a.days[day]?.messages, 7)
    }

    /// Never lowered is not never replaced: a read that counts more Claude
    /// usage (a transcript folder allowed later, or rules that count more)
    /// takes the day's Claude slice, and so does one that counts as much at a
    /// new price.
    func test_a_read_with_more_claude_or_a_new_price_takes_the_new_claude_figures() {
        var more = storedBoth()
        more.mergeScanEntriesByProvider([se(day, "Claude", "claude-sonnet-4-5", input: 200, output: 60, cost: 0.50),
                                         se(day, "Claude", ScanEntry.messageBucketModel, msgs: 9)])
        XCTAssertEqual(more.days[day]?.perProvider["Claude"], ProviderDaySlice(tokens: 260, cost: 0.50, messages: 9))
        XCTAssertEqual(more.days[day]?.perModel["claude-sonnet-4-5"], ModelDaySlice(tokens: 260, cost: 0.50))
        XCTAssertEqual(more.days[day]?.perProvider["Codex"], codexSlice)
        XCTAssertEqual(more.days[day]?.tokens, 480)

        var repriced = storedBoth()
        repriced.mergeScanEntriesByProvider([se(day, "Claude", "claude-sonnet-4-5", input: 100, output: 50, cost: 0.45),
                                             se(day, "Claude", ScanEntry.messageBucketModel, msgs: 7)])
        XCTAssertEqual(repriced.days[day]?.perProvider["Claude"], ProviderDaySlice(tokens: 150, cost: 0.45, messages: 7))
        XCTAssertEqual(repriced.days[day]?.cost ?? 0, 0.55, accuracy: 0.0001)
    }

    /// Codex keeps its logs, so a Codex read replaces the stored slice even
    /// when it is smaller: that is a recount under newer rules reaching the day.
    func test_a_codex_read_that_counts_less_replaces_the_codex_slice() {
        var a = storedBoth()
        a.mergeScanEntriesByProvider(codex(day, input: 100, output: 10, cost: 0.05))

        XCTAssertEqual(a.days[day]?.perProvider["Codex"], ProviderDaySlice(tokens: 110, cost: 0.05, messages: 0))
        XCTAssertEqual(a.days[day]?.perModel["gpt-5"], ModelDaySlice(tokens: 110, cost: 0.05))
        XCTAssertEqual(a.days[day]?.perProvider["Claude"], claudeSlice)
        XCTAssertEqual(a.days[day]?.tokens, 260)
    }

    // MARK: - Models

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

    /// A model name can change between versions (a dated name maps to its base
    /// once the base has a price row). The kept provider's models stay, the
    /// found provider's old name goes, and the models add up to the day.
    func test_models_add_up_to_the_day_after_a_found_providers_model_name_changed() {
        var a = DailyUsageArchive()
        a.mergeScanEntries(claude(day) + [se(day, "Codex", "gpt-5-2025-08-07", input: 200, output: 20, cost: 0.1)])
        a.mergeScanEntriesByProvider(codex(day))

        let d = a.days[day]!
        XCTAssertNil(d.perModel["gpt-5-2025-08-07"], "the Codex model's old name was kept beside its new one")
        XCTAssertEqual(d.perModel["gpt-5"], ModelDaySlice(tokens: 220, cost: 0.10))
        XCTAssertEqual(d.perModel["claude-sonnet-4-5"], ModelDaySlice(tokens: 150, cost: 0.30))
        XCTAssertEqual(d.perModel.values.reduce(0) { $0 + $1.tokens }, d.tokens)
        XCTAssertEqual(DailyUsageStats.byModel(a).reduce(0) { $0 + $1.tokens }, DailyUsageStats.totalTokens(a))
    }

    /// The same for a kept Claude slice whose model the read reports under a
    /// new name: the kept slice brings its own models, not the read's.
    func test_a_kept_claude_slice_brings_its_models_not_the_reads() {
        var a = DailyUsageArchive()
        a.mergeScanEntries([se(day, "Claude", "claude-opus-4-1-20250805", input: 900, output: 100, cost: 3.0)] + codex(day))
        a.mergeScanEntriesByProvider([se(day, "Claude", "claude-opus-4-1", input: 90, output: 10, cost: 0.3)] + codex(day))

        let d = a.days[day]!
        XCTAssertEqual(d.perModel["claude-opus-4-1-20250805"], ModelDaySlice(tokens: 1000, cost: 3.0))
        XCTAssertNil(d.perModel["claude-opus-4-1"])
        XCTAssertEqual(d.perModel.values.reduce(0) { $0 + $1.tokens }, d.tokens)
    }

    /// A model the name rules do not know (a third-party model behind Claude
    /// Code) goes with the read's provider when the read reports it, and with
    /// the only provider of a day that has one.
    func test_a_model_with_an_unknown_name_goes_with_its_provider() {
        var a = DailyUsageArchive()
        a.mergeScanEntries([se(day, "Claude", "glm-4.6", input: 500, output: 50, cost: 0.2)] + codex(day))
        a.mergeScanEntriesByProvider([se(day, "Claude", "glm-4.6", input: 50, output: 5, cost: 0.02)]
                                     + codex(day, input: 100, output: 10, cost: 0.05))

        let d = a.days[day]!
        XCTAssertEqual(d.perProvider["Claude"]?.tokens, 550)
        XCTAssertEqual(d.perModel["glm-4.6"], ModelDaySlice(tokens: 550, cost: 0.2))
        XCTAssertEqual(d.perModel["gpt-5"], ModelDaySlice(tokens: 110, cost: 0.05))
        XCTAssertEqual(d.perModel.values.reduce(0) { $0 + $1.tokens }, d.tokens)

        XCTAssertEqual(DailyUsageArchive.provider(ofModelNamed: "claude-sonnet-4-5"), "Claude")
        XCTAssertEqual(DailyUsageArchive.provider(ofModelNamed: "gpt-5.1-codex-max"), "Codex")
        XCTAssertEqual(DailyUsageArchive.provider(ofModelNamed: "o3"), "Codex")
        XCTAssertNil(DailyUsageArchive.provider(ofModelNamed: "glm-4.6"))
        XCTAssertEqual(DailyUsageArchive.provider(
            ofStoredModel: "glm-4.6", on: DayRollup(perProvider: ["Claude": claudeSlice]), readModelProviders: [:]),
            "Claude")
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

    /// The whole-day rule, which the routine read still uses on every day but
    /// its oldest, loses Claude's share on the same input. So the fixture
    /// above can tell the two rules apart, and a backfill wired back to
    /// `mergeScanEntries` shows up.
    func test_negative_control_the_whole_day_rule_drops_the_slice_on_the_same_input() {
        var a = storedBoth()
        a.mergeScanEntries(codex(day))

        XCTAssertNil(a.days[day]?.perProvider["Claude"])
        XCTAssertEqual(a.days[day]?.tokens, 220)
        XCTAssertEqual(DailyUsageStats.totalMessages(a), 0)
    }

    // MARK: - The routine read's oldest day

    /// The routine read covers the day of `now − 30 days` through today, and
    /// Claude Code's cleanup deletes transcripts last active before
    /// `now − 30 days`. On that oldest day the read sees what is left, so the
    /// day is merged by provider; the day after it is replaced whole.
    func test_the_routine_read_does_not_lower_claude_on_the_day_cleanup_is_working_through() {
        let utc = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-01T18:00:00Z")!
        let reach = DailyUsageArchive.claudeCleanupReach(now: now, in: utc)
        XCTAssertEqual(reach, "2026-09-01")
        let next = "2026-09-02"

        var a = DailyUsageArchive()
        a.mergeScanEntries(claude(reach) + codex(reach) + claude(next) + codex(next), claudeCleanupReach: reach)
        a.mergeScanEntries([se(reach, "Claude", "claude-sonnet-4-5", input: 10, output: 5, cost: 0.03)]
                           + codex(reach, input: 100)
                           + [se(next, "Claude", "claude-sonnet-4-5", input: 10, output: 5, cost: 0.03)]
                           + codex(next, input: 100),
                           claudeCleanupReach: reach)

        XCTAssertEqual(a.days[reach]?.perProvider["Claude"], claudeSlice, "the oldest day's Claude share was lowered")
        XCTAssertEqual(a.days[reach]?.perProvider["Codex"]?.tokens, 120, "Codex on the oldest day was not counted anew")
        XCTAssertEqual(a.days[next]?.perProvider["Claude"]?.tokens, 15, "a day inside the window was not replaced whole")
        XCTAssertEqual(a.days[next]?.tokens, 135)
    }

    /// The oldest day is written as read when the archive does not hold it,
    /// and a day the read finds nothing on is left alone, as before.
    func test_the_routine_reads_oldest_day_is_written_as_read_when_absent() {
        let reach = "2026-09-01"
        var a = DailyUsageArchive()
        a.mergeScanEntries(codex(reach), claudeCleanupReach: reach)
        XCTAssertEqual(a.days[reach]?.perProvider, ["Codex": codexSlice])
    }

    func test_the_cleanup_reach_is_the_day_of_now_minus_thirty_days_where_the_user_is() {
        let now = ISO8601DateFormatter().date(from: "2026-10-01T02:00:00Z")!
        XCTAssertEqual(DailyUsageArchive.claudeCleanupReach(now: now, in: TimeZone(identifier: "UTC")!), "2026-09-01")
        XCTAssertEqual(DailyUsageArchive.claudeCleanupReach(now: now, in: TimeZone(identifier: "America/Los_Angeles")!),
                       "2026-08-31")
        XCTAssertEqual(DailyUsageArchive.claudeCodeCleanupDays, 30)
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

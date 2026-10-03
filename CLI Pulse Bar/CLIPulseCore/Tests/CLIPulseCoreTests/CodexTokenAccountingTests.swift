import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// The pieces of Codex accounting on their own: the per-file counting rules,
/// which files count, and how one request is priced. The whole scanner is held
/// to realistic rollouts in `CodexAccountingFixtureTests`.
final class CodexTokenAccountingTests: XCTestCase {

    private typealias Totals = CostUsageCodexTotals
    private typealias Pricing = CostUsageScanner.Pricing

    private func t(_ input: Int, _ cached: Int, _ output: Int) -> Totals {
        Totals(input: input, cached: cached, output: output)
    }

    // MARK: - The baseline only rises

    func test_counts_the_growth_of_the_cumulative_total() {
        var a = CodexTokenAccountant()
        XCTAssertEqual(a.count(eventUnixMs: 1, total: t(100, 80, 10), last: t(100, 80, 10)), t(100, 80, 10))
        XCTAssertEqual(a.count(eventUnixMs: 2, total: t(250, 200, 25), last: t(150, 120, 15)), t(150, 120, 15))
        XCTAssertEqual(a.watermark, t(250, 200, 25))
    }

    func test_a_repeated_total_adds_nothing() {
        var a = CodexTokenAccountant()
        _ = a.count(eventUnixMs: 1, total: t(100, 50, 10), last: t(100, 50, 10))
        XCTAssertNil(a.count(eventUnixMs: 2, total: t(100, 50, 10), last: t(100, 50, 10)))
        XCTAssertEqual(a.state.eventCount, 2, "a repeated event is still an event of this file")
    }

    func test_a_falling_total_is_skipped_and_the_baseline_stays() {
        var a = CodexTokenAccountant()
        _ = a.count(eventUnixMs: 1, total: t(200, 160, 20), last: t(200, 160, 20))
        XCTAssertNil(a.count(eventUnixMs: 2, total: t(150, 120, 15), last: t(1, 1, 1)))
        XCTAssertEqual(a.watermark, t(200, 160, 20))
        // The climb back counts only above the old high.
        XCTAssertEqual(a.count(eventUnixMs: 3, total: t(250, 200, 25), last: t(100, 80, 10)), t(50, 40, 5))
    }

    func test_a_fall_in_any_one_component_is_a_fall() {
        var a = CodexTokenAccountant()
        _ = a.count(eventUnixMs: 1, total: t(200, 160, 20), last: nil)
        XCTAssertNil(a.count(eventUnixMs: 2, total: t(300, 150, 30), last: nil), "cached went down")
        XCTAssertEqual(a.watermark, t(200, 160, 20))
    }

    func test_an_event_without_usage_is_not_an_event() {
        var a = CodexTokenAccountant()
        XCTAssertNil(a.count(eventUnixMs: 1, total: nil, last: nil))
        XCTAssertEqual(a.state.eventCount, 0)
        XCTAssertNil(a.state.firstEventUnixMs)
    }

    func test_last_only_events_count_as_reported() {
        var a = CodexTokenAccountant()
        XCTAssertEqual(a.count(eventUnixMs: 1, total: nil, last: t(10, 5, 1)), t(10, 5, 1))
        XCTAssertEqual(a.count(eventUnixMs: 2, total: nil, last: t(20, 5, 2)), t(20, 5, 2))
    }

    // MARK: - Children: copied history and inherited counters

    func test_a_childs_events_before_its_own_session_meta_are_not_counted() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "child", isChild: true, metaUnixMs: 1_000)
        XCTAssertNil(a.count(eventUnixMs: 900, total: t(3000, 2000, 100), last: t(1000, 800, 50)))
        XCTAssertNil(a.watermark, "copied history does not set the baseline")
        XCTAssertEqual(a.state.eventCount, 0)
        XCTAssertEqual(a.count(eventUnixMs: 1_001, total: t(400, 300, 20), last: t(400, 300, 20)), t(400, 300, 20))
        XCTAssertEqual(a.state.firstEventUnixMs, 1_001)
    }

    func test_a_non_child_counts_events_whatever_their_time() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "root", isChild: false, metaUnixMs: 1_000)
        XCTAssertEqual(a.count(eventUnixMs: 900, total: t(10, 0, 1), last: t(10, 0, 1)), t(10, 0, 1))
    }

    func test_a_childs_inherited_counter_becomes_its_baseline() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "fork", isChild: true, metaUnixMs: 0)
        XCTAssertEqual(a.count(eventUnixMs: 1, total: t(5700, 4500, 340), last: t(700, 500, 40)), t(700, 500, 40))
        XCTAssertEqual(a.count(eventUnixMs: 2, total: t(6500, 5100, 380), last: t(800, 600, 40)), t(800, 600, 40))
    }

    func test_a_childs_fresh_counter_counts_from_zero() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 0)
        XCTAssertEqual(a.count(eventUnixMs: 1, total: t(600, 500, 30), last: t(600, 500, 30)), t(600, 500, 30))
    }

    func test_only_the_first_own_event_is_checked_for_inheritance() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 0)
        _ = a.count(eventUnixMs: 1, total: t(100, 0, 10), last: t(100, 0, 10))
        // A later event whose total exceeds its last is ordinary growth.
        XCTAssertEqual(a.count(eventUnixMs: 2, total: t(300, 0, 30), last: t(200, 0, 20)), t(200, 0, 20))
    }

    func test_a_root_files_carried_over_counter_becomes_its_baseline() {
        // A continuation of a thread whose counter picks up where an earlier
        // file ended: not a child, but the first total still exceeds its last.
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "thread", isChild: false, metaUnixMs: 0)
        XCTAssertEqual(a.count(eventUnixMs: 1, total: t(6500, 5200, 130), last: t(1500, 1200, 30)), t(1500, 1200, 30))
    }

    func test_without_last_a_root_files_first_total_counts() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "old-format", isChild: false, metaUnixMs: 0)
        XCTAssertEqual(a.count(eventUnixMs: 1, total: t(500, 0, 10), last: nil), t(500, 0, 10))
    }

    func test_without_last_a_childs_first_total_is_treated_as_inherited() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 0)
        XCTAssertNil(a.count(eventUnixMs: 1, total: t(5000, 0, 100), last: nil))
        XCTAssertEqual(a.count(eventUnixMs: 2, total: t(5200, 0, 110), last: nil), t(200, 0, 10))
    }

    func test_only_the_first_session_meta_is_the_files_own() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "leaf", isChild: true, metaUnixMs: 2_000)
        a.observeSessionMeta(rolloutId: "ancestor", isChild: false, metaUnixMs: 1_000)
        XCTAssertEqual(a.state.rolloutId, "leaf")
        XCTAssertTrue(a.state.isChild)
        XCTAssertEqual(a.state.metaUnixMs, 2_000)
    }

    func test_an_unreadable_first_line_leaves_the_identity_unknown() {
        var a = CodexTokenAccountant()
        a.observeUnreadableFirstLine()
        a.observeSessionMeta(rolloutId: "ancestor", isChild: false, metaUnixMs: 1)
        XCTAssertNil(a.state.rolloutId, "a copied ancestor meta is not the file's own")
        XCTAssertTrue(a.state.sawMeta)
    }

    func test_a_childs_lines_numbered_before_its_history_start_are_copied() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, historyStartOrdinal: 5)
        // The parent's session_meta, copied in just after the child's own.
        a.observeCopiedSessionMeta(ordinal: 1)
        XCTAssertEqual(a.state.copiedPrefix, .ancestorMetadata)
        // Copied lines are stamped when written, after the child's own meta:
        // only their numbers show they are the parent's.
        XCTAssertNil(a.count(eventUnixMs: 1_100, ordinal: 3, total: t(4000, 3000, 100), last: t(4000, 3000, 100)))
        XCTAssertNil(a.count(eventUnixMs: 1_200, ordinal: 4, total: t(10000, 8000, 250), last: t(6000, 5000, 150)))
        XCTAssertNil(a.watermark, "copied history does not set the baseline")
        XCTAssertEqual(a.state.eventCount, 0)
        XCTAssertEqual(a.count(eventUnixMs: 1_300, ordinal: 6, total: t(700, 500, 20), last: t(700, 500, 20)), t(700, 500, 20))
    }

    // MARK: - Children whose boundary has no copied session_meta ahead of it

    private func tokenEvent(_ ms: Int64, _ ordinal: Int?, _ total: Totals?, _ last: Totals?) -> CodexTokenAccountant.Event {
        .init(instant: Date(timeIntervalSince1970: Double(ms) / 1000), ordinal: ordinal, total: total, last: last, model: "gpt-5.5")
    }

    private func inputs(_ counted: [CodexTokenAccountant.Counted]) -> [Int] {
        counted.map { $0.delta.input }
    }

    /// Codex's migration of an older subagent rollout puts the boundary at the
    /// end of the file and copies no session_meta: every line is numbered
    /// before the boundary, and none of it is the parent's.
    func test_without_a_copied_session_meta_the_boundary_marks_nothing() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, historyStartOrdinal: 5)
        XCTAssertEqual(a.receive(tokenEvent(1_100, 2, t(600, 500, 30), t(600, 500, 30))).count, 0, "held")
        XCTAssertEqual(a.receive(tokenEvent(1_200, 3, t(1400, 1100, 60), t(800, 600, 30))).count, 0, "held")
        XCTAssertEqual(inputs(a.finish()), [600, 800], "no marker came: they are the subagent's own")
        XCTAssertEqual(a.state.copiedPrefix, .noMarker)
        XCTAssertEqual(a.state.eventCount, 2)
        XCTAssertTrue(a.finish().isEmpty, "nothing is counted twice")
    }

    func test_events_before_the_first_inter_agent_message_are_the_parents_replayed_tail() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, historyStartOrdinal: 8)
        XCTAssertTrue(a.receive(tokenEvent(1_100, 2, t(4500, 3600, 200), t(2500, 2000, 110))).isEmpty)
        a.observeInterAgentMessage(ordinal: 3)
        XCTAssertEqual(a.state.copiedPrefix, .interAgentMessage)
        XCTAssertNil(a.watermark, "the replayed tail does not set the baseline")
        XCTAssertEqual(a.state.eventCount, 0)
        // The subagent's counter continues from the replayed one: its first own
        // event counts only its own request (rule 3).
        XCTAssertEqual(inputs(a.receive(tokenEvent(1_300, 6, t(5200, 4100, 230), t(700, 500, 30)))), [700])
        XCTAssertEqual(inputs(a.receive(tokenEvent(1_400, 7, t(5500, 4300, 250), t(300, 200, 20)))), [300])
        XCTAssertTrue(a.finish().isEmpty)
    }

    func test_held_events_count_in_order_before_the_first_event_past_the_boundary() {
        // A migrated rollout that was later resumed: lines 1-2 are its history,
        // line 3 a request made after the migration.
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, historyStartOrdinal: 3)
        XCTAssertTrue(a.receive(tokenEvent(1_100, 1, t(700, 0, 1), t(700, 0, 1))).isEmpty)
        XCTAssertTrue(a.receive(tokenEvent(1_200, 2, t(900, 0, 2), t(200, 0, 1))).isEmpty)
        XCTAssertEqual(inputs(a.receive(tokenEvent(1_300, 3, t(1200, 0, 3), t(300, 0, 1)))), [700, 200, 300])
        XCTAssertEqual(a.state.copiedPrefix, .noMarker)
    }

    func test_markers_at_or_past_the_boundary_mark_nothing() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, historyStartOrdinal: 3)
        _ = a.receive(tokenEvent(1_100, 1, t(700, 0, 1), t(700, 0, 1)))
        a.observeCopiedSessionMeta(ordinal: 3)
        a.observeInterAgentMessage(ordinal: 4)
        XCTAssertNil(a.state.copiedPrefix)
        XCTAssertEqual(inputs(a.finish()), [700])
    }

    func test_a_copied_session_meta_drops_what_was_held() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, historyStartOrdinal: 6)
        _ = a.receive(tokenEvent(1_100, 1, t(700, 0, 1), t(700, 0, 1)))
        a.observeCopiedSessionMeta(ordinal: 2)
        XCTAssertEqual(a.state.copiedPrefix, .ancestorMetadata)
        XCTAssertTrue(a.finish().isEmpty)
        XCTAssertTrue(a.receive(tokenEvent(1_200, 3, t(900, 0, 2), t(900, 0, 2))).isEmpty, "copied by line number")
        XCTAssertEqual(inputs(a.receive(tokenEvent(1_300, 6, t(100, 0, 1), t(100, 0, 1)))), [100])
    }

    func test_a_root_file_or_a_child_without_a_boundary_holds_nothing() {
        var root = CodexTokenAccountant()
        root.observeSessionMeta(rolloutId: "root", isChild: false, metaUnixMs: 0, historyStartOrdinal: 5)
        XCTAssertEqual(inputs(root.receive(tokenEvent(1, 1, t(10, 0, 1), t(10, 0, 1)))), [10])
        var child = CodexTokenAccountant()
        child.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 0)
        XCTAssertEqual(inputs(child.receive(tokenEvent(1, 1, t(10, 0, 1), t(10, 0, 1)))), [10])
        XCTAssertFalse(child.awaitsCopiedPrefixMarker)
    }

    /// Rule 3 takes the inherited part field by field and clamps it at zero,
    /// so a first total below its own request in one field inherits nothing in
    /// that field (upstream takes no baseline at all in that case).
    func test_a_first_total_below_its_last_in_one_field_inherits_the_rest() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "thread", isChild: false, metaUnixMs: 0)
        XCTAssertEqual(a.count(eventUnixMs: 1, total: t(1000, 900, 50), last: t(1200, 800, 60)), t(1000, 800, 50))
        XCTAssertEqual(a.watermark, t(1000, 900, 50))
    }

    func test_growth_beyond_the_events_own_request_counts() {
        // A request with no token event of its own (an aborted turn) shows only
        // in the cumulative total.
        var a = CodexTokenAccountant()
        _ = a.count(eventUnixMs: 1, total: t(1000, 800, 40), last: t(1000, 800, 40))
        XCTAssertEqual(a.count(eventUnixMs: 2, total: t(4000, 3200, 120), last: t(1000, 800, 40)), t(3000, 2400, 80))
    }

    func test_a_lines_ordinal_is_read_from_its_head() {
        func ord(_ text: String) -> Int? { CostUsageScanner.codexLineOrdinal(Data(text.utf8)) }
        XCTAssertEqual(ord(#"{"timestamp":"t","ordinal":12,"type":"session_meta"}"#), 12)
        XCTAssertEqual(ord(#"{"ordinal": 7}"#), 7)
        XCTAssertEqual(ord(#"{"ordinal":-2}"#), -2)
        XCTAssertNil(ord(#"{"type":"session_meta"}"#))
        XCTAssertNil(ord(#"{"ordinal":"x"}"#))
        XCTAssertNil(ord(String(repeating: "x", count: 600) + #""ordinal":3"#), "only the head is read")
    }

    func test_a_root_files_line_numbers_do_not_matter() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "root", isChild: false, metaUnixMs: 0, historyStartOrdinal: 5)
        XCTAssertEqual(a.count(eventUnixMs: 1, ordinal: 1, total: t(10, 0, 1), last: t(10, 0, 1)), t(10, 0, 1))
    }

    // MARK: - The first line

    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func test_the_first_line_is_read_on_its_own() throws {
        let dir = try tempDir("codex-first-line")
        let url = dir.appendingPathComponent("f.jsonl")
        try Data("abc\ndef\n".utf8).write(to: url)
        XCTAssertEqual(CostUsageScanner.readCodexFirstLine(fileURL: url), .line(Data("abc".utf8)))
        try Data("abcdef".utf8).write(to: url)
        XCTAssertEqual(CostUsageScanner.readCodexFirstLine(fileURL: url), .incomplete)
        XCTAssertEqual(CostUsageScanner.readCodexFirstLine(fileURL: url, maxBytes: 4), .tooLong)
        try Data("abcd\n".utf8).write(to: url)
        XCTAssertEqual(CostUsageScanner.readCodexFirstLine(fileURL: url, maxBytes: 4), .line(Data("abcd".utf8)))
        try Data().write(to: url)
        XCTAssertEqual(CostUsageScanner.readCodexFirstLine(fileURL: url), .incomplete)
        XCTAssertEqual(CostUsageScanner.readCodexFirstLine(fileURL: dir.appendingPathComponent("missing")), .unreadable)
    }

    private func event(_ time: String, _ input: Int, ordinal: Int) -> String {
        let usage = #"{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":1}"#
        return #"{"timestamp":"2026-09-10T\#(time).000Z","type":"event_msg","ordinal":\#(ordinal),"payload":{"type":"token_count","info":{"total_token_usage":\#(usage),"last_token_usage":\#(usage)}}}"#
    }

    private func meta(_ id: String, _ time: String, extra: String = "") -> String {
        #"{"timestamp":"2026-09-10T\#(time).000Z","type":"session_meta","ordinal":0,"payload":{"id":"\#(id)","session_id":"\#(id)","timestamp":"2026-09-10T\#(time).000Z"\#(extra)}}"#
    }

    /// Codex input a fresh scan reports for these files, all in 2026/09/10.
    private func scannedInput(_ files: [String: String]) throws -> Int {
        let home = try tempDir("codex-scan")
        let dir = home.appendingPathComponent("sessions/2026/09/10", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: dir.appendingPathComponent(name))
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [],
            cacheRoot: home.appendingPathComponent("cache", isDirectory: true),
            daysToScan: 30
        )
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        options.now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")
        return CostUsageScanner.scan(options: options).entries
            .filter { $0.provider == "Codex" }
            .reduce(0) { $0 + $1.inputTokens }
    }

    /// A subagent whose own session_meta is too long to read, followed by its
    /// parent's copied session_meta. Taking the copied one as the file's own
    /// would give the subagent its parent's payload.id, and one of them would
    /// look like a copy of the other.
    func test_a_subagent_with_an_unreadable_first_line_is_not_taken_for_its_parent() throws {
        let huge = String(repeating: "x", count: CostUsageScanner.codexFirstLineMaxBytes + 1)
        let childMeta = meta("child", "12:00:30", extra: #","parent_thread_id":"parent","base_instructions":{"text":"\#(huge)"}"#)
        let input = try scannedInput([
            "rollout-parent.jsonl": [meta("parent", "12:00:00"), event("12:01:00", 1_000, ordinal: 1)].joined(separator: "\n") + "\n",
            "rollout-child.jsonl": [childMeta, meta("parent", "12:00:00"), event("12:01:00", 500, ordinal: 2)].joined(separator: "\n") + "\n",
        ])
        XCTAssertEqual(input, 1_500)
    }

    func test_a_file_whose_first_line_is_still_being_written_is_left_for_the_next_scan() throws {
        let input = try scannedInput([
            "rollout-done.jsonl": [meta("done", "12:00:00"), event("12:01:00", 1_000, ordinal: 1)].joined(separator: "\n") + "\n",
            "rollout-new.jsonl": #"{"timestamp":"2026-09-10T12:02"#,
        ])
        XCTAssertEqual(input, 1_000)
    }

    func test_a_later_session_meta_never_gives_a_file_its_identity() throws {
        let other = #"{"timestamp":"2026-09-10T12:00:00.000Z","type":"turn_context","ordinal":0,"payload":{"model":"gpt-5.5"}}"#
        let input = try scannedInput([
            "rollout-a.jsonl": [meta("thread", "12:00:00"), event("12:01:00", 1_000, ordinal: 1)].joined(separator: "\n") + "\n",
            "rollout-b.jsonl": [other, meta("thread", "12:00:00"), event("12:01:00", 700, ordinal: 2)].joined(separator: "\n") + "\n",
        ])
        XCTAssertEqual(input, 1_700)
    }

    func test_absurd_token_counts_neither_trap_nor_wrap() throws {
        let usage = #"{"input_tokens":1e20,"cached_input_tokens":0,"output_tokens":9.3e18}"#
        let line = #"{"timestamp":"2026-09-10T12:01:00.000Z","type":"event_msg","ordinal":1,"payload":{"type":"token_count","info":{"total_token_usage":\#(usage),"last_token_usage":\#(usage)}}}"#
        let input = try scannedInput([
            "rollout-big.jsonl": [meta("big", "12:00:00"), line, line].joined(separator: "\n") + "\n",
        ])
        XCTAssertEqual(input, 1_000_000_000_000_000, "capped at 10^15 and counted once")
    }

    /// An ancestor's session_meta is often over the 32 KB line limit: the
    /// scanner reads its head, so it still marks the copied history after it.
    func test_a_long_copied_session_meta_still_marks_the_copied_history() throws {
        let huge = String(repeating: "x", count: 40 * 1024)
        let childMeta = meta("child", "12:00:30", extra: #","parent_thread_id":"parent","subagent_history_start_ordinal":4"#)
        let copiedMeta = meta("parent", "12:00:00", extra: #","base_instructions":{"text":"\#(huge)"}"#)
            .replacingOccurrences(of: #""ordinal":0"#, with: #""ordinal":1"#)
        let input = try scannedInput([
            "rollout-child.jsonl": [
                childMeta, copiedMeta, event("12:00:31", 5_000, ordinal: 2), event("12:00:32", 5_000, ordinal: 3),
                event("12:01:00", 400, ordinal: 4),
            ].joined(separator: "\n") + "\n",
        ])
        XCTAssertEqual(input, 400)
    }

    /// A token line caught half-written is read whole on the next scan. Before,
    /// the scan moved past it, so the file's first event was lost and the next
    /// one looked like a counter carried over (rule 3): the first request was
    /// never counted.
    func test_a_token_line_caught_half_written_is_read_whole_on_the_next_scan() throws {
        let home = try tempDir("codex-half-line")
        let dir = home.appendingPathComponent("sessions/2026/09/10", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-half.jsonl")
        let first = event("12:01:00", 1_000, ordinal: 1)
        let secondUsage = #"{"input_tokens":2500,"cached_input_tokens":0,"output_tokens":2}"#
        let lastUsage = #"{"input_tokens":1500,"cached_input_tokens":0,"output_tokens":1}"#
        let second = #"{"timestamp":"2026-09-10T12:02:00.000Z","type":"event_msg","ordinal":2,"payload":{"type":"token_count","info":{"total_token_usage":\#(secondUsage),"last_token_usage":\#(lastUsage)}}}"#
        let cut = first.index(first.startIndex, offsetBy: first.count / 2)
        try Data((meta("half", "12:00:00") + "\n" + String(first[..<cut])).utf8).write(to: url)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [],
            cacheRoot: home.appendingPathComponent("cache", isDirectory: true),
            daysToScan: 30
        )
        options.refreshMinIntervalSeconds = 0
        options.now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")
        func input() -> Int {
            CostUsageScanner.scan(options: options).entries.filter { $0.provider == "Codex" }.reduce(0) { $0 + $1.inputTokens }
        }
        XCTAssertEqual(input(), 0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(first[cut...]) + "\n" + second + "\n").utf8))
        try handle.close()
        XCTAssertEqual(input(), 2_500)
    }

    /// A last line without a newline that already decodes is a finished line
    /// and counts; the next scan does not count it again.
    func test_a_complete_last_line_without_a_newline_counts_once() throws {
        let home = try tempDir("codex-no-newline")
        let dir = home.appendingPathComponent("sessions/2026/09/10", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-nonl.jsonl")
        try Data((meta("nonl", "12:00:00") + "\n" + event("12:01:00", 1_000, ordinal: 1)).utf8).write(to: url)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [],
            cacheRoot: home.appendingPathComponent("cache", isDirectory: true),
            daysToScan: 30
        )
        options.refreshMinIntervalSeconds = 0
        options.now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")
        func input() -> Int {
            CostUsageScanner.scan(options: options).entries.filter { $0.provider == "Codex" }.reduce(0) { $0 + $1.inputTokens }
        }
        XCTAssertEqual(input(), 1_000)
        let second = #"{"timestamp":"2026-09-10T12:02:00.000Z","type":"event_msg","ordinal":2,"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1600,"cached_input_tokens":0,"output_tokens":2},"last_token_usage":{"input_tokens":600,"cached_input_tokens":0,"output_tokens":1}}}}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + second + "\n").utf8))
        try handle.close()
        XCTAssertEqual(input(), 1_600)
    }

    /// Which local day an event is filed under, half an hour either side of
    /// local midnight, in three zones: the process's time zone is switched for
    /// the test through `TZ` (and put back). The shared fixtures sit at midday
    /// UTC, so they never test this. Setting `NSTimeZone.default` does not
    /// move `TimeZone.current`, so it cannot be used here; an earlier version
    /// of this test tried it and only ever skipped.
    func test_events_either_side_of_local_midnight_land_on_their_own_local_days() throws {
        func setProcessZone(_ identifier: String?) {
            if let identifier { setenv("TZ", identifier, 1) } else { unsetenv("TZ") }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }
        let original = getenv("TZ").map { String(cString: $0) }
        defer { setProcessZone(original) }
        let probe = Date(timeIntervalSince1970: 1_789_000_000)
        for zone in ["America/Los_Angeles", "Asia/Tokyo", "UTC"] {
            setProcessZone(zone)
            let wanted = try XCTUnwrap(TimeZone(identifier: zone))
            XCTAssertEqual(TimeZone.current.secondsFromGMT(for: probe), wanted.secondsFromGMT(for: probe),
                           "\(zone): the process time zone did not switch, so this test would prove nothing")
            let calendar = DayKey.calendar()
            func at(_ day: Int, _ hour: Int, _ minute: Int) throws -> String {
                let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)))
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return iso.string(from: date)
            }
            func line(_ ts: String, _ total: Int, _ last: Int, _ ordinal: Int) -> String {
                #"{"timestamp":"\#(ts)","type":"event_msg","ordinal":\#(ordinal),"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":\#(ordinal)},"last_token_usage":{"input_tokens":\#(last),"cached_input_tokens":0,"output_tokens":1}}}}"#
            }
            let start = try at(10, 23, 0)
            let head = #"{"timestamp":"\#(start)","type":"session_meta","ordinal":0,"payload":{"id":"night","session_id":"night","timestamp":"\#(start)"}}"#
            let home = try tempDir("codex-midnight")
            let dir = home.appendingPathComponent("sessions/2026/09/10", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([head, line(try at(10, 23, 30), 1_000, 1_000, 1), line(try at(11, 0, 30), 1_600, 600, 2)]
                .joined(separator: "\n").appending("\n").utf8)
                .write(to: dir.appendingPathComponent("rollout-night.jsonl"))
            var options = CostUsageScanner.Options(
                codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
                claudeProjectsRoots: [],
                cacheRoot: home.appendingPathComponent("cache", isDirectory: true),
                daysToScan: 30
            )
            options.forceRescan = true
            options.refreshMinIntervalSeconds = 0
            options.now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")
            var byDay: [String: Int] = [:]
            for entry in CostUsageScanner.scan(options: options).entries where entry.provider == "Codex" {
                byDay[entry.date, default: 0] += entry.inputTokens
            }
            XCTAssertEqual(byDay, ["2026-09-10": 1_000, "2026-09-11": 600], zone)
        }
    }

    /// A model with no rate is counted and left unpriced (nil), never read as $0.
    func test_an_unpriced_model_is_counted_and_left_unpriced() throws {
        let home = try tempDir("codex-unpriced")
        let dir = home.appendingPathComponent("sessions/2026/09/10", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let turn = #"{"timestamp":"2026-09-10T12:00:05.000Z","type":"turn_context","ordinal":1,"payload":{"model":"not-a-gpt-model"}}"#
        try Data([meta("u", "12:00:00"), turn, event("12:01:00", 1_000, ordinal: 2)].joined(separator: "\n").appending("\n").utf8)
            .write(to: dir.appendingPathComponent("rollout-u.jsonl"))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [],
            cacheRoot: home.appendingPathComponent("cache", isDirectory: true),
            daysToScan: 30
        )
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        options.now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")
        let entry = try XCTUnwrap(CostUsageScanner.scan(options: options).entries.first { $0.provider == "Codex" })
        XCTAssertEqual(entry.model, "not-a-gpt-model")
        XCTAssertEqual(entry.inputTokens, 1_000)
        XCTAssertNil(entry.costUSD)
    }

    /// Live sessions are one row per rollout: a subagent carries its parent's
    /// session_id, and keying the row on it merged the two, showing whichever
    /// file was written last.
    func test_a_live_subagent_is_its_own_session() throws {
        let home = try tempDir("codex-live")
        let now = Date()
        let dayDir = DayKey.string(from: now).split(separator: "-")
            .reduce(home.appendingPathComponent("sessions", isDirectory: true)) { $0.appendingPathComponent(String($1), isDirectory: true) }
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now.addingTimeInterval(-30))
        func line(_ id: String, parent: String?, input: Int) -> String {
            let parentField = parent.map { #","parent_thread_id":"\#($0)""# } ?? ""
            let usage = #"{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":1}"#
            return #"{"timestamp":"\#(ts)","type":"session_meta","ordinal":0,"payload":{"id":"\#(id)","session_id":"p","timestamp":"\#(ts)"\#(parentField)}}"#
                + "\n" + #"{"timestamp":"\#(ts)","type":"event_msg","ordinal":1,"payload":{"type":"token_count","info":{"total_token_usage":\#(usage),"last_token_usage":\#(usage)}}}"# + "\n"
        }
        try Data(line("p", parent: nil, input: 2_000).utf8).write(to: dayDir.appendingPathComponent("rollout-p.jsonl"))
        try Data(line("c", parent: "p", input: 300).utf8).write(to: dayDir.appendingPathComponent("rollout-c.jsonl"))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [],
            cacheRoot: home.appendingPathComponent("cache", isDirectory: true),
            daysToScan: 7
        )
        options.refreshMinIntervalSeconds = 0
        let candidates = CostUsageScanner.scan(options: options).activeSessionCandidates.filter { $0.provider == "Codex" }
        XCTAssertEqual(Set(candidates.compactMap(\.sessionId)), ["p", "c"])
        let sessions = CostUsageScanner.synthesizeSessions(candidates: candidates, now: now, deviceName: "Mac")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.total_usage)), [2_001, 301])
    }

    func test_which_session_meta_payloads_name_a_parent() {
        typealias A = CodexTokenAccountant
        XCTAssertTrue(A.sessionMetaNamesParent(["parent_thread_id": "p"]))
        XCTAssertTrue(A.sessionMetaNamesParent(["forked_from_id": "p"]))
        XCTAssertTrue(A.sessionMetaNamesParent(["source": ["subagent": ["thread_spawn": [:]]]]))
        XCTAssertFalse(A.sessionMetaNamesParent(["source": "vscode"]))
        XCTAssertFalse(A.sessionMetaNamesParent(["source": ["other": 1]]))
        XCTAssertFalse(A.sessionMetaNamesParent(["parent_thread_id": "", "forked_from_id": NSNull()]))
        XCTAssertFalse(A.sessionMetaNamesParent(["id": "x", "session_id": "y"]))
    }

    // MARK: - Which files count

    private func file(_ path: String, _ id: String?, events: Int, _ first: Int64?, _ last: Int64?, final: Int = 0) -> CodexCopyResolver.File {
        .init(path: path, rolloutId: id, eventCount: events, firstEventUnixMs: first, lastEventUnixMs: last, finalTokens: final)
    }

    func test_nested_files_of_one_thread_count_once_keeping_the_one_with_more_events() {
        XCTAssertEqual(CodexCopyResolver.countedPaths([file("a", "x", events: 3, 10, 30), file("b", "x", events: 5, 10, 50)]), ["b"])
        // The file taken first decides: a longer file with fewer events is not
        // inside the shorter one, so both count.
        XCTAssertEqual(CodexCopyResolver.countedPaths([file("a", "x", events: 3, 10, 60), file("b", "x", events: 5, 10, 50)]), ["a", "b"])
    }

    func test_ties_go_to_the_larger_final_total_then_the_earlier_path() {
        XCTAssertEqual(CodexCopyResolver.countedPaths([
            file("a", "x", events: 2, 1, 5, final: 10), file("b", "x", events: 2, 1, 5, final: 20),
        ]), ["b"])
        XCTAssertEqual(CodexCopyResolver.countedPaths([
            file("b", "x", events: 2, 1, 5, final: 10), file("a", "x", events: 2, 1, 5, final: 10),
        ]), ["a"])
    }

    func test_a_span_inside_a_kept_one_is_a_copy_and_a_partial_overlap_is_not() {
        XCTAssertEqual(CodexCopyResolver.countedPaths([file("a", "x", events: 3, 1, 9), file("b", "x", events: 2, 3, 5)]), ["a"])
        XCTAssertEqual(CodexCopyResolver.countedPaths([file("a", "x", events: 2, 1, 5), file("b", "x", events: 1, 5, 9)]), ["a", "b"])
        XCTAssertEqual(CodexCopyResolver.countedPaths([file("a", "x", events: 2, 1, 5), file("b", "x", events: 1, 6, 9)]), ["a", "b"])
    }

    func test_files_without_events_or_without_an_id_always_count() {
        XCTAssertEqual(CodexCopyResolver.countedPaths([
            file("a", "x", events: 0, nil, nil),
            file("b", "x", events: 4, 1, 9),
            file("c", nil, events: 4, 1, 9),
            file("d", "", events: 4, 1, 9),
        ]), ["a", "b", "c", "d"])
    }

    func test_different_threads_never_hide_each_other() {
        XCTAssertEqual(CodexCopyResolver.countedPaths([file("a", "x", events: 2, 1, 5), file("b", "y", events: 2, 1, 5)]), ["a", "b"])
    }

    // MARK: - Pricing one request

    /// A `CodexPricingTable` row with round rates and a 272K tier.
    private let base = CodexPricingTable.Rates(
        input: 1e-6, output: 1e-5, cachedInput: 1e-7,
        longContextThreshold: 272_000,
        inputAboveThreshold: 2e-6, outputAboveThreshold: 1.5e-5, cachedInputAboveThreshold: 2e-7
    )

    func test_a_request_at_the_threshold_is_billed_at_base_rates() {
        let cost = CodexPricingTable.requestCostUSD(rates: base, inputTokens: 272_000, cachedInputTokens: 72_000, outputTokens: 1_000)
        XCTAssertEqual(cost, 200_000 * 1e-6 + 72_000 * 1e-7 + 1_000 * 1e-5, accuracy: 1e-12)
    }

    func test_a_request_over_the_threshold_is_billed_at_long_context_rates_in_full() {
        let cost = CodexPricingTable.requestCostUSD(rates: base, inputTokens: 272_001, cachedInputTokens: 72_000, outputTokens: 1_000)
        XCTAssertEqual(cost, 200_001 * 2e-6 + 72_000 * 2e-7 + 1_000 * 1.5e-5, accuracy: 1e-12)
    }

    func test_cached_tokens_are_clamped_to_the_input_and_default_to_the_input_rate() {
        let noCacheRate = CodexPricingTable.Rates(input: 1e-6, output: 0, cachedInput: nil)
        XCTAssertEqual(CodexPricingTable.requestCostUSD(rates: noCacheRate, inputTokens: 100, cachedInputTokens: 500, outputTokens: 0), 100 * 1e-6, accuracy: 1e-15)
    }

    func test_a_long_context_tier_without_a_cache_rate_bills_cached_reads_at_the_base_cache_rate() {
        let tierWithoutCache = CodexPricingTable.Rates(
            input: 1e-6, output: 1e-5, cachedInput: 1e-7,
            longContextThreshold: 272_000,
            inputAboveThreshold: 2e-6, outputAboveThreshold: 1.5e-5, cachedInputAboveThreshold: nil
        )
        let cost = CodexPricingTable.requestCostUSD(rates: tierWithoutCache, inputTokens: 300_000, cachedInputTokens: 100_000, outputTokens: 0)
        XCTAssertEqual(cost, 200_000 * 2e-6 + 100_000 * 1e-7, accuracy: 1e-12)
    }

    /// The long-context tier is a property of the request the event reports
    /// (`last_token_usage`), not of the counted growth, which can also hold
    /// requests that wrote no event of their own; that part is billed at base
    /// rates.
    func test_the_tier_is_decided_by_the_events_own_request() {
        // Growth of 400K over a 100K request: nothing is long-context.
        XCTAssertEqual(
            Pricing.codexEventCostUSD(rates: base, counted: t(400_000, 0, 0), request: t(100_000, 0, 0)),
            400_000 * 1e-6, accuracy: 1e-12
        )
        // A 300K request, counted in full: long-context.
        XCTAssertEqual(
            Pricing.codexEventCostUSD(rates: base, counted: t(300_000, 0, 1_000), request: t(300_000, 0, 1_000)),
            300_000 * 2e-6 + 1_000 * 1.5e-5, accuracy: 1e-12
        )
        // A 300K request plus 100K beyond it: the request long-context, the rest at base rates.
        XCTAssertEqual(
            Pricing.codexEventCostUSD(rates: base, counted: t(400_000, 0, 1_000), request: t(300_000, 0, 1_000)),
            300_000 * 2e-6 + 1_000 * 1.5e-5 + 100_000 * 1e-6, accuracy: 1e-12
        )
        // A first event that counts less than its request (the rest was carried
        // over) is still that request's tier.
        XCTAssertEqual(
            Pricing.codexEventCostUSD(rates: base, counted: t(10_000, 0, 0), request: t(300_000, 0, 0)),
            10_000 * 2e-6, accuracy: 1e-12
        )
        // Without `last`, the counted tokens are the request.
        XCTAssertEqual(
            Pricing.codexEventCostUSD(rates: base, counted: t(300_000, 0, 0), request: nil),
            300_000 * 2e-6, accuracy: 1e-12
        )
    }

    func test_a_request_made_now_is_billed_at_the_current_rates() {
        let now = Date()
        for model in ["gpt-5.5", "gpt-5.4", "gpt-5", "gpt-5.6-sol", "gpt-5.6"] {
            XCTAssertEqual(
                Pricing.codexCostUSD(model: model, inputTokens: 1_000, cachedInputTokens: 100, outputTokens: 10, at: now),
                Pricing.codexCostUSD(model: model, inputTokens: 1_000, cachedInputTokens: 100, outputTokens: 10),
                model
            )
        }
    }

    // MARK: - A day row's cost

    func test_a_day_rows_cost_is_its_stored_request_costs() {
        // 1.5 USD stored; pricing the aggregate would give something else.
        let cost = CostUsageScanner.codexCost(model: "gpt-5.5", packed: [1_000, 0, 0, 1_500_000_000])
        XCTAssertEqual(try XCTUnwrap(cost), 1.5, accuracy: 1e-12)
    }

    func test_an_unpriced_models_row_stays_unpriced() {
        XCTAssertNil(CostUsageScanner.codexCost(model: "not-a-gpt-model", packed: [1_000, 0, 0, 0]))
    }

    func test_a_row_without_stored_cost_is_not_guessed_at() {
        XCTAssertNil(CostUsageScanner.codexCost(model: "gpt-5.5", packed: [1_000, 100, 10]))
    }

    // MARK: - Rate changes reach stored costs only through a rules bump

    /// Each request's cost is stored when it is read, so a change to
    /// `CodexPricingTable` (a rate, a tier, a dated rate, an alias) — or to
    /// which row a model name resolves to — leaves every day already scanned
    /// at the old price, and an unpriced model's stored $0 reading as a priced
    /// $0 once it gains a row, unless `costUsageCodexCacheRulesVersion` is
    /// bumped. This pin fails when either changes; bump the version, then
    /// update both numbers here.
    func test_codex_rate_changes_come_with_a_rules_version_bump() {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Pricing.codexRatesFingerprint().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        XCTAssertEqual(
            [UInt64(costUsageCodexCacheRulesVersion), hash],
            [5, 5_837_815_579_421_536_959],
            "Codex rates changed: bump costUsageCodexCacheRulesVersion, then pin the new version and hash"
        )
    }

    // MARK: - Timestamps

    func test_timestamps_keep_their_milliseconds() throws {
        let a = try XCTUnwrap(CostUsageScanner.instantFromTimestamp("2026-09-10T12:00:00.123Z"))
        let b = try XCTUnwrap(CostUsageScanner.instantFromTimestamp("2026-09-10T12:00:00.000Z"))
        XCTAssertEqual(CostUsageScanner.unixMillis(a) - CostUsageScanner.unixMillis(b), 123)
        let c = try XCTUnwrap(CostUsageScanner.instantFromTimestamp("2026-09-10T21:00:00.5+09:00"))
        XCTAssertEqual(CostUsageScanner.unixMillis(c) - CostUsageScanner.unixMillis(b), 500)
    }

    func test_day_keys_are_unchanged_by_the_millisecond_reading() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for text in [
            "2026-09-10T23:59:59.999Z", "2026-09-10T00:00:00.001Z",
            "2026-09-10T23:59:59.999+09:00", "2026-09-10T00:00:00.000-05:00",
        ] {
            let expected = DayKey.string(from: try XCTUnwrap(iso.date(from: text)))
            XCTAssertEqual(CostUsageScanner.dayKeyFromTimestamp(text), expected, text)
        }
    }
}

#endif

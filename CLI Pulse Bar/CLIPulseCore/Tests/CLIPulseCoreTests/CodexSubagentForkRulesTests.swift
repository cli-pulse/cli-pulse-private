// Translated in part from steipete/CodexBar, taken at upstream commit 3bbf6bc4
// (2026-10-03) (https://github.com/steipete/CodexBar): the rollouts and the
// expected tokens of these swift-testing suites, run here through CLI Pulse's
// own scanner (`CostUsageScanner.scan`) as XCTest:
//
//   Tests/CodexBarTests/CodexSubagentAccountingIntegrationTests.swift
//   Tests/CodexBarTests/CodexCompactSubagentAccountingTests.swift
//   Tests/CodexBarTests/CodexCompactSubagentFixture.swift
//   Tests/CodexBarTests/CodexSubagentForkBaselineTests.swift
//   Tests/CodexBarTests/CodexDirectForkBaselineTests.swift
//   Tests/CodexBarTests/CodexSubagentOrdinalBoundaryTests.swift
//
// NOT verbatim: upstream asserts on its own parser's internals (resolver
// calls, dependency keys, cached rows, report entries); these assert what CLI
// Pulse reports for the same files. Where CLI Pulse counts differently on
// purpose, the test says so and asserts CLI Pulse's number, with upstream's in
// the message: those are the differences the Codex note's "simplified rules"
// line and `scripts/codex_codexbar_daily_compare.py` describe. Upstream's
// variants that escape JSON keys (`"type"`) exercise a second parser CLI
// Pulse does not have and are not translated. The rule-level tests at the end
// are ours.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
// ──────────────────────────────────────────────────────────────────

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CodexSubagentForkRulesTests: XCTestCase {

    private typealias Totals = CostUsageCodexTotals
    private typealias Usage = (input: Int, cached: Int, output: Int)

    // MARK: - Rollout lines, as upstream's tests write them

    /// 2026-09-15 12:00:00 UTC, plus `seconds`.
    private func ts(_ seconds: Double = 0) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: 1_789_473_600 + seconds))
    }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func meta(_ id: String?, at seconds: Double = 0, ordinal: Int? = nil, _ extra: [String: Any] = [:]) -> String {
        var payload: [String: Any] = ["timestamp": ts(seconds)]
        if let id { payload["id"] = id }
        payload.merge(extra) { $1 }
        var object: [String: Any] = ["type": "session_meta", "timestamp": ts(seconds), "payload": payload]
        if let ordinal { object["ordinal"] = ordinal }
        return line(object)
    }

    private func subagent(_ parent: String? = nil) -> [String: Any] {
        ["subagent": ["thread_spawn": parent.map { ["parent_thread_id": $0] } ?? [:]]]
    }

    private func turn(at seconds: Double? = 0, model: String = "gpt-5.4", ordinal: Int? = nil) -> String {
        var object: [String: Any] = ["type": "turn_context", "payload": ["model": model]]
        if let seconds { object["timestamp"] = ts(seconds) }
        if let ordinal { object["ordinal"] = ordinal }
        return line(object)
    }

    private func message(at seconds: Double? = 0, trigger: Bool = true, ordinal: Int? = nil,
                         topLevelTrigger: Bool? = nil) -> String {
        var object: [String: Any] = ["type": "inter_agent_communication_metadata", "payload": ["trigger_turn": trigger]]
        if let seconds { object["timestamp"] = ts(seconds) }
        if let ordinal { object["ordinal"] = ordinal }
        if let topLevelTrigger { object["trigger_turn"] = topLevelTrigger }
        return line(object)
    }

    private func usage(_ u: Usage) -> [String: Int] {
        ["input_tokens": u.input, "cached_input_tokens": u.cached, "output_tokens": u.output]
    }

    private func tokens(at seconds: Double = 0, total: Usage? = nil, last: Usage? = nil,
                        model: String? = "gpt-5.4", ordinal: Int? = nil) -> String {
        var info: [String: Any] = [:]
        if let model { info["model"] = model }
        if let total { info["total_token_usage"] = usage(total) }
        if let last { info["last_token_usage"] = usage(last) }
        var object: [String: Any] = ["type": "event_msg", "timestamp": ts(seconds),
                                     "payload": ["type": "token_count", "info": info]]
        if let ordinal { object["ordinal"] = ordinal }
        return line(object)
    }

    // MARK: - Scanning

    private func tempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fork-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ files: [String: [String]], to home: URL, appending: Bool = false) throws {
        let dir = home.appendingPathComponent("sessions/2026/09/15", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, lines) in files {
            let url = dir.appendingPathComponent("rollout-2026-09-15T12-00-00-\(name).jsonl")
            let data = Data(lines.map { $0 + "\n" }.joined().utf8)
            if appending, let handle = try? FileHandle(forWritingTo: url) {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url)
            }
        }
    }

    /// Model → [input, cached, output] on 2026-09-15.
    private func scan(_ home: URL, force: Bool = false) -> [String: [Int]] {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [],
            cacheRoot: home.appendingPathComponent("cache", isDirectory: true),
            daysToScan: 30
        )
        options.forceRescan = force
        options.refreshMinIntervalSeconds = 0
        options.now = ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")
        var out: [String: [Int]] = [:]
        for entry in CostUsageScanner.scan(options: options).entries where entry.provider == "Codex" {
            XCTAssertEqual(entry.date, "2026-09-15")
            out[entry.model] = [entry.inputTokens, entry.cachedTokens, entry.outputTokens]
        }
        return out
    }

    private func total(_ rows: [String: [Int]]) -> [Int] {
        rows.values.reduce([0, 0, 0]) { [$0[0] + $1[0], $0[1] + $1[1], $0[2] + $1[2]] }
    }

    private func scanned(_ files: [String: [String]]) throws -> [Int] {
        let home = try tempHome()
        try write(files, to: home)
        return total(scan(home, force: true))
    }

    private let prefix: Usage = (1000, 900, 100)
    private let own: Usage = (1050, 910, 105)
    private let request: Usage = (50, 10, 5)

    // MARK: - CodexSubagentAccountingIntegrationTests

    /// Upstream: "copied parent prefix keeps the inherited baseline after late
    /// lineage metadata" — [50, 10, 5], the parent's total at the fork time
    /// read from the parent's file. CLI Pulse does not read the parent's file;
    /// with no turn marker in the child, its first copied event counts its own
    /// request (the parent's last) once more.
    func test_late_lineage_metadata_without_a_turn_marker_counts_the_last_copied_request() throws {
        let child = [
            meta("child-session", ["source": subagent("parent-session")]),
            turn(model: "gpt-5.3"),
            tokens(at: 1, total: prefix, last: request, model: "gpt-5.3"),
            meta("child-session", ["forked_from_id": "parent-session"]),
            meta("parent-session"),
            turn(),
            tokens(at: 2, total: own, last: request),
        ]
        XCTAssertEqual(try scanned(["child": child]), [100, 20, 10], "upstream: [50, 10, 5] from the parent's file")
    }

    /// Upstream: "local marker owns only its suffix and persists lineage-only
    /// cache mode". The turn its parent's message triggers after the copied
    /// session_meta starts the subagent's own history; the replayed snapshot
    /// right after it adds nothing. Upstream's escaped-key variant is not
    /// translated; its escaped-timestamp variant is.
    func test_a_local_marker_owns_only_its_suffix() throws {
        func child(_ id: String) -> [String] {
            [
                meta(id, ["source": subagent("parent-session")]),
                turn(model: "gpt-5.3"),
                tokens(at: 1, total: prefix, last: request, model: "gpt-5.3"),
                meta(id, ["forked_from_id": "parent-session"]),
                meta("ancestor-session"),
                turn(at: 2),
                message(at: 2),
                tokens(at: 2.5, total: prefix, last: request, model: "gpt-5.3"),
                tokens(at: 3, total: own, last: request),
            ]
        }
        let escaped = child("marker-child-escaped-timestamp").map {
            $0.replacingOccurrences(of: #""timestamp":"#, with: #""timestamp":"#)
        }
        XCTAssertEqual(try scanned(["marker-child": child("marker-child")]), [50, 10, 5])
        XCTAssertEqual(try scanned(["escaped": escaped]), [50, 10, 5])
        let home = try tempHome()
        try write(["a": child("marker-child"), "b": escaped], to: home)
        XCTAssertEqual(scan(home, force: true), ["gpt-5.4": [100, 20, 10]], "each counts its own suffix once")
    }

    /// Upstream: "copied prefix infers its parent and ignores a spoofed
    /// trigger outside the payload". The message's own `trigger_turn` is
    /// false, so there is no turn marker (a marker would give [50, 10, 5]);
    /// upstream then reads the inferred parent's file, CLI Pulse does not.
    func test_a_spoofed_trigger_outside_the_payload_is_not_a_marker() throws {
        let child = [
            meta("inferred-child", ["source": ["subagent": ["thread_spawn": [String: Any]()]]]),
            tokens(at: 1, total: prefix, last: request, model: "gpt-5.3"),
            meta("inferred-parent"),
            turn(at: 2),
            message(at: 2, trigger: false, topLevelTrigger: true),
            tokens(at: 3, total: own, last: request),
        ]
        XCTAssertEqual(try scanned(["child": child]), [100, 20, 10], "upstream: [50, 10, 5] from the parent's file")
    }

    /// Upstream: "oversized ancestor metadata remains conservative
    /// copied-prefix evidence". An ancestor's session_meta over the line limit
    /// is still read as one (from the id in its head): with a turn marker
    /// after it, only the suffix counts. Not seen, the file would count all of
    /// it ([100, 20, 10]).
    func test_an_oversized_ancestor_session_meta_is_still_copied_history_evidence() throws {
        let oversized = #"{"type":"session_meta","timestamp":"\#(ts())","payload":{"id":"oversized-parent","padding":""#
            + String(repeating: "x", count: 300_000) + #""}}"#
        let child = [
            meta("oversized-child", ["source": subagent()]),
            tokens(at: 1, total: prefix, last: request, model: "gpt-5.3"),
            oversized,
            turn(at: 2),
            message(at: 2),
            tokens(at: 3, total: own, last: request),
        ]
        XCTAssertEqual(try scanned(["child": child]), [50, 10, 5])
    }

    /// Upstream: "invalid timestamp suffix markers preserve parent dependency".
    /// A turn_context and an inter-agent message without timestamps are not a
    /// marker (one would give [50, 10, 5]); upstream then reads the parent's
    /// file, CLI Pulse counts by its other rules.
    func test_markers_without_timestamps_are_not_markers() throws {
        let child = [
            meta("invalid-marker-child", ["source": subagent()]),
            tokens(at: 1, total: prefix, last: request, model: "gpt-5.3"),
            meta("invalid-marker-parent"),
            turn(at: nil),
            message(at: nil),
            tokens(at: 2, total: own, last: request),
        ]
        XCTAssertEqual(try scanned(["child": child]), [100, 20, 10], "upstream: [50, 10, 5] from the parent's file")
    }

    /// Upstream: "idless copied prefix without a parent or local marker is
    /// suppressed" — nothing. CLI Pulse counts the growth beyond the first
    /// total, which a child without `last` inherits whole (rule 3).
    func test_an_idless_copied_prefix_without_a_marker_counts_its_growth() throws {
        let child = [
            meta("ambiguous-child", ["source": subagent()]),
            tokens(at: 1, total: prefix, last: nil, model: "gpt-5.3"),
            line(["type": "session_meta", "timestamp": ts(), "payload": [String: Any]()]),
            tokens(at: 2, total: own, last: nil),
        ]
        XCTAssertEqual(try scanned(["child": child]), [50, 10, 5], "upstream: nothing")
    }

    /// Upstream: "protocol ordinal isolates the child suffix without resolving
    /// its parent" — [50, 10, 5]. A history boundary inside the file with no
    /// copied session_meta and no inter-agent message ahead of it marks
    /// nothing in CLI Pulse (rule 2; a migrated rollout resumed later looks
    /// the same), so the event numbered before it counts.
    func test_an_ordinal_boundary_with_no_marker_ahead_of_it_marks_nothing() throws {
        let child = [
            meta("ordinal-child", ordinal: 0, ["forked_from_id": "ordinal-parent", "subagent_history_start_ordinal": 10,
                                                "source": subagent("ordinal-parent")]),
            tokens(at: 1, total: prefix, last: request, model: "gpt-5.3", ordinal: 9),
            turn(at: 2, ordinal: 10),
            tokens(at: 3, total: own, last: request, ordinal: 11),
        ]
        XCTAssertEqual(try scanned(["child": child]), [100, 20, 10], "upstream: [50, 10, 5]")
    }

    /// Upstream: "legacy child proves its inherited baseline from first owned
    /// total minus last".
    func test_a_legacy_child_inherits_its_first_total() throws {
        let child = [
            meta("legacy-self-confirmed", ["forked_from_id": "legacy-parent", "source": subagent("legacy-parent")]),
            tokens(at: 1, total: prefix, last: nil, model: "gpt-5.3"),
            turn(at: 2),
            message(at: 2),
            tokens(at: 3, total: own, last: request),
            tokens(at: 4, total: (1070, 915, 110), last: (20, 5, 5)),
        ]
        XCTAssertEqual(try scanned(["child": child]), [70, 15, 10])
    }

    /// Upstream: "bounded append fallback reclassifies the complete subagent
    /// rollout". A subagent rollout without a history ordinal is read whole
    /// again when it grows: the copied session_meta and the turn marker that
    /// arrive later decide what the earlier lines were. (Before the append
    /// upstream counts the whole opening total, 1,100 tokens; CLI Pulse
    /// inherits it, rule 3.)
    func test_a_growing_subagent_is_read_whole_again() throws {
        let home = try tempHome()
        try write(["growing": [
            meta("growing-child", ["source": ["subagent": ["thread_spawn": [String: Any]()]]]),
            turn(model: "gpt-5.3"),
            tokens(at: 1, total: prefix, last: nil, model: "gpt-5.3"),
        ]], to: home)
        XCTAssertEqual(total(scan(home, force: true)), [0, 0, 0])
        try write(["growing": [
            meta("growing-parent"),
            turn(at: 2),
            message(at: 2),
            tokens(at: 3, total: own, last: request),
        ]], to: home, appending: true)
        XCTAssertEqual(total(scan(home)), [50, 10, 5], "the append is read with the whole file")
        XCTAssertEqual(total(scan(home)), [50, 10, 5], "and the saved cache gives the same")
        XCTAssertEqual(total(scan(home, force: true)), [50, 10, 5])
    }

    // MARK: - CodexCompactSubagentAccountingTests

    private func compactParent() -> [String] {
        [meta("compact-parent", at: -2), turn(at: -2, model: "gpt-5.3"),
         tokens(at: -1, total: prefix, last: prefix, model: "gpt-5.3")]
    }

    private func compactChild(preBoundaryLast: Usage?) -> [String] {
        var lines = [
            meta("compact-child", ["forked_from_id": "compact-parent", "source": subagent("compact-parent")]),
            tokens(at: 0.1, total: prefix, last: prefix, model: nil),
        ]
        if let preBoundaryLast { lines.append(tokens(at: 0.2, last: preBoundaryLast, model: nil)) }
        lines += [
            turn(at: 1),
            message(at: 1),
            tokens(at: 2, total: (prefix.input + request.input, prefix.cached + request.cached,
                                  prefix.output + request.output), last: request, model: nil),
        ]
        return lines
    }

    /// Upstream: "locally confirmed first turn marker drops a compact copied
    /// prefix", cold, warm and forced.
    func test_a_locally_confirmed_first_turn_drops_a_compact_copied_prefix() throws {
        let home = try tempHome()
        try write(["parent": compactParent(), "child": compactChild(preBoundaryLast: (7, 3, 2))], to: home)
        for (label, force) in [("cold", true), ("warm", false), ("forced", true)] {
            let rows = scan(home, force: force)
            XCTAssertEqual(rows["gpt-5.3"], [1000, 900, 100], label)
            XCTAssertEqual(rows["gpt-5.4"], [50, 10, 5], label)
            XCTAssertNil(rows["gpt-5"], "\(label): nothing filed without a model")
        }
    }

    /// Upstream: "locally confirmed compact prefix ignores parent resolution".
    func test_a_compact_child_needs_no_parent_file() throws {
        XCTAssertEqual(try scanned(["child": compactChild(preBoundaryLast: nil)]), [50, 10, 5])
    }

    // MARK: - CodexSubagentForkBaselineTests

    /// Upstream's `verifyForks`: forks opening with an inherited total, then a
    /// repeat of it and (`mismatched`) a larger copied snapshot, before their
    /// own two requests and a repeat of the last one.
    private func forks(explicit: Bool, trigger: Bool, mismatched: Bool, parentPresent: Bool, depth: Int = 1,
                       contextPresent: Bool = true, opening: [Int] = [1000, 900, 100],
                       owned: Bool = true) -> (files: [String: [String]], expected: [Int]) {
        func u(_ v: [Int]) -> Usage { (v[0], v[1], v[2]) }
        var files: [String: [String]] = [:]
        var prefix = opening
        if parentPresent {
            files["fork-0"] = [
                line(["type": "session_meta", "timestamp": ts(), "payload": ["id": "fork-0"]]),
                turn(ordinal: 10),
                tokens(total: u(prefix), last: u(prefix), ordinal: 2),
            ]
        }
        for level in 1...depth {
            let baseline = mismatched ? [prefix[0] + 4000, prefix[1] + 3000, prefix[2] + 400] : prefix
            var metadata: [String: Any] = [
                "forked_from_id": "fork-\(level - 1)", "thread_source": "subagent",
                "source": ["subagent": ["thread_spawn": ["parent_thread_id": "fork-\(level - 1)", "depth": level]]],
            ]
            if explicit { metadata["subagent_history_start_ordinal"] = 10 }
            var lines = [
                meta("fork-\(level)", ordinal: 0, metadata),
                line(["type": "compacted", "ordinal": 1, "timestamp": ts(), "payload": [String: Any]()]),
                tokens(total: u(prefix), last: (0, 0, 0), ordinal: 2),
            ]
            if contextPresent { lines.append(turn(ordinal: 10)) }
            if trigger { lines.append(message(ordinal: 11)) }
            // Even total == last can be a copied snapshot; equality alone cannot prove a reset.
            lines.append(tokens(total: u(prefix), last: u(prefix), ordinal: 12))
            lines.append(tokens(total: u(baseline), last: u(baseline), ordinal: 13))
            let final = [baseline[0] + 70, baseline[1] + 15, baseline[2] + 10]
            if owned {
                lines.append(tokens(total: (baseline[0] + 50, baseline[1] + 10, baseline[2] + 5), last: (50, 10, 5),
                                    ordinal: 19))
                lines.append(tokens(at: 1, total: u(final), last: (20, 5, 5), ordinal: 20))
                // A fresh timestamp with the same cumulative payload must remain a replay.
                lines.append(tokens(at: 2, total: u(final), last: (20, 5, 5), ordinal: 21))
            }
            files["fork-\(level)"] = lines
            prefix = final
        }
        let ownTotal = owned ? [70 * depth, 15 * depth, 10 * depth] : [0, 0, 0]
        let parent = parentPresent ? opening : [0, 0, 0]
        return (files, [parent[0] + ownTotal[0], parent[1] + ownTotal[1], parent[2] + ownTotal[2]])
    }

    private func checkForks(_ label: String, _ shape: (files: [String: [String]], expected: [Int])) throws {
        XCTAssertEqual(try scanned(shape.files), shape.expected, label)
        // Half of each file, scanned, then the rest: the saved state resumes
        // (a child with a history ordinal) or the file is read whole again.
        let home = try tempHome()
        var rest: [String: [String]] = [:]
        var head: [String: [String]] = [:]
        for (name, lines) in shape.files {
            let half = max(1, lines.count / 2)
            head[name] = Array(lines[..<half])
            rest[name] = Array(lines[half...])
        }
        try write(head, to: home)
        _ = scan(home, force: true)
        try write(rest.filter { !$0.value.isEmpty }, to: home, appending: true)
        XCTAssertEqual(total(scan(home)), shape.expected, "\(label), resumed")
    }

    func test_an_explicit_suffix_excludes_inherited_totals_even_when_components_drift() throws {
        for mismatched in [false, true] {
            for parentPresent in [false, true] {
                try checkForks("explicit mismatched=\(mismatched) parent=\(parentPresent)",
                               forks(explicit: true, trigger: true, mismatched: mismatched, parentPresent: parentPresent))
            }
        }
    }

    func test_a_legacy_suffix_excludes_inherited_totals_without_a_parent_snapshot() throws {
        for mismatched in [false, true] {
            for trigger in [false, true] {
                try checkForks("legacy mismatched=\(mismatched) trigger=\(trigger)",
                               forks(explicit: false, trigger: trigger, mismatched: mismatched, parentPresent: false))
            }
        }
    }

    func test_a_legacy_first_owned_token_identifies_its_boundary_without_turn_metadata() throws {
        for mismatched in [false, true] {
            try checkForks("no context mismatched=\(mismatched)",
                           forks(explicit: false, trigger: false, mismatched: mismatched, parentPresent: false,
                                 contextPresent: false))
        }
    }

    func test_nested_forks_count_each_owned_suffix_once() throws {
        for explicit in [false, true] {
            for parentPresent in [false, true] {
                try checkForks("nested explicit=\(explicit) parent=\(parentPresent)",
                               forks(explicit: explicit, trigger: true, mismatched: true, parentPresent: parentPresent,
                                     depth: 2))
            }
        }
    }

    func test_zero_inherited_counters_preserve_fresh_child_usage() throws {
        for explicit in [false, true] {
            try checkForks("zero opening explicit=\(explicit)",
                           forks(explicit: explicit, trigger: true, mismatched: false, parentPresent: false,
                                 opening: [0, 0, 0]))
        }
    }

    func test_terminal_inherited_only_suffixes_contribute_no_child_usage() throws {
        for explicit in [false, true] {
            for parentPresent in [false, true] {
                try checkForks("inherited only explicit=\(explicit) parent=\(parentPresent)",
                               forks(explicit: explicit, trigger: true, mismatched: true, parentPresent: parentPresent,
                                     owned: false))
            }
        }
    }

    // MARK: - CodexDirectForkBaselineTests

    /// Upstream: "direct fork chains preserve cumulative inheritance" — the
    /// child counts 20, and the day 1,020 (+40 with the parent's own event).
    /// CLI Pulse does not read a fork's inherited counter from its parent's
    /// file: the child's first event, a repeat of the snapshot it was forked
    /// from, counts its own request once more (1,000, or the parent's 40).
    /// This is the known limit the Codex note's "simplified rules" line states.
    func test_a_direct_fork_counts_the_snapshot_it_repeats() throws {
        func metadata(_ id: String, parent: String?, time: Double) -> String {
            var payload: [String: Any] = ["id": id, "source": "vscode", "thread_source": "user", "timestamp": ts(time)]
            payload["forked_from_id"] = parent
            return line(["type": "session_meta", "payload": payload])
        }
        func inputTokens(_ input: Int, last: Int, time: Double) -> String {
            line(["type": "event_msg", "timestamp": ts(time), "payload": ["type": "token_count", "info": [
                "model": "gpt-5.4",
                "total_token_usage": ["input_tokens": input, "output_tokens": 0],
                "last_token_usage": ["input_tokens": last, "output_tokens": 0],
            ]]])
        }
        for (parentEventTime, ours, upstream) in [(0.0, 2020, 1020), (3.0, 1100, 1060), (8.0, 2060, 1060)] {
            var parent = [metadata("parent", parent: "root", time: 2)]
            if parentEventTime > 0 { parent.append(inputTokens(1040, last: 40, time: parentEventTime)) }
            let inherited = parentEventTime == 3 ? 1040 : 1000
            let files = [
                "root": [metadata("root", parent: nil, time: 0), inputTokens(1000, last: 1000, time: 1)],
                "parent": parent,
                "child": [
                    metadata("child", parent: "parent", time: 4),
                    inputTokens(inherited, last: parentEventTime == 3 ? 40 : 1000, time: 5),
                    inputTokens(inherited + 20, last: 20, time: 6),
                    inputTokens(inherited + 20, last: 20, time: 7),
                ],
            ]
            XCTAssertEqual(try scanned(files)[0], ours, "parent event at \(parentEventTime); upstream: \(upstream)")
        }
    }

    // MARK: - CodexSubagentOrdinalBoundaryTests

    /// Upstream: "explicit boundary excludes a prefix ending before child
    /// history" (nothing) and "explicit boundary preserves first owned usage
    /// across cached and bounded appends" (35 tokens after the append). A
    /// boundary past the last line with an inter-agent message before it is
    /// the shape Codex's migration leaves; CLI Pulse counts the subagent's
    /// work after that message (rule 2), which CodexBar does not.
    func test_a_boundary_past_the_end_is_a_migrated_rollout() throws {
        let home = try tempHome()
        try write(["ordinal-child": [
            meta("ordinal-child", ordinal: 0, ["forked_from_id": "ordinal-parent", "subagent_history_start_ordinal": 210,
                                                "source": subagent("ordinal-parent")]),
            tokens(total: prefix, last: (0, 0, 0), ordinal: 2),
            turn(ordinal: 10),
            message(ordinal: 11),
            tokens(total: own, last: request, ordinal: 19),
            tokens(total: (1070, 915, 110), last: (20, 5, 5), ordinal: 208),
        ]], to: home)
        XCTAssertEqual(total(scan(home, force: true)), [70, 15, 10], "upstream: nothing")
        XCTAssertEqual(total(scan(home)), [70, 15, 10])
        try write(["ordinal-child": [
            turn(at: 5, ordinal: 210),
            tokens(at: 6, total: (1100, 930, 115), last: (30, 15, 5), ordinal: 211),
        ]], to: home, appending: true)
        XCTAssertEqual(total(scan(home)), [100, 30, 15], "upstream: [30, 15, 5]")
        XCTAssertEqual(total(scan(home, force: true)), [100, 30, 15])
    }

    // MARK: - Rule 4, on its own

    private func t(_ input: Int, _ cached: Int, _ output: Int) -> Totals {
        Totals(input: input, cached: cached, output: output)
    }

    private func event(_ ordinal: Int, _ total: Totals?, _ last: Totals?, line: Int = 0) -> CodexTokenAccountant.Event {
        .init(instant: Date(timeIntervalSince1970: 2_000 + Double(ordinal)), ordinal: ordinal, total: total, last: last,
              model: "gpt-5.5", line: line)
    }

    private func inputs(_ counted: [CodexTokenAccountant.Counted]) -> [Int] { counted.map(\.delta.input) }

    func test_until_its_first_tokens_a_child_skips_repeats_of_its_copied_counter_and_copied_snapshots() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, historyStartOrdinal: 4)
        a.observeCopiedSessionMeta(ordinal: 1)
        XCTAssertTrue(a.receive(event(2, t(5000, 4000, 300), t(1000, 800, 50))).isEmpty, "copied")
        XCTAssertEqual(a.state.inheritedReference, t(5000, 4000, 300), "the copied counter is the reference")
        XCTAssertTrue(a.receive(event(5, t(5000, 4000, 300), t(1000, 800, 50))).isEmpty, "a repeat of it")
        XCTAssertTrue(a.receive(event(6, t(9000, 7000, 600), t(9000, 7000, 600))).isEmpty, "a copied snapshot")
        XCTAssertEqual(a.state.inheritedReference, t(9000, 7000, 600))
        XCTAssertEqual(inputs(a.receive(event(7, t(9400, 7300, 620), t(400, 300, 20)))), [400], "its own request")
        XCTAssertEqual(a.state.openingSettled, true)
        // After the first tokens, a total equal to its own request counts as growth.
        XCTAssertEqual(inputs(a.receive(event(8, t(9900, 7600, 640), t(9900, 7600, 640)))), [500])
    }

    func test_a_snapshot_below_the_inherited_counter_is_a_fresh_request() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, historyStartOrdinal: 4)
        a.observeCopiedSessionMeta(ordinal: 1)
        _ = a.receive(event(2, t(5000, 4000, 300), t(1000, 800, 50)))
        XCTAssertEqual(inputs(a.receive(event(5, t(400, 300, 20), t(400, 300, 20)))), [400],
                       "a counter restarted below the inherited one is the child's own")
    }

    func test_an_opening_total_with_no_request_of_its_own_is_the_reference() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, historyStartOrdinal: 4)
        XCTAssertTrue(a.receive(event(5, t(5000, 4000, 300), t(0, 0, 0))).isEmpty)
        XCTAssertEqual(a.state.inheritedReference, t(5000, 4000, 300))
        XCTAssertNotEqual(a.state.openingSettled, true)
        XCTAssertTrue(a.receive(event(6, t(9000, 7000, 600), t(9000, 7000, 600))).isEmpty, "a copied snapshot")
        XCTAssertEqual(inputs(a.receive(event(7, t(9500, 7300, 640), t(500, 300, 40)))), [500])
    }

    func test_rule_4_is_for_children_with_a_history_ordinal_only() {
        for isChild in [false, true] {
            var a = CodexTokenAccountant()
            a.observeSessionMeta(rolloutId: "f", isChild: isChild, metaUnixMs: 1_000)
            XCTAssertTrue(a.receive(event(1, t(5000, 4000, 300), t(0, 0, 0))).isEmpty)
            XCTAssertEqual(inputs(a.receive(event(2, t(9000, 7000, 600), t(9000, 7000, 600)))), [4000],
                           "isChild=\(isChild): growth, as before")
            XCTAssertNil(a.state.inheritedReference)
        }
    }

    // MARK: - Rule 5, on its own

    func test_a_subagent_without_a_history_ordinal_is_held_whole_and_classified_at_the_end() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, isSubagent: true)
        XCTAssertTrue(a.classifiesWholeFile)
        XCTAssertTrue(a.receive(event(1, t(5000, 4000, 300), t(1000, 800, 50), line: 1)).isEmpty)
        a.observeWholeFileLine(.sessionMetadata(id: "parent"), line: 2)
        a.observeWholeFileLine(.turnContext, line: 3)
        a.observeWholeFileLine(.interAgentCommunication(triggerTurn: true), line: 4)
        XCTAssertTrue(a.receive(event(5, t(5400, 4300, 320), t(400, 300, 20), line: 5)).isEmpty, "held")
        XCTAssertEqual(inputs(a.finish()), [400], "the copied event before the marker is not counted")
        XCTAssertTrue(a.finish().isEmpty)
    }

    func test_without_a_marker_a_whole_subagent_counts_by_the_other_rules() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "sub", isChild: true, metaUnixMs: 1_000, isSubagent: true)
        _ = a.receive(event(1, t(600, 500, 30), t(600, 500, 30), line: 1))
        a.observeWholeFileLine(.turnContext, line: 2)
        _ = a.receive(event(3, t(1400, 1100, 60), t(800, 600, 30), line: 3))
        XCTAssertEqual(inputs(a.finish()), [600, 800])
    }

    func test_only_a_subagent_without_a_history_ordinal_is_read_whole() {
        var withOrdinal = CodexTokenAccountant()
        withOrdinal.observeSessionMeta(rolloutId: "s", isChild: true, metaUnixMs: 0, historyStartOrdinal: 5, isSubagent: true)
        XCTAssertFalse(withOrdinal.classifiesWholeFile)
        var fork = CodexTokenAccountant()
        fork.observeSessionMeta(rolloutId: "f", isChild: true, metaUnixMs: 0, namesForkParent: true)
        XCTAssertFalse(fork.classifiesWholeFile, "a fork that is not a subagent is read as it grows")
        XCTAssertFalse(fork.state.classifiesWholeFile)
    }

    func test_a_repeat_of_the_files_own_session_meta_can_name_its_fork_parent() {
        var a = CodexTokenAccountant()
        a.observeSessionMeta(rolloutId: "leaf", isChild: true, metaUnixMs: 0, isSubagent: true)
        a.observeWholeFileLine(.sessionMetadata(id: "other"), line: 1, namesForkParent: true)
        XCTAssertNotEqual(a.state.namesForkParent, true, "an ancestor's fork parent is not this file's")
        a.observeWholeFileLine(.sessionMetadata(id: " leaf "), line: 2, namesForkParent: true)
        XCTAssertEqual(a.state.namesForkParent, true)
    }

    // MARK: - Reading the lines rule 5 needs

    func test_the_id_in_a_long_session_meta_is_read_from_its_head() {
        func id(_ text: String) -> String? { CostUsageScanner.codexHeadId(Data(text.utf8)) }
        XCTAssertEqual(id(#"{"type":"session_meta","payload":{"id":"abc","x":1"#), "abc")
        XCTAssertEqual(id(#"{"payload":{"session_id":"s","parent_thread_id":"p","id":"real"#), nil, "unterminated")
        XCTAssertEqual(id(#"{"payload":{"session_id":"s","id":"real","y":"#), "real", "not a key ending in _id")
        XCTAssertEqual(id(#"{"id":"a\"b","payload":{"id":"c"}"#), "c", "an escaped value is skipped")
        XCTAssertNil(id(#"{"type":"session_meta"}"#))
    }

    func test_which_session_meta_payloads_are_a_subagents_or_name_a_fork_parent() {
        typealias A = CodexTokenAccountant
        XCTAssertTrue(A.sessionMetaIsSubagent(["source": " Subagent "]))
        XCTAssertTrue(A.sessionMetaIsSubagent(["source": ["subagent": "review"]]))
        XCTAssertTrue(A.sessionMetaIsSubagent(["source": ["subagent": ["thread_spawn": [:]]]]))
        XCTAssertFalse(A.sessionMetaIsSubagent(["source": ["subagent": 1]]))
        XCTAssertFalse(A.sessionMetaIsSubagent(["source": "vscode"]))
        XCTAssertEqual(A.sessionMetaForkParent(["forkedFromId": " p "]), "p")
        XCTAssertEqual(A.sessionMetaForkParent(["parent_session_id": "q"]), "q")
        XCTAssertEqual(A.sessionMetaForkParent(["parentSessionId": "r"]), "r")
        XCTAssertNil(A.sessionMetaForkParent(["forked_from_id": "  ", "parent_thread_id": "t"]))
        XCTAssertTrue(A.sessionMetaNamesParent(["source": "subagent"]))
        XCTAssertTrue(A.sessionMetaNamesParent(["parentSessionId": "r"]))
    }
}
#endif

#!/usr/bin/env python3
"""Offline tests for scripts/codex_accounting_replica.py, on the shared fixtures.

`CLI Pulse Bar/CLIPulseCore/Tests/Fixtures/codex-accounting-cases.json` holds
Codex rollouts shaped like real ones and, for each case, the per-day, per-model
[input, cached, output] the app must report. The Swift scanner is held to the
same file by CodexAccountingFixtureTests, so passing here and there means the
replica and the app agree on every case, and the replica can be trusted as the
reference when the two are compared on a real machine.

Negative controls, so a green run means the fixtures can tell the rules apart:

  * `--policy legacy` (the scanner before 1.56: a file dropped when its
    session_id was already seen, deltas against the previous total, no
    copied-history rules) must get the subagent, fork, copied-history,
    continuation and falling-counter cases wrong;
  * each single-rule control (SINGLE_RULE_CONTROLS) replaces one rule and
    must get exactly the cases that rule governs wrong and every other case
    right.

Run: python3 scripts/test_codex_accounting_replica.py
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import codex_accounting_replica as replica  # noqa: E402

FIXTURES = os.path.join(
    HERE, "..", "CLI Pulse Bar", "CLIPulseCore", "Tests", "Fixtures", "codex-accounting-cases.json"
)
SCAN = {"now_utc": "2026-09-30T12:00:00Z", "days_to_scan": 30}


def load_fixtures() -> dict:
    with open(FIXTURES, encoding="utf-8") as fh:
        return json.load(fh)


def write_case(home: str, case: dict) -> None:
    for f in case["files"]:
        path = os.path.join(home, *f["path"].split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            for line in f["lines"]:
                fh.write(json.dumps(line, separators=(",", ":")) + "\n")
            if f.get("unterminated"):
                fh.write(f["unterminated"])


def run_case(case: dict, fixtures: dict, policy: str = "overlap") -> dict:
    now = datetime.fromisoformat(fixtures["now_utc"].replace("Z", "+00:00"))
    today = datetime.fromtimestamp(now.timestamp()).date()
    home = tempfile.mkdtemp(prefix="codex-accounting-")
    try:
        write_case(home, case)
        res = replica.scan(home, today, fixtures["days_to_scan"], policy)
        return {day: {m: list(r) for m, r in models.items()} for day, models in res.days.items()}
    finally:
        shutil.rmtree(home, ignore_errors=True)


def total_input(result: dict) -> int:
    return sum(r[0] for models in result.values() for r in models.values())


def event(time: str, n: int, ordinal: int) -> dict:
    u = {"input_tokens": n, "cached_input_tokens": 0, "output_tokens": 1}
    return {
        "timestamp": f"2026-09-10T{time}.000Z",
        "type": "event_msg",
        "ordinal": ordinal,
        "payload": {"type": "token_count", "info": {"total_token_usage": u, "last_token_usage": u}},
    }


def meta(rid: str, time: str, **extra) -> dict:
    payload = {"id": rid, "session_id": extra.pop("session_id", rid), "timestamp": f"2026-09-10T{time}.000Z"}
    payload.update(extra)
    return {"timestamp": f"2026-09-10T{time}.000Z", "type": "session_meta", "ordinal": 0, "payload": payload}


class FixtureCases(unittest.TestCase):
    def test_every_case_matches_expected(self):
        fx = load_fixtures()
        self.assertGreaterEqual(len(fx["cases"]), 20)
        for case in fx["cases"]:
            with self.subTest(case=case["name"]):
                self.assertEqual(run_case(case, fx), case["expected"], case["description"])

    def test_the_old_scanner_gets_the_new_cases_wrong(self):
        fx = load_fixtures()
        must_fail = {
            "parent_and_two_subagents",
            "empty_shell_then_real_file",
            "continuation_without_overlap",
            "fork_with_inherited_counter",
            "copied_history_before_meta",
            "copied_history_marked_by_ordinal",
            "counter_goes_down_and_back",
            "continuation_that_carries_its_counter_over",
            "migrated_subagent_counts_its_own_work",
            "migrated_subagent_skips_the_replayed_parent_tail",
            "migrated_subagent_without_an_inter_agent_message_counts_in_full",
            "interleaved_lineages_count_the_higher_only",
        }
        for case in fx["cases"]:
            if case["name"] in must_fail:
                with self.subTest(case=case["name"]):
                    self.assertNotEqual(run_case(case, fx, "legacy"), case["expected"])

    # Each single-rule control replaces one rule with what it replaced or left
    # out. It must get exactly the cases that rule governs wrong, and every
    # other case right: so each rule is shown to matter, and each control to
    # disable only its own rule.
    SINGLE_RULE_CONTROLS = {
        # keep the first file per payload.id
        "first-payload-id": {
            "empty_shell_then_real_file",
            "continuation_without_overlap",
            "continuation_that_carries_its_counter_over",
            "partial_overlap_both_count",
            "continuation_that_replays_the_previous_tail_counts_it_twice",
        },
        # no copy resolution at all
        "count-all-files": {"byte_identical_copy", "archived_prefix_of_live_file"},
        # any overlap in time makes a copy
        "any-overlap": {
            "partial_overlap_both_count",
            "continuation_that_replays_the_previous_tail_counts_it_twice",
        },
        # the carried-over-counter rule for subagents and forks only
        "children-only-inherit": {
            "continuation_that_carries_its_counter_over",
            "continuation_that_replays_the_previous_tail_counts_it_twice",
        },
        # copied history found only by time, not by line number
        "no-ordinal-rule": {"copied_history_marked_by_ordinal"},
        # the line-number boundary trusted without a copied session_meta ahead
        # of it: Codex's migrated subagent rollouts lose all their usage
        "ordinal-without-ancestor-meta": {
            "migrated_subagent_counts_its_own_work",
            "migrated_subagent_skips_the_replayed_parent_tail",
            "migrated_subagent_without_an_inter_agent_message_counts_in_full",
        },
        # a migrated rollout's events before the first inter-agent message
        # counted, not held: the parent's replayed tail is counted again
        "no-interagent-hold": {"migrated_subagent_skips_the_replayed_parent_tail"},
        # CodexBar's choice where the total grows by more than the request
        "last-over-gap": {"gap_over_last_counts_the_growth"},
        # each event's last_token_usage summed, no cumulative baseline
        "sum-last": {
            "repeated_total",
            "counter_goes_down_and_back",
            "counter_restart_counts_only_above_the_old_high",
            "gap_over_last_counts_the_growth",
            "interleaved_lineages_count_the_higher_only",
        },
        # events without a cumulative total ignored
        "totals-only": {"last_usage_only"},
    }

    def test_each_rule_changes_exactly_the_cases_it_governs(self):
        fx = load_fixtures()
        names = {c["name"] for c in fx["cases"]}
        for policy, must_fail in self.SINGLE_RULE_CONTROLS.items():
            self.assertLessEqual(must_fail, names, policy)
            for case in fx["cases"]:
                with self.subTest(policy=policy, case=case["name"]):
                    got = run_case(case, fx, policy)
                    if case["name"] in must_fail:
                        self.assertNotEqual(got, case["expected"])
                    else:
                        self.assertEqual(got, case["expected"])


class FirstLine(unittest.TestCase):
    """Mirrors the first-line tests in CodexTokenAccountingTests.swift."""

    def test_a_subagent_with_an_unreadable_first_line_is_not_taken_for_its_parent(self):
        parent_meta = meta("parent", "12:00:00")
        child_meta = meta(
            "child", "12:00:30", session_id="parent", parent_thread_id="parent",
            base_instructions={"text": "x" * (replica.FIRST_LINE_MAX_BYTES + 1)},
        )
        case = {"files": [
            {"path": "sessions/2026/09/10/rollout-parent.jsonl", "lines": [parent_meta, event("12:01:00", 1000, 1)]},
            {"path": "sessions/2026/09/10/rollout-child.jsonl",
             "lines": [child_meta, dict(parent_meta, ordinal=1), event("12:01:00", 500, 2)]},
        ]}
        self.assertEqual(total_input(run_case(case, SCAN)), 1500)

    def test_a_file_whose_first_line_is_still_being_written_is_left_for_the_next_scan(self):
        case = {"files": [
            {"path": "sessions/2026/09/10/rollout-done.jsonl",
             "lines": [meta("done", "12:00:00"), event("12:01:00", 1000, 1)]},
            {"path": "sessions/2026/09/10/rollout-new.jsonl", "lines": [],
             "unterminated": '{"timestamp":"2026-09-10T12:02'},
        ]}
        self.assertEqual(total_input(run_case(case, SCAN)), 1000)

    def test_a_later_session_meta_never_gives_a_file_its_identity(self):
        # The first line is not a session_meta: the file stays anonymous, so a
        # copied meta further down cannot make it look like a copy of another.
        other = {"timestamp": "2026-09-10T12:00:00.000Z", "type": "turn_context", "ordinal": 0,
                 "payload": {"model": "gpt-5.5"}}
        case = {"files": [
            {"path": "sessions/2026/09/10/rollout-a.jsonl",
             "lines": [meta("thread", "12:00:00"), event("12:01:00", 1000, 1)]},
            {"path": "sessions/2026/09/10/rollout-b.jsonl",
             "lines": [other, dict(meta("thread", "12:00:00"), ordinal=1), event("12:01:00", 700, 2)]},
        ]}
        self.assertEqual(total_input(run_case(case, SCAN)), 1700)


class CopiedPrefixMarkers(unittest.TestCase):
    """Mirrors the marker tests in CodexTokenAccountingTests.swift."""

    def child_meta(self, start: int, **extra) -> dict:
        return meta("child", "12:00:30", session_id="parent", parent_thread_id="parent",
                    subagent_history_start_ordinal=start, **extra)

    def test_a_long_copied_session_meta_still_marks_the_prefix(self):
        # Ancestors' session_meta lines carry their base instructions and are
        # often over 32 KB: the marker is read from the line's head.
        copied = dict(meta("parent", "12:00:00", base_instructions={"text": "x" * (replica.PREFIX_BYTES + 1)}),
                      ordinal=1)
        case = {"files": [
            {"path": "sessions/2026/09/10/rollout-child.jsonl",
             "lines": [self.child_meta(4), copied, event("12:00:31", 5000, 2), event("12:00:32", 5000, 3),
                       event("12:01:00", 400, 4)]},
        ]}
        self.assertEqual(total_input(run_case(case, SCAN)), 400)

    def test_a_session_meta_at_or_past_the_boundary_is_not_a_copy_marker(self):
        late = dict(meta("parent", "12:00:00"), ordinal=3)
        case = {"files": [
            {"path": "sessions/2026/09/10/rollout-child.jsonl",
             "lines": [self.child_meta(3), event("12:00:31", 700, 1), event("12:00:32", 900, 2), late]},
        ]}
        # No marker ahead of the boundary and no inter-agent message: all counts.
        self.assertEqual(total_input(run_case(case, SCAN)), 900)

    def test_a_migrated_file_resumed_past_its_boundary_counts_in_order(self):
        # Lines 1-2 are the migrated history (no marker ahead of the boundary
        # at 3); line 3 is a later request. The held events count first, so
        # the later one adds only its own 300.
        case = {"files": [
            {"path": "sessions/2026/09/10/rollout-child.jsonl",
             "lines": [self.child_meta(3), event("12:01:00", 700, 1),
                       dict(event("12:02:00", 900, 2), payload={"type": "token_count", "info": {
                           "total_token_usage": {"input_tokens": 900, "cached_input_tokens": 0, "output_tokens": 2},
                           "last_token_usage": {"input_tokens": 200, "cached_input_tokens": 0, "output_tokens": 1}}}),
                       dict(event("12:03:00", 1200, 3), payload={"type": "token_count", "info": {
                           "total_token_usage": {"input_tokens": 1200, "cached_input_tokens": 0, "output_tokens": 3},
                           "last_token_usage": {"input_tokens": 300, "cached_input_tokens": 0, "output_tokens": 1}}})]},
        ]}
        self.assertEqual(total_input(run_case(case, SCAN)), 1200)

    def test_line_ordinal_is_read_from_the_head(self):
        self.assertEqual(replica.line_ordinal(b'{"timestamp":"t","ordinal":12,"type":"session_meta"}'), 12)
        self.assertEqual(replica.line_ordinal(b'{"ordinal": 7}'), 7)
        self.assertIsNone(replica.line_ordinal(b'{"type":"session_meta"}'))
        self.assertIsNone(replica.line_ordinal(b"x" * 600 + b'"ordinal":3'))


class LastLine(unittest.TestCase):
    """A last line without a newline is read only when it already decodes."""

    def test_a_complete_last_line_without_a_newline_counts_and_a_half_one_does_not(self):
        lines = [meta("done", "12:00:00"), event("12:01:00", 1000, 1)]
        whole = json.dumps(event("12:02:00", 1600, 2), separators=(",", ":"))
        for tail, expected in ((whole, 1600), (whole[: len(whole) // 2], 1000)):
            with self.subTest(expected=expected):
                case = {"files": [{"path": "sessions/2026/09/10/rollout-done.jsonl", "lines": lines,
                                   "unterminated": tail}]}
                self.assertEqual(total_input(run_case(case, SCAN)), expected)


class LocalDay(unittest.TestCase):
    """Which local day an event is filed under, in the zone the test runs in
    (CI runs it in UTC; run it with TZ=America/Los_Angeles or TZ=Asia/Tokyo
    to check other zones). The shared fixtures sit at midday UTC, so they
    never test this."""

    def test_events_half_an_hour_either_side_of_local_midnight(self):
        def utc(local: datetime) -> str:
            return local.astimezone().astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

        before = datetime(2026, 9, 10, 23, 30)
        after = datetime(2026, 9, 11, 0, 30)
        u = lambda n, out: {"input_tokens": n, "cached_input_tokens": 0, "output_tokens": out}  # noqa: E731
        tok = lambda at, total, last, o: {  # noqa: E731
            "timestamp": utc(at), "type": "event_msg", "ordinal": o,
            "payload": {"type": "token_count",
                        "info": {"total_token_usage": u(total, o), "last_token_usage": u(last, 1)}}}
        head = meta("night", "12:00:00")
        head["timestamp"] = head["payload"]["timestamp"] = utc(datetime(2026, 9, 10, 23, 0))
        case = {"files": [{"path": "sessions/2026/09/10/rollout-night.jsonl",
                           "lines": [head, tok(before, 1000, 1000, 1), tok(after, 1600, 600, 2)]}]}
        got = run_case(case, SCAN)
        self.assertEqual(got, {"2026-09-10": {"gpt-5": [1000, 0, 1]}, "2026-09-11": {"gpt-5": [600, 0, 1]}})


class ModelNames(unittest.TestCase):
    def test_the_swift_price_table_is_found(self):
        # The replica drops a date suffix only when the rest names a row, as
        # the app does, so it reads the row names from the Swift table. If the
        # table moves and this finds nothing, dated names would silently stop
        # normalising.
        keys = replica._swift_codex_model_keys()
        self.assertIn("gpt-5.5", keys)
        self.assertIn("gpt-5.6-sol", keys)
        self.assertIn("gpt-6-astra", keys)
        self.assertNotIn("gpt-5.6", keys, "an alias is not a row")
        self.assertEqual(replica.normalize_codex_model("gpt-5.5-2026-04-23"), "gpt-5.5")
        self.assertEqual(replica.normalize_codex_model("openai/gpt-5.6-sol"), "gpt-5.6-sol")
        self.assertEqual(replica.normalize_codex_model("gpt-5.6-2026-08-01"), "gpt-5.6-2026-08-01")


class Timestamps(unittest.TestCase):
    def test_fast_parse_matches_iso(self):
        for text in (
            "2026-09-10T12:00:00.000Z",
            "2026-09-10T12:00:00.123Z",
            "2026-09-10T21:00:00.5+09:00",
            "2026-09-10T02:00:00-05:00",
            "2026-09-10T12:00:00Z",
        ):
            with self.subTest(text=text):
                iso = datetime.fromisoformat(text.replace("Z", "+00:00"))
                self.assertEqual(replica.parse_instant_ms(text), int(round(iso.timestamp() * 1000)))

    def test_milliseconds_are_kept_to_three_digits(self):
        a = replica.parse_instant_ms("2026-09-10T12:00:00.1239Z")
        b = replica.parse_instant_ms("2026-09-10T12:00:00.123Z")
        self.assertEqual(a, b)


class CopyResolver(unittest.TestCase):
    def f(self, path, rid, events, first, last, final=0):
        r = replica.FileResult(path=path, rollout_id=rid)
        r.event_count, r.first_ms, r.last_ms = events, first, last
        r.watermark = (final, 0, 0)
        return r

    def counted(self, *files):
        return replica.counted_paths(list(files), "overlap")

    def test_nested_copies_keep_the_one_with_more_events(self):
        self.assertEqual(self.counted(self.f("a", "x", 3, 10, 30), self.f("b", "x", 5, 10, 50)), {"b"})
        # the file taken first decides: a longer file with fewer events is not
        # inside the shorter one, so both count
        self.assertEqual(self.counted(self.f("a", "x", 3, 10, 60), self.f("b", "x", 5, 10, 50)), {"a", "b"})

    def test_equal_events_keep_the_larger_final_total_then_the_earlier_path(self):
        self.assertEqual(self.counted(self.f("a", "x", 2, 1, 5, 10), self.f("b", "x", 2, 1, 5, 20)), {"b"})
        self.assertEqual(self.counted(self.f("b", "x", 2, 1, 5, 10), self.f("a", "x", 2, 1, 5, 10)), {"a"})

    def test_a_span_inside_a_kept_one_is_a_copy_and_a_partial_overlap_is_not(self):
        self.assertEqual(self.counted(self.f("a", "x", 3, 1, 9), self.f("b", "x", 2, 3, 5)), {"a"})
        self.assertEqual(self.counted(self.f("a", "x", 2, 1, 5), self.f("b", "x", 1, 5, 9)), {"a", "b"})
        self.assertEqual(self.counted(self.f("a", "x", 2, 1, 5), self.f("b", "x", 1, 6, 9)), {"a", "b"})

    def test_files_without_events_or_ids_always_count(self):
        files = (self.f("a", "x", 0, None, None), self.f("b", "x", 4, 1, 9), self.f("c", None, 4, 1, 9))
        self.assertEqual(self.counted(*files), {"a", "b", "c"})


if __name__ == "__main__":
    unittest.main(verbosity=1)

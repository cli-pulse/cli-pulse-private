#!/usr/bin/env python3
"""Compare the app's Codex counting with CodexBar's, day by day.

CodexBar (https://github.com/steipete/CodexBar) reads the same
`~/.codex/sessions` logs and its CLI prints a per-day report:

    codexbar cost --provider codex --days 30 --format json

This script runs that command (or reads a saved copy with `--codexbar-json`),
counts the same logs with the app's rules (scripts/codex_accounting_replica.py),
and compares every day both report. It compares days, never totals: the app's
30-day window is 31 local days (today minus 30 through today) and CodexBar's is
30, so their sums differ by a whole day for reasons that are not counting.

A day that differs is either explained by a known difference, with the amount
computed from the logs, or reported as unexplained (exit 1).

KNOWN DIFFERENCES (the app's rules differ from CodexBar's; `explain()` computes
each day's amount from the logs, and must account for the whole difference of a
day in input, cached and output for the day to pass):

  migrated-subagent
      Codex's migration of older subagent rollouts rewrites them with the
      history boundary (`subagent_history_start_ordinal`) at the end of the
      file and without the copied session_meta lines, so every line is
      numbered before the boundary. CodexBar reads the boundary as it reads a
      current rollout's, and counts nothing from such a file. The app counts
      the subagent's own work in it: everything after its first inter-agent
      message (what comes before is the parent's replayed tail, not counted),
      or all of it when there is no such message. The amount is what the app
      counts from those events.

  gap-over-last
      Where a cumulative total grows by more than the event's own
      last_token_usage (a request that wrote no token event of its own, such
      as an aborted turn's), the app counts the growth and CodexBar counts
      last_token_usage. The amount is the growth beyond last_token_usage.

  older-file (a negative amount: CodexBar counts it, the app does not)
      The app reads the `sessions/YYYY/MM/DD` directories from the day before
      its window to the day after, so a rollout file in an older directory (a
      thread started earlier and still written to inside the window) is not
      read at all. CodexBar reads it. The amount is what the app's rules
      would count from those files.

A difference `explain()` does not compute, flagged on the days it touches:

  after-a-fall
      Once a cumulative total falls below the baseline, CodexBar counts the
      rest of that file differently: it treats a small fall as a stale
      snapshot, and after a real one counts the smaller of each event's own
      usage and the growth under its high mark. The app keeps skipping events
      below the baseline and counts the growth above it. The two agree on a
      single fall followed by a climb (the restart case below) and can differ
      on counters that interleave. An unexplained day with events counted
      after a fall says so.

Found and corrected: the line-number rule once dropped every migrated
subagent rollout, just as CodexBar does, and a day that differed because of
those files was put down to copied parent history. Nothing in them is copied
except the replayed tail described above.

NOT a difference, but worth knowing (reported, never counted by either):

  after-counter-restart
      A rollout whose cumulative counter falls back to one request's own usage
      and climbs again inside one file. The baseline only rises, in CodexBar
      and in the app, so requests after the restart are not counted until the
      counter passes its old high. The line shows how many such requests there
      were. Other falls below the baseline (dips, replayed snapshots) are not
      included in it.

`--cost` adds a per-day cost comparison at CodexBar's own standard rates
(its bundled table at 25bba9b7, for the models listed in CODEXBAR_RATES), so
that a cost difference can only come from counting, not from prices. It prices
each day's tokens as one amount, which equals per-request pricing only while no
request is over the 272K long-context threshold; the count of such requests
(by each event's own last_token_usage) is printed so that is visible.

Output is aggregate numbers only. CodexBar's JSON contains project paths; this
script reads only its `daily` rows and prints nothing else from it.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import date, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import codex_accounting_replica as replica  # noqa: E402

# CodexBar @25bba9b7 Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift,
# standard rates: (input, cached input, output) USD per token.
CODEXBAR_RATES = {
    "gpt-5.4": (2.5e-6, 2.5e-7, 1.5e-5),
    "gpt-5.5": (5e-6, 5e-7, 3e-5),
    "gpt-6-astra": (1e-5, 1e-6, 5e-5),
    "gpt-5.6-sol": (4e-6, 4e-7, 2e-5),
    "gpt-5.6-terra": (2e-6, 2e-7, 1.2e-5),
    "gpt-5.6-luna": (2e-7, 2e-8, 1.2e-6),
}


def load_codexbar(days: int, saved: str | None) -> list[dict]:
    if saved:
        with open(saved, encoding="utf-8") as fh:
            data = json.load(fh)
    else:
        out = subprocess.run(
            ["codexbar", "cost", "--provider", "codex", "--days", str(days), "--format", "json"],
            check=True, capture_output=True, text=True, timeout=600,
        ).stdout
        data = json.loads(out)
    report = data[0] if isinstance(data, list) else data
    rows = []
    for d in report.get("daily") or []:
        rows.append({
            "date": d["date"],
            "input": int(d.get("inputTokens") or 0),
            "cached": int(d.get("cacheReadTokens") or 0),
            "output": int(d.get("outputTokens") or 0),
            "cost": float(d.get("totalCost") or 0.0),
        })
    return rows


def unlisted_files(codex_home: str, res: replica.ScanResult) -> list[str]:
    """Rollout files under the Codex roots that the app's listing for this
    window does not reach (older date directories)."""
    listed = {f.path for f in res.files}
    listed.update(p for root in replica.roots_for(codex_home)
                  for p in replica.list_files(root, res.window.scan_since, res.window.scan_until))
    out = []
    for root in replica.roots_for(codex_home):
        for dirpath, _dirs, names in os.walk(root):
            for name in names:
                p = os.path.join(dirpath, name)
                if name.lower().endswith(".jsonl") and not name.startswith(".") and p not in listed:
                    out.append(p)
    return sorted(out)


def explain(res: replica.ScanResult, codex_home: str | None = None) -> dict:
    """Per day, the [input, cached, output] the app counts that CodexBar does
    not (negative where CodexBar counts more), by reason (see KNOWN
    DIFFERENCES)."""
    out: dict = {}
    if codex_home:
        for path in unlisted_files(codex_home, res):
            f = replica.parse_file(path, res.window.scan_since, res.window.scan_until, "overlap")
            for day, models in f.days.items():
                if not (res.window.since <= day <= res.window.until):
                    continue
                dst = out.setdefault(day, {}).setdefault("older-file", [0, 0, 0])
                for row in models.values():
                    for i in range(3):
                        dst[i] -= row[i]
    for f in res.files:
        if f.path not in res.counted:
            continue
        for reason, days in (("migrated-subagent", f.unmarked_prefix_days), ("gap-over-last", f.gap_days)):
            for day, models in days.items():
                if not (res.window.since <= day <= res.window.until):
                    continue
                dst = out.setdefault(day, {}).setdefault(reason, [0, 0, 0])
                for row in models.values():
                    for i in range(3):
                        dst[i] += row[i]
    return out


def fall_days(res: replica.ScanResult) -> set:
    return {d for f in res.files if f.path in res.counted for d in f.fall_days}


def restart_note(res: replica.ScanResult) -> tuple[int, int]:
    files = sum(1 for f in res.files if f.path in res.counted and f.restart_skips)
    events = sum(f.restart_skips for f in res.files if f.path in res.counted)
    return files, events


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--codex-home", default=os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"))
    ap.add_argument("--days", type=int, default=30, help="CodexBar's --days (default 30)")
    ap.add_argument("--today", help="local date both windows end on (default: today)")
    ap.add_argument("--codexbar-json", help="a saved `codexbar cost ... --format json` output instead of running it")
    ap.add_argument("--cost", action="store_true", help="also compare cost at CodexBar's standard rates")
    args = ap.parse_args(argv)

    today = date.fromisoformat(args.today) if args.today else date.today()
    first_day = today - timedelta(days=args.days - 1)
    cb = {r["date"]: r for r in load_codexbar(args.days, args.codexbar_json)}
    # The app's window for `days` covers first_day - 1 .. today: every CodexBar day.
    res = replica.scan(args.codex_home, today, args.days, "overlap")
    mine = res.day_totals()
    reasons = explain(res, args.codex_home)
    fell = fall_days(res)

    print(f"CodexBar window {first_day}..{today}; app window {res.window.since}..{res.window.until}")
    print("day         app input/cached/output        CodexBar input/cached/output   verdict")
    exact = explained = unexplained = 0
    for day in sorted(set(cb) | {d for d in mine if d >= first_day.isoformat()}):
        a = mine.get(day, [0, 0, 0])
        c = cb.get(day)
        b = [c["input"], c["cached"], c["output"]] if c else [0, 0, 0]
        fmt = lambda t: "/".join(f"{x / 1e6:.2f}M" for x in t)  # noqa: E731
        if a == b:
            exact += 1
            verdict = "same"
        else:
            diff = [a[i] - b[i] for i in range(3)]
            known = reasons.get(day, {})
            covered = [sum(v[i] for v in known.values()) for i in range(3)]
            described = ", ".join(f"{k} {v[0] / 1e6:+.2f}M input" for k, v in known.items())
            if known and diff == covered:
                explained += 1
                verdict = "explained: " + described
            else:
                unexplained += 1
                verdict = f"UNEXPLAINED input diff {diff[0] / 1e6:+.2f}M"
                if known:
                    verdict += " (known reasons cover " + described + ")"
                if day in fell:
                    verdict += " (events counted after a counter fell: after-a-fall)"
        print(f"{day}  {fmt(a):>30}  {fmt(b):>30}   {verdict}")

    files, events = restart_note(res)
    print(f"{exact} day(s) identical, {explained} explained, {unexplained} unexplained")
    print(f"after-counter-restart: {events} request(s) in {files} file(s) not counted by either (baseline only rises)")
    long_requests = sum(f.long_requests for f in res.files if f.path in res.counted)
    print(f"requests over 272K input: {long_requests}")

    if args.cost:
        total_app = total_cb = 0.0
        unpriced = defaultdict(int)
        for day in sorted(cb):
            cost = 0.0
            for model, row in res.days.get(day, {}).items():
                rate = CODEXBAR_RATES.get(model)
                if not rate:
                    unpriced[model] += row[0]
                    continue
                cost += (row[0] - row[1]) * rate[0] + row[1] * rate[1] + row[2] * rate[2]
            total_app += cost
            total_cb += cb[day]["cost"]
        print(f"cost on CodexBar's days at CodexBar's rates: app ${total_app:.2f}, CodexBar ${total_cb:.2f}")
        if unpriced:
            print("models without a rate here (input): " + ", ".join(f"{m} {v / 1e6:.2f}M" for m, v in unpriced.items()))
    return 1 if unexplained else 0


if __name__ == "__main__":
    sys.exit(main())

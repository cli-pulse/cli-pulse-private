#!/usr/bin/env python3
"""A Python replica of how the app counts Codex tokens, for checking the app.

It mirrors `CostUsageScanner` (Codex half) and `CodexTokenAccounting.swift`
rule for rule: which rollout files are read, how each `token_count` event is
counted, which files count, and which local day each token lands on. Run next
to the app, both should give the same input / cached / output for every day
(`--app-cache` does that comparison).

Three uses:

  * Check the app on a real machine:
        scripts/codex_accounting_replica.py --app-cache ~/Library/Caches/CLIPulse/cost-usage/codex-v2.json
    (the Mac App Store build keeps that file inside its container). The window
    is taken from the cache's own last scan, so a cache written a minute ago
    compares cleanly; a file being written to right now may differ slightly.
  * Print the per-day numbers:  scripts/codex_accounting_replica.py [--days 30]
  * Be imported by scripts/test_codex_accounting_replica.py and
    scripts/codex_codexbar_daily_compare.py.

Output is aggregate numbers only: per-day token counts and file counts. It
never prints a path, a model's conversation, or anything else from a log.

Rules mirrored (Swift names in brackets):

  * Selection [listCodexSessionFiles, codexSessionsRoots]: `sessions/YYYY/MM/DD`
    directories from one day before the window to one day after it, the same
    under `archived_sessions/`, plus `*.jsonl` directly in either root unless
    the file name carries a date outside that range. A file reached twice (a
    hard link) is read once.
  * Lines [readCodexFirstLine, scanJsonl, parseCodexFile]: the first line
    (up to 1 MB) alone gives the file's identity; a file whose first line has
    no newline yet is left for the next refresh, and a last line without a
    newline is read only when it already decodes. A later session_meta line
    (an ancestor's, copied in) and an `inter_agent_communication_metadata`
    line are recognised from the line's head at any length; every other line
    over 32 KB is skipped, and only lines holding the compact
    `"type":"event_msg"` (with `token_count`) or `"type":"turn_context"` are
    decoded.
  * Counting [CodexTokenAccountant]: the cumulative total's baseline only rises;
    a total below it is skipped; a file's first own event whose total exceeds
    its `last` starts from that difference (a counter carried over). A
    subagent's or fork's copied history is not counted: events stamped before
    its own session_meta; events numbered before its
    `subagent_history_start_ordinal` once an ancestor's session_meta has been
    copied in ahead of them; and, in a child whose boundary has no copied
    session_meta ahead of it (the shape Codex's migration of older subagent
    rollouts leaves), the events before its first inter-agent message: they
    are held until that message (then dropped) or the end of the read (then
    counted). Until a child with a history ordinal counts its first tokens, a
    repeat of the counter it started from (the last copied total, or an
    opening total with no request of its own) and a copied snapshot (a total
    equal to its own request, at or above that counter) add nothing.
  * Subagents without a history ordinal [CodexSubagentRolloutShape, ported
    from CodexBar]: the file is read whole first. Its own history starts at a
    turn_context immediately followed by an inter-agent message that triggers
    a turn — the first after the last copied ancestor session_meta, or, in a
    rollout that names the thread it was forked from, its first turn once its
    first own event confirms it — or at an opening total with no request of
    its own. Events before it are copied; counting starts from the counter it
    had there. Without one, the rules above apply.
  * Files [CodexCopyResolver]: files sharing `session_meta.payload.id` are
    copies only when one's event span lies within another's; files are taken
    with the most events first (then the larger final total, then the earlier
    path).

`--policy` other than `overlap` selects a negative control for the fixture
test — one rule replaced by what it replaced or left out — and is not the app:
`legacy` (the scanner before 1.56), `first-payload-id`, `count-all-files`,
`any-overlap`, `children-only-inherit`, `no-ordinal-rule`,
`ordinal-without-ancestor-meta`, `no-interagent-hold`, `last-over-gap`,
`sum-last`, `totals-only`, `no-snapshot-skip`, `no-turn-marker`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone

PREFIX_BYTES = 32 * 1024
FIRST_LINE_MAX_BYTES = 1 << 20
POLICIES = (
    "overlap",
    # negative controls, not the app:
    "legacy",
    "first-payload-id",
    "count-all-files",
    "any-overlap",
    "children-only-inherit",
    "no-ordinal-rule",
    "ordinal-without-ancestor-meta",
    "no-interagent-hold",
    "last-over-gap",
    "sum-last",
    "totals-only",
    "no-snapshot-skip",
    "no-turn-marker",
)

# How a child's copied prefix was recognised [CodexCopiedPrefix]
ANCESTOR_METADATA = "ancestor-metadata"
INTER_AGENT_MESSAGE = "inter-agent-message"
NO_MARKER = "no-marker"

_FILENAME_DATE = re.compile(r"(\d{4}-\d{2}-\d{2})")
_DATED_SUFFIX = re.compile(r"-\d{4}-\d{2}-\d{2}$")


# --------------------------------------------------------------------------
# Model names (only the display key: token counts do not depend on it)


def _swift_codex_model_keys() -> set[str]:
    """The Codex pricing keys in the Swift table (`CodexPricingTable.current`),
    read from the source so a dated model name normalises the same way the app
    stores it. `test_the_swift_price_table_is_found` fails if this stops
    finding it."""
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.join(
        here, "..", "CLI Pulse Bar", "CLIPulseCore", "Sources", "CLIPulseCore", "CodexPricingTable.swift"
    )
    try:
        text = open(src, encoding="utf-8").read()
    except OSError:
        return set()
    start = text.find("static let current: [String: Rates] = [")
    if start < 0:
        return set()
    end = text.find("\n    ]\n", start)
    block = text[start:end if end > 0 else len(text)]
    return set(re.findall(r'^\s*"([^"]+)"\s*:', block, flags=re.M))


_MODEL_KEYS = _swift_codex_model_keys()


def normalize_codex_model(raw: str) -> str:
    trimmed = raw.strip()
    if trimmed.startswith("openai/"):
        trimmed = trimmed[len("openai/"):]
    if trimmed in _MODEL_KEYS:
        return trimmed
    m = _DATED_SUFFIX.search(trimmed)
    if m and trimmed[: m.start()] in _MODEL_KEYS:
        return trimmed[: m.start()]
    return trimmed


# --------------------------------------------------------------------------
# Timestamps [instantFromTimestamp]


def _digit(b: bytes, i: int) -> int | None:
    if 0 <= i < len(b) and 48 <= b[i] <= 57:
        return b[i] - 48
    return None


def _two(b: bytes, i: int) -> int | None:
    d0, d1 = _digit(b, i), _digit(b, i + 1)
    return None if d0 is None or d1 is None else d0 * 10 + d1


def parse_instant_ms(text: str) -> int | None:
    """Unix milliseconds of an ISO-8601 log timestamp, like the Swift fast
    parse (whole seconds plus the first three fraction digits), with an ISO
    fallback. Malformed-but-parseable dates (month 13) are not normalised the
    way Foundation's calendar would; real Codex logs never contain them."""
    b = text.encode("utf-8")
    ms = _fast_instant_ms(b)
    if ms is not None:
        return ms
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        return None
    return int(round(dt.timestamp() * 1000))


def _fast_instant_ms(b: bytes) -> int | None:
    if len(b) < 20 or b[4:5] != b"-" or b[7:8] != b"-":
        return None
    year = None
    if all(_digit(b, i) is not None for i in range(4)):
        year = int(b[0:4])
    month, day = _two(b, 5), _two(b, 8)
    if year is None or month is None or day is None:
        return None
    hour = minute = second = 0
    if b[10:11] == b"T":
        if b[13:14] != b":" or b[16:17] != b":":
            return None
        h, mi, s = _two(b, 11), _two(b, 14), _two(b, 17)
        if h is None or mi is None or s is None:
            return None
        hour, minute, second = h, mi, s
    tz_index = None
    sign = 0
    for idx in range(len(b) - 1, 10, -1):
        ch = b[idx]
        if ch == 90:  # Z
            tz_index, sign = idx, 0
            break
        if ch == 43:  # +
            tz_index, sign = idx, 1
            break
        if ch == 45:  # -
            tz_index, sign = idx, -1
            break
    if tz_index is None:
        return None
    offset = 0
    if sign != 0:
        start = tz_index + 1
        hours = _two(b, start)
        if hours is None:
            return None
        minutes = 0
        if len(b) > start + 2:
            if b[start + 2] == 58:
                m = _two(b, start + 3)
                if m is not None:
                    minutes = m
            else:
                m = _two(b, start + 2)
                if m is not None:
                    minutes = m
        offset = sign * (hours * 3600 + minutes * 60)
    millis = 0
    if b[19:20] == b".":
        scale, idx = 100, 20
        while scale > 0:
            d = _digit(b, idx)
            if d is None:
                break
            millis += d * scale
            scale //= 10
            idx += 1
    try:
        dt = datetime(year, month, day, hour, minute, second, tzinfo=timezone(timedelta(seconds=offset)))
    except ValueError:
        return None
    return int(dt.timestamp()) * 1000 + millis


def local_day_key(ms: int, tz: timezone | None = None) -> str:
    dt = datetime.fromtimestamp(ms / 1000, tz) if tz else datetime.fromtimestamp(ms / 1000)
    return dt.strftime("%Y-%m-%d")


# --------------------------------------------------------------------------
# Counting one file [CodexTokenAccountant]


def _to_int(v) -> int:
    """A token count: 0 for anything that is not a positive number, capped at
    10^15 (Swift clamps so no conversion or sum can trap)."""
    if isinstance(v, bool):
        n = float(v)
    elif isinstance(v, (int, float)):
        n = float(v)
    else:
        return 0
    if n != n or n <= 0 or n == float("inf"):
        return 0
    if n >= 1e15:
        return 10**15
    return max(0, int(v))


def _as_int(v) -> int | None:
    """What Swift's `as? Int` gives for a JSON value (ordinals)."""
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return None


def _totals(usage) -> tuple[int, int, int] | None:
    if not isinstance(usage, dict):
        return None
    cached_raw = usage["cached_input_tokens"] if "cached_input_tokens" in usage else usage.get("cache_read_input_tokens")
    return (_to_int(usage.get("input_tokens")), _to_int(cached_raw), _to_int(usage.get("output_tokens")))


def _sub(a, b):
    return tuple(max(0, x - y) for x, y in zip(a, b))


def _is_zero(t) -> bool:
    return t[0] == 0 and t[1] == 0 and t[2] == 0


def names_parent(payload: dict) -> bool:
    for key in ("parent_thread_id", "forked_from_id"):
        v = payload.get(key)
        if isinstance(v, str) and v:
            return True
    src = payload.get("source")
    return (isinstance(src, dict) and "subagent" in src) or is_subagent_source(payload) or explicit_parent_id(payload) is not None


def is_subagent_source(payload: dict) -> bool:
    """A subagent's rollout [CodexTokenAccountant.sessionMetaIsSubagent]:
    `source` is "subagent", or an object with a `subagent` entry."""
    src = payload.get("source")
    if isinstance(src, str):
        return src.strip().lower() == "subagent"
    return isinstance(src, dict) and isinstance(src.get("subagent"), (str, dict))


def explicit_parent_id(payload: dict) -> str | None:
    """The thread a rollout says it was forked from
    [CodexTokenAccountant.sessionMetaForkParent]."""
    for key in ("forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"):
        v = payload.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None


# --------------------------------------------------------------------------
# Where a subagent's own history starts, without a history ordinal
# [CodexSubagentRolloutShape, ported from CodexBar]

COPIED_PREFIX = "copied-prefix"
INDEPENDENT = "independent"


@dataclass
class Observation:
    """One line of a subagent rollout, as the classification sees it."""
    line: int
    kind: str  # "meta" | "turn" | "message" | "tokens"
    id: str | None = None
    trigger: bool = False
    total: tuple[int, int, int] | None = None
    last: tuple[int, int, int] | None = None


@dataclass
class OwnedSuffix:
    start: int
    baseline: tuple[int, int, int]
    first_token: int | None = None


@dataclass
class RolloutShape:
    semantics: str
    owned: OwnedSuffix | None
    # (suffix, parent totals at the boundary, locally confirmed)
    candidate: tuple | None


def _norm_id(v) -> str | None:
    if not isinstance(v, str):
        return None
    v = v.strip()
    return v or None


def _usage(t) -> bool:
    return t[0] > 0 or t[1] > 0 or t[2] > 0


def _at_least(a, b) -> bool:
    return a[0] >= b[0] and a[1] >= b[1] and a[2] >= b[2]


def classify_ids(leaf: str | None, ids: list) -> str:
    nleaf = _norm_id(leaf)
    ancestors = [i for i in map(_norm_id, ids) if i != nleaf]
    embedded = bool(ancestors) or (nleaf is None and len(ids) > 1)
    return COPIED_PREFIX if embedded else INDEPENDENT


def classify(leaf: str | None, obs: list, has_explicit_parent: bool = False) -> RolloutShape:
    """[CodexSubagentRolloutShape.classify]: whether a subagent rollout starts
    with copied history, and where its own history starts."""
    semantics = classify_ids(leaf, [o.id for o in obs if o.kind == "meta"])
    can_propose = semantics == INDEPENDENT and has_explicit_parent
    if not (semantics == COPIED_PREFIX or can_propose):
        return RolloutShape(semantics, None, None)
    nleaf = _norm_id(leaf)
    last_raw = None
    pending = None  # (line, baseline)
    owned = None
    parent_at_boundary = None
    confirmed = False
    inspected = False
    saw_leaf = False
    saw_turn = False
    inherited_opening = False
    for o in obs:
        if o.kind == "meta":
            embedded = (_norm_id(o.id) != nleaf if nleaf is not None else True) if saw_leaf else False
            saw_leaf = True
            if embedded:
                owned, parent_at_boundary, confirmed, inspected = None, None, False, False
            pending = None
        elif o.kind == "turn":
            first_turn = not saw_turn
            saw_turn = True
            accepts = semantics == COPIED_PREFIX or (can_propose and first_turn)
            pending = (o.line, last_raw) if accepts and last_raw is not None else None
            if inherited_opening and first_turn and pending is not None:
                owned = OwnedSuffix(pending[0], pending[1])
                inspected = False
        elif o.kind == "message":
            if (owned is None and o.trigger and pending is not None and o.line == pending[0] + 1
                    and (semantics == COPIED_PREFIX or _usage(pending[1]))):
                owned = OwnedSuffix(pending[0], pending[1])
                parent_at_boundary = pending[1]
                confirmed = False
                inspected = False
            pending = None
        else:
            total, last = o.total, o.last
            if (last_raw is None and can_propose and not saw_turn and total is not None and last is not None
                    and _usage(total) and not _usage(last)):
                # An opening total with no request of its own is inherited.
                inherited_opening = True
                owned = OwnedSuffix(o.line, total)
                parent_at_boundary = total
                confirmed = True
            if (inherited_opening and not saw_turn and total is not None and last is not None and _usage(last)
                    and total != last_raw):
                inherited_opening = False
                owned = OwnedSuffix(o.line, last_raw if last_raw is not None else total)
                inspected = False
            if not inspected and owned is not None and total is not None and total != owned.baseline:
                inspected = True
                if last is not None:
                    snapshot = _usage(owned.baseline) and total == last and _at_least(total, owned.baseline)
                    owned = OwnedSuffix(owned.start, total if snapshot else _sub(total, last), o.line)
                    inspected = not snapshot
                    confirmed = True
            if total is not None:
                last_raw = total
            pending = None
    if semantics == COPIED_PREFIX:
        return RolloutShape(COPIED_PREFIX, owned, None)
    candidate = (owned, parent_at_boundary, confirmed) if owned is not None and parent_at_boundary is not None else None
    return RolloutShape(INDEPENDENT, None, candidate)


@dataclass
class Event:
    """One token_count event, with what the caller needs to file it: its local
    day and the model in effect when it was written [CodexTokenAccountant.Event]."""
    ms: int
    ordinal: int | None
    total: tuple[int, int, int] | None
    last: tuple[int, int, int] | None
    day: str
    model: str


@dataclass
class FileResult:
    path: str
    # False when the first line is not complete yet: the app keeps nothing
    # from such a file this time and reads it again on the next refresh.
    complete: bool = True
    session_id: str | None = None
    rollout_id: str | None = None
    # parent_thread_id, else forked_from_id (for the CodexBar comparison only)
    parent_id: str | None = None
    is_child: bool = False
    meta_ms: int | None = None
    history_start_ordinal: int | None = None
    # ANCESTOR_METADATA / INTER_AGENT_MESSAGE / NO_MARKER, or None while undecided
    copied_prefix: str | None = None
    # a subagent's rollout (`source`), and whether it names the thread it was
    # forked from (`forked_from_id` and its spellings)
    is_subagent: bool = False
    explicit_parent: bool = False
    # A child with a history ordinal, until it counts its first tokens: the
    # cumulative total it is known to start from [CodexTokenAccountant rule 4]
    inherited_ref: tuple[int, int, int] | None = None
    opening_settled: bool = False
    # a subagent without a history ordinal whose own history was found to
    # start at a turn followed by an inter-agent message (counts only)
    turn_marker: bool = False
    saw_meta: bool = False
    baseline_checked: bool = False
    event_count: int = 0
    first_ms: int | None = None
    last_ms: int | None = None
    watermark: tuple[int, int, int] | None = None
    # day -> model -> [input, cached, output]
    days: dict = field(default_factory=dict)
    # events held until the first inter-agent message [CodexTokenAccountant.pending]
    pending: list = field(default_factory=list)
    # events skipped by each rule, for the CodexBar comparison (counts only)
    skipped_copied: int = 0
    replayed_tail_skips: int = 0
    restart_skips: int = 0
    dip_skips: int = 0
    inherited_input: int = 0
    _in_restart: bool = False
    # requests over 272K input (the long-context threshold), by their own `last`
    long_requests: int = 0
    # For the CodexBar comparison, per day [input, cached, output]:
    #   tokens counted from events numbered before the history boundary of a
    #   child whose boundary has no copied session_meta ahead of it (CodexBar
    #   counts none of these);
    unmarked_prefix_days: dict = field(default_factory=dict)
    #   counted growth of the cumulative total beyond the event's own `last`
    #   (CodexBar counts `last` there).
    gap_days: dict = field(default_factory=dict)
    #   days with events counted after the cumulative total fell below the
    #   baseline in this file (CodexBar counts those differently).
    fall_days: set = field(default_factory=set)
    _fell: bool = False

    @property
    def skipped_decrease(self) -> int:
        return self.restart_skips + self.dip_skips

    # -- copied-prefix markers [observeCopiedSessionMeta, observeInterAgentMessage]

    def _awaits_marker(self) -> bool:
        return self.is_child and self.history_start_ordinal is not None and self.copied_prefix is None

    def observe_copied_session_meta(self, ordinal) -> None:
        """A session_meta after the first line: an ancestor's, copied in with
        its history. Numbered before the boundary, it marks the file's
        copied prefix by line number."""
        if not self._awaits_marker():
            return
        if ordinal is not None and ordinal >= self.history_start_ordinal:
            return
        self.copied_prefix = ANCESTOR_METADATA
        self.skipped_copied += len(self.pending)
        self._drop_pending()

    def observe_inter_agent_message(self, ordinal) -> None:
        """An inter-agent message numbered before the boundary of a child with
        no copied session_meta ahead of it: what came before it was the
        parent's replayed tail."""
        if not self._awaits_marker():
            return
        if ordinal is not None and ordinal >= self.history_start_ordinal:
            return
        self.copied_prefix = INTER_AGENT_MESSAGE
        self.replayed_tail_skips += len(self.pending)
        self._drop_pending()

    def _drop_pending(self) -> None:
        """The held events were copied: not counted; the last total among
        them is the counter the child starts from (rule 4)."""
        for ev in reversed(self.pending):
            if ev.total is not None:
                self.inherited_ref = ev.total
                break
        self.pending.clear()

    def receive(self, ev: Event, policy: str) -> list:
        """[(event, delta)] counted now, in order [CodexTokenAccountant.receive]."""
        released = []
        if self._awaits_marker() and ev.ordinal is not None:
            if ev.ordinal < self.history_start_ordinal:
                if policy not in ("legacy", "no-interagent-hold"):
                    self.pending.append(ev)
                    return []
            else:
                # Past the boundary with no marker ahead of it: the held
                # events were the file's own, and count before this one.
                released = self.finish(policy)
        delta = self.count(ev.ms, ev.ordinal, ev.total, ev.last, policy)
        return released if delta is None else released + [(ev, delta)]

    def finish(self, policy: str) -> list:
        """No marker came: the held events count, in order
        [CodexTokenAccountant.finish]. Called at the end of every read, and
        when the file goes past its boundary."""
        if not self.pending:
            return []
        self.copied_prefix = NO_MARKER
        held, self.pending = self.pending, []
        out = []
        for ev in held:
            delta = self.count(ev.ms, ev.ordinal, ev.total, ev.last, policy)
            if delta is not None:
                out.append((ev, delta))
        return out

    def count(self, event_ms: int, ordinal, total, last, policy: str):
        if total is None and last is None:
            return None
        if policy == "legacy":
            # Pre-1.56: delta against the previous total, whatever it was.
            if total is not None:
                prev = self.watermark or (0, 0, 0)
                delta = _sub(total, prev)
                self.watermark = total
            else:
                delta = last
            return None if _is_zero(delta) else delta
        if self.is_child:
            by_ordinal = (
                policy != "no-ordinal-rule"
                and self.history_start_ordinal is not None
                and ordinal is not None
                and ordinal < self.history_start_ordinal
                and (self.copied_prefix == ANCESTOR_METADATA or policy == "ordinal-without-ancestor-meta")
            )
            if by_ordinal or (self.meta_ms is not None and event_ms < self.meta_ms):
                self.skipped_copied += 1
                if total is not None:
                    self.inherited_ref = total
                return None
        self.event_count += 1
        self.first_ms = event_ms if self.first_ms is None else min(self.first_ms, event_ms)
        self.last_ms = event_ms if self.last_ms is None else max(self.last_ms, event_ms)
        if policy == "sum-last":
            # Negative control: each event's own usage, repeats and all.
            use = last if last is not None else total
            if total is not None:
                self.watermark = total
            return None if _is_zero(use) else use
        if total is None:
            self.baseline_checked = True
            if policy == "totals-only":
                return None
            return self._opening_counted(None if last is None or _is_zero(last) else last)
        opening = self._in_opening(policy)
        if opening and self.inherited_ref is not None:
            # Rule 4: until a child counts its first tokens, a repeat of the
            # counter it started from, or a copied snapshot (a total equal to
            # its own request, at or above that counter), adds nothing.
            ref = self.inherited_ref
            if total == ref:
                return None
            if _usage(ref) and last is not None and total == last and _at_least(total, ref):
                self.inherited_ref = total
                if self.baseline_checked:
                    self.watermark = total if self.watermark is None else tuple(
                        max(a, b) for a, b in zip(self.watermark, total))
                return None
        if not self.baseline_checked and (self.is_child or policy != "children-only-inherit"):
            self.baseline_checked = True
            if last is not None:
                inherited = _sub(total, last)
            elif self.is_child:
                # Without `last`, a child's first total is inherited: all of
                # it, or what exceeds the counter it is known to start from.
                inherited = self.inherited_ref if opening and self.inherited_ref is not None else total
            else:
                inherited = (0, 0, 0)
            if not _is_zero(inherited):
                self.inherited_input += inherited[0]
                self.watermark = (
                    inherited if self.watermark is None else tuple(max(a, b) for a, b in zip(self.watermark, inherited))
                )
        if self.watermark is not None:
            base = self.watermark
            if total[0] < base[0] or total[1] < base[1] or total[2] < base[2]:
                # A restart: the total fell to this request's own usage.
                if total == last:
                    self._in_restart = True
                if self._in_restart:
                    self.restart_skips += 1
                else:
                    self.dip_skips += 1
                self._fell = True
                return None
            delta = _sub(total, base)
            self.watermark = total
            self._in_restart = False
        else:
            self.watermark = total
            delta = total
        if policy == "last-over-gap" and last is not None:
            # Negative control: CodexBar's choice, the request's own usage
            # where the total grew by more.
            delta = tuple(min(d, x) for d, x in zip(delta, last))
        return self._opening_counted(None if _is_zero(delta) else delta)

    def _in_opening(self, policy: str) -> bool:
        return (self.is_child and self.history_start_ordinal is not None and not self.opening_settled
                and policy != "no-snapshot-skip")

    def _opening_counted(self, delta):
        """Rule 4's bookkeeping after an event: the opening ends with the
        first tokens counted; until then the baseline is the counter the
        child starts from."""
        if self.is_child and self.history_start_ordinal is not None and not self.opening_settled:
            if delta is None:
                if self.watermark is not None:
                    self.inherited_ref = self.watermark
            else:
                self.opening_settled = True
        return delta


def _add_row(days: dict, day: str, model: str, t) -> None:
    row = days.setdefault(day, {}).setdefault(model, [0, 0, 0])
    row[0] += t[0]
    row[1] += min(t[1], t[0])
    row[2] += t[2]


def _file_counted(res: FileResult, ev: Event, delta, scan_since: str, scan_until: str) -> None:
    """File one counted event [parseCodexFile's add]."""
    if (ev.last or delta)[0] > 272_000:
        res.long_requests += 1
    if not (scan_since <= ev.day <= scan_until):
        return
    model = normalize_codex_model(ev.model)
    _add_row(res.days, ev.day, model, delta)
    if res._fell:
        res.fall_days.add(ev.day)
    start = res.history_start_ordinal
    if (
        res.is_child
        and start is not None
        and ev.ordinal is not None
        and ev.ordinal < start
        and res.copied_prefix != ANCESTOR_METADATA
    ):
        _add_row(res.unmarked_prefix_days, ev.day, model, delta)
    elif ev.last is not None:
        beyond = _sub(delta, ev.last)
        if not _is_zero(beyond):
            _add_row(res.gap_days, ev.day, model, beyond)


_ORDINAL = re.compile(rb'"ordinal":[ \t\r]*(-?\d{1,18})')


def line_ordinal(head: bytes) -> int | None:
    """A line's own number, read from its first 512 bytes without decoding
    the line [codexLineOrdinal]: the lines it is needed for can be long."""
    m = _ORDINAL.search(head[:512])
    return int(m.group(1)) if m else None


def _observe_first_line(res: FileResult, line: bytes) -> None:
    """The file's identity, from its first line only [parseCodexFile]."""
    res.saw_meta = True
    if b'"type":"session_meta"' not in line:
        return
    try:
        obj = json.loads(line)
    except ValueError:
        return
    if not isinstance(obj, dict) or obj.get("type") != "session_meta":
        return
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else None
    p = payload or {}
    res.session_id = next(
        (v for v in (p.get("session_id"), p.get("sessionId"), p.get("id"), obj.get("session_id")) if isinstance(v, str)),
        None,
    )
    res.rollout_id = p.get("id") if isinstance(p.get("id"), str) else None
    res.is_child = names_parent(payload) if payload is not None else False
    for key in ("parent_thread_id", "forked_from_id"):
        if isinstance(p.get(key), str) and p.get(key):
            res.parent_id = p[key]
            break
    res.history_start_ordinal = _as_int(p.get("subagent_history_start_ordinal"))
    res.is_subagent = is_subagent_source(p)
    res.explicit_parent = explicit_parent_id(p) is not None
    meta_time = p.get("timestamp") if isinstance(p.get("timestamp"), str) else obj.get("timestamp")
    res.meta_ms = parse_instant_ms(meta_time) if isinstance(meta_time, str) else None


_HEAD_ID = re.compile(rb'"id":"([^"\\]*)"')


def _later_meta_id(raw: bytes) -> tuple[str | None, bool]:
    """A later session_meta's thread id and whether it names a fork parent
    [codexLaterSessionMeta]: decoded when the line is short enough to be read
    whole, else the first `"id":"…"` in its head (no parent known)."""
    if len(raw) <= PREFIX_BYTES:
        try:
            obj = json.loads(raw)
        except ValueError:
            obj = None
        if isinstance(obj, dict):
            p = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
            ident = next((v for v in (p.get("id"), obj.get("id"), p.get("session_id"), p.get("sessionId"),
                                      obj.get("session_id"), obj.get("sessionId")) if isinstance(v, str)), None)
            return ident, explicit_parent_id(p) is not None
    m = _HEAD_ID.search(raw[:TRUNCATED_HEAD_BYTES])
    return (m.group(1).decode("utf-8", "replace") if m else None), False


def _trigger_turn(raw: bytes) -> bool | None:
    """An inter-agent message line: whether it triggers a turn; None when it
    is not one, or has no valid timestamp [codexInterAgentTrigger]."""
    if len(raw) > PREFIX_BYTES:
        return None
    try:
        obj = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(obj, dict) or obj.get("type") != "inter_agent_communication_metadata":
        return None
    ts = obj.get("timestamp")
    if not isinstance(ts, str) or parse_instant_ms(ts) is None:
        return None
    payload = obj.get("payload")
    return isinstance(payload, dict) and payload.get("trigger_turn") is True


TRUNCATED_HEAD_BYTES = 4096


def _decodes(line: bytes) -> bool:
    """Whether a line is a whole JSON object or array (JSONSerialization's
    default, without fragments)."""
    try:
        return isinstance(json.loads(line), (dict, list))
    except ValueError:
        return False


def parse_file(path: str, scan_since: str, scan_until: str, policy: str, tz=None) -> FileResult:
    legacy = policy == "legacy"
    res = FileResult(path=path)
    model = None
    with open(path, "rb") as fh:
        data = fh.read()
    if not legacy:
        newline = data.find(b"\n")
        if newline < 0:
            if len(data) > FIRST_LINE_MAX_BYTES:
                res.saw_meta = True  # too long: identity unknown
            else:
                res.complete = False  # still being written (or empty)
                return res
        elif newline > FIRST_LINE_MAX_BYTES:
            res.saw_meta = True
        else:
            _observe_first_line(res, data[:newline])
    segments = data.split(b"\n")
    # A last line without a newline is read only when it already decodes; any
    # other is still being written and waits for the next refresh [scanJsonl].
    tail = segments.pop()
    if tail and (legacy or (len(tail) <= PREFIX_BYTES and _decodes(tail))):
        segments.append(tail)
    # A subagent rollout without a history ordinal is read whole before any
    # of it counts: where its own history starts is decided from all of it
    # [CodexSubagentRolloutShape].
    classify_mode = (not legacy and policy != "no-turn-marker" and res.is_subagent
                     and res.history_start_ordinal is None)
    observations: list = []
    held_all: list = []  # (line, Event)
    if classify_mode:
        observations.append(Observation(line=0, kind="meta", id=res.rollout_id))
    line_no = -1
    for idx, raw in enumerate(segments):
        if not raw:
            continue
        line_no += 1
        if not legacy:
            if idx == 0:
                continue  # the first line was read on its own
            head = raw[:TRUNCATED_HEAD_BYTES] if len(raw) > PREFIX_BYTES else raw
            if b'"type":"session_meta"' in head:
                if classify_mode:
                    ident, names_fork = _later_meta_id(raw)
                    observations.append(Observation(line=line_no, kind="meta", id=ident))
                    if names_fork and _norm_id(ident) is not None and _norm_id(ident) == _norm_id(res.rollout_id):
                        res.explicit_parent = True
                res.observe_copied_session_meta(line_ordinal(raw))
                continue
            if b'"type":"inter_agent_communication_metadata"' in head:
                if classify_mode:
                    trigger = _trigger_turn(raw)
                    if trigger is not None:
                        observations.append(Observation(line=line_no, kind="message", trigger=trigger))
                res.observe_inter_agent_message(line_ordinal(raw))
                continue
        if len(raw) > PREFIX_BYTES:
            continue
        if b'"type":"session_meta"' in raw:
            # Legacy only: the first session_meta anywhere gave the file its key.
            if res.session_id is None:
                try:
                    obj = json.loads(raw)
                    p = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
                    res.session_id = next(
                        (v for v in (p.get("session_id"), p.get("sessionId"), p.get("id"), obj.get("session_id"))
                         if isinstance(v, str)),
                        None,
                    )
                except (ValueError, AttributeError):
                    pass
            continue
        is_event = b'"type":"event_msg"' in raw
        if not (is_event or b'"type":"turn_context"' in raw):
            continue
        if is_event and b'"token_count"' not in raw:
            continue
        try:
            obj = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(obj, dict) or not isinstance(obj.get("type"), str):
            continue
        typ = obj["type"]
        ts = obj.get("timestamp")
        if not isinstance(ts, str):
            continue
        ms = parse_instant_ms(ts)
        if ms is None:
            continue
        day = local_day_key(ms, tz)
        payload = obj.get("payload")
        if typ == "turn_context":
            if classify_mode:
                observations.append(Observation(line=line_no, kind="turn"))
            if isinstance(payload, dict):
                if isinstance(payload.get("model"), str):
                    model = payload["model"]
                elif isinstance(payload.get("info"), dict) and isinstance(payload["info"].get("model"), str):
                    model = payload["info"]["model"]
            continue
        if typ != "event_msg" or not isinstance(payload, dict) or payload.get("type") != "token_count":
            continue
        info = payload.get("info") if isinstance(payload.get("info"), dict) else None
        total = _totals(info.get("total_token_usage")) if info else None
        last = _totals(info.get("last_token_usage")) if info else None
        if total is None and last is None:
            continue
        m = None
        for cand in (
            info.get("model") if info else None,
            info.get("model_name") if info else None,
            payload.get("model"),
            obj.get("model"),
        ):
            if isinstance(cand, str):
                m = cand
                break
        ev = Event(ms=ms, ordinal=_as_int(obj.get("ordinal")), total=total, last=last, day=day,
                   model=m or model or "gpt-5")
        if classify_mode:
            observations.append(Observation(line=line_no, kind="tokens", total=total, last=last))
            held_all.append((line_no, ev))
            continue
        for e, delta in res.receive(ev, policy):
            _file_counted(res, e, delta, scan_since, scan_until)
    if classify_mode:
        _count_classified(res, observations, held_all, policy, scan_since, scan_until)
    for e, delta in res.finish(policy):
        _file_counted(res, e, delta, scan_since, scan_until)
    return res


def _count_classified(res: FileResult, observations: list, held: list, policy: str,
                      scan_since: str, scan_until: str) -> None:
    """A subagent rollout without a history ordinal, read whole
    [CodexTokenAccountant.finishWholeFile]. When its own history is found to
    start at a turn that an inter-agent message triggers (after copied
    history, or confirmed by its first own event), the events before it are
    copied and counting starts from the counter it had there. Otherwise the
    file counts by the other rules."""
    shape = classify(res.rollout_id, observations, res.explicit_parent)
    owned = shape.owned
    if owned is None and shape.candidate is not None and shape.candidate[2]:
        owned = shape.candidate[0]
    if owned is None:
        for _line, ev in held:
            for e, delta in res.receive(ev, policy):
                _file_counted(res, e, delta, scan_since, scan_until)
        return
    res.turn_marker = True
    res.watermark = owned.baseline
    res.baseline_checked = True
    for line, ev in held:
        if line < owned.start or (owned.first_token is not None and line < owned.first_token):
            res.skipped_copied += 1
            continue
        delta = res.count(ev.ms, ev.ordinal, ev.total, ev.last, policy)
        if delta is not None:
            _file_counted(res, ev, delta, scan_since, scan_until)


# --------------------------------------------------------------------------
# Selection [listCodexSessionFiles]


def list_files(root: str, scan_since: str, scan_until: str) -> list[str]:
    out, seen = [], set()
    if os.path.exists(root):
        d = date.fromisoformat(scan_since)
        end = date.fromisoformat(scan_until)
        while d <= end:
            day_dir = os.path.join(root, f"{d.year:04d}", f"{d.month:02d}", f"{d.day:02d}")
            try:
                names = os.listdir(day_dir)
            except OSError:
                names = []
            for name in names:
                p = os.path.join(day_dir, name)
                if name.startswith(".") or not name.lower().endswith(".jsonl") or p in seen:
                    continue
                seen.add(p)
                out.append(p)
            d += timedelta(days=1)
    try:
        names = os.listdir(root)
    except OSError:
        names = []
    for name in names:
        p = os.path.join(root, name)
        if name.startswith(".") or not name.lower().endswith(".jsonl") or p in seen:
            continue
        m = _FILENAME_DATE.search(name)
        if m and not (scan_since <= m.group(1) <= scan_until):
            continue
        seen.add(p)
        out.append(p)
    return sorted(out)


def roots_for(codex_home: str) -> list[str]:
    return [os.path.join(codex_home, "sessions"), os.path.join(codex_home, "archived_sessions")]


# --------------------------------------------------------------------------
# Which files count [CodexCopyResolver]


def counted_paths(files: list[FileResult], policy: str) -> set[str]:
    counted: set[str] = set()
    if policy == "legacy":
        seen = set()
        for f in files:  # scan order
            if f.session_id and f.session_id in seen:
                continue
            if f.session_id:
                seen.add(f.session_id)
            counted.add(f.path)
        return counted
    if policy == "first-payload-id":
        seen = set()
        for f in files:
            if f.rollout_id and f.rollout_id in seen:
                continue
            if f.rollout_id:
                seen.add(f.rollout_id)
            counted.add(f.path)
        return counted
    if policy == "count-all-files":
        return {f.path for f in files}
    threads: dict[str, list[FileResult]] = {}
    for f in files:
        if not f.rollout_id:
            counted.add(f.path)
        else:
            threads.setdefault(f.rollout_id, []).append(f)
    for group in threads.values():
        def final_tokens(f):
            w = f.watermark or (0, 0, 0)
            return w[0] + w[2]

        ordered = sorted(group, key=lambda f: (-f.event_count, -final_tokens(f), f.path))
        kept = []
        for f in ordered:
            if f.first_ms is None or f.last_ms is None:
                counted.add(f.path)
                continue
            if policy == "any-overlap":
                nested = any(f.first_ms <= b and a <= f.last_ms for a, b in kept)
            else:
                nested = any(a <= f.first_ms and f.last_ms <= b for a, b in kept)
            if nested:
                continue
            kept.append((f.first_ms, f.last_ms))
            counted.add(f.path)
    return counted


# --------------------------------------------------------------------------
# The whole scan


@dataclass
class Window:
    since: str
    until: str
    scan_since: str
    scan_until: str


def window_for(today: date, days: int) -> Window:
    since = today - timedelta(days=days)
    return Window(
        since=since.isoformat(),
        until=today.isoformat(),
        scan_since=(since - timedelta(days=1)).isoformat(),
        scan_until=(today + timedelta(days=1)).isoformat(),
    )


@dataclass
class ScanResult:
    window: Window
    files: list[FileResult]
    counted: set[str]
    # day -> model -> [input, cached, output], days in since..until
    days: dict

    def day_totals(self) -> dict:
        out = {}
        for day, models in self.days.items():
            t = [0, 0, 0]
            for row in models.values():
                for i in range(3):
                    t[i] += row[i]
            out[day] = t
        return out


def scan(codex_home: str, today: date, days: int = 30, policy: str = "overlap", tz=None) -> ScanResult:
    if policy not in POLICIES:
        raise ValueError(policy)
    win = window_for(today, days)
    paths, seen_paths, seen_ids = [], set(), set()
    for root in roots_for(codex_home):
        for p in list_files(root, win.scan_since, win.scan_until):
            if p in seen_paths:
                continue
            seen_paths.add(p)
            try:
                st = os.stat(p)
                ident = (st.st_dev, st.st_ino)
            except OSError:
                ident = None
            if ident is not None:
                if ident in seen_ids:
                    continue
                seen_ids.add(ident)
            paths.append(p)
    parsed = [parse_file(p, win.scan_since, win.scan_until, policy, tz) for p in paths]
    files = [f for f in parsed if f.complete]
    counted = counted_paths(files, policy)
    merged: dict = {}
    for f in files:
        if f.path not in counted:
            continue
        for day, models in f.days.items():
            if not (win.since <= day <= win.until):
                continue
            for model, row in models.items():
                dst = merged.setdefault(day, {}).setdefault(model, [0, 0, 0])
                for i in range(3):
                    dst[i] += row[i]
    for day in list(merged):
        merged[day] = {m: r for m, r in merged[day].items() if any(r)}
        if not merged[day]:
            del merged[day]
    return ScanResult(window=win, files=files, counted=counted, days=merged)


# --------------------------------------------------------------------------
# Comparing with the app's cache


def app_cache_days(cache_path: str, win: Window) -> tuple[dict, dict]:
    """The app's Codex day rows (tokens only) inside the window, plus header
    facts. Reads only `days`, `pricingVersion` and `lastScanUnixMs`: the
    `files` map is keyed by paths and is never printed."""
    with open(cache_path, encoding="utf-8") as fh:
        cache = json.load(fh)
    rows = {}
    for day, models in (cache.get("days") or {}).items():
        if not (win.since <= day <= win.until):
            continue
        rows[day] = {m: [int(p[i]) if i < len(p) else 0 for i in range(3)] for m, p in models.items()}
    return rows, {"pricingVersion": cache.get("pricingVersion"), "lastScanUnixMs": cache.get("lastScanUnixMs")}


def _fmt(n: int) -> str:
    return f"{n / 1e6:.2f}M"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--codex-home", default=os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"))
    ap.add_argument("--today", help="local date the window ends on (default: today, or the app cache's last scan)")
    ap.add_argument("--days", type=int, default=30, help="the app's daysToScan (default 30: 31 local days)")
    ap.add_argument("--policy", choices=POLICIES, default="overlap")
    ap.add_argument("--app-cache", help="the app's codex-v2.json, to compare day by day")
    ap.add_argument("--json", action="store_true", help="print the per-day numbers as JSON")
    args = ap.parse_args(argv)

    today = date.fromisoformat(args.today) if args.today else None
    header = {}
    if args.app_cache and today is None:
        with open(args.app_cache, encoding="utf-8") as fh:
            last_ms = json.load(fh).get("lastScanUnixMs") or 0
        if last_ms:
            today = datetime.fromtimestamp(last_ms / 1000).date()
    today = today or date.today()

    res = scan(args.codex_home, today, args.days, args.policy)
    totals = res.day_totals()
    children = sum(1 for f in res.files if f.is_child)
    skipped_copied = sum(f.skipped_copied for f in res.files)
    replayed = sum(f.replayed_tail_skips for f in res.files)
    restarts = sum(f.restart_skips for f in res.files)
    dips = sum(f.dip_skips for f in res.files)
    inherited = sum(f.inherited_input for f in res.files)

    if args.json and not args.app_cache:
        print(json.dumps({"window": res.window.__dict__, "files": len(res.files), "counted": len(res.counted),
                          "days": {d: totals[d] for d in sorted(totals)}}, indent=1))
        return 0

    print(f"window {res.window.since}..{res.window.until} (read {res.window.scan_since}..{res.window.scan_until}), policy={args.policy}")
    print(f"files read {len(res.files)}, counted {len(res.counted)}, copies not counted {len(res.files) - len(res.counted)}, subagent/fork files {children}")
    print(
        f"events not counted: copied parent history {skipped_copied}, a migrated subagent's replayed parent "
        f"tail {replayed}, after a counter restart {restarts}, "
        f"below the baseline otherwise {dips}; carried-over input not counted {_fmt(inherited)}"
    )
    grand = [sum(t[i] for t in totals.values()) for i in range(3)]
    print(f"total input {_fmt(grand[0])} cached {_fmt(grand[1])} output {_fmt(grand[2])}")

    if not args.app_cache:
        for d in sorted(totals):
            t = totals[d]
            print(f"  {d}  input {_fmt(t[0])}  cached {_fmt(t[1])}  output {_fmt(t[2])}")
        return 0

    app_rows, header = app_cache_days(args.app_cache, res.window)
    print(f"app cache: rules version {header['pricingVersion']}, last scan {header['lastScanUnixMs']}")
    mismatched = 0
    for d in sorted(set(totals) | set(app_rows)):
        mine = totals.get(d, [0, 0, 0])
        app = [sum(r[i] for r in app_rows.get(d, {}).values()) for i in range(3)]
        same = mine == app
        mismatched += 0 if same else 1
        mark = "same" if same else "DIFF"
        print(f"  {d}  {mark}  replica {'/'.join(_fmt(x) for x in mine)}  app {'/'.join(_fmt(x) for x in app)}")
        if not same:
            for model in sorted(set(res.days.get(d, {})) | set(app_rows.get(d, {}))):
                a = res.days.get(d, {}).get(model, [0, 0, 0])
                b = app_rows.get(d, {}).get(model, [0, 0, 0])
                if a != b:
                    print(f"      {model}: replica {a} app {b}")
    print(f"{mismatched} day(s) differ")
    return 1 if mismatched else 0


if __name__ == "__main__":
    sys.exit(main())

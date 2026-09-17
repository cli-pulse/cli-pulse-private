#!/usr/bin/env python3
"""
Collector status lines — English copy written straight into `status_text`.

`status_text` ("5h 60% left · Weekly 40% left", "12/100 used") is data: collectors
run in the Login Item helper as well as the app, the value is uploaded, and every
device renders the PRODUCING device's bytes. So it stays English and is
translated where it is shown, by `L10n.providers.localizedStatusText`. That only
works for text it can recognize, and it recognizes exactly two things:

  * the sentinels its switch knows ("Operational", "Connected", "Unknown",
    "Disabled", "<n>% used", and `ClaudeStatusSentinel`), and
  * whatever `CollectorStatusText`'s builders write.

Until 2026-09-17 every collector composed its own line from literals, and every
one of them rendered English in all five other languages. The fix routed them
through the builders. This gate keeps it that way: a collector that writes a
status literal of its own — `status_text: "\\(n) widgets left"`,
`status += " · overdue"` — FAILS until the words go through a builder (and so
get a translation) or are recorded in `scripts/collector_status_text_allowlist.json`
with the reason they must stay as written (a vendor's product or unit name).

WHAT COUNTS AS A STATUS LITERAL
A string literal with a run of two or more letters, once interpolations and
printf specifiers are removed, found in:
  * the argument of `status_text:`;
  * the right-hand side of an assignment to `status`, `statusText`, `parts` or
    `segments`;
  * a `parts.append(…)` / `segments.append(…)` call;
  * the body of a function whose name contains `statusText` / `StatusText`;
  * the right-hand side of a local used as a plain value in one of the above
    (one step; not through interpolations or a builder's arguments).
Literals passed INTO a builder (`CollectorStatusText.remaining("$5 USD")`) are
values, not copy, and are skipped; so are literals compared with `==` / `!=`.

RECALL IS NOT COMPLETE — READ THIS BEFORE TRUSTING A GREEN RUN
A line built in a helper with an unrelated name and passed in as a variable is
invisible here. The builders' own tests (`CollectorStatusTextTests`) are the
proof that what IS built translates; this gate is a ratchet on the common ways
a collector writes its line, and it carries a positive control so a moved
directory fails instead of scanning nothing.

  python3 scripts/check_collector_status_text.py
  python3 scripts/check_collector_status_text.py --root <tree>   # test fixtures

Pure Python on purpose: repo-hygiene runs on Linux.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

COLLECTORS = "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors"
ALLOWLIST = "scripts/collector_status_text_allowlist.json"
BUILDER = "CollectorStatusText"

# Recognized by the sentinel switch in L10n.providers.localizedStatusText.
SENTINELS = {"Operational", "Connected", "Unknown", "Disabled", "{}% used"}

# The real tree has ~200 status contexts (2026-09-17). Far fewer means the
# scanner is looking in the wrong place and a green run would mean nothing.
MIN_CONTEXTS_REAL_TREE = 100

# The variables collectors build their line in. Anything else joins in only by
# flowing into one of these (see `status_literals`).
ASSIGN = re.compile(
    r"\b(?:(?:let|var)\s+)?(status|statusText|parts|segments)\s*(?::\s*\[?String\]?\??\s*)?(\+=|=)(?!=)")
DECL = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::[^=\n]*)?=(?!=)")
# An identifier used as a value: not a member (`.x`), not a callee or receiver.
VALUE_USE = re.compile(r"(?<![.\w])([a-z]\w*)\b(?!\s*[(.\[!?:]|\s*\+?=)")
APPEND = re.compile(r"\b(?:parts|segments)\.append\(")
STATUS_ARG = re.compile(r"\bstatus_text\s*:")
STATUS_FUNC = re.compile(r"\bfunc\s+(\w*[Ss]tatusText\w*)\s*\(")
BUILDER_CALL = re.compile(r"\b" + BUILDER + r"\.(\w+)\s*\(")
# No flags on purpose: with a space flag, the "% u" in "\\(n)% used" reads as a
# conversion and the sentinel stops being recognized.
SPEC = re.compile(r"%(?:\d+\$)?0?\d*(?:\.\d+)?(?:ll|l|q)?[@dfiu]")


def blank_comments(src: str) -> str:
    """Replace // and /* */ comments with spaces, keeping offsets and newlines."""
    out = list(src)
    i, n = 0, len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"' or c == "\n":
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j == -1 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
            continue
        i += 1
    return "".join(out)


def scan_string(src: str, i: int) -> int:
    """i is just past an opening quote; return the index just past the closing one."""
    n = len(src)
    while i < n:
        c = src[i]
        if c == "\\":
            if i + 1 < n and src[i + 1] == "(":
                i = scan_interp(src, i + 2)
                continue
            i += 2
            continue
        if c == '"' or c == "\n":
            return i + 1
        i += 1
    return n


def scan_interp(src: str, i: int) -> int:
    depth, n = 1, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i = scan_string(src, i + 1)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def literals(src: str) -> list[tuple[int, int, str]]:
    """(start, end, body) of every single-line string literal, outermost only."""
    out = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            i = n if j == -1 else j + 3
            continue
        if src[i] == '"':
            j = scan_string(src, i + 1)
            out.append((i, j, src[i + 1:j - 1]))
            i = j
            continue
        i += 1
    return out


def call_end(src: str, open_paren: int) -> int:
    """Index just past the `)` matching the `(` at open_paren."""
    depth, i, n = 0, open_paren, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i = scan_string(src, i + 1)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def argument_end(src: str, start: int) -> int:
    """End of a call argument: the `,` or closing bracket at depth 0."""
    depth, i, n = 0, start, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i = scan_string(src, i + 1)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return i
            depth -= 1
        elif c == "," and depth == 0:
            return i
        i += 1
    return n


CONTINUES = ("?", ":", "+", ".", "&&", "||", "??")


def statement_end(src: str, start: int) -> int:
    """End of an assignment's right-hand side: a newline at depth 0, unless the
    next line continues the expression (a ternary split over lines). A `{` at
    depth 0 opens a closure only straight after `=`, `?`, `:` or `(`; after
    anything else it is the body of `if let x = y {`, which is not the value."""
    depth, i, n = 0, start, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i = scan_string(src, i + 1)
            continue
        if c == "{" and depth == 0 and src[:i].rstrip()[-1:] not in ("=", "?", ":", "(", ",", "["):
            return i
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return i
            depth -= 1
        elif c == "\n" and depth == 0:
            rest = src[i + 1:].lstrip(" \t")
            if not rest.startswith(CONTINUES):
                return i
        elif c == ";" and depth == 0:
            return i
        i += 1
    return n


def body_span(src: str, func_start: int) -> tuple[int, int] | None:
    brace = src.find("{", func_start)
    if brace == -1:
        return None
    return brace, call_end(src, brace)


def normalize(body: str) -> str:
    out, i, n = [], 0, len(body)
    while i < n:
        if body.startswith("\\(", i):
            i = scan_interp(body, i + 2)
            out.append("{}")
            continue
        out.append(body[i])
        i += 1
    s = "".join(out).replace("%%", "\x00")
    s = SPEC.sub("{}", s)
    return s.replace("\x00", "%")


def is_copy(normalized: str) -> bool:
    return re.search(r"[A-Za-z]{2,}", normalized.replace("{}", " ")) is not None


def blank(chunk: str, offset: int, exempt: list[tuple[int, int]]) -> str:
    """`chunk` (starting at `offset` in the file) with builder arguments blanked."""
    out = list(chunk)
    for a, b in exempt:
        for k in range(max(a, offset), min(b, offset + len(chunk))):
            out[k - offset] = " "
    return "".join(out) + "\n"


def status_literals(src: str) -> tuple[list[tuple[int, str]], int]:
    """Status literals as (offset, normalized text), and how many contexts were seen."""
    spans: list[tuple[int, int]] = []
    for m in STATUS_ARG.finditer(src):
        spans.append((m.end(), argument_end(src, m.end())))
    # `status` is also every collector's HTTP code and OSStatus, so its
    # assignments are scanned but never followed (`flow_from` below).
    for m in ASSIGN.finditer(src):
        spans.append((m.end(), statement_end(src, m.end())))
    for m in APPEND.finditer(src):
        spans.append((m.end() - 1, call_end(src, m.end() - 1)))
    for m in STATUS_FUNC.finditer(src):
        body = body_span(src, m.end())
        if body:
            spans.append(body)

    exempt: list[tuple[int, int]] = []
    for m in BUILDER_CALL.finditer(src):
        if m.group(1) != "join":
            exempt.append((m.end() - 1, call_end(src, m.end() - 1)))

    # One step of data flow: a local used as a VALUE in a status expression is
    # part of the line too — Manus builds `balanceText` first and joins it in
    # later. Only one step, and only bare uses: an identifier inside a literal's
    # interpolation, inside a builder's arguments, or used as a receiver or
    # callee is not the line, and following those pulls in the whole file.
    status_assignments = {m.end() for m in ASSIGN.finditer(src) if m.group(1) == "status"}
    starts = {a for a, _ in spans}
    blanked = blank(src, 0, exempt + [(a, b) for a, b, _ in literals(src)])
    used_names: set[str] = set()
    flow_from = [(a, b) for a, b in spans if a not in status_assignments]
    for a, b in flow_from:
        for m in VALUE_USE.finditer(blanked[a:b]):
            used_names.add(m.group(1))
    for m in DECL.finditer(src):
        if m.group(1) in used_names and m.end() not in starts:
            spans.append((m.end(), statement_end(src, m.end())))
            starts.add(m.end())

    found: dict[int, str] = {}
    for start, end, body in literals(src):
        if not any(a <= start < b for a, b in spans):
            continue
        if any(a <= start < b for a, b in exempt):
            continue
        if start > 0 and src[start - 1] == "#":
            continue          # a raw-string regex pattern, not copy
        if start > 1 and src[start - 1] == "[" and re.match(r"[\w)\]?!]", src[start - 2]):
            continue          # a subscript key (`fields["grpc-status"]`), not copy
        before = src[max(0, start - 12):start].rstrip()
        if before.endswith(("==", "!=")) or re.search(r"\bcase\s*$", before):
            continue
        norm = normalize(body)
        if is_copy(norm):
            found[start] = norm
    return sorted(found.items()), len(spans)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    if "--root" in sys.argv:
        root = Path(sys.argv[sys.argv.index("--root") + 1]).resolve()
    collectors = root / COLLECTORS
    if not collectors.is_dir():
        print(f"collector status text: FAILED — {COLLECTORS} not found under {root}")
        return 1

    allow_path = root / ALLOWLIST
    entries = json.loads(allow_path.read_text(encoding="utf-8"))["entries"] if allow_path.exists() else []
    allowed = {(e["path"], e["literal"]): e for e in entries}
    errors: list[str] = []
    for e in entries:
        if len((e.get("reason") or "").strip()) < 20:
            errors.append(f'{e["path"]}: "{e["literal"]}" needs a real reason')

    used: set[tuple[str, str]] = set()
    contexts = 0
    for path in sorted(collectors.rglob("*.swift")):
        rel = str(path.relative_to(root))
        src = blank_comments(path.read_text(encoding="utf-8", errors="replace"))
        hits, seen = status_literals(src)
        contexts += seen
        for offset, norm in hits:
            if norm in SENTINELS:
                continue
            key = (rel, norm)
            if key in allowed:
                used.add(key)
                continue
            line = src[:offset].count("\n") + 1
            errors.append(f'{rel}:{line}: "{norm}" is English status copy that no recognizer translates')

    for key in allowed:
        if key not in used:
            errors.append(f'{key[0]}: allowlisted "{key[1]}" is no longer written — stale entry, delete it')

    if "--root" not in sys.argv and contexts < MIN_CONTEXTS_REAL_TREE:
        errors.append(f"only {contexts} status contexts found (expected at least {MIN_CONTEXTS_REAL_TREE}) — "
                      "the scanner is not looking where the collectors are")

    if errors:
        print("collector status text: FAILED\n")
        for e in errors:
            print(f"  - {e}")
        print(
            "\nBuild the line with CollectorStatusText (add a builder, its recognizer, and the key in all six\n"
            ".lproj catalogues), or, if the words are a vendor's own term, record them in\n"
            f"{ALLOWLIST} with the reason.")
        return 1
    print(f"collector status text: OK — {contexts} status contexts scanned, "
          f"{len(used)} vendor literal(s) allowlisted with a reason.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

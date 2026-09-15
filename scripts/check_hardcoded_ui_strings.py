#!/usr/bin/env python3
"""
Hardcoded English in the Apple UI — the half the parity gate cannot see.

`check_apple_strings_parity.py` compares keys BETWEEN .lproj catalogues. A
string that was never externalized has no key, so there is nothing for it to
find missing. On 2026-09-10 the zh-Hans App Store screenshots were shot from the
real app and its Sessions tab still said "Active", "recent activity" and
"Running = process confirmed. Recent = JSONL activity only." in English — with
the parity gate green, because it was correctly reporting that every key had a
translation. The strings simply were not keys.

WHAT IT CHECKS
Every string literal passed to a user-facing SwiftUI/AppKit API (Text, Button,
Toggle, Label, Section, TextField, Link, Menu, .help, .navigationTitle,
.alert, header:/title:/message: arguments …), and every literal RETURNED from a
property or function whose name says it is display copy (label, title,
subtitle, caption, header, hint, message, placeholder, description …) in the
app, watch, widget and CLIPulseCore sources.

A RATCHET, NOT A BAR — same reasoning as the parity gate
Some literals are correct as they are: product and provider names, protocol
tokens, shell commands, DEBUG-only menus, persisted raw values. Those live in
`scripts/hardcoded_ui_strings_baseline.json`, each with the reason it is allowed.
  * a literal that is not in the baseline FAILS  — new hardcoded copy is caught
    in the PR that adds it;
  * a baseline entry whose literal is gone FAILS — so the allowlist can only
    shrink, and cannot quietly cover something new under a stale entry.
Entries are keyed by (file, literal, count), not line numbers, so unrelated
edits above a literal do not churn the baseline.

INTERPOLATION
`Text("tokens · \\(x)")` is a hardcoded English word with a variable in it. The
first inventory for this sweep used a regex that rejected backslashes inside the
literal and so structurally could not see it. Literals here come from a small
tokenizer that tracks `\\( … )` depth and nested literals, so neither that nor a
quoted dictionary key inside an interpolation cuts a literal short. Multi-line
triple-quoted string literals are out of scope for a line scanner.

Pure Python on purpose: repo-hygiene runs on Linux.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

APP = "CLI Pulse Bar"
SCAN_DIRS = [
    f"{APP}/CLI Pulse Bar",
    f"{APP}/CLI Pulse Bar iOS",
    f"{APP}/CLI Pulse Bar Watch",
    f"{APP}/CLI Pulse Widgets",
    f"{APP}/CLIPulseCore/Sources/CLIPulseCore",
]
SKIP_PARTS = {".build", "Tests", "codexbar", "scripts", "DerivedData", "build"}
BASELINE_DEFAULT = "scripts/hardcoded_ui_strings_baseline.json"

# ---- literal tokenizer -------------------------------------------------------
# A regex cannot delimit a Swift literal whose interpolation contains another
# literal: `"\(dict["k"] ?? "")"`. The first version of this gate used one and
# cut such literals off at the inner quote — only ever producing false alarms,
# never misses, but leaving allowlist keys that were fragments of code. This
# walks the line and tracks `\( … )` depth and nested literals instead.

def _scan_string(line: str, i: int) -> int:
    """i is just past an opening quote; return index just past the closing one, or -1."""
    n = len(line)
    while i < n:
        c = line[i]
        if c == '\\':
            if i + 1 < n and line[i + 1] == '(':
                i = _scan_interp(line, i + 2)
                if i < 0:
                    return -1
                continue
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    return -1


def _scan_interp(line: str, i: int) -> int:
    """i is just past `\\(`; return index just past the matching `)`, or -1."""
    depth, n = 1, len(line)
    while i < n:
        c = line[i]
        if c == '"':
            j = _scan_string(line, i + 1)
            if j < 0:
                return -1
            i = j
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def literals(line: str) -> list[tuple[int, str]]:
    """(start index, literal incl. quotes) for each single-line literal; stops at a // comment."""
    out, i, n = [], 0, len(line)
    while i < n:
        if line.startswith('//', i):
            break
        if line[i] == '"':
            if line.startswith('"""', i):          # multi-line literal: out of scope for a line scanner
                break
            j = _scan_string(line, i + 1)
            if j < 0:
                break
            out.append((i, line[i:j]))
            i = j
            continue
        i += 1
    return out


def without_interpolations(body: str) -> str:
    out, i, n = [], 0, len(body)
    while i < n:
        if body[i] == '\\' and i + 1 < n and body[i + 1] == '(':
            j = _scan_interp(body, i + 2)
            if j < 0:
                break
            i = j
            continue
        out.append(body[i])
        i += 1
    return ''.join(out)


UI_PREFIX = re.compile(
    r'(?:(?<![\w.])(?:Text|Button|Toggle|Label|Section|TextField|SecureField|Picker|Menu|Link|'
    r'ContentUnavailableView|CommandMenu|NavigationLink)\s*\(\s*'
    r'|\.(?:help|navigationTitle|alert|confirmationDialog|accessibilityLabel|accessibilityHint)\s*\(\s*'
    r'|\b(?:header|footer|title|subtitle|message|placeholder|prompt|caption)\s*:\s*)$'
)
RETURN_PREFIX = re.compile(r'\breturn\s+$')
DECL = re.compile(r'\b(?:var|func|let)\s+(\w+)')
DISPLAY_NAME = re.compile(r'label|title|caption|header|footer|hint|message|placeholder|description|'
                          r'displayname|text|subtitle|summary|reason|badge|chip|tooltip|headline|detail|explanation', re.I)
# A name list always has gaps (`var badge: String` returned "recent activity" and was missed by the first
# version of this list). So a second, structural signal: a multi-word phrase returned from a declaration
# typed String is prose whatever the property is called.
PHRASE = re.compile(r'[A-Za-z]{2,}[\s,.;:·—-]+[A-Za-z]{2,}')


def is_copy(literal: str) -> bool:
    """Literals that could be English prose: a run of 2+ letters outside any interpolation."""
    return re.search(r'[A-Za-z]{2,}', without_interpolations(literal[1:-1])) is not None


def scan_file(path: Path) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    recent_decl = ''
    recent_decl_is_string = False
    for n, line in enumerate(lines, 1):
        stripped = line.lstrip()
        if not stripped or stripped.startswith(('//', '*', '/*', '@available')):
            continue
        lits = literals(line)
        code_only = line
        for start, lit in reversed(lits):          # blank literals before looking for declarations
            code_only = code_only[:start] + '""' + code_only[start + len(lit):]
        m = DECL.search(code_only)
        if m:
            recent_decl = m.group(1)
            recent_decl_is_string = 'String' in code_only
        named_copy = bool(DISPLAY_NAME.search(recent_decl or ''))
        for start, lit in lits:
            if not is_copy(lit):
                continue
            before = line[:start]
            if UI_PREFIX.search(before):
                found.append((n, lit))
            elif RETURN_PREFIX.search(before) and (
                    named_copy or (recent_decl_is_string and PHRASE.search(without_interpolations(lit[1:-1])))):
                found.append((n, lit))
    return found


def scan(root: Path) -> dict[tuple[str, str], list[int]]:
    hits: dict[tuple[str, str], list[int]] = {}
    for d in SCAN_DIRS:
        base = root / d
        if not base.is_dir():
            continue
        for f in sorted(base.rglob('*.swift')):
            rel = f.relative_to(root)
            if SKIP_PARTS & set(rel.parts[1:]):
                continue
            for n, lit in scan_file(f):
                hits.setdefault((rel.as_posix(), lit), []).append(n)
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument('--baseline', type=Path, default=None)
    ap.add_argument('--write-baseline', action='store_true',
                    help='print a baseline for the current tree (reasons left for a human)')
    args = ap.parse_args()
    root = args.root
    baseline_path = args.baseline or (root / BASELINE_DEFAULT)
    hits = scan(root)

    if args.write_baseline:
        entries = [{"path": p, "literal": lit, "count": len(ns), "reason": "TODO"}
                   for (p, lit), ns in sorted(hits.items())]
        print(json.dumps({"entries": entries}, ensure_ascii=False, indent=1))
        return 0

    try:
        baseline = json.loads(baseline_path.read_text(encoding='utf-8'))["entries"]
    except FileNotFoundError:
        print(f"check_hardcoded_ui_strings: baseline not found: {baseline_path}", file=sys.stderr)
        return 2

    allowed = Counter()
    for e in baseline:
        if not e.get("reason") or e["reason"] == "TODO":
            print(f"check_hardcoded_ui_strings: baseline entry without a reason: {e['path']} {e['literal']}")
            return 1
        allowed[(e["path"], e["literal"])] += int(e.get("count", 1))

    errors = []
    for (p, lit), ns in sorted(hits.items()):
        extra = len(ns) - allowed.get((p, lit), 0)
        if extra > 0:
            errors.append(f"  NEW   {p}:{ns[-1]}  {lit}"
                          + (f"  (+{extra} beyond baseline)" if allowed.get((p, lit)) else ""))
    for (p, lit), count in sorted(allowed.items()):
        present = len(hits.get((p, lit), []))
        if present < count:
            errors.append(f"  STALE {p}  {lit}  (baseline {count}, found {present}) — shrink the baseline")

    if errors:
        print("check_hardcoded_ui_strings: FAILED")
        print("\n".join(errors))
        print("\nUser-visible copy must go through L10n (CLIPulseCore/L10n.swift + all six .lproj).\n"
              "If a literal is genuinely not translatable (a product name, a shell command, a DEBUG-only\n"
              f"menu), add it to {BASELINE_DEFAULT} with the reason.")
        return 1

    total = sum(len(v) for v in hits.values())
    print(f"check_hardcoded_ui_strings: OK — {total} literal(s) in scope, all allowlisted with a reason.")
    return 0


if __name__ == '__main__':
    sys.exit(main())

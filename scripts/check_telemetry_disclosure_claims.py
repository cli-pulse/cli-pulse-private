#!/usr/bin/env python3
"""
Fail the build if the anonymous-telemetry payload carries a field that the
user-facing disclosure does not mention.

WHY THIS EXISTS
---------------
The telemetry switch defaults ON. That is only defensible because the app
states what it sends before it sends anything, so the disclosure is not
documentation -- it is the consent basis. A field no disclosure mentions is a
field collected without consent.

Nothing mechanical connected the two. When v0.76 added three fields, BOTH
disclosure surfaces still said "two things": the first-run card and
Settings > Privacy, hardcoded separately in English, saying the same wrong
thing twice. This repo has already paid for that exact shape -- one predicate,
two call sites, only the UI one fixed.

WHAT IT CHECKS
--------------
  1. every `CodingKeys` case in `AnonymousInstallPayload` is registered in
     `scripts/telemetry_disclosure.allow`;
  2. every registered phrase appears in EVERY disclosure surface, not just the
     one someone happened to open;
  3. every registered field still exists in `CodingKeys` -- a stale entry is as
     misleading as a missing one, because it reads as coverage.

Check 2 is the one with teeth: a registry that only matched names would be
satisfied by inventing a name, which is the failure mode it exists to stop.

WHAT IT CANNOT CHECK
--------------------
That the phrase is TRUE, or that a user understood it. Both disclosure
surfaces are also hardcoded English, so a Spanish user reads this in English
regardless -- a real defect, tracked separately, and not one a string match can
find.

Usage:
  python3 scripts/check_telemetry_disclosure_claims.py
  python3 scripts/check_telemetry_disclosure_claims.py --root <tree>
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

PAYLOAD = Path("CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AnonymousInstallTelemetry.swift")
ALLOW = Path("scripts/telemetry_disclosure.allow")

# Every place the app tells a user what it sends. A guard that watches one of
# two surfaces licenses the other.
SURFACES = [
    Path("CLI Pulse Bar/CLI Pulse Bar/AnonymousTelemetryDisclosureCard.swift"),
    Path("CLI Pulse Bar/CLI Pulse Bar/PrivacySettingsSection.swift"),
]

# Described as "the id is random and is deleted when you uninstall" rather than
# by name, on every surface. Exempted here so the registry does not need a row
# whose phrase is really about deletion.
EXEMPT = {"installID"}

CODING_KEYS_RE = re.compile(
    r"enum CodingKeys: String, CodingKey \{(.*?)\n    \}", re.DOTALL
)
CASE_RE = re.compile(r"case\s+(\w+)\s*=")


def collapse(text: str) -> str:
    """Whitespace-collapsed source, so a line-wrapped Swift literal matches."""
    return re.sub(r"\s+", " ", text.replace("\\\n", " "))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=None)
    args = ap.parse_args()
    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent.parent

    payload = root / PAYLOAD
    allow = root / ALLOW
    for path in (payload, allow):
        if not path.is_file():
            print(f"FATAL: missing {path}", file=sys.stderr)
            return 2

    block = CODING_KEYS_RE.search(payload.read_text(encoding="utf-8"))
    if not block:
        print(f"FATAL: no AnonymousInstallPayload CodingKeys block in {payload}", file=sys.stderr)
        return 2
    fields = [m.group(1) for m in CASE_RE.finditer(block.group(1))]
    if len(fields) < 3:
        print(f"FATAL: parsed only {fields} from CodingKeys — the parser is broken, "
              "not the payload", file=sys.stderr)
        return 2

    registry: dict[str, str] = {}
    for raw in allow.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 3:
            print(f"FATAL: malformed registry line: {raw}", file=sys.stderr)
            return 2
        registry[parts[0]] = parts[1]

    surfaces: dict[Path, str] = {}
    for rel in SURFACES:
        path = root / rel
        if not path.is_file():
            print(f"FATAL: disclosure surface missing at {path}", file=sys.stderr)
            return 2
        surfaces[rel] = collapse(path.read_text(encoding="utf-8"))

    failed = False

    unregistered = [f for f in fields if f not in registry and f not in EXEMPT]
    if unregistered:
        failed = True
        print("FAIL — payload field(s) with no entry in scripts/telemetry_disclosure.allow.", file=sys.stderr)
        print("       The telemetry switch defaults ON, so an undisclosed field is", file=sys.stderr)
        print("       collected without consent:\n", file=sys.stderr)
        for f in unregistered:
            print(f"    {f}", file=sys.stderr)
        print("", file=sys.stderr)

    stale = [f for f in registry if f not in fields]
    if stale:
        failed = True
        print("FAIL — registry entr(ies) naming a field the payload no longer has.", file=sys.stderr)
        print("       A stale row reads as coverage:\n", file=sys.stderr)
        for f in stale:
            print(f"    {f}", file=sys.stderr)
        print("", file=sys.stderr)

    for field in fields:
        phrase = registry.get(field)
        if phrase is None:
            continue
        missing = [str(rel) for rel, text in surfaces.items() if phrase.lower() not in text.lower()]
        if missing:
            failed = True
            print(f"FAIL — {field} is registered as disclosed by \"{phrase}\", but that", file=sys.stderr)
            print("       phrase is absent from:\n", file=sys.stderr)
            for m in missing:
                print(f"    {m}", file=sys.stderr)
            print("\n    Both surfaces must say it. A guard watching one licenses the other.\n", file=sys.stderr)

    if failed:
        return 1

    print(f"check_telemetry_disclosure_claims: OK — {len(fields)} payload field(s); "
          f"{len(registry)} disclosed across {len(surfaces)} surface(s), "
          f"{len(EXEMPT & set(fields))} exempt by name.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

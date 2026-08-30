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
  2. every registered phrase appears in the SHIPPED English copy of EVERY
     disclosure surface -- not in the source prose, and not in just the one
     someone happened to open;
  3. every disclosure surface still RENDERS its localized copy, so a surface
     cannot quietly stop showing the disclosure while the strings sit unused
     in the catalogue;
  4. every registered field still exists in `CodingKeys` -- a stale entry is as
     misleading as a missing one, because it reads as coverage.

Checks 2 and 3 are the ones with teeth, and they need each other. Reading only
the catalogue would pass a build where neither view renders it; reading only
the views would pass a view that renders an empty key.

v1.52.1 moved this copy out of hardcoded Swift string literals and into
`Localizable.strings`, because a Spanish, Korean or Japanese user was being
shown an ENGLISH explanation of what the app sends and then opted in by
default. So the phrases now live in `en.lproj` and the guard follows them
there; the six-locale parity gate is what keeps the other catalogues carrying
the same keys.

WHAT IT CANNOT CHECK
--------------------
That the phrase is TRUE, that the translations say the same thing as the
English, or that a user understood any of it.

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

# Every place the app tells a user what it sends, and the L10n accessor each
# one must render. A guard that watches one of two surfaces licenses the other.
SURFACES = {
    Path("CLI Pulse Bar/CLI Pulse Bar/AnonymousTelemetryDisclosureCard.swift"):
        "L10n.telemetry.disclosureBody",
    Path("CLI Pulse Bar/CLI Pulse Bar/PrivacySettingsSection.swift"):
        "L10n.telemetry.settingsBody",
}

# The shipped English copy the phrases must appear in. `en` specifically: the
# registry phrases are English, and the parity gate is what guarantees the
# other five catalogues carry the same keys.
CATALOGUE = Path("CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources/en.lproj/Localizable.strings")
DISCLOSURE_KEYS = [
    "telemetry.disclosure_body",
    "telemetry.disclosure_body_local_only",
    "telemetry.not_collected",
    "telemetry.settings_body",
]

# Described as "the id is random and is deleted when you uninstall" rather than
# by name, on every surface. Exempted here so the registry does not need a row
# whose phrase is really about deletion.
EXEMPT = {"installID"}

# Tolerant of extra conformances. The first version pinned the exact
# `String, CodingKey {` spelling and went FATAL the moment `CaseIterable` was
# added — a guard that mistakes its own parser breaking for a verdict. CI caught
# it; the local run had been made before that edit.
CODING_KEYS_RE = re.compile(
    r"enum CodingKeys\s*:[^{]*\{(.*?)\n    \}", re.DOTALL
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

    # Check 3: each surface must still render its localized copy.
    unrendered: list[str] = []
    for rel, accessor in SURFACES.items():
        path = root / rel
        if not path.is_file():
            print(f"FATAL: disclosure surface missing at {path}", file=sys.stderr)
            return 2
        if accessor not in path.read_text(encoding="utf-8"):
            unrendered.append(f"{rel} no longer renders {accessor}")

    catalogue = root / CATALOGUE
    if not catalogue.is_file():
        print(f"FATAL: catalogue missing at {catalogue}", file=sys.stderr)
        return 2
    cat_text = catalogue.read_text(encoding="utf-8")
    values: list[str] = []
    for key in DISCLOSURE_KEYS:
        m = re.search(r'^"' + re.escape(key) + r'"\s*=\s*"(.*?)";$', cat_text, re.M | re.S)
        if m is None:
            print(f"FATAL: {key} is not in {CATALOGUE.name} — the copy moved again", file=sys.stderr)
            return 2
        values.append(m.group(1))
    disclosed = collapse(" ".join(values))
    if len(disclosed) < 200:
        print(f"FATAL: the disclosure copy parsed to {len(disclosed)} chars — "
              "the parser is broken, not the copy", file=sys.stderr)
        return 2

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

    if unrendered:
        failed = True
        print("FAIL — a disclosure surface stopped rendering its copy. The strings", file=sys.stderr)
        print("       would sit in the catalogue while the user is shown nothing:\n", file=sys.stderr)
        for u in unrendered:
            print(f"    {u}", file=sys.stderr)
        print("", file=sys.stderr)

    for field in fields:
        phrase = registry.get(field)
        if phrase is None:
            continue
        if phrase.lower() not in disclosed.lower():
            failed = True
            print(f"FAIL — {field} is registered as disclosed by \"{phrase}\", but that", file=sys.stderr)
            print(f"       phrase is absent from the shipped copy in {CATALOGUE.name}.\n", file=sys.stderr)
            print("    The telemetry switch defaults ON, so a field the disclosure does", file=sys.stderr)
            print("    not mention is a field collected without consent.\n", file=sys.stderr)

    if failed:
        return 1

    print(f"check_telemetry_disclosure_claims: OK — {len(fields)} payload field(s); "
          f"{len(registry)} disclosed in {len(DISCLOSURE_KEYS)} localized string(s), "
          f"rendered by {len(SURFACES)} surface(s), "
          f"{len(EXEMPT & set(fields))} exempt by name.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

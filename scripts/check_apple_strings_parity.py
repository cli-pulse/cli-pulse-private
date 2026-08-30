#!/usr/bin/env python3
"""
A5 — the Apple half of the localization parity gate.

Android has had `ci_check_android_strings_parity.py` since v1.21. The Apple
`.lproj` catalogues never got one, and drifted: on 2026-08-30 es and ko each
carried 774 of the 1057 base keys, ja and zh-Hant 1005. 670 strings across
four shipped locales had no translation at all, and every one of them
rendered as its raw dotted identifier until `L10n.resolve` gained an English
fallback.

WHY THIS IS NOT A STRAIGHT PORT OF THE ANDROID SCRIPT
-----------------------------------------------------
The Android script is fail-closed strict parity, which it can afford because
Android was already at parity when it landed. Apple is 670 keys short today.
A gate that is red the moment it merges is either reverted or wrapped in
`continue-on-error`, and this repo has shipped five guards that were green
while guarding nothing — a permanently-red one is the same failure wearing
the other colour.

So this gate is a RATCHET, not a bar:

  * every key missing from a locale must be listed in the baseline file
    (`scripts/apple_strings_parity_baseline.json`) — so a NEW key added to
    en without being added to every locale fails immediately, which is the
    exact regression that produced the 670;
  * every baseline entry must still be genuinely missing — so translating a
    key forces the baseline to shrink, and the debt can never quietly grow
    back under cover of an entry that no longer applies.

Two checks have no baseline at all, because both are at zero today and
neither has an acceptable non-zero value:

  * ORPHANS — a key in a locale but not in en. en is the fallback for every
    other locale and has no fallback of its own, so an en-missing key is
    user-visible debug output with no safety net. This is the H-13 bug
    (`L10nEnBaseKeysTests`) expressed as a gate.
  * DUPLICATES — a key declared twice in one file. `.strings` silently keeps
    the last, so the earlier translation is dead text that reads as done.

DELIBERATELY NOT CHECKED
------------------------
A locale carrying the English value verbatim ("present but untranslated").
Mechanically indistinguishable from the many strings that are legitimately
identical across languages — "CLI Pulse", "Codex", "OK", "%d". A gate that
fires on those trains people to ignore it.

Usage:
  python3 scripts/check_apple_strings_parity.py
  python3 scripts/check_apple_strings_parity.py --root <tree>   # test fixtures
  python3 scripts/check_apple_strings_parity.py --update-baseline

Exit codes:
  0 — parity holds, or every gap is a known and still-accurate baseline entry
  1 — new drift, stale baseline, orphan key, or duplicate key
  2 — the catalogues could not be read at all
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import sys
from pathlib import Path

RES_SUBPATH = Path("CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources")
BASELINE_SUBPATH = Path("scripts/apple_strings_parity_baseline.json")
BASE_LOCALE = "en"
STRINGS_FILE = "Localizable.strings"

# `"key" = "value";` — the key may contain escaped quotes. Anchored to the
# line start so a `"` inside a value can never be read as a key.
KEY_RE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', re.MULTILINE)


def read_keys(path: Path) -> list[str]:
    """Declared keys, in file order, duplicates included."""
    return KEY_RE.findall(path.read_text(encoding="utf-8"))


def collect(res_dir: Path) -> dict[str, list[str]]:
    catalogues: dict[str, list[str]] = {}
    for lproj in sorted(res_dir.glob("*.lproj")):
        strings = lproj / STRINGS_FILE
        if strings.is_file():
            catalogues[lproj.name.removesuffix(".lproj")] = read_keys(strings)
    return catalogues


def compute(catalogues: dict[str, list[str]]) -> tuple[dict[str, list[str]], list[str], list[str]]:
    """Returns (missing-per-locale, orphan complaints, duplicate complaints)."""
    base = set(catalogues[BASE_LOCALE])
    missing: dict[str, list[str]] = {}
    orphans: list[str] = []
    duplicates: list[str] = []

    for locale, keys in catalogues.items():
        seen = set(keys)
        dupes = sorted(k for k, n in collections.Counter(keys).items() if n > 1)
        for key in dupes:
            duplicates.append(f"{locale}: {key} is declared more than once")
        if locale == BASE_LOCALE:
            continue
        for key in sorted(seen - base):
            orphans.append(f"{locale}: {key} is not in {BASE_LOCALE}.lproj")
        gap = sorted(base - seen)
        if gap:
            missing[locale] = gap

    return missing, orphans, duplicates


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=None,
                    help="repo root to check (defaults to this script's repo); used by the negative-control tests")
    ap.add_argument("--update-baseline", action="store_true",
                    help="rewrite the baseline to the tree's current state")
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent.parent
    res_dir = root / RES_SUBPATH
    baseline_path = root / BASELINE_SUBPATH

    if not res_dir.is_dir():
        print(f"FATAL: no .lproj resources at {res_dir}", file=sys.stderr)
        return 2

    catalogues = collect(res_dir)
    if BASE_LOCALE not in catalogues:
        print(f"FATAL: {BASE_LOCALE}.lproj/{STRINGS_FILE} missing under {res_dir}", file=sys.stderr)
        return 2
    if len(catalogues) < 2:
        print(f"FATAL: only found {sorted(catalogues)} — nothing to compare", file=sys.stderr)
        return 2

    missing, orphans, duplicates = compute(catalogues)

    if args.update_baseline:
        payload = {
            "_comment": [
                "Keys that a shipped locale does not carry yet. Generated by",
                "scripts/check_apple_strings_parity.py --update-baseline.",
                "This list may only SHRINK. Adding to it is adding untranslated",
                "UI; the gate makes that a deliberate, reviewable act.",
            ],
            "missing": {loc: keys for loc, keys in sorted(missing.items())},
        }
        baseline_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        total = sum(len(v) for v in missing.values())
        print(f"baseline rewritten: {total} untranslated key(s) across {len(missing)} locale(s)")
        return 0

    try:
        baseline = json.loads(baseline_path.read_text(encoding="utf-8")).get("missing", {})
    except FileNotFoundError:
        print(f"FATAL: baseline missing at {baseline_path} — run --update-baseline", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"FATAL: baseline is not valid JSON: {exc}", file=sys.stderr)
        return 2

    new_drift: dict[str, list[str]] = {}
    stale: dict[str, list[str]] = {}
    for locale in sorted(set(missing) | set(baseline)):
        allowed = set(baseline.get(locale, []))
        actual = set(missing.get(locale, []))
        if actual - allowed:
            new_drift[locale] = sorted(actual - allowed)
        if allowed - actual:
            stale[locale] = sorted(allowed - actual)

    failed = False

    if duplicates:
        failed = True
        print("FAIL — a key is declared twice; .strings keeps only the last, so the", file=sys.stderr)
        print("       earlier translation is dead text that reads as done:\n", file=sys.stderr)
        for line in duplicates:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    if orphans:
        failed = True
        print(f"FAIL — key(s) present in a locale but not in {BASE_LOCALE}.lproj. {BASE_LOCALE} is the", file=sys.stderr)
        print("       fallback for every other locale and has no fallback itself, so", file=sys.stderr)
        print("       English users see the raw dotted key:\n", file=sys.stderr)
        for line in orphans:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    if new_drift:
        failed = True
        total = sum(len(v) for v in new_drift.values())
        print(f"FAIL — {total} key(s) exist in {BASE_LOCALE}.lproj but in no baseline entry.", file=sys.stderr)
        print("       Adding a key to en without adding it to every locale is exactly", file=sys.stderr)
        print("       how the existing 670-string gap accumulated:\n", file=sys.stderr)
        for locale, keys in new_drift.items():
            print(f"    {locale}.lproj — {len(keys)} new:", file=sys.stderr)
            for key in keys[:8]:
                print(f"        - {key}", file=sys.stderr)
            if len(keys) > 8:
                print(f"        ... ({len(keys) - 8} more)", file=sys.stderr)
        print("\n    Translate them into each locale. Do not paste the English text —", file=sys.stderr)
        print("    L10n already falls back to English on its own, so a pasted string", file=sys.stderr)
        print("    only hides the gap from this gate.\n", file=sys.stderr)

    if stale:
        failed = True
        total = sum(len(v) for v in stale.values())
        print(f"FAIL — {total} baseline entr(ies) are no longer missing. The baseline is a", file=sys.stderr)
        print("       ratchet: it may only shrink, so translated keys must leave it or", file=sys.stderr)
        print("       the same gap can silently reopen later:\n", file=sys.stderr)
        for locale, keys in stale.items():
            print(f"    {locale}.lproj — {len(keys)} to remove:", file=sys.stderr)
            for key in keys[:8]:
                print(f"        - {key}", file=sys.stderr)
            if len(keys) > 8:
                print(f"        ... ({len(keys) - 8} more)", file=sys.stderr)
        print(f"\n    Fix: python3 {BASELINE_SUBPATH.parent.name}/{Path(__file__).name} --update-baseline\n", file=sys.stderr)

    if failed:
        return 1

    debt = sum(len(v) for v in missing.values())
    locales = ", ".join(f"{loc} {len(catalogues[loc])}" for loc in sorted(catalogues))
    print(f"OK — {len(catalogues)} locales, no new drift, no orphans, no duplicates.")
    print(f"     key counts: {locales}")
    if debt:
        per_locale = ", ".join(f"{loc} {len(keys)}" for loc, keys in sorted(missing.items()))
        print(f"     known untranslated debt: {debt} key(s) ({per_locale}) — these render as English.")
    else:
        print("     translation debt is zero.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

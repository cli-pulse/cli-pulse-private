#!/usr/bin/env python3
"""
Quota tier names — the display strings that are also dedup keys.

A "tier name" is the short label on a usage bar or ring: "Weekly", "5h Window",
"Credits". Collectors on macOS, the Python helper, Android and the Tauri desktop
app all produce them in English, they are uploaded to the cloud, and every
device renders the PRODUCING device's bytes. They are also used as alert
`suppression_key`s, `ForEach` ids, React list keys and dictionary keys, and
`WatchRingMath.weeklyTier` finds the weekly window by matching "week" in the
name. So the stored value is always English and only the rendering is localized
(`L10n.quotaTier.localized`).

That leaves one decision per name, which is a judgment call and not derivable:

  TRANSLATE    the name is a generic description this app composed for a number
               it computed ("Weekly", "Requests", "Bonus Credits").
  PASSTHROUGH  the name is, or contains, the VENDOR's own term for the bucket —
               a product or plan ("Ark Plan", "Kilo Pass", "Token Plan"), a
               model ("Pro", "Flash" are Gemini tiers), a unit the vendor coined
               ("Compute Points", "DIEM Balance"), or a currency code. Showing a
               translation would stop the row matching the vendor's own billing
               page, which is what the user is comparing it against.

`scripts/quota_tier_names.json` records that decision for every known name WITH
ITS REASON, and this gate keeps the record honest.

WHAT IT CHECKS
  1. every manifest name is still produced somewhere   — a stale entry FAILS, so
     the record can only shrink and cannot quietly cover something new;
  2. every name the scanner finds is in the manifest   — a new collector's tier
     name FAILS until someone decides how to show it;
  3. every TRANSLATE name has its `L10n.quotaTier` accessor AND a value in all
     six .lproj catalogues                             — a half-done
     translation FAILS instead of silently rendering English;
  4. every entry carries a real reason, and no name is classified twice.

THE SCANNER'S RECALL IS 82%, MEASURED — DO NOT READ IT AS COMPLETE
Collectors rarely call `UsageTier(name:)` directly; most build tiers through a
local helper (`windowTier("Rolling", …)`, `addTier("Voucher", …)`,
`addPool("Open Source", …)`) or map a vendor token to a name in a switch
(z.ai's `TOKENS_LIMIT` -> "Tokens"). The scanner covers constructors, helpers
whose name contains tier/pool/window/bucket, and `name = "…"` assignments.
Measured against the 56 names found by reading every producer by hand, it sees
46 of them. These 10 it CANNOT see, and each is in the manifest by hand:

    CNY Balance   (not a literal at all — DeepSeek composes
                   `"\\(b.currency) Balance"`, so the manifest marks it
                   composed_at_runtime and pins the EXPRESSION instead)
    Extra Usage, Opus (Weekly), Opus only, Session, Sonnet (Weekly)
                  (Python helper / HelperSwift, not Swift constructors)
    Other, Quota, Window   (Android and desktop fallbacks)
    Overall       (AlertGenerator's synthetic name for a provider with no tiers)

So check 2 is a ratchet for the common case, not a proof of completeness.
Checks 1, 3 and 4 hold regardless of what the scanner can see. Adding a name
the scanner cannot reach is a review job; this gate cannot do it for you.

Pure Python on purpose: repo-hygiene runs on Linux.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

LOCALES = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]

APPLE = "CLI Pulse Bar"
PRODUCER_ROOTS = [
    f"{APPLE}/CLIPulseCore/Sources",
    f"{APPLE}/CLI Pulse Bar",
    f"{APPLE}/CLI Pulse Bar iOS",
    f"{APPLE}/CLI Pulse Bar Watch",
    "HelperSwift/Sources",
    "android/app/src/main",
    "helper",
]
SOURCE_SUFFIXES = (".swift", ".kt", ".py")

CTOR = re.compile(r"\b(?:UsageTier|TierDTO|makeExtraTier)\s*\(")
NAME_ARG = re.compile(r'\bname\s*[:=]\s*"((?:[^"\\]|\\.)*)"')
HELPER = re.compile(r'\b\w*(?:[Tt]ier|[Pp]ool|[Ww]indow|[Bb]ucket)\w*\s*\(\s*"((?:[^"\\]|\\.)*)"')
NAME_ASSIGN = re.compile(r'\bname\s*=\s*"((?:[^"\\]|\\.)*)"')

# Literals the scanner's heuristics reach but which are not tier names: file
# paths, provider ids, log-span names, test scaffolding, and the obfuscated
# window keys Anthropic returns (`seven_day_omelette`) which the app maps INTO
# a tier name rather than using as one.
NOT_A_TIER_NAME = re.compile(
    r"^(?:/|~/)"                      # any absolute or home-relative path
    r"|^[a-z0-9]+(?:[-_][a-z0-9]+)*$" # lower_snake / kebab ids and tokens
    r"|^X$"
    r"|^\\#\(name\)$"
    r"|^MacBook Pro$"
    r"|^(?:Dashboard metrics pass|Helper heartbeat monitor|Provider adapter review|Session error triage)$"
)

BOILERPLATE_REASON = re.compile(r"^(?:todo|tbd|n/?a|\?+|fixme|-+|because|reason)?$", re.I)


def fail(errors: list[str]) -> None:
    print("quota tier names: FAILED\n")
    for e in errors:
        print(f"  - {e}")
    print(
        "\nEvery quota tier name needs a recorded decision in"
        " scripts/quota_tier_names.json:\n"
        '  TRANSLATE   -> add "l10n_key", the L10n.quotaTier accessor, and a value in all six .lproj\n'
        "  PASSTHROUGH -> say in \"reason\" whose product, model, unit or currency it is\n"
    )
    sys.exit(1)


def source_files(root: Path):
    for rel in PRODUCER_ROOTS:
        base = root / rel
        if not base.exists():
            continue
        for p in base.rglob("*"):
            if p.suffix in SOURCE_SUFFIXES and "/.build/" not in str(p):
                yield p


def strip_line_comments(src: str) -> str:
    """Blank out `//` and `#` comment tails, keeping offsets so lines still map.

    A comment documenting an XML pattern — `// Pattern: <option name="quotaInfo"`
    — otherwise reads as a tier-name assignment. Quotes are tracked so a `//`
    inside a string literal (a URL) does not start a comment.
    """
    out: list[str] = []
    i, n = 0, len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            if c == "\\" and i + 1 < n:
                out.append(src[i:i + 2])
                i += 2
                continue
            if c == '"':
                in_str = False
            out.append(c)
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if src.startswith("//", i) or c == "#":
            j = src.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def scan_produced(root: Path) -> dict[str, str]:
    """Names the heuristics can see -> "file:line" of the first hit."""
    found: dict[str, str] = {}
    for p in source_files(root):
        src = strip_line_comments(p.read_text(encoding="utf-8", errors="replace"))
        hits: list[tuple[str, int]] = []
        for m in CTOR.finditer(src):
            nm = NAME_ARG.search(src[m.end(): m.end() + 400])
            if nm:
                hits.append((nm.group(1), m.start()))
        for rx in (HELPER, NAME_ASSIGN):
            for m in rx.finditer(src):
                hits.append((m.group(1), m.start()))
        for name, off in hits:
            if "\\(" in name or not name.strip():
                continue          # interpolated or empty: not a closed literal
            if NOT_A_TIER_NAME.search(name):
                continue
            if name not in found:
                line = src[:off].count("\n") + 1
                found[name] = f"{p.relative_to(root)}:{line}"
    return found


def literal_is_present(root: Path, name: str) -> bool:
    """Is this exact literal still written down anywhere a producer lives?"""
    needle = f'"{name}"'
    for p in source_files(root):
        if needle in p.read_text(encoding="utf-8", errors="replace"):
            return True
    return False


def parse_strings(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    rx = re.compile(r'\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
    for line in path.read_text(encoding="utf-8").splitlines():
        m = rx.match(line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    for i, a in enumerate(sys.argv):
        if a == "--root":
            root = Path(sys.argv[i + 1]).resolve()

    manifest_path = root / "scripts/quota_tier_names.json"
    if not manifest_path.exists():
        fail([f"missing manifest {manifest_path.relative_to(root)}"])
    entries = json.loads(manifest_path.read_text(encoding="utf-8"))["entries"]

    errors: list[str] = []

    # 4. shape, duplicates, reasons
    seen: dict[str, dict] = {}
    for e in entries:
        name = e.get("name", "")
        if not name:
            errors.append(f"entry with no name: {e!r}")
            continue
        if name in seen:
            errors.append(f'"{name}" is classified twice')
            continue
        seen[name] = e
        if e.get("display") not in ("TRANSLATE", "PASSTHROUGH"):
            errors.append(f'"{name}": display must be TRANSLATE or PASSTHROUGH, got {e.get("display")!r}')
        reason = (e.get("reason") or "").strip()
        if BOILERPLATE_REASON.match(reason) or len(reason) < 20:
            errors.append(f'"{name}": needs a real reason, got {reason!r}')
        if e.get("display") == "TRANSLATE" and not e.get("l10n_key"):
            errors.append(f'"{name}": TRANSLATE entries need a "key"')
        if e.get("display") == "PASSTHROUGH" and e.get("l10n_key"):
            errors.append(f'"{name}": PASSTHROUGH entries must not carry an "l10n_key"')

    # 1. stale entries. A name COMPOSED at runtime ("\(b.currency) Balance")
    #    has no literal to find, so requiring one would fail forever; such an
    #    entry must instead name the expression that builds it.
    for name, e in seen.items():
        if e.get("composed_at_runtime"):
            if not e.get("composed_from"):
                errors.append(f'"{name}": composed_at_runtime needs "composed_from" naming the expression')
            elif not literal_is_present(root, e["composed_from"]):
                errors.append(
                    f'"{name}": composed_from {e["composed_from"]!r} is not in any producer — '
                    "the expression that built this name is gone, so delete the entry")
        elif not literal_is_present(root, name):
            errors.append(f'"{name}": no producer writes this literal any more — stale entry, delete it')

    # 2. newly produced names
    produced = scan_produced(root)
    for name, where in sorted(produced.items()):
        if name not in seen:
            errors.append(f'"{name}" ({where}) is produced but has no entry in the manifest')

    # 3. TRANSLATE names must be fully wired
    l10n = (root / APPLE / "CLIPulseCore/Sources/CLIPulseCore/L10n.swift").read_text(encoding="utf-8")
    cats = {loc: parse_strings(root / APPLE /
                               f"CLIPulseCore/Sources/CLIPulseCore/Resources/{loc}.lproj/Localizable.strings")
            for loc in LOCALES}
    for name, e in sorted(seen.items()):
        if e.get("display") != "TRANSLATE":
            continue
        key = e["l10n_key"]
        if f'tr("{key}")' not in l10n:
            errors.append(f'"{name}": no L10n accessor calls tr("{key}")')
        if f'case "{name}"' not in l10n and f'case "{name.lower()}"' not in l10n:
            errors.append(f'"{name}": L10n.quotaTier.localized has no case for it, so it renders English')
        for loc in LOCALES:
            if key not in cats[loc]:
                errors.append(f'"{name}": {key} missing from {loc}.lproj')

    if errors:
        fail(errors)

    t = sum(1 for e in seen.values() if e["display"] == "TRANSLATE")
    p = len(seen) - t
    blind = sum(1 for e in seen.values() if e.get("scanner_blind_spot"))
    print(f"quota tier names: OK — {len(seen)} classified ({t} translated, {p} passed through), "
          f"{len(produced)} seen by the scanner, {blind} recorded by hand (scanner cannot see them).")


if __name__ == "__main__":
    main()

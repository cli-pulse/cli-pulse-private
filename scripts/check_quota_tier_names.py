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
     six .lproj catalogues, and on Android an entry in `QuotaTierDisplay` AND a
     value in all six strings.xml                     — a half-done
     translation FAILS instead of silently rendering English. On Apple the
     `localized` switch is READ, not searched: it must be on
     `raw.lowercased()`, every label lowercase, the name's label must return
     the accessor whose tr() key is the manifest's `l10n_key`, and no label may
     match a PASSTHROUGH name or no name at all;
  4. every entry carries a real reason, and no name is classified twice — not
     even in two capitalizations, since matching ignores case.

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

ANDROID_RES = "android/app/src/main/res"
ANDROID_DIRS = ["values", "values-es", "values-ja", "values-ko", "values-zh-rCN", "values-zh-rTW"]
ANDROID_MAPPER = "android/app/src/main/java/com/clipulse/android/ui/common/QuotaTierDisplay.kt"

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


def strip_line_comments(src: str, hash_comments: bool = True) -> str:
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
        if src.startswith("//", i) or (hash_comments and c == "#"):
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


# Files that CONSUME tier names rather than produce them. L10n.swift's
# `case "4-hour"` and QuotaTierDisplay.kt's `"4-hour" to R.string…` are the
# mappers this gate checks; counting them as producers meant those entries could
# never be reported stale, and a doc comment quoting "Voice slots" did the same.
NOT_A_PRODUCER = {"L10n.swift", "QuotaTierDisplay.kt"}

# A name only another repository writes has no literal here to find. Such an
# entry says which file writes it, as `produced_elsewhere`, instead of being
# kept alive by an unrelated comment — which is how "Other" (written only by the
# Tauri desktop's Gemini collector) passed the stale check until comments
# stopped counting: PetRuleset.swift mentions "Other" in a doc comment.
EXTERNAL_PRODUCER_REPOS = ("cli-pulse-desktop ",)


def literal_is_present(root: Path, name: str) -> bool:
    """Is this exact literal still written down, outside a comment, where a producer lives?"""
    needle = f'"{name}"'
    for p in source_files(root):
        if p.name in NOT_A_PRODUCER:
            continue
        src = p.read_text(encoding="utf-8", errors="replace")
        if needle in src and needle in strip_line_comments(src, hash_comments=p.suffix == ".py"):
            return True
    return False


def swift_quota_tier_switch(l10n: str) -> tuple[str | None, dict[str, str], list[tuple[str, str]], list[str]]:
    """Read `L10n.quotaTier`: (switch subject, accessor -> tr key, [(label, accessor)], problems).

    Reads the switch rather than searching the file for `case "<name>"`. The
    search accepted `case "Bonus Credits":`, which can never match because the
    switch is on `raw.lowercased()`, and `case "weekly": return monthly`, which
    renders every Weekly bar as 每月. Both passed, and so did a PASSTHROUGH
    "weekly" beside TRANSLATE "Weekly", which the runtime translates anyway.
    """
    problems: list[str] = []
    src = strip_line_comments(l10n, hash_comments=False)
    enum = re.search(r"\benum\s+quotaTier\s*\{", src)
    if not enum:
        return None, {}, [], ["L10n.swift has no `enum quotaTier`, so no tier name is translated"]
    depth, end = 0, len(src)
    for k in range(enum.end() - 1, len(src)):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                end = k
                break
    body = src[enum.end():end]
    accessors = {m.group(1): m.group(2) for m in re.finditer(
        r'\bstatic\s+var\s+`?(\w+)`?\s*:\s*String\s*\{\s*tr\(\s*"([^"]+)"\s*\)\s*\}', body)}
    func = re.search(r"\bfunc\s+localized\s*\(\s*_\s+raw\s*:\s*String\s*\)", body)
    switch = re.search(r"\bswitch\s+([^{]+?)\s*\{", body[func.end():]) if func else None
    if not switch:
        return None, accessors, [], ["L10n.quotaTier has no `func localized(_ raw: String)` with a switch to read"]
    labels: list[tuple[str, str]] = []
    for m in re.finditer(r'\bcase\s+((?:"[^"]*"\s*,\s*)*"[^"]*")\s*:\s*return\s+`?(\w+)`?',
                         body[func.end() + switch.end():]):
        for label in re.findall(r'"([^"]*)"', m.group(1)):
            labels.append((label, m.group(2)))
    if not labels:
        problems.append("L10n.quotaTier.localized has no `case \"…\": return accessor` arms to read")
    return switch.group(1).strip(), accessors, labels, problems


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

    # 4b. names that differ by case alone. `localized` matches case-insensitively,
    #     so two such entries are one rendering with two recorded decisions.
    by_folded: dict[str, list[str]] = {}
    for name in seen:
        by_folded.setdefault(name.lower(), []).append(name)
    for folded, names in sorted(by_folded.items()):
        if len(names) > 1:
            errors.append(f"{' and '.join(repr(n) for n in sorted(names))} differ only by case; "
                          "L10n.quotaTier.localized matches case-insensitively, so they cannot be "
                          "classified differently")

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
        elif e.get("produced_elsewhere") is not None:
            where = str(e["produced_elsewhere"])
            if not where.startswith(EXTERNAL_PRODUCER_REPOS):
                errors.append(f'"{name}": produced_elsewhere must name the file in '
                              f'{" or ".join(r.strip() for r in EXTERNAL_PRODUCER_REPOS)} that writes it, got {where!r}')
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
    subject, accessors, labels, switch_problems = swift_quota_tier_switch(l10n)
    errors += switch_problems
    if subject is not None and re.sub(r"\s", "", subject) != "raw.lowercased()":
        errors.append(f"L10n.quotaTier.localized switches on `{subject}`, not `raw.lowercased()` — "
                      "the lowercase labels below only match a lowercased name")
    arm: dict[str, str] = {}
    for label, accessor in labels:
        if label in arm:
            errors.append(f'L10n.quotaTier.localized has case "{label}" twice; only the first can match')
            continue
        arm[label] = accessor
        if label != label.lower():
            errors.append(f'L10n.quotaTier.localized has case "{label}", which can never match: '
                          "the switch is on raw.lowercased(), so every label must be lowercase")
    for name, e in sorted(seen.items()):
        if e.get("display") != "TRANSLATE":
            continue
        key = e["l10n_key"]
        if f'tr("{key}")' not in l10n:
            errors.append(f'"{name}": no L10n accessor calls tr("{key}")')
        accessor = arm.get(name.lower())
        if accessor is None:
            errors.append(f'"{name}": L10n.quotaTier.localized has no case "{name.lower()}", so it renders English')
        elif accessor not in accessors:
            errors.append(f'"{name}": case "{name.lower()}" returns {accessor}, which is not a '
                          "`static var … { tr(\"…\") }` accessor of L10n.quotaTier")
        elif accessors[accessor] != key:
            errors.append(f'"{name}": case "{name.lower()}" returns {accessor}, which reads '
                          f'{accessors[accessor]}, but the manifest says {key} — every "{name}" bar '
                          "would show another tier's name")
        for loc in LOCALES:
            if key not in cats[loc]:
                errors.append(f'"{name}": {key} missing from {loc}.lproj')
    folded = {n.lower(): e for n, e in seen.items()}
    for label in sorted(arm):
        entry = folded.get(label)
        if entry is None:
            errors.append(f'L10n.quotaTier.localized has case "{label}", which matches no manifest name — '
                          "a tier nobody classified, or a stale arm")
        elif entry.get("display") == "PASSTHROUGH":
            errors.append(f'"{entry["name"]}" is PASSTHROUGH, but L10n.quotaTier.localized has case "{label}", '
                          "so it is translated at runtime anyway")

    # 3b. ...and the same on Android, where the resource name is the key with `_`.
    if (root / ANDROID_RES).is_dir():
        mapper_path = root / ANDROID_MAPPER
        mapper = mapper_path.read_text(encoding="utf-8") if mapper_path.exists() else ""
        if not mapper:
            errors.append(f"{ANDROID_MAPPER} is missing, so every tier name renders English on Android")
        android = {d: set(re.findall(r'<string\s+name="([^"]+)"',
                                     (root / ANDROID_RES / d / "strings.xml").read_text(encoding="utf-8")))
                   if (root / ANDROID_RES / d / "strings.xml").exists() else set()
                   for d in ANDROID_DIRS}
        for name, e in sorted(seen.items()):
            if e.get("display") != "TRANSLATE":
                continue
            res = e["l10n_key"].replace(".", "_")
            if mapper and f'"{name.lower()}" to R.string.{res}' not in mapper:
                errors.append(f'"{name}": QuotaTierDisplay has no "{name.lower()}" to R.string.{res}, so Android renders English')
            for d in ANDROID_DIRS:
                if res not in android[d]:
                    errors.append(f'"{name}": {res} missing from {d}/strings.xml')

    if errors:
        fail(errors)

    t = sum(1 for e in seen.values() if e["display"] == "TRANSLATE")
    p = len(seen) - t
    blind = sum(1 for e in seen.values() if e.get("scanner_blind_spot"))
    print(f"quota tier names: OK — {len(seen)} classified ({t} translated, {p} passed through), "
          f"{len(produced)} seen by the scanner, {blind} recorded by hand (scanner cannot see them).")


if __name__ == "__main__":
    main()

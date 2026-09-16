#!/usr/bin/env python3
"""
Android string-resource gate: parity, and the translation defects parity cannot see.

HISTORY
-------
v1.21 E6 added a key-presence check after values-es / values-ko / values-zh-rTW
drifted to 137 keys while values/ had 195 — ~30% of the UI silently fell back
to English. That check was a regex over `<string name="…">`, and on 2026-09-17
it was blind to everything below. Worse, it ran only in android-ci.yml, only on
PRs touching android/**, and only AFTER the step that restores
google-services.json from a secret — so a PR editing just this script never ran
it, and a run without the secret never reached it.

WHAT IT CHECKS NOW (the catalogues are at parity, so nothing is baselined):

  * SHIPPED LOCALES are declared, not discovered. Deleting values-ko/ used to
    remove it from the loop and pass. An undeclared locale directory fails too,
    so the list cannot quietly go stale in the other direction.
  * the file PARSES. aapt2 rejects a malformed file at build time, but this gate
    runs without the Android SDK, in the path-blind hygiene job.
  * MISSING keys, ORPHAN keys (in a locale, not in values/), DUPLICATE keys,
    and a key whose TYPE differs (<string> in values/, <plurals> in a locale).
  * FORMAT ARGUMENTS. `getString(id, args)` walks the arguments by the
    specifiers it finds: a translation that turns `%1$d` into `%1$s` or drops
    `%2$s` passes aapt2 and crashes with IllegalFormatConversionException, or
    shows the wrong value, in that language only. Positions are compared, not
    order, so `%2$s … %1$s` is a legal reordering.
  * PLURALS. Every <plurals> carries `other` (Android's fallback for any
    missing quantity), and only the CLDR categories that language actually
    selects. `one` in ja/ko/zh is never chosen, so it is dead text that reads
    as done.
  * a BARE % in a string formatted with arguments. Formatter parses it anyway:
    Spanish "98 % del uso" reads `% d` as a flag and a conversion.
  * UNESCAPED APOSTROPHES, which fail the aapt2 release build.
  * PER-APP LANGUAGE. The manifest's android:localeConfig names exactly the
    shipped locales, so Android 13+ offers every language the app has and
    none it lacks.

Usage:
  python3 scripts/ci_check_android_strings_parity.py
  python3 scripts/ci_check_android_strings_parity.py --root <tree>   # negative-control fixtures

Exit codes:
  0 — every check holds
  1 — at least one defect (each printed with its locale and key)
  2 — the resources could not be read at all
"""
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

RES_SUBPATH = Path("android/app/src/main/res")
DEFAULT_DIR = "values"
STRINGS_FILE = "strings.xml"

MANIFEST_SUBPATH = Path("android/app/src/main/AndroidManifest.xml")
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"

# The BCP-47 tag each shipped directory is declared as in locales_config.xml.
# `values` is English: the unqualified resources are the English copy.
LOCALE_TAG = {
    "values": "en",
    "values-es": "es",
    "values-ja": "ja",
    "values-ko": "ko",
    "values-zh-rCN": "zh-CN",
    "values-zh-rTW": "zh-TW",
}

# The locales the app SHIPS, with the plural categories CLDR selects for
# integers in each language. `many` is a CLDR 42 category for Spanish (used for
# 1000000); devices whose ICU predates it simply use `other`.
SHIPPED: dict[str, frozenset[str]] = {
    "values": frozenset({"one", "other"}),
    "values-es": frozenset({"one", "many", "other"}),
    "values-ja": frozenset({"other"}),
    "values-ko": frozenset({"other"}),
    "values-zh-rCN": frozenset({"other"}),
    "values-zh-rTW": frozenset({"other"}),
}

# A directory is a LOCALE directory when its first qualifier is a language:
# values-es, values-zh-rTW, values-b+zh+Hant. values-night, values-v23 and
# values-sw600dp are configuration qualifiers.
LOCALE_DIR = re.compile(r"^values-(?:[a-z]{2,3}(?:-r[A-Z]{2})?|b\+[a-z]{2,3}(?:\+[A-Za-z0-9]+)*)(?:-|$)")

# Specifiers as this codebase writes them. Deliberately narrow: a loose Java
# Formatter pattern reads the "% o" in "~98% of" as a flag and a conversion.
SPEC = re.compile(r"%%|%(?:(\d+)\$)?(?:\.\d+)?([sdf])")
KIND = {"s": "string", "d": "integer", "f": "float"}

# An apostrophe aapt2 accepts: escaped, or anywhere inside a "double-quoted" value.
UNESCAPED_APOSTROPHE = re.compile(r"(?<!\\)'")


class Resource:
    def __init__(self, kind: str, values: dict[str, str], translatable: bool):
        self.kind = kind            # "string" | "plurals" | "string-array"
        self.values = values        # "" for a string; quantity or index otherwise
        self.translatable = translatable


def signature(text: str) -> list[tuple[str, str]]:
    sig: list[tuple[str, str]] = []
    implicit = 0
    for m in SPEC.finditer(text):
        if m.group(0) == "%%":
            continue
        implicit += 1
        sig.append((m.group(1) or str(implicit), KIND[m.group(2)]))
    return sorted(sig)


def stray_percent(text: str) -> bool:
    """A `%` that is neither a specifier nor `%%`. In a string formatted with
    arguments, Formatter parses it anyway: "98 % del uso" reads `% d` as a
    space flag plus an integer conversion and consumes an argument."""
    return "%" in SPEC.sub("", text)


def load(path: Path) -> tuple[dict[str, Resource], list[str]]:
    """Resources in one strings.xml, plus problems found while reading it."""
    problems: list[str] = []
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        return {}, [f"does not parse ({exc}); aapt2 drops the build, and every key in it is unreadable"]
    resources: dict[str, Resource] = {}
    for elem in root:
        name = elem.get("name")
        if elem.tag not in ("string", "plurals", "string-array") or name is None:
            continue
        if name in resources:
            problems.append(f"{name!r} is declared more than once; only one of them is ever used")
            continue
        translatable = elem.get("translatable", "true") != "false"
        if elem.tag == "string":
            values = {"": "".join(elem.itertext())}
        elif elem.tag == "plurals":
            values = {item.get("quantity", ""): "".join(item.itertext()) for item in elem.findall("item")}
        else:
            values = {str(i): "".join(item.itertext()) for i, item in enumerate(elem.findall("item"))}
        resources[name] = Resource(elem.tag, values, translatable)
        for slot, text in values.items():
            stripped = text.strip()
            quoted = len(stripped) >= 2 and stripped.startswith('"') and stripped.endswith('"')
            if not quoted and UNESCAPED_APOSTROPHE.search(text):
                where = f"{name!r}" + (f" [{slot}]" if slot else "")
                problems.append(f"{where} has an unescaped apostrophe; aapt2 fails the release build (write \\')")
    return resources, problems


def compare(locale: str, base: dict[str, Resource], res: dict[str, Resource]) -> list[str]:
    problems: list[str] = []
    wanted = {k for k, r in base.items() if r.translatable}
    for key in sorted(wanted - set(res)):
        problems.append(f"{key!r} is missing — the UI falls back to English")
    for key in sorted(set(res) - wanted):
        why = "is marked translatable=\"false\" in values/" if key in base else "is not in values/"
        problems.append(f"{key!r} {why} (orphan)")
    for key in sorted(wanted & set(res)):
        b, r = base[key], res[key]
        if b.kind != r.kind:
            problems.append(f"{key!r} is a <{r.kind}> here but a <{b.kind}> in values/")
            continue
        formatted = any(signature(text) for text in b.values.values())
        for slot, text in sorted(r.values.items()):
            if formatted and stray_percent(text):
                where = f"{key!r}" + (f" [{slot}]" if slot else "")
                problems.append(f"{where} has a bare % in a string formatted with arguments; write %%")
        if b.kind == "string":
            want, got = signature(b.values[""]), signature(r.values[""])
            if want != got:
                problems.append(f"{key!r} consumes {got or 'no arguments'}, values/ consumes {want or 'no arguments'}")
        elif b.kind == "plurals":
            allowed = SHIPPED[locale]
            if "other" not in r.values:
                problems.append(f"{key!r} has no quantity=\"other\", which every language falls back to")
            for quantity in sorted(set(r.values) - allowed):
                problems.append(f"{key!r} has quantity=\"{quantity}\", which {locale} never selects (dead text)")
            want = signature(b.values.get("other", ""))
            for quantity, text in sorted(r.values.items()):
                got = signature(text)
                if quantity == "other" and got != want:
                    problems.append(f"{key!r} [other] consumes {got or 'no arguments'}, values/ consumes {want or 'no arguments'}")
                elif quantity != "other" and not set(got) <= set(want):
                    problems.append(f"{key!r} [{quantity}] consumes {got}, which values/ [other] does not supply ({want or 'none'})")
        else:
            if len(b.values) != len(r.values):
                problems.append(f"{key!r} has {len(r.values)} items, values/ has {len(b.values)}")
            for slot in sorted(set(b.values) & set(r.values)):
                if signature(b.values[slot]) != signature(r.values[slot]):
                    problems.append(f"{key!r} item {slot} consumes different format arguments from values/")
    return problems


def locale_config_problems(root: Path) -> list[str]:
    """Android 13+ lists an app under Settings > App languages only when the
    manifest declares android:localeConfig, and offers exactly the languages
    that file names. A shipped locale missing from it cannot be chosen; a
    language in it with no resources is offered and then renders English."""
    manifest = root / MANIFEST_SUBPATH
    if not manifest.is_file():
        return [f"{MANIFEST_SUBPATH} is missing"]
    try:
        app = ET.parse(manifest).getroot().find("application")
    except ET.ParseError as exc:
        return [f"{MANIFEST_SUBPATH} does not parse ({exc})"]
    ref = app.get(f"{ANDROID_NS}localeConfig") if app is not None else None
    if not ref or not ref.startswith("@xml/"):
        return ["<application> declares no android:localeConfig, so Android 13+ offers no per-app language"]
    path = root / RES_SUBPATH / "xml" / f"{ref.removeprefix('@xml/')}.xml"
    if not path.is_file():
        return [f"android:localeConfig points at {ref}, which does not exist"]
    try:
        declared = [el.get(f"{ANDROID_NS}name") for el in ET.parse(path).getroot().findall("locale")]
    except ET.ParseError as exc:
        return [f"{path.name} does not parse ({exc})"]
    problems = []
    want = {LOCALE_TAG[d] for d in SHIPPED}
    for tag in sorted(want - set(declared)):
        problems.append(f"{path.name} does not offer {tag}, which the app ships")
    for tag in sorted(set(declared) - want):
        problems.append(f"{path.name} offers {tag}, which has no strings (it would render English)")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=None, help="repo root to check (defaults to this script's repo)")
    args = ap.parse_args()
    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent.parent
    res_dir = root / RES_SUBPATH

    base_path = res_dir / DEFAULT_DIR / STRINGS_FILE
    if not base_path.is_file():
        print(f"FATAL: default strings.xml missing at {base_path}", file=sys.stderr)
        return 2

    report: dict[str, list[str]] = {}
    base, base_problems = load(base_path)
    if base_problems:
        report[DEFAULT_DIR] = base_problems
    if not base and not base_problems:
        print(f"FATAL: {base_path} declares no strings — nothing to compare", file=sys.stderr)
        return 2
    for key, r in base.items():
        if any(signature(t) for t in r.values.values()) and any(stray_percent(t) for t in r.values.values()):
            report.setdefault(DEFAULT_DIR, []).append(
                f"{key!r} has a bare % in a string formatted with arguments; write %%")
        if r.kind == "plurals":
            for quantity in sorted(SHIPPED[DEFAULT_DIR] - set(r.values)):
                report.setdefault(DEFAULT_DIR, []).append(f"{key!r} has no quantity=\"{quantity}\"")

    present = {d.name for d in res_dir.iterdir() if d.is_dir() and LOCALE_DIR.match(d.name)} if res_dir.is_dir() else set()
    for name in sorted(present - set(SHIPPED)):
        report.setdefault(name, []).append(
            "is a locale directory this gate does not declare; add it to SHIPPED with its CLDR plural categories")

    for locale in sorted(set(SHIPPED) - {DEFAULT_DIR}):
        path = res_dir / locale / STRINGS_FILE
        if not path.is_file():
            report.setdefault(locale, []).append(f"{STRINGS_FILE} is missing — the whole locale renders English")
            continue
        res, problems = load(path)
        problems += compare(locale, base, res) if res or not problems else []
        if problems:
            report.setdefault(locale, []).extend(problems)

    config_problems = locale_config_problems(root)
    if config_problems:
        report.setdefault("per-app language", []).extend(config_problems)

    if not report:
        print(f"OK — {len(SHIPPED)} locales, {len(base)} resources each: parity, format arguments, "
              "plural categories, percent signs, apostrophes and per-app language all hold.")
        return 0

    total = sum(len(v) for v in report.values())
    print(f"FAIL — {total} Android string-resource defect(s):\n", file=sys.stderr)
    for locale, problems in report.items():
        print(f"  {locale}:", file=sys.stderr)
        for line in problems:
            print(f"    - {line}", file=sys.stderr)
    print("\nTranslate rather than paste English: a pasted string hides the gap from this gate\n"
          "and still reads as English on the device.\n", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
r"""
Traditional Chinese terminology — one word per concept, recorded with its evidence.

The zh-Hant (Taiwan) words for session and alert changed three times in a
month, each time by a reviewer's opinion: #557 unified the Apple catalogue on
會話 for sessions, #582 moved Android zh-rTW to 告警 for alerts, #593 moved
Apple back to 警示. A language reviewer reads one catalogue at a time, so
nothing stopped the next review from flipping a term back, or from leaving half
the strings on the old one. Counting the platforms' own zh_TW tables settles
these questions; this gate makes the answer stick.

`scripts/zh_hant_terms.json` records, per concept, the term each platform uses,
the variants it must not use, and the evidence (counts from macOS's and
Android's own zh_TW strings). This gate reads every Apple `zh-Hant.lproj/*.strings`
table under `CLI Pulse Bar/` — CLIPulseCore's catalogue AND the tables an app
target ships from its own bundle (App Intents names, Siri phrases, permission
prompts) — and every Android `values-zh-rTW` resource file, and fails on a
forbidden variant anywhere in a string value, listing file:line: key. Build
output (`build/`, `.build/`, `DerivedData/`, e.g. an App Store .xcarchive that
carries an old copy of the catalogue) is not scanned: it is not the source.

WHAT IT CHECKS
  1. no string value contains a forbidden variant for its platform, unless the
     allowlist names that (file, key) and a phrase containing it — a vendor's own
     product name such as 「Google 帳戶」. Comments are not scanned: they are
     not shown to anyone;
  2. every allowlist entry still matches, and carries a real reason — a stale
     entry FAILS, so the list can only shrink;
  3. the manifest cannot contradict itself: a forbidden variant that is part of
     a term the same platform uses would fail every correct string (Android's
     處理程序 contains 程序, which is why Android forbids nothing for process);
  4. each platform has at least one table, and every term in use appears in it
     at least once — a moved directory FAILS instead of scanning nothing.

A value is matched after decoding what the platform itself decodes, so an
escaped word is still that word: `\U6703` in an Apple table, `\u6703`,
`&#26371;` and `&#x6703;` in an Android one. Apple keys may be unquoted
(`key = "value";`) and Android attributes single-quoted (`name='x'`).

It does not judge whether a sentence reads well; that is a review job. It stops
a decided term from being undone, silently or one string at a time.

  python3 scripts/check_zh_hant_terms.py
  python3 scripts/check_zh_hant_terms.py --root <tree>   # test fixtures

Pure Python on purpose: repo-hygiene runs on Linux.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

MANIFEST = "scripts/zh_hant_terms.json"
APPLE_ROOT = "CLI Pulse Bar"
ANDROID_ROOT = "android"
PLATFORMS = ("apple", "android")

# Android resource directories that hold Traditional Chinese (Taiwan): the
# classic qualifier, the BCP-47 form, and either with further qualifiers.
ANDROID_DIR = re.compile(r"^values-(?:zh-rTW|b\+zh\+Hant(?:\+TW)?)(?:-.+)?$")

# Build output is not the source: an .xcarchive or a Gradle intermediate carries
# a copy of an older catalogue. Matched against path parts relative to the root,
# so a checkout that itself lives under a directory named `build` is still read.
SKIP_DIRS = {".build", "build", "DerivedData"}

# The key is quoted or a bare token, as OpenStep plists allow (`key = "v";`).
STRINGS_ENTRY = re.compile(r'(?:"(?P<qkey>(?:[^"\\]|\\.)*)"|(?P<key>[^\s;,={}()"/]+))'
                           r'\s*=\s*"(?P<value>(?:[^"\\]|\\.)*)"\s*;')
XML_COMMENT = re.compile(r"<!--.*?-->", re.S)
_NAME = r"""\bname=(?:"(?P<name>[^"]+)"|'(?P<sname>[^']+)')"""
# `<string(?=\s)`, not `<string\b`: the word boundary also matches `<string-array`.
XML_STRING = re.compile(r'<string(?=\s)[^>]*?' + _NAME + r'[^>]*?(?<!/)>(?P<body>.*?)</string>', re.S)
XML_PLURALS = re.compile(r'<plurals\b[^>]*?' + _NAME + r'[^>]*>(?P<body>.*?)</plurals>', re.S)
XML_ARRAY = re.compile(r'<(?:string-)?array\b[^>]*?' + _NAME + r'[^>]*>(?P<body>.*?)</(?:string-)?array>', re.S)
XML_ITEM = re.compile(r'<item\b([^>]*?)(?<!/)>(.*?)</item>', re.S)
QUANTITY = re.compile(r"""\bquantity=["'](\w+)["']""")
# `\U6703` (Apple), `\u6703`, `&#26371;`, `&#x6703;` (Android). Only code
# points from U+0080 up are decoded: every term is CJK, and leaving control
# characters alone keeps a decoded value's newlines where the file has them.
ESCAPE = re.compile(r"\\[uU]([0-9A-Fa-f]{4})|&#[xX]([0-9A-Fa-f]+);|&#([0-9]+);")


def decode(value: str) -> str:
    def one(m: re.Match) -> str:
        cp = int(m.group(1) or m.group(2), 16) if (m.group(1) or m.group(2)) else int(m.group(3))
        return chr(cp) if 0x80 <= cp <= 0x10FFFF and not 0xD800 <= cp <= 0xDFFF else m.group(0)
    return ESCAPE.sub(one, value)


def blank_strings_comments(src: str) -> str:
    """`.strings` text with /* */ and // comments turned into spaces, keeping
    every offset and newline so line numbers still point at the file."""
    out = list(src)
    i, n = 0, len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
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


def blank_xml_comments(src: str) -> str:
    return XML_COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), src)


def apple_entries(text: str) -> list[tuple[str, int, str]]:
    """(key, offset of the value, value) for every entry of a `.strings` table."""
    src = blank_strings_comments(text)
    return [(m.group("qkey") if m.group("qkey") is not None else m.group("key"), m.start("value"), m.group("value"))
            for m in STRINGS_ENTRY.finditer(src)]


def android_entries(text: str) -> list[tuple[str, int, str]]:
    """(label, offset of the text, text) for every string, plural item and array
    item. A plural item is labelled name[quantity], an array item name[index]."""
    src = blank_xml_comments(text)

    def name(m: re.Match) -> str:
        return m.group("name") or m.group("sname")

    out = [(name(m), m.start("body"), m.group("body")) for m in XML_STRING.finditer(src)]
    for m in XML_PLURALS.finditer(src):
        for it in XML_ITEM.finditer(m.group("body")):
            q = QUANTITY.search(it.group(1))
            out.append((f"{name(m)}[{q.group(1) if q else '?'}]", m.start("body") + it.start(2), it.group(2)))
    for m in XML_ARRAY.finditer(src):
        for idx, it in enumerate(XML_ITEM.finditer(m.group("body"))):
            out.append((f"{name(m)}[{idx}]", m.start("body") + it.start(2), it.group(2)))
    return sorted(out, key=lambda e: e[1])


def is_build_output(path: Path, root: Path) -> bool:
    return not SKIP_DIRS.isdisjoint(path.relative_to(root).parts)


def tables(root: Path) -> dict[str, list[Path]]:
    apple_root = root / APPLE_ROOT
    apple = sorted(p for p in apple_root.rglob("zh-Hant.lproj/*.strings")
                   if not is_build_output(p, root)) if apple_root.is_dir() else []
    android_root = root / ANDROID_ROOT
    android: list[Path] = []
    if android_root.is_dir():
        for d in sorted(android_root.rglob("values-*")):
            if d.is_dir() and ANDROID_DIR.match(d.name) and not is_build_output(d, root):
                android.extend(sorted(d.glob("*.xml")))
    return {"apple": apple, "android": android}


def manifest_problems(concepts: list[dict], allowlist: list[dict]) -> list[str]:
    errors: list[str] = []
    uses: dict[str, list[str]] = {p: [] for p in PLATFORMS}
    for c in concepts:
        name = c.get("concept") or "?"
        if len((c.get("evidence") or "").strip()) < 40:
            errors.append(f"manifest: concept {name!r} needs its evidence (what was counted, and the numbers)")
        for p in PLATFORMS:
            spec = c.get(p)
            if not isinstance(spec, dict) or not spec.get("use") or not isinstance(spec.get("forbid"), list):
                errors.append(f"manifest: concept {name!r} needs {p}.use and a {p}.forbid list")
                continue
            uses[p].append(spec["use"])
    for c in concepts:
        for p in PLATFORMS:
            spec = c.get(p)
            if not isinstance(spec, dict) or not isinstance(spec.get("forbid"), list):
                continue
            for bad in spec["forbid"]:
                for term in uses[p]:
                    if bad in term:
                        errors.append(f"manifest: {p} forbids {bad!r} ({c.get('concept')}), but it is part of "
                                      f"{term!r}, a term {p} uses — every correct string would fail")
    seen: set[tuple] = set()
    forbidden = {p: {b for c in concepts for b in (c.get(p) or {}).get("forbid") or []} for p in PLATFORMS}
    for e in allowlist:
        ident = (e.get("platform"), e.get("file"), e.get("key"), e.get("phrase"))
        label = f'{e.get("file")}: {e.get("key")}: "{e.get("phrase")}"'
        if ident in seen:
            errors.append(f"allowlist: {label} is listed twice")
        seen.add(ident)
        if e.get("platform") not in PLATFORMS:
            errors.append(f"allowlist: {label} has platform {e.get('platform')!r} (expected apple or android)")
        elif e.get("variant") not in forbidden[e["platform"]]:
            errors.append(f"allowlist: {label} excuses {e.get('variant')!r}, which {e['platform']} does not forbid")
        if not e.get("phrase") or not e.get("variant") or e["variant"] not in e["phrase"]:
            errors.append(f"allowlist: {label} — the phrase must contain the variant it excuses")
        if len((e.get("reason") or "").strip()) < 20:
            errors.append(f"allowlist: {label} needs a real reason")
    return errors


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    if "--root" in sys.argv:
        root = Path(sys.argv[sys.argv.index("--root") + 1]).resolve()

    manifest_path = root / MANIFEST
    if not manifest_path.exists():
        print(f"zh-Hant terms: FAILED — {MANIFEST} not found under {root}")
        return 1
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    concepts = manifest.get("concepts") or []
    allowlist = manifest.get("allowlist") or []
    errors = manifest_problems(concepts, allowlist)
    if not concepts:
        errors.append("manifest: no concepts")

    found = tables(root)
    used_allow: set[int] = set()
    scanned = 0
    for platform in PLATFORMS:
        paths = found[platform]
        if not paths:
            where = f"{APPLE_ROOT}/**/zh-Hant.lproj" if platform == "apple" else f"{ANDROID_ROOT}/**/values-zh-rTW"
            errors.append(f"no {platform} tables found under {where} — the scanner is not looking where the catalogues are")
            continue
        rules = [(c["concept"], c[platform]["use"], bad)
                 for c in concepts if isinstance(c.get(platform), dict)
                 for bad in c[platform].get("forbid") or []]
        in_use = {c[platform]["use"]: 0 for c in concepts if isinstance(c.get(platform), dict) and c[platform].get("use")}
        read = apple_entries if platform == "apple" else android_entries
        for path in paths:
            rel = path.relative_to(root).as_posix()
            text = path.read_text(encoding="utf-8")
            for key, offset, raw in read(text):
                scanned += 1
                value = decode(raw)
                masked = value
                for idx, e in enumerate(allowlist):
                    if (e.get("platform"), e.get("file"), e.get("key")) == (platform, rel, key) \
                            and e.get("phrase") and e["phrase"] in masked:
                        used_allow.add(idx)
                        masked = masked.replace(e["phrase"], "\x00" * len(e["phrase"]))
                for term in in_use:
                    in_use[term] += masked.count(term)
                for concept, use, bad in rules:
                    at = masked.find(bad)
                    while at != -1:
                        line = text.count("\n", 0, offset) + value.count("\n", 0, at) + 1
                        errors.append(f'{rel}:{line}: {key}: uses {bad} — {concept} is {use} on {platform} '
                                      f'(「{value[max(0, at - 8):at + len(bad) + 8]}」)')
                        at = masked.find(bad, at + len(bad))
        for term, count in in_use.items():
            if count == 0:
                errors.append(f"{platform}: {term!r} appears in no {platform} string — either the scanner is reading "
                              f"nothing, or the term is gone and {MANIFEST} should say what replaced it")

    for idx, e in enumerate(allowlist):
        if idx not in used_allow:
            errors.append(f'allowlist: {e.get("file")}: {e.get("key")}: "{e.get("phrase")}" no longer appears — '
                          "stale entry, delete it")

    if errors:
        print("zh-Hant terms: FAILED\n")
        for e in errors:
            print(f"  - {e}")
        print(
            f"\nUse the term {MANIFEST} records for that concept and platform. If a forbidden sequence is\n"
            "legitimately part of another word (a vendor's product name), add a (file, key, phrase) entry to its\n"
            "allowlist with the reason. To change a term itself, change the manifest and its evidence in the\n"
            "same pull request as the catalogues.")
        return 1
    counts = {p: len(found[p]) for p in PLATFORMS}
    print(f"zh-Hant terms: OK — {len(concepts)} concepts, {counts['apple']} Apple and {counts['android']} Android "
          f"table(s), {scanned} strings scanned, {len(used_allow)} allowlisted phrase(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

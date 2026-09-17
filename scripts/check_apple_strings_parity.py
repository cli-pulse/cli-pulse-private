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

These checks have no baseline at all, because each is at zero today and none
has an acceptable non-zero value:

  * ORPHANS — a key in a locale but not in en. en is the fallback for every
    other locale and has no fallback of its own, so an en-missing key is
    user-visible debug output with no safety net. This is the H-13 bug
    (`L10nEnBaseKeysTests`) expressed as a gate.
  * DUPLICATES — a key declared twice in one file. `.strings` silently keeps
    the last, so the earlier translation is dead text that reads as done.
  * FORMAT ARGUMENTS — a translation whose specifiers (or `${name}` parameters)
    consume different arguments from English. A `%d` that became `%@` crashes
    `String(format:)` in that language only. A bare `%` in a formatted string is
    the same defect in disguise: "98 % de" consumes an argument.
  * CODE ARGUMENTS — the arguments each `tr("key", …)` passes, typed from the
    accessor, against the specifiers in EN. The check above cannot see a
    specifier changed in all six catalogues at once; this one can.
  * COMPOSED KEYS — `tr("pet.form_\\(form.rawValue)")` expanded over the enum's
    cases, so a new case without its key fails. One the gate cannot expand
    fails too.

And the tables the APP BUNDLES ship, which the system reads without L10n:

  * every `CLI Pulse Bar/<app>/<locale>.lproj/*.strings` gets the same syntax
    scan, two-reader agreement and duplicate check as the core catalogues;
  * every App Intents literal (title, description, category, search keywords,
    parameter title, description and request dialogs, parameter summary, type
    and display names, shortTitle, dialogs — initialised, computed or returned
    by a helper) is a key in the app's en Localizable.strings, and every key
    there is still such a literal. A value is read by its type, so `"…"`,
    `.init("…")`, `Type("…")`, `Type.init("…")` and `.init(stringLiteral: "…")`
    all yield the same key, and a literal inside a localized value that no
    reading claims (a ternary, a helper call, a label the gate does not list)
    fails instead of going unchecked. Files are chosen by what their code
    uses, not by how the import is spelled; every AppIntent must yield a title
    (and every AppEnum/AppEntity a type name) the gate actually read; and a
    table with keys while nothing was read fails rather than "matching";
  * every such table is a child of its PBXVariantGroup for all six locales, in
    the owning target's Resources phase — otherwise Xcode silently skips it;
  * the four hosts that render L10n declare exactly the six locales in
    CFBundleLocalizations (three of them have no .lproj of their own).

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
  1 — new drift, stale baseline, orphan key, duplicate key, format-argument
      mismatch, or any app-bundle problem above
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

# The catalogues the app SHIPS, declared rather than discovered.
#
# Discovery by glob was a hole: deleting an entire `.lproj` simply removed it
# from the loop, so a whole shipped translation could vanish and this gate
# stayed green. Both Info.plists declare these six, so Apple routes users into
# them; a missing one is a regression, not a smaller job. (Codex review,
# 2026-08-30.)
SHIPPED_LOCALES = ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"]

# `"key" = "value";` — the key may contain escaped quotes. Anchored to the
# line start so a `"` inside a value can never be read as a key.
KEY_RE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', re.MULTILINE)


def read_keys(path: Path) -> list[str]:
    """Declared keys, in file order, duplicates included."""
    return KEY_RE.findall(path.read_text(encoding="utf-8"))


class StringsSyntaxError(Exception):
    """A .strings file CFBundle would refuse, with the line that breaks it."""


def _scan_strings(text: str) -> int:
    """Strictly scan an old-style plist `.strings` body; return the entry count.

    Raises `StringsSyntaxError` on anything CFBundle would reject. Deliberately
    hand-written rather than shelled out to `plutil`: that is macOS-only, and
    this gate runs on the Linux CI runner, where a shell-out either crashes
    (it did) or gets caught and skipped — leaving the gate blind exactly where
    it actually runs.

    Literal newlines inside a quoted value are legal here and are used (see
    `advanced.remote_consent_body`), so they are counted, not rejected.
    """
    i, n, line, entries = 0, len(text), 1, 0
    if text.startswith("\ufeff"):
        i = 1

    def fail(msg: str) -> None:
        raise StringsSyntaxError(f"line {line}: {msg}")

    def skip_filler() -> None:
        nonlocal i, line
        while i < n:
            c = text[i]
            if c == "\n":
                line += 1
                i += 1
            elif c.isspace():
                i += 1
            elif text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j
            elif text.startswith("/*", i):
                j = text.find("*/", i + 2)
                if j < 0:
                    fail("unterminated /* comment")
                line += text.count("\n", i, j)
                i = j + 2
            else:
                return

    def quoted() -> str:
        nonlocal i, line
        if i >= n or text[i] != '"':
            fail(f"expected a quoted string, found {text[i:i+1]!r}")
        i += 1
        out = []
        while i < n:
            c = text[i]
            if c == "\\":
                if i + 1 >= n:
                    fail("string ends with a dangling backslash")
                out.append(text[i + 1])
                if text[i + 1] == "\n":
                    line += 1
                i += 2
            elif c == '"':
                i += 1
                return "".join(out)
            else:
                if c == "\n":
                    line += 1
                out.append(c)
                i += 1
        fail("unterminated string")
        return ""

    def expect(ch: str) -> None:
        nonlocal i
        if i >= n or text[i] != ch:
            found = text[i:i+1] or "end of file"
            hint = ("usually an unescaped quote inside the previous value "
                    '(write \\" or a typographic quote)') if ch == ";" else \
                   "the entry is not in the house `\"key\" = \"value\";` form"
            fail(f"expected {ch!r}, found {found!r} — {hint}")
        i += 1

    while True:
        skip_filler()
        if i >= n:
            return entries
        quoted()            # key
        skip_filler()
        expect("=")
        skip_filler()
        quoted()            # value
        skip_filler()
        expect(";")
        entries += 1


def unparseable(root: Path) -> list[str]:
    """String tables this repo will not accept: every CLIPulseCore catalogue AND
    every table an app bundle ships (`CLI Pulse Bar/<app>/<locale>.lproj/*.strings`).

    NOT the same set as "files CFBundle would refuse", and the difference is
    deliberate: this scanner is STRICTER. CFBundle's old-style plist parser
    also accepts unquoted tokens (`key = value;`), a brace-wrapped dictionary,
    and a stray extra `;`. None of those appear in any shipped catalogue,
    Xcode does not emit them, and accepting them would mean carrying a second
    grammar for no benefit. It also rejects an unterminated `/* comment`,
    which CFBundle swallows to end-of-file — silently losing every key after
    it, which is the outage this gate exists to prevent.

    So a rejection here means "not the house format", which is a superset of
    "the runtime cannot load it".

    This gate reads keys with a line regex, which is the right tool for
    counting parity but happily accepts a file the runtime rejects. On
    2026-09-06 a stray double quote inside an English value
    (`"Can"t reach this Mac."`) made `en.lproj` unparseable: this script
    printed OK and reported the full key count, because the regex read
    straight past the break. CFBundle does not — it dropped the WHOLE
    catalogue, so every key in the app, including long-shipped ones, rendered
    as its raw dotted identifier. Only `L10nFallbackTests` noticed. A broken
    `en` is the worst case: it is the fallback for every other locale and has
    no fallback itself.

    The app-bundle tables were read only by loose line regexes until
    2026-09-17. Deleting the closing `*/` of the header comment in
    `ja.lproj/AppShortcuts.strings` made `plutil -p` print `{}` — every Japanese
    Siri phrase gone — and `plutil -lint` still said OK, so Xcode copies the
    file without complaint. This gate said OK too. An unescaped quote in an
    `InfoPlist.strings` makes iOS drop the whole table, so both permission
    prompts fall back to English. Same scanner, same two-reader rule, now for
    every table.
    """
    broken: list[str] = []
    tables = [(lproj.name, lproj / STRINGS_FILE) for lproj in sorted((root / RES_SUBPATH).glob("*.lproj"))]
    tables += [(str(path.relative_to(root / APP_ROOT_SUBPATH)), path) for path in app_bundle_tables(root)]
    for label, strings in tables:
        if not strings.is_file():
            continue
        try:
            entries = _scan_strings(strings.read_text(encoding="utf-8"))
        except StringsSyntaxError as exc:
            broken.append(f"{label} — {exc}")
            continue
        except UnicodeDecodeError as exc:
            broken.append(f"{label} — not valid UTF-8: {exc}")
            continue
        # Vacuity guard: a scanner that silently consumed nothing would call
        # an empty file healthy, and an empty catalogue is the same outage.
        if entries == 0:
            broken.append(f"{label} — parsed, but declares no entries")
            continue
        # Two independent readers, one file. `read_keys` is a line regex that
        # COUNTS; `_scan_strings` is a syntax scanner that VALIDATES. They must
        # agree, and when they do not it is the regex that has read past
        # something — which is precisely how the 2026-09-06 break scored a
        # full 1069 keys on a catalogue the runtime could not load at all.
        counted = len(read_keys(strings))
        if counted != entries:
            broken.append(
                f"{label} — the two readers disagree: the key regex sees "
                f"{counted} entr(ies), the syntax scanner {entries}. One of "
                f"them is misreading this file."
            )
    return broken


def app_bundle_tables(root: Path) -> list[Path]:
    """Every `.strings` table an app target ships from its own folder."""
    app_root = root / APP_ROOT_SUBPATH
    if not app_root.is_dir():
        return []
    return sorted(app_root.glob("*/*.lproj/*.strings"))


def app_bundle_duplicates(root: Path) -> list[str]:
    """A key declared twice in an app-bundle table. The system keeps the last, so
    the first is dead text — and nothing compared these tables for it."""
    found: list[str] = []
    for path in app_bundle_tables(root):
        try:
            keys = read_keys(path)
        except (OSError, UnicodeDecodeError):
            continue  # unparseable() reports it
        label = path.relative_to(root / APP_ROOT_SUBPATH)
        for key in sorted(k for k, n in collections.Counter(keys).items() if n > 1):
            found.append(f"{label}: {key} is declared more than once")
    return found


def replacement_characters(root: Path) -> list[str]:
    """Values that carry U+FFFD, the character a decoder substitutes for bytes it
    could not read.

    It is valid UTF-8, so the syntax scanner accepts it and every key still
    counts. On screen it is a black diamond: ja `integrations.filter_all` shipped
    as す���て and `integrations.filter_providers` as プロバ��ダー, both mangled
    somewhere between a translator and the file. No catalogue has a legitimate use
    for it.
    """
    found: list[str] = []
    tables = sorted((root / RES_SUBPATH).glob("*.lproj/*.strings"))
    tables += sorted((root / APP_ROOT_SUBPATH).glob("*/*.lproj/*.strings"))
    for path in tables:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError):
            continue  # unparseable() reports undecodable files
        for number, line in enumerate(lines, 1):
            if "\ufffd" in line:
                found.append(f"{path.relative_to(root)}:{number}: {line.strip()[:80]}")
    return found


def collect(res_dir: Path) -> dict[str, list[str]]:
    catalogues: dict[str, list[str]] = {}
    for lproj in sorted(res_dir.glob("*.lproj")):
        strings = lproj / STRINGS_FILE
        if strings.is_file():
            catalogues[lproj.name.removesuffix(".lproj")] = read_keys(strings)
    return catalogues


L10N_SUBPATH = Path("CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/L10n.swift")


APP_ROOT_SUBPATH = Path("CLI Pulse Bar")
USAGE_KEY = "UsageDescription"


def unlocalized_permission_prompts(root: Path) -> list[str]:
    """Every `NS…UsageDescription` an app declares must be localized, in every locale.

    These are the lines iOS shows inside its own permission alert. They are not
    in any `Localizable.strings` — iOS reads them from the app bundle's
    `<locale>.lproj/InfoPlist.strings` — so nothing above can see them. Until
    this existed there was not a single InfoPlist.strings in the repository and
    the iPhone's camera and local-network prompts were English in every language.
    A new usage description added without translations would reopen that
    silently, so it fails here.
    """
    import plistlib
    problems: list[str] = []
    app_root = root / APP_ROOT_SUBPATH
    if not app_root.is_dir():
        return problems
    for info in sorted(app_root.glob("*/Info.plist")):
        try:
            declared = plistlib.loads(info.read_bytes())
        except Exception:
            continue
        keys = sorted(k for k in declared if k.endswith(USAGE_KEY))
        if not keys:
            continue
        target = info.parent.name
        for loc in SHIPPED_LOCALES:
            strings = info.parent / f"{loc}.lproj" / "InfoPlist.strings"
            if not strings.is_file():
                problems.append(f"{target}: {loc}.lproj/InfoPlist.strings is missing ({', '.join(keys)})")
                continue
            have = set(re.findall(r'^\s*"([^"]+)"\s*=', strings.read_text(encoding="utf-8"), re.M))
            for k in keys:
                if k not in have:
                    problems.append(f"{target}: {k} is not in {loc}.lproj/InfoPlist.strings")
    return problems


APP_TABLES = ("Localizable.strings", "AppShortcuts.strings")
PHRASE_TOKEN = "${applicationName}"


def _strings_keys_values(path: Path) -> dict[str, str]:
    rx = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
    return {m.group(1): m.group(2) for m in rx.finditer(path.read_text(encoding="utf-8"))}


def app_bundle_table_problems(root: Path) -> list[str]:
    """String tables that live in an APP bundle rather than in CLIPulseCore.

    App Intent titles and Shortcut phrases are read by the system from the app's
    own `<locale>.lproj/Localizable.strings` and `AppShortcuts.strings` — the
    Shortcuts app and Spotlight can read them before CLI Pulse has run, so they
    cannot go through L10n. The catalogue comparison above only covers
    CLIPulseCore, so these get their own checks:

      * every locale of a table declares the same keys;
      * every Shortcut phrase, in every locale, contains ${applicationName}
        EXACTLY ONCE — iOS silently ignores a phrase without it, so a translation
        that drops the token makes that phrase dead in that language with no error
        anywhere;
      * every phrase written in an `AppShortcutsProvider` has a translation.
    """
    problems: list[str] = []
    app_root = root / APP_ROOT_SUBPATH
    if not app_root.is_dir():
        return problems
    for app_dir in sorted(d for d in app_root.iterdir() if d.is_dir()):
        for table in APP_TABLES:
            present = {loc: app_dir / f"{loc}.lproj" / table for loc in SHIPPED_LOCALES}
            if not any(p.is_file() for p in present.values()):
                continue
            parsed: dict[str, dict[str, str]] = {}
            for loc, path in present.items():
                if not path.is_file():
                    problems.append(f"{app_dir.name}: {loc}.lproj/{table} is missing")
                else:
                    parsed[loc] = _strings_keys_values(path)
            base = parsed.get(BASE_LOCALE, {})
            for loc, kv in parsed.items():
                if loc == BASE_LOCALE:
                    continue
                for k in sorted(set(base) - set(kv)):
                    problems.append(f"{app_dir.name}: {loc}.lproj/{table} lacks {k!r}")
                for k in sorted(set(kv) - set(base)):
                    problems.append(f"{app_dir.name}: {loc}.lproj/{table} has {k!r}, which en does not")
            if table == "AppShortcuts.strings":
                for loc, kv in parsed.items():
                    for k, v in kv.items():
                        n = v.count(PHRASE_TOKEN)
                        if n != 1:
                            problems.append(
                                f"{app_dir.name}: {loc}.lproj/{table} phrase {k!r} contains "
                                f"{PHRASE_TOKEN} {n} times — iOS silently ignores it unless it is exactly once")
                declared = set()
                for swift in app_dir.rglob("*.swift"):
                    src = swift.read_text(encoding="utf-8", errors="replace")
                    for block in re.findall(r"phrases:\s*\[(.*?)\]", src, re.S):
                        for lit in re.findall(r'"((?:[^"\\]|\\.)*)"', block):
                            declared.add(lit.replace("\\(.applicationName)", PHRASE_TOKEN))
                for phrase in sorted(declared - set(base)):
                    problems.append(f"{app_dir.name}: Shortcut phrase {phrase!r} has no entry in AppShortcuts.strings")
    return problems


# The arguments a value consumes, written the way this codebase writes them:
# %@ %d %ld %lld %.1f, optionally positional (%2$@). `%%` is a literal percent.
# App-bundle tables use `${name}` parameters instead. Deliberately narrow: a
# looser pattern reads the "% o" in "~98% of" as a flag-and-conversion.
SPEC_RE = re.compile(r"%%|%(?:(\d+)\$)?(?:\.\d+)?(?:ll|l|q)?([@dfiu])|\$\{(\w+)\}")
SPEC_KIND = {"@": "object", "d": "integer", "i": "integer", "u": "integer", "f": "float"}


def argument_signature(value: str) -> list[tuple[str, str]]:
    """(position, kind) for every argument the value consumes, sorted.

    Positions are compared, not order: `%2$d … %1$d` in a translation consumes
    the same arguments as `%d … %d` in English.
    """
    sig: list[tuple[str, str]] = []
    implicit = 0
    for m in SPEC_RE.finditer(value):
        if m.group(0) == "%%":
            continue
        if m.group(3):
            sig.append((m.group(3), "parameter"))
            continue
        implicit += 1
        sig.append((m.group(1) or str(implicit), SPEC_KIND[m.group(2)]))
    return sorted(sig)


def _stray_percent(value: str) -> bool:
    """A `%` that is neither a specifier nor `%%`. `String(format:)` parses it
    anyway: Spanish "98 % de" reads `% d` as a flag and an integer conversion."""
    return "%" in SPEC_RE.sub("", value)


def _signature_problems(label: str, tables: dict[str, dict[str, str]]) -> list[str]:
    base = tables.get(BASE_LOCALE, {})
    problems: list[str] = []
    for loc, kv in sorted(tables.items()):
        for key in sorted(set(kv) & set(base)):
            formatted = any(kind != "parameter" for _, kind in argument_signature(base[key]))
            if formatted and _stray_percent(kv[key]):
                problems.append(f"{label}: {loc} {key!r} has a bare % in a string formatted with "
                                "arguments; write %%")
        if loc == BASE_LOCALE:
            continue
        for key in sorted(set(kv) & set(base)):
            want, got = argument_signature(base[key]), argument_signature(kv[key])
            if want != got:
                problems.append(f"{label}: {loc} {key!r} consumes {got or 'nothing'}, "
                                f"{BASE_LOCALE} consumes {want or 'nothing'}")
    return problems


def format_argument_mismatches(root: Path) -> list[str]:
    """Translations that consume different arguments from English.

    `String(format:)` walks the argument list by the specifiers it finds, so a
    translation that turns `%d` into `%@` reads an integer as an object pointer
    and crashes, one that drops a `%@` shifts every later argument into the
    wrong slot, and one that adds a specifier reads past the end. None of it
    shows in English, and none of it is a missing key, so nothing above sees it.
    """
    res_dir = root / RES_SUBPATH
    problems = _signature_problems(
        STRINGS_FILE,
        {loc: _strings_keys_values(res_dir / f"{loc}.lproj" / STRINGS_FILE)
         for loc in SHIPPED_LOCALES if (res_dir / f"{loc}.lproj" / STRINGS_FILE).is_file()})
    app_root = root / APP_ROOT_SUBPATH
    if app_root.is_dir():
        for app_dir in sorted(d for d in app_root.iterdir() if d.is_dir()):
            for table in APP_TABLES:
                paths = {loc: app_dir / f"{loc}.lproj" / table for loc in SHIPPED_LOCALES}
                parsed = {loc: _strings_keys_values(p) for loc, p in paths.items() if p.is_file()}
                if parsed:
                    problems += _signature_problems(f"{app_dir.name}/{table}", parsed)
    return problems


def keys_the_code_asks_for(root: Path) -> set[str]:
    """Every key passed to `L10n.tr` in L10n.swift.

    The catalogue-to-catalogue comparison below is structurally blind to a key
    that is missing from ALL of them: there is no locale to be inconsistent
    with. `L10n.resolve` then falls back to en, finds nothing there either, and
    NSLocalizedString echoes the key — so the user reads `collector_error.
    invalid_url` off the screen. That is the same class of bug the fallback
    machinery was built for, from the other direction.
    A key COMPOSED at runtime — `tr("pet.form_\\(form.rawValue)")` — is not a
    literal, so it is not returned here; `composed_keys` expands it per enum case.
    Comments are not read: a doc comment quoting `tr("…")` is not a request.
    """
    return {key for key, *_ in _tr_calls(root) if "\\(" not in key}


# ── Reading Swift ────────────────────────────────────────────────────────────
# The checks below read Swift source, which a line regex misreads the moment a
# comment quotes code or a string holds a brace. These helpers produce two
# views of a file, each the SAME LENGTH as the source so an offset in one is an
# offset in the other: comments blanked (string contents kept, to read
# literals), and comments AND string contents blanked (to match brackets).

def swift_masks(src: str, literals: list[tuple[int, int]] | None = None) -> tuple[str, str]:
    """(comments blanked, comments and string contents blanked). Newlines kept.

    `literals`, when given, receives the (start, end) span of every string literal
    that closes — delimiters and `#`s included, nested ones inside an
    interpolation too."""
    n = len(src)
    no_comments, code = list(src), list(src)
    stack: list[tuple] = []   # ("str", hashes, multiline, start) | ("interp", paren depth)
    open_string = re.compile(r'(#*)("""|")')

    def blank(buf: list[str], a: int, b: int) -> None:
        for k in range(a, b):
            if buf[k] != "\n":
                buf[k] = " "

    i = 0
    while i < n:
        top = stack[-1] if stack else None
        if top is None or top[0] == "interp":
            if src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                blank(no_comments, i, j)
                blank(code, i, j)
                i = j
                continue
            if src.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if src.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif src.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                blank(no_comments, i, j)
                blank(code, i, j)
                i = j
                continue
            if src[i] in '#"':
                m = open_string.match(src, i)
                if m:
                    stack.append(("str", len(m.group(1)), m.group(2) == '"""', i))
                    i = m.end()
                    continue
            if top is not None:
                if src[i] == "(":
                    stack[-1] = ("interp", top[1] + 1)
                elif src[i] == ")":
                    if top[1] == 1:
                        code[i] = " "   # closes `\(`, whose opening is blanked too
                        stack.pop()
                        i += 1
                        continue
                    stack[-1] = ("interp", top[1] - 1)
            i += 1
            continue
        _, hashes, multiline, start = top
        if src[i] == "\\" and src.startswith("#" * hashes, i + 1):
            k = i + 1 + hashes
            if k < n and src[k] == "(":
                blank(code, i, k + 1)
                stack.append(("interp", 1))
                i = k + 1
                continue
            blank(code, i, min(n, k + 1))
            i = k + 1
            continue
        close = ('"""' if multiline else '"') + "#" * hashes
        if src.startswith(close, i):
            stack.pop()
            i += len(close)
            if literals is not None:
                literals.append((start, i))
            continue
        if src[i] != "\n":
            code[i] = " "
        i += 1
    return "".join(no_comments), "".join(code)


def match_close(code: str, open_at: int) -> int:
    """Offset just past the bracket that closes `code[open_at]`, or -1."""
    closer = {"(": ")", "[": "]", "{": "}"}
    stack: list[str] = []
    for k in range(open_at, len(code)):
        c = code[k]
        if c in closer:
            stack.append(closer[c])
        elif c in ")]}":
            if not stack or stack.pop() != c:
                return -1
            if not stack:
                return k + 1
    return -1


def split_top_level(code: str, a: int, b: int) -> list[tuple[int, int]]:
    """Comma-separated spans of `code[a:b]` at bracket depth zero, blanks dropped."""
    spans, depth, start = [], 0, a
    for k in range(a, b):
        c = code[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            spans.append((start, k))
            start = k + 1
    spans.append((start, b))
    return [(s, e) for s, e in spans if code[s:e].strip()]


def first_string_literal(text: str, at: int) -> str | None:
    """The raw (still escaped) body of the `"…"` literal starting at `text[at]`."""
    m = re.compile(r'"((?:[^"\\\n]|\\\([^)\n]*\)|\\.)*)"').match(text, at)
    return m.group(1) if m else None


CORE_SOURCES_SUBPATH = Path("CLI Pulse Bar/CLIPulseCore/Sources")


class SwiftIndex:
    """What the checks need to know about CLIPulseCore's declarations: the String
    raw values of every enum, the associated-value types of every enum case, and
    the return type of every function name."""

    def __init__(self, root: Path) -> None:
        self.raw_values: dict[str, list[str]] = {}
        self.case_payloads: dict[str, dict[str, list[str]]] = {}
        self.returns: dict[str, set[str]] = collections.defaultdict(set)
        base = root / CORE_SOURCES_SUBPATH
        for path in sorted(base.rglob("*.swift")) if base.is_dir() else []:
            try:
                src = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            no_comments, code = swift_masks(src)
            self._read_enums(no_comments, code)
            for m in re.finditer(r"\bfunc\s+`?(\w+)`?\s*(?:<[^>{]*>)?\s*\(", code):
                close = match_close(code, m.end() - 1)
                if close < 0:
                    continue
                r = re.compile(r"\s*(?:async\s+)?(?:throws\s+)?->\s*([\w.]+[?!]?)").match(code, close)
                if r:
                    self.returns[m.group(1)].add(r.group(1))

    def _read_enums(self, no_comments: str, code: str) -> None:
        for m in re.finditer(r"\benum\s+(\w+)\s*(:[^{]*)?\{", code):
            body_open = m.end() - 1
            body_close = match_close(code, body_open)
            if body_close < 0:
                continue
            name, inherits = m.group(1), m.group(2) or ""
            string_raw = re.search(r"\bString\b", inherits) is not None
            raws: list[str] = []
            payloads: dict[str, list[str]] = {}
            depth = 0
            k = body_open + 1
            while k < body_close - 1:
                c = code[k]
                if c in "{([":
                    depth += 1
                elif c in "})]":
                    depth -= 1
                elif depth == 0 and code.startswith("case", k) and not (code[k - 1].isalnum() or code[k - 1] == "_") \
                        and k + 4 < body_close and not (code[k + 4].isalnum() or code[k + 4] == "_"):
                    end = k + 4
                    while end < body_close - 1 and code[end] not in "\n;{}":
                        if code[end] == "(":
                            end = match_close(code, end)
                            continue
                        end += 1
                    for s, e in split_top_level(code, k + 4, end):
                        item = no_comments[s:e].strip()
                        cm = re.match(r"`?(\w+)`?\s*(\((.*)\))?\s*(?:=\s*\"((?:[^\"\\]|\\.)*)\")?\s*$", item, re.S)
                        if not cm:
                            continue
                        if cm.group(2):
                            types = []
                            ps, pe = s + no_comments[s:e].index("(") + 1, s + no_comments[s:e].rindex(")")
                            for ts, te in split_top_level(code, ps, pe):
                                t = no_comments[ts:te].strip()
                                types.append(t.split(":", 1)[1].strip() if ":" in t else t)
                            payloads[cm.group(1)] = types
                        raws.append(cm.group(4) if cm.group(4) is not None else cm.group(1))
                    k = end
                    continue
                k += 1
            if string_raw:
                self.raw_values[name] = raws
            self.case_payloads[name] = payloads


INTEGER_TYPES = {"Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64"}
FLOAT_TYPES = {"Double", "Float", "CGFloat"}
OBJECT_TYPES = {"String", "Substring", "NSString"}


def _kind_of_type(swift_type: str) -> str | None:
    t = swift_type.strip()
    if t in INTEGER_TYPES:
        return "integer"
    if t in FLOAT_TYPES:
        return "float"
    if t in OBJECT_TYPES:
        return "object"
    return None


class _Function:
    def __init__(self, body_open: int, body_close: int, params: dict[str, str]) -> None:
        self.body_open, self.body_close, self.params = body_open, body_close, params


def _functions(no_comments: str, code: str) -> list[_Function]:
    found = []
    for m in re.finditer(r"\bfunc\s+`?\w+`?\s*(?:<[^>{]*>)?\s*\(", code):
        params_close = match_close(code, m.end() - 1)
        if params_close < 0:
            continue
        body_open = code.find("{", params_close)
        body_close = match_close(code, body_open) if body_open >= 0 else -1
        if body_close < 0:
            continue
        params: dict[str, str] = {}
        for s, e in split_top_level(code, m.end(), params_close - 1):
            declared = no_comments[s:e].split("=", 1)[0]
            if ":" not in declared:
                continue
            names, swift_type = declared.split(":", 1)
            if names.split():
                params[names.split()[-1].strip("`")] = swift_type.strip()
        found.append(_Function(body_open, body_close, params))
    return found


def _argument_kind(expr: str, fn: _Function | None, no_comments: str, code: str, at: int,
                   index: SwiftIndex) -> tuple[str | None, str]:
    """(kind, explanation) for one argument expression passed to tr()."""
    expr = expr.strip()
    if expr.startswith('"'):
        return "object", "a string literal"
    call = re.fullmatch(r"(?:[\w.]+\.)?(\w+)\s*\((.*)\)", expr, re.S)
    if call:
        if _kind_of_type(call.group(1)):
            return _kind_of_type(call.group(1)), f"{call.group(1)}(…)"
        types = index.returns.get(call.group(1), set())
        kinds = {_kind_of_type(t) for t in types}
        if len(kinds) == 1 and None not in kinds:
            return kinds.pop(), f"{call.group(1)}(…) returns {'/'.join(sorted(types))}"
        return None, f"cannot tell what {expr!r} returns"
    if not re.fullmatch(r"\w+", expr):
        return None, f"cannot tell the type of {expr!r}"
    if fn is None:
        return None, f"{expr!r} is not a parameter of any function"
    if expr in fn.params:
        kind = _kind_of_type(fn.params[expr])
        return kind, f"{expr}: {fn.params[expr]}"
    body = no_comments[fn.body_open:at]
    lets = list(re.finditer(r"\b(?:let|var)\s+" + re.escape(expr) + r"\b\s*(?::\s*([\w.]+))?\s*=\s*([^\n]*)", body))
    if lets:
        last = lets[-1]
        if last.group(1):
            return _kind_of_type(last.group(1)), f"{expr}: {last.group(1)}"
        return _argument_kind(last.group(2), fn, no_comments, code, fn.body_open + last.start(), index)
    # `case .name(let a0, let a1): return tr("…", a0, a1)` — the type is the
    # enum case's associated value, and the enum is the switch subject's type.
    line_start = no_comments.rfind("\n", 0, at) + 1
    bound = re.search(r"\bcase\s+\.(\w+)\s*\(([^)]*)\)", no_comments[line_start:at])
    if bound:
        names = [b.strip() for b in bound.group(2).split(",")]
        position = next((i for i, b in enumerate(names) if re.fullmatch(r"let\s+" + re.escape(expr), b)), None)
        switch = list(re.finditer(r"\bswitch\s+(\w+)", no_comments[fn.body_open:at]))
        subject_type = fn.params.get(switch[-1].group(1)) if switch else None
        payload = index.case_payloads.get(subject_type or "", {}).get(bound.group(1))
        if position is not None and payload and position < len(payload):
            return _kind_of_type(payload[position]), f"{expr}: {payload[position]} ({subject_type}.{bound.group(1)})"
    return None, f"cannot find where {expr!r} is declared"


def _tr_calls(root: Path):
    """(key literal, [argument expressions], enclosing function, offset, texts) for
    every `tr(…)` in L10n.swift, comments excluded."""
    path = root / L10N_SUBPATH
    if not path.is_file():
        return
    src = path.read_text(encoding="utf-8")
    no_comments, code = swift_masks(src)
    functions = _functions(no_comments, code)
    for m in re.finditer(r"\btr\(\s*\"", code):
        open_at = code.rfind("(", 0, m.end())
        close = match_close(code, open_at)
        if close < 0:
            continue
        spans = split_top_level(code, open_at + 1, close - 1)
        key = first_string_literal(no_comments, no_comments.index('"', spans[0][0]))
        if key is None:
            continue
        args = [no_comments[s:e].strip() for s, e in spans[1:]]
        args = [a for a in args if not re.match(r"english\s*:", a)]
        inside = [f for f in functions if f.body_open < m.start() < f.body_close]
        fn = min(inside, key=lambda f: f.body_close - f.body_open) if inside else None
        line = src.count("\n", 0, m.start()) + 1
        yield key, args, fn, m.start(), line, no_comments, code


COMPOSED_KEY = re.compile(r"^((?:[^\\]|\\[^(])*)\\\((\w+)\.rawValue\)((?:[^\\]|\\[^(])*)$")


def composed_keys(root: Path, index: SwiftIndex) -> tuple[set[str], list[str]]:
    """Keys built at runtime from an enum's raw value, expanded case by case.

    `tr("pet.form_\\(form.rawValue)")` names 71 keys, one per `PetForm` case, and
    no literal says which. So a new cat added without its `pet.form_<raw>` key
    showed "pet.form_zoomies2" in the Cattery, in its VoiceOver label and as the
    companion's default name, in all six languages, with every gate green. The
    expansion reads the enum the parameter is declared as. A composed key it
    cannot expand FAILS rather than being skipped: skipping is how this one went
    unchecked.
    """
    keys: set[str] = set()
    problems: list[str] = []
    for key, _args, fn, _at, line, _nc, _code in _tr_calls(root):
        if "\\(" not in key:
            continue
        m = COMPOSED_KEY.match(key)
        param_type = fn.params.get(m.group(2)) if (m and fn) else None
        raws = index.raw_values.get((param_type or "").strip())
        if not m or raws is None:
            problems.append(
                f"L10n.swift:{line}: tr(\"{key}\") is composed at runtime and the gate cannot expand it — "
                "only `\\(param.rawValue)` of a parameter typed as a String-backed enum declared in "
                "CLIPulseCore can be checked")
            continue
        if not raws:
            problems.append(f"L10n.swift:{line}: {param_type} has no cases to expand tr(\"{key}\") with")
            continue
        keys.update(f"{m.group(1)}{raw}{m.group(3)}" for raw in raws)
    return keys, problems


def code_argument_mismatches(root: Path, index: SwiftIndex, en: dict[str, str]) -> list[str]:
    """Arguments L10n.swift passes that the ENGLISH value does not consume.

    `format_argument_mismatches` compares every translation with English. That
    catches a translation drifting, and cannot catch English and the code
    disagreeing — because when all six catalogues change together, they still
    agree with each other. `providers.tracked_count` switched from %d to %@ in
    all six passed with "format arguments match", and would have crashed the
    Providers tab on both platforms: `String(format:)` reads the Int it is given
    as an object pointer.

    So each call's arguments are typed from the accessor's parameters (or the
    local `let`, or the enum case it was bound from) and compared with the
    specifiers in en. An argument whose type cannot be read FAILS: a check that
    quietly skips what it cannot read is how the next one gets through.
    """
    problems: list[str] = []
    for key, args, fn, at, line, no_comments, code in _tr_calls(root):
        if "\\(" in key or key not in en:
            continue
        kinds: list[str] = []
        unreadable = False
        for position, expr in enumerate(args, 1):
            kind, why = _argument_kind(expr, fn, no_comments, code, at, index)
            if kind is None:
                problems.append(f"L10n.swift:{line}: {key} argument {position} — {why}; "
                                "the gate cannot check it against English")
                unreadable = True
            kinds.append(kind or "?")
        if unreadable:
            continue
        want = sorted(set(argument_signature(en[key])))
        want = [(p, k) for p, k in want if k != "parameter"]
        got = sorted({(str(i), k) for i, k in enumerate(kinds, 1)})
        if not args:
            if want:
                problems.append(f"L10n.swift:{line}: {key} is called with no arguments, and en consumes "
                                f"{want} — the specifiers render literally")
            elif "%%" in en[key]:
                problems.append(f"L10n.swift:{line}: {key} is called with no arguments, so tr() does not "
                                "format it and en's %% renders as two percent signs")
            continue
        conflicting = sorted({p for p, _ in want if sum(1 for q, _ in want if q == p) > 1})
        if conflicting:
            problems.append(f"L10n.swift:{line}: en {key!r} reads argument(s) {conflicting} as two different types")
        elif want != got:
            problems.append(f"L10n.swift:{line}: {key} — L10n.swift passes {got}, en consumes {want or 'nothing'}")
    return problems


# ── App Intents metadata ─────────────────────────────────────────────────────

# App Intents turns a Swift literal into a LocalizedStringResource, which the
# system looks up BY ITS ENGLISH TEXT in the app's own
# `<locale>.lproj/Localizable.strings`. Every localized type is also
# ExpressibleByStringLiteral and has initialisers of its own, so one key has
# several spellings — `"…"`, `.init("…")`, `Type("…")`, `.init(stringLiteral: "…")`,
# `.init(name: "…")` — and a site that reads only the first lets the others show
# English in every language while this gate prints OK. So a value is read by its
# TYPE, whichever spelling it takes, and a literal inside a localized value that
# no reading claims fails (see `_literal_sites`).

LSR = "LocalizedStringResource"
# Each localized type's initialisers: the type of an unlabelled FIRST argument
# (None: it takes none), label → type of that argument, and labels that carry no
# key. "String" is the key itself, as `stringLiteral:` takes it; "[T]" is an array.
LOCALIZED_INITS: dict[str, tuple[str | None, dict[str, str], frozenset[str]]] = {
    LSR: ("String", {"stringLiteral": "String"},
          frozenset({"defaultValue", "table", "locale", "bundle", "comment"})),
    "IntentDescription": (LSR, {"stringLiteral": "String", "categoryName": LSR, "resultValueName": LSR,
                                "searchKeywords": f"[{LSR}]"}, frozenset()),
    "IntentDialog": (LSR, {"stringLiteral": "String", "full": LSR, "supporting": LSR}, frozenset({"image"})),
    "TypeDisplayRepresentation": (None, {"stringLiteral": "String", "name": LSR, "numericFormat": LSR},
                                  frozenset()),
    "DisplayRepresentation": (None, {"stringLiteral": "String", "title": LSR, "subtitle": LSR,
                                     "synonyms": f"[{LSR}]"}, frozenset({"image"})),
}
_TYPE_NAMES = "|".join(LOCALIZED_INITS)
# A localized initialiser at the start of a value: `.init(`, `Type(`, `Type.init(`.
LOCALIZED_INIT_CALL = re.compile(r"(?:\b(" + _TYPE_NAMES + r")(?:\.init)?|\.init)\(")
LITERAL_START = re.compile(r'#*"')
ARGUMENT_LABEL = re.compile(r"\s*(\w+)\s*:(?!:)")

# The sites, in the order they claim a value (the first names it):

# 1. A property typed as one of the localized types, initialised or computed:
#    `static var title: LocalizedStringResource = …`, and the computed `{ … }` /
#    `{ return … }` / `{ get { … } }` bodies. The site is named after the property,
#    and the whole initialiser or body is a localized value.
DECLARATION_SITE = re.compile(
    r"\b(?:var|let)\s+`?(\w+)`?\s*:\s*(" + _TYPE_NAMES + r")\??\s*"
    r"(?:=\s*|(\{)\s*(?:get\s*\{\s*)?(?:return\s+)?)")
#    …and a function returning one — `func dialog() -> IntentDialog { "…" }`, a
#    helper whose call a site cannot see into. Named after the function.
FUNCTION_SITE = re.compile(r"\bfunc\s+`?(\w+)`?\s*(?:<[^>{]*>)?\s*\(")
RETURNS_LOCALIZED = re.compile(
    r"\s*(?:async\s+)?(?:throws\s+)?->\s*(" + _TYPE_NAMES + r")\??\s*(\{)\s*(?:return\s+)?")

# 2. Calls that TAKE a localized value without being one: (site, callee ending at
#    its "(", type of an unlabelled first argument, label → type, prefix naming a
#    labelled site). Only these arguments are localized — `default:`, `phrases:`,
#    `systemImageName:` are not.
INTENT_CALLS = [
    ("parameterSummary", re.compile(r"\bSummary\("), "String", {}, ""),
    ("@Parameter", re.compile(r"@Parameter\s*\("), None,
     {"title": LSR, "description": LSR, "requestValueDialog": "IntentDialog",
      "requestDisambiguationDialog": "IntentDialog"}, "@Parameter "),
    ("AppShortcut", re.compile(r"\bAppShortcut\("), None, {"shortTitle": LSR}, ""),
    ("dialog", re.compile(r"\b(?:requestValue|needsValueError)\("), "IntentDialog", {}, ""),
    ("dialog", re.compile(r"(?:\.result|\b(?:requestDisambiguation|needsDisambiguationError|"
                          r"requestConfirmation|needsConfirmationError))\("), None, {"dialog": "IntentDialog"}, ""),
]

# 3. A localized type's own initialiser, called by name wherever it is written:
#    (type, site, prefix naming a labelled site).
TYPE_CALLS = [
    (LSR, LSR, LSR + " "),
    ("IntentDescription", "description", ""),
    ("IntentDialog", "IntentDialog", "IntentDialog "),
    ("TypeDisplayRepresentation", "typeDisplayRepresentation", "typeDisplayRepresentation "),
    ("DisplayRepresentation", "DisplayRepresentation", "DisplayRepresentation "),
]

# 4. Argument labels that take a localized value in whatever call they are
#    written — `needsDisambiguationError(among:dialog:)`, `.init(title:subtitle:)`
#    — so a call the lists above do not name is still read when its value is a
#    literal or a localized initialiser.
LABEL_TYPES = {
    "dialog": "IntentDialog", "requestValueDialog": "IntentDialog",
    "requestDisambiguationDialog": "IntentDialog", "requestConfirmationDialog": "IntentDialog",
    "categoryName": LSR, "resultValueName": LSR, "shortTitle": LSR, "subtitle": LSR,
}
INTENT_LABEL_SITE = re.compile(r"[(,]\s*(" + "|".join(LABEL_TYPES) + r")\s*:(?!:)\s*")
INTENT_ARRAY_LABEL_SITE = re.compile(r"[(,]\s*(searchKeywords|synonyms)\s*:\s*(?=\[)")

SUMMARY_PARAMETER = re.compile(r"\\\(\\\.\$(\w+)\)")

# Which files are read: any that USES App Intents, judged from its code (comments
# and strings blanked) rather than from one spelling of its import line. Matching
# `^import AppIntents` let `@preconcurrency import AppIntents` — or an intent in a
# file that gets the module some other way — take a file, or every file, out of
# the scan, and the gate then reported a match it had never looked for.
APP_INTENTS_USE = re.compile(
    r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?AppIntents\b"
    r"|\b(?:AppIntent|AppShortcutsProvider|AppShortcut|AppEnum|AppEntity|EntityQuery|IntentResult|"
    r"IntentDescription|IntentDialog|LocalizedStringResource|TypeDisplayRepresentation|"
    r"DisplayRepresentation|ParameterSummary)\b|@Parameter\b")

# What a conforming type must declare, and this gate must therefore READ. A type
# whose required string it cannot read fails, so a form the lists above do not
# know — `{ .init("…") }`, a raw string — is a failure to teach the gate, never an
# intent quietly left out of the check.
REQUIRED_MEMBERS = [
    (re.compile(r"^\w*Intent$"), "title"),
    (re.compile(r"^(?:AppEnum|AppEntity|TransientAppEntity|IndexedEntity|UniqueAppEntity|FileEntity)$"),
     "typeDisplayRepresentation"),
]
TYPE_DECLARATION = re.compile(r"\b(struct|enum|class|actor|extension)\s+`?([A-Za-z_][\w.]*)`?([^{;]*)\{")
# `class func`, `class override var` … are members, not types.
NOT_TYPE_NAMES = {"var", "let", "func", "subscript", "init", "deinit", "static", "override", "final",
                  "private", "fileprivate", "internal", "public", "open", "required", "convenience",
                  "dynamic", "nonisolated", "lazy", "mutating"}


def _depth_zero(code: str, a: int, b: int) -> list[bool]:
    """For each offset in code[a:b], whether it sits at bracket depth zero."""
    flags, depth = [], 0
    for k in range(a, b):
        c = code[k]
        if c in ")]}":
            depth -= 1
        flags.append(depth == 0)
        if c in "([{":
            depth += 1
    return flags


def _type_declarations(code: str):
    """(keyword, type name, inherited names, header offset, body open, body close)."""
    out = []
    for m in TYPE_DECLARATION.finditer(code):
        name = m.group(2).split(".")[-1]
        if name in NOT_TYPE_NAMES:
            continue
        close = match_close(code, m.end() - 1)
        if close < 0:
            continue
        header = re.sub(r"<[^<>]*>", "", m.group(3))
        header = re.split(r"\bwhere\b", header)[0]
        inherited = []
        if header.strip().startswith(":"):
            for part in re.split(r"[,&]", header.strip()[1:]):
                part = part.strip().split(".")[-1].strip()
                if re.fullmatch(r"\w+", part):
                    inherited.append(part)
        out.append((m.group(1), name, inherited, m.start(), m.end() - 1, close))
    return out


def _statement_end(code: str, a: int) -> int:
    """Offset of the newline or `;` that ends the expression starting at code[a],
    or of the bracket that encloses it."""
    depth = 0
    for k in range(a, len(code)):
        c = code[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return k
            depth -= 1
        elif depth == 0 and c in "\n;":
            return k
    return len(code)


def _literal_sites(code: str, spans: list[tuple[int, int]]) -> tuple[dict[int, str], dict[int, str]]:
    """(opening quote or `#` of every localized literal → site name,
        opening of every literal inside a localized value that no site reads → site name).

    `spans` is every string literal in the file, as `swift_masks` records them.

    The second map is the backstop. A localized value is a declaration's
    initialiser or body, a localized argument of an INTENT_CALLS call, or the
    argument list of a localized initialiser; any literal in one that is not a key
    read here — `cond ? "A" : "B"`, a label this gate does not list, a helper call
    — is a string the system may look up and no language checks. Arguments that
    carry no key (`comment:`, `image:` …) are left out; a runtime value, having no
    literal, never trips it."""
    sites: dict[int, str] = {}
    values: list[tuple[int, int, str]] = []
    no_key: list[tuple[int, int]] = []

    def read(a: int, b: int, kind: str, name: str) -> None:
        """Claim what the value in code[a:b], of type `kind`, yields — as `name`."""
        while a < b and code[a].isspace():
            a += 1
        if a >= b:
            return
        if LITERAL_START.match(code, a, b):
            sites.setdefault(a, name)
        elif kind.startswith("["):
            close = match_close(code, a) if code[a] == "[" else -1
            if 0 <= close <= b:
                values.append((a + 1, close - 1, name))
                for s, e in split_top_level(code, a + 1, close - 1):
                    read(s, e, kind[1:-1], name)
        else:
            m = LOCALIZED_INIT_CALL.match(code, a, b)
            type_ = (m.group(1) or (kind if kind in LOCALIZED_INITS else None)) if m else None
            close = match_close(code, m.end() - 1) if type_ else -1
            if 0 <= close <= b:
                read_init(type_, m.end(), close - 1, name, name + " ")

    def read_init(type_: str, a: int, b: int, name: str, prefix: str) -> None:
        """The arguments code[a:b] of `type_`'s initialiser."""
        positional, labels, no_key_labels = LOCALIZED_INITS[type_]
        values.append((a, b, name))
        for n, (s, e) in enumerate(split_top_level(code, a, b)):
            lab = ARGUMENT_LABEL.match(code, s, e)
            if lab is None:
                if n == 0 and positional:
                    read(s, e, positional, name)
            elif lab.group(1) in no_key_labels:
                no_key.append((s, e))
            elif lab.group(1) in labels:
                kind = labels[lab.group(1)]
                sub = name if kind == "String" else prefix + lab.group(1)
                values.append((lab.end(), e, sub))
                read(lab.end(), e, kind, sub)

    for m in DECLARATION_SITE.finditer(code):
        if m.group(3):
            close = match_close(code, m.start(3))
            if close < 0:
                continue
            a, b = m.start(3) + 1, close - 1
        else:
            a, b = m.end(), _statement_end(code, m.end())
        values.append((a, b, m.group(1)))
        read(m.end(), b, m.group(2), m.group(1))
    for m in FUNCTION_SITE.finditer(code):
        params = match_close(code, m.end() - 1)
        r = RETURNS_LOCALIZED.match(code, params) if params >= 0 else None
        close = match_close(code, r.start(2)) if r else -1
        if close >= 0:
            values.append((r.start(2) + 1, close - 1, m.group(1)))
            read(r.end(), close - 1, r.group(1), m.group(1))
    for site, rx, positional, labels, prefix in INTENT_CALLS:
        for m in rx.finditer(code):
            close = match_close(code, m.end() - 1)
            if close < 0:
                continue
            for n, (s, e) in enumerate(split_top_level(code, m.end(), close - 1)):
                lab = ARGUMENT_LABEL.match(code, s, e)
                if lab is None:
                    if n == 0 and positional:
                        values.append((s, e, site))
                        read(s, e, positional, site)
                elif lab.group(1) in labels:
                    values.append((lab.end(), e, prefix + lab.group(1)))
                    read(lab.end(), e, labels[lab.group(1)], prefix + lab.group(1))
    for type_, site, prefix in TYPE_CALLS:
        for m in re.finditer(r"\b" + type_ + r"(?:\.init)?\(", code):
            close = match_close(code, m.end() - 1)
            if close >= 0:
                read_init(type_, m.end(), close - 1, site, prefix)
    for m in INTENT_LABEL_SITE.finditer(code):
        read(m.end(), len(code), LABEL_TYPES[m.group(1)], m.group(1))
    for m in INTENT_ARRAY_LABEL_SITE.finditer(code):
        close = match_close(code, m.end())
        if close >= 0:
            values.append((m.end() + 1, close - 1, m.group(1)))
            read(m.end(), close, f"[{LSR}]", m.group(1))

    # A literal inside another's interpolation is reported through the outer one.
    nested: set[int] = set()
    open_ends: list[int] = []
    for s, e in sorted(spans):
        while open_ends and open_ends[-1] <= s:
            open_ends.pop()
        if open_ends:
            nested.add(s)
        open_ends.append(e)
    unread: dict[int, str] = {}
    for a, b, name in sorted(values, key=lambda v: v[1] - v[0]):   # the innermost value names it
        for s, _ in spans:
            if a <= s < b and s not in sites and s not in nested and not any(x <= s < y for x, y in no_key):
                unread.setdefault(s, name)
    return sites, unread


class _IntentFile:
    """One Swift file's App Intents strings, and the types it declares."""

    def __init__(self, rel: str, src: str) -> None:
        self.rel = rel
        self.src = src
        spans: list[tuple[int, int]] = []
        no_comments, code = swift_masks(src, spans)
        self.types = _type_declarations(code)

        # Exempt, but still counted as producing its key:
        #   * a case's NAME in `caseDisplayRepresentations` — the provider names
        #     (Claude, Codex…) are proper nouns, and a missing key falls back to
        #     the literal, which is right. A case's subtitle or synonyms are
        #     ordinary words and are checked;
        #   * everything in a type declaring `isDiscoverable = false` — the
        #     system never lists it.
        case_names: list[tuple[int, int]] = []
        for m in re.finditer(r"\bcaseDisplayRepresentations\b[^=\n]*=\s*\[", code):
            close = match_close(code, m.end() - 1)
            if close >= 0:
                case_names.append((m.start(), close))
        exempt: list[tuple[int, int]] = []
        self.hidden: set[str] = set()
        for _, name, _, header, body_open, close in self.types:
            body = code[body_open + 1:close - 1]
            for d in re.finditer(r"\bstatic\s+(?:var|let)\s+isDiscoverable\s*(?::\s*Bool\s*)?=\s*false\b", body):
                prefix = body[:d.start()]
                if prefix.count("{") == prefix.count("}"):
                    exempt.append((header, close))
                    self.hidden.add(name)

        def is_exempt(at: int, site: str) -> bool:
            return any(a <= at < b for a, b in exempt) or (
                site.split()[-1] == "title" and any(a <= at < b for a, b in case_names))

        sites, unread = _literal_sites(code, spans)
        # (site, key or None when unreadable, line, exempt, offset)
        self.literals: list[tuple[str, str | None, int, bool, int]] = []
        for at, site in sorted(sites.items()):
            literal = None
            if no_comments[at] == '"' and not no_comments.startswith('"""', at):
                literal = first_string_literal(no_comments, at)
            if literal is not None and site == "parameterSummary":
                literal = SUMMARY_PARAMETER.sub(r"${\1}", literal)
            self.literals.append((site, literal, self.line(at), is_exempt(at, site), at))
        # (site, the literal as written, line, exempt) for literals inside a
        # localized value that no site reads.
        ends = dict(spans)
        self.unread: list[tuple[str, str, int, bool]] = [
            (site, src[at:ends[at]], self.line(at), is_exempt(at, site)) for at, site in sorted(unread.items())]

        # Where each type declares the members REQUIRED_MEMBERS asks for:
        # type name → member → [(start, end)] spans, each running from the
        # declaration to the next member of the same body.
        self.members: dict[str, dict[str, list[tuple[int, int]]]] = {}
        boundary = re.compile(r"@\w+|\b(?:var|let|func|init|deinit|subscript|case|struct|enum|class|actor|"
                              r"typealias|associatedtype|static|private|public|internal|fileprivate|package|"
                              r"nonisolated|mutating|override|final|lazy|open)\b")
        wanted = {member for _, member in REQUIRED_MEMBERS}
        for _, name, _, _, body_open, close in self.types:
            a, b = body_open + 1, close - 1
            flat = _depth_zero(code, a, b)
            starts = [a + m.start() for m in boundary.finditer(code[a:b]) if flat[m.start()]]
            for m in re.finditer(r"\b(?:var|let)\s+`?(\w+)`?\b", code[a:b]):
                if m.group(1) not in wanted or not flat[m.start()]:
                    continue
                begin = a + m.end()
                end = next((s for s in starts if s >= begin), b)
                self.members.setdefault(name, {}).setdefault(m.group(1), []).append((a + m.start(), end))

    def line(self, at: int) -> int:
        return self.src.count("\n", 0, at) + 1


def intent_metadata_problems(root: Path, stats: dict | None = None) -> list[str]:
    """App Intent names, descriptions, parameters, dialogs and short titles with no
    entry in the app's own Localizable.strings — and entries no intent asks for.

    Only Shortcut phrases were tied to Swift. Renaming GetStatusIntent's title to
    "Get CLI Pulse Summary", rewording its Summary, adding a parameter
    description or changing a shortTitle all passed every gate, and each one
    shows English in Shortcuts and Spotlight on every non-English iPhone while
    the old translation becomes dead text.

    A check that reads nothing must not report a match, so three things fail
    instead of passing quietly: an app whose table declares keys while no
    literal was read from it; an intent (or AppEnum/AppEntity) whose title (or
    type name) the gate cannot read; and a literal it found but cannot parse.

    `stats`, when given, receives app → (literals checked, exempt, files read).
    """
    problems: list[str] = []
    app_root = root / APP_ROOT_SUBPATH
    if not app_root.is_dir():
        return problems
    for app_dir in sorted(d for d in app_root.iterdir() if d.is_dir() and d.name != "CLIPulseCore"):
        files: list[_IntentFile] = []
        for swift in sorted(app_dir.rglob("*.swift")):
            src = swift.read_text(encoding="utf-8", errors="replace")
            if not APP_INTENTS_USE.search(src):
                continue
            if not APP_INTENTS_USE.search(swift_masks(src)[1]):
                continue
            files.append(_IntentFile(str(swift.relative_to(app_root)), src))

        table = app_dir / f"{BASE_LOCALE}.lproj" / STRINGS_FILE
        declared = set(_strings_keys_values(table)) if table.is_file() else set()
        literals = [(f, *lit) for f in files for lit in f.literals]
        if stats is not None and literals:
            exempted = sum(1 for lit in literals if lit[4])
            stats[app_dir.name] = (len(literals) - exempted, exempted, len(files))
        if declared and not literals:
            # Reported once, in place of one orphan per key: the fault is the
            # scan, not the keys.
            problems.append(
                f"{app_dir.name}/{BASE_LOCALE}.lproj/{STRINGS_FILE} declares {len(declared)} key(s), but no "
                f"App Intents literal was read from any Swift file in {app_dir.name} ({len(files)} file(s) "
                "use App Intents). Nothing was compared: either the intents are gone and the table is dead, "
                "or they are written in a form this gate does not read")
        if literals and not table.is_file():
            problems.append(f"{app_dir.name}: has App Intents but no {BASE_LOCALE}.lproj/{STRINGS_FILE}")

        for f, site, key, line, exempt, _ in literals:
            if exempt:
                continue
            if key is None:
                problems.append(f"{f.rel}:{line}: {site} is a literal this gate cannot read (raw, multi-line or "
                                "unterminated), so its table entry is unchecked — write it as a plain \"…\"")
            elif "\\(" in key:
                problems.append(f"{f.rel}:{line}: {site} {key!r} interpolates something other than a "
                                "parameter, so its table key cannot be derived")
            elif key not in declared:
                problems.append(f"{f.rel}:{line}: {site} {key!r} has no entry in "
                                f"{app_dir.name}/{BASE_LOCALE}.lproj/{STRINGS_FILE}, so it shows English "
                                "in every language")
        for f in files:
            for site, text, line, exempt in f.unread:
                if exempt:
                    continue
                shown = text if len(text) <= 60 else text[:57] + "..."
                problems.append(f"{f.rel}:{line}: {site} holds the literal {shown} in a form this gate does not "
                                "read as a key, so whatever the system looks up there is checked in no "
                                "language — write it as \"…\", .init(\"…\") or an argument label the gate "
                                "lists, or teach the gate this form")

        # Every conforming type's required string is one the gate read.
        spans: dict[str, dict[str, list[tuple[_IntentFile, int, int]]]] = {}
        hidden: set[str] = set()
        for f in files:
            hidden |= f.hidden
            for name, members in f.members.items():
                for member, ranges in members.items():
                    spans.setdefault(name, {}).setdefault(member, []).extend((f, a, b) for a, b in ranges)
        reported: set[tuple[str, str]] = set()
        for f in files:
            for _, name, inherited, header, _, _ in f.types:
                if name in hidden:
                    continue
                for proto in inherited:
                    for rx, member in REQUIRED_MEMBERS:
                        if not rx.match(proto) or (name, member) in reported:
                            continue
                        read = any(g is lf and a <= at < b
                                   for g, a, b in spans.get(name, {}).get(member, [])
                                   for lf, *_, at in literals)
                        if not read:
                            reported.add((name, member))
                            problems.append(
                                f"{f.rel}:{f.line(header)}: {name} conforms to {proto}, but this gate reads no "
                                f"{member} literal for it, so that name is checked in no language — declare "
                                f"`static var {member}: … = \"…\"`, or teach the gate the form used")
        produced = {key for _, _, key, _, _, _ in literals if key is not None}
        for key in sorted(declared - produced) if literals else []:
            problems.append(f"{app_dir.name}/{BASE_LOCALE}.lproj/{STRINGS_FILE}: {key!r} is not written by any "
                            "App Intents literal any more — dead text, or a renamed literal whose "
                            "translations it orphaned")
    return problems


# ── What the app bundles declare and copy ────────────────────────────────────

# The targets that render CLIPulseCore's L10n. The macOS app, the Watch app and
# the widgets ship no .lproj of their own, so CFBundleLocalizations is the ONLY
# place they declare their languages — and the resource bundle's localization
# choice is constrained by what the main bundle declares.
HOST_INFO_PLISTS = [
    "CLI Pulse Bar/Info.plist",
    "CLI Pulse Bar iOS/Info.plist",
    "CLI Pulse Bar Watch/Info.plist",
    "CLI Pulse Widgets/Info.plist",
]


def host_localization_problems(root: Path) -> list[str]:
    """Every host Info.plist declares exactly the shipped locales.

    Nothing read CFBundleLocalizations. Deleting `<string>ko</string>` from the
    macOS Info.plist passed every gate and `swift test` (which runs in the
    xctest host), and a Korean Mac would get the English menu bar app.
    """
    import plistlib
    problems: list[str] = []
    app_root = root / APP_ROOT_SUBPATH
    declared_hosts = {app_root / rel for rel in HOST_INFO_PLISTS}
    others = sorted(set(app_root.glob("*/Info.plist")) - declared_hosts) if app_root.is_dir() else []
    for info in sorted(declared_hosts) + others:
        rel = info.relative_to(app_root)
        if not info.is_file():
            problems.append(f"{rel} is missing")
            continue
        try:
            plist = plistlib.loads(info.read_bytes())
        except Exception as exc:  # noqa: BLE001 — any parse failure is the finding
            problems.append(f"{rel} does not parse: {exc}")
            continue
        value = plist.get("CFBundleLocalizations")
        if value is None:
            if info in declared_hosts:
                problems.append(f"{rel} declares no CFBundleLocalizations")
            continue
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            problems.append(f"{rel}: CFBundleLocalizations is not a list of strings")
            continue
        for loc in sorted(set(SHIPPED_LOCALES) - set(value)):
            problems.append(f"{rel}: CFBundleLocalizations lacks {loc}")
        for loc in sorted(set(value) - set(SHIPPED_LOCALES)):
            problems.append(f"{rel}: CFBundleLocalizations declares {loc}, which is not a shipped locale")
        for loc in sorted(v for v, n in collections.Counter(value).items() if n > 1):
            problems.append(f"{rel}: CFBundleLocalizations lists {loc} twice")
    return problems


PBXPROJ_SUBPATH = Path("CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj")


def parse_openstep_plist(text: str):
    """An old-style (OpenStep) property list, as Xcode writes project.pbxproj."""
    i, n = 0, len(text)
    token = re.compile(r"(?:[^\s;,={}()\"/]|/(?![/*]))+")
    escapes = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}

    def skip() -> None:
        nonlocal i
        while i < n:
            if text[i].isspace():
                i += 1
            elif text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j
            elif text.startswith("/*", i):
                j = text.find("*/", i + 2)
                if j < 0:
                    raise ValueError("unterminated comment")
                i = j + 2
            else:
                return

    def expect(ch: str) -> None:
        nonlocal i
        skip()
        if i >= n or text[i] != ch:
            raise ValueError(f"expected {ch!r} at offset {i}, found {text[i:i + 20]!r}")
        i += 1

    def value():
        nonlocal i
        skip()
        if i >= n:
            raise ValueError("unexpected end of file")
        c = text[i]
        if c == "{":
            i += 1
            out = {}
            while True:
                skip()
                if i < n and text[i] == "}":
                    i += 1
                    return out
                k = value()
                expect("=")
                v = value()
                expect(";")
                out[k] = v
        if c == "(":
            i += 1
            out = []
            while True:
                skip()
                if i < n and text[i] == ")":
                    i += 1
                    return out
                out.append(value())
                skip()
                if i < n and text[i] == ",":
                    i += 1
                elif i < n and text[i] != ")":
                    raise ValueError(f"expected ',' or ')' at offset {i}")
        if c == '"':
            i += 1
            chars = []
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    chars.append(escapes.get(text[i + 1], text[i + 1]))
                    i += 2
                else:
                    chars.append(text[i])
                    i += 1
            if i >= n:
                raise ValueError("unterminated string")
            i += 1
            return "".join(chars)
        m = token.match(text, i)
        if not m or not m.group(0):
            raise ValueError(f"unexpected {text[i:i + 20]!r} at offset {i}")
        i = m.end()
        return m.group(0)

    result = value()
    skip()
    if i != n:
        raise ValueError(f"trailing content at offset {i}")
    return result


def variant_group_problems(root: Path) -> list[str]:
    """App-bundle tables that are on disk but that Xcode does not copy.

    A table reaches the app only as a child of its PBXVariantGroup, and only if
    that group is in the owning target's Resources phase. project.pbxproj is
    edited by hand here. Removing `B20115 /* ko */,` from the AppShortcuts group
    leaves the file on disk, so every file-based check passes, and `xcodebuild`
    succeeds — the app just ships without ko.lproj/AppShortcuts.strings, and
    Korean Siri phrases stop working with no error anywhere.
    """
    problems: list[str] = []
    on_disk: dict[str, dict[str, set[str]]] = collections.defaultdict(lambda: collections.defaultdict(set))
    for path in app_bundle_tables(root):
        on_disk[path.parent.parent.name][path.name].add(path.parent.name.removesuffix(".lproj"))
    if not on_disk:
        return problems
    project = root / PBXPROJ_SUBPATH
    if not project.is_file():
        return [f"{PBXPROJ_SUBPATH} is missing, so nothing proves the app-bundle tables are copied"]
    try:
        objects = parse_openstep_plist(project.read_text(encoding="utf-8"))["objects"]
    except (ValueError, KeyError, TypeError) as exc:
        return [f"{PBXPROJ_SUBPATH} does not parse: {exc}"]

    def obj(oid) -> dict:
        found = objects.get(oid, {}) if isinstance(oid, str) else {}
        return found if isinstance(found, dict) else {}

    owners: dict[str, set[str]] = collections.defaultdict(set)
    for tid, target in objects.items():
        if not isinstance(target, dict) or target.get("isa") != "PBXNativeTarget":
            continue
        for cid in obj(target.get("buildConfigurationList")).get("buildConfigurations", []):
            info = obj(cid).get("buildSettings", {}).get("INFOPLIST_FILE", "")
            if "/" in info:
                owners[info.split("/", 1)[0]].add(tid)

    for app, tables in sorted(on_disk.items()):
        groups = [o for o in objects.values() if isinstance(o, dict) and o.get("isa") == "PBXGroup"
                  and (o.get("path") or o.get("name")) == app]
        if not groups:
            problems.append(f"{app}: the Xcode project has no group for this folder, so none of its tables are copied")
            continue
        children = [c for g in groups for c in g.get("children", [])]
        for table, locales in sorted(tables.items()):
            variant = [c for c in children if obj(c).get("isa") == "PBXVariantGroup" and obj(c).get("name") == table]
            if len(variant) != 1:
                problems.append(f"{app}: {table} is on disk ({', '.join(sorted(locales))}) but "
                                f"{'is not a variant group' if not variant else 'is in several variant groups'} "
                                "in the Xcode project")
                continue
            vid = variant[0]
            paths = collections.Counter(obj(c).get("path") for c in obj(vid).get("children", []))
            for loc in SHIPPED_LOCALES:
                want = f"{loc}.lproj/{table}"
                if paths[want] == 0:
                    problems.append(f"{app}: {want} is not a child of the {table} variant group, so Xcode "
                                    "never copies it into the app")
                elif paths[want] > 1:
                    problems.append(f"{app}: {want} is a child of the {table} variant group {paths[want]} times")
            if not owners.get(app):
                problems.append(f"{app}: no target builds from {app}/Info.plist, so nothing copies {table}")
            for tid in sorted(owners.get(app, ())):
                phases = [obj(p) for p in obj(tid).get("buildPhases", [])]
                copied = any(obj(bf).get("fileRef") == vid
                             for p in phases if p.get("isa") == "PBXResourcesBuildPhase"
                             for bf in p.get("files", []))
                if not copied:
                    problems.append(f"{app}: target {obj(tid).get('name', tid)!r} does not copy {table} — the "
                                    "variant group is not in its Resources build phase")
    return problems


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
                    help="rewrite the baseline to the tree's current state (may only shrink)")
    ap.add_argument("--allow-growth", action="store_true",
                    help="permit --update-baseline to INCREASE the debt; a deliberate, reviewable act")
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent.parent
    res_dir = root / RES_SUBPATH
    baseline_path = root / BASELINE_SUBPATH

    if not res_dir.is_dir():
        print(f"FATAL: no .lproj resources at {res_dir}", file=sys.stderr)
        return 2

    broken = unparseable(root)
    if broken:
        print("FAIL — a .strings file does not parse. CFBundle drops the ENTIRE", file=sys.stderr)
        print("       catalogue, so every key in that locale renders as its raw", file=sys.stderr)
        print("       dotted identifier — not just the broken line:\n", file=sys.stderr)
        for line in broken:
            print(f"    {line}", file=sys.stderr)
        print("\n    Usually an unescaped \" inside a value. Use \\\" or a typographic", file=sys.stderr)
        print("    quote, then re-run.\n", file=sys.stderr)
        return 1

    mangled = replacement_characters(root)
    if mangled:
        print("FAIL — U+FFFD replacement character in a catalogue. It parses, so nothing", file=sys.stderr)
        print("       else notices, but users see a black diamond where a letter was:\n", file=sys.stderr)
        for line in mangled:
            print(f"    {line}", file=sys.stderr)
        print("\n    Retype the word from the source text.\n", file=sys.stderr)
        return 1

    catalogues = collect(res_dir)
    if BASE_LOCALE not in catalogues:
        print(f"FATAL: {BASE_LOCALE}.lproj/{STRINGS_FILE} missing under {res_dir}", file=sys.stderr)
        return 2
    if len(catalogues) < 2:
        print(f"FATAL: only found {sorted(catalogues)} — nothing to compare", file=sys.stderr)
        return 2

    absent = [loc for loc in SHIPPED_LOCALES if loc not in catalogues]
    if absent:
        print("FATAL: shipped locale(s) missing from the resource bundle:\n", file=sys.stderr)
        for loc in absent:
            print(f"    {loc}.lproj", file=sys.stderr)
        print("\n    Both Info.plists declare these, so Apple routes users into them.\n"
              "    A locale that disappears is a regression, not a smaller job — and\n"
              "    discovering locales by glob is exactly how that goes unnoticed.\n",
              file=sys.stderr)
        return 2

    missing, orphans, duplicates = compute(catalogues)

    if args.update_baseline:
        # The baseline is a RATCHET. Regenerating it must not be a way to
        # launder new untranslated UI into "known debt" — that is the whole
        # difference between a ratchet and a rubber stamp. (Codex review,
        # 2026-08-30: `--update-baseline` used to accept any growth.)
        previous_total = 0
        if baseline_path.is_file():
            try:
                prev = json.loads(baseline_path.read_text(encoding="utf-8")).get("missing", {})
                previous_total = sum(len(v) for v in prev.values())
            except json.JSONDecodeError:
                previous_total = 0
        new_total = sum(len(v) for v in missing.values())
        if new_total > previous_total and not args.allow_growth:
            print(f"REFUSED — the baseline may only shrink: {previous_total} -> {new_total}.\n",
                  file=sys.stderr)
            print("    Translate the new keys instead. If a locale genuinely has to take\n"
                  "    on debt, say so explicitly with --allow-growth so it appears in the\n"
                  "    diff as a decision rather than as a regenerated file.\n",
                  file=sys.stderr)
            return 1
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
        print(f"baseline rewritten: {new_total} untranslated key(s) across "
              f"{len(missing)} locale(s) (was {previous_total})")
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
    duplicates += app_bundle_duplicates(root)

    if duplicates:
        failed = True
        print("FAIL — a key is declared twice; .strings keeps only the last, so the", file=sys.stderr)
        print("       earlier translation is dead text that reads as done:\n", file=sys.stderr)
        for line in duplicates:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    index = SwiftIndex(root)
    expanded, unexpandable = composed_keys(root, index)
    if unexpandable:
        failed = True
        print("FAIL — L10n.swift composes a key at runtime that this gate cannot expand, so", file=sys.stderr)
        print("       nothing proves any of the keys it builds exist:\n", file=sys.stderr)
        for line in unexpandable:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    undeclared = sorted((keys_the_code_asks_for(root) | expanded) - set(catalogues[BASE_LOCALE]))
    if undeclared:
        failed = True
        print("FAIL — L10n.swift asks for key(s) that are in NO catalogue, not even", file=sys.stderr)
        print(f"       {BASE_LOCALE}.lproj. Nothing else catches this: the parity check below", file=sys.stderr)
        print("       compares catalogues to each other, and a key missing from all of", file=sys.stderr)
        print("       them has no locale to disagree with. NSLocalizedString echoes the", file=sys.stderr)
        print("       key, so every user reads the raw dotted identifier off the screen:\n", file=sys.stderr)
        for key in undeclared:
            print(f"    {key}", file=sys.stderr)
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

    prompts = unlocalized_permission_prompts(root)
    if prompts:
        failed = True
        print("FAIL — a permission prompt is not localized. iOS shows these inside its own", file=sys.stderr)
        print("       system alert and reads them from <locale>.lproj/InfoPlist.strings, not", file=sys.stderr)
        print("       from any Localizable.strings, so a missing entry renders English:\n", file=sys.stderr)
        for line in prompts:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    tables = app_bundle_table_problems(root)
    if tables:
        failed = True
        print("FAIL — an app-bundle string table (App Intents / Shortcuts) is inconsistent.", file=sys.stderr)
        print("       The system reads these from the app bundle, not from CLIPulseCore:\n", file=sys.stderr)
        for line in tables:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    mismatched = format_argument_mismatches(root)
    if mismatched:
        failed = True
        print("FAIL — a translation consumes different format arguments from English.", file=sys.stderr)
        print("       String(format:) reads arguments by the specifiers it finds: a %d that", file=sys.stderr)
        print("       became %@ crashes, and a dropped %@ shifts every later argument.", file=sys.stderr)
        print("       Only that language is affected, so English testing never sees it:\n", file=sys.stderr)
        for line in mismatched:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    en_values = _strings_keys_values(res_dir / f"{BASE_LOCALE}.lproj" / STRINGS_FILE)
    passed = code_argument_mismatches(root, index, en_values)
    if passed:
        failed = True
        print("FAIL — L10n.swift passes arguments that the English value does not consume.", file=sys.stderr)
        print("       The check above compares translations with English, so a specifier", file=sys.stderr)
        print("       changed in ALL six catalogues at once still matches. String(format:)", file=sys.stderr)
        print("       reads an Int passed to %@ as an object pointer and crashes in every", file=sys.stderr)
        print("       language:\n", file=sys.stderr)
        for line in passed:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    intent_stats: dict[str, tuple[int, int, int]] = {}
    intents = intent_metadata_problems(root, intent_stats)
    if intents:
        failed = True
        print("FAIL — an App Intents string does not match the app's Localizable.strings,", file=sys.stderr)
        print("       or this gate could not read one it has to. The system looks titles,", file=sys.stderr)
        print("       descriptions, parameters, dialogs and short titles up by their exact", file=sys.stderr)
        print("       English text, so a renamed literal shows English in Shortcuts, Siri", file=sys.stderr)
        print("       and Spotlight in every other language:\n", file=sys.stderr)
        for line in intents:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    hosts = host_localization_problems(root)
    if hosts:
        failed = True
        print("FAIL — an app's Info.plist does not declare exactly the shipped locales.", file=sys.stderr)
        print("       The macOS app, the Watch app and the widgets ship no .lproj of their", file=sys.stderr)
        print("       own; CFBundleLocalizations is how they tell the system which of", file=sys.stderr)
        print("       CLIPulseCore's languages they speak. A locale missing here gets English:\n", file=sys.stderr)
        for line in hosts:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    uncopied = variant_group_problems(root)
    if uncopied:
        failed = True
        print("FAIL — an app-bundle string table is on disk but Xcode does not copy it.", file=sys.stderr)
        print("       xcodebuild succeeds and every file check passes; the app just ships", file=sys.stderr)
        print("       without that language's table:\n", file=sys.stderr)
        for line in uncopied:
            print(f"    {line}", file=sys.stderr)
        print("", file=sys.stderr)

    if failed:
        return 1

    debt = sum(len(v) for v in missing.values())
    locales = ", ".join(f"{loc} {len(catalogues[loc])}" for loc in sorted(catalogues))
    print(f"OK — {len(catalogues)} locales (all {len(SHIPPED_LOCALES)} shipped ones present), "
          "no new drift, no orphans, no duplicates, format arguments match.")
    print(f"     code: {len(keys_the_code_asks_for(root)) + len(expanded)} key(s) asked for "
          f"({len(expanded)} expanded from composed keys), every tr() argument agrees with en; "
          f"app bundles: {len(app_bundle_tables(root))} table(s) parse and are copied, "
          f"CFBundleLocalizations match.")
    # The counts are part of the claim: "match" over zero literals read is what
    # this line used to print when the scan found nothing.
    read = "; ".join(f"{app}: {n} literal(s) read from {files} file(s) are keys in its "
                     f"{BASE_LOCALE}.lproj/{STRINGS_FILE} ({x} exempt: hidden intents, case names)"
                     for app, (n, x, files) in sorted(intent_stats.items()))
    print(f"     App Intents — {read or 'no app declares any'}.")
    print(f"     key counts: {locales}")
    if debt:
        per_locale = ", ".join(f"{loc} {len(keys)}" for loc, keys in sorted(missing.items()))
        print(f"     known untranslated debt: {debt} key(s) ({per_locale}) — these render as English.")
    else:
        print("     translation debt is zero.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

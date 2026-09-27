#!/usr/bin/env python3
"""The App Store listing texts: where they live, how they load, what makes them valid.

One module, imported by everything that reads or pushes the listing, so the
layout is written down exactly once:

  - scripts/asc_push_listing.py          pushes the texts to App Store Connect
  - scripts/asc_listing_preflight.py     validates them (CI) and compares them
                                          with the live store (release time)
  - scripts/asc_submit.py                sets What's New (see WHAT'S NEW below)
  - CLI Pulse Bar/scripts/appstore_metadata.py, resubmit.py   the older pushers

LAYOUT
------
    CLI Pulse Bar/appstore/<source>/description.txt        <= 4000 characters
    CLI Pulse Bar/appstore/<source>/keywords.txt           <= 100, comma-separated
    CLI Pulse Bar/appstore/<source>/promotional_text.txt   <= 170
    CLI Pulse Bar/appstore/<source>/subtitle.txt           <= 30

`<source>` is a directory named in LOCALE_SOURCES below, which maps each App
Store Connect locale to the directory holding its text. Six directories feed
seven ASC locales: es-ES and es-MX share `es/` (see the note on the mapping).

description.txt and promotional_text.txt may be overridden for one platform by
a sibling `description.ios.txt` / `description.macos.txt` (same for the
promotional text). None exists today: the iOS and macOS listings carry the same
text, written so that every claim is true on both (it says what happens on the
Mac and what happens on iPhone, iPad and Apple Watch). Add an override only when
a sentence would be false on one platform, such as a promotional text that
tells people to add a Home Screen widget (the Mac app has none).

A feature that only the direct-download (Developer ID) Mac build has, such as
Remote Control or fan control, is not advertised in any App Store listing,
override or not. The App Store Mac build cannot do it, and an iPhone listing
that sells it would depend on software sold outside the App Store.

Keywords and the subtitle have no per-platform form: the subtitle belongs to the
app record (appInfoLocalizations), shared by both platforms, and one keyword
list serves both stores.

WHY THE CHECKS
--------------
The limits are App Store Connect's own. Checking them here means a bad text
fails in CI, months before the release push would have been refused halfway
through (after some locales were already written).

The platform-name list is Guideline 2.3.10: macOS 1.52.0 was rejected on
2026-08-28 for a What's New bullet that mentioned Android. The description,
keywords and promotional text are metadata under the same guideline, and they
now exist in six languages, so the list carries the localized spellings too.
The English terms must stay a superset of `check_release_notes_platforms.sh`;
`scripts/test_asc_listing_preflight.sh` fails if the two drift.

The English-leftover heuristic exists because a translated listing that still
carries one untranslated English paragraph looks like a machine did it, and
nothing else would notice: every other check here passes on English text.

WHAT'S NEW
----------
Release notes live at the repo root, one directory per release:

    whatsnew_<version>/<locale>.txt         iOS text for that ASC locale   <= 4000
    whatsnew_<version>/macos-<locale>.txt   macOS text, when the two differ <= 4000

`<locale>` is an App Store Connect locale (a key of LOCALE_SOURCES), so es-ES
and es-MX are two files. While they share one listing directory they must say
the same thing, for the reason given at LOCALE_SOURCES.

A directory with no macos-*.txt at all carries one text per locale for both
platforms, and the Mac reads <locale>.txt. A directory with any macos-*.txt has
split the platforms, and then every locale needs its macos- file: the Mac does
NOT fall back to <locale>.txt, because in a split directory that is the iPhone
text (Siri, widgets, the Providers tab) and a missing Mac file is an omission.
`load_whatsnew()` is the one place that decides which file a locale gets;
`asc_submit.py` writes what it returns and nothing else.

The What's New checks are the listing's (2.3.10 platform names in every
language, English left in a translation) plus: the macOS text may not name a
feature only the direct-download Mac build has (the App Store build is sandboxed
without network.server and cannot offer Remote Control), and zh-Hant uses the
terms recorded in scripts/zh_hant_terms.json.
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LISTING_DIR_REL = "CLI Pulse Bar/appstore"

PRIMARY_LOCALE = "en-US"

# ASC locale -> directory under LISTING_DIR_REL.
#
# es-ES and es-MX share one neutral Spanish text on purpose. The app itself
# ships a single `es.lproj`, written in neutral Spanish ("costo", "Ajustes"),
# so a listing split by country would describe the app in words the app does
# not use in at least one of the two storefronts. Two copies of the same text
# would also drift the way the two copies of the English description once did.
# The one regional concession is in keywords, which are search terms rather
# than prose: the list carries Spain's "coste" next to the subtitle's "costo".
#
# Keeping the shared text neutral means avoiding the forms where Spain and Latin
# America differ. The Mac takes the neutral possessive ("tu Mac"): Spain writes
# "este Mac / un Mac" and Apple Latin America "esta Mac / una Mac". The one
# deliberate Spain form is "pantalla de bloqueo" (es_419: "pantalla bloqueada"),
# kept because it is what the app's own es.lproj says.
LOCALE_SOURCES: dict[str, str] = {
    "en-US": "en-US",
    "zh-Hans": "zh-Hans",
    "zh-Hant": "zh-Hant",
    "ja": "ja",
    "ko": "ko",
    "es-ES": "es",
    "es-MX": "es",
}

# The app name is the brand and is never translated. The pusher copies it into
# every new appInfoLocalization, and refuses to if en-US says anything else.
APP_NAME = "CLI Pulse"


@dataclass(frozen=True)
class Field:
    file: str          # base file name inside the locale directory
    attribute: str     # App Store Connect attribute
    resource: str      # "version" -> appStoreVersionLocalizations, "appInfo" -> appInfoLocalizations
    limit: int         # App Store Connect's character limit
    per_platform: bool  # may be overridden by <stem>.ios.txt / <stem>.macos.txt


FIELDS: tuple[Field, ...] = (
    Field("description.txt", "description", "version", 4000, True),
    Field("keywords.txt", "keywords", "version", 100, False),
    Field("promotional_text.txt", "promotionalText", "version", 170, True),
    Field("subtitle.txt", "subtitle", "appInfo", 30, False),
)
FIELD_BY_ATTRIBUTE = {f.attribute: f for f in FIELDS}

# ASC platform token -> override suffix.
PLATFORM_SUFFIX = {"IOS": "ios", "MAC_OS": "macos"}

# ── Guideline 2.3.10 ─────────────────────────────────────────────────────────
# Latin-script terms are matched case-insensitively on word boundaries, like
# `grep -iw` in check_release_notes_platforms.sh (so "Linuxism" does not fire,
# and neither does a substring of a URL). This list must contain every term of
# that script's FORBIDDEN list; the self-test enforces it.
#
# NB "Windows" fires on the English word "windows" too — that is deliberate and
# matches the release-notes guard. Say "quota periods", not "quota windows".
PLATFORM_TERMS_LATIN: tuple[str, ...] = (
    "Android",
    "Google Play",
    "Play Store",
    "Windows",
    "Linux",
    "Microsoft Store",
    "ChromeOS",
    "Chromebook",
)
# Localized spellings, matched as plain substrings (CJK has no word boundaries).
# 윈도우 is also the everyday Korean word for a GUI window; the listing has no
# reason to use it in either sense.
PLATFORM_TERMS_LOCALIZED: tuple[str, ...] = (
    "安卓", "安卓系统", "安卓系統", "谷歌商店", "Google 商店", "Play 商店",
    "微软商店", "微軟商店", "Microsoft 商店",
    "アンドロイド", "ウィンドウズ", "リナックス", "グーグルプレイ", "Google プレイ",
    "マイクロソフトストア",
    "안드로이드", "윈도우", "윈도즈", "리눅스", "구글 플레이", "플레이 스토어",
    "마이크로소프트 스토어",
)

# Other apps that do what this one does. Their names do not belong in our
# keywords (App Review Guideline 2.3.7). The providers we MONITOR — Claude,
# Codex, Gemini — are not competitors; they are what the app is about.
COMPETITOR_NAMES: tuple[str, ...] = ("codexbar", "ccusage", "token-monitor", "tokscale")

# ── English-leftover heuristic ───────────────────────────────────────────────
# Function words that are English and not also Spanish (no "a", "no", "me"),
# so a Spanish line never trips it. A line with three or more of these is an
# English sentence.
_EN_FUNCTION_WORDS = frozenset("""
    the and your you with for of to is are this that when from it will can
    on at by or an be have has in what how into its our we they their them
    was were been would should could which while than then there these those
""".split())
# Product and platform names that legitimately stay Latin inside CJK text.
_ALLOWED_LATIN_NAMES = (
    "CLI Pulse Pro", "CLI Pulse", "Claude Code", "Claude", "Codex", "Gemini",
    "Cursor", "Copilot", "OpenRouter", "Ollama", "Apple Watch", "Apple Account",
    "App Store", "iPhone", "iPad", "Mac", "Siri", "API", "SDK", "CSV", "PDF",
    "LLM", "Token", "AI", "Pro",
)
_URL = re.compile(r"https?://\S+")
_LATIN_WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")
# Five Latin words in a row, separated only by spaces/hyphens/commas.
_LATIN_RUN = re.compile(r"[A-Za-z]+(?:[ ,\-']+[A-Za-z]+){4,}")
_CJK = re.compile(r"[぀-ヿ㐀-鿿가-힯]")


@dataclass(frozen=True)
class Problem:
    where: str   # e.g. "ja/keywords.txt"
    what: str

    def __str__(self) -> str:
        return f"{self.where}: {self.what}"


def listing_dir(root: Path | None = None) -> Path:
    return (root or REPO) / LISTING_DIR_REL


def source_dirs() -> list[str]:
    """Each source directory once, in LOCALE_SOURCES order."""
    seen: list[str] = []
    for src in LOCALE_SOURCES.values():
        if src not in seen:
            seen.append(src)
    return seen


def field_path(field: Field, locale: str, platform: str | None = None,
               root: Path | None = None) -> Path:
    """The file that supplies `field` for `locale` on `platform`.

    With a platform, a `<stem>.<platform>.txt` override wins when it exists.
    """
    d = listing_dir(root) / LOCALE_SOURCES[locale]
    if platform and field.per_platform:
        stem = field.file[: -len(".txt")]
        override = d / f"{stem}.{PLATFORM_SUFFIX[platform]}.txt"
        if override.exists():
            return override
    return d / field.file


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def load_field(attribute: str, locale: str, platform: str | None = None,
               root: Path | None = None) -> str:
    """The repo text for one ASC attribute. Raises SystemExit if missing/empty."""
    field = FIELD_BY_ATTRIBUTE[attribute]
    path = field_path(field, locale, platform, root)
    if not path.exists():
        raise SystemExit(f"App Store listing text missing: {path}")
    text = read_text(path)
    if not text:
        raise SystemExit(f"App Store listing text is empty: {path}")
    return text


def load_locale(locale: str, platform: str | None = None,
                root: Path | None = None) -> dict[str, str]:
    """attribute -> text, for every field of one locale."""
    return {f.attribute: load_field(f.attribute, locale, platform, root) for f in FIELDS}


# ── validation ───────────────────────────────────────────────────────────────

def platform_terms_in(text: str) -> list[str]:
    hits = []
    for term in PLATFORM_TERMS_LATIN:
        pat = r"(?<![A-Za-z0-9_])" + re.escape(term).replace(r"\ ", r"\s+") + r"(?![A-Za-z0-9_])"
        if re.search(pat, text, flags=re.IGNORECASE):
            hits.append(term)
    for term in PLATFORM_TERMS_LOCALIZED:
        if term in text:
            hits.append(term)
    return hits


def english_lines(text: str, cjk: bool) -> list[str]:
    """Lines of a non-English text that look like untranslated English."""
    out = []
    for raw in text.splitlines():
        line = _URL.sub(" ", raw).strip()
        if not line:
            continue
        words = [w.lower() for w in _LATIN_WORD.findall(line)]
        if len({w for w in words if w in _EN_FUNCTION_WORDS}) >= 3:
            out.append(raw.strip())
            continue
        if cjk:
            stripped = line
            for name in _ALLOWED_LATIN_NAMES:
                stripped = stripped.replace(name, " ")
            if _LATIN_RUN.search(stripped):
                out.append(raw.strip())
    return out


def keyword_problems(keywords: str, subtitle: str, name: str = APP_NAME) -> list[str]:
    out: list[str] = []
    if re.search(r"\s,|,\s", keywords):
        out.append("keywords must be comma-separated without spaces around the commas")
    if keywords.startswith(",") or keywords.endswith(","):
        out.append("keywords start or end with a comma")
    if "\n" in keywords or "，" in keywords or "、" in keywords:
        out.append("keywords must be one line separated by ASCII commas "
                   "(no newlines, no full-width commas)")
    items = [k.strip() for k in keywords.split(",")]
    if any(not k for k in items):
        out.append("keywords contain an empty item (two commas in a row?)")
    seen: set[str] = set()
    for k in items:
        low = k.casefold()
        if low and low in seen:
            out.append(f"keyword '{k}' appears twice")
        seen.add(low)
    # Words already in the name or subtitle are indexed from there; repeating
    # them in keywords spends characters on nothing.
    name_words = {w.casefold() for w in re.findall(r"\w+", name)}
    sub_words = {w.casefold() for w in re.findall(r"\w+", subtitle)}
    for k in items:
        if not k:
            continue
        low = k.casefold()
        if low in name_words:
            out.append(f"keyword '{k}' repeats a word of the app name")
        elif low in sub_words or (_CJK.search(k) and k in subtitle):
            out.append(f"keyword '{k}' repeats a word of the subtitle")
        if any(c in low for c in COMPETITOR_NAMES):
            out.append(f"keyword '{k}' names a competing app (Guideline 2.3.7)")
    return out


def validate(root: Path | None = None) -> list[Problem]:
    """Every problem with the repo's listing texts. Empty list = valid."""
    base = listing_dir(root)
    problems: list[Problem] = []
    if not base.is_dir():
        return [Problem(LISTING_DIR_REL, "listing directory is missing")]

    # The layout itself: nothing left over from the old one, nothing nobody pushes.
    for legacy in sorted(base.glob("description_*.txt")):
        problems.append(Problem(legacy.name,
                                "legacy flat-layout file; the text lives in "
                                "<locale>/description.txt now — delete this copy"))
    known = set(source_dirs())
    for d in sorted(p for p in base.iterdir() if p.is_dir()):
        if d.name not in known:
            problems.append(Problem(d.name + "/",
                                    "directory is not in LOCALE_SOURCES, so nothing "
                                    "pushes it; map it to an ASC locale or remove it"))

    allowed_names = set()
    for f in FIELDS:
        allowed_names.add(f.file)
        if f.per_platform:
            stem = f.file[: -len(".txt")]
            for suffix in PLATFORM_SUFFIX.values():
                allowed_names.add(f"{stem}.{suffix}.txt")

    en_first_line = ""
    for src in source_dirs():
        d = base / src
        if not d.is_dir():
            problems.append(Problem(src + "/", "locale directory is missing"))
            continue
        for extra in sorted(d.iterdir()):
            if extra.is_file() and extra.name not in allowed_names and extra.name != ".DS_Store":
                problems.append(Problem(f"{src}/{extra.name}",
                                        "unexpected file; expected only "
                                        + ", ".join(f.file for f in FIELDS)
                                        + " (+ .ios/.macos overrides of description "
                                          "and promotional_text)"))
        texts: dict[str, str] = {}
        for f in FIELDS:
            p = d / f.file
            rel = f"{src}/{f.file}"
            if not p.exists():
                problems.append(Problem(rel, "missing"))
                continue
            texts[f.attribute] = read_text(p)
            if not texts[f.attribute]:
                problems.append(Problem(rel, "empty"))
        # Every variant of every field (base + platform overrides).
        variants: list[tuple[Field, Path]] = []
        for f in FIELDS:
            if (d / f.file).exists():
                variants.append((f, d / f.file))
            if f.per_platform:
                stem = f.file[: -len(".txt")]
                for suffix in PLATFORM_SUFFIX.values():
                    o = d / f"{stem}.{suffix}.txt"
                    if o.exists():
                        variants.append((f, o))
        for f, p in variants:
            rel = f"{src}/{p.name}"
            body = read_text(p)
            if p.name != f.file and not body:
                problems.append(Problem(rel, "empty override"))
            if len(body) > f.limit:
                problems.append(Problem(rel, f"{len(body)} characters, over App Store "
                                             f"Connect's limit of {f.limit}"))
            if "\n" in body and f.attribute in ("subtitle", "keywords"):
                problems.append(Problem(rel, "must be a single line"))
            for term in platform_terms_in(body):
                problems.append(Problem(rel, f"names '{term}' — Guideline 2.3.10: App Store "
                                             "metadata may not mention other platforms"))
            if src != "en-US" and f.attribute in ("description", "promotionalText"):
                cjk = src in ("zh-Hans", "zh-Hant", "ja", "ko")
                for line in english_lines(body, cjk)[:3]:
                    problems.append(Problem(rel, f"looks like untranslated English: {line[:90]!r}"))
        if texts.get("keywords") is not None:
            for msg in keyword_problems(texts["keywords"], texts.get("subtitle", "")):
                problems.append(Problem(f"{src}/keywords.txt", msg))
        if src == "en-US" and texts.get("description"):
            en_first_line = texts["description"].splitlines()[0]
        elif src != "en-US" and texts.get("description") and en_first_line \
                and en_first_line in texts["description"]:
            problems.append(Problem(f"{src}/description.txt",
                                    "contains the English description's first line verbatim"))
    return problems


# The pushers must READ these files. An inline copy in a pusher is how the
# listing drifted before: on 2026-09-01 one pusher said "Optional cloud sync via
# your CLI Pulse account" while the other said "All data stays on your local
# network / Connects to your self-hosted CLI Pulse backend", and whichever ran
# last decided what the App Store said about our privacy posture.
PUSHERS_REL: tuple[str, ...] = (
    "CLI Pulse Bar/scripts/appstore_metadata.py",
    "CLI Pulse Bar/scripts/resubmit.py",
    "scripts/asc_push_listing.py",
)
LEGACY_DESCRIPTION_MARKER = "CLI Pulse monitors your AI coding tool usage"


def inline_copy_problems(root: Path | None = None) -> list[Problem]:
    """A pusher that carries its own copy of any listing text."""
    r = root or REPO
    base = listing_dir(r)
    markers: list[tuple[str, str]] = [("legacy description", LEGACY_DESCRIPTION_MARKER)]
    for src in source_dirs():
        for f in FIELDS:
            p = base / src / f.file
            if not p.exists():
                continue
            body = read_text(p)
            if not body:
                continue
            probe = body.splitlines()[0][:60] if f.attribute == "description" else body
            if len(probe) >= 12:
                markers.append((f"{src}/{f.file}", probe))
    out: list[Problem] = []
    for rel in PUSHERS_REL:
        src_file = r / rel
        if not src_file.exists():
            out.append(Problem(rel, "pusher missing — if it was retired, remove it from "
                                    "PUSHERS_REL in scripts/appstore_listing.py"))
            continue
        code = src_file.read_text(encoding="utf-8")
        for label, probe in markers:
            if probe in code:
                out.append(Problem(rel, f"carries an inline copy of {label}; pushers must "
                                        "read the file through scripts/appstore_listing.py"))
    return out


def summary_rows(root: Path | None = None) -> list[tuple[str, dict[str, int]]]:
    """(source dir, {file name: character count}) for a human-readable table."""
    base = listing_dir(root)
    rows = []
    for src in source_dirs():
        counts = {}
        for f in FIELDS:
            p = base / src / f.file
            counts[f.file] = len(read_text(p)) if p.exists() else -1
        rows.append((src, counts))
    return rows


# ── What's New ───────────────────────────────────────────────────────────────
# Layout and rules: WHAT'S NEW in the module docstring.

WHATSNEW_LIMIT = 4000          # App Store Connect's limit for whatsNew
WHATSNEW_MAC_PREFIX = "macos-"
PLATFORM_LABEL = {"IOS": "iOS", "MAC_OS": "macOS"}

# Features only the direct-download (Developer ID) Mac build has. The App Store
# Mac build cannot offer them, so its What's New may not name them. A tripwire
# for the obvious wording in each language, not a proof: a sentence can sell
# the feature without these words, which is what review is for. Latin terms
# match case-insensitively on word boundaries; the others as plain substrings.
DEVID_ONLY_TERMS_LATIN: tuple[str, ...] = (
    "Remote Control", "control remoto", "fan control", "fan speed", "fan boost",
    "ventilador",
)
DEVID_ONLY_TERMS_LOCALIZED: tuple[str, ...] = (
    "远程控制", "远程操作", "遠端控制", "遠端操作", "リモート操作", "リモートコントロール",
    "원격 제어", "원격 조작", "风扇", "風扇", "ファンの回転", "ファン回転", "팬 속도", "팬 부스트",
)
ZH_HANT_TERMS_REL = "scripts/zh_hant_terms.json"


@dataclass(frozen=True)
class WhatsNewText:
    locale: str
    file: str   # file name inside the directory, e.g. "macos-ja.txt"
    text: str


def _terms_in(text: str, latin: tuple[str, ...], localized: tuple[str, ...]) -> list[str]:
    hits = []
    for term in latin:
        pat = r"(?<![A-Za-z0-9_])" + re.escape(term).replace(r"\ ", r"\s+") + r"(?![A-Za-z0-9_])"
        if re.search(pat, text, flags=re.IGNORECASE):
            hits.append(term)
    hits.extend(t for t in localized if t in text)
    return hits


def devid_only_terms_in(text: str) -> list[str]:
    return _terms_in(text, DEVID_ONLY_TERMS_LATIN, DEVID_ONLY_TERMS_LOCALIZED)


def zh_hant_forbidden_terms(root: Path | None = None) -> dict[str, str]:
    """variant -> the word to use instead, from the Apple half of the zh-Hant
    terminology manifest. Empty if the manifest is missing, which the manifest's
    own gate (check_zh_hant_terms.py) already fails on."""
    path = (root or REPO) / ZH_HANT_TERMS_REL
    if not path.exists():
        path = REPO / ZH_HANT_TERMS_REL
    if not path.exists():
        return {}
    import json  # noqa: PLC0415 - only this check needs it
    out: dict[str, str] = {}
    for concept in json.loads(path.read_text(encoding="utf-8")).get("concepts", []):
        apple = concept.get("apple") or {}
        for bad in apple.get("forbid", []):
            out[bad] = apple.get("use", "")
    return out


def whatsnew_is_split(d: Path) -> bool:
    """True when the directory carries separate macOS texts (any macos-*.txt)."""
    return any(p.name.startswith(WHATSNEW_MAC_PREFIX) for p in d.glob("*.txt"))


def whatsnew_file(d: Path, locale: str, platform: str) -> Path:
    """The file that must supply `locale`'s What's New on `platform`."""
    if platform == "MAC_OS" and whatsnew_is_split(d):
        return d / f"{WHATSNEW_MAC_PREFIX}{locale}.txt"
    return d / f"{locale}.txt"


def load_whatsnew(d: Path, platform: str, root: Path | None = None
                  ) -> tuple[dict[str, WhatsNewText], list[Problem]]:
    """Every store locale's What's New for `platform` (IOS or MAC_OS), and every
    reason not to send it. Problems name the file; an empty list means every
    locale in LOCALE_SOURCES has a valid text."""
    if not d.is_dir():
        return {}, [Problem(str(d), "What's New directory not found")]
    split = whatsnew_is_split(d)
    # Unsplit, one file serves both platforms: word it the same way for both,
    # so whatsnew_problems() reports it once.
    label = PLATFORM_LABEL[platform] if split else "iOS or macOS"
    texts: dict[str, WhatsNewText] = {}
    problems: list[Problem] = []
    zh_hant_bad = zh_hant_forbidden_terms(root)
    for locale in LOCALE_SOURCES:
        path = whatsnew_file(d, locale, platform)
        where = f"{d.name}/{path.name}"
        if not path.exists():
            why = f"missing: {locale} has no {label} What's New"
            if split and platform == "MAC_OS":
                why += (f" (this directory has macOS texts, so the Mac does not fall back "
                        f"to {locale}.txt, which is the iPhone text)")
            problems.append(Problem(where, why))
            continue
        text = read_text(path)
        if not text:
            problems.append(Problem(where, "empty"))
            continue
        texts[locale] = WhatsNewText(locale, path.name, text)
        if len(text) > WHATSNEW_LIMIT:
            problems.append(Problem(where, f"{len(text)} characters, over App Store Connect's "
                                           f"limit of {WHATSNEW_LIMIT}"))
        for term in platform_terms_in(text):
            problems.append(Problem(where, f"names '{term}' — Guideline 2.3.10: What's New may "
                                           "not mention other platforms (macOS 1.52.0 was "
                                           "rejected for this)"))
        if platform == "MAC_OS":
            for term in devid_only_terms_in(text):
                problems.append(Problem(where, f"names '{term}', which only the direct-download "
                                               "Mac build has; the App Store Mac build cannot "
                                               "offer it"))
        if locale != PRIMARY_LOCALE:
            cjk = LOCALE_SOURCES[locale] in ("zh-Hans", "zh-Hant", "ja", "ko")
            for line in english_lines(text, cjk)[:3]:
                problems.append(Problem(where, f"looks like untranslated English: {line[:90]!r}"))
        if LOCALE_SOURCES[locale] == "zh-Hant":
            for bad, use in zh_hant_bad.items():
                if bad in text:
                    problems.append(Problem(where, f"uses '{bad}'; zh-Hant says '{use}' "
                                                   f"({ZH_HANT_TERMS_REL})"))
    # Locales that share a listing directory share the What's New as well.
    by_source: dict[str, list[str]] = {}
    for locale, src in LOCALE_SOURCES.items():
        by_source.setdefault(src, []).append(locale)
    for src, locales in by_source.items():
        present = [loc for loc in locales if loc in texts]
        if len({texts[loc].text for loc in present}) > 1:
            names = ", ".join(texts[loc].file for loc in present)
            problems.append(Problem(f"{d.name}/{texts[present[-1]].file}",
                                    f"{names} differ; {', '.join(locales)} share the listing "
                                    f"directory '{src}/', so they carry one text"))
    return texts, problems


def whatsnew_problems(d: Path, root: Path | None = None) -> list[Problem]:
    """Every problem with a What's New directory, for both platforms."""
    problems: list[Problem] = []
    for platform in PLATFORM_LABEL:
        problems += load_whatsnew(d, platform, root)[1]
    if d.is_dir():
        expected = {f"{loc}.txt" for loc in LOCALE_SOURCES}
        expected |= {f"{WHATSNEW_MAC_PREFIX}{loc}.txt" for loc in LOCALE_SOURCES}
        for extra in sorted(p for p in d.glob("*.txt") if p.name not in expected):
            problems.append(Problem(f"{d.name}/{extra.name}",
                                    "unexpected file: not <locale>.txt or macos-<locale>.txt for "
                                    "an App Store locale (" + ", ".join(LOCALE_SOURCES) + ")"))
    unique: list[Problem] = []
    for p in problems:           # a shared file is read for both platforms
        if p not in unique:
            unique.append(p)
    return unique


if __name__ == "__main__":
    probs = validate() + inline_copy_problems()
    for src, counts in summary_rows():
        print(f"{src:8} " + "  ".join(f"{k.split('.')[0]}={v}" for k, v in counts.items()))
    for p in probs:
        print(f"FAIL  {p}")
    sys.exit(1 if probs else 0)

#!/usr/bin/env python3
"""The iPhone App Store screenshots: which exist, where they live, what makes one uploadable.

One module, imported by everything that makes, checks or pushes them, so the
layout is written down exactly once:

  - CLI Pulse Bar/scripts/capture_ios_screenshots.sh     captures the raw PNGs
    (bash; scripts/test_appstore_screenshots.py holds its lists to this one)
  - CLI Pulse Bar/scripts/compose_appstore_ios_screenshots.py   composes the panels
  - scripts/asc_push_screenshots.py                      uploads the panels
  - scripts/asc_listing_preflight.py --require-shots     checks every locale has them

LAYOUT
------
    CLI Pulse Bar/screenshots/ios-raw/<lang>/NN_<screen>.png
        simulator captures, 1320x2868 on the 6.9" iPhone 17 Pro Max
    CLI Pulse Bar/screenshots/ios-composed/<lang>/NN_<screen>_1290x2796.png
        the marketing panels App Store Connect gets, in its APP_IPHONE_67 set
    CLI Pulse Bar/screenshots/ios-composed/<lang>/compose.json
        written by the compositor only when every panel of the set passed
        (captions fit, every glyph drawn, corners clean): each panel's md5,
        with the captions, faces and sizes it was drawn with. A failing run
        deletes it. A set without it, or with a panel whose md5 it does not
        record, is not uploadable, whatever its PNG headers say.

`<lang>` is one of LANGS, the app's six languages. SHOT_SOURCES maps each App
Store Connect locale to the language whose panels it shows: seven locales, six
sets, because es-ES and es-MX share the Spanish images exactly as they share the
Spanish listing text (scripts/appstore_listing.py explains why).

A locale may instead be mapped to FALLBACK: it then gets no set of its own and
App Store Connect shows it the primary locale's (en-US) screenshots. That is a
decision, recorded here, not a gap: `--require-shots` accepts it and says so.

The 1.53.0 set predates this layout: English in screenshots/ios/ (raw) and
screenshots/ios/composed/, Simplified Chinese in screenshots/ios-zh/. Those
directories stay until the first capture in this layout replaces them;
LEGACY_COMPOSED names them for the release preflight in the meantime.

WHAT MAKES A PANEL UPLOADABLE
-----------------------------
Exactly 1290x2796 pixels, 8-bit RGB with no alpha channel and no transparency
chunk, a real PNG, at most 10 MB, and the file compose.json says the last clean
compose run wrote. App Store Connect refuses an image with an
alpha channel for screenshots, and it refuses it after the old set may already
have been deleted, so this is checked before anything is sent. Read straight
from the PNG header: no Pillow, so it also runs on a bare CI runner.
"""
from __future__ import annotations

import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCREENSHOTS_REL = "CLI Pulse Bar/screenshots"

# The App Store set, in listing order: NN is the 1-based position. The Swift
# enum ScreenshotLaunch.Screen and the capture script name the same five.
SCREENS: tuple[str, ...] = ("overview", "providers", "cost", "sessions", "alerts")

# The app's languages, as its .lproj directories are named.
LANGS: tuple[str, ...] = ("en", "zh-Hans", "zh-Hant", "ja", "ko", "es")

# Earlier spellings still accepted on the command line.
LANG_ALIASES: dict[str, str] = {"zh": "zh-Hans"}

FALLBACK = None   # see the module docstring

# ASC locale -> the language whose panels it shows (or FALLBACK).
SHOT_SOURCES: dict[str, str | None] = {
    "en-US": "en",
    "zh-Hans": "zh-Hans",
    "zh-Hant": "zh-Hant",
    "ja": "ja",
    "ko": "ko",
    "es-ES": "es",
    "es-MX": "es",
}

# The 1.53.0 panels, by language (see the module docstring).
LEGACY_COMPOSED: dict[str, str] = {
    "en": "ios/composed",
    "zh-Hans": "ios-zh/composed",
}

DISPLAY_TYPE = "APP_IPHONE_67"
CANVAS = (1290, 2796)
MAX_BYTES = 10 * 1000 * 1000
SUFFIX = f"_{CANVAS[0]}x{CANVAS[1]}.png"
MANIFEST = "compose.json"


def canonical_lang(lang: str) -> str:
    lang = LANG_ALIASES.get(lang, lang)
    if lang not in LANGS:
        raise SystemExit(f"unknown language {lang!r}; known: {', '.join(LANGS)}")
    return lang


def stem(index: int, screen: str) -> str:
    """'03_cost' for the third screen."""
    return f"{index:02d}_{screen}"


def stems() -> list[str]:
    return [stem(i, s) for i, s in enumerate(SCREENS, start=1)]


def composed_name(stem_: str) -> str:
    return stem_ + SUFFIX


def screenshots_dir(root: Path | None = None) -> Path:
    return (root or REPO) / SCREENSHOTS_REL


def raw_dir(lang: str, root: Path | None = None) -> Path:
    return screenshots_dir(root) / "ios-raw" / canonical_lang(lang)


def composed_dir(lang: str, root: Path | None = None) -> Path:
    return screenshots_dir(root) / "ios-composed" / canonical_lang(lang)


def expected_composed(lang: str, root: Path | None = None) -> list[Path]:
    d = composed_dir(lang, root)
    return [d / composed_name(s) for s in stems()]


def preflight_dir(lang: str, root: Path | None = None) -> Path:
    """The panels the store should be showing for `lang`: this layout's if it
    has any, else the 1.53.0 directory."""
    new = composed_dir(lang, root)
    if new.is_dir() and any(new.glob("*.png")):
        return new
    legacy = LEGACY_COMPOSED.get(canonical_lang(lang))
    return screenshots_dir(root) / legacy if legacy else new


# ── the PNG header ───────────────────────────────────────────────────────────

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
COLOR_TYPES = {0: "grayscale", 2: "RGB", 3: "palette", 4: "grayscale+alpha", 6: "RGBA"}


def png_info(path: Path) -> dict:
    """Width, height, bit depth, colour type and whether any transparency is
    declared, from the PNG's own chunks. Raises ValueError if it is not a PNG."""
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("not a PNG file")
    pos = len(PNG_SIGNATURE)
    info: dict = {}
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            if length != 13:
                raise ValueError("malformed IHDR")
            w, h, depth, color = struct.unpack(">IIBB", body[:10])
            info.update(width=w, height=h, bit_depth=depth, color_type=color, trns=False)
        elif kind == b"tRNS":
            info["trns"] = True
        elif kind == b"IEND":
            break
        pos += 12 + length
    if "width" not in info:
        raise ValueError("no IHDR chunk")
    info["has_alpha"] = info["color_type"] in (4, 6) or info["trns"]
    return info


def panel_problems(path: Path) -> list[str]:
    """Why App Store Connect would refuse this panel. Empty = uploadable."""
    if not path.is_file():
        return ["missing"]
    size = path.stat().st_size
    out = []
    if size > MAX_BYTES:
        out.append(f"{size} bytes, over the {MAX_BYTES}-byte limit")
    try:
        info = png_info(path)
    except (ValueError, struct.error) as exc:
        return out + [str(exc)]
    if (info["width"], info["height"]) != CANVAS:
        out.append(f"{info['width']}x{info['height']}, expected {CANVAS[0]}x{CANVAS[1]}")
    if info["color_type"] != 2 or info["bit_depth"] != 8:
        kind = COLOR_TYPES.get(info["color_type"], f"colour type {info['color_type']}")
        out.append(f"{kind}, {info['bit_depth']}-bit; expected 8-bit RGB")
    elif info["trns"]:
        out.append("declares transparency (tRNS chunk); expected opaque RGB")
    return out


def md5_of(path: Path) -> str:
    return hashlib.md5(path.read_bytes()).hexdigest()


def write_manifest(directory: Path, lang: str, record: dict | None = None) -> None:
    """Record `directory`'s five panels as the output of a clean compose run.
    Only the compositor calls this, and only when every panel passed; tests
    call it to build a set that stands for one."""
    panels = {composed_name(s): md5_of(directory / composed_name(s)) for s in stems()}
    data = {"lang": canonical_lang(lang), "panels": panels, **(record or {})}
    (directory / MANIFEST).write_text(json.dumps(data, ensure_ascii=False, indent=1, sort_keys=True)
                                      + "\n", encoding="utf-8")


def manifest_problems(lang: str, root: Path | None = None) -> list[str]:
    """Whether the set is what the last clean compose run wrote."""
    d = composed_dir(lang, root)
    path = d / MANIFEST
    if not path.is_file():
        return [f"{MANIFEST} is missing: these panels are not the output of a clean compose "
                "run (compose_appstore_ios_screenshots.py writes it only when every panel "
                "passed, and deletes it when a run fails)"]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        recorded = dict(data["panels"])
        lang_ok = data.get("lang") == canonical_lang(lang)
    except (ValueError, KeyError, TypeError) as exc:
        return [f"{MANIFEST} is unreadable ({type(exc).__name__})"]
    out = [] if lang_ok else [f"{MANIFEST} was written for {data.get('lang')!r}, not {lang!r}"]
    for p in expected_composed(lang, root):
        if p.is_file() and recorded.get(p.name) != md5_of(p):
            out.append(f"{p.name}: not the file the last clean compose run wrote "
                       f"(its md5 is not the one {MANIFEST} records)")
    return out


def set_problems(lang: str, root: Path | None = None) -> list[str]:
    """Problems with one language's composed set: every panel present and
    uploadable, nothing else in the directory that a push would skip, and
    every panel the one a clean compose run wrote (compose.json)."""
    d = composed_dir(lang, root)
    if not d.is_dir():
        return [f"{d.relative_to(screenshots_dir(root).parent)}/ does not exist"]
    out = []
    expected = expected_composed(lang, root)
    for p in expected:
        for why in panel_problems(p):
            out.append(f"{p.name}: {why}")
    extra = sorted(p.name for p in d.glob("*.png") if p not in expected)
    for name in extra:
        out.append(f"{name}: not one of the {len(SCREENS)} panels; remove it or add its screen")
    return out + manifest_problems(lang, root)


def require_shots_problems(locales, root: Path | None = None) -> list[tuple[str, str]]:
    """(locale, problem) for every listing locale without a complete set."""
    out: list[tuple[str, str]] = []
    for loc in locales:
        if loc not in SHOT_SOURCES:
            out.append((loc, "has listing texts but no entry in SHOT_SOURCES "
                             "(scripts/appstore_screenshots.py); map it to a language or FALLBACK"))
            continue
        lang = SHOT_SOURCES[loc]
        if lang is FALLBACK:
            continue
        out.extend((loc, f"{lang}: {why}") for why in set_problems(lang, root))
    return out


# ── writing test fixtures ────────────────────────────────────────────────────

def write_png(path: Path, width: int, height: int, color_type: int = 2, trns: bool = False) -> None:
    """A minimal valid PNG (one solid colour). For tests and negative controls."""
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    row = b"\x00" + b"\x40" * (width * channels)
    raw = zlib.compress(row * height, 1)

    def chunk(kind: bytes, body: bytes) -> bytes:
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    parts = [PNG_SIGNATURE, chunk(b"IHDR", ihdr)]
    if trns:
        parts.append(chunk(b"tRNS", b"\x00\x00\x00\x00\x00\x00"))
    parts += [chunk(b"IDAT", raw), chunk(b"IEND", b"")]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"".join(parts))


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import appstore_listing as listing  # noqa: E402
    problems = require_shots_problems(listing.LOCALE_SOURCES)
    for loc, lang in SHOT_SOURCES.items():
        print(f"{loc:8} -> {lang or 'FALLBACK (en-US panels)'}")
    for loc, why in problems:
        print(f"FAIL  [{loc}] {why}")
    sys.exit(1 if problems else 0)

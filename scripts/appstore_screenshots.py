#!/usr/bin/env python3
"""The App Store screenshots, iPhone and Mac: which exist, where they live, what makes one uploadable.

One module, imported by everything that makes, checks or pushes them, so the
layout is written down exactly once:

  - CLI Pulse Bar/scripts/capture_ios_screenshots.sh     captures the raw iPhone PNGs
    (bash; scripts/test_appstore_screenshots.py holds its lists to this one)
  - scripts/render_macos_qa_views.sh --set store         renders the raw Mac PNGs
  - CLI Pulse Bar/scripts/compose_appstore_ios_screenshots.py     composes the iPhone panels
  - CLI Pulse Bar/scripts/compose_appstore_macos_screenshots.py   composes the Mac panels
  - scripts/asc_push_screenshots.py --platform IOS|MAC_OS   uploads the panels
  - scripts/asc_listing_preflight.py --require-shots     checks every locale has them

Two platforms (Platform): IPHONE, the default of every function below, and MAC.
The module-level names SCREENS, CANVAS, DISPLAY_TYPE, SUFFIX and COMPOSITOR_REL
are the iPhone's, as they were before the Mac set existed.

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
        record, is not uploadable, whatever its PNG headers say. Nor is one
        whose recorded captions are not the compositor's COPY any more: a
        caption edited without recomposing leaves the old words in the image.
        It also records the md5 of each raw capture the panels were drawn
        from, and --require-shots fails when ios-raw/<lang>/ no longer holds
        exactly those (capture_problems): they are committed so that a set
        can be recomposed without a simulator.

    CLI Pulse Bar/screenshots/macos-raw/<lang>/NN_<screen>.png, render.json
        the QA build's offscreen renders of the real Mac views (the store set,
        docs/qa/macos-offscreen-renders.md): 380x580-point popovers at 3x
        (04_cost's shortened so it opens above a card, render.json says how
        much), 03_usage_history.panel.png beside the third, and the renderer's
        render.json with each file's md5 and the facts of the build that drew
        them (render_problems)
    CLI Pulse Bar/screenshots/macos-composed/<lang>/NN_<screen>_2880x1800.png
        the Mac panels, in the APP_DESKTOP set, with compose.json as above

`<lang>` is one of LANGS, the app's six languages. SHOT_SOURCES maps each App
Store Connect locale to the language whose panels it shows: seven locales, six
sets, because es-ES and es-MX share the Spanish images exactly as they share the
Spanish listing text (scripts/appstore_listing.py explains why).

A locale may instead be mapped to FALLBACK: it then gets no set of its own and
App Store Connect shows it the primary locale's (en-US) screenshots. That is a
decision, recorded here, not a gap: `--require-shots` accepts it and says so.

The 1.53.0 set (English in screenshots/ios/, Simplified Chinese in
screenshots/ios-zh/, shot by hand) was retired when the first six-language
capture in this layout landed for 1.54.0. Nothing reads those paths any more;
the release preflight compares the live store with ios-composed/<lang>/ only.

WHAT MAKES A PANEL UPLOADABLE
-----------------------------
Exactly its platform's canvas (1290x2796 iPhone, 2880x1800 Mac) in pixels, 8-bit RGB with no alpha channel and no transparency
chunk, a real PNG, at most 10 MB, and the file compose.json says the last clean
compose run wrote. App Store Connect refuses an image with an
alpha channel for screenshots, and it refuses it after the old set may already
have been deleted, so this is checked before anything is sent. Read straight
from the PNG header: no Pillow, so it also runs on a bare CI runner.
"""
from __future__ import annotations

import ast
import hashlib
import json
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path

# CHECKOUT is this checkout. REPO starts as the same path, but tests point it at
# a fixture tree; only CHECKOUT is known to carry the compositor.
CHECKOUT = Path(__file__).resolve().parent.parent
REPO = CHECKOUT
SCREENSHOTS_REL = "CLI Pulse Bar/screenshots"
COMPOSITOR_REL = "CLI Pulse Bar/scripts/compose_appstore_ios_screenshots.py"

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

DISPLAY_TYPE = "APP_IPHONE_67"
CANVAS = (1290, 2796)
MAX_BYTES = 10 * 1000 * 1000
SUFFIX = f"_{CANVAS[0]}x{CANVAS[1]}.png"
MANIFEST = "compose.json"

# ── the Mac set ──────────────────────────────────────────────────────────────
# The Swift store catalog (QARenderSnapshot.storeCatalog) draws the same six in
# the same order; scripts/test_appstore_screenshots.py holds the two together.
MAC_SCREENS: tuple[str, ...] = ("overview", "providers", "usage_history", "cost", "alerts", "pulse_cat")
MAC_COMPOSITOR_REL = "CLI Pulse Bar/scripts/compose_appstore_macos_screenshots.py"
# Screens drawn with the usage panel beside the popover: its raw file is
# NN_<screen>.panel.png, next to the popover's.
MAC_PANEL_SCREENS: tuple[str, ...] = ("usage_history",)
RENDER_MANIFEST = "render.json"
# What render.json must say (render_problems): the store set, at 3x, with the
# popover at its default size and the panel at DashboardPanelController's
# width, drawn by a build without DEVID_BUILD and without remote control, from
# a local usage history holding only what the scanner records.
MAC_RENDER_SCALE = 3
MAC_POPOVER_PT = (380, 580)
# A shot on a "lastAligned" page (QARenderSnapshot.alignedTrim) is drawn in a
# popover shortened so it opens just above a whole card (406 points for 1.55's
# cost shot: QARenderSnapshot.alignedCard); users drag it from 400 to 900.
MAC_POPOVER_MIN_HEIGHT_PT = 400
MAC_PANEL_WIDTH_PT = 520
LOCAL_SCAN_PROVIDERS = frozenset({"Claude", "Codex"})
# The region each language is drawn on (render_macos_qa_views.sh locale_for,
# the same as the iPhone capture's): render.json's displayLocale must be in it.
MAC_REGIONS: dict[str, str] = {"en": "US", "zh-Hans": "CN", "zh-Hant": "TW", "ja": "JP", "ko": "KR",
                               "es": "MX"}
# The usage panel's backdrop, drawn over the panel's dark fill; above this
# relative luminance it drew as a flat gray slab (QARenderSnapshot
# storePanelMaxBackdropLuminance).
MAC_PANEL_MAX_BACKDROP_LUMINANCE = 0.25


@dataclass(frozen=True)
class Platform:
    name: str                  # for messages
    asc_platform: str          # App Store Connect's platform
    display_type: str          # the screenshot set this platform's panels go to
    canvas: tuple[int, int]
    screens_var: str           # the module-level tuple naming the screens
    compositor_var: str        # the module-level path of the compositor (tests repoint it)
    raw_subdir: str
    composed_subdir: str
    panel_screens: tuple[str, ...] = ()
    render_manifest: str | None = None

    @property
    def screens(self) -> tuple[str, ...]:
        return globals()[self.screens_var]

    @property
    def compositor_rel(self) -> str:
        return globals()[self.compositor_var]

    @property
    def suffix(self) -> str:
        return f"_{self.canvas[0]}x{self.canvas[1]}.png"

    @property
    def compositor_name(self) -> str:
        return Path(self.compositor_rel).name


IPHONE = Platform("iPhone", "IOS", DISPLAY_TYPE, CANVAS, "SCREENS", "COMPOSITOR_REL",
                  "ios-raw", "ios-composed")
MAC = Platform("Mac", "MAC_OS", "APP_DESKTOP", (2880, 1800), "MAC_SCREENS", "MAC_COMPOSITOR_REL",
               "macos-raw", "macos-composed", panel_screens=MAC_PANEL_SCREENS,
               render_manifest=RENDER_MANIFEST)
PLATFORMS: dict[str, Platform] = {p.asc_platform: p for p in (IPHONE, MAC)}


def canonical_lang(lang: str) -> str:
    lang = LANG_ALIASES.get(lang, lang)
    if lang not in LANGS:
        raise SystemExit(f"unknown language {lang!r}; known: {', '.join(LANGS)}")
    return lang


def stem(index: int, screen: str) -> str:
    """'03_cost' for the third screen."""
    return f"{index:02d}_{screen}"


def stems(platform: Platform = IPHONE) -> list[str]:
    return [stem(i, s) for i, s in enumerate(platform.screens, start=1)]


def composed_name(stem_: str, platform: Platform = IPHONE) -> str:
    return stem_ + platform.suffix


def panel_raw_names(platform: Platform = IPHONE) -> list[str]:
    """The raw files drawn beside a screen's own (`NN_<screen>.panel.png`)."""
    return [f"{st}.panel.png" for st, screen in zip(stems(platform), platform.screens)
            if screen in platform.panel_screens]


def raw_names(platform: Platform = IPHONE) -> list[str]:
    """Every raw PNG the compositor reads, in listing order."""
    names = []
    for st in stems(platform):
        names.append(st + ".png")
        names += [n for n in panel_raw_names(platform) if n.startswith(st + ".")]
    return names


def screenshots_dir(root: Path | None = None) -> Path:
    return (root or REPO) / SCREENSHOTS_REL


def raw_dir(lang: str, root: Path | None = None, platform: Platform = IPHONE) -> Path:
    return screenshots_dir(root) / platform.raw_subdir / canonical_lang(lang)


def composed_dir(lang: str, root: Path | None = None, platform: Platform = IPHONE) -> Path:
    return screenshots_dir(root) / platform.composed_subdir / canonical_lang(lang)


def expected_composed(lang: str, root: Path | None = None, platform: Platform = IPHONE) -> list[Path]:
    d = composed_dir(lang, root, platform)
    return [d / composed_name(s, platform) for s in stems(platform)]


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


def panel_problems(path: Path, platform: Platform = IPHONE) -> list[str]:
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
    canvas = platform.canvas
    if (info["width"], info["height"]) != canvas:
        out.append(f"{info['width']}x{info['height']}, expected {canvas[0]}x{canvas[1]}")
    if info["color_type"] != 2 or info["bit_depth"] != 8:
        kind = COLOR_TYPES.get(info["color_type"], f"colour type {info['color_type']}")
        out.append(f"{kind}, {info['bit_depth']}-bit; expected 8-bit RGB")
    elif info["trns"]:
        out.append("declares transparency (tRNS chunk); expected opaque RGB")
    return out


def md5_of(path: Path) -> str:
    return hashlib.md5(path.read_bytes()).hexdigest()


def write_manifest(directory: Path, lang: str, record: dict | None = None,
                   platform: Platform = IPHONE) -> None:
    """Record `directory`'s panels as the output of a clean compose run.
    Only the compositor calls this, and only when every panel passed; tests
    call it to build a set that stands for one."""
    panels = {composed_name(s, platform): md5_of(directory / composed_name(s, platform))
              for s in stems(platform)}
    data = {"lang": canonical_lang(lang), "panels": panels, **(record or {})}
    (directory / MANIFEST).write_text(json.dumps(data, ensure_ascii=False, indent=1, sort_keys=True)
                                      + "\n", encoding="utf-8")


def caption_copy(root: Path | None = None, platform: Platform = IPHONE) -> dict | None:
    """The compositor's COPY table ({lang: {stem: (title, subtitle)}}), read
    from its source rather than imported, so a bare CI runner without Pillow
    reads it too. None when the tree has no compositor (a test fixture)."""
    path = (root or REPO) / platform.compositor_rel
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except (OSError, SyntaxError, ValueError):
        return None
    for node in tree.body:
        if isinstance(node, ast.AnnAssign):
            targets = [node.target]
        elif isinstance(node, ast.Assign):
            targets = node.targets
        else:
            continue
        if any(isinstance(t, ast.Name) and t.id == "COPY" for t in targets) and node.value is not None:
            return ast.literal_eval(node.value)
    return None


def manifest_problems(lang: str, root: Path | None = None, platform: Platform = IPHONE) -> list[str]:
    """Whether the set is what the last clean compose run wrote."""
    d = composed_dir(lang, root, platform)
    path = d / MANIFEST
    if not path.is_file():
        return [f"{MANIFEST} is missing: these panels are not the output of a clean compose "
                f"run ({platform.compositor_name} writes it only when every panel "
                "passed, and deletes it when a run fails)"]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        recorded = dict(data["panels"])
        lang_ok = data.get("lang") == canonical_lang(lang)
    except (ValueError, KeyError, TypeError) as exc:
        return [f"{MANIFEST} is unreadable ({type(exc).__name__})"]
    out = [] if lang_ok else [f"{MANIFEST} was written for {data.get('lang')!r}, not {lang!r}"]
    copy = caption_copy(root, platform)
    if copy is None or canonical_lang(lang) not in copy:
        # A fixture tree may have no compositor. This checkout always has one,
        # so here a missing file, a missing COPY or a missing language fails
        # instead of quietly switching the caption check off.
        if (root or REPO) == CHECKOUT:
            out.append(f"the captions cannot be checked: {platform.compositor_rel} is missing, "
                       f"unparsable, or has no COPY for {canonical_lang(lang)!r}")
    else:
        want = {st: list(pair) for st, pair in copy[canonical_lang(lang)].items()}
        drawn = data.get("captions")
        stale = sorted(st for st in want if not isinstance(drawn, dict) or drawn.get(st) != want[st])
        if stale:
            out.append(f"{', '.join(stale)}: the caption drawn is not the compositor's COPY "
                       f"(edited without recomposing; run {platform.compositor_name} "
                       f"--lang {canonical_lang(lang)})")
    for p in expected_composed(lang, root, platform):
        if p.is_file() and recorded.get(p.name) != md5_of(p):
            out.append(f"{p.name}: not the file the last clean compose run wrote "
                       f"(its md5 is not the one {MANIFEST} records)")
    return out


def capture_problems(lang: str, root: Path | None = None, platform: Platform = IPHONE) -> list[str]:
    """Whether ios-raw/<lang>/ (macos-raw/<lang>/) holds the captures the set was composed from:
    every capture compose.json records under "captures", with that md5, and no
    other the compositor would read. The raw captures are committed so that a
    caption fix is a recompose (`--all`), not a recapture; that holds only
    while they are the ones behind the committed panels. For --require-shots
    (CI), not the pusher: what it uploads is the panels.

    A set without a readable compose.json is manifest_problems' to report. A
    fixture tree may record no captures and is not checked; this checkout's
    compose.json always records them, so there a missing record fails.

    The Mac set also records its render.json (under "render"), and that must
    still be the one there and still pass render_problems: the facts it states
    about the build that drew the raws are what makes them the App Store
    build's."""
    try:
        data = json.loads((composed_dir(lang, root, platform) / MANIFEST).read_text(encoding="utf-8"))
        recorded = data.get("captures")
    except (OSError, ValueError, AttributeError):
        return []
    raw = raw_dir(lang, root, platform)
    where = raw.relative_to(screenshots_dir(root).parent)
    if not isinstance(recorded, dict):
        if (root or REPO) == CHECKOUT:
            return [f"{MANIFEST} records no captures, so {where}/ cannot be checked against "
                    f"it; recompose: {platform.compositor_name} --lang {canonical_lang(lang)}"]
        return []
    out = []
    for name in raw_names(platform):
        path = raw / name
        if name not in recorded:
            out.append(f"{MANIFEST} records no capture {name}")
        elif not path.is_file():
            out.append(f"{where}/{name}: missing; {MANIFEST} records it as the capture "
                       f"its panel was composed from")
        elif md5_of(path) != recorded[name]:
            out.append(f"{where}/{name}: not the capture {MANIFEST} records (md5 "
                       f"{md5_of(path)}, recorded {recorded[name]}); recompose from it, "
                       f"or restore the recorded one")
    stray = sorted({p.name for p in raw.glob("[0-9][0-9]_*.png")} - set(raw_names(platform)))
    for name in stray:
        out.append(f"{where}/{name}: not a capture of the set; the compositor refuses "
                   f"a directory holding it")
    if platform.render_manifest:
        render = raw / platform.render_manifest
        want = data.get("render")
        if not render.is_file():
            out.append(f"{where}/{platform.render_manifest}: missing; the raws cannot be "
                       "shown to be the App Store build's without it")
        elif want != md5_of(render):
            out.append(f"{where}/{platform.render_manifest}: not the one {MANIFEST} records "
                       f"(md5 {md5_of(render)}, recorded {want})")
        out += [f"{where}/{platform.render_manifest}: {why}"
                for why in render_problems(lang, root, platform)]
    return out


def region_of(locale_id: str | None) -> str | None:
    """'MX' for 'es_MX' or 'es-MX@calendar=gregorian'; None without a region."""
    if not isinstance(locale_id, str):
        return None
    base = locale_id.split("@", 1)[0].replace("-", "_")
    last = base.rsplit("_", 1)[-1] if "_" in base else ""
    return last if len(last) == 2 and last.isalpha() and last.isupper() else None


def mac_popover_pt(render: dict, stem_: str) -> tuple[int, int]:
    """The popover's size in points for one shot, as render.json records it:
    the pinned 380x580, or a lastAligned shot's shortened height."""
    for s in render.get("shots") or []:
        if s.get("id") == stem_ and s.get("popoverHeight") is not None:
            return (MAC_POPOVER_PT[0], s["popoverHeight"])
    return MAC_POPOVER_PT


def render_problems(lang: str, root: Path | None = None, platform: Platform = MAC,
                    directory: Path | None = None) -> list[str]:
    """Why macos-raw/<lang>/ is not a store set this pipeline may compose from.

    render.json is written by the QA build's store set (QASnapshotRenderer),
    which measures the build it runs in. It must say: the store set, in this
    language, the catalogue in effect; drawn at 3x with the popover at 380x580
    points (a lastAligned shot's shorter, down to 400) and the panel 520 wide,
    settled and dark; overlay scroll bars; the language's own region
    (MAC_REGIONS); no DEVID_BUILD, no remote control; no warning, refused
    request or blank-looking render; a local usage history of Claude and
    Codex only (what the scanner records), with days and messages in it; and
    exactly these raw files, with these md5s."""
    raw = directory or raw_dir(lang, root, platform)
    path = raw / (platform.render_manifest or RENDER_MANIFEST)
    if not path.is_file():
        return [f"{path.name} is missing (render it: scripts/render_macos_qa_views.sh --set store)"]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        variant = data.get("variant") or {}
        shots_ = data.get("shots") or []
        renders = {r.get("file"): r for r in data.get("renders") or []}
    except (ValueError, AttributeError, TypeError) as exc:
        return [f"{path.name} is unreadable ({type(exc).__name__})"]
    lang = canonical_lang(lang)
    out = []

    def want(cond: bool, why: str) -> None:
        if not cond:
            out.append(why)

    want(data.get("set") == "store", f"set is {data.get('set')!r}, not the store set")
    want(data.get("language") == lang and data.get("localeOverride") == lang
         and data.get("resolvedLocalization") == lang,
         f"drawn in {data.get('language')!r} (override {data.get('localeOverride')!r}, "
         f"catalogue {data.get('resolvedLocalization')!r}), not {lang!r}")
    want(data.get("localizationActive") is True, "the catalogue was not in effect")
    want(data.get("scale") == MAC_RENDER_SCALE, f"drawn at {data.get('scale')}x, not {MAC_RENDER_SCALE}x")
    want(data.get("windowBackingScale") == MAC_RENDER_SCALE,
         f"the window's backing scale was {data.get('windowBackingScale')}, so the views "
         f"rasterized at that scale, not {MAC_RENDER_SCALE}x")
    want(data.get("warnings") == [], f"warnings: {data.get('warnings')}")
    want(data.get("blockedRequests") == [], f"refused requests: {data.get('blockedRequests')}")
    blank = sorted(f for f, r in renders.items() if r.get("suspectBlank") is not False)
    want(not blank, f"looks blank: {', '.join(str(b) for b in blank)}")
    want(variant.get("devidBuild") is False, "drawn by a build with DEVID_BUILD (the Developer ID build)")
    want(variant.get("remoteControlAvailable") is False,
         "drawn by a build offering remote control, which the Mac App Store build does not")
    want((variant.get("popoverWidth"), variant.get("popoverHeight")) == MAC_POPOVER_PT,
         f"popover {variant.get('popoverWidth')}x{variant.get('popoverHeight')} points, "
         f"not {MAC_POPOVER_PT[0]}x{MAC_POPOVER_PT[1]}")
    want(variant.get("panelWidth") == MAC_PANEL_WIDTH_PT,
         f"panel {variant.get('panelWidth')} points wide, not {MAC_PANEL_WIDTH_PT}")
    want(variant.get("panelSettled") is True, "the usage panel was still changing when drawn")
    want(variant.get("scrollerStyle") == "overlay",
         f"scroll bars were {variant.get('scrollerStyle')!r}, not 'overlay': a legacy scroller's "
         "gutter is left empty offscreen and pushes every scrolling tab off-centre")
    lum = variant.get("panelBackdropLuminance")
    want(isinstance(lum, (int, float)) and not isinstance(lum, bool)
         and 0 <= lum <= MAC_PANEL_MAX_BACKDROP_LUMINANCE,
         f"the usage panel's backdrop has luminance {lum!r}, over "
         f"{MAC_PANEL_MAX_BACKDROP_LUMINANCE}: a flat gray slab, not the dark HUD")
    region = region_of(data.get("displayLocale"))
    want(region == MAC_REGIONS.get(lang),
         f"formatted for {data.get('displayLocale')!r}, not on {lang}'s region "
         f"{MAC_REGIONS.get(lang)} (render_macos_qa_views.sh passes -AppleLocale)")
    days = variant.get("localScanDays")
    want(isinstance(days, int) and days > 0,
         "no local usage history, so the Activity card and the panel say there is none")
    providers = variant.get("localScanProviders")
    want(isinstance(providers, list) and providers and set(providers) <= LOCAL_SCAN_PROVIDERS,
         f"local usage history of {providers}: the scanner records only "
         f"{' and '.join(sorted(LOCAL_SCAN_PROVIDERS))}")
    want(isinstance(variant.get("localScanMessages"), int) and variant.get("localScanMessages") > 0,
         "the local usage history has no messages")

    ids = [s.get("id") for s in shots_]
    want(ids == stems(platform), f"shots {ids}, expected {stems(platform)}")
    for s in shots_:
        sid = s.get("id")
        files = [(s.get("file"), s.get("md5"), f"{sid}.png")]
        height = s.get("popoverHeight")
        if height is not None:
            want(s.get("page") == "lastAligned"
                 and isinstance(height, (int, float)) and not isinstance(height, bool)
                 and float(height).is_integer()
                 and MAC_POPOVER_MIN_HEIGHT_PT <= height < MAC_POPOVER_PT[1],
                 f"{sid}: popover {height!r} points high on a {s.get('page')!r} page; only a "
                 f"lastAligned page may shorten it, to whole points from "
                 f"{MAC_POPOVER_MIN_HEIGHT_PT} up to {MAC_POPOVER_PT[1]}")
        popover = (MAC_POPOVER_PT[0], int(height)) if isinstance(height, (int, float)) \
            and not isinstance(height, bool) else MAC_POPOVER_PT
        is_panel_shot = any(sid == st for st, sc in zip(stems(platform), platform.screens)
                            if sc in platform.panel_screens)
        if is_panel_shot:
            files.append((s.get("panelFile"), s.get("panelMD5"), f"{sid}.panel.png"))
        elif s.get("panelFile"):
            out.append(f"{sid}: carries a panel ({s.get('panelFile')}); only "
                       f"{', '.join(panel_raw_names(platform))} may")
        for name, md5, expected in files:
            if name != expected:
                out.append(f"{sid}: file {name!r}, expected {expected!r}")
                continue
            f = raw / name
            if not f.is_file():
                out.append(f"{name}: missing")
            elif md5_of(f) != md5:
                out.append(f"{name}: not the file the render wrote (md5 {md5_of(f)}, "
                           f"{path.name} says {md5})")
            r = renders.get(name) or {}
            if expected.endswith(".panel.png"):
                size_ok = (r.get("width") == MAC_PANEL_WIDTH_PT
                           and r.get("pixelWidth") == MAC_PANEL_WIDTH_PT * MAC_RENDER_SCALE)
            else:
                size_ok = ((r.get("width"), r.get("height")) == popover
                           and (r.get("pixelWidth"), r.get("pixelHeight"))
                           == (popover[0] * MAC_RENDER_SCALE, popover[1] * MAC_RENDER_SCALE))
            if not size_ok:
                out.append(f"{name}: drawn {r.get('width')}x{r.get('height')} points / "
                           f"{r.get('pixelWidth')}x{r.get('pixelHeight')} px")
    stray = sorted(p.name for p in raw.iterdir()
                   if not p.name.startswith(".") and p.name not in set(raw_names(platform)) | {path.name}) \
        if raw.is_dir() else []
    want(not stray, f"not part of the store set: {', '.join(stray)}")
    return out


def set_problems(lang: str, root: Path | None = None, platform: Platform = IPHONE) -> list[str]:
    """Problems with one language's composed set: every panel present and
    uploadable, nothing else in the directory that a push would skip, and
    every panel the one a clean compose run wrote (compose.json)."""
    d = composed_dir(lang, root, platform)
    if not d.is_dir():
        return [f"{d.relative_to(screenshots_dir(root).parent)}/ does not exist"]
    out = []
    expected = expected_composed(lang, root, platform)
    for p in expected:
        for why in panel_problems(p, platform):
            out.append(f"{p.name}: {why}")
    extra = sorted(p.name for p in d.glob("*.png") if p not in expected)
    for name in extra:
        out.append(f"{name}: not one of the {len(platform.screens)} panels; remove it or add its screen")
    return out + manifest_problems(lang, root, platform)


def composed_app_version(lang: str, root: Path | None = None, platform: Platform = MAC) -> str | None:
    """The app version the set's raws were drawn by, as compose.json records
    it (the Mac set: its footer reads "CLI Pulse v<version>"). None if unrecorded."""
    try:
        data = json.loads((composed_dir(lang, root, platform) / MANIFEST).read_text(encoding="utf-8"))
        return (data.get("app") or {}).get("version")
    except (OSError, ValueError, AttributeError):
        return None


def require_shots_problems(locales, root: Path | None = None,
                           platform: Platform = IPHONE) -> list[tuple[str, str]]:
    """(locale, problem) for every listing locale without a complete set, or
    whose set's raw captures are not the committed ones (capture_problems)."""
    out: list[tuple[str, str]] = []
    for loc in locales:
        if loc not in SHOT_SOURCES:
            out.append((loc, "has listing texts but no entry in SHOT_SOURCES "
                             "(scripts/appstore_screenshots.py); map it to a language or FALLBACK"))
            continue
        lang = SHOT_SOURCES[loc]
        if lang is FALLBACK:
            continue
        out.extend((loc, f"{lang}: {why}")
                   for why in set_problems(lang, root, platform) + capture_problems(lang, root, platform))
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
    failed = False
    for plat in PLATFORMS.values():
        problems = require_shots_problems(listing.LOCALE_SOURCES, platform=plat)
        print(f"{plat.name} ({plat.display_type}):")
        for loc, lang in SHOT_SOURCES.items():
            print(f"  {loc:8} -> {lang or 'FALLBACK (en-US panels)'}")
        for loc, why in problems:
            print(f"FAIL  [{loc}] {why}")
        failed |= bool(problems)
    sys.exit(1 if failed else 0)

#!/usr/bin/env python3
"""What the App Store screenshot compositors share: captions and publishing.

Two compositors draw marketing panels from raw renders, one per platform:

  compose_appstore_ios_screenshots.py     iPhone, 1290x2796 (APP_IPHONE_67)
  compose_appstore_macos_screenshots.py   Mac, 2880x1800 (APP_DESKTOP)

Each keeps its own caption table (COPY), canvas and framing. Everything that
decides whether a caption is drawn right lives here, once, so a fix to one
reaches both:

  * line breaking: kinsoku in Chinese and Japanese, spaces in Korean and
    Spanish, never inside "CLI Pulse" or a Latin word, U+200B as a preferred
    break (wrap);
  * fonts: a face per language and role, checked glyph by glyph against its
    own .notdef box, and for Chinese against the other region's shapes
    (pick_faces, has_glyph, regional_problem);
  * the caption block: one title size and one subtitle size per set, the
    headline pinned to the same height on every panel whatever its
    subtitle's line count (Layout, set_sizes, caption_layout);
  * publishing: a set is swapped in whole, with its compose.json, only when
    every panel passed; a failing run withdraws the earlier set's compose.json
    and leaves its own panels in <out>.rejected/ (publish_set, withdraw_set).

Why each of those rules exists is in the iPhone compositor's docstring; the
iPhone sets committed before this module existed recompose byte-identically
through it (scripts/test_appstore_screenshots.py).

Pure text layout (wrap, caption_layout) needs no Pillow, so CI runs its tests
on a bare runner.
"""

from __future__ import annotations

import functools
import glob
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # the pure text-layout functions below work without Pillow
    Image = ImageDraw = ImageFont = None

ZWSP = "\u200b"

Copy = dict[str, dict[str, tuple[str, str]]]

# ── line breaking (pure; tested without Pillow) ──────────────────────────────

CJK_LANGS = frozenset({"zh-Hans", "zh-Hant", "ja"})

# Kinsoku shori: what a line may not start with, and may not end with.
NO_LINE_START = frozenset(
    "、。，．,.・：；:;！？!?）)」』】〕〉》〙〛]｝}ー々〻ゝゞヽヾ〜～…‥%％"
    "ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ")
NO_LINE_END = frozenset("（(「『【〔〈《〘〚[｛{")
# A break right after one of these reads as a pause, not a cut.
PREFERRED_AFTER = frozenset("、，。・：；！？,;:—")
# Never split, in any language.
NO_BREAK_PHRASES = ("CLI Pulse", "Apple Watch")


def _protected(text: str) -> set[int]:
    """Break positions (between text[i-1] and text[i]) that would split a
    Latin word or a no-break phrase."""
    out: set[int] = set()
    for phrase in NO_BREAK_PHRASES:
        start = text.find(phrase)
        while start != -1:
            out.update(range(start + 1, start + len(phrase)))
            start = text.find(phrase, start + 1)
    for i in range(1, len(text)):
        a, b = text[i - 1], text[i]
        if a.isascii() and b.isascii() and (a.isalnum() or a in "'-") and (b.isalnum() or b in "'-"):
            out.add(i)
    return out


def break_candidates(text: str, lang: str) -> list[tuple[int, int, bool]]:
    """(cut_start, cut_end, preferred): line 1 is text[:cut_start], line 2
    text[cut_end:]. A space or U+200B at the break is dropped. Kinsoku is
    applied here for breaks between characters, and again by `legal` for
    breaks at a space (whose neighbours are only known once it is dropped)."""
    protected = _protected(text)
    out = []
    for i, ch in enumerate(text):
        if ch == ZWSP:
            out.append((i, i + 1, True))
        elif ch == " ":
            if i in protected or (i + 1) in protected:
                continue
            prev = text[:i].rstrip()
            out.append((i, i + 1, bool(prev) and prev[-1] in PREFERRED_AFTER))
        elif lang in CJK_LANGS and i > 0 and i not in protected \
                and text[i - 1] not in (" ", ZWSP) \
                and ch not in NO_LINE_START and text[i - 1] not in NO_LINE_END:
            out.append((i, i, text[i - 1] in PREFERRED_AFTER))
    return out


def _lines(text: str, cut: tuple[int, int, bool]) -> tuple[str, str]:
    a = text[:cut[0]].replace(ZWSP, "").rstrip()
    b = text[cut[1]:].replace(ZWSP, "").lstrip()
    return a, b


def legal(a: str, b: str) -> bool:
    return bool(a) and bool(b) and a[-1] not in NO_LINE_END and b[0] not in NO_LINE_START


def wrap(text: str, lang: str, width_of, max_w: float, max_lines: int = 2,
         one_line_w: float | None = None) -> list[str] | None:
    """At most `max_lines` (1 or 2) lines of `text` that each fit `max_w`, or
    None. One line if it fits `one_line_w` (default `max_w`); otherwise the most
    balanced legal break, preferring one after punctuation or at a U+200B."""
    whole = text.replace(ZWSP, "")
    if width_of(whole) <= (max_w if one_line_w is None else one_line_w):
        return [whole]
    if max_lines < 2:
        return None
    # A break that is not after punctuation costs this much imbalance: a lot
    # in Chinese and Japanese, where it cuts a word, less where it falls
    # between two words anyway. So "Alerts for quota, / CPU spikes and long-
    # running sessions" loses to a balanced break, and 、 still wins in Chinese.
    penalty = max_w * (0.5 if lang in CJK_LANGS else 0.2)
    options = []
    for cut in break_candidates(text, lang):
        a, b = _lines(text, cut)
        if not legal(a, b):
            continue
        wa, wb = width_of(a), width_of(b)
        if wa <= max_w and wb <= max_w:
            options.append((abs(wa - wb) + (0 if cut[2] else penalty), [a, b]))
    return min(options)[1] if options else None


# ── fonts ────────────────────────────────────────────────────────────────────

PINGFANG = "/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*.asset/AssetData/PingFang.ttc"


@dataclass(frozen=True)
class Face:
    path: str                 # a file, or a glob (PingFang is a downloaded asset)
    family: str | None = None  # face inside a .ttc, matched by name
    style: str | None = None
    weight: int | None = None  # for a variable font (SF): the Weight axis


SF = "/System/Library/Fonts/SFNS.ttf"
HEITI = "/System/Library/Fonts/STHeiti Medium.ttc"
HIRAGINO_W6 = "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
HIRAGINO_W3 = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"
SD_GOTHIC = "/System/Library/Fonts/AppleSDGothicNeo.ttc"

# Most preferred first; the first face that can draw every character of the
# language's captions (and, for Chinese, in its own region's shapes; see
# REGIONAL_PROBES) wins. One table for both compositors: the same language
# looks the same on the iPhone panels and the Mac ones.
FACES: dict[str, dict[str, list[Face]]] = {
    "en": {"title": [Face(SF, weight=600)], "subtitle": [Face(SF, weight=400)]},
    "es": {"title": [Face(SF, weight=600)], "subtitle": [Face(SF, weight=400)]},
    "zh-Hans": {
        "title": [Face(PINGFANG, "PingFang SC", "Semibold"), Face(HEITI, "Heiti SC", "Medium")],
        "subtitle": [Face(PINGFANG, "PingFang SC", "Regular"), Face(HEITI, "Heiti SC", "Medium")],
    },
    "zh-Hant": {
        "title": [Face(PINGFANG, "PingFang TC", "Semibold"), Face(HEITI, "Heiti TC", "Medium")],
        "subtitle": [Face(PINGFANG, "PingFang TC", "Regular"), Face(HEITI, "Heiti TC", "Medium")],
    },
    "ja": {
        "title": [Face(HIRAGINO_W6, "Hiragino Sans", "W6")],
        "subtitle": [Face(HIRAGINO_W3, "Hiragino Sans", "W3")],
    },
    "ko": {
        "title": [Face(SD_GOTHIC, "Apple SD Gothic Neo", "SemiBold")],
        "subtitle": [Face(SD_GOTHIC, "Apple SD Gothic Neo", "Regular")],
    },
}

# A character each language's faces MUST draw, beyond its captions: one of the
# script (Simplified 额, Traditional 臺, kana, Hangul, Spanish ñ and ¿). The
# check runs on the captions too; this keeps it honest when a caption happens
# to use only shared characters. It is a COVERAGE probe only: PingFang SC draws
# 臺 too, in the same shape as PingFang TC, so it cannot tell the regions apart.
PROBES = {"en": "A", "es": "ñ¿", "zh-Hans": "额", "zh-Hant": "臺說", "ja": "あア", "ko": "한"}

# What does tell them apart: a character both regions write, in two shapes.
# 說 (兌 in Taiwan, 兑 on the Mainland) is drawn differently by PingFang SC and
# TC and by Heiti SC and TC; 臺 is not (measured). The face chosen for one
# region must draw it unlike every face of the other region's candidates that
# is on this machine, so a Mainland face cannot pass for a Taiwan one, or the
# reverse, just because it has the glyph.
REGIONAL_PROBES: dict[str, tuple[str, str]] = {"zh-Hant": ("說", "zh-Hans"),
                                               "zh-Hans": ("說", "zh-Hant")}

# An unassigned codepoint, so every font renders it as .notdef.
NOTDEF_PROBE = "\U000f0000"


def require_pillow() -> None:
    if ImageFont is None:
        raise SystemExit("Pillow is required to compose: pip install pillow")


def has_glyph(font, ch: str) -> bool:
    """Whether `font` has a real glyph for `ch`, rather than the .notdef box.

    The obvious test — `font.getbbox(ch)[2] > 0` — is a TAUTOLOGY: a font
    missing the character still reports a positive width, because what it
    measures is the substituted .notdef glyph (the box you see as "tofu").
    Rendering an unassigned codepoint shows what .notdef looks like in THIS
    font; a character whose bitmap differs from it is genuinely present.
    """
    try:
        real, notdef = _bitmap(font, ch), _bitmap(font, NOTDEF_PROBE)
    except Exception:
        return False
    return any(real) and real != notdef


def _bitmap(font, ch: str) -> bytes:
    img = Image.new("L", (160, 160), 0)
    ImageDraw.Draw(img).text((16, 16), ch, font=font, fill=255)
    return img.tobytes()


def regional_problem(lang: str, role: str, face: Face) -> str | None:
    """Why `face` does not draw `lang`'s regional forms, or None. Only Chinese
    has a probe; see REGIONAL_PROBES."""
    if lang not in REGIONAL_PROBES:
        return None
    ch, other = REGIONAL_PROBES[lang]
    mine = _bitmap(load_face(face, 64), ch)
    others = [f for f in FACES[other][role] if load_face(f, 64) is not None]
    if not others:
        return (f"cannot tell whether {face.family or face.path} draws {lang}'s shapes: "
                f"no {other} face on this machine to compare {ch} with")
    same = [f.family or f.path for f in others if _bitmap(load_face(f, 64), ch) == mine]
    if same:
        return (f"{face.family or face.path} draws {ch} exactly like {', '.join(same)} ({other}): "
                f"it has the glyph, in the other region's shape")
    return None


def _paths(face: Face) -> list[str]:
    return sorted(glob.glob(face.path)) if any(c in face.path for c in "*?[") else [face.path]


@functools.lru_cache(maxsize=None)
def load_face(face: Face, size: int):
    """The FreeTypeFont for `face` at `size`, or None if this machine lacks it."""
    for path in _paths(face):
        if not Path(path).exists():
            continue
        for index in range(0, 64):
            try:
                font = ImageFont.truetype(path, size, index=index)
            except OSError:
                break
            family, style = font.getname()
            if face.family and (family, style) != (face.family, face.style):
                continue
            if face.weight is not None:
                axes = font.get_variation_axes()
                values = []
                for axis in axes:
                    name = axis["name"].decode() if isinstance(axis["name"], bytes) else axis["name"]
                    if name == "Weight":
                        values.append(face.weight)
                    elif name == "Optical Size":
                        # What Apple's text engine does on its own: display
                        # sizes get the tighter display design.
                        values.append(max(axis["minimum"], min(axis["maximum"], size)))
                    else:
                        values.append(axis["default"])
                font.set_variation_by_axes(values)
            return font
    return None


def caption_chars(copy: Copy, lang: str) -> str:
    text = "".join(t + s for t, s in copy[lang].values()) + PROBES[lang]
    return "".join(sorted({c for c in text if not c.isspace() and c != ZWSP}))


def pick_faces(copy: Copy, lang: str) -> tuple[dict[str, Face], list[str]]:
    """{role: face} of the first face per role that draws every character of
    this language's captions, and the problems if a role has none."""
    require_pillow()
    chosen: dict[str, Face] = {}
    problems: list[str] = []
    chars = caption_chars(copy, lang)
    for role, candidates in FACES[lang].items():
        tried = []
        for face in candidates:
            font = load_face(face, 64)
            if font is None:
                tried.append(f"{face.family or Path(face.path).name}: not on this machine")
                continue
            missing = [c for c in chars if not has_glyph(font, c)]
            if missing:
                tried.append(f"{face.family or Path(face.path).name}: cannot draw {''.join(missing[:12])!r}")
                continue
            wrong_region = regional_problem(lang, role, face)
            if wrong_region:
                tried.append(wrong_region)
                continue
            chosen[role] = face
            break
        else:
            problems.append(f"{lang} {role}: no font can draw its captions ({'; '.join(tried)})")
    return chosen, problems


def face_name(face: Face) -> str:
    return face.family or Path(face.path).stem


# ── the caption block ────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Layout:
    """A compositor's canvas and caption metrics, in canvas pixels."""
    canvas_w: int
    canvas_h: int
    title_size_max: int = 100
    title_size_min: int = 58
    sub_size_max: int = 46
    sub_size_min: int = 30
    sub_max_lines: int = 2
    line_box: float = 1.25          # line height, in ems
    text_top_margin: int = 140
    title_to_sub_gap: int = 10
    sub_line_gap: int = 0
    text_to_shot_gap: int = 70
    text_side_margin: int = 70
    # Wider than this share of the text width, a one-line subtitle reads as a
    # strip across the panel, and is wrapped instead.
    sub_one_line_share: float = 0.86

    @property
    def text_w(self) -> int:
        return self.canvas_w - self.text_side_margin * 2

    @property
    def sub_one_line_w(self) -> int:
        return int(self.text_w * self.sub_one_line_share)


def make_vertical_gradient(w: int, h: int, top, bot):
    small = Image.new("RGB", (1, 2))
    small.putpixel((0, 0), top)
    small.putpixel((0, 1), bot)
    return small.resize((w, h), Image.BICUBIC)


def line_height(layout: Layout, font) -> int:
    """The line box: a fixed multiple of the type size, the same in every
    language. Not the ink, which moves a subtitle up under a title without
    descenders; and not the font's own ascent + descent, which is 1.0 em in
    Hiragino and 1.4 em in PingFang, so Japanese captions came out cramped and
    Chinese ones loose."""
    return round(font.size * layout.line_box)


# Full-width marks whose ink sits at the left of their em. At the end of a line
# the empty right part is not part of the line anyone sees.
TRAILING_BLANK_PUNCT = frozenset("、。，．")


def centering_width(text: str, font) -> float:
    """The width to centre `text` on: its advance, less the blank right part of
    a trailing full-width 、 or 。. Centring the advance put a line ending in
    、 about half an em left of the line under it."""
    width = font.getlength(text)
    if text and text[-1] in TRAILING_BLANK_PUNCT:
        width -= trailing_blank(font, text[-1])
    return width


def trailing_blank(font, ch: str) -> float:
    """The blank part of `ch`'s advance to the right of its ink. Measured on a
    rendering: Pillow's getbbox reports these marks' advance box, not ink."""
    size = int(font.size * 3)
    x0 = font.size
    img = Image.new("L", (size, size), 0)
    ImageDraw.Draw(img).text((x0, font.size * 2), ch, font=font, fill=255, anchor="ls")
    ink = img.getbbox()
    if ink is None:
        return 0.0
    return max(0.0, font.getlength(ch) - (ink[2] - x0))


def draw_centered(layout: Layout, draw, y, text, font, color) -> int:
    """Draw one centred line whose box starts at `y`; return where it ends."""
    ascent, descent = font.getmetrics()
    box = line_height(layout, font)
    baseline = y + (box - (ascent + descent)) / 2 + ascent
    x = (layout.canvas_w - centering_width(text, font)) / 2
    draw.text((x, baseline), text, font=font, fill=color, anchor="ls")
    return y + box


def rounded_corners(img, radius: int):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([(0, 0), img.size], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def title_size(layout: Layout, title: str, face: Face) -> int | None:
    """The largest size at which the title fits one line."""
    for size in range(layout.title_size_max, layout.title_size_min - 1, -2):
        if load_face(face, size).getlength(title) <= layout.text_w:
            return size
    return None


def subtitle_lines(layout: Layout, subtitle: str, lang: str, face: Face,
                   size: int) -> list[str] | None:
    """The subtitle at `size`: one line if it is comfortably narrower than the
    panel, else two that each fit. A line that only just fits runs from edge to
    edge and reads as a strip, so it is wrapped instead."""
    font = load_face(face, size)
    return wrap(subtitle, lang, font.getlength, layout.text_w, layout.sub_max_lines,
                one_line_w=layout.sub_one_line_w)


def subtitle_size(layout: Layout, subtitle: str, lang: str, face: Face) -> int | None:
    for size in range(layout.sub_size_max, layout.sub_size_min - 1, -2):
        if subtitle_lines(layout, subtitle, lang, face, size):
            return size
    return None


def set_sub_lines(layout: Layout, copy: Copy, lang: str, faces: dict[str, Face],
                  stems_: list[str], s_size: int) -> int:
    """How many subtitle lines the set's tallest caption takes. Every panel
    reserves that much, so the screenshot sits at the same place and size on
    each."""
    return max(len(subtitle_lines(layout, copy[lang][st][1], lang, faces["subtitle"], s_size) or [""])
               for st in stems_)


@dataclass(frozen=True)
class CaptionLayout:
    title_y: int                # top of the title's line box
    sub_ys: tuple[int, ...]     # top of each subtitle line's box
    shot_top: int               # where the space for the screenshot starts


def caption_layout(layout: Layout, title_box: int, sub_box: int, sub_lines: int,
                   reserved_lines: int) -> CaptionLayout:
    """Where one panel's caption and screenshot go, from its line boxes (pure;
    tested without Pillow). `reserved_lines` is the set's tallest subtitle
    (set_sub_lines), and every panel reserves room for that many lines.

    The headline is pinned to the top of that room, the subtitle follows
    directly under it, and whatever a shorter subtitle leaves over stays empty
    below it, so the headline sits at the same height on every panel of the
    set. The screenshot's place depends only on the room."""
    reserved_lines = max(reserved_lines, sub_lines)
    title_y = layout.text_top_margin
    first_sub = title_y + title_box + layout.title_to_sub_gap
    sub_ys = tuple(first_sub + i * (sub_box + layout.sub_line_gap) for i in range(sub_lines))
    room = (title_box + layout.title_to_sub_gap
            + reserved_lines * sub_box + (reserved_lines - 1) * layout.sub_line_gap)
    return CaptionLayout(title_y, sub_ys, layout.text_top_margin + room + layout.text_to_shot_gap)


def set_sizes(layout: Layout, copy: Copy, lang: str, faces: dict[str, Face],
              stems_: list[str]) -> tuple[int, int, list[str]]:
    """One title size and one subtitle size for the whole set, the largest at
    which every caption fits: a carousel whose panels change type size from
    one swipe to the next looks unfinished. Also the captions that fit nowhere."""
    problems = []
    t_sizes, s_sizes = [], []
    for st in stems_:
        title, subtitle = copy[lang][st]
        t = title_size(layout, title, faces["title"])
        s = subtitle_size(layout, subtitle, lang, faces["subtitle"])
        if t is None:
            problems.append(f"{st}: title does not fit one line at {layout.title_size_min}pt: {title!r}")
        if s is None:
            problems.append(f"{st}: subtitle does not fit {layout.sub_max_lines} lines at "
                            f"{layout.sub_size_min}pt: {subtitle!r}")
        t_sizes.append(t or layout.title_size_min)
        s_sizes.append(s or layout.sub_size_min)
    return min(t_sizes), min(s_sizes), problems


# ── publishing a set ─────────────────────────────────────────────────────────

def rejected_dir(out_dir: Path) -> Path:
    """Where a failing run leaves its panels, next to `out_dir`, for a look."""
    return out_dir.with_name(out_dir.name + ".rejected")


def withdraw_set(out_dir: Path, manifest_name: str) -> None:
    """A run for this set failed: whatever an earlier run left in `out_dir` is
    no longer what the captions and captures say, so it must not be pushed.
    Removing compose.json is what set_problems (and so the pusher) refuses."""
    manifest = out_dir / manifest_name
    if manifest.exists():
        manifest.unlink()
        print(f"  {out_dir}: removed {manifest_name}; the panels there are an earlier "
              "run's and will not be pushed")


def publish_set(staging: Path, out_dir: Path, write_manifest: Callable[[Path], None]) -> None:
    """Swap a set that passed every check into `out_dir`, whole: the manifest
    first (inside staging), then one rename. The set that was there goes."""
    write_manifest(staging)
    staging.chmod(0o755)   # mkdtemp makes it 0700
    previous = out_dir.with_name(f".{out_dir.name}.previous")
    shutil.rmtree(previous, ignore_errors=True)
    if out_dir.exists():
        out_dir.rename(previous)
    staging.rename(out_dir)
    shutil.rmtree(previous, ignore_errors=True)
    shutil.rmtree(rejected_dir(out_dir), ignore_errors=True)

#!/usr/bin/env python3
"""Composite iPhone screenshots onto ASC-compliant 1290x2796 marketing panels.

Dark navy gradient background, white title + grey subtitle at the top, the
device screenshot centred below with rounded corners (the capture has no device
chrome, so it gets a corner radius instead of looking like a bare bitmap).

Six languages: en, zh-Hans, zh-Hant, ja, ko, es. Where their files live and
which App Store locale shows which set is scripts/appstore_screenshots.py.

Usage:
    compose_appstore_ios_screenshots.py --lang ja        # ios-raw/ja -> ios-composed/ja
    compose_appstore_ios_screenshots.py --all            # every language
    compose_appstore_ios_screenshots.py --lang en --in DIR --out DIR
    compose_appstore_ios_screenshots.py --check-fonts    # glyph coverage only

(`--locale` is the old name of `--lang`, and `zh` of `zh-Hans`.)

Exit 1 if any caption does not fit or any character would render as tofu.
The output directory then keeps no set a push would accept (see 5).

Five things this script learned the hard way, each of which silently produces a
listing you would not ship:

1. TEXT THAT DOES NOT FIT IS NOT A LAYOUT PROBLEM, IT IS A CROPPED SENTENCE.
   The first version drew title and subtitle at a fixed 100/44pt and printed
   "OK" while long captions ran off both edges. Titles now shrink to fit one
   line, subtitles wrap to at most two lines before shrinking, and whatever
   still does not fit fails the run.

2. A FONT WITHOUT THE GLYPH DRAWS A BOX, AND SAYS NOTHING.
   SFNS.ttf has no CJK. Each language names its faces by family and style, and
   every character of every caption is checked against the chosen face by
   comparing its bitmap with that face's .notdef box. Measuring a width is not
   a check: the box has a width too (see has_glyph).

   A GLYPH IN THE OTHER REGION'S SHAPE IS NOT A BOX, AND PASSES THAT CHECK.
   PingFang SC has a glyph for every Traditional character tried, 臺 included,
   drawn pixel for pixel like PingFang TC's. So coverage cannot tell an SC face
   from a TC one; REGIONAL_PROBES can: 說 is drawn differently in the two, and
   the chosen Chinese face must draw it unlike every face of the other region.

3. A LINE MAY NOT START WITH 。 OR 」, NOR BREAK "CLI Pulse" IN TWO.
   Chinese and Japanese wrap between any two characters except where kinsoku
   forbids it (no line starting with closing punctuation or a small kana, none
   ending with an opening bracket), and never inside a Latin word or a brand
   name. Korean and Spanish wrap only at spaces. Breaks after a comma or 、 are
   preferred, and an invisible U+200B in a caption marks a preferred break.
   A line ending in a full-width 、 or 。 is centred on its ink: the mark sits
   in the left half of its em, so centring the advance width pushed the
   visible line about half an em left of the one under it.

4. A CAPTION IS A CLAIM. The copy below says only what the screen under it
   shows. The macOS App Store build cannot do remote control and the listing
   does not sell it (scripts/appstore_listing.py), so neither does a caption,
   although the iPhone's Overview shows the Remote Control row.

5. A FAILED RUN MUST NOT LEAVE A SET THAT LOOKS UPLOADABLE.
   The pusher checks what a PNG is (size, colour type), not what is drawn on
   it, so a panel with a cut-off caption passed it. A run now composes into a
   staging directory and swaps the whole set into the output directory only
   when every panel passed, together with compose.json (file name -> md5 of
   each panel). A failing run leaves its panels in <out>.rejected/ to be
   looked at, and deletes compose.json from <out>, so the set a previous run
   left there cannot be pushed as if it were this run's: set_problems in
   scripts/appstore_screenshots.py, which the pusher and --require-shots use,
   refuses a set without compose.json or with a panel it does not list.
"""

from __future__ import annotations

import argparse
import functools
import glob
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # the pure text-layout functions below work without Pillow
    Image = ImageDraw = ImageFont = None

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent.parent / "scripts"))
import appstore_screenshots as shots  # noqa: E402

CANVAS_W, CANVAS_H = shots.CANVAS

BG_TOP = (16, 20, 42)
BG_BOTTOM = (8, 10, 22)

TITLE_COLOR = (255, 255, 255)
SUBTITLE_COLOR = (175, 182, 200)

TITLE_SIZE_MAX, TITLE_SIZE_MIN = 100, 58
SUB_SIZE_MAX, SUB_SIZE_MIN = 46, 30
SUB_MAX_LINES = 2
LINE_BOX = 1.25   # line height, in ems

TEXT_TOP_MARGIN = 140
TITLE_TO_SUB_GAP = 10
SUB_LINE_GAP = 0
TEXT_TO_SHOT_GAP = 70
SIDE_MARGIN = 80
TEXT_SIDE_MARGIN = 70
# The phone's corners, as a share of the scaled capture's width. Captures are
# taken with the display mask rendered black (so the Dynamic Island is always
# there, not only when SpringBoard happens to be drawing it), which also
# blackens the display's own corners, about 200 px of 1320. This radius is the
# smallest circle that clips all of that away; check_corners() fails the panel
# if any black is left.
SHOT_CORNER_RATIO = 0.16
TEXT_W = CANVAS_W - TEXT_SIDE_MARGIN * 2
# Wider than this, a one-line subtitle reads as a strip across the panel.
SUB_ONE_LINE_W = int(TEXT_W * 0.86)

ZWSP = "\u200b"

# ── captions ─────────────────────────────────────────────────────────────────
# (title, subtitle) per screen. Written against the screen each sits on (the
# Demo data: Codex/Gemini/Claude, estimated costs, a weekly quota at 92%, CPU
# and long-running-session alerts) and the app's own words for things: the
# tab names, 配额/配額/クォータ/할당량/cuota, 告警/警示/アラート/알림/alertas,
# 会话/工作階段/セッション/세션/sesiones, "costo" in Spanish.
COPY: dict[str, dict[str, tuple[str, str]]] = {
    "en": {
        "01_overview": ("Everything at a glance",
                        "Usage, cost, sessions and alerts, all on one screen"),
        "02_providers": ("Live quotas and costs",
                         "See what’s left before you hit the wall"),
        "03_cost": ("Where the money goes",
                    "Per-provider cost, top projects and risk signals"),
        "04_sessions": ("Every CLI run tracked",
                        "Active sessions with usage, cost and requests"),
        "05_alerts": ("Never miss a limit",
                      "Quota, CPU spike and long-running session alerts"),
    },
    "zh-Hans": {
        "01_overview": ("关键数据，一屏总览", "用量、费用、会话和告警，打开就能看到"),
        "02_providers": ("实时掌握配额与费用", "离上限还有多远，一眼就知道"),
        "03_cost": ("钱都花在了哪里", "按服务商细分的费用、主要项目和风险信号"),
        "04_sessions": ("每个会话都有账可查", "活跃会话的用量、费用和请求数"),
        "05_alerts": ("配额不再突然见底", "配额将尽、CPU 过高、会话过久，都会告警"),
    },
    "zh-Hant": {
        "01_overview": ("一眼掌握全局", "用量、費用、工作階段與警示，一頁看完"),
        "02_providers": ("即時查看配額與費用", "用完之前，就知道還剩多少"),
        "03_cost": ("錢花在哪裡", "各服務商的費用、高用量專案與風險訊號"),
        "04_sessions": ("每次 CLI 執行都有紀錄", "活躍工作階段的用量、費用與請求數"),
        "05_alerts": ("配額不再突然見底", "配額將盡、CPU 使用率過高、工作階段執行過久，都會發出警示"),
    },
    "ja": {
        "01_overview": ("すべてをひと目で", "使用量、コスト、セッション、アラートを\u200bひとつの画面に"),
        "02_providers": ("クォータとコストを把握", "上限に達する前に、\u200b残りがわかる"),
        "03_cost": ("コストの内訳がわかる", "プロバイダー別のコスト、\u200b上位プロジェクト、\u200bリスクシグナル"),
        "04_sessions": ("CLI の実行をすべて記録", "アクティブなセッションの\u200b使用量、コスト、リクエスト数"),
        "05_alerts": ("上限の接近を見逃さない", "クォータ残量の低下、CPU の高負荷、\u200b長時間実行中のセッションを通知"),
    },
    "ko": {
        "01_overview": ("모든 것을 한눈에", "사용량, 비용, 세션, 알림을 한 화면에서"),
        "02_providers": ("실시간 할당량과 비용", "한도까지 얼마나 남았는지 바로 확인하세요"),
        "03_cost": ("비용, 어디에 쓰이나요?", "공급자별 비용, 상위 프로젝트, 위험 신호"),
        "04_sessions": ("모든 CLI 실행을 기록", "활성 세션의 사용량, 비용, 요청 수"),
        "05_alerts": ("할당량이 바닥나기 전에", "CPU 사용률 급증과 오래 실행 중인 세션도 알려 드려요"),
    },
    "es": {
        "01_overview": ("Todo de un vistazo",
                        "Uso, costos, sesiones y alertas en una sola pantalla"),
        "02_providers": ("Cuotas y costos en vivo",
                         "Consulta cuánto te queda antes de llegar al límite"),
        "03_cost": ("En qué se va tu dinero",
                    "Costo por proveedor y proyecto, con señales de riesgo"),
        "04_sessions": ("Cada ejecución, registrada",
                        "Sesiones activas con su uso, costo y solicitudes"),
        "05_alerts": ("Sin sorpresas con la cuota",
                      "Alertas de cuota, picos de CPU y sesiones de larga duración"),
    },
}

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
# REGIONAL_PROBES) wins.
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


def _require_pillow() -> None:
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


def caption_chars(lang: str) -> str:
    text = "".join(t + s for t, s in COPY[lang].values()) + PROBES[lang]
    return "".join(sorted({c for c in text if not c.isspace() and c != ZWSP}))


def pick_faces(lang: str) -> tuple[dict[str, Face], list[str]]:
    """{role: face} of the first face per role that draws every character of
    this language's captions, and the problems if a role has none."""
    _require_pillow()
    chosen: dict[str, Face] = {}
    problems: list[str] = []
    chars = caption_chars(lang)
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


# ── composing ────────────────────────────────────────────────────────────────

def make_vertical_gradient(w: int, h: int, top, bot):
    small = Image.new("RGB", (1, 2))
    small.putpixel((0, 0), top)
    small.putpixel((0, 1), bot)
    return small.resize((w, h), Image.BICUBIC)


def line_height(font) -> int:
    """The line box: a fixed multiple of the type size, the same in every
    language. Not the ink, which moves a subtitle up under a title without
    descenders; and not the font's own ascent + descent, which is 1.0 em in
    Hiragino and 1.4 em in PingFang, so Japanese captions came out cramped and
    Chinese ones loose."""
    return round(font.size * LINE_BOX)


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


def draw_centered(draw, y, text, font, color) -> int:
    """Draw one centred line whose box starts at `y`; return where it ends."""
    ascent, descent = font.getmetrics()
    box = line_height(font)
    baseline = y + (box - (ascent + descent)) / 2 + ascent
    x = (CANVAS_W - centering_width(text, font)) / 2
    draw.text((x, baseline), text, font=font, fill=color, anchor="ls")
    return y + box


def rounded_corners(img, radius: int):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([(0, 0), img.size], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def title_size(title: str, face: Face) -> int | None:
    """The largest size at which the title fits one line."""
    for size in range(TITLE_SIZE_MAX, TITLE_SIZE_MIN - 1, -2):
        if load_face(face, size).getlength(title) <= TEXT_W:
            return size
    return None


def subtitle_lines(subtitle: str, lang: str, face: Face, size: int) -> list[str] | None:
    """The subtitle at `size`: one line if it is comfortably narrower than the
    panel, else two that each fit. A line that only just fits runs from edge to
    edge and reads as a strip, so it is wrapped instead."""
    font = load_face(face, size)
    return wrap(subtitle, lang, font.getlength, TEXT_W, SUB_MAX_LINES, one_line_w=SUB_ONE_LINE_W)


def subtitle_size(subtitle: str, lang: str, face: Face) -> int | None:
    for size in range(SUB_SIZE_MAX, SUB_SIZE_MIN - 1, -2):
        if subtitle_lines(subtitle, lang, face, size):
            return size
    return None


def set_sub_lines(lang: str, faces: dict[str, Face], stems_: list[str], s_size: int) -> int:
    """How many subtitle lines the set's tallest caption takes. Every panel
    reserves that much, so the phone sits at the same place and size on each."""
    return max(len(subtitle_lines(COPY[lang][st][1], lang, faces["subtitle"], s_size) or [""])
               for st in stems_)


def set_sizes(lang: str, faces: dict[str, Face], stems_: list[str]) -> tuple[int, int, list[str]]:
    """One title size and one subtitle size for the whole set, the largest at
    which every caption fits: a carousel whose panels change type size from
    one swipe to the next looks unfinished. Also the captions that fit nowhere."""
    problems = []
    t_sizes, s_sizes = [], []
    for st in stems_:
        title, subtitle = COPY[lang][st]
        t = title_size(title, faces["title"])
        s = subtitle_size(subtitle, lang, faces["subtitle"])
        if t is None:
            problems.append(f"{st}: title does not fit one line at {TITLE_SIZE_MIN}pt: {title!r}")
        if s is None:
            problems.append(f"{st}: subtitle does not fit {SUB_MAX_LINES} lines at "
                            f"{SUB_SIZE_MIN}pt: {subtitle!r}")
        t_sizes.append(t or TITLE_SIZE_MIN)
        s_sizes.append(s or SUB_SIZE_MIN)
    return min(t_sizes), min(s_sizes), problems


def check_corners(canvas, origin, size, radius) -> list[str]:
    """The display mask must not show at the phone's corners: just inside the
    rounded clip, on each corner's diagonal, the pixel is screen content, never
    the black of the capture's mask."""
    x0, y0 = origin
    w, h = size
    d = int(radius * (1 - 2 ** -0.5)) + 3
    points = {"top-left": (x0 + d, y0 + d), "top-right": (x0 + w - 1 - d, y0 + d),
              "bottom-left": (x0 + d, y0 + h - 1 - d),
              "bottom-right": (x0 + w - 1 - d, y0 + h - 1 - d)}
    out = []
    for name, xy in points.items():
        r, g, b = canvas.getpixel(xy)[:3]
        if max(r, g, b) < 24:
            out.append(f"black device mask shows at the {name} corner; raise SHOT_CORNER_RATIO")
    return out


def compose_one(src: Path, dst: Path, lang: str, faces: dict[str, Face],
                t_size: int, s_size: int, reserved_lines: int) -> list[str]:
    """Write one panel; return why it is not fit to upload (empty = fine)."""
    title, subtitle = COPY[lang][src.stem]
    problems = []

    canvas = make_vertical_gradient(CANVAS_W, CANVAS_H, BG_TOP, BG_BOTTOM).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    title_font = load_face(faces["title"], t_size)
    sub_font = load_face(faces["subtitle"], s_size)
    if title_font.getlength(title) > TEXT_W:
        problems.append(f"title overflows at {t_size}pt: {title!r}")
    sub_lines = subtitle_lines(subtitle, lang, faces["subtitle"], s_size)
    if sub_lines is None:
        problems.append(f"subtitle overflows at {s_size}pt: {subtitle!r}")
        sub_lines = [subtitle.replace(ZWSP, "")]

    def block(lines: int) -> int:
        return (line_height(title_font) + TITLE_TO_SUB_GAP
                + lines * line_height(sub_font) + (lines - 1) * SUB_LINE_GAP)

    # The text is centred in a block as tall as the set's tallest caption, so
    # the phone below starts at the same height on every panel of the set.
    reserved = block(max(reserved_lines, len(sub_lines)))
    y = TEXT_TOP_MARGIN + (reserved - block(len(sub_lines))) // 2
    y = draw_centered(draw, y, title, title_font, TITLE_COLOR)
    y += TITLE_TO_SUB_GAP
    for i, line in enumerate(sub_lines):
        y = draw_centered(draw, y, line, sub_font, SUBTITLE_COLOR)
        if i != len(sub_lines) - 1:
            y += SUB_LINE_GAP

    shot = Image.open(src).convert("RGB")
    top = TEXT_TOP_MARGIN + reserved + TEXT_TO_SHOT_GAP
    avail_h = CANVAS_H - top - 80
    avail_w = CANVAS_W - SIDE_MARGIN * 2
    scale = min(avail_w / shot.width, avail_h / shot.height)
    shot = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.LANCZOS)
    radius = round(shot.width * SHOT_CORNER_RATIO)
    shot = rounded_corners(shot, radius)
    origin = ((CANVAS_W - shot.size[0]) // 2, top + (avail_h - shot.size[1]) // 2)
    canvas.alpha_composite(shot, origin)
    problems += check_corners(canvas, origin, shot.size, radius)
    dst.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(dst, "PNG", optimize=True)

    problems += shots.panel_problems(dst)
    print(f"  {src.name} -> {dst.name}: {title} | {' / '.join(sub_lines)}")
    for p in problems:
        print(f"    FAIL {p}")
    return problems


def rejected_dir(out_dir: Path) -> Path:
    """Where a failing run leaves its panels, next to `out_dir`, for a look."""
    return out_dir.with_name(out_dir.name + ".rejected")


def withdraw_set(out_dir: Path) -> None:
    """A run for this set failed: whatever an earlier run left in `out_dir` is
    no longer what the captions and captures say, so it must not be pushed.
    Removing compose.json is what set_problems (and so the pusher) refuses."""
    manifest = out_dir / shots.MANIFEST
    if manifest.exists():
        manifest.unlink()
        print(f"  {out_dir}: removed {shots.MANIFEST}; the panels there are an earlier "
              "run's and will not be pushed")


def publish_set(staging: Path, out_dir: Path, lang: str, record: dict) -> None:
    """Swap a set that passed every check into `out_dir`, whole: the manifest
    first (inside staging), then one rename. The set that was there goes."""
    shots.write_manifest(staging, lang, record)
    staging.chmod(0o755)   # mkdtemp makes it 0700
    previous = out_dir.with_name(f".{out_dir.name}.previous")
    shutil.rmtree(previous, ignore_errors=True)
    if out_dir.exists():
        out_dir.rename(previous)
    staging.rename(out_dir)
    shutil.rmtree(previous, ignore_errors=True)
    shutil.rmtree(rejected_dir(out_dir), ignore_errors=True)


def compose_lang(lang: str, in_dir: Path | None, out_dir: Path | None) -> list[str]:
    lang = shots.canonical_lang(lang)
    in_dir = in_dir or shots.raw_dir(lang)
    out_dir = out_dir or shots.composed_dir(lang)
    faces, problems = pick_faces(lang)
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        withdraw_set(out_dir)
        return problems

    srcs = sorted(p for p in in_dir.glob("[0-9][0-9]_*.png"))
    names = {p.stem for p in srcs}
    expected = shots.stems()
    missing = [s for s in expected if s not in names]
    unknown = sorted(names - set(expected))
    if missing:
        problems.append(f"{lang}: no capture for {', '.join(missing)} in {in_dir}")
    if unknown:
        problems.append(f"{lang}: {', '.join(unknown)} in {in_dir} is not a screen of the set")
    for p in problems:
        print(f"FAIL {p}")
    if not srcs or unknown:
        withdraw_set(out_dir)
        return problems

    t_size, s_size, size_problems = set_sizes(lang, faces, [p.stem for p in srcs])
    for p in size_problems:
        print(f"FAIL {lang} {p}")
    problems += size_problems
    reserved_lines = set_sub_lines(lang, faces, [p.stem for p in srcs], s_size)
    face_names = ", ".join(f"{r}={f.family or Path(f.path).stem}" for r, f in faces.items())
    print(f"[{lang}] {len(srcs)} capture(s) from {in_dir} [{face_names}; "
          f"title {t_size}pt, subtitle {s_size}pt]")

    out_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{out_dir.name}.staging-", dir=out_dir.parent))
    try:
        for src in srcs:
            problems += compose_one(src, staging / shots.composed_name(src.stem), lang, faces,
                                    t_size, s_size, reserved_lines)
        if problems:
            rejected = rejected_dir(out_dir)
            shutil.rmtree(rejected, ignore_errors=True)
            staging.rename(rejected)
            print(f"  [{lang}] NOT PUBLISHED: this run's panels are in {rejected} for a look; "
                  f"{out_dir} was not updated")
            withdraw_set(out_dir)
            return problems
        publish_set(staging, out_dir, lang, {
            "faces": {r: f.family or Path(f.path).stem for r, f in faces.items()},
            "title_pt": t_size, "subtitle_pt": s_size,
            "captions": {st: list(COPY[lang][st]) for st in expected},
            "captures": {p.name: shots.md5_of(p) for p in srcs},
        })
        print(f"  [{lang}] published to {out_dir} with {shots.MANIFEST}")
        return problems
    except BaseException:
        # A panel that raised (a truncated capture, Ctrl-C) is a failed run
        # too: the set already in out_dir may no longer match COPY, so it must
        # not stay pushable.
        withdraw_set(out_dir)
        raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--lang", "--locale", dest="lang",
                    help=f"one of {', '.join(shots.LANGS)} (default en)")
    ap.add_argument("--all", action="store_true", help="every language")
    ap.add_argument("--in", dest="in_dir", type=Path, default=None,
                    help="captures (default screenshots/ios-raw/<lang>; with --all, DIR/<lang>)")
    ap.add_argument("--out", dest="out_dir", type=Path, default=None,
                    help="panels (default screenshots/ios-composed/<lang>; with --all, DIR/<lang>)")
    ap.add_argument("--check-fonts", action="store_true",
                    help="only check that every caption can be drawn, in every language")
    args = ap.parse_args()
    _require_pillow()

    if args.check_fonts:
        problems = []
        for lang in shots.LANGS:
            faces, probs = pick_faces(lang)
            problems += probs
            print(f"{lang:8} " + ", ".join(f"{r}: {f.family or Path(f.path).stem}"
                                           for r, f in faces.items()))
        for p in problems:
            print(f"FAIL {p}")
        return 1 if problems else 0

    if args.all and args.lang:
        ap.error("--all or --lang, not both")
    langs = list(shots.LANGS) if args.all else [args.lang or "en"]
    problems = []
    for lang in langs:
        lang = shots.canonical_lang(lang)
        in_dir = (args.in_dir / lang) if (args.all and args.in_dir) else args.in_dir
        out_dir = (args.out_dir / lang) if (args.all and args.out_dir) else args.out_dir
        problems += compose_lang(lang, in_dir, out_dir)
    if problems:
        print(f"\n{len(problems)} problem(s); these panels are not fit to upload.")
        return 1
    print("\nDone. Every caption fits and every character has a glyph.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

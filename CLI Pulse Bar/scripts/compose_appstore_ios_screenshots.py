#!/usr/bin/env python3
"""Composite iPhone screenshots onto ASC-compliant 1290x2796 marketing panels.

Dark navy gradient background, white title + grey subtitle at the top, the
device screenshot centred below with rounded corners (the capture has no device
chrome, so it gets a corner radius instead of looking like a bare bitmap).

Six languages: en, zh-Hans, zh-Hant, ja, ko, es. Where their files live and
which App Store locale shows which set is scripts/appstore_screenshots.py.
Line breaking, fonts, the caption block and publishing are shared with the Mac
compositor (compose_appstore_macos_screenshots.py) in appstore_compose_common.py;
this file keeps the iPhone's captions, canvas and phone framing.

Usage:
    compose_appstore_ios_screenshots.py --lang ja        # ios-raw/ja -> ios-composed/ja
    compose_appstore_ios_screenshots.py --all            # every language
    compose_appstore_ios_screenshots.py --lang en --in DIR --out DIR
    compose_appstore_ios_screenshots.py --check-fonts    # glyph coverage only

(`--locale` is the old name of `--lang`, and `zh` of `zh-Hans`.)

Exit 1 if any caption does not fit or any character would render as tofu.
The output directory then keeps no set a push would accept (see 5).

Six things this script learned the hard way, each of which silently produces a
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

6. PANELS ARE SEEN SIDE BY SIDE, SO THEIR HEADLINES MUST LINE UP.
   Every panel of a set reserves room for the set's tallest subtitle, so the
   phone sits at the same place on each. Centring a shorter caption in that
   room dropped its headline half a line below its neighbours' in every set
   mixing one- and two-line subtitles. The headline now sits at the top of
   the room on every panel (caption_layout).
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR.parent.parent / "scripts"))
import appstore_compose_common as common  # noqa: E402
import appstore_screenshots as shots  # noqa: E402
# The shared parts, under the names this module has always had (the tests and
# the Mac compositor read them from here as well as from common).
from appstore_compose_common import (  # noqa: E402,F401
    CJK_LANGS, FACES, HEITI, HIRAGINO_W3, HIRAGINO_W6, NO_BREAK_PHRASES, NO_LINE_END,
    NO_LINE_START, NOTDEF_PROBE, PINGFANG, PREFERRED_AFTER, PROBES, REGIONAL_PROBES,
    SD_GOTHIC, SF, TRAILING_BLANK_PUNCT, ZWSP, CaptionLayout, Face, Image, ImageDraw,
    ImageFont, break_candidates, centering_width, has_glyph, legal, load_face,
    make_vertical_gradient, regional_problem, rejected_dir, rounded_corners,
    trailing_blank, wrap,
)

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

LAYOUT = common.Layout(
    canvas_w=CANVAS_W, canvas_h=CANVAS_H,
    title_size_max=TITLE_SIZE_MAX, title_size_min=TITLE_SIZE_MIN,
    sub_size_max=SUB_SIZE_MAX, sub_size_min=SUB_SIZE_MIN, sub_max_lines=SUB_MAX_LINES,
    line_box=LINE_BOX, text_top_margin=TEXT_TOP_MARGIN, title_to_sub_gap=TITLE_TO_SUB_GAP,
    sub_line_gap=SUB_LINE_GAP, text_to_shot_gap=TEXT_TO_SHOT_GAP,
    text_side_margin=TEXT_SIDE_MARGIN,
)
TEXT_W = LAYOUT.text_w
# Wider than this, a one-line subtitle reads as a strip across the panel.
SUB_ONE_LINE_W = LAYOUT.sub_one_line_w

# ── captions ─────────────────────────────────────────────────────────────────
# (title, subtitle) per screen. Written against the screen each sits on (the
# Demo data: Codex/Gemini/Claude, estimated costs for Codex and Claude (Gemini
# is quota-only, as it is in production), a weekly quota at 92%, CPU
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
                    "Estimated cost for today and the last 30 days, by provider"),
        "04_sessions": ("Every CLI run tracked",
                        "Active sessions with usage, cost and requests"),
        "05_alerts": ("Never miss a limit",
                      "Quota, CPU spike and long-running session alerts"),
    },
    "zh-Hans": {
        "01_overview": ("关键数据，一屏总览", "用量、费用、会话和告警，打开就能看到"),
        "02_providers": ("实时掌握配额与费用", "离上限还有多远，一眼就知道"),
        "03_cost": ("钱都花在了哪里", "今日与近 30 天的估算费用，按服务商细分"),
        "04_sessions": ("每个会话都有账可查", "活跃会话的用量、费用和请求数"),
        "05_alerts": ("配额不再突然见底", "配额将尽、CPU 过高、会话过久，都会告警"),
    },
    "zh-Hant": {
        "01_overview": ("一眼掌握全局", "用量、費用、工作階段與警示，一頁看完"),
        "02_providers": ("即時查看配額與費用", "用完之前，就知道還剩多少"),
        "03_cost": ("錢花在哪裡", "今日與近 30 天的預估費用，依服務商細分"),
        "04_sessions": ("每次 CLI 執行都有紀錄", "活躍工作階段的用量、費用與請求數"),
        "05_alerts": ("配額不再突然見底", "配額將盡、CPU 使用率過高、工作階段執行過久，都會發出警示"),
    },
    "ja": {
        "01_overview": ("すべてをひと目で", "使用量、コスト、セッション、アラートを\u200bひとつの画面に"),
        "02_providers": ("クォータとコストを把握", "上限に達する前に、\u200b残りがわかる"),
        "03_cost": ("コストの内訳がわかる", "今日の推定コストをプロバイダー別に、\u200b30日間の推定額も"),
        "04_sessions": ("CLI の実行をすべて記録", "アクティブなセッションの\u200b使用量、コスト、リクエスト数"),
        "05_alerts": ("上限の接近を見逃さない", "クォータ残量の低下、CPU の高負荷、\u200b長時間実行中のセッションを通知"),
    },
    "ko": {
        "01_overview": ("모든 것을 한눈에", "사용량, 비용, 세션, 알림을 한 화면에서"),
        "02_providers": ("실시간 할당량과 비용", "한도까지 얼마나 남았는지 바로 확인하세요"),
        "03_cost": ("비용, 어디에 쓰이나요?", "오늘과 30일간의 추정 비용을 공급자별로 확인하세요"),
        "04_sessions": ("모든 CLI 실행을 기록", "활성 세션의 사용량, 비용, 요청 수"),
        "05_alerts": ("할당량이 바닥나기 전에", "CPU 사용률 급증과 오래 실행 중인 세션도 알려 드려요"),
    },
    "es": {
        "01_overview": ("Todo de un vistazo",
                        "Uso, costos, sesiones y alertas en una sola pantalla"),
        "02_providers": ("Cuotas y costos en vivo",
                         "Consulta cuánto te queda antes de llegar al límite"),
        "03_cost": ("En qué se va tu dinero",
                    "Costo estimado de hoy y de los últimos 30 días, por proveedor"),
        "04_sessions": ("Cada ejecución, registrada",
                        "Sesiones activas con su uso, costo y solicitudes"),
        "05_alerts": ("Sin sorpresas con la cuota",
                      "Alertas de cuota, picos de CPU y sesiones de larga duración"),
    },
}

# ── the shared caption code, with this compositor's COPY and LAYOUT ──────────

def _require_pillow() -> None:
    common.require_pillow()


def caption_chars(lang: str) -> str:
    return common.caption_chars(COPY, lang)


def pick_faces(lang: str) -> tuple[dict[str, Face], list[str]]:
    """{role: face} of the first face per role that draws every character of
    this language's captions, and the problems if a role has none."""
    return common.pick_faces(COPY, lang)


def line_height(font) -> int:
    return common.line_height(LAYOUT, font)


def draw_centered(draw, y, text, font, color) -> int:
    """Draw one centred line whose box starts at `y`; return where it ends."""
    return common.draw_centered(LAYOUT, draw, y, text, font, color)


def title_size(title: str, face: Face) -> int | None:
    return common.title_size(LAYOUT, title, face)


def subtitle_lines(subtitle: str, lang: str, face: Face, size: int) -> list[str] | None:
    return common.subtitle_lines(LAYOUT, subtitle, lang, face, size)


def subtitle_size(subtitle: str, lang: str, face: Face) -> int | None:
    return common.subtitle_size(LAYOUT, subtitle, lang, face)


def set_sub_lines(lang: str, faces: dict[str, Face], stems_: list[str], s_size: int) -> int:
    """How many subtitle lines the set's tallest caption takes. Every panel
    reserves that much, so the phone sits at the same place and size on each."""
    return common.set_sub_lines(LAYOUT, COPY, lang, faces, stems_, s_size)


def caption_layout(title_box: int, sub_box: int, sub_lines: int,
                   reserved_lines: int) -> CaptionLayout:
    """Where one panel's caption and phone go (see 6 in the module docstring
    and common.caption_layout)."""
    return common.caption_layout(LAYOUT, title_box, sub_box, sub_lines, reserved_lines)


def set_sizes(lang: str, faces: dict[str, Face], stems_: list[str]) -> tuple[int, int, list[str]]:
    """One title size and one subtitle size for the whole set (common.set_sizes)."""
    return common.set_sizes(LAYOUT, COPY, lang, faces, stems_)


# ── composing ────────────────────────────────────────────────────────────────

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

    # Headline at the same height on every panel of the set, and the phone
    # too: see caption_layout.
    layout = caption_layout(line_height(title_font), line_height(sub_font),
                            len(sub_lines), reserved_lines)
    draw_centered(draw, layout.title_y, title, title_font, TITLE_COLOR)
    for y, line in zip(layout.sub_ys, sub_lines):
        draw_centered(draw, y, line, sub_font, SUBTITLE_COLOR)

    shot = Image.open(src).convert("RGB")
    top = layout.shot_top
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


def withdraw_set(out_dir: Path) -> None:
    """A failed run: remove the earlier set's compose.json (common.withdraw_set)."""
    common.withdraw_set(out_dir, shots.MANIFEST)


def publish_set(staging: Path, out_dir: Path, lang: str, record: dict) -> None:
    """Swap a set that passed every check into `out_dir`, whole (common.publish_set)."""
    common.publish_set(staging, out_dir, lambda d: shots.write_manifest(d, lang, record))


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

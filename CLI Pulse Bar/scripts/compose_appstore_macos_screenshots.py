#!/usr/bin/env python3
"""Composite the Mac App Store screenshots onto ASC-compliant 2880x1800 panels.

The raw material is the QA build's store set (scripts/render_macos_qa_views.sh
--set store; docs/qa/macos-offscreen-renders.md): the real SwiftUI views of the
Mac app, drawn offscreen at 3x with Demo data, in each of the app's six
languages, plus render.json, which records what the build that drew them was.
Only views whose visible UI is the same in that QA build and in the Mac App
Store build are drawn (QARenderSnapshot.storeCatalog), and this refuses a set
whose render.json does not say so (scripts/appstore_screenshots.py
render_problems): no DEVID_BUILD, no remote control, a local usage history of
Claude and Codex only, no warnings.

Each panel: the dark navy gradient and captions of the iPhone set (the same
fonts, sizes, line breaking and pinned headline: appstore_compose_common.py),
the 380x580-point menu-bar popover below them at one fixed scale for the whole
set, framed as the popover window frames it (rounded corners, hairline, soft
shadow; no fake menu bar). The cost panel's popover is a little shorter
(render.json records how much: QARenderSnapshot.alignedTrim), so the Overview
scrolled to its end opens above a card rather than through a line of text; it
sits at the same place and scale as the others and simply ends higher. The usage-history panel shows the dashboard panel
DashboardPanelController slides out to the left of the popover, top-aligned,
8 points away, at the same scale; it is taller than the canvas and is the only
thing allowed past an edge, and only past the bottom one.

Usage:
    compose_appstore_macos_screenshots.py --lang ja      # macos-raw/ja -> macos-composed/ja
    compose_appstore_macos_screenshots.py --all          # every language
    compose_appstore_macos_screenshots.py --lang en --in DIR --out DIR
    compose_appstore_macos_screenshots.py --check-fonts  # glyph coverage only

Exit 1 if any caption does not fit, any character would render as tofu, the
raw set is not a clean store render, or the popover would be drawn smaller
than MIN_PX_PER_PT. A failing run publishes nothing: its panels go to
<out>.rejected/ and the earlier set's compose.json is withdrawn, so the pusher
refuses it (the iPhone compositor's rule 5).

A caption is a claim about the Mac App Store build, which has no remote
control, no helper-driven terminal and none of the Developer ID build's
updater or fan controls: scripts/test_appstore_screenshots.py holds every
language's captions to that.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR.parent.parent / "scripts"))
import appstore_compose_common as common  # noqa: E402
import appstore_screenshots as shots  # noqa: E402
from appstore_compose_common import Face, Image, ImageDraw  # noqa: E402

try:
    import PIL
    from PIL import ImageFilter
except ImportError:  # the pure parts work without Pillow
    PIL = ImageFilter = None

PLATFORM = shots.MAC
CANVAS_W, CANVAS_H = PLATFORM.canvas

BG_TOP = (16, 20, 42)
BG_BOTTOM = (8, 10, 22)
TITLE_COLOR = (255, 255, 255)
SUBTITLE_COLOR = (175, 182, 200)

# The iPhone set's caption metrics, on the Mac canvas.
LAYOUT = common.Layout(canvas_w=CANVAS_W, canvas_h=CANVAS_H)
BOTTOM_MARGIN = 80

POPOVER_PT = shots.MAC_POPOVER_PT
PANEL_WIDTH_PT = shots.MAC_PANEL_WIDTH_PT
RENDER_SCALE = shots.MAC_RENDER_SCALE
# The popover fills the room under the captions, so its scale follows from the
# set's caption height: about 2.27 canvas pixels per point with one-line
# subtitles, which puts 11-point text at about 25 pixels. Below this, the set
# fails rather than shrinking the app into an unreadable thumbnail.
MIN_PX_PER_PT = 2.2
# The popover window's corner radius, measured from a real capture of it (the
# v1.28 set's 01_overview.png, 2x): the first opaque pixel on the corner's
# diagonal is 9 px in, which is a 32 px (16 pt) continuous corner.
POPOVER_CORNER_PT = 16
# DashboardPanelController: hosting.layer.cornerRadius = 16, and the panel sits
# `leftEdge - width - 8`, 8 points left of the popover, top-aligned with it.
PANEL_CORNER_PT = 16
PANEL_GAP_PT = 8
HAIRLINE = (255, 255, 255, 46)
SHADOW_ALPHA = 120
SHADOW_BLUR_PT = 12
SHADOW_OFFSET_PT = 6

# ── captions ─────────────────────────────────────────────────────────────────
# (title, subtitle) per screen, written against the screen each sits on (Demo
# data; the usage panel from the local Claude + Codex history) and in the
# app's own words: 配额/配額/クォータ/할당량/cuota, 告警/警示/アラート/알림/
# alertas, 会话/工作階段/セッション/세션/sesiones, "costo", 菜单栏/選單列/
# メニューバー/메뉴 막대/barra de menús, the dashboard's scope line ("Claude +
# Codex local history", 本地历史/本機歷史/ローカル履歴/로컬 기록/historial local),
# the alert buttons in the order the cards show them (Ack/Resolve/Snooze), the
# pet's Energy and Hunger, and the pet's name, pet.title. The alerts subtitle
# promises no kind of alert: the Demo list, like a paired account's, also holds
# CPU and long-running-session alerts from a helper on another device. Where the iPhone set says the same thing, its reviewed
# words are reused as they are.
COPY: dict[str, dict[str, tuple[str, str]]] = {
    "en": {
        "01_overview": ("Everything at a glance",
                        "Usage, cost, sessions and alerts in your menu bar"),
        "02_providers": ("Live quotas and costs",
                         "See what’s left before you hit the wall"),
        "03_usage_history": ("Your usage history, one click away",
                             "Heatmap, streaks and top models from your local Claude and Codex history"),
        "04_cost": ("Where the money goes",
                    "Per-provider cost, top projects and risk signals"),
        "05_alerts": ("Never miss a limit",
                      "Alerts you can acknowledge, resolve or snooze"),
        "06_pulse_cat": ("Meet Pulse Cat",
                         "A desktop cat whose energy and hunger follow your AI usage"),
    },
    "zh-Hans": {
        "01_overview": ("关键数据，一屏总览", "用量、费用、会话和告警，在菜单栏一点即看"),
        "02_providers": ("实时掌握配额与费用", "离上限还有多远，一眼就知道"),
        "03_usage_history": ("用量历史，一点就展开",
                             "活动热力图、连续天数和最常用模型，来自 Claude 与 Codex 的本地历史"),
        "04_cost": ("钱都花在了哪里", "按服务商细分的费用、主要项目和风险信号"),
        "05_alerts": ("配额不再突然见底", "告警可以确认、解决或稍后提醒"),
        "06_pulse_cat": ("认识一下脉冲猫", "一只桌面猫，活力和饱食度跟着你的 AI 用量变化"),
    },
    "zh-Hant": {
        "01_overview": ("一眼掌握全局", "用量、費用、工作階段與警示，在選單列按一下就能看到"),
        "02_providers": ("即時查看配額與費用", "用完之前，就知道還剩多少"),
        "03_usage_history": ("用量歷史，按一下就展開",
                             "活動熱度圖、連續天數與常用模型，來自 Claude 與 Codex 的本機歷史"),
        "04_cost": ("錢花在哪裡", "各服務商的費用、高用量專案與風險訊號"),
        "05_alerts": ("配額不再突然見底", "警示可以確認、解決或稍後提醒"),
        "06_pulse_cat": ("來認識脈衝貓", "一隻桌面貓，活力與飽食度會隨你的 AI 用量變化"),
    },
    "ja": {
        "01_overview": ("すべてをひと目で",
                        "使用量、コスト、セッション、アラートを\u200bメニューバーからすぐ確認"),
        "02_providers": ("クォータとコストを把握", "上限に達する前に、\u200b残りがわかる"),
        "03_usage_history": ("使用履歴をワンクリックで",
                             "Claude と Codex のローカル履歴から、\u200bヒートマップ・連続日数・"
                             "よく使うモデルを表示"),
        "04_cost": ("コストの内訳がわかる",
                    "プロバイダー別のコスト、\u200b上位プロジェクト、\u200bリスクシグナル"),
        "05_alerts": ("上限の接近を見逃さない",
                      "アラートを、\u200bその場で確認・解決・スヌーズ"),
        "06_pulse_cat": ("パルスキャットに会おう",
                         "エネルギーとおなかの具合が AI の使い方で変わる\u200bデスクトップ猫"),
    },
    "ko": {
        "01_overview": ("모든 것을 한눈에", "메뉴 막대에서 사용량, 비용, 세션, 알림까지"),
        "02_providers": ("실시간 할당량과 비용", "한도까지 얼마나 남았는지 바로 확인하세요"),
        "03_usage_history": ("사용 기록을 클릭 한 번으로",
                             "Claude와 Codex 로컬 기록으로 보는 활동 히트맵, 연속 사용일, 자주 쓰는 모델"),
        "04_cost": ("비용, 어디에 쓰이나요?", "공급자별 비용, 상위 프로젝트, 위험 신호"),
        "05_alerts": ("할당량이 바닥나기 전에", "경고는 그 자리에서 확인하고, 해결하거나 다시 알림으로 미루세요"),
        "06_pulse_cat": ("펄스 캣을 만나 보세요", "AI 사용량에 따라 에너지와 허기가 달라지는 데스크톱 고양이"),
    },
    "es": {
        "01_overview": ("Todo de un vistazo",
                        "Uso, costos, sesiones y alertas en tu barra de menús"),
        "02_providers": ("Cuotas y costos en vivo",
                         "Consulta cuánto te queda antes de llegar al límite"),
        "03_usage_history": ("Tu historial de uso, a un clic",
                             "Mapa de calor, rachas y modelos más usados, a partir de tu historial local "
                             "de Claude y Codex"),
        "04_cost": ("En qué se va tu dinero",
                    "Costo por proveedor y proyecto, con señales de riesgo"),
        "05_alerts": ("Sin sorpresas con la cuota",
                      "Alertas que puedes confirmar, resolver o posponer"),
        "06_pulse_cat": ("Conoce a tu Gato Pulse",
                         "Un gato de escritorio cuya energía y hambre reflejan tu uso de IA"),
    },
}

# Words that name what only the Developer ID build has, or what this listing
# no longer has, in the captions of any language (the Mac listing's own
# tripwire, beside appstore_listing.devid_only_terms_in). Case-insensitive,
# on word boundaries for Latin, as substrings otherwise.
MAC_CAPTION_DENYLIST: tuple[str, ...] = (
    "Remote Control", "remote", "terminal", "helper", "Developer ID", "Homebrew", "update",
    "updater", "fan", "Low Power", "Swarm", "Local-only",
    "远程", "遠端", "リモート", "원격", "终端", "終端", "ターミナル", "터미널",
    "助手程序", "ヘルパー", "헬퍼", "风扇", "風扇", "ファン", "팬 ", "remoto", "ventilador",
)

# ── the shared caption code, with this compositor's COPY and LAYOUT ──────────


def pick_faces(lang: str) -> tuple[dict[str, Face], list[str]]:
    return common.pick_faces(COPY, lang)


def subtitle_lines(subtitle: str, lang: str, face: Face, size: int) -> list[str] | None:
    return common.subtitle_lines(LAYOUT, subtitle, lang, face, size)


# ── the stage (pure; tested without Pillow) ──────────────────────────────────

def px_per_pt(shot_top: int) -> float:
    """Canvas pixels per popover point: the popover fills the room from the
    end of the caption block to BOTTOM_MARGIN above the canvas's bottom."""
    return (CANVAS_H - BOTTOM_MARGIN - shot_top) / POPOVER_PT[1]


@dataclass(frozen=True)
class Placement:
    name: str
    x: int
    y: int
    w: int
    h: int
    may_bleed_bottom: bool = False


def placements(screen_has_panel: bool, shot_top: int, scale: float,
               panel_height_pt: float | None = None,
               popover_height_pt: float | None = None) -> list[Placement]:
    """Where the popover (and the usage panel beside it) go, in canvas pixels.
    A single popover is centred; with the panel, the group is centred, the
    panel on the left, top-aligned, PANEL_GAP_PT away, as the app places it.
    A shortened popover keeps the same top, so the tab bar does not move
    from one panel of the set to the next."""
    pw, ph = round(POPOVER_PT[0] * scale), round((popover_height_pt or POPOVER_PT[1]) * scale)
    if not screen_has_panel:
        return [Placement("popover", (CANVAS_W - pw) // 2, shot_top, pw, ph)]
    qw = round(PANEL_WIDTH_PT * scale)
    qh = round((panel_height_pt or 0) * scale)
    gap = round(PANEL_GAP_PT * scale)
    x0 = (CANVAS_W - (qw + gap + pw)) // 2
    return [Placement("panel", x0, shot_top, qw, qh, may_bleed_bottom=True),
            Placement("popover", x0 + qw + gap, shot_top, pw, ph)]


def placement_problems(items: list[Placement], scale: float) -> list[str]:
    """The popover whole on the canvas, and at a legible scale; only the
    usage panel may leave the canvas, and only through the bottom edge."""
    out = []
    if scale < MIN_PX_PER_PT:
        out.append(f"the popover would be drawn at {scale:.3f} px/pt, under {MIN_PX_PER_PT}: "
                   "shorten the set's longest subtitle to one line")
    for it in items:
        if it.x < 0 or it.y < 0 or it.x + it.w > CANVAS_W:
            out.append(f"the {it.name} leaves the canvas at the side or the top "
                       f"({it.x},{it.y} {it.w}x{it.h})")
        if it.y + it.h > CANVAS_H and not it.may_bleed_bottom:
            out.append(f"the {it.name} leaves the canvas at the bottom ({it.y + it.h} > {CANVAS_H})")
    return out


# ── composing ────────────────────────────────────────────────────────────────

def framed(img, w: int, h: int, radius: int):
    """`img` scaled to w x h (LANCZOS, a downscale of the 3x render) with the
    window's rounded corners and a hairline border, as RGBA."""
    out = img.convert("RGB").resize((w, h), Image.LANCZOS)
    out = common.rounded_corners(out, radius)
    ImageDraw.Draw(out).rounded_rectangle([(0, 0), (w - 1, h - 1)], radius=radius,
                                          outline=HAIRLINE, width=2)
    return out


def drop_shadow(canvas, it: Placement, radius: int, scale: float) -> None:
    layer = Image.new("L", canvas.size, 0)
    off = round(SHADOW_OFFSET_PT * scale)
    ImageDraw.Draw(layer).rounded_rectangle(
        [(it.x, it.y + off), (it.x + it.w - 1, it.y + it.h - 1 + off)], radius=radius, fill=SHADOW_ALPHA)
    layer = layer.filter(ImageFilter.GaussianBlur(SHADOW_BLUR_PT * scale / 2))
    black = Image.new("RGBA", canvas.size, (0, 0, 0, 255))
    black.putalpha(layer)
    canvas.alpha_composite(black)


def compose_one(src_dir: Path, stem_: str, dst: Path, lang: str, faces: dict[str, Face],
                t_size: int, s_size: int, reserved_lines: int,
                popover_pt: tuple[int, int] = POPOVER_PT) -> tuple[list[str], float]:
    """Write one panel; return why it is not fit to upload (empty = fine),
    and the scale it was drawn at. `popover_pt` is the popover's size as
    render.json records it for this shot (shots.mac_popover_pt)."""
    title, subtitle = COPY[lang][stem_]
    problems = []

    canvas = common.make_vertical_gradient(CANVAS_W, CANVAS_H, BG_TOP, BG_BOTTOM).convert("RGBA")
    draw = ImageDraw.Draw(canvas)
    title_font = common.load_face(faces["title"], t_size)
    sub_font = common.load_face(faces["subtitle"], s_size)
    if title_font.getlength(title) > LAYOUT.text_w:
        problems.append(f"title overflows at {t_size}pt: {title!r}")
    sub_lines = subtitle_lines(subtitle, lang, faces["subtitle"], s_size)
    if sub_lines is None:
        problems.append(f"subtitle overflows at {s_size}pt: {subtitle!r}")
        sub_lines = [subtitle.replace(common.ZWSP, "")]
    layout = common.caption_layout(LAYOUT, common.line_height(LAYOUT, title_font),
                                   common.line_height(LAYOUT, sub_font), len(sub_lines), reserved_lines)
    common.draw_centered(LAYOUT, draw, layout.title_y, title, title_font, TITLE_COLOR)
    for y, line in zip(layout.sub_ys, sub_lines):
        common.draw_centered(LAYOUT, draw, y, line, sub_font, SUBTITLE_COLOR)

    scale = px_per_pt(layout.shot_top)
    popover = Image.open(src_dir / f"{stem_}.png")
    panel_path = src_dir / f"{stem_}.panel.png"
    has_panel = stem_ in [f[:-len(".panel.png")] for f in shots.panel_raw_names(PLATFORM)]
    panel = Image.open(panel_path) if has_panel else None
    want = (popover_pt[0] * RENDER_SCALE, popover_pt[1] * RENDER_SCALE)
    if popover.size != want:
        problems.append(f"{stem_}.png is {popover.size[0]}x{popover.size[1]}, not {want[0]}x{want[1]}")
    if panel is not None and panel.size[0] != PANEL_WIDTH_PT * RENDER_SCALE:
        problems.append(f"{panel_path.name} is {panel.size[0]} px wide, not {PANEL_WIDTH_PT * RENDER_SCALE}")
    items = placements(panel is not None, layout.shot_top, scale,
                       panel.size[1] / RENDER_SCALE if panel is not None else None,
                       popover_height_pt=popover_pt[1])
    problems += placement_problems(items, scale)
    for it in items:
        img, corner_pt = (panel, PANEL_CORNER_PT) if it.name == "panel" else (popover, POPOVER_CORNER_PT)
        radius = round(corner_pt * scale)
        drop_shadow(canvas, it, radius, scale)
        tile = framed(img, it.w, it.h, radius)
        if it.y + it.h > CANVAS_H:   # the panel, past the bottom edge (placement_problems)
            tile = tile.crop((0, 0, it.w, CANVAS_H - it.y))
        canvas.alpha_composite(tile, (it.x, it.y))
    dst.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(dst, "PNG", optimize=True)

    problems += shots.panel_problems(dst, PLATFORM)
    print(f"  {stem_} -> {dst.name}: {title} | {' / '.join(sub_lines)}  [{scale:.3f} px/pt]")
    for p in problems:
        print(f"    FAIL {p}")
    return problems, scale


def withdraw_set(out_dir: Path) -> None:
    common.withdraw_set(out_dir, shots.MANIFEST)


def publish_set(staging: Path, out_dir: Path, lang: str, record: dict) -> None:
    common.publish_set(staging, out_dir,
                       lambda d: shots.write_manifest(d, lang, record, platform=PLATFORM))


def compose_lang(lang: str, in_dir: Path | None, out_dir: Path | None) -> list[str]:
    lang = shots.canonical_lang(lang)
    in_dir = in_dir or shots.raw_dir(lang, platform=PLATFORM)
    out_dir = out_dir or shots.composed_dir(lang, platform=PLATFORM)
    faces, problems = pick_faces(lang)
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        withdraw_set(out_dir)
        return problems

    # The raws must be a clean store render in this language, by a build
    # without the Developer ID UI: render.json says so, or nothing is drawn.
    render_probs = shots.render_problems(lang, platform=PLATFORM, directory=in_dir)
    for p in render_probs:
        print(f"FAIL {lang} {in_dir.name}/{shots.RENDER_MANIFEST}: {p}")
    if render_probs:
        withdraw_set(out_dir)
        return render_probs
    render = json.loads((in_dir / shots.RENDER_MANIFEST).read_text(encoding="utf-8"))

    stems_ = shots.stems(PLATFORM)
    t_size, s_size, size_problems = common.set_sizes(LAYOUT, COPY, lang, faces, stems_)
    for p in size_problems:
        print(f"FAIL {lang} {p}")
    problems += size_problems
    reserved_lines = common.set_sub_lines(LAYOUT, COPY, lang, faces, stems_, s_size)
    face_names = ", ".join(f"{r}={common.face_name(f)}" for r, f in faces.items())
    print(f"[{lang}] {len(stems_)} screen(s) from {in_dir} [{face_names}; "
          f"title {t_size}pt, subtitle {s_size}pt]")

    out_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{out_dir.name}.staging-", dir=out_dir.parent))
    try:
        scales = set()
        for st in stems_:
            probs, scale = compose_one(in_dir, st, staging / shots.composed_name(st, PLATFORM), lang,
                                       faces, t_size, s_size, reserved_lines,
                                       popover_pt=shots.mac_popover_pt(render, st))
            problems += probs
            scales.add(round(scale, 6))
        if len(scales) != 1:
            problems.append(f"the popover is drawn at {len(scales)} different scales in one set: {sorted(scales)}")
        if problems:
            rejected = common.rejected_dir(out_dir)
            shutil.rmtree(rejected, ignore_errors=True)
            staging.rename(rejected)
            print(f"  [{lang}] NOT PUBLISHED: this run's panels are in {rejected} for a look; "
                  f"{out_dir} was not updated")
            withdraw_set(out_dir)
            return problems
        publish_set(staging, out_dir, lang, {
            "faces": {r: common.face_name(f) for r, f in faces.items()},
            "title_pt": t_size, "subtitle_pt": s_size,
            "px_per_pt": round(next(iter(scales)), 4),
            "captions": {st: list(COPY[lang][st]) for st in stems_},
            "captures": {name: shots.md5_of(in_dir / name) for name in shots.raw_names(PLATFORM)},
            "render": shots.md5_of(in_dir / shots.RENDER_MANIFEST),
            "app": {"version": render["app"]["version"], "build": render["app"]["build"]},
            # Another Pillow resamples and encodes differently, so a byte-for-byte
            # recompose is only expected with this one (test_appstore_screenshots.py).
            "pillow": PIL.__version__,
        })
        print(f"  [{lang}] published to {out_dir} with {shots.MANIFEST}")
        return problems
    except BaseException:
        withdraw_set(out_dir)
        raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--lang", help=f"one of {', '.join(shots.LANGS)} (default en)")
    ap.add_argument("--all", action="store_true", help="every language")
    ap.add_argument("--in", dest="in_dir", type=Path, default=None,
                    help="raw store renders (default screenshots/macos-raw/<lang>; with --all, DIR/<lang>)")
    ap.add_argument("--out", dest="out_dir", type=Path, default=None,
                    help="panels (default screenshots/macos-composed/<lang>; with --all, DIR/<lang>)")
    ap.add_argument("--check-fonts", action="store_true",
                    help="only check that every caption can be drawn, in every language")
    args = ap.parse_args()
    common.require_pillow()

    if args.check_fonts:
        problems = []
        for lang in shots.LANGS:
            faces, probs = pick_faces(lang)
            problems += probs
            print(f"{lang:8} " + ", ".join(f"{r}: {common.face_name(f)}" for r, f in faces.items()))
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
    print("\nDone. Every caption fits, every character has a glyph, and every raw set is a "
          "clean store render.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

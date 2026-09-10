#!/usr/bin/env python3
"""Composite iPhone screenshots onto ASC-compliant 1290x2796 marketing panels.

Dark navy gradient background, white title + grey subtitle at the top, the
device screenshot centered below with rounded corners (the iPhone capture has
no device chrome — we add a corner radius so it doesn't look like a bare
bitmap).

Usage:
    compose_appstore_ios_screenshots.py                 # en, screenshots/ios
    compose_appstore_ios_screenshots.py --locale zh     # screenshots/ios-zh
    compose_appstore_ios_screenshots.py --in DIR --out DIR --locale en

Two things this script learned the hard way, both of which silently produce a
listing you would not ship:

1. TEXT THAT DOES NOT FIT IS NOT A LAYOUT PROBLEM, IT IS A CROPPED SENTENCE.
   The first version drew title and subtitle at a fixed 100/44pt. Any caption
   longer than the canvas simply ran off both edges, and because the script
   prints "OK" either way you only find out by opening the PNG. Titles now
   shrink to fit and subtitles wrap to at most two lines before shrinking, so
   a long caption gets smaller rather than getting cut in half.

2. SFNS.TTF HAS NO CJK GLYPHS.
   Rendering "实时额度" with the system UI font produces a row of tofu boxes —
   again, with no error. The zh locale therefore renders through PingFang, and
   `pick_font` *verifies* coverage by measuring a representative glyph instead
   of trusting the filename: a font that cannot draw the character reports a
   zero-width mask, and we fall through to the next candidate.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

CANVAS_W, CANVAS_H = 1290, 2796

BG_TOP = (16, 20, 42)
BG_BOTTOM = (8, 10, 22)

TITLE_COLOR = (255, 255, 255)
SUBTITLE_COLOR = (175, 182, 200)

TITLE_SIZE_MAX, TITLE_SIZE_MIN = 100, 58
SUB_SIZE_MAX, SUB_SIZE_MIN = 46, 30

TEXT_TOP_MARGIN = 140
TITLE_TO_SUB_GAP = 24
SUB_LINE_GAP = 10
TEXT_TO_SHOT_GAP = 70
SIDE_MARGIN = 80
TEXT_SIDE_MARGIN = 70
SHOT_CORNER_RADIUS = 56

# Fonts, most-preferred first. zh needs a CJK face; en keeps the SF system font.
FONTS = {
    "en": ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"],
    "zh": [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
    ],
}
# A character each locale's font MUST be able to draw.
PROBE_GLYPH = {"en": "A", "zh": "额"}

# An unassigned codepoint, so every font renders it as .notdef. Comparing a real
# glyph against this is what makes the coverage check discriminate — see has_glyph.
NOTDEF_PROBE = "\U000f0000"

COPY = {
    "en": {
        "01_overview": ("Everything at a glance",
                        "Usage, spend and sessions — plus remote control of your Mac"),
        "02_providers": ("Live quotas, real costs",
                         "See what's left before you hit the wall"),
        "03_cost": ("Where the money goes",
                    "Per-provider cost, top projects and risk signals"),
        "04_sessions": ("Every CLI run tracked",
                        "Live sessions with usage, cost and requests"),
        "05_alerts": ("Never miss a limit",
                      "Alerts for quota, cost spikes and offline devices"),
    },
    "zh": {
        "01_overview": ("一屏看全", "用量、花费、会话 —— 还能远程操作你的 Mac"),
        "02_providers": ("实时额度,真实花费", "撞墙之前就知道还剩多少"),
        "03_cost": ("钱花在哪里", "按服务商拆分的花费、热门项目和风险信号"),
        "04_sessions": ("每一次 CLI 运行都在案", "实时会话,附用量、费用和请求数"),
        "05_alerts": ("额度不再突然见底", "额度、费用突增、设备离线都会提醒"),
    },
}

SCRIPT_DIR = Path(__file__).resolve().parent
REPO = SCRIPT_DIR.parent


def make_vertical_gradient(w: int, h: int, top, bot) -> Image.Image:
    small = Image.new("RGB", (1, 2))
    small.putpixel((0, 0), top)
    small.putpixel((0, 1), bot)
    return small.resize((w, h), Image.BICUBIC)


def has_glyph(font: ImageFont.FreeTypeFont, ch: str) -> bool:
    """Whether `font` has a real glyph for `ch`, rather than the .notdef box.

    The obvious test — `font.getbbox(ch)[2] > 0` — is a TAUTOLOGY and was the
    first thing written here. A font missing the character still reports a
    positive width, because what it measures is the substituted .notdef glyph
    (the empty rectangle you see as "tofu"). So the check passed for every font
    on the machine, including a latin-only one, and would have shipped a
    Chinese listing rendered entirely as boxes.

    Rendering an unassigned codepoint gives us what .notdef looks like in THIS
    font; a character whose bitmap differs from it is genuinely present.
    """
    def rendered(c: str) -> bytes:
        img = Image.new("L", (128, 128), 0)
        ImageDraw.Draw(img).text((16, 16), c, font=font, fill=255)
        return img.tobytes()

    try:
        real, notdef = rendered(ch), rendered(NOTDEF_PROBE)
    except Exception:
        return False
    return any(real) and real != notdef


def pick_font_path(locale: str) -> str:
    """Return the first font file that can actually draw this locale's script.

    Checking the glyph rather than the filename is the point: a missing CJK
    face renders tofu silently, and a wrong-but-present file would pass any
    existence check.
    """
    probe = PROBE_GLYPH[locale]
    for path in FONTS[locale]:
        if not Path(path).exists():
            continue
        try:
            if has_glyph(ImageFont.truetype(path, 64), probe):
                return path
        except OSError:
            continue
    raise SystemExit(f"No font on this machine can render {probe!r} for locale {locale!r}")


def fitted_font(text: str, path: str, max_w: int, size_max: int, size_min: int):
    """Largest size in [size_min, size_max] whose rendering of `text` fits max_w."""
    for size in range(size_max, size_min - 1, -2):
        font = ImageFont.truetype(path, size)
        if font.getbbox(text)[2] <= max_w:
            return font, True
    return ImageFont.truetype(path, size_min), False


def wrap_to_lines(text: str, font_path: str, max_w: int, size: int, locale: str):
    """Split `text` into <=2 lines that each fit max_w. CJK wraps per character."""
    font = ImageFont.truetype(font_path, size)
    if font.getbbox(text)[2] <= max_w:
        return [text]
    units = list(text) if locale == "zh" else text.split(" ")
    joiner = "" if locale == "zh" else " "
    best = None
    for split in range(1, len(units)):
        a = joiner.join(units[:split]).strip()
        b = joiner.join(units[split:]).strip()
        if not a or not b:
            continue
        wa, wb = font.getbbox(a)[2], font.getbbox(b)[2]
        if wa <= max_w and wb <= max_w:
            score = abs(wa - wb)          # prefer visually balanced lines
            if best is None or score < best[0]:
                best = (score, [a, b])
    return best[1] if best else [text]


def draw_centered(draw, y, text, font, color) -> int:
    bbox = draw.textbbox((0, 0), text, font=font, anchor="lt")
    x = (CANVAS_W - (bbox[2] - bbox[0])) // 2
    draw.text((x, y), text, font=font, fill=color, anchor="lt")
    return y + (bbox[3] - bbox[1])


def rounded_corners(img: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([(0, 0), img.size], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def compose_one(src: Path, dst: Path, locale: str, font_path: str) -> None:
    title, subtitle = COPY[locale].get(
        src.stem, ("CLI Pulse", "Monitor your AI coding tools"))
    text_w = CANVAS_W - TEXT_SIDE_MARGIN * 2

    canvas = make_vertical_gradient(CANVAS_W, CANVAS_H, BG_TOP, BG_BOTTOM).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    title_font, title_fit = fitted_font(title, font_path, text_w, TITLE_SIZE_MAX, TITLE_SIZE_MIN)
    y = draw_centered(draw, TEXT_TOP_MARGIN, title, title_font, TITLE_COLOR)
    y += TITLE_TO_SUB_GAP

    sub_lines = wrap_to_lines(subtitle, font_path, text_w, SUB_SIZE_MAX, locale)
    widest = max(sub_lines, key=len)
    sub_font, sub_fit = fitted_font(widest, font_path, text_w, SUB_SIZE_MAX, SUB_SIZE_MIN)
    for i, line in enumerate(sub_lines):
        y = draw_centered(draw, y, line, sub_font, SUBTITLE_COLOR)
        if i != len(sub_lines) - 1:
            y += SUB_LINE_GAP

    shot = Image.open(src).convert("RGB")
    top = y + TEXT_TO_SHOT_GAP
    avail_h = CANVAS_H - top - 80
    avail_w = CANVAS_W - SIDE_MARGIN * 2
    scale = min(avail_w / shot.width, avail_h / shot.height)
    shot = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.LANCZOS)
    shot = rounded_corners(shot, SHOT_CORNER_RADIUS)

    canvas.alpha_composite(
        shot, ((CANVAS_W - shot.size[0]) // 2, top + (avail_h - shot.size[1]) // 2))
    canvas.convert("RGB").save(dst, "PNG", optimize=True)

    flags = []
    if not title_fit:
        flags.append("TITLE STILL OVERFLOWS")
    if not sub_fit:
        flags.append("SUBTITLE STILL OVERFLOWS")
    if len(sub_lines) > 1:
        flags.append(f"subtitle wrapped to {len(sub_lines)} lines")
    note = ("  [" + "; ".join(flags) + "]") if flags else ""
    print(f"  {src.name} -> {dst.name} "
          f"(title {title_font.size}pt, sub {sub_font.size}pt){note}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--locale", choices=sorted(COPY), default="en")
    ap.add_argument("--in", dest="in_dir", type=Path, default=None)
    ap.add_argument("--out", dest="out_dir", type=Path, default=None)
    args = ap.parse_args()

    suffix = "" if args.locale == "en" else f"-{args.locale}"
    in_dir = args.in_dir or (REPO / "screenshots" / f"ios{suffix}")
    out_dir = args.out_dir or (in_dir / "composed")
    out_dir.mkdir(parents=True, exist_ok=True)

    font_path = pick_font_path(args.locale)
    srcs = sorted(p for p in in_dir.glob("[0-9][0-9]_*.png") if p.parent.name != "composed")
    if not srcs:
        raise SystemExit(f"No source screenshots in {in_dir}")

    print(f"Composing {len(srcs)} screenshot(s) at {CANVAS_W}x{CANVAS_H} "
          f"[locale={args.locale}, font={Path(font_path).name}]")
    for src in srcs:
        compose_one(src, out_dir / f"{src.stem}_1290x2796.png", args.locale, font_path)
    print(f"\nDone. Output: {out_dir}")


if __name__ == "__main__":
    main()

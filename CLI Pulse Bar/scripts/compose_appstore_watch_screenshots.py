#!/usr/bin/env python3
"""The Apple Watch App Store panels, from the Watch app's own captures.

    watch-raw/<lang>/NN_<page>.png        422x514 captures (capture_ios_screenshots.sh --set watch)
 -> watch-composed/<lang>/NN_<page>_422x514.png + compose.json   (APP_WATCH_ULTRA)

A Watch panel is the Watch's screen and nothing else: 422x514 pixels is the
size App Store Connect's APP_WATCH_ULTRA set takes for the Apple Watch Ultra 3,
and a caption at that size would be unreadable. So this "composes" by checking
each capture and writing it opaque: simctl writes Watch screenshots with an
alpha channel (measured on the Ultra 3 simulator, 1.56), which App Store
Connect refuses for a screenshot, so any transparent pixel is laid on black,
the Watch's own canvas, and the panel is saved as 8-bit RGB.

As with the iPhone, iPad and Mac compositors, a set is published only whole:
every page present, every capture exactly 422x514 (an iPhone or iPad capture
is refused, App Review guideline 2.3.3), every panel uploadable
(scripts/appstore_screenshots.py panel_problems). Then compose.json records
each panel's md5, each capture's md5 and the Pillow it was written with. A
failing run leaves its panels in watch-composed/<lang>.rejected/ and withdraws
the earlier compose.json, so nothing pushes a set it did not write.

Usage:
    compose_appstore_watch_screenshots.py --lang ja
    compose_appstore_watch_screenshots.py --all
    compose_appstore_watch_screenshots.py --lang en --in DIR --out DIR

Until 1.56 this file composed 820x1004 captioned panels (a size App Store
Connect does not take for a Watch) from screenshots/watch/, which an AppKit
script drew with figures of its own; both were retired with this layout.
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

PLATFORM = shots.WATCH
CAPTURE_SIZE = PLATFORM.canvas      # the capture is the panel
BACKDROP = (0, 0, 0)                # the Watch's canvas, under any transparent pixel


def compose_one(src: Path, dst: Path) -> list[str]:
    """Write one panel; return why it is not fit to upload (empty = fine)."""
    from PIL import Image
    problems = []
    shot = Image.open(src)
    if shot.size != CAPTURE_SIZE:
        problems.append(f"{src.name} is {shot.width}x{shot.height}, not the "
                        f"{CAPTURE_SIZE[0]}x{CAPTURE_SIZE[1]} of an Apple Watch Ultra 3 capture, "
                        f"which the {PLATFORM.name} set is made of")
    rgba = shot.convert("RGBA")
    flat = Image.new("RGBA", rgba.size, BACKDROP + (255,))
    flat.alpha_composite(rgba)
    dst.parent.mkdir(parents=True, exist_ok=True)
    flat.convert("RGB").save(dst, "PNG", optimize=True)
    problems += shots.panel_problems(dst, PLATFORM)
    see_through = sum(1 for a in rgba.getchannel("A").getdata() if a < 255)
    print(f"  {src.name} -> {dst.name}"
          + (f" ({see_through} transparent pixel(s) laid on black)" if see_through else ""))
    for p in problems:
        print(f"    FAIL {p}")
    return problems


def compose_lang(lang: str, in_dir: Path | None = None, out_dir: Path | None = None) -> list[str]:
    common.require_pillow()
    import PIL
    lang = shots.canonical_lang(lang)
    in_dir = in_dir or shots.raw_dir(lang, platform=PLATFORM)
    out_dir = out_dir or shots.composed_dir(lang, platform=PLATFORM)
    srcs = sorted(in_dir.glob("[0-9][0-9]_*.png"))
    names = {p.stem for p in srcs}
    expected = shots.stems(PLATFORM)
    problems = []
    missing = [s for s in expected if s not in names]
    unknown = sorted(names - set(expected))
    if missing:
        problems.append(f"{lang}: no capture for {', '.join(missing)} in {in_dir}")
    if unknown:
        problems.append(f"{lang}: {', '.join(unknown)} in {in_dir} is not a page of the set")
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        common.withdraw_set(out_dir, shots.MANIFEST)
        return problems

    print(f"[{PLATFORM.name} {lang}] {len(srcs)} capture(s) from {in_dir}")
    out_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{out_dir.name}.staging-", dir=out_dir.parent))
    try:
        for src in srcs:
            problems += compose_one(src, staging / shots.composed_name(src.stem, PLATFORM))
        if problems:
            rejected = common.rejected_dir(out_dir)
            shutil.rmtree(rejected, ignore_errors=True)
            staging.rename(rejected)
            print(f"  [{lang}] NOT PUBLISHED: this run's panels are in {rejected} for a look; "
                  f"{out_dir} was not updated")
            common.withdraw_set(out_dir, shots.MANIFEST)
            return problems
        record = {
            "captures": {p.name: shots.md5_of(p) for p in srcs},
            "pillow": PIL.__version__,
        }
        common.publish_set(staging, out_dir,
                           lambda d: shots.write_manifest(d, lang, record, platform=PLATFORM))
        print(f"  [{lang}] published to {out_dir} with {shots.MANIFEST}")
        return problems
    except BaseException:
        common.withdraw_set(out_dir, shots.MANIFEST)
        raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    which = ap.add_mutually_exclusive_group(required=True)
    which.add_argument("--lang", help="one language (" + ", ".join(shots.LANGS) + ")")
    which.add_argument("--all", action="store_true", help="every language")
    ap.add_argument("--in", dest="in_dir", type=Path, help="captures (default screenshots/watch-raw/<lang>)")
    ap.add_argument("--out", dest="out_dir", type=Path, help="panels (default screenshots/watch-composed/<lang>)")
    args = ap.parse_args()
    if args.all and (args.in_dir or args.out_dir):
        ap.error("--in/--out go with --lang")
    langs = shots.LANGS if args.all else (args.lang,)
    failed = []
    for lang in langs:
        if compose_lang(lang, args.in_dir, args.out_dir):
            failed.append(lang)
    if failed:
        print(f"FAILED: {', '.join(failed)}")
        return 1
    print("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())

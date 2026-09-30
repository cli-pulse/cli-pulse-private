#!/usr/bin/env python3
"""Tests for the iPhone screenshot pipeline's parts that need no simulator.

  * scripts/appstore_screenshots.py: every listing locale has a screenshot
    source; the capture script (bash) names the same screens, languages and
    order; the PNG header check tells an uploadable panel from one App Store
    Connect would refuse; a set is complete only with exactly its five panels;
    a FALLBACK locale is accepted;
  * CLI Pulse Bar/scripts/compose_appstore_ios_screenshots.py: every language
    has a caption for every screen; no caption sells remote control; the
    Traditional Chinese captions use the decided terms (scripts/zh_hant_terms.json);
    lines wrap where each script allows it (kinsoku in Chinese and Japanese,
    spaces in Korean and Spanish, never inside "CLI Pulse" or a Latin word);
    every headline of a set starts at the same height, whatever its subtitle's
    line count, and so does every phone;
  * a composed set is uploadable only with the compose.json a clean compose
    run writes, and only with the panels it records;
  * on macOS with Pillow only: every caption's every character has a glyph in
    the chosen face; a Latin-only face, and a face of the other Chinese region,
    is refused (the negative controls); a trailing 、 is centred on its ink; a
    failing compose run publishes nothing and withdraws the earlier set; on a
    composed set mixing one- and two-line subtitles, every headline is on the
    same pixel rows. On any other machine these are reported as NOT RUN, never
    as passed.

The Mac set (scripts/appstore_screenshots.py MAC, compose_appstore_macos_screenshots.py):

  * the six Mac screens are the Swift store catalog's (QARenderSnapshot), in
    order, and the render script renders the app's six languages;
  * every language has a caption for every Mac screen, and none names what
    only the Developer ID build has, another platform, or a retired feature
    (with a planted term for each gate as its negative control);
  * a Mac panel is 2880x1800 RGB; a Mac set is uploadable only with its
    compose.json, and its raws only while render.json says a clean store render
    drew them: no DEVID_BUILD, no remote control, the right language, no
    warnings or refused requests, a 3x backing scale, Claude and Codex local
    history, the panel beside the usage-history shot, each file's md5 (each
    broken one way at a time, and each must fail);
  * the popover's scale and placement: at least 2.2 px/pt, whole on the
    canvas, and only the usage panel may leave it, through the bottom;
  * on macOS with Pillow only: every Mac caption fits in all six languages at
    a scale of at least 2.2 px/pt, the committed iPhone and Mac sets recompose
    byte-identically from their committed raws (the iPhone sets through the
    compose code both compositors now share), and a render.json from a
    Developer ID build makes the compositor refuse and withdraw the set.

Bare python3 for everything else; CI runs it in repo-hygiene.yml.
"""
from __future__ import annotations

import ast
import inspect
import json
import re
import shutil
import sys
import tempfile
import textwrap
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "CLI Pulse Bar" / "scripts"))
import appstore_listing as listing  # noqa: E402
import appstore_screenshots as shots  # noqa: E402
import compose_appstore_ios_screenshots as compose  # noqa: E402
import compose_appstore_macos_screenshots as compose_mac  # noqa: E402

passed = 0
failed = 0
not_run = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global passed, failed
    if cond:
        print(f"ok:   {name}")
        passed += 1
    else:
        print(f"FAIL: {name}")
        if detail:
            print("      " + str(detail).replace("\n", "\n      ")[:2000])
        failed += 1


# ── the layout, against the listing and the capture script ───────────────────

check("every listing locale has a screenshot source, and nothing else does",
      set(shots.SHOT_SOURCES) == set(listing.LOCALE_SOURCES),
      f"{sorted(shots.SHOT_SOURCES)} vs {sorted(listing.LOCALE_SOURCES)}")
check("every source is one of the app's languages or FALLBACK",
      all(v is shots.FALLBACK or v in shots.LANGS for v in shots.SHOT_SOURCES.values()))
check("es-ES and es-MX share the Spanish set, as they share the Spanish text",
      shots.SHOT_SOURCES["es-ES"] == shots.SHOT_SOURCES["es-MX"] == "es"
      and listing.LOCALE_SOURCES["es-ES"] == listing.LOCALE_SOURCES["es-MX"])
check("file stems are NN_screen in listing order",
      shots.stems() == ["01_overview", "02_providers", "03_cost", "04_sessions", "05_alerts"])

script = (HERE.parent / "CLI Pulse Bar" / "scripts" / "capture_ios_screenshots.sh").read_text()


def bash_array(name: str) -> list[str]:
    m = re.search(rf"^{name}=\(([^)]*)\)", script, re.M)
    return m.group(1).split() if m else []


check("the capture script captures the same screens in the same order",
      bash_array("SCREENS") == list(shots.SCREENS), str(bash_array("SCREENS")))
check("the capture script captures the same languages",
      bash_array("LANGS") == list(shots.LANGS), str(bash_array("LANGS")))
locale_cases = dict(re.findall(r"^\s+([A-Za-z-]+)\) echo ([a-z]{2}_[A-Z]{2}) ;;", script, re.M))
check("the capture script has an -AppleLocale for every language, in that language",
      set(locale_cases) == set(shots.LANGS)
      and all(v.split("_")[0] == k.split("-")[0] for k, v in locale_cases.items()),
      str(locale_cases))
check("Traditional Chinese is captured with Taiwan's locale (the zh-Hant terms are Taiwan's)",
      locale_cases.get("zh-Hant") == "zh_TW", str(locale_cases))

# ── the PNG check ────────────────────────────────────────────────────────────

tmp = Path(tempfile.mkdtemp(prefix="appstore-shots-test-"))
good = tmp / "good.png"
shots.write_png(good, 1290, 2796)
check("an 8-bit RGB 1290x2796 PNG is uploadable", shots.panel_problems(good) == [],
      str(shots.panel_problems(good)))

cases = {
    "RGBA": dict(color_type=6),
    "grayscale+alpha": dict(color_type=4),
    "grayscale": dict(color_type=0),
    "tRNS": dict(trns=True),
}
for label, kw in cases.items():
    p = tmp / f"{label}.png"
    shots.write_png(p, 1290, 2796, **kw)
    probs = shots.panel_problems(p)
    check(f"a {label} PNG is refused", bool(probs) and any(label.split("+")[0] in x or "transparency" in x
                                                              for x in probs), str(probs))
small = tmp / "small.png"
shots.write_png(small, 1320, 2868)
check("a raw 1320x2868 capture is refused as a panel",
      any("1320x2868" in x for x in shots.panel_problems(small)), str(shots.panel_problems(small)))
fake = tmp / "fake.png"
fake.write_bytes(b"\xff\xd8\xff\xe0 JPEG pretending")
check("a file that is not a PNG is refused", shots.panel_problems(fake) == ["not a PNG file"],
      str(shots.panel_problems(fake)))
big = tmp / "big.png"
big.write_bytes(good.read_bytes() + b"\0" * (shots.MAX_BYTES + 1))
check("a panel over 10 MB is refused", any("limit" in x for x in shots.panel_problems(big)),
      str(shots.panel_problems(big)))
check("a missing panel is reported as missing", shots.panel_problems(tmp / "nope.png") == ["missing"])

# ── sets and --require-shots ─────────────────────────────────────────────────

root = tmp / "repo"
for lang in shots.LANGS:
    for p in shots.expected_composed(lang, root):
        shots.write_png(p, 1290, 2796)
    shots.write_manifest(shots.composed_dir(lang, root), lang)
check("a complete tree satisfies --require-shots for every listing locale",
      shots.require_shots_problems(listing.LOCALE_SOURCES, root) == [],
      str(shots.require_shots_problems(listing.LOCALE_SOURCES, root)))
shots.expected_composed("ko", root)[3].unlink()
(shots.composed_dir("ja", root) / "06_settings_1290x2796.png").write_bytes(good.read_bytes())
probs = shots.require_shots_problems(listing.LOCALE_SOURCES, root)
check("a missing panel and a stray one are both reported, against their locales",
      ("ko", "ko: 04_sessions_1290x2796.png: missing") in probs
      and any(loc == "ja" and "06_settings" in why for loc, why in probs), str(probs))

# compose.json: the set is what a clean compose run wrote, or it is not uploadable.
m_root = tmp / "manifest"
for p in shots.expected_composed("en", m_root):
    shots.write_png(p, 1290, 2796)
check("valid PNGs without compose.json are not a set",
      any("compose.json is missing" in x for x in shots.set_problems("en", m_root)),
      str(shots.set_problems("en", m_root)))
shots.write_manifest(shots.composed_dir("en", m_root), "en")
check("the same PNGs with compose.json are", shots.set_problems("en", m_root) == [],
      str(shots.set_problems("en", m_root)))
changed = shots.expected_composed("en", m_root)[2]
changed.write_bytes(changed.read_bytes() + b"x")
check("a panel replaced after the compose run is refused, by name",
      any(x.startswith("03_cost_1290x2796.png: not the file") for x in shots.set_problems("en", m_root)),
      str(shots.set_problems("en", m_root)))
shots.write_manifest(shots.composed_dir("en", m_root), "en")
(shots.composed_dir("en", m_root) / shots.MANIFEST).write_text(
    (shots.composed_dir("en", m_root) / shots.MANIFEST).read_text().replace('"lang": "en"', '"lang": "ja"'))
check("a compose.json written for another language is refused",
      any("not 'en'" in x for x in shots.set_problems("en", m_root)), str(shots.set_problems("en", m_root)))
(shots.composed_dir("en", m_root) / shots.MANIFEST).write_text("{not json")
check("an unreadable compose.json is refused",
      any("unreadable" in x for x in shots.set_problems("en", m_root)), str(shots.set_problems("en", m_root)))

es_probs = shots.require_shots_problems(["es-ES", "es-MX"], tmp / "empty")
check("es-ES and es-MX both fail when the Spanish set is missing",
      {loc for loc, _ in es_probs} == {"es-ES", "es-MX"}, str(es_probs))
saved = dict(shots.SHOT_SOURCES)
try:
    shots.SHOT_SOURCES["ko"] = shots.FALLBACK
    check("a locale mapped to FALLBACK needs no set of its own",
          not any(loc == "ko" for loc, _ in shots.require_shots_problems(["ko"], tmp / "empty")))
    del shots.SHOT_SOURCES["ko"]
    check("a listing locale with no SHOT_SOURCES entry fails",
          any(loc == "ko" and "SHOT_SOURCES" in why
              for loc, why in shots.require_shots_problems(["ko"], root)))
finally:
    shots.SHOT_SOURCES.clear()
    shots.SHOT_SOURCES.update(saved)

# The caption check reads COPY from the compositor. A fixture root may have no
# compositor and skips it (m_root above); the real repo must not, or moving the
# compositor would switch the check off without a word.
UNCHECKABLE = "the captions cannot be checked"
check("on the real repo the caption check has the compositor's COPY to compare with",
      not any(UNCHECKABLE in x for x in shots.manifest_problems("en")),
      str(shots.manifest_problems("en")))
saved_rel = shots.COMPOSITOR_REL
try:
    shots.COMPOSITOR_REL = "CLI Pulse Bar/scripts/no_such_compositor.py"
    check("on the real repo a missing compositor fails instead of skipping the caption check",
          any(UNCHECKABLE in x for x in shots.manifest_problems("en")),
          str(shots.manifest_problems("en")))
finally:
    shots.COMPOSITOR_REL = saved_rel

# The raw-capture check (--require-shots; test_asc_listing_preflight.sh breaks
# the real captures one way at a time). Same split as the caption check: a
# fixture set may record no captures and is not checked, this checkout's may not.
check("on the real repo every raw capture is the one its compose.json records",
      all(shots.capture_problems(lang) == [] for lang in shots.LANGS),
      str({lang: shots.capture_problems(lang) for lang in shots.LANGS}))
check("a fixture set that records no captures is not checked for them",
      shots.capture_problems("en", root) == [], str(shots.capture_problems("en", root)))
saved_checkout = shots.CHECKOUT
try:
    shots.CHECKOUT = root
    check("on the real repo a compose.json that records no captures fails, and --require-shots says so",
          any("records no captures" in why for loc, why in shots.require_shots_problems(["en-US"], root)),
          str(shots.require_shots_problems(["en-US"], root)))
finally:
    shots.CHECKOUT = saved_checkout

# ── captions ─────────────────────────────────────────────────────────────────

check("every language has a caption for every screen, and no other",
      all(set(compose.COPY.get(lang, {})) == set(shots.stems()) for lang in shots.LANGS)
      and set(compose.COPY) == set(shots.LANGS))
check("every caption has a title and a subtitle",
      all(t.strip() and s.strip() for lang in compose.COPY for t, s in compose.COPY[lang].values()))

remote = re.compile(r"remote|远程|遠端|遠程|リモート|원격|remot", re.I)
selling = [f"{lang} {st}" for lang in compose.COPY for st, (t, s) in compose.COPY[lang].items()
           if remote.search(t + s)]
check("no caption sells remote control (the App Store Mac build cannot do it)", not selling,
      str(selling))

terms = json.loads((HERE / "zh_hant_terms.json").read_text())
forbidden = [w for c in terms["concepts"] for w in c["apple"]["forbid"]]
bad = [f"{st}: {w}" for st, (t, s) in compose.COPY["zh-Hant"].items() for w in forbidden if w in t + s]
check("Traditional Chinese captions use the decided terms (工作階段, 警示, 服務商 …)", not bad, str(bad))
simplified = [f"{st}: {c}" for st, (t, s) in compose.COPY["zh-Hant"].items() for c in t + s if c in "会话费额备进单这发们时"]
check("Traditional Chinese captions contain no Simplified characters", not simplified, str(simplified))
es_words = " ".join(t + " " + s for t, s in compose.COPY["es"].values()).lower()
check("Spanish captions say costo, as the app does, not coste",
      "coste" not in es_words and "costo" in es_words)
brand = [f"{lang} {st}" for lang in compose.COPY for st, (t, s) in compose.COPY[lang].items()
         if re.search(r"CLI\s*Pulse", t + s) and "CLI Pulse" not in t + s]
check("\"CLI Pulse\" is always two words", not brand, str(brand))

# ── line breaking ────────────────────────────────────────────────────────────


def width(text: str) -> float:
    """A monospace stand-in: CJK and Hangul count 2, everything else 1."""
    return sum(2 if ord(c) > 0x2E80 else 1 for c in text)


def wrap(text: str, lang: str, max_w: float) -> list[str] | None:
    return compose.wrap(text, lang, width, max_w)


check("text that fits stays on one line", wrap("用量、费用", "zh-Hans", 40) == ["用量、费用"])
lines = wrap("用量、费用、会话和告警，打开就能看到", "zh-Hans", 26)
check("Chinese prefers a break after punctuation",
      lines is not None and lines[0].endswith(("，", "、")), str(lines))
lines = wrap("上限に達する前に、残りがわかる", "ja", 20)
check("Japanese breaks after 、 and never starts a line with it",
      lines == ["上限に達する前に、", "残りがわかる"], str(lines))
# Kinsoku: with only character breaks available, none may start with 。」ー or a small kana.
for text, lang in [("アラートでお知らせします。", "ja"), ("「警示」會提醒你", "zh-Hant"),
                   ("クォータとコスト", "ja"), ("セッションを記録", "ja")]:
    for max_w in range(6, width(text)):
        got = wrap(text, lang, max_w)
        if got and len(got) == 2:
            if got[1][0] in compose.NO_LINE_START or got[0][-1] in compose.NO_LINE_END:
                check(f"kinsoku holds for {text!r}", False, f"{max_w}: {got}")
                break
    else:
        check(f"kinsoku holds for {text!r} at every width", True)
cands = [c for c, _, _ in compose.break_candidates("クォータ", "ja")]
check("no break before a small kana or the long-vowel mark",
      2 not in cands and 1 not in cands, str(cands))
lines = wrap("每次 CLI 运行都有记录", "zh-Hans", 12)
check("Chinese never breaks inside a Latin word",
      lines is not None and all("CL" not in ln or "CLI" in ln for ln in lines), str(lines))
cands = compose.break_candidates("Monitor CLI Pulse today", "en")
check("\"CLI Pulse\" is never split",
      all(not "Monitor CLI Pulse today"[:c[0]].endswith("CLI") for c in cands), str(cands))
lines = wrap("할당량, CPU 급증, 오래 실행되는 세션을 알림으로", "ko", 28)
check("Korean breaks only at spaces",
      lines is not None and " ".join(lines) == "할당량, CPU 급증, 오래 실행되는 세션을 알림으로", str(lines))
check("Korean never breaks inside a word", not compose.break_candidates("세션을알림으로", "ko"))
lines = wrap("Alertas de cuota, picos de CPU y sesiones demasiado largas", "es", 40)
check("Spanish breaks at spaces, balanced", lines is not None and len(lines) == 2
      and " ".join(lines) == "Alertas de cuota, picos de CPU y sesiones demasiado largas"
      and abs(len(lines[0]) - len(lines[1])) < 20, str(lines))
lines = wrap("すべてを​ひと目で見る", "ja", 12)
check("a U+200B is a preferred break and is never drawn",
      lines == ["すべてを", "ひと目で見る"], str(lines))
check("nothing fits: None, not a clipped line", wrap("Averyveryverylongword", "en", 5) is None)

# ── caption layout ───────────────────────────────────────────────────────────
# Every panel of a set reserves room for the set's tallest subtitle. App Store
# Connect shows the panels side by side, so in a set mixing one- and two-line
# subtitles a one-line panel's headline must start where a two-line panel's
# does; centring the caption in the room dropped it half a line.
t_box, s_box = round(100 * compose.LINE_BOX), round(46 * compose.LINE_BOX)
one, two = (compose.caption_layout(t_box, s_box, n, 2) for n in (1, 2))
check("in a set mixing one- and two-line subtitles, every headline and subtitle starts at the same y",
      one.title_y == two.title_y and one.sub_ys[0] == two.sub_ys[0], f"{one} vs {two}")
check("... and every phone too",
      one.shot_top == two.shot_top, f"{one} vs {two}")
check("the headline is at the top of the room, the subtitle directly under it",
      one.title_y == compose.TEXT_TOP_MARGIN
      and one.sub_ys == (one.title_y + t_box + compose.TITLE_TO_SUB_GAP,)
      and two.sub_ys[1] == two.sub_ys[0] + s_box + compose.SUB_LINE_GAP, f"{one} / {two}")
alone = compose.caption_layout(t_box, s_box, 1, 1)
check("a set of one-line subtitles reserves one line, so its phone starts one line higher",
      alone.title_y == one.title_y
      and alone.shot_top == one.shot_top - s_box - compose.SUB_LINE_GAP, f"{alone} vs {one}")
# The checks above test caption_layout alone; the pixel test that proves
# compose_one draws with it needs macOS fonts and is NOT RUN in CI. So check
# the source too: compose_one calls caption_layout and uses none of the
# spacing constants it owns, which any caption layout of its own would need.
_one = ast.parse(textwrap.dedent(inspect.getsource(compose.compose_one)))
_calls = {n.func.id for n in ast.walk(_one) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
_owned = {"TEXT_TOP_MARGIN", "TITLE_TO_SUB_GAP", "SUB_LINE_GAP", "TEXT_TO_SHOT_GAP"}
_used = {n.id for n in ast.walk(_one) if isinstance(n, ast.Name)} & _owned
check("compose_one places its caption and phone with caption_layout, not its own arithmetic",
      "caption_layout" in _calls and not _used,
      f"calls caption_layout: {'caption_layout' in _calls}; uses {sorted(_used)}")

# ── fonts (macOS with Pillow only) ───────────────────────────────────────────

fonts_here = compose.ImageFont is not None and Path("/System/Library/Fonts/SFNS.ttf").exists()
if fonts_here:
    for lang in shots.LANGS:
        faces, probs = compose.pick_faces(lang)
        check(f"{lang}: every caption character has a glyph in the chosen faces",
              not probs and set(faces) == {"title", "subtitle"}, str(probs))
    faces, _ = compose.pick_faces("zh-Hant")
    check("Traditional Chinese uses a Traditional (TC) face",
          all(f.family and f.family.endswith("TC") for f in faces.values()), str(faces))
    saved_faces = compose.FACES["zh-Hant"]
    try:
        compose.FACES["zh-Hant"] = {"title": [compose.Face(compose.SF, weight=600)],
                                    "subtitle": [compose.Face(compose.SF)]}
        _, probs = compose.pick_faces("zh-Hant")
        check("negative control: a Latin-only face is refused for Traditional Chinese",
              len(probs) == 2 and all("cannot draw" in p for p in probs), str(probs))
        font = compose.load_face(compose.Face(compose.SF), 64)
        check("negative control: SF has no 臺, and the check says so",
              not compose.has_glyph(font, "臺") and compose.has_glyph(font, "A"))

        # PingFang SC has every Traditional glyph the captions use, so coverage
        # alone would accept it for Taiwan; the regional probe must not.
        compose.FACES["zh-Hant"] = {r: [f for f in compose.FACES["zh-Hans"][r]]
                                    for r in ("title", "subtitle")}
        sc_font = compose.load_face(compose.FACES["zh-Hans"]["title"][0], 64)
        check("PingFang SC has a glyph for every zh-Hant caption character (why coverage is not enough)",
              all(compose.has_glyph(sc_font, c) for c in compose.caption_chars("zh-Hant")))
        _, probs = compose.pick_faces("zh-Hant")
        check("negative control: a Simplified (SC) face is refused for Traditional Chinese",
              len(probs) == 2 and all("other region's shape" in p for p in probs), str(probs))
    finally:
        compose.FACES["zh-Hant"] = saved_faces
    saved_sc = compose.FACES["zh-Hans"]
    try:
        compose.FACES["zh-Hans"] = {r: list(saved_faces[r]) for r in ("title", "subtitle")}
        _, probs = compose.pick_faces("zh-Hans")
        check("negative control: a Traditional (TC) face is refused for Simplified Chinese",
              len(probs) == 2 and all("other region's shape" in p for p in probs), str(probs))
    finally:
        compose.FACES["zh-Hans"] = saved_sc

    # A line ending in 、 is centred on its ink, not on its advance.
    ja_sub = compose.load_face(compose.pick_faces("ja")[0]["subtitle"], 46)
    plain, trailing = "使用量、コスト", "使用量、コスト、"
    blank = compose.trailing_blank(ja_sub, "、")
    check("a trailing 、 does not count its blank half when centring",
          ja_sub.size * 0.4 < blank < ja_sub.size * 0.8
          and abs(compose.centering_width(trailing, ja_sub)
                  - (ja_sub.getlength(trailing) - blank)) < 0.01
          and compose.centering_width(plain, ja_sub) == ja_sub.getlength(plain),
          f"blank {blank} at {ja_sub.size}pt")

    # A failing compose run publishes nothing and withdraws the earlier set.
    from PIL import Image as _Image
    raw = tmp / "compose-raw"
    for st in shots.stems():
        raw.mkdir(parents=True, exist_ok=True)
        _Image.new("RGB", (1320, 2868), (240, 242, 246)).save(raw / f"{st}.png")
    out = tmp / "compose-out" / "ko"
    import contextlib
    import io
    with contextlib.redirect_stdout(io.StringIO()):
        good_run = compose.compose_lang("ko", raw, out)
    manifest = out / shots.MANIFEST
    check("a clean compose run publishes the set with compose.json",
          good_run == [] and manifest.is_file()
          and sorted(p.name for p in out.glob("*.png")) == [shots.composed_name(s) for s in shots.stems()]
          and not compose.rejected_dir(out).exists()
          and not any(p.name.startswith(".ko.") for p in out.parent.iterdir()),
          str(good_run))
    before = {p.name: p.read_bytes() for p in out.glob("*.png")}
    saved_copy = compose.COPY["ko"]["03_cost"]
    try:
        compose.COPY["ko"]["03_cost"] = (saved_copy[0], "공급자별 " * 60)
        with contextlib.redirect_stdout(io.StringIO()) as log:
            bad_run = compose.compose_lang("ko", raw, out)
    finally:
        compose.COPY["ko"]["03_cost"] = saved_copy
    check("a failing run leaves the published panels as they were, and withdraws compose.json",
          bad_run and {p.name: p.read_bytes() for p in out.glob("*.png")} == before
          and not manifest.exists(), log.getvalue())
    check("... and puts its own panels in <out>.rejected for a look",
          sorted(p.name for p in compose.rejected_dir(out).glob("*.png"))
          == [shots.composed_name(s) for s in shots.stems()], log.getvalue())
    check("... and leaves no staging directory behind",
          not any(p.name.startswith(".ko.") for p in out.parent.iterdir()),
          str(list(out.parent.iterdir())))
    with contextlib.redirect_stdout(io.StringIO()):
        again = compose.compose_lang("ko", raw, out)
    check("the next clean run publishes again and clears the rejected panels",
          again == [] and manifest.is_file() and not compose.rejected_dir(out).exists(), str(again))
    # A panel that raises (a truncated capture, Ctrl-C) is a failed run too.
    saved_one = compose.compose_one
    calls = {"n": 0}

    def raising_compose_one(*a, **k):
        calls["n"] += 1
        if calls["n"] == 3:
            raise OSError("truncated capture")
        return saved_one(*a, **k)
    raised = None
    try:
        compose.compose_one = raising_compose_one
        with contextlib.redirect_stdout(io.StringIO()):
            compose.compose_lang("ko", raw, out)
    except OSError as e:
        raised = e
    finally:
        compose.compose_one = saved_one
    check("a panel that raises withdraws the published set's compose.json and re-raises",
          raised is not None and calls["n"] == 3 and not manifest.exists()
          and not any(p.name.startswith(".ko.") for p in out.parent.iterdir()),
          f"raised={raised!r} manifest={manifest.exists()}")

    # The headline rule on the pixels: one headline over all five panels,
    # subtitles alternating one and two lines (the one-line one is the other's
    # first line, so it draws the same ink), composed and measured.
    from PIL import ImageChops as _Chops
    FIXTURE_RGB = (240, 242, 246)   # the raw captures above

    def ink_rows(img, lo: int, hi: int, floor: int):
        """(first, last) row in [lo, hi) with a pixel whose every channel is >= floor."""
        chans = [c.point(lambda v: 255 if v >= floor else 0)
                 for c in img.crop((0, lo, img.width, hi)).split()]
        box = _Chops.darker(_Chops.darker(chans[0], chans[1]), chans[2]).getbbox()
        return None if box is None else (lo + box[1], lo + box[3] - 1)

    def phone_top(img) -> int | None:
        """The first row whose middle 200 px are all the capture's colour."""
        mid = img.width // 2
        for y in range(img.height):
            if set(img.crop((mid - 100, y, mid + 100, y + 1)).getdata()) == {FIXTURE_RGB}:
                return y
        return None

    es_faces = compose.pick_faces("es")[0]
    long_sub = "Alertas de cuota, picos de CPU y sesiones de larga duración"
    long_lines = compose.subtitle_lines(long_sub, "es", es_faces["subtitle"], compose.SUB_SIZE_MAX) or []
    short_sub = long_lines[0] if long_lines else long_sub
    mixed = {st: ("Todo de un vistazo", long_sub if i % 2 else short_sub)
             for i, st in enumerate(shots.stems())}
    saved_es = dict(compose.COPY["es"])
    out_es = tmp / "compose-out" / "es"
    try:
        compose.COPY["es"].update(mixed)
        with contextlib.redirect_stdout(io.StringIO()) as log:
            es_run = compose.compose_lang("es", raw, out_es)
        n_lines = [len(compose.subtitle_lines(s, "es", es_faces["subtitle"], compose.SUB_SIZE_MAX) or [])
                   for _, s in mixed.values()]
    finally:
        compose.COPY["es"].clear()
        compose.COPY["es"].update(saved_es)
    check("the headline fixture composes, and mixes one- and two-line subtitles",
          es_run == [] and n_lines == [1, 2, 1, 2, 1], f"{es_run} {n_lines}\n{log.getvalue()}")
    measured = {}
    for st in shots.stems():
        img = _Image.open(out_es / shots.composed_name(st)).convert("RGB")
        top = phone_top(img)
        # Only the white title reaches 215 in every channel; the grey subtitle
        # (175, 182, 200) never does, and anything above 120 is one of the two.
        title = ink_rows(img, 0, top or 0, 215) if top else None
        sub = ink_rows(img, title[1] + 1, top, 120) if title else None
        measured[st] = (title, sub[0] if sub else None, top,
                        img.crop((0, top, img.width, img.height)).tobytes() if top else None)
    detail = "\n".join(f"{st}: headline rows {m[0]}, subtitle from row {m[1]}, phone from row {m[2]}"
                       for st, m in measured.items())
    check("every panel's headline is on the same rows when subtitles mix one and two lines",
          None not in {m[0] for m in measured.values()} and len({m[0] for m in measured.values()}) == 1,
          detail)
    check("... and so is its subtitle's first line",
          None not in {m[1] for m in measured.values()} and len({m[1] for m in measured.values()}) == 1,
          detail)
    check("... and the phone starts on the same row, drawn the same, on every panel",
          None not in {m[2] for m in measured.values()}
          and len({(m[2], m[3]) for m in measured.values()}) == 1, detail)
else:
    not_run += 1
    print("NOT RUN: glyph coverage (needs macOS system fonts and Pillow); "
          "run this file on a Mac, or compose_appstore_ios_screenshots.py --check-fonts")

# ══ the Mac set ══════════════════════════════════════════════════════════════
MAC = shots.MAC
MAC_STEMS = shots.stems(MAC)

swift = (HERE.parent / "CLI Pulse Bar" / "CLIPulseCore" / "Sources" / "CLIPulseCore"
         / "QARenderSnapshot.swift").read_text(encoding="utf-8")
rows = re.findall(r'\("(\w+)", \.demo\(\.(\w+)\), \.(first|last|lastAligned), (true|false)\)', swift)
check("the Mac screens are the Swift store catalog's, in the same order",
      [r[0] for r in rows] == list(shots.MAC_SCREENS), f"{rows} vs {shots.MAC_SCREENS}")
check("the cost screen is the only one scrolled to its end, and it opens above a card (lastAligned)",
      [(r[0], r[2]) for r in rows if r[2] != "first"] == [("cost", "lastAligned")], str(rows))
check("... and the screens drawn with the usage panel are the same",
      [r[0] for r in rows if r[3] == "true"] == list(shots.MAC_PANEL_SCREENS), str(rows))
check("Mac stems are NN_screen in listing order",
      MAC_STEMS == ["01_overview", "02_providers", "03_usage_history", "04_cost", "05_alerts",
                    "06_pulse_cat"], str(MAC_STEMS))
check("the Mac raw set is the six popovers and the usage panel beside the third",
      shots.raw_names(MAC) == ["01_overview.png", "02_providers.png", "03_usage_history.png",
                               "03_usage_history.panel.png", "04_cost.png", "05_alerts.png",
                               "06_pulse_cat.png"], str(shots.raw_names(MAC)))
render_sh = (HERE / "render_macos_qa_views.sh").read_text()
m = re.search(r"^ALL_LANGUAGES=\(([^)]*)\)", render_sh, re.M)
check("the render script renders the app's six languages",
      m is not None and m.group(1).split() == list(shots.LANGS), m.group(1) if m else "no ALL_LANGUAGES")
check("the iPhone platform is still the default of every helper",
      shots.stems() == shots.stems(shots.IPHONE) and shots.CANVAS == shots.IPHONE.canvas
      and shots.composed_dir("en").name == "en" and "ios-composed" in str(shots.composed_dir("en")))

# ── Mac captions ─────────────────────────────────────────────────────────────

check("every language has a Mac caption for every Mac screen, and no other",
      set(compose_mac.COPY) == set(shots.LANGS)
      and all(set(compose_mac.COPY[lang]) == set(MAC_STEMS) for lang in shots.LANGS),
      str({lang: sorted(compose_mac.COPY.get(lang, {})) for lang in shots.LANGS}))
check("every Mac caption has a title and a subtitle",
      all(t.strip() and s_.strip() for lang in compose_mac.COPY for t, s_ in compose_mac.COPY[lang].values()))


def mac_caption_problems(copy: dict) -> list[str]:
    """Every gate a Mac caption must pass, in every language."""
    out = []
    forbid_zh_hant = listing.zh_hant_forbidden_terms()
    for lang, table in copy.items():
        for st, (t, s_) in table.items():
            text = (t + " " + s_).replace(compose.ZWSP, "")
            for hit in listing.devid_only_terms_in(text):
                out.append(f"{lang} {st}: names a Developer ID-only feature ({hit})")
            for hit in listing.platform_terms_in(text):
                out.append(f"{lang} {st}: names another platform ({hit})")
            for term in compose_mac.MAC_CAPTION_DENYLIST:
                latin = term.isascii()
                pat = (r"(?<![A-Za-z0-9_])" + re.escape(term.strip()) + r"(?![A-Za-z0-9_])") if latin else None
                if (latin and re.search(pat, text, re.I)) or (not latin and term in text):
                    out.append(f"{lang} {st}: names {term.strip()!r}, which the Mac App Store build "
                               "does not have or the listing no longer sells")
            if remote.search(text):
                out.append(f"{lang} {st}: sells remote control")
            if lang != "en" and listing.english_lines(text, cjk=lang in ("zh-Hans", "zh-Hant", "ja", "ko")):
                out.append(f"{lang} {st}: English left in the translation: {text!r}")
            if lang == "zh-Hant":
                out += [f"zh-Hant {st}: {w} (use {forbid_zh_hant[w]})" for w in forbid_zh_hant if w in text]
                out += [f"zh-Hant {st}: Simplified {c}" for c in text if c in "会话费额备进单这发们时"]
            if lang == "es" and re.search(r"\bcoste", text, re.I):
                out.append(f"es {st}: says 'coste'; the app says 'costo'")
            if re.search(r"CLI\s*Pulse", text) and "CLI Pulse" not in text:
                out.append(f"{lang} {st}: 'CLI Pulse' is two words")
    return out


check("no Mac caption, in any language, sells what the Mac App Store build lacks or another platform",
      mac_caption_problems(compose_mac.COPY) == [], "\n".join(mac_caption_problems(compose_mac.COPY)))
for label, lang, planted in [
        ("a Developer ID-only feature", "en", "Remote Control from your iPhone"),
        ("Homebrew (the Mac denylist)", "es", "Instálalo con Homebrew"),
        ("the fan (the Mac denylist, Japanese)", "ja", "ファンの回転数も"),
        # Only MAC_CAPTION_DENYLIST names this one: devid_only_terms_in knows
        # the fan by "ファンの回転" alone, so a denylist without ファン passed.
        ("the fan in words only the Mac denylist knows (Japanese)", "ja", "静かなファンで快適に"),
        ("another platform", "ko", "Android에서도"),
        ("a Taiwan-forbidden term", "zh-Hant", "會話與告警"),
        ("English left in a translation", "zh-Hans", "see what is left for your team and the rest of it"),
]:
    planted_copy = {lang: {"06_pulse_cat": (compose_mac.COPY[lang]["06_pulse_cat"][0], planted)}}
    check(f"negative control: a Mac caption naming {label} is caught",
          mac_caption_problems(planted_copy) != [], planted)

# ── Mac panels, sets and render.json (fixtures, no Pillow) ──────────────────

good_mac = tmp / "mac-good.png"
shots.write_png(good_mac, 2880, 1800)
check("a 2880x1800 RGB PNG is an uploadable Mac panel", shots.panel_problems(good_mac, MAC) == [],
      str(shots.panel_problems(good_mac, MAC)))
check("an iPhone-sized panel is refused as a Mac panel, and a Mac one as an iPhone panel",
      any("1290x2796" in x for x in shots.panel_problems(good, MAC))
      and any("2880x1800" in x for x in shots.panel_problems(good_mac)))
rgba_mac = tmp / "mac-rgba.png"
shots.write_png(rgba_mac, 2880, 1800, color_type=6)
check("an RGBA Mac panel is refused", any("RGBA" in x for x in shots.panel_problems(rgba_mac, MAC)))


# The cost shot opens above a card in a shortened popover (QARenderSnapshot
# alignedTrim); the fixtures give it a 551-point one, as the 1.54 renders
# measured (1.55's measure 458).
MAC_ALIGNED = {"04_cost": 551}


def mac_render(raw: Path, lang: str, **over) -> dict:
    """A render.json a clean store render of `lang` would write for the files in `raw`."""
    renders, shot_rows = [], []
    for st in MAC_STEMS:
        f = raw / f"{st}.png"
        h = MAC_ALIGNED.get(st, 580)
        renders.append({"file": f.name, "width": 380, "height": h, "pixelWidth": 1140,
                        "pixelHeight": h * 3, "suspectBlank": False})
        row = {"id": st, "file": f.name, "md5": shots.md5_of(f),
               "page": "lastAligned" if st in MAC_ALIGNED else "first"}
        if st in MAC_ALIGNED:
            row["popoverHeight"] = MAC_ALIGNED[st]
        q = raw / f"{st}.panel.png"
        if q.exists():
            renders.append({"file": q.name, "width": 520, "height": 862, "pixelWidth": 1560,
                            "pixelHeight": 2586, "suspectBlank": False})
            row.update(panelFile=q.name, panelMD5=shots.md5_of(q))
        shot_rows.append(row)
    data = {"set": "store", "language": lang, "localeOverride": lang, "resolvedLocalization": lang,
            "displayLocale": f"{lang}_{shots.MAC_REGIONS[lang]}",
            "localizationActive": True, "scale": 3, "windowBackingScale": 3, "warnings": [],
            "blockedRequests": [], "renders": renders, "shots": shot_rows,
            "app": {"version": "1.54.0", "build": "107"},
            "variant": {"devidBuild": False, "debugBuild": True, "sandboxed": False, "channel": "qa",
                        "remoteControlAvailable": False, "popoverWidth": 380, "popoverHeight": 580,
                        "panelWidth": 520, "panelSettled": True, "localScanDays": 250,
                        "localScanProviders": ["Claude", "Codex"], "localScanMessages": 15659,
                        "scrollerStyle": "overlay", "panelBackdropLuminance": 0.12}}
    for key, value in over.items():
        if key.startswith("variant."):
            data["variant"][key.split(".", 1)[1]] = value
        else:
            data[key] = value
    return data


def make_mac_set(root: Path, lang: str, **over) -> None:
    raw = shots.raw_dir(lang, root, MAC)
    for name in shots.raw_names(MAC):
        w, h = (1560, 2586) if name.endswith(".panel.png") else (1140, 3 * MAC_ALIGNED.get(name[:-4], 580))
        shots.write_png(raw / name, w, h)
        (raw / name).write_bytes((raw / name).read_bytes() + name.encode())   # distinct md5s
    (raw / shots.RENDER_MANIFEST).write_text(json.dumps(mac_render(raw, lang, **over)))
    out = shots.composed_dir(lang, root, MAC)
    for p_ in shots.expected_composed(lang, root, MAC):
        shots.write_png(p_, 2880, 1800)
    shots.write_manifest(out, lang, {
        "captures": {n: shots.md5_of(raw / n) for n in shots.raw_names(MAC)},
        "render": shots.md5_of(raw / shots.RENDER_MANIFEST),
        "app": {"version": "1.54.0", "build": "107"}}, platform=MAC)


mac_root = tmp / "mac-repo"
for lang in shots.LANGS:
    make_mac_set(mac_root, lang)
clean = shots.require_shots_problems(listing.LOCALE_SOURCES, mac_root, platform=MAC)
check("a complete Mac tree satisfies --require-shots for every listing locale", clean == [], str(clean))
check("... and the iPhone check of the same tree does not count the Mac sets",
      bool(shots.require_shots_problems(["en-US"], mac_root)))
check("compose.json's recorded app version is what the pusher checks",
      shots.composed_app_version("ja", mac_root) == "1.54.0")


def mac_breaks(label: str, needle: str, lang: str = "ko", mutate=None, **over) -> None:
    root = tmp / f"mac-case-{len(label)}-{abs(hash(label)) % 10**6}"
    make_mac_set(root, lang, **over)
    if mutate:
        mutate(root)
    probs = shots.require_shots_problems([next(loc for loc, src in shots.SHOT_SOURCES.items() if src == lang)],
                                         root, platform=MAC)
    check(f"negative control: {label} fails --require-shots, for that reason",
          any(needle in why for _, why in probs), "\n".join(why for _, why in probs) or "no problem reported")


mac_breaks("render.json from a Developer ID build", "DEVID_BUILD", **{"variant.devidBuild": True})
mac_breaks("render.json from a build offering remote control", "remote control",
           **{"variant.remoteControlAvailable": True})
mac_breaks("render.json in another language", "not 'ko'", language="ja")
mac_breaks("render.json with a warning", "warnings", warnings=["the usage panel was still changing"])
mac_breaks("render.json with a refused request", "refused requests", blockedRequests=["https://x.invalid/"])
mac_breaks("render.json at a 1x backing scale", "backing scale", windowBackingScale=1)
mac_breaks("an empty local usage history", "no local usage history", **{"variant.localScanDays": 0})
mac_breaks("a local usage history with Gemini in it", "the scanner records only",
           **{"variant.localScanProviders": ["Claude", "Codex", "Gemini"]})
mac_breaks("an unsettled usage panel", "still changing", **{"variant.panelSettled": False})
mac_breaks("the review set's manifest instead of the store set's", "not the store set", set="review")
mac_breaks("legacy scroll bars (an empty gutter beside every scrolling tab)", "not 'overlay'",
           **{"variant.scrollerStyle": "legacy"})
mac_breaks("a usage panel drawn as a flat gray slab", "flat gray slab",
           **{"variant.panelBackdropLuminance": 0.36})
mac_breaks("a usage panel with no backdrop measurement", "flat gray slab",
           **{"variant.panelBackdropLuminance": None})
mac_breaks("numbers formatted on the render Mac's region", "not on ko's region", displayLocale="ko_US")
mac_breaks("no display locale recorded", "not on ko's region", displayLocale=None)
mac_breaks("a local usage history without messages", "has no messages", **{"variant.localScanMessages": 0})


def rewrite_render(root: Path, change, lang: str = "ko", record: bool = True) -> None:
    """Edit render.json; with `record`, also record the edit in compose.json,
    so that only render_problems can tell."""
    raw = shots.raw_dir(lang, root, MAC)
    f = raw / shots.RENDER_MANIFEST
    data = json.loads(f.read_text())
    change(data)
    f.write_text(json.dumps(data))
    if record:
        m_ = shots.composed_dir(lang, root, MAC) / shots.MANIFEST
        rec = json.loads(m_.read_text())
        rec["render"] = shots.md5_of(f)
        shots.write_manifest(shots.composed_dir(lang, root, MAC), lang,
                             {k: v for k, v in rec.items() if k not in ("lang", "panels")}, platform=MAC)


mac_breaks("a render that looks blank", "looks blank",
           mutate=lambda r: rewrite_render(r, lambda d: d["renders"][4].update(suspectBlank=True)))
mac_breaks("the shots out of order", "shots [",
           mutate=lambda r: rewrite_render(r, lambda d: d["shots"].reverse()))
mac_breaks("a shot missing from render.json", "shots [",
           mutate=lambda r: rewrite_render(r, lambda d: d["shots"].pop(4)))
mac_breaks("a popover drawn 700 points high", "drawn 380x700 points",
           mutate=lambda r: rewrite_render(r, lambda d: d["renders"][0].update(height=700, pixelHeight=2100)))
mac_breaks("a popover drawn at 2x", "760x1160 px",
           mutate=lambda r: rewrite_render(r, lambda d: d["renders"][0].update(pixelWidth=760, pixelHeight=1160)))
mac_breaks("a shortened popover on a page that is not lastAligned", "only a lastAligned page may shorten",
           mutate=lambda r: rewrite_render(r, lambda d: d["shots"][4].update(popoverHeight=551)))
mac_breaks("a popover shortened under the 400 points users can set", "only a lastAligned page may shorten",
           mutate=lambda r: rewrite_render(r, lambda d: d["shots"][3].update(popoverHeight=380)))
mac_breaks("a popover shortened by a fraction of a point", "only a lastAligned page may shorten",
           mutate=lambda r: rewrite_render(r, lambda d: d["shots"][3].update(popoverHeight=551.5)))
mac_breaks("the shortened popover's raw at the pinned height", "04_cost.png: drawn",
           mutate=lambda r: rewrite_render(r, lambda d: d["shots"][3].pop("popoverHeight")))
mac_breaks("a render.json edited after the panels were composed", "not the one compose.json records",
           mutate=lambda r: rewrite_render(r, lambda d: d.update(generatedAt="later"), record=False))
mac_breaks("a stray render.log committed beside the raws", "not part of the store set: render.log",
           mutate=lambda r: (shots.raw_dir("ko", r, MAC) / "render.log").write_text("build log"))
check("a lastAligned shot's popover size is the one render.json records, the others the pinned one",
      shots.mac_popover_pt(mac_render(shots.raw_dir("ko", mac_root, MAC), "ko"), "04_cost") == (380, 551)
      and shots.mac_popover_pt(mac_render(shots.raw_dir("ko", mac_root, MAC), "ko"), "01_overview")
      == shots.MAC_POPOVER_PT)
check("region_of reads a locale identifier's region, and nothing else",
      [shots.region_of(x) for x in ("es_MX", "zh-Hant_TW", "ja-JP@calendar=japanese", "en", None, "es_419")]
      == ["MX", "TW", "JP", None, None, None])
render_regions = dict(re.findall(r"^\s+([A-Za-z-]+)\) echo ([a-z]{2}_[A-Z]{2}) ;;", render_sh, re.M))
check("the render script draws each language on the region MAC_REGIONS names, as the iPhone capture does",
      {k: v.split("_")[1] for k, v in render_regions.items()} == shots.MAC_REGIONS
      and render_regions == locale_cases, f"{render_regions} vs {locale_cases}")
check("the render script asks for overlay scroll bars",
      "-AppleShowScrollBars WhenScrolling" in render_sh and '-AppleLocale "$(locale_for "$lang")"' in render_sh)


def swap_raw(root: Path) -> None:
    """Replace a raw and record it in compose.json, so only render.json can tell."""
    raw = shots.raw_dir("ko", root, MAC)
    f = raw / "05_alerts.png"
    f.write_bytes(f.read_bytes() + b"swapped")
    m_ = shots.composed_dir("ko", root, MAC) / shots.MANIFEST
    data = json.loads(m_.read_text())
    data["captures"]["05_alerts.png"] = shots.md5_of(f)
    m_.write_text(json.dumps(data))
    shots.write_manifest(shots.composed_dir("ko", root, MAC), "ko",
                         {k: v for k, v in data.items() if k not in ("lang", "panels")}, platform=MAC)


mac_breaks("a raw that is not the one the render wrote", "not the file the render wrote", mutate=swap_raw)
mac_breaks("a missing usage panel", "03_usage_history.panel.png",
           mutate=lambda r: (shots.raw_dir("ko", r, MAC) / "03_usage_history.panel.png").unlink())
mac_breaks("a stray raw", "not a capture of the set",
           mutate=lambda r: shots.write_png(shots.raw_dir("ko", r, MAC) / "07_settings.png", 1140, 1740))
mac_breaks("a missing render.json", "render.json: missing",
           mutate=lambda r: (shots.raw_dir("ko", r, MAC) / shots.RENDER_MANIFEST).unlink())
mac_breaks("a set without compose.json", "compose.json is missing",
           mutate=lambda r: (shots.composed_dir("ko", r, MAC) / shots.MANIFEST).unlink())
mac_breaks("a Mac panel of the wrong size", "expected 2880x1800",
           mutate=lambda r: (shots.write_png(shots.expected_composed("ko", r, MAC)[0], 2560, 1600),
                             shots.write_manifest(shots.composed_dir("ko", r, MAC), "ko",
                                                  {"captures": json.loads((shots.composed_dir("ko", r, MAC)
                                                                           / shots.MANIFEST).read_text())
                                                   ["captures"]}, platform=MAC)))

# ── the popover's scale and placement (pure) ─────────────────────────────────
one_line = compose.caption_layout(round(100 * compose.LINE_BOX), round(46 * compose.LINE_BOX), 1, 1)
mac_one = compose_mac.common.caption_layout(compose_mac.LAYOUT, round(100 * compose.LINE_BOX),
                                            round(46 * compose.LINE_BOX), 1, 1)
scale = compose_mac.px_per_pt(mac_one.shot_top)
check("with one-line captions the popover is drawn at about 2.27 px/pt, over the 2.2 floor",
      2.25 < scale < 2.3 and scale >= compose_mac.MIN_PX_PER_PT, f"{scale}")
two = compose_mac.common.caption_layout(compose_mac.LAYOUT, round(100 * compose.LINE_BOX),
                                        round(46 * compose.LINE_BOX), 2, 2)
check("negative control: a two-line subtitle would push it under the floor, and that fails",
      compose_mac.placement_problems([], compose_mac.px_per_pt(two.shot_top)) != [],
      f"{compose_mac.px_per_pt(two.shot_top)}")
single = compose_mac.placements(False, mac_one.shot_top, scale)
group = compose_mac.placements(True, mac_one.shot_top, scale, panel_height_pt=862)
check("a single popover is centred and whole on the canvas",
      compose_mac.placement_problems(single, scale) == []
      and abs(single[0].x * 2 + single[0].w - compose_mac.CANVAS_W) <= 1, str(single))
check("the usage panel sits left of the popover, top-aligned, 8 points away, and may leave only through the bottom",
      compose_mac.placement_problems(group, scale) == [] and group[0].name == "panel"
      and group[0].y == group[1].y and group[1].x - (group[0].x + group[0].w) == round(8 * scale)
      and group[0].y + group[0].h > compose_mac.CANVAS_H, str(group))
moved = [compose_mac.Placement("popover", -10, single[0].y, single[0].w, single[0].h)]
check("negative control: a popover leaving the canvas at the side fails",
      compose_mac.placement_problems(moved, scale) != [])
tall = [compose_mac.Placement("popover", single[0].x, 900, single[0].w, single[0].h)]
check("negative control: a popover leaving the canvas at the bottom fails",
      compose_mac.placement_problems(tall, scale) != [])
side = [compose_mac.Placement("panel", 2000, 400, 1200, 3000, may_bleed_bottom=True)]
check("negative control: the panel leaving the canvas at the side fails",
      compose_mac.placement_problems(side, scale) != [])

# ── the committed Mac sets ───────────────────────────────────────────────────
check("on the real repo every Mac set is uploadable, recorded and drawn from the committed raws",
      all(shots.set_problems(lang, platform=MAC) == [] and shots.capture_problems(lang, platform=MAC) == []
          for lang in shots.LANGS),
      str({lang: shots.set_problems(lang, platform=MAC) + shots.capture_problems(lang, platform=MAC)
           for lang in shots.LANGS}))
check("on the real repo every Mac set was drawn by the app version its render.json names",
      all(shots.composed_app_version(lang) == json.loads(
          (shots.raw_dir(lang, platform=MAC) / shots.RENDER_MANIFEST).read_text())["app"]["version"]
          for lang in shots.LANGS))

# ── with Pillow: fit, and the byte-identical recomposes ──────────────────────
if fonts_here:
    import contextlib
    import hashlib
    import io
    for lang in shots.LANGS:
        faces, probs = compose_mac.pick_faces(lang)
        t_size, s_size, size_probs = compose_mac.common.set_sizes(compose_mac.LAYOUT, compose_mac.COPY, lang,
                                                                  faces, MAC_STEMS)
        reserved = compose_mac.common.set_sub_lines(compose_mac.LAYOUT, compose_mac.COPY, lang, faces,
                                                    MAC_STEMS, s_size) if not probs else 0
        lay = compose_mac.common.caption_layout(
            compose_mac.LAYOUT, round(t_size * compose.LINE_BOX), round(s_size * compose.LINE_BOX),
            reserved, reserved) if not probs else None
        pxpt = compose_mac.px_per_pt(lay.shot_top) if lay else 0
        check(f"{lang}: every Mac caption has a glyph, fits, and leaves the popover at >= 2.2 px/pt",
              not probs and not size_probs and pxpt >= compose_mac.MIN_PX_PER_PT,
              f"{probs} {size_probs} {pxpt:.3f}")

    def recomposes(module, platform, lang: str, out: Path) -> list[str]:
        committed = shots.composed_dir(lang, platform=platform) / shots.MANIFEST
        if not committed.is_file():
            return [f"no committed {committed}"]
        with contextlib.redirect_stdout(io.StringIO()):
            problems = module.compose_lang(lang, None, out)
        want = json.loads(committed.read_text())
        got = json.loads((out / shots.MANIFEST).read_text()) if (out / shots.MANIFEST).exists() else {}
        diff = [n for n, m_ in want.get("panels", {}).items()
                if not (out / n).exists() or hashlib.md5((out / n).read_bytes()).hexdigest() != m_]
        return problems + diff + ([] if got == want else ["compose.json differs"])

    # Byte for byte only with the Pillow the sets were composed with: another
    # version resamples and encodes differently (12.3.0 differs from 10.4.0 in
    # every panel). The iPhone sets record none; they were composed, and
    # recompose identically through the shared code, with 10.4.0 (measured
    # 2026-09-28). The Mac sets record theirs in compose.json.
    import PIL
    IPHONE_COMPOSED_WITH_PILLOW = "10.4.0"
    if PIL.__version__ == IPHONE_COMPOSED_WITH_PILLOW:
        ios_diff = {lang: recomposes(compose, shots.IPHONE, lang, tmp / "re-ios" / lang)
                    for lang in shots.LANGS}
        check("the committed iPhone sets recompose byte-identically through the shared compose code",
              not any(ios_diff.values()), str(ios_diff))
    else:
        not_run += 1
        print(f"NOT RUN: the iPhone byte-identical recompose (composed with Pillow "
              f"{IPHONE_COMPOSED_WITH_PILLOW}, this is {PIL.__version__})")
    mac_pillow = {json.loads((shots.composed_dir(lang, platform=MAC) / shots.MANIFEST).read_text())
                  .get("pillow") for lang in shots.LANGS}
    check("every Mac set records the Pillow it was composed with, the same for all six",
          len(mac_pillow) == 1 and None not in mac_pillow, str(mac_pillow))
    if mac_pillow == {PIL.__version__}:
        mac_diff = {lang: recomposes(compose_mac, MAC, lang, tmp / "re-mac" / lang) for lang in shots.LANGS}
        check("the committed Mac sets recompose byte-identically from the committed raws",
              not any(mac_diff.values()), str(mac_diff))
    else:
        not_run += 1
        print(f"NOT RUN: the Mac byte-identical recompose (composed with Pillow {mac_pillow}, "
              f"this is {PIL.__version__})")

    # compose_one's own check of the popover's size, which render_problems
    # cannot stand in for when it is called with raws it never saw.
    odd_raw = tmp / "mac-odd-raw"
    shutil.copytree(shots.raw_dir("en", platform=MAC), odd_raw)
    from PIL import Image as PILImage
    PILImage.new("RGB", (1140, 2100), (255, 255, 255)).save(odd_raw / "01_overview.png")
    faces_en, _ = compose_mac.pick_faces("en")
    with contextlib.redirect_stdout(io.StringIO()):
        odd, _ = compose_mac.compose_one(odd_raw, "01_overview", tmp / "mac-odd-out" / "p.png", "en",
                                         faces_en, 100, 46, 1)
        aligned, _ = compose_mac.compose_one(odd_raw, "04_cost", tmp / "mac-odd-out" / "q.png", "en",
                                             faces_en, 100, 46, 1)
    check("negative control: a raw popover of the wrong size is refused by the compositor itself",
          any("01_overview.png is 1140x2100, not 1140x1740" in p_ for p_ in odd), str(odd))
    check("negative control: the shortened cost popover composed as if it were the pinned 580 points "
          "is refused", any("04_cost.png is 1140x" in p_ and "not 1140x1740" in p_ for p_ in aligned),
          str(aligned))

    # A render.json from a Developer ID build: the compositor refuses and
    # withdraws whatever set was there.
    bad_raw = tmp / "mac-devid-raw"
    shutil.copytree(shots.raw_dir("en", platform=MAC), bad_raw)
    data = json.loads((bad_raw / shots.RENDER_MANIFEST).read_text())
    data["variant"]["devidBuild"] = True
    (bad_raw / shots.RENDER_MANIFEST).write_text(json.dumps(data))
    out_bad = tmp / "mac-devid-out" / "en"
    shutil.copytree(shots.composed_dir("en", platform=MAC), out_bad)
    with contextlib.redirect_stdout(io.StringIO()) as log:
        refused = compose_mac.compose_lang("en", bad_raw, out_bad)
    check("negative control: raws from a Developer ID build are refused and the earlier set withdrawn",
          any("DEVID_BUILD" in p_ for p_ in refused) and not (out_bad / shots.MANIFEST).exists(),
          log.getvalue())
else:
    not_run += 1
    print("NOT RUN: Mac caption fit and the byte-identical iPhone and Mac recomposes (need macOS "
          "system fonts and Pillow); run this file on a Mac")

print(f"test_appstore_screenshots: {passed} passed, {failed} failed"
      + (f", {not_run} group(s) NOT RUN" if not_run else "") + ".")
sys.exit(1 if failed else 0)

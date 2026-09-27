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
  * a composed set is uploadable only with the compose.json a clean compose
    run writes, and only with the panels it records;
  * on macOS with Pillow only: every caption's every character has a glyph in
    the chosen face; a Latin-only face, and a face of the other Chinese region,
    is refused (the negative controls); a trailing 、 is centred on its ink; a
    failing compose run publishes nothing and withdraws the earlier set. On any
    other machine these are reported as NOT RUN, never as passed.

Bare python3 for everything else; CI runs it in repo-hygiene.yml.
"""
from __future__ import annotations

import json
import re
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "CLI Pulse Bar" / "scripts"))
import appstore_listing as listing  # noqa: E402
import appstore_screenshots as shots  # noqa: E402
import compose_appstore_ios_screenshots as compose  # noqa: E402

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
else:
    not_run += 1
    print("NOT RUN: glyph coverage (needs macOS system fonts and Pillow); "
          "run this file on a Mac, or compose_appstore_ios_screenshots.py --check-fonts")

print(f"test_appstore_screenshots: {passed} passed, {failed} failed"
      + (f", {not_run} group(s) NOT RUN" if not_run else "") + ".")
sys.exit(1 if failed else 0)

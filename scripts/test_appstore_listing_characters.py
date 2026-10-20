#!/usr/bin/env python3
"""Tests for the character check in scripts/appstore_listing.py.

App Store Connect refuses some characters with a 409 for the whole field. On
2026-10-20 it refused the 1.57 iOS What's New for one "✕" (U+2715), after the
Mac's seven locales had been written. Apple publishes no list, so
store_character_problems() lets through letters and digits in their plain form
and, of everything else, only ACCEPTED_SYMBOLS: what the store has accepted in
this app's listing and What's New texts. This checks that:

  * the refused 1.57 sentence fails, naming U+2715 and what happened;
  * every character the store refused (REFUSED_BY_STORE) fails, and none of
    them is also in ACCEPTED_SYMBOLS;
  * letters of all six listing languages pass, and so does every listing and
    What's New text in the repo (the positive control on real text);
  * compatibility forms (an Arabic presentation form like the one App Store
    Connect refused elsewhere, a ligature, styled letters, half-width kana,
    full-width digits), combining marks, emoji and invisible characters fail;
  * each ACCEPTED_SYMBOLS entry is used by a listing or What's New text in the
    repo, so the list stays a record of what the store took, and the
    comparison notices an entry nothing uses (its negative control);
  * the check runs where the texts are checked: validate() for the listing,
    load_whatsnew() for What's New (asc_submit.py, asc_listing_preflight.py),
    and `appstore_listing.py --characters` for check_release_notes_platforms.sh.

Runs with a bare python3; CI runs it in repo-hygiene.yml.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import appstore_listing as listing  # noqa: E402

REPO = listing.REPO
passed = 0
failed = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global passed, failed
    if cond:
        print(f"ok:   {name}")
        passed += 1
    else:
        print(f"FAIL: {name}")
        if detail:
            print("      " + detail.replace("\n", "\n      ")[:2000])
        failed += 1


def problems(text: str) -> list[str]:
    return listing.store_character_problems(text)


def accepted_texts() -> dict[str, str]:
    """Every text the store accepted that the repo still has: the listing and
    What's New 1.49 onwards (the root whatsnew_*/ directories)."""
    out = {}
    for p in sorted(listing.listing_dir().glob("*/*.txt")):
        out[str(p.relative_to(REPO))] = listing.read_text(p)
    for p in sorted(REPO.glob("whatsnew_*/*.txt")):
        out[str(p.relative_to(REPO))] = listing.read_text(p)
    return out


def unused_entries(symbols: str, texts: dict[str, str]) -> list[str]:
    used = set("".join(texts.values()))
    return [c for c in symbols if c not in used]


# 1. The sentence App Store Connect refused in 1.57 (iOS, en-US).
got = problems("Tap the day again, or ✕, to close the list.")
check("the 1.57 '✕' fails, once, naming the code point and the refusal",
      len(got) == 1 and "'✕' (U+2715 MULTIPLICATION X)" in got[0]
      and "refused it in the iOS What's New of 1.57 on 2026-10-20" in got[0], str(got))
got = problems("first line\nsecond ✕\nthird ✕ ✕")
check("a character found several times is reported once, at its first line, with the count",
      len(got) == 1 and got[0].startswith("line 2: ") and ", 3 times:" in got[0], str(got))

# 2. Everything the store refused fails, and is not also allowed.
for ch in listing.REFUSED_BY_STORE:
    check(f"refused by the store: {listing.describe_character(ch)} fails",
          not listing.store_accepts(ch) and len(problems(f"a {ch} b")) == 1)
both = [c for c in listing.REFUSED_BY_STORE if c in listing.ACCEPTED_SYMBOLS]
check("no character is both refused and accepted", not both, str(both))

# 3. Letters of the six languages pass.
for lang, text in [
    ("en", "Usage history, 30 days: 12.5K tokens (estimated)"),
    ("es", "Historial de uso: «Ajustes» · año, información, pingüino, ÉXITO"),
    ("ja", "使用状況の履歴を「設定」から確認できます。ー々ヶ"),
    ("ko", "사용량 기록을 설정에서 확인할 수 있습니다"),
    ("zh-Hans", "在「设置」中查看使用记录（估算）；每日统计。"),
    ("zh-Hant", "在「設定」中查看使用紀錄（估算）；每日統計。"),
]:
    check(f"{lang} prose passes", problems(text) == [], str(problems(text)))

for ch in listing.ACCEPTED_SYMBOLS:
    if not listing.store_accepts(ch):
        check(f"ACCEPTED_SYMBOLS entry {listing.describe_character(ch)} passes", False)
        break
else:
    check(f"every ACCEPTED_SYMBOLS entry passes ({len(listing.ACCEPTED_SYMBOLS)})", True)

# 4. What fails, and why.
for label, ch, needle in [
    ("an Arabic presentation form (ITMS-4000 elsewhere)", "ﯽ", "a compatibility form of"),
    ("a ligature", "ﬁ", "a compatibility form of 'fi'"),
    ("a styled 'bold' letter", "\U0001d400", "a compatibility form of 'A'"),
    ("half-width katakana", "ｶ", "a compatibility form of 'カ'"),
    ("a full-width digit", "２", "a compatibility form of '2'"),
    ("a superscript digit", "²", "a compatibility form of '2'"),
    ("a combining accent (decomposed text)", "́", "write the text precomposed (Unicode NFC)"),
    ("an emoji", "\U0001f389", "U+1F389 PARTY POPPER): not among the characters"),
    ("a check mark", "✓", "U+2713 CHECK MARK): not among the characters"),
    ("an arrow", "→", "U+2192 RIGHTWARDS ARROW): not among the characters"),
    ("a zero-width space", "​", "'\\u200b' (U+200B ZERO WIDTH SPACE)"),
    ("a byte-order mark", "﻿", "U+FEFF ZERO WIDTH NO-BREAK SPACE"),
    ("a no-break space", " ", "U+00A0 NO-BREAK SPACE"),
    ("a carriage return", "\r", "'\\r' (U+000D unnamed)"),
    ("a tab", "\t", "'\\t' (U+0009 unnamed)"),
    ("a less-than sign (never sent)", "<", "U+003C LESS-THAN SIGN"),
]:
    got = problems(f"Usage{ch}history")
    check(f"{label} fails, saying why", len(got) == 1 and needle in got[0], str(got))
check("an emoji keycap (digit + VS16 + enclosing mark) fails on its marks",
      len(problems("Step 1️⃣")) == 2, str(problems("Step 1️⃣")))

# 5. The texts the store accepted pass (positive control on real text), and
#    every ACCEPTED_SYMBOLS entry is one of them uses.
texts = accepted_texts()
bad = {k: v for k, v in ((k, problems(t)) for k, t in texts.items()) if v}
check(f"every listing and What's New text in the repo passes ({len(texts)} files)",
      len(texts) > 60 and not bad, str(bad)[:1500])
unused = unused_entries(listing.ACCEPTED_SYMBOLS, texts)
check("every ACCEPTED_SYMBOLS entry is used by a text the store accepted",
      not unused, ", ".join(listing.describe_character(c) for c in unused))
check("... and that comparison notices an entry no text uses (negative control)",
      unused_entries(listing.ACCEPTED_SYMBOLS + "→", texts) == ["→"])

# 6. Where the check runs.
tmp = Path(tempfile.mkdtemp(prefix="store-chars-test-"))
try:
    root = tmp / "repo"
    shutil.copytree(listing.listing_dir(), root / listing.LISTING_DIR_REL)
    check("validate() passes the listing as committed", listing.validate(root) == [],
          str(listing.validate(root)))
    kw = root / listing.LISTING_DIR_REL / "en-US" / "keywords.txt"
    kw.write_text(kw.read_text(encoding="utf-8").strip() + ",✓done\n", encoding="utf-8")
    probs = [str(p) for p in listing.validate(root)]
    check("validate() refuses a keyword list with '✓', naming the file",
          any(p.startswith("en-US/keywords.txt: line 1: '✓' (U+2713") for p in probs), str(probs))

    wn = tmp / "whatsnew_157"
    shutil.copytree(REPO / "whatsnew_157", wn)
    check("load_whatsnew() passes whatsnew_157 as committed (both platforms)",
          listing.whatsnew_problems(wn) == [], str(listing.whatsnew_problems(wn)))
    en = wn / "en-US.txt"
    en.write_text(en.read_text(encoding="utf-8").rstrip("\n")
                  + "\n• Tap the day again, or ✕, to close the list.\n", encoding="utf-8")
    texts_ios, probs_ios = listing.load_whatsnew(wn, "IOS")
    probs_mac = listing.load_whatsnew(wn, "MAC_OS")[1]
    check("load_whatsnew() refuses the iOS text with '✕' (what asc_submit.py writes)",
          [str(p).split(": line")[0] for p in probs_ios] == ["whatsnew_157/en-US.txt"]
          and "U+2715" in str(probs_ios[0]), str(probs_ios))
    check("... and the macOS texts beside it still pass", probs_mac == [], str(probs_mac))

    cli = [sys.executable, str(REPO / "scripts" / "appstore_listing.py"), "--characters"]
    r = subprocess.run(cli + [str(en)], capture_output=True, text=True)
    check("--characters FILE: exit 1, the file and U+2715 named",
          r.returncode == 1 and f"{en}: line " in r.stdout and "U+2715" in r.stdout,
          r.stdout + r.stderr)
    r = subprocess.run(cli + [str(wn / "ja.txt")], capture_output=True, text=True)
    check("--characters on a clean file: exit 0", r.returncode == 0, r.stdout + r.stderr)
    r = subprocess.run(cli, capture_output=True, text=True)
    check("--characters with no file refuses rather than passing",
          r.returncode != 0 and "checking nothing would pass" in r.stderr, r.stdout + r.stderr)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print(f"test_appstore_listing_characters: {passed} passed, {failed} failed.")
sys.exit(1 if failed else 0)

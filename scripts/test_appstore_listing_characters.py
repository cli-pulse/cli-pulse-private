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
    full-width digits), combining marks, emoji and invisible characters fail,
    and so does a text not in NFC (decomposed Korean, a separate accent);
  * each ACCEPTED_SYMBOLS entry records where the store accepted it, and each
    frozen text a record cites (a whatsnew_NNN/ directory, an old submit
    script's What's New) holds the character. An entry no current text uses
    stays on its record ("!", from 1.11.0); the checks' negative controls are
    a record that says nothing, one whose text lacks the character and one
    citing a text that is not there;
  * the check runs where the texts are checked: validate() for the listing,
    load_whatsnew() for What's New (asc_submit.py, asc_listing_preflight.py),
    `appstore_listing.py --characters` for check_release_notes_platforms.sh,
    and ASC_WHATS_NEW in the legacy CLI Pulse Bar/scripts/appstore_metadata.py,
    before its first request.

Runs with a bare python3; CI runs it in repo-hygiene.yml.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types
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


def unused_entries(symbols, texts: dict[str, str]) -> list[str]:
    used = set("".join(texts.values()))
    return [c for c in symbols if c not in used]


# A record cites a frozen text as a whatsnew_NNN/ directory at the repo root or
# an old CLI Pulse Bar/scripts/submit_v*.py; the listing is cited in words.
FROZEN = re.compile(r"whatsnew_\d+/|submit_v[\d_]+\.py")
SUBMIT_WHATS_NEW = re.compile(r'^WHATS_NEW\w*\s*=\s*"""(.*?)"""', re.S | re.M)


def frozen_text(cite: str) -> str | None:
    """The text a record cites, as sent: every .txt of a What's New directory,
    or the What's New strings of a submit script (not its code). None if the
    repo does not have it."""
    if cite.startswith("whatsnew_"):
        d = REPO / cite
        if not d.is_dir():
            return None
        return "\n".join(listing.read_text(f) for f in sorted(d.glob("*.txt")))
    path = REPO / "CLI Pulse Bar" / "scripts" / cite
    if not path.is_file():
        return None
    return "\n".join(SUBMIT_WHATS_NEW.findall(path.read_text(encoding="utf-8")))


def record_problems(records: dict[str, str]) -> list[str]:
    """Why a record of where the store accepted a character does not hold."""
    out = []
    for ch, where in records.items():
        name = listing.describe_character(ch)
        if not re.search(r"\bthe listing\b|What's New \d+\.\d+", where):
            out.append(f"{name}: the record does not say where App Store Connect "
                       f"accepted it: {where!r}")
            continue
        for cite in FROZEN.findall(where):
            text = frozen_text(cite)
            if text is None:
                out.append(f"{name}: cites {cite}, which is not in the repo")
            elif ch not in text:
                out.append(f"{name}: cites {cite}, whose What's New does not hold it")
    return out


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
    ("an emoji", "\U0001f389", "U+1F389 PARTY POPPER): not among the characters"),
    ("a check mark", "✓", "U+2713 CHECK MARK): not among the characters"),
    ("an arrow", "→", "U+2192 RIGHTWARDS ARROW): not among the characters"),
    ("a zero-width space", "\u200b", "'\\u200b' (U+200B ZERO WIDTH SPACE)"),
    ("a byte-order mark", "\ufeff", "U+FEFF ZERO WIDTH NO-BREAK SPACE"),
    ("a no-break space", "\u00a0", "U+00A0 NO-BREAK SPACE"),
    ("a carriage return", "\r", "'\\r' (U+000D unnamed)"),
    ("a tab", "\t", "'\\t' (U+0009 unnamed)"),
    ("a less-than sign (never sent)", "<", "U+003C LESS-THAN SIGN"),
]:
    got = problems(f"Usage{ch}history")
    check(f"{label} fails, saying why", len(got) == 1 and needle in got[0], str(got))
got = problems("Step 1\ufe0f\u20e3")
check("an emoji keycap (digit + VS16 + enclosing mark) fails on its marks",
      len(got) == 2, str(got))

# Decomposed text: an accent as a separate mark fails on the mark and on NFC;
# Korean as conjoining jamo passes letter by letter, so only NFC catches it.
got = problems("Usage\nUsa\u0301ge history")
check("a combining accent (decomposed text) fails, as a mark and as not NFC",
      len(got) == 2 and "U+0301 COMBINING ACUTE ACCENT" in got[0]
      and "write the text precomposed (Unicode NFC)" in got[0]
      and got[1].startswith("line 2: not in Unicode NFC"), str(got))
decomposed = "\u1109\u1161\u110b\u116d\u11bc\u1105\u1163\u11bc"   # 사용량, as jamo
check("decomposed Korean is a different string from the precomposed one",
      decomposed != "사용량" and listing.unicodedata.normalize("NFC", decomposed) == "사용량")
got = problems("사용량 기록\n" + decomposed + " 기록")
check("decomposed Korean (conjoining jamo) fails as not NFC, naming its line",
      len(got) == 1 and got[0].startswith("line 2: not in Unicode NFC")
      and "Korean as separate jamo" in got[0], str(got))
check("... and the same words precomposed pass", problems("사용량 기록\n사용량 기록") == [])

# 5. The texts the store accepted pass (positive control on real text), and
#    every ACCEPTED_SYMBOLS entry carries a record of where the store took it.
texts = accepted_texts()
bad = {k: v for k, v in ((k, problems(t)) for k, t in texts.items()) if v}
check(f"every listing and What's New text in the repo passes ({len(texts)} files)",
      len(texts) > 60 and not bad, str(bad)[:1500])
rec = record_problems(listing.ACCEPTED_SYMBOLS)
check(f"every ACCEPTED_SYMBOLS entry records where the store accepted it, and each "
      f"frozen text it cites holds it ({len(listing.ACCEPTED_SYMBOLS)} entries)",
      not rec, "\n".join(rec))
cited = sorted({c for w in listing.ACCEPTED_SYMBOLS.values() for c in FROZEN.findall(w)})
check(f"the records' citations are read, both kinds ({len(cited)}: {', '.join(cited)})",
      "submit_v1_11_0.py" in cited and any(c.startswith("whatsnew_") for c in cited)
      and all(frozen_text(c) for c in cited), str(cited))
# The record, not a current text, keeps an entry: no text in the repo uses "!"
# today, and a listing rewrite that dropped "&" from the subtitle would leave
# "&" unused too. Both stay.
unused = unused_entries(listing.ACCEPTED_SYMBOLS, texts)
check("'!' is in ACCEPTED_SYMBOLS on its 1.11.0 record although no current text uses it",
      "!" in unused and record_problems({"!": listing.ACCEPTED_SYMBOLS["!"]}) == [],
      str(unused))
without_subtitle = {k: v for k, v in texts.items() if not k.endswith("en-US/subtitle.txt")}
check("'&' stays on its record when no current text uses it (a subtitle rewrite)",
      "&" in unused_entries(listing.ACCEPTED_SYMBOLS, without_subtitle)
      and record_problems({"&": listing.ACCEPTED_SYMBOLS["&"]}) == [])
# Negative controls for the record check.
for label, records, needle in [
    ("a record that says nothing", {"\u2192": ""}, "does not say where"),
    ("a record that names no text", {"\u2192": "seen somewhere"}, "does not say where"),
    ("a record whose What's New lacks the character",
     {"\u2192": "What's New 1.50 (whatsnew_150/)"}, "cites whatsnew_150/, whose What's New"),
    ("a record citing a What's New that is not there",
     {"\u2192": "What's New 1.99 (whatsnew_199/)"}, "whatsnew_199/, which is not in the repo"),
    ("a record citing a script whose code, not its What's New, has the character",
     {"=": "What's New 1.11.0 (submit_v1_11_0.py)"}, "submit_v1_11_0.py, whose What's New"),
]:
    got = record_problems(records)
    check(f"the record check refuses {label} (negative control)",
          len(got) == 1 and needle in got[0], str(got))

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

# 7. The legacy pusher CLI Pulse Bar/scripts/appstore_metadata.py writes
#    ASC_WHATS_NEW, a text from the environment that CI never sees: it checks
#    the characters before its first request. Its API calls are replaced so
#    that the first one ends the run here.
for mod in ("jwt", "requests"):   # imported at the top; never called below
    sys.modules.setdefault(mod, types.ModuleType(mod))
spec = importlib.util.spec_from_file_location(
    "appstore_metadata", REPO / "CLI Pulse Bar" / "scripts" / "appstore_metadata.py")
meta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(meta)


class Reached(Exception):
    pass


requests_made: list[str] = []


def _stub(name):
    def call(*_args, **_kwargs):
        requests_made.append(name)
        raise Reached(name)
    return call


for fn in ("api_get", "api_post", "api_patch", "api_delete"):
    setattr(meta, fn, _stub(fn))


def run_metadata(whats_new: str | None, entry=lambda: meta.main()) -> str:
    """How a run with this ASC_WHATS_NEW ends: 'exit: <message>' for a refusal,
    'reached <call>' when it got as far as a request."""
    requests_made.clear()
    saved = os.environ.pop("ASC_WHATS_NEW", None)
    if whats_new is not None:
        os.environ["ASC_WHATS_NEW"] = whats_new
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            entry()
        return "returned"
    except SystemExit as e:
        return f"exit: {e.code}"
    except Reached as e:
        return f"reached {e}"
    finally:
        os.environ.pop("ASC_WHATS_NEW", None)
        if saved is not None:
            os.environ["ASC_WHATS_NEW"] = saved


got = run_metadata("\u2022 Fixed a crash on the last day of the month.")
check("appstore_metadata.py: a clean ASC_WHATS_NEW gets as far as its first request",
      got == "reached api_get", got)
got = run_metadata("\u2022 Tap the day again, or \u2715, to close the list.")
check("appstore_metadata.py refuses an ASC_WHATS_NEW with '\u2715' before any request",
      got.startswith("exit: error: ASC_WHATS_NEW holds characters") and "U+2715" in got
      and requests_made == [], f"{got} {requests_made}")
got = run_metadata("\u1109\u1161\u110b\u116d\u11bc\u1105\u1163\u11bc")
check("... and one in decomposed Korean (not NFC)",
      got.startswith("exit: ") and "not in Unicode NFC" in got and requests_made == [],
      f"{got} {requests_made}")
got = run_metadata(None)
check("... and still refuses an unset ASC_WHATS_NEW, now before any request",
      got.startswith("exit: error: ASC_WHATS_NEW is not set") and requests_made == [],
      f"{got} {requests_made}")
got = run_metadata("\u2022 Tap \u2715 to close.",
                   entry=lambda: meta.set_localization("version-id", "IOS"))
check("set_localization() refuses it too, before reading the version's localizations",
      got.startswith("exit: error: ASC_WHATS_NEW holds characters") and requests_made == [],
      f"{got} {requests_made}")

print(f"test_appstore_listing_characters: {passed} passed, {failed} failed.")
sys.exit(1 if failed else 0)

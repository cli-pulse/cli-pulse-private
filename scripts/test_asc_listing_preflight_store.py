#!/usr/bin/env python3
"""Offline tests for the STORE half of scripts/asc_listing_preflight.py: the
What's New comparison (check 5), against a fake App Store Connect.

WHY THIS EXISTS
---------------
On 2026-09-28 `asc_listing_preflight.py --version 1.54.0 --whatsnew-dir
whatsnew_154` printed PREFLIGHT OK while What's New was empty in all 14
localizations of 1.54.0 (seven per platform). --whatsnew-dir validated the
repo's files and nothing compared them with the store's field, so the OK
covered text nobody had checked. The store half needs the ASC key and so has
never run in CI; this replaces the HTTP layer with an in-memory store and runs
the real main():

  * positive control: every localization holds its platform's text, trailing
    whitespace aside -> PREFLIGHT OK, and the OK line says What's New matched;
  * the 1.54.0 state, What's New empty everywhere -> FAIL, once per locale per
    platform (the check that would have caught it);
  * one Mac locale holding the iPhone text -> FAIL on that locale only, naming
    the iPhone file; the iPhone version is untouched by it;
  * a store locale the directory has no text for -> FAIL;
  * --whatsnew-unwritten-ok: empty on an editable version -> NOT WRITTEN, exit
    0, and the OK line counts them; but a text that DIFFERS still fails, and an
    empty one on a version already WAITING_FOR_REVIEW still fails;
  * --whatsnew-unwritten-ok without --whatsnew-dir is a usage error;
  * without --whatsnew-dir the run says What's New was NOT compared, on every
    platform and in the OK line, so its OK cannot be read as covering it.

Every case runs with --skip-screenshots (check 3 downloads images). The real
whatsnew_154/ and CLI Pulse Bar/appstore/ are the fixtures. Runs with a bare
python3 (no jwt/requests needed); CI runs it in repo-hygiene.yml.
"""
from __future__ import annotations

import contextlib
import copy
import io
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import appstore_listing as listing  # noqa: E402
import asc_listing_preflight as pf  # noqa: E402

REPO = HERE.parent
NOTES = REPO / "whatsnew_154"
APP = pf.APP_ID
LOCALES = list(listing.LOCALE_SOURCES)
PLATS = ("IOS", "MAC_OS")


def whatsnew(plat: str, locale: str) -> str:
    texts, problems = listing.load_whatsnew(NOTES, plat)
    assert not problems, problems
    return texts[locale].text


class Resp:
    def __init__(self, status: int, body: dict) -> None:
        self.status_code = status
        self._body = body
        self.text = str(body)

    def json(self) -> dict:
        return self._body


def base_store(state: str = "PREPARE_FOR_SUBMISSION") -> dict:
    """1.54.0 on both platforms: listing texts equal to the repo, What's New
    equal to whatsnew_154/ (the positive control)."""
    vlocs = {}
    for plat in PLATS:
        vlocs[plat] = {
            loc: {"locale": loc,
                  "description": listing.load_field("description", loc, plat),
                  "keywords": listing.load_field("keywords", loc, plat),
                  "promotionalText": listing.load_field("promotionalText", loc, plat),
                  "whatsNew": whatsnew(plat, loc) + "\n"}   # the store keeps what it is sent
            for loc in LOCALES}
    return {
        "versions": {plat: {"versionString": "1.54.0", "platform": plat, "appStoreState": state}
                     for plat in PLATS},
        "vlocs": vlocs,
        "subtitles": {loc: listing.load_field("subtitle", loc, "IOS") for loc in LOCALES},
    }


class FakeRequests:
    """Stands in for the `requests` module: answers the GETs the preflight makes."""

    def __init__(self, store: dict) -> None:
        self.store = store
        self.calls: list[tuple[str, str]] = []

    def get(self, url, headers=None, params=None, timeout=None):
        assert url.startswith(pf.BASE), url
        path = url[len(pf.BASE):]
        params = params or {}
        self.calls.append(("GET", path))
        s = self.store
        if path == f"/apps/{APP}/subscriptionGroups":
            return Resp(200, {"data": [{"id": "g1"}]})
        if path == "/subscriptionGroups/g1/subscriptions":
            return Resp(200, {"data": [
                {"attributes": {"productId": "yyh.CLI_Pulse.pro.monthly", "state": "APPROVED"}},
                {"attributes": {"productId": "yyh.CLI_Pulse.pro.yearly", "state": "APPROVED"}}]})
        if path == f"/apps/{APP}/inAppPurchasesV2":
            return Resp(200, {"data": []})
        if path == f"/apps/{APP}/appInfos":
            return Resp(200, {"data": [{"id": "ai-edit",
                                        "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]})
        if path == "/appInfos/ai-edit/appInfoLocalizations":
            return Resp(200, {"data": [{"id": f"il-{loc}",
                                        "attributes": {"locale": loc, "subtitle": sub}}
                                       for loc, sub in s["subtitles"].items()]})
        if path == f"/apps/{APP}/appStoreVersions":
            plat = params.get("filter[platform]")
            v = s["versions"].get(plat)
            rows = []
            if v and params.get("filter[versionString]") in (None, v["versionString"]):
                rows = [{"id": f"v-{plat}", "attributes": dict(v)}]
            return Resp(200, {"data": rows})
        if path.startswith("/appStoreVersions/v-") and path.endswith("/appStoreVersionLocalizations"):
            plat = path.split("/")[2][2:]
            return Resp(200, {"data": [{"id": f"vl-{plat}-{loc}", "attributes": dict(a)}
                                       for loc, a in s["vlocs"][plat].items()]})
        raise AssertionError(f"unexpected GET {path}")


pf._load_http_deps = lambda: None     # no jwt/requests import
pf.token = lambda: "test-token"       # no key file, no signing


def run(store: dict, *argv: str) -> tuple[int, str, FakeRequests]:
    fake = FakeRequests(store)
    pf.requests = fake
    out = io.StringIO()
    sys.argv = ["asc_listing_preflight.py", "--version", "1.54.0", "--skip-screenshots", *argv]
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            code = pf.main()
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
    return code, out.getvalue(), fake


def with_notes(store: dict, *argv: str) -> tuple[int, str, FakeRequests]:
    return run(store, "--whatsnew-dir", str(NOTES), *argv)


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
            print("      " + detail.replace("\n", "\n      ")[:4000])
        failed += 1


# 0. positive control
code, out, fake = with_notes(base_store())
check("store What's New equal to whatsnew_154/ on both platforms: PREFLIGHT OK",
      code == 0 and "PREFLIGHT OK" in out, out)
check("... every localization reported as matching, 7 per platform",
      out.count("What's New matches") == 14
      and "What's New: 14 localization(s) match whatsnew_154/." in out, out)
check("... the Mac is compared with macos-<locale>.txt, the iPhone with <locale>.txt",
      "[ja] What's New matches whatsnew_154/macos-ja.txt" in out
      and "[ja] What's New matches whatsnew_154/ja.txt" in out, out)
check("... read-only: every request is a GET", all(m == "GET" for m, _ in fake.calls))

# 1. the 1.54.0 state: What's New empty in all 14 localizations
empty = base_store()
for plat in PLATS:
    for row in empty["vlocs"][plat].values():
        row["whatsNew"] = None
code, out, _ = with_notes(empty)
check("What's New empty everywhere (the 1.54.0 state) fails",
      code == 1 and "PREFLIGHT FAILED" in out and "PREFLIGHT OK" not in out, out)
check("... once per locale per platform", out.count("What's New is EMPTY on the store") == 14, out)
check("... and the summary counts them", "0 localization(s) match whatsnew_154/, 14 empty or different"
      in out, out)

# 2. one Mac locale carries the iPhone text
swapped = base_store()
swapped["vlocs"]["MAC_OS"]["ja"]["whatsNew"] = whatsnew("IOS", "ja")
code, out, _ = with_notes(swapped)
check("a Mac locale holding the iPhone text fails, on that locale only",
      code == 1 and out.count("What's New on the store differs") == 1
      and "[ja] What's New on the store differs from whatsnew_154/macos-ja.txt" in out, out)
check("... and names the iPhone file it holds", "the store holds the iOS text, ja.txt" in out, out)
check("... the first differing line is shown from both sides",
      "          store: " in out and "          repo:  " in out, out)

# 3. a different text: an old release's notes left on one locale
stale = base_store()
stale["vlocs"]["IOS"]["ko"]["whatsNew"] = "• 버그 수정."
code, out, _ = with_notes(stale)
check("a stale text on one locale fails",
      code == 1 and "[ko] What's New on the store differs from whatsnew_154/ko.txt" in out, out)

# 4. a store locale the directory has no text for
extra = base_store()
extra["vlocs"]["IOS"]["fr-FR"] = {"locale": "fr-FR", "description": "Texte.", "keywords": "a",
                                  "promotionalText": None, "whatsNew": "Corrections."}
code, out, _ = with_notes(extra)
check("a store locale with no text in the directory fails",
      code == 1 and "[fr-FR] What's New: whatsnew_154/ has no iOS text" in out, out)

# 5. --whatsnew-unwritten-ok: before asc_submit.py --submit
code, out, _ = with_notes(empty, "--whatsnew-unwritten-ok")
check("--whatsnew-unwritten-ok: empty on an editable version passes",
      code == 0 and "PREFLIGHT OK" in out, out)
check("... each empty locale reported as NOT WRITTEN, not as a match",
      out.count("NOT WRITTEN [") == 14 and "What's New matches" not in out, out)
check("... and the OK line says so",
      "What's New: 0 localization(s) match whatsnew_154/, 14 NOT WRITTEN yet" in out, out)

code, out, _ = with_notes(stale, "--whatsnew-unwritten-ok")
check("--whatsnew-unwritten-ok does not excuse a text that differs",
      code == 1 and "[ko] What's New on the store differs" in out, out)

submitted = copy.deepcopy(empty)
for v in submitted["versions"].values():
    v["appStoreState"] = "WAITING_FOR_REVIEW"
code, out, _ = with_notes(submitted, "--whatsnew-unwritten-ok")
check("--whatsnew-unwritten-ok does not excuse an empty text on a submitted version",
      code == 1 and out.count("What's New is EMPTY on the store") == 14
      and "WAITING_FOR_REVIEW, no longer editable" in out, out)

state_fallback = copy.deepcopy(empty)
for v in state_fallback["versions"].values():
    v["appVersionState"] = v.pop("appStoreState")
code, out, _ = with_notes(state_fallback, "--whatsnew-unwritten-ok")
check("the version state falls back to appVersionState, as in asc_push_listing",
      code == 0 and out.count("NOT WRITTEN [") == 14, out)

code, out, fake = run(base_store(), "--whatsnew-unwritten-ok")
check("--whatsnew-unwritten-ok without --whatsnew-dir is a usage error, store not contacted",
      code == 2 and not fake.calls and "only makes sense with --whatsnew-dir" in out, out)

# 6. without --whatsnew-dir: said out loud, not implied
code, out, _ = run(empty)
check("without --whatsnew-dir the store's empty What's New is not judged (exit 0)", code == 0, out)
check("... but every platform says it was not compared",
      out.count("What's New not compared: pass --whatsnew-dir") == 2, out)
check("... and so does the OK line", "What's New: NOT compared (no --whatsnew-dir)." in out, out)

# 7. one platform only
code, out, _ = with_notes(swapped, "--platform", "IOS")
check("--platform IOS does not compare the Mac's texts",
      code == 0 and out.count("What's New matches") == 7, out)

print(f"test_asc_listing_preflight_store: {passed} passed, {failed} failed.")
sys.exit(1 if failed else 0)

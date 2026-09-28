#!/usr/bin/env python3
"""Offline tests for scripts/asc_push_listing.py, against a fake App Store Connect.

The write path is the one nobody can exercise for real until a release: App
Store Connect has an editable version only while one is being prepared, and a
test that writes to the real store is not a test. So this replaces the client
with an in-memory fake that behaves like the endpoints the pusher uses, and
checks what the pusher WOULD send:

  * a dry run sends nothing;
  * --apply to a live (READY_FOR_SALE) version is refused with zero writes;
  * invalid repo texts are refused before App Store Connect is even contacted;
  * --apply to an editable version PATCHes only the fields that differ, CREATES
    the missing app info locales with name "CLI Pulse" + en-US's
    privacyPolicyUrl, never DELETEs, and a second run writes nothing (idempotent);
  * like the real store, the fake answers each app info create by making an
    EMPTY version localization for that locale on every editable version, iOS
    and Mac, and answers a create of a locale the version has with 409. The
    pusher reads the version again after the app info writes and PATCHes those
    rows (texts + en-US's supportUrl/marketingUrl) instead of creating them;
    the Mac run then fills in the Mac copies; and when the store makes the row
    only after that read (a create gets 409), the row is PATCHed all the same;
  * with no such store behaviour, the missing version locales are CREATED with
    supportUrl/marketingUrl copied from en-US;
  * a localization that lacks a URL gets en-US's, one with its own keeps it,
    and the read-back fails while any locale has no support URL;
  * an en-US app name that is not "CLI Pulse" is refused before the first write;
  * --locale limits the writes to the named locales;
  * a write the store silently drops is caught by the read-back and fails;
  * with no editable app info, the version text is written but the run reports
    the subtitle as not applied and exits non-zero;
  * the real client retries a timed-out GET or PATCH but sends a POST (a create)
    only once, so a create that landed without its response is not sent again;
  * such a create does not fail the run when the read-back finds its text, and
    a create the store refused fails the run through the read-back.

Runs with a bare python3 (no jwt/requests needed); CI runs it in repo-hygiene.yml.
"""
from __future__ import annotations

import contextlib
import copy
import io
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import appstore_listing as listing  # noqa: E402
import asc_push_listing as pusher  # noqa: E402

APP = pusher.APP_ID
SUPPORT = "https://example.invalid/support"
MARKETING = "https://example.invalid/"
PRIVACY = "https://example.invalid/privacy.html"


def repo(attr: str, locale: str, platform: str = "IOS") -> str:
    return listing.load_field(attr, locale, platform)


def base_store(version_state: str = "PREPARE_FOR_SUBMISSION", editable_info: bool = True,
               app_name: str = "CLI Pulse") -> dict:
    """1.54.0 being prepared on iOS, with en-US stale and zh-Hans half up to date."""
    vlocs = {
        "vl-en": {"locale": "en-US", "description": "Old English text.", "keywords": "old,words",
                  "promotionalText": None, "supportUrl": SUPPORT, "marketingUrl": MARKETING,
                  "whatsNew": "Fixes."},
        "vl-zh": {"locale": "zh-Hans", "description": repo("description", "zh-Hans"),
                  "keywords": "旧,关键词", "promotionalText": repo("promotionalText", "zh-Hans"),
                  "supportUrl": SUPPORT, "marketingUrl": MARKETING, "whatsNew": "修复。"},
    }
    infos = {"ai-live": {"state": "READY_FOR_DISTRIBUTION"}}
    ilocs = {"ai-live": {
        "il-en": {"locale": "en-US", "name": app_name, "subtitle": None, "privacyPolicyUrl": PRIVACY},
        "il-zh": {"locale": "zh-Hans", "name": "CLI Pulse", "subtitle": repo("subtitle", "zh-Hans"),
                  "privacyPolicyUrl": PRIVACY},
    }}
    if editable_info:
        infos["ai-edit"] = {"state": "PREPARE_FOR_SUBMISSION"}
        # Distinct ids, as in the real store: a PATCH aimed at the editable
        # app info must not be able to land on the live one.
        ilocs["ai-edit"] = {"ie-" + k[3:]: dict(v) for k, v in ilocs["ai-live"].items()}
    return {
        "versions": {
            "v-new": {"platform": "IOS", "versionString": "1.54.0", "appStoreState": version_state},
            "v-live": {"platform": "IOS", "versionString": "1.53.0", "appStoreState": "READY_FOR_SALE"},
            "v-mac": {"platform": "MAC_OS", "versionString": "1.54.0", "appStoreState": version_state},
        },
        "vlocs": {"v-new": vlocs, "v-live": copy.deepcopy(vlocs),
                  "v-mac": {"m" + k: dict(v) for k, v in vlocs.items()}},
        "infos": infos,
        "ilocs": ilocs,
    }


EMPTY_VLOC = {"description": None, "keywords": None, "promotionalText": None,
              "supportUrl": None, "marketingUrl": None, "whatsNew": None}


class FakeASC:
    store: dict = {}
    writes: list = []
    drop: set = set()      # attributes a PATCH silently ignores
    # What App Store Connect did on 2026-09-28: creating an appInfoLocalization
    # made an EMPTY appStoreVersionLocalization for that locale on every
    # editable version, iOS and Mac. "late": they appear only when the next
    # version localization create arrives, after the pusher's re-read.
    auto_vlocs = "now"     # "now" | "late" | "off"
    queued: list = []
    constructed = 0

    def __init__(self) -> None:
        FakeASC.constructed += 1

    @staticmethod
    def _rows(table: dict) -> list:
        return [{"id": k, "attributes": dict(v)} for k, v in table.items()]

    @staticmethod
    def _add_empty_vlocs(locale: str) -> None:
        s = FakeASC.store
        for vid, v in s["versions"].items():
            if (v["appStoreState"] in pusher.EDITABLE_STATES
                    and all(r["locale"] != locale for r in s["vlocs"][vid].values())):
                s["vlocs"][vid][f"auto-{vid}-{locale}"] = {"locale": locale, **EMPTY_VLOC}

    def get(self, path: str, **params) -> dict:
        s = FakeASC.store
        if path == f"/apps/{APP}/appStoreVersions":
            rows = [r for r in self._rows(s["versions"])
                    if r["attributes"]["platform"] == params.get("filter[platform]")
                    and params.get("filter[versionString]") in (None, r["attributes"]["versionString"])]
            return {"data": rows}
        if path == f"/apps/{APP}/appInfos":
            return {"data": self._rows(s["infos"])}
        if path.startswith("/appStoreVersions/") and path.endswith("/appStoreVersionLocalizations"):
            return {"data": self._rows(s["vlocs"][path.split("/")[2]])}
        if path.startswith("/appInfos/") and path.endswith("/appInfoLocalizations"):
            return {"data": self._rows(s["ilocs"][path.split("/")[2]])}
        raise AssertionError(f"unexpected GET {path}")

    def write(self, method: str, path: str, body: dict):
        FakeASC.writes.append((method, path, copy.deepcopy(body)))
        s = FakeASC.store
        data = body["data"]
        attrs = {k: v for k, v in data.get("attributes", {}).items() if k not in FakeASC.drop}
        if method == "PATCH" and path.startswith("/appStoreVersionLocalizations/"):
            for table in s["vlocs"].values():
                if data["id"] in table:
                    table[data["id"]].update(attrs)
                    return {"data": data}
        elif method == "PATCH" and path.startswith("/appInfoLocalizations/"):
            for table in s["ilocs"].values():
                if data["id"] in table:
                    table[data["id"]].update(attrs)
                    return {"data": data}
        elif method == "POST" and path == "/appStoreVersionLocalizations":
            while FakeASC.queued:
                FakeASC._add_empty_vlocs(FakeASC.queued.pop(0))
            vid = data["relationships"]["appStoreVersion"]["data"]["id"]
            if any(r["locale"] == attrs["locale"] for r in s["vlocs"][vid].values()):
                # What the real client prints for the store's answer, and returns.
                print("    POST /appStoreVersionLocalizations -> 409")
                print("      ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE: Entity with locale: "
                      f"{attrs['locale']} already exists. Try updating.")
                return None
            s["vlocs"][vid][f"vl-new-{len(FakeASC.writes)}"] = dict(attrs)
            return {"data": data}
        elif method == "POST" and path == "/appInfoLocalizations":
            iid = data["relationships"]["appInfo"]["data"]["id"]
            s["ilocs"][iid][f"il-new-{len(FakeASC.writes)}"] = dict(attrs)
            if FakeASC.auto_vlocs == "now":
                FakeASC._add_empty_vlocs(attrs["locale"])
            elif FakeASC.auto_vlocs == "late":
                FakeASC.queued.append(attrs["locale"])
            return {"data": data}
        raise AssertionError(f"unexpected write {method} {path}")


def run(*argv: str) -> tuple[int, str]:
    out = io.StringIO()
    sys.argv = ["asc_push_listing.py", *argv]
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            code = pusher.main()
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
    return code, out.getvalue()


def fresh(auto_vlocs: str = "now", **kw) -> None:
    FakeASC.store = base_store(**kw)
    FakeASC.writes = []
    FakeASC.drop = set()
    FakeASC.auto_vlocs = auto_vlocs
    FakeASC.queued = []
    FakeASC.constructed = 0


def vloc_rows(vid: str) -> dict[str, dict]:
    return {r["locale"]: r for r in FakeASC.store["vlocs"][vid].values()}


def listing_complete(vid: str, platform: str) -> bool:
    """Every repo locale on the version with the repo texts and en-US's URLs."""
    rows = vloc_rows(vid)
    return all(loc in rows and rows[loc].get("supportUrl") == SUPPORT
               and rows[loc].get("marketingUrl") == MARKETING
               and all(rows[loc].get(a) == repo(a, loc, platform)
                       for a in ("description", "keywords", "promotionalText"))
               for loc in ALL)


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
            print("      " + detail.replace("\n", "\n      ")[:3000])
        failed += 1


RealASC = pusher.ASC
pusher.ASC = FakeASC
ALL = list(listing.LOCALE_SOURCES)
NEW = [loc for loc in ALL if loc not in ("en-US", "zh-Hans")]

# 1. dry run writes nothing
fresh()
code, out = run()
check("dry run exits 0 and writes nothing", code == 0 and not FakeASC.writes, out)
check("dry run reports the editable version", "1.54.0  state=PREPARE_FOR_SUBMISSION (editable)" in out, out)

# 2. live version refused
fresh()
code, out = run("--apply", "--version", "1.53.0", "--platform", "IOS")
check("apply to a READY_FOR_SALE version is refused with zero writes",
      code == 1 and not FakeASC.writes and "Nothing was written" in out, out)

# 3. apply needs --version and --platform
fresh()
code, out = run("--apply", "--platform", "IOS")
check("apply without --version is refused before contacting the store",
      code == 1 and not FakeASC.writes and FakeASC.constructed == 0, out)

# 4. invalid texts refused before the store is contacted
fresh()
real_validate = listing.validate
listing.validate = lambda root=None: [listing.Problem("ja/subtitle.txt", "planted problem")]
try:
    code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
finally:
    listing.validate = real_validate
check("invalid repo texts: refused, store never contacted",
      code == 1 and FakeASC.constructed == 0 and "planted problem" in out, out)

# 5. the real apply. As on 2026-09-28: each app info create makes the store
# add an empty version localization on 1.54.0, iOS and Mac.
fresh()
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
methods = [(m, p) for m, p, _ in FakeASC.writes]
check("apply to the editable version exits 0 (read-back verified)",
      code == 0 and "APPLY OK" in out, out)
check("never DELETEs", all(m in ("PATCH", "POST") for m, _ in methods), str(methods))
en_patch = [b for m, p, b in FakeASC.writes if p == "/appStoreVersionLocalizations/vl-en"]
check("en-US version: one PATCH with exactly the three changed fields",
      len(en_patch) == 1 and set(en_patch[0]["data"]["attributes"])
      == {"description", "keywords", "promotionalText"}, str(en_patch))
zh_patch = [b for m, p, b in FakeASC.writes if p == "/appStoreVersionLocalizations/vl-zh"]
check("zh-Hans version: only the stale field (keywords) is sent",
      len(zh_patch) == 1 and set(zh_patch[0]["data"]["attributes"]) == {"keywords"}, str(zh_patch))
check("no version localization is POSTed, so none gets 409: the store already made them",
      not any(m == "POST" and p == "/appStoreVersionLocalizations" for m, p in methods)
      and "409" not in out, out)
filled = {p.rsplit("-", 1)[1]: b["data"]["attributes"] for m, p, b in FakeASC.writes
          if m == "PATCH" and p.startswith("/appStoreVersionLocalizations/auto-v-new-")}
check("the rows the store made are PATCHed, one per new locale, and it says why",
      sorted(filled) == sorted(loc.split("-")[-1] for loc in NEW)
      and all(f"[{loc}] on the version now" in out for loc in NEW), str(sorted(filled)) + out)
check("... with the texts and en-US's support and marketing URLs",
      all(set(a) == {"description", "keywords", "promotionalText", "supportUrl", "marketingUrl"}
          and a["supportUrl"] == SUPPORT and a["marketingUrl"] == MARKETING
          for a in filled.values()), str(filled)[:600])
check("... and no What's New (asc_submit.py owns it)", all("whatsNew" not in a for a in filled.values()))
check("the iOS version now holds every locale's texts and URLs", listing_complete("v-new", "IOS"),
      str(vloc_rows("v-new"))[:800])
check("es-ES and es-MX receive the same Spanish text",
      vloc_rows("v-new")["es-ES"]["description"] == vloc_rows("v-new")["es-MX"]["description"]
      == repo("description", "es-ES"))
check("the Mac version got the store's empty rows too, and the iOS run left them alone",
      all(vloc_rows("v-mac")[loc] == {"locale": loc, **EMPTY_VLOC} for loc in NEW)
      and not any("auto-v-mac-" in p for _, p in methods), str(vloc_rows("v-mac"))[:600])
info_created = {b["data"]["attributes"]["locale"]: b["data"]
                for m, p, b in FakeASC.writes if m == "POST" and p == "/appInfoLocalizations"}
check("missing app info locales are created on the EDITABLE app info",
      sorted(info_created) == sorted(NEW)
      and all(d["relationships"]["appInfo"]["data"]["id"] == "ai-edit"
              for d in info_created.values()), str(info_created)[:400])
check("created app info carries name 'CLI Pulse' and en-US's privacy policy URL",
      all(d["attributes"]["name"] == "CLI Pulse" and d["attributes"]["privacyPolicyUrl"] == PRIVACY
          for d in info_created.values()))
check("the live app info is never written",
      not any(p.endswith(("/il-en", "/il-zh")) for _, p, _ in FakeASC.writes)
      and any(p == "/appInfoLocalizations/ie-en" for _, p, _ in FakeASC.writes),
      str(methods))
first_info = next(i for i, (m, p) in enumerate(methods) if "appInfoLocalizations" in p)
first_ver = next(i for i, (m, p) in enumerate(methods) if "appStoreVersionLocalizations" in p)
check("app info is written before version text", first_info < first_ver, str(methods))
check("apply reminds that new locales have no What's New yet", "no What's New yet" in out, out)

# 6. idempotent
FakeASC.writes = []
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
check("a second apply writes nothing and exits 0", code == 0 and not FakeASC.writes, out)

# 6b. the Mac run fills in the empty rows the iOS run made the store create
FakeASC.writes = []
code, out = run("--version", "1.54.0", "--platform", "MAC_OS")
check("Mac dry run: the store's empty rows need their texts and en-US's URLs",
      code == 0 and not FakeASC.writes and "supportUrl       ADD" in out
      and "marketingUrl     ADD" in out, out)
code, out = run("--apply", "--version", "1.54.0", "--platform", "MAC_OS")
mac_writes = [(m, p) for m, p, _ in FakeASC.writes]
check("Mac apply PATCHes those rows, creates nothing, and verifies",
      code == 0 and "APPLY OK" in out and all(m == "PATCH" for m, _ in mac_writes)
      and not any("appInfoLocalizations" in p for _, p in mac_writes)
      and listing_complete("v-mac", "MAC_OS"), out)
FakeASC.writes = []
code, out = run("--apply", "--version", "1.54.0", "--platform", "MAC_OS")
check("a second Mac apply writes nothing", code == 0 and not FakeASC.writes, out)

# 6c. a store that does not add version localizations: the pusher creates them
fresh(auto_vlocs="off")
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
created = {b["data"]["attributes"]["locale"]: b["data"]["attributes"]
           for m, p, b in FakeASC.writes if m == "POST" and p == "/appStoreVersionLocalizations"}
check("without the store's own rows, every missing locale is created on the version",
      code == 0 and sorted(created) == sorted(NEW) and listing_complete("v-new", "IOS"),
      str(sorted(created)) + out)
check("created version locales carry en-US's support and marketing URLs",
      all(a.get("supportUrl") == SUPPORT and a.get("marketingUrl") == MARKETING
          for a in created.values()), str(created)[:400])
check("created version locales carry no What's New (asc_submit.py owns it)",
      all("whatsNew" not in a for a in created.values()))

# 6d. the store adds its rows only after the pusher's re-read: the creates get
# 409, and the pusher PATCHes the rows it finds instead
fresh(auto_vlocs="late")
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
check("a create that gets 409 because the store made the row: that row is PATCHed, run OK",
      code == 0 and out.count("-> 409") == len(NEW) and "APPLY OK" in out
      and "MISMATCH" not in out and listing_complete("v-new", "IOS"), out)

# 6e. what the rerun on 2026-09-28 left behind: the store's rows hold the
# texts but no URLs, and the app info is done. Only the URLs are missing.
fresh()
for loc in NEW:
    FakeASC._add_empty_vlocs(loc)
    row = vloc_rows("v-new")[loc]
    row.update({a: repo(a, loc) for a in ("description", "keywords", "promotionalText")})
    FakeASC.store["ilocs"]["ai-edit"][f"ie-{loc}"] = {
        "locale": loc, "name": "CLI Pulse", "subtitle": repo("subtitle", loc),
        "privacyPolicyUrl": PRIVACY}
zh = FakeASC.store["vlocs"]["v-new"]["vl-zh"]
zh["supportUrl"] = None
zh["marketingUrl"] = "https://example.invalid/zh"   # its own: must stay
code, out = run("--version", "1.54.0", "--platform", "IOS")
check("dry run: a row with no URLs shows en-US's as ADD",
      code == 0 and out.count("supportUrl       ADD") == len(NEW) + 1
      and out.count("marketingUrl     ADD") == len(NEW), out)
FakeASC.writes = []
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
url_patches = {p.rsplit("-", 1)[1]: b["data"]["attributes"] for m, p, b in FakeASC.writes
               if p.startswith("/appStoreVersionLocalizations/auto-")}
zh_patch = [b["data"]["attributes"] for m, p, b in FakeASC.writes
            if p == "/appStoreVersionLocalizations/vl-zh"]
rows = vloc_rows("v-new")
check("... and the apply sends exactly the URLs those rows lack",
      code == 0 and "APPLY OK" in out and len(url_patches) == len(NEW)
      and all(a == {"supportUrl": SUPPORT, "marketingUrl": MARKETING} for a in url_patches.values())
      and not any(m == "POST" for m, _, _ in FakeASC.writes), out)
check("a locale's own URL stays; only the one it lacks is added",
      zh_patch and zh_patch[0].get("supportUrl") == SUPPORT and "marketingUrl" not in zh_patch[0]
      and rows["zh-Hans"]["marketingUrl"] == "https://example.invalid/zh"
      and all(rows[loc]["supportUrl"] == SUPPORT for loc in ALL), str(zh_patch))

# 6f. the read-back fails while a locale has no support URL
fresh()
FakeASC.drop = {"supportUrl"}
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
check("a support URL the store drops fails the run",
      code == 1 and all(f"MISMATCH [{loc}] supportUrl" in out for loc in NEW)
      and "APPLY INCOMPLETE" in out, out)
fresh()
del FakeASC.store["vlocs"]["v-new"]["vl-en"]["supportUrl"]
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
check("with no en-US support URL to copy, every locale without one is reported, and why",
      code == 1 and out.count("supportUrl: none") == len(ALL) - 1   # zh-Hans has its own
      and "[zh-Hans] supportUrl" not in out and "en-US has none to copy" in out, out)

# 7. wrong app name refused before the first write
fresh(app_name="CLI Pulse — AI usage")
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
check("a non-brand en-US app name is refused with zero writes",
      code == 1 and not FakeASC.writes and "expected 'CLI Pulse'" in out, out)

# 8. --locale filter
fresh()
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS", "--locale", "ja")
locs_written = {b["data"].get("attributes", {}).get("locale") for m, p, b in FakeASC.writes
                if m == "POST"}
check("--locale ja writes only ja", code == 0 and locs_written == {"ja"}
      and not any(p.endswith(("vl-en", "vl-zh", "ie-en", "ie-zh")) for m, p, _ in FakeASC.writes),
      str(FakeASC.writes)[:400])

# 9. a silently dropped write is caught by the read-back
fresh()
FakeASC.drop = {"promotionalText"}
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
check("a write the store drops fails the run (read-back MISMATCH)",
      code == 1 and "MISMATCH" in out and "promotionalText" in out, out)

# 10. no editable app info: version written, subtitle reported as not applied
fresh(editable_info=False)
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
check("without an editable app info the run is incomplete, and says why",
      code == 1 and "subtitle: NOT written" in out
      and not any("appInfoLocalizations" in p for _, p, _ in FakeASC.writes), out)
check("... while the version text is still written",
      any(p == "/appStoreVersionLocalizations/vl-en" for _, p, _ in FakeASC.writes))

# 11. a create whose response is lost, or that the store rejects: the read-back decides
class _UnconfirmedCreates(FakeASC):
    """ja's two creates come back as None: `land` says whether they reached the store
    (the response was lost) or not (the store refused them)."""
    land = True

    def write(self, method, path, body):
        if method == "POST" and body["data"]["attributes"].get("locale") == "ja":
            if _UnconfirmedCreates.land:
                FakeASC.write(self, method, path, body)
            else:
                FakeASC.writes.append((method, path, copy.deepcopy(body)))
            return None
        return FakeASC.write(self, method, path, body)


pusher.ASC = _UnconfirmedCreates
try:
    fresh()
    _UnconfirmedCreates.land = True
    code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
    check("a create that landed without its response does not fail the run",
          code == 0 and "not confirmed" in out and "APPLY OK" in out
          and "MISMATCH" not in out, out)

    fresh()
    _UnconfirmedCreates.land = False
    code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
    check("a create the store refused fails the run through the read-back",
          code == 1 and "MISMATCH [ja] description" in out
          and "MISMATCH [ja] subtitle" in out and "APPLY INCOMPLETE" in out, out)
finally:
    pusher.ASC = FakeASC
    _UnconfirmedCreates.land = True


# 12. the real client's retry rule, with the HTTP layer faked
class _Timeout(Exception):
    pass


class _ConnectionError(Exception):
    pass


class _FlakyRequests:
    """Stands in for the `requests` module: the first `fail` calls time out."""
    Timeout = _Timeout
    ConnectionError = _ConnectionError

    def __init__(self, fail: int) -> None:
        self.fail = fail
        self.calls: list[str] = []

    def request(self, method, url, **kw):
        self.calls.append(method)
        if len(self.calls) <= self.fail:
            raise _Timeout()

        class _Resp:
            status_code = 200
            text = "{}"

            @staticmethod
            def json():
                return {}
        return _Resp()


def real_client(fail: int):
    client = RealASC.__new__(RealASC)   # skip __init__: no key, no jwt
    client._requests = _FlakyRequests(fail)
    client._headers = {}
    return client


real_sleep = pusher.time.sleep
pusher.time.sleep = lambda _s: None
try:
    c = real_client(fail=1)
    with contextlib.redirect_stderr(io.StringIO()):
        res = c.write("PATCH", "/appStoreVersionLocalizations/x", {"data": {}})
    check("a PATCH that times out once is sent again and succeeds",
          res == {} and c._requests.calls == ["PATCH", "PATCH"], str(c._requests.calls))

    c = real_client(fail=1)
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        res = c.write("POST", "/appStoreVersionLocalizations", {"data": {}})
    check("a POST that times out is sent once, reported, and not retried",
          res is None and c._requests.calls == ["POST"] and "not sent again" in err.getvalue(),
          f"{c._requests.calls} {err.getvalue()}")

    c = real_client(fail=pusher._RETRIES)
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            c.get("/apps/x")
        gave_up = False
    except SystemExit:
        gave_up = True
    check(f"a GET that times out {pusher._RETRIES} times gives up",
          gave_up and c._requests.calls == ["GET"] * pusher._RETRIES, str(c._requests.calls))

    # 13. the token: at most 20 minutes, so a long run mints it again.
    class _StatusRequests(_FlakyRequests):
        """Answers with the given status codes in turn, then 200."""
        def __init__(self, statuses: list[int]) -> None:
            super().__init__(0)
            self.statuses = list(statuses)
            self.auth: list[str] = []

        def request(self, method, url, **kw):
            self.auth.append(kw["headers"].get("Authorization", ""))
            resp = super().request(method, url, **kw)
            if self.statuses:
                resp.status_code = self.statuses.pop(0)
            return resp

    def minting_client(statuses: list[int], age: float = 0.0):
        c = RealASC.__new__(RealASC)
        c._requests = _StatusRequests(statuses)
        c._key = object()   # stands for the key file; _mint is replaced below
        c.mints = 0

        def fake_mint() -> None:
            c.mints += 1
            c._headers = {"Authorization": f"Bearer token-{c.mints}"}
            c._minted_at = pusher.time.monotonic()
        c._mint = fake_mint
        fake_mint()
        c._minted_at -= age
        return c

    c = minting_client([], age=pusher.TOKEN_RENEW_AFTER + 1)
    c.get("/apps/x")
    check("a token older than TOKEN_RENEW_AFTER is minted again before the request",
          c.mints == 2 and c._requests.auth == ["Bearer token-2"], str(c._requests.auth))
    c = minting_client([])
    c.get("/apps/x")
    check("a young token is used as it is", c.mints == 1 and c._requests.auth == ["Bearer token-1"])
    c = minting_client([401])
    with contextlib.redirect_stderr(io.StringIO()):
        c.get("/apps/x")
    check("a 401 mints a new token and sends once more, with it",
          c.mints == 2 and c._requests.auth == ["Bearer token-1", "Bearer token-2"],
          str(c._requests.auth))
    c = minting_client([401, 401])
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            c.get("/apps/x")
        refused = False
    except SystemExit:
        refused = True
    check("a second 401 is not retried again: the GET fails",
          refused and c._requests.calls == ["GET", "GET"], str(c._requests.calls))
    c = real_client(fail=0)
    c._requests = _StatusRequests([401])
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            c.get("/apps/x")
        refused = False
    except SystemExit:
        refused = True
    check("a client without a key (the tests' stand-in) does not try to mint", refused)
finally:
    pusher.time.sleep = real_sleep

print(f"test_asc_push_listing: {passed} passed, {failed} failed.")
sys.exit(1 if failed else 0)

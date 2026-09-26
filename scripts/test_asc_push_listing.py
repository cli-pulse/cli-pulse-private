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
    the missing locales with supportUrl/marketingUrl copied from en-US and app
    info with name "CLI Pulse" + en-US's privacyPolicyUrl, never DELETEs, and a
    second run writes nothing (idempotent);
  * an en-US app name that is not "CLI Pulse" is refused before the first write;
  * --locale limits the writes to the named locales;
  * a write the store silently drops is caught by the read-back and fails;
  * with no editable app info, the version text is written but the run reports
    the subtitle as not applied and exits non-zero;
  * the real client retries a timed-out GET or PATCH but sends a POST (a create)
    only once, so a create that landed without its response is not sent again.

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
        },
        "vlocs": {"v-new": vlocs, "v-live": copy.deepcopy(vlocs)},
        "infos": infos,
        "ilocs": ilocs,
    }


class FakeASC:
    store: dict = {}
    writes: list = []
    drop: set = set()      # attributes a PATCH silently ignores
    constructed = 0

    def __init__(self) -> None:
        FakeASC.constructed += 1

    @staticmethod
    def _rows(table: dict) -> list:
        return [{"id": k, "attributes": dict(v)} for k, v in table.items()]

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
            vid = data["relationships"]["appStoreVersion"]["data"]["id"]
            s["vlocs"][vid][f"vl-new-{len(FakeASC.writes)}"] = dict(attrs)
            return {"data": data}
        elif method == "POST" and path == "/appInfoLocalizations":
            iid = data["relationships"]["appInfo"]["data"]["id"]
            s["ilocs"][iid][f"il-new-{len(FakeASC.writes)}"] = dict(attrs)
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


def fresh(**kw) -> None:
    FakeASC.store = base_store(**kw)
    FakeASC.writes = []
    FakeASC.drop = set()
    FakeASC.constructed = 0


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

# 5. the real apply
fresh()
code, out = run("--apply", "--version", "1.54.0", "--platform", "IOS")
methods = [(m, p) for m, p, _ in FakeASC.writes]
check("apply to the editable version exits 0 (read-back verified)", code == 0, out)
check("never DELETEs", all(m in ("PATCH", "POST") for m, _ in methods), str(methods))
en_patch = [b for m, p, b in FakeASC.writes if p == "/appStoreVersionLocalizations/vl-en"]
check("en-US version: one PATCH with exactly the three changed fields",
      len(en_patch) == 1 and set(en_patch[0]["data"]["attributes"])
      == {"description", "keywords", "promotionalText"}, str(en_patch))
zh_patch = [b for m, p, b in FakeASC.writes if p == "/appStoreVersionLocalizations/vl-zh"]
check("zh-Hans version: only the stale field (keywords) is sent",
      len(zh_patch) == 1 and set(zh_patch[0]["data"]["attributes"]) == {"keywords"}, str(zh_patch))
created = {b["data"]["attributes"]["locale"]: b["data"]["attributes"]
           for m, p, b in FakeASC.writes if m == "POST" and p == "/appStoreVersionLocalizations"}
check("every missing locale is created on the version", sorted(created) == sorted(NEW),
      str(sorted(created)))
check("created version locales carry en-US's support and marketing URLs",
      all(a.get("supportUrl") == SUPPORT and a.get("marketingUrl") == MARKETING
          for a in created.values()), str(created)[:400])
check("created version locales carry no What's New (asc_submit.py owns it)",
      all("whatsNew" not in a for a in created.values()))
check("es-ES and es-MX receive the same Spanish text",
      created.get("es-ES", {}).get("description") == created.get("es-MX", {}).get("description")
      == repo("description", "es-ES"))
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

# 11. the real client's retry rule, with the HTTP layer faked
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
finally:
    pusher.time.sleep = real_sleep

print(f"test_asc_push_listing: {passed} passed, {failed} failed.")
sys.exit(1 if failed else 0)

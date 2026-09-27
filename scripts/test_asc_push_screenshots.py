#!/usr/bin/env python3
"""Offline tests for scripts/asc_push_screenshots.py, against a fake App Store Connect.

Like test_asc_push_listing.py: the write path can only run for real while a
version is being prepared, so this replaces the client with an in-memory fake
of the endpoints the pusher uses and checks what it WOULD do:

  * a dry run sends nothing and lists every file with its md5;
  * a panel App Store Connect would refuse (alpha, wrong size) stops --apply
    before the store is contacted;
  * --apply to a live or WAITING_FOR_REVIEW version, or to a version missing a
    locale's localization, is refused with zero writes;
  * the real apply uploads every new panel and waits for COMPLETE before it
    deletes a single old one, sets the order, verifies md5 and size, touches
    only APP_IPHONE_67, gives es-ES and es-MX the same Spanish files, and a
    second run writes nothing;
  * a set no clean compose run wrote (no compose.json) is refused like one
    App Store Connect would refuse;
  * a panel App Store Connect fails to process: the new ones are removed and
    the old set is left exactly as it was; the same when a read ends the run
    (a 5xx) or Ctrl-C lands mid-upload; a refused cleanup is reported with
    the ids left, never as "untouched";
  * a rerun after a run that stopped halfway reuses the panels it already
    uploaded, deletes unfinished uploads first, and never has to delete the
    live set first because of its own leftovers;
  * a set that would exceed 10 with both present deletes the old ones first;
  * a locale without an iPhone set gets one created;
  * --locale limits the writes;
  * an upload part is sent with the headers App Store Connect named and never
    the API's bearer token.

Runs with a bare python3 (no Pillow, jwt or requests); CI runs it in repo-hygiene.yml.
"""
from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import appstore_screenshots as shots  # noqa: E402
import asc_push_listing as listing_pusher  # noqa: E402
import asc_push_screenshots as pusher  # noqa: E402

APP = listing_pusher.APP_ID
ALL = list(shots.SHOT_SOURCES)

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


# ── a repo with composed panels, in a temp dir ───────────────────────────────

TMP = Path(tempfile.mkdtemp(prefix="asc-shots-test-"))
REAL_REPO = shots.REPO


def make_panels(lang: str, *, bad: str | None = None, width: int = 1290) -> None:
    for i, p in enumerate(shots.expected_composed(lang, TMP)):
        color = 6 if (bad == "alpha" and i == 2) else 2
        # Different pixel data per language so md5s differ between sets.
        shots.write_png(p, width if i == 0 else 1290, 2796 + 0 * i, color_type=color)
        p.write_bytes(p.read_bytes() + lang.encode() + bytes([i]))  # trailing bytes: unique md5
    if bad != "no-manifest":
        shots.write_manifest(shots.composed_dir(lang, TMP), lang)


def fresh_repo(**kw) -> None:
    for p in [*TMP.rglob("*.png"), *TMP.rglob(shots.MANIFEST)]:
        p.unlink()
    for lang in shots.LANGS:
        make_panels(lang, **(kw if lang == "ja" else {}))


def md5s(lang: str) -> list[str]:
    return [hashlib.md5(p.read_bytes()).hexdigest() for p in shots.expected_composed(lang, TMP)]


# ── the fake store ───────────────────────────────────────────────────────────

class FakeASC:
    store: dict = {}
    log: list = []           # ("POST"/"PATCH"/"DELETE"/"PUT", path or id)
    uploads: dict = {}       # shot id -> bytes received
    fail_processing: set = set()   # fileNames App Store Connect marks FAILED
    fail_get: set = set()          # screenshot ids whose GET ends the run (a 5xx: die)
    fail_delete = False            # every DELETE is refused
    interrupt_upload_of: str | None = None   # a fileName whose part PUT raises Ctrl-C
    constructed = 0
    next_id = 0

    def __init__(self) -> None:
        FakeASC.constructed += 1

    # reads
    def get(self, path: str, **params) -> dict:
        s = FakeASC.store
        if path == f"/apps/{APP}/appStoreVersions":
            rows = [{"id": k, "attributes": dict(v)} for k, v in s["versions"].items()
                    if v["platform"] == params.get("filter[platform]")
                    and params.get("filter[versionString]") in (None, v["versionString"])]
            return {"data": rows}
        if path.endswith("/appStoreVersionLocalizations"):
            vid = path.split("/")[2]
            return {"data": [{"id": k, "attributes": dict(v)} for k, v in s["vlocs"][vid].items()]}
        if path.endswith("/appScreenshotSets"):
            lid = path.split("/")[2]
            return {"data": [{"id": k, "attributes": {"screenshotDisplayType": v["type"]}}
                             for k, v in s["sets"].items() if v["loc"] == lid]}
        if path.startswith("/appScreenshotSets/") and path.endswith("/appScreenshots"):
            sid = path.split("/")[2]
            return {"data": [self._shot(i) for i in s["sets"][sid]["shots"]]}
        if path.startswith("/appScreenshots/"):
            if path.split("/")[2] in FakeASC.fail_get:
                listing_pusher.die(f"GET {path} -> 503: Service Unavailable")
            return {"data": self._shot(path.split("/")[2])}
        raise AssertionError(f"unexpected GET {path}")

    @staticmethod
    def _shot(i: str) -> dict:
        a = FakeASC.store["shots"][i]
        return {"id": i, "attributes": {
            "fileName": a["fileName"], "fileSize": a["fileSize"],
            "sourceFileChecksum": a.get("sourceFileChecksum"),
            "assetDeliveryState": {"state": a["state"], "errors": []}}}

    # writes
    def write(self, method: str, path: str, body: dict):
        s = FakeASC.store
        FakeASC.log.append((method, path))
        data = body["data"]
        if method == "POST" and path == "/appScreenshots":
            sid = data["relationships"]["appScreenshotSet"]["data"]["id"]
            if len(s["sets"][sid]["shots"]) >= pusher.MAX_PER_SET:
                return None     # the real store refuses an 11th
            FakeASC.next_id += 1
            new_id = f"shot-{FakeASC.next_id}"
            a = data["attributes"]
            s["shots"][new_id] = {"fileName": a["fileName"], "fileSize": a["fileSize"],
                                  "state": "AWAITING_UPLOAD", "set": sid}
            s["sets"][sid]["shots"].append(new_id)
            half = a["fileSize"] // 2
            ops = [{"method": "PUT", "url": f"https://upload.invalid/{new_id}/0", "offset": 0,
                    "length": half, "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]},
                   {"method": "PUT", "url": f"https://upload.invalid/{new_id}/1", "offset": half,
                    "length": a["fileSize"] - half, "requestHeaders": []}]
            return {"data": {"id": new_id, "attributes": {"uploadOperations": ops}}}
        if method == "PATCH" and path.startswith("/appScreenshots/"):
            i = path.split("/")[2]
            a = s["shots"][i]
            got = FakeASC.uploads.get(i, b"")
            a["sourceFileChecksum"] = data["attributes"]["sourceFileChecksum"]
            ok = (len(got) == a["fileSize"]
                  and hashlib.md5(got).hexdigest() == a["sourceFileChecksum"]
                  and a["fileName"] not in FakeASC.fail_processing)
            a["state"] = "COMPLETE" if ok else "FAILED"
            return {"data": {"id": i}}
        if method == "PATCH" and path.endswith("/relationships/appScreenshots"):
            sid = path.split("/")[2]
            ids = [d["id"] for d in data]
            assert sorted(ids) == sorted(s["sets"][sid]["shots"]), (ids, s["sets"][sid]["shots"])
            s["sets"][sid]["shots"] = ids
            return {}
        if method == "POST" and path == "/appScreenshotSets":
            new_id = f"set-new-{len(s['sets'])}"
            s["sets"][new_id] = {"loc": data["relationships"]["appStoreVersionLocalization"]["data"]["id"],
                                 "type": data["attributes"]["screenshotDisplayType"], "shots": []}
            return {"data": {"id": new_id}}
        raise AssertionError(f"unexpected write {method} {path}")

    def delete(self, path: str) -> bool:
        s = FakeASC.store
        FakeASC.log.append(("DELETE", path))
        if FakeASC.fail_delete:
            return False
        i = path.split("/")[2]
        shot = s["shots"].pop(i)
        s["sets"][shot["set"]]["shots"].remove(i)
        return True

    def upload_part(self, op: dict, chunk: bytes) -> bool:
        i = op["url"].split("/")[3]
        FakeASC.log.append(("PUT", i))
        if FakeASC.store["shots"][i]["fileName"] == FakeASC.interrupt_upload_of:
            raise KeyboardInterrupt
        FakeASC.uploads[i] = FakeASC.uploads.get(i, b"") + chunk
        return True


def base_store(state: str = "PREPARE_FOR_SUBMISSION", old_per_set: int = 5,
               drop_locale: str | None = None, no_set_for: str | None = None) -> dict:
    vlocs = {f"vl-{loc}": {"locale": loc} for loc in ALL if loc != drop_locale}
    sets, shots_tbl = {}, {}
    for lid, attrs in vlocs.items():
        # The iPad set comes first, so a pusher that took the first set it saw
        # would write to it.
        ipad = f"ipad-{attrs['locale']}"
        sets[ipad] = {"loc": lid, "type": "APP_IPAD_PRO_3GEN_129", "shots": [f"{ipad}-0"]}
        shots_tbl[f"{ipad}-0"] = {"fileName": "ipad.png", "fileSize": 7, "state": "COMPLETE",
                                  "sourceFileChecksum": "1" * 32, "set": ipad}
        if attrs["locale"] != no_set_for:
            sid = f"set-{attrs['locale']}"
            sets[sid] = {"loc": lid, "type": "APP_IPHONE_67", "shots": []}
            for n in range(old_per_set):
                i = f"old-{attrs['locale']}-{n}"
                shots_tbl[i] = {"fileName": f"old_{n}.png", "fileSize": 100, "state": "COMPLETE",
                                "sourceFileChecksum": "0" * 32, "set": sid}
                sets[sid]["shots"].append(i)
    return {
        "versions": {
            "v-new": {"platform": "IOS", "versionString": "1.54.0", "appStoreState": state},
            "v-live": {"platform": "IOS", "versionString": "1.53.0", "appStoreState": "READY_FOR_SALE"},
        },
        "vlocs": {"v-new": vlocs, "v-live": copy.deepcopy(vlocs)},
        "sets": sets,
        "shots": shots_tbl,
    }


def fresh(**kw) -> None:
    FakeASC.store = base_store(**kw)
    FakeASC.log = []
    FakeASC.uploads = {}
    FakeASC.fail_processing = set()
    FakeASC.fail_get = set()
    FakeASC.fail_delete = False
    FakeASC.interrupt_upload_of = None
    FakeASC.constructed = 0


def writes() -> list:
    return [x for x in FakeASC.log]


def run(*argv: str) -> tuple[int, str]:
    out = io.StringIO()
    sys.argv = ["asc_push_screenshots.py", *argv]
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            code = pusher.main()
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
    return code, out.getvalue()


def set_files(loc: str) -> list[tuple[str, str]]:
    s = FakeASC.store
    sid = next(k for k, v in s["sets"].items()
               if v["type"] == "APP_IPHONE_67" and s["vlocs"]["v-new"][v["loc"]]["locale"] == loc)
    return [(s["shots"][i]["fileName"], s["shots"][i].get("sourceFileChecksum")) for i in s["sets"][sid]["shots"]]


RealShotsASC = pusher.ShotsASC
pusher.ShotsASC = FakeASC
pusher.time.sleep = lambda _s: None
pusher.POLL_TIMEOUT = 0.5   # sleep is a no-op here; a stuck poll must end, not hang
shots.REPO = TMP
try:
    # 1. dry run
    fresh_repo()
    fresh()
    code, out = run()
    check("dry run exits 0 and writes nothing", code == 0 and not writes(), out)
    check("dry run lists every local file with its md5",
          all(m in out for m in md5s("ja")) and "01_overview_1290x2796.png" in out, out)
    check("dry run says each locale would be replaced, and names the untouched sets",
          out.count("(replace)") == len(ALL) and "untouched: APP_IPAD_PRO_3GEN_129" in out, out)

    # 2. an invalid panel stops --apply before the store is contacted
    fresh_repo(bad="alpha")
    fresh()
    code, out = run("--apply", "--version", "1.54.0")
    check("a panel with alpha: refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "RGBA" in out
          and "nothing was written or deleted" in out, out)
    fresh_repo(width=1284)
    fresh()
    code, out = run("--apply", "--version", "1.54.0")
    check("a panel of the wrong size: refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "1284x2796" in out, out)
    fresh_repo(bad="no-manifest")
    fresh()
    code, out = run("--apply", "--version", "1.54.0")
    check("a set no clean compose run wrote (no compose.json): refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "compose.json is missing" in out, out)
    fresh_repo()

    # 3. editability
    fresh()
    code, out = run("--apply", "--version", "1.53.0")
    check("apply to a READY_FOR_SALE version is refused with zero writes",
          code == 1 and not writes() and "Nothing was written" in out, out)
    fresh(state="WAITING_FOR_REVIEW")
    code, out = run("--apply", "--version", "1.54.0")
    check("apply while WAITING_FOR_REVIEW is refused, with the withdraw hint",
          code == 1 and not writes() and "Withdraw the iOS submission" in out, out)
    fresh()
    code, out = run("--apply")
    check("apply without --version is refused before contacting the store",
          code == 1 and FakeASC.constructed == 0, out)

    # 4. a locale with no localization on the version
    fresh(drop_locale="ko")
    code, out = run("--apply", "--version", "1.54.0")
    check("a locale missing its localization: refused with zero writes",
          code == 1 and not writes() and "no localization for ko" in out, out)

    # 5. the real apply
    fresh()
    ipad_before = {k: list(v["shots"]) for k, v in FakeASC.store["sets"].items()
                   if v["type"] != "APP_IPHONE_67"}
    code, out = run("--apply", "--version", "1.54.0")
    check("apply exits 0 and verifies", code == 0 and "APPLY OK" in out, out)
    for loc in ALL:
        lang = shots.SHOT_SOURCES[loc]
        want = list(zip([p.name for p in shots.expected_composed(lang, TMP)], md5s(lang)))
        if set_files(loc) != want:
            check(f"[{loc}] holds exactly the new panels in order", False, str(set_files(loc)))
            break
    else:
        check("every locale holds exactly the new panels, in order, with their md5", True)
    check("es-ES and es-MX got the same Spanish files", set_files("es-ES") == set_files("es-MX"))
    check("only APP_IPHONE_67 sets were touched",
          {k: list(v["shots"]) for k, v in FakeASC.store["sets"].items()
           if v["type"] != "APP_IPHONE_67"} == ipad_before
          and not any("ipad" in p for _, p in FakeASC.log))
    # Per locale: every new upload is committed before the first old one is deleted.
    # Locales go in order, five commits each, so by the time a locale's first
    # old panel is deleted, its own five (and every earlier locale's) are in.
    order_ok = True
    commits = [i for i, (m, p) in enumerate(FakeASC.log)
               if m == "PATCH" and p.startswith("/appScreenshots/")]
    for n, loc in enumerate(ALL, start=1):
        del_idx = [i for i, (m, p) in enumerate(FakeASC.log) if m == "DELETE" and f"old-{loc}-" in p]
        if not del_idx or len([i for i in commits if i < min(del_idx)]) < 5 * n:
            order_ok = False
    check("each locale's old panels are deleted only after its new ones are committed", order_ok,
          str(FakeASC.log)[:1500])
    check("uploaded bytes are the local files", all(
        hashlib.md5(b).hexdigest() == FakeASC.store["shots"][i]["sourceFileChecksum"]
        for i, b in FakeASC.uploads.items() if i in FakeASC.store["shots"]))

    # 6. idempotent
    FakeASC.log = []
    code, out = run("--apply", "--version", "1.54.0")
    check("a second apply writes nothing and exits 0",
          code == 0 and not writes() and out.count("nothing to do") == len(ALL), out)

    # 7. App Store Connect fails to process one panel
    fresh()
    FakeASC.fail_processing = {"03_cost_1290x2796.png"}
    code, out = run("--apply", "--version", "1.54.0", "--locale", "ja")
    check("a panel the store fails: run fails, the new ones are removed, the old set is intact",
          code == 1 and set_files("ja") == [(f"old_{n}.png", "0" * 32) for n in range(5)]
          and "the live set is untouched" in out and "App Store Connect FAILED it" in out, out)

    # 7b. a read that ends the run while the new panels are processing
    fresh()
    FakeASC.fail_get = {"shot-3"}
    FakeASC.next_id = 0
    code, out = run("--apply", "--version", "1.54.0", "--locale", "ja")
    check("a GET that dies mid-run: the new ones are removed first, the old set is intact",
          code == 2 and set_files("ja") == [(f"old_{n}.png", "0" * 32) for n in range(5)]
          and "stopped by SystemExit" in out and "removed the 5 added; the live set is untouched" in out,
          out)

    # 7c. the cleanup itself is refused: the run must not claim a clean set
    fresh()
    FakeASC.fail_processing = {"03_cost_1290x2796.png"}
    FakeASC.fail_delete = True
    code, out = run("--apply", "--version", "1.54.0", "--locale", "ja")
    check("a refused cleanup is reported with the ids left, never as 'untouched'",
          code == 1 and "could NOT remove 5 of the 5 added" in out
          and "the live set is untouched" not in out and len(set_files("ja")) == 10, out)

    # 7d. Ctrl-C in the middle of an upload
    fresh()
    FakeASC.interrupt_upload_of = "04_sessions_1290x2796.png"
    interrupted = False
    try:
        run("--apply", "--version", "1.54.0", "--locale", "ja")
    except KeyboardInterrupt:
        interrupted = True
    check("Ctrl-C mid-upload: the reserved panel and the ones before it are removed, then it stops",
          interrupted and set_files("ja") == [(f"old_{n}.png", "0" * 32) for n in range(5)],
          str(set_files("ja")))

    # 7e. a rerun after a run that stopped with both sets in place (5 old + 5 new)
    fresh()
    ja_set = "set-ja"
    for n, (p, m) in enumerate(zip(shots.expected_composed("ja", TMP), md5s("ja"))):
        i = f"left-{n}"
        FakeASC.store["shots"][i] = {"fileName": p.name, "fileSize": p.stat().st_size,
                                     "state": "COMPLETE", "sourceFileChecksum": m, "set": ja_set}
        FakeASC.store["sets"][ja_set]["shots"].append(i)
    code, out = run("--apply", "--version", "1.54.0", "--locale", "ja")
    check("a rerun reuses what the stopped run uploaded: no upload, no delete-first, old ones gone",
          code == 0 and "reusing them" in out and "would exceed" not in out
          and not any(m == "POST" for m, _ in FakeASC.log)
          and set_files("ja") == list(zip([p.name for p in shots.expected_composed("ja", TMP)], md5s("ja")))
          and all(f"old-ja-{n}" not in FakeASC.store["shots"] for n in range(5)), out)

    # 7f. unfinished uploads from a stopped run are deleted before anything else
    fresh()
    for n in range(3):
        i = f"debris-{n}"
        FakeASC.store["shots"][i] = {"fileName": f"0{n + 1}_x.png", "fileSize": 9,
                                     "state": "AWAITING_UPLOAD", "set": ja_set}
        FakeASC.store["sets"][ja_set]["shots"].append(i)
    code, out = run("--apply", "--version", "1.54.0", "--locale", "ja")
    first_debris = min((i for i, (m, p) in enumerate(FakeASC.log) if m == "DELETE" and "debris" in p),
                       default=10**6)
    first_post = min((i for i, (m, p) in enumerate(FakeASC.log) if m == "POST"), default=-1)
    first_old = min((i for i, (m, p) in enumerate(FakeASC.log) if m == "DELETE" and "old-ja" in p),
                    default=-1)
    check("unfinished uploads go first; the live set still goes only after the new one is in",
          code == 0 and first_debris < first_post < first_old and "would exceed" not in out
          and [n for n, _ in set_files("ja")] == [p.name for p in shots.expected_composed("ja", TMP)], out)

    # 8. 8 old + 5 new > 10: old first
    fresh(old_per_set=8)
    code, out = run("--apply", "--version", "1.54.0", "--locale", "en-US")
    first_post = next(i for i, (m, p) in enumerate(FakeASC.log) if m == "POST")
    first_del = next(i for i, (m, p) in enumerate(FakeASC.log) if m == "DELETE")
    check("a set that would exceed 10 deletes the old panels first, and says so",
          code == 0 and first_del < first_post and "would exceed 10" in out
          and [n for n, _ in set_files("en-US")] == [p.name for p in shots.expected_composed("en", TMP)],
          out)

    # 9. no iPhone set yet
    fresh(no_set_for="ko")
    code, out = run("--apply", "--version", "1.54.0", "--locale", "ko")
    check("a locale with no iPhone set gets one, then its panels",
          code == 0 and ("POST", "/appScreenshotSets") in FakeASC.log and len(set_files("ko")) == 5, out)

    # 10. --locale
    fresh()
    code, out = run("--apply", "--version", "1.54.0", "--locale", "ja")
    touched = {p.split("-")[1] for m, p in FakeASC.log if m == "DELETE"}
    check("--locale ja writes only ja", code == 0 and touched == {"ja"}, str(FakeASC.log)[:600])
finally:
    shots.REPO = REAL_REPO
    pusher.ShotsASC = RealShotsASC


# 11. the real client's upload part: named headers only, no bearer token
class _Requests:
    Timeout = TimeoutError
    ConnectionError = ConnectionError

    def __init__(self) -> None:
        self.calls = []

    def request(self, method, url, **kw):
        self.calls.append((method, url, kw))

        class _R:
            status_code = 200
        return _R()


client = RealShotsASC.__new__(RealShotsASC)
client._requests = _Requests()
client._headers = {"Authorization": "Bearer secret-token", "Content-Type": "application/json"}
ok = client.upload_part({"method": "PUT", "url": "https://upload.invalid/x", "offset": 0, "length": 3,
                         "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]}, b"abc")
method, url, kw = client._requests.calls[0]
check("an upload part carries only the headers App Store Connect named",
      ok and kw["headers"] == {"Content-Type": "image/png"} and kw["data"] == b"abc"
      and "secret-token" not in repr(kw), repr(kw))

print(f"test_asc_push_screenshots: {passed} passed, {failed} failed.")
sys.exit(1 if failed else 0)

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
  * App Store Connect fills in a checksum seconds to a minute after it reports
    COMPLETE: the read-back waits for it (one run does every locale), and
    fails, saying why, if it never comes; a rerun that finds a COMPLETE panel
    with the right name and size but no checksum yet waits for it instead of
    re-uploading and deleting it, and changes nothing if it never comes;
  * a set that would exceed 10 with both present deletes only the overflow
    first, the rest once the new panels are COMPLETE;
  * --apply without --platform is refused; --platform MAC_OS touches only the
    macOS version's APP_DESKTOP sets (creating the missing ones), never iOS;
    it refuses Mac panels drawn by another version (compose.json), makes room
    with 4 deletes on 8 live and 5 on 9, and a failure after making room says
    how many of the live set were already gone;
  * a locale without an iPhone set gets one created;
  * --display-type APP_IPAD_PRO_3GEN_129 pushes the iPad panels to the IOS
    version's 13" iPad sets only (creating the missing ones, as the live store
    has them on two locales), never the iPhone sets beside them; refuses
    iPhone-sized panels, a set without compose.json, the MAC_OS platform, a
    version in review, and a write without --platform; and a second run
    writes nothing;
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
import json
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
    # As on 2026-09-28: a set read shows a just-committed screenshot COMPLETE
    # with sourceFileChecksum null, for this many reads of its set.
    checksum_lag = 0
    lag: dict = {}                 # shot id -> set reads left without its checksum
    wrong_checksum: set = set()    # fileNames a set read reports with another file's checksum
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
            rows = [self._shot(i) for i in s["sets"][sid]["shots"]]
            for r in rows:
                if FakeASC.lag.get(r["id"], 0) > 0:
                    FakeASC.lag[r["id"]] -= 1
                    r["attributes"]["sourceFileChecksum"] = None
                elif r["attributes"]["fileName"] in FakeASC.wrong_checksum:
                    r["attributes"]["sourceFileChecksum"] = "e" * 32
            return {"data": rows}
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
            FakeASC.lag[i] = FakeASC.checksum_lag
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
               drop_locale: str | None = None, no_set_for: str | None = None,
               ipad_locales=None, ipad_old: int = 1) -> dict:
    """`ipad_locales`: the locales with an iPad set (default every one), each of
    `ipad_old` old panels."""
    vlocs = {f"vl-{loc}": {"locale": loc} for loc in ALL if loc != drop_locale}
    sets, shots_tbl = {}, {}
    for lid, attrs in vlocs.items():
        # The iPad set comes first, so a pusher that took the first set it saw
        # would write to it.
        ipad = f"ipad-{attrs['locale']}"
        if ipad_locales is None or attrs["locale"] in ipad_locales:
            sets[ipad] = {"loc": lid, "type": "APP_IPAD_PRO_3GEN_129", "shots": []}
            for n in range(ipad_old):
                shots_tbl[f"{ipad}-{n}"] = {"fileName": "ipad.png" if n == 0 else f"ipad_{n}.png",
                                            "fileSize": 7, "state": "COMPLETE",
                                            "sourceFileChecksum": "1" * 32, "set": ipad}
                sets[ipad]["shots"].append(f"{ipad}-{n}")
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
    FakeASC.checksum_lag = 0
    FakeASC.lag = {}
    FakeASC.wrong_checksum = set()
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
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0")
    check("a panel with alpha: refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "RGBA" in out
          and "nothing was written or deleted" in out, out)
    fresh_repo(width=1284)
    fresh()
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0")
    check("a panel of the wrong size: refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "1284x2796" in out, out)
    fresh_repo(bad="no-manifest")
    fresh()
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0")
    check("a set no clean compose run wrote (no compose.json): refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "compose.json is missing" in out, out)
    fresh_repo()

    # 3. editability
    fresh()
    code, out = run("--apply", "--platform", "IOS", "--version", "1.53.0")
    check("apply to a READY_FOR_SALE version is refused with zero writes",
          code == 1 and not writes() and "Nothing was written" in out, out)
    fresh(state="WAITING_FOR_REVIEW")
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0")
    check("apply while WAITING_FOR_REVIEW is refused, with the withdraw hint",
          code == 1 and not writes() and "Withdraw the iOS submission" in out, out)
    fresh()
    code, out = run("--apply", "--platform", "IOS")
    check("apply without --version is refused before contacting the store",
          code == 1 and FakeASC.constructed == 0, out)
    fresh()
    code, out = run("--apply", "--version", "1.54.0")
    check("apply without --platform is refused before contacting the store",
          code == 1 and FakeASC.constructed == 0 and "--platform" in out, out)

    # 4. a locale with no localization on the version
    fresh(drop_locale="ko")
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0")
    check("a locale missing its localization: refused with zero writes",
          code == 1 and not writes() and "no localization for ko" in out, out)

    # 5. the real apply
    fresh()
    ipad_before = {k: list(v["shots"]) for k, v in FakeASC.store["sets"].items()
                   if v["type"] != "APP_IPHONE_67"}
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0")
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
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0")
    check("a second apply writes nothing and exits 0",
          code == 0 and not writes() and out.count("nothing to do") == len(ALL), out)

    # 7. App Store Connect fails to process one panel
    fresh()
    FakeASC.fail_processing = {"03_cost_1290x2796.png"}
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
    check("a panel the store fails: run fails, the new ones are removed, the old set is intact",
          code == 1 and set_files("ja") == [(f"old_{n}.png", "0" * 32) for n in range(5)]
          and "the live set is untouched" in out and "App Store Connect FAILED it" in out, out)

    # 7b. a read that ends the run while the new panels are processing
    fresh()
    FakeASC.fail_get = {"shot-3"}
    FakeASC.next_id = 0
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
    check("a GET that dies mid-run: the new ones are removed first, the old set is intact",
          code == 2 and set_files("ja") == [(f"old_{n}.png", "0" * 32) for n in range(5)]
          and "stopped by SystemExit" in out and "removed the 5 added; the live set is untouched" in out,
          out)

    # 7c. the cleanup itself is refused: the run must not claim a clean set
    fresh()
    FakeASC.fail_processing = {"03_cost_1290x2796.png"}
    FakeASC.fail_delete = True
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
    check("a refused cleanup is reported with the ids left, never as 'untouched'",
          code == 1 and "could NOT remove 5 of the 5 added" in out
          and "the live set is untouched" not in out and len(set_files("ja")) == 10, out)

    # 7d. Ctrl-C in the middle of an upload
    fresh()
    FakeASC.interrupt_upload_of = "04_sessions_1290x2796.png"
    interrupted = False
    try:
        run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
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
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
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
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
    first_debris = min((i for i, (m, p) in enumerate(FakeASC.log) if m == "DELETE" and "debris" in p),
                       default=10**6)
    first_post = min((i for i, (m, p) in enumerate(FakeASC.log) if m == "POST"), default=-1)
    first_old = min((i for i, (m, p) in enumerate(FakeASC.log) if m == "DELETE" and "old-ja" in p),
                    default=-1)
    check("unfinished uploads go first; the live set still goes only after the new one is in",
          code == 0 and first_debris < first_post < first_old and "would exceed" not in out
          and [n for n, _ in set_files("ja")] == [p.name for p in shots.expected_composed("ja", TMP)], out)

    # 7g. the read-back right after the commit sees no checksum on the new
    # panels yet; it waits for them, and one run does every locale
    fresh()
    FakeASC.checksum_lag = 3
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0")
    check("checksums that lag behind COMPLETE: the read-back waits, and one run does every locale",
          code == 0 and "APPLY OK" in out and "MISMATCH" not in out
          and out.count("checksums match") == len(ALL)
          and all(set_files(loc) == list(zip([p.name for p in shots.expected_composed(
              shots.SHOT_SOURCES[loc], TMP)], md5s(shots.SHOT_SOURCES[loc]))) for loc in ALL), out)
    fresh()
    FakeASC.checksum_lag = 10**9
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
    check("a checksum that never comes: the read-back gives up at POLL_TIMEOUT and says why",
          code == 1 and "5 screenshot(s) still without a checksum after" in out
          and "MISMATCH" in out and "no checksum]" in out, out)

    # 7h. a rerun right after a run whose last panel has no checksum yet: the
    # ja 05_alerts churn of 2026-09-28 (re-uploaded and deleted by four reruns)
    def settled_ja(lag: int, md5_of_last: str | None = None) -> None:
        fresh()
        FakeASC.store["sets"][ja_set]["shots"] = []
        for n in range(5):
            FakeASC.store["shots"].pop(f"old-ja-{n}")
        for n, (p, m) in enumerate(zip(shots.expected_composed("ja", TMP), md5s("ja"))):
            i = f"left-{n}"
            FakeASC.store["shots"][i] = {"fileName": p.name, "fileSize": p.stat().st_size,
                                         "state": "COMPLETE", "sourceFileChecksum": m, "set": ja_set}
            FakeASC.store["sets"][ja_set]["shots"].append(i)
        if md5_of_last:
            FakeASC.store["shots"]["left-4"]["sourceFileChecksum"] = md5_of_last
        FakeASC.lag = {"left-4": lag}

    settled_ja(lag=3)
    code, out = run("--version", "1.54.0", "--locale", "ja")
    check("dry run: a COMPLETE panel without a checksum yet is named, and --apply will wait",
          code == 0 and "1 COMPLETE without a checksum yet" in out, out)
    settled_ja(lag=3)
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
    check("a COMPLETE panel with the right name and size but no checksum yet is waited for, "
          "then kept: no upload, no delete",
          code == 0 and "waiting for App Store Connect" in out and "nothing to do" in out
          and not writes() and "left-4" in FakeASC.store["shots"], out)
    settled_ja(lag=3, md5_of_last="f" * 32)
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
    posts = [p for m, p in FakeASC.log if m == "POST"]
    check("... and once its checksum shows it is another file, it is replaced like any old one",
          code == 0 and "4 panel(s) already uploaded by an earlier run" in out
          and posts == ["/appScreenshots"] and "left-4" not in FakeASC.store["shots"]
          and set_files("ja") == list(zip([p.name for p in shots.expected_composed("ja", TMP)],
                                          md5s("ja"))), out)
    settled_ja(lag=10**9)
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
    check("a checksum that never comes: the rerun stops and changes nothing in the set",
          code == 1 and "still no checksum after" in out and "Nothing in this set was changed" in out
          and not writes() and "left-4" in FakeASC.store["shots"], out)

    # 8. 8 old + 5 new > 10: only the overflow goes first
    fresh(old_per_set=8)
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "en-US")
    first_post = next(i for i, (m, p) in enumerate(FakeASC.log) if m == "POST")
    dels = [i for i, (m, p) in enumerate(FakeASC.log) if m == "DELETE"]
    check("a set that would exceed 10 deletes only as many old panels first as it needs (3), "
          "the other 5 once the new ones are in, and says so",
          code == 0 and len([i for i in dels if i < first_post]) == 3
          and len([i for i in dels if i > first_post]) == 5 and "would exceed 10" in out
          and [n for n, _ in set_files("en-US")] == [p.name for p in shots.expected_composed("en", TMP)],
          out)

    # 9. no iPhone set yet
    fresh(no_set_for="ko")
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ko")
    check("a locale with no iPhone set gets one, then its panels",
          code == 0 and ("POST", "/appScreenshotSets") in FakeASC.log and len(set_files("ko")) == 5, out)

    # 10. --locale
    fresh()
    code, out = run("--apply", "--platform", "IOS", "--version", "1.54.0", "--locale", "ja")
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


# ── the Mac set: --platform MAC_OS, APP_DESKTOP ──────────────────────────────
# A store with both platforms' 1.54.0: iOS waiting for review (untouchable),
# macOS DEVELOPER_REJECTED (editable). Each macOS localization may have an
# APP_DESKTOP set of old panels; each iOS one has an iPhone set that must stay
# exactly as it is.
MAC = shots.MAC
MAC_W, MAC_H = MAC.canvas


def make_mac_panels(lang: str, *, version: str = "1.54.0", width: int = MAC_W) -> None:
    for i, p in enumerate(shots.expected_composed(lang, TMP, platform=MAC)):
        shots.write_png(p, width if i == 0 else MAC_W, MAC_H)
        p.write_bytes(p.read_bytes() + b"mac" + lang.encode() + bytes([i]))
    shots.write_manifest(shots.composed_dir(lang, TMP, platform=MAC), lang,
                         {"app": {"version": version, "build": "107"}}, platform=MAC)


def fresh_mac_repo(**kw) -> None:
    for p in [*TMP.rglob("*.png"), *TMP.rglob(shots.MANIFEST)]:
        p.unlink()
    for lang in shots.LANGS:
        make_mac_panels(lang, **(kw if lang == "ja" else {}))


def mac_store(mac_state: str = "DEVELOPER_REJECTED", old: dict | None = None) -> dict:
    """`old`: locale -> number of old APP_DESKTOP panels (absent = no set)."""
    old = {"en-US": 8, "zh-Hans": 9} if old is None else old
    ios_vlocs = {f"il-{loc}": {"locale": loc} for loc in ALL}
    mac_vlocs = {f"ml-{loc}": {"locale": loc} for loc in ALL}
    sets, tbl = {}, {}
    for lid, a in ios_vlocs.items():
        sid = f"iset-{a['locale']}"
        sets[sid] = {"loc": lid, "type": "APP_IPHONE_67", "shots": [f"{sid}-0"]}
        tbl[f"{sid}-0"] = {"fileName": "01_overview_1290x2796.png", "fileSize": 9, "state": "COMPLETE",
                           "sourceFileChecksum": "2" * 32, "set": sid}
    for lid, a in mac_vlocs.items():
        loc = a["locale"]
        if loc not in old:
            continue
        sid = f"mset-{loc}"
        sets[sid] = {"loc": lid, "type": "APP_DESKTOP", "shots": []}
        for n in range(old[loc]):
            i = f"mold-{loc}-{n}"
            tbl[i] = {"fileName": f"MAC_OS_APP_DESKTOP_{n:02d}.png", "fileSize": 100, "state": "COMPLETE",
                      "sourceFileChecksum": "0" * 32, "set": sid}
            sets[sid]["shots"].append(i)
    return {
        "versions": {
            "v-ios": {"platform": "IOS", "versionString": "1.54.0", "appStoreState": "WAITING_FOR_REVIEW"},
            "v-mac": {"platform": "MAC_OS", "versionString": "1.54.0", "appStoreState": mac_state},
        },
        "vlocs": {"v-ios": ios_vlocs, "v-mac": mac_vlocs},
        "sets": sets,
        "shots": tbl,
    }


def fresh_mac(**kw) -> None:
    fresh()
    FakeASC.store = mac_store(**kw)


def mac_files(loc: str) -> list[tuple[str, str]]:
    s = FakeASC.store
    sid = next((k for k, v in s["sets"].items()
                if v["type"] == "APP_DESKTOP" and s["vlocs"]["v-mac"][v["loc"]]["locale"] == loc), None)
    return [] if sid is None else [(s["shots"][i]["fileName"], s["shots"][i].get("sourceFileChecksum"))
                                   for i in s["sets"][sid]["shots"]]


def mac_want(lang: str) -> list[tuple[str, str]]:
    paths = shots.expected_composed(lang, TMP, platform=MAC)
    return [(p.name, hashlib.md5(p.read_bytes()).hexdigest()) for p in paths]


def ios_snapshot() -> dict:
    s = FakeASC.store
    return {k: [(i, dict(s["shots"][i])) for i in v["shots"]] for k, v in s["sets"].items()
            if v["type"] == "APP_IPHONE_67"}


shots.REPO = TMP
pusher.ShotsASC = FakeASC
try:
    # M1. a Mac dry run reads MAC_OS only and writes nothing
    fresh_mac_repo()
    fresh_mac()
    code, out = run("--platform", "MAC_OS", "--version", "1.54.0")
    check("Mac dry run: exits 0, writes nothing, lists the 2880x1800 panels and every locale",
          code == 0 and not writes() and "APP_DESKTOP" in out and "=== MAC_OS 1.54.0" in out
          and "01_overview_2880x1800.png" in out and out.count("(replace)") == len(ALL)
          and "(drawn by 1.54.0)" in out
          and out.count("no APP_DESKTOP set yet: --apply creates one") == 5
          and "8 live + 6 new would exceed 10: --apply deletes 4 of the live ones first" in out
          and "9 live + 6 new would exceed 10: --apply deletes 5 of the live ones first" in out, out)

    # M2. the real apply
    fresh_mac_repo()
    fresh_mac()
    ios_before = ios_snapshot()
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0")
    check("Mac apply exits 0 and verifies", code == 0 and "APPLY OK" in out and "APPLY MAC_OS 1.54.0" in out, out)
    bad = [loc for loc in ALL if mac_files(loc) != mac_want(shots.SHOT_SOURCES[loc])]
    check("every locale's APP_DESKTOP set holds exactly the six new Mac panels, in order, with their md5",
          not bad, str({loc: mac_files(loc) for loc in bad})[:1500])
    check("es-ES and es-MX got the same Spanish Mac files", mac_files("es-ES") == mac_files("es-MX"))
    created = [p for m, p in FakeASC.log if (m, p) == ("POST", "/appScreenshotSets")]
    check("an APP_DESKTOP set was created for each of the five locales without one",
          len(created) == 5 and all(v["type"] in ("APP_DESKTOP", "APP_IPHONE_67")
                                    for v in FakeASC.store["sets"].values()), str(FakeASC.log)[:800])
    check("nothing iOS was touched: the iPhone sets of the version in review are exactly as they were",
          ios_snapshot() == ios_before
          and not any("iset" in p or "il-" in p for _, p in FakeASC.log), str(FakeASC.log)[:800])

    # M3. make room: 8 live + 6 new deletes exactly 4 first; 9 + 6 deletes 5
    for loc, n_old, n_first in (("en-US", 8, 4), ("zh-Hans", 9, 5)):
        fresh_mac(old={loc: n_old})
        code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0", "--locale", loc)
        first_post = next((i for i, (m, p) in enumerate(FakeASC.log) if m == "POST" and p == "/appScreenshots"),
                          10**6)
        dels = [i for i, (m, p) in enumerate(FakeASC.log) if m == "DELETE"]
        check(f"{loc}: {n_old} live + 6 new deletes exactly {n_first} first and {n_old - n_first} after",
              code == 0 and len([i for i in dels if i < first_post]) == n_first
              and len([i for i in dels if i > first_post]) == n_old - n_first
              and mac_files(loc) == mac_want(shots.SHOT_SOURCES[loc]), out)

    # M4. a panel the store fails, after making room: only the new ones are removed
    fresh_mac(old={"en-US": 8})
    FakeASC.fail_processing = {"05_alerts_2880x1800.png"}
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0", "--locale", "en-US")
    left = mac_files("en-US")
    check("a failure after making room removes only the new panels, and says 4 of the 8 were already gone",
          code == 1 and len(left) == 4 and all(n.startswith("MAC_OS_APP_DESKTOP_") for n, _ in left)
          and "4 of the live set's 8 were already deleted to make room" in out, out)
    check("... and the room was made from the carousel's end: its first four are the ones left",
          [n for n, _ in left] == [f"MAC_OS_APP_DESKTOP_{n:02d}.png" for n in range(4)], str(left))
    fresh_mac(old={"ja": 3})
    FakeASC.fail_processing = {"05_alerts_2880x1800.png"}
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0", "--locale", "ja")
    check("a failure with room to spare leaves the old Mac set exactly as it was",
          code == 1 and mac_files("ja") == [(f"MAC_OS_APP_DESKTOP_{n:02d}.png", "0" * 32) for n in range(3)]
          and "the live set is untouched" in out, out)

    # M5. panels drawn by another version: refused before the store is contacted
    fresh_mac_repo(version="1.53.0")
    fresh_mac()
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0")
    check("Mac panels drawn by 1.53.0 are refused for 1.54.0, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "drawn by 1.53.0" in out, out)
    fresh_mac_repo(version="1.53.0")
    fresh_mac()
    code, out = run("--platform", "MAC_OS")
    check("... and a dry run without --version checks them against the version it found",
          code == 1 and not writes() and "drawn by 1.53.0" in out, out)

    # M6. a Mac panel of the wrong size, or an iPhone-sized one: refused before contact
    fresh_mac_repo(width=2560)
    fresh_mac()
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0")
    check("a Mac panel of the wrong size is refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "2560x1800" in out, out)

    # M7. the macOS version waiting for review: refused, with the macOS hint
    fresh_mac_repo()
    fresh_mac(mac_state="WAITING_FOR_REVIEW")
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0")
    check("Mac apply while macOS waits for review is refused with zero writes and the macOS hint",
          code == 1 and not writes() and "Withdraw the macOS submission" in out, out)

    # M8. the read-back sees another file's checksum: MISMATCH, exit 1
    fresh_mac_repo()
    fresh_mac(old={"ja": 2})
    FakeASC.wrong_checksum = {"03_usage_history_2880x1800.png"}
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0", "--locale", "ja")
    check("a Mac read-back that does not match what was sent fails, saying MISMATCH",
          code == 1 and "MISMATCH after upload" in out and "APPLY OK" not in out, out)

    # M9. what the panels were composed from: render.json beside the raws must
    # still be the one compose.json records, and a clean store render
    def with_raws(lang: str, **over) -> None:
        raw = shots.raw_dir(lang, TMP, platform=MAC)
        for name in shots.raw_names(MAC):
            h = 2586 if name.endswith(".panel.png") else 3 * (551 if name == "04_cost.png" else 580)
            shots.write_png(raw / name, 1560 if name.endswith(".panel.png") else 1140, h)
            (raw / name).write_bytes((raw / name).read_bytes() + name.encode())
        renders, rows = [], []
        for st in shots.stems(MAC):
            h = 551 if st == "04_cost" else 580
            renders.append({"file": f"{st}.png", "width": 380, "height": h, "pixelWidth": 1140,
                            "pixelHeight": 3 * h, "suspectBlank": False})
            row = {"id": st, "file": f"{st}.png", "md5": shots.md5_of(raw / f"{st}.png"),
                   "page": "lastAligned" if st == "04_cost" else "first"}
            if st == "04_cost":
                row["popoverHeight"] = 551
            if (raw / f"{st}.panel.png").exists():
                renders.append({"file": f"{st}.panel.png", "width": 520, "height": 862,
                                "pixelWidth": 1560, "pixelHeight": 2586, "suspectBlank": False})
                row.update(panelFile=f"{st}.panel.png", panelMD5=shots.md5_of(raw / f"{st}.panel.png"))
            rows.append(row)
        variant = {"devidBuild": False, "debugBuild": True, "sandboxed": False, "channel": "qa",
                   "remoteControlAvailable": False, "popoverWidth": 380, "popoverHeight": 580,
                   "panelWidth": 520, "panelSettled": True, "localScanDays": 250,
                   "localScanProviders": ["Claude", "Codex"], "localScanMessages": 15659,
                   "scrollerStyle": "overlay", "panelBackdropLuminance": 0.12}
        variant.update(over)
        (raw / shots.RENDER_MANIFEST).write_text(json.dumps({
            "set": "store", "language": lang, "localeOverride": lang, "resolvedLocalization": lang,
            "displayLocale": f"{lang}_{shots.MAC_REGIONS[lang]}", "localizationActive": True,
            "scale": 3, "windowBackingScale": 3, "warnings": [], "blockedRequests": [],
            "renders": renders, "shots": rows, "app": {"version": "1.54.0", "build": "107"},
            "variant": variant}))
        d = shots.composed_dir(lang, TMP, platform=MAC)
        shots.write_manifest(d, lang, {
            "app": {"version": "1.54.0", "build": "107"},
            "captures": {n: shots.md5_of(raw / n) for n in shots.raw_names(MAC)},
            "render": shots.md5_of(raw / shots.RENDER_MANIFEST)}, platform=MAC)

    fresh_mac_repo()
    with_raws("ja")
    fresh_mac(old={})
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0", "--locale", "ja")
    check("Mac panels whose raws and clean render.json are the recorded ones are pushed",
          code == 0 and "APPLY OK" in out and mac_files("ja") == mac_want("ja"), out)
    fresh_mac_repo()
    with_raws("ja", devidBuild=True)
    fresh_mac()
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0", "--locale", "ja")
    check("negative control: raws drawn by a Developer ID build are refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "DEVID_BUILD" in out, out)
    fresh_mac_repo()
    with_raws("ja")
    f = shots.raw_dir("ja", TMP, platform=MAC) / shots.RENDER_MANIFEST
    f.write_text(f.read_text().replace('"devidBuild": false', '"devidBuild": true'))
    fresh_mac()
    code, out = run("--apply", "--platform", "MAC_OS", "--version", "1.54.0", "--locale", "ja")
    check("negative control: a render.json edited after the panels were composed is refused",
          code == 1 and FakeASC.constructed == 0 and "not the one compose.json records" in out, out)
    for p_ in TMP.rglob(shots.RENDER_MANIFEST):
        p_.unlink()
finally:
    shots.REPO = REAL_REPO
    pusher.ShotsASC = RealShotsASC

# ── the iPad set: --platform IOS --display-type APP_IPAD_PRO_3GEN_129 ────────
# The live store as the 1.55 prep found it: a 13" iPad set of five panels on
# en-US and zh-Hans only, beside every locale's iPhone set on the same IOS
# version. The iPad panels must go to the iPad sets alone.
IPAD = shots.IPAD
IPAD_W, IPAD_H = IPAD.canvas
IPAD_TYPE = "APP_IPAD_PRO_3GEN_129"
IPAD_ARGS = ("--platform", "IOS", "--display-type", IPAD_TYPE)


def make_ipad_panels(lang: str, *, width: int = IPAD_W, height: int = IPAD_H,
                     manifest: bool = True) -> None:
    for i, p in enumerate(shots.expected_composed(lang, TMP, platform=IPAD)):
        shots.write_png(p, width, height)
        p.write_bytes(p.read_bytes() + b"ipad" + lang.encode() + bytes([i]))
    if manifest:
        shots.write_manifest(shots.composed_dir(lang, TMP, platform=IPAD), lang, platform=IPAD)


def fresh_ipad_repo(**kw) -> None:
    fresh_repo()
    for lang in shots.LANGS:
        make_ipad_panels(lang, **(kw if lang == "ja" else {}))


def fresh_ipad(**kw) -> None:
    fresh(**kw)
    FakeASC.store = base_store(ipad_locales={"en-US", "zh-Hans"}, ipad_old=5,
                               **{k: v for k, v in kw.items() if k == "state"})


def ipad_files(loc: str) -> list[tuple[str, str]]:
    s = FakeASC.store
    sid = next((k for k, v in s["sets"].items()
                if v["type"] == IPAD_TYPE and s["vlocs"]["v-new"][v["loc"]]["locale"] == loc), None)
    return [] if sid is None else [(s["shots"][i]["fileName"], s["shots"][i].get("sourceFileChecksum"))
                                   for i in s["sets"][sid]["shots"]]


def ipad_want(lang: str) -> list[tuple[str, str]]:
    return [(p.name, hashlib.md5(p.read_bytes()).hexdigest())
            for p in shots.expected_composed(lang, TMP, platform=IPAD)]


def iphone_sets() -> dict:
    s = FakeASC.store
    return {k: [(i, dict(s["shots"][i])) for i in v["shots"]] for k, v in s["sets"].items()
            if v["type"] == "APP_IPHONE_67"}


shots.REPO = TMP
pusher.ShotsASC = FakeASC
try:
    # I1. a dry run names the iPad set, writes nothing
    fresh_ipad_repo()
    fresh_ipad()
    code, out = run("--display-type", IPAD_TYPE, "--version", "1.54.0")
    check("iPad dry run: exits 0, writes nothing, lists the 2064x2752 panels, and would create five sets",
          code == 0 and not writes() and "=== IOS 1.54.0" in out
          and "local panels (iPad, APP_IPAD_PRO_3GEN_129, 2064x2752)" in out
          and "01_overview_2064x2752.png" in out and out.count("(replace)") == len(ALL)
          and out.count(f"no {IPAD_TYPE} set yet: --apply creates one") == 5
          and "untouched: APP_IPHONE_67" in out, out)

    # I2. the real apply: only the iPad sets change
    fresh_ipad_repo()
    fresh_ipad()
    before = iphone_sets()
    code, out = run("--apply", *IPAD_ARGS, "--version", "1.54.0")
    check("iPad apply exits 0 and verifies", code == 0 and "APPLY OK" in out, out)
    bad = [loc for loc in ALL if ipad_files(loc) != ipad_want(shots.SHOT_SOURCES[loc])]
    check("every locale's iPad set holds exactly the five new iPad panels, in order, with their md5",
          not bad, str({loc: ipad_files(loc) for loc in bad})[:1500])
    check("es-ES and es-MX got the same Spanish iPad files", ipad_files("es-ES") == ipad_files("es-MX"))
    created = [p for m, p in FakeASC.log if (m, p) == ("POST", "/appScreenshotSets")]
    check("an iPad set was created for each of the five locales without one",
          len(created) == 5 and sum(1 for v in FakeASC.store["sets"].values() if v["type"] == IPAD_TYPE)
          == len(ALL), str(FakeASC.log)[:800])
    check("the iPhone sets beside them are exactly as they were, and no write named one",
          iphone_sets() == before
          and not any(any(f"/appScreenshotSets/set-{loc}/" in p for loc in ALL) or "old-" in p
                      for _, p in FakeASC.log),
          str(FakeASC.log)[:800])

    # I3. idempotent
    FakeASC.log = []
    code, out = run("--apply", *IPAD_ARGS, "--version", "1.54.0")
    check("a second iPad apply writes nothing", code == 0 and not writes()
          and out.count("nothing to do") == len(ALL), out)

    # I4. iPhone captures dressed as iPad panels, or no compose.json: refused before contact
    fresh_ipad_repo(width=1290, height=2796)
    fresh_ipad()
    code, out = run("--apply", *IPAD_ARGS, "--version", "1.54.0")
    check("iPhone-sized panels in the iPad set are refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "1290x2796, expected 2064x2752" in out, out)
    fresh_ipad_repo(manifest=False)
    fresh_ipad()
    code, out = run("--apply", *IPAD_ARGS, "--version", "1.54.0")
    check("an iPad set no clean compose run wrote is refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "compose.json is missing" in out, out)
    fresh_ipad_repo()
    ko_ipad = shots.composed_dir("ko", TMP, platform=IPAD)
    for p_ in ko_ipad.glob("*.png"):
        p_.unlink()
    (ko_ipad / shots.MANIFEST).unlink()
    ko_ipad.rmdir()
    fresh_ipad()
    code, out = run("--apply", *IPAD_ARGS, "--version", "1.54.0")
    check("a language without its iPad set is refused, store never contacted (the iPhone set is not a stand-in)",
          code == 1 and FakeASC.constructed == 0 and "ipad-composed/ko/ does not exist" in out, out)

    # I5. the wrong platform, no platform, a version in review
    fresh_ipad_repo()
    fresh_ipad()
    code, out = run("--apply", "--platform", "MAC_OS", "--display-type", IPAD_TYPE, "--version", "1.54.0")
    check("the iPad set with --platform MAC_OS is refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "belongs to the IOS version" in out, out)
    code, out = run("--apply", "--platform", "IOS", "--display-type", "APP_DESKTOP", "--version", "1.54.0")
    check("... and the Mac set with --platform IOS", code == 1 and FakeASC.constructed == 0
          and "belongs to the MAC_OS version" in out, out)
    code, out = run("--apply", "--display-type", IPAD_TYPE, "--version", "1.54.0")
    check("an iPad write without --platform is refused, store never contacted",
          code == 1 and FakeASC.constructed == 0 and "--platform" in out, out)
    fresh_ipad(state="WAITING_FOR_REVIEW")
    code, out = run("--apply", *IPAD_ARGS, "--version", "1.54.0")
    check("an iPad write while iOS waits for review is refused with zero writes and the iOS hint",
          code == 1 and not writes() and "Withdraw the iOS submission" in out, out)

    # I6. a panel the store fails: the old iPad set is left as it was
    fresh_ipad()
    FakeASC.fail_processing = {"04_sessions_2064x2752.png"}
    old_en = ipad_files("en-US")
    code, out = run("--apply", *IPAD_ARGS, "--version", "1.54.0", "--locale", "en-US")
    check("an iPad panel the store fails: the new ones are removed, the five old ones intact",
          code == 1 and ipad_files("en-US") == old_en and len(old_en) == 5
          and "the live set is untouched" in out, out)

    # I7. --locale
    fresh_ipad()
    code, out = run("--apply", *IPAD_ARGS, "--version", "1.54.0", "--locale", "zh-Hans")
    touched = {p for m, p in FakeASC.log if m == "DELETE"}
    check("--locale zh-Hans replaces only zh-Hans's iPad set",
          code == 0 and ipad_files("zh-Hans") == ipad_want("zh-Hans")
          and touched == {f"/appScreenshots/ipad-zh-Hans-{n}" for n in range(5)}, str(FakeASC.log)[:600])
finally:
    shots.REPO = REAL_REPO
    pusher.ShotsASC = RealShotsASC

print(f"test_asc_push_screenshots: {passed} passed, {failed} failed.")
sys.exit(1 if failed else 0)

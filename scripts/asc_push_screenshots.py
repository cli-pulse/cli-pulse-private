#!/usr/bin/env python3
"""Push the composed iPhone or Mac screenshots to App Store Connect, per locale.

The sibling of scripts/asc_push_listing.py, which pushes the listing text: same
key, same client, same editability rule. Which files go to which locale is
scripts/appstore_screenshots.py (en-US <- en, es-ES and es-MX <- es, ...).

Two platforms, one per run: --platform IOS (the default of a dry run) pushes
the iPhone panels to the iOS version's APP_IPHONE_67 sets; --platform MAC_OS
pushes the Mac panels (screenshots/macos-composed/) to the macOS version's
APP_DESKTOP sets. A write must name its platform.

DEFAULT IS A DRY RUN. It validates every local panel, GETs what each locale's
set holds now, and prints per locale what would be replaced, with the size and
md5 of every file on both sides. Nothing is written.

    python3 scripts/asc_push_screenshots.py                     # iPhone, the version being prepared
    python3 scripts/asc_push_screenshots.py --version 1.54.0 --locale ja,ko
    python3 scripts/asc_push_screenshots.py --platform MAC_OS --version 1.54.0

WRITING needs --apply, --platform and --version:

    python3 scripts/asc_push_screenshots.py --apply --platform IOS --version 1.54.0
    python3 scripts/asc_push_screenshots.py --apply --platform MAC_OS --version 1.54.0

and then, before the first write, it:
  * refuses unless every selected locale's panels are all there and uploadable:
    the platform's canvas (1290x2796 iPhone, 2880x1800 Mac), 8-bit RGB, no
    alpha, at most 10 MB. App Store Connect rejects an alpha channel only after
    the upload, by which time a script that deleted first has left the listing
    without screenshots;
  * for the Mac, refuses unless the panels were composed from renders of this
    very version: each set's compose.json records the app version that drew
    them, and the popover's footer shows it ("CLI Pulse v1.54.0");
  * refuses unless that platform's version is editable (PREPARE_FOR_SUBMISSION,
    DEVELOPER_REJECTED, REJECTED, METADATA_REJECTED). WAITING_FOR_REVIEW is not:
    App Store Connect refuses screenshot writes (409) while a version waits for
    review, and only the affected platform's submission needs withdrawing;
  * refuses unless every selected locale already has a localization on that
    version (screenshots hang off it; asc_push_listing.py creates it). A
    locale with no set of the platform's display type yet gets one.

Then, one locale at a time:
  * uploads the new panels first (reserve, PUT the parts App Store Connect
    names, commit with the file's md5) and waits until every one is COMPLETE;
  * only then deletes the old ones, and sets the carousel order;
  * reads the set back and fails unless it holds exactly the new panels, in
    order, each COMPLETE with the md5 and size that were sent. App Store
    Connect reports a panel COMPLETE before it fills in its checksum (seconds
    to a minute later), so the read-back is repeated, for at most POLL_TIMEOUT,
    until every screenshot has one.
If the new ones cannot all be uploaded, it deletes what it added and leaves the
old set as it was, whatever stopped it: a refused write, a panel the store
failed to process, or a read that ended the run (a 5xx, a lost connection,
Ctrl-C). It says which screenshots it could not delete, if any. The token is
minted again before it is 15 minutes old and on a 401 (asc_push_listing.py).
The one exception is a set that would exceed App Store Connect's 10
screenshots with both present: then only as many old ones as the new ones need
room for go first (the carousel's last ones), after the local checks above
passed, the rest after the new ones are COMPLETE, and the run says so.

A rerun after a run that stopped halfway starts from what the set holds:
uploads that never finished are deleted first (the store shows none of them),
and panels already uploaded with the same name and md5 are reused rather than
counted against the limit (plan_set). A COMPLETE screenshot with a panel's
name and size whose checksum is not filled in yet is most likely that panel,
uploaded by the run just before: the rerun waits for its checksum and then
decides, rather than replacing it.

It touches the platform's one display type (APP_IPHONE_67 or APP_DESKTOP) on
that platform's version only. Every other set (iPad, Apple Watch, the other
platform) is listed and left alone, as is every locale not selected or not in
the repo.

Exit: 0 = dry run clean / apply verified. 1 = invalid panels, refused, or a
write that failed or did not stick. 2 = could not reach App Store Connect.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
import time
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import appstore_screenshots as shots  # noqa: E402
import asc_push_listing as pusher  # noqa: E402

DISPLAY_TYPE = shots.DISPLAY_TYPE   # the iPhone's; a run uses its platform's
MAX_PER_SET = 10
POLL_SECONDS = 5
POLL_TIMEOUT = 600
SHOT_FIELDS = "fileName,fileSize,sourceFileChecksum,assetDeliveryState"

die = pusher.die


class ShotsASC(pusher.ASC):
    """The listing pusher's client, plus the two calls screenshots need."""

    def delete(self, path: str) -> bool:
        r = self._send("DELETE", path)
        if r is None or r.status_code not in (200, 204):
            print(f"    DELETE {path} -> {getattr(r, 'status_code', 'no response')}")
            return False
        return True

    def upload_part(self, op: dict, chunk: bytes) -> bool:
        """PUT one part to the URL App Store Connect handed out. Only the
        headers it named are sent: the bearer token stays with the API."""
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        try:
            r = self._requests.request(op.get("method", "PUT"), op["url"], headers=headers,
                                       data=chunk, timeout=pusher._TIMEOUT)
        except (self._requests.Timeout, self._requests.ConnectionError) as exc:
            print(f"    upload part at offset {op.get('offset')}: {type(exc).__name__}")
            return False
        if r.status_code >= 300:
            print(f"    upload part at offset {op.get('offset')} -> {r.status_code}")
            return False
        return True


@dataclass
class Panel:
    path: Path
    size: int
    md5: str

    @property
    def name(self) -> str:
        return self.path.name


def local_panels(lang: str, platform: shots.Platform = shots.IPHONE) -> tuple[list[Panel], list[str]]:
    problems = shots.set_problems(lang, platform=platform)
    panels = []
    for p in shots.expected_composed(lang, platform=platform):
        if p.is_file():
            data = p.read_bytes()
            panels.append(Panel(p, len(data), hashlib.md5(data).hexdigest()))
    return panels, problems


def parse_locales(raw: list[str] | None) -> list[str]:
    return pusher.parse_locales(raw)


def state_of(row: dict) -> str:
    return ((row.get("attributes") or {}).get("assetDeliveryState") or {}).get("state") or "UNKNOWN"


def set_rows(asc, set_id: str) -> list[dict]:
    return asc.get(f"/appScreenshotSets/{set_id}/appScreenshots", limit=50,
                   **{"fields[appScreenshots]": SHOT_FIELDS})["data"]


def checksum(row: dict) -> str | None:
    return (row.get("attributes") or {}).get("sourceFileChecksum")


def poll_set(asc, set_id: str, waiting) -> tuple[list[dict], list[dict]]:
    """Read the set until no row is waiting(row), for at most POLL_TIMEOUT
    (as wait_complete): (the rows, those still waiting)."""
    deadline = time.monotonic() + POLL_TIMEOUT
    while True:
        rows = set_rows(asc, set_id)
        late = [r for r in rows if waiting(r)]
        if not late or time.monotonic() > deadline:
            return rows, late
        time.sleep(POLL_SECONDS)


def matches(live: list[dict], panels: list[Panel]) -> bool:
    if len(live) != len(panels):
        return False
    for row, panel in zip(live, panels):
        a = row.get("attributes") or {}
        if ((a.get("fileName"), a.get("fileSize"), a.get("sourceFileChecksum"))
                != (panel.name, panel.size, panel.md5)):
            return False
        if state_of(row) != "COMPLETE":
            return False
    return True


# ── one locale's upload ──────────────────────────────────────────────────────

def upload(asc, set_id: str, panel: Panel) -> str | None:
    """Reserve, PUT, commit. The new screenshot's id, or None. A reservation
    that does not end committed is deleted again, whatever stopped it."""
    res = asc.write("POST", "/appScreenshots", {"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": panel.name, "fileSize": panel.size},
        "relationships": {"appScreenshotSet": {"data": {
            "type": "appScreenshotSets", "id": set_id}}}}})
    if not res or "data" not in res:
        print(f"    reserve {panel.name}: FAILED")
        return None
    shot_id = res["data"]["id"]
    committed = None
    try:
        ops = (res["data"].get("attributes") or {}).get("uploadOperations") or []
        if not ops:
            print(f"    reserve {panel.name}: no upload operations returned")
            return None
        data = panel.path.read_bytes()
        for op in ops:
            offset, length = int(op["offset"]), int(op["length"])
            if not asc.upload_part(op, data[offset:offset + length]):
                return None
        committed = asc.write("PATCH", f"/appScreenshots/{shot_id}", {"data": {
            "type": "appScreenshots", "id": shot_id,
            "attributes": {"uploaded": True, "sourceFileChecksum": panel.md5}}})
        if committed is None:
            print(f"    commit {panel.name}: FAILED")
            return None
    finally:
        if committed is None and _discard(asc, [shot_id]):
            print(f"    could NOT delete the unfinished {panel.name} ({shot_id}); "
                  "a rerun deletes it before uploading")
    print(f"    uploaded {panel.name}  {panel.size} B  md5 {panel.md5}")
    return shot_id


def _discard(asc, ids: list[str]) -> list[str]:
    """Delete these screenshots; the ids that could NOT be deleted. Never
    raises: it runs while another failure is already being reported."""
    left = []
    for i in ids:
        try:
            ok = asc.delete(f"/appScreenshots/{i}")
        except BaseException as exc:   # noqa: BLE001 - a cleanup must not mask the cause
            print(f"    DELETE /appScreenshots/{i}: {type(exc).__name__}")
            ok = False
        if not ok:
            left.append(i)
    return left


def _rolled_back(asc, loc: str, new_ids: list[str], old_gone: int, old_total: int = 0) -> str:
    """Remove this run's uploads after a failure; say truthfully what the set
    now holds. `old_gone` is how many of the live set were deleted first."""
    left = _discard(asc, new_ids)
    if not old_gone:
        old = "the live set is untouched"
    elif old_gone >= old_total:
        old = "the live set was already deleted"
    else:
        old = f"{old_gone} of the live set's {old_total} were already deleted to make room"
    if not left:
        return f"removed the {len(new_ids)} added; {old}"
    return (f"could NOT remove {len(left)} of the {len(new_ids)} added ({', '.join(left)}); "
            f"they are still in the set. {old.capitalize()}. A rerun reuses the complete "
            "ones and deletes the rest before uploading")


def wait_complete(asc, ids: list[str]) -> bool:
    deadline = time.monotonic() + POLL_TIMEOUT
    pending = list(ids)
    while pending:
        still = []
        for i in pending:
            row = asc.get(f"/appScreenshots/{i}", **{"fields[appScreenshots]": SHOT_FIELDS})["data"]
            st = state_of(row)
            if st == "COMPLETE":
                continue
            if st == "FAILED":
                errors = ((row.get("attributes") or {}).get("assetDeliveryState") or {}).get("errors")
                print(f"    {row['attributes'].get('fileName')}: App Store Connect FAILED it: {errors}")
                return False
            still.append(i)
        pending = still
        if pending:
            if time.monotonic() > deadline:
                print(f"    {len(pending)} screenshot(s) not COMPLETE after {POLL_TIMEOUT}s")
                return False
            time.sleep(POLL_SECONDS)
    return True


def plan_set(live: list[dict], panels: list[Panel]
             ) -> tuple[list[str], dict[int, str], list[str], list[str]]:
    """What to do with the rows a set holds now, before anything is uploaded:
    (debris, reused, old, unsettled).

    debris     rows that are not COMPLETE: an earlier run's upload that never
               finished. The store shows none of them, so they go first.
    reused     panel index -> the id of a COMPLETE row with that panel's file
               name and md5: an earlier run already uploaded it. Not uploaded again.
    unsettled  COMPLETE rows with a panel's file name and size but no checksum
               yet. App Store Connect fills sourceFileChecksum in seconds to a
               minute after it reports COMPLETE, so this is most likely that
               panel, uploaded by the run just before. Neither reused nor old:
               replace_set waits for the checksum and plans again. (Treated as
               old, it was re-uploaded and deleted by every rerun: the ja
               05_alerts panel churned four times on 2026-09-28.)
    old        every other COMPLETE row: the set being replaced. Deleted only once
               the new panels are all COMPLETE (unless the set would overflow).
    So a run that stopped halfway (a lost connection, an expired token) leaves
    nothing the next run trips over: it neither exceeds the 10-per-set limit
    nor has to delete the live set first because of its own leftovers."""
    debris = [r["id"] for r in live if state_of(r) != "COMPLETE"]
    sizes = {(p.name, p.size) for p in panels}
    unsettled = [r["id"] for r in live
                 if state_of(r) == "COMPLETE" and not checksum(r)
                 and ((r.get("attributes") or {}).get("fileName"),
                      (r.get("attributes") or {}).get("fileSize")) in sizes]
    reused: dict[int, str] = {}
    taken: set[str] = set()
    for n, panel in enumerate(panels):
        for r in live:
            a = r.get("attributes") or {}
            if (r["id"] not in taken and state_of(r) == "COMPLETE"
                    and (a.get("fileName"), a.get("sourceFileChecksum")) == (panel.name, panel.md5)):
                reused[n] = r["id"]
                taken.add(r["id"])
                break
    old = [r["id"] for r in live
           if state_of(r) == "COMPLETE" and r["id"] not in taken and r["id"] not in unsettled]
    return debris, reused, old, unsettled


def describe(rows: list[dict]) -> str:
    return ", ".join(f"{(r.get('attributes') or {}).get('fileName')}[{state_of(r)}"
                     + ("" if checksum(r) else ", no checksum") + "]" for r in rows)


def replace_set(asc, loc: str, set_id: str, live: list[dict], panels: list[Panel]) -> bool:
    unsettled = plan_set(live, panels)[3]
    if unsettled:
        print(f"  [{loc}] {len(unsettled)} COMPLETE screenshot(s) with a panel's name and size "
              "but no checksum yet: waiting for App Store Connect to fill it in before "
              "deciding what to keep")
        live, late = poll_set(asc, set_id, lambda r: r["id"] in unsettled and not checksum(r))
        if late:
            print(f"  [{loc}] still no checksum after {POLL_TIMEOUT}s: {describe(late)}. "
                  "Nothing in this set was changed; run again later")
            return False
        if matches(live, panels):
            print(f"  [{loc}] OK: the set already holds the {len(panels)} panels, in order; "
                  "nothing to do")
            return True
    debris, reused, old_ids, still = plan_set(live, panels)
    # Rows the wait above settled are now reused or old. One that still has no
    # checksum (it appeared while waiting) takes a place in the set like an old
    # one and goes with them, so the room below counts it.
    old_ids += still
    if debris:
        print(f"  [{loc}] {len(debris)} unfinished upload(s) from an earlier run: deleting them first")
        left = _discard(asc, debris)
        if left:
            print(f"  [{loc}] could not delete {', '.join(left)}; nothing else was changed")
            return False
    if reused:
        print(f"  [{loc}] {len(reused)} panel(s) already uploaded by an earlier run: reusing them")
    to_upload = [n for n in range(len(panels)) if n not in reused]
    # Room for the new panels: only the overflow goes before the upload (the
    # carousel's last ones), the rest once the new panels are COMPLETE.
    overflow = len(old_ids) + len(reused) + len(to_upload) - MAX_PER_SET
    first = old_ids[len(old_ids) - overflow:] if overflow > 0 else []
    old_ids = [i for i in old_ids if i not in first]
    delete_first = len(first)
    old_total = len(first) + len(old_ids)
    if first:
        print(f"  [{loc}] {old_total} live + {len(to_upload)} new would exceed {MAX_PER_SET}: "
              f"deleting {len(first)} of the live ones first to make room (the local panels "
              "already passed every check); the other "
              f"{len(old_ids)} go once the new ones are COMPLETE")
        left = _discard(asc, first)
        if left:
            print(f"  [{loc}] could not delete {', '.join(left)}; nothing was uploaded")
            return False

    # From the first upload until every new panel is COMPLETE, any failure,
    # including one that ends the process (a GET that dies, Ctrl-C), removes
    # what this run added before it is reported.
    new_ids: list[str] = []
    try:
        for n in to_upload:
            sid = upload(asc, set_id, panels[n])
            if sid is None:
                print(f"  [{loc}] upload failed; "
                      + _rolled_back(asc, loc, new_ids, delete_first, old_total))
                return False
            new_ids.append(sid)
        if not wait_complete(asc, new_ids):
            print(f"  [{loc}] processing failed; "
                  + _rolled_back(asc, loc, new_ids, delete_first, old_total))
            return False
    except BaseException as exc:
        print(f"  [{loc}] stopped by {type(exc).__name__} while uploading; "
              + _rolled_back(asc, loc, new_ids, delete_first, old_total))
        raise

    by_index = dict(reused)
    by_index.update(zip(to_upload, new_ids))
    order_ids = [by_index[n] for n in range(len(panels))]
    if old_ids:
        left = _discard(asc, old_ids)
        if left:
            print(f"  [{loc}] could not delete {len(left)} old screenshot(s); the read-back decides")
    order = asc.write("PATCH", f"/appScreenshotSets/{set_id}/relationships/appScreenshots",
                      {"data": [{"type": "appScreenshots", "id": i} for i in order_ids]})
    if order is None:
        print(f"  [{loc}] setting the order FAILED")
    after, late = poll_set(asc, set_id, lambda r: not checksum(r))
    ok = [r["id"] for r in after] == order_ids and matches(after, panels)
    if not ok:
        if late:
            print(f"  [{loc}] {len(late)} screenshot(s) still without a checksum after "
                  f"{POLL_TIMEOUT}s")
        print(f"  [{loc}] MISMATCH after upload: the set holds {describe(after)}")
        return False
    print(f"  [{loc}] OK: {len(order_ids)} screenshot(s), in order, COMPLETE, checksums match")
    return True


# ── main ─────────────────────────────────────────────────────────────────────

def version_problems(plan_langs: dict[str, str], version: str | None,
                     platform: shots.Platform) -> list[str]:
    """The Mac panels show the version that drew them in the popover's footer,
    so they may go only to that version (compose.json records it). The iPhone
    panels carry no version."""
    if platform is not shots.MAC or not version:
        return []
    out = []
    for loc, lang in plan_langs.items():
        drawn = shots.composed_app_version(lang, platform=platform)
        if drawn != version:
            out.append(f"{loc}: the {lang} panels were drawn by {drawn or 'an unrecorded version'}, "
                       f"not {version} (the popover's footer says so); render and compose "
                       "them again for this version")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--platform", choices=sorted(shots.PLATFORMS),
                    help="IOS (iPhone panels, APP_IPHONE_67) or MAC_OS (Mac panels, APP_DESKTOP); "
                         "required with --apply, IOS for a dry run without it")
    ap.add_argument("--version", help="versionString, e.g. 1.54.0 (required with --apply)")
    ap.add_argument("--locale", action="append",
                    help="limit to these ASC locales (comma-separated or repeated)")
    ap.add_argument("--apply", action="store_true", help="WRITE to App Store Connect")
    args = ap.parse_args()

    if args.apply and not args.platform:
        die("--apply needs --platform IOS|MAC_OS. A write names exactly one platform.", 1)
    if args.apply and not args.version:
        die("--apply needs --version <X.Y.Z>. A write names exactly one version.", 1)
    plat = shots.PLATFORMS[args.platform or "IOS"]
    display_type = plat.display_type
    locales = parse_locales(args.locale)

    # 1. The local panels, before anything else.
    plan: dict[str, list[Panel]] = {}
    plan_langs: dict[str, str] = {}
    problems: list[str] = []
    print(f"local panels ({plat.name}, {display_type}, {plat.canvas[0]}x{plat.canvas[1]}):")
    for loc in locales:
        lang = shots.SHOT_SOURCES.get(loc, shots.FALLBACK)
        if lang is shots.FALLBACK:
            print(f"  [{loc}] no set of its own: App Store Connect shows it en-US's")
            continue
        panels, probs = local_panels(lang, plat)
        plan[loc] = panels
        plan_langs[loc] = lang
        where = shots.composed_dir(lang, platform=plat).relative_to(shots.REPO)
        drawn = shots.composed_app_version(lang, platform=plat) if plat is shots.MAC else None
        print(f"  [{loc}] <- {where}" + (f"  (drawn by {drawn})" if plat is shots.MAC else ""))
        for p in panels:
            print(f"      {p.name}  {p.size} B  md5 {p.md5}")
        for why in probs:
            print(f"      INVALID {why}")
            problems.append(f"{loc}: {why}")
    for why in version_problems(plan_langs, args.version, plat):
        print(f"  INVALID {why}")
        problems.append(why)
    if problems and args.apply:
        die(f"{len(problems)} problem(s) with the local panels; nothing was written or deleted.", 1)

    # 2. The store.
    asc = ShotsASC()
    ver = pusher.pick_version(asc, plat.asc_platform, args.version)
    if ver is None:
        die(f"{plat.asc_platform}: no version {args.version or ''} in App Store Connect", 1)
    vs = ver["attributes"]["versionString"]
    st = pusher.version_state(ver["attributes"])
    editable = st in pusher.EDITABLE_STATES
    if not args.version:
        for why in version_problems(plan_langs, vs, plat):
            print(f"  INVALID {why}")
            problems.append(why)
    print(f"\n=== {plat.asc_platform} {vs}  state={st} ({'editable' if editable else 'NOT editable'})")
    vlocs = pusher.version_locs(asc, ver["id"])

    todo: list[tuple[str, str | None, list[dict]]] = []
    missing_locs = []
    for loc, panels in plan.items():
        row = vlocs.get(loc)
        if row is None:
            print(f"  [{loc}] no localization on this version: push the listing first "
                  "(scripts/asc_push_listing.py)")
            missing_locs.append(loc)
            continue
        sets = asc.get(f"/appStoreVersionLocalizations/{row['id']}/appScreenshotSets",
                       limit=50)["data"]
        target = next((s for s in sets
                       if s["attributes"].get("screenshotDisplayType") == display_type), None)
        others = [s["attributes"].get("screenshotDisplayType") for s in sets if s is not target]
        live = set_rows(asc, target["id"]) if target else []
        same = matches(live, panels)
        unsettled = plan_set(live, panels)[3]
        print(f"  [{loc}] {display_type}: {len(live)} live -> {len(panels)} new"
              + ("  (same; nothing to do)" if same else "  (replace)")
              + (f"; {len(unsettled)} COMPLETE without a checksum yet, which --apply "
                 "waits for before deciding" if unsettled and not same else ""))
        if not same:
            for r in live:
                a = r.get("attributes") or {}
                print(f"      live  {a.get('fileName')}  {a.get('fileSize')} B  "
                      f"md5 {a.get('sourceFileChecksum')}  {state_of(r)}")
        if not same and target is None:
            print(f"      no {display_type} set yet: --apply creates one")
        if not same:
            # An unsettled row is counted as the panel it most likely is (reused).
            debris, reused, old_ids, _ = plan_set(live, panels)
            overflow = len(old_ids) + len(panels) - MAX_PER_SET
            if overflow > 0:
                print(f"      {len(old_ids)} live + {len(panels) - len(reused)} new would exceed "
                      f"{MAX_PER_SET}: --apply deletes {overflow} of the live ones first, the "
                      f"other {len(old_ids) - overflow} once the new ones are COMPLETE")
        if others:
            print(f"      untouched: {', '.join(sorted(o or '?' for o in others))}")
        if not same:
            todo.append((loc, target["id"] if target else None, live))

    if not args.apply:
        verdict = "INVALID local panels; --apply would refuse. " if problems else ""
        print(f"\nDRY RUN: {verdict}{len(todo)} locale(s) would be replaced. Nothing was written.")
        return 1 if problems else 0

    # 3. Apply: every precondition before the first write.
    if not editable:
        other = "Mac" if plat is shots.IPHONE else "iOS"
        mine = "iOS" if plat is shots.IPHONE else "macOS"
        hint = (f" Withdraw the {mine} submission first (the {other} one can stay in review)."
                if st == "WAITING_FOR_REVIEW" else "")
        die(f"{plat.asc_platform} {vs} is {st}; screenshots can only be written to "
            f"{sorted(pusher.EDITABLE_STATES)}.{hint} Nothing was written.", 1)
    if missing_locs:
        die(f"no localization for {', '.join(missing_locs)} on {plat.asc_platform} {vs}; push "
            "the listing text first. Nothing was written.", 1)

    print(f"\nAPPLY {plat.asc_platform} {vs}")
    failures = 0
    for loc, set_id, live in todo:
        if set_id is None:
            res = asc.write("POST", "/appScreenshotSets", {"data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display_type},
                "relationships": {"appStoreVersionLocalization": {"data": {
                    "type": "appStoreVersionLocalizations", "id": vlocs[loc]["id"]}}}}})
            if not res or "data" not in res:
                print(f"  [{loc}] creating the {display_type} set FAILED")
                failures += 1
                break
            set_id = res["data"]["id"]
        if not replace_set(asc, loc, set_id, live, plan[loc]):
            failures += 1
            break   # stop at the first locale that did not stick
    if failures:
        print("\nAPPLY INCOMPLETE: stopped at the locale above; the locales before it are done.")
        return 1
    print(f"\nAPPLY OK: {len(todo)} locale(s) replaced and verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

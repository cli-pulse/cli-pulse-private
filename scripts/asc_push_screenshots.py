#!/usr/bin/env python3
"""Push the composed iPhone screenshots to App Store Connect, per locale.

The sibling of scripts/asc_push_listing.py, which pushes the listing text: same
key, same client, same editability rule. Which files go to which locale is
scripts/appstore_screenshots.py (en-US <- en, es-ES and es-MX <- es, ...).

DEFAULT IS A DRY RUN. It validates every local panel, GETs what each locale's
iPhone set (APP_IPHONE_67) holds now, and prints per locale what would be
replaced, with the size and md5 of every file on both sides. Nothing is written.

    python3 scripts/asc_push_screenshots.py                     # the version being prepared
    python3 scripts/asc_push_screenshots.py --version 1.54.0 --locale ja,ko

WRITING needs --apply and --version:

    python3 scripts/asc_push_screenshots.py --apply --version 1.54.0

and then, before the first write, it:
  * refuses unless every selected locale's panels are all there and uploadable:
    1290x2796, 8-bit RGB, no alpha, at most 10 MB. App Store Connect rejects an
    alpha channel only after the upload, by which time a script that deleted
    first has left the listing without screenshots;
  * refuses unless that iOS version is editable (PREPARE_FOR_SUBMISSION,
    DEVELOPER_REJECTED, REJECTED, METADATA_REJECTED). WAITING_FOR_REVIEW is not:
    App Store Connect refuses screenshot writes (409) while a version waits for
    review, and only the iOS submission needs withdrawing, never the Mac one;
  * refuses unless every selected locale already has a localization on that
    version (screenshots hang off it; asc_push_listing.py creates it).

Then, one locale at a time:
  * uploads the new panels first (reserve, PUT the parts App Store Connect
    names, commit with the file's md5) and waits until every one is COMPLETE;
  * only then deletes the old ones, and sets the carousel order;
  * reads the set back and fails unless it holds exactly the new panels, in
    order, each COMPLETE with the md5 and size that were sent.
If the new ones cannot all be uploaded, it deletes what it added and leaves the
old set as it was. The one exception is a set that would exceed App Store
Connect's 10 screenshots with both present: then the old ones go first, after
the local checks above passed, and the run says so.

It touches the APP_IPHONE_67 set only. iPad, Apple Watch and Mac sets are listed
and left alone, as is every locale not selected or not in the repo.

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

DISPLAY_TYPE = shots.DISPLAY_TYPE
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


def local_panels(lang: str) -> tuple[list[Panel], list[str]]:
    problems = shots.set_problems(lang)
    panels = []
    for p in shots.expected_composed(lang):
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


def matches(live: list[dict], panels: list[Panel]) -> bool:
    if len(live) != len(panels):
        return False
    for row, panel in zip(live, panels):
        a = row.get("attributes") or {}
        if (a.get("fileName"), a.get("sourceFileChecksum")) != (panel.name, panel.md5):
            return False
        if state_of(row) != "COMPLETE":
            return False
    return True


# ── one locale's upload ──────────────────────────────────────────────────────

def upload(asc, set_id: str, panel: Panel) -> str | None:
    """Reserve, PUT, commit. The new screenshot's id, or None."""
    res = asc.write("POST", "/appScreenshots", {"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": panel.name, "fileSize": panel.size},
        "relationships": {"appScreenshotSet": {"data": {
            "type": "appScreenshotSets", "id": set_id}}}}})
    if not res or "data" not in res:
        print(f"    reserve {panel.name}: FAILED")
        return None
    shot_id = res["data"]["id"]
    ops = (res["data"].get("attributes") or {}).get("uploadOperations") or []
    if not ops:
        print(f"    reserve {panel.name}: no upload operations returned")
        _discard(asc, [shot_id])
        return None
    data = panel.path.read_bytes()
    for op in ops:
        offset, length = int(op["offset"]), int(op["length"])
        if not asc.upload_part(op, data[offset:offset + length]):
            _discard(asc, [shot_id])
            return None
    committed = asc.write("PATCH", f"/appScreenshots/{shot_id}", {"data": {
        "type": "appScreenshots", "id": shot_id,
        "attributes": {"uploaded": True, "sourceFileChecksum": panel.md5}}})
    if committed is None:
        print(f"    commit {panel.name}: FAILED")
        _discard(asc, [shot_id])
        return None
    print(f"    uploaded {panel.name}  {panel.size} B  md5 {panel.md5}")
    return shot_id


def _discard(asc, ids: list[str]) -> bool:
    ok = True
    for i in ids:
        ok = asc.delete(f"/appScreenshots/{i}") and ok
    return ok


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


def replace_set(asc, loc: str, set_id: str, old: list[dict], panels: list[Panel]) -> bool:
    old_ids = [r["id"] for r in old]
    delete_first = len(old_ids) + len(panels) > MAX_PER_SET
    if delete_first:
        print(f"  [{loc}] {len(old_ids)} live + {len(panels)} new would exceed {MAX_PER_SET}: "
              "deleting the live ones first (the local panels already passed every check)")
        if not _discard(asc, old_ids):
            return False
    new_ids: list[str] = []
    for panel in panels:
        sid = upload(asc, set_id, panel)
        if sid is None:
            print(f"  [{loc}] upload failed; removing the {len(new_ids)} added, "
                  + ("the live set was already gone" if delete_first else "the live set is untouched"))
            _discard(asc, new_ids)
            return False
        new_ids.append(sid)
    if not wait_complete(asc, new_ids):
        print(f"  [{loc}] processing failed; removing the new ones, "
              + ("the live set was already gone" if delete_first else "the live set is untouched"))
        _discard(asc, new_ids)
        return False
    if not delete_first and old_ids:
        if not _discard(asc, old_ids):
            print(f"  [{loc}] could not delete every old screenshot; the read-back decides")
    order = asc.write("PATCH", f"/appScreenshotSets/{set_id}/relationships/appScreenshots",
                      {"data": [{"type": "appScreenshots", "id": i} for i in new_ids]})
    if order is None:
        print(f"  [{loc}] setting the order FAILED")
    after = set_rows(asc, set_id)
    ok = [r["id"] for r in after] == new_ids and matches(after, panels)
    if not ok:
        print(f"  [{loc}] MISMATCH after upload: the set holds "
              + ", ".join(f"{(r.get('attributes') or {}).get('fileName')}[{state_of(r)}]" for r in after))
        return False
    print(f"  [{loc}] OK: {len(new_ids)} screenshot(s), in order, COMPLETE, checksums match")
    return True


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--version", help="iOS versionString, e.g. 1.54.0 (required with --apply)")
    ap.add_argument("--locale", action="append",
                    help="limit to these ASC locales (comma-separated or repeated)")
    ap.add_argument("--apply", action="store_true", help="WRITE to App Store Connect")
    args = ap.parse_args()

    if args.apply and not args.version:
        die("--apply needs --version <X.Y.Z>. A write names exactly one version.", 1)
    locales = parse_locales(args.locale)

    # 1. The local panels, before anything else.
    plan: dict[str, list[Panel]] = {}
    problems: list[str] = []
    print(f"local panels ({DISPLAY_TYPE}, {shots.CANVAS[0]}x{shots.CANVAS[1]}):")
    for loc in locales:
        lang = shots.SHOT_SOURCES.get(loc, shots.FALLBACK)
        if lang is shots.FALLBACK:
            print(f"  [{loc}] no set of its own: App Store Connect shows it en-US's")
            continue
        panels, probs = local_panels(lang)
        plan[loc] = panels
        print(f"  [{loc}] <- {shots.composed_dir(lang).relative_to(shots.REPO)}")
        for p in panels:
            print(f"      {p.name}  {p.size} B  md5 {p.md5}")
        for why in probs:
            print(f"      INVALID {why}")
            problems.append(f"{loc}: {why}")
    if problems and args.apply:
        die(f"{len(problems)} problem(s) with the local panels; nothing was written or deleted.", 1)

    # 2. The store.
    asc = ShotsASC()
    ver = pusher.pick_version(asc, "IOS", args.version)
    if ver is None:
        die(f"IOS: no version {args.version or ''} in App Store Connect", 1)
    vs = ver["attributes"]["versionString"]
    st = pusher.version_state(ver["attributes"])
    editable = st in pusher.EDITABLE_STATES
    print(f"\n=== IOS {vs}  state={st} ({'editable' if editable else 'NOT editable'})")
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
                       if s["attributes"].get("screenshotDisplayType") == DISPLAY_TYPE), None)
        others = [s["attributes"].get("screenshotDisplayType") for s in sets if s is not target]
        live = set_rows(asc, target["id"]) if target else []
        same = matches(live, panels)
        print(f"  [{loc}] {DISPLAY_TYPE}: {len(live)} live -> {len(panels)} new"
              + ("  (same; nothing to do)" if same else "  (replace)"))
        if not same:
            for r in live:
                a = r.get("attributes") or {}
                print(f"      live  {a.get('fileName')}  {a.get('fileSize')} B  "
                      f"md5 {a.get('sourceFileChecksum')}  {state_of(r)}")
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
        hint = (" Withdraw the iOS submission first (the Mac one can stay in review)."
                if st == "WAITING_FOR_REVIEW" else "")
        die(f"IOS {vs} is {st}; screenshots can only be written to "
            f"{sorted(pusher.EDITABLE_STATES)}.{hint} Nothing was written.", 1)
    if missing_locs:
        die(f"no localization for {', '.join(missing_locs)} on IOS {vs}; push the listing "
            "text first. Nothing was written.", 1)

    print(f"\nAPPLY IOS {vs}")
    failures = 0
    for loc, set_id, live in todo:
        if set_id is None:
            res = asc.write("POST", "/appScreenshotSets", {"data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": DISPLAY_TYPE},
                "relationships": {"appStoreVersionLocalization": {"data": {
                    "type": "appStoreVersionLocalizations", "id": vlocs[loc]["id"]}}}}})
            if not res or "data" not in res:
                print(f"  [{loc}] creating the {DISPLAY_TYPE} set FAILED")
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

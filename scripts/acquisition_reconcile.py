#!/usr/bin/env python3
"""Reconcile anonymous telemetry against EXTERNAL acquisition denominators.

WHY THIS EXISTS
---------------
`anonymous_installs` can only ever answer "of the people who reached the
disclosure card, how many reached a provider?". It cannot distinguish

    (a) tiny acquisition,
    (b) users abandoning before the menu is ever opened,
    (c) an instrument that barely reaches anyone,

and those three call for completely different work. Nothing in the telemetry
separates them; only outside numbers do. This script pulls the outside numbers.

It needs no new telemetry and no schema change. It is read-only everywhere:
GitHub release/traffic reads and App Store Connect GETs. It creates no ASC
resource -- the analytics report requests it reads must already exist (they do;
both ONGOING and ONE_TIME_SNAPSHOT were already provisioned).

THE TRAP THAT MATTERS MOST -- Apple suppresses small numbers
------------------------------------------------------------
App Store analytics apply a privacy threshold. Days below it are not reported
at all, and what survives is rounded. Observed floor in this app's data: no
value below 5 ever appears.

So "0 first-time Mac downloads" DOES NOT MEAN ZERO. It means "never once
crossed the threshold on any single day". That is still a strong statement over
a long window, but it is a different statement, and reporting it as a hard zero
would be exactly the confident-wrong-label failure this project keeps paying
for. Every printed Apple figure below carries the caveat inline.

GITHUB COUNTS HAVE THEIR OWN CONTAMINATION
------------------------------------------
`download_count` on a release asset includes CI, the owner's own testing, bots
and mirrors. Tap `clones` includes any `git clone`, and public repos are
crawled. Treat GitHub numbers as UPPER BOUNDS on real humans, never as counts.

USAGE
    python3 scripts/acquisition_reconcile.py                # all sources
    python3 scripts/acquisition_reconcile.py --skip-asc     # no Apple creds needed

PREREQ for the ASC half (same as asc_submit.py, per feedback_asc_icloud_key_tcc):
    ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
The .p8 is the only secret; KEY_ID / ISSUER / APP_ID are identifiers.
"""

from __future__ import annotations

import argparse
import collections
import csv
import gzip
import io
import json
import subprocess
import sys
import time

try:
    import jwt
    import requests
except ImportError:
    sys.exit("pip install pyjwt requests cryptography")

# Identifiers, not secrets -- same values as scripts/asc_submit.py.
KEY_ID = "DMMFP6XTXX"
ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
APP_ID = "6761163709"  # CLI Pulse
BASE = "https://api.appstoreconnect.apple.com/v1"

# The DMG lives in cli-pulse-distrib. The cask points at the `JasonYeYuhe/`
# owner segment, which redirects here -- see the pin comment in the cask; that
# prefix is load-bearing for already-installed copies and must not be "tidied".
DISTRIB_REPO = "cli-pulse/cli-pulse-distrib"
SITE_REPO = "cli-pulse/cli-pulse"
TAP_REPO = "cli-pulse/homebrew-tap"

APPLE_CAVEAT = "(Apple suppresses days below ~5; 0 means 'never crossed threshold', NOT zero)"
GH_CAVEAT = "(includes CI, owner testing, bots -- UPPER BOUND on humans)"


# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------

def gh(path: str):
    """gh api, failing loudly. A silent {} here would turn an auth failure into
    a confident 'zero downloads', which is the whole failure mode this file
    exists to avoid."""
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"gh api {path} failed: {r.stderr.strip()[:400]}")
    return json.loads(r.stdout)


def github_section(version: str | None) -> None:
    print("\n" + "=" * 74)
    print("GITHUB -- devid + brew denominators  " + GH_CAVEAT)
    print("=" * 74)

    releases = gh(f"repos/{DISTRIB_REPO}/releases?per_page=100")
    print(f"\n  {DISTRIB_REPO} release assets (most recent 6):")
    for rel in releases[:6]:
        assets = " ".join(
            f"{a['name'].replace('CLI-Pulse-', '')}={a['download_count']}"
            for a in rel["assets"]
            if a["name"].endswith(".dmg")
        )
        mark = "  <-- current" if version and rel["tag_name"].endswith(version) else ""
        print(f"    {rel['tag_name']:<16} {rel['published_at'][:10]}  {assets}{mark}")

    # The update feed. One active install checking daily produces ~1/day, so
    # this is the closest thing to a live DEVID/brew install count we have.
    try:
        latest = gh(f"repos/{DISTRIB_REPO}/releases/tags/latest")
        for a in latest["assets"]:
            print(f"\n  update feed {a['name']}: {a['download_count']} fetches "
                  f"since {a['updated_at'][:10]}")
            print("    ^ in-app updater checks on focus, 24h throttle => ~1/day per live install")
    except SystemExit:
        print("\n  update feed: no `latest` tag found")

    print(f"\n  traffic, last 14 days:")
    for repo, label in [(TAP_REPO, "tap"), (DISTRIB_REPO, "distrib"), (SITE_REPO, "site repo")]:
        v = gh(f"repos/{repo}/traffic/views")
        c = gh(f"repos/{repo}/traffic/clones")
        print(f"    {label:<10} views={v['count']:<5} uniq={v['uniques']:<5} "
              f"clones={c['count']:<5} uniq={c['uniques']}")
    print("    ^ `brew tap` does a clone; but so do crawlers. Unique clones is an"
          "\n      upper bound on machines that tapped, not a count of them.")


# ---------------------------------------------------------------------------
# App Store Connect
# ---------------------------------------------------------------------------

def asc_token() -> str:
    import os
    path = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
    if not os.path.exists(path):
        sys.exit(f"ASC key not found at {path} (NOT iCloud -- TCC-denied headless).")
    return jwt.encode(
        {"iss": ISSUER, "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
        open(path).read(),
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def asc_get(path: str, params: dict | None = None) -> dict:
    r = requests.get(BASE + path, headers={"Authorization": "Bearer " + asc_token()},
                     params=params, timeout=60)
    if r.status_code >= 300:
        sys.exit(f"ASC GET {path} failed {r.status_code}: {r.text[:400]}")
    return r.json()


def fetch_download_rows(request_id: str) -> list[dict]:
    """All 'App Downloads Detailed' rows under one analytics report request."""
    reports = asc_get(f"/analyticsReportRequests/{request_id}/reports",
                      {"limit": 200, "filter[name]": "App Downloads Detailed"})
    rows: list[dict] = []
    for rep in reports.get("data", []):
        inst = asc_get(f"/analyticsReports/{rep['id']}/instances",
                       {"limit": 200, "filter[granularity]": "DAILY"})
        for i in inst.get("data", []):
            segs = asc_get(f"/analyticsReportInstances/{i['id']}/segments", {"limit": 50})
            for s in segs.get("data", []):
                raw = requests.get(s["attributes"]["url"], timeout=180).content
                try:
                    text = gzip.decompress(raw).decode("utf-8")
                except OSError:
                    text = raw.decode("utf-8")
                rows += list(csv.DictReader(io.StringIO(text), delimiter="\t"))
    # Instances overlap and redeliver rows; dedupe on the whole record.
    seen, uniq = set(), []
    for r in rows:
        k = tuple(sorted(r.items()))
        if k not in seen:
            seen.add(k)
            uniq.append(r)
    return uniq


def asc_section() -> None:
    print("\n" + "=" * 74)
    print("APP STORE CONNECT -- mas + ios denominators  " + APPLE_CAVEAT)
    print("=" * 74)

    reqs = asc_get(f"/apps/{APP_ID}/analyticsReportRequests", {"limit": 20})
    by_type = {d["attributes"]["accessType"]: d["id"] for d in reqs.get("data", [])}
    if not by_type:
        sys.exit("No analytics report requests exist for this app. One must be created\n"
                 "in ASC first -- this script deliberately does not create one.")
    for t, rid in by_type.items():
        stopped = next(d["attributes"]["stoppedDueToInactivity"]
                       for d in reqs["data"] if d["id"] == rid)
        flag = "  *** STOPPED DUE TO INACTIVITY ***" if stopped else ""
        print(f"  request {t:<20} {rid}{flag}")

    rows: list[dict] = []
    for rid in by_type.values():
        rows += fetch_download_rows(rid)
    seen, uniq = set(), []
    for r in rows:
        k = tuple(sorted(r.items()))
        if k not in seen:
            seen.add(k)
            uniq.append(r)

    if not uniq:
        print("\n  NO ROWS. That is not 'no downloads' -- check the report requests above\n"
              "  are live, then check instance coverage. An empty result here is an\n"
              "  empty conclusion, not a finding.")
        return

    def count(r: dict) -> int:
        try:
            return int(r["Counts"])
        except (ValueError, KeyError):
            return 0

    dates = sorted(r["Date"] for r in uniq)
    print(f"\n  {len(uniq)} unique rows, event dates {dates[0]} .. {dates[-1]}")

    print("\n  Device x Download Type " + APPLE_CAVEAT)
    agg: dict = collections.defaultdict(int)
    for r in uniq:
        agg[(r["Device"], r["Download Type"])] += count(r)
    for k in sorted(agg):
        print(f"    {k[0]:<10} {k[1]:<24} {agg[k]}")

    # The number that actually matters. Everything else is updates to people
    # who already had it.
    mac_first = sum(c for (dev, typ), c in agg.items()
                    if dev == "Desktop" and typ == "First-time download")
    ios_first = sum(c for (dev, typ), c in agg.items()
                    if dev in ("iPhone", "iPad") and typ == "First-time download")
    print(f"\n  FIRST-TIME acquisition over the whole window:")
    print(f"    Mac (Desktop) : {mac_first}   {APPLE_CAVEAT}")
    print(f"    iOS           : {ios_first}")
    print("    ^ auto-updates and redownloads are NOT acquisition -- they are people"
          "\n      who already had the app. Only first-time downloads enter the funnel.")

    print("\n  by territory")
    terr: dict = collections.defaultdict(int)
    for r in uniq:
        terr[r["Territory"]] += count(r)
    for k, v in sorted(terr.items(), key=lambda x: -x[1]):
        print(f"    {k:<6} {v}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", help="current marketing version, e.g. 1.47.0")
    ap.add_argument("--skip-asc", action="store_true", help="GitHub only, no Apple creds")
    args = ap.parse_args()

    github_section(args.version)
    if not args.skip_asc:
        asc_section()

    print("\n" + "=" * 74)
    print("HOW TO READ THIS")
    print("=" * 74)
    print("""
  Compare FIRST-TIME acquisition above against the row count from
  backend/supabase/analysis/phase1_menu_open_to_provider.sql.

  If external acquisition is itself in the single digits, the telemetry funnel
  percentage is unreadable NO MATTER HOW LONG YOU WAIT, and the Phase 1 gate
  (~100 mature rows) cannot be reached by waiting. That is a finding about
  acquisition, not about activation, and it redirects the work.

  Do not compute a ratio between an Apple figure and a telemetry figure. The
  Apple numbers are thresholded and rounded; a ratio built on them carries a
  precision they do not have.
""")


if __name__ == "__main__":
    main()

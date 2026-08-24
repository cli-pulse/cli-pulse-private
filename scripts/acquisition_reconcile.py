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

THE TRAP THAT MATTERS MOST -- "Detailed" is the CENSORED report
---------------------------------------------------------------
Apple ships two variants of each analytics report and the names are actively
misleading:

    App Downloads DETAILED  -- more dimensions, PRIVACY-THRESHOLDED.
                               Minimum reportable value 5. Cells below it are
                               dropped entirely, not rounded down.
    App Downloads STANDARD  -- fewer dimensions, NOT thresholded.
                               Minimum reportable value 1.

The threshold is applied PER CELL, where a cell is the full dimensional tuple
(date x version x device x OS build x source x page x territory x ...). Adding
dimensions therefore does not merely add detail -- it shatters the data into
cells too small to survive, and the report silently returns less. Measured on
this app, 2026-04-03..08-15:

    Mac first-time downloads   DETAILED     0     STANDARD   108
    Mac impressions            DETAILED 50,165    STANDARD 75,364
    Mac product page views     DETAILED    44     STANDARD   641

Until 2026-08-17 this script read DETAILED, and the numbers it printed were
used to conclude that observable acquisition was "single digits across all
channels" and that Mac first-time downloads had "never crossed Apple's
threshold in 3.5 months". The mechanism was right; the conclusion was wrong by
two orders of magnitude, because the loss is worst exactly where the numbers
are smallest -- i.e. in every figure anyone cared about.

Suppression is therefore NOT a uniform haircut. It is steeply biased toward
small cells, so a RATIO built from a thresholded report is wrong in a
predictable direction: numerators (page views, downloads) are censored far
harder than denominators (impressions). Mac tap-through read 0.089% from
DETAILED and 0.851% from STANDARD -- a 9.5x error, all of it manufactured by
the instrument.

This script now reads STANDARD everywhere and asserts, at runtime, that the
report it received is not thresholded (see `assert_not_thresholded`). It also
prints the DETAILED figure beside it so the gap stays visible instead of
becoming folklore again.

Residual caveat that STANDARD does NOT remove: days with genuinely zero events
are absent rather than zero, and Apple may still restate recent days.

A SECOND THING THIS FILE USED TO CLAIM, AND IT WAS ALSO WRONG
------------------------------------------------------------
"ASC is structurally blind to someone who reads the website and runs
`brew install`." Partly false. `App Store Web Preview Engagement Standard`
covers the apps.apple.com product page as viewed in a BROWSER, and it had 14
ONGOING instances nobody had ever read -- 163 rows over 63 days, including a
`View in Mac App Store` tap that is a measurable web -> store handoff.

It narrows that gap without closing it, for a reason worth keeping in mind
whenever a channel looks newly visible: its `Source Type` is entirely
`Unavailable`, so it still cannot separate a visitor our own website sent from
one a search engine did. See `web_preview_section`.

The pattern by now is hard to miss: three separate "we are blind to X" claims in
this project turned out to be "nobody opened the report about X".

MAC AND iOS ARE NOT TWO CHANNELS OF ONE PRODUCT -- NEVER SUM THEM
-----------------------------------------------------------------
This script has split downloads by Device since it was written, and write-ups
kept quoting the total anyway. So the reason now prints next to the numbers.

iOS builds no collectors. It has nothing to read on the device it runs on, its
content sits behind a login, and it fills up only by cloud sync FROM a Mac that
is already running CLI Pulse. An iPhone first-time download therefore does not
enter the funnel a Mac download enters -- most of them meet a sign-in wall and
an empty screen. A combined figure reads as reach and measures nothing: it moves
when store appeal changes on a platform that delivers no value yet, and it hides
the only number the Mac funnel is denominated in.

The same caution applies to iPhone's tap-through rate, which has run far above
Mac's. That is a measurement of the listing, not of anything delivered.

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

APPLE_CAVEAT = "(App Store only -- blind to Developer ID DMG and Homebrew)"
GH_CAVEAT = "(includes CI, owner testing, bots -- UPPER BOUND on humans)"

# The uncensored variants. Do not "improve" these to Detailed for the extra
# dimensions: see the module docstring. Detailed is kept only as a contrast.
RPT_DOWNLOADS = "App Downloads Standard"
RPT_ENGAGEMENT = "App Store Discovery and Engagement Standard"
RPT_INSTALL_DELETE = "App Store Installation and Deletion Standard"
RPT_PURCHASES = "App Store Purchases Standard"
RPT_WEB_PREVIEW = "App Store Web Preview Engagement Standard"
RPT_DOWNLOADS_CENSORED = "App Downloads Detailed"
RPT_ENGAGEMENT_CENSORED = "App Store Discovery and Engagement Detailed"


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

    print("\n  traffic, last 14 days:")
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


def fetch_report(report_name: str, access_types: dict[str, str]) -> list[dict]:
    """Every DAILY row of one named report, across all report requests.

    Deduped on the DIMENSION key rather than the whole record, and ONGOING wins
    over ONE_TIME_SNAPSHOT. That matters: Apple restates the most recent few
    days, so the same cell can arrive twice with counts differing by 1-2.
    Deduping on the whole record keeps both copies and quietly inflates every
    total -- measured at 32 conflicting keys on the engagement report.
    """
    rows: list[dict] = []
    for access_type, rid in access_types.items():
        reports = asc_get(f"/analyticsReportRequests/{rid}/reports",
                          {"limit": 200, "filter[name]": report_name})
        for rep in reports.get("data", []):
            inst = asc_get(f"/analyticsReports/{rep['id']}/instances",
                           {"limit": 200, "filter[granularity]": "DAILY"})
            for i in inst.get("data", []):
                segs = asc_get(f"/analyticsReportInstances/{i['id']}/segments",
                               {"limit": 50})
                for s in segs.get("data", []):
                    raw = requests.get(s["attributes"]["url"], timeout=300).content
                    try:
                        text = gzip.decompress(raw).decode("utf-8")
                    except OSError:
                        text = raw.decode("utf-8")
                    for r in csv.DictReader(io.StringIO(text), delimiter="\t"):
                        r["_accessType"] = access_type
                        rows.append(r)

    value_cols = {"Counts", "Unique Counts", "Unique Devices", "Purchases",
                  "Paying Users", "Proceeds in USD", "Sales in USD", "_accessType"}
    best: dict[tuple, dict] = {}
    for r in rows:
        key = tuple(sorted((k, v) for k, v in r.items() if k not in value_cols))
        prev = best.get(key)
        if prev is None or (r["_accessType"] == "ONGOING"
                            and prev["_accessType"] != "ONGOING"):
            best[key] = r
    return list(best.values())


def count_of(row: dict, field: str = "Counts") -> int:
    v = row.get(field, "")
    return int(v) if str(v).isdigit() else 0


def assert_not_thresholded(report_name: str, rows: list[dict]) -> None:
    """Fail loudly if we were handed a privacy-thresholded report.

    A thresholded report CANNOT emit a value below 5 -- cells that small are
    dropped. So observing any 1..4 proves the report is uncensored, and never
    observing one across thousands of rows is the signature of the floor.

    This guard exists because the failure it catches is invisible: the censored
    report returns valid-looking rows, sums cleanly, and is wrong by 100x. It is
    exercised in both directions by `--self-test`.
    """
    if not rows:
        sys.exit(f"\n{report_name}: NO ROWS. That is an empty result, not a zero.\n"
                 "  Check the report requests are live before concluding anything.")
    vals = [count_of(r) for r in rows]
    vals = [v for v in vals if v > 0]
    floor = min(vals) if vals else 0
    if floor >= 5:
        sys.exit(
            f"\n*** REFUSING TO REPORT FROM A THRESHOLDED REPORT ***\n"
            f"  {report_name}: {len(rows)} rows, smallest non-zero value = {floor}.\n"
            f"  A report with no value below 5 is privacy-thresholded: cells under\n"
            f"  the floor were DROPPED, not rounded. Small numbers -- every number\n"
            f"  this script exists to produce -- are censored hardest.\n"
            f"  Use the STANDARD variant of this report, not Detailed.\n"
            f"  See the module docstring for the measured size of the error.")
    print(f"    [guard] {report_name}: {len(rows)} rows, floor={floor} "
          f"-> uncensored (a thresholded report cannot emit <5)")


def report_requests() -> dict[str, str]:
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
    return by_type


def asc_section(show_censored: bool = True) -> None:
    print("\n" + "=" * 74)
    print("APP STORE CONNECT -- mas + ios denominators  " + APPLE_CAVEAT)
    print("=" * 74)
    by_type = report_requests()

    print(f"\n  fetching {RPT_DOWNLOADS!r} ...")
    dl = fetch_report(RPT_DOWNLOADS, by_type)
    assert_not_thresholded(RPT_DOWNLOADS, dl)

    dates = sorted(r["Date"] for r in dl)
    print(f"  {len(dl)} unique rows, event dates {dates[0]} .. {dates[-1]}")

    print("\n  Device x Download Type")
    agg: dict = collections.defaultdict(int)
    for r in dl:
        agg[(r["Device"], r["Download Type"])] += count_of(r)
    for k in sorted(agg):
        print(f"    {k[0]:<10} {k[1]:<24} {agg[k]}")

    # The number that actually matters. Everything else is updates to people
    # who already had it.
    mac_first = sum(c for (dev, typ), c in agg.items()
                    if dev == "Desktop" and typ == "First-time download")
    ios_first = sum(c for (dev, typ), c in agg.items()
                    if dev in ("iPhone", "iPad") and typ == "First-time download")
    print("\n  FIRST-TIME acquisition over the whole window:")
    print(f"    Mac (Desktop) : {mac_first}   {APPLE_CAVEAT}")
    print(f"    iOS           : {ios_first}")
    print("    ^ auto-updates and redownloads are NOT acquisition -- they are people"
          "\n      who already had the app. Only first-time downloads enter the funnel.")
    # v1.50 W3. This split has been printed since the report existed; the sum
    # kept turning up in write-ups anyway, so the reason it is wrong is now
    # printed next to the numbers rather than left in a memo.
    print(f"\n    DO NOT ADD THESE TOGETHER. There is no {mac_first + ios_first}."
          "\n      The two platforms are not two channels of one product. iOS builds no"
          "\n      collectors: it has nothing to read on the device it runs on, its content"
          "\n      sits behind a login, and it fills up only by cloud sync FROM a Mac that"
          "\n      is already running CLI Pulse. An iPhone first-time download is therefore"
          "\n      not an entry into the same funnel a Mac download enters -- most of them"
          "\n      meet a sign-in wall and an empty screen."
          "\n      A combined figure reads as reach and measures nothing: it moves when"
          "\n      store appeal changes on a platform that delivers no value yet, and it"
          "\n      hides the only number the Mac funnel is denominated in.")

    print("\n  first-time downloads by month")
    per_month: dict = collections.defaultdict(lambda: collections.defaultdict(int))
    for r in dl:
        if r["Download Type"] == "First-time download":
            per_month[r["Date"][:7]][r["Device"]] += count_of(r)
    print(f"    {'month':<9} {'Mac':>6} {'iPhone':>8} {'iPad':>6}")
    for mo in sorted(per_month):
        m = per_month[mo]
        print(f"    {mo:<9} {m['Desktop']:>6} {m['iPhone']:>8} {m['iPad']:>6}")

    print("\n  first-time downloads by acquisition source")
    src: dict = collections.defaultdict(int)
    for r in dl:
        if r["Download Type"] == "First-time download":
            src[(r["Device"], r["Source Type"])] += count_of(r)
    for dev in ("Desktop", "iPhone", "iPad"):
        tot = sum(v for k, v in src.items() if k[0] == dev)
        if not tot:
            continue
        print(f"    {dev} ({tot})")
        for k in sorted((k for k in src if k[0] == dev), key=lambda k: -src[k]):
            print(f"      {k[1]:<20} {src[k]:>5}  ({src[k]/tot*100:.1f}%)")
    print("    ^ 'Web referrer' is the ONLY visible website->App Store path, and it")
    print("      does not include Homebrew or the DMG at all: those never touch the")
    print("      App Store, so no Apple report can ever see them.")

    print("\n  by territory (all download types)")
    terr: dict = collections.defaultdict(int)
    for r in dl:
        terr[r["Territory"]] += count_of(r)
    for k, v in sorted(terr.items(), key=lambda x: -x[1])[:12]:
        print(f"    {k:<6} {v}")

    # ---- storefront funnel: impression -> product page -> tap ----------------
    print(f"\n  fetching {RPT_ENGAGEMENT!r} ...")
    eng = fetch_report(RPT_ENGAGEMENT, by_type)
    assert_not_thresholded(RPT_ENGAGEMENT, eng)

    print("\n  STOREFRONT FUNNEL -- impression -> product page view -> tap")
    print("    Impressions and page views are independent event counts over the same")
    print("    window; Apple does not attribute a page view to the impression that")
    print("    caused it. Read the ratio as a rate, never as a per-user conversion.")
    f: dict = collections.defaultdict(int)
    for r in eng:
        f[(r["Device"], r["Event"])] += count_of(r)
    print(f"\n    {'device':<14} {'impressions':>12} {'page views':>11} {'taps':>7} {'imp->PV':>9}")
    for dev in sorted({r["Device"] for r in eng}):
        i, p, t = f[(dev, "Impression")], f[(dev, "Page view")], f[(dev, "Tap")]
        print(f"    {dev:<14} {i:>12,} {p:>11,} {t:>7,} "
              f"{p/i*100 if i else 0:>8.3f}%")

    print("\n    by source type -- the same listing assets on different surfaces")
    g: dict = collections.defaultdict(int)
    for r in eng:
        g[(r["Device"], r["Source Type"], r["Event"])] += count_of(r)
    for dev in ("Desktop", "iPhone"):
        print(f"      {dev}")
        for s in sorted({k[1] for k in g if k[0] == dev},
                        key=lambda s: -g[(dev, s, "Impression")]):
            i, p = g[(dev, s, "Impression")], g[(dev, s, "Page view")]
            rate = f"{p/i*100:>7.3f}%" if i else "      --"
            print(f"        {s:<20} impressions={i:>8,}  page views={p:>5,}  {rate}")
    print("      ^ icon, screenshots, subtitle and description are identical across")
    print("        these rows. A gap between surfaces is about placement and intent,")
    print("        NOT about the listing assets.")

    retention_section(by_type, dl)
    purchases_section(by_type)
    web_preview_section(by_type)

    if show_censored:
        censored_contrast(by_type, dl, eng)


def retention_section(by_type: dict[str, str], dl: list[dict]) -> None:
    """Install -> deletion, from a report nobody had opened until 2026-08-17.

    `App Store Installation and Deletion Standard` carries an `App Download
    Date` on every row, which makes it the only Apple feed that yields a real
    COHORT: how long after downloading did this install get removed. That is
    the single most useful number about onboarding available anywhere, and it
    costs nothing -- no client change, no new telemetry, no privacy delta.

    It is also the reason v1.49 did NOT ship D1/D7/D30 retention pings. The
    pings would have been conditioned on the user having already opened the
    popover and accepted the disclosure card -- i.e. on having cleared the very
    hurdle under investigation -- so they could only ever have described the
    survivors. This report has no such conditioning.

    WHAT IT CANNOT SEE, and this is the whole reason for the coverage line
    below: it is a CONSENTING-USER SAMPLE, not a census. Only users who agreed
    to share analytics with developers appear. Measured 2026-08-17 it held 19
    Mac installs against 108 Mac first-time downloads in the download feed --
    roughly a sixth. So:

        the SHAPE of the latency distribution is usable
        the RATE (deletes / installs) is NOT

    Quoting a deletion percentage from here would be the same error as quoting
    a ratio off a thresholded report: a numerator and denominator drawn from
    different populations.
    """
    print(f"\n  fetching {RPT_INSTALL_DELETE!r} ...")
    rows = fetch_report(RPT_INSTALL_DELETE, by_type)
    if not rows:
        print("    no rows -- an empty result, not a zero. Check the report "
              "requests above are live before concluding anything.")
        return
    assert_not_thresholded(RPT_INSTALL_DELETE, rows)

    dates = sorted(r["Date"] for r in rows)
    print(f"    {len(rows)} rows, {len(set(dates))} distinct dates, "
          f"{dates[0]} .. {dates[-1]}")

    print("\n  INSTALL / DELETE counts")
    # `Install` here spans EVERY Download Type -- first-time, redownload,
    # auto-download and manual update. Comparing that total against first-time
    # downloads is comparing two different events, and it shows: doing so
    # reported iPad coverage of 114%, which is impossible for a subset. Coverage
    # is therefore computed first-time-against-first-time only.
    g: dict = collections.defaultdict(int)
    for r in rows:
        g[(r["Device"], r["Event"], r["Download Type"])] += count_of(r)
    devices = sorted({r["Device"] for r in rows})
    print(f"    {'device':<10} {'installs':>9} {'(first-time)':>13} {'deletes':>9}"
          f"   first-time coverage of the download feed")
    for dev in devices:
        inst = sum(v for k, v in g.items() if k[0] == dev and k[1] == "Install")
        inst_first = g[(dev, "Install", "First-time download")]
        dele = sum(v for k, v in g.items() if k[0] == dev and k[1] == "Delete")
        if not (inst or dele):
            continue
        first = sum(count_of(r) for r in dl if r["Device"] == dev
                    and r["Download Type"] == "First-time download")
        cov = (f"{inst_first}/{first} = {inst_first / first * 100:.0f}%"
               if first else "n/a")
        print(f"    {dev:<10} {inst:>9,} {inst_first:>13,} {dele:>9,}   {cov}")
    print("    ^ that last column is the SAMPLE FRACTION. Only users who agreed")
    print("      to share analytics with developers appear here at all, and it")
    print("      lands around 5-15% of first-time downloads. So:")
    print("        the SHAPE of the latency distribution below is usable;")
    print("        deletes/installs is NOT a deletion rate and must not be quoted")
    print("        as one -- it divides one population by another.")

    # ---- the cohort: how long did an install survive? ----------------------
    import datetime as _dt
    latencies: list[int] = []
    per_device: dict = collections.defaultdict(list)
    for r in rows:
        if r["Event"] != "Delete" or not r.get("App Download Date"):
            continue
        try:
            born = _dt.date.fromisoformat(r["App Download Date"])
            died = _dt.date.fromisoformat(r["Date"])
        except ValueError:
            continue
        days = (died - born).days
        if days < 0:
            continue
        latencies += [days] * count_of(r)
        per_device[r["Device"]] += [days] * count_of(r)

    print("\n  DELETION LATENCY -- days from download to deletion")
    if not latencies:
        print("    no deletion carries a download date in this window.")
        print("    That is an absence of cohort rows, NOT evidence that nobody")
        print("    deleted the app.")
        return
    latencies.sort()

    def pct(xs: list[int], q: float) -> int:
        return xs[min(int(len(xs) * q), len(xs) - 1)]

    print(f"    n={len(latencies)}  min={latencies[0]}  p25={pct(latencies, .25)}  "
          f"median={pct(latencies, .5)}  p75={pct(latencies, .75)}  max={latencies[-1]}")
    for label, cutoff in (("same day (0)", 0), ("within 1 day", 1),
                          ("within 7 days", 7), ("within 30 days", 30)):
        n = sum(1 for x in latencies if x <= cutoff)
        print(f"    {label:<16} {n:>4} / {len(latencies)}  ({n / len(latencies) * 100:.0f}%)")
    for dev in sorted(per_device):
        xs = sorted(per_device[dev])
        print(f"      {dev:<9} n={len(xs):<4} median={pct(xs, .5)}")
    print("""
    A median at or near 0 is the signature of "opened it, did not get it" --
    abandonment before the app ever proved itself, which no in-app counter can
    observe because the counter only fires after the menu is opened and the
    disclosure card accepted. Track this series across releases: it is the
    readout for the v1.49 first-run window, and the honest one, because it is
    measured outside the app rather than by the app.""")


def purchases_section(by_type: dict[str, str]) -> None:
    """Every App Store purchase, for a product where that is a countable list."""
    print(f"\n  fetching {RPT_PURCHASES!r} ...")
    rows = fetch_report(RPT_PURCHASES, by_type)
    if not rows:
        print("    no rows. For purchases specifically this is ambiguous between")
        print("    'no purchases' and 'report not generating' -- check the")
        print("    instance ledger before repeating it as zero.")
        return
    total = sum(int(r.get("Purchases", 0) or 0) for r in rows)
    proceeds = sum(float(r.get("Proceeds in USD", 0) or 0) for r in rows)
    print(f"    {len(rows)} rows, {total} purchase(s), "
          f"${proceeds:.2f} proceeds")
    for r in sorted(rows, key=lambda r: r["Date"]):
        print(f"      {r['Date']}  {r.get('Content Name', '?'):<26} "
              f"{r.get('Device', '?'):<8} {r.get('Territory', '?'):<4} "
              f"{r.get('Payment Method', '?'):<10} "
              f"${r.get('Proceeds in USD', '?')}")


def web_preview_section(by_type: dict[str, str]) -> None:
    """The apps.apple.com product page, viewed in a BROWSER.

    This one corrects a claim made repeatedly in the v1.49 plan and in this
    file's own docstring: that ASC is "structurally blind to someone who reads
    the website and runs `brew install`". Part of that path is visible after
    all, and had simply never been read -- 14 ONGOING instances sitting there,
    163 rows over 63 days.

    What it shows is the WEB product page and, usefully, a measurable handoff:
    `View in Mac App Store` is someone leaving the browser page for the store.

    THREE THINGS IT STILL CANNOT DO, and none of them are optional to state:

      * `Source Type` is entirely `Unavailable`, so it CANNOT distinguish a
        visitor sent by our own site from one who arrived via a search engine.
        The website-attribution gap is narrowed, not closed.
      * It is crawler-contaminated -- `bingbot` shows up in the Browser column.
      * A web page view is a far stronger intent signal than an in-store
        impression. Do NOT compare this section's tap-through against the
        storefront funnel's; the denominators are different animals.

    And one unexplained discrepancy, printed rather than smoothed over: the taps
    counted here are several times the Mac `Web referrer` page views in the
    storefront report. Either the handoff loses most people or the two reports
    attribute differently. Until someone establishes which, they are two
    numbers, not one.
    """
    print(f"\n  fetching {RPT_WEB_PREVIEW!r} ...")
    rows = fetch_report(RPT_WEB_PREVIEW, by_type)
    if not rows:
        print("    no rows -- an empty result, not a zero.")
        return
    assert_not_thresholded(RPT_WEB_PREVIEW, rows)

    dates = sorted(r["Date"] for r in rows)
    print(f"    {len(rows)} rows, {len(set(dates))} dates, {dates[0]} .. {dates[-1]}")

    views = sum(count_of(r) for r in rows if r["Event"] == "Page view")
    print("\n  WEB product page (apps.apple.com in a browser)")
    print(f"    page views: {views:,}")
    taps: dict = collections.defaultdict(int)
    for r in rows:
        if r["Event"] == "Tap":
            taps[r["Engagement Type"] or "(unspecified)"] += count_of(r)
    print(f"    {'engagement':<34} {'count':>6} {'% of page views':>16}")
    for k in sorted(taps, key=lambda k: -taps[k]):
        pct = taps[k] / views * 100 if views else 0
        print(f"    {k:<34} {taps[k]:>6} {pct:>15.1f}%")

    crawlers = sum(count_of(r) for r in rows
                   if r["Event"] == "Page view" and "bot" in r.get("Browser", "").lower())
    print(f"\n    of which browser looks like a crawler: {crawlers}"
          f" -- contamination, small but real")

    print("\n    top territories")
    terr: dict = collections.defaultdict(int)
    for r in rows:
        if r["Event"] == "Page view":
            terr[r["Territory"]] += count_of(r)
    for k, v in sorted(terr.items(), key=lambda x: -x[1])[:6]:
        print(f"      {k:<5} {v}")
    print("""
    Read this as its own channel, not as part of the storefront funnel. It
    cannot tell our website's visitors from a search engine's (Source Type is
    always 'Unavailable'), so it narrows the website-attribution gap without
    closing it.""")


def censored_contrast(by_type: dict[str, str], dl: list[dict],
                      eng: list[dict]) -> None:
    """Print the thresholded figures next to the real ones, every run.

    Not decoration. The whole reason this error survived four months and two
    adversarial plan reviews is that nobody had the two side by side.
    """
    print("\n" + "-" * 74)
    print("  CONTRAST: what the thresholded 'Detailed' reports say instead")
    print("-" * 74)
    for label, real, name in ((RPT_DOWNLOADS, dl, RPT_DOWNLOADS_CENSORED),
                              (RPT_ENGAGEMENT, eng, RPT_ENGAGEMENT_CENSORED)):
        cen = fetch_report(name, by_type)
        vals = [count_of(r) for r in cen if count_of(r) > 0]
        print(f"\n    {name}: {len(cen)} rows, floor={min(vals) if vals else 0}")
        if "Download Type" in (cen[0] if cen else {}):
            for dev in ("Desktop", "iPhone"):
                a = sum(count_of(r) for r in real if r["Device"] == dev
                        and r["Download Type"] == "First-time download")
                b = sum(count_of(r) for r in cen if r["Device"] == dev
                        and r["Download Type"] == "First-time download")
                print(f"      {dev:<9} first-time downloads: "
                      f"uncensored={a:<6} thresholded={b:<6} hidden={a-b}")
        else:
            for dev in ("Desktop", "iPhone"):
                for ev in ("Impression", "Page view"):
                    a = sum(count_of(r) for r in real if r["Device"] == dev
                            and r["Event"] == ev)
                    b = sum(count_of(r) for r in cen if r["Device"] == dev
                            and r["Event"] == ev)
                    pct = (a - b) / a * 100 if a else 0
                    print(f"      {dev:<9} {ev:<11} uncensored={a:<8,} "
                          f"thresholded={b:<8,} hidden={pct:5.1f}%")
    print("\n    The suppression gradient -- mild on impressions, severe on page")
    print("    views and downloads -- is why every RATIO taken from the thresholded")
    print("    reports was wrong in the same direction.")


def self_test() -> int:
    """Prove the guard fires, in both directions, with no network.

    A guard that has only ever been observed passing is not known to work. This
    is the negative control.
    """
    print("=" * 74)
    print("SELF-TEST -- does assert_not_thresholded actually fire?")
    print("=" * 74)
    failures = 0

    thresholded = [{"Counts": str(v)} for v in (5, 6, 12, 40, 5, 9)]
    uncensored = [{"Counts": str(v)} for v in (1, 2, 5, 40, 3)]
    empty: list[dict] = []

    for label, rows, want_exit in (("thresholded (floor 5)", thresholded, True),
                                   ("uncensored (has a 1)", uncensored, False),
                                   ("empty result", empty, True)):
        try:
            assert_not_thresholded("synthetic:" + label, rows)
            got_exit = False
        except SystemExit:
            got_exit = True
        ok = got_exit == want_exit
        failures += 0 if ok else 1
        print(f"  {'PASS' if ok else 'FAIL':<5} {label:<24} "
              f"expected {'reject' if want_exit else 'accept'}, "
              f"got {'reject' if got_exit else 'accept'}")

    print(f"\n  {'ALL PASS' if not failures else f'{failures} FAILURE(S)'}")
    return 1 if failures else 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", help="current marketing version, e.g. 1.47.0")
    ap.add_argument("--skip-asc", action="store_true", help="GitHub only, no Apple creds")
    ap.add_argument("--skip-github", action="store_true", help="ASC only")
    ap.add_argument("--no-contrast", action="store_true",
                    help="omit the thresholded-report contrast block")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the anti-threshold guard fires; no network, no creds")
    args = ap.parse_args()

    if args.self_test:
        sys.exit(self_test())

    if not args.skip_github:
        github_section(args.version)
    if not args.skip_asc:
        asc_section(show_censored=not args.no_contrast)

    print("\n" + "=" * 74)
    print("HOW TO READ THIS")
    print("=" * 74)
    print("""
  Compare FIRST-TIME acquisition above against the row count from
  backend/supabase/analysis/phase1_menu_open_to_provider.sql -- but compare the
  RIGHT windows. anonymous_installs cannot contain an install that predates the
  backend going live (2026-08-06) or a build that predates the collector, and
  `n_tup_ins` is the real numerator because deleted rows never come back.
  Charging the telemetry for 4.5 months of downloads it could not have seen is
  the same class of error as reading a thresholded report.

  Do not compute a ratio between an Apple figure and a telemetry figure without
  saying what each side cannot see. Apple sees no Developer ID and no Homebrew
  install, ever. The telemetry sees nobody who did not open the menu bar popover
  and accept the disclosure card. Neither is the funnel; both are slices of it.
""")


if __name__ == "__main__":
    main()

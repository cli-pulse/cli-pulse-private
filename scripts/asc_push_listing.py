#!/usr/bin/env python3
"""Push the App Store listing texts (description, keywords, promotional text,
subtitle) from the repo to App Store Connect — for every locale, or some.

DEFAULT IS A DRY RUN. It GETs the listing App Store Connect holds and prints,
per locale and per field, what a push would change. Nothing is written.

    python3 scripts/asc_push_listing.py                          # both platforms
    python3 scripts/asc_push_listing.py --platform IOS --locale ja,ko
    python3 scripts/asc_push_listing.py --version 1.54.0         # diff that version

WRITING needs all three of --apply, --version and --platform:

    python3 scripts/asc_push_listing.py --apply --version 1.54.0 --platform IOS
    python3 scripts/asc_push_listing.py --apply --version 1.54.0 --platform MAC_OS

and then it:
  * validates every repo text first (lengths, keyword format, Guideline 2.3.10
    platform names, untranslated English — scripts/appstore_listing.py) and
    writes nothing if any check fails;
  * refuses unless that version's appStoreState is editable
    (PREPARE_FOR_SUBMISSION, DEVELOPER_REJECTED, REJECTED, METADATA_REJECTED).
    A live version's text is not ours to rewrite from a script;
  * PATCHes only the fields that differ, on locales that exist, and gives a
    localization with no supportUrl or marketingUrl the version's en-US one
    (App Store Connect will not submit a version while a localization has no
    support URL). A URL a locale already has is left as it is;
  * CREATES the appStoreVersionLocalization for a locale ASC does not have yet,
    copying supportUrl and marketingUrl from the version's en-US localization;
  * sets the subtitle on the EDITABLE appInfo only (the one App Store Connect
    opens alongside a new version), creating a missing appInfoLocalization
    with name "CLI Pulse" and privacyPolicyUrl copied from its en-US row.
    Creating one makes App Store Connect create an EMPTY version localization
    for that locale itself, on every editable version of both platforms. So
    the version is read again after the app info writes, and a row the store
    made is PATCHed (texts and URLs) rather than created, which would get 409.
    The other platform's copy is filled in by that platform's run;
  * NEVER deletes a locale, and never touches What's New — that is
    scripts/asc_submit.py's job (--whatsnew-dir). A locale created here has no
    What's New yet; App Store Connect requires one before an UPDATE can be
    submitted, and asc_submit.py refuses to submit until --whatsnew-dir has a
    text for every locale of the version;
  * re-reads everything it wrote and exits non-zero if the store does not now
    hold the repo text, or a localization has no support URL.

The texts live in CLI Pulse Bar/appstore/<locale>/ — see scripts/appstore_listing.py
for the layout and why es-ES and es-MX share one Spanish text. The iPhone
screenshots are pushed by the sibling scripts/asc_push_screenshots.py, with this
script's client and the same editability rule.

The ASC API key is read from ~/.appstoreconnect/private_keys/ (headless-safe),
then the owner's secrets directory, then iCloud Drive. The signed token is never
printed, logged or written anywhere.

Exit: 0 = dry run clean / apply verified. 1 = invalid texts, refused, or a
write that did not stick. 2 = could not reach App Store Connect.
"""
from __future__ import annotations

import argparse
import difflib
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import appstore_listing as listing  # noqa: E402

KEY_ID = "DMMFP6XTXX"
ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
APP_ID = "6761163709"
BASE = "https://api.appstoreconnect.apple.com/v1"

KEY_CANDIDATES = [
    Path.home() / f".appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8",
    Path.home() / "Library/Application Support/CLI-Pulse-Secrets"
    / f"asc-api-key-{KEY_ID}-2026-07-08.p8",
    Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Downloads"
    / f"AuthKey_{KEY_ID}.p8",
]

EDITABLE_STATES = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                   "METADATA_REJECTED"}
LIVE_STATES = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "PENDING_DEVELOPER_RELEASE"}
VERSION_FIELDS = [f for f in listing.FIELDS if f.resource == "version"]
APPINFO_FIELDS = [f for f in listing.FIELDS if f.resource == "appInfo"]
# Not in the repo: a localization without one takes the version's en-US one.
URL_ATTRS = ("supportUrl", "marketingUrl")

_TIMEOUT = 120
_RETRIES = 3
# An App Store Connect token may live 20 minutes at most. A run that uploads
# screenshots for seven locales and waits for each to be processed can take
# longer than that, and a request with an expired token is refused (401): so a
# token is minted again once it is this old, and once more on a 401.
TOKEN_LIFETIME = 1200
TOKEN_RENEW_AFTER = 900
# Only these are sent again after a timeout or a dropped connection. A POST
# creates a localization; if the first one landed and only the response was
# lost, a second POST gets 409 and the locale is reported FAILED although the
# store holds the right text. So a POST is sent once, and the read-back after
# the writes decides whether it landed and whether the run fails.
_IDEMPOTENT = frozenset({"GET", "PATCH"})


def _created(res: dict | None) -> str:
    """Status for a create. A create is not counted as a failure here: when its
    response is lost it may still have landed, and one the store rejected leaves
    the locale missing. The read-back sees both cases and counts only a text
    that is really not on the store."""
    return "ok" if res is not None else "not confirmed; the read-back below decides"


def die(msg: str, code: int = 2) -> "NoReturn":  # noqa: F821
    print(f"FATAL: {msg}", file=sys.stderr)
    raise SystemExit(code)


class ASC:
    """Minimal ASC client. The bearer token stays inside the headers dict and
    is never formatted into any message — errors print the response body only."""

    def __init__(self) -> None:
        try:
            import jwt  # noqa: PLC0415
            import requests  # noqa: PLC0415
        except ImportError as exc:
            die(f"missing dependency ({exc}). pip install pyjwt requests")
        self._requests = requests
        self._jwt = jwt
        key = next((p for p in KEY_CANDIDATES if p.exists()), None)
        if key is None:
            die("no ASC API key found. Looked in:\n  " + "\n  ".join(map(str, KEY_CANDIDATES)))
        self._key = key
        self._mint()

    def _mint(self) -> None:
        """A fresh token in the headers. The token itself is never kept
        anywhere else, and never printed."""
        now = int(time.time())
        tok = self._jwt.encode(
            {"iss": ISSUER, "iat": now, "exp": now + TOKEN_LIFETIME, "aud": "appstoreconnect-v1"},
            self._key.read_text(), algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"},
        )
        self._headers = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
        self._minted_at = time.monotonic()
        del tok

    def _can_mint(self) -> bool:
        # A client made without __init__ (the tests' stand-in) has no key.
        return getattr(self, "_key", None) is not None

    def _send(self, method: str, path: str, **kw):
        """The response, or None for a POST that timed out (see _IDEMPOTENT).
        A 401 is answered by minting a new token and sending once more: the
        request was refused unread, so even a POST cannot have landed."""
        if self._can_mint() and time.monotonic() - self._minted_at > TOKEN_RENEW_AFTER:
            self._mint()
        r = self._send_once(method, path, **kw)
        if r is not None and r.status_code == 401 and self._can_mint():
            print(f"  {method} {path}: 401, minting a new token and sending again", file=sys.stderr)
            self._mint()
            r = self._send_once(method, path, **kw)
        return r

    def _send_once(self, method: str, path: str, **kw):
        url = path if path.startswith("http") else BASE + path
        attempts = _RETRIES if method in _IDEMPOTENT else 1
        last = None
        for attempt in range(1, attempts + 1):
            try:
                return self._requests.request(method, url, headers=self._headers,
                                              timeout=_TIMEOUT, **kw)
            except (self._requests.Timeout, self._requests.ConnectionError) as exc:
                last = exc
                print(f"  {method} {path}: {type(exc).__name__} "
                      f"(attempt {attempt}/{attempts})", file=sys.stderr)
                if attempt < attempts:
                    time.sleep(5 * attempt)
        if method not in _IDEMPOTENT:
            print(f"  {method} {path}: not sent again, because a create may already "
                  "have landed; the read-back below shows whether it did", file=sys.stderr)
            return None
        die(f"{method} {path} failed after {attempts} attempts: {type(last).__name__}")

    def get(self, path: str, **params) -> dict:
        r = self._send("GET", path, params=params)
        if r.status_code != 200:
            die(f"GET {path} -> {r.status_code}: {r.text[:400]}")
        return r.json()

    def write(self, method: str, path: str, body: dict) -> dict | None:
        r = self._send(method, path, json=body)
        if r is None:
            return None
        if r.status_code >= 300:
            print(f"    {method} {path} -> {r.status_code}")
            try:
                for e in r.json().get("errors", []):
                    print(f"      {e.get('code', '')}: {e.get('detail') or e.get('title')}")
            except ValueError:
                print(f"      {r.text[:400]}")
            return None
        return r.json() if r.text else {}


# ── reading the store ────────────────────────────────────────────────────────

def version_state(attrs: dict) -> str:
    return attrs.get("appStoreState") or attrs.get("appVersionState") or "UNKNOWN"


def appinfo_state(attrs: dict) -> str:
    return attrs.get("state") or attrs.get("appStoreState") or "UNKNOWN"


def pick_version(asc: ASC, platform: str, version: str | None) -> dict | None:
    params = {"filter[platform]": platform, "limit": 20,
              "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,platform"}
    if version:
        params["filter[versionString]"] = version
    rows = asc.get(f"/apps/{APP_ID}/appStoreVersions", **params)["data"]
    if version:
        return rows[0] if rows else None
    # No version named: the one being prepared if there is one, else the live one.
    for row in rows:
        if version_state(row["attributes"]) in EDITABLE_STATES:
            return row
    for row in rows:
        if version_state(row["attributes"]) in LIVE_STATES:
            return row
    return rows[0] if rows else None


def pick_appinfo(asc: ASC) -> tuple[dict | None, dict | None]:
    """(editable appInfo or None, the one to diff against)."""
    rows = asc.get(f"/apps/{APP_ID}/appInfos")["data"]
    editable = next((r for r in rows if appinfo_state(r["attributes"]) in EDITABLE_STATES), None)
    live = next((r for r in rows if appinfo_state(r["attributes"]) in LIVE_STATES), None)
    return editable, editable or live or (rows[0] if rows else None)


def version_locs(asc: ASC, version_id: str) -> dict[str, dict]:
    rows = asc.get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations", limit=50)["data"]
    return {r["attributes"]["locale"]: r for r in rows}


def appinfo_locs(asc: ASC, info_id: str) -> dict[str, dict]:
    rows = asc.get(f"/appInfos/{info_id}/appInfoLocalizations", limit=50)["data"]
    return {r["attributes"]["locale"]: r for r in rows}


# ── diffing ──────────────────────────────────────────────────────────────────

def norm(value) -> str:
    return (value or "").strip()


def show_diff(attr: str, live: str, repo: str, full: bool) -> None:
    if attr != "description":
        print(f"        live: {live!r}")
        print(f"        repo: {repo!r}")
        return
    lines = list(difflib.unified_diff(live.splitlines(), repo.splitlines(),
                                      "live", "repo", n=0, lineterm=""))[2:]
    cap = None if full else 14
    for ln in lines[:cap]:
        print(f"        {ln[:150]}")
    if cap is not None and len(lines) > cap:
        print(f"        … {len(lines) - cap} more diff line(s); --full-diff shows all")


def compare_block(locale: str, platform: str, live_row: dict | None, fields,
                  full: bool) -> dict[str, str]:
    """Print one locale's comparison; return {attribute: repo text} for fields that differ."""
    changed: dict[str, str] = {}
    live_attrs = (live_row or {}).get("attributes", {})
    for f in fields:
        repo = listing.load_field(f.attribute, locale, platform if f.per_platform else None)
        src = listing.field_path(f, locale, platform if f.per_platform else None)
        live = norm(live_attrs.get(f.attribute))
        if live_row is None:
            print(f"    {f.attribute:<16} NEW       repo {len(repo)} chars ({src.name})")
            changed[f.attribute] = repo
        elif live == repo:
            print(f"    {f.attribute:<16} same      {len(repo)} chars")
        else:
            label = "ADD" if not live else "CHANGE"
            print(f"    {f.attribute:<16} {label:<9} live {len(live)} -> repo {len(repo)} chars")
            show_diff(f.attribute, live, repo, full)
            changed[f.attribute] = repo
    return changed


def missing_urls(attrs: dict, en_attrs: dict) -> dict[str, str]:
    """en-US's support and marketing URL, for each one this localization has
    none of. A URL it already has is its own and stays."""
    return {a: en_attrs[a] for a in URL_ATTRS if norm(en_attrs.get(a)) and not norm(attrs.get(a))}


def version_fields(attrs: dict, locale: str, platform: str, en_attrs: dict) -> dict[str, str]:
    """What one existing version localization still lacks: each repo text it
    does not hold, and en-US's URLs where it has none."""
    fields = {}
    for f in VERSION_FIELDS:
        want = listing.load_field(f.attribute, locale, platform)
        if norm(attrs.get(f.attribute)) != want:
            fields[f.attribute] = want
    fields.update(missing_urls(attrs, en_attrs))
    return fields


# ── main ─────────────────────────────────────────────────────────────────────

def parse_locales(raw: list[str] | None) -> list[str]:
    if not raw:
        return list(listing.LOCALE_SOURCES)
    wanted = [x.strip() for chunk in raw for x in chunk.split(",") if x.strip()]
    unknown = [x for x in wanted if x not in listing.LOCALE_SOURCES]
    if unknown:
        die(f"unknown locale(s) {unknown}; known: {', '.join(listing.LOCALE_SOURCES)}", 1)
    return [x for x in listing.LOCALE_SOURCES if x in wanted]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--platform", choices=["IOS", "MAC_OS"],
                    help="one platform (required with --apply); default: both for a dry run")
    ap.add_argument("--version", help="versionString to diff or write, e.g. 1.54.0")
    ap.add_argument("--locale", action="append",
                    help="limit to these ASC locales (comma-separated or repeated)")
    ap.add_argument("--apply", action="store_true",
                    help="WRITE to App Store Connect (needs --version and --platform)")
    ap.add_argument("--full-diff", action="store_true", help="print whole description diffs")
    args = ap.parse_args()

    locales = parse_locales(args.locale)
    if args.apply and not (args.version and args.platform):
        die("--apply needs --version <X.Y.Z> and --platform IOS|MAC_OS. "
            "A write names exactly one version.", 1)

    # 1. The repo texts must be valid before anything else, dry run included.
    problems = listing.validate()
    print(f"repo texts: {len(listing.source_dirs())} source dir(s) for "
          f"{len(listing.LOCALE_SOURCES)} ASC locale(s)")
    for src, counts in listing.summary_rows():
        print(f"  {src:8} " + "  ".join(f"{k[:-4]}={v}" for k, v in counts.items()))
    if problems:
        for p in problems:
            print(f"  INVALID  {p}")
        if args.apply:
            die(f"{len(problems)} problem(s) in the repo texts; nothing was written.", 1)
        print("  (dry run continues so the diff is visible; --apply would refuse)")

    asc = ASC()
    platforms = [args.platform] if args.platform else ["IOS", "MAC_OS"]

    editable_info, diff_info = pick_appinfo(asc)
    info_locs = appinfo_locs(asc, diff_info["id"]) if diff_info else {}

    pending_writes = 0
    plan: list[tuple[str, dict, dict[str, dict], dict[str, dict[str, str]]]] = []
    for plat in platforms:
        ver = pick_version(asc, plat, args.version)
        if ver is None:
            msg = f"{plat}: no version {args.version or ''} in App Store Connect"
            if args.apply:
                die(msg + ". Create it first: scripts/asc_submit.py --create-version "
                    "ios|macos --version X.Y.Z --apply (or in App Store Connect).", 1)
            print(f"\n=== {msg} — skipped")
            continue
        vs = ver["attributes"]["versionString"]
        st = version_state(ver["attributes"])
        tag = "editable" if st in EDITABLE_STATES else "NOT editable"
        print(f"\n=== {plat} {vs}  state={st} ({tag})")
        vlocs = version_locs(asc, ver["id"])
        en_urls = vlocs.get(listing.PRIMARY_LOCALE, {}).get("attributes", {})
        changes: dict[str, dict[str, str]] = {}
        for loc in locales:
            print(f"  [{loc}]" + ("" if loc in vlocs else "  — no localization on this version yet"))
            ch = compare_block(loc, plat, vlocs.get(loc), VERSION_FIELDS, args.full_diff)
            if loc in vlocs:
                urls = missing_urls(vlocs[loc]["attributes"], en_urls)
                for attr, url in urls.items():
                    print(f"    {attr:<16} ADD       none here; en-US's {url}")
                ch.update(urls)
            if ch:
                changes[loc] = ch
                pending_writes += len(ch)
        extra = sorted(set(vlocs) - set(listing.LOCALE_SOURCES))
        if extra:
            print(f"  note: on the store but not in the repo (left untouched): {', '.join(extra)}")
        plan.append((plat, ver, vlocs, changes))

    state = appinfo_state(diff_info["attributes"]) if diff_info else "none"
    print(f"\n=== app info (subtitle; shared by both platforms)  state={state}"
          + ("" if editable_info else "  — no editable appInfo: subtitles cannot be written now"))
    info_changes: dict[str, dict[str, str]] = {}
    for loc in locales:
        print(f"  [{loc}]" + ("" if loc in info_locs else "  — no app info localization yet"))
        ch = compare_block(loc, "IOS", info_locs.get(loc), APPINFO_FIELDS, args.full_diff)
        if ch:
            info_changes[loc] = ch
            pending_writes += len(ch)

    if not args.apply:
        print(f"\nDRY RUN: {pending_writes} field(s) differ. Nothing was written.")
        return 1 if problems else 0

    # ── 2. apply: one platform, one version, editable only ────────────────────
    plat, ver, vlocs, changes = plan[0]
    st = version_state(ver["attributes"])
    if st not in EDITABLE_STATES:
        die(f"{plat} {args.version} is {st}; only {sorted(EDITABLE_STATES)} can be written. "
            "Nothing was written.", 1)
    en_row = vlocs.get(listing.PRIMARY_LOCALE)
    if en_row is None:
        die(f"{plat} {args.version} has no {listing.PRIMARY_LOCALE} localization to copy "
            "URLs from. Nothing was written.", 1)
    en_attrs = en_row["attributes"]
    # Every precondition is checked before the first write, so a refusal never
    # leaves a half-pushed listing behind.
    elocs: dict[str, dict] = {}
    en_info: dict = {}
    if info_changes and editable_info is not None:
        elocs = appinfo_locs(asc, editable_info["id"])
        en_info = elocs.get(listing.PRIMARY_LOCALE, {}).get("attributes", {})
        if en_info.get("name") != listing.APP_NAME:
            die(f"en-US app name is {en_info.get('name')!r}, expected "
                f"{listing.APP_NAME!r}; refusing to copy it into new locales. "
                "Nothing was written.", 1)

    failures = 0
    print(f"\nAPPLY {plat} {args.version}")
    # App info first: a new locale gets its name and privacy policy URL before
    # its version text, which is the order App Store Connect's own UI uses.
    if info_changes:
        if editable_info is None:
            print("  subtitle: NOT written — App Store Connect has no editable appInfo. "
                  "It opens one with a new version; run again then.")
            failures += 1
        else:
            for loc, fields in info_changes.items():
                if loc in elocs:
                    lid = elocs[loc]["id"]
                    res = asc.write("PATCH", f"/appInfoLocalizations/{lid}", {"data": {
                        "type": "appInfoLocalizations", "id": lid, "attributes": fields}})
                    print(f"  [{loc}] PATCH subtitle: {'ok' if res is not None else 'FAILED'}")
                    failures += res is None
                else:
                    attrs = {"locale": loc, "name": listing.APP_NAME, **fields}
                    if en_info.get("privacyPolicyUrl"):
                        attrs["privacyPolicyUrl"] = en_info["privacyPolicyUrl"]
                    res = asc.write("POST", "/appInfoLocalizations", {"data": {
                        "type": "appInfoLocalizations", "attributes": attrs,
                        "relationships": {"appInfo": {"data": {
                            "type": "appInfos", "id": editable_info["id"]}}}}})
                    print(f"  [{loc}] CREATE app info localization: {_created(res)}")

    # The app info writes above may have made App Store Connect create some of
    # the version localizations planned as creates (empty, with no URLs; on
    # 2026-09-28 all five 1.54.0 creates then got 409 DUPLICATE). Read the
    # version again and PATCH what the store made.
    if any(loc not in vlocs for loc in changes):
        fresh = version_locs(asc, ver["id"])
        for loc in [x for x in changes if x not in vlocs and x in fresh]:
            changes[loc] = version_fields(fresh[loc]["attributes"], loc, plat, en_attrs)
            print(f"  [{loc}] on the version now (App Store Connect adds an empty one when "
                  "an app info localization is created): PATCH rather than create")
        vlocs = fresh

    def patch(loc: str, lid: str, fields: dict[str, str]) -> bool:
        res = asc.write("PATCH", f"/appStoreVersionLocalizations/{lid}", {"data": {
            "type": "appStoreVersionLocalizations", "id": lid, "attributes": fields}})
        print(f"  [{loc}] PATCH {', '.join(fields)}: {'ok' if res is not None else 'FAILED'}")
        return res is None

    for loc, fields in changes.items():
        if loc in vlocs:
            if fields:
                failures += patch(loc, vlocs[loc]["id"], fields)
            continue
        attrs = {"locale": loc, **fields, **missing_urls({}, en_attrs)}
        res = asc.write("POST", "/appStoreVersionLocalizations", {"data": {
            "type": "appStoreVersionLocalizations", "attributes": attrs,
            "relationships": {"appStoreVersion": {"data": {
                "type": "appStoreVersions", "id": ver["id"]}}}}})
        row = None if res is not None else version_locs(asc, ver["id"]).get(loc)
        if row is None:
            print(f"  [{loc}] CREATE localization: {_created(res)}")
            continue
        # Not confirmed, yet the locale is there: the store made it after the
        # read above (409), or ours landed and only the response was lost.
        rest = version_fields(row["attributes"], loc, plat, en_attrs)
        print(f"  [{loc}] CREATE localization: not confirmed, but the version has this locale "
              + ("now" if rest else "now, with the repo text"))
        if rest:
            failures += patch(loc, row["id"], rest)

    # ── 3. verify by reading back ─────────────────────────────────────────────
    print("\nVERIFY (read back)")
    after = version_locs(asc, ver["id"])
    en_after = after.get(listing.PRIMARY_LOCALE, {}).get("attributes", {})
    for loc in locales:
        got_attrs = after.get(loc, {}).get("attributes", {})
        for f in VERSION_FIELDS:
            want = listing.load_field(f.attribute, loc, plat)
            got = norm(got_attrs.get(f.attribute))
            if got != want:
                print(f"  MISMATCH [{loc}] {f.attribute}: store {len(got)} chars, repo {len(want)}")
                failures += 1
        if not norm(got_attrs.get("supportUrl")):
            print(f"  MISMATCH [{loc}] supportUrl: none; App Store Connect will not submit the "
                  "version until every localization has one"
                  + ("" if norm(en_after.get("supportUrl")) else " (en-US has none to copy)"))
            failures += 1
        if norm(en_after.get("marketingUrl")) and not norm(got_attrs.get("marketingUrl")):
            print(f"  MISMATCH [{loc}] marketingUrl: none, en-US has one")
            failures += 1
    if editable_info is not None:
        after_info = appinfo_locs(asc, editable_info["id"])
        for loc in locales:
            want = listing.load_field("subtitle", loc)
            got = norm(after_info.get(loc, {}).get("attributes", {}).get("subtitle"))
            if got != want:
                print(f"  MISMATCH [{loc}] subtitle: store {got!r}, repo {want!r}")
                failures += 1
    missing_whatsnew = [loc for loc in locales
                        if not norm(after.get(loc, {}).get("attributes", {}).get("whatsNew"))]
    if missing_whatsnew:
        print(f"  note: no What's New yet on {', '.join(missing_whatsnew)} — set it with "
              "scripts/asc_submit.py --whatsnew-dir before submitting an update.")
    if failures:
        print(f"\nAPPLY INCOMPLETE: {failures} problem(s) above: a write that failed or did "
              "not stick, or a localization with no support URL.")
        return 1
    print("\nAPPLY OK: the store now holds the repo text for every selected locale.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

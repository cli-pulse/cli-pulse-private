#!/usr/bin/env python3
"""App Store Connect: create a version, set its What's New in every locale,
attach an uploaded build and submit it for review — one platform (IOS or
MAC_OS) per run.

DEFAULT IS A DRY RUN. Without --apply every request is a GET: the run shows the
version, the build and, per locale, which What's New file would be written and
how long it is, and it exits non-zero on anything that would stop the real run.
--apply performs the writes.

Promoted from the throwaway /tmp/asc_lib.py + /tmp/asc_submit.py pattern into a
committed, parameterized tool (DEV_PLAN_2026-07-02 §S6). Self-contained: no
/tmp side-files.

PREREQ (per [[feedback_asc_icloud_key_tcc]]): the ASC API .p8 key must live at
  ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
NOT on iCloud Drive — a headless/background process is TCC-denied there. The
KEY_ID / ISSUER / APP_ID below are identifiers, not secrets; only the .p8 is.

The build must already be UPLOADED and finished processing (processingState=
VALID). iOS processing can lag ~1 h after `build-appstore.sh … --upload`; poll
`--list-builds ios` until the target build shows VALID before submitting.

Usage:
  # list processed builds for a platform (find the build id to submit):
  python3 scripts/asc_submit.py --list-builds ios
  python3 scripts/asc_submit.py --list-builds macos

  # create the version row, and nothing else (the listing push needs it):
  python3 scripts/asc_submit.py --create-version ios --version 1.54.0            # dry run
  python3 scripts/asc_submit.py --create-version ios --version 1.54.0 --apply

  # What's New + App Review notes + build + review submission:
  python3 scripts/asc_submit.py --submit ios   --build <BUILD_ID> --version 1.54.0 \
      --whatsnew-dir whatsnew_154 --review-notes <notes-ios.txt>
  python3 scripts/asc_submit.py --submit macos --build <BUILD_ID> --version 1.54.0 \
      --whatsnew-dir whatsnew_154 --review-notes <notes-macos.txt>
  (the same with --apply writes and submits)

The release order around this script is in AGENTS.md ("Releasing a version to
the App Store").

WHAT'S NEW
----------
--whatsnew-dir holds <locale>.txt (iOS) and macos-<locale>.txt (macOS), one per
App Store locale. Which file a locale gets on which platform, and every check on
the texts, is scripts/appstore_listing.py (load_whatsnew); this script writes
what that returns and nothing else. In short: the Mac reads macos-<locale>.txt,
and reads <locale>.txt only from a directory that has no macOS texts at all.

--submit refuses, exit 1 with NOTHING written, when:
  * the directory fails the checks: a locale without its file, a text over 4000
    characters, another platform named (Guideline 2.3.10), a feature only the
    direct-download Mac build has in a macOS text, English left in a
    translation, es-ES and es-MX differing;
  * the version does not exist, or is not editable;
  * any localization of the version has no text for this platform;
  * a locale the repo has a listing for is not on the version (the listing
    push has not run), unless --allow-missing-locales;
  * the build is not VALID, or belongs to another platform or version;
  * the App Review notes read as an older version's (below), or the version
    has no App Review details at all.
Then, with --apply: the review notes are written if --review-notes differs from
the store and read back, What's New is written only where it differs and read
back, and only if both hold is the build attached and the version submitted.

APP REVIEW NOTES
----------------
App Store Connect gives a new version the previous version's App Review
details, notes included, word for word. 1.54.0 got 1.53.0's, which told the
reviewer that "THE MAIN FEATURE IN 1.53.0" needs a second device and listed
1.53.0's fixes; nothing in the release path looked at them. So --submit prints
the notes the version holds now (the contact and demo-account fields are never
printed and never written), and refuses, before any write, notes that name an
older version of this app as if it were the one under review:
  * notes that name an older version and never this one (the copied set); or
  * a mention of an older version that is neither compared with this one
    ("since 1.53.0", "unchanged from 1.53.0", "added in 1.53.0 and unchanged in
    1.54.0", "was removed in 1.52.1") nor about another product ("Guideline
    1.4.1", "iOS 17.0"): "THE MAIN FEATURE IN 1.53.0", "this 1.53.0 build".
It is a tripwire for the copied-notes case, not a reading of the prose.
--review-notes FILE replaces the notes with FILE (the same check applies to it;
at most 4000 characters), and --apply PATCHes only `notes` and reads back that
the notes equal FILE and every other field is unchanged. --accept-review-notes
submits notes the check flags, for when the mention is deliberate.

RELEASE TYPE
------------
--create-version makes the version MANUAL unless --release-type AFTER_APPROVAL
is given. MANUAL is the default on purpose: a forgotten flag leaves a version
waiting for the owner after approval, which one click in App Store Connect
fixes, while a wrong AFTER_APPROVAL publishes the moment Apple approves. The
releases themselves pass AFTER_APPROVAL (1.53.0, 1.54.0; AGENTS.md says why).
Both --create-version and --submit print the releaseType the version actually
has, and --create-version warns when an existing version's differs from the
one asked for. This script never changes it.

--whatsnew (one fallback file for any locale the directory did not cover) is
retired. That fallback is how English notes once landed on every storefront
(v1.41), and with the listing in seven locales it would put one language's
notes under another's listing. A store locale the repo does not translate is a
decision (translate it, or remove the locale), not something to paper over.

Exit 0 = dry run clean / submitted. 1 = refused, or a write that failed.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import appstore_listing as listing  # noqa: E402
from asc_push_listing import EDITABLE_STATES, version_state  # noqa: E402

# Imported when App Store Connect is actually contacted (_deps), so the tests
# run on a bare python3 with a stand-in for `requests`.
jwt = None
requests = None

KEY_ID = "DMMFP6XTXX"
ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
APP_ID = "6761163709"
BASE = "https://api.appstoreconnect.apple.com/v1"

# Platform tokens the ASC API expects.
PLATFORMS = {"ios": "IOS", "macos": "MAC_OS"}

RELEASE_TYPE_MEANING = {
    "MANUAL": "after approval it waits until the owner releases it in App Store Connect",
    "AFTER_APPROVAL": "App Store Connect releases it as soon as Apple approves it",
    "SCHEDULED": "App Store Connect releases it on its scheduled date once approved",
}

# ── App Review notes (APP REVIEW NOTES in the docstring) ─────────────────────
REVIEW_NOTES_LIMIT = 4000   # App Store Connect's limit for appStoreReviewDetails.notes
# A version number as written in prose: 1.53.0, or v1.53 / v1.53.0. Not part of
# a longer dotted number, not glued to a word, not a price. A bare two-part
# number ("a 1.5 GB download") is not taken for a version: this app's versions
# are always written with three parts.
_VERSION_MENTION = re.compile(
    r"(?<![\w.$€£¥])(?:(v)(\d+)\.(\d+)(?:\.(\d+))?|(\d+)\.(\d+)\.(\d+))(?!\w|\.\d)")
# ...that belongs to something else when the word before it is one of these.
_OTHER_PRODUCT = re.compile(
    r"\b(?:guidelines?|section|rule|ios|ipados|macos|watchos|visionos|tvos|xcode|swift|"
    r"sdk|python|os)\s+"
    r"(?:v?[\d.]+\s*(?:,|and|or|&)\s*)*$",      # ...or a later item of its list: "Guidelines 2.1 and 1.4.1"
    re.IGNORECASE)
# "this 1.53.0 build" presents the older version as the one under review.
_PRESENTED_AS_CURRENT = re.compile(r"\b(?:this|the current|current)\s+$", re.IGNORECASE)
# Words that make a mention a comparison with the past rather than a claim:
# "since 1.53.0", "unchanged from 1.52.1", "exactly as in 1.52.1".
_COMPARISON = re.compile(
    r"\b(?:since|from|than|before|prior to|previous(?:ly)?|earlier|unchanged|until|"
    r"as in|as of|compared (?:to|with)|vs\.?|versus|over)\s+(?:\S+\s+){0,2}$", re.IGNORECASE)
# ...and history in the passive: "was removed in 1.52.1", "were added in 1.53.0".
_HISTORY = re.compile(r"\b(?:was|were|been)\s+(?:\w+\s+){1,3}(?:in|since)\s+$", re.IGNORECASE)
_SENTENCE_BREAK = re.compile(r"(?<=[.!?])\s+|\n+")


def _version_tuple(text: str) -> tuple[int, int, int] | None:
    m = re.fullmatch(r"v?(\d+)\.(\d+)(?:\.(\d+))?", text.strip())
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)) if m else None


def review_notes_problems(notes: str, version: str) -> list[str]:
    """Reasons to believe `notes` were written for an older version of the app
    than `version` (see APP REVIEW NOTES). Empty = nothing flagged."""
    target = _version_tuple(version)
    if target is None or not notes.strip():
        return []
    older: list[str] = []           # every older version named, in order
    claims: list[tuple[str, str]] = []
    names_target = False
    for sentence in _SENTENCE_BREAK.split(notes):
        mentions = []
        for m in _VERSION_MENTION.finditer(sentence):
            parts = m.group(2, 3, 4) if m.group(1) else m.group(5, 6, 7)
            v = (int(parts[0]), int(parts[1]), int(parts[2] or 0))
            if _OTHER_PRODUCT.search(sentence[:m.start()]) or v[0] != target[0]:
                continue
            mentions.append((m, v))
        sentence_names_target = any(v == target for _, v in mentions)
        names_target |= sentence_names_target
        for m, v in mentions:
            if v >= target:
                continue
            shown = m.group(0).lstrip("v")
            if shown not in older:
                older.append(shown)
            before = sentence[:m.start()]
            if _PRESENTED_AS_CURRENT.search(before):
                claims.append((shown, sentence))
            elif sentence_names_target or _COMPARISON.search(before) or _HISTORY.search(before):
                continue
            else:
                claims.append((shown, sentence))
    problems = []
    if older and not names_target:
        problems.append(f"the notes name {', '.join(older)} and never {version}: they read as "
                        "an earlier version's notes, which App Store Connect copies onto every "
                        "new version")
    for shown, sentence in claims:
        s = " ".join(sentence.split())
        problems.append(f"presents {shown} as the version under review: "
                        f"{s[:140] + ('...' if len(s) > 140 else '')!r}")
    return problems


def review_notes_file_problems(text: str, path: Path) -> list[str]:
    if not text:
        return [f"{path}: empty"]
    if len(text) > REVIEW_NOTES_LIMIT:
        return [f"{path}: {len(text)} characters, over App Store Connect's limit of "
                f"{REVIEW_NOTES_LIMIT} for App Review notes"]
    return []


def _deps() -> None:
    global jwt, requests
    if jwt is not None and requests is not None:
        return
    try:
        import jwt as _jwt  # noqa: PLC0415 - PyJWT
        import requests as _requests  # noqa: PLC0415
    except ImportError:
        sys.exit("pip install pyjwt requests  (needed for the ASC API)")
    jwt, requests = _jwt, _requests


def _key_path() -> str:
    candidates = [
        os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"),
        # legacy fallback — TCC-denied headless, but allow interactive runs.
        os.path.expanduser(
            f"~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_{KEY_ID}.p8"
        ),
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    sys.exit(
        f"ASC key not found. Place AuthKey_{KEY_ID}.p8 at "
        f"~/.appstoreconnect/private_keys/ (NOT iCloud — TCC-denied headless)."
    )


def _token() -> str:
    _deps()
    key = open(_key_path()).read()
    return jwt.encode(
        {"iss": ISSUER, "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def _headers() -> dict[str, str]:
    return {"Authorization": "Bearer " + _token(), "Content-Type": "application/json"}


# The ASC API is routinely slower than 30s, and a read timeout mid-submit is
# the worst possible failure here: `submit()` PATCHes whatsNew per locale, then
# attaches the build, then submits. A timeout between those steps leaves a
# half-configured version in App Store Connect that the next run has to
# reconcile.
#
# Measured 2026-08-27 submitting 1.51.0: two consecutive runs died on
# `read timeout=30` — the first on the very first GET, the second after
# creating the version and setting en-US but before zh-Hans. The What's New
# writes are idempotent (overwrite, and skipped when already equal), so
# re-running is safe; it just should not have needed three attempts.
_TIMEOUT = 120
_RETRIES = 3


def _with_retry(fn, what: str):
    """Retry only on transport timeouts. An HTTP error response is returned to
    the caller untouched — those are the caller's business, and retrying a 4xx
    would just repeat a rejected write."""
    _deps()
    last = None
    for attempt in range(1, _RETRIES + 1):
        try:
            return fn()
        except (requests.Timeout, requests.ConnectionError) as exc:
            last = exc
            print(f"  ASC {what}: {type(exc).__name__} "
                  f"(attempt {attempt}/{_RETRIES})", file=sys.stderr)
            if attempt < _RETRIES:
                time.sleep(5 * attempt)
    raise last


def _get_response(path: str):
    return _with_retry(
        lambda: requests.get(BASE + path, headers=_headers(), timeout=_TIMEOUT),
        f"GET {path}",
    )


def _get(path: str) -> dict:
    r = _get_response(path)
    if r.status_code >= 300:
        # Fail LOUDLY — a silent {} here made --list-builds print nothing and
        # exit 0 on auth/API failures (2026-07-03 review).
        sys.exit(f"ASC GET {path} failed {r.status_code}: {r.text[:400]}")
    return r.json()


def _post(path: str, body: dict):
    return _with_retry(
        lambda: requests.post(BASE + path, headers=_headers(), json=body,
                              timeout=_TIMEOUT),
        f"POST {path}",
    )


def _patch(path: str, body: dict):
    return _with_retry(
        lambda: requests.patch(BASE + path, headers=_headers(), json=body,
                               timeout=_TIMEOUT),
        f"PATCH {path}",
    )


def list_builds(platform_key: str) -> None:
    plat = PLATFORMS[platform_key]
    r = _get(
        f"/builds?filter[app]={APP_ID}&filter[preReleaseVersion.platform]={plat}"
        f"&sort=-uploadedDate&limit=10"
        f"&fields[builds]=version,processingState,uploadedDate"
    )
    for b in r.get("data", []):
        a = b.get("attributes", {})
        print(f"{b['id']}  build {a.get('version')}  {a.get('processingState')}  {a.get('uploadedDate')}")


def find_version(plat: str, version: str) -> dict | None:
    r = _get(
        f"/apps/{APP_ID}/appStoreVersions"
        f"?filter[platform]={plat}&filter[versionString]={version}"
    )
    vs = r.get("data", [])
    return vs[0] if vs else None


def create_version(platform_key: str, version: str, apply: bool,
                   release_type: str = "MANUAL") -> bool:
    """Find-or-create the appStoreVersion row, and nothing else.

    releaseType defaults MANUAL, and releases pass AFTER_APPROVAL: RELEASE TYPE
    in the module docstring. App Store Connect gives a new version the
    localizations of the previous one; the ones the repo adds come from
    asc_push_listing.py."""
    plat = PLATFORMS[platform_key]
    ver = find_version(plat, version)
    if ver:
        has = ver["attributes"].get("releaseType") or "UNKNOWN"
        print(f"[{plat}] version {version} exists: {ver['id']} "
              f"state={version_state(ver['attributes'])} releaseType={has} — nothing to create")
        if has != release_type:
            print(f"  WARN  it is {has}, not the {release_type} asked for: "
                  f"{RELEASE_TYPE_MEANING.get(has, 'App Store Connect did not say')}. This "
                  "script does not change it; do that in App Store Connect if it is wrong.")
        return True
    if not apply:
        print(f"[{plat}] DRY RUN — version {version} does not exist; --apply would create it "
              f"(releaseType={release_type}). Nothing was written.")
        return True
    cr = _post(
        "/appStoreVersions",
        {"data": {"type": "appStoreVersions",
                  "attributes": {"platform": plat, "versionString": version,
                                 "releaseType": release_type},
                  "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}},
    )
    if cr.status_code >= 300:
        # A retried POST whose first attempt landed gets 409: look before failing.
        again = find_version(plat, version)
        if again:
            print(f"[{plat}] version {version} exists: {again['id']} (the create landed)")
            return True
        print(f"[{plat}] CREATE version FAILED {cr.status_code}: {cr.text[:400]}")
        return False
    print(f"[{plat}] created version {cr.json()['data']['id']} (releaseType={release_type})")
    return True


def _check_build(plat: str, build_id: str, version: str) -> tuple[str, list[str]]:
    """(description, problems) for the build about to be attached."""
    r = _get_response(f"/builds/{build_id}?include=preReleaseVersion")
    if r.status_code == 404:
        return "", [f"build {build_id} does not exist (--list-builds shows the ids)"]
    if r.status_code >= 300:
        sys.exit(f"ASC GET /builds/{build_id} failed {r.status_code}: {r.text[:400]}")
    body = r.json()
    attrs = body.get("data", {}).get("attributes", {})
    state = attrs.get("processingState")
    pre = next((x.get("attributes", {}) for x in body.get("included", [])
                if x.get("type") == "preReleaseVersions"), {})
    desc = (f"build {build_id}: {pre.get('version', '?')} ({attrs.get('version', '?')}), "
            f"{pre.get('platform', '?')}, {state}")
    problems = []
    if state != "VALID":
        problems.append(f"build {build_id} is {state}, not VALID: still processing, or rejected")
    # A build whose platform or version the store did not report cannot be
    # checked, so it is refused rather than attached on trust.
    if not pre.get("platform") or not pre.get("version"):
        problems.append(f"build {build_id}: App Store Connect did not say which platform and "
                        "version it belongs to (no preReleaseVersion), so it cannot be checked")
    if pre.get("platform") and pre["platform"] != plat:
        problems.append(f"build {build_id} belongs to {pre['platform']}, not {plat}")
    if pre.get("version") and pre["version"] != version:
        problems.append(f"build {build_id} is version {pre['version']}, not {version}")
    return desc, problems


def _review_detail(ver_id: str) -> dict | None:
    """The version's appStoreReviewDetail ({id, attributes}), or None if it has none."""
    r = _get_response(f"/appStoreVersions/{ver_id}/appStoreReviewDetail")
    if r.status_code == 404:
        return None
    if r.status_code >= 300:
        sys.exit(f"ASC GET /appStoreVersions/{ver_id}/appStoreReviewDetail failed "
                 f"{r.status_code}: {r.text[:400]}")
    return r.json().get("data") or None


def _print_notes(notes: str) -> None:
    if not notes:
        print("    | (empty)")
    for line in notes.splitlines():
        print(f"    | {line}")


def notes_file_problems(path: Path, version: str, accept: bool
                        ) -> tuple[str | None, list[str]]:
    """(text, problems) for --review-notes FILE, before the store is contacted."""
    if not path.is_file():
        return None, [f"--review-notes {path}: no such file"]
    text = listing.read_text(path)
    problems = review_notes_file_problems(text, path)
    flagged = review_notes_problems(text, version)
    for p in flagged:
        if accept:
            print(f"  WARN  {path}: {p} (--accept-review-notes)")
        else:
            problems.append(f"{path}: {p}")
    if flagged and not accept:
        problems.append(f"fix {path}, or pass --accept-review-notes if the mention is deliberate")
    return text, problems


def plan_review_notes(plat: str, ver_id: str, version: str, new_text: str | None,
                      source: str | None, accept: bool
                      ) -> tuple[dict | None, str | None, list[str]]:
    """(review detail, the notes to write or None, refusals). Prints the notes
    the version holds now: the dry run is where they get read. `new_text` is
    --review-notes' text, already checked by notes_file_problems()."""
    detail = _review_detail(ver_id)
    if detail is None:
        return None, None, [f"version {version} has no App Review details (contact, notes). "
                            "App Store Connect copies them from the previous version, and this "
                            "one has none: fill them in App Store Connect first"]
    current = (detail["attributes"].get("notes") or "").strip()
    print(f"[{plat}] App Review notes on the version now ({len(current)} chars; the contact and "
          "demo-account fields are not shown and never written):")
    _print_notes(current)
    if new_text is not None:
        if new_text == current:
            print(f"  ok    --review-notes {source}: the version already holds it, nothing to write")
            return detail, None, []
        print(f"  ok    --review-notes {source} ({len(new_text)} chars) replaces them")
        return detail, new_text, []
    refusals: list[str] = []
    flagged = review_notes_problems(current, version)
    for p in flagged:
        if accept:
            print(f"  WARN  the notes on the version: {p} (--accept-review-notes)")
        else:
            print(f"  FAIL  the notes on the version: {p}")
            refusals.append(f"the App Review notes on the version: {p}")
    if flagged and not accept:
        refusals.append(f"pass --review-notes <file> with notes written for {version}, or "
                        "--accept-review-notes if the version's notes are right as they are")
    elif not flagged:
        print("  ok    the notes name no older version as the one under review")
    return detail, None, refusals


def write_review_notes(plat: str, ver_id: str, detail: dict, text: str) -> bool:
    """PATCH `notes` only, then read back: the notes must equal `text` and every
    other field (contact, demo account) must be what it was."""
    rid = detail["id"]
    before = dict(detail["attributes"])
    pr = _patch(f"/appStoreReviewDetails/{rid}",
                {"data": {"type": "appStoreReviewDetails", "id": rid,
                          "attributes": {"notes": text}}})
    print(f"[{plat}] review notes <- {len(text)} chars: {pr.status_code}")
    if pr.status_code >= 300:
        print(f"[{plat}] STOPPED — the review notes were refused: {pr.text[:300]}. The build "
              "was not attached and nothing was submitted.")
        return False
    back = _review_detail(ver_id)
    after = dict((back or {}).get("attributes") or {})
    got = (after.get("notes") or "").strip()
    changed = sorted(k for k in set(before) | set(after)
                     if k != "notes" and before.get(k) != after.get(k))
    if got != text or changed or (back or {}).get("id") != rid:
        why = []
        if got != text:
            why.append(f"the notes read back are not the file ({len(got)} vs {len(text)} chars)")
        if changed:
            why.append("these fields changed although only notes was sent: " + ", ".join(changed))
        if (back or {}).get("id") != rid:
            why.append("the version's review detail is no longer the one written")
        print(f"[{plat}] STOPPED — " + "; ".join(why) + ". Not attaching, not submitting.")
        return False
    print(f"[{plat}] review notes verified; the other review fields are unchanged")
    return True


def submit(platform_key: str, build_id: str, version: str, whatsnew_dir: Path,
           apply: bool = False, allow_missing_locales: bool = False,
           review_notes: Path | None = None, accept_review_notes: bool = False) -> bool:
    plat = PLATFORMS[platform_key]
    label = listing.PLATFORM_LABEL[plat]

    # 1. The repo texts, before App Store Connect is contacted.
    texts, problems = listing.load_whatsnew(whatsnew_dir, plat)
    if problems:
        print(f"[{plat}] REFUSED — {whatsnew_dir}/ is not ready for {label}:")
        for p in problems:
            print(f"  FAIL  {p}")
        print("Nothing was written. (python3 scripts/asc_listing_preflight.py "
              f"--whatsnew-dir {whatsnew_dir} checks both platforms.)")
        return False
    notes_text = None
    if review_notes is not None:
        notes_text, problems = notes_file_problems(review_notes, version, accept_review_notes)
        if problems:
            print(f"[{plat}] REFUSED — the App Review notes in --review-notes are not ready:")
            for p in problems:
                print(f"  FAIL  {p}")
            print("Nothing was written.")
            return False

    # 2. Everything the writes depend on, read before the first write.
    refusals: list[str] = []
    ver = find_version(plat, version)
    if not ver:
        print(f"[{plat}] REFUSED — no version {version}. Create it first: "
              f"--create-version {platform_key} --version {version} --apply, then push the "
              "listing (asc_push_listing.py). Nothing was written.")
        return False
    ver_id = ver["id"]
    state = version_state(ver["attributes"])
    release_type = ver["attributes"].get("releaseType") or "UNKNOWN"
    print(f"[{plat}] version {version}  id={ver_id}  state={state}  releaseType={release_type}"
          f" ({RELEASE_TYPE_MEANING.get(release_type, 'App Store Connect did not say')})")
    if state not in EDITABLE_STATES:
        refusals.append(f"version {version} is {state}; What's New can only be set while it is "
                        f"one of {', '.join(sorted(EDITABLE_STATES))}")

    locs = _get(f"/appStoreVersions/{ver_id}/appStoreVersionLocalizations").get("data", [])
    store_locales = [loc["attributes"]["locale"] for loc in locs]
    plan: list[tuple[str, str, str, str]] = []   # (localization id, locale, file, text)
    print(f"[{plat}] What's New from {whatsnew_dir}/:")
    for loc in sorted(locs, key=lambda x: x["attributes"]["locale"]):
        locale = loc["attributes"]["locale"]
        current = (loc["attributes"].get("whatsNew") or "").strip()
        wn = texts.get(locale)
        if wn is None:
            print(f"  FAIL  {locale:7} no text for {label}")
            refusals.append(f"the version has a {locale} localization and {whatsnew_dir}/ has no "
                            f"{label} text for it; add it (and to LOCALE_SOURCES if it is a new "
                            "store language), or remove the locale in App Store Connect")
            continue
        change = "unchanged" if current == wn.text else f"store has {len(current)}, will change"
        print(f"  ok    {locale:7} {wn.file:18} {len(wn.text):5} chars  ({change})")
        plan.append((loc["id"], locale, wn.file, wn.text))
    missing = [loc for loc in listing.LOCALE_SOURCES if loc not in store_locales]
    if missing:
        msg = (f"the version has no {', '.join(missing)} localization: the listing for "
               f"{'it' if len(missing) == 1 else 'them'} was not pushed "
               "(asc_push_listing.py --apply), so those storefronts would get no What's New")
        if allow_missing_locales:
            print(f"  WARN  {msg} (--allow-missing-locales)")
        else:
            refusals.append(msg + "; push the listing first, or pass --allow-missing-locales")

    detail, notes_plan, notes_refusals = plan_review_notes(
        plat, ver_id, version, notes_text, review_notes, accept_review_notes)
    refusals += notes_refusals

    desc, build_problems = _check_build(plat, build_id, version)
    if desc:
        print(f"[{plat}] {desc}")
    refusals += build_problems

    if refusals:
        print(f"[{plat}] REFUSED:")
        for r in refusals:
            print(f"  FAIL  {r}")
        print("Nothing was written.")
        return False
    if not apply:
        notes_step = (f"replace the App Review notes with {review_notes}, "
                      if notes_plan is not None else "")
        print(f"[{plat}] DRY RUN OK — nothing was written. --apply would {notes_step}set What's "
              f"New on {len(plan)} locale(s), attach the build and submit {version} for review.")
        return True

    # 3. The App Review notes, if --review-notes differs from the store; read back.
    if notes_plan is not None and not write_review_notes(plat, ver_id, detail, notes_plan):
        return False

    # 4. What's New, only where it differs; then read it all back.
    for lid, locale, fname, text in plan:
        current = next((x["attributes"].get("whatsNew") or "").strip()
                       for x in locs if x["id"] == lid)
        if current == text:
            continue
        pr = _patch(
            f"/appStoreVersionLocalizations/{lid}",
            {"data": {"type": "appStoreVersionLocalizations", "id": lid,
                      "attributes": {"whatsNew": text}}},
        )
        print(f"[{plat}] whatsNew {locale} <- {fname}: {pr.status_code}")
        if pr.status_code >= 300:
            print(f"[{plat}] STOPPED — {locale} was refused: {pr.text[:300]}. The build was not "
                  "attached and nothing was submitted; fix and re-run.")
            return False
    back = {x["attributes"]["locale"]: (x["attributes"].get("whatsNew") or "").strip()
            for x in _get(f"/appStoreVersions/{ver_id}/appStoreVersionLocalizations")
            .get("data", [])}
    wrong = [locale for _, locale, _, text in plan if back.get(locale) != text]
    if wrong:
        print(f"[{plat}] STOPPED — the store does not hold the repo text for "
              f"{', '.join(wrong)} after writing it. Not attaching, not submitting.")
        return False
    print(f"[{plat}] What's New verified on {len(plan)} locale(s)")

    # 5. attach the processed build.
    br = _patch(
        f"/appStoreVersions/{ver_id}/relationships/build",
        {"data": {"type": "builds", "id": build_id}},
    )
    print(f"[{plat}] attach build: {br.status_code} {'' if br.status_code < 300 else br.text[:300]}")
    if br.status_code >= 300:
        return False

    # 6. create a reviewSubmission, add the version as an item, submit.
    sr = _post(
        "/reviewSubmissions",
        {"data": {"type": "reviewSubmissions", "attributes": {"platform": plat},
                  "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}},
    )
    if sr.status_code >= 300:
        print(f"[{plat}] reviewSubmission FAILED {sr.status_code}: {sr.text[:400]}")
        return False
    sub_id = sr.json()["data"]["id"]
    ir = _post(
        "/reviewSubmissionItems",
        {"data": {"type": "reviewSubmissionItems",
                  "relationships": {
                      "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                      "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}}}}},
    )
    print(f"[{plat}] add item: {ir.status_code} {'' if ir.status_code < 300 else ir.text[:300]}")
    if ir.status_code >= 300:
        # ASC allows only ONE open reviewSubmission per platform — a dangling
        # empty one would block every retry. Cancel it before bailing
        # (2026-07-03 review).
        cr2 = _patch(
            f"/reviewSubmissions/{sub_id}",
            {"data": {"type": "reviewSubmissions", "id": sub_id,
                      "attributes": {"canceled": True}}},
        )
        print(f"[{plat}] add-item failed — canceled dangling submission {sub_id}: {cr2.status_code}")
        return False
    fr = _patch(
        f"/reviewSubmissions/{sub_id}",
        {"data": {"type": "reviewSubmissions", "id": sub_id, "attributes": {"submitted": True}}},
    )
    ok = fr.status_code < 300
    print(f"[{plat}] SUBMIT: {fr.status_code} {'OK — submitted for review' if ok else fr.text[:400]}")
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description="ASC version, What's New, attach build, submit")
    ap.add_argument("--list-builds", choices=PLATFORMS.keys(), help="list recent builds for a platform")
    ap.add_argument("--create-version", choices=PLATFORMS.keys(),
                    help="find-or-create the version row for a platform, nothing else")
    ap.add_argument("--submit", choices=PLATFORMS.keys(), help="submit a build for review")
    ap.add_argument("--build", help="build id (from --list-builds)")
    # No default on purpose: a hardcoded default silently attaches the next
    # train's build to the WRONG version row (2026-07-03 review).
    ap.add_argument("--version", help="marketing version string, e.g. 1.54.0")
    ap.add_argument("--whatsnew-dir", type=Path,
                    help="release notes directory: <locale>.txt for iOS, macos-<locale>.txt "
                         "for macOS, one per App Store locale (see scripts/appstore_listing.py)")
    ap.add_argument("--whatsnew", help=argparse.SUPPRESS)   # retired; refused below
    ap.add_argument("--allow-missing-locales", action="store_true",
                    help="submit although the version lacks locales the repo has a listing for")
    ap.add_argument("--apply", action="store_true",
                    help="write (default is a dry run: GETs only, nothing written)")
    ap.add_argument("--review-notes", type=Path,
                    help="for --submit: a file with this version's App Review notes; --apply "
                         "writes it (notes only) and reads it back before submitting")
    ap.add_argument("--accept-review-notes", action="store_true",
                    help="for --submit: submit although the review notes name an older version "
                         "as the one under review (after reading them in the dry run)")
    ap.add_argument("--release-type", choices=["MANUAL", "AFTER_APPROVAL"], default="MANUAL",
                    help="for --create-version. MANUAL (default, so a forgotten flag fails safe): "
                         "the owner releases it in App Store Connect after approval. "
                         "AFTER_APPROVAL: released as soon as Apple approves it, which is what "
                         "releases use (AGENTS.md)")
    args = ap.parse_args()

    if args.whatsnew:
        ap.error("--whatsnew is retired: one fallback text for every locale put English notes "
                 "on every storefront. Pass --whatsnew-dir with a <locale>.txt (iOS) and "
                 "macos-<locale>.txt (macOS) per App Store locale.")
    if (args.review_notes or args.accept_review_notes) and not args.submit:
        ap.error("--review-notes and --accept-review-notes go with --submit")
    if args.list_builds:
        list_builds(args.list_builds)
        return 0
    if args.create_version:
        if not args.version:
            ap.error("--create-version requires --version <X.Y.Z>")
        return 0 if create_version(args.create_version, args.version, args.apply,
                                   args.release_type) else 1
    if args.submit:
        if not args.build:
            ap.error("--submit requires --build <BUILD_ID>")
        if not args.version:
            ap.error("--submit requires --version <X.Y.Z>")
        if not args.whatsnew_dir:
            ap.error("--submit requires --whatsnew-dir <dir>")
        return 0 if submit(args.submit, args.build, args.version, args.whatsnew_dir,
                           apply=args.apply,
                           allow_missing_locales=args.allow_missing_locales,
                           review_notes=args.review_notes,
                           accept_review_notes=args.accept_review_notes) else 1
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Release preflight: does the STORE agree with the repo, and with itself?

WHY THIS EXISTS
---------------
`scripts/check_paywall_claims.sh` guards the *sources*: the paywall bullets, the
screenshot caption table, and the description text in `appstore_metadata.py` /
`resubmit.py`. It is green, and it has been green while the App Store served
something else entirely — because a source fix is not a delivery.

Three times now, the same shape:

  2026-08-28  caption source fixed in v1.51; the PNG was never regenerated or
              re-uploaded, so 1.52.0 shipped screenshots selling Team and
              Lifetime — the two tiers that version withdrew.
  2026-08-30  PR #484 re-shot the paywall screenshot. Still not uploaded.
  2026-08-31  description source fixed in v1.52.1 (no Team, no hardcoded
              prices) — and the LIVE macOS description still reads
              "CLI Pulse Team is available as a monthly ($9.99/month) or
              yearly ($99.99/year) auto-renewable subscription", while both
              Team SKUs are DEVELOPER_REMOVED_FROM_SALE in App Store Connect.
              (iOS's description had been updated; macOS's had not.)

A guard that reads the repo cannot see any of that. This one reads App Store
Connect, so its subject is the thing customers actually see.

It cannot run in CI — CI has no ASC key. It is a **release-time preflight**, run
from the owner's machine before submitting a build.

CHECKS
------
1. SKU-vs-copy      the description must not name a tier whose SKU is not
                    purchasable (state != APPROVED). This needs no repo source
                    at all: it compares the store's words to the store's own
                    product catalogue, so it is true by construction.
2. Listing drift     every live localization's description, keywords,
                    promotional text and subtitle must match the repo text
                    for that locale (CLI Pulse Bar/appstore/<locale>/), and
                    every locale the repo carries must exist on the store.
3. Screenshot drift  every live screenshot must match the local composed PNG
                    of the same name (decoded pixels; ASC re-encodes). The
                    iPhone set per locale, against that locale's language
                    (scripts/appstore_screenshots.py); Mac and iPad on en-US.
                    Catches "regenerated but never uploaded", which is the
                    case that keeps recurring.

4. iPhone panels    with --require-shots only: every locale with listing texts
                    has its five composed iPhone screenshots, each one App
                    Store Connect would accept (scripts/appstore_screenshots.py),
                    or deliberately falls back to en-US's. Repo-only; CI runs
                    it together with --texts-only.

Before any of that it validates the repo texts themselves — the part that needs
no key, and so also runs in CI (repo-hygiene.yml) as `--texts-only`:

0. Repo texts        for every locale directory: all four files present and
                    non-empty, App Store Connect's length limits, keyword
                    format, no Guideline 2.3.10 platform names, no leftover
                    English in a translated text, and no pusher carrying an
                    inline copy of any of it. See scripts/appstore_listing.py.
                    Negative controls: scripts/test_asc_listing_preflight.sh.
   What's New       with --whatsnew-dir DIR, first, and a failure ends the run:
                    every store locale has its iOS <locale>.txt and macOS
                    macos-<locale>.txt (or one shared <locale>.txt when the
                    directory has no macOS texts), non-empty and within 4000
                    characters, no other platform named in any language, no
                    English left in a translation, nothing only the
                    direct-download Mac build has in a macOS text, the zh-Hant
                    terms, and es-ES equal to es-MX. Repo-only, no key; the
                    same checks asc_submit.py runs before its first write.

READ-ONLY. Every request is a GET. This script never mutates App Store Connect;
pushing is scripts/asc_push_listing.py, and a deliberate, owner-driven action.

Usage:
    python3 scripts/asc_listing_preflight.py --texts-only    # repo texts only, no key
    python3 scripts/asc_listing_preflight.py --texts-only --require-shots   # + iPhone panels (CI)
    python3 scripts/asc_listing_preflight.py                 # all platforms, live versions
    python3 scripts/asc_listing_preflight.py --platform MAC_OS
    python3 scripts/asc_listing_preflight.py --version 1.54.0  # the version being prepared
    python3 scripts/asc_listing_preflight.py --texts-only --whatsnew-dir whatsnew_154
Exit 0 = the store agrees with itself and with the repo. 1 = drift, or invalid
repo texts. 2 = could not check (missing key/网络), which is NOT a pass.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import appstore_listing as listing  # noqa: E402
import appstore_screenshots as shots  # noqa: E402

# jwt/requests are imported only when App Store Connect is actually contacted,
# so `--texts-only` runs on a bare CI runner.
jwt = None
requests = None


def _load_http_deps() -> None:
    global jwt, requests
    try:
        import jwt as _jwt  # noqa: PLC0415
        import requests as _requests  # noqa: PLC0415
    except ImportError as exc:  # pragma: no cover - environment problem, not drift
        print(f"FATAL: missing dependency ({exc}). pip install pyjwt requests", file=sys.stderr)
        raise SystemExit(2)
    jwt, requests = _jwt, _requests


REPO = Path(__file__).resolve().parent.parent
KEY_ID = "DMMFP6XTXX"
ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
APP_ID = "6761163709"
BASE = "https://api.appstoreconnect.apple.com/v1"

KEY_CANDIDATES = [
    Path.home() / ".appstoreconnect/private_keys/AuthKey_DMMFP6XTXX.p8",
    Path.home() / "Library/Application Support/CLI-Pulse-Secrets"
    / "asc-api-key-DMMFP6XTXX-2026-07-08.p8",
    Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Downloads"
    / "AuthKey_DMMFP6XTXX.p8",
]

# Tier words that, if they appear in the description, assert that tier is buyable.
# Maps a word to the product-id fragment that would have to be APPROVED.
TIER_CLAIMS = {
    "Team": "team",
    "Lifetime": "lifetime",
}

# Where the composed marketing PNGs live, by ASC display type.
LOCAL_SHOTS = {
    "APP_DESKTOP": REPO / "CLI Pulse Bar/screenshots/macos/composed",
    # APP_IPHONE_67 is per locale: shots.composed_dir(<language>), the
    # six-language panels (scripts/appstore_screenshots.py).
    "APP_IPAD_PRO_3GEN_129": REPO / "CLI Pulse Bar/screenshots/ipad/composed",
    "APP_IPAD_PRO_129": REPO / "CLI Pulse Bar/screenshots/ipad/composed",
}

LIVE_STATES = {"READY_FOR_SALE", "PENDING_DEVELOPER_RELEASE"}


def die(msg: str) -> "NoReturn":  # noqa: F821
    print(f"FATAL: {msg}", file=sys.stderr)
    raise SystemExit(2)


def token() -> str:
    key = next((p for p in KEY_CANDIDATES if p.exists()), None)
    if key is None:
        die("no ASC API key found. Looked in:\n  " + "\n  ".join(str(p) for p in KEY_CANDIDATES))
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key.read_text(),
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


class ASC:
    def __init__(self) -> None:
        self.h = {"Authorization": f"Bearer {token()}"}

    def get(self, path: str, **params):
        url = path if path.startswith("http") else BASE + path
        r = requests.get(url, headers=self.h, params=params, timeout=30)
        if r.status_code != 200:
            die(f"ASC GET {path} -> {r.status_code}: {r.text[:300]}")
        return r.json()


def purchasable_products(asc: ASC) -> dict[str, str]:
    """product_id -> state, for every subscription and one-time IAP."""
    out: dict[str, str] = {}
    for grp in asc.get(f"/apps/{APP_ID}/subscriptionGroups", limit=20)["data"]:
        subs = asc.get(
            f"/subscriptionGroups/{grp['id']}/subscriptions",
            limit=50,
            **{"fields[subscriptions]": "name,productId,state"},
        )
        for s in subs["data"]:
            a = s["attributes"]
            out[a["productId"]] = a.get("state", "UNKNOWN")
    try:
        iaps = asc.get(
            f"/apps/{APP_ID}/inAppPurchasesV2",
            limit=50,
            **{"fields[inAppPurchases]": "name,productId,state"},
        )
        for i in iaps["data"]:
            a = i["attributes"]
            out[a["productId"]] = a.get("state", "UNKNOWN")
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        die(f"could not list one-time IAPs: {exc}")
    if not out:
        die("ASC returned zero products. A check with nothing to check always passes; refusing to.")
    return out


def live_versions(asc: ASC, platform: str | None, version: str | None = None):
    """The version to check per platform: the live one, or `version` if named.

    Naming the version is how this runs usefully at release time: the texts are
    pushed to the version being prepared, and the live one still shows the old
    text until the new one ships.
    """
    plats = [platform] if platform else ["MAC_OS", "IOS"]
    for plat in plats:
        params = {"filter[platform]": plat,
                  "fields[appStoreVersions]": "versionString,appStoreState,platform"}
        if version:
            params["filter[versionString]"] = version
        vers = asc.get(f"/apps/{APP_ID}/appStoreVersions", limit=10, **params)
        if version:
            if not vers["data"]:
                print(f"  note: {plat} has no version {version} — skipped")
                continue
            yield plat, vers["data"][0]
            continue
        live = [v for v in vers["data"] if v["attributes"]["appStoreState"] in LIVE_STATES]
        if not live:
            print(f"  note: no live version for {plat} (nothing serving) — skipped")
            continue
        yield plat, live[0]


def subtitles(asc: ASC, prefer_unreleased: bool) -> dict[str, str]:
    """locale -> subtitle, from the app info that goes with the checked version."""
    infos = asc.get(f"/apps/{APP_ID}/appInfos")["data"]

    def state(row):
        a = row["attributes"]
        return a.get("state") or a.get("appStoreState") or ""
    live = [i for i in infos if state(i) in LIVE_STATES | {"READY_FOR_DISTRIBUTION"}]
    other = [i for i in infos if i not in live]
    pick = (other or live) if prefer_unreleased else (live or other)
    if not pick:
        return {}
    rows = asc.get(f"/appInfos/{pick[0]['id']}/appInfoLocalizations", limit=50)["data"]
    return {r["attributes"]["locale"]: (r["attributes"].get("subtitle") or "").strip()
            for r in rows}


def check_whatsnew(d: Path, root: Path | None = None) -> bool:
    """The What's New check (--whatsnew-dir): both platforms, every store locale.

    It runs before everything else and a failure ends the run, because the
    release step it guards (asc_submit.py --submit) refuses on the same
    problems: listing them here, days earlier, is the point."""
    problems = listing.whatsnew_problems(d, root)
    split = d.is_dir() and listing.whatsnew_is_split(d)
    print(f"What's New in {d}/ ({'separate iOS and macOS texts' if split else 'one text per locale for both platforms'}):")
    for plat, label in listing.PLATFORM_LABEL.items():
        texts, _ = listing.load_whatsnew(d, plat, root)
        row = "  ".join(f"{loc}={len(texts[loc].text) if loc in texts else '-'}"
                        for loc in listing.LOCALE_SOURCES)
        print(f"  {label:6} {row}   (characters, limit {listing.WHATSNEW_LIMIT})")
    for p in problems:
        print(f"  FAIL  {p}")
    if not problems:
        print(f"  ok    {len(listing.LOCALE_SOURCES)} locale(s) x 2 platforms ready")
    return not problems


def check_repo_texts(root: Path | None = None) -> bool:
    """Check 0: the repo's listing texts, and that no pusher carries its own copy.

    The inline-copy ratchet used to live here as a description-only check of two
    pushers. It now covers every field of every locale, in three pushers, and it
    runs in CI because it needs no key — a copy growing back is caught at review,
    not at the next release.
    """
    problems = listing.validate(root) + listing.inline_copy_problems(root)
    print("repo listing texts (characters):")
    for src, counts in listing.summary_rows(root):
        locales = [loc for loc, d in listing.LOCALE_SOURCES.items() if d == src]
        print(f"  {src:8} " + "  ".join(f"{k[:-4]}={v}" for k, v in counts.items())
              + f"   -> {', '.join(locales)}")
    for p in problems:
        print(f"  FAIL  {p}")
    if not problems:
        print(f"  ok    {len(listing.source_dirs())} locale dir(s) valid for "
              f"{len(listing.LOCALE_SOURCES)} App Store locale(s)")
    return not problems


def check_repo_shots(root: Path | None = None) -> bool:
    """Check 4 (--require-shots): every locale with listing texts has its five
    composed iPhone panels, each uploadable (1290x2796, RGB, no alpha, <=10 MB),
    or is mapped to FALLBACK and shows en-US's. Repo-only, so it runs in CI:
    repo-hygiene.yml passes --require-shots since the six-language capture for
    1.54.0 landed. It stays a flag rather than the default so that a listing-text
    change can still be checked on its own (test_asc_listing_preflight.sh
    builds text-only fixtures), not because the panels may be missing."""
    problems = shots.require_shots_problems(listing.LOCALE_SOURCES, root)
    print("repo iPhone screenshots (--require-shots):")
    for loc in listing.LOCALE_SOURCES:
        lang = shots.SHOT_SOURCES.get(loc, "?")
        where = ("FALLBACK: shows en-US's panels" if lang is shots.FALLBACK
                 else f"{shots.composed_dir(lang, root).relative_to(root or REPO)}")
        print(f"  {loc:8} -> {where}")
    for loc, why in problems:
        print(f"  FAIL  [{loc}] {why}")
    if not problems:
        print(f"  ok    {len(listing.LOCALE_SOURCES)} locale(s) have their "
              f"{len(shots.SCREENS)} panels")
    return not problems


def compare_set(asc: ASC, locale: str, screenshot_set: dict, dtype: str,
                local_dir: Path | None) -> bool:
    """Compare one live screenshot set with the local composed PNGs of the same
    names. True if anything failed."""
    failed = False
    live_shots = asc.get(
        f"/appScreenshotSets/{screenshot_set['id']}/appScreenshots",
        limit=50,
        **{"fields[appScreenshots]": "fileName,imageAsset"},
    )
    tag = f"[{locale}] {dtype}"
    if local_dir is None or not local_dir.is_dir():
        print(f"  note  {tag}: {len(live_shots['data'])} live shot(s), no local dir mapped "
              "— not compared")
        return False

    # Drift also runs the other way: a composed screenshot that exists
    # in the repo and is NOT on the store. Reported as a note, not a
    # failure — 1.52.1 deliberately ships 8 of the 9 macOS shots,
    # leaving out the paywall one because the only machine available to
    # re-shoot it is on a non-USD storefront and the en-US set is the
    # fallback every storefront without its own screenshots sees. A
    # permanently-red gate gets `continue-on-error`'d, which is the
    # same failure as a green gate that guards nothing.
    live_names = {(x["attributes"].get("fileName") or "") for x in live_shots["data"]}
    for extra in sorted(local_dir.glob("*.png")):
        if extra.name not in live_names:
            print(f"  note  {tag} {extra.name}: in the repo, not on the store "
                  f"(never uploaded, or deliberately withheld)")
    for shot in live_shots["data"]:
        a = shot["attributes"]
        name = a.get("fileName") or "?"
        asset = a.get("imageAsset") or {}
        tmpl = asset.get("templateUrl")
        local = local_dir / name
        if not local.exists():
            print(f"  note  {tag} {name}: live, but no local file at {local.relative_to(REPO)}")
            continue
        if not tmpl:
            print(f"  FAIL  {tag} {name}: live shot has no downloadable asset URL")
            failed = True
            continue
        w = asset.get("width") or 2880
        h = asset.get("height") or 1800
        url = tmpl.replace("{w}", str(w)).replace("{h}", str(h)).replace("{f}", "png")
        try:
            blob = requests.get(url, timeout=60).content
        except Exception as exc:  # noqa: BLE001
            die(f"could not download {name}: {exc}")
        # ASC re-encodes on ingest, so bytes rarely match exactly. Compare
        # dimensions + a perceptual-ish digest of the decoded pixels when
        # Pillow is available; otherwise report so nobody reads silence
        # as agreement.
        try:
            from PIL import Image  # noqa: PLC0415
            import io  # noqa: PLC0415
            live_img = Image.open(io.BytesIO(blob)).convert("RGB")
            local_img = Image.open(local).convert("RGB")
            box = (256, 256)
            lv = sha(live_img.resize(box).tobytes())
            lc = sha(local_img.resize(box).tobytes())
            if lv == lc:
                print(f"  ok    {tag} {name}: live matches local")
            else:
                print(f"  FAIL  {tag} {name}: live screenshot differs from the local composed PNG")
                print(f"          local:  {local.relative_to(REPO)}")
                print(f"          live:   {url}")
                print("          Regenerated locally but never uploaded, or vice versa.")
                failed = True
        except ImportError:
            print(f"  note  {tag} {name}: Pillow not installed, cannot compare pixels "
                  "(pip install pillow). NOT treated as a pass.")
            failed = True
    return failed


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--whatsnew-dir", type=Path,
                    help="also check a release's What's New directory (e.g. whatsnew_154), "
                         "first; repo-only, works with --texts-only")
    ap.add_argument("--platform", choices=["MAC_OS", "IOS"], help="check one platform only")
    ap.add_argument("--skip-screenshots", action="store_true",
                    help="skip check 3 (it downloads every live screenshot)")
    ap.add_argument("--version", help="check this versionString instead of the live version")
    ap.add_argument("--texts-only", action="store_true",
                    help="check 0 only: validate the repo texts, no App Store Connect (CI)")
    ap.add_argument("--root", type=Path,
                    help="repo root to validate (with --texts-only; for the self-test)")
    ap.add_argument("--require-shots", action="store_true",
                    help="also require every listing locale's five composed iPhone panels "
                         "(check 4; repo-only, works with --texts-only)")
    args = ap.parse_args()
    if args.whatsnew_dir is not None and not check_whatsnew(args.whatsnew_dir, args.root):
        print("WHAT'S NEW INVALID — fix the files above; asc_submit.py would refuse them too.")
        return 1

    if args.root and not args.texts_only:
        ap.error("--root only makes sense with --texts-only")
    texts_ok = check_repo_texts(args.root)
    shots_ok = True
    if args.require_shots:
        shots_ok = check_repo_shots(args.root)
    else:
        print("repo iPhone screenshots: not checked (--require-shots)")
    if args.texts_only:
        print("TEXTS OK" if texts_ok else "TEXTS INVALID — fix the files above.")
        if args.require_shots:
            print("SHOTS OK" if shots_ok else "SHOTS INCOMPLETE — capture and compose them: "
                  "CLI Pulse Bar/scripts/capture_ios_screenshots.sh, then "
                  "compose_appstore_ios_screenshots.py --all")
        return 0 if texts_ok and shots_ok else 1

    _load_http_deps()
    asc = ASC()
    products = purchasable_products(asc)
    buyable = {pid for pid, st in products.items() if st == "APPROVED"}
    print(f"ASC catalogue: {len(products)} product(s), {len(buyable)} purchasable")
    for pid, st in sorted(products.items()):
        mark = "OK " if st == "APPROVED" else "NOT"
        print(f"   {mark}  {st:<28} {pid}")

    failed = not (texts_ok and shots_ok)
    checked_any = False
    live_subtitles = subtitles(asc, prefer_unreleased=bool(args.version))

    for plat, ver in live_versions(asc, args.platform, args.version):
        vs = ver["attributes"]["versionString"]
        print(f"\n=== {'LIVE ' if not args.version else ''}{plat} v{vs} "
              f"({ver['attributes'].get('appStoreState')}) ===")
        locs = asc.get(
            f"/appStoreVersions/{ver['id']}/appStoreVersionLocalizations",
            limit=50,
            **{"fields[appStoreVersionLocalizations]":
               "locale,description,keywords,promotionalText"},
        )
        by_locale = {}
        rows_by_locale = {}
        for row in locs["data"]:
            lc = row["attributes"].get("locale")
            body = (row["attributes"].get("description") or "").strip()
            if lc:
                rows_by_locale[lc] = row["attributes"]
            if lc and body:
                by_locale[lc] = body
        if "en-US" not in by_locale:
            die(f"{plat} v{vs} has no en-US localization with a description; cannot check.")
        checked_any = True

        # A locale the repo translates and the store does not carry is drift too:
        # the translation exists, and nobody in that storefront can read it.
        for locale in listing.LOCALE_SOURCES:
            if locale not in rows_by_locale:
                print(f"  FAIL  [{locale}] the repo has a listing for this locale; the store "
                      "has no localization. Push it: scripts/asc_push_listing.py")
                failed = True

        # EVERY localization, not just en-US. Checking one and printing a pass
        # is how the Chinese listing went on selling the withdrawn Team tier —
        # and showing a price placeholder with no number in it — for months
        # after en-US had been fixed.
        for locale in sorted(by_locale):
            desc = by_locale[locale]

            # ── 1. SKU-vs-copy ────────────────────────────────────────────
            for word, fragment in TIER_CLAIMS.items():
                if not re.search(rf"\b{re.escape(word)}\b", desc):
                    continue
                matching = {p for p in products if fragment in p.lower()}
                sellable = matching & buyable
                if not sellable:
                    states = ", ".join(f"{p}={products[p]}" for p in sorted(matching)) or "no such SKU"
                    print(f"  FAIL  [{locale}] description sells '{word}', "
                          f"which cannot be bought ({states})")
                    for line in desc.splitlines():
                        if re.search(rf"\b{re.escape(word)}\b", line):
                            print(f"          > {line.strip()[:160]}")
                    failed = True
                else:
                    print(f"  ok    [{locale}] mentions '{word}' and it is purchasable")

            # ── 2. listing drift, against THIS locale's repo text ─────────
            if locale not in listing.LOCALE_SOURCES:
                print(f"  note  [{locale}] no repo text for this locale — not compared. "
                      "Add it to LOCALE_SOURCES in scripts/appstore_listing.py.")
                continue
            live_attrs = dict(rows_by_locale.get(locale, {}))
            live_attrs["subtitle"] = live_subtitles.get(locale, "")
            for f in listing.FIELDS:
                if f.attribute == "description":
                    continue
                want = listing.load_field(f.attribute, locale, plat)
                got = (live_attrs.get(f.attribute) or "").strip()
                if got == want:
                    print(f"  ok    [{locale}] live {f.attribute} matches the repo")
                else:
                    print(f"  FAIL  [{locale}] live {f.attribute} differs from the repo")
                    print(f"          store: {got[:150]!r}")
                    print(f"          repo:  {want[:150]!r}")
                    failed = True
            canon = listing.load_field("description", locale, plat)
            if desc == canon:
                print(f"  ok    [{locale}] live description matches the repo source")
            else:
                print(f"  FAIL  [{locale}] live description differs from the repo source "
                      f"(live {len(desc)} chars; repo {len(canon)})")
                live_only = [ln.strip() for ln in desc.splitlines()
                             if ln.strip() and ln.strip() not in canon]
                repo_only = [ln.strip() for ln in canon.splitlines()
                             if ln.strip() and ln.strip() not in desc]
                for line in live_only[:6]:
                    print(f"          only on the STORE: {line[:150]}")
                for line in repo_only[:6]:
                    print(f"          only in the REPO:  {line[:150]}")
                # Do NOT tell anyone to blind-push. Measured 2026-08-31: the two
                # had drifted in OPPOSITE directions — the store was stale on the
                # subscription paragraph (still selling withdrawn Team, prices
                # 4-5x over) and NEWER than the repo on the privacy section.
                # Pushing the repo verbatim would have fixed one and regressed
                # the other.
                print("          Drift can run in BOTH directions. Read both lists"
                      " above before acting;")
                print("          do not blind-push either side over the other.")
                failed = True

        # ── 3. screenshot drift ───────────────────────────────────────────
        # The iPhone set is per locale (scripts/appstore_screenshots.py maps
        # each locale to its language's panels; a locale with no set of its own
        # is shown en-US's). The Mac and iPad sets exist on en-US only, which
        # every other locale inherits, so those are compared there alone.
        if args.skip_screenshots:
            continue
        for loc_row in locs["data"]:
            locale = loc_row["attributes"].get("locale")
            is_en = locale == "en-US"
            iphone_lang = shots.SHOT_SOURCES.get(locale, shots.FALLBACK)
            sets = asc.get(f"/appStoreVersionLocalizations/{loc_row['id']}/appScreenshotSets",
                           limit=20)
            for st in sets["data"]:
                dtype = st["attributes"].get("screenshotDisplayType")
                if dtype == shots.DISPLAY_TYPE:
                    if iphone_lang is shots.FALLBACK and not is_en:
                        print(f"  note  [{locale}] has an iPhone set of its own, but "
                              "SHOT_SOURCES says it shows en-US's — not compared")
                        continue
                    local_dir = shots.composed_dir(iphone_lang or "en")
                elif is_en:
                    local_dir = LOCAL_SHOTS.get(dtype)
                else:
                    continue
                failed |= compare_set(asc, locale, st, dtype, local_dir)

    if not checked_any:
        die("no live version was checked on any platform.")

    print()
    if failed:
        print("PREFLIGHT FAILED — the store does not agree with the repo, or with itself.")
        print("Listing text: scripts/asc_push_listing.py shows the per-field diff (dry run),")
        print("then --apply --version <X.Y.Z> --platform IOS|MAC_OS writes the editable version.")
        print("At release time, re-run this with --version <X.Y.Z>: the live version keeps")
        print("the old text until the new one ships.")
        return 1
    print("PREFLIGHT OK — live listing agrees with the repo and sells only purchasable tiers.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

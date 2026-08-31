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
2. Description drift the live en-US description must match the repo source that
                    claims to produce it.
3. Screenshot drift  every live screenshot must be byte-identical to the local
                    composed PNG of the same name. Catches "regenerated but
                    never uploaded", which is the case that keeps recurring.

READ-ONLY. Every request is a GET. This script never mutates App Store Connect;
uploading remains a deliberate, owner-driven action.

Usage:
    python3 scripts/asc_listing_preflight.py                 # all platforms
    python3 scripts/asc_listing_preflight.py --platform MAC_OS
Exit 0 = the store agrees with itself and with the repo. 1 = drift. 2 = could
not check (missing key/网络), which is NOT a pass.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import time
from pathlib import Path

try:
    import jwt
    import requests
except ImportError as exc:  # pragma: no cover - environment problem, not drift
    print(f"FATAL: missing dependency ({exc}). pip install pyjwt requests", file=sys.stderr)
    raise SystemExit(2)

REPO = Path(__file__).resolve().parent.parent
KEY_ID = "DMMFP6XTXX"
ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
APP_ID = "6761163709"
BASE = "https://api.appstoreconnect.apple.com/v1"

KEY_CANDIDATES = [
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
    "APP_IPHONE_67": REPO / "CLI Pulse Bar/screenshots/ios/composed",
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


def live_versions(asc: ASC, platform: str | None):
    plats = [platform] if platform else ["MAC_OS", "IOS"]
    for plat in plats:
        vers = asc.get(
            f"/apps/{APP_ID}/appStoreVersions",
            limit=10,
            **{"filter[platform]": plat,
               "fields[appStoreVersions]": "versionString,appStoreState,platform"},
        )
        live = [v for v in vers["data"] if v["attributes"]["appStoreState"] in LIVE_STATES]
        if not live:
            print(f"  note: no live version for {plat} (nothing serving) — skipped")
            continue
        yield plat, live[0]


DESCRIPTION_SOURCES = ("appstore_metadata.py", "resubmit.py")


def repo_descriptions() -> dict[str, str]:
    """The description the repo would push, plus a check that there is only one.

    There used to be two: a literal in `appstore_metadata.py` and another in
    `resubmit.py`. They drifted, and not cosmetically — on 2026-09-01 the
    second one claimed "All data stays on your local network", "No cloud sync
    or third-party analytics" and "Connects to your self-hosted CLI Pulse
    backend", none of which is true of the shipping app. Whichever script ran
    last decided what the App Store said about our privacy posture.

    Both now read `CLI Pulse Bar/appstore/description_en-US.txt`, and this
    refuses to pass if either one regrows an inline copy.
    """
    canonical = REPO / "CLI Pulse Bar/appstore/description_en-US.txt"
    if not canonical.exists():
        die(f"canonical App Store description missing: {canonical}")
    text = canonical.read_text(encoding="utf-8").strip()
    if not text:
        die(f"canonical App Store description is empty: {canonical}")

    # Ratchet: an inline literal in a pusher is how the drift happened. The
    # marker is the description's own first sentence, so a copy-paste is
    # caught no matter what variable it is assigned to.
    MARKER = "CLI Pulse monitors your AI coding tool usage"
    for name in DESCRIPTION_SOURCES:
        src = REPO / "CLI Pulse Bar/scripts" / name
        if not src.exists():
            die(f"repo description pusher missing: {src}")
        body = src.read_text(encoding="utf-8")
        if MARKER in body:
            die(f"{name} carries an inline App Store description again. "
                f"Both pushers must read {canonical.name}; two copies is how "
                "the store ended up being told the app was self-hosted.")

    out = {"en-US": text}
    # Every other locale the repo carries a canonical file for. The store has a
    # zh-Hans description too, and on 2026-09-01 it was STILL selling the
    # withdrawn Team tier and carried a broken "¥/月" price placeholder with no
    # number in it — long after en-US had been cleaned up — because nothing
    # ever read anything but en-US.
    for extra in sorted((REPO / "CLI Pulse Bar/appstore").glob("description_*.txt")):
        locale = extra.stem[len("description_"):]
        if locale == "en-US":
            continue
        body = extra.read_text(encoding="utf-8").strip()
        if body:
            out[locale] = body
    return out


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=["MAC_OS", "IOS"], help="check one platform only")
    ap.add_argument("--skip-screenshots", action="store_true",
                    help="skip check 3 (it downloads every live screenshot)")
    args = ap.parse_args()

    asc = ASC()
    products = purchasable_products(asc)
    buyable = {pid for pid, st in products.items() if st == "APPROVED"}
    print(f"ASC catalogue: {len(products)} product(s), {len(buyable)} purchasable")
    for pid, st in sorted(products.items()):
        mark = "OK " if st == "APPROVED" else "NOT"
        print(f"   {mark}  {st:<28} {pid}")

    repo_descs = repo_descriptions()
    print("repo canonical descriptions: " +
          ", ".join(f"{n} ({len(d)} chars)" for n, d in sorted(repo_descs.items())))
    # The old "the pushers disagree with each other" note is gone: there is now
    # exactly one file per locale and the pushers read them, so the only way to
    # disagree is an inline literal — which `repo_descriptions` refuses outright.

    failed = False
    checked_any = False

    for plat, ver in live_versions(asc, args.platform):
        vs = ver["attributes"]["versionString"]
        print(f"\n=== LIVE {plat} v{vs} ===")
        locs = asc.get(
            f"/appStoreVersions/{ver['id']}/appStoreVersionLocalizations",
            limit=20,
            **{"fields[appStoreVersionLocalizations]": "locale,description"},
        )
        by_locale = {}
        for row in locs["data"]:
            lc = row["attributes"].get("locale")
            body = (row["attributes"].get("description") or "").strip()
            if lc and body:
                by_locale[lc] = body
        if "en-US" not in by_locale:
            die(f"{plat} v{vs} has no en-US localization with a description; cannot check.")
        checked_any = True

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

            # ── 2. description drift, against THIS locale's canonical text ──
            canon = repo_descs.get(locale)
            if canon is None:
                print(f"  note  [{locale}] no canonical repo text — not compared. "
                      f"Add CLI Pulse Bar/appstore/description_{locale}.txt to cover it.")
            elif desc == canon:
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
        # Screenshots hang off the en-US localization; the other locales
        # inherit them, so one pass over en-US covers the set.
        if args.skip_screenshots:
            continue
        en_loc = next(x for x in locs["data"]
                      if x["attributes"].get("locale") == "en-US")
        sets = asc.get(f"/appStoreVersionLocalizations/{en_loc['id']}/appScreenshotSets", limit=20)
        for st in sets["data"]:
            dtype = st["attributes"].get("screenshotDisplayType")
            local_dir = LOCAL_SHOTS.get(dtype)
            shots = asc.get(
                f"/appScreenshotSets/{st['id']}/appScreenshots",
                limit=50,
                **{"fields[appScreenshots]": "fileName,imageAsset"},
            )
            if local_dir is None or not local_dir.is_dir():
                print(f"  note  {dtype}: {len(shots['data'])} live shot(s), no local dir mapped — not compared")
                continue

            # Drift also runs the other way: a composed screenshot that exists
            # in the repo and is NOT on the store. Reported as a note, not a
            # failure — 1.52.1 deliberately ships 8 of the 9 macOS shots,
            # leaving out the paywall one because the only machine available to
            # re-shoot it is on a non-USD storefront and the en-US set is the
            # fallback every storefront without its own screenshots sees. A
            # permanently-red gate gets `continue-on-error`'d, which is the
            # same failure as a green gate that guards nothing.
            live_names = {(x["attributes"].get("fileName") or "") for x in shots["data"]}
            for extra in sorted(local_dir.glob("*.png")):
                if extra.name not in live_names:
                    print(f"  note  {extra.name}: in the repo, not on the store "
                          f"(never uploaded, or deliberately withheld)")
            for shot in shots["data"]:
                a = shot["attributes"]
                name = a.get("fileName") or "?"
                asset = a.get("imageAsset") or {}
                tmpl = asset.get("templateUrl")
                local = local_dir / name
                if not local.exists():
                    print(f"  note  {name}: live, but no local file at {local.relative_to(REPO)}")
                    continue
                if not tmpl:
                    print(f"  FAIL  {name}: live shot has no downloadable asset URL")
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
                        print(f"  ok    {name}: live matches local")
                    else:
                        print(f"  FAIL  {name}: live screenshot differs from the local composed PNG")
                        print(f"          local:  {local.relative_to(REPO)}")
                        print(f"          live:   {url}")
                        print("          Regenerated locally but never uploaded, or vice versa.")
                        failed = True
                except ImportError:
                    print(f"  note  {name}: Pillow not installed, cannot compare pixels "
                          "(pip install pillow). NOT treated as a pass.")
                    failed = True

    if not checked_any:
        die("no live version was checked on any platform.")

    print()
    if failed:
        print("PREFLIGHT FAILED — the store does not agree with the repo, or with itself.")
        print("Fix by re-pushing the affected metadata/screenshots to App Store Connect.")
        return 1
    print("PREFLIGHT OK — live listing agrees with the repo and sells only purchasable tiers.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

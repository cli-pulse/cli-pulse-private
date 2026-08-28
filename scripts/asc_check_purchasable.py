#!/usr/bin/env python3
"""App Store Connect: can anyone actually buy what the app is selling?

READ-ONLY. Makes only GET requests and never writes.

WHY THIS EXISTS
---------------
`SubscriptionManager.loadProducts()` asks StoreKit for five product IDs. Until
v1.51 it reduced every failure to `products = []`, so a misconfigured product, a
network error, and a user who simply did not buy all rendered as the same empty
paywall. That made "checkout is broken" an explanation nobody could rule in or
out — it fit every conversion number the product had ever produced.

Running this on 2026-08-26 found `com.clipulse.pro.lifetime` sitting in
MISSING_METADATA with no localization, no price point and no review screenshot:
a product shell created and never configured. StoreKit omits it from every
response, so the Lifetime tile had rendered a dead "Not Available" button since
v1.14 and had never once been purchasable — the largest single payment in the
app. Nothing in the client, the store, or CI had ever said so.

So: before reading anything into a conversion number, run this. A product that
is not sellable produces exactly the same signal as a product nobody wanted.

PREREQ (per [[feedback_asc_icloud_key_tcc]]): the ASC API .p8 key must live at
  ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
NOT on iCloud Drive — a headless process is TCC-denied there. KEY_ID / ISSUER /
APP_ID below are identifiers, not secrets; only the .p8 is.

WHAT IT DOES NOT COVER
----------------------
Two failure modes produce zero purchasable products and are NOT visible here:
  * the Paid Applications agreement lapsing — not exposed by the ASC API;
  * `Product.products(for:)` failing at runtime on a real signed build.
Neither can be checked from a desk. A green run here means "the catalogue is
right", not "checkout works". The runtime half still needs a signed build and a
sandbox account.

Usage:
  python3 scripts/asc_check_purchasable.py
Exit status: 0 if every ID the client asks for is sellable, 1 otherwise —
so it can be wired into a release checklist.
"""
import os
import re
import sys
import time

try:
    import jwt  # PyJWT
    import requests
except ImportError:
    sys.exit("pip install pyjwt requests  (needed for the ASC API)")

KEY_ID = "DMMFP6XTXX"
ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
APP_ID = "6761163709"
BASE = "https://api.appstoreconnect.apple.com/v1"

# The offered set is PARSED from SubscriptionManager.swift, not restated here.
#
# It used to be a hardcoded list, directly above a comment warning that it
# "must stay in sync with SubscriptionManager.allProductIDs" — and by
# 2026-08-28 it had drifted exactly as predicted: five IDs here, two in the
# app. The guard failed on `com.clipulse.pro.lifetime`, a product v1.52
# deliberately withdrew, while printing the header "the IDs
# SubscriptionManager.allProductIDs asks for". It was reporting on a set it
# never read.
#
# A guard that is red for a reason absent from the diff is one people stop
# reading, so this now derives the set instead of asserting it.
SUBSCRIPTION_MANAGER = (
    "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SubscriptionManager.swift"
)

# Products withdrawn from sale but still HONORED for existing owners. These are
# expected to be unsellable; reporting them is useful, failing on them is not.
# Keep in step with the withdrawal comments in SubscriptionView/SubscriptionSection.
WITHDRAWN_BUT_HONORED = {
    "com.clipulse.pro.lifetime": "withdrawn v1.52 (MISSING_METADATA since v1.14)",
    "com.clipulse.team.monthly": "withdrawn v1.52 (tier has no exclusive benefit)",
    "com.clipulse.team.yearly": "withdrawn v1.52 (tier has no exclusive benefit)",
}


def offered_product_ids(repo_root: str) -> list[str]:
    """The IDs `allProductIDs` actually contains, read from the Swift source.

    `allProductIDs` lists constant NAMES (`proMonthlyID`), not literals, so this
    resolves each name through its `let <name> = "<literal>"` declaration.
    Raises rather than returning a partial set: silently checking fewer products
    than the app sells is the failure mode this function exists to prevent.
    """
    path = os.path.join(repo_root, SUBSCRIPTION_MANAGER)
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as exc:
        raise SystemExit(f"cannot read {SUBSCRIPTION_MANAGER}: {exc}")

    block = re.search(
        r"allProductIDs\s*:\s*Set<String>\s*=\s*\[(.*?)\]", src, re.S
    )
    if not block:
        raise SystemExit(
            "could not find `allProductIDs: Set<String> = [...]` in\n"
            f"  {SUBSCRIPTION_MANAGER}\n"
            "The declaration moved or changed shape. Fix this parser — do NOT\n"
            "fall back to a hardcoded list, which is what drifted last time."
        )

    literals = {
        name: value
        for name, value in re.findall(
            r'let\s+(\w+)\s*=\s*"([^"]+)"', src
        )
    }

    ids: list[str] = []
    for token in (t.strip() for t in block.group(1).split(",")):
        if not token or token.startswith("//"):
            continue
        if token.startswith('"') and token.endswith('"'):
            ids.append(token.strip('"'))
        elif token in literals:
            ids.append(literals[token])
        else:
            raise SystemExit(
                f"`allProductIDs` names `{token}`, but no `let {token} = \"...\"`\n"
                "was found. Refusing to check a partial set."
            )
    if not ids:
        raise SystemExit("`allProductIDs` parsed as empty — refusing to pass vacuously.")
    return ids

# States in which the store will actually serve the product to StoreKit.
SELLABLE = {"APPROVED", "READY_FOR_SALE"}


def _key_path() -> str:
    path = os.path.expanduser(
        f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"
    )
    if not os.path.exists(path):
        sys.exit(
            f"ASC key not found at {path}. See the module docstring — it must "
            "not live on iCloud Drive."
        )
    return path


def _headers() -> dict:
    token = jwt.encode(
        {"iss": ISSUER, "exp": int(time.time()) + 1200,
         "aud": "appstoreconnect-v1"},
        open(_key_path()).read(),
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )
    return {"Authorization": f"Bearer {token}"}


def get(url: str, headers: dict, **params) -> dict:
    r = requests.get(url, headers=headers, params=params, timeout=60)
    if r.status_code != 200:
        return {"__error__": f"{r.status_code} {r.text[:300]}"}
    return r.json()


def main() -> int:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    wanted = offered_product_ids(repo_root)

    H = _headers()
    found: dict[str, str] = {}

    print("=" * 74)
    print("AUTO-RENEWABLE SUBSCRIPTIONS")
    print("=" * 74)
    groups = get(f"{BASE}/apps/{APP_ID}/subscriptionGroups", H, limit=200)
    if "__error__" in groups:
        print("  ERROR:", groups["__error__"])
    for g in groups.get("data", []):
        print(f"\n  group: {g['attributes'].get('referenceName')}")
        subs = get(
            f"{BASE}/subscriptionGroups/{g['id']}/subscriptions", H,
            limit=200,
            **{"fields[subscriptions]": "productId,name,state,subscriptionPeriod"},
        )
        if "__error__" in subs:
            print("    ERROR:", subs["__error__"])
            continue
        for s in subs.get("data", []):
            a = s["attributes"]
            found[a.get("productId")] = a.get("state")
            prices = get(f"{BASE}/subscriptions/{s['id']}/prices", H, limit=200)
            n = len(prices.get("data", [])) if "__error__" not in prices else -1
            print(f"    {a.get('productId'):32s} {str(a.get('state')):20s} "
                  f"{n} price entries")

    print()
    print("=" * 74)
    print("IN-APP PURCHASES (non-consumable / consumable)")
    print("=" * 74)
    iaps = get(
        f"{BASE}/apps/{APP_ID}/inAppPurchasesV2", H, limit=200,
        **{"fields[inAppPurchases]": "productId,name,state,inAppPurchaseType"},
    )
    if "__error__" in iaps:
        print("  ERROR:", iaps["__error__"])
    for p in iaps.get("data", []):
        a = p["attributes"]
        found[a.get("productId")] = a.get("state")
        # A shell product 404s on all four of these. That is the signature of
        # "created in ASC and never configured".
        detail = []
        for rel in ("inAppPurchaseLocalizations", "pricePoints",
                    "iapPriceSchedule", "appStoreReviewScreenshot"):
            d = get(f"{BASE}/inAppPurchasesV2/{p['id']}/{rel}", H, limit=5)
            detail.append(f"{rel}={'404' if '__error__' in d else 'ok'}")
        print(f"  {a.get('productId'):32s} {str(a.get('state')):20s} "
              f"{a.get('inAppPurchaseType')}")
        print(f"    {'  '.join(detail)}")

    print()
    print("=" * 74)
    print(f"VERDICT — the {len(wanted)} ID(s) parsed from "
          f"SubscriptionManager.allProductIDs")
    print("=" * 74)
    bad = []
    for pid in wanted:
        state = found.get(pid)
        if state is None:
            mark, reason = "NOT IN ASC", "absent from App Store Connect entirely"
        elif state in SELLABLE:
            mark, reason = "ok", ""
        else:
            mark, reason = "NOT SELLABLE", f"state={state}"
        if reason:
            bad.append((pid, reason))
        print(f"  {pid:32s} {str(state):22s} {mark}")

    # Advisory only — never fails the run.
    #
    # Two distinct things live in ASC but not in `allProductIDs`, and conflating
    # them is how the old version got stuck red:
    #   * WITHDRAWN_BUT_HONORED — retired on purpose, existing owners keep them.
    #     Unsellable is the CORRECT state.
    #   * everything else — genuinely dead catalogue entries.
    #
    # A withdrawn product that is still SELLABLE is worth shouting about: it
    # means the app stopped offering it while the store will still charge for
    # it. That is the live Team situation as of 2026-08-28.
    extra = sorted(set(found) - set(wanted))
    if extra:
        print("\n  In ASC but not offered by the app:")
        for pid in extra:
            note = WITHDRAWN_BUT_HONORED.get(pid)
            state = found[pid]
            if note and state in SELLABLE:
                print(f"    {pid:32s} {state:22s} ⚠️  {note}")
                print(f"    {'':32s} {'':22s}    STILL PURCHASABLE — the app no "
                      f"longer offers it, but the")
                print(f"    {'':32s} {'':22s}    store will still take money. "
                      f"Remove from sale in ASC.")
            elif note:
                print(f"    {pid:32s} {state:22s} withdrawn as intended — {note}")
            else:
                print(f"    {pid:32s} {state:22s} dead catalogue entry")

    print()
    if bad:
        print(f"FAIL — {len(bad)} product(s) cannot be purchased:")
        for pid, reason in bad:
            print(f"  {pid}: {reason}")
        print()
        print("StoreKit silently omits these from Product.products(for:). The")
        print("paywall renders '--' or hides the tile; the user sees no error,")
        print("and the funnel records a non-purchase indistinguishable from a")
        print("declined offer.")
        return 1

    print("OK — every product the client asks for is sellable per ASC.")
    print("NOTE: this does not prove checkout works. The Paid Applications")
    print("agreement is not exposed by the API, and Product.products() can")
    print("still fail at runtime. Both need a signed build to rule out.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

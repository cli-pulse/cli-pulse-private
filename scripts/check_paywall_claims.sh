#!/bin/bash
# Fail the build if the paywall advertises a benefit that no code withholds.
#
# WHY THIS EXISTS
# ---------------
# Until v1.51 the Pro/Team cards in `SubscriptionView` sold eleven bullets. Five
# of them named features that did not exist anywhere in the tree — priority
# alerts, cost analytics, shared alerts, admin controls, team dashboards — and
# four more named limits that nothing enforced (2/5/unlimited devices,
# 7/90/365-day retention). The retention one was worse than unenforced: the
# nightly cleanup reads `user_settings.data_retention_days`, which defaults to 7
# for every account and is never written from the tier, so a Pro subscriber was
# promised 90 days while the server deleted at 7.
#
# None of that was caught by anything. Feature bullets are strings, and a string
# compiles whether or not the thing it describes is real. The only mechanism
# that can catch it is one that insists a bullet name a line of code.
#
# WHAT IT CHECKS
# --------------
#   1. every bullet in `SubscriptionView.planCard(features:)` is registered in
#      scripts/paywall_claims.allow;
#   2. every registered enforcement site still exists AND still contains the
#      pattern that does the enforcing — so deleting a gate and leaving the
#      bullet fails here rather than shipping;
#   3. every registered bullet is still on the paywall (stale registry entries
#      are as misleading as missing ones);
#   4. none of the nine strings deleted in v1.51 has come back.
#
# Check 2 is the one with teeth. A registry that only matched names would be
# satisfied by inventing a name, which is exactly the failure mode it exists to
# stop.
#
# NEGATIVE CONTROL: `scripts/test_check_paywall_claims.sh` mutates a throwaway
# copy of the tree four ways and asserts this script fails each time. A guard
# nobody has watched fail is not known to work.
#
# Usage: check_paywall_claims.sh [--root DIR]   (--root is for the self-test)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "${1:-}" = "--root" ]; then
    ROOT="$2"
fi

PAYWALL="$ROOT/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SubscriptionView.swift"
ALLOW="$ROOT/scripts/paywall_claims.allow"

# The SECOND paywall surface. `SubscriptionSection` renders inline buy cards in
# macOS Settings with their own one-line pitch, and the first cut of this guard
# did not read it — so while the main paywall was being cleaned up, these rows
# still said "Unlimited providers, 5 devices" and "Unlimited everything, team
# features" in hardcoded English. A guard that watches one of two surfaces
# licenses the other.
INLINE="$ROOT/CLI Pulse Bar/CLI Pulse Bar/SubscriptionSection.swift"

# Bullets that describe the SHAPE of a purchase rather than a capability
# withheld from free, so there is no enforcement site to name. Anything asking
# for an exemption has to argue for it here; the default answer is "then it is
# not a benefit, delete it".
#
# v1.52.1 — EMPTY, on purpose.
#
# Held "everythingInPro lifetimeDescription" until v1.52 withdrew the Team card
# and the Lifetime tile, taking both bullets with them. The exemptions outlived
# the bullets, and the guard's success line went on naming them on every green
# run — describing a paywall that no longer existed.
#
# A pointer bullet is one that pitches no benefit of its own ("Everything in
# Pro", or a statement of billing terms), so there is nothing to enforce and
# nothing to register. If one is reintroduced, add it back here WITH the reason,
# and the stale-exemption check below will tell you when it stops being needed.
POINTER_BULLETS=""

# Deleted in v1.51. Listed by localization key because that is the form that
# survives in the .strings catalogs after the Swift symbol is gone.
RETIRED_KEYS="subscription.priority_alerts
subscription.cost_analytics
subscription.shared_alerts
subscription.admin_controls
subscription.team_dashboards
subscription.up_to_5_devices
subscription.unlimited_devices
subscription.data_retention_90
subscription.data_retention_365"

failed=0

for required in "$PAYWALL" "$ALLOW" "$INLINE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: expected file is missing: ${required#"$ROOT"/}"
        echo "       This guard cannot verify the paywall it cannot find."
        exit 1
    fi
done

# ── 1. bullets on the paywall ────────────────────────────────────────────────
# Every feature array entry is `L10n.subscription.<symbol>` on its own line
# inside a `features: [ ... ]` literal. Pull the symbols from those arrays only,
# so an unrelated mention of L10n.subscription elsewhere in the file does not
# register as an advertised bullet.
bullets="$(awk '
    BEGIN { prefix = "L10n.subscription."; plen = length(prefix) }
    /features: \[/ {
        # `features: [String],` in planCard(...)s own signature closes on the
        # same line and is NOT an advertised list. Only a bracket left open at
        # end of line starts a feature array.
        if ($0 ~ /features: \[[^]]*\]/) next
        inside = 1
        next
    }
    inside && /\]/ { inside = 0; next }
    inside && match($0, /L10n\.subscription\.[A-Za-z0-9_]+/) {
        print substr($0, RSTART + plen, RLENGTH - plen)
    }
' "$PAYWALL" | sort -u)"

if [ -z "$bullets" ]; then
    echo "ERROR: found no feature bullets in SubscriptionView.planCard(features:)."
    echo "       Either the paywall lost its feature list or this guard's parser"
    echo "       no longer matches it. Both are worth stopping for — a guard that"
    echo "       silently matches nothing is the failure mode this repo keeps"
    echo "       hitting (see feedback_guards_that_never_run)."
    exit 1
fi

# `sed` not `tr` here: `tr -d '[:space:]'` deletes newlines too and would fuse
# the whole registry into one unmatchable token.
registered="$(grep -v '^[[:space:]]*#' "$ALLOW" | grep -v '^[[:space:]]*$' \
    | cut -d'|' -f1 | sed 's/[[:space:]]//g' | sort -u)"

# ── 1b. the inline Settings buy cards ────────────────────────────────────────
# Their pitch text must come from a registered L10n bullet, not a literal. A
# hardcoded string here is invisible to every check above and to the .strings
# catalogs, which is exactly how "5 devices" survived the first cleanup.
inline_literals="$(awk '
    /inlineProductRow\(/ , /\)/ {
        if (match($0, /features: "[^"]*"/)) {
            print substr($0, RSTART + 11, RLENGTH - 12)
        }
    }
' "$INLINE" | grep -v '^Save ' || true)"

if [ -n "$inline_literals" ]; then
    echo "ERROR: the inline buy cards in SubscriptionSection.swift pitch features"
    echo "       with hardcoded string literals:"
    echo "$inline_literals" | sed 's/^/         "/; s/$/"/'
    echo
    echo "       Use a registered L10n.subscription bullet instead. A literal here"
    echo "       is invisible to the paywall-claims registry and to every"
    echo "       localization catalog — which is how \"5 devices\" and \"team"
    echo "       features\" survived after both were removed from the main"
    echo "       paywall. (Price-only blurbs like \"Save 17%\" are exempt.)"
    failed=1
fi

inline_bullets="$(grep -oE 'features: L10n\.subscription\.[A-Za-z0-9_]+' "$INLINE" \
    | sed 's/.*L10n\.subscription\.//' | sort -u)"
for sym in $inline_bullets; do
    case " $POINTER_BULLETS " in *" $sym "*) continue ;; esac
    if ! echo "$registered" | grep -qx "$sym"; then
        echo "ERROR: the inline buy card in SubscriptionSection.swift pitches"
        echo "       'L10n.subscription.$sym', which is not registered in"
        echo "       scripts/paywall_claims.allow."
        failed=1
    fi
done

# ── 2. every bullet is registered ────────────────────────────────────────────
for sym in $bullets; do
    case " $POINTER_BULLETS " in *" $sym "*) continue ;; esac
    if ! echo "$registered" | grep -qx "$sym"; then
        echo "ERROR: the paywall advertises 'L10n.subscription.$sym' but it is not"
        echo "       registered in scripts/paywall_claims.allow."
        echo
        echo "       Add a line naming the code that withholds this benefit from"
        echo "       the free tier. If no such code exists, the bullet is a claim,"
        echo "       not a feature — delete it instead. Five bullets shipped for"
        echo "       months naming features that were never built; that is what"
        echo "       this check is for."
        failed=1
    fi
done

# ── 3. every registered enforcement site still enforces ──────────────────────
while IFS='|' read -r sym file pattern _note; do
    case "$sym" in \#*|"") continue ;; esac
    sym="$(echo "$sym" | tr -d '[:space:]')"
    [ -z "$sym" ] && continue
    file="$(echo "$file" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    pattern="$(echo "$pattern" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    if ! echo "$bullets" | grep -qx "$sym"; then
        echo "ERROR: scripts/paywall_claims.allow registers '$sym' but the paywall"
        echo "       no longer advertises it. Remove the stale registry line — a"
        echo "       registry that describes a paywall we do not ship is not"
        echo "       evidence of anything."
        failed=1
        continue
    fi

    if [ ! -f "$ROOT/$file" ]; then
        echo "ERROR: '$sym' is advertised on the paywall, but its enforcement file"
        echo "       is gone: $file"
        failed=1
        continue
    fi

    if ! grep -qF -- "$pattern" "$ROOT/$file"; then
        echo "ERROR: '$sym' is advertised on the paywall, but the code that"
        echo "       enforces it is gone."
        echo "         file:    $file"
        echo "         missing: $pattern"
        echo
        echo "       Either restore the gate or stop selling the bullet. Shipping"
        echo "       the bullet without the gate is the exact defect this guard"
        echo "       was written for."
        failed=1
    fi
done < "$ALLOW"

# ── 3b. withdrawn tiers stay withdrawn ───────────────────────────────────────
# v1.52 withdrew Team and Lifetime from sale. Team has no exclusive benefit and
# 7 of its 8 RPCs are absent from production; Lifetime has been MISSING_METADATA
# in App Store Connect since v1.14 and StoreKit never returned it.
#
# The ID CONSTANTS stay (entitlement resolution needs them so existing holders
# keep their tier). What must not come back silently is the OFFER — putting them
# back into `allProductIDs` starts selling them again, and that is a product
# decision, not a refactor.
OFFER_FILE="$ROOT/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SubscriptionManager.swift"
if [ -f "$OFFER_FILE" ]; then
    offer_block="$(awk '/private static let allProductIDs/,/\]/' "$OFFER_FILE")"
    if [ -z "$offer_block" ]; then
        echo "ERROR: could not find 'allProductIDs' in SubscriptionManager.swift."
        echo "       This guard cannot check an offer list it cannot parse."
        failed=1
    else
        for withdrawn in teamMonthlyID teamYearlyID proLifetimeID; do
            if echo "$offer_block" | grep -q "$withdrawn"; then
                echo "ERROR: '$withdrawn' is back in allProductIDs — that puts a withdrawn"
                echo "       tier back on sale."
                echo
                echo "       Team was withdrawn because it has no exclusive benefit and 7 of"
                echo "       its 8 RPCs do not exist in production. Lifetime was withdrawn"
                echo "       because it has been MISSING_METADATA in App Store Connect since"
                echo "       v1.14. If either has genuinely changed, say so in the commit and"
                echo "       remove it from this guard deliberately."
                failed=1
            fi
        done
    fi
fi

# ── 4. the retired claims stay retired ───────────────────────────────────────
# Scan source files only. `CLI Pulse Bar/CLIPulseCore/.build` alone is ~4 GB of
# compiler artifacts and a naive `grep -r` over it runs for minutes; it also
# holds stale copies of the very strings we just deleted, so it would report
# them as "back" forever. `codexbar/` is vendored upstream, not our paywall.
sources="$(find "$ROOT/CLI Pulse Bar" "$ROOT/android" \
    \( -name '.build' -o -name 'build' -o -name 'codexbar' -o -name 'DerivedData' \
       -o -name '.gradle' -o -name 'archive' \) -prune -o \
    -type f \( -name '*.strings' -o -name '*.swift' -o -name '*.kt' -o -name '*.xml' \) \
    -print 2>/dev/null)"

if [ -z "$sources" ]; then
    echo "ERROR: found no source files to scan for retired paywall keys."
    echo "       A scan that looks at nothing always passes; refusing to."
    exit 1
fi

# Each retired claim is searched in BOTH key conventions.
#
# This scan has included `android/`, `*.kt` and `*.xml` since it was written,
# which made it look cross-platform. It was not: RETIRED_KEYS are in Apple's
# dotted form (`subscription.up_to_5_devices`) while Android resources use
# underscores (`subscription_up_to_5_devices`, see
# android/app/src/main/res/values/strings.xml). The literal `grep -F` could
# therefore never match an Android file — the coverage was entirely cosmetic,
# and a retired claim could reappear on Android with the guard staying green.
#
# `subscription.` -> `subscription_` is the whole of the transform; Android
# flattens the namespace separator and keeps the rest verbatim.
while IFS= read -r key; do
    [ -z "$key" ] && continue
    android_key="$(printf '%s' "$key" | tr '.' '_')"
    hits="$(printf '%s\n' "$sources" | tr '\n' '\0' \
        | xargs -0 grep -lF -e "\"$key\"" -e "\"$android_key\"" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
        echo "ERROR: '$key' was deleted in v1.51 because nothing implemented or"
        echo "       enforced it, and it has come back in:"
        echo "$hits" | sed "s|^$ROOT/|         |"
        echo "       (searched as \"$key\" and \"$android_key\")"
        echo "       If the feature now exists, rename the key and register it in"
        echo "       scripts/paywall_claims.allow with its enforcement site."
        failed=1
    fi
done <<EOF
$RETIRED_KEYS
EOF

# ── 5. App Store screenshot captions ─────────────────────────────────────────
# The THIRD purchase surface, and the least forgiving one: caption text is baked
# into an uploaded PNG, so a false claim there cannot be fixed by shipping an app
# update — someone has to regenerate and re-upload the screenshot. It shipped
# "Unlimited providers, devices, and priority support", of which two thirds were
# untrue: nothing enforces a per-tier device limit, and "priority support" exists
# nowhere in the product, the docs or TERMS.md.
#
# Phrase matching, not key matching — these are prose, so there is no symbol to
# register. Deliberately narrow: only the specific claims we retired.
RETIRED_PHRASES="priority support
priority alert
cost analytic
shared alert
admin control
team dashboard
unlimited device
day retention
day data retention"

caption_files="$(find "$ROOT/CLI Pulse Bar/scripts" -maxdepth 1 \
    -name 'compose_appstore*screenshots.py' -print 2>/dev/null)"

if [ -z "$caption_files" ]; then
    echo "ERROR: found no App Store screenshot caption sources to scan."
    echo "       They used to be CLI Pulse Bar/scripts/compose_appstore*.py."
    echo "       A scan that looks at nothing always passes; refusing to."
    failed=1
else
    # Strip `#` comments before matching. The comment above the caption table
    # NAMES the retired phrases in order to explain why they were removed, and a
    # naive grep flags that as a violation — a guard that cannot tell a claim
    # from a note about a claim would force the next person to delete the
    # explanation in order to get CI green.
    while IFS= read -r phrase; do
        [ -z "$phrase" ] && continue
        hits=""
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            if sed 's/#.*$//' "$f" | grep -qie "$phrase"; then
                hits="$hits$f
"
            fi
        done <<CAPTIONFILES
$caption_files
CAPTIONFILES
        hits="$(printf '%s' "$hits" | sed '/^$/d')"
        if [ -n "$hits" ]; then
            echo "ERROR: an App Store screenshot caption claims '$phrase', which was"
            echo "       retired because nothing implements or enforces it:"
            echo "$hits" | sed "s|^$ROOT/|         |"
            echo "       Caption text is baked into an uploaded PNG — it cannot be"
            echo "       fixed later by an app update. Fix the caption here, and"
            echo "       regenerate + re-upload the screenshot."
            failed=1
        fi
    done <<EOF
$RETIRED_PHRASES
EOF
fi

# ── 5b. the App Store description ────────────────────────────────────────────
#
# The FOURTH purchase surface, and the one furthest from the code: the store
# listing itself. Two scripts push it — `appstore_metadata.py` and
# `resubmit.py` — and until v1.52.1 both carried, verbatim:
#
#   "CLI Pulse Pro is available as a monthly ($4.99/month) or yearly
#    ($49.99/year) ... CLI Pulse Team is available as a monthly ($9.99/month)
#    or yearly ($99.99/year) auto-renewable subscription."
#
# Measured against App Store Connect on 2026-08-28, the real USD prices were
# $0.99 / $12.99 / $1.99 / $24.99 — EVERY figure overstated by 4-5x — and the
# paragraph sold the Team tier that v1.52 withdrew. That text was live on the
# store, and was sitting on the 1.52.0 version then in review.
#
# Hardcoded prices in a description cannot help but drift: they are a copy of a
# number that lives in ASC and changes there. So the rule is not "keep them in
# sync", it is "do not state them here at all" — the pattern TERMS.md already
# uses ("shown in the App Store and in the app at the time of purchase").
description_sources="$(find "$ROOT/CLI Pulse Bar/scripts" -maxdepth 1 \
    \( -name 'appstore_metadata.py' -o -name 'resubmit.py' \) -print 2>/dev/null)"

if [ -z "$description_sources" ]; then
    echo "ERROR: found no App Store description sources to scan."
    echo "       A scan that looks at nothing always passes; refusing to."
    exit 1
fi

while IFS= read -r src; do
    [ -z "$src" ] && continue
    rel="${src#"$ROOT"/}"
    body="$(sed 's/#.*$//' "$src")"

    if printf '%s' "$body" | grep -qE '\$[0-9]+\.[0-9]{2}'; then
        echo "ERROR: $rel hardcodes a price in the App Store description."
        printf '%s' "$body" | grep -nE '\$[0-9]+\.[0-9]{2}' | sed 's/^/         /'
        echo "       Prices live in App Store Connect and change there; a copy"
        echo "       here silently goes stale. On 2026-08-28 every figure in this"
        echo "       file was 4-5x the real price. Say what TERMS.md says instead:"
        echo "       pricing is 'shown in the App Store and in the app at the"
        echo "       time of purchase'."
        failed=1
    fi

    if printf '%s' "$body" | grep -qiE 'CLI Pulse Team'; then
        echo "ERROR: $rel sells 'CLI Pulse Team' in the App Store description,"
        echo "       but the tier was withdrawn from sale in v1.52."
        echo "       The store listing is a purchase surface like any other."
        failed=1
    fi
done <<EOF
$description_sources
EOF

if [ "$failed" -ne 0 ]; then
    echo
    echo "Paywall claim check FAILED."
    exit 1
fi

# ── 6. report what was actually checked ──────────────────────────────────────
#
# The old success line counted `advertised` from the paywall bullets and
# `backed` from the allow-file entries — two DIFFERENT sets — and then said
# "$backed of them", which is only true when the counts happen to coincide. It
# also always printed "the rest are pointer bullets: everythingInPro
# lifetimeDescription", including when there was no rest and when neither
# symbol appeared on any paywall (both were removed with the Team card and the
# Lifetime tile in v1.52).
#
# A green line that describes a paywall which no longer exists is how a guard
# stops being read. Both numbers now come from the SAME parsed bullet set.
advertised=0
exempt_seen=""
backed_seen=""
for sym in $bullets; do
    advertised=$((advertised + 1))
    case " $POINTER_BULLETS " in
        *" $sym "*) exempt_seen="$exempt_seen $sym"; continue ;;
    esac
    backed_seen="$backed_seen $sym"
done
backed="$(printf '%s' "$backed_seen" | wc -w | tr -d ' ')"
exempt="$(printf '%s' "$exempt_seen" | wc -w | tr -d ' ')"

echo "check_paywall_claims: OK — $advertised paywall bullet(s); $backed registered" \
     "against a live enforcement site, $exempt exempt as pointer bullets."
[ "$exempt" -gt 0 ] && echo "  pointer bullets in use:$exempt_seen"

# Dead exemptions are how the old message went stale: a symbol stays on the
# exemption list long after it leaves the paywall, and the list quietly becomes
# a description of the past. Advisory, not fatal — an unused exemption is untidy,
# not unsafe.
for sym in $POINTER_BULLETS; do
    case " $bullets " in
        *" $sym "*) ;;
        *) echo "  note: '$sym' is exempted in POINTER_BULLETS but appears on no" \
                "paywall surface — stale exemption, consider removing it." ;;
    esac
done
exit 0

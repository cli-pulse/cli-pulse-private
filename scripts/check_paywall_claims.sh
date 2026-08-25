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

# `everythingInPro` points at the Pro card rather than naming a benefit, so it
# has no enforcement site of its own. It is the only such bullet; anything else
# that wants an exemption should have to argue for it here.
POINTER_BULLETS="everythingInPro"

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

for required in "$PAYWALL" "$ALLOW"; do
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

while IFS= read -r key; do
    [ -z "$key" ] && continue
    hits="$(printf '%s\n' "$sources" | tr '\n' '\0' \
        | xargs -0 grep -lF -- "\"$key\"" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
        echo "ERROR: '$key' was deleted in v1.51 because nothing implemented or"
        echo "       enforced it, and it has come back in:"
        echo "$hits" | sed "s|^$ROOT/|         |"
        echo "       If the feature now exists, rename the key and register it in"
        echo "       scripts/paywall_claims.allow with its enforcement site."
        failed=1
    fi
done <<EOF
$RETIRED_KEYS
EOF

if [ "$failed" -ne 0 ]; then
    echo
    echo "Paywall claim check FAILED."
    exit 1
fi

advertised="$(echo "$bullets" | wc -l | tr -d ' ')"
backed="$(echo "$registered" | wc -l | tr -d ' ')"
echo "check_paywall_claims: OK — $advertised bullets advertised, $backed of them" \
     "registered against a live enforcement site (the rest are pointer bullets:" \
     "$POINTER_BULLETS)."
exit 0

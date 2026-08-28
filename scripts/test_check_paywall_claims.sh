#!/bin/bash
# Negative control for `check_paywall_claims.sh`.
#
# WHY THIS EXISTS
# ---------------
# This repo has shipped four separate guards that were green because they never
# ran or never matched anything (see feedback_guards_that_never_run), and one
# security fix — a column-level REVOKE — that read correctly, passed review, and
# was measured afterwards to be a total no-op. The lesson both times was the
# same: a check that has never been watched to FAIL is not known to work.
#
# So this builds a throwaway copy of only the files the guard reads, mutates it
# nine ways, and asserts the guard rejects each one (plus two positive controls). It also asserts the
# unmutated fixture PASSES — without that positive control, a guard that always
# failed would sail through every case below.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check_paywall_claims.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PAYWALL_REL="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SubscriptionView.swift"
OFFER_REL="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SubscriptionManager.swift"
INLINE_REL="CLI Pulse Bar/CLI Pulse Bar/SubscriptionSection.swift"
CAPTION_REL="CLI Pulse Bar/scripts/compose_appstore_screenshots.py"
STRINGS_REL="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources/en.lproj/Localizable.strings"
# The Android catalog. Until v1.52.1 this suite exercised only the Apple side,
# so the guard's Android coverage was never tested — and it turned out to be
# inert: RETIRED_KEYS are dotted (subscription.up_to_5_devices) while Android
# resources use underscores, so the literal grep could never match.
ANDROID_STRINGS_REL="android/app/src/main/res/values/strings.xml"
# The App Store description sources — the fourth purchase surface. Both
# carried prices 4-5x the real ones and sold the withdrawn Team tier until
# v1.52.1, live on the store and on the version then in review.
METADATA_REL="CLI Pulse Bar/scripts/appstore_metadata.py"
RESUBMIT_REL="CLI Pulse Bar/scripts/resubmit.py"

# Build the fixture: the guard only reads the paywall, the registry, the
# registered enforcement files, and any .swift/.strings/.kt/.xml under the two
# source roots. Copying those alone keeps this fast (the real tree carries ~4 GB
# of build artifacts).
build_fixture() {
    local dest="$1"
    rm -rf "$dest"
    mkdir -p "$dest/scripts"
    cp "$ROOT/scripts/paywall_claims.allow" "$dest/scripts/"
    mkdir -p "$dest/android"
    # every file the registry points at, plus the paywall and one catalog
    {
        echo "$PAYWALL_REL"
        echo "$INLINE_REL"
        echo "$OFFER_REL"
        echo "$STRINGS_REL"
        echo "$ANDROID_STRINGS_REL"
        echo "$METADATA_REL"
        echo "$RESUBMIT_REL"
        # every App Store screenshot caption source — the guard refuses to run
        # if it finds none, so the fixture must carry them all
        (cd "$ROOT" && find "CLI Pulse Bar/scripts" -maxdepth 1 \
            -name 'compose_appstore*screenshots.py' -print)
        grep -v '^[[:space:]]*#' "$ROOT/scripts/paywall_claims.allow" \
            | grep -v '^[[:space:]]*$' | cut -d'|' -f2 \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    } | sort -u | while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        mkdir -p "$dest/$(dirname "$rel")"
        cp "$ROOT/$rel" "$dest/$rel"
    done
}

pass=0
fail=0

# A mutation that silently does nothing turns its case into a no-op that
# "passes" for the wrong reason — which is the same class of bug this whole file
# exists to catch, one level up. Every mutation below is checked to have
# actually changed the fixture before the guard is run against it.
assert_changed() {
    local name="$1" file="$2" before="$3"
    if [ "$before" = "$(shasum "$file" | cut -d' ' -f1)" ]; then
        echo "FAIL: [$name] the mutation changed nothing — this case proves nothing."
        echo "      (the pattern it edits has probably drifted; fix the mutation)"
        fail=$((fail + 1))
        return 1
    fi
    return 0
}

# expect_fail <name> <substring the output must contain> ; fixture pre-mutated
expect_fail() {
    local name="$1" needle="$2"
    local out rc
    out="$(bash "$GUARD" --root "$TMP/case" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: [$name] guard PASSED a tree it should have rejected."
        fail=$((fail + 1))
        return
    fi
    if ! echo "$out" | grep -qF -- "$needle"; then
        echo "FAIL: [$name] guard failed, but not for the expected reason."
        echo "      wanted output containing: $needle"
        echo "      got:"
        echo "$out" | sed 's/^/        /'
        fail=$((fail + 1))
        return
    fi
    echo "ok:   [$name] guard rejected it, for the right reason."
    pass=$((pass + 1))
}

# ── 0. positive control ──────────────────────────────────────────────────────
# If this fails, every expect_fail below is meaningless.
build_fixture "$TMP/case"
if out="$(bash "$GUARD" --root "$TMP/case" 2>&1)"; then
    echo "ok:   [positive control] guard accepts the unmutated fixture."
    pass=$((pass + 1))
else
    echo "FAIL: [positive control] guard rejects the UNMUTATED tree — every"
    echo "      negative case below proves nothing. Output:"
    echo "$out" | sed 's/^/        /'
    fail=$((fail + 1))
fi

# ── 1. a bullet with no registry entry ───────────────────────────────────────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$PAYWALL_REL" | cut -d' ' -f1)"
perl -0pi -e 's/(L10n\.subscription\.unlimitedProviders,)/$1\n                    L10n.subscription.quantumEntanglement,/' \
    "$TMP/case/$PAYWALL_REL"
assert_changed "unregistered bullet" "$TMP/case/$PAYWALL_REL" "$before" \
    && expect_fail "unregistered bullet" "quantumEntanglement"

# ── 2. the enforcement code is deleted, bullet left behind ───────────────────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/CLI Pulse Bar/CLI Pulse Widgets/UsageOverviewWidget.swift" | cut -d' ' -f1)"
perl -0pi -e 's/entry\.data\.isPro == false/entry.data.isPro == nil \&\& false/g' \
    "$TMP/case/CLI Pulse Bar/CLI Pulse Widgets/UsageOverviewWidget.swift"
assert_changed "gate removed, bullet kept" "$TMP/case/CLI Pulse Bar/CLI Pulse Widgets/UsageOverviewWidget.swift" "$before" \
    && expect_fail "gate removed, bullet kept" "the code that"

# ── 3. bullet dropped, registry entry left stale ─────────────────────────────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$PAYWALL_REL" | cut -d' ' -f1)"
# drop a registered bullet from the paywall, leaving its registry line behind
perl -0pi -e 's/,\n\s*L10n\.subscription\.homeScreenWidgets//' "$TMP/case/$PAYWALL_REL"
assert_changed "stale registry entry" "$TMP/case/$PAYWALL_REL" "$before" \
    && expect_fail "stale registry entry" "no longer advertises"

# ── 4. a retired claim comes back ────────────────────────────────────────────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$STRINGS_REL" | cut -d' ' -f1)"
printf '\n"subscription.priority_alerts" = "Priority alerts";\n' \
    >> "$TMP/case/$STRINGS_REL"
assert_changed "retired key resurrected" "$TMP/case/$STRINGS_REL" "$before" \
    && expect_fail "retired key resurrected" "has come back"

# ── 4b. the same claim comes back on ANDROID, in Android's key form ─────────
# The regression this catches: the guard scanned android/, *.kt and *.xml from
# the start, which made it look cross-platform, but it compared only the dotted
# Apple key. A retired claim could reappear in Android resources and the guard
# would stay green. Verified 2026-08-28 that this case FAILS against the
# pre-fix guard and passes after.
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$ANDROID_STRINGS_REL" | cut -d' ' -f1)"
python3 - "$TMP/case/$ANDROID_STRINGS_REL" <<'PLANT'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = '<string name="subscription_title">'
assert anchor in s, "fixture lost the anchor string"
open(p, "w").write(s.replace(
    anchor,
    '<string name="subscription_up_to_5_devices">Up to 5 devices</string>\n    ' + anchor,
    1))
PLANT
assert_changed "retired key resurrected on Android" \
    "$TMP/case/$ANDROID_STRINGS_REL" "$before" \
    && expect_fail "retired key resurrected on Android" "has come back"

# ── 5. the parser stops matching (the guard-that-never-runs failure mode) ────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$PAYWALL_REL" | cut -d' ' -f1)"
perl -0pi -e 's/features: \[/featuresRenamed: [/g' "$TMP/case/$PAYWALL_REL"
assert_changed "parser matches nothing" "$TMP/case/$PAYWALL_REL" "$before" \
    && expect_fail "parser matches nothing" "found no feature bullets"

# ── 6. the second paywall surface pitches a hardcoded literal ───────────────
# This is the case the first version of the guard did not have, which is why
# "Unlimited providers, 5 devices" survived in Settings after being deleted from
# the main paywall. The literal below is the exact one that shipped.
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$INLINE_REL" | cut -d' ' -f1)"
perl -0pi -e 's/features: L10n\.subscription\.unlimitedProviders/features: "Unlimited providers, 5 devices"/' \
    "$TMP/case/$INLINE_REL"
assert_changed "inline card literal" "$TMP/case/$INLINE_REL" "$before" \
    && expect_fail "inline card literal" "hardcoded string literals"

# ── 7. the second surface pitches an unregistered bullet ────────────────────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$INLINE_REL" | cut -d' ' -f1)"
perl -0pi -e 's/features: L10n\.subscription\.unlimitedProviders/features: L10n.subscription.quantumEntanglement/' \
    "$TMP/case/$INLINE_REL"
assert_changed "inline card unregistered bullet" "$TMP/case/$INLINE_REL" "$before" \
    && expect_fail "inline card unregistered bullet" "quantumEntanglement"

# ── 8. a retired claim comes back in a screenshot caption ──────────────────
# The third purchase surface, and the least forgiving: caption text is baked
# into an uploaded PNG, so a false claim there survives every app update. The
# string below is the one that actually shipped.
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$CAPTION_REL" | cut -d' ' -f1)"
perl -0pi -e 's/"Unlimited providers — track every tool you use"/"Unlimited providers, devices, and priority support"/' \
    "$TMP/case/$CAPTION_REL"
assert_changed "screenshot caption claim" "$TMP/case/$CAPTION_REL" "$before" \
    && expect_fail "screenshot caption claim" "screenshot caption claims"

# ── 9. the caption scan silently matches nothing ───────────────────────────
# Same failure mode as case 5, one surface over: if the compose scripts move or
# get renamed, a phrase scan over zero files passes forever.
build_fixture "$TMP/case"
rm -f "$TMP/case/CLI Pulse Bar/scripts/"compose_appstore*screenshots.py
expect_fail "caption scan matches nothing" "found no App Store screenshot caption sources"

# ── 10. the caption check must not trip over a comment ABOUT a claim ────────
# The caption table carries a comment naming the retired phrases to explain why
# they went. A guard that cannot tell a claim from a note about a claim would
# force the next person to delete the explanation to get CI green. This is a
# POSITIVE case: the guard must still pass.
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$CAPTION_REL" | cut -d' ' -f1)"
perl -0pi -e 's/^(COPY = \{)/# note: we deliberately no longer promise priority support or unlimited devices\n$1/m' \
    "$TMP/case/$CAPTION_REL"
if assert_changed "comment mentioning retired claims" "$TMP/case/$CAPTION_REL" "$before"; then
    if out="$(bash "$GUARD" --root "$TMP/case" 2>&1)"; then
        echo "ok:   [comment mentioning retired claims] guard correctly ignored a comment."
        pass=$((pass + 1))
    else
        echo "FAIL: [comment mentioning retired claims] guard flagged a COMMENT as a claim."
        echo "$out" | sed 's/^/        /'
        fail=$((fail + 1))
    fi
fi

# ── 11. a withdrawn tier goes back on sale ─────────────────────────────────
# v1.52 withdrew Team and Lifetime. The ID constants stay (existing holders
# must keep their entitlement), so the only thing standing between "withdrawn"
# and "on sale again" is one line of `allProductIDs` — exactly the kind of
# one-token reversal that slips through review.
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$OFFER_REL" | cut -d' ' -f1)"
perl -0pi -e 's/^(\s*)proMonthlyID, proYearlyID$/$1proMonthlyID, proYearlyID, proLifetimeID/m' \
    "$TMP/case/$OFFER_REL"
assert_changed "withdrawn tier back on sale" "$TMP/case/$OFFER_REL" "$before" \
    && expect_fail "withdrawn tier back on sale" "back in allProductIDs"

# ── 12. the offer list stops being parseable ───────────────────────────────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$OFFER_REL" | cut -d' ' -f1)"
perl -0pi -e 's/private static let allProductIDs/private static let offeredProductIDs/' \
    "$TMP/case/$OFFER_REL"
assert_changed "offer list unparseable" "$TMP/case/$OFFER_REL" "$before" \
    && expect_fail "offer list unparseable" "could not find"

echo
# ── 4c. a hardcoded price returns to the App Store description ──────────────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$METADATA_REL" | cut -d' ' -f1)"
python3 - "$TMP/case/$METADATA_REL" <<'PLANT'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "CLI Pulse Pro is available as an auto-renewing subscription."
assert anchor in s, "fixture lost the description anchor"
open(p, "w").write(s.replace(
    anchor, "CLI Pulse Pro is available for $4.99/month.", 1))
PLANT
assert_changed "hardcoded price in store description" \
    "$TMP/case/$METADATA_REL" "$before" \
    && expect_fail "hardcoded price in store description" "hardcodes a price"

# ── 4d. the withdrawn Team tier returns to the App Store description ─────────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$RESUBMIT_REL" | cut -d' ' -f1)"
python3 - "$TMP/case/$RESUBMIT_REL" <<'PLANT'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "CLI Pulse Pro is available as an auto-renewing subscription."
assert anchor in s, "fixture lost the description anchor"
open(p, "w").write(s.replace(
    anchor, anchor + " CLI Pulse Team is also available.", 1))
PLANT
assert_changed "withdrawn Team tier in store description" \
    "$TMP/case/$RESUBMIT_REL" "$before" \
    && expect_fail "withdrawn Team tier in store description" "withdrawn from sale"

echo "test_check_paywall_claims: $pass passed, $fail failed."
[ "$fail" -eq 0 ] || exit 1
exit 0

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
# five ways, and asserts the guard rejects each one. It also asserts the
# unmutated fixture PASSES — without that positive control, a guard that always
# failed would sail through every case below.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check_paywall_claims.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PAYWALL_REL="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SubscriptionView.swift"
STRINGS_REL="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources/en.lproj/Localizable.strings"

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
        echo "$STRINGS_REL"
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

# ── 5. the parser stops matching (the guard-that-never-runs failure mode) ────
build_fixture "$TMP/case"
before="$(shasum "$TMP/case/$PAYWALL_REL" | cut -d' ' -f1)"
perl -0pi -e 's/features: \[/featuresRenamed: [/g' "$TMP/case/$PAYWALL_REL"
assert_changed "parser matches nothing" "$TMP/case/$PAYWALL_REL" "$before" \
    && expect_fail "parser matches nothing" "found no feature bullets"

echo
echo "test_check_paywall_claims: $pass passed, $fail failed."
[ "$fail" -eq 0 ] || exit 1
exit 0

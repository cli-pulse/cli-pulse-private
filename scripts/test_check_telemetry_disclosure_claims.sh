#!/bin/bash
# Negative controls for check_telemetry_disclosure_claims.py.
#
# The guard's whole claim is that a payload field cannot ship without the
# disclosure mentioning it. That claim is worth exactly the proof that it
# fires, so every failure mode is planted here and must be caught FOR THE
# STATED REASON.
#
# The POSITIVE control is not optional: a guard that rejects every tree looks
# identical to a guard that works.
#
# `assert_changed` scores a no-op plant as a failure rather than a catch.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check_telemetry_disclosure_claims.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

CORE="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore"
RES="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources"
APP="CLI Pulse Bar/CLI Pulse Bar"

build_fixture() {
    local dest="$1"
    rm -rf "$dest"
    mkdir -p "$dest/$CORE" "$dest/$APP" "$dest/scripts"

    cat > "$dest/$CORE/AnonymousInstallTelemetry.swift" <<'SWIFT'
public struct AnonymousInstallPayload: Encodable {
    enum CodingKeys: String, CodingKey {
        case installID = "p_install_id"
        case channel = "p_channel"
        case providerDetected = "p_provider_detected"
        case helperConnected = "p_helper_connected"
    }
}
SWIFT

    mkdir -p "$dest/$RES/en.lproj"
    cat > "$dest/$APP/AnonymousTelemetryDisclosureCard.swift" <<'SWIFT'
Text(L10n.telemetry.disclosureBody)
SWIFT

    cat > "$dest/$APP/PrivacySettingsSection.swift" <<'SWIFT'
Text(L10n.telemetry.settingsBody)
SWIFT

    cat > "$dest/$RES/en.lproj/Localizable.strings" <<'STRINGS'
"telemetry.disclosure_body" = "CLI Pulse reports how far it got: that it was installed, whether the helper connected, and whether it ever found a CLI to track. That is how we tell where the app stops working for people, with no account involved anywhere at all.";
"telemetry.disclosure_body_local_only" = "Local-only mode is on, so nothing is sent at all right now.";
"telemetry.not_collected" = "No file paths, project names or provider names. The id is random and is deleted when you uninstall.";
"telemetry.settings_body" = "How far the app got, with no account: that it was installed, whether the helper connected, and whether it ever found a CLI to track.";
STRINGS

    cat > "$dest/scripts/telemetry_disclosure.allow" <<'ALLOW'
# fixture registry
channel          | installed        | channel
providerDetected | found a          | provider
helperConnected  | helper connected | helper
ALLOW
}

assert_changed() {
    local name="$1" file="$2" before="$3" after
    after="$(shasum "$file" | cut -d' ' -f1)"
    if [ "$before" = "$after" ]; then
        echo "FAIL: [$name] mutation was a NO-OP — the case proves nothing."
        fail=$((fail + 1)); return 1
    fi
    return 0
}

expect_fail() {
    local name="$1" needle="$2" out rc
    out="$(python3 "$GUARD" --root "$TMP/case" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: [$name] guard PASSED a tree it should have rejected."
        fail=$((fail + 1)); return
    fi
    if ! printf '%s' "$out" | grep -qF "$needle"; then
        echo "FAIL: [$name] guard failed (rc=$rc), but not for the expected reason."
        echo "      wanted substring: $needle"
        echo "      got: $out"
        fail=$((fail + 1)); return
    fi
    echo "ok:   [$name] guard rejected it, for the right reason."
    pass=$((pass + 1))
}

# ── positive control ────────────────────────────────────────────────────────
build_fixture "$TMP/case"
if python3 "$GUARD" --root "$TMP/case" >/dev/null 2>&1; then
    echo "ok:   [positive control] guard accepts a fully disclosed payload."
    pass=$((pass + 1))
else
    echo "FAIL: [positive control] guard rejected a clean tree."
    python3 "$GUARD" --root "$TMP/case" 2>&1 | sed 's/^/      /'
    fail=$((fail + 1))
fi

# ── 1. a new field with no registry entry — collected without consent ───────
build_fixture "$TMP/case"
F="$TMP/case/$CORE/AnonymousInstallTelemetry.swift"
B="$(shasum "$F" | cut -d' ' -f1)"
perl -0pi -e 's/(case helperConnected = "p_helper_connected"\n)/$1        case uiLanguage = "p_ui_language"\n/' "$F"
assert_changed "unregistered field" "$F" "$B" && expect_fail "unregistered field" "uiLanguage"

# ── 2. the shipped copy stopped disclosing a field ─────────────────────────
#    The real 2026-08-30 defect: both surfaces said "two things" while the
#    payload carried more. Now that the copy lives in one catalogue, dropping
#    the phrase there is that same defect in its new home.
build_fixture "$TMP/case"
F="$TMP/case/$RES/en.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
perl -pi -e 's/whether the helper connected, and //g' "$F"
assert_changed "copy dropped a field" "$F" "$B" && expect_fail "copy dropped a field" "helperConnected"

# ── 3. a surface stopped RENDERING the copy ────────────────────────────────
#    The failure the catalogue check ALONE cannot see: every string is present
#    and correct, and the user is shown none of them.
build_fixture "$TMP/case"
F="$TMP/case/$APP/PrivacySettingsSection.swift"
B="$(shasum "$F" | cut -d' ' -f1)"
printf 'Text("hardcoded English again")\n' > "$F"
assert_changed "surface stopped rendering" "$F" "$B" && expect_fail "surface stopped rendering" "no longer renders"

# ── 4. a stale registry row reads as coverage ──────────────────────────────
build_fixture "$TMP/case"
F="$TMP/case/scripts/telemetry_disclosure.allow"
B="$(shasum "$F" | cut -d' ' -f1)"
printf 'costShown | cost to show | removed field\n' >> "$F"
assert_changed "stale registry row" "$F" "$B" && expect_fail "stale registry row" "costShown"

# ── 5. an extra conformance must NOT look like a missing block ─────────────
#    The first version of the guard pinned `String, CodingKey {` exactly and
#    went FATAL the moment `CaseIterable` was added. A guard that mistakes its
#    own parser breaking for a verdict is worse than no guard: it fails loudly
#    on a correct tree and teaches people to ignore it.
build_fixture "$TMP/case"
F="$TMP/case/$CORE/AnonymousInstallTelemetry.swift"
B="$(shasum "$F" | cut -d' ' -f1)"
perl -pi -e 's/enum CodingKeys: String, CodingKey \{/enum CodingKeys: String, CodingKey, CaseIterable {/' "$F"
if assert_changed "extra conformance" "$F" "$B"; then
    if python3 "$GUARD" --root "$TMP/case" >/dev/null 2>&1; then
        echo "ok:   [extra conformance] guard still parses the block."
        pass=$((pass + 1))
    else
        echo "FAIL: [extra conformance] guard broke on its own parser."
        python3 "$GUARD" --root "$TMP/case" 2>&1 | sed 's/^/      /'
        fail=$((fail + 1))
    fi
fi

# ── 6. a broken parse must not be a silent pass ────────────────────────────
build_fixture "$TMP/case"
cat > "$TMP/case/$CORE/AnonymousInstallTelemetry.swift" <<'SWIFT'
public struct AnonymousInstallPayload: Encodable {}
SWIFT
expect_fail "no CodingKeys block" "no AnonymousInstallPayload CodingKeys block"

# ── 6b. the catalogue going missing must not be a silent pass ─────────────
build_fixture "$TMP/case"
rm "$TMP/case/$RES/en.lproj/Localizable.strings"
expect_fail "catalogue deleted" "catalogue missing"

# ── 7. a disclosure surface going missing must not be a silent pass ────────
build_fixture "$TMP/case"
rm "$TMP/case/$APP/PrivacySettingsSection.swift"
expect_fail "surface deleted" "disclosure surface missing"

echo
echo "check_telemetry_disclosure_claims negative controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

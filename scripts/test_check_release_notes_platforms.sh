#!/bin/bash
# Negative controls for check_release_notes_platforms.sh.
#
# The guard it tests exists because macOS 1.52.0 was rejected under Guideline
# 2.3.10 for an Android mention in the release notes. A guard written in
# response to a rejection is worth exactly as much as the proof that it fires,
# so every forbidden term gets planted and every plant must be caught.
#
# Includes the POSITIVE control — the unmutated fixture must PASS — because
# without it a guard that rejects everything would look identical to a guard
# that works.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check_release_notes_platforms.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

build_fixture() {
    local dest="$1"
    rm -rf "$dest"
    mkdir -p "$dest/whatsnew_test"
    cat > "$dest/whatsnew_test/en-US.txt" <<'NOTE'
We were selling two things we cannot deliver. They are gone.

• Removed: the Team plan. It never had a feature Pro did not already include.

• Fixed: purchases that could not be confirmed with our server failed silently.
NOTE
}

# assert the mutation actually changed the file — a no-op plant would make the
# guard "pass" for the wrong reason and the case would prove nothing.
assert_changed() {
    local name="$1" file="$2" before="$3"
    local after; after="$(shasum "$file" | cut -d' ' -f1)"
    if [ "$before" = "$after" ]; then
        echo "FAIL: [$name] mutation was a NO-OP — the case proves nothing."
        fail=$((fail + 1)); return 1
    fi
    return 0
}

expect_fail() {
    local name="$1" needle="$2" out
    out="$(bash "$GUARD" --root "$TMP/case" 2>&1)"
    if [ $? -eq 0 ]; then
        echo "FAIL: [$name] guard PASSED a tree it should have rejected."
        fail=$((fail + 1)); return
    fi
    if ! printf '%s' "$out" | grep -qF "$needle"; then
        echo "FAIL: [$name] guard failed, but not for the expected reason."
        echo "      wanted substring: $needle"
        fail=$((fail + 1)); return
    fi
    echo "ok:   [$name] guard rejected it, for the right reason."
    pass=$((pass + 1))
}

# ── positive control ────────────────────────────────────────────────────────
build_fixture "$TMP/case"
if bash "$GUARD" --root "$TMP/case" >/dev/null 2>&1; then
    echo "ok:   [positive control] guard accepts clean release notes."
    pass=$((pass + 1))
else
    echo "FAIL: [positive control] guard rejected a clean tree."
    fail=$((fail + 1))
fi

# ── every forbidden term must be caught ─────────────────────────────────────
while IFS='|' read -r label sentence; do
    [ -z "$label" ] && continue
    build_fixture "$TMP/case"
    before="$(shasum "$TMP/case/whatsnew_test/en-US.txt" | cut -d' ' -f1)"
    printf '\n• %s\n' "$sentence" >> "$TMP/case/whatsnew_test/en-US.txt"
    assert_changed "$label" "$TMP/case/whatsnew_test/en-US.txt" "$before" \
        && expect_fail "$label" "mentions"
done <<'CASES'
Android|Removed on Android: the option to subscribe.
Google Play|Also fixed on Google Play billing.
Play Store|Now available in the Play Store.
Windows|The Windows desktop app gets the same fix.
Linux|Linux users are unaffected.
CASES

# ── characters App Store Connect refuses or has never taken ─────────────────
# The first case is the 1.57 iOS What's New as App Store Connect refused it on
# 2026-10-20 (409 INVALID_CHARACTERS, "✕"). Each plant must be caught, with the
# code point named so an invisible one can be found.
while IFS='|' read -r label sentence needle; do
    [ -z "$label" ] && continue
    build_fixture "$TMP/case"
    before="$(shasum "$TMP/case/whatsnew_test/en-US.txt" | cut -d' ' -f1)"
    printf '\n• %b\n' "$sentence" >> "$TMP/case/whatsnew_test/en-US.txt"
    assert_changed "$label" "$TMP/case/whatsnew_test/en-US.txt" "$before" \
        && expect_fail "$label" "$needle"
done <<'CASES'
the ✕ App Store Connect refused in 1.57|Tap the day again, or ✕, to close the list.|U+2715 MULTIPLICATION X): App Store Connect refused it
a backtick (refused in 1.18.0)|Run `codex exec --json` once.|U+0060 GRAVE ACCENT), 2 times: App Store Connect refused it
an emoji|New: Pulse Cat 🐱|U+1F431
an arrow the store has never taken|Settings → Privacy.|U+2192 RIGHTWARDS ARROW): not among the characters
a zero-width space|Usage\xe2\x80\x8bhistory.|U+200B ZERO WIDTH SPACE
a full-width digit|Fixed 1 crash, then ２ more.|a compatibility form of '2'
CASES

# The same character in a file under release/ (the 1.45-1.47 notes, which
# nothing sends to App Store Connect any more) is left to the platform check.
build_fixture "$TMP/case"
mkdir -p "$TMP/case/release/whatsnew_145"
printf 'Settings > Privacy.\n' > "$TMP/case/release/whatsnew_145/en-US.txt"
if bash "$GUARD" --root "$TMP/case" >/dev/null 2>&1; then
    echo "ok:   [release/ notes] the character check leaves the archived notes alone."
    pass=$((pass + 1))
else
    echo "FAIL: [release/ notes] the character check refused an archived note."
    fail=$((fail + 1))
fi
printf '\n• Also on Android.\n' >> "$TMP/case/release/whatsnew_145/en-US.txt"
expect_fail "Android in an archived note (the platform check still reads release/)" "release/whatsnew_145/en-US.txt mentions 'Android'"

# ── the guard must refuse to scan nothing ───────────────────────────────────
rm -rf "$TMP/empty"; mkdir -p "$TMP/empty"
out="$(bash "$GUARD" --root "$TMP/empty" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "found no whatsnew"; then
    echo "ok:   [scans nothing] guard refused rather than passing vacuously."
    pass=$((pass + 1))
else
    echo "FAIL: [scans nothing] guard passed with no files to scan."
    fail=$((fail + 1))
fi

echo
echo "test_check_release_notes_platforms: $pass passed, $fail failed."
[ "$fail" -eq 0 ]

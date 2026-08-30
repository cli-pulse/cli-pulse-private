#!/bin/bash
# Negative controls for check_apple_strings_parity.py.
#
# This repo has shipped five guards that were green while guarding nothing, so
# a new guard is worth exactly the proof that it fires. Every failure mode the
# gate claims to catch is planted here and must be caught FOR THE STATED
# REASON — a guard that fails for the wrong reason is not evidence.
#
# The POSITIVE control is not optional either: without it, a gate that rejects
# every tree looks identical to a gate that works.
#
# Each case runs against a fixture tree via --root. `assert_changed` proves the
# mutation actually landed, so a no-op plant can never be scored as a catch.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check_apple_strings_parity.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

RES="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources"

build_fixture() {
    local dest="$1"
    rm -rf "$dest"
    mkdir -p "$dest/$RES/en.lproj" "$dest/$RES/es.lproj" "$dest/$RES/ja.lproj" "$dest/scripts"

    cat > "$dest/$RES/en.lproj/Localizable.strings" <<'STRINGS'
/* CLI Pulse — English (Base) */
"tab.overview" = "Overview";
"tab.settings" = "Settings";
"wizard.welcome" = "Welcome";
STRINGS

    # es is deliberately one key short — that gap is the baselined debt.
    cat > "$dest/$RES/es.lproj/Localizable.strings" <<'STRINGS'
/* CLI Pulse — Español */
"tab.overview" = "Resumen";
"tab.settings" = "Ajustes";
STRINGS

    cat > "$dest/$RES/ja.lproj/Localizable.strings" <<'STRINGS'
/* CLI Pulse — 日本語 */
"tab.overview" = "概要";
"tab.settings" = "設定";
"wizard.welcome" = "ようこそ";
STRINGS

    cat > "$dest/scripts/apple_strings_parity_baseline.json" <<'JSON'
{
  "_comment": ["fixture baseline"],
  "missing": {
    "es": ["wizard.welcome"]
  }
}
JSON
}

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
    echo "ok:   [positive control] guard accepts a tree whose only gap is baselined."
    pass=$((pass + 1))
else
    echo "FAIL: [positive control] guard rejected a clean tree."
    python3 "$GUARD" --root "$TMP/case" 2>&1 | sed 's/^/      /'
    fail=$((fail + 1))
fi

# ── 1. new key added to en only — the regression that made the 670 ──────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/en.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"wizard.finish" = "Finish";\n' >> "$F"
assert_changed "new en key" "$F" "$B" && expect_fail "new en key" "wizard.finish"

# ── 2. a translation deleted from a locale ─────────────────────────────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/ja.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
grep -v 'tab.settings' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
assert_changed "deleted translation" "$F" "$B" && expect_fail "deleted translation" "tab.settings"

# ── 3. stale baseline — the key got translated, the entry stayed ────────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/es.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"wizard.welcome" = "Bienvenido";\n' >> "$F"
assert_changed "stale baseline" "$F" "$B" && expect_fail "stale baseline" "no longer missing"

# ── 4. orphan — a key in a locale that en does not have ────────────────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/ja.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"wizard.only_in_ja" = "日本語だけ";\n' >> "$F"
assert_changed "orphan key" "$F" "$B" && expect_fail "orphan key" "wizard.only_in_ja"

# ── 5. duplicate key — .strings keeps the last, silently ───────────────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/ja.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"tab.overview" = "概要(2)";\n' >> "$F"
assert_changed "duplicate key" "$F" "$B" && expect_fail "duplicate key" "declared more than once"

# ── 6. the baseline itself going missing must not be a silent pass ─────────
build_fixture "$TMP/case"
rm "$TMP/case/scripts/apple_strings_parity_baseline.json"
expect_fail "absent baseline" "baseline missing"

# ── 7. an empty resources tree must not be a silent pass ──────────────────
build_fixture "$TMP/case"
rm -rf "$TMP/case/$RES/es.lproj" "$TMP/case/$RES/ja.lproj"
expect_fail "single locale" "nothing to compare"

echo
echo "check_apple_strings_parity negative controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

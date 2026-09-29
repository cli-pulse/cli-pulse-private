#!/bin/bash
# Negative controls for scripts/update_cask.sh's style check.
#
# WHY THIS EXISTS
# ---------------
# On 2026-09-28 (1.54.0) update_cask.sh printed "==> brew style", Homebrew
# answered "Error: Homebrew requires casks to be in a tap, rejecting: …", and
# the script still exited 0: `brew style --cask "$CASK" || echo …` had turned
# the refusal into a note. The check had not run, and nothing said so.
#
# So this runs the real script in a throwaway tree, with stand-ins for `gh`
# (serves a fixture "DMG") and `brew` (answers like Homebrew does), and asserts
# that every way the style check can fail or not run fails the script with the
# repo's cask left unchanged, and that the clean run updates it. When Homebrew
# is installed it also runs the REAL `brew style` on the cask this script
# writes, clean and broken; on a machine without it (CI) those cases say
# NOT RUN rather than pass.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CASE="$TMP/case"
FAKEBIN="$TMP/bin"
NOBREWBIN="$TMP/bin-nobrew"
mkdir -p "$FAKEBIN" "$NOBREWBIN"

# The fixture "DMG": any bytes will do, the script only hashes them.
printf 'not really a dmg\n' > "$TMP/fixture.dmg"
WANT_SHA="$(shasum -a 256 "$TMP/fixture.dmg" | awk '{print $1}')"

# gh: `release download <tag> --repo R --pattern P --dir D` copies the fixture
# to D/P, unless FAKE_GH=missing.
cat > "$FAKEBIN/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$FAKE_LOG"
[ "${FAKE_GH:-ok}" = missing ] && exit 1
dir=""; pat=""
while [ $# -gt 0 ]; do
    case "$1" in --dir) dir="$2"; shift ;; --pattern) pat="$2"; shift ;; esac
    shift
done
cp "$FAKE_DMG" "$dir/$pat"
SH
# brew: answers `brew style …` the way Homebrew does, per FAKE_BREW, and keeps
# a copy of the file it was asked to check.
cat > "$FAKEBIN/brew" <<'SH'
#!/bin/bash
echo "brew $*" >> "$FAKE_LOG"
for a in "$@"; do [ -f "$a" ] && cp "$a" "$FAKE_SEEN" && echo "$a" > "$FAKE_SEEN.path"; done
case "${FAKE_BREW:-clean}" in
    clean)   printf '\n1 file inspected, no offenses detected\n'; exit 0 ;;
    offense) printf 'Casks/cli-pulse.rb:16:9: C: [Correctable] Cask/Desc: Description shouldn'"'"'t start with an article.\n\n1 file inspected, 1 offense detected, 1 offense autocorrectable\n'; exit 1 ;;
    tap)     printf 'Error: Homebrew requires casks to be in a tap, rejecting:\n  %s\n' "$2"; exit 1 ;;
    tap0)    printf 'Error: Homebrew requires casks to be in a tap, rejecting:\n  %s\n' "$2"; exit 0 ;;
    silent)  exit 0 ;;
esac
SH
cp "$FAKEBIN/gh" "$NOBREWBIN/gh"
chmod +x "$FAKEBIN/gh" "$FAKEBIN/brew" "$NOBREWBIN/gh"

export FAKE_LOG="$TMP/calls.log" FAKE_DMG="$TMP/fixture.dmg" FAKE_SEEN="$TMP/seen.rb"

# The tree: the script and the cask, the cask set back to an older version so
# that the run has something to change.
build_fixture() {
    rm -rf "$CASE" "$FAKE_LOG" "$FAKE_SEEN" "$FAKE_SEEN.path"
    mkdir -p "$CASE/scripts" "$CASE/Casks"
    cp "$ROOT/scripts/update_cask.sh" "$CASE/scripts/"
    python3 - "$ROOT/Casks/cli-pulse.rb" "$CASE/Casks/cli-pulse.rb" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'^(\s*version\s+)"[^"]*"', r'\g<1>"1.0.0"', s, count=1, flags=re.M)
s = re.sub(r'^(\s*sha256\s+)"[^"]*"', r'\g<1>"' + "0" * 64 + '"', s, count=1, flags=re.M)
open(sys.argv[2], "w").write(s)
PY
    cp "$CASE/Casks/cli-pulse.rb" "$TMP/before.rb"
}

pass=0
fail=0
notrun=0
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; sed 's/^/        /' "$TMP/out"; fail=$((fail + 1)); }

# run_script <PATH> <args...>
run_script() {
    local path="$1"; shift
    PATH="$path" bash "$CASE/scripts/update_cask.sh" "$@" >"$TMP/out" 2>&1
}
cask_unchanged() { cmp -s "$TMP/before.rb" "$CASE/Casks/cli-pulse.rb"; }
cask_updated() {
    grep -q '^  version "1.54.0"$' "$CASE/Casks/cli-pulse.rb" \
        && grep -q "^  sha256 \"$WANT_SHA\"$" "$CASE/Casks/cli-pulse.rb"
}
WITH_BREW="$FAKEBIN:/usr/bin:/bin"
NO_BREW="$NOBREWBIN:/usr/bin:/bin"

# ── positive control ─────────────────────────────────────────────────────────
build_fixture
if FAKE_BREW=clean run_script "$WITH_BREW" 1.54.0 && cask_updated; then
    ok "a clean style run updates the cask to the release's version and sha256"
else
    bad "a clean style run updates the cask to the release's version and sha256"
fi
if grep -qx "brew style $(cat "$FAKE_SEEN.path" 2>/dev/null)" "$FAKE_LOG" \
        && ! grep -q -- "--cask" "$FAKE_LOG"; then
    ok "... brew is asked for 'style <file>', not 'style --cask' (refused outside a tap)"
else
    bad "... brew is asked for 'style <file>', not 'style --cask' (refused outside a tap)"
fi
case "$(cat "$FAKE_SEEN.path" 2>/dev/null)" in
    */Casks/cli-pulse.rb) ok "... the file checked sits in a directory named Casks (cask cops apply)" ;;
    *) bad "... the file checked sits in a directory named Casks (cask cops apply)" ;;
esac
if grep -q '^  version "1.54.0"$' "$FAKE_SEEN" 2>/dev/null; then
    ok "... and it is the NEW cask that was checked, not the old one"
else
    bad "... and it is the NEW cask that was checked, not the old one"
fi
if grep -q "check_release_surfaces.sh 1.54.0" "$TMP/out" && grep -q "core.hooksPath=/dev/null" "$TMP/out"; then
    ok "... and the next steps name the tap push with hooks off and the surfaces check"
else
    bad "... and the next steps name the tap push with hooks off and the surfaces check"
fi

# ── every way the check can fail, or not run ─────────────────────────────────
# expect_refused <name> <FAKE_BREW> <PATH> <substring> [args...]
expect_refused() {
    local name="$1" mode="$2" path="$3" why="$4"; shift 4
    build_fixture
    if FAKE_BREW="$mode" run_script "$path" 1.54.0 "$@"; then
        bad "$name: the script exited 0"
    elif ! grep -qF -- "$why" "$TMP/out"; then
        bad "$name: failed, but not for '$why'"
    elif ! cask_unchanged; then
        bad "$name: failed, but Casks/cli-pulse.rb was changed anyway"
    else
        ok "$name: fails, cask unchanged"
    fi
}
expect_refused "brew style finds an offense" offense "$WITH_BREW" "brew style found problems"
expect_refused "Homebrew refuses the file (the 1.54.0 case)" tap "$WITH_BREW" \
    "refused to style-check the cask outside a tap"
expect_refused "Homebrew refuses the file but exits 0" tap0 "$WITH_BREW" \
    "refused to style-check the cask outside a tap"
expect_refused "brew style exits 0 without inspecting anything" silent "$WITH_BREW" \
    "without saying it inspected the cask"
expect_refused "no Homebrew installed" clean "$NO_BREW" "brew is not installed"

build_fixture
if run_script "$NO_BREW" 1.54.0 --skip-style && cask_updated \
        && grep -q "NOT CHECKED (--skip-style)" "$TMP/out"; then
    ok "--skip-style without Homebrew: updates the cask and says the style is NOT CHECKED"
else
    bad "--skip-style without Homebrew: updates the cask and says the style is NOT CHECKED"
fi

build_fixture
if FAKE_GH=missing run_script "$WITH_BREW" 1.54.0; then
    bad "a release without the DMG: the script exited 0"
elif grep -q "has no asset" "$TMP/out" && cask_unchanged; then
    ok "a release without the DMG: fails, cask unchanged"
else
    bad "a release without the DMG: fails, cask unchanged"
fi

build_fixture
run_script "$WITH_BREW"; rc=$?
if [ "$rc" -eq 2 ] && cask_unchanged; then ok "no version: usage error (exit 2)"; else bad "no version: usage error (exit 2)"; fi
run_script "$WITH_BREW" 1.54.0 1.55.0; rc=$?
if [ "$rc" -eq 2 ] && cask_unchanged; then ok "two versions: usage error (exit 2)"; else bad "two versions: usage error (exit 2)"; fi

# ── the real brew style ──────────────────────────────────────────────────────
# Only Homebrew knows its cops; the stand-in above only knows what it answers.
# Here the gh stand-in serves the DMG and the real brew does the checking.
if REAL_BREW="$(command -v brew)"; then
    REALBIN="$TMP/bin-real"
    mkdir -p "$REALBIN"
    cp "$FAKEBIN/gh" "$REALBIN/gh"
    ln -s "$REAL_BREW" "$REALBIN/brew"
    REAL_PATH="$REALBIN:/usr/bin:/bin"

    build_fixture
    if run_script "$REAL_PATH" 1.54.0 && cask_updated \
            && grep -q "1 file inspected, no offenses detected" "$TMP/out"; then
        ok "real brew style: the committed cask's template passes"
    else
        bad "real brew style: the committed cask's template passes"
    fi

    build_fixture
    python3 - "$CASE/Casks/cli-pulse.rb" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
new = s.replace('desc "Menu bar app', 'desc "A menu bar app', 1)
assert new != s, "the mutation target moved; update this case"
open(p, "w").write(new)
PY
    cp "$CASE/Casks/cli-pulse.rb" "$TMP/before.rb"
    if run_script "$REAL_PATH" 1.54.0; then
        bad "real brew style: a desc starting with an article fails"
    elif grep -q "Cask/Desc" "$TMP/out" && cask_unchanged; then
        ok "real brew style: a desc starting with an article fails (Cask/Desc), cask unchanged"
    else
        bad "real brew style: a desc starting with an article fails (Cask/Desc), cask unchanged"
    fi
else
    echo "NOT RUN: real brew style (Homebrew is not installed here; the stand-in cases above ran)"
    notrun=$((notrun + 2))
fi

echo "test_update_cask: $pass passed, $fail failed, $notrun not run."
[ "$fail" -eq 0 ] || exit 1
exit 0

#!/bin/bash
# Negative controls for `asc_listing_preflight.py --texts-only`, i.e. for the
# listing-text checks in scripts/appstore_listing.py.
#
# WHY THIS EXISTS
# ---------------
# A check that has never been watched to fail is not known to work — this repo
# has shipped guards that were green because they never matched anything (see
# test_check_paywall_claims.sh for the history). So this copies the listing
# texts and the pushers into a throwaway tree, breaks them one way at a time,
# and asserts the check rejects each break FOR THE RIGHT REASON. It also asserts
# the unmodified copy passes: without that positive control, a check that
# always failed would sail through every case below — and the positive control
# is also the false-positive test, since it runs the English-leftover heuristic
# over all five real translations.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$ROOT/scripts/asc_listing_preflight.py"
LISTING_REL="CLI Pulse Bar/appstore"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CASE="$TMP/case"

PUSHERS="$(cd "$ROOT" && python3 -c '
import sys; sys.path.insert(0, "scripts")
import appstore_listing as l; print("\n".join(l.PUSHERS_REL))')"

build_fixture() {
    rm -rf "$CASE"
    mkdir -p "$CASE/$LISTING_REL"
    cp -R "$ROOT/$LISTING_REL/." "$CASE/$LISTING_REL/"
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        mkdir -p "$CASE/$(dirname "$rel")"
        cp "$ROOT/$rel" "$CASE/$rel"
    done <<EOF
$PUSHERS
EOF
}

pass=0
fail=0

run_check() {
    python3 "$PREFLIGHT" --texts-only --root "$CASE" >"$TMP/out" 2>&1
}

expect_pass() {
    local name="$1"
    if run_check; then
        echo "ok:   [$name] passes."
        pass=$((pass + 1))
    else
        echo "FAIL: [$name] was rejected, but it should pass:"
        sed 's/^/        /' "$TMP/out"
        fail=$((fail + 1))
    fi
}

# expect_fail <name> <substring the rejection must contain>
expect_fail() {
    local name="$1" why="$2"
    if run_check; then
        echo "FAIL: [$name] the check PASSED a broken listing."
        fail=$((fail + 1))
    elif grep -qF -- "$why" "$TMP/out"; then
        echo "ok:   [$name] rejected, for the right reason."
        pass=$((pass + 1))
    else
        echo "FAIL: [$name] rejected, but not for '$why':"
        sed 's/^/        /' "$TMP/out"
        fail=$((fail + 1))
    fi
}

# mutate <file relative to the listing dir> <python expression over s>
# Rewrites the file to the expression's value; refuses a no-op mutation, which
# would make the case prove nothing.
mutate() {
    local rel="$1" expr="$2"
    python3 - "$CASE/$LISTING_REL/$rel" "$expr" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8") if p.exists() else ""
new = eval(sys.argv[2], {"s": s})
if new == s:
    sys.exit(f"mutation of {p} changed nothing — the case would prove nothing")
p.write_text(new, encoding="utf-8")
PY
}

# ── positive control ─────────────────────────────────────────────────────────
build_fixture
expect_pass "unmodified listing (all six languages)"

# ── files and layout ─────────────────────────────────────────────────────────
build_fixture; rm "$CASE/$LISTING_REL/ja/keywords.txt"
expect_fail "a missing file" "ja/keywords.txt: missing"

build_fixture; : > "$CASE/$LISTING_REL/ko/subtitle.txt"
expect_fail "an empty file" "ko/subtitle.txt: empty"

build_fixture; rm -r "$CASE/$LISTING_REL/zh-Hant"
expect_fail "a missing locale directory" "zh-Hant/: locale directory is missing"

build_fixture; mkdir "$CASE/$LISTING_REL/fr"; echo "Texte" > "$CASE/$LISTING_REL/fr/description.txt"
expect_fail "a directory nothing pushes" "not in LOCALE_SOURCES"

build_fixture; cp "$CASE/$LISTING_REL/en-US/description.txt" "$CASE/$LISTING_REL/description_en-US.txt"
expect_fail "the old flat layout growing back" "legacy flat-layout file"

build_fixture; cp "$CASE/$LISTING_REL/es/keywords.txt" "$CASE/$LISTING_REL/es/keyword.txt"
expect_fail "a misnamed file" "es/keyword.txt: unexpected file"

# ── App Store Connect's limits ───────────────────────────────────────────────
build_fixture; mutate "es/description.txt" 's + "\n" + "Más texto. " * 400'
expect_fail "description over 4000" "limit of 4000"

build_fixture; mutate "zh-Hant/subtitle.txt" 's + "，而且還有更多更多更多的說明文字"'
expect_fail "subtitle over 30" "limit of 30"

build_fixture; mutate "en-US/promotional_text.txt" 's + " And then some more words to push it well past the limit."'
expect_fail "promotional text over 170" "limit of 170"

build_fixture; mutate "ja/keywords.txt" 's + ",ながいキーワード" * 3'
expect_fail "keywords over 100" "limit of 100"

build_fixture; printf '%s' "$(head -c 4001 < /dev/zero | tr '\0' 'x')" > "$CASE/$LISTING_REL/es/description.macos.txt"
expect_fail "a per-platform override over the limit" "es/description.macos.txt: 4001 characters"

# ── keyword format ───────────────────────────────────────────────────────────
build_fixture; mutate "en-US/keywords.txt" 's.replace(",", ", ", 1)'
expect_fail "a space after a keyword comma" "without spaces around the commas"

build_fixture; mutate "ko/keywords.txt" 's + ",,API"'
expect_fail "an empty keyword" "empty item"

build_fixture; mutate "es/keywords.txt" 's.replace(",llm,", ",llm,Gemini,")'
expect_fail "a duplicate keyword (case-insensitive)" "appears twice"

build_fixture; mutate "en-US/keywords.txt" 's.replace(",dashboard", ",usage")'
expect_fail "a keyword repeating the subtitle" "repeats a word of the subtitle"

build_fixture; mutate "zh-Hans/keywords.txt" 's.replace(",统计", ",用量")'
expect_fail "a CJK keyword repeating the subtitle" "repeats a word of the subtitle"

build_fixture; mutate "en-US/keywords.txt" 's.replace(",dashboard", ",pulse")'
expect_fail "a keyword repeating the app name" "repeats a word of the app name"

build_fixture; mutate "en-US/keywords.txt" 's.replace(",dashboard", ",codexbar")'
expect_fail "a competitor's name in keywords" "names a competing app"

# ── Guideline 2.3.10: other platforms ────────────────────────────────────────
build_fixture; mutate "es/description.txt" 's.replace("en tu Mac y", "en tu Mac, en Android y", 1)'
expect_fail "Android in the Spanish description" "names 'Android'"

build_fixture; mutate "en-US/promotional_text.txt" '"Also on Google Play. " + s[:120]'
expect_fail "Google Play in the promotional text" "names 'Google Play'"

build_fixture; mutate "zh-Hans/description.txt" 's.replace("可在 Mac、iPhone", "可在 Mac、安卓、iPhone", 1)'
expect_fail "安卓 in the Chinese description" "names '安卓'"

build_fixture; mutate "ko/description.txt" 's.replace("Mac뿐 아니라", "Mac과 윈도우뿐 아니라", 1)'
expect_fail "윈도우 in the Korean description" "names '윈도우'"

build_fixture; mutate "en-US/description.txt" 's.replace("an activity heatmap", "an activity heatmap across quota windows", 1)'
expect_fail "the word 'windows' (matches the release-notes guard)" "names 'Windows'"

# ── untranslated English ─────────────────────────────────────────────────────
build_fixture; mutate "ja/description.txt" 's.replace("\n\nプライバシー", "\n\nYour usage data syncs to your own account over an encrypted connection.\n\nプライバシー", 1)'
expect_fail "an English sentence left in the Japanese description" "looks like untranslated English"

build_fixture; mutate "es/description.txt" 's.replace("\n\nPrivacidad", "\n\nThe same quotas and alerts, synced from your Mac to the phone.\n\nPrivacidad", 1)'
expect_fail "an English sentence left in the Spanish description" "looks like untranslated English"

build_fixture; mutate "zh-Hant/description.txt" 's.replace("\n\n隱私", "\n\nReal time usage monitoring across major providers\n\n隱私", 1)'
expect_fail "an English phrase (no function words) in zh-Hant" "looks like untranslated English"

build_fixture; mutate "ko/promotional_text.txt" '"See how much quota is left and when it resets on your Mac."'
expect_fail "an English promotional text in Korean" "looks like untranslated English"

export EN_DESC="$CASE/$LISTING_REL/en-US/description.txt"
build_fixture; mutate "zh-Hans/description.txt" 'open(__import__("os").environ["EN_DESC"], encoding="utf-8").read().splitlines()[0] + "\n" + s'
expect_fail "the English first line pasted into a translation" "English description's first line verbatim"

# ── What's New (--whatsnew-dir) ──────────────────────────────────────────────
# The fixture is the real whatsnew_154/: fourteen release notes in seven
# languages, so the positive control is also the false-positive test of the
# platform-name, English-leftover and zh-Hant checks on real text. These run
# with their own helpers because the listing cases above use run_check.
WN="$CASE/whatsnew_154"
wn_fixture() { build_fixture; cp -R "$ROOT/whatsnew_154" "$WN"; }
wn_check() {
    python3 "$PREFLIGHT" --texts-only --root "$CASE" --whatsnew-dir "$WN" >"$TMP/out" 2>&1
}
wn_pass() {
    if wn_check; then
        echo "ok:   [$1] passes."; pass=$((pass + 1))
    else
        echo "FAIL: [$1] was rejected, but it should pass:"; sed 's/^/        /' "$TMP/out"
        fail=$((fail + 1))
    fi
}
wn_fail() {   # wn_fail <name> <substring the rejection must contain>
    if wn_check; then
        echo "FAIL: [$1] the check PASSED broken release notes."; fail=$((fail + 1))
    elif grep -qF -- "$2" "$TMP/out"; then
        echo "ok:   [$1] rejected, for the right reason."; pass=$((pass + 1))
    else
        echo "FAIL: [$1] rejected, but not for '$2':"; sed 's/^/        /' "$TMP/out"
        fail=$((fail + 1))
    fi
}
wn_mutate() {   # wn_mutate <file in the notes dir> <python expression over s>
    python3 - "$WN/$1" "$2" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
new = eval(sys.argv[2], {"s": s})
if new == s:
    sys.exit(f"mutation of {p} changed nothing — the case would prove nothing")
p.write_text(new, encoding="utf-8")
PY
}

wn_fixture
wn_pass "whatsnew_154 as committed (iOS and macOS, seven locales)"
grep -qF "TEXTS OK" "$TMP/out" && { echo "ok:   [What's New passing lets the listing check run]"; pass=$((pass + 1)); } \
    || { echo "FAIL: [What's New passing lets the listing check run]"; fail=$((fail + 1)); }

wn_fixture; rm "$WN"/macos-*.txt
wn_pass "no macOS texts at all: one text per locale serves both platforms"

wn_fixture; rm "$WN/macos-ja.txt"
wn_fail "a split directory missing one macOS text" "macos-ja.txt: missing: ja has no macOS What's New"

wn_fixture; rm "$WN/es-MX.txt"
wn_fail "a store locale without its iOS text" "es-MX.txt: missing"

wn_fixture; : > "$WN/ko.txt"
wn_fail "an empty text" "ko.txt: empty"

wn_fixture; wn_mutate "macos-es-ES.txt" 's + "\n" + "Más texto. " * 400'
wn_fail "a text over 4000 characters" "limit of 4000"

wn_fixture; wn_mutate "macos-en-US.txt" 's + "\n• New: Remote Control from your iPhone.\n"'
wn_fail "Remote Control in the macOS text" "names 'Remote Control', which only the direct-download"

wn_fixture; wn_mutate "macos-ja.txt" 's + "\n・リモート操作に対応しました。\n"'
wn_fail "リモート操作 in the Japanese macOS text" "names 'リモート操作'"

wn_fixture; wn_mutate "en-US.txt" 's + "\n• Fixed: Remote Control reconnects after a restart.\n"'
wn_pass "Remote Control in the iOS text (the direct-download check is macOS only)"

wn_fixture; wn_mutate "ko.txt" 's + "\n• 안드로이드 앱도 같은 수정이 적용되었습니다.\n"'
wn_fail "안드로이드 in Korean (the bash release-notes guard is Latin-only)" "names '안드로이드'"

wn_fixture; wn_mutate "zh-Hans.txt" 's.replace("• 翻译：", "• Also on Google Play. 翻译：", 1)'
wn_fail "Google Play in the Chinese text" "names 'Google Play'"

wn_fixture; wn_mutate "ja.txt" 's + "\nThe usage history chart is now filled in for every account.\n"'
wn_fail "an English sentence left in the Japanese text" "looks like untranslated English"

wn_fixture; wn_mutate "es-MX.txt" 's.replace("Casi todo en esta versión", "Casi todo en esta versión nueva", 1)'
wn_fail "es-MX no longer equal to es-ES" "share the listing directory 'es/'"

wn_fixture; wn_mutate "macos-zh-Hant.txt" 's.replace("工作階段", "會話", 1)'
wn_fail "a Mainland term in zh-Hant" "uses '會話'; zh-Hant says '工作階段'"

wn_fixture; cp "$WN/en-US.txt" "$WN/fr-FR.txt"
wn_fail "a file for a locale the store listing does not have" "fr-FR.txt: unexpected file"

wn_fixture; rm -r "$WN"
wn_fail "a directory that is not there" "What's New directory not found"

# ── pushers must read the files, not carry copies ────────────────────────────
build_fixture
kw="$(cat "$CASE/$LISTING_REL/en-US/keywords.txt")"
printf '\nKEYWORDS = "%s"\n' "$kw" >> "$CASE/CLI Pulse Bar/scripts/appstore_metadata.py"
expect_fail "an inline keyword list in a pusher" "appstore_metadata.py: carries an inline copy of en-US/keywords.txt"

build_fixture
printf '\nDESC = "CLI Pulse monitors your AI coding tool usage across everything"\n' >> "$CASE/CLI Pulse Bar/scripts/resubmit.py"
expect_fail "the old description literal in a pusher" "carries an inline copy of legacy description"

build_fixture; rm "$CASE/scripts/asc_push_listing.py"
expect_fail "a pusher that vanished" "pusher missing"

# ── the platform-name list must cover the release-notes guard's list ─────────
# Two lists of the same rule is how rules drift. The release-notes guard is
# bash; the listing check is Python. This asserts every term the bash guard
# forbids is forbidden here too — and, as its own negative control, that the
# comparison notices a term missing from the Python side.
coverage="$(python3 - "$ROOT" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts"))
import appstore_listing as l
sh = (root / "scripts/check_release_notes_platforms.sh").read_text()
m = re.search(r'FORBIDDEN="([^"]*)"', sh)
if not m:
    print("UNPARSEABLE"); sys.exit()
bash_terms = [t.strip() for t in m.group(1).splitlines() if t.strip()]
def missing(py_terms):
    have = {t.casefold() for t in py_terms}
    return [t for t in bash_terms if t.casefold() not in have]
print("MISSING:" + ",".join(missing(l.PLATFORM_TERMS_LATIN)) if missing(l.PLATFORM_TERMS_LATIN)
      else f"OK {len(bash_terms)}")
# negative control: drop one term and the comparison must notice
print("CONTROL:" + ("noticed" if missing(l.PLATFORM_TERMS_LATIN[1:]) else "BLIND"))
PY
)"
case "$coverage" in
    "OK "*"CONTROL:noticed")
        echo "ok:   [platform list covers check_release_notes_platforms.sh] ${coverage%%$'\n'*}"
        pass=$((pass + 1)) ;;
    *)
        echo "FAIL: [platform list covers check_release_notes_platforms.sh] $coverage"
        fail=$((fail + 1)) ;;
esac

# ── --require-shots: every listing locale's iPhone panels ────────────────────
# A flag (CI passes it; the fixtures above carry listing texts only), so the
# run without it must stay green without panels, and the flag must turn a
# missing, stray or unuploadable panel into a failure.
run_check() {
    python3 "$PREFLIGHT" --texts-only --root "$CASE" $EXTRA >"$TMP/out" 2>&1
}
panels() {   # panels <lang...>: the five valid panels of a clean compose run, per language
    python3 - "$ROOT" "$CASE" "$@" <<'PY'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "scripts"))
import appstore_screenshots as s
for lang in sys.argv[3:]:
    for p in s.expected_composed(lang, pathlib.Path(sys.argv[2])):
        s.write_png(p, 1290, 2796)
    s.write_manifest(s.composed_dir(lang, pathlib.Path(sys.argv[2])), lang)
PY
}

EXTRA=""; build_fixture
expect_pass "no iPhone panels, --require-shots not given"

EXTRA="--require-shots"; build_fixture
expect_fail "--require-shots with no panels at all" "[en-US] en: screenshots/ios-composed/en/ does not exist"

build_fixture; panels en zh-Hans zh-Hant ja ko es
expect_pass "--require-shots with all six languages' panels"

build_fixture; panels en zh-Hans zh-Hant ja ko
expect_fail "--require-shots without the Spanish set (es-ES and es-MX)" "[es-MX] es:"

build_fixture; panels en zh-Hans zh-Hant ja ko es
rm "$CASE/CLI Pulse Bar/screenshots/ios-composed/ko/03_cost_1290x2796.png"
expect_fail "--require-shots with one panel missing" "[ko] ko: 03_cost_1290x2796.png: missing"

build_fixture; panels en zh-Hans zh-Hant ja ko es
python3 - "$ROOT" "$CASE" <<'PY'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "scripts"))
import appstore_screenshots as s
s.write_png(s.expected_composed("ja", pathlib.Path(sys.argv[2]))[0], 1290, 2796, color_type=6)
PY
expect_fail "--require-shots with a panel that has alpha" "[ja] ja: 01_overview_1290x2796.png: RGBA"

# A set the compositor did not finish cleanly: valid PNGs, no compose.json
# (a failing run deletes it), or a panel replaced after the run.
build_fixture; panels en zh-Hans zh-Hant ja ko es
rm "$CASE/CLI Pulse Bar/screenshots/ios-composed/zh-Hant/compose.json"
expect_fail "--require-shots with a set a clean compose run did not write" "[zh-Hant] zh-Hant: compose.json is missing"

build_fixture; panels en zh-Hans zh-Hant ja ko es
printf 'x' >> "$CASE/CLI Pulse Bar/screenshots/ios-composed/ko/02_providers_1290x2796.png"
expect_fail "--require-shots with a panel changed after the compose run" "[ko] ko: 02_providers_1290x2796.png: not the file the last clean compose run wrote"
EXTRA=""

echo "test_asc_listing_preflight: $pass passed, $fail failed."
[ "$fail" -eq 0 ] || exit 1
exit 0

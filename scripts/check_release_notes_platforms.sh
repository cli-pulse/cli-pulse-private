#!/bin/bash
# Fail if App Store release notes mention a non-Apple platform.
#
# WHY THIS EXISTS
# ---------------
# macOS 1.52.0 (build 104) was REJECTED on 2026-08-28 under Guideline 2.3.10
# — Performance / Accurate Metadata:
#
#   "The app or metadata includes information about third-party platforms that
#    may not be relevant for App Store users, who are focused on experiences
#    offered by the app itself.
#    Next Steps: Revise the app's What's New text to remove Android references."
#
# The notes carried a bullet reading "Removed on Android: the option to
# subscribe." True, and irrelevant to someone reading the Mac App Store.
#
# Worth knowing: the IDENTICAL text passed review on iOS the same week. Two
# reviewers, two outcomes. So "it got approved last time" is not evidence the
# text is compliant — which is exactly why this is a mechanical check and not a
# habit.
#
# WHAT IT CHECKS
# --------------
# Every whatsnew_*/ file, for the name of any platform that is not the one the
# notes ship to. The repo really does have Android and Windows clients, so the
# temptation to mention them in release notes is live and recurring, not
# hypothetical.
#
# And every character App Store Connect may refuse. It refuses some outright,
# with a 409 for the whole field that names them: the 1.57 iOS What's New was
# refused on 2026-10-20 for one "✕" (U+2715). The rule is the listing check's
# (store_character_problems in scripts/appstore_listing.py, which asc_submit.py
# and asc_listing_preflight.py apply before writing What's New), run here over
# every release note so a bad character fails in the PR that adds it.
#
# NEGATIVE CONTROL: scripts/test_check_release_notes_platforms.sh plants each
# forbidden term, and characters the store refuses, in a throwaway copy and
# asserts this script rejects each, and asserts the unmutated fixture passes. A
# guard nobody has watched fail is not known to work.
#
# Usage: check_release_notes_platforms.sh [--root DIR]   (--root is for the self-test)
set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
if [ "${1:-}" = "--root" ]; then
    ROOT="$2"
fi

# Word-boundary matched, case-insensitive. "Play Store" and "Google Play" are
# listed separately from "Android" because a note can name the store without
# naming the OS.
FORBIDDEN="Android
Google Play
Play Store
Windows
Linux
Microsoft Store"

notes="$(find "$ROOT" -maxdepth 2 -type d -name 'whatsnew_*' -print 2>/dev/null \
    | while IFS= read -r d; do find "$d" -maxdepth 1 -type f -name '*.txt' -print; done)"

if [ -z "$notes" ]; then
    echo "ERROR: found no whatsnew_*/*.txt release-note files to scan."
    echo "       A scan that looks at nothing always passes; refusing to."
    echo "       If release notes moved, point this guard at their new home."
    exit 1
fi

failed=0
scanned=0
rels=()

while IFS= read -r f; do
    [ -z "$f" ] && continue
    scanned=$((scanned + 1))
    rel="${f#"$ROOT"/}"
    # release/whatsnew_145..147 hold the 1.45-1.47 notes, from before the notes
    # moved to whatsnew_*/ at the root. Nothing sends them to App Store Connect
    # any more, and whether the store took 1.45's "Settings > Privacy" as
    # written is not on record, so the character check leaves them out.
    case "$rel" in release/*) ;; *) rels+=("$rel") ;; esac
    while IFS= read -r term; do
        [ -z "$term" ] && continue
        # -w so "Linux" does not fire on "Linuxism" and, more to the point, so
        # a substring inside a URL or product name does not produce a false
        # positive that trains people to ignore this guard.
        if grep -qiw -- "$term" "$f"; then
            echo "ERROR: $rel mentions '$term'."
            grep -niw -- "$term" "$f" | sed 's/^/         /'
            echo
            echo "       App Store release notes may not describe third-party"
            echo "       platforms — Guideline 2.3.10. macOS 1.52.0 was rejected"
            echo "       for exactly this, on a bullet about Android."
            echo "       Say it in the GitHub release notes instead; the App Store"
            echo "       notes are for what changed on THIS platform."
            failed=1
        fi
    done <<EOF
$FORBIDDEN
EOF
done <<EOF
$notes
EOF

# Characters App Store Connect may refuse: one Python check for every file,
# run from ROOT so it names them as above.
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found; the character check needs it (scripts/appstore_listing.py)."
    exit 1
fi
if [ "${#rels[@]}" -eq 0 ]; then
    echo "ERROR: no whatsnew_*/*.txt at the repo root for the character check."
    echo "       A scan that looks at nothing always passes; refusing to."
    exit 1
fi
chars_out="$(cd "$ROOT" && python3 "$SCRIPTS/appstore_listing.py" --characters "${rels[@]}" 2>&1)"
chars_rc=$?
if [ "$chars_rc" -ne 0 ]; then
    printf '%s\n' "$chars_out" | sed 's/^/ERROR: /'
    echo
    echo "       App Store Connect refuses some characters with a 409 for the whole"
    echo "       field (1.57: one '✕' in the iOS What's New). Write them as words."
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    echo "Release-note check FAILED."
    exit 1
fi

echo "check_release_notes_platforms: OK — $scanned release-note file(s) scanned," \
     "no third-party platform references; the ${#rels[@]} under whatsnew_*/ hold" \
     "only characters App Store Connect has accepted."
exit 0

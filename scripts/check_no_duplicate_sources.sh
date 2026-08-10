#!/usr/bin/env bash
# Fail when a duplicate-named source file appears next to its original.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-11 the iOS App Store archive failed after ~20 minutes with:
#
#     'WatchSessionIdentity' is ambiguous for type lookup in this context
#       found this candidate: WatchSessionBoundary 2.swift
#       found this candidate: WatchSessionBoundary 3.swift
#       found this candidate: WatchSessionBoundary.swift
#
# There were **25** of them under CLIPulseCore/Sources, every one byte-identical
# to its original, dated between 07-30 and 08-03. SwiftPM globs its Sources
# directory, so unlike the Xcode app target — which only compiles what
# project.pbxproj lists — every stray copy gets compiled.
#
# .gitignore already covers `* [2-9].*`, and that is exactly why this needed a
# separate guard: ignoring a file protects the INDEX, not the BUILD. The files
# were invisible to `git status`, invisible to code review, and fatal to
# `xcodebuild archive`.
#
# The failure is also maximally expensive: it surfaces at the end of a long
# archive, as a type-ambiguity error that reads like a code bug rather than a
# stray file. This guard turns twenty minutes into one second.
#
# WHERE THEY COME FROM — HONESTLY UNKNOWN
# ---------------------------------------
# Long assumed to be iCloud. That is unproven and probably wrong: `~/Documents`
# is a plain directory, Desktop & Documents sync is OFF, and the repo holds zero
# `.icloud` placeholders. OneDrive syncs only `~/OneDrive - keio.jp`. So the
# source has not been identified, which is the whole reason this guard is worth
# having — deleting them is a reset, not a fix, and they have already come back
# at least once (14 deleted 08-07, 25 present 08-11).
#
# Usage: scripts/check_no_duplicate_sources.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Directories whose contents are COMPILED. SwiftPM globs Sources/ and Tests/;
# a stray file there is a build failure, not a cosmetic wart.
SEARCH_DIRS=(
    "CLI Pulse Bar/CLIPulseCore/Sources"
    "CLI Pulse Bar/CLIPulseCore/Tests"
    "HelperSwift/Sources"
    "SensorProbe/Sources"
)

# `<name> <digit>.<ext>` — what macOS and several sync clients produce on a
# collision. Deliberately not anchored to .swift: a duplicated .h, .c or
# resource breaks a build just as effectively.
offenders=""
for dir in "${SEARCH_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        canonical_base="$(sed -E 's/ [0-9]+(\.[A-Za-z0-9]+)$/\1/' <<< "$base")"
        canonical="$(dirname "$f")/$canonical_base"
        if [[ -f "$canonical" ]]; then
            if cmp -s "$f" "$canonical"; then
                offenders+="${f} — byte-identical duplicate of ${canonical_base}"$'\n'
            else
                offenders+="${f} — duplicate NAME of ${canonical_base}, but CONTENT DIFFERS (inspect before deleting)"$'\n'
            fi
        else
            offenders+="${f} — duplicate-style name with no original present"$'\n'
        fi
    done < <(find "$dir" -type f -name "* [0-9].*" -print0 2>/dev/null)
done

if [[ -n "$offenders" ]]; then
    count="$(grep -c . <<< "$offenders")"
    echo "✗ $count duplicate-named source file(s) in a COMPILED directory:" >&2
    echo "" >&2
    sed '/^$/d; s/^/    /' <<< "$offenders" >&2
    cat >&2 <<'MSG'

SwiftPM compiles everything under Sources/ and Tests/, so these WILL break the
build with an "ambiguous for type lookup" error — typically at the end of a long
archive. .gitignore does not help: it protects the index, not the compiler.

Delete the ones reported as byte-identical. Inspect any reported as CONTENT
DIFFERS first — that one is not a stray copy, it is divergent work.
MSG
    exit 1
fi

echo "✓ no duplicate-named files in compiled source directories"

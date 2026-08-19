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
# 2026-08-19 — THE STRONGEST EVIDENCE SO FAR. 60 duplicates appeared in a tree
# this guard had reported CLEAN twice earlier the same day. Their timestamps say
# 07-27..08-03, in batches sharing one second exactly (26 files at 08-03
# 01:26:48, 22 at 08-03 12:19:59, 7 at 07-30 17:13:57) — a bulk copy, not drift.
#
# The timestamps are a lie, and APFS proves it. Inode numbers are allocated
# monotonically:
#
#     CollectorRunner.swift        birth 08-04   inode 250,454,865
#     FirstRunPresentation.swift   birth 08-18   inode 261,235,600   (written that day)
#     CollectorRunner 2.swift      birth "08-03" inode 263,212,836   <-- HIGHER
#
# A duplicate claiming to predate a file by two weeks has a HIGHER inode than
# that file. So it was physically written to this volume AFTER it, i.e. during
# the 2026-08-18 session, and its birth time is metadata carried over by a
# copy that preserves it (`ditto`, `cp -p`, `rsync -a`, or a restore).
#
# What this narrows it to: a timestamp-preserving BULK COPY into the working
# tree, running while a session is active. Two things it is NOT — both tested,
# not assumed: not iCloud (no fileprovider xattr on any specimen; see the
# correction in build_signed_app.sh), and not a git worktree (absent from all
# four .claude/worktrees and from a scratch `git worktree add`).
#
# The copy also reaches INSIDE .git — `.git/refs/heads/main 2` (which breaks
# `git pull` outright with "bad object", since a space is illegal in a ref name)
# and `.git/logs/refs/heads/v1 2.15-multi-cli`. That last name is the signature:
# " 2" inserted before the LAST DOT, treating `.15-multi-cli` as an extension.
# That is macOS's own duplicate-resolution algorithm. No compiler, no SwiftPM
# and no git names a file that way.
#
# So: something copies this entire directory, .git included, using macOS file
# APIs, during sessions. Whoever picks this up next should start there rather
# than re-testing iCloud.
#
# Usage: scripts/check_no_duplicate_sources.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Directories whose contents are COMPILED. SwiftPM globs Sources/ and Tests/;
# a stray file there is a build failure, not a cosmetic wart.
#
# DISCOVERED, NOT HARDCODED — and that change is why this guard now works.
# The list used to be four literal paths and it had gone stale: on 2026-08-18 a
# `LocalSessionServer 2.swift` broke a QA build from HelperSwift/Sources (which
# WAS listed, so that one was caught) while SIX more sat unnoticed in
# HelperSwift/Tests, which was NOT. Enumerating the packages showed the guard
# covered 4 of ~10 compiled directories: HelperSwift/Tests, SensorProbe/Tests,
# both MachineRootHelper dirs and CLI Pulse Bar/codexbar were all unscanned.
#
# A hardcoded allowlist of build inputs is the same trap as the QA bundle-id
# allowlist and the UserDefaults migration prefixes: adding a package silently
# drops it out of coverage, and nothing says so. Deriving the list from
# Package.swift means a new package is covered the day it is added.
SEARCH_DIRS=()
while IFS= read -r -d '' pkg; do
    pkg_dir="$(dirname "$pkg")"
    for sub in Sources Tests; do
        [[ -d "$pkg_dir/$sub" ]] && SEARCH_DIRS+=("$pkg_dir/$sub")
    done
done < <(
    find . -name Package.swift -maxdepth 4 \
        -not -path "./.git/*" \
        -not -path "*/.build/*" \
        -not -path "./.claude/*" \
        -not -path "./build/*" \
        -print0 2>/dev/null
)

if [[ ${#SEARCH_DIRS[@]} -eq 0 ]]; then
    # An empty search list would make this guard pass unconditionally, which is
    # the failure mode it exists to prevent. Fail loudly instead.
    echo "✗ no SwiftPM packages found — the guard would scan nothing." >&2
    echo "  This is a guard failure, not a clean tree." >&2
    exit 1
fi

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

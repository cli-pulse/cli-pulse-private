#!/usr/bin/env bash
#
# Fail when a tracked file is also matched by .gitignore.
#
# WHY THIS EXISTS
# ---------------
# `.gitignore` does not apply to files git already tracks. Once something is
# committed — by `git add -A`, by `git add <explicit path>`, or by a stray hunk
# in an unrelated PR — the ignore rule becomes decorative and stays that way
# silently. The repo looks protected and is not.
#
# Found on 2026-08-24: `.gitignore:70` has ignored `CLI Pulse Bar/codexbar/`
# (a local reference checkout of steipete/CodexBar, 865 MB) for months, and
# exactly one file inside it was tracked anyway —
# `Sources/CodexBar/PlanUtilizationHistoryChartMenuView.swift`, 798 lines of
# somebody else's MIT-licensed source, committed by PR #447 ("scripts: read the
# web product page"), which had nothing to do with it. It imports `CodexBarCore`
# so it cannot compile here, nothing references it, and `cli-pulse-private` is
# a PUBLIC repository — so it was an unattributed redistribution of a third
# party's code sitting in a directory the repo believed it was ignoring.
#
# This repo already knows how to vendor properly: see
# `CLIPulseCore/Sources/CLIPulseCore/Vendor/SweetCookieKit/`, where every file
# carries "Vendored from steipete/SweetCookieKit 0.4.1 (MIT, © Peter
# Steinberger)" and a LICENSE pointer. The problem is not the practice, it is
# that one file bypassed it and nothing noticed for months.
#
# The invariant is deliberately general rather than a codexbar-specific rule:
# a tracked file that .gitignore claims to ignore is always either a mistake or
# something that deserves an explicit, reviewed exception.
#
# EXCEPTIONS
# ----------
# None today. If you need one, add it to ALLOWED below with a comment saying
# why the file must be both tracked and ignored — that pairing is strange
# enough to be worth explaining in the diff.

set -euo pipefail

cd "$(dirname "$0")/.."

# Paths permitted to be both tracked and ignored, one basic regex per line.
ALLOWED=(
)

tracked_ignored="$(git ls-files --cached --ignored --exclude-standard)"

if [[ -z "$tracked_ignored" ]]; then
    echo "OK: no tracked file is matched by .gitignore"
    exit 0
fi

violations=""
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    allowed=0
    for pattern in "${ALLOWED[@]:-}"; do
        [[ -z "$pattern" ]] && continue
        if printf '%s' "$path" | grep -Eq "$pattern"; then
            allowed=1
            break
        fi
    done
    if [[ $allowed -eq 0 ]]; then
        violations+="$path"$'\n'
    fi
done <<< "$tracked_ignored"

if [[ -z "$violations" ]]; then
    echo "OK: every tracked+ignored file is on the explicit allow list"
    exit 0
fi

echo "error: these files are tracked by git AND matched by .gitignore." >&2
echo "" >&2
printf '%s' "$violations" | sed 's/^/  /' >&2
echo "" >&2
echo "A tracked file is not covered by .gitignore — the rule is decorative for" >&2
echo "anything already committed. Either:" >&2
echo "" >&2
echo "  * it should not be in the repo:   git rm --cached '<path>'" >&2
echo "  * or it genuinely belongs here:   remove the .gitignore rule, and if it" >&2
echo "    is third-party code, vendor it properly — see" >&2
echo "    CLIPulseCore/Sources/CLIPulseCore/Vendor/SweetCookieKit/ for the" >&2
echo "    per-file attribution + LICENSE pattern this repo uses." >&2
echo "" >&2
echo "Remember cli-pulse-private is PUBLIC despite the name." >&2
exit 1

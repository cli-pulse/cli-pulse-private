#!/bin/bash
# PRIVACY.md names the version it describes, in a paragraph of its own:
#
#     It describes CLI Pulse 1.62.
#
# That X.Y must be the major.minor of MARKETING_VERSION in the Xcode project.
#
# WHY THIS EXISTS
# 1.62.0's release PR (#748) moved all twelve MARKETING_VERSION sites to 1.62.0,
# and #746 had already added a 1.62 sentence to the policy, yet PRIVACY.md kept
# saying "It describes CLI Pulse 1.60." The 1.57-1.60 release notes each list
# this line as a manual release step; 1.62 skipped it and nothing noticed. A
# manual step a release can skip silently is what this gate replaces.
#
# WHAT IT ASKS OF A RELEASE
# The comparison is major.minor, so a patch release (1.62.1) changes nothing.
# Every minor version's bump PR sets the line, even when the policy text did not
# change: the release re-affirms which version the policy describes, after
# someone has read it against that version. "Last Updated" is not checked here:
# it is the date of the last substantive revision of the policy (moving this
# line alone is not one), set by hand on release day together with the hosted
# page (cli-pulse/cli-pulse, docs/privacy.html), which lives in another
# repository and is not visible to this check.
#
# usage: check_privacy_version.sh [--root DIR]   (DIR defaults to this repo)
# exit:  0 the line matches, 1 it does not or cannot be read, 2 bad usage.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            [ $# -ge 2 ] || { echo "usage: $0 [--root DIR]" >&2; exit 2; }
            ROOT="$2"; shift 2 ;;
        *) echo "usage: $0 [--root DIR]" >&2; exit 2 ;;
    esac
done

PBXPROJ="$ROOT/CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj"
PRIVACY="$ROOT/PRIVACY.md"
PREFIX="It describes CLI Pulse"

fail() {
    echo "::error::check_privacy_version: $*" >&2
    exit 1
}

# The same, annotated on PRIVACY.md's line in the pull request's diff.
fail_at() {
    local line="$1"; shift
    echo "::error file=PRIVACY.md,line=$line::check_privacy_version: $*" >&2
    exit 1
}

[ -f "$PBXPROJ" ] || fail "no Xcode project at $PBXPROJ"
[ -f "$PRIVACY" ] || fail "no PRIVACY.md at $PRIVACY"

# ── MARKETING_VERSION: every site, one value ────────────────────────────────
# Every assignment's raw value is kept, valid or not, so one malformed site is a
# second distinct value rather than something the parse quietly drops. A site
# written in a shape the parse does not read (a quoted key, an
# "[sdk=...]" variant, no spaces around "=") is caught by the count: SITE is any
# build-setting key MARKETING_VERSION followed by "=", ASSIGN only the plain
# form. Neither counts a reference to the setting ($(MARKETING_VERSION),
# ${MARKETING_VERSION}, $MARKETING_VERSION), the word in a comment, or a longer
# setting name that ends in it, so those neither block nor feed the check.
NOT_KEY='(^|[^$({_A-Za-z0-9])'
SITE_RE="${NOT_KEY}\"?MARKETING_VERSION(\\[[^]]*\\])?\"?[[:space:]]*="
ASSIGN_RE="${NOT_KEY}MARKETING_VERSION = [^;]*;"
sites="$(grep -oE "$SITE_RE" "$PBXPROJ" | wc -l | tr -d '[:space:]')"
assignments="$(grep -oE "$ASSIGN_RE" "$PBXPROJ" | wc -l | tr -d '[:space:]')"
[ "$sites" = "$assignments" ] \
    || fail "the Xcode project sets MARKETING_VERSION in $sites places but only $assignments are plain 'MARKETING_VERSION = X;' assignments; every site must be one this check can read"
[ "$assignments" -gt 0 ] || fail "found no MARKETING_VERSION in $PBXPROJ"
versions="$(grep -oE "$ASSIGN_RE" "$PBXPROJ" \
    | sed -E 's/^.*MARKETING_VERSION = //; s/;$//; s/[[:space:]"]//g' \
    | sort -u)"
distinct="$(printf '%s\n' "$versions" | wc -l | tr -d '[:space:]')"
[ "$distinct" = 1 ] \
    || fail "the Xcode project has $distinct different MARKETING_VERSION values ($(printf '%s ' $versions)); they must agree before the policy can be compared (scripts/check-versions.sh)"
version="$versions"
printf '%s\n' "$version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    || fail "MARKETING_VERSION '$version' is not X.Y or X.Y.Z"
want="$(printf '%s\n' "$version" | sed -E 's/^([0-9]+\.[0-9]+).*$/\1/')"

# ── PRIVACY.md: exactly one line that starts the sentence ───────────────────
# CRs are dropped so a file saved with CRLF endings is read the same way.
lines="$(tr -d '\r' < "$PRIVACY" | grep -n "^$PREFIX" || true)"
[ -n "$lines" ] \
    || fail "PRIVACY.md has no line starting '$PREFIX'. Add the paragraph 'It describes CLI Pulse $want.' (it says which version the policy describes)."
count="$(printf '%s\n' "$lines" | wc -l | tr -d '[:space:]')"
[ "$count" = 1 ] \
    || fail "PRIVACY.md has $count lines starting '$PREFIX' (lines $(printf '%s\n' "$lines" | cut -d: -f1 | tr '\n' ' ' | sed -E 's/ $//')); keep exactly one."
lineno="${lines%%:*}"
text="${lines#*:}"

# Exactly "It describes CLI Pulse X.Y." — anything else ("1.62.0.", "1.62 and
# later.") fails loudly rather than being half-parsed into a false pass.
printf '%s\n' "$text" | grep -qE "^$PREFIX [0-9]+\.[0-9]+\.\$" \
    || fail_at "$lineno" "PRIVACY.md line $lineno reads '$text'; it must be exactly 'It describes CLI Pulse $want.' (major.minor, then a full stop)."
have="$(printf '%s\n' "$text" | sed -E "s/^$PREFIX ([0-9]+\.[0-9]+)\.\$/\1/")"

if [ "$have" != "$want" ]; then
    fail_at "$lineno" "PRIVACY.md line $lineno says it describes CLI Pulse $have, but MARKETING_VERSION is $version. Read the policy against $want, then set that line to 'It describes CLI Pulse $want.' (and the hosted page, cli-pulse/cli-pulse docs/privacy.html, on release day)."
fi

echo "OK — PRIVACY.md line $lineno describes CLI Pulse $have; MARKETING_VERSION is $version."

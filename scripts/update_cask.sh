#!/usr/bin/env bash
# Regenerate Casks/cli-pulse.rb for a released version.
#
# W6 exists because the previous cask was a dead stub — version "0.1.0",
# `sha256 :no_check`, and a URL pointing at the pre-org-move address. A cask
# that is updated by hand becomes that stub again within two releases, so the
# version and checksum come from the published release, never from an argument.
#
# `sha256 :no_check` is not an option here: it disables the only integrity
# check between GitHub's CDN and the user's Applications folder, on an app that
# ships a privileged LaunchAgent helper.
#
# Usage:
#   scripts/update_cask.sh 1.44.0
#   scripts/update_cask.sh 1.44.0 --skip-style   # no Homebrew here; see below
#
# Run AFTER the DEVID release is published (the DMG must exist to be hashed).
# This only rewrites the file in this repo. The cask users get is the copy in
# the tap repo (cli-pulse/homebrew-tap), pushed separately: AGENTS.md,
# "Releasing the Developer ID build — three surfaces".
#
# THE STYLE CHECK
# ---------------
# The new cask is written to a scratch Casks/ directory, checked there with
# `brew style <file>`, and copied over Casks/cli-pulse.rb only if it passes.
#
# It used to run `brew style --cask "$CASK" || echo "(style issues above…)"`.
# Current Homebrew refuses `--cask` for a file outside a tap ("Homebrew
# requires casks to be in a tap, rejecting: …") and the `|| echo` turned that
# into exit 0, so on 2026-09-28 (1.54.0) the check did not run at all and the
# script reported success. `brew style <file>` without `--cask` runs RuboCop
# with Homebrew's config, cask cops included (Cask/StanzaOrder, Cask/Desc, …),
# for a file in a directory named Casks. The run counts only if brew exits 0
# AND says it inspected one file with no offenses; anything else — offenses,
# a rejection, no summary line — fails the script with the cask unchanged.
# No Homebrew at all also fails, unless --skip-style says so on purpose.
# Negative controls: scripts/test_update_cask.sh.

set -euo pipefail

usage() {
    echo "usage: $0 <version> [--skip-style]   e.g. $0 1.44.0" >&2
    exit 2
}

VERSION=""
SKIP_STYLE=0
for arg in "$@"; do
    case "$arg" in
        --skip-style) SKIP_STYLE=1 ;;
        -*) usage ;;
        *) [[ -z "$VERSION" ]] || usage; VERSION="$arg" ;;
    esac
done
[[ -n "$VERSION" ]] || usage

# PINNED CONTRACT: app updates live in `cli-pulse-distrib` under the
# `JasonYeYuhe` owner, and the arch is always arm64. See Casks/cli-pulse.rb.
REPO="JasonYeYuhe/cli-pulse-distrib"
TAG="app-v${VERSION}"
ASSET="CLI-Pulse-${VERSION}-arm64.dmg"
CASK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Casks/cli-pulse.rb"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NEW="$WORK/Casks/cli-pulse.rb"     # a directory named Casks: see THE STYLE CHECK
mkdir -p "$WORK/Casks"

echo "==> fetching $ASSET from $REPO@$TAG"
if ! gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$WORK" 2>/dev/null; then
    echo "ERROR: $REPO has no asset '$ASSET' on tag '$TAG'." >&2
    echo "       Publish the DEVID release first — the cask is generated from" >&2
    echo "       what actually shipped, not from what we intended to ship." >&2
    exit 1
fi

SHA="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
echo "==> sha256 $SHA"

# Exit code must not travel through a pipe (a known trap in this repo), so
# rewrite with python3 and check its status directly.
python3 - "$CASK" "$NEW" "$VERSION" "$SHA" <<'PY'
import re, sys
path, out, version, sha = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
src = open(path).read()
new = re.sub(r'^(\s*version\s+)"[^"]*"', rf'\g<1>"{version}"', src, count=1, flags=re.M)
new = re.sub(r'^(\s*sha256\s+)"[^"]*"', rf'\g<1>"{sha}"', new, count=1, flags=re.M)
if new == src:
    print("ERROR: cask unchanged — version/sha256 lines did not match "
          "(or the cask already says this version and checksum)", file=sys.stderr)
    sys.exit(1)
open(out, "w").write(new)
PY
grep -E '^\s*(version|sha256)' "$NEW"

if [[ "$SKIP_STYLE" == 1 ]]; then
    echo "==> brew style: NOT CHECKED (--skip-style). Run 'brew style Casks/cli-pulse.rb'"
    echo "    on a machine with Homebrew before this file goes to the tap."
elif ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: brew is not installed, so the cask's style cannot be checked, and" >&2
    echo "       Casks/cli-pulse.rb was NOT changed. Run this where Homebrew is, or pass" >&2
    echo "       --skip-style and check it before pushing to the tap." >&2
    exit 1
else
    echo "==> brew style $NEW"
    set +e
    STYLE_OUT="$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 \
        brew style "$NEW" 2>&1)"
    STYLE_RC=$?
    set -e
    printf '%s\n' "$STYLE_OUT" | sed 's/^/    /'
    if grep -q "requires casks to be in a tap" <<<"$STYLE_OUT"; then
        echo "ERROR: Homebrew refused to style-check the cask outside a tap, so the check" >&2
        echo "       did not run. Casks/cli-pulse.rb was NOT changed." >&2
        exit 1
    fi
    if [[ "$STYLE_RC" -ne 0 ]]; then
        echo "ERROR: brew style found problems (exit $STYLE_RC; above). Casks/cli-pulse.rb" >&2
        echo "       was NOT changed. Fix the cask's template, then run this again." >&2
        exit 1
    fi
    if ! grep -qE '^1 file inspected, no offenses detected$' <<<"$STYLE_OUT"; then
        echo "ERROR: brew style exited 0 without saying it inspected the cask (no" >&2
        echo "       '1 file inspected, no offenses detected'), so it cannot be counted as" >&2
        echo "       a pass. Casks/cli-pulse.rb was NOT changed." >&2
        exit 1
    fi
    echo "==> brew style: 1 file inspected, no offenses"
fi

cp "$NEW" "$CASK"
echo "==> updated $CASK"

echo
echo "Next (AGENTS.md, \"Releasing the Developer ID build — three surfaces\"):"
echo "  1. commit Casks/cli-pulse.rb here in a small PR"
echo "  2. push the same file to the tap, branch master, hooks off (a hook in a tap"
echo "     checkout once ran brew fetch for minutes):"
echo "       git clone git@github.com:cli-pulse/homebrew-tap.git \"\$T\""
echo "       cp \"$CASK\" \"\$T/Casks/\""
echo "       git -C \"\$T\" add Casks/cli-pulse.rb"
echo "       git -C \"\$T\" -c core.hooksPath=/dev/null commit --no-verify -m \"cask: $VERSION\""
echo "       git -C \"\$T\" push origin master"
echo "  3. scripts/check_release_surfaces.sh $VERSION   # release, latest.json and tap all say $VERSION"

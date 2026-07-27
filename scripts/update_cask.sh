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
#
# Run AFTER the DEVID release is published (the DMG must exist to be hashed).
# Publishing the tap itself is a separate, Owner-gated step.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>   e.g. $0 1.44.0" >&2
    exit 2
fi

# PINNED CONTRACT: app updates live in `cli-pulse-distrib` under the
# `JasonYeYuhe` owner, and the arch is always arm64. See Casks/cli-pulse.rb.
REPO="JasonYeYuhe/cli-pulse-distrib"
TAG="app-v${VERSION}"
ASSET="CLI-Pulse-${VERSION}-arm64.dmg"
CASK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Casks/cli-pulse.rb"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
# rewrite in place with python3 and check its status directly.
python3 - "$CASK" "$VERSION" "$SHA" <<'PY'
import re, sys
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
new = re.sub(r'^(\s*version\s+)"[^"]*"', rf'\g<1>"{version}"', src, count=1, flags=re.M)
new = re.sub(r'^(\s*sha256\s+)"[^"]*"', rf'\g<1>"{sha}"', new, count=1, flags=re.M)
if new == src:
    print("ERROR: cask unchanged — version/sha256 lines did not match", file=sys.stderr)
    sys.exit(1)
open(path, "w").write(new)
PY

echo "==> updated $CASK"
grep -E '^\s*(version|sha256)' "$CASK"

if command -v brew >/dev/null 2>&1; then
    echo "==> brew style"
    brew style --cask "$CASK" || echo "    (style issues above — fix before publishing)"
else
    echo "==> brew not installed; skipping style check"
fi

echo
echo "Next (Owner-gated): publish to the tap so \`brew install --cask cli-pulse\` resolves."

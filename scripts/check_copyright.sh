#!/usr/bin/env bash
# Keep the product copyright line consistent, and keep it away from the two
# things that look like copyright and are not.
#
# From v1.45 the holder is "Ye Yuhe & Cao Yuqi" — the partner was added as a
# joint holder on 2026-08-01. v1.44.0 shipped as "2026 Yuhe Ye" and is not
# changed retroactively.
#
# THREE STRINGS IN THIS REPO LOOK ALIKE. ONLY ONE IS THE PRODUCT COPYRIGHT:
#
#   1. LICENSE.md's holder line — the product copyright. This is what changes.
#   2. "Developer ID Application: Yuhe Ye (KHMK6Q3L3K)" — an Apple SIGNING
#      CERTIFICATE identity. Rewriting it breaks signing and the notarisation
#      chain, and HelperPkgVerifier matches on it. Never touch it.
#   3. "Copyright (c) 2026 Peter Steinberger" — upstream attribution for code
#      adapted from CodexBar. Rewriting it would claim someone else's work.
#      Never touch it.
#
# A blanket search-and-replace over "Yuhe Ye" hits all three. This gate exists
# so that mistake fails loudly instead of shipping.
#
# The App Store Connect `copyright` field on each appStoreVersion must match
# LICENSE.md, and nothing in this repo can enforce that — it is set through the
# API or the ASC web UI per version, and it silently inherits the previous
# version's value when a new one is created. The reminder below is the only
# guard there is; treat a release checklist item as mandatory.
#
# Usage: scripts/check_copyright.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXPECTED="Copyright (c) 2025–2026 Ye Yuhe & Cao Yuqi. All Rights Reserved."
status=0

if ! grep -qF "$EXPECTED" LICENSE.md; then
    echo "✗ LICENSE.md does not carry the expected copyright line." >&2
    echo "" >&2
    echo "  expected: $EXPECTED" >&2
    echo "  found:    $(grep -m1 -i 'copyright' LICENSE.md || echo '(no copyright line)')" >&2
    echo "" >&2
    echo "  If the holder legitimately changed, update EXPECTED in this script" >&2
    echo "  AND the copyright field on the next appStoreVersion in ASC — they" >&2
    echo "  are set independently and drift silently." >&2
    status=1
fi

# The signing identity must survive intact in EVERY build script that uses it.
#
# The first version of this check was `grep -rq` over two directories, i.e. "is
# it anywhere at all". That passes while three of four build scripts have been
# rewritten, and it passed both negative tests when they were first run — a gate
# that cannot fail. Each file is now checked individually.
#
# This script is deliberately excluded from the scan: it contains the string in
# its own documentation, and including it would let the gate satisfy itself.
SIGN_FILES=(
    "scripts/build_helper_uninstaller.sh"
    "scripts/build_devid_dmg.sh"
    "scripts/build_helper_pkg.sh"
    "CLI Pulse Bar/scripts/build-tmux-universal.sh"
)
for f in "${SIGN_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    if ! grep -qF "Developer ID Application: Yuhe Ye" "$f"; then
        echo "✗ $f no longer carries the Developer ID signing identity." >&2
        echo "  'Developer ID Application: Yuhe Ye (KHMK6Q3L3K)' is a CERTIFICATE" >&2
        echo "  name, not a copyright. Renaming it breaks signing." >&2
        status=1
    fi
done

# Upstream attribution must survive intact.
# Count, not existence. 42 files carry this header today; a rename that hit
# some-but-not-all would leave the count above zero and pass an existence
# check — which is what happened on the first run of this gate's own negative
# test (42 -> 36 and still green). The floor makes partial removal fail.
STEINBERGER_MIN=42
steinberger="$(grep -rl "Copyright (c) 2026 Peter Steinberger" \
    "CLI Pulse Bar/CLIPulseCore/Sources" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$steinberger" -lt "$STEINBERGER_MIN" ]]; then
    echo "✗ Upstream attribution count dropped: $steinberger < $STEINBERGER_MIN expected." >&2
    echo "  Those headers credit code adapted from CodexBar. Removing them" >&2
    echo "  claims someone else's work — restore them." >&2
    status=1
fi

if [[ $status -eq 0 ]]; then
    echo "✓ copyright: LICENSE.md correct, ${#SIGN_FILES[@]} signing sites and $steinberger upstream headers intact"
fi
exit $status

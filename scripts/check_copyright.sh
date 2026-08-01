#!/usr/bin/env bash
# Keep the product copyright line consistent, and keep it away from the two
# things that look like copyright and are not.
#
# The holder is "Ye Yuhe & Cao Yuqi" — the partner was added as a joint holder
# on 2026-08-01, effective from v1.44.0.
#
# An earlier draft of this comment said the change started at v1.45 because
# v1.44.0 was already approved and editing an approved version's metadata was
# assumed to risk a return to review. That assumption was never tested and was
# wrong for this field: the ASC `copyright` PATCH went through on both
# platforms with the state staying PENDING_DEVELOPER_RELEASE and no review
# submission reopening, so 1.44.0 shipped with the joint holder.
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
# LICENSE.md, and nothing in this repo can enforce that — it is set per version
# through the API or the ASC web UI. A new version SILENTLY INHERITS the
# previous one's value, so 1.45.0 will pick up the correct string from 1.44.0
# on its own. That inheritance is also the hazard: if the holder ever changes
# again, every future version keeps the old value until someone sets it by
# hand, and nothing here will complain.
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

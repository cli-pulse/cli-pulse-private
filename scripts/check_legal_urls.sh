#!/usr/bin/env bash
# Fail if the app's Privacy Policy / Terms of Use links are wrong or dead.
#
# These are not ordinary links. Guideline 3.1.2 requires a subscription app to
# carry working Terms and Privacy links INSIDE the app, and App Review clicks
# them. They are compiled into the paywall, the iOS settings screen and the
# account-deletion screen.
#
# It has already gone wrong once, silently. The 2026-07-18 move to the
# `cli-pulse` org changed where GitHub Pages serves from, and GitHub does not
# redirect `<user>.github.io/<repo>` after a transfer. Every one of these links
# started returning 404 — for users of the LIVE App Store build, not just for
# the next one — and nothing noticed for twelve days. It was found only because
# someone happened to curl the URL while syncing unrelated GitHub metadata.
#
# Two things are checked, because either alone would have missed it:
#   1. The source uses the canonical host (a grep — cheap, runs everywhere).
#   2. Both the canonical AND the legacy host actually serve 200 (a network
#      check — skipped when offline, since a laptop on a plane is not a defect).
#
# The legacy host must keep working for as long as any supported release
# hardcodes it: those binaries cannot be changed. JasonYeYuhe/cli-pulse exists
# only to serve redirect stubs for that reason.
#
# Usage: scripts/check_legal_urls.sh [--offline]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="https://cli-pulse.github.io/cli-pulse"
LEGACY="https://jasonyeyuhe.github.io/cli-pulse"

status=0

# --- 1. source uses the canonical host -------------------------------------
#
# Scoped to the app targets. `.build/` and `.claude/worktrees/` are excluded:
# the former is derived, and the latter holds other sessions' checkouts, which
# this repo's gates have no business asserting about.
hits="$(
    find "$ROOT/CLI Pulse Bar" -name '*.swift' -not -path '*/.build/*' -print0 2>/dev/null \
        | xargs -0 grep -l "jasonyeyuhe\.github\.io" 2>/dev/null || true
)"

if [[ -n "$hits" ]]; then
    echo "✗ Source still points at the legacy Pages host:" >&2
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo "    ${f#"$ROOT/"}" >&2
    done <<< "$hits"
    cat >&2 <<MSG

  Use $CANONICAL instead. The legacy host is kept alive only so that ALREADY
  SHIPPED builds keep working — new code must not add to that debt.
MSG
    status=1
fi

# --- 2. both hosts actually serve ------------------------------------------
if [[ "${1:-}" == "--offline" ]]; then
    echo "(offline: skipped the reachability check)"
else
    if ! curl -sSf -o /dev/null --max-time 10 "$CANONICAL/" 2>/dev/null; then
        echo "(no network, or the canonical host is unreachable: skipping URL checks)"
    else
        for host_label in "canonical:$CANONICAL" "legacy:$LEGACY"; do
            label="${host_label%%:*}"
            base="${host_label#*:}"
            for page in privacy.html terms.html; do
                code="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 15 "$base/$page")"
                if [[ "$code" != "200" ]]; then
                    echo "✗ $label $base/$page → HTTP $code" >&2
                    if [[ "$label" == "legacy" ]]; then
                        cat >&2 <<'MSG'
    Shipped builds hardcode this URL in the paywall and settings screens, and
    App Review checks it under Guideline 3.1.2. Restore the redirect stubs in
    JasonYeYuhe/cli-pulse (docs/) — do not delete that repository.
MSG
                    fi
                    status=1
                else
                    echo "✓ $label $base/$page → 200"
                fi
            done
        done
    fi
fi

if [[ $status -eq 0 ]]; then
    echo "✓ legal URLs: source is canonical, both hosts serve"
fi
exit $status

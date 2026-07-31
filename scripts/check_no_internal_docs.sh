#!/usr/bin/env bash
# Fail if internal engineering documents are committed to this PUBLIC repository.
#
# The repo is named `cli-pulse-private` and is public. That name is the trap,
# and it worked: AGENTS.md said "`origin` is the private source repository" and
# listed the product directories under "Must stay private" — both false since
# the repo was made public — so 91 PROJECT_FIX_*.md files and 46 planning
# documents, session checkpoints and fix plans were published. One of them
# carried a "Credentials recap" section. Nothing in it was a live secret, but
# nobody discovered that until someone went looking, twelve weeks later.
#
# The wording was fixed (#402) and the documents moved to cli-pulse-internal.
# This gate is the part that does not depend on anyone reading the wording.
#
# What belongs in cli-pulse-internal instead:
#   - incident write-ups and fix post-mortems (PROJECT_FIX_*)
#   - development plans, ship checklists, session checkpoints
#   - anything naming credentials, even redacted ones
#   - anything you would not want a competitor or a stranger to read
#
# Genuinely public documentation — README, AGENTS, CLAUDE, BRANCHING, PRIVACY,
# TERMS, LICENSE, the docs/ site — is unaffected.
#
# Usage: scripts/check_no_internal_docs.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Patterns that mark a file as internal. Deliberately matched against the
# FILENAME rather than the content: a content heuristic would either miss
# rewordings or block legitimate public docs that merely mention an incident.
PATTERNS=(
    'PROJECT_FIX'
    'DEVELOPMENT_PLAN'
    'DEV_PLAN'
    'FIX_PLAN'
    'SESSION_CHECKPOINT'
    'SHIP_CHECKLIST'
)

offenders=""
while IFS= read -r f; do
    base="$(basename "$f")"
    for p in "${PATTERNS[@]}"; do
        case "$base" in
            *"$p"*) offenders="${offenders}${f}"$'\n'; break ;;
        esac
    done
done < <(git ls-files)

if [[ -n "$offenders" ]]; then
    count="$(grep -c . <<< "$offenders" || true)"
    echo "✗ $count internal document(s) tracked in this PUBLIC repository:" >&2
    echo "" >&2
    sed '/^$/d; s/^/    /' <<< "$offenders" | head -20 >&2
    if [[ "$count" -gt 20 ]]; then
        echo "    … and $((count - 20)) more" >&2
    fi
    cat >&2 <<'MSG'

  This repository is public. Its name is not.

  Move these to cli-pulse-internal:

      git clone git@github.com:cli-pulse/cli-pulse-internal.git
      cp <file> cli-pulse-internal/private-repo-root-docs/
      git rm <file>

  If a file genuinely belongs in public — a design note written for users,
  say — rename it so it does not read as an internal document, or add its
  exact path to the allowlist in this script with a comment explaining why.
MSG
    exit 1
fi

echo "✓ no internal documents tracked in the public repo"

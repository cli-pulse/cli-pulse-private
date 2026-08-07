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

# LAYER 1 — filename patterns.
#
# Matched case-INSENSITIVELY. The original version compared with a
# case-sensitive glob, which let `macos-onboarding-multi-account-checklist.md`
# through while blocking `SHIP_CHECKLIST.md`: same kind of document, opposite
# verdict, decided by the shift key. Naming style is not a security boundary.
PATTERNS=(
    'PROJECT_FIX'
    'DEVELOPMENT_PLAN'
    'DEV_PLAN'
    'FIX_PLAN'
    'SESSION_CHECKPOINT'
    'SHIP_CHECKLIST'
    'POSTMORTEM'
    'POST_MORTEM'
    'RUNBOOK'
    # 2026-08-07. The list above missed a whole class: per-session AI artifacts.
    # `CLAUDE_HANDOFF_v1.21_long_tail_2026-05-15.txt` sat TRACKED in this public
    # repo while this gate reported it clean, because no pattern matched it and
    # it never declares itself internal, so LAYER 2 could not see it either.
    # These are hand-off notes, task prompts and review dumps written for one
    # working session — exactly the material the 07-31 incident was about.
    #
    # Hyphen AND underscore variants are both listed on purpose: matching is a
    # literal substring test, so 'REVIEW_TODO' does not match
    # `gemini-review-todo.md`. Naming style is not a security boundary — the
    # same reasoning that made this list case-insensitive.
    'HANDOFF'
    'NEXT_SESSION'
    'KICKOFF'
    'REVIEW_PROMPT'
    'REVIEW-PROMPT'
    'FIX_PROMPT'
    'FIX-PROMPT'
    'REVIEW_FEEDBACK'
    'REVIEW-FEEDBACK'
    'REVIEW_TODO'
    'REVIEW-TODO'
    'CHECKLIST'
)

# LAYER 2 — the document says so itself.
#
# The header comment used to argue that content matching was the wrong tool,
# and for TOPIC words it is: grepping for "incident" blocks a public changelog
# that mentions one. But an author writing "Internal only. Do not publish."
# is not mentioning a topic, they are DECLARING the file's audience — and a
# declaration is exactly what a gate should key on. Layer 1 cannot see it,
# because that author is free to name the file anything.
#
# Only the first 25 lines are searched: a declaration belongs at the top, and
# bounding it keeps a body quoting one of these phrases from tripping the gate.
DECLARATIONS=(
    'internal/private-source'
    'internal only'
    'internal-only'
    'do not publish'
    'not for public'
    'internal engineering document'
)

# Paths that match a rule above but are deliberately public. Each needs a
# comment saying why — an unexplained entry is how a gate rots into a no-op.
ALLOWLIST=(
    # Reviewed 2026-07-31 and deliberately kept public. Its own header records
    # the decision: it originally carried a private-source restriction written
    # on the false premise that this repo is private, and "every value in the
    # table below is already a literal in CLIPulseRuntimeEnvironment.swift,
    # which ships in this repo". So it is a QA checklist containing nothing the
    # source does not already publish.
    #
    # It is allowlisted rather than left unmatched because this gate's own
    # header cites it as the example of a document that wrongly got through —
    # yet no pattern actually matched it even after the case-insensitivity fix.
    # 'CHECKLIST' now matches it, and this entry is the recorded decision.
    "docs/qa/macos-onboarding-multi-account-checklist.md"
)

is_allowlisted() {
    local candidate="$1" entry
    for entry in ${ALLOWLIST[@]+"${ALLOWLIST[@]}"}; do
        [[ "$candidate" == "$entry" ]] && return 0
    done
    return 1
}

# `nocasematch` makes `[[ == ]]` case-insensitive using bash's own matcher.
# The obvious alternative — lowercasing with `tr` — forks a process per file
# per pattern. At this repo's file count that took the gate from milliseconds
# to over five minutes, which in CI is indistinguishable from a hang. A gate
# nobody will wait for is a gate somebody will disable.
shopt -s nocasematch

offenders=""
while IFS= read -r f; do
    is_allowlisted "$f" && continue
    base="${f##*/}"
    matched=""

    for p in "${PATTERNS[@]}"; do
        if [[ "$base" == *"$p"* ]]; then
            matched="filename matches '$p'"
            break
        fi
    done

    # Layer 2 reads the file, so restrict it to text documents and skip this
    # script — which necessarily contains every phrase it searches for.
    if [[ -z "$matched" && -f "$f" && "$f" != "scripts/check_no_internal_docs.sh" ]]; then
        case "$f" in
            *.md|*.txt|*.rst|*.adoc)
                head_text="$(head -25 "$f" 2>/dev/null || true)"
                for d in "${DECLARATIONS[@]}"; do
                    if [[ "$head_text" == *"$d"* ]]; then
                        matched="declares itself internal (\"$d\")"
                        break
                    fi
                done
                ;;
        esac
    fi

    [[ -n "$matched" ]] && offenders="${offenders}${f} — ${matched}"$'\n'
done < <(git ls-files)

shopt -u nocasematch

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

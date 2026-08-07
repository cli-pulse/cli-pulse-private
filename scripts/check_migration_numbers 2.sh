#!/usr/bin/env bash
# Fail if two backend migrations claim the same version number.
#
# These files are the only record of what has been applied to production, and
# they are matched BY NUMBER. Two different migrations sharing one means nobody
# can later answer "did v0.70 run?" — the answer becomes "which v0.70?".
# Postgres will not stop you: both apply cleanly, and the damage surfaces months
# later during an incident.
#
# It happened on 2026-07-28: `main` carried migrate_v0.70_device_app_version.sql,
# already applied to production, while PR #393 independently added
# migrate_v0.70_provider_accounts.sql. Different schema, same number, neither
# author aware. Review caught it; nothing in the toolchain would have.
#
# Parallel branches are normal here, so "check before you name it" is advice
# that will be missed. This is the part that cannot be.
#
# Usage: scripts/check_migration_numbers.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG_DIR="$ROOT/backend/supabase"

if [[ ! -d "$MIG_DIR" ]]; then
    echo "ERROR: $MIG_DIR not found" >&2
    exit 2
fi

# Version = the vX.Y(.Z) token right after `migrate_`. Everything after the
# next underscore is a human label and is deliberately ignored — the number is
# the identity.
#
# Exit code deliberately does not travel through a pipe (a trap this repo has
# hit before): collect first, then test.
dupes=""
while IFS= read -r version; do
    [[ -z "$version" ]] && continue
    # Parenthesised -o, and -print0: the repo path contains a space, so an
    # unquoted find|xargs pipeline splits "cli pulse" into two bogus entries.
    count=$(find "$MIG_DIR" -maxdepth 1 \( -name "migrate_${version}_*.sql" -o -name "migrate_${version}.sql" \) -print0 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ')
    if [[ "$count" -gt 1 ]]; then
        dupes="${dupes}${version}"$'\n'
    fi
done < <(
    find "$MIG_DIR" -maxdepth 1 -name 'migrate_v*.sql' -print0 2>/dev/null \
        | xargs -0 -n1 basename 2>/dev/null \
        | sed -E 's/^migrate_(v[0-9]+(\.[0-9]+)*)(_.*)?\.sql$/\1/' \
        | sort -u
)

if [[ -n "$dupes" ]]; then
    echo "✗ Duplicate migration numbers:" >&2
    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        echo "" >&2
        echo "  $version is claimed by:" >&2
        find "$MIG_DIR" -maxdepth 1 \( -name "migrate_${version}_*.sql" -o -name "migrate_${version}.sql" \) -print0 2>/dev/null \
            | xargs -0 -n1 basename 2>/dev/null | sed 's/^/    /' >&2
    done <<< "$dupes"
    cat >&2 <<'MSG'

One number, one migration, forever.

Whichever of these is NOT on `main` must be renumbered — `main` wins, because
its migration has usually already been applied to production. Rename the file,
update any reference to it, and note the change in the PR.

Next free number:
MSG
    find "$MIG_DIR" -maxdepth 1 -name 'migrate_v*.sql' -print0 2>/dev/null \
        | xargs -0 -n1 basename 2>/dev/null | sort -V | tail -1 | sed 's/^/  after: /' >&2
    exit 1
fi

total=$(find "$MIG_DIR" -maxdepth 1 -name 'migrate_v*.sql' 2>/dev/null | wc -l | tr -d ' ')
echo "✓ $total migrations, all numbers unique"

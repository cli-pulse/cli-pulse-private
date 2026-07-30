#!/usr/bin/env bash
# Exercise the provider-account contract against both supported install paths:
#   1. the exact pre-v0.72 main schema/RPC baseline plus migrate_v0.72;
#   2. the current canonical schema/RPC files with no migration replay.
#
# The caller owns two empty, disposable databases. Keeping them independent
# prevents a canonical-file replay from masking migration drift.
#
# Usage:
#   UPGRADE_DATABASE_URL=postgres://.../v072_upgrade \
#   FRESH_DATABASE_URL=postgres://.../v072_fresh \
#     ./backend/supabase/tests/run_v072_provider_accounts_tests.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
# Exact `origin/main` integrated by this branch before provider accounts became
# v0.72. It includes the production v0.70 and v0.71 canonical state but no
# provider-account tables/RPCs, so the upgrade fixture cannot skip either side
# of the real boundary.
BASELINE_REF="${PROVIDER_ACCOUNTS_BASE_REF:-87aa7ac97102cac22f2157ca194e7145bc7f2c56}"

if [[ -z "${UPGRADE_DATABASE_URL:-}" ]]; then
  echo "UPGRADE_DATABASE_URL must point to an empty disposable database" >&2
  exit 2
fi
if [[ -z "${FRESH_DATABASE_URL:-}" ]]; then
  echo "FRESH_DATABASE_URL must point to a different empty disposable database" >&2
  exit 2
fi
if [[ "$UPGRADE_DATABASE_URL" == "$FRESH_DATABASE_URL" ]]; then
  echo "upgrade and fresh paths must use different databases" >&2
  exit 2
fi
if ! git -C "$REPO_ROOT" cat-file -e "${BASELINE_REF}^{commit}"; then
  echo "pre-v0.72 baseline commit is unavailable: $BASELINE_REF" >&2
  echo "fetch full history or set PROVIDER_ACCOUNTS_BASE_REF explicitly" >&2
  exit 2
fi

BASELINE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipulse-v072-baseline.XXXXXX")"
cleanup() {
  rm -rf "$BASELINE_DIR"
}
trap cleanup EXIT

for file in schema.sql app_rpc.sql helper_rpc.sql; do
  git -C "$REPO_ROOT" show \
    "${BASELINE_REF}:backend/supabase/${file}" \
    >"$BASELINE_DIR/$file"
done

PSQL=(psql --no-psqlrc -X -q -v ON_ERROR_STOP=1)

apply_sql() {
  local database_url="$1"
  local label="$2"
  local file="$3"
  echo "── $label"
  "${PSQL[@]}" "$database_url" -f "$file"
}

seed_supabase_shim() {
  local database_url="$1"
  apply_sql \
    "$database_url" \
    "seeding plain-Postgres Supabase shim" \
    "$HERE/rls/00_supabase_shim.sql"
}

echo "== provider accounts: pre-v0.72 upgrade path =="
seed_supabase_shim "$UPGRADE_DATABASE_URL"
apply_sql "$UPGRADE_DATABASE_URL" "loading pre-v0.72 schema" \
  "$BASELINE_DIR/schema.sql"
apply_sql "$UPGRADE_DATABASE_URL" "loading pre-v0.72 app RPCs" \
  "$BASELINE_DIR/app_rpc.sql"
apply_sql "$UPGRADE_DATABASE_URL" "loading pre-v0.72 helper RPCs" \
  "$BASELINE_DIR/helper_rpc.sql"
apply_sql "$UPGRADE_DATABASE_URL" "applying migrate_v0.72" \
  "$REPO_ROOT/backend/supabase/migrate_v0.72_provider_accounts.sql"
apply_sql "$UPGRADE_DATABASE_URL" "reapplying migrate_v0.72 (idempotence)" \
  "$REPO_ROOT/backend/supabase/migrate_v0.72_provider_accounts.sql"
apply_sql "$UPGRADE_DATABASE_URL" "running upgrade-path contract assertions" \
  "$HERE/migrate_v0.72_provider_accounts.test.sql"
DATABASE_URL="$UPGRADE_DATABASE_URL" \
  bash "$HERE/migrate_v0.72_provider_accounts.concurrent.sh"

echo "== provider accounts: current canonical fresh path =="
seed_supabase_shim "$FRESH_DATABASE_URL"
apply_sql "$FRESH_DATABASE_URL" "loading current schema" \
  "$REPO_ROOT/backend/supabase/schema.sql"
apply_sql "$FRESH_DATABASE_URL" "loading current app RPCs" \
  "$REPO_ROOT/backend/supabase/app_rpc.sql"
apply_sql "$FRESH_DATABASE_URL" "loading current helper RPCs" \
  "$REPO_ROOT/backend/supabase/helper_rpc.sql"
apply_sql "$FRESH_DATABASE_URL" "running fresh-path contract assertions" \
  "$HERE/migrate_v0.72_provider_accounts.test.sql"
DATABASE_URL="$FRESH_DATABASE_URL" \
  bash "$HERE/migrate_v0.72_provider_accounts.concurrent.sh"

echo "provider-account v0.72 upgrade + fresh contract suites: PASS"

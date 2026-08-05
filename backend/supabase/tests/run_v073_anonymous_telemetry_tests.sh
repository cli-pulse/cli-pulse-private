#!/usr/bin/env bash
# Verify migrate_v0.73 against a real Postgres, without pgTAP.
#
# The companion .test.sql is pgTAP and is owner-run against a branch database,
# which in practice means it runs approximately never. This script asserts the
# same properties with plain SQL so CI can run it on every push — a check that
# only ever ran on one laptop is not a check.
#
# What it proves, in priority order:
#
#   1. LOCKDOWN. record_anonymous_install is the only RPC in this schema
#      callable by an UNAUTHENTICATED caller, so the table behind it must be
#      unreachable three independent ways: RLS on, zero policies, zero grants.
#   2. VALIDATION. Bad channel / app_version / os_version are REJECTED and
#      leave no row. Without this, an anonymous caller has free-text storage.
#   3. WRITE-ONCE. first_provider_detected_at survives later launches. If it
#      could move, "time to first value" would decay into "time since last
#      launch" — still populated, still plausible, wrong in the flattering
#      direction.
#
# Usage:
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/v073 \
#     ./backend/supabase/tests/run_v073_anonymous_telemetry_tests.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATION="$HERE/../migrate_v0.73_anonymous_install_telemetry.sql"

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to an empty disposable database" >&2
    exit 2
fi
[[ -f "$MIGRATION" ]] || { echo "missing $MIGRATION" >&2; exit 2; }

psql_q() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qtAX "$@"; }

# Supabase's roles do not exist in a bare Postgres. Without them the grants in
# the migration would error and the privilege assertions would be vacuous.
psql_q -c "do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
end \$\$;" >/dev/null

echo "applying $(basename "$MIGRATION") ..."
psql_q -f "$MIGRATION" >/dev/null

# Applying twice proves idempotence. A migration that only works on an empty
# database is a migration that cannot be re-run after a partial failure.
psql_q -f "$MIGRATION" >/dev/null
echo "  re-applied cleanly (idempotent)"

fails=0
check() { # check <label> <sql returning t/f>
    local label="$1" sql="$2" got
    got="$(psql_q -c "select ($sql)::text")"
    if [[ "$got" == "true" ]]; then
        echo "  PASS  $label"
    else
        echo "  FAIL  $label  (got '$got')" >&2
        fails=$((fails + 1))
    fi
}

echo "lockdown:"
check "RLS enabled"                 "select relrowsecurity from pg_class where oid='public.anonymous_installs'::regclass"
check "zero policies (deliberate)"  "select count(*)=0 from pg_policies where tablename='anonymous_installs'"
check "anon cannot SELECT"          "select not has_table_privilege('anon','public.anonymous_installs','SELECT')"
check "anon cannot INSERT"          "select not has_table_privilege('anon','public.anonymous_installs','INSERT')"
check "authenticated cannot SELECT" "select not has_table_privilege('authenticated','public.anonymous_installs','SELECT')"
check "anon CAN execute ingest"     "select has_function_privilege('anon','public.record_anonymous_install(uuid,text,text,text,boolean)','EXECUTE')"
check "anon cannot read summary"    "select not has_function_privilege('anon','public.anonymous_activation_summary(integer)','EXECUTE')"
check "anon cannot prune"           "select not has_function_privilege('anon','public.prune_anonymous_installs()','EXECUTE')"

echo "validation (must reject, not store):"
reject() { # reject <label> <args>
    local label="$1"; shift
    if psql_q -c "select record_anonymous_install($*)" >/dev/null 2>&1; then
        echo "  FAIL  $label was ACCEPTED" >&2
        fails=$((fails + 1))
    else
        echo "  PASS  $label rejected"
    fi
}
BAD_ID="'11111111-1111-1111-1111-111111111111'::uuid"
reject "unknown channel"  "$BAD_ID,'bogus','1.44.0','15.1'"
reject "junk app_version" "$BAD_ID,'mas','not-a-version; drop table x','15.1'"
reject "junk os_version"  "$BAD_ID,'mas','1.44.0','15.1.1-custom-build'"
check  "rejected input stored no row" "select count(*)=0 from anonymous_installs where install_id=$BAD_ID"

echo "behaviour:"
ID="'22222222-2222-2222-2222-222222222222'::uuid"
psql_q -c "select record_anonymous_install($ID,'devid','1.44.0','15.1',false)" >/dev/null
psql_q -c "select record_anonymous_install($ID,'devid','1.44.0','15.1',false)" >/dev/null
psql_q -c "select record_anonymous_install($ID,'devid','1.45.0','15.2',false)" >/dev/null
check "3 calls -> 1 row"        "select count(*)=1 from anonymous_installs where install_id=$ID"
check "version/channel refresh" "select app_version='1.45.0' and channel='devid' from anonymous_installs where install_id=$ID"

psql_q -c "select record_anonymous_install($ID,'devid','1.45.0','15.2',true)" >/dev/null
FIRST="$(psql_q -c "select first_provider_detected_at from anonymous_installs where install_id=$ID")"
[[ -n "$FIRST" ]] || { echo "  FAIL  activation was not recorded" >&2; fails=$((fails + 1)); }
# Each psql -c is its own transaction, so now() advances between these calls;
# a missing coalesce in the upsert would visibly move the timestamp.
sleep 1
psql_q -c "select record_anonymous_install($ID,'devid','1.45.0','15.2',true)" >/dev/null
psql_q -c "select record_anonymous_install($ID,'devid','1.45.0','15.2',true)" >/dev/null
check "activation ts never overwritten" \
    "select first_provider_detected_at='$FIRST'::timestamptz from anonymous_installs where install_id=$ID"

# Negative control: prove the assertion above can actually fail. A test that
# cannot fail is decoration. This builds the buggy upsert (no coalesce) and
# asserts that it DOES move the timestamp.
psql_q -c "create or replace function _v073_bad(p_id uuid) returns void language plpgsql as \$f\$
begin
  insert into anonymous_installs as ai (install_id,channel,app_version,os_version,first_provider_detected_at)
  values (p_id,'devid','1.45.0','15.2',now())
  on conflict (install_id) do update set first_provider_detected_at = excluded.first_provider_detected_at;
end \$f\$;" >/dev/null
BAD="'44444444-4444-4444-4444-444444444444'::uuid"
psql_q -c "select _v073_bad($BAD)" >/dev/null
BAD_FIRST="$(psql_q -c "select first_provider_detected_at from anonymous_installs where install_id=$BAD")"
sleep 1
psql_q -c "select _v073_bad($BAD)" >/dev/null
check "negative control: buggy upsert DOES move it" \
    "select first_provider_detected_at <> '$BAD_FIRST'::timestamptz from anonymous_installs where install_id=$BAD"
psql_q -c "drop function _v073_bad(uuid)" >/dev/null

echo
if (( fails > 0 )); then
    echo "✗ $fails check(s) failed" >&2
    exit 1
fi
echo "✓ v0.73 anonymous telemetry: lockdown, validation and write-once all hold"

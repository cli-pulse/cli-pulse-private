#!/usr/bin/env bash
# Verify migrate_v0.76 against a real Postgres, on the UPGRADE PATH.
#
# The risk in v0.76 is not the new columns, it is the function replacement.
# `record_anonymous_install` is the only RPC in this schema callable by an
# UNAUTHENTICATED caller, and v0.76 drops and recreates it with three extra
# parameters. Three things can go wrong, all silently:
#
#   1. `create or replace` cannot add parameters. Doing it that way leaves the
#      old 5-arg function in place as a second overload, and every subsequent
#      call is ambiguous. The failure is a 300-error on the only write path
#      anonymous users have.
#   2. Grants do not survive a drop. A migration that forgets to re-grant
#      closes that same path, and the symptom -- no rows arriving -- is
#      indistinguishable from "nobody installed the app".
#   3. A shipped 1.52 binary sends five keys. If it stops binding, every
#      install already in the field goes silent, and it goes silent in exactly
#      the way this telemetry exists to detect, so nothing reports the outage.
#
# So this replays the real sequence -- v0.73, then v0.76 -- rather than seeding
# the end state, and asserts against a row written by the OLD signature before
# the upgrade.
#
# Usage:
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/v076 \
#     ./backend/supabase/tests/run_v076_activation_funnel_tests.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V073="$HERE/../migrate_v0.73_anonymous_install_telemetry.sql"
V076="$HERE/../migrate_v0.76_activation_funnel.sql"

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to an empty disposable database" >&2
    exit 2
fi
for f in "$V073" "$V076"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done

psql_q() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qtAX "$@"; }

psql_q -c "do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
end \$\$;" >/dev/null

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

FIVE_ARG="public.record_anonymous_install(uuid,text,text,text,boolean)"
EIGHT_ARG="public.record_anonymous_install(uuid,text,text,text,boolean,boolean,boolean,text)"
OLD_ID="'11111111-1111-1111-1111-111111111111'::uuid"
NEW_ID="'33333333-3333-3333-3333-333333333333'::uuid"

# ── the pre-state, exactly as production looked on 2026-08-30 ──────────────
echo "applying v0.73 (pre-state) ..."
psql_q -f "$V073" >/dev/null
check "pre-state has the 5-arg signature" \
      "select has_function_privilege('anon','$FIVE_ARG','EXECUTE')"

# A row written by the OLD client, BEFORE the upgrade. Every claim about
# backward compatibility below is measured against this row rather than a row
# the new code wrote and then read back.
psql_q -c "select record_anonymous_install($OLD_ID,'devid','1.52.0','15.1',true)" >/dev/null
OLD_ACTIVATED="$(psql_q -c "select first_provider_detected_at from anonymous_installs where install_id=$OLD_ID")"
[[ -n "$OLD_ACTIVATED" ]] || { echo "  FAIL  pre-state row was not written" >&2; exit 1; }

# ── the upgrade ────────────────────────────────────────────────────────────
echo "applying v0.76 ..."
psql_q -f "$V076" >/dev/null
psql_q -f "$V076" >/dev/null
echo "  re-applied cleanly (idempotent)"

echo "function replacement:"
check "exactly ONE overload exists" \
      "select count(*)=1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='record_anonymous_install'"
check "the 5-arg signature is GONE" \
      "select to_regprocedure('$FIVE_ARG') is null"
check "anon CAN execute the new ingest"          "select has_function_privilege('anon','$EIGHT_ARG','EXECUTE')"
check "authenticated CAN execute the new ingest" "select has_function_privilege('authenticated','$EIGHT_ARG','EXECUTE')"

echo "lockdown survived the alter:"
check "RLS still enabled"           "select relrowsecurity from pg_class where oid='public.anonymous_installs'::regclass"
check "still zero policies"         "select count(*)=0 from pg_policies where tablename='anonymous_installs'"
check "anon still cannot SELECT"    "select not has_table_privilege('anon','public.anonymous_installs','SELECT')"
check "anon still cannot INSERT"    "select not has_table_privilege('anon','public.anonymous_installs','INSERT')"
check "anon cannot read the funnel" "select not has_function_privilege('anon','public.anonymous_funnel_summary(integer)','EXECUTE')"
check "authenticated cannot either" "select not has_function_privilege('authenticated','public.anonymous_funnel_summary(integer)','EXECUTE')"

echo "backward compatibility (a shipped 1.52 binary sends five keys):"
psql_q -c "select record_anonymous_install($OLD_ID,'devid','1.52.0','15.1',true)" >/dev/null
check "the 5-key call still binds and updates one row" \
      "select count(*)=1 from anonymous_installs where install_id=$OLD_ID"
check "pre-migration row keeps its activation timestamp" \
      "select first_provider_detected_at='$OLD_ACTIVATED'::timestamptz from anonymous_installs where install_id=$OLD_ID"
check "pre-migration row reports NULL, not false, for the new milestones" \
      "select helper_connected_at is null and first_cost_at is null and ui_language is null
         from anonymous_installs where install_id=$OLD_ID"

echo "the new fields:"
psql_q -c "select record_anonymous_install($NEW_ID,'mas','1.53.0','15.2',true,true,true,'ko')" >/dev/null
check "all three milestones recorded" \
      "select helper_connected_at is not null and first_provider_detected_at is not null
              and first_cost_at is not null and ui_language='ko'
         from anonymous_installs where install_id=$NEW_ID"

HC="$(psql_q -c "select helper_connected_at from anonymous_installs where install_id=$NEW_ID")"
LS="$(psql_q -c "select last_seen_at from anonymous_installs where install_id=$NEW_ID")"
# Each psql -c is its own transaction, so now() advances between calls. Without
# that, a `do $$ ... $$` block would freeze now() and every timestamp assertion
# below would pass no matter what the upsert did.
sleep 1
psql_q -c "select record_anonymous_install($NEW_ID,'mas','1.53.0','15.2',true,true,true,'ko')" >/dev/null
check "helper_connected_at never moves"  "select helper_connected_at='$HC'::timestamptz from anonymous_installs where install_id=$NEW_ID"
check "last_seen_at DOES move"           "select last_seen_at > '$LS'::timestamptz from anonymous_installs where install_id=$NEW_ID"

echo "language handling:"
psql_q -c "select record_anonymous_install($NEW_ID,'mas','1.52.0','15.2',true)" >/dev/null
check "an older client does not erase a known language" \
      "select ui_language='ko' from anonymous_installs where install_id=$NEW_ID"
psql_q -c "select record_anonymous_install($NEW_ID,'mas','1.53.0','15.2',true,true,true,'es')" >/dev/null
check "a language change is picked up (latest wins)" \
      "select ui_language='es' from anonymous_installs where install_id=$NEW_ID"

echo "validation (must reject, not store):"
BAD_ID="'44444444-4444-4444-4444-444444444444'::uuid"
if psql_q -c "select record_anonymous_install($BAD_ID,'mas','1.53.0','15.2',false,false,false,'fr')" >/dev/null 2>&1; then
    echo "  FAIL  an unlisted ui_language was ACCEPTED" >&2
    fails=$((fails + 1))
else
    echo "  PASS  unlisted ui_language rejected"
fi
check "the rejected call stored no row" "select count(*)=0 from anonymous_installs where install_id=$BAD_ID"
for lang in en es ja ko zh-Hans zh-Hant other; do
    psql_q -c "select record_anonymous_install(gen_random_uuid(),'devid','1.53.0','15.2',false,false,false,'$lang')" >/dev/null
done
check "all seven listed languages accepted" \
      "select count(distinct ui_language)=7 from anonymous_installs where ui_language is not null"

echo "readout:"
check "the funnel counts each milestone independently" \
      "select helper_connected=1 and provider_detected=1 and cost_shown=1
         from anonymous_funnel_summary(30) where channel='mas' and ui_language='es'"
check "pre-migration rows report as 'unreported', not as failures" \
      "select installs=1 and helper_connected=0
         from anonymous_funnel_summary(30) where channel='devid' and ui_language='unreported'"
check "the v0.73 readout still works, untouched" \
      "select count(*)>0 from anonymous_activation_summary(30)"

# ── negative control ───────────────────────────────────────────────────────
# Two of the assertions above are the kind that pass for the wrong reason: a
# timestamp that "never moves" also never moves if nothing wrote it, and a
# language that "is not erased" also survives if the upsert ignores the column
# entirely. Build the buggy upsert on purpose and prove each assertion fails
# against it. A check nobody has watched fail is decoration.
echo "negative control (the buggy upsert MUST break these):"
psql_q -c "create or replace function _v076_bad(p_id uuid, p_lang text) returns void language plpgsql as \$f\$
begin
  insert into anonymous_installs as ai (install_id,channel,app_version,os_version,helper_connected_at,ui_language)
  values (p_id,'devid','1.53.0','15.2',now(),p_lang)
  on conflict (install_id) do update set
    helper_connected_at = excluded.helper_connected_at,
    ui_language = excluded.ui_language;
end \$f\$;" >/dev/null
NEG="'55555555-5555-5555-5555-555555555555'::uuid"
psql_q -c "select _v076_bad($NEG,'ko')" >/dev/null
NEG_HC="$(psql_q -c "select helper_connected_at from anonymous_installs where install_id=$NEG")"
sleep 1
psql_q -c "select _v076_bad($NEG,null)" >/dev/null
check "buggy upsert DOES move helper_connected_at" \
      "select helper_connected_at <> '$NEG_HC'::timestamptz from anonymous_installs where install_id=$NEG"
check "buggy upsert DOES erase the language" \
      "select ui_language is null from anonymous_installs where install_id=$NEG"
psql_q -c "drop function _v076_bad(uuid,text)" >/dev/null

echo
if (( fails > 0 )); then
    echo "✗ $fails check(s) failed" >&2
    exit 1
fi
echo "✓ v0.76 activation funnel: upgrade path, lockdown, back-compat and write-once all hold"

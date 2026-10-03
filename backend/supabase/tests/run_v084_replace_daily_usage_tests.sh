#!/usr/bin/env bash
# Verify migrate_v0.84 (replace_daily_usage) against a real Postgres.
#
# The bug: upsert_daily_usage never deletes, so when the Mac renames a model
# (`claude-haiku-4-5-20251001` -> `claude-haiku-4-5`) the day keeps both rows
# and the iPhone counts the model twice. The fix: replace_daily_usage makes a
# device's rows for each (day, provider) it sends exactly the set it sent.
#
# What matters is as much what it must NOT delete as what it must:
#   * days and providers the payload does not carry;
#   * another device's rows, the shared "no device" rows, another user's rows;
#   * anything at all when the call fails (one transaction);
#   * and upsert_daily_usage, which apps up to 1.55 still call, must behave
#     exactly as before.
#
# The database is built the way production got there: the shim, schema.sql
# (the pre-v0.37 baseline), v0.37 (device_id, the 2-arg upsert, get_daily_usage
# summing devices) and v0.81's grants on the upsert, then v0.84, twice.
#
# Every check runs even after one fails, and each prints its own label, so a
# branch carrying several deliberate mutations shows one FAIL per mutation.
#
# Usage:
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/v084 \
#     ./backend/supabase/tests/run_v084_replace_daily_usage_tests.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/rls/00_supabase_shim.sql"
SCHEMA="$HERE/../schema.sql"
V037="$HERE/../migrate_v0.37_daily_usage_device_id.sql"
V084="$HERE/../migrate_v0.84_replace_daily_usage.sql"

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to an empty disposable database" >&2
    exit 2
fi
for f in "$SHIM" "$SCHEMA" "$V037" "$V084"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done

psql_q() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX "$@"; }

A=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa      # the user under test
B=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb      # another user
DEV_A1=a1a1a1a1-0000-4000-8000-0000000000a1 # A's paired Mac
DEV_A2=a2a2a2a2-0000-4000-8000-0000000000a2 # A's other paired Mac
DEV_B=b1b1b1b1-0000-4000-8000-0000000000b1  # B's Mac
NIL=00000000-0000-0000-0000-000000000000    # "no device": every unpaired Mac

fails=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }
check() { # check <label> <sql returning boolean>, as the superuser
    local label="$1" sql="$2" got
    got="$(psql_q -c "select ($sql)::text")"
    if [[ "$got" == "true" ]]; then pass "$label"; else fail "$label  (got '$got')"; fi
}

# as_user <uuid|-> <commit|rollback> <sql>: run <sql> the way PostgREST runs a
# call, as `authenticated` with the JWT's sub. `-` sends a JWT without one.
as_user() {
    local user="$1" end="$2" sql="$3" claims
    if [[ "$user" == "-" ]]; then claims='{}'; else claims="{\"sub\":\"$user\",\"role\":\"authenticated\"}"; fi
    psql_q <<SQL
begin;
select set_config('request.jwt.claims', '$claims', true) \g /dev/null
set local role authenticated;
$sql
$end;
SQL
}

# replace_as <uuid> <metrics json> <device uuid|null>: one committed call.
replace_as() {
    local dev="null"
    [[ "$3" != "null" ]] && dev="'$3'::uuid"
    as_user "$1" commit "select public.replace_daily_usage('$2'::jsonb, $dev);"
}

# row <date expr> <provider> <model> <input tokens>: one metrics element
row() { echo "{\"metric_date\":\"$1\",\"provider\":\"$2\",\"model\":\"$3\",\"input_tokens\":$4,\"cost\":0.01}"; }

tokens() { # tokens <user> <device> <date> <provider> <model>: input_tokens or 'none'
    psql_q -c "select coalesce((select input_tokens::text from public.daily_usage_metrics
                 where user_id='$1' and device_id='$2' and metric_date='$3'
                   and provider='$4' and model='$5'), 'none')"
}

D1="$(psql_q -c "select (current_date - 2)::text")"    # in the Mac's window
D2="$(psql_q -c "select (current_date - 1)::text")"    # in the Mac's window
D3="$(psql_q -c "select (current_date - 3)::text")"    # the race below
OLD="$(psql_q -c "select (current_date - 60)::text")"  # no longer uploaded
OLDNAME=claude-haiku-4-5-20251001
NEWNAME=claude-haiku-4-5

echo "building the database the way production got there ..."
psql_q -f "$SHIM" >/dev/null
psql_q -f "$SCHEMA" >/dev/null
psql_q -f "$V037" >/dev/null
# v0.81 §4: what production's upsert_daily_usage grants are.
psql_q >/dev/null <<'SQL'
revoke execute on function public.upsert_daily_usage(jsonb, uuid) from public, anon;
grant  execute on function public.upsert_daily_usage(jsonb, uuid) to authenticated, service_role;
SQL

psql_q >/dev/null <<SQL
insert into auth.users (id, email) values ('$A', 'a@test.local'), ('$B', 'b@test.local');
insert into public.devices (id, user_id, name) values
  ('$DEV_A1', '$A', 'A1'), ('$DEV_A2', '$A', 'A2'), ('$DEV_B', '$B', 'B1');

-- What an app before the rename left in the cloud.
insert into public.daily_usage_metrics
  (user_id, device_id, metric_date, provider, model, input_tokens, updated_at) values
  ('$A', '$DEV_A1', '$D1',  'Claude', '$OLDNAME',        100, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$D1',  'Claude', 'claude-opus-5',  1000, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$D1',  'Codex',  'gpt-5.5',         500, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$D2',  'Claude', '$OLDNAME',        200, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$OLD', 'Claude', '$OLDNAME',        300, now() - interval '60 days'),
  ('$A', '$DEV_A2', '$D1',  'Claude', 'claude-sonnet-5',  70, now() - interval '1 day'),
  ('$A', '$NIL',    '$D1',  'Claude', '$OLDNAME',         40, now() - interval '1 day'),
  ('$B', '$DEV_B',  '$D1',  'Claude', '$OLDNAME',        999, now() - interval '1 day'),
  ('$B', '$NIL',    '$D1',  'Claude', '$OLDNAME',        888, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$D3',  'Claude', 'claude-y',          1, now() - interval '1 day');
SQL

# The renamed upload: what a 1.56 Mac sends for D1 and D2 (Claude only).
RENAMED="[$(row "$D1" Claude "$NEWNAME" 100),$(row "$D1" Claude claude-opus-5 1000),$(row "$D2" Claude "$NEWNAME" 200)]"

# ── the bug, reproduced, before anything is fixed ──────────────────────────
echo "before v0.84, through upsert_daily_usage:"
got="$(as_user "$A" rollback "select public.upsert_daily_usage('$RENAMED'::jsonb, '$DEV_A1'::uuid) \g /dev/null
select (select count(*) from public.daily_usage_metrics
         where device_id = '$DEV_A1' and metric_date = '$D1' and provider = 'Claude'
           and model in ('$OLDNAME', '$NEWNAME')) = 2;")"
if [[ "$got" == "t" ]]; then
    pass "[control] a renamed model keeps both rows: the double count reproduces"
else
    fail "[control] the rename did not leave two rows (got '$got'): this suite would prove nothing"
fi

# ── the migration ──────────────────────────────────────────────────────────
echo "applying $(basename "$V084") ..."
psql_q -f "$V084" >/dev/null
psql_q -f "$V084" >/dev/null
echo "  re-applied cleanly (idempotent)"

echo "grants:"
check "anon cannot execute replace_daily_usage" \
      "not has_function_privilege('anon', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE')"
check "authenticated can execute replace_daily_usage" \
      "has_function_privilege('authenticated', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE')"
check "replace_daily_usage is SECURITY DEFINER with a pinned search_path" \
      "exists (select 1 from pg_proc where proname = 'replace_daily_usage' and prosecdef
                 and proconfig::text like '%search_path=pg_catalog, public, extensions%')"
check "upsert_daily_usage(jsonb, uuid) is still there, still not anon's" \
      "to_regprocedure('public.upsert_daily_usage(jsonb,uuid)') is not null
       and not has_function_privilege('anon', 'public.upsert_daily_usage(jsonb,uuid)', 'EXECUTE')"

# ── old apps: upsert_daily_usage is unchanged ──────────────────────────────
echo "apps up to 1.55 (upsert_daily_usage) behave as before:"
got="$(as_user "$A" rollback "select public.upsert_daily_usage('$RENAMED'::jsonb, '$DEV_A1'::uuid) \g /dev/null
select (select count(*) from public.daily_usage_metrics
         where device_id = '$DEV_A1' and metric_date = '$D1' and provider = 'Claude') = 3;")"
[[ "$got" == "t" ]] && pass "upsert_daily_usage still only writes (3 Claude rows on D1, old name kept)" \
                    || fail "upsert_daily_usage changed behaviour (got '$got')"

# ── the fix ────────────────────────────────────────────────────────────────
echo "replace_daily_usage, A's paired Mac, the renamed upload:"
result="$(replace_as "$A" "$RENAMED" "$DEV_A1")"
check "it reports 3 written and 2 removed  ($result)" \
      "'$result'::jsonb = '{\"upserted\": 3, \"removed\": 2}'::jsonb"
[[ "$(tokens "$A" "$DEV_A1" "$D1" Claude "$OLDNAME")" == none ]] \
    && pass "the old name is gone from D1" || fail "the old name is still on D1"
[[ "$(tokens "$A" "$DEV_A1" "$D2" Claude "$OLDNAME")" == none ]] \
    && pass "the old name is gone from D2" || fail "the old name is still on D2"
[[ "$(tokens "$A" "$DEV_A1" "$D1" Claude "$NEWNAME")" == 100 ]] \
    && pass "the new name carries D1's figure" || fail "the new name is missing or wrong on D1"
[[ "$(tokens "$A" "$DEV_A1" "$D1" Claude claude-opus-5)" == 1000 ]] \
    && pass "a model sent again under its own name stays" || fail "a model sent again was lost"

echo "what it must not touch:"
[[ "$(tokens "$A" "$DEV_A1" "$D1" Codex gpt-5.5)" == 500 ]] \
    && pass "another provider on the same day (Codex) is kept" \
    || fail "another provider's row on the same day was deleted"
[[ "$(tokens "$A" "$DEV_A1" "$OLD" Claude "$OLDNAME")" == 300 ]] \
    && pass "a day not in the upload is kept" || fail "a day not in the upload was touched"
[[ "$(tokens "$A" "$DEV_A2" "$D1" Claude claude-sonnet-5)" == 70 ]] \
    && pass "another device's rows are kept" || fail "another device's row was deleted"
[[ "$(tokens "$A" "$NIL" "$D1" Claude "$OLDNAME")" == 40 ]] \
    && pass "the shared no-device rows are kept by a paired Mac's upload" \
    || fail "a paired Mac's upload deleted the no-device rows"
[[ "$(tokens "$B" "$DEV_B" "$D1" Claude "$OLDNAME")" == 999 ]] \
    && pass "another user's rows are kept" || fail "another user's row was deleted"

echo "what the iPhone reads (get_daily_usage, summed over devices):"
got="$(as_user "$A" rollback "select sum((r->>'input_tokens')::bigint) from jsonb_array_elements(public.get_daily_usage(30)) r
 where r->>'metric_date' = '$D1';")"
# A1: haiku 100 + opus 1000 + Codex 500; A2: 70; no device: 40.
[[ "$got" == 1710 ]] && pass "D1 adds up to 1710, the old name no longer counted" \
                     || fail "D1 adds up to $got, not 1710"

echo "an unpaired Mac (no p_device_id):"
replace_as "$A" "[$(row "$D1" Claude "$NEWNAME" 45)]" null >/dev/null
[[ "$(tokens "$A" "$NIL" "$D1" Claude "$OLDNAME")" == none && "$(tokens "$A" "$NIL" "$D1" Claude "$NEWNAME")" == 45 ]] \
    && pass "its rows are replaced the same way" || fail "the no-device rows were not replaced"
[[ "$(tokens "$B" "$NIL" "$D1" Claude "$OLDNAME")" == 888 ]] \
    && pass "another user's no-device rows are kept" || fail "another user's no-device row was deleted"
[[ "$(tokens "$A" "$DEV_A1" "$D1" Claude "$NEWNAME")" == 100 ]] \
    && pass "the paired Mac's rows are kept by the unpaired upload" \
    || fail "the unpaired upload touched a paired Mac's rows"

echo "refusals, and nothing deleted by them:"
if out="$(replace_as "$B" "[$(row "$D1" Claude other 1)]" "$DEV_A1" 2>&1)"; then
    fail "B wrote under A's device"
else
    [[ "$out" == *"Device not owned by caller"* ]] && pass "B is refused A's device (42501)" \
                                                   || fail "B's call failed for another reason: $out"
fi
[[ "$(tokens "$A" "$DEV_A1" "$D1" Claude claude-opus-5)" == 1000 ]] \
    && pass "and A's rows on that device are intact" || fail "a refused call deleted A's rows"
if out="$(replace_as - "[$(row "$D1" Claude other 1)]" null 2>&1)"; then
    fail "an unauthenticated call went through"
else
    [[ "$out" == *"Not authenticated"* ]] && pass "an unauthenticated call is refused" \
                                          || fail "the unauthenticated call failed for another reason: $out"
fi
if out="$(as_user "$A" commit "set local role anon; select public.replace_daily_usage('[]'::jsonb, null);" 2>&1)"; then
    fail "anon executed replace_daily_usage"
else
    [[ "$out" == *"permission denied"* ]] && pass "anon cannot call it" \
                                          || fail "anon's call failed for another reason: $out"
fi

echo "one transaction:"
BAD="[$(row "$D2" Claude claude-brand-new 7),{\"metric_date\":\"$D2\",\"provider\":\"Claude\",\"model\":null}]"
if replace_as "$A" "$BAD" "$DEV_A1" >/dev/null 2>&1; then
    fail "a row without a model was accepted"
else
    pass "a row without a model fails the call"
fi
[[ "$(tokens "$A" "$DEV_A1" "$D2" Claude claude-brand-new)" == none && "$(tokens "$A" "$DEV_A1" "$D2" Claude "$NEWNAME")" == 200 ]] \
    && pass "and leaves the day exactly as it was" || fail "a failed call changed the day"

echo "the edges of the payload:"
replace_as "$A" "[$(row "$D2" Claude "$NEWNAME" 5),$(row "$D2" Claude "$NEWNAME" 7)]" "$DEV_A1" >/dev/null
[[ "$(tokens "$A" "$DEV_A1" "$D2" Claude "$NEWNAME")" == 7 ]] \
    && pass "a model sent twice keeps the last figure, as upsert_daily_usage does" \
    || fail "a model sent twice did not keep the last figure"
result="$(replace_as "$A" "[$(row "$D2" Claude "$NEWNAME" 7)]" "$DEV_A1")"
check "sending the same set again removes nothing  ($result)" \
      "('$result'::jsonb ->> 'removed')::int = 0"
result="$(replace_as "$A" "[]" "$DEV_A1")"
check "an empty upload writes and removes nothing  ($result)" \
      "'$result'::jsonb = '{\"upserted\": 0, \"removed\": 0}'::jsonb"
check "and leaves every row of A's Mac in place" \
      "(select count(*) from public.daily_usage_metrics where device_id = '$DEV_A1') = 6"

# ── two overlapping uploads from one Mac must not end with both sets ────────
# The first holds its transaction open; the second, with a disjoint set,
# starts meanwhile. Without the per-device lock, the second's delete cannot
# see the first's uncommitted row and both sets survive.
echo "two overlapping uploads from one Mac:"
first_log="$(mktemp)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX >"$first_log" 2>&1 <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$A","role":"authenticated"}', true) \g /dev/null
set local role authenticated;
select public.replace_daily_usage('[$(row "$D3" Claude claude-x 10)]'::jsonb, '$DEV_A1'::uuid) \g /dev/null
select pg_sleep(4) \g /dev/null
commit;
SQL
first=$!
sleep 1.5
replace_as "$A" "[$(row "$D3" Claude claude-z 30)]" "$DEV_A1" >/dev/null
wait "$first" || { cat "$first_log" >&2; fail "the first overlapping upload failed"; }
rm -f "$first_log"
got="$(psql_q -c "select string_agg(model, ',' order by model) from public.daily_usage_metrics
                  where user_id = '$A' and device_id = '$DEV_A1' and metric_date = '$D3'")"
[[ "$got" == claude-z ]] && pass "the later upload holds the day whole ($got)" \
                         || fail "overlapping uploads left '$got', not claude-z"

echo
if (( fails > 0 )); then
    echo "✗ $fails check(s) failed" >&2
    exit 1
fi
echo "✓ v0.84: a device's day is replaced whole; nothing else is touched; old apps unchanged"

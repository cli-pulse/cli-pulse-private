#!/usr/bin/env bash
# Verify migrate_v0.85 (replace_daily_usage, targeted rule for the shared
# "no device" id) against a real Postgres.
#
# v0.84's replace_daily_usage makes a device's rows for each (day, provider)
# it sends exactly the set it sent. Every unpaired Mac of an account sends no
# p_device_id and shares the nil UUID, so under v0.84 one unpaired Mac's
# upload deleted the models only another unpaired Mac used. The owner's
# decision (2026-10-07): under the nil UUID, delete only a `-YYYYMMDD`
# spelling of a model sent for the same day and provider; paired devices keep
# v0.84's full replace.
#
# What this proves:
#   * two unpaired Macs with different models both keep them (and the
#     iPhone's day total stops swinging), with v0.84 alone as the control;
#   * a dated spelling of a model sent that day is removed, and nothing else
#     is: other dated names, other date forms, other days, other providers,
#     other users, paired devices;
#   * a paired device's replace is unchanged: the same workload gives the
#     same rows and the same answers under v0.84 and under v0.85;
#   * upsert_daily_usage, which apps up to 1.55 call, is unchanged: same
#     definition, same grants, and the same workload gives the same rows
#     before v0.84, after it, and after v0.85;
#   * v0.85 refuses to run without v0.84, and applies twice cleanly.
#
# The database is built the way production got there: the shim, schema.sql
# (the pre-v0.37 baseline), v0.37, v0.81's grants on the upsert, then v0.84,
# then v0.85.
#
# Every check runs even after one fails, and each prints its own label, so a
# branch carrying several deliberate mutations shows one FAIL per mutation.
#
# Usage:
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/v085 \
#     ./backend/supabase/tests/run_v085_replace_daily_usage_unpaired_tests.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/rls/00_supabase_shim.sql"
SCHEMA="$HERE/../schema.sql"
V037="$HERE/../migrate_v0.37_daily_usage_device_id.sql"
V084="$HERE/../migrate_v0.84_replace_daily_usage.sql"
V085="$HERE/../migrate_v0.85_replace_daily_usage_unpaired_dated_only.sql"

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to an empty disposable database" >&2
    exit 2
fi
for f in "$SHIM" "$SCHEMA" "$V037" "$V084" "$V085"; do
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
same() { # same <label> <a> <b>
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"; diff <(echo "$2" | tr ' ' '\n') <(echo "$3" | tr ' ' '\n') >&2 || true; fi
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

# row <date> <provider> <model> <input tokens>: one metrics element
row() { echo "{\"metric_date\":\"$1\",\"provider\":\"$2\",\"model\":\"$3\",\"input_tokens\":$4,\"cost\":0.01}"; }

tokens() { # tokens <user> <device> <date> <provider> <model>: input_tokens or 'none'
    psql_q -c "select coalesce((select input_tokens::text from public.daily_usage_metrics
                 where user_id='$1' and device_id='$2' and metric_date='$3'
                   and provider='$4' and model='$5'), 'none')"
}

# Every row of the table, without updated_at, in one line. Run as the
# superuser (after `reset role` inside a user's transaction).
SNAP="select coalesce(string_agg(format('%s/%s/%s/%s/%s=%s,%s,%s,%s', user_id, device_id, metric_date,
        provider, model, input_tokens, cached_tokens, output_tokens, cost), ' '
        order by user_id, device_id, metric_date, provider, model), '') from public.daily_usage_metrics;"

# A's day total as the iPhone reads it (get_daily_usage sums every device).
day_total_sql() {
    echo "select coalesce(sum((r->>'input_tokens')::bigint), 0)
            from jsonb_array_elements(public.get_daily_usage(30)) r where r->>'metric_date' = '$1';"
}

D1="$(psql_q -c "select (current_date - 2)::text")"
D2="$(psql_q -c "select (current_date - 1)::text")"
D3="$(psql_q -c "select (current_date - 3)::text")"
D4="$(psql_q -c "select (current_date - 4)::text")"
OLD="$(psql_q -c "select (current_date - 60)::text")"  # no longer uploaded
OLDNAME=claude-haiku-4-5-20251001   # what an app before the rename stored
NEWNAME=claude-haiku-4-5            # what 1.56 sends for the same model

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

insert into public.daily_usage_metrics
  (user_id, device_id, metric_date, provider, model, input_tokens, updated_at) values
  -- A's paired Mac, before the rename (plus one model it will stop sending)
  ('$A', '$DEV_A1', '$D1',  'Claude', '$OLDNAME',                    100, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$D1',  'Claude', 'claude-opus-5',              1000, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$D1',  'Claude', 'claude-sonnet-x',               5, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$D1',  'Codex',  'gpt-5.5',                     500, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$D2',  'Claude', '$OLDNAME',                    200, now() - interval '1 day'),
  ('$A', '$DEV_A1', '$OLD', 'Claude', '$OLDNAME',                    300, now() - interval '60 days'),
  ('$A', '$DEV_A1', '$D3',  'Claude', 'claude-y',                      1, now() - interval '1 day'),
  ('$A', '$DEV_A2', '$D1',  'Claude', 'claude-sonnet-5',              70, now() - interval '1 day'),
  -- A's unpaired Macs, all under the nil UUID. Mac X before its rename:
  ('$A', '$NIL',    '$D1',  'Claude', '$OLDNAME',                     40, now() - interval '1 day'),
  -- ... and Mac Y, which uses other models:
  ('$A', '$NIL',    '$D1',  'Claude', 'claude-sonnet-5',              70, now() - interval '1 day'),
  ('$A', '$NIL',    '$D1',  'Claude', 'claude-sonnet-4-5-20250929',   12, now() - interval '1 day'),
  ('$A', '$NIL',    '$D1',  'Codex',  'gpt-5.5',                      13, now() - interval '1 day'),
  -- names close to a dated spelling of what X sends, which are not one:
  ('$A', '$NIL',    '$D1',  'Claude', 'claude-opus-5-2025100',        15, now() - interval '1 day'),
  ('$A', '$NIL',    '$D1',  'Claude', 'claude-opus-5-2025-10-01',     16, now() - interval '1 day'),
  ('$A', '$NIL',    '$D1',  'Codex',  'gpt-5-2025-08-07',             17, now() - interval '1 day'),
  ('$A', '$NIL',    '$D1',  'Claude', 'claude-opus-5-202510011',      19, now() - interval '1 day'),
  ('$A', '$NIL',    '$D1',  'Claude', 'claude-opus-20251001-5',       21, now() - interval '1 day'),
  -- a dated spelling of what X sends: under another provider X also sends
  -- that day (its base only under Claude), on another day of the upload
  -- that lacks the base, and on a day the upload does not carry:
  ('$A', '$NIL',    '$D1',  'Cursor', '$OLDNAME',                     18, now() - interval '1 day'),
  ('$A', '$NIL',    '$D3',  'Claude', '$OLDNAME',                     14, now() - interval '1 day'),
  ('$A', '$NIL',    '$OLD', 'Claude', '$OLDNAME',                    300, now() - interval '60 days'),
  -- another user
  ('$B', '$DEV_B',  '$D1',  'Claude', '$OLDNAME',                    999, now() - interval '1 day'),
  ('$B', '$NIL',    '$D1',  'Claude', '$OLDNAME',                    888, now() - interval '1 day');
SQL

# Mac X (unpaired, 1.56): the renamed haiku and opus on D1, a Codex model and
# a Cursor model on D1, opus on D3. Mac Y (unpaired): its own models on D1.
X_UPLOAD="[$(row "$D1" Claude "$NEWNAME" 45),$(row "$D1" Claude claude-opus-5 20),$(row "$D1" Codex gpt-5 3),$(row "$D1" Cursor auto 2),$(row "$D3" Claude claude-opus-5 5)]"
Y_UPLOAD="[$(row "$D1" Claude claude-sonnet-5 71),$(row "$D1" Claude claude-sonnet-4-5-20250929 12),$(row "$D1" Codex gpt-5.5 13)]"

# The paired workload, compared between v0.84 and v0.85. Rolled back.
PAIRED_WORK="
select public.replace_daily_usage('[$(row "$D1" Claude "$NEWNAME" 100),$(row "$D1" Claude claude-opus-5 1000),$(row "$D2" Claude "$NEWNAME" 200)]'::jsonb, '$DEV_A1'::uuid);
select public.replace_daily_usage('[$(row "$D4" Claude claude-q 1),$(row "$D1" Claude "$NEWNAME" 100),$(row "$D1" Claude claude-opus-5 1000)]'::jsonb, '$DEV_A1'::uuid);
select public.replace_daily_usage('[]'::jsonb, '$DEV_A1'::uuid);
select public.replace_daily_usage('[$(row "$D2" Claude "$NEWNAME" 5),$(row "$D2" Claude "$NEWNAME" 7)]'::jsonb, '$DEV_A1'::uuid);
select public.replace_daily_usage('[$(row "$D1" Codex gpt-5.6-sol 9)]'::jsonb, '$DEV_A2'::uuid);
reset role;
$SNAP"

# What an app up to 1.55 does, compared before v0.84, after it and after
# v0.85. Rolled back.
UPSERT_WORK="
select public.upsert_daily_usage('[$(row "$D1" Claude "$NEWNAME" 100),$(row "$D1" Claude claude-opus-5 1000),$(row "$D2" Claude "$NEWNAME" 200)]'::jsonb, '$DEV_A1'::uuid);
select public.upsert_daily_usage('$X_UPLOAD'::jsonb, null);
select public.upsert_daily_usage('[]'::jsonb, null);
reset role;
$SNAP"

UPSERT_DEF="select md5(pg_get_functiondef('public.upsert_daily_usage(jsonb,uuid)'::regprocedure))
             || '/' || has_function_privilege('anon', 'public.upsert_daily_usage(jsonb,uuid)', 'EXECUTE')
             || '/' || has_function_privilege('authenticated', 'public.upsert_daily_usage(jsonb,uuid)', 'EXECUTE');"

# ── before v0.84 ───────────────────────────────────────────────────────────
echo "before v0.84:"
upsert_def_0="$(psql_q -c "$UPSERT_DEF")"
upsert_work_0="$(as_user "$A" rollback "$UPSERT_WORK")"
if out="$(psql_q -f "$V085" 2>&1)"; then
    fail "v0.85 applied without v0.84"
else
    [[ "$out" == *"apply v0.84 first"* ]] && pass "v0.85 refuses to run without v0.84" \
                                          || fail "v0.85 failed without v0.84, but not on its precondition: $out"
fi
check "and created nothing" "to_regprocedure('public.replace_daily_usage(jsonb,uuid)') is null"

# ── v0.84 alone: the controls ──────────────────────────────────────────────
echo "applying $(basename "$V084") ..."
psql_q -f "$V084" >/dev/null
HAS_RULE="select p.prosrc like '%v0.85 targeted rule%' from pg_proc p where p.proname = 'replace_daily_usage'"
[[ "$(psql_q -c "$HAS_RULE")" == f ]] && pass "[preflight] the header's has_rule query reads false on v0.84" \
                                      || fail "[preflight] the header's has_rule query is not false on v0.84"
paired_work_084="$(as_user "$A" rollback "$PAIRED_WORK")"
upsert_work_084="$(as_user "$A" rollback "$UPSERT_WORK")"
got="$(as_user "$A" rollback "select public.replace_daily_usage('$X_UPLOAD'::jsonb, null) \g /dev/null
reset role;
select coalesce((select input_tokens::text from public.daily_usage_metrics
                  where user_id = '$A' and device_id = '$NIL' and metric_date = '$D1'
                    and provider = 'Claude' and model = 'claude-sonnet-5'), 'none');")"
if [[ "$got" == none ]]; then
    pass "[control] under v0.84 one unpaired Mac's upload deletes another's model"
else
    fail "[control] under v0.84 the other unpaired Mac's model survived (got '$got'): this suite would prove nothing"
fi

# ── v0.85 ──────────────────────────────────────────────────────────────────
echo "applying $(basename "$V085") ..."
psql_q -f "$V085" >/dev/null
psql_q -f "$V085" >/dev/null
echo "  re-applied cleanly (idempotent)"

echo "the function:"
check "one replace_daily_usage, no second overload" \
      "(select count(*) from pg_proc where proname = 'replace_daily_usage') = 1"
check "[preflight] the header's has_rule query reads true" "($HAS_RULE)"
check "anon cannot execute replace_daily_usage" \
      "not has_function_privilege('anon', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE')"
check "authenticated and service_role can" \
      "has_function_privilege('authenticated', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE')
       and has_function_privilege('service_role', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE')"
check "SECURITY DEFINER with a pinned search_path" \
      "exists (select 1 from pg_proc where proname = 'replace_daily_usage' and prosecdef
                 and proconfig::text like '%search_path=pg_catalog, public, extensions%')"

echo "apps up to 1.55 (upsert_daily_usage) are unchanged:"
same "its definition and grants are the same as before v0.84" "$upsert_def_0" "$(psql_q -c "$UPSERT_DEF")"
upsert_work_085="$(as_user "$A" rollback "$UPSERT_WORK")"
same "the same calls leave the same rows as before v0.84" "$upsert_work_0" "$upsert_work_085"
same "and as under v0.84" "$upsert_work_084" "$upsert_work_085"

echo "a paired Mac's replace is unchanged:"
paired_work_085="$(as_user "$A" rollback "$PAIRED_WORK")"
same "the same paired calls give the same answers and rows as under v0.84" "$paired_work_084" "$paired_work_085"
got="$(as_user "$A" rollback "select public.replace_daily_usage('[$(row "$D1" Claude "$NEWNAME" 100),$(row "$D1" Claude claude-opus-5 1000)]'::jsonb, '$DEV_A1'::uuid);")"
check "it still removes every model it did not send, dated or not  ($got)" \
      "'$got'::jsonb = '{\"upserted\": 2, \"removed\": 2}'::jsonb"

# ── the unpaired Macs, committed from here on ──────────────────────────────
echo "Mac X (unpaired) uploads the renamed model:"
result="$(replace_as "$A" "$X_UPLOAD" null)"
check "it reports 5 written and 1 removed  ($result)" \
      "'$result'::jsonb = '{\"upserted\": 5, \"removed\": 1}'::jsonb"
[[ "$(tokens "$A" "$NIL" "$D1" Claude "$OLDNAME")" == none ]] \
    && pass "the dated spelling of a model it sent is gone from that day" \
    || fail "the dated spelling of a sent model is still there"
[[ "$(tokens "$A" "$NIL" "$D1" Claude "$NEWNAME")" == 45 ]] \
    && pass "the new name carries the figure" || fail "the new name is missing or wrong"

echo "what X's upload must not touch:"
[[ "$(tokens "$A" "$NIL" "$D1" Claude claude-sonnet-5)" == 70 ]] \
    && pass "Mac Y's model on the same day and provider is kept" || fail "Mac Y's model was deleted"
[[ "$(tokens "$A" "$NIL" "$D1" Codex gpt-5.5)" == 13 ]] \
    && pass "Mac Y's model of another provider X sent that day is kept" || fail "Mac Y's Codex model was deleted"
[[ "$(tokens "$A" "$NIL" "$D1" Claude claude-sonnet-4-5-20250929)" == 12 ]] \
    && pass "a dated name whose base X did not send is kept" || fail "a dated name whose base was not sent was deleted"
[[ "$(tokens "$A" "$NIL" "$D1" Claude claude-opus-5-2025100)" == 15 ]] \
    && pass "a 7-digit suffix is not a date: kept" || fail "a 7-digit suffix was taken for a date"
[[ "$(tokens "$A" "$NIL" "$D1" Claude claude-opus-5-202510011)" == 19 ]] \
    && pass "a 9-digit suffix is not the rule's form: kept" || fail "a 9-digit suffix was taken for a date"
[[ "$(tokens "$A" "$NIL" "$D1" Claude claude-opus-20251001-5)" == 21 ]] \
    && pass "8 digits that do not end the name are not a suffix: kept" \
    || fail "8 digits in the middle of a name were taken for a date suffix"
[[ "$(tokens "$A" "$NIL" "$D1" Claude claude-opus-5-2025-10-01)" == 16 ]] \
    && pass "a -YYYY-MM-DD suffix is not the rule's form: kept" || fail "a -YYYY-MM-DD spelling was deleted"
[[ "$(tokens "$A" "$NIL" "$D1" Codex gpt-5-2025-08-07)" == 17 ]] \
    && pass "a dated Codex spelling of a sent Codex model is kept" || fail "a dated Codex spelling was deleted"
[[ "$(tokens "$A" "$NIL" "$D1" Cursor "$OLDNAME")" == 18 ]] \
    && pass "its dated spelling under another provider X sent that day is kept" \
    || fail "a dated row was deleted because its base was sent under another provider"
[[ "$(tokens "$A" "$NIL" "$D3" Claude "$OLDNAME")" == 14 ]] \
    && pass "the dated spelling on an uploaded day without its base is kept" \
    || fail "a dated row was deleted on a day its base was not sent"
[[ "$(tokens "$A" "$NIL" "$OLD" Claude "$OLDNAME")" == 300 ]] \
    && pass "a day not in the upload is kept" || fail "a day not in the upload was touched"
[[ "$(tokens "$B" "$NIL" "$D1" Claude "$OLDNAME")" == 888 ]] \
    && pass "another user's no-device rows are kept" || fail "another user's no-device row was deleted"
[[ "$(tokens "$A" "$DEV_A1" "$D1" Claude "$OLDNAME")" == 100 && "$(tokens "$A" "$DEV_A1" "$D1" Claude claude-sonnet-x)" == 5 ]] \
    && pass "a paired Mac's rows are kept by the unpaired upload" || fail "the unpaired upload touched a paired Mac's rows"

echo "two unpaired Macs with different models:"
result="$(replace_as "$A" "$Y_UPLOAD" null)"
check "Mac Y's upload removes nothing  ($result)" "('$result'::jsonb ->> 'removed')::int = 0"
[[ "$(tokens "$A" "$NIL" "$D1" Claude "$NEWNAME")" == 45 && "$(tokens "$A" "$NIL" "$D1" Codex gpt-5)" == 3 ]] \
    && pass "Mac X's models stay after Mac Y's upload" || fail "Mac Y's upload deleted Mac X's models"
after_y="$(as_user "$A" rollback "$(day_total_sql "$D1")")"
result="$(replace_as "$A" "$X_UPLOAD" null)"
check "Mac X's next upload removes nothing  ($result)" "('$result'::jsonb ->> 'removed')::int = 0"
[[ "$(tokens "$A" "$NIL" "$D1" Claude claude-sonnet-5)" == 71 ]] \
    && pass "Mac Y's models stay after Mac X's next upload" || fail "Mac X's upload deleted Mac Y's models"
after_x="$(as_user "$A" rollback "$(day_total_sql "$D1")")"
# Paired A1: 100 + 1000 + 5 + 500; A2: 70; no device: haiku 45, opus 20,
# sonnet-5 71, sonnet-4-5 dated 12, 15, 16, gpt-5.5 13, gpt-5 3, 17, 19, 21,
# Cursor 18 + 2.
[[ "$after_y" == 1947 && "$after_x" == 1947 ]] \
    && pass "the iPhone's day total holds at 1947 whichever Mac uploaded last" \
    || fail "the iPhone's day total moved: $after_y after Y, $after_x after X (want 1947)"

echo "a dated spelling the app writes and later renames:"
result="$(replace_as "$A" "[$(row "$D2" Claude claude-z 1),$(row "$D2" Claude claude-z-20250101 2)]" null)"
check "both spellings in one upload are kept  ($result)" \
      "'$result'::jsonb = '{\"upserted\": 2, \"removed\": 0}'::jsonb"
result="$(replace_as "$A" "[$(row "$D2" Claude claude-z 3)]" null)"
check "the next upload without the dated one removes it  ($result)" \
      "'$result'::jsonb = '{\"upserted\": 1, \"removed\": 1}'::jsonb"
[[ "$(tokens "$A" "$NIL" "$D2" Claude claude-z-20250101)" == none && "$(tokens "$A" "$NIL" "$D2" Claude claude-z)" == 3 ]] \
    && pass "only the base name is left on that day" || fail "the dated spelling was not removed"

echo "refusals, and nothing deleted by them:"
if out="$(replace_as "$A" "[$(row "$D1" Claude "$NEWNAME" 1)]" "$NIL" 2>&1)"; then
    fail "an explicit nil UUID as p_device_id was accepted"
else
    [[ "$out" == *"Device not owned by caller"* ]] && pass "an explicit nil UUID as p_device_id is refused (42501)" \
                                                   || fail "the explicit nil UUID failed for another reason: $out"
fi
result="$(replace_as "$A" "[]" null)"
check "an empty unpaired upload writes and removes nothing  ($result)" \
      "'$result'::jsonb = '{\"upserted\": 0, \"removed\": 0}'::jsonb"
BAD="[$(row "$D1" Claude claude-sonnet-5 99),{\"metric_date\":\"$D1\",\"provider\":\"Claude\",\"model\":null}]"
if out="$(replace_as "$A" "$BAD" null 2>&1)"; then
    fail "a row without a model was accepted"
else
    [[ "$out" == *"not-null constraint"* ]] && pass "a row without a model fails the unpaired call" \
                                            || fail "the row without a model failed for another reason: $out"
fi
[[ "$(tokens "$A" "$NIL" "$D1" Claude claude-sonnet-5)" == 71 && "$(tokens "$A" "$NIL" "$D1" Claude "$NEWNAME")" == 45 ]] \
    && pass "and leaves the day exactly as it was" || fail "a failed unpaired call changed the day"
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

echo "a paired Mac's committed replace, after the unpaired uploads:"
result="$(replace_as "$A" "[$(row "$D1" Claude "$NEWNAME" 100),$(row "$D1" Claude claude-opus-5 1000),$(row "$D2" Claude "$NEWNAME" 200)]" "$DEV_A1")"
check "it reports 3 written and 3 removed  ($result)" \
      "'$result'::jsonb = '{\"upserted\": 3, \"removed\": 3}'::jsonb"
[[ "$(tokens "$A" "$DEV_A1" "$D1" Claude claude-sonnet-x)" == none && "$(tokens "$A" "$DEV_A1" "$D1" Claude "$OLDNAME")" == none ]] \
    && pass "its models not sent are gone, dated or not (full replace)" || fail "the paired replace kept a model it did not send"
[[ "$(tokens "$A" "$DEV_A1" "$D1" Codex gpt-5.5)" == 500 && "$(tokens "$A" "$DEV_A2" "$D1" Claude claude-sonnet-5)" == 70 ]] \
    && pass "another provider and another device are kept" || fail "the paired replace touched another provider or device"
[[ "$(tokens "$A" "$NIL" "$D1" Claude claude-sonnet-5)" == 71 && "$(tokens "$B" "$DEV_B" "$D1" Claude "$OLDNAME")" == 999 ]] \
    && pass "the no-device rows and another user's rows are kept" || fail "the paired replace touched no-device or foreign rows"

# ── overlapping uploads ────────────────────────────────────────────────────
# overlap <device|null> <first model> <second model>: the first upload holds
# its transaction open; the second starts meanwhile.
overlap() {
    local dev="null" first_log first
    [[ "$1" != "null" ]] && dev="'$1'::uuid"
    first_log="$(mktemp)"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX >"$first_log" 2>&1 <<SQL &
begin;
select set_config('request.jwt.claims', '{"sub":"$A","role":"authenticated"}', true) \g /dev/null
set local role authenticated;
select public.replace_daily_usage('[$(row "$D3" Claude "$2" 10)]'::jsonb, $dev) \g /dev/null
select pg_sleep(6) \g /dev/null
commit;
SQL
    first=$!
    # Start the second only once the first holds an advisory lock with a
    # bigint key (objsubid 1) in this database: the per-device lock.
    local waited=0
    until [[ "$(psql_q -c "select count(*) from pg_locks
                            where locktype = 'advisory' and granted and objsubid = 1
                              and database = (select oid from pg_database where datname = current_database())")" -gt 0 ]]; do
        (( waited++ < 100 )) || { fail "the first overlapping upload never took the lock"; break; }
        sleep 0.1
    done
    replace_as "$A" "[$(row "$D3" Claude "$3" 30)]" "$1" >/dev/null
    wait "$first" || { cat "$first_log" >&2; fail "the first overlapping upload failed"; }
    rm -f "$first_log"
}
echo "two overlapping uploads (the paired case is the one that needs the lock):"
overlap "$DEV_A1" claude-x claude-z
got="$(psql_q -c "select string_agg(model, ',' order by model collate \"C\") from public.daily_usage_metrics
                  where user_id = '$A' and device_id = '$DEV_A1' and metric_date = '$D3'")"
[[ "$got" == claude-z ]] && pass "from one paired Mac: the later upload holds the day whole ($got)" \
                         || fail "overlapping paired uploads left '$got', not claude-z"
overlap null claude-x claude-w
got="$(psql_q -c "select string_agg(model, ',' order by model collate \"C\") from public.daily_usage_metrics
                  where user_id = '$A' and device_id = '$NIL' and metric_date = '$D3'")"
want="$OLDNAME,claude-opus-5,claude-w,claude-x"
[[ "$got" == "$want" ]] && pass "from two unpaired Macs: both models stay ($got)" \
                        || fail "overlapping unpaired uploads left '$got', not '$want'"

echo
if (( fails > 0 )); then
    echo "✗ $fails check(s) failed" >&2
    exit 1
fi
echo "✓ v0.85: unpaired uploads remove only a dated spelling of a model sent; paired replace and old apps unchanged"

#!/usr/bin/env bash
# Verify migrate_v0.86 (the summary RPCs count each token once) against a real
# Postgres, on both install paths.
#
# dashboard_summary, provider_summary and provider_account_summary added
# input + cached + output for every provider. Codex's input already includes
# its cached input (OpenAI's convention), so every Codex figure counted the
# cache twice. v0.86 counts each token once, by the Mac's rule
# (ArchiveTokenBasis): Codex input + output, every other provider input +
# cached + output, each row clamped at 0.
#
# What this proves:
#   * the figures are the fixture's (fixtures/summary_tokens_each_once.json,
#     the file the Mac's code is asserted against too), from all three RPCs,
#     with the old figures reproduced first as the control;
#   * nothing else in the answers moves: the same keys, the same costs,
#     windows, quota and account fields, session/device/alert counts;
#   * the contract apps up to 1.57 rely on holds: one overload each, the same
#     arguments and return type, the same grants (anon cannot call them),
#     SECURITY DEFINER with a pinned search_path, a call without
#     p_user_today still answers, an unauthenticated one is refused;
#   * v0.86 refuses to run without the functions it replaces, applies twice
#     cleanly, and rollback_v0.86.sql puts the exact pre-v0.86 bodies back;
#   * a fresh install (schema.sql + app_rpc.sql + helper_rpc.sql) installs the
#     same bodies and gives the same figures.
#
# The upgrade database is built from the canonical files, then the summary
# functions are put back the way production has run them before v0.86:
# v0.44 (dashboard_summary, provider_summary) and v0.72
# (provider_account_summary), the newest migrations that defined them.
#
# Every check runs even after one fails, and each prints its own label, so a
# branch carrying several deliberate mutations shows one FAIL per mutation.
#
# Usage:
#   UPGRADE_DATABASE_URL=postgres://postgres:postgres@localhost:5432/v086_upgrade \
#   FRESH_DATABASE_URL=postgres://postgres:postgres@localhost:5432/v086_fresh \
#     ./backend/supabase/tests/run_v086_summary_tokens_each_once_tests.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$HERE/.."
SHIM="$HERE/rls/00_supabase_shim.sql"
FIXTURE="$HERE/fixtures/summary_tokens_each_once.json"
V044="$SQL_DIR/migrate_v0.44_user_tz_today.sql"
V072="$SQL_DIR/migrate_v0.72_provider_accounts.sql"
V086="$SQL_DIR/migrate_v0.86_summary_tokens_each_once.sql"
ROLLBACK="$SQL_DIR/rollback_v0.86.sql"

for v in UPGRADE_DATABASE_URL FRESH_DATABASE_URL; do
    if [[ -z "${!v:-}" ]]; then
        echo "$v must point to an empty disposable database" >&2
        exit 2
    fi
done
if [[ "$UPGRADE_DATABASE_URL" == "$FRESH_DATABASE_URL" ]]; then
    echo "the upgrade and fresh paths need two different databases" >&2
    exit 2
fi
for f in "$SHIM" "$FIXTURE" "$V044" "$V072" "$V086" "$ROLLBACK" \
         "$SQL_DIR/schema.sql" "$SQL_DIR/app_rpc.sql" "$SQL_DIR/helper_rpc.sql"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done

DB=""   # the database the helpers below talk to
# The replayed files say a lot of "already exists, skipping"; only warnings
# and errors are worth a line in the log.
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
psql_q() { psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX "$@"; }
apply() { psql_q -f "$1" >/dev/null; }

fails=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }
check() { # check <label> <sql returning boolean>, as the superuser
    local label="$1" sql="$2" got
    got="$(psql_q -c "select ($sql)::text")"
    if [[ "$got" == "true" ]]; then pass "$label"; else fail "$label  (got '$got')"; fi
}
same() { # same <label> <want> <got>
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"; echo "      want: $2" >&2; echo "      got:  $3" >&2; fi
}

# as_user <uuid|-> <sql>: run <sql> the way PostgREST runs a call, as
# `authenticated` with the JWT's sub, and roll it back. `-` sends no sub.
as_user() {
    local claims='{}'
    [[ "$1" != "-" ]] && claims="{\"sub\":\"$1\",\"role\":\"authenticated\"}"
    psql_q <<SQL
begin;
select set_config('request.jwt.claims', '$claims', true) \g /dev/null
set local role authenticated;
$2
rollback;
SQL
}

FUNCS="'dashboard_summary', 'provider_summary', 'provider_account_summary'"

# One line per function: name, arguments, result, SECURITY DEFINER, config,
# grants. Everything the apps' calls depend on except the body.
CONTRACT="select string_agg(format('%s(%s) -> %s secdef=%s config=%s acl=%s',
                   p.proname, pg_get_function_arguments(p.oid), pg_get_function_result(p.oid),
                   p.prosecdef, p.proconfig, p.proacl), E'\n' order by p.proname)
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ($FUNCS);"
BODIES="select string_agg(p.proname || '=' || md5(p.prosrc), ' ' order by p.proname)
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname in ($FUNCS);"
RULE="select coalesce(bool_and(p.prosrc like '%v0.86 each token once%'), false)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in ($FUNCS)"   # no ';': check() wraps it

load_fixture() {
    psql_q -v fixture="$(cat "$FIXTURE")" >/dev/null <<'SQL'
create schema v086_test;
create table v086_test.fixture (doc jsonb not null);
insert into v086_test.fixture values (:'fixture'::jsonb);
insert into auth.users (id, email)
select (doc->>'user')::uuid, 'a@test.local' from v086_test.fixture
union all
select (doc->>'other_user')::uuid, 'b@test.local' from v086_test.fixture;
insert into public.daily_usage_metrics
  (user_id, metric_date, provider, model, input_tokens, cached_tokens, output_tokens, cost)
select (f.doc->>(r->>'user'))::uuid, (r->>'metric_date')::date, r->>'provider', r->>'model',
       (r->>'input_tokens')::bigint, (r->>'cached_tokens')::bigint,
       (r->>'output_tokens')::bigint, (r->>'cost')::numeric
  from v086_test.fixture f, jsonb_array_elements(f.doc->'rows') r;
-- Quota rows and accounts, so the fields that must not move are not all null:
-- one for a provider with usage, one for a provider without.
insert into public.provider_quotas (user_id, provider, remaining, quota, plan_type, tiers)
select (doc->>'user')::uuid, 'Codex', 8, 100, 'Pro', '[{"name":"Weekly","quota":100,"remaining":8}]'::jsonb
  from v086_test.fixture
union all
select (doc->>'user')::uuid, 'Copilot', 40, 100, 'Pro', '[]'::jsonb from v086_test.fixture;
insert into public.provider_accounts (user_id, id, provider, display_label, plan_type)
select (doc->>'user')::uuid, '86000000-8600-4860-8860-0000000000c1'::uuid, 'Claude', 'Account 1', 'Max'
  from v086_test.fixture
union all
select (doc->>'user')::uuid, '86000000-8600-4860-8860-0000000000c2'::uuid, 'Copilot', 'Account 2', null
  from v086_test.fixture;
insert into public.provider_account_quotas
  (user_id, provider_account_id, provider, remaining, quota, tiers, observed_at)
select (doc->>'user')::uuid, '86000000-8600-4860-8860-0000000000c1', 'Claude', 47, 100,
       '[{"name":"5h Window","quota":100,"remaining":47}]'::jsonb, '2026-07-24T05:00:00Z'
  from v086_test.fixture;
SQL
    USER_ID="$(psql_q -c "select doc->>'user' from v086_test.fixture")"
    TODAY="$(psql_q -c "select doc->>'today' from v086_test.fixture")"
}

# The fixture's expected tokens per provider, "Provider=today/week ...".
expected() { # expected <after|before>
    local pick="value"
    [[ "$1" == before ]] && pick="value->'before_v086'"
    psql_q -c "select string_agg(format('%s=%s/%s', key, $pick->>'today_usage', $pick->>'total_usage'),
                                 ' ' order by key collate \"C\")
                 from v086_test.fixture, jsonb_each(doc->'expected')"
}
expected_dashboard() { # expected_dashboard <after|before>
    local key=expected_dashboard_today_usage
    [[ "$1" == before ]] && key=expected_dashboard_today_usage_before_v086
    psql_q -c "select doc->>'$key' from v086_test.fixture"
}

# What an RPC answers for the fixture's user and today, as the app reads it:
# the providers with tokens (Copilot, a quota and an account without usage,
# is checked on its own).
tokens_of() { # tokens_of <provider_summary|provider_account_summary>
    as_user "$USER_ID" "select string_agg(format('%s=%s/%s', r->>'provider', r->>'today_usage', r->>'total_usage'),
                                          ' ' order by r->>'provider' collate \"C\")
                          from jsonb_array_elements(public.$1('$TODAY'::date)) r
                         where r->>'provider' <> 'Copilot';"
}
copilot_of() { # copilot_of <provider_summary|provider_account_summary>
    as_user "$USER_ID" "select format('%s/%s', r->>'today_usage', r->>'total_usage')
                          from jsonb_array_elements(public.$1('$TODAY'::date)) r
                         where r->>'provider' = 'Copilot';"
}
dashboard_tokens() {
    as_user "$USER_ID" "select public.dashboard_summary('$TODAY'::date)->>'today_usage';"
}
# Every other field of every answer, and the keys and JSON types of the token
# fields: what must not move.
rest_of() { # rest_of <provider_summary|provider_account_summary>
    as_user "$USER_ID" "select jsonb_agg(r - 'today_usage' - 'total_usage'
                                          || jsonb_build_object('types', jsonb_typeof(r->'today_usage') || '/' || jsonb_typeof(r->'total_usage'),
                                                                'keys', (select string_agg(k, ',' order by k) from jsonb_object_keys(r) k))
                                          order by r->>'provider' collate \"C\")
                          from jsonb_array_elements(public.$1('$TODAY'::date)) r;"
}
dashboard_rest() {
    as_user "$USER_ID" "select (public.dashboard_summary('$TODAY'::date) - 'today_usage')::text
                        || ' keys=' || (select string_agg(k, ',' order by k) from jsonb_object_keys(public.dashboard_summary('$TODAY'::date)) k);"
}

# The figures, all three RPCs, against the fixture.
check_figures() { # check_figures <label> <after|before>
    local want; want="$(expected "$2")"
    same "[$1] provider_summary: $(tokens_of provider_summary)" "$want" "$(tokens_of provider_summary)"
    same "[$1] provider_account_summary gives the same" "$want" "$(tokens_of provider_account_summary)"
    same "[$1] dashboard_summary today_usage: $(dashboard_tokens)" "$(expected_dashboard "$2")" "$(dashboard_tokens)"
    same "[$1] a provider with a quota or an account and no usage reads 0/0 in both" \
         "0/0 0/0" "$(copilot_of provider_summary) $(copilot_of provider_account_summary)"
}

check_contract_calls() { # what every app's call relies on
    local label="$1"
    check "[$label] one overload of each, all taking (p_user_today date default null)" \
          "(select count(*) = 3 and bool_and(pg_get_function_arguments(p.oid) = 'p_user_today date DEFAULT NULL::date'
                                            and pg_get_function_result(p.oid) = 'jsonb')
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname in ($FUNCS))"
    check "[$label] SECURITY DEFINER with a pinned search_path" \
          "(select bool_and(p.prosecdef and p.proconfig::text like '%search_path=pg_catalog, public, extensions%')
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname in ($FUNCS))"
    for f in dashboard_summary provider_summary provider_account_summary; do
        check "[$label] anon cannot execute $f, authenticated can" \
              "not has_function_privilege('anon', 'public.$f(date)', 'EXECUTE')
               and has_function_privilege('authenticated', 'public.$f(date)', 'EXECUTE')"
        local got
        got="$(as_user "$USER_ID" "select jsonb_typeof(public.$f());")"
        [[ "$got" == array || "$got" == object ]] \
            && pass "[$label] $f() without p_user_today still answers (as the desktop app calls it)" \
            || fail "[$label] $f() without p_user_today: '$got'"
        if out="$(as_user - "select public.$f('$TODAY'::date);" 2>&1)"; then
            fail "[$label] $f answered a call without a user"
        else
            [[ "$out" == *"Not authenticated"* ]] && pass "[$label] $f refuses a call without a user" \
                                                 || fail "[$label] $f failed without a user for another reason: $out"
        fi
    done
    for f in provider_summary provider_account_summary; do
        local sorted
        sorted="$(as_user "$USER_ID" "select coalesce(bool_and(a >= b), true) from (
                    select (r->>'total_usage')::numeric a,
                           lead((r->>'total_usage')::numeric) over (order by ord) b
                      from jsonb_array_elements(public.$f('$TODAY'::date)) with ordinality t(r, ord)) s
                   where b is not null;")"
        [[ "$sorted" == t ]] && pass "[$label] $f's rows are still sorted by the 7-day tokens" \
                             || fail "[$label] $f's rows are not sorted by the 7-day tokens"
    done
}

# ════════════════════════════════════════════════════════════════════════════
echo "== upgrade path: production's definitions, then v0.86 =="
DB="$UPGRADE_DATABASE_URL"
apply "$SHIM"
apply "$SQL_DIR/schema.sql"
apply "$SQL_DIR/app_rpc.sql"
apply "$SQL_DIR/helper_rpc.sql"

echo "v0.86 without the function it replaces:"
psql_q -c "drop function public.provider_account_summary(date);"
before_refusal="$(psql_q -c "$BODIES")"
if out="$(psql_q -f "$V086" 2>&1)"; then
    fail "v0.86 applied without provider_account_summary"
else
    [[ "$out" == *"apply v0.72 first"* ]] && pass "v0.86 refuses to run without v0.72's function" \
                                          || fail "v0.86 failed without v0.72's function, but not on its precondition: $out"
fi
same "and replaced nothing" "$before_refusal" "$(psql_q -c "$BODIES")"
check "and created nothing" "to_regprocedure('public.provider_account_summary(date)') is null"

echo "putting back the definitions production runs (v0.44, v0.72) ..."
apply "$V044"
apply "$V072"
apply "$V072"   # twice, as its own suite does: it is written to be re-run
check "[preflight] the header's rule query reads false before v0.86" "not ($RULE)"
load_fixture
contract_before="$(psql_q -c "$CONTRACT")"
bodies_before="$(psql_q -c "$BODIES")"
rest_ps_before="$(rest_of provider_summary)"
rest_pas_before="$(rest_of provider_account_summary)"
rest_dash_before="$(dashboard_rest)"

echo "before v0.86 (the control):"
check_figures "control" before
[[ "$(tokens_of provider_summary)" == *"Codex=192600/267600"* ]] \
    && pass "[control] Codex's cached input is counted twice before v0.86" \
    || fail "[control] the fixture does not show the double count: this suite would prove nothing"

echo "applying $(basename "$V086") twice ..."
apply "$V086"
apply "$V086"
echo "  re-applied cleanly (idempotent)"
check "[postflight] the header's rule query reads true" "($RULE)"

echo "after v0.86:"
check_figures "each once" after
same "Codex drops to input + output: $(tokens_of provider_summary | tr ' ' '\n' | grep '^Codex=')" \
     "Codex=111100/156100" "$(tokens_of provider_summary | tr ' ' '\n' | grep '^Codex=')"
same "nothing else in provider_summary's answer moved (keys, types, costs, quota fields)" \
     "$rest_ps_before" "$(rest_of provider_summary)"
same "nothing else in provider_account_summary's answer moved (keys, types, costs, accounts)" \
     "$rest_pas_before" "$(rest_of provider_account_summary)"
same "nothing else in dashboard_summary's answer moved" "$rest_dash_before" "$(dashboard_rest)"
same "signatures, results, SECURITY DEFINER, search_path and grants unchanged" \
     "$contract_before" "$(psql_q -c "$CONTRACT")"
check_contract_calls "upgrade"
bodies_after="$(psql_q -c "$BODIES")"
[[ "$bodies_after" != "$bodies_before" ]] && pass "the three bodies were replaced" \
                                          || fail "v0.86 left the bodies as they were"

echo "rollback_v0.86.sql:"
apply "$ROLLBACK"
same "puts back the exact pre-v0.86 bodies (v0.44's and v0.72's)" "$bodies_before" "$(psql_q -c "$BODIES")"
same "with the same signatures and grants" "$contract_before" "$(psql_q -c "$CONTRACT")"
check_figures "rolled back" before
apply "$V086"
same "v0.86 applies again after the rollback" "$bodies_after" "$(psql_q -c "$BODIES")"
check_figures "re-applied" after

# ════════════════════════════════════════════════════════════════════════════
echo "== fresh path: schema.sql + app_rpc.sql + helper_rpc.sql =="
DB="$FRESH_DATABASE_URL"
apply "$SHIM"
apply "$SQL_DIR/schema.sql"
apply "$SQL_DIR/app_rpc.sql"
apply "$SQL_DIR/helper_rpc.sql"
load_fixture
same "the fresh install has the upgraded bodies, byte for byte" "$bodies_after" "$(psql_q -c "$BODIES")"
check "[fresh] the rule query reads true" "($RULE)"
check_figures "fresh" after
check_contract_calls "fresh"
apply "$V086"
same "v0.86 on a fresh install changes nothing" "$bodies_after" "$(psql_q -c "$BODIES")"

echo
if (( fails > 0 )); then
    echo "✗ $fails check(s) failed" >&2
    exit 1
fi
echo "✓ v0.86: the summary RPCs count each token once, as the Mac does; contract, costs and grants unchanged"

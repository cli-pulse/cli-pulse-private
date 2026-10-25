#!/usr/bin/env bash
# Verify migrate_v0.87 (the nightly retention cleanup deletes again;
# dashboard_summary counts only fresh sessions and devices) against a real
# Postgres, on both install paths.
#
# Production's cleanup (`_cleanup_expired_data_internal`, migrate_v0.21) deleted
# from a table that never existed, `device_snapshots`, inside the same
# per-account block as its sessions and alerts deletes, so the error rolled all
# of them back, every night. v0.87 gives each table its own savepoint, deletes
# sessions of any status once they are older than the account's retention (the
# zombie 'Running' rows included) and alerts likewise, and reports per-table
# counts and errors. dashboard_summary's two counts ignore rows nothing has
# rewritten for 300 s (sessions) and 1800 s (devices).
#
# What this proves:
#   * the control: production's definitions (v0.21's cleanup, v0.22's wrapper,
#     v0.86's dashboard_summary) reproduce the bug: rows past retention, a run,
#     nothing deleted, and the stale counts;
#   * after v0.87 the cleanup deletes exactly the rows past each account's
#     retention (7 days, 30 days, and 0 = keep), of every status, and nothing
#     else; a second run deletes nothing; its answer gives each table's count;
#   * the dry-run query APPLY step 0 prints predicts the first run's answer
#     exactly (the counts the owner approves are the counts that go);
#   * the negative control: one table's DELETE forced to fail (each of the
#     three in turn) is counted as errors = 1, named, reported with a WARNING,
#     and the other two tables are still cleaned;
#   * dashboard_summary counts only fresh rows, and its body is v0.86's plus
#     exactly two lines; every other value of its answer, its signature and
#     grants do not move; anon cannot call it, a call without a user is
#     refused;
#   * the ops check (ops/check_cron_references.sql, run as it stands) reports
#     production's missing table before v0.87, nothing after, and a missing
#     table again when one is taken away (negative controls, one of them two
#     calls deep);
#   * v0.87 refuses to run without v0.86's dashboard_summary, without v0.21's
#     cleanup, or when a table its cleanup names is missing, and replaces
#     nothing then; it applies twice cleanly;
#   * the APPLY steps in the header hold: step 0's query, as printed, gives the
#     answer it says to expect before and after, with the md5 values it lists;
#     step 4's query sees rows a day past retention before the first run and
#     none after; the ROLLBACK (step 0's saved definitions) gives step 0's
#     bodies back;
#   * a fresh install (schema.sql + app_rpc.sql + helper_rpc.sql) installs the
#     same bodies, production's service_role wrapper byte for byte, the same
#     grants, and behaves the same.
#
# pg_cron is not available on plain Postgres, so each database gets a stand-in
# `cron.job` table holding production's job for the cleanup (its command as
# migrate_v0.21 scheduled it); the ops check only reads that table.
#
# Every check runs even after one fails, and each prints its own label.
#
# Usage:
#   UPGRADE_DATABASE_URL=postgres://postgres:postgres@localhost:5432/v087_upgrade \
#   FRESH_DATABASE_URL=postgres://postgres:postgres@localhost:5432/v087_fresh \
#     ./backend/supabase/tests/run_v087_retention_cleanup_tests.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$HERE/.."
SHIM="$HERE/rls/00_supabase_shim.sql"
V021="$SQL_DIR/migrate_v0.21_cleanup_cron.sql"
V022="$SQL_DIR/migrate_v0.22_retention_cron.sql"
V044="$SQL_DIR/migrate_v0.44_user_tz_today.sql"
V086="$SQL_DIR/migrate_v0.86_summary_tokens_each_once.sql"
V087="$SQL_DIR/migrate_v0.87_retention_cleanup_and_fresh_counts.sql"
OPS="$SQL_DIR/ops/check_cron_references.sql"

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
for f in "$SHIM" "$V021" "$V022" "$V044" "$V086" "$V087" "$OPS" \
         "$SQL_DIR/schema.sql" "$SQL_DIR/app_rpc.sql" "$SQL_DIR/helper_rpc.sql"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Production's two cleanup functions, cut out of the migrations that installed
# them (both files also schedule pg_cron jobs, which plain Postgres lacks).
sed -n '/^CREATE OR REPLACE FUNCTION public._cleanup_expired_data_internal()/,/^\$\$;/p' "$V021" > "$WORK/v021_internal.sql"
sed -n '/^CREATE OR REPLACE FUNCTION public.cleanup_expired_data()/,/^\$\$;/p' "$V022" > "$WORK/v022_wrapper.sql"
echo "REVOKE ALL ON FUNCTION public._cleanup_expired_data_internal() FROM PUBLIC, authenticated, anon;" >> "$WORK/v021_internal.sql"
echo "REVOKE ALL ON FUNCTION public.cleanup_expired_data() FROM PUBLIC, authenticated, anon;" >> "$WORK/v022_wrapper.sql"
grep -q 'device_snapshots' "$WORK/v021_internal.sql" \
    || { echo "could not cut v0.21's cleanup out of $V021" >&2; exit 2; }
grep -q '_cleanup_expired_data_internal' "$WORK/v022_wrapper.sql" \
    || { echo "could not cut v0.22's wrapper out of $V022" >&2; exit 2; }

DB=""   # the database the helpers below talk to
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

UA='87000000-8700-4870-8870-00000000000a'   # retention 7 days (the default)
UB='87000000-8700-4870-8870-00000000000b'   # retention 30 days
UC='87000000-8700-4870-8870-00000000000c'   # retention 0: keeps everything

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

FUNCS="'_cleanup_expired_data_internal', 'cleanup_expired_data', 'dashboard_summary'"
CONTRACT="select string_agg(format('%s(%s) -> %s secdef=%s config=%s acl=%s',
                   p.proname, pg_get_function_arguments(p.oid), pg_get_function_result(p.oid),
                   p.prosecdef, p.proconfig, p.proacl), E'\n' order by p.proname)
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ($FUNCS);"
BODIES="select string_agg(p.proname || '=' || md5(p.prosrc), ' ' order by p.proname)
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname in ($FUNCS);"
body_of() { psql_q -c "select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'public' and p.proname = '$1';"; }

# ── the header's APPLY steps, read from the file as printed ────────────────
STEP0_SQL="$(sed -n '/^-- 0\. Preflight/,/order by 1;/p' "$V087" | sed -n '/select p\.proname/,$p' | sed 's/^--//')"
DRYRUN_SQL="$(sed -n '/^--      with keep as (/,/^--      order by 1;/p' "$V087" | sed 's/^--//')"
STEP4_SQL="$(sed -n '/^-- 4\. The day after/,/^--    cron\.job_run_details/p' "$V087" | sed -n '/^--      select (select count/,/;$/p' | sed 's/^--//')"
[[ -n "$STEP0_SQL" && -n "$DRYRUN_SQL" && -n "$STEP4_SQL" ]] || { echo "could not read APPLY steps 0 and 4 from $V087" >&2; exit 2; }
step0() { psql_q -c "$STEP0_SQL" | paste -sd' ' -; }
dry_run() { psql_q -c "$DRYRUN_SQL" | paste -sd' ' -; }
# The md5 lines of one APPLY step: "--      vX.YY  <function>  <md5>".
md5_lines() { # md5_lines <first line of the step> <first line after it>
    sed -n "/$1/,/$2/p" "$V087" \
        | grep -E '^--[[:space:]]+v0\.[0-9]+[[:space:]]+[a-z_]+[[:space:]]+[0-9a-f]{32}[[:space:]]*$' || true
}
STEP0_MD5="$(md5_lines '^-- 0\. Preflight' '^-- 1\. Apply')"
STEP2_MD5="$(md5_lines '^-- 2\. Post-apply' '^-- 3\. ')"
header_bodies() { # "name=md5 ..." as $BODIES prints it
    echo "$1" | awk '{print $3 "=" $4}' | LC_ALL=C sort | paste -sd' ' -
}
# What step 0's query should print: proname|args|prosecdef|v087|md5|anon|authenticated.
step0_expected() { # step0_expected <md5 lines> <v087 for the two replaced functions t|f>
    echo "$1" | awk -v v="$2" '{
        name = $3; args = ""; auth = "f"; mark = v
        if (name == "dashboard_summary") { args = "p_user_today date"; auth = "t" }
        if (name == "cleanup_expired_data") { mark = "f" }
        print name "|" args "|t|" mark "|" $4 "|f|" auth
    }' | LC_ALL=C sort | paste -sd' ' -
}

# ── the stand-in for pg_cron's job table, with production's cleanup job ────
cron_stub() {
    psql_q >/dev/null <<'SQL'
create schema if not exists cron;
create table if not exists cron.job (
  jobid bigserial primary key, schedule text, command text, nodename text, nodeport integer,
  database text, username text default 'postgres', active boolean not null default true, jobname text
);
insert into cron.job (jobname, schedule, command)
values ('cleanup_expired_data_nightly', '7 3 * * *', 'SELECT public._cleanup_expired_data_internal();');
SQL
}
ops_check() { psql_q -f "$OPS" | paste -sd' ' -; }
ops_check_with() { # ops_check_with <sql run first, in a transaction rolled back after>
    psql_q <<SQL | paste -sd' ' -
begin;
$1
\i '$OPS'
rollback;
SQL
}

# ── the fixture: three accounts, rows either side of each retention ────────
# Session and alert ids say what should happen to them: `del-` rows are past
# their account's retention, `keep-` rows are not (or the account keeps all).
load_fixture() {
    psql_q >/dev/null <<SQL
create schema if not exists v087_test;
insert into auth.users (id, email) values
  ('$UA', 'a@test.local'), ('$UB', 'b@test.local'), ('$UC', 'c@test.local');
update public.user_settings set data_retention_days = 30 where user_id = '$UB';
update public.user_settings set data_retention_days = 0 where user_id = '$UC';

insert into public.sessions (id, user_id, provider, status, started_at, last_active_at) values
  ('del-a-ended-10d',        '$UA', 'Codex',  'Ended',   now() - interval '10 days 1 hour', now() - interval '10 days'),
  ('del-a-running-10d',      '$UA', 'Claude', 'Running', now() - interval '10 days 1 hour', now() - interval '10 days'),
  ('del-a-idle-8d',          '$UA', 'Codex',  'Idle',    now() - interval '8 days 1 hour',  now() - interval '8 days'),
  ('keep-a-ended-1d',        '$UA', 'Codex',  'Ended',   now() - interval '1 day 1 hour',   now() - interval '1 day'),
  ('keep-a-running-60s',     '$UA', 'Claude', 'Running', now() - interval '1 hour',         now() - interval '60 seconds'),
  ('keep-a-running-240s',    '$UA', 'Codex',  'Running', now() - interval '1 hour',         now() - interval '240 seconds'),
  ('keep-a-running-360s',    '$UA', 'Codex',  'Running', now() - interval '1 hour',         now() - interval '360 seconds'),
  ('keep-a-running-1h',      '$UA', 'Claude', 'Running', now() - interval '2 hours',        now() - interval '1 hour'),
  ('del-b-ended-40d',        '$UB', 'Codex',  'Ended',   now() - interval '40 days 1 hour', now() - interval '40 days'),
  ('del-b-running-40d',      '$UB', 'Codex',  'Running', now() - interval '40 days 1 hour', now() - interval '40 days'),
  ('keep-b-ended-10d',       '$UB', 'Codex',  'Ended',   now() - interval '10 days 1 hour', now() - interval '10 days'),
  ('keep-c-ended-400d',      '$UC', 'Codex',  'Ended',   now() - interval '400 days',       now() - interval '400 days'),
  ('keep-c-running-400d',    '$UC', 'Codex',  'Running', now() - interval '400 days',       now() - interval '400 days');

insert into public.alerts (id, user_id, type, title, is_resolved, created_at) values
  ('del-a-resolved-10d',  '$UA', 'Usage Spike', 'old, resolved',   true,  now() - interval '10 days'),
  ('del-a-open-10d',      '$UA', 'Usage Spike', 'old, unresolved', false, now() - interval '10 days'),
  ('keep-a-open-1d',      '$UA', 'Usage Spike', 'recent',          false, now() - interval '1 day'),
  ('del-b-open-40d',      '$UB', 'Usage Spike', 'past 30 days',    false, now() - interval '40 days'),
  ('keep-b-open-10d',     '$UB', 'Usage Spike', 'within 30 days',  false, now() - interval '10 days'),
  ('keep-c-open-400d',    '$UC', 'Usage Spike', 'kept for good',   false, now() - interval '400 days');

insert into public.pairing_attempt_log (ip_addr, attempted_at) values
  ('192.0.2.1', now() - interval '2 hours'),
  ('192.0.2.2', now() - interval '10 minutes');

insert into public.devices (user_id, name, status, last_seen_at) values
  ('$UA', 'a-online-60s',   'Online',  now() - interval '60 seconds'),
  ('$UA', 'a-online-1500s', 'Online',  now() - interval '1500 seconds'),
  ('$UA', 'a-online-2100s', 'Online',  now() - interval '2100 seconds'),
  ('$UA', 'a-online-40d',   'Online',  now() - interval '40 days'),
  ('$UA', 'a-offline-60s',  'Offline', now() - interval '60 seconds'),
  ('$UB', 'b-online-10s',   'Online',  now() - interval '10 seconds'),
  ('$UC', 'c-online-40d',   'Online',  now() - interval '40 days');

insert into public.daily_usage_metrics
  (user_id, metric_date, provider, model, input_tokens, cached_tokens, output_tokens, cost)
values ('$UA', current_date, 'Codex', 'gpt-5-codex', 1000, 600, 100, 0.5),
       ('$UA', current_date, 'Claude', 'claude-sonnet-4-5', 300, 2000, 50, 0.25);
SQL
}

# What is left, by id, and what the cleanup should have left.
LEFT="select (select string_agg(id, ',' order by id collate \"C\") from public.sessions) || ' | '
          || (select string_agg(id, ',' order by id collate \"C\") from public.alerts) || ' | '
          || (select count(*) from public.pairing_attempt_log)::text;"
KEPT_SESSIONS="keep-a-ended-1d,keep-a-running-1h,keep-a-running-240s,keep-a-running-360s,keep-a-running-60s,keep-b-ended-10d,keep-c-ended-400d,keep-c-running-400d"
KEPT_ALERTS="keep-a-open-1d,keep-b-open-10d,keep-c-open-400d"
EXPECTED_LEFT="$KEPT_SESSIONS | $KEPT_ALERTS | 1"
FULL_FIXTURE="del-a-ended-10d,del-a-idle-8d,del-a-running-10d,del-b-ended-40d,del-b-running-40d,$KEPT_SESSIONS | del-a-open-10d,del-a-resolved-10d,del-b-open-40d,$KEPT_ALERTS | 2"

# The cleanup's answer as "table|deleted|running" lines, the dry run's shape.
ANSWER_AS_DRYRUN="select format('alerts|%s| pairing_attempt_log|%s| sessions|%s|%s',
                          r->>'alerts_deleted', r->>'pairing_attempt_log_deleted',
                          r->>'sessions_deleted', r->>'running_sessions_deleted')
                    from (select public._cleanup_expired_data_internal() as r) s;"
summary_of() { # summary_of <answer jsonb text>: the counts and the errors
    psql_q -c "select format('sessions=%s running=%s alerts=%s pairing=%s errors=%s failed=%s',
                     r->>'sessions_deleted', r->>'running_sessions_deleted', r->>'alerts_deleted',
                     r->>'pairing_attempt_log_deleted', r->>'errors', r->'failed')
                 from (select '$1'::jsonb as r) s;"
}

dashboard_counts() { # dashboard_counts <user>: "active_sessions/online_devices"
    as_user "$1" "select format('%s/%s', d->>'active_sessions', d->>'online_devices')
                    from (select public.dashboard_summary(current_date) as d) s;"
}
dashboard_rest() { # everything else in the answer, and its keys
    as_user "$UA" "select (d - 'active_sessions' - 'online_devices')::text
                          || ' keys=' || (select string_agg(k, ',' order by k) from jsonb_object_keys(d) k)
                     from (select public.dashboard_summary(current_date) as d) s;"
}
check_fresh_counts() { # check_fresh_counts <label>
    same "[$1] account A: active_sessions counts the Running rows of the last 300 s, online_devices the Online devices of the last 1800 s" \
         "2/2" "$(dashboard_counts "$UA")"
    same "[$1] account B: its zombie Running row no longer counts, its fresh device does" "0/1" "$(dashboard_counts "$UB")"
    same "[$1] account C: nothing fresh, nothing counted" "0/0" "$(dashboard_counts "$UC")"
}
check_calls() { # check_calls <label>: grants and the calls the apps make
    local label="$1" out
    check "[$label] anon cannot execute dashboard_summary, authenticated can" \
          "not has_function_privilege('anon', 'public.dashboard_summary(date)', 'EXECUTE')
           and has_function_privilege('authenticated', 'public.dashboard_summary(date)', 'EXECUTE')"
    check "[$label] neither anon nor authenticated can execute the cleanup or its wrapper" \
          "not has_function_privilege('anon', 'public._cleanup_expired_data_internal()', 'EXECUTE')
           and not has_function_privilege('authenticated', 'public._cleanup_expired_data_internal()', 'EXECUTE')
           and not has_function_privilege('anon', 'public.cleanup_expired_data()', 'EXECUTE')
           and not has_function_privilege('authenticated', 'public.cleanup_expired_data()', 'EXECUTE')"
    check "[$label] each is SECURITY DEFINER with a pinned search_path, one overload each" \
          "(select count(*) = 3 and bool_and(p.prosecdef and p.proconfig::text like '%search_path=pg_catalog, public, extensions%')
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname in ($FUNCS))"
    out="$(as_user "$UA" "select jsonb_typeof(public.dashboard_summary());")"
    same "[$label] dashboard_summary() without p_user_today still answers" "object" "$out"
    if out="$(as_user - "select public.dashboard_summary(current_date);" 2>&1)"; then
        fail "[$label] dashboard_summary answered a call without a user"
    else
        [[ "$out" == *"Not authenticated"* ]] && pass "[$label] dashboard_summary refuses a call without a user" \
                                             || fail "[$label] dashboard_summary failed without a user for another reason: $out"
    fi
    if out="$(as_user "$UA" "select public.cleanup_expired_data();" 2>&1)"; then
        fail "[$label] a signed-in user ran cleanup_expired_data"
    else
        [[ "$out" == *"permission denied"* || "$out" == *"Forbidden"* ]] \
            && pass "[$label] a signed-in user cannot run cleanup_expired_data" \
            || fail "[$label] cleanup_expired_data failed for a signed-in user for another reason: $out"
    fi
    if out="$(psql_q -c "select public.cleanup_expired_data();" 2>&1)"; then
        fail "[$label] cleanup_expired_data ran without the service_role claim"
    else
        [[ "$out" == *"Forbidden: service_role required"* ]] \
            && pass "[$label] the wrapper still refuses a caller without the service_role claim" \
            || fail "[$label] the wrapper failed without the claim for another reason: $out"
    fi
}

# nc_one_table <label> <table>: make <table>'s DELETE fail, run the cleanup,
# and roll everything back. The other two tables must still be cleaned.
nc_one_table() {
    local label="$1" table="$2" answer errf want left
    errf="$WORK/nc_$table.err"
    answer="$(psql_q 2>"$errf" <<SQL | sed -n 1p
begin;
create function v087_test.refuse_delete() returns trigger language plpgsql as \$\$
begin raise exception 'v0.87 negative control: % refuses deletes', tg_table_name; end \$\$;
create trigger v087_nc before delete on public.$table
  for each statement execute function v087_test.refuse_delete();
select public._cleanup_expired_data_internal()::text;
$LEFT
rollback;
SQL
)" || answer='{}'   # a cleanup that raised: the checks below fail, the suite goes on
    case "$table" in
        sessions)            want='sessions=0 running=0 alerts=3 pairing=1 errors=1 failed=["sessions"]' ;;
        alerts)              want='sessions=5 running=2 alerts=0 pairing=1 errors=1 failed=["alerts"]' ;;
        pairing_attempt_log) want='sessions=5 running=2 alerts=3 pairing=0 errors=1 failed=["pairing_attempt_log"]' ;;
    esac
    same "[$label NC] $table's DELETE forced to fail: errors = 1, it is named, the other two tables are still cleaned" \
         "$want" "$(summary_of "$answer")"
    grep -q "WARNING:  _cleanup_expired_data_internal: $table not cleaned: v0.87 negative control" "$errf" \
        && pass "[$label NC] the failure is reported with a WARNING naming $table" \
        || { fail "[$label NC] no WARNING naming $table"; sed 's/^/      /' "$errf" >&2; }
}

check_cleanup() { # check_cleanup <label>: the dry run, then the real first run
    local label="$1" dry answer
    same "[$label] before the first run every fixture row is there" "$FULL_FIXTURE" "$(psql_q -c "$LEFT")"
    same "[$label] APPLY step 4's query sees the rows a day past retention before the first run" \
         "5|3" "$(psql_q -c "$STEP4_SQL")"
    for t in sessions alerts pairing_attempt_log; do nc_one_table "$label" "$t"; done
    same "[$label NC] the negative controls rolled back: every fixture row is there" "$FULL_FIXTURE" "$(psql_q -c "$LEFT")"
    dry="$(dry_run)"
    same "[$label] the dry run (APPLY step 0, as printed) counts what is past retention" \
         "alerts|3| pairing_attempt_log|1| sessions|5|2" "$dry"
    same "[$label] the first run's answer is exactly the dry run's counts" "$dry" "$(psql_q -c "$ANSWER_AS_DRYRUN")"
    same "[$label] what is left: every keep- row, no del- row (7 days, 30 days, and 0 = keep all)" \
         "$EXPECTED_LEFT" "$(psql_q -c "$LEFT")"
    same "[$label] a second run deletes nothing and reports no error" \
         'sessions=0 running=0 alerts=0 pairing=0 errors=0 failed=[]' \
         "$(summary_of "$(psql_q -c "select public._cleanup_expired_data_internal()::text;")")"
    same "[$label] and the dry run now counts nothing" \
         "alerts|0| pairing_attempt_log|0| sessions|0|0" "$(dry_run)"
    same "[$label] APPLY step 4's query, as printed, finds no row a day past retention" "0|0" "$(psql_q -c "$STEP4_SQL")"
    same "[$label] the service_role wrapper gives the cleanup's answer" \
         'sessions=0 running=0 alerts=0 pairing=0 errors=0 failed=[]' \
         "$(summary_of "$(psql_q <<'SQL' | sed -n 1p
begin;
select set_config('request.jwt.claims', '{"role":"service_role"}', true) \g /dev/null
select public.cleanup_expired_data()::text;
rollback;
SQL
)")"
}

# ════════════════════════════════════════════════════════════════════════════
echo "== upgrade path: production's definitions, then v0.87 =="
DB="$UPGRADE_DATABASE_URL"
apply "$SHIM"
apply "$SQL_DIR/schema.sql"
apply "$SQL_DIR/app_rpc.sql"
apply "$SQL_DIR/helper_rpc.sql"
echo "putting back the definitions production runs (v0.21's cleanup, v0.22's wrapper, v0.86's dashboard_summary) ..."
apply "$WORK/v021_internal.sql"
apply "$WORK/v022_wrapper.sql"
apply "$V086"
cron_stub
check "[preflight] there is no device_snapshots table, as in production" "to_regclass('public.device_snapshots') is null"

same "[preflight] the md5 values APPLY step 0 lists are the bodies production runs (v0.21, v0.22, v0.86)" \
     "$(header_bodies "$STEP0_MD5")" "$(psql_q -c "$BODIES")"
same "[preflight] APPLY step 0's query, as printed, gives the answer it says to expect" \
     "$(step0_expected "$STEP0_MD5" f)" "$(step0)"
psql_q -A -c "select string_agg(pg_get_functiondef(p.oid) || ';', E'\n')
                from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname in ($FUNCS);" > "$WORK/saved_definitions.sql"
contract_before="$(psql_q -c "$CONTRACT")"
bodies_before="$(psql_q -c "$BODIES")"
body_of dashboard_summary > "$WORK/dashboard_v086.txt"
wrapper_md5() { psql_q -c "select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                             where n.nspname = 'public' and p.proname = 'cleanup_expired_data';"; }
wrapper_before="$(wrapper_md5)"

same "[preflight] the ops check reports production's missing table, exactly as it did there" \
     "cleanup_expired_data_nightly|_cleanup_expired_data_internal|public.device_snapshots" "$(ops_check)"

load_fixture
echo "before v0.87 (the control):"
control="$(PGOPTIONS="-c client_min_messages=notice" psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX \
             -c "begin" -c "select public._cleanup_expired_data_internal()::text" -c "$LEFT" -c "rollback" \
             2>"$WORK/control.err")"
same "[control] production's cleanup deletes no session and no alert, though 5 sessions and 3 alerts are past retention (only the old pairing attempt goes)" \
     "${FULL_FIXTURE% | 2} | 1" "$(echo "$control" | sed -n 2p)"
grep -q 'device_snapshots' "$WORK/control.err" \
    && pass "[control] because each account's block fails on device_snapshots and rolls back the rest" \
    || fail "[control] the old cleanup did not fail on device_snapshots: this suite would prove nothing"
same "[control] and its answer counts the Ended sessions and the alerts it rolled back as deleted" \
     "2/3" "$(psql_q -c "select format('%s/%s', r->>'sessions_deleted', r->>'alerts_deleted')
                           from (select '$(echo "$control" | sed -n 1p)'::jsonb r) s;")"
same "[control] v0.86's dashboard_summary counts every Running row and every Online device" \
     "5/4 1/1 1/1" "$(dashboard_counts "$UA") $(dashboard_counts "$UB") $(dashboard_counts "$UC")"
rest_before="$(dashboard_rest)"

echo "v0.87 refuses to run without what it replaces:"
refuse() { # refuse <label> <sql that takes something away> <message> <sql that puts it back>
    local before out
    psql_q -c "$2" >/dev/null
    before="$(psql_q -c "$BODIES")"
    if out="$(psql_q -f "$V087" 2>&1)"; then
        fail "[refusal] v0.87 applied $1"
    else
        [[ "$out" == *"$3"* ]] && pass "[refusal] v0.87 refuses to run $1: '$3'" \
                               || fail "[refusal] v0.87 failed $1, but not on its precondition: $out"
    fi
    same "[refusal] $1, v0.87 replaced nothing" "$before" "$(psql_q -c "$BODIES")"
    psql_q -c "$4" >/dev/null
}
apply "$V044"
refuse "over v0.44's dashboard_summary (v0.86 not applied)" "select 1" "apply v0.86 first" "select 1"
apply "$V086"
refuse "without v0.21's cleanup" "drop function public._cleanup_expired_data_internal();" \
       "apply v0.21 first" "select 1"
apply "$WORK/v021_internal.sql"
refuse "when a table the new cleanup names is missing" \
       "alter table public.pairing_attempt_log rename to pairing_attempt_log_away;" \
       "the cleanup names public.pairing_attempt_log, which does not exist" \
       "alter table public.pairing_attempt_log_away rename to pairing_attempt_log;"
same "[refusal] after the refusals, production's bodies and grants are back" \
     "$bodies_before $contract_before" "$(psql_q -c "$BODIES") $(psql_q -c "$CONTRACT")"

echo "applying $(basename "$V087") twice ..."
apply "$V087"
apply "$V087"
echo "  re-applied cleanly (idempotent)"
bodies_after="$(psql_q -c "$BODIES")"
same "[postflight] the md5 values APPLY step 2 lists are v0.87's bodies (and the wrapper's, unchanged)" \
     "$(header_bodies "$STEP2_MD5")" "$bodies_after"
same "[postflight] step 0's query gives v0.87's bodies, the args, SECURITY DEFINER and grants unchanged" \
     "$(step0_expected "$STEP2_MD5" t)" "$(step0)"
same "[postflight] signatures, results, SECURITY DEFINER, search_path and grants unchanged" \
     "$contract_before" "$(psql_q -c "$CONTRACT")"
same "[postflight] the wrapper's body is production's, byte for byte" "$wrapper_before" "$(wrapper_md5)"
body_of dashboard_summary > "$WORK/dashboard_v087.txt"
same "[postflight] dashboard_summary's body is v0.86's plus exactly two lines, both marked, nothing removed" \
     "2 added, 0 removed, 2 marked" \
     "$(diff "$WORK/dashboard_v086.txt" "$WORK/dashboard_v087.txt" | awk '
         /^>/ { a++; if ($0 ~ /-- v0\.87 fresh rows only$/) m++ }
         /^</ { r++ }
         END { printf "%d added, %d removed, %d marked", a, r, m }')"
same "[postflight] the ops check reports nothing" "" "$(ops_check)"

echo "after v0.87:"
check_fresh_counts "upgrade"
same "nothing else in dashboard_summary's answer moved" "$rest_before" "$(dashboard_rest)"
check_calls "upgrade"

echo "the ops check, negative controls:"
same "[ops NC] a table the cleanup names taken away: reported" \
     "cleanup_expired_data_nightly|_cleanup_expired_data_internal|public.pairing_attempt_log" \
     "$(ops_check_with "alter table public.pairing_attempt_log rename to pairing_attempt_log_away;")"
same "[ops NC] a missing table two calls below a job's command: reported, under the function that names it" \
     "v087_nc_job|v087_nc_inner|public.v087_no_such_table" \
     "$(ops_check_with "create function public.v087_nc_inner() returns void language plpgsql as \$\$ begin delete from public.v087_no_such_table; end \$\$;
create function public.v087_nc_outer() returns void language plpgsql as \$\$ begin perform public.v087_nc_inner(); end \$\$;
insert into cron.job (jobname, schedule, command) values ('v087_nc_job', '* * * * *', 'select public.v087_nc_outer()');")"
same "[ops NC] an inactive job is not read" "" \
     "$(ops_check_with "create function public.v087_nc_inner() returns void language plpgsql as \$\$ begin delete from public.v087_no_such_table; end \$\$;
insert into cron.job (jobname, schedule, command, active) values ('v087_nc_off', '* * * * *', 'select public.v087_nc_inner()', false);")"

echo "the first run:"
check_cleanup "upgrade"

echo "ROLLBACK (step 0's saved definitions):"
apply "$WORK/saved_definitions.sql"
same "[rollback] gives back step 0's bodies, the ones production runs" "$(header_bodies "$STEP0_MD5")" "$(psql_q -c "$BODIES")"
same "[rollback] with the same signatures and grants" "$contract_before" "$(psql_q -c "$CONTRACT")"
apply "$V087"
same "[rollback] v0.87 applies again after it" "$bodies_after" "$(psql_q -c "$BODIES")"

# ════════════════════════════════════════════════════════════════════════════
echo "== fresh path: schema.sql + app_rpc.sql + helper_rpc.sql =="
DB="$FRESH_DATABASE_URL"
apply "$SHIM"
apply "$SQL_DIR/schema.sql"
apply "$SQL_DIR/app_rpc.sql"
apply "$SQL_DIR/helper_rpc.sql"
cron_stub
same "[fresh] the fresh install has the upgraded bodies, byte for byte (the wrapper production's)" \
     "$bodies_after" "$(psql_q -c "$BODIES")"
same "[fresh] step 0's query gives what step 2 expects in production" \
     "$(step0_expected "$STEP2_MD5" t)" "$(step0)"
same "[fresh] the ops check reports nothing (pairing_attempt_log is in schema.sql)" "" "$(ops_check)"
load_fixture
check_fresh_counts "fresh"
check_calls "fresh"
check_cleanup "fresh"
apply "$V087"
same "[fresh] v0.87 on a fresh install changes nothing" "$bodies_after" "$(psql_q -c "$BODIES")"

echo
if (( fails > 0 )); then
    echo "✗ $fails check(s) failed" >&2
    exit 1
fi
echo "✓ v0.87: the retention cleanup deletes what is past retention, table by table; dashboard_summary counts fresh rows only"

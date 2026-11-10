#!/usr/bin/env bash
# Verify migrate_v0.88 (schedule public.prune_anonymous_installs() nightly) and
# ops/check_anonymous_install_retention.sql against a real Postgres.
#
# pg_cron is not available on plain Postgres, so each database gets a stand-in
# `cron` schema: `cron.job` with pg_cron's columns and its unique
# (jobname, username), `cron.job_run_details`, and `cron.schedule` /
# `cron.unschedule` that behave like pg_cron 1.6's where v0.88 relies on them
# (scheduling a name this role already has updates that job's schedule and
# command in place, keeping its jobid; unscheduling a missing name raises).
# It holds production's eight jobs exactly as `cron.job` listed them on
# 2026-11-10, with a stub function for each command so the ops check sees
# them as existing. The anonymous telemetry schema is v0.73 + v0.76 + v0.79 +
# v0.80, as production has it.
#
# What this proves:
#   * v0.88 applies, and again (idempotent): one prune_anonymous_installs_nightly
#     job, '37 4 * * *', the command as written, active, and the same jobid
#     after the second apply (so the run history Q3 reads survives); the eight
#     other jobs (every column: jobid, name, schedule, command, active, user,
#     database, node) and every other column comment are what they were; the
#     seven comments it writes say what it says they do;
#   * an existing job of that name and role, with another schedule, ends as
#     one job, same jobid, with v0.88's schedule and command;
#   * the job's command, run as stored and as the job's user, deletes a row
#     last touched 400 days and an hour ago and keeps rows touched 400 days
#     less an hour ago and today, and returns 1;
#   * what the comments say about a pruned install that reports again: v0.80's
#     RPC inserts a new row whose first_seen_at and every milestone it
#     re-sends are the same instant;
#   * ops/check_cron_references.sql returns nothing, and names this job when
#     its table is taken away (negative control);
#   * ops/check_anonymous_install_retention.sql returns exactly 'no run
#     recorded' right after the apply (other jobs' runs do not count), and
#     nothing after a recent successful run or a failure followed by a
#     success, with rows a day, 399 days 23 hours and 400 days 12 hours old
#     in the table; it names each problem it is for when that problem is made
#     to happen: job missing, inactive, running another command; the prune
#     function changed (body, SECURITY INVOKER, search_path, dropped); last
#     run failed (chosen by runid, so a run pg_cron left with no start_time
#     does not hide or fake one); no run started in 26 hours (another job's
#     recent runs do not count); a row older than 401 days;
#   * the header's APPLY queries, extracted from the file as printed: Q0 and
#     Q2 give the answers the header says to expect; Q3 returns this job's
#     three newest runs by runid, before and after a second apply (stand-in
#     runs, one of them with no start_time and one whose runid and start_time
#     disagree; its 'succeeded' / '1 row' answer can only be seen in
#     production, where pg_cron runs the job);
#   * the header's ROLLBACK statement removes the job and nothing else;
#   * every guard in A and every check in D can fire, and when one does
#     nothing is left behind (cron.job and all seven comments unchanged): a
#     changed function body, a missing function, a SECURITY INVOKER function,
#     a function without its pinned search_path, a function anon or
#     authenticated can execute, no pg_cron, a job of that name owned by
#     another role; a cron.schedule that silently does nothing, one that
#     deletes another job, or changes another job's command, schedule or
#     active flag, one that stores the job inactive, with another schedule,
#     with another command, or under a role that cannot execute the function;
#     and copies of the migration without each of its seven `comment on`
#     statements.
#
# Every check runs even after one fails, and each prints its own label.
#
# Usage (DATABASE_URL: any database on a server where this role may create
# databases; the script creates and drops its own v088_* databases):
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres \
#     ./backend/supabase/tests/run_v088_prune_anonymous_installs_cron_tests.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$HERE/.."
V073="$SQL_DIR/migrate_v0.73_anonymous_install_telemetry.sql"
V076="$SQL_DIR/migrate_v0.76_activation_funnel.sql"
V079="$SQL_DIR/migrate_v0.79_anonymous_installs_column_comments.sql"
V080="$SQL_DIR/migrate_v0.80_remote_control_usage_latches.sql"
V088="$SQL_DIR/migrate_v0.88_schedule_prune_anonymous_installs.sql"
OPS="$SQL_DIR/ops/check_cron_references.sql"
RETENTION="$SQL_DIR/ops/check_anonymous_install_retention.sql"

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to a database on a disposable server" >&2
    exit 2
fi
for f in "$V073" "$V076" "$V079" "$V080" "$V088" "$OPS" "$RETENTION"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done

BASE="${DATABASE_URL%/*}"
WORK="$(mktemp -d)"
CREATED=()
cleanup() {
    for d in "${CREATED[@]:-}"; do
        [[ -n "$d" ]] && PGOPTIONS='-c client_min_messages=warning' \
            psql "$DATABASE_URL" -qtAX -c "drop database if exists $d" >/dev/null 2>&1
    done
    /bin/rm -rf "$WORK"
}
trap cleanup EXIT

fails=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

newdb() { # newdb <name>: creates it and sets DB to its URL (no subshell, so
          # CREATED survives for the cleanup trap)
    PGOPTIONS='-c client_min_messages=warning' psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 \
        -c "drop database if exists $1" -c "create database $1" >/dev/null \
        || { echo "cannot create database $1" >&2; exit 2; }
    CREATED+=("$1")
    DB="$BASE/$1"
}

q() { # q <url> <sql> -> value
    psql "$1" -v ON_ERROR_STOP=1 -qtAX -c "$2"
}

check() { # check <url> <label> <sql returning boolean>
    local got
    got="$(q "$1" "select ($3)::text" 2>&1)"
    if [[ "$got" == "true" ]]; then pass "$2"; else fail "$2  (got '$got')"; fi
}

same() { # same <label> <got> <want>
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi
}

apply() { # apply <url> <file> -> exit status of psql
    psql "$1" -v ON_ERROR_STOP=1 -qtAX -f "$2" >"$WORK/apply.out" 2>&1
}

# Supabase's roles do not exist in a bare Postgres; v0.73 grants to them.
psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 -c "do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end \$\$;" >/dev/null || exit 2

# ── the stand-in for pg_cron, with production's eight jobs ─────
CRON_STUB="$WORK/cron_stub.sql"
cat >"$CRON_STUB" <<'SQL'
create schema cron;
create table cron.job (
    jobid    bigserial primary key,
    schedule text    not null,
    command  text    not null,
    nodename text    not null default 'localhost',
    nodeport integer not null default 5432,
    database text    not null default current_database(),
    username text    not null default current_user,
    active   boolean not null default true,
    jobname  text,
    unique (jobname, username)
);
create table cron.job_run_details (
    jobid          bigint,
    runid          bigserial primary key,
    job_pid        integer,
    database       text,
    username       text,
    command        text,
    status         text,
    return_message text,
    start_time     timestamptz,
    end_time       timestamptz
);
-- pg_cron 1.6: scheduling a name this role already has updates that job in
-- place. Only schedule and command are updated here, so a test cannot pass
-- by relying on the update reactivating a job.
create function cron.schedule(job_name text, schedule text, command text)
returns bigint language plpgsql as $f$
declare v bigint;
begin
    insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
    on conflict (jobname, username) do update
        set schedule = excluded.schedule, command = excluded.command
    returning jobid into v;
    return v;
end $f$;
-- pg_cron 1.6: unscheduling a name this role does not have raises.
create function cron.unschedule(job_name text)
returns boolean language plpgsql as $f$
begin
    delete from cron.job where jobname = job_name and username = current_user;
    if not found then
        raise exception 'could not find valid entry for job ''%''', job_name;
    end if;
    return true;
end $f$;

create function public.process_app_push_jobs() returns void language sql as 'select';
create function public._cleanup_expired_data_internal() returns void language sql as 'select';
create function public.trigger_send_due_notifications() returns void language sql as 'select';
create function public.process_webhook_jobs() returns void language sql as 'select';
create function public._cleanup_remote_retention_internal() returns void language sql as 'select';
create function public._cleanup_remote_swarms_internal() returns void language sql as 'select';
create function public._cleanup_retention_data_internal(integer) returns void language sql as 'select';
create function public.process_widget_refresh() returns void language sql as 'select';

insert into cron.job (jobname, schedule, command) values
    ('app_push_jobs_drain',              '30 seconds', 'select public.process_app_push_jobs()'),
    ('cleanup_expired_data_nightly',     '7 3 * * *',  'SELECT public._cleanup_expired_data_internal();'),
    ('m10_send_due_notifications',       '* * * * *',  'select public.trigger_send_due_notifications()'),
    ('process_webhook_jobs',             '30 seconds', 'select public.process_webhook_jobs()'),
    ('remote_retention_cleanup_nightly', '47 3 * * *', 'SELECT public._cleanup_remote_retention_internal();'),
    ('remote_swarms_cleanup_nightly',    '7 4 * * *',  'select public._cleanup_remote_swarms_internal();'),
    ('retention_cleanup_nightly',        '27 3 * * *', 'SELECT public._cleanup_retention_data_internal(18);'),
    ('widget_refresh_hourly',            '13 * * * *', 'select public.process_widget_refresh()');
SQL

setup() { # setup <url>: cron stand-in, then the telemetry migrations production has
    apply "$1" "$CRON_STUB" || { cat "$WORK/apply.out" >&2; echo "cron stand-in failed" >&2; exit 2; }
    for f in "$V073" "$V076" "$V079" "$V080"; do
        apply "$1" "$f" || { cat "$WORK/apply.out" >&2; echo "$(basename "$f") failed" >&2; exit 2; }
    done
}

# Fingerprints. ALL_JOBS covers every cron.job row (a refusal must leave it
# exactly as it was); OTHER_JOBS leaves out the prune job.
ALL_JOBS_SQL="select md5(coalesce(string_agg(jobid || '|' || coalesce(jobname, '') || '|' || schedule || '|' || command || '|' || active::text || '|' || username, E'\n' order by jobid), '<empty>')) from cron.job"
OTHER_JOBS_SQL="select md5(string_agg(jobid || '|' || jobname || '|' || schedule || '|' || command || '|' || active::text || '|' || username || '|' || database || '|' || nodename || '|' || nodeport, E'\n' order by jobname)) from cron.job where jobname <> 'prune_anonymous_installs_nightly'"
OTHER_COMMENTS_SQL="select md5(string_agg(a.attname || '|' || coalesce(col_description(a.attrelid, a.attnum), '<none>'), E'\n' order by a.attname)) from pg_attribute a where a.attrelid = 'public.anonymous_installs'::regclass and a.attnum > 0 and not a.attisdropped and a.attname not in ('last_seen_at', 'first_seen_at', 'first_provider_detected_at')"
col_comment() { echo "coalesce(col_description('public.anonymous_installs'::regclass, (select attnum from pg_attribute where attrelid = 'public.anonymous_installs'::regclass and attname = '$1')), '<none>')"; }
SEVEN_COMMENTS_SQL="select md5(concat_ws(E'\n',
    coalesce(obj_description('public.anonymous_installs'::regclass, 'pg_class'), '<none>'),
    $(col_comment last_seen_at),
    $(col_comment first_seen_at),
    $(col_comment first_provider_detected_at),
    coalesce(obj_description('public.anonymous_funnel_summary(integer)'::regprocedure, 'pg_proc'), '<none>'),
    coalesce(obj_description('public.anonymous_activation_summary(integer)'::regprocedure, 'pg_proc'), '<none>'),
    coalesce(obj_description(to_regprocedure('public.prune_anonymous_installs()'), 'pg_proc'), '<none>')))"
JOBID_SQL="select jobid from cron.job where jobname = 'prune_anonymous_installs_nightly'"

# The header's APPLY queries, extracted as printed (one line each, after "Q<n>: ").
header_query() { sed -n "s/^--    Q$1: //p" "$V088"; }
Q0="$(header_query 0)"; Q2="$(header_query 2)"; Q3="$(header_query 3)"
for n in 0 2 3; do
    v="Q$n"
    [[ -n "${!v}" ]] || { echo "the header has no Q$n query" >&2; exit 2; }
done
ROLLBACK_SQL="$(sed -n 's/^-- ROLLBACK: //p' "$V088")"
[[ -n "$ROLLBACK_SQL" ]] || { echo "the header has no ROLLBACK statement" >&2; exit 2; }

retention() { # retention <url> [sql to run first, in the same rolled-back transaction]
    psql "$1" -v ON_ERROR_STOP=1 -qtAX 2>&1 <<SQL
begin;
${2:-}
$(cat "$RETENTION")
rollback;
SQL
}

# ═══ 1. upgrade path ═══════════════════════════════════════════
echo "upgrade path (v0.73 + v0.76 + v0.79 + v0.80, then v0.88):"
newdb v088_upgrade; U="$DB"
setup "$U"

check "$U" "fixture: prune_anonymous_installs() has v0.73's body" \
    "(select md5(prosrc) from pg_proc where oid = 'public.prune_anonymous_installs()'::regprocedure) = '29941fa052e043c75ed49fbad5a785d7'"
check "$U" "fixture: v0.79's comment says DO NOT DELETE ROWS" \
    "obj_description('public.anonymous_installs'::regclass, 'pg_class') like '%DO NOT DELETE ROWS%'"

same "header Q0 before apply" "$(q "$U" "$Q0" 2>&1)" "29941fa052e043c75ed49fbad5a785d7|t|f|0|8"

JOBS_BEFORE="$(q "$U" "$OTHER_JOBS_SQL")"
COMMENTS_BEFORE="$(q "$U" "$OTHER_COMMENTS_SQL")"

if apply "$U" "$V088"; then pass "v0.88 applies"; else fail "v0.88 applies: $(cat "$WORK/apply.out")"; fi
grep -q "v0.88: prune_anonymous_installs_nightly scheduled" "$WORK/apply.out" \
    && pass "v0.88 reports its verification passed" || fail "v0.88 printed no verification notice"

check "$U" "one prune_anonymous_installs_nightly job" \
    "(select count(*) from cron.job where jobname = 'prune_anonymous_installs_nightly') = 1"
check "$U" "schedule '37 4 * * *', command as written, active" \
    "exists (select 1 from cron.job where jobname = 'prune_anonymous_installs_nightly' and schedule = '37 4 * * *' and command = 'select public.prune_anonymous_installs()' and active)"
check "$U" "the eight other jobs did not move" "($OTHER_JOBS_SQL) = '$JOBS_BEFORE'"
check "$U" "every other column comment did not move" "($OTHER_COMMENTS_SQL) = '$COMMENTS_BEFORE'"
check "$U" "table comment: only the nightly job deletes, a returning install reads as new; DO NOT DELETE ROWS is gone" \
    "obj_description('public.anonymous_installs'::regclass, 'pg_class') like '%deleted ONLY by the nightly pg_cron job prune_anonymous_installs_nightly (migrate_v0.88)%activated on day 0%' and obj_description('public.anonymous_installs'::regclass, 'pg_class') not like '%DO NOT DELETE ROWS%'"
check "$U" "last_seen_at comment keeps NOT LIVENESS, names the retention key and the bias" \
    "col_description('public.anonymous_installs'::regclass, (select attnum from pg_attribute where attrelid = 'public.anonymous_installs'::regclass and attname = 'last_seen_at')) like 'MISNAMED — NOT LIVENESS%IS the retention key%rates read high%'"
check "$U" "anonymous_funnel_summary comment keeps v0.76's text and adds PRUNING" \
    "obj_description('public.anonymous_funnel_summary(integer)'::regprocedure, 'pg_proc') like 'Owner-only funnel readout: installs -> helper connected -> provider detected -> cost shown, split by channel and resolved UI language. Rows from before v0.76 report NULL for the new milestones; that is \"never reported\", not \"did not happen\", and a reader who forgets it will see a cliff on the day this deployed. PRUNING (migrate_v0.88%'"
check "$U" "anonymous_activation_summary and prune_anonymous_installs have their new comments" \
    "obj_description('public.anonymous_activation_summary(integer)'::regprocedure, 'pg_proc') like '%PRUNING (migrate_v0.88%' and obj_description('public.prune_anonymous_installs()'::regprocedure, 'pg_proc') like '%prune_anonymous_installs_nightly (migrate_v0.88)%'"

check "$U" "first_seen_at comment: the day a returning install came back; 'means what a reader expects' is gone" \
    "$(col_comment first_seen_at) like 'When this row was created:%the day it came back%' and $(col_comment first_seen_at) not like '%means what a reader expects%'"
check "$U" "first_provider_detected_at comment: write-once per row; for a returning install, the day it came back only if it had reached first value" \
    "$(col_comment first_provider_detected_at) like 'First value:%Write-once per row%had already reached first value, it is the day it came back, equal to first_seen_at;%stays NULL until it reaches first value%'"

same "header Q2 after apply" "$(q "$U" "$Q2" 2>&1)" "37 4 * * *|select public.prune_anonymous_installs()|t|t"

OPS_OUT="$(psql "$U" -v ON_ERROR_STOP=1 -qtAX -f "$OPS" 2>&1)"
same "ops/check_cron_references returns no rows" "$OPS_OUT" ""

# Negative control: the ops check must see this job's table go missing.
OPS_NC="$(psql "$U" -v ON_ERROR_STOP=1 -qtAX 2>&1 <<SQL
begin;
alter table public.anonymous_installs rename to anonymous_installs_gone;
$(cat "$OPS")
rollback;
SQL
)"
grep -q "prune_anonymous_installs_nightly|prune_anonymous_installs|public.anonymous_installs" <<<"$OPS_NC" \
    && pass "ops/check_cron_references names this job when its table is missing (negative control)" \
    || fail "ops/check_cron_references missed the missing table: '$OPS_NC'"

# ── the retention ops check ────────────────────────────────────
echo "ops/check_anonymous_install_retention.sql:"
JOBID="$(q "$U" "$JOBID_SQL")"
OTHER_JOBID="$(q "$U" "select jobid from cron.job where jobname = 'widget_refresh_hourly'")"
run() { # run <jobid> <status> <start_time sql or null> [return_message]: one job_run_details row
    echo "insert into cron.job_run_details (jobid, status, return_message, start_time) values ($1, '$2', '${4:-1 row}', $3);"
}
RECENT="$(run "$JOBID" succeeded "now() - interval '2 hours'")"
# Rows the promise allows: a day old, and just under and just over 400 days
# (the job runs daily, so a row lives up to 401 days).
IN_WINDOW="insert into public.anonymous_installs (install_id, first_seen_at, last_seen_at, channel, app_version, os_version) values
  ('00000000-0000-4000-8000-0000000a0000', now() - interval '1 day',    now(),                              'brew',  '1.62.0', '26.1'),
  ('00000000-0000-4000-8000-0000000a0399', now() - interval '500 days', now() - interval '399 days 23 hours', 'mas',   '1.44.0', '15.1'),
  ('00000000-0000-4000-8000-0000000a0400', now() - interval '500 days', now() - interval '400 days 12 hours', 'devid', '1.44.0', '15.1');"
same "right after the apply: exactly 'no run recorded'" "$(retention "$U" "$IN_WINDOW")" "no run recorded|"
same "right after the apply: exactly 'no run recorded' (other jobs' runs do not count)" \
    "$(retention "$U" "$IN_WINDOW $(run "$OTHER_JOBID" succeeded "now() - interval '1 minute'")")" "no run recorded|"
same "no rows after a recent successful run" "$(retention "$U" "$IN_WINDOW $RECENT")" ""
same "no rows after a failure followed by a success" \
    "$(retention "$U" "$IN_WINDOW $(run "$JOBID" failed "now() - interval '26 hours'" "ERROR: x") $RECENT")" ""
same "names a missing job (and nothing else)" \
    "$(retention "$U" "$RECENT delete from cron.job where jobname = 'prune_anonymous_installs_nightly';")" "job missing|"
same "names an inactive job" \
    "$(retention "$U" "$RECENT update cron.job set active = false where jobname = 'prune_anonymous_installs_nightly';")" "job inactive|"
same "names a job that runs another command" \
    "$(retention "$U" "$RECENT update cron.job set command = 'select 1' where jobname = 'prune_anonymous_installs_nightly';")" "job command changed|select 1"
same "names a changed prune function" \
    "$(retention "$U" "$RECENT create or replace function public.prune_anonymous_installs() returns integer language plpgsql security definer set search_path = public, pg_temp as \$f\$ begin delete from public.anonymous_installs where last_seen_at < now() - interval '4000 days'; return 0; end; \$f\$;")" \
    "prune function changed|"
same "names a prune function without its pinned search_path" \
    "$(retention "$U" "$RECENT alter function public.prune_anonymous_installs() reset search_path;")" "prune function changed|"
same "names a SECURITY INVOKER prune function" \
    "$(retention "$U" "$RECENT alter function public.prune_anonymous_installs() security invoker;")" "prune function changed|"
same "names a dropped prune function" \
    "$(retention "$U" "$RECENT drop function public.prune_anonymous_installs();")" "prune function changed|"
got="$(retention "$U" "$(run "$JOBID" succeeded "now() - interval '3 hours'") $(run "$JOBID" failed "now() - interval '1 hour'" "ERROR: x")")"
[[ "$got" == "last run failed|at "* ]] && pass "names a failed last run" || fail "failed last run: got '$got'"
same "names a last run that failed before it started (no start_time), by its message" \
    "$(retention "$U" "$RECENT $(run "$JOBID" failed null "server restarted")")" "last run failed|server restarted"
same "a run left with no start_time, followed by a success, is not the last run" \
    "$(retention "$U" "$(run "$JOBID" failed null "server restarted") $RECENT")" ""
got="$(retention "$U" "$(run "$JOBID" succeeded "now() - interval '27 hours'") $(run "$OTHER_JOBID" succeeded "now() - interval '1 minute'")")"
[[ "$got" == "no run in the last 26 hours|last run started at "* ]] \
    && pass "names a job that has not started a run in 26 hours (another job's recent run does not count)" \
    || fail "26 hours: got '$got'"
got="$(retention "$U" "$(run "$JOBID" succeeded "now() - interval '30 hours'") $(run "$JOBID" connecting null)")"
[[ "$got" == "no run in the last 26 hours|last run started at "* ]] \
    && pass "a newer run left with no start_time does not hide 30 hours without a run" \
    || fail "orphan hides staleness: got '$got'"
same "names rows older than 401 days" \
    "$(retention "$U" "$RECENT insert into public.anonymous_installs (install_id, first_seen_at, last_seen_at, channel, app_version, os_version) values ('00000000-0000-4000-8000-000000000402', now() - interval '500 days', now() - interval '402 days', 'devid', '1.44.0', '15.1');")" \
    "rows older than 401 days|1"

# ── Q3 and jobid stability across a re-apply ───────────────────
# Committed, one statement each so runids ascend in this order: an old run
# with no start_time (lowest runid), then runs whose runid and start_time
# disagree (r4 is newer by runid, older by start_time than r3), then another
# job's run with the highest runid of all. Q3 must give r5, r4, r3.
for r in "$(run "$JOBID" failed null r1)" \
         "$(run "$JOBID" succeeded "now() - interval '3 days'" r2)" \
         "$(run "$JOBID" succeeded "now() - interval '1 day'" r3)" \
         "$(run "$JOBID" failed "now() - interval '2 days'" r4)" \
         "$(run "$JOBID" succeeded "now() - interval '1 hour'" r5)" \
         "$(run "$OTHER_JOBID" succeeded "now() - interval '1 minute'" other)"; do
    q "$U" "$r" >/dev/null
done
Q3_WANT="$(printf 'succeeded|r5\nfailed|r4\nsucceeded|r3')"
same "header Q3 gives this job's three newest runs by runid" "$(q "$U" "$Q3" 2>&1 | cut -d'|' -f1,2)" "$Q3_WANT"

# Idempotence: a second apply leaves the same state, and the same jobid.
if apply "$U" "$V088"; then pass "v0.88 applies a second time"; else fail "second apply: $(cat "$WORK/apply.out")"; fi
check "$U" "still one job after the second apply" \
    "(select count(*) from cron.job where jobname = 'prune_anonymous_installs_nightly') = 1"
same "the job keeps its jobid across the second apply" "$(q "$U" "$JOBID_SQL")" "$JOBID"
check "$U" "the eight other jobs still did not move" "($OTHER_JOBS_SQL) = '$JOBS_BEFORE'"
same "header Q3 gives the same runs after the second apply (history kept)" "$(q "$U" "$Q3" 2>&1 | cut -d'|' -f1,2)" "$Q3_WANT"

# ── what the job does when it runs ─────────────────────────────
echo "the job's command, run as stored:"
q "$U" "insert into public.anonymous_installs (install_id, first_seen_at, last_seen_at, channel, app_version, os_version) values
  ('00000000-0000-4000-8000-000000000401', now() - interval '500 days', now() - interval '400 days 1 hour', 'devid', '1.44.0', '15.1'),
  ('00000000-0000-4000-8000-000000000399', now() - interval '500 days', now() - interval '399 days 23 hours', 'mas', '1.44.0', '15.1'),
  ('00000000-0000-4000-8000-000000000000', now() - interval '1 day',    now(), 'brew', '1.62.0', '26.1')" >/dev/null
JOB_USER="$(q "$U" "select username from cron.job where jobname = 'prune_anonymous_installs_nightly'")"
JOB_CMD="$(q "$U" "select command from cron.job where jobname = 'prune_anonymous_installs_nightly'")"
if psql "$U" -v ON_ERROR_STOP=1 -qtAX -c "set role \"$JOB_USER\"" -c "$JOB_CMD" >"$WORK/run.out" 2>&1; then
    same "it returns 1 (one row deleted)" "$(tr -d '[:space:]' <"$WORK/run.out")" "1"
else
    fail "running the command as $JOB_USER failed: $(cat "$WORK/run.out")"
fi
check "$U" "the row last touched 400 days and an hour ago is gone" \
    "not exists (select 1 from public.anonymous_installs where install_id = '00000000-0000-4000-8000-000000000401')"
check "$U" "the rows touched 400 days less an hour ago and today are kept" \
    "(select count(*) from public.anonymous_installs where install_id in ('00000000-0000-4000-8000-000000000399', '00000000-0000-4000-8000-000000000000')) = 2"

# What the comments say about a pruned install that reports again: the client
# re-sends every milestone it has latched, and the RPC's INSERT path stamps
# them all, and first_seen_at, with the same now().
q "$U" "select public.record_anonymous_install('00000000-0000-4000-8000-000000000401'::uuid, 'devid', '1.62.0', '26.1', true, true, false, null, false, false, false, false)" >/dev/null
check "$U" "a pruned install reporting again returns as a new row, every re-sent milestone stamped at its first_seen_at" \
    "exists (select 1 from public.anonymous_installs where install_id = '00000000-0000-4000-8000-000000000401' and first_seen_at > now() - interval '1 minute' and first_provider_detected_at = first_seen_at and helper_connected_at = first_seen_at and first_cost_at is null)"

# The header's ROLLBACK statement removes the job and nothing else.
if q "$U" "$ROLLBACK_SQL" >/dev/null 2>"$WORK/rb.err"; then
    check "$U" "ROLLBACK removes the job" "not exists (select 1 from cron.job where jobname = 'prune_anonymous_installs_nightly')"
    check "$U" "ROLLBACK leaves the eight other jobs" "($OTHER_JOBS_SQL) = '$JOBS_BEFORE'"
else
    fail "the header's ROLLBACK statement failed: $(cat "$WORK/rb.err")"
fi

# ═══ 2. an existing job of the same name and role ══════════════
echo "an existing prune_anonymous_installs_nightly (same role) with another schedule:"
newdb v088_existing; E="$DB"
setup "$E"
q "$E" "select cron.schedule('prune_anonymous_installs_nightly', '0 0 * * *', 'select 1')" >/dev/null
check "$E" "setup: the old job is there" \
    "exists (select 1 from cron.job where jobname = 'prune_anonymous_installs_nightly' and schedule = '0 0 * * *' and command = 'select 1')"
OLD_JOBID="$(q "$E" "$JOBID_SQL")"
if apply "$E" "$V088"; then pass "v0.88 applies"; else fail "v0.88 applies: $(cat "$WORK/apply.out")"; fi
check "$E" "one job, with v0.88's schedule and command" \
    "(select count(*) from cron.job where jobname = 'prune_anonymous_installs_nightly') = 1 and exists (select 1 from cron.job where jobname = 'prune_anonymous_installs_nightly' and schedule = '37 4 * * *' and command = 'select public.prune_anonymous_installs()')"
same "it is the same job (jobid kept)" "$(q "$E" "$JOBID_SQL")" "$OLD_JOBID"

# ═══ 3. guards and checks that must refuse ═════════════════════
# Each runs in its own database. "Nothing left behind" means: every cron.job
# row and all seven comments exactly as they were before the apply.
refuses() { # refuses <label> <db name> <setup sql, may be empty> <migration file> <expected error text>
    local label="$1" name="$2" pre="$3" file="$4" want="$5" url jobs comments has_cron
    newdb "$name"; url="$DB"
    setup "$url"
    if [[ -n "$pre" ]]; then
        psql "$url" -v ON_ERROR_STOP=1 -qtAX >/dev/null 2>"$WORK/pre.err" <<<"$pre" \
            || { fail "$label: setup failed: $(cat "$WORK/pre.err")"; return; }
    fi
    has_cron="$(q "$url" "select exists (select 1 from pg_namespace where nspname = 'cron')")"
    [[ "$has_cron" == "t" ]] && jobs="$(q "$url" "$ALL_JOBS_SQL")"
    comments="$(q "$url" "$SEVEN_COMMENTS_SQL")"
    if apply "$url" "$file"; then
        fail "$label: v0.88 APPLIED"
        return
    fi
    if grep -qF -- "$want" "$WORK/apply.out"; then
        pass "$label: refused ($want)"
    else
        fail "$label: refused for another reason: $(cat "$WORK/apply.out")"
    fi
    check "$url" "$label: all seven comments are unchanged" "($SEVEN_COMMENTS_SQL) = '$comments'"
    if [[ "$has_cron" == "t" ]]; then
        check "$url" "$label: cron.job is unchanged" "($ALL_JOBS_SQL) = '$jobs'"
    fi
}

stub_schedule() { # stub_schedule <insert column list> <insert values>: a cron.schedule that stores what it is told
    cat <<SQL
create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint language plpgsql as \$f\$
declare v bigint;
begin
    insert into cron.job ($1) values ($2) returning jobid into v;
    return v;
end \$f\$;
SQL
}

echo "guards (A):"
refuses "changed function body" v088_nc_body \
"create or replace function public.prune_anonymous_installs() returns integer language plpgsql security definer set search_path = public, pg_temp as \$f\$
declare v_deleted integer;
begin
    delete from public.anonymous_installs where last_seen_at < now() - interval '30 days';
    get diagnostics v_deleted = row_count;
    return v_deleted;
end;
\$f\$;" "$V088" "is not v0.73's body"

refuses "missing function" v088_nc_missing \
"drop function public.prune_anonymous_installs();" "$V088" "does not exist"

refuses "SECURITY INVOKER function" v088_nc_invoker \
"alter function public.prune_anonymous_installs() security invoker;" "$V088" "is not SECURITY DEFINER"

refuses "function without its pinned search_path" v088_nc_searchpath \
"alter function public.prune_anonymous_installs() reset search_path;" "$V088" "does not pin search_path=public, pg_temp"

refuses "function anon can execute" v088_nc_anon \
"grant execute on function public.prune_anonymous_installs() to anon;" "$V088" "anon or authenticated can execute"

refuses "function authenticated can execute" v088_nc_authenticated \
"grant execute on function public.prune_anonymous_installs() to authenticated;" "$V088" "anon or authenticated can execute"

refuses "no pg_cron" v088_nc_nocron \
"drop schema cron cascade;" "$V088" "pg_cron (cron.schedule) is not installed"

refuses "a job of that name owned by another role" v088_nc_otherrole \
"insert into cron.job (jobname, schedule, command, username) values ('prune_anonymous_installs_nightly', '0 0 * * *', 'select 1', 'service_role');" \
"$V088" "belongs to another role"

echo "verification (D):"
refuses "cron.schedule that silently does nothing" v088_nc_noop \
"create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as 'select 0::bigint';" \
"$V088" "expected one prune_anonymous_installs_nightly job, found 0"

refuses "cron.schedule that takes another job with it" v088_nc_collateral \
"create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint language plpgsql as \$f\$
declare v bigint;
begin
    delete from cron.job where jobname = 'widget_refresh_hourly';
    insert into cron.job (jobname, schedule, command) values (job_name, schedule, command) returning jobid into v;
    return v;
end \$f\$;" "$V088" "7 of the 8 existing cron jobs are unchanged"

refuses "cron.schedule that stores the job inactive" v088_nc_inactive \
"$(stub_schedule "jobname, schedule, command, active" "job_name, schedule, command, false")" \
"$V088" "is not scheduled as written"

refuses "cron.schedule that stores another schedule" v088_nc_schedule \
"$(stub_schedule "jobname, schedule, command" "job_name, '0 0 * * *', command")" \
"$V088" "is not scheduled as written"

refuses "cron.schedule that stores another command" v088_nc_command \
"$(stub_schedule "jobname, schedule, command" "job_name, schedule, 'select 1'")" \
"$V088" "is not scheduled as written"

refuses "cron.schedule that stores the job under a role that cannot execute the function" v088_nc_role \
"$(stub_schedule "jobname, schedule, command, username" "job_name, schedule, command, 'anon'")" \
"$V088" "is not scheduled as written"

touches_other() { # touches_other <sql changing widget_refresh_hourly>: a cron.schedule that does that, then schedules as pg_cron does
    cat <<SQL
create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint language plpgsql as \$f\$
declare v bigint;
begin
    $1
    insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
    on conflict (jobname, username) do update set schedule = excluded.schedule, command = excluded.command
    returning jobid into v;
    return v;
end \$f\$;
SQL
}
refuses "cron.schedule that changes another job's command" v088_nc_other_command \
"$(touches_other "update cron.job set command = 'select 1' where jobname = 'widget_refresh_hourly';")" \
"$V088" "7 of the 8 existing cron jobs are unchanged"
refuses "cron.schedule that changes another job's schedule" v088_nc_other_schedule \
"$(touches_other "update cron.job set schedule = '14 * * * *' where jobname = 'widget_refresh_hourly';")" \
"$V088" "7 of the 8 existing cron jobs are unchanged"
refuses "cron.schedule that deactivates another job" v088_nc_other_active \
"$(touches_other "update cron.job set active = false where jobname = 'widget_refresh_hourly';")" \
"$V088" "7 of the 8 existing cron jobs are unchanged"

# Copies of the migration without one `comment on` statement each: the
# checks in D must notice every one.
python3 - "$V088" "$WORK" <<'PY'
import sys
src = open(sys.argv[1]).read()
for tag, stmt in [
    ("table",      "comment on table public.anonymous_installs is"),
    ("column",     "comment on column public.anonymous_installs.last_seen_at is"),
    ("firstseen",  "comment on column public.anonymous_installs.first_seen_at is"),
    ("firstvalue", "comment on column public.anonymous_installs.first_provider_detected_at is"),
    ("funnel",     "comment on function public.anonymous_funnel_summary(integer) is"),
    ("activation", "comment on function public.anonymous_activation_summary(integer) is"),
    ("prune",      "comment on function public.prune_anonymous_installs() is"),
]:
    assert src.count(stmt) == 1, stmt
    i = src.index(stmt)
    j = src.index("';\n", i) + 3
    open(f"{sys.argv[2]}/v088_no_{tag}_comment.sql", "w").write(src[:i] + src[j:])
PY
refuses "no table comment statement"      v088_nc_c_table      "" "$WORK/v088_no_table_comment.sql"      "the table comment was not rewritten"
refuses "no last_seen_at comment statement" v088_nc_c_column   "" "$WORK/v088_no_column_comment.sql"     "the last_seen_at comment was not rewritten"
refuses "no first_seen_at comment statement" v088_nc_c_firstseen "" "$WORK/v088_no_firstseen_comment.sql" "the first_seen_at or first_provider_detected_at comment was not rewritten"
refuses "no first_provider_detected_at comment statement" v088_nc_c_firstvalue "" "$WORK/v088_no_firstvalue_comment.sql" "the first_seen_at or first_provider_detected_at comment was not rewritten"
refuses "no funnel summary comment statement" v088_nc_c_funnel "" "$WORK/v088_no_funnel_comment.sql"     "a function comment was not rewritten"
refuses "no activation summary comment statement" v088_nc_c_act "" "$WORK/v088_no_activation_comment.sql" "a function comment was not rewritten"
refuses "no prune function comment statement" v088_nc_c_prune  "" "$WORK/v088_no_prune_comment.sql"      "a function comment was not rewritten"

echo
if [[ $fails -eq 0 ]]; then
    echo "v0.88: all checks passed"
else
    echo "v0.88: $fails check(s) FAILED" >&2
    exit 1
fi

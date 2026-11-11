#!/usr/bin/env bash
# Verify migrate_v0.91 (the nightly cleanup also deletes webhook jobs that
# were finalized more than a day ago; a pending job is never deleted) against
# a real Postgres, on both install paths, and the ops check
# ops/check_webhook_jobs_retention.sql.
#
# Install paths:
#   upgrade  production's shape before v0.89: the current baseline files with
#            the webhook objects replaced by B0's frozen blocks
#            (tests/fixtures/webhook_baseline_b0/) WITHOUT their comment-only
#            lines (the worker's md5 is production's, 7e7c1040…), the cleanup
#            put back to v0.87's body cut from its migration (production's
#            md5, 119e431b…), Supabase's service_role grants, and a pg_cron
#            stand-in holding the nightly cleanup job (active) and the
#            webhook job (paused); then v0.89, as production will have it
#            first (the webhook job then restored); then v0.91, then v0.91
#            again.
#   fresh    schema.sql + app_rpc.sql + helper_rpc.sql as they are (v0.91's
#            cleanup and the table comment), then v0.91 (changes nothing).
# The refusals run on the upgrade database, with v0.89 and without it.
#
# The fixture is inserted in the SAME transaction as the cleanup call, so
# now() is one instant for both: a job finalized exactly now() - 1 day is on
# the boundary, not a few milliseconds past it.
#
# What this proves:
#   0. md5 values: v0.87's cleanup cut from its file is production's measured
#      body (and without its comment-only lines it is not); v0.91's from
#      between this migration's BEGIN/END cleanup markers, raw and stripped,
#      and v0.89's worker, raw and stripped, are the header's values and
#      exactly the guard's, the verification's and the ops check's; the fresh
#      app_rpc.sql installs v0.91's body; the webhook block is the last block
#      (static, on the migration and on app_rpc.sql).
#   1. CONTROL, v0.87's body after v0.89: nothing is deleted from
#      webhook_jobs, and the answer has no webhook_jobs_deleted.
#   2. upgrade apply, through the header's statements as printed: Q0 (hashes
#      and booleans only) before and after, G1 (counts only), G2, G3, Q3,
#      Q3b, DRY, R0, Q6, P9 and RB; the header's expected acl_md5 and
#      table_comment_md5 are the real ones; the catalog fingerprint
#      (ops/check_webhook_catalog.sql) moves only in the cleanup's md5 and
#      the table's comment; the contract (SECURITY DEFINER, search_path,
#      signature, grants); applied twice; the rollback (R0 + RB) restores
#      step 0's Q0 exactly.
#   3. behaviour, on both paths, the fixture of the plan: finalized 25 h ago,
#      a failure 2 days ago, and a job of an account whose retention is 0
#      (deleted); finalized 23 h ago, exactly a day ago, and 1 h ago though
#      enqueued 3 days ago (kept); pending 3 days old, pending with its
#      attempts used up, pending and fresh, and the jobs the fixture's alerts
#      enqueue (kept); the answer's webhook_jobs_deleted equals DRY (and G1's
#      eligible); a second run deletes nothing; the other three tables are
#      cleaned as in v0.87; after a run the caller's lock_timeout is the
#      block's 5 s (why the block stays last).
#      Failure and recovery: (a) a DELETE that fails (a trigger raising):
#      errors = 1, webhook_jobs named, a WARNING, nothing of it deleted, the
#      other three tables cleaned, and the next run takes the whole backlog;
#      (b) a row locked by another session: the block gives up at 5 s
#      (lock_timeout), the others are cleaned, and after the release the next
#      run deletes it; (c) why there is no statement_timeout in the block: one
#      set inside a function does not stop the statement already running it,
#      and one that does fire is not caught by WHEN OTHERS: a slow webhook
#      DELETE under it cancels the whole cleanup, the other tables with it;
#      (d) an alert inserted (500 ms limit) while the nightly DELETE's
#      transaction holds its locks goes on, its pending job enqueued; (e) the
#      block's lock_timeout is 5 s inside the caller's transaction and the
#      session's own value again after the commit.
#   4. re-runs: accepted over v0.87's body, over v0.91 raw and over v0.91
#      without its comment-only lines (a client that strips them), in every
#      order.
#   5. guards: each refuses and changes nothing (cleanup, worker, rows,
#      comment, cron jobs): no v0.89 (v0.25's worker, or none), no table,
#      processed_at of another type, a foreign body (v0.87's stripped; one
#      naming v0.91), a second function of that name or an overload,
#      SECURITY INVOKER, another search_path, EXECUTE for authenticated, for
#      PUBLIC, or reaching anon through an inherited role, an applier that is
#      neither owner nor member, the nightly job missing, inactive, with
#      another command or schedule, a second job calling the cleanup, the name
#      on another job than the caller, a job user that cannot execute it or
#      does not exist; a session holding the cleanup's catalog row, and one
#      holding SHARE UPDATE EXCLUSIVE on the queue (an autovacuum's lock),
#      make it give up at lock_timeout. An applier that is a member of the
#      owner role applies. While the apply is open an alert insert (its job
#      enqueued) and a cleanup call go on without waiting. An apply made to
#      run past the 2 s budget is stopped with nothing changed
#      (transaction_timeout on PostgreSQL 17; the pre-17 branch forced).
#   5b. Q3c, as printed: settings only; each source of a timeout in its
#      column (the job user's, in its database, the database's, the server's
#      with its source).
#   6. the ops check, run as it stands: no rows on a healthy database; each
#      problem made in a rolled-back transaction is named (job missing,
#      inactive, command or schedule changed, cleanup changed, no run, last
#      run failed, no run in 26 h, a job finalized 50 h ago but not one 48 h
#      ago, a pending job over a day old, a stuck pending job); a webhook
#      DELETE that failed inside a run that "succeeded" shows up as overdue;
#      APPLY step 5's sequence (overdue before the first run, nothing after);
#      a changed command and a failed run's message holding synthetic secret
#      text are named by md5 and a fixed text, the text nowhere in the
#      output; the private investigation query I1 runs as printed; without
#      the cron schema the check fails, as its header says.
#   7. negative controls: mutants of the cleanup cut from between the markers
#      and applied directly to a throwaway database (bypassing the guards),
#      and a copy of the migration without its v0.89 guard, must each fail
#      the assertion named for them (including a DELETE that takes a lock
#      blocking writers, set_config(..., false), and the ops check printing
#      the raw command or message); the unmutated cut passes them all.
#
# Usage (creates and drops its own b2_<pid>_* databases and roles there):
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres \
#     ./backend/supabase/tests/run_v091_prune_webhook_jobs_tests.sh
# Run it as a superuser (it creates roles and stand-in schemas).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$(cd "$HERE/.." && pwd)"
SHIM="$HERE/rls/00_supabase_shim.sql"
FROZEN="$HERE/fixtures/webhook_baseline_b0"
V087="$SQL_DIR/migrate_v0.87_retention_cleanup_and_fresh_counts.sql"
V089="$SQL_DIR/migrate_v0.89_webhook_jobs_finalize_failures.sql"
V091="$SQL_DIR/migrate_v0.91_prune_webhook_jobs.sql"
OPS="$SQL_DIR/ops/check_webhook_jobs_retention.sql"
CATALOG="$SQL_DIR/ops/check_webhook_catalog.sql"

# Measured in production by B0's catalog check (2026-11-12).
PROD_WORKER25_MD5=7e7c1040479aa3f0879cbb1b99911c21
PROD_CLEANUP_MD5=119e431b2b0f5c95f52a611e6dd14ac6

UA='b2000000-b200-4b20-8b20-00000000000a'   # retention 7 days (the default)
UC='b2000000-b200-4b20-8b20-00000000000c'   # retention 0: keeps its sessions and alerts

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to a database on a disposable server" >&2
    exit 2
fi
for f in "$SHIM" "$FROZEN/schema_block.sql" "$FROZEN/app_rpc_block.sql" "$V087" "$V089" "$V091" "$OPS" "$CATALOG" \
         "$SQL_DIR/schema.sql" "$SQL_DIR/app_rpc.sql" "$SQL_DIR/helper_rpc.sql"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done
command -v perl >/dev/null || { echo "perl is needed for the negative controls" >&2; exit 2; }

BASE="${DATABASE_URL%/*}"
PFX="b2_$$"
WORK="$(mktemp -d)"
CREATED=()
BGPIDS=()
STRANGER="${PFX}_stranger"
MEMBER="${PFX}_member"
CARRIER="${PFX}_carrier"   # holds EXECUTE on the cleanup; anon inherits it in one guard case
cleanup() { # best-effort: every step runs, failures only warn, the exit status is the script's own
    set +e
    local p d r
    for p in "${BGPIDS[@]:-}" $(cat "$WORK/bgpids" 2>/dev/null); do [[ -n "$p" ]] && kill "$p" >/dev/null 2>&1; done
    for d in "${CREATED[@]:-}" $(cat "$WORK/created" 2>/dev/null); do
        [[ -n "$d" ]] || continue
        PGOPTIONS='-c client_min_messages=warning' psql "$DATABASE_URL" -qtAX -c "drop database if exists $d with (force)" >/dev/null 2>&1 \
            || echo "warning: could not drop database $d (drop it by hand)" >&2
    done
    for r in "$STRANGER" "$MEMBER" "$CARRIER"; do
        PGOPTIONS='-c client_min_messages=warning' psql "$DATABASE_URL" -qtAX -c "drop role if exists $r" >/dev/null 2>&1 \
            || echo "warning: could not drop role $r (drop it by hand)" >&2
    done
    wait >/dev/null 2>&1
    /bin/rm -rf "$WORK" || echo "warning: could not remove $WORK" >&2
}
trap cleanup EXIT

export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
fails=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }
same() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi; }

DB=""
newdb() { # newdb <name> [template]: sets DB to its URL
    psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 \
        -c "drop database if exists $1 with (force)" -c "create database $1${2:+ template $2}" >/dev/null \
        || { echo "cannot create database $1" >&2; exit 2; }
    CREATED+=("$1"); echo "$1" >> "$WORK/created"
    DB="$BASE/$1"
}
dropdb_now() { psql "$DATABASE_URL" -qtAX -c "drop database if exists $1 with (force)" >/dev/null 2>&1 || true; }
q() { psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX "$@"; }
apply() { q -f "$1" >/dev/null; }
check() { # check <label> <sql returning boolean>
    local got; got="$(q -c "select ($2)::text" 2>&1)" || true
    if [[ "$got" == "true" ]]; then pass "$1"; else fail "$1  (got '$got')"; fi
}
# migrate <file> [role]: apply a migration as the superuser (or after SET ROLE
# <role>), notices on; prints everything psql said; psql's status is returned.
migrate() {
    local pre=()
    [[ -n "${2:-}" ]] && pre=(-c "set role $2")
    PGOPTIONS='-c client_min_messages=notice' psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX ${pre[@]+"${pre[@]}"} -f "$1" 2>&1
}
wait_for() { # wait_for <sql returning boolean>: up to 15 s
    local i
    for i in $(seq 1 150); do
        [[ "$(q -c "select ($1)::text" 2>/dev/null)" == "true" ]] && return 0
        sleep 0.1
    done
    echo "timed out waiting for: $1" >&2
    exit 2
}
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }
BGPID=""
run_bg_to() { # run_bg_to <output file> <command...>
    local o="$1"; shift
    "$@" > "$o" 2>&1 &
    BGPID=$!; BGPIDS+=("$BGPID"); echo "$BGPID" >> "$WORK/bgpids"
}
sleeping() { # sleeping <statement>: another session is running it
    echo "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'active' and query like '$1%' and wait_event = 'PgSleep')"
}
end_sleepers() {
    q -c "select pg_terminate_backend(pid) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query like '%pg_sleep(%'" >/dev/null
}

# ── extraction from the files: loud, never silent ──────────────────────────
# between <file> <name>: the lines strictly between "-- BEGIN <name>" and
# "-- END <name>"; exactly one pair, BEGIN first, or the suite stops.
between() {
    local f="$1" n="$2" nb ne lb le
    nb="$(grep -c -x -- "-- BEGIN $n" "$f" || true)"; ne="$(grep -c -x -- "-- END $n" "$f" || true)"
    [[ "$nb" == 1 && "$ne" == 1 ]] \
        || { echo "markers: $(basename "$f"): want one '-- BEGIN $n' and one '-- END $n', found $nb and $ne" >&2; exit 2; }
    lb="$(grep -n -x -- "-- BEGIN $n" "$f" | cut -d: -f1)"; le="$(grep -n -x -- "-- END $n" "$f" | cut -d: -f1)"
    (( le > lb + 1 )) || { echo "markers: $(basename "$f"): '-- END $n' does not follow '-- BEGIN $n'" >&2; exit 2; }
    sed -n "$((lb + 1)),$((le - 1))p" "$f"
}
# hq <label>: that APPLY line of the header, exactly as printed.
hq() {
    local n; n="$(grep -c -E "^-- +$1: " "$V091" || true)"
    [[ "$n" == 1 ]] || { echo "header: want one '$1:' line, found $n" >&2; exit 2; }
    sed -n -E "s/^-- +$1: //p" "$V091"
}
strip_comment_lines() { sed '/^[[:space:]]*--/d' "$1"; }
# cut_fn <file> <out>: the CREATE of _cleanup_expired_data_internal(), from its
# first line to its language line; exactly one, or the suite stops
cut_fn() {
    local n; n="$(grep -c -x 'create or replace function public._cleanup_expired_data_internal()' "$1" || true)"
    [[ "$n" == 1 ]] || { echo "$(basename "$1"): want one cleanup CREATE line, found $n" >&2; exit 2; }
    sed -n '/^create or replace function public\._cleanup_expired_data_internal()$/,/^\$\$ language plpgsql security definer set search_path = pg_catalog, public, extensions;$/p' "$1" > "$2"
    tail -n 1 "$2" | grep -q '^\$\$ language plpgsql' || { echo "$(basename "$1"): the cleanup cut does not end on its language line" >&2; exit 2; }
}

# mutate <src> <dst> <count> <perl regex> <replacement>: replace every match,
# and there must be exactly <count>, or the suite stops (a control that
# mutates nothing proves nothing).
mutate() {
    MUT_RE="$4" MUT_TO="$5" MUT_N="$3" perl -0777 -e '
        my $t = do { local $/; <STDIN> };
        my ($re, $to, $want) = ($ENV{MUT_RE}, $ENV{MUT_TO}, $ENV{MUT_N});
        my $n = () = $t =~ /$re/g;
        if ($n != $want) { print STDERR "mutation matched $n times, want $want: $re\n"; exit 3 }
        $t =~ s/$re/$to/g;
        print $t;' < "$1" > "$2" || { echo "control setup failed" >&2; exit 2; }
    if cmp -s "$1" "$2"; then echo "mutation changed nothing: $4" >&2; exit 2; fi
}

# position_check <file holding the cleanup>: "ok" when the webhook block is the
# last of the four and its set_config sits inside it; otherwise what is wrong
position_check() {
    local f="$1" order pa wh sc after
    order="$(grep -oE 'delete from public\.[a-z_]+' "$f" | sed 's/delete from public\.//' | paste -sd' ' -)"
    [[ "$order" == "sessions alerts pairing_attempt_log webhook_jobs" ]] || { echo "the DELETEs run in the order: $order"; return 0; }
    pa="$(grep -n 'delete from public\.pairing_attempt_log' "$f" | cut -d: -f1)"
    wh="$(grep -n 'delete from public\.webhook_jobs' "$f" | cut -d: -f1)"
    sc="$(grep -n "set_config('lock_timeout'" "$f" | cut -d: -f1 | paste -sd' ' -)"
    if ! [[ "$sc" =~ ^[0-9]+$ ]] || (( sc < pa || sc > wh )); then
        echo "set_config('lock_timeout') at line(s) '$sc', the pairing DELETE at $pa, the webhook DELETE at $wh"; return 0
    fi
    after="$(awk -v w="$wh" 'NR > w && /^  begin$/' "$f" | wc -l | tr -d ' ')"
    (( after == 0 )) || { echo "$after block(s) after the webhook block"; return 0; }
    grep -q -- '-- KEEP THIS BLOCK LAST' "$f" || { echo "no KEEP THIS BLOCK LAST comment"; return 0; }
    echo ok
}

# ── stand-ins and fixtures ──────────────────────────────────────────────────
cat > "$WORK/stubs.sql" <<'SQL'
-- pg_cron (1.6): cron.job, cron.job_run_details and alter_job with pg_cron's
-- parameter names; the nightly cleanup job (active, as production runs it)
-- and the webhook job (paused, so that v0.89 applies; restored after it).
create schema if not exists cron;
create table cron.job (
  jobid bigserial primary key,
  schedule text not null,
  command text not null,
  nodename text not null default 'localhost',
  nodeport integer not null default 5432,
  database text not null default current_database(),
  username text not null default current_user,
  active boolean not null default true,
  jobname text
);
create table cron.job_run_details (
  jobid bigint, runid bigserial primary key, job_pid integer, database text, username text,
  command text, status text, return_message text, start_time timestamptz, end_time timestamptz
);
create function cron.alter_job(
  job_id bigint,
  schedule text default null,
  command text default null,
  database text default null,
  username text default null,
  active boolean default null
) returns void language plpgsql as $$
begin
  update cron.job j
     set schedule = coalesce(alter_job.schedule, j.schedule),
         command  = coalesce(alter_job.command, j.command),
         database = coalesce(alter_job.database, j.database),
         username = coalesce(alter_job.username, j.username),
         active   = coalesce(alter_job.active, j.active)
   where j.jobid = alter_job.job_id;
  if not found then
    raise exception 'Job % does not exist', alter_job.job_id;
  end if;
end $$;
insert into cron.job (jobid, jobname, schedule, command, active) values
  (1, 'cleanup_expired_data_nightly', '7 3 * * *', 'SELECT public._cleanup_expired_data_internal();', true),
  (3, 'process_webhook_jobs', '30 seconds', 'select public.process_webhook_jobs()', false);
select setval('cron.job_jobid_seq', 3);
insert into cron.job_run_details (jobid, status, return_message, start_time, end_time) values
  (1, 'succeeded', '1 row', now() - interval '20 hours', now() - interval '20 hours');

-- the suite's own probes, outside public
create schema b2t;
create function b2t.snapshot() returns text language plpgsql as $$
declare
  r text;
  x text;
begin
  select coalesce(string_agg(format('%s|%s|%s|%s|%s|%s', p.oid::regprocedure, md5(p.prosrc), p.prosecdef,
                                    p.proconfig, p.proacl, pg_get_userbyid(p.proowner)), ';'
                             order by p.oid::regprocedure::text), 'no cleanup')
    into r from pg_proc p where p.proname = '_cleanup_expired_data_internal';
  r := r || '#worker=' || coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('public.process_webhook_jobs()')), 'none');
  if to_regclass('public.webhook_jobs') is not null then
    execute 'select coalesce(md5(string_agg(t::text, ''|'' order by t.id)), ''empty'') from public.webhook_jobs t' into x;
    r := r || '#rows=' || x || '#comment=' || coalesce(md5(obj_description('public.webhook_jobs'::regclass, 'pg_class')), 'none');
  end if;
  execute 'select string_agg(j::text, ''|'' order by j.jobid) from cron.job j' into x;
  return r || '#cron=' || coalesce(x, 'none');
end $$;
SQL

cat > "$WORK/users.sql" <<SQL
insert into auth.users (id, email) values ('$UA', 'a@test.local'), ('$UC', 'c@test.local');
update public.user_settings set data_retention_days = 0 where user_id = '$UC';
SQL

# v0.87's cleanup, as production runs it, with v0.21's revoke and Supabase's
# service_role grant (B0's catalog check: {postgres, service_role})
cut_fn "$V087" "$WORK/cleanup87.sql"
cp "$WORK/cleanup87.sql" "$WORK/cleanup87.prod.sql"
cat >> "$WORK/cleanup87.prod.sql" <<'SQL'
revoke all on function public._cleanup_expired_data_internal() from public, anon, authenticated;
grant execute on function public._cleanup_expired_data_internal() to service_role;
SQL

# The upgrade path's database before v0.89: production's shape today.
build_upgrade_base() {
    apply "$SHIM"; apply "$SQL_DIR/schema.sql"; apply "$SQL_DIR/app_rpc.sql"; apply "$SQL_DIR/helper_rpc.sql"
    q >/dev/null <<'SQL'
drop trigger if exists alerts_webhook_enqueue on public.alerts;
drop function if exists public.alerts_enqueue_webhook();
drop function if exists public.process_webhook_jobs();
drop table if exists public.webhook_jobs;
SQL
    strip_comment_lines "$FROZEN/schema_block.sql" > "$WORK/schema_block.prod.sql"
    strip_comment_lines "$FROZEN/app_rpc_block.sql" > "$WORK/app_rpc_block.prod.sql"
    apply "$WORK/schema_block.prod.sql"; apply "$WORK/app_rpc_block.prod.sql"
    q -c "grant execute on function public.process_webhook_jobs() to service_role" >/dev/null
    apply "$WORK/cleanup87.prod.sql"
    apply "$WORK/stubs.sql"; apply "$WORK/users.sql"
}
build_fresh() {
    apply "$SHIM"; apply "$SQL_DIR/schema.sql"; apply "$SQL_DIR/app_rpc.sql"; apply "$SQL_DIR/helper_rpc.sql"
    apply "$WORK/stubs.sql"; apply "$WORK/users.sql"
}

refuses() { # refuses <label> <regex of the refusal> [role]: apply $MIG; it must fail on it and change nothing
    local before after out rc=0
    before="$(q -c "select b2t.snapshot()")"
    out="$(migrate "$MIG" "${3:-}")" || rc=$?
    after="$(q -c "select b2t.snapshot()")"
    if (( rc == 0 )); then fail "$1: the migration applied"
    elif ! grep -q -E -- "$2" <<<"$out"; then fail "$1: refused, but not by /$2/: $(grep -m1 -E 'ERROR|FATAL' <<<"$out")"
    elif [[ "$before" != "$after" ]]; then fail "$1: refused, but something changed"
    else pass "$1"; fi
}
LAST_OUT=""
applies() { # applies <label> [role]: apply $MIG; it must succeed; keeps its output in LAST_OUT
    local rc=0
    LAST_OUT="$(migrate "$MIG" "${2:-}")" || rc=$?
    if (( rc == 0 )); then pass "$1"; else fail "$1: $(grep -m1 -E 'ERROR|FATAL' <<<"$LAST_OUT")"; fi
}
MIG="$V091"
q0() { q -c "$(hq Q0)"; }
cleanup_md5() { q -c "select md5(prosrc) from pg_proc where oid = 'public._cleanup_expired_data_internal()'::regprocedure"; }
worker_md5() { q -c "select md5(prosrc) from pg_proc where oid = to_regprocedure('public.process_webhook_jobs()')"; }
notice() { grep -E 'NOTICE: +v0\.91: ' <<<"$1" | sed -E 's/.*NOTICE: +v0\.91: //' | paste -sd'|' -; }
ops() { q -f "$OPS" | cut -d'|' -f1 | paste -sd',' -; }
OPS_UNDER_TEST=""
# ops_secret_case: a changed command and a failed run's message, both holding
# synthetic secret text; the check names both problems without printing it
ops_secret_case() {
    local cmd="SELECT public._cleanup_expired_data_internal(); -- b2-SYNTHETIC-SECRET-cmd" out
    out="$(q <<SQL
begin;
update cron.job set command = '$cmd' where jobid = 1;
insert into cron.job_run_details (jobid, status, return_message, start_time)
values (1, 'failed', 'ERROR: b2-SYNTHETIC-SECRET-msg, a value quoted from a row', null);
\i '${OPS_UNDER_TEST:-$OPS}'
rollback;
SQL
)" || true
    same "$P a changed command and a failed run's message holding synthetic secret text: named by the command's md5 and a fixed text, no secret text in the output" \
         "$(grep -c 'SYNTHETIC-SECRET' <<<"$out" || true) / $(paste -sd',' - <<<"$out")" \
         "0 / job command changed|command md5 $(q -c "select md5('$cmd')"),last run failed|status failed (its message: PRIVATE INVESTIGATION I1)"
}
ops_with() { # ops_with <sql run first, in a transaction rolled back after>: the problems named
    q <<SQL | cut -d'|' -f1 | paste -sd',' -
begin;
$1
\i '$OPS'
rollback;
SQL
}

SU="$(psql "$DATABASE_URL" -qtAX -c 'select current_user')"
SVN="$(psql "$DATABASE_URL" -qtAX -c 'show server_version_num')"

# =============================================================================
echo "== 0. md5 values (the header's, the guard's and the ops check's, against the files)"
newdb "${PFX}_md5"; apply "$SHIM"
fn_md5() { # fn_md5 <file holding a CREATE of the function> <regprocedure>
    q -c "drop function if exists $2" >/dev/null
    apply "$1"
    q -c "select md5(prosrc) from pg_proc where oid = '$2'::regprocedure"
}
CL='public._cleanup_expired_data_internal()'
strip_comment_lines "$WORK/cleanup87.sql" > "$WORK/cleanup87.stripped.sql"
between "$V091" cleanup > "$WORK/cleanup91.sql"
grep -q '^create or replace function public\._cleanup_expired_data_internal()$' "$WORK/cleanup91.sql" \
    || { echo "the cleanup markers do not hold the cleanup" >&2; exit 2; }
strip_comment_lines "$WORK/cleanup91.sql" > "$WORK/cleanup91.stripped.sql"
between "$V089" worker > "$WORK/worker89.sql"
strip_comment_lines "$WORK/worker89.sql" > "$WORK/worker89.stripped.sql"
cut_fn "$SQL_DIR/app_rpc.sql" "$WORK/cleanup.baseline.sql"
FILES87="$(fn_md5 "$WORK/cleanup87.sql" "$CL")"
STRIP87="$(fn_md5 "$WORK/cleanup87.stripped.sql" "$CL")"
RAW91="$(fn_md5 "$WORK/cleanup91.sql" "$CL")"
STRIP91="$(fn_md5 "$WORK/cleanup91.stripped.sql" "$CL")"
BASE91="$(fn_md5 "$WORK/cleanup.baseline.sql" "$CL")"
RAW89="$(fn_md5 "$WORK/worker89.sql" 'public.process_webhook_jobs()')"
STRIP89="$(fn_md5 "$WORK/worker89.stripped.sql" 'public.process_webhook_jobs()')"
same "0. v0.87's cleanup as its file has it is production's measured body (no comment stripping for this function)" "$FILES87" "$PROD_CLEANUP_MD5"
if [[ "$STRIP87" != "$PROD_CLEANUP_MD5" ]]; then pass "0. v0.87's cleanup without its comment-only lines is NOT production's ($STRIP87)"
else fail "0. v0.87's stripped and raw bodies are equal: the header's claim is wrong"; fi
same "0. the header names that stripped body as the one not installed" \
     "$(grep -oE "v0\.87's body without them \([0-9a-f]{32}\)" "$V091" | grep -oE '[0-9a-f]{32}')" "$STRIP87"
if [[ "$RAW91" != "$STRIP91" ]]; then pass "0. v0.91's body has comment-only lines, so its two forms differ and both are listed"
else fail "0. v0.91's raw and stripped bodies are equal: the header's two 'after' values would be one"; fi
same "0. the fresh app_rpc.sql's cleanup is v0.91's body, byte for byte" "$BASE91" "$RAW91"
same "0. the header's cleanup MD5 VALUES are v0.87's, v0.91's raw and stripped, in order" \
     "$(grep -E '^--   (before|after) +v0\.(87|91), ' "$V091" | grep -oE '[0-9a-f]{32}$' | paste -sd' ' -)" \
     "$PROD_CLEANUP_MD5 $RAW91 $STRIP91"
same "0. the header's worker values are v0.89's raw and stripped (v0.89's own header lists the same)" \
     "$(grep -E '^--   v0\.89, ' "$V091" | grep -oE '[0-9a-f]{32}$' | paste -sd' ' -)" "$RAW89 $STRIP89"
same "0. the md5 literals in the migration's code are exactly those five" \
     "$(sed -n '/^begin;$/,$p' "$V091" | grep -oE "'[0-9a-f]{32}'" | tr -d "'" | sort -u | paste -sd' ' -)" \
     "$(printf '%s\n' "$PROD_CLEANUP_MD5" "$RAW91" "$STRIP91" "$RAW89" "$STRIP89" | sort -u | paste -sd' ' -)"
same "0. the guard (A3, A5) lists all five" \
     "$(sed -n '/^do \$guard\$$/,/^\$guard\$;$/p' "$V091" | grep -oE "'[0-9a-f]{32}'" | tr -d "'" | sort | paste -sd' ' -)" \
     "$(printf '%s\n' "$PROD_CLEANUP_MD5" "$RAW91" "$STRIP91" "$RAW89" "$STRIP89" | sort | paste -sd' ' -)"
same "0. the verification (D) lists the two 'after' values only" \
     "$(sed -n '/^do \$verify\$$/,/^\$verify\$;$/p' "$V091" | grep -oE "'[0-9a-f]{32}'" | tr -d "'" | sort | paste -sd' ' -)" \
     "$(printf '%s\n' "$RAW91" "$STRIP91" | sort | paste -sd' ' -)"
same "0. the ops check accepts the two v0.91 values only" \
     "$(grep -oE "'[0-9a-f]{32}'" "$OPS" | tr -d "'" | sort | paste -sd' ' -)" \
     "$(printf '%s\n' "$RAW91" "$STRIP91" | sort | paste -sd' ' -)"
same "0. step 0 (Q0) expects production's body on a first apply" \
     "$(grep -c -E "^--    FIRST APPLY: expect body_md5 = $PROD_CLEANUP_MD5,$" "$V091")" "1"
HDR="$(sed -n '1,/^begin;$/p' "$V091" | sed -E 's/^-- ?//' | tr '\n' ' ' | tr -s ' ')"
if [[ "$HDR" == *"RE-RUN OR RECOVERY: body_md5 = $RAW91 or $STRIP91 "* ]]; then pass "0. step 0 accepts the two v0.91 bodies on a re-run or in recovery"
else fail "0. step 0's RE-RUN OR RECOVERY line does not list $RAW91 and $STRIP91"; fi
if [[ "$HDR" == *"worker_md5 = $RAW89 or $STRIP89 "* ]]; then pass "0. step 0 expects v0.89's worker (either form)"
else fail "0. step 0 does not expect v0.89's worker as $RAW89 or $STRIP89"; fi
same "0. static: the webhook block is the last of the four in the migration (its set_config inside it)" "$(position_check "$WORK/cleanup91.sql")" "ok"
same "0. static: and in app_rpc.sql" "$(position_check "$WORK/cleanup.baseline.sql")" "ok"
same "0. static: no code line of the cleanup sets a statement_timeout (header B; only a comment names it)" \
     "$(strip_comment_lines "$WORK/cleanup91.sql" | grep -c 'statement_timeout' || true)" "0"
held="$(grep -c -x 'commit;' "$V091" || true)"
[[ "$held" == 1 ]] || { echo "the migration must end with exactly one 'commit;' line (found $held)" >&2; exit 2; }
dropdb_now "${PFX}_md5"

# =============================================================================
# The fixture of the plan, inserted in the caller's transaction (now() fixed).
# Job alert_ids say what must happen: wj-del-* go, wj-keep-* stay; the two
# al-* jobs are the ones the fixture's alerts enqueue (pending: they stay).
read -r -d '' FIXTURE_SQL <<SQL || true
insert into public.sessions (id, user_id, provider, status, started_at, last_active_at) values
  ('s-old', '$UA', 'Codex', 'Ended', now() - interval '10 days 1 hour', now() - interval '10 days'),
  ('s-new', '$UA', 'Codex', 'Ended', now() - interval '1 day 1 hour', now() - interval '1 day');
insert into public.alerts (id, user_id, type, title, grouping_key, created_at) values
  ('al-old', '$UA', 'Usage Spike', 'old', 'g-al-old', now() - interval '10 days'),
  ('al-new', '$UA', 'Usage Spike', 'new', 'g-al-new', now() - interval '1 day');
insert into public.pairing_attempt_log (ip_addr, attempted_at) values
  ('192.0.2.1', now() - interval '2 hours'), ('192.0.2.2', now() - interval '10 minutes');
insert into public.webhook_jobs (user_id, alert_id, alert_payload, enqueued_at, dispatched_at, processed_at, attempt_count, pg_net_request_id, last_error) values
  ('$UA', 'wj-del-25h',                 '{"grouping_key":"k1"}', now() - interval '25 hours 1 minute', now() - interval '25 hours 1 minute', now() - interval '25 hours', 1, 101, null),
  ('$UA', 'wj-del-failed-2d',           '{"grouping_key":"k2"}', now() - interval '2 days 10 minutes', null, now() - interval '2 days', 4, null, 'HTTP 502: x'),
  ('$UC', 'wj-del-keepall',             '{"grouping_key":"k3"}', now() - interval '30 days 1 minute', now() - interval '30 days 1 minute', now() - interval '30 days', 1, 103, null),
  ('$UA', 'wj-keep-23h',                '{"grouping_key":"k4"}', now() - interval '23 hours 1 minute', now() - interval '23 hours 1 minute', now() - interval '23 hours', 1, 104, null),
  ('$UA', 'wj-keep-boundary',           '{"grouping_key":"k5"}', now() - interval '1 day 1 minute', now() - interval '1 day 1 minute', now() - interval '1 day', 1, 105, null),
  ('$UA', 'wj-keep-recent-old-enqueue', '{"grouping_key":"k6"}', now() - interval '3 days', now() - interval '1 hour 1 minute', now() - interval '1 hour', 3, 106, null),
  ('$UA', 'wj-keep-pending-3d',         '{"grouping_key":"k7"}', now() - interval '3 days', now() - interval '3 days', null, 1, 107, null),
  ('$UA', 'wj-keep-pending-stuck',      '{"grouping_key":"k8"}', now() - interval '2 days', null, null, 4, null, 'HTTP 502: y'),
  ('$UA', 'wj-keep-pending-fresh',      '{"grouping_key":"k9"}', now(), null, null, 0, null, null);
SQL
ANSWER="format('%s|%s|%s|%s|%s|%s', r->>'webhook_jobs_deleted', r->>'sessions_deleted', r->>'alerts_deleted', r->>'pairing_attempt_log_deleted', r->>'errors', r->'failed')"
LEFT3="(select count(*) from public.sessions) || '/' || (select count(*) from public.alerts) || '/' || (select count(*) from public.pairing_attempt_log)"
jobs_in() { echo "(select count(*) from public.webhook_jobs where alert_id in ($1))"; }
DEL_IDS="'wj-del-25h', 'wj-del-failed-2d', 'wj-del-keepall'"
RECENT_IDS="'wj-keep-23h', 'wj-keep-recent-old-enqueue'"
PENDING_IDS="'wj-keep-pending-3d', 'wj-keep-pending-stuck', 'wj-keep-pending-fresh', 'al-old', 'al-new'"
# txn <sql>: run it in one transaction, rolled back; stdout is what it selects,
# stderr goes to $WORK/txn.err
txn() {
    q 2>"$WORK/txn.err" <<SQL
begin;
$1
rollback;
SQL
}
val() { sed -n "s/^$1=//p" <<<"$TXN_OUT" | head -1; }
TXN_OUT=""
prune_txn() { # the fixture, then two runs, in one transaction
    TXN_OUT="$(txn "
$FIXTURE_SQL
select 'before=' || (select count(*) from public.webhook_jobs) || '/' || $LEFT3;
select 'dry=' || ($(hq DRY | sed 's/;$//'));
select 'g1=' || (select eligible from ($(hq G1 | sed 's/;$//')) g);
select 'first=' || $ANSWER from (select public._cleanup_expired_data_internal() as r) s;
select 'lt=' || current_setting('lock_timeout');
select 'gone=' || $(jobs_in "$DEL_IDS");
select 'recent=' || $(jobs_in "$RECENT_IDS");
select 'boundary=' || $(jobs_in "'wj-keep-boundary'");
select 'pending=' || (select count(*) from public.webhook_jobs where alert_id in ($PENDING_IDS) and processed_at is null);
select 'left=' || $LEFT3;
select 'second=' || $ANSWER from (select public._cleanup_expired_data_internal() as r) s;
")" || true
}

# ── behavioural cases (P set by the caller) ─────────────────────────────────
P=""
case_prune() {
    prune_txn
    same "$P before the run: the 9 fixture jobs, the alerts' 2, and the other tables' rows" "$(val before)" "11/2/2/2"
    same "$P DRY (as printed) counts the three eligible jobs, and G1's eligible agrees" "$(val dry)/$(val g1)" "3/3"
    same "$P finalized more than a day ago: deleted (25 h; a failure 2 days old; an account whose retention is 0)" "$(val gone)" "0"
    same "$P recent finalized kept (23 h; 1 h, though enqueued 3 days ago)" "$(val recent)" "2"
    same "$P exactly a day: kept (the cut is <, not <=)" "$(val boundary)" "1"
    same "$P pending never deleted (3 days old; attempts used up; fresh; the alerts' own jobs)" "$(val pending)" "5"
    same "$P its answer: webhook_jobs_deleted is DRY's count; the other three tables cleaned as in v0.87; no error" \
         "$(val first)" "$(val dry)|1|1|1|0|[]"
    same "$P what is left of the other tables: the recent session, alert and pairing attempt" "$(val left)" "1/1/1"
    same "$P a second run deletes nothing" "$(val second)" "0|0|0|0|0|[]"
    same "$P after a run the caller's lock_timeout is the block's 5 s (why the block must stay last)" "$(val lt)" "5s"
}
# (a) a DELETE that fails: a trigger raising on webhook_jobs
case_fail_trigger() {
    TXN_OUT="$(txn "
$FIXTURE_SQL
create function b2t.refuse_delete() returns trigger language plpgsql as \$\$
begin raise exception 'v0.91 test: webhook_jobs refuses deletes'; end \$\$;
create trigger b2t_refuse before delete on public.webhook_jobs for each statement execute function b2t.refuse_delete();
select 'first=' || $ANSWER from (select public._cleanup_expired_data_internal() as r) s;
select 'jobs=' || (select count(*) from public.webhook_jobs);
select 'left=' || $LEFT3;
select 'lt=' || current_setting('lock_timeout');
drop trigger b2t_refuse on public.webhook_jobs;
select 'retry=' || $ANSWER from (select public._cleanup_expired_data_internal() as r) s;
select 'gone=' || $(jobs_in "$DEL_IDS");
select 'kept=' || (select count(*) from public.webhook_jobs);
")" || true
    same "$P a DELETE that fails: errors = 1, webhook_jobs named, nothing of it deleted, the other three tables still cleaned" \
         "$(val first) / $(val jobs) / $(val left)" "0|1|1|1|1|[\"webhook_jobs\"] / 11 / 1/1/1"
    if grep -q "WARNING:  _cleanup_expired_data_internal: webhook_jobs not cleaned: v0.91 test: webhook_jobs refuses deletes" "$WORK/txn.err" \
       && grep -q "WARNING:  _cleanup_expired_data_internal: 1 of 4 tables failed: webhook_jobs" "$WORK/txn.err"; then
        pass "$P the failure is reported with WARNINGs naming webhook_jobs (and 1 of 4 tables)"
    else fail "$P no WARNING naming webhook_jobs: $(head -3 "$WORK/txn.err")"; fi
    same "$P after the failed block the caller's lock_timeout is its own again (the savepoint undid the set_config)" "$(val lt)" "0"
    same "$P the next run, the cause gone, deletes the whole backlog at once and keeps the rest" \
         "$(val retry) / $(val gone) / $(val kept)" "3|0|0|0|0|[] / 0 / 8"
}
# (b) an eligible row locked by another session
case_locked_row() {
    local out t0 ms bg
    q >/dev/null <<SQL
insert into public.sessions (id, user_id, provider, status, started_at, last_active_at) values
  ('s-lock-old', '$UA', 'Codex', 'Ended', now() - interval '10 days 1 hour', now() - interval '10 days');
insert into public.alerts (id, user_id, type, title, grouping_key, created_at) values
  ('al-lock-old', '$UA', 'Usage Spike', 'old', 'g-al-lock-old', now() - interval '10 days');
insert into public.pairing_attempt_log (ip_addr, attempted_at) values ('192.0.2.9', now() - interval '2 hours');
insert into public.webhook_jobs (user_id, alert_id, alert_payload, enqueued_at, processed_at, attempt_count) values
  ('$UA', 'wj-locked', '{"grouping_key":"kl1"}', now() - interval '2 days 1 minute', now() - interval '2 days', 1),
  ('$UA', 'wj-free',   '{"grouping_key":"kl2"}', now() - interval '2 days 1 minute', now() - interval '2 days', 1);
SQL
    psql "$DB" --no-psqlrc -qtAX -c "begin" -c "select id from public.webhook_jobs where alert_id = 'wj-locked' for update" -c "select pg_sleep(60)" >/dev/null 2>&1 &
    bg=$!; BGPIDS+=("$bg"); echo "$bg" >> "$WORK/bgpids"
    wait_for "$(sleeping 'select pg_sleep(60)')"
    t0=$(now_ms)
    # the suite's own limit: a cleanup that waits on the lock for good is
    # cancelled at 20 s
    out="$(PGOPTIONS='-c client_min_messages=warning -c statement_timeout=20s' psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX \
             -c "select $ANSWER from (select public._cleanup_expired_data_internal() as r) s" 2>"$WORK/locked.err")" || out="(failed: $(head -1 "$WORK/locked.err"))"
    ms=$(( $(now_ms) - t0 ))
    same "$P a locked eligible row: the block gives up within lock_timeout (errors = 1, nothing of it deleted), the other three tables cleaned" \
         "$out / $(q -c "select count(*) from public.webhook_jobs where alert_id in ('wj-locked', 'wj-free')")" \
         "0|1|1|1|1|[\"webhook_jobs\"] / 2"
    if (( ms >= 4000 && ms < 15000 )); then pass "$P it gave up after about 5 s ($ms ms)"; else fail "$P it took $ms ms (want about 5 s)"; fi
    grep -q "WARNING:  _cleanup_expired_data_internal: webhook_jobs not cleaned: canceling statement due to lock timeout (SQLSTATE 55P03)" "$WORK/locked.err" \
        && pass "$P the WARNING says it was the lock timeout" || fail "$P no lock-timeout WARNING: $(head -2 "$WORK/locked.err")"
    q -c "select pg_terminate_backend(pid) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query = 'select pg_sleep(60)'" >/dev/null
    wait "$bg" >/dev/null 2>&1 || true
    same "$P once the lock is released the next run deletes both" \
         "$(q -c "select $ANSWER from (select public._cleanup_expired_data_internal() as r) s") / $(q -c "select count(*) from public.webhook_jobs where alert_id in ('wj-locked', 'wj-free')")" \
         "2|0|0|0|0|[] / 0"
}
# the nightly DELETE holds its locks (its transaction kept open after the
# call) while an alert is inserted, with the same grouping_key as a job being
# deleted, under a 500 ms limit
case_insert_during_prune() {
    local m rc out pending open_now
    q >/dev/null <<SQL
insert into public.webhook_jobs (user_id, alert_id, alert_payload, enqueued_at, processed_at, attempt_count) values
  ('$UA', 'wj-old-1', '{"grouping_key":"g-during"}', now() - interval '2 days 1 minute', now() - interval '2 days', 1),
  ('$UA', 'wj-old-2', '{"grouping_key":"kd2"}',      now() - interval '2 days 1 minute', now() - interval '2 days', 1);
SQL
    run_bg_to "$WORK/prune.out" psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -c "begin" \
        -c "select 'answer=' || $ANSWER from (select public._cleanup_expired_data_internal() as r) s" \
        -c "select pg_sleep(3)" -c "commit"; m=$BGPID
    wait_for "$(sleeping 'select pg_sleep(3)')"
    same "$P (setup) the cleanup's open transaction holds ROW EXCLUSIVE on webhook_jobs and the row locks of the two jobs it deleted" \
         "$(q -c "select exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                                  where a.datname = current_database() and a.query = 'select pg_sleep(3)' and l.granted
                                    and l.relation = 'public.webhook_jobs'::regclass and l.mode = 'RowExclusiveLock')") / $(q -c "select count(*) from (select 1 from public.webhook_jobs where alert_id in ('wj-old-1', 'wj-old-2') for update skip locked) x")" \
         "t / 0"
    rc=0; out="$(psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -c "set statement_timeout = '500ms'" \
        -c "insert into public.alerts (id, user_id, type, title, grouping_key) values ('al-during-prune', '$UA', 'Usage Spike', 't', 'g-during')" 2>&1)" || rc=$?
    pending="$(q -c "select count(*) from public.webhook_jobs where alert_id = 'al-during-prune' and processed_at is null")"
    open_now="$(q -c "select count(*) from pg_stat_activity where datname = current_database() and state = 'active' and query = 'select pg_sleep(3)'")"
    same "$P an alert inserted while the nightly DELETE holds its locks goes on at once (500 ms limit) and its pending job is enqueued, though a job being deleted has its grouping_key" \
         "$rc / $pending / $open_now" "0 / 1 / 1"
    rc=0; wait "$m" || rc=$?
    same "$P then the cleanup commits: the two old jobs deleted, the new pending job kept" \
         "$rc / $(sed -n 's/^answer=//p' "$WORK/prune.out" | cut -d'|' -f1) / $(q -c "select count(*) from public.webhook_jobs where alert_id in ('wj-old-1', 'wj-old-2')") / $(q -c "select count(*) from public.webhook_jobs where alert_id = 'al-during-prune' and processed_at is null")" \
         "0 / 2 / 0 / 1"
}
# the block's lock_timeout is local: in the caller's transaction it is 5 s,
# after the commit the session's own value is back
case_session_lock_timeout() {
    local out
    out="$(psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX \
             -c "select current_setting('lock_timeout')" \
             -c "select public._cleanup_expired_data_internal() ->> 'errors'" \
             -c "select current_setting('lock_timeout')" \
             -c "begin" -c "select public._cleanup_expired_data_internal() ->> 'errors'" \
             -c "select current_setting('lock_timeout')" -c "commit" \
             -c "select current_setting('lock_timeout')" 2>&1 | paste -sd' ' -)"
    same "$P after the cleanup's transaction commits, the next statement in the same session has its own lock_timeout again (5 s only inside the transaction)" \
         "$out" "0 0 0 0 5s 0"
}
run_cases() { case_prune; case_fail_trigger; case_locked_row; case_insert_during_prune; case_session_lock_timeout; }

# =============================================================================
echo "== 1. control: v0.87's cleanup, with v0.89 applied (production between v0.89 and v0.91)"
newdb "${PFX}_upbase"; build_upgrade_base
same "1. the upgrade base runs production's cleanup body and production's v0.25 worker" "$(cleanup_md5) $(worker_md5)" "$PROD_CLEANUP_MD5 $PROD_WORKER25_MD5"
same "1. and production's cleanup ACL" \
     "$(q -c "select proacl::text from pg_proc where oid = '$CL'::regprocedure")" "{$SU=X/$SU,service_role=X/$SU}"
newdb "${PFX}_up89" "${PFX}_upbase"
out="$(migrate "$V089")" || { echo "v0.89 did not apply on the upgrade base: $(grep -m1 ERROR <<<"$out")" >&2; exit 2; }
q -c "select cron.alter_job(3, active := true)" >/dev/null   # v0.89's R9: the webhook job back on
same "1. v0.89 applied: its worker body" "$(worker_md5)" "$RAW89"
newdb "${PFX}_ctl" "${PFX}_up89"
P="[v0.87 control]"
prune_txn
same "$P nothing is deleted from webhook_jobs (every fixture job left), and the answer has no webhook_jobs_deleted" \
     "$(val first) / $(val gone)/$(val recent)/$(val boundary)/$(val pending)" "|1|1|1|0|[] / 3/2/1/5"
dropdb_now "${PFX}_ctl"

# =============================================================================
echo "== 2. upgrade: the header's steps, as printed"
newdb "${PFX}_up" "${PFX}_up89"
P="[upgrade]"
ACL_UP="$(q -c "select md5('{$SU=X/$SU,service_role=X/$SU}')")"
ACL_FR="$(q -c "select md5('{$SU=X/$SU}')")"
same "$P Q0 before (hashes and booleans only): production's body, one function, attributes, applier, grants, ACL, v0.89's worker, no table comment" \
     "$(q0)" "$PROD_CLEANUP_MD5|1|t|t|t|$ACL_UP|$RAW89|"
hvals() { grep -oE "$1 = [0-9a-f]{32}" <<<"$HDR" | grep -oE '[0-9a-f]{32}' | sort -u | paste -sd' ' -; }
if [[ "$SU" == postgres ]]; then   # the header states production's values, whose role is postgres
    same "$P the header's expected acl_md5 is this ACL's (production's)" "$(hvals acl_md5)" "$ACL_UP"
fi
same "$P G1 returns counts only (no timestamp column)" \
     "$(psql "$DB" --no-psqlrc -X -A -c "$(hq G1)" | head -1)" "total|pending|eligible|pending_over_1_day|stuck"
same "$P G1 as printed" "$(q -c "$(hq G1)")" "0|0|0|0|0"
same "$P G2 returns sizes and vacuum statistics (metadata)" \
     "$(psql "$DB" --no-psqlrc -X -A -c "$(hq G2)" | head -1)" "bytes|n_live_tup|n_dead_tup|vacuums|hours_since_vacuum"
q -c "$(hq G3)" | grep -q 'Execution Time' && pass "$P G3 (a SELECT, never the DELETE) prints the scan's Execution Time" || fail "$P G3 did not run as printed"
same "$P Q3: one job by name, one calling the cleanup, active, v0.21's command and schedule, its user can execute it, UTC" "$(q -c "$(hq Q3)")" "1|1|t|t|t|t"
same "$P Q3b: its recent runs by status" "$(q -c "$(hq Q3b)")" "succeeded|1"
same "$P DRY as printed" "$(q -c "$(hq DRY)")" "0"
same "$P the ops check before v0.91: the cleanup is not v0.91's" "$(ops)" "cleanup function changed"
q -c "$(hq R0)" > "$WORK/rollback.sql"; echo ';' >> "$WORK/rollback.sql"
grep -q 'CREATE OR REPLACE FUNCTION public._cleanup_expired_data_internal()' "$WORK/rollback.sql" || fail "$P R0 did not print the cleanup's definition"
FP_BEFORE="$(q -f "$CATALOG")"
same "$P Q6 before the apply: no apply session" "$(q -c "$(hq Q6)")" "0"
applies "$P the migration applies on production's shape (after v0.89)"
same "$P its NOTICEs: applier and owner, the body it installed" "$(notice "$LAST_OUT")" \
     "applier $SU, cleanup owner $SU|cleanup replaced (body md5 $RAW91), owner and ACL unchanged"
TCOMMENT_MD5="$(q -c "select md5(obj_description('public.webhook_jobs'::regclass, 'pg_class'))")"
same "$P Q0 after: v0.91's body and the table comment, everything else as before" "$(q0)" "$RAW91|1|t|t|t|$ACL_UP|$RAW89|$TCOMMENT_MD5"
same "$P the table_comment_md5 the header expects is the comment's" "$(hvals table_comment_md5)" "$TCOMMENT_MD5"
same "$P Q3 after: the job untouched" "$(q -c "$(hq Q3)")" "1|1|t|t|t|t"
FP_AFTER="$(q -f "$CATALOG")"
same "$P fingerprint: only the cleanup's line and the table's line changed" \
     "$(diff <(echo "$FP_BEFORE") <(echo "$FP_AFTER") | grep -E '^[<>] ' \
        | sed -E 's/^([<>]) (1b\|_cleanup_expired_data_internal|5a\|rls)\|.*/\1 \2/' | sort | paste -sd' ' -)" \
     "< 1b|_cleanup_expired_data_internal < 5a|rls > 1b|_cleanup_expired_data_internal > 5a|rls"
same "$P fingerprint: the cleanup's line moved in its body md5 only" \
     "$(diff <(grep '^1b|_cleanup_expired_data_internal|' <<<"$FP_BEFORE" | sed "s/$PROD_CLEANUP_MD5/X/") \
             <(grep '^1b|_cleanup_expired_data_internal|' <<<"$FP_AFTER" | sed "s/$RAW91/X/") >/dev/null && echo same)" "same"
same "$P fingerprint: the table's line moved in its comment only" \
     "$(diff <(grep '^5a|rls|' <<<"$FP_BEFORE" | sed 's/|comment=NULL$/|comment=X/') \
             <(grep '^5a|rls|' <<<"$FP_AFTER" | sed "s/|comment=$TCOMMENT_MD5\$/|comment=X/") >/dev/null && echo same)" "same"
check "$P contract: SECURITY DEFINER, search_path pinned, no arguments, returns jsonb, plpgsql" \
      "(select p.prosecdef and p.proconfig = array['search_path=pg_catalog, public, extensions']
               and pg_get_function_identity_arguments(p.oid) = '' and p.prorettype = 'jsonb'::regtype and l.lanname = 'plpgsql'
          from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = '$CL'::regprocedure)"
check "$P contract: anon and authenticated cannot execute it, service_role can (as before)" \
      "not has_function_privilege('anon', '$CL', 'EXECUTE')
       and not has_function_privilege('authenticated', '$CL', 'EXECUTE')
       and has_function_privilege('service_role', '$CL', 'EXECUTE')"
same "$P the ops check after the apply (a healthy database): no rows" "$(ops)" ""
applies "$P applied a second time"
same "$P second time: same body, owner, ACL and comment" "$(notice "$LAST_OUT" | cut -d'|' -f2) / $(q0)" \
     "cleanup replaced (body md5 $RAW91), owner and ACL unchanged / $RAW91|1|t|t|t|$ACL_UP|$RAW89|$TCOMMENT_MD5"
# rollback: R0's saved definition and RB
newdb "${PFX}_rb" "${PFX}_up"
apply "$WORK/rollback.sql"; q -c "$(hq RB)" >/dev/null
same "$P ROLLBACK (R0 + RB): Q0 exactly as in step 0" "$(q0)" "$PROD_CLEANUP_MD5|1|t|t|t|$ACL_UP|$RAW89|"
same "$P and v0.91 applies again after it" "$(migrate "$V091" >/dev/null && q0)" "$RAW91|1|t|t|t|$ACL_UP|$RAW89|$TCOMMENT_MD5"
out="$(psql "$DB" --no-psqlrc -X -v ON_ERROR_STOP=1 -c "$(hq P9)" 2>&1)" || true
same "$P P9 (stop further runs), as printed, pauses the nightly job and nothing else" \
     "$(grep -c '(1 row)' <<<"$out") $(q -c "select string_agg(jobid || '=' || active, ' ' order by jobid) from cron.job")" "1 1=false 3=true"
dropdb_now "${PFX}_rb"

# =============================================================================
echo "== 3. fresh install (the baseline files)"
newdb "${PFX}_fr"; build_fresh
P="[fresh]"
same "$P Q0: the baseline installs v0.91's body, v0.89's worker and the table comment, owner-only ACL" \
     "$(q0)" "$RAW91|1|t|t|t|$ACL_FR|$RAW89|$TCOMMENT_MD5"
applies "$P the migration re-applies on a fresh install (its own body)"
same "$P nothing changed" "$(q0)" "$RAW91|1|t|t|t|$ACL_FR|$RAW89|$TCOMMENT_MD5"
same "$P the ops check: no rows" "$(ops)" ""

# =============================================================================
echo "== 4. behaviour, both paths"
for path in up fr; do
    newdb "${PFX}_cases_$path" "${PFX}_$path"
    if [[ $path == up ]]; then P="[upgrade]"; else P="[fresh]"; fi
    run_cases
    dropdb_now "${PFX}_cases_$path"
done

echo "== 4c. why the block sets no statement_timeout"
newdb "${PFX}_st" "${PFX}_up"
P="[timeout]"
q >/dev/null <<'SQL'
create function b2t.sets_timeout_then_sleeps() returns text language plpgsql as $$
begin
  perform set_config('statement_timeout', '200ms', true);
  perform pg_sleep(1);
  return 'not cancelled';
end $$;
SQL
same "$P a statement_timeout set inside a function does not stop the statement already running it (200 ms set, 1 s slept)" \
     "$(q -c "select b2t.sets_timeout_then_sleeps()" 2>&1)" "not cancelled"
out="$(psql "$DB" --no-psqlrc -qtAX 2>&1 <<SQL
begin;
$FIXTURE_SQL
create function b2t.slow_delete() returns trigger language plpgsql as \$\$
begin perform pg_sleep(2); return null; end \$\$;
create trigger b2t_slow before delete on public.webhook_jobs for each statement execute function b2t.slow_delete();
savepoint before_run;
set local statement_timeout = '500ms';
select 'answer=' || public._cleanup_expired_data_internal()::text;
rollback to savepoint before_run;
select 'left=' || $LEFT3 || '/' || (select count(*) from public.webhook_jobs);
rollback;
SQL
)" || true
if grep -q 'canceling statement due to statement timeout' <<<"$out" && ! grep -q '^answer=' <<<"$out"; then
    pass "$P a statement timeout that fires during the webhook DELETE is not caught by WHEN OTHERS: the whole call is cancelled"
else fail "$P a statement timeout in the webhook block: $(head -3 <<<"$out")"; fi
same "$P and the other three tables' deletes are undone with it (all fixture rows still there)" "$(sed -n 's/^left=//p' <<<"$out")" "2/2/2/11"
dropdb_now "${PFX}_st"

# =============================================================================
echo "== 5. re-runs (bodies with and without comment-only lines)"
strip_comment_lines "$V091" > "$WORK/v091.stripped.sql"
newdb "${PFX}_rr" "${PFX}_up89"
P="[re-run]"
rc=0; LAST_OUT="$(migrate "$WORK/v091.stripped.sql")" || rc=$?
same "$P the migration without its comment-only lines applies over v0.87's body" "$rc / $(cleanup_md5)" "0 / $STRIP91"
applies "$P then as written, over the stripped v0.91 body"
same "$P which installs the raw body" "$(cleanup_md5)" "$RAW91"
rc=0; LAST_OUT="$(migrate "$WORK/v091.stripped.sql")" || rc=$?
same "$P and stripped again, over the raw v0.91 body" "$rc / $(cleanup_md5)" "0 / $STRIP91"
newdb "${PFX}_rr_cases" "${PFX}_rr"
P="[stripped body]"
case_prune
dropdb_now "${PFX}_rr_cases"; dropdb_now "${PFX}_rr"

# =============================================================================
echo "== 6. guards: each refuses and changes nothing"
psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 \
    -c "create role $STRANGER nologin" -c "create role $MEMBER nologin" -c "grant $SU to $MEMBER" \
    -c "create role $CARRIER nologin" >/dev/null
P="[guard]"
G=0
guard() { # guard <label> <regex> <setup sql or ""> [role] [template]
    G=$((G + 1)); newdb "${PFX}_g$G" "${5:-${PFX}_up89}"
    [[ -z "$3" ]] || q >/dev/null <<<"$3"
    refuses "$P $1: refused, nothing changed" "$2" "${4:-}"
    dropdb_now "${PFX}_g$G"
}
guard_without_b1() { # the refusal negative control 7 must fail
    guard "without v0.89 (production today: v0.25's worker)" 'v0\.89 is not applied \(public\.process_webhook_jobs\(\) body md5 7e7c1040479aa3f0879cbb1b99911c21\)' \
          "" "" "${PFX}_upbase"
}
guard_without_b1
guard "no worker at all" 'v0\.89 is not applied \(public\.process_webhook_jobs\(\) body md5 none\)' \
      "drop function public.process_webhook_jobs();"
guard "no webhook_jobs table" 'public\.webhook_jobs does not exist' \
      "drop table public.webhook_jobs cascade;"
guard "processed_at of another type" 'has no processed_at timestamptz column' \
      "alter table public.webhook_jobs alter column processed_at type timestamp;"
guard "a foreign body: v0.87's without its comment-only lines" "unexpected definition \\(body md5 $STRIP87\\), rebase required" \
      "$(cat "$WORK/cleanup87.stripped.sql")"
guard "a foreign body that names v0.91 and webhook_jobs" 'unexpected definition \(body md5 [0-9a-f]+\), rebase required' \
      "create or replace function public._cleanup_expired_data_internal() returns jsonb as \$\$
begin
  -- v0.91 webhook jobs finalized more than a day ago
  delete from public.webhook_jobs where processed_at < now() - interval '1 day';
  return '{}'::jsonb;
end;
\$\$ language plpgsql security definer set search_path = pg_catalog, public, extensions;"
guard "a second _cleanup_expired_data_internal in another schema" 'expected exactly one function named _cleanup_expired_data_internal' \
      "create schema other; create function other._cleanup_expired_data_internal() returns jsonb language sql as 'select ''{}''::jsonb';"
guard "an overload in public" 'expected exactly one function named _cleanup_expired_data_internal' \
      "create function public._cleanup_expired_data_internal(integer) returns jsonb language sql as 'select ''{}''::jsonb';"
guard "SECURITY INVOKER" 'is not SECURITY DEFINER' \
      "alter function public._cleanup_expired_data_internal() security invoker;"
guard "another search_path" 'has proconfig .*expected \{search_path=pg_catalog, public, extensions\}' \
      "alter function public._cleanup_expired_data_internal() set search_path = public;"
guard "EXECUTE granted to authenticated" 'PUBLIC, anon or authenticated may execute' \
      "grant execute on function public._cleanup_expired_data_internal() to authenticated;"
guard "EXECUTE granted to PUBLIC" 'PUBLIC, anon or authenticated may execute' \
      "grant execute on function public._cleanup_expired_data_internal() to public;"
# EXECUTE that reaches anon only through a role it inherits: no direct grant,
# so only the effective check refuses it (PostgreSQL 16+: WITH INHERIT TRUE,
# since the shim's anon, like Supabase's, is NOINHERIT)
G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_up89"
q -c "grant execute on function public._cleanup_expired_data_internal() to $CARRIER" >/dev/null
psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 -c "grant $CARRIER to anon with inherit true" >/dev/null
same "$P (setup) no direct grant to PUBLIC, anon or authenticated, yet anon can execute the cleanup: Q0's anon_auth_denied is false" \
     "$(q -c "select proacl::text from pg_proc where oid = '$CL'::regprocedure") / $(q0 | cut -d'|' -f5)" \
     "{$SU=X/$SU,service_role=X/$SU,$CARRIER=X/$SU} / f"
refuses "$P EXECUTE reaching anon through an inherited role (no direct grant): refused, nothing changed" \
        'anon may execute public\._cleanup_expired_data_internal\(\) through a role it inherits'
psql "$DATABASE_URL" -qtAX -c "revoke $CARRIER from anon" >/dev/null
dropdb_now "${PFX}_g$G"
guard "an applier that is neither the owner nor a member of it" "$STRANGER is neither the owner .* nor a member" \
      "" "$STRANGER"
guard "the nightly job missing" 'exactly one cron job named cleanup_expired_data_nightly \(found 0\)' \
      "delete from cron.job where jobid = 1;"
guard "the nightly job inactive" 'cron job 1 \(cleanup_expired_data_nightly\) is not active' \
      "update cron.job set active = false where jobid = 1;"
guard "the nightly job runs another command" "cron job 1 \\(cleanup_expired_data_nightly\\) runs select public\\._cleanup_expired_data_internal\\(\\) on 7 3 \\* \\* \\*, not v0\\.21's" \
      "update cron.job set command = 'select public._cleanup_expired_data_internal()' where jobid = 1;"
guard "the nightly job on another schedule" "runs SELECT public\\._cleanup_expired_data_internal\\(\\); on 7 4 \\* \\* \\*, not v0\\.21's" \
      "update cron.job set schedule = '7 4 * * *' where jobid = 1;"
guard "a second job calling the cleanup" 'exactly one calling _cleanup_expired_data_internal \(found 2\)' \
      "insert into cron.job (jobname, schedule, command) values ('cleanup_again', '0 * * * *', 'SELECT PUBLIC._CLEANUP_EXPIRED_DATA_INTERNAL();');"
guard "the name on another job than the one calling the cleanup" 'is not cleanup_expired_data_nightly' \
      "update cron.job set command = 'select 1' where jobid = 1;
       insert into cron.job (jobname, schedule, command) values ('renamed_cleanup', '7 3 * * *', 'SELECT public._cleanup_expired_data_internal();');"
guard "the job's user cannot execute the cleanup" 'cron job 1 runs as anon, which cannot execute' \
      "update cron.job set username = 'anon' where jobid = 1;"
guard "the job's user does not exist" 'cron job 1 runs as no_such_role_v091, which cannot execute' \
      "update cron.job set username = 'no_such_role_v091' where jobid = 1;"
# a session holding the cleanup's catalog row: the replace gives up at lock_timeout
held_session() { # held_session <sql holding a lock>: in a background session, then asleep
    psql "$DB" --no-psqlrc -qtAX -c "begin" -c "$1" -c "select pg_sleep(60)" >/dev/null 2>&1 &
    BGPID=$!; BGPIDS+=("$BGPID"); echo "$BGPID" >> "$WORK/bgpids"
    wait_for "$(sleeping 'select pg_sleep(60)')"
}
for held in "alter function public._cleanup_expired_data_internal() set work_mem = '64kB'|the cleanup's catalog row" \
            "lock table public.webhook_jobs in share update exclusive mode|SHARE UPDATE EXCLUSIVE on the queue (an autovacuum's lock)"; do
    G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_up89"
    held_session "${held%%|*}"
    t0=$SECONDS
    refuses "$P a session holding ${held#*|}: the apply gives up at lock_timeout, nothing changed" 'lock timeout'
    (( SECONDS - t0 < 30 )) && pass "$P and it gave up within 30 s ($((SECONDS - t0)) s)" || fail "$P it took $((SECONDS - t0)) s"
    end_sleepers; wait "$BGPID" >/dev/null 2>&1 || true
    dropdb_now "${PFX}_g$G"
done
# an applier that is a member of the owner role (not superuser) applies
G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_up89"
applies "$P an applier that is a member of the owner role, not a superuser, applies" "$MEMBER"
same "$P its NOTICE names that applier and the owner; the owner is unchanged" \
     "$(notice "$LAST_OUT" | cut -d'|' -f1) / $(q -c "select pg_get_userbyid(proowner) from pg_proc where oid = '$CL'::regprocedure")" \
     "applier $MEMBER, cleanup owner $SU / $SU"
dropdb_now "${PFX}_g$G"

echo "== 6c. Q3c: the timeouts the nightly run is under"
newdb "${PFX}_q3c" "${PFX}_up"
P="[Q3c]"
same "$P returns settings only (no row of any table)" \
     "$(psql "$DB" --no-psqlrc -X -A -c "$(hq Q3c)" | head -1)" \
     "username|role_in_database|role_settings|database_settings|server_statement_timeout|server_lock_timeout"
same "$P as printed, nothing set (this server's defaults)" "$(q -c "$(hq Q3c)")" "$SU|(none)|(none)|(none)|0 ms from default|0 ms from default"
psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 \
    -c "alter role $CARRIER set statement_timeout = '45s'" \
    -c "alter role $CARRIER in database ${PFX}_q3c set statement_timeout = '30s'" \
    -c "alter database ${PFX}_q3c set lock_timeout = '3s'" >/dev/null
q -c "update cron.job set username = '$CARRIER' where jobid = 1" >/dev/null
same "$P a job user with its own setting, a role-in-database setting and a database setting: each in its column, and the server column says when this session's value is not the server's (source database)" \
     "$(q -c "$(hq Q3c)")" "$CARRIER|statement_timeout=30s|statement_timeout=45s|lock_timeout=3s|0 ms from default|3000 ms from database"
psql "$DATABASE_URL" -qtAX -c "alter role $CARRIER reset all" >/dev/null
dropdb_now "${PFX}_q3c"

echo "== 6b. what waits on the apply (nothing that writes) and the time budget (A0)"
# held_copy <src> <dst> <statement>: the migration with <statement> run just before its commit
held_copy() {
    HELD="$3" perl -pe 's/^commit;$/$ENV{HELD}\ncommit;/' "$1" > "$2"
    [[ "$(grep -c -x -F -- "$3" "$2")" == 1 ]] || { echo "held_copy: '$3' not placed once" >&2; exit 2; }
}
P="[budget]"
newdb "${PFX}_z1" "${PFX}_up89"
held_copy "$V091" "$WORK/held.z1.sql" "select pg_sleep(1.5);"
run_bg_to "$WORK/z1.mig" psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.z1.sql"; m=$BGPID
wait_for "$(sleeping 'select pg_sleep(1.5)')"
rc=0; out="$(psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -c "set statement_timeout = '500ms'" \
    -c "insert into public.alerts (id, user_id, type, title, grouping_key) values ('al-during', '$UA', 'Usage Spike', 't', 'g-during')" 2>&1)" || rc=$?
rc2=0; out2="$(psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -c "set statement_timeout = '500ms'" \
    -c "select public._cleanup_expired_data_internal() ? 'webhook_jobs_deleted'" 2>&1)" || rc2=$?
open_now="$(q -c "$(hq Q6)")"
same "$P while the apply is open (replaced and commented, not committed: Q6 still 1), an alert insert goes on at once (500 ms limit) and its job is enqueued" \
     "$open_now / $rc / $(q -c "select count(*) from public.webhook_jobs where alert_id = 'al-during' and processed_at is null")" "1 / 0 / 1"
same "$P and so does a cleanup call, which runs the committed (old) body" "$rc2 / $out2" "0 / f"
rc=0; wait "$m" || rc=$?
same "$P then the apply commits" "$rc / $(cleanup_md5)" "0 / $RAW91"
dropdb_now "${PFX}_z1"
if (( SVN >= 170000 )); then BUDGET_RE='terminating connection due to transaction timeout'; else BUDGET_RE='canceling statement due to statement timeout'; fi
budget_overrun() { # budget_overrun <tag> <migration> <regex of the abort> <label>
    local rc t0 before
    newdb "${PFX}_z$1" "${PFX}_up89"
    before="$(q -c "select b2t.snapshot()")"
    held_copy "$2" "$WORK/held.z$1.sql" "select pg_sleep(3);"
    t0=$(now_ms); rc=0
    psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.z$1.sql" > "$WORK/z$1.mig" 2>&1 || rc=$?
    t0=$(( $(now_ms) - t0 ))
    if (( rc != 0 )) && grep -q -E -- "$3" "$WORK/z$1.mig" && (( t0 < 2900 )); then
        pass "$P $4: the apply runs past 2 s and is stopped after $t0 ms: /$3/"
    else fail "$P $4: rc $rc after $t0 ms, not /$3/ within 2.9 s: $(grep -m1 -E 'ERROR|FATAL' "$WORK/z$1.mig")"; fi
    same "$P $4: nothing changed" "$(q -c "select b2t.snapshot()")" "$before"
    dropdb_now "${PFX}_z$1"
}
if (( SVN >= 170000 )); then
    budget_overrun 2 "$V091" "$BUDGET_RE" "PostgreSQL $((SVN / 10000)), transaction_timeout 2s"
    mutate "$V091" "$WORK/v091.fallback.sql" 1 "current_setting\\('server_version_num'\\)::int >= 170000" "current_setting('server_version_num')::int >= 990000"
    budget_overrun 3 "$WORK/v091.fallback.sql" 'canceling statement due to statement timeout' "the pre-17 branch, forced (statement_timeout 2s per statement)"
else
    budget_overrun 2 "$V091" "$BUDGET_RE" "PostgreSQL $((SVN / 10000)) (before 17), statement_timeout 2s per statement"
fi

# =============================================================================
echo "== 7. the ops check (ops/check_webhook_jobs_retention.sql), as it stands"
newdb "${PFX}_ops" "${PFX}_up"
P="[ops]"
same "$P a healthy database: no rows" "$(ops)" ""
same "$P job missing" "$(ops_with "delete from cron.job where jobid = 1;")" "job missing"
same "$P job inactive" "$(ops_with "update cron.job set active = false where jobid = 1;")" "job inactive"
same "$P job command changed" "$(ops_with "update cron.job set command = 'select 1' where jobid = 1;")" "job command changed"
same "$P job schedule changed" "$(ops_with "update cron.job set schedule = '7 4 * * *' where jobid = 1;")" "job schedule changed"
same "$P the cleanup back to v0.87's body" "$(ops_with "$(cat "$WORK/cleanup87.sql")")" "cleanup function changed"
same "$P the cleanup made SECURITY INVOKER" "$(ops_with "alter function public._cleanup_expired_data_internal() security invoker;")" "cleanup function changed"
same "$P no run recorded" "$(ops_with "delete from cron.job_run_details;")" "no run recorded"
same "$P last run failed" "$(ops_with "insert into cron.job_run_details (jobid, status, return_message, start_time) values (1, 'failed', 'ERROR: x', now() - interval '1 hour');")" "last run failed"
same "$P no run in the last 26 hours" "$(ops_with "update cron.job_run_details set start_time = now() - interval '30 hours' where jobid = 1;")" "no run in the last 26 hours"
same "$P a job finalized 50 hours ago is overdue, one finalized 48 hours ago is not (counted: 1)" \
     "$(q <<SQL | paste -sd',' -
begin;
insert into public.webhook_jobs (user_id, alert_id, alert_payload, enqueued_at, processed_at, attempt_count) values
  ('$UA', 'ops-50h', '{"grouping_key":"o1"}', now() - interval '50 hours 1 minute', now() - interval '50 hours', 1),
  ('$UA', 'ops-48h', '{"grouping_key":"o2"}', now() - interval '48 hours 1 minute', now() - interval '48 hours', 1);
\i '$OPS'
rollback;
SQL
)" "finalized jobs overdue (finalized more than 49 hours ago)|1"
same "$P a pending job over a day old (a request in flight, so not stuck)" \
     "$(ops_with "insert into public.webhook_jobs (user_id, alert_id, alert_payload, enqueued_at, attempt_count, pg_net_request_id, dispatched_at) values ('$UA', 'ops-old', '{\"grouping_key\":\"o3\"}', now() - interval '2 days', 1, 5, now() - interval '2 days');")" \
     "pending jobs older than 1 day"
same "$P a stuck pending job (attempts used up, no request), enqueued just now" \
     "$(ops_with "insert into public.webhook_jobs (user_id, alert_id, alert_payload, attempt_count, last_error) values ('$UA', 'ops-stuck', '{\"grouping_key\":\"o4\"}', 4, 'HTTP 502: x');")" \
     "stuck pending jobs (attempts used up, no request: v0.89's bug)"
same "$P a webhook DELETE that failed in a run cron records as succeeded shows up as overdue" \
     "$(ops_with "insert into public.webhook_jobs (user_id, alert_id, alert_payload, enqueued_at, processed_at, attempt_count) values ('$UA', 'ops-kept', '{\"grouping_key\":\"o5\"}', now() - interval '3 days', now() - interval '3 days', 1);
create function b2t.refuse_delete() returns trigger language plpgsql as \$\$ begin raise exception 'refused'; end \$\$;
create trigger b2t_refuse before delete on public.webhook_jobs for each statement execute function b2t.refuse_delete();
select public._cleanup_expired_data_internal() ->> 'errors' \\g /dev/null")" \
     "finalized jobs overdue (finalized more than 49 hours ago)"
ops_secret_case
n="$(grep -c -E '^-- +I1: ' "$OPS" || true)"; [[ "$n" == 1 ]] || { echo "ops check: want one 'I1:' line, found $n" >&2; exit 2; }
same "$P the PRIVATE INVESTIGATION query I1, as printed, gives the raw command and the last runs (owner only)" \
     "$(q -c "$(sed -n -E 's/^-- +I1: //p' "$OPS")" | cut -d'|' -f1,2,4)" "1|SELECT public._cleanup_expired_data_internal();|succeeded"
dropdb_now "${PFX}_ops"
newdb "${PFX}_ops0" "${PFX}_up"
q -c "drop schema cron cascade" >/dev/null
out="$(q -f "$OPS" 2>&1)" || true
grep -q 'relation "cron.job" does not exist' <<<"$out" \
    && pass "$P where the cron schema does not exist (plain local Postgres) it fails, as its header says" \
    || fail "$P without the cron schema: $out"
dropdb_now "${PFX}_ops0"
# APPLY step 5's sequence: a backlog the old body never deleted
newdb "${PFX}_ops5" "${PFX}_up89"
q -c "insert into public.webhook_jobs (user_id, alert_id, alert_payload, enqueued_at, processed_at, attempt_count) values ('$UA', 'backlog', '{\"grouping_key\":\"b1\"}', now() - interval '20 days', now() - interval '20 days', 1)" >/dev/null
same "$P before v0.91: the cleanup is not v0.91's, and the backlog is overdue" "$(ops)" \
     "cleanup function changed,finalized jobs overdue (finalized more than 49 hours ago)"
migrate "$V091" >/dev/null || fail "$P v0.91 did not apply over a backlog"
same "$P after the apply, before the first run: the backlog only (APPLY step 5)" "$(ops)" "finalized jobs overdue (finalized more than 49 hours ago)"
same "$P the first run deletes it (DRY counted it)" "$(q -c "$(hq DRY)") $(q -c "select (public._cleanup_expired_data_internal() ->> 'webhook_jobs_deleted')")" "1 1"
same "$P after the first run: no rows" "$(ops)" ""
dropdb_now "${PFX}_ops5"

# =============================================================================
echo "== 8. negative controls (each mutant must fail its named assertion)"
M=0
# control <name> <mutant sql> <case function> <regex of the FAIL label it must produce>
control() {
    local out hit
    M=$((M + 1)); newdb "${PFX}_m$M" "${PFX}_up"
    apply "$2"
    out="$( (P="[mutant]"; fails=0; "$3") 2>&1 )" || true
    hit="$(grep -m1 -E -- "^  FAIL  \[mutant\] $4" <<<"$out" || true)"
    if [[ -n "$hit" ]]; then
        pass "control: $1"
        echo "          fails: ${hit#  FAIL  [mutant] }" | cut -c1-220
    else
        fail "control: $1 — did not fail /$4/"
        grep -E 'FAIL|ERROR' <<<"$out" | head -5 >&2 || true
    fi
    dropdb_now "${PFX}_m$M"
}
C="$WORK/cleanup91.sql"; MUT="$WORK/mutant"
mutate "$C" "$MUT.1.sql" 1 "interval '1 day'" "interval '0 days'"
control "1. retention '0 days'" "$MUT.1.sql" case_prune 'recent finalized kept'
mutate "$C" "$MUT.2.sql" 1 "processed_at is not null\\n\\s*and processed_at < now\\(\\) - interval '1 day'" "enqueued_at < now() - interval '1 day'"
control "2a. enqueued_at instead of processed_at (pending jobs)" "$MUT.2.sql" case_prune 'pending never deleted'
control "2b. enqueued_at instead of processed_at (a recent finalization of an old job)" "$MUT.2.sql" case_prune 'recent finalized kept'
mutate "$C" "$MUT.3.sql" 1 "and processed_at < now\\(\\)" "and processed_at <= now()"
control "3. <= instead of <" "$MUT.3.sql" case_prune 'exactly a day: kept'
mutate "$C" "$MUT.4.sql" 1 "\\n  exception when others then\\n    v_failed := v_failed \\|\\| 'webhook_jobs'::text;\\n    raise warning '[^\\n]*webhook_jobs not cleaned[^\\n]*;" ""
control "4. the block outside its own savepoint (no handler)" "$MUT.4.sql" case_fail_trigger 'a DELETE that fails'
mutate "$C" "$MUT.5.sql" 1 "(?s)  -- v0\\.91 webhook jobs.*?\\n  end;\\n\\n" ""
control "5. the block removed" "$MUT.5.sql" case_prune 'finalized more than a day ago: deleted'
mutate "$C" "$MUT.6.sql" 1 "    perform set_config\\('lock_timeout', '5s', true\\);\\n" ""
control "6. no lock_timeout (the suite's own 20 s limit cancels the wait)" "$MUT.6.sql" case_locked_row 'a locked eligible row'
# 7. the migration without its v0.89 guard (A5)
mutate "$V091" "$MUT.7.sql" 1 "(?s)    -- 5\\. v0\\.89 is applied.*?    end if;\\n" ""
M=$((M + 1))
out="$( (P="[mutant]"; MIG="$MUT.7.sql"; fails=0; guard_without_b1) 2>&1 )" || true
hit="$(grep -m1 -E -- '^  FAIL  \[mutant\] without v0\.89' <<<"$out" || true)"
if [[ -n "$hit" ]]; then pass "control: 7. the migration without its v0.89 guard"; echo "          fails: ${hit#  FAIL  [mutant] }" | cut -c1-220
else fail "control: 7. the migration without its v0.89 guard — did not fail the refusal"; grep -E 'FAIL|ERROR' <<<"$out" | head -5 >&2 || true; fi
mutate "$C" "$MUT.9.sql" 1 "    perform set_config\\('lock_timeout', '5s', true\\);\\n\\K" $'    lock table public.webhook_jobs in share row exclusive mode;\n'
control "9. the DELETE takes a lock that blocks writers (SHARE ROW EXCLUSIVE)" "$MUT.9.sql" case_insert_during_prune 'an alert inserted while the nightly DELETE holds its locks'
mutate "$C" "$MUT.10.sql" 1 "set_config\\('lock_timeout', '5s', true\\)" "set_config('lock_timeout', '5s', false)"
control "10. set_config(..., false): the block's lock_timeout set for the session" "$MUT.10.sql" case_session_lock_timeout 'after the cleanup.s transaction commits'
# 11. the ops check printing raw values again
ocontrol() { # ocontrol <name> <mutant ops file>
    local out hit
    M=$((M + 1)); newdb "${PFX}_m$M" "${PFX}_up"
    out="$( (P="[mutant]"; OPS_UNDER_TEST="$2"; fails=0; ops_secret_case) 2>&1 )" || true
    hit="$(grep -m1 -E -- '^  FAIL  \[mutant\] a changed command and a failed run' <<<"$out" || true)"
    if [[ -n "$hit" ]]; then pass "control: $1"; echo "          fails: ${hit#  FAIL  [mutant] }" | cut -c1-220
    else fail "control: $1 — did not fail the secret-text case"; grep -E 'FAIL|ERROR' <<<"$out" | head -5 >&2 || true; fi
    dropdb_now "${PFX}_m$M"
}
mutate "$OPS" "$MUT.o1.sql" 1 "'command md5 ' \\|\\| md5\\(command\\)" "command"
ocontrol "11a. the ops check printing the changed command" "$MUT.o1.sql"
mutate "$OPS" "$MUT.o2.sql" 1 "'status failed \\(its message: PRIVATE INVESTIGATION I1\\)'" "(select d.return_message from cron.job_run_details d order by d.runid desc limit 1)"
ocontrol "11b. the ops check printing the failed run's message" "$MUT.o2.sql"
# 8. the block moved before the pairing block: the static position check fails
perl -0777 -pe 's/(  -- Pairing attempts older[^\n]*\n.*?\n  end;\n\n)(  -- v0\.91 webhook jobs.*?\n  end;\n\n)/$2$1/s or die "swap failed\n"' "$C" > "$MUT.8.sql" \
    || { echo "control setup failed (swap)" >&2; exit 2; }
cmp -s "$C" "$MUT.8.sql" && { echo "the swap changed nothing" >&2; exit 2; }
pc="$(position_check "$MUT.8.sql")"
if [[ "$pc" != ok ]]; then pass "control: 8. the block moved before the pairing block"; echo "          fails: static position: $pc" | cut -c1-220
else fail "control: 8. the static position check passed a moved block"; fi
# and the unmutated cut passes the same checks (the controls fail for the mutation, not the harness)
newdb "${PFX}_m0" "${PFX}_up"; apply "$C"
out="$( (P="[cut]"; fails=0; case_prune; case_fail_trigger; case_locked_row; case_insert_during_prune; case_session_lock_timeout; ops_secret_case; exit $fails) 2>&1 )" \
    && pass "control harness: the unmutated cut passes every check the mutants fail" \
    || { fail "control harness: the unmutated cut fails"; grep FAIL <<<"$out" | head -5 >&2; }
dropdb_now "${PFX}_m0"

echo
if (( fails > 0 )); then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all checks passed"

#!/usr/bin/env bash
# Verify migrate_v0.89 (webhook jobs that keep failing are finalized, instead
# of staying pending forever) against a real Postgres, on both install paths.
#
# Install paths:
#   upgrade  production's shape before v0.89: the current baseline files with
#            the webhook objects replaced by B0's frozen blocks
#            (tests/fixtures/webhook_baseline_b0/: v0.25 + v0.55's policy +
#            v0.62's revoke) WITHOUT their comment-only lines, as production
#            runs them (B0's catalog check, 2026-11-12: the worker's body md5
#            is 7e7c1040…, the trigger function's 6bf7c08a…, both reproduced
#            here first), service_role's EXECUTE grant as production has it,
#            and the cron job active; then the header's pause (P2), the
#            migration, and the header's restore (R6).
#   fresh    schema.sql + app_rpc.sql + helper_rpc.sql as they are (v0.89's
#            body and the comment on processed_at).
# pg_net, vault and pg_cron are not in plain Postgres, so each database gets
# stand-ins: net._http_response with pg_net's columns the worker reads;
# net.http_post with pg_net 0.20's signature, which records each call in
# net.v089_calls and returns its id as the request id (or raises when the
# setting v089.post_mode is 'raise'); vault.decrypted_secrets with both
# secrets; cron.job, cron.job_run_details and cron.alter_job with pg_cron
# 1.6's names, holding production's job (jobid 3, '30 seconds', active).
#
# Every behavioural case runs whole worker calls (both passes, each call its
# own transaction, as pg_cron runs it) and asserts the job's state AND the
# recorder: how many http_post calls, and which request id the job holds.
# Time moves by backdating: respond() also backdates the job's dispatched_at
# by 3 s (pass 1 only reads jobs older than 2 s, and these calls take
# milliseconds; without it every reconcile case would silently do nothing), a
# new job's enqueued_at is aged 6 s (pass 2 reads jobs older than 5 s), and
# age() shifts both.
#
# What this proves:
#   0. md5 values: v0.25's worker cut from its file, raw and without its
#      comment-only lines (the latter equals production's measured md5), and
#      v0.89's from between this migration's BEGIN/END worker markers, raw and
#      stripped, are the header's four values and exactly the guard's; the
#      fresh app_rpc.sql installs v0.89's body.
#   1. CONTROL, the old body on the upgrade path: a 502 twice ends at attempt
#      4, pending, and a new alert with that key is never enqueued; no answer
#      ends at 3, pending; three raises end at 3, pending; a transport failure
#      waits 5 minutes; a request id without dispatched_at is never read.
#   2. upgrade apply, through the header's statements as printed: Q0 (hashes
#      and booleans only) before and after, Q1 (counts only), Q2, Q3, R0, the
#      pause P2 and the restore R9 against the cron stand-in, the quiesce
#      checks Q4/Q4b (a stale 'running' row older than 10 minutes does not
#      count), the recount Q5, Q6; the header's expected acl_md5, job_md5 and
#      comment_md5 are the real ones; the catalog fingerprint
#      (ops/check_webhook_catalog.sql) moves only in the worker's body md5 and
#      the comment on processed_at; the contract (SECURITY DEFINER,
#      search_path, signature, grants); applied twice (same md5 and ACL,
#      nothing backfilled).
#   3. behaviour, on both paths: 502; transport failures (timed out, error);
#      no answer (a row with nothing completed is no answer; the live third
#      request is not finalized, then it is); raises; 2xx on the first and on
#      the third request; malformed rows; one call at a time; dedup.
#   4. backfill: exactly the stuck rows (no request id, attempt_count >= 3);
#      rows with a request id are left to the worker; the NOTICE equals the
#      recount Q5 taken after the pause, not Q1's preliminary count (a job
#      stuck in between is counted); above 5000 it refuses, and the header's
#      BF batch then lets it apply, the job still paused; the rollback (R0's
#      saved definition) restores the body and leaves the backfilled rows
#      finalized.
#   5. re-runs: accepted on v0.25 raw, on v0.89 raw and on v0.89 without its
#      comment-only lines (a client that strips them), in every order.
#   6. guards: each refuses and changes nothing (worker, ACL, rows, comment,
#      cron jobs); a monitoring query and a session in another database do
#      not block; an applier that is a member of the owner role applies; a
#      session holding the worker's catalog row makes it give up at
#      lock_timeout.
#   6b. exclusive access (A5): an idle transaction that already ran the
#      worker is refused, and one that never touched the queue does not
#      stop the apply; an open transaction that read the queue is refused
#      by the pg_locks check; one that wrote it makes the apply wait and give
#      up at lock_timeout; so does a v0.89 worker run holding the worker's
#      lock during a re-run; a worker call that starts during a first apply
#      (against the header's precondition) waits on the queue lock, then runs
#      the old body after the commit and can leave a stuck row: step 7's
#      post-commit drain (Q4, Q6) waits for it, step 8's Q5 shows the row and
#      BF clears it; during a re-run a v0.89 worker call returns at once and
#      touches nothing.
#   6c. recovery (APPLY step 6): an error injected after the replace and the
#      backfill rolls everything back (old body, no comment, stuck rows still
#      stuck) and R9 restores the recorded value; with the client killed
#      mid-apply, another session still sees the old body while Q6 shows the
#      apply open, and once Q6 is 0, Q0/Q5 tell a commit (sent as one string,
#      as apply_migration does) from a rollback (psql -f, killed before the
#      commit); R9 then restores a recorded value of false as false.
#   6d. the budget (A0, 2 s: how long the apply can block the queue) and alert
#      uploads: while the apply holds the queue lock, a helper upload
#      (helper_sync as anon with statement_timeout 3s, as the helpers call
#      it) and an insert as authenticated (8s) wait, then land with their
#      jobs enqueued; an upload whose own statement_timeout runs out first
#      fails and leaves nothing, and sent again it lands; an apply made to
#      run past 2 s is stopped (transaction_timeout on PostgreSQL 17, and the
#      pre-17 per-statement branch forced) with nothing changed, and a helper
#      upload waiting on it goes on; the lock hold time with the size guard's
#      limit of stuck jobs plus thousands of finalized ones is measured from
#      the apply's NOTICE.
#   7. negative controls: mutants of the worker and the backfill, cut from
#      between the markers and applied directly to a throwaway database
#      (bypassing the guards), must each fail the assertion named for them;
#      and copies of the migration without each exclusive-access guard (A5b
#      idle check, A5c advisory lock, A5d LOCK TABLE, A5e pg_locks check),
#      or with the idle check unscoped again, must each fail theirs.
#
# Usage (creates and drops its own b1_<pid>_* databases and roles there):
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres \
#     ./backend/supabase/tests/run_v089_webhook_jobs_finalize_tests.sh
# Run it as a superuser (it creates roles and stand-in schemas).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$(cd "$HERE/.." && pwd)"
SHIM="$HERE/rls/00_supabase_shim.sql"
FROZEN="$HERE/fixtures/webhook_baseline_b0"
V025="$SQL_DIR/migrate_v0.25_sessions_alerts_hardening.sql"
V089="$SQL_DIR/migrate_v0.89_webhook_jobs_finalize_failures.sql"
OPS="$SQL_DIR/ops/check_webhook_catalog.sql"

# Measured in production by B0's catalog check (2026-11-12).
PROD_WORKER_MD5=7e7c1040479aa3f0879cbb1b99911c21
PROD_ENQUEUE_MD5=6bf7c08ada157c7fd949222e09ca9134

UA='b1000000-b100-4b10-8b10-00000000000a'
UB='b1000000-b100-4b10-8b10-00000000000b'
DEV='b1000000-b100-4b10-8b10-0000000000d1'   # a paired Mac; its helper secret is a test value
LOCK_KEY="hashtextextended('process_webhook_jobs', 0)"

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to a database on a disposable server" >&2
    exit 2
fi
for f in "$SHIM" "$FROZEN/schema_block.sql" "$FROZEN/app_rpc_block.sql" "$V025" "$V089" "$OPS" \
         "$SQL_DIR/schema.sql" "$SQL_DIR/app_rpc.sql" "$SQL_DIR/helper_rpc.sql"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done
command -v perl >/dev/null || { echo "perl is needed for the negative controls" >&2; exit 2; }

BASE="${DATABASE_URL%/*}"
PFX="b1_$$"
WORK="$(mktemp -d)"
CREATED=()
BGPIDS=()
STRANGER="${PFX}_stranger"
MEMBER="${PFX}_member"
cleanup() { # best-effort: every step runs, failures only warn, the exit status is the script's own
    set +e
    local p d r
    { exec 3>&-; } 2>/dev/null
    for p in "${BGPIDS[@]:-}" $(cat "$WORK/bgpids" 2>/dev/null); do [[ -n "$p" ]] && kill "$p" >/dev/null 2>&1; done
    for d in "${CREATED[@]:-}" $(cat "$WORK/created" 2>/dev/null); do
        [[ -n "$d" ]] || continue
        PGOPTIONS='-c client_min_messages=warning' psql "$DATABASE_URL" -qtAX -c "drop database if exists $d with (force)" >/dev/null 2>&1 \
            || echo "warning: could not drop database $d (drop it by hand)" >&2
    done
    for r in "$STRANGER" "$MEMBER"; do
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
    CREATED+=("$1"); echo "$1" >> "$WORK/created"   # the file: also from subshells
    DB="$BASE/$1"
}
dropdb_now() { psql "$DATABASE_URL" -qtAX -c "drop database if exists $1 with (force)" >/dev/null 2>&1 || true; }
q() { psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX "$@"; }
apply() { q -f "$1" >/dev/null; }
check() { # check <label> <sql returning boolean>
    local got; got="$(q -c "select ($2)::text" 2>&1)"
    if [[ "$got" == "true" ]]; then pass "$1"; else fail "$1  (got '$got')"; fi
}
# migrate <file> [role]: apply a migration as the superuser (or after SET ROLE
# <role>), notices on; prints everything psql said; psql's status is returned.
migrate() {
    local pre=()
    [[ -n "${2:-}" ]] && pre=(-c "set role $2")
    PGOPTIONS='-c client_min_messages=notice' psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX ${pre[@]+"${pre[@]}"} -f "$1" 2>&1
}
BGPID=""
poll() { # poll <sql returning boolean> <tenths of a second>: 0 once true, 1 if never
    local i
    for i in $(seq 1 "$2"); do
        [[ "$(q -c "select ($1)::text" 2>/dev/null)" == "true" ]] && return 0
        sleep 0.1
    done
    return 1
}
poll_out() { # poll_out <sql> <expected output> <tenths of a second>
    local i
    for i in $(seq 1 "$3"); do [[ "$(q -c "$1" 2>/dev/null)" == "$2" ]] && return 0; sleep 0.1; done
    return 1
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

# ── extraction from the migration file: loud, never silent ──────────────────
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
    local n; n="$(grep -c -E "^-- +$1: " "$V089" || true)"
    [[ "$n" == 1 ]] || { echo "header: want one '$1:' line, found $n" >&2; exit 2; }
    sed -n -E "s/^-- +$1: //p" "$V089"
}
strip_comment_lines() { sed '/^[[:space:]]*--/d' "$1"; }

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

# ── stand-ins and fixtures ──────────────────────────────────────────────────
cat > "$WORK/stubs.sql" <<'SQL'
-- pg_net (0.20): the response table's columns the worker reads, and http_post
-- with pg_net's signature, recording each call; its id is the request id.
create schema if not exists net;
create table net._http_response (
  id bigint primary key,
  status_code integer,
  content text,
  timed_out boolean,
  error_msg text,
  created timestamptz not null default now()
);
create table net.v089_calls (
  id bigserial primary key,
  url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer,
  called_at timestamptz not null default clock_timestamp()
);
create function net.http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb,
  timeout_milliseconds integer default 5000
) returns bigint language plpgsql as $$
declare
  v_id bigint;
begin
  if current_setting('v089.post_mode', true) = 'raise' then
    raise exception 'v089 stub: http_post refused';
  end if;
  insert into net.v089_calls (url, body, params, headers, timeout_milliseconds)
  values (http_post.url, http_post.body, http_post.params, http_post.headers, http_post.timeout_milliseconds)
  returning id into v_id;
  return v_id;
end $$;
grant usage on schema net to anon, authenticated, service_role;

-- vault: both secrets, each once (the values are placeholders).
create schema if not exists vault;
create table vault.v089_secrets (name text, decrypted_secret text);
create view vault.decrypted_secrets as select name, decrypted_secret from vault.v089_secrets;
insert into vault.v089_secrets values
  ('app_supabase_url', 'https://stub.invalid'),
  ('app_service_role_key', 'stub-key');
grant usage on schema vault to service_role;

-- pg_cron (1.6): cron.job, cron.job_run_details and alter_job with pg_cron's
-- parameter names; production's webhook job (jobid 3) and one other job.
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
  (3, 'process_webhook_jobs', '30 seconds', 'select public.process_webhook_jobs()', true),
  (4, 'app_push_jobs_drain',  '30 seconds', 'select public.process_app_push_jobs()', true);
select setval('cron.job_jobid_seq', 4);
insert into cron.job_run_details (jobid, status, start_time, end_time) values
  (3, 'succeeded', now() - interval '1 minute', now() - interval '1 minute'),
  (3, 'running',   now() - interval '20 minutes', null),   -- stale: a crash leftover
  (4, 'running',   now() - interval '1 minute', null);     -- another job's run

-- the suite's own probes, outside public
create schema b1t;
create function b1t.snapshot() returns text language plpgsql as $$
declare
  r text;
  x text;
begin
  select coalesce(string_agg(format('%s|%s|%s|%s|%s|%s', p.oid::regprocedure, md5(p.prosrc), p.prosecdef,
                                    p.proconfig, p.proacl, pg_get_userbyid(p.proowner)), ';'
                             order by p.oid::regprocedure::text), 'no worker')
    into r from pg_proc p where p.proname = 'process_webhook_jobs';
  if to_regclass('public.webhook_jobs') is not null then
    execute 'select coalesce(md5(string_agg(t::text, ''|'' order by t.id)), ''empty'') from public.webhook_jobs t' into x;
    r := r || '#rows=' || x || '#comment=' || coalesce(md5(col_description('public.webhook_jobs'::regclass,
                 (select attnum from pg_attribute where attrelid = 'public.webhook_jobs'::regclass
                    and attname = 'processed_at'))), 'none');
  end if;
  execute 'select string_agg(j::text, ''|'' order by j.jobid) from cron.job j' into x;
  return r || '#cron=' || coalesce(x, 'none') || '#calls=' || (select count(*) from net.v089_calls);
end $$;
SQL

cat > "$WORK/users.sql" <<SQL
insert into auth.users (id, email) values ('$UA', 'a@test.local'), ('$UB', 'b@test.local');
insert into public.devices (id, user_id, name, helper_secret)
values ('$DEV', '$UA', 'test-mac', encode(extensions.digest('test-helper-secret', 'sha256'), 'hex'));
SQL

# The upgrade path's database: production's shape before v0.89.
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
    # production's grant (Supabase's default privileges; v0.62 revoked only anon/authenticated)
    q -c "grant execute on function public.process_webhook_jobs() to service_role" >/dev/null
    apply "$WORK/stubs.sql"; apply "$WORK/users.sql"
}
build_fresh() {
    apply "$SHIM"; apply "$SQL_DIR/schema.sql"; apply "$SQL_DIR/app_rpc.sql"; apply "$SQL_DIR/helper_rpc.sql"
    apply "$WORK/stubs.sql"; apply "$WORK/users.sql"
}

# ── the worker, driven the way pg_cron drives it ────────────────────────────
P=""   # the label prefix of the current case: [upgrade], [fresh], [mutant] ...
invoke() { # one call, its own transaction; anything it prints (a WARNING) fails the case
    local out; out="$(q -c "select public.process_webhook_jobs()" 2>&1)"
    [[ -z "${out//[[:space:]]/}" ]] || fail "$P the worker call printed: $(head -2 <<<"$out" | tr '\n' ' ')"
}
invoke_raise() { # one call with http_post raising
    local out; out="$(q -c "set v089.post_mode = 'raise'; select public.process_webhook_jobs();" 2>&1)"
    [[ -z "${out//[[:space:]]/}" ]] || fail "$P the worker call printed: $(head -2 <<<"$out" | tr '\n' ' ')"
}
reset_queue() {
    q >/dev/null <<'SQL'
truncate public.webhook_jobs restart identity;
delete from public.alerts;
truncate net._http_response;
truncate net.v089_calls restart identity;
SQL
}
alert() { # alert <alert id> <grouping key> [type]: insert an alert; the trigger may enqueue
    q -c "insert into public.alerts (id, user_id, type, title, grouping_key) values ('$1', '$UA', '${3:-Usage Spike}', 't', '$2')" >/dev/null
}
enqueue() { # enqueue <alert id> <key>: its job, aged past pass 2's 5 s; echoes the job id
    alert "$1" "$2"
    q -c "update public.webhook_jobs set enqueued_at = enqueued_at - interval '6 seconds' where alert_id = '$1' returning id"
}
age() { # age <job id> <interval>
    q -c "update public.webhook_jobs set enqueued_at = enqueued_at - interval '$2', dispatched_at = dispatched_at - interval '$2' where id = $1" >/dev/null
}
respond() { # respond <request id> <status | timeout | error | empty>, and backdate that job's dispatch by 3 s
    local vals
    case "$2" in
        timeout) vals="null, null, true, null" ;;
        error)   vals="null, null, null, 'could not connect'" ;;
        empty)   vals="null, null, false, null" ;;
        *)       vals="$2, 'answer $2', false, null" ;;
    esac
    q >/dev/null <<SQL
insert into net._http_response (id, status_code, content, timed_out, error_msg) values ($1, $vals);
update public.webhook_jobs set dispatched_at = dispatched_at - interval '3 seconds' where pg_net_request_id = $1;
SQL
}
js() { q -c "select attempt_count || ' ' || coalesce('req' || pg_net_request_id, 'noreq') || ' ' || case when processed_at is null then 'pending' else 'final' end from public.webhook_jobs where id = $1"; }
calls() { q -c "select count(*) from net.v089_calls"; }
st() { echo "$(js "$1") calls=$(calls)"; }
lasterr() { q -c "select coalesce(last_error, '<null>') from public.webhook_jobs where id = $1"; }
pat() { q -c "select processed_at from public.webhook_jobs where id = $1"; }
key_jobs() { q -c "select count(*) filter (where processed_at is null) || ' pending of ' || count(*) from public.webhook_jobs where alert_payload->>'grouping_key' = '$1'"; }

# ── behavioural cases (P set by the caller) ─────────────────────────────────
case_502() {
    local j t
    reset_queue; j="$(enqueue a502 k502)"; invoke
    same "$P 502: the first call sends request 1" "$(st "$j")" "1 req1 pending calls=1"
    check "$P 502: request 1 carries the alert to send-webhook as before" \
          "(select url = 'https://stub.invalid/functions/v1/send-webhook' and body->>'user_id' = '$UA'
                   and body->'alert'->>'id' = 'a502' and headers->>'Authorization' = 'Bearer stub-key'
                   and headers->>'X-Internal-Trigger' = 'alerts_dispatch_webhook' and timeout_milliseconds = 5000
              from net.v089_calls where id = 1)"
    respond 1 502; invoke
    same "$P 502: the first 502 is counted and the job redispatched in the same call, not finalized" "$(st "$j")" "3 req2 pending calls=2"
    respond 2 502; invoke
    same "$P 502: the second 502 finalizes the job, and nothing more is sent" "$(st "$j")" "4 noreq final calls=2"
    same "$P 502: its last_error is the second answer" "$(lasterr "$j")" "HTTP 502: answer 502"
    t="$(pat "$j")"; invoke
    same "$P 502: a further call changes nothing and sends nothing" "$(st "$j") $(pat "$j")" "4 noreq final calls=2 $t"
    alert a502n k502
    same "$P 502: a new alert with that key is enqueued again (its dedup slot is free)" "$(key_jobs k502)" "1 pending of 2"
}
case_transport() { # case_transport <timeout|error> <expected detail>
    local j
    reset_queue; j="$(enqueue "at-$1" "kt-$1")"; invoke
    same "$P transport ($1): the first call sends request 1" "$(st "$j")" "1 req1 pending calls=1"
    respond 1 "$1"; invoke
    same "$P transport ($1): the failure counts at once, with no 5-minute wait, and the job is redispatched" "$(st "$j")" "3 req2 pending calls=2"
    respond 2 "$1"; invoke
    same "$P transport ($1): the second failure finalizes the job" "$(st "$j")" "4 noreq final calls=2"
    same "$P transport ($1): its last_error names the transport failure" "$(lasterr "$j")" "transport failure: $2"
}
case_noresp() {
    local j t
    reset_queue; j="$(enqueue anr knr)"; invoke
    same "$P no answer: the first call sends request 1" "$(st "$j")" "1 req1 pending calls=1"
    respond 1 empty; invoke
    same "$P no answer: a response row with nothing completed is no answer: the job waits" "$(st "$j")" "1 req1 pending calls=1"
    age "$j" '6 minutes'; invoke
    same "$P no answer: after 5 minutes the attempt is given up and request 2 sent" "$(st "$j")" "2 req2 pending calls=2"
    age "$j" '6 minutes'; invoke
    same "$P no answer: the third request goes out and the job stays pending while it is live" "$(st "$j")" "3 req3 pending calls=3"
    age "$j" '1 minute'; invoke
    same "$P no answer: under 5 minutes the third request is live: not finalized" "$(st "$j") / $(lasterr "$j")" \
         "3 req3 pending calls=3 / pg_net response not yet available"
    age "$j" '5 minutes'; invoke
    same "$P no answer: after the third request has had no answer for 5 minutes, the job is finalized" "$(st "$j")" "3 noreq final calls=3"
    same "$P no answer: its last_error says it gave up" "$(lasterr "$j")" "gave up: no response from pg_net after 3 attempts"
    t="$(pat "$j")"; invoke
    same "$P no answer: a further call changes nothing" "$(st "$j") $(pat "$j")" "3 noreq final calls=3 $t"
}
case_raise() {
    local j t
    reset_queue; j="$(enqueue ars kars)"
    invoke_raise
    same "$P raise: the first raise counts attempt 1 and sends nothing" "$(st "$j") / $(lasterr "$j")" \
         "1 noreq pending calls=0 / http_post failed: v089 stub: http_post refused"
    invoke_raise
    same "$P raise: the second raise counts attempt 2, not finalized" "$(st "$j")" "2 noreq pending calls=0"
    invoke_raise
    same "$P raise: the third raise finalizes the job" "$(st "$j")" "3 noreq final calls=0"
    t="$(pat "$j")"; invoke
    same "$P raise: a working http_post afterwards sends nothing for it" "$(st "$j") $(pat "$j")" "3 noreq final calls=0 $t"
}
case_2xx() {
    local j t
    reset_queue; j="$(enqueue a200 k200)"; invoke; respond 1 200; invoke
    same "$P 2xx: an answer to the first request finalizes the job successfully" "$(st "$j") / $(lasterr "$j")" "1 req1 final calls=1 / <null>"
    t="$(pat "$j")"; invoke
    same "$P 2xx: a further call leaves processed_at as it was and sends nothing" "$(st "$j") $(pat "$j")" "1 req1 final calls=1 $t"
    reset_queue; j="$(enqueue a2003 k2003)"; invoke; age "$j" '6 minutes'; invoke; age "$j" '6 minutes'; invoke
    same "$P 2xx on the third request: it goes out, the job pending" "$(st "$j")" "3 req3 pending calls=3"
    respond 3 204; invoke
    same "$P 2xx on the third request: it finalizes the job successfully" "$(st "$j") / $(lasterr "$j")" "3 req3 final calls=3 / <null>"
    t="$(pat "$j")"; invoke
    same "$P 2xx on the third request: a further call changes nothing" "$(st "$j") $(pat "$j")" "3 req3 final calls=3 $t"
}
case_malformed() {
    local j
    reset_queue; j="$(enqueue am1 km1)"
    q >/dev/null <<SQL
update public.webhook_jobs set pg_net_request_id = 900, dispatched_at = null, attempt_count = 1,
       enqueued_at = now() - interval '10 seconds' where id = $j;
insert into net._http_response (id, status_code, content, timed_out) values (900, 200, 'ok', false);
SQL
    invoke
    same "$P malformed: a request id without dispatched_at, answered 200, is reconciled and finalized" "$(st "$j") / $(lasterr "$j")" "1 req900 final calls=0 / <null>"
    reset_queue; j="$(enqueue am2 km2)"
    q -c "update public.webhook_jobs set pg_net_request_id = 901, dispatched_at = null, attempt_count = 1, enqueued_at = now() - interval '10 minutes' where id = $j" >/dev/null
    invoke
    same "$P malformed: one with no answer, enqueued 10 minutes ago, has its request id cleared and a new request sent" "$(st "$j")" "2 req1 pending calls=1"
}
case_serialization() {
    local j bg
    reset_queue; j="$(enqueue asr ksr)"
    psql "$DB" --no-psqlrc -qtAX -c "select pg_advisory_lock($LOCK_KEY)" -c "select pg_sleep(60)" >/dev/null 2>&1 &
    bg=$!; BGPIDS+=("$bg")
    wait_for "exists (select 1 from pg_locks where locktype = 'advisory' and granted and database = (select oid from pg_database where datname = current_database()))"
    invoke
    same "$P one call at a time: while another session holds the lock, a call sends nothing and changes no job" \
         "$(st "$j") / $(lasterr "$j")" "0 noreq pending calls=0 / <null>"
    q -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() and query = 'select pg_sleep(60)'" >/dev/null
    wait "$bg" >/dev/null 2>&1 || true
    invoke
    same "$P one call at a time: once the lock is free, a call sends the job" "$(st "$j")" "1 req1 pending calls=1"
}
case_dedup() {
    reset_queue
    alert ad1 kd; alert ad2 kd; alert ad3 kd2; alert ad4 kd3 Test
    same "$P dedup: two alerts with one key give one job, another key a second, a Test alert none" \
         "$(q -c "select string_agg(alert_id, ',' order by id) from public.webhook_jobs")" "ad1,ad3"
    q -c "update public.webhook_jobs set enqueued_at = enqueued_at - interval '6 seconds'" >/dev/null
    invoke
    same "$P dedup: one call per job" "$(calls) $(q -c "select string_agg(body->'alert'->>'id', ',' order by id) from net.v089_calls")" "2 ad1,ad3"
    same "$P dedup: the partial unique index is unchanged" \
         "$(q -c "select indexdef from pg_indexes where schemaname = 'public' and indexname = 'idx_webhook_jobs_pending_dedup'")" \
         "CREATE UNIQUE INDEX idx_webhook_jobs_pending_dedup ON public.webhook_jobs USING btree (user_id, ((alert_payload ->> 'grouping_key'::text))) WHERE (processed_at IS NULL)"
}
case_transport_timeout() { case_transport timeout "timed out"; }
case_transport_error() { case_transport error "could not connect"; }
run_cases() {
    case_502; case_transport timeout "timed out"; case_transport error "could not connect"; case_noresp
    case_raise; case_2xx; case_malformed; case_serialization; case_dedup
}

# ── backfill fixture: one row per kind the backfill must or must not touch ──
backfill_rows() {
    q >/dev/null <<SQL
insert into public.webhook_jobs (user_id, alert_id, alert_payload, enqueued_at, pg_net_request_id, dispatched_at, processed_at, attempt_count, last_error) values
  ('$UA', 'bf-a',  '{"grouping_key":"bf-a"}',  now() - interval '1 day',  null, null, null, 4, 'HTTP 502: answer 502'),
  ('$UA', 'bf-a3', '{"grouping_key":"bf-a3"}', now() - interval '1 day',  null, null, null, 3, 'http_post failed: refused'),
  ('$UA', 'bf-b',  '{"grouping_key":"bf-b"}',  now() - interval '1 hour', 950, now() - interval '1 minute', null, 3, null),
  ('$UA', 'bf-c',  '{"grouping_key":"bf-c"}',  now() - interval '1 hour', 951, now() - interval '10 minutes', null, 3, 'pg_net response not yet available'),
  ('$UA', 'bf-d',  '{"grouping_key":"bf-d"}',  now() - interval '1 hour', null, null, null, 2, 'HTTP 500: answer 500'),
  ('$UA', 'bf-e',  '{"grouping_key":"bf-e"}',  now() - interval '2 days', 940, now() - interval '2 days', now() - interval '2 days', 5, 'HTTP 500: old');
create table b1t.bf_before as select * from public.webhook_jobs;
SQL
}
row_of() { q -c "select row(enqueued_at, pg_net_request_id, dispatched_at, processed_at, attempt_count, last_error)::text from $2 where alert_id = '$1'"; }
backfill_checks() { # what the migration's backfill (or a mutant of it) did to the fixture
    local r
    for r in b c d e; do
        same "$P backfill: row $r is untouched" "$(row_of "bf-$r" public.webhook_jobs)" "$(row_of "bf-$r" b1t.bf_before)"
    done
    check "$P backfill: rows a and a3 (no request id, attempt_count 4 and 3) are finalized, last_error prefixed, nothing else changed" \
          "(select count(*) = 2 and bool_and(n.processed_at is not null
                   and n.last_error = 'v0.89 backfill: retries exhausted before v0.89; ' || o.last_error
                   and n.attempt_count = o.attempt_count and n.pg_net_request_id is null and n.dispatched_at is null
                   and n.enqueued_at = o.enqueued_at)
              from public.webhook_jobs n join b1t.bf_before o using (id) where n.alert_id in ('bf-a', 'bf-a3'))"
}

# refuses <label> <regex the error must match> [role]: apply v0.89 to $DB; it
# must fail, on that guard, and leave everything b1t.snapshot() sees as it was.
refuses() {
    local before after out rc=0
    before="$(q -c "select b1t.snapshot()")"
    out="$(migrate "$MIG" "${3:-}")" || rc=$?
    after="$(q -c "select b1t.snapshot()")"
    if (( rc == 0 )); then fail "$1: the migration applied"
    elif ! grep -q -E -- "$2" <<<"$out"; then fail "$1: refused, but not by /$2/: $(grep -m1 -E 'ERROR' <<<"$out")"
    elif [[ "$before" != "$after" ]]; then fail "$1: refused, but something changed"
    else pass "$1"; fi
}
applies() { # applies <label> [role]: apply v0.89 to $DB; it must succeed; echoes nothing, keeps its output in LAST_OUT
    local rc=0
    LAST_OUT="$(migrate "$MIG" "${2:-}")" || rc=$?
    if (( rc == 0 )); then pass "$1"; else fail "$1: $(grep -m1 -E 'ERROR' <<<"$LAST_OUT")"; fi
}
LAST_OUT=""
MIG="$V089"
pause_job() { # the header's P2, as printed; it must touch exactly one job
    local out; out="$(psql "$DB" --no-psqlrc -X -v ON_ERROR_STOP=1 -c "$(hq P2)" 2>&1)"
    grep -q '(1 row)' <<<"$out" || fail "$P P2 (pause) did not return exactly one row: $out"
}
restore_job() { # restore_job <recorded active value>: the header's R9 with that value put in
    local r8 out
    r8="$(hq R9)"
    [[ "$(grep -o '<recorded active>' <<<"$r8" | wc -l | tr -d ' ')" == 1 ]] || { echo "R9: want one <recorded active>" >&2; exit 2; }
    out="$(psql "$DB" --no-psqlrc -X -v ON_ERROR_STOP=1 -c "${r8/<recorded active>/$1}" 2>&1)"
    grep -q '(1 row)' <<<"$out" || fail "$P R9 (restore $1) did not return exactly one row: $out"
}
q0() { q -c "$(hq Q0)"; }
q3() { q -c "$(hq Q3)"; }
q5() { q -c "$(hq Q5)"; }
worker_md5() { q -c "select md5(prosrc) from pg_proc where oid = 'public.process_webhook_jobs()'::regprocedure"; }
notice() { grep -E 'NOTICE: +v0\.89: ' <<<"$1" | grep -v 'queue lock was held' | sed -E 's/.*NOTICE: +v0\.89: //' | paste -sd'|' -; }
lock_ms() { grep -oE 'queue lock was held [0-9]+ ms' <<<"$1" | grep -oE '[0-9]+' | tail -1; }

SU="$(psql "$DATABASE_URL" -qtAX -c 'select current_user')"
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }

# =============================================================================
echo "== 0. md5 values (the header's and the guard's against the files)"
newdb "${PFX}_md5"; apply "$SHIM"
body_md5() { # body_md5 <file holding the worker's CREATE statement>
    q -c "drop function if exists public.process_webhook_jobs()" >/dev/null
    apply "$1"
    worker_md5
}
n25="$(grep -c -x 'create or replace function public.process_webhook_jobs()' "$V025" || true)"
[[ "$n25" == 1 ]] || { echo "v0.25: want one worker CREATE line, found $n25" >&2; exit 2; }
sed -n '/^create or replace function public\.process_webhook_jobs()$/,/^\$\$ language plpgsql security definer set search_path = pg_catalog, extensions, public, net;$/p' "$V025" > "$WORK/w25.sql"
tail -n 1 "$WORK/w25.sql" | grep -q '^\$\$ language plpgsql' || { echo "v0.25: the worker cut does not end on its language line" >&2; exit 2; }
strip_comment_lines "$WORK/w25.sql" > "$WORK/w25.prod.sql"
between "$V089" worker > "$WORK/worker.sql"
between "$V089" backfill > "$WORK/backfill.sql"
grep -q '^create or replace function public\.process_webhook_jobs()$' "$WORK/worker.sql" \
    || { echo "the worker markers do not hold the worker" >&2; exit 2; }
strip_comment_lines "$WORK/worker.sql" > "$WORK/worker.stripped.sql"
FILES25="$(body_md5 "$WORK/w25.sql")"
PROD25="$(body_md5 "$WORK/w25.prod.sql")"
RAW89="$(body_md5 "$WORK/worker.sql")"
STRIP89="$(body_md5 "$WORK/worker.stripped.sql")"
same "0. v0.25's worker without its comment-only lines is production's measured body" "$PROD25" "$PROD_WORKER_MD5"
q -c "drop function if exists public.process_webhook_jobs()" >/dev/null; apply "$FROZEN/app_rpc_block.sql"
same "0. B0's frozen worker block holds v0.25's body as the file has it" "$(worker_md5)" "$FILES25"
if [[ "$RAW89" != "$STRIP89" ]]; then pass "0. v0.89's body has comment-only lines, so its two forms differ and both are listed"
else fail "0. v0.89's raw and stripped bodies are equal: the header's two 'after' values would be one"; fi
same "0. the header's MD5 VALUES are the four bodies, in order" \
     "$(grep -E '^--   (before|after) +v0\.(25|89), ' "$V089" | grep -oE '[0-9a-f]{32}$' | paste -sd' ' -)" \
     "$PROD25 $FILES25 $RAW89 $STRIP89"
same "0. the md5 literals in the migration's code are exactly those four" \
     "$(sed -n '/^begin;$/,$p' "$V089" | grep -oE "'[0-9a-f]{32}'" | tr -d "'" | sort -u | paste -sd' ' -)" \
     "$(printf '%s\n' "$PROD25" "$FILES25" "$RAW89" "$STRIP89" | sort -u | paste -sd' ' -)"
same "0. the guard (A2) lists all four" \
     "$(sed -n '/^do \$guard\$$/,/^\$guard\$;$/p' "$V089" | grep -oE "'[0-9a-f]{32}'" | tr -d "'" | sort | paste -sd' ' -)" \
     "$(printf '%s\n' "$PROD25" "$FILES25" "$RAW89" "$STRIP89" | sort | paste -sd' ' -)"
same "0. the verification (E) lists the two 'after' values only" \
     "$(sed -n '/^do \$verify\$$/,/^\$verify\$;$/p' "$V089" | grep -oE "'[0-9a-f]{32}'" | tr -d "'" | sort | paste -sd' ' -)" \
     "$(printf '%s\n' "$RAW89" "$STRIP89" | sort | paste -sd' ' -)"
same "0. step 0 (Q0) expects production's body on a first apply" "$(grep -c -E "^--    FIRST APPLY: expect body_md5 = $PROD_WORKER_MD5,$" "$V089")" "1"
HDR="$(sed -n '1,/^begin;$/p' "$V089" | sed -E 's/^-- ?//' | tr '\n' ' ' | tr -s ' ')"
if [[ "$HDR" == *"RE-RUN OR RECOVERY: body_md5 = $RAW89 or $STRIP89 "* ]]; then pass "0. step 0 accepts the two v0.89 bodies on a re-run or in recovery"
else fail "0. step 0's RE-RUN OR RECOVERY line does not list $RAW89 and $STRIP89"; fi
held="$(grep -c -x 'commit;' "$V089" || true)"
[[ "$held" == 1 ]] || { echo "the migration must end with exactly one 'commit;' line (found $held)" >&2; exit 2; }
dropdb_now "${PFX}_md5"

# =============================================================================
echo "== 1. control: the bug, on the old body (upgrade path, before v0.89)"
newdb "${PFX}_upbase"; build_upgrade_base
same "1. the upgrade base runs production's worker body" "$(worker_md5)" "$PROD_WORKER_MD5"
same "1. and production's trigger function body" \
     "$(q -c "select md5(prosrc) from pg_proc where oid = 'public.alerts_enqueue_webhook()'::regprocedure")" "$PROD_ENQUEUE_MD5"
same "1. and production's worker ACL" \
     "$(q -c "select proacl::text from pg_proc where oid = 'public.process_webhook_jobs()'::regprocedure")" \
     "{$SU=X/$SU,service_role=X/$SU}"
newdb "${PFX}_ctl" "${PFX}_upbase"
P="[v0.25 control]"
reset_queue; j="$(enqueue c502 kc502)"; invoke; respond 1 502; invoke; respond 2 502; invoke; invoke
same "$P a 502 twice ends at attempt 4, pending forever, after 2 requests" "$(st "$j")" "4 noreq pending calls=2"
alert c502n kc502
same "$P and a new alert with that key is never enqueued" "$(key_jobs kc502)" "1 pending of 1"
reset_queue; j="$(enqueue cnr kcnr)"; invoke; age "$j" '6 minutes'; invoke; age "$j" '6 minutes'; invoke
age "$j" '6 minutes'; invoke; invoke
same "$P no answer ends at attempt 3, pending forever, after 3 requests" "$(st "$j")" "3 noreq pending calls=3"
reset_queue; j="$(enqueue crs kcrs)"; invoke_raise; invoke_raise; invoke_raise; invoke_raise
same "$P three raises end at attempt 3, pending forever" "$(st "$j")" "3 noreq pending calls=0"
reset_queue; j="$(enqueue ctt kctt)"; invoke; respond 1 timeout; invoke
same "$P a timed-out request is read as no answer yet (it waits 5 minutes)" "$(st "$j")" "1 req1 pending calls=1"
reset_queue; j="$(enqueue cmf kcmf)"
q -c "update public.webhook_jobs set pg_net_request_id = 900, dispatched_at = null, attempt_count = 1, enqueued_at = now() - interval '10 minutes' where id = $j; insert into net._http_response (id, status_code, timed_out) values (900, 200, false);" >/dev/null
invoke
same "$P a request id without dispatched_at is never reconciled" "$(st "$j")" "1 req900 pending calls=0"
dropdb_now "${PFX}_ctl"

# =============================================================================
echo "== 2. upgrade: the header's steps, as printed"
newdb "${PFX}_up" "${PFX}_upbase"
P="[upgrade]"
ACL_UP="$(q -c "select md5('{$SU=X/$SU,service_role=X/$SU}')")"
ACL_FR="$(q -c "select md5('{$SU=X/$SU}')")"
JOB_MD5="$(q -c "select md5('3|process_webhook_jobs|30 seconds|select public.process_webhook_jobs()|$SU')")"
same "$P Q0 before (hashes and booleans only): production's body, one function, attributes, applier, grants, ACL, no comment" \
     "$(q0)" "$PROD_WORKER_MD5|1|t|t|t|$ACL_UP|"
hvals() { grep -oE "$1 = [0-9a-f]{32}" <<<"$HDR" | grep -oE '[0-9a-f]{32}' | sort -u | paste -sd' ' -; }
if [[ "$SU" == postgres ]]; then   # the header states production's values, whose role is postgres
    same "$P the header's expected acl_md5 is this ACL's (production's)" "$(hvals acl_md5)" "$ACL_UP"
    same "$P the header's expected job_md5 is this job's (production's)" "$(hvals job_md5)" "$JOB_MD5"
fi
FP_BEFORE="$(q -f "$OPS")"
for l in Q1 Q1b Q2b Q3b Q9; do q -c "$(hq "$l")" >/dev/null || fail "$P $l does not run as printed"; done
same "$P Q1 returns counts only (no timestamp column)" \
     "$(psql "$DB" --no-psqlrc -X -A -c "$(hq Q1)" | head -1)" \
     "total|pending|stuck|awaiting|malformed_id_without_dispatch|never_dispatched_old|finalized_with_request_id|odd_counts"
same "$P Q2: both secrets once, non-empty (no value selected)" "$(q -c "$(hq Q2)" | sort | paste -sd' ' -)" \
     "app_service_role_key|1|1 app_supabase_url|1|1"
same "$P Q3: exactly one webhook job, active, its definition's hash" "$(q3)" "1|true|$JOB_MD5"
q -c "$(hq R0)" > "$WORK/rollback.sql"; echo ';' >> "$WORK/rollback.sql"
grep -q 'CREATE OR REPLACE FUNCTION public.process_webhook_jobs()' "$WORK/rollback.sql" || fail "$P R0 did not print the worker's definition"
pause_job
same "$P P2 paused the webhook job and nothing else" \
     "$(q -c "select string_agg(jobid || '=' || active, ' ' order by jobid) from cron.job")" "3=false 4=true"
same "$P Q3 after the pause" "$(q3)" "1|false|$JOB_MD5"
same "$P Q4: nothing running, no idle transaction holding the queue, nobody holding the queue, everybody visible" "$(q -c "$(hq Q4)")" "0|0|0|0"
same "$P Q4b: a 'running' row 20 minutes old does not count" "$(q -c "$(hq Q4b)")" "0"
q -c "insert into cron.job_run_details (jobid, status, start_time) values (3, 'starting', now() - interval '1 minute')" >/dev/null
same "$P Q4b: a recent 'starting' row does" "$(q -c "$(hq Q4b)")" "1"
q -c "update cron.job_run_details set status = 'succeeded', end_time = now() where status = 'starting'" >/dev/null
same "$P Q5: the recount right before the apply" "$(q5)" "0"
same "$P Q6 before the apply: no worker lock, no apply session" "$(q -c "$(hq Q6)")" "0|0"
applies "$P the migration applies on production's shape, the job paused"
ms="$(lock_ms "$LAST_OUT")"
if [[ -n "$ms" ]]; then pass "$P its NOTICE gives the queue lock's hold time ($ms ms here, empty queue)"; else fail "$P no 'queue lock was held' NOTICE"; fi
same "$P its NOTICEs: applier and owner, nothing to backfill, the body it installed" "$(notice "$LAST_OUT")" \
     "applier $SU, worker owner $SU|backfilled 0 stuck job(s): finalized with failure, nothing re-sent|worker replaced (body md5 $RAW89), owner and ACL unchanged"
COMMENT_MD5="$(q -c "select md5(col_description('public.webhook_jobs'::regclass, 8))")"
same "$P Q0 after: v0.89's body and the comment, everything else as before" "$(q0)" "$RAW89|1|t|t|t|$ACL_UP|$COMMENT_MD5"
same "$P every comment_md5 the header expects is the comment's" \
     "$(grep -oE 'comment_md5 =? ?[0-9a-f]{32}' <<<"$HDR" | grep -oE '[0-9a-f]{32}' | sort -u | paste -sd' ' -)" "$COMMENT_MD5"
same "$P Q3 after the apply: one job, same definition, still paused" "$(q3)" "1|false|$JOB_MD5"
restore_job true
same "$P R9 restored the recorded value (true); Q3 as in step 0" "$(q3)" "1|true|$JOB_MD5"
FP_AFTER="$(q -f "$OPS")"
same "$P fingerprint: only the worker's line and processed_at's line changed" \
     "$(diff <(echo "$FP_BEFORE") <(echo "$FP_AFTER") | grep -E '^[<>] ' \
        | sed -E 's/^([<>]) (1b\|process_webhook_jobs|2a\|col\|[0-9]+\|processed_at)\|.*/\1 \2/' | sort | paste -sd' ' -)" \
     "< 1b|process_webhook_jobs < 2a|col|8|processed_at > 1b|process_webhook_jobs > 2a|col|8|processed_at"
same "$P fingerprint: the worker's line moved in its body md5 only" \
     "$(diff <(grep '^1b|process_webhook_jobs|' <<<"$FP_BEFORE" | sed "s/$PROD_WORKER_MD5/X/") <(grep '^1b|process_webhook_jobs|' <<<"$FP_AFTER" | sed "s/$RAW89/X/") >/dev/null && echo same)" "same"
check "$P contract: SECURITY DEFINER, search_path pinned, no arguments, returns void, plpgsql" \
      "(select p.prosecdef and p.proconfig = array['search_path=pg_catalog, extensions, public, net']
               and pg_get_function_identity_arguments(p.oid) = '' and p.prorettype = 'void'::regtype and l.lanname = 'plpgsql'
          from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = 'public.process_webhook_jobs()'::regprocedure)"
check "$P contract: anon and authenticated cannot execute it, service_role can (as before)" \
      "not has_function_privilege('anon', 'public.process_webhook_jobs()', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.process_webhook_jobs()', 'EXECUTE')
       and has_function_privilege('service_role', 'public.process_webhook_jobs()', 'EXECUTE')"
check "$P the column comment says FINALIZED, and is schema.sql's" \
      "col_description('public.webhook_jobs'::regclass, 8) like 'FINALIZED, not delivered (v0.89).%'"
pause_job
applies "$P applied a second time"
same "$P second time: nothing backfilled, same body, owner and ACL" "$(notice "$LAST_OUT") / $(q0)" \
     "applier $SU, worker owner $SU|backfilled 0 stuck job(s): finalized with failure, nothing re-sent|worker replaced (body md5 $RAW89), owner and ACL unchanged / $RAW89|1|t|t|t|$ACL_UP|$COMMENT_MD5"
restore_job true

# =============================================================================
echo "== 3. fresh install (the baseline files)"
newdb "${PFX}_fr"; build_fresh
P="[fresh]"
same "$P Q0: the baseline installs v0.89's body and the comment, owner-only ACL" "$(q0)" "$RAW89|1|t|t|t|$ACL_FR|$COMMENT_MD5"
check "$P the baseline carries the comment on processed_at" \
      "col_description('public.webhook_jobs'::regclass, 8) like 'FINALIZED, not delivered (v0.89).%'"
pause_job
applies "$P the migration re-applies on a fresh install (its own body)"
same "$P nothing backfilled, body, ACL and comment unchanged" "$(notice "$LAST_OUT" | cut -d'|' -f2) / $(q0)" \
     "backfilled 0 stuck job(s): finalized with failure, nothing re-sent / $RAW89|1|t|t|t|$ACL_FR|$COMMENT_MD5"
restore_job true

# =============================================================================
echo "== 4. behaviour, both paths"
for path in up fr; do
    newdb "${PFX}_cases_$path" "${PFX}_$path"
    if [[ $path == up ]]; then P="[upgrade]"; else P="[fresh]"; fi
    run_cases
    dropdb_now "${PFX}_cases_$path"
done

# =============================================================================
echo "== 5. backfill (upgrade path)"
newdb "${PFX}_bf" "${PFX}_upbase"
P="[upgrade]"
backfill_rows
q1_stuck="$(q -c "select stuck from ($(hq Q1 | sed 's/;$//')) q1")"
same "$P Q1 (preliminary) counts the two stuck rows" "$q1_stuck" "2"
same "$P Q1b, by attempt_count" "$(q -c "$(hq Q1b)" | paste -sd' ' -)" "2|1 3|3 4|1"
pause_job
# the old worker was still running between Q1 and the pause: one more job used its attempts up
q -c "insert into public.webhook_jobs (user_id, alert_id, alert_payload, attempt_count, last_error) values ('$UA', 'bf-late', '{\"grouping_key\":\"bf-late\"}', 4, 'HTTP 502: late')" >/dev/null
same "$P Q4 after the pause: quiet" "$(q -c "$(hq Q4)")" "0|0|0|0"
n_stuck="$(q5)"
same "$P Q5, the recount after the pause, sees the job that got stuck after Q1" "$n_stuck" "3"
applies "$P the migration applies with stuck rows"
same "$P its NOTICE backfilled the recount (not Q1's preliminary count)" "$(notice "$LAST_OUT" | cut -d'|' -f2)" \
     "backfilled $n_stuck stuck job(s): finalized with failure, nothing re-sent"
backfill_checks
same "$P Q5 after: stuck = 0" "$(q5)" "0"
restore_job true
invoke
same "$P row b (third request live for 1 minute) stays pending under the new worker" "$(q -c "select attempt_count || ' ' || pg_net_request_id || ' ' || (processed_at is null) from public.webhook_jobs where alert_id = 'bf-b'")" "3 950 true"
same "$P row c (third request, no answer for 10 minutes) is given up by the new worker" \
     "$(q -c "select (processed_at is not null) || ' ' || coalesce(pg_net_request_id::text, 'noreq') || ' ' || last_error from public.webhook_jobs where alert_id = 'bf-c'")" \
     "true noreq gave up: no response from pg_net after 3 attempts"
same "$P row d (attempt 2) gets its third request" "$(q -c "select attempt_count || ' req' || pg_net_request_id || ' ' || (processed_at is null) from public.webhook_jobs where alert_id = 'bf-d'") calls=$(calls)" "3 req1 true calls=1"
same "$P Q5 (new stuck) stays 0 under the new worker" "$(q5)" "0"
# rollback: R0's saved definition, the job paused
pause_job
apply "$WORK/rollback.sql"
same "$P rollback: R0's saved definition restores production's body; ACL unchanged, the comment stays" \
     "$(q0)" "$PROD_WORKER_MD5|1|t|t|t|$ACL_UP|$COMMENT_MD5"
check "$P rollback: the backfilled rows stay finalized" \
      "(select bool_and(processed_at is not null and last_error like 'v0.89 backfill: %') from public.webhook_jobs where alert_id in ('bf-a', 'bf-a3'))"
restore_job true
dropdb_now "${PFX}_bf"

newdb "${PFX}_bfs" "${PFX}_upbase"
q -c "insert into public.webhook_jobs (user_id, alert_id, alert_payload, attempt_count, last_error)
      select '$UA', 'bulk-' || i, jsonb_build_object('grouping_key', 'bulk-' || i), 4, 'HTTP 502: x'
        from generate_series(1, 5001) i" >/dev/null
backfill_rows
pause_job
refuses "$P size guard: 5003 stuck jobs: refused, nothing changed" 'more than 5000'
q -c "$(hq BF)" >/dev/null
n_stuck="$(q5)"
same "$P one BF batch, as printed, finalizes 1000 (job still paused; Q5 recounts)" "$n_stuck / $(q3)" "4003 / 1|false|$JOB_MD5"
applies "$P after it the migration applies"
same "$P and backfills the rest (the recount after the batch)" "$(notice "$LAST_OUT" | cut -d'|' -f2)" \
     "backfilled $n_stuck stuck job(s): finalized with failure, nothing re-sent"
backfill_checks
dropdb_now "${PFX}_bfs"

# =============================================================================
echo "== 6. re-runs (bodies with and without comment-only lines)"
strip_comment_lines "$V089" > "$WORK/v089.stripped.sql"
newdb "${PFX}_rr" "${PFX}_upbase"
P="[re-run]"
pause_job
rc=0; LAST_OUT="$(migrate "$WORK/v089.stripped.sql")" || rc=$?
same "$P the migration without its comment-only lines applies on production's body" "$rc / $(worker_md5)" "0 / $STRIP89"
applies "$P then as written, over the stripped v0.89 body"
same "$P which installs the raw body" "$(worker_md5)" "$RAW89"
rc=0; LAST_OUT="$(migrate "$WORK/v089.stripped.sql")" || rc=$?
same "$P and stripped again, over the raw v0.89 body" "$rc / $(worker_md5)" "0 / $STRIP89"
dropdb_now "${PFX}_rr"
newdb "${PFX}_rr25" "${PFX}_upbase"
q -f "$FROZEN/app_rpc_block.sql" >/dev/null
same "$P a database on v0.25's body as the files have it (B0's baseline)" "$(worker_md5)" "$FILES25"
pause_job
applies "$P the migration applies there too"
same "$P installing v0.89's body" "$(worker_md5)" "$RAW89"
dropdb_now "${PFX}_rr25"

# =============================================================================
echo "== 7. guards: each refuses and changes nothing"
psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 \
    -c "create role $STRANGER nologin" -c "create role $MEMBER nologin" -c "grant $SU to $MEMBER" >/dev/null
newdb "${PFX}_gb" "${PFX}_upbase"
P="[guard]"
pause_job; backfill_rows
G=0
guard() { # guard <label> <regex> <setup sql or ""> [role]
    G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_gb"
    [[ -z "$3" ]] || q >/dev/null <<<"$3"
    refuses "$P $1: refused, nothing changed" "$2" "${4:-}"
    dropdb_now "${PFX}_g$G"
}
guard "no webhook_jobs table" 'public\.webhook_jobs does not exist' \
      "drop table public.webhook_jobs cascade;"
guard "the enqueue trigger disabled" 'trigger alerts_webhook_enqueue on public\.alerts is missing, disabled' \
      "alter table public.alerts disable trigger alerts_webhook_enqueue;"
guard "a second process_webhook_jobs in another schema" 'expected exactly one function named process_webhook_jobs' \
      "create schema other; create function other.process_webhook_jobs() returns void language sql as 'select';"
guard "an overload in public" 'expected exactly one function named process_webhook_jobs' \
      "create function public.process_webhook_jobs(integer) returns void language sql as 'select';"
guard "net._http_response without timed_out" 'net\._http_response lacks timed_out' \
      "alter table net._http_response drop column timed_out;"
guard "a foreign body that contains the old error text and 'v0.89'" 'unexpected definition \(body md5 [0-9a-f]+\), rebase required' \
      "create or replace function public.process_webhook_jobs() returns void as \$\$
begin
  -- v0.89: pg_net response not yet available
  raise warning 'process_webhook_jobs reconcile (job %): %', 0, 'pg_net response not yet available, v0.89';
end;
\$\$ language plpgsql security definer set search_path = pg_catalog, extensions, public, net;"
guard "SECURITY INVOKER" 'is not SECURITY DEFINER' \
      "alter function public.process_webhook_jobs() security invoker;"
guard "another search_path" 'has proconfig .*expected \{search_path=pg_catalog, extensions, public, net\}' \
      "alter function public.process_webhook_jobs() set search_path = public;"
guard "EXECUTE granted to authenticated" 'PUBLIC, anon or authenticated may execute' \
      "grant execute on function public.process_webhook_jobs() to authenticated;"
guard "EXECUTE granted to PUBLIC" 'PUBLIC, anon or authenticated may execute' \
      "grant execute on function public.process_webhook_jobs() to public;"
guard "an applier that is neither the owner nor a member of it" "$STRANGER is neither the owner .* nor a member" \
      "" "$STRANGER"
guard "the cron job still active" 'cron job 3 \(process_webhook_jobs\) is active; pause it first' \
      "update cron.job set active = true where jobid = 3;"
guard "a second cron job calling the worker" 'expected exactly one cron job calling process_webhook_jobs, found 2' \
      "insert into cron.job (jobname, schedule, command, active) values ('webhook_again', '1 minute', 'SELECT PUBLIC.PROCESS_WEBHOOK_JOBS();', false);"
guard "a cron job whose user cannot execute the worker" 'cron job 3 runs as anon, which cannot execute' \
      "update cron.job set username = 'anon' where jobid = 3;"
guard "a cron job whose user does not exist" 'cron job 3 runs as no_such_role_v089, which cannot execute' \
      "update cron.job set username = 'no_such_role_v089' where jobid = 3;"
# a session running the worker (upper case: tools may upper-case SQL)
G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_gb"
psql "$DB" --no-psqlrc -qtAX -c "SELECT PUBLIC.PROCESS_WEBHOOK_JOBS(), PG_SLEEP(60)" >/dev/null 2>&1 &
bg=$!; BGPIDS+=("$bg")
wait_for "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'active' and query like '%PG_SLEEP(60)%')"
refuses "$P a session running the worker (its query in upper case): refused, nothing changed" 'another session is running a query that names process_webhook_jobs'
q -c "select pg_terminate_backend(pid) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query like '%PG_SLEEP(60)%'" >/dev/null
wait "$bg" >/dev/null 2>&1 || true
dropdb_now "${PFX}_g$G"
# a session holding the worker's catalog row: the replace gives up at lock_timeout
G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_gb"
psql "$DB" --no-psqlrc -qtAX -c "begin" -c "alter function public.process_webhook_jobs() set work_mem = '64kB'" -c "select pg_sleep(60)" >/dev/null 2>&1 &
bg=$!; BGPIDS+=("$bg")
wait_for "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'active' and query = 'select pg_sleep(60)')"
t0=$SECONDS
refuses "$P a session holding the worker's catalog row: the replace gives up at lock_timeout, nothing changed" 'lock timeout'
(( SECONDS - t0 < 30 )) && pass "$P and it gave up within 30 s ($((SECONDS - t0)) s)" || fail "$P it took $((SECONDS - t0)) s"
q -c "select pg_terminate_backend(pid) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query = 'select pg_sleep(60)'" >/dev/null
wait "$bg" >/dev/null 2>&1 || true
dropdb_now "${PFX}_g$G"
# what must NOT block: a monitoring query, and a session in another database
G=$((G + 1)); newdb "${PFX}_other"; newdb "${PFX}_g$G" "${PFX}_gb"
psql "$DB" --no-psqlrc -qtAX -c "select pg_sleep(60), 'process_webhook_jobs()' as watched, (select count(*) from pg_stat_activity)" >/dev/null 2>&1 &
bg1=$!; BGPIDS+=("$bg1")
psql "$BASE/${PFX}_other" --no-psqlrc -qtAX -c "select pg_sleep(60) /* public.process_webhook_jobs() */" >/dev/null 2>&1 &
bg2=$!; BGPIDS+=("$bg2")
wait_for "(select count(*) from pg_stat_activity where pid <> pg_backend_pid() and state = 'active' and query like '%pg_sleep(60)%process_webhook_jobs()%') = 2"
applies "$P a monitoring query naming the worker, and a session in another database, do not block it"
psql "$DATABASE_URL" -qtAX -c "select pg_terminate_backend(pid) from pg_stat_activity where datname in ('${PFX}_g$G', '${PFX}_other') and pid <> pg_backend_pid()" >/dev/null
wait "$bg1" "$bg2" >/dev/null 2>&1 || true
dropdb_now "${PFX}_g$G"; dropdb_now "${PFX}_other"
# an applier that is a member of the owner role (not superuser) applies
G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_gb"
applies "$P an applier that is a member of the owner role, not a superuser, applies" "$MEMBER"
same "$P its NOTICE names that applier and the owner; the owner is unchanged" \
     "$(notice "$LAST_OUT" | cut -d'|' -f1) / $(q -c "select pg_get_userbyid(proowner) from pg_proc where oid = 'public.process_webhook_jobs()'::regprocedure")" \
     "applier $MEMBER, worker owner $SU / $SU"
dropdb_now "${PFX}_g$G"

# =============================================================================
echo "== 7b. exclusive access to the queue (A5) and the late caller"
# held_copy <src> <dst> <statement>: the migration with <statement> run just before its commit
held_copy() {
    HELD="$3" perl -pe 's/^commit;$/$ENV{HELD}\ncommit;/' "$1" > "$2"
    [[ "$(grep -c -x -F -- "$3" "$2")" == 1 ]] || { echo "held_copy: '$3' not placed once" >&2; exit 2; }
}
# idle_open <sql>: a session that runs <sql> inside an open transaction, then
# sits idle in it (its input is a fifo the suite holds open on fd 3)
idle_open() {
    /bin/rm -f "$WORK/fifo"; mkfifo "$WORK/fifo"
    psql "$DB" --no-psqlrc -qtAX < "$WORK/fifo" >/dev/null 2>&1 &
    IDLE_PID=$!; BGPIDS+=("$IDLE_PID"); echo "$IDLE_PID" >> "$WORK/bgpids"
    exec 3> "$WORK/fifo"
    printf 'begin;\n%s\n' "$1" >&3
}
idle_close() { exec 3>&-; wait "$IDLE_PID" >/dev/null 2>&1 || true; }
IDLE_PID=""
sleeping() { # sleeping <statement>: another session is running it (psql -f may keep its ';')
    echo "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'active' and query like '$1%' and wait_event = 'PgSleep')"
}
end_sleepers() {
    q -c "select pg_terminate_backend(pid) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query like 'select pg_sleep(%'" >/dev/null
}
start_bg() { "$@" >/dev/null 2>&1 & BGPID=$!; BGPIDS+=("$BGPID"); echo "$BGPID" >> "$WORK/bgpids"; }

ex_idle() { # ex_idle <tag>
    newdb "${PFX}_x$1" "${PFX}_gb"
    idle_open "select public.process_webhook_jobs();"
    wait_for "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'idle in transaction')"
    check "$P (setup) the idle session ran the worker and holds a write lock on the queue" \
          "exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid where a.state = 'idle in transaction' and a.datname = current_database() and l.relation = 'public.webhook_jobs'::regclass and l.mode = 'RowExclusiveLock')"
    same "$P (setup) Q4 sees it: idle_holding_queue and queue_lock_holders" "$(q -c "$(hq Q4)" | cut -d'|' -f2,3)" "1|1"
    refuses "$P an idle transaction that already ran the worker: refused, nothing changed" 'idle in an open transaction'
    idle_close
    dropdb_now "${PFX}_x$1"
}
ex_reader() {
    newdb "${PFX}_x$1" "${PFX}_gb"
    start_bg psql "$DB" --no-psqlrc -qtAX -c "begin" -c "select count(*) from public.webhook_jobs" -c "select pg_sleep(60)"
    local b=$BGPID
    wait_for "$(sleeping 'select pg_sleep(60)')"
    refuses "$P an open transaction that read the queue (busy, not idle, not naming the worker): refused by the lock check, nothing changed" \
            'other session\(s\) hold a lock on public\.webhook_jobs'
    end_sleepers; wait "$b" >/dev/null 2>&1 || true
    dropdb_now "${PFX}_x$1"
}
ex_writer() {
    local b t0
    newdb "${PFX}_x$1" "${PFX}_gb"
    start_bg psql "$DB" --no-psqlrc -qtAX -c "begin" -c "update public.webhook_jobs set attempt_count = attempt_count where id = -1" -c "select pg_sleep(60)"
    b=$BGPID
    wait_for "$(sleeping 'select pg_sleep(60)')"
    t0=$(now_ms)
    refuses "$P an open transaction that wrote the queue: the apply waits for it, gives up at lock_timeout, nothing changed" \
            'held a write lock on public\.webhook_jobs'
    t0=$(( $(now_ms) - t0 ))
    if (( t0 >= 900 && t0 < 10000 )); then pass "$P and it waited about lock_timeout (1 s; the whole apply took $t0 ms)"
    else fail "$P it gave up after $t0 ms, not about lock_timeout (1 s)"; fi
    end_sleepers; wait "$b" >/dev/null 2>&1 || true
    dropdb_now "${PFX}_x$1"
}
ex_advisory() {
    local b
    newdb "${PFX}_x$1" "${PFX}_gb"
    LAST_OUT="$(migrate "$V089")" || { fail "$P (setup) v0.89 did not apply"; return; }
    start_bg psql "$DB" --no-psqlrc -qtAX -c "select pg_advisory_lock($LOCK_KEY)" -c "select pg_sleep(60)"
    b=$BGPID
    wait_for "$(sleeping 'select pg_sleep(60)')"
    refuses "$P a re-run while a v0.89 worker run holds the worker's lock: it waits, gives up at lock_timeout, nothing changed" \
            "held the worker's advisory lock"
    end_sleepers; wait "$b" >/dev/null 2>&1 || true
    dropdb_now "${PFX}_x$1"
}
ex_late_first() {
    local m w rc=0
    newdb "${PFX}_x$1" "${PFX}_gb"
    held_copy "$MIG" "$WORK/held.$1.sql" "select pg_sleep(1.5);"
    start_bg psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.$1.sql"; m=$BGPID
    wait_for "$(sleeping 'select pg_sleep(1.5)')"
    start_bg psql "$DB" --no-psqlrc -qtAX -c "select public.process_webhook_jobs()"; w=$BGPID
    if poll "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query = 'select public.process_webhook_jobs()' and wait_event_type = 'Lock')" 30; then
        pass "$P late starter (first apply): a worker call that starts during the apply waits on the queue lock"
    else
        fail "$P late starter (first apply): a worker call that starts during the apply waits on the queue lock (it did not wait)"
    fi
    wait "$m" || rc=$?
    same "$P late starter (first apply): the apply commits regardless" "$rc / $(worker_md5)" "0 / $RAW89"
    # step 7: drain after the commit (no waiting on the caller's process: only Q4 and Q6)
    if poll_out "select (select running = 0 and queue_lock_holders = 0 from ($(hq Q4 | sed 's/;$//')) q4) and (select worker_lock = 0 and apply_sessions = 0 from ($(hq Q6 | sed 's/;$//')) q6)" "t" 150; then
        pass "$P late starter (first apply), against the precondition: step 7's drain (Q4, Q6) waits until the late call has finished"
    else
        fail "$P late starter (first apply): step 7's drain never reached Q4 = 0 and Q6 = 0"
    fi
    same "$P late starter (first apply): it ran the body it started with (v0.25) and abandoned row c's request without finalizing it: step 8's Q5 = 1" \
         "$(q5) / $(q -c "select attempt_count || ' ' || coalesce(pg_net_request_id::text, 'noreq') || ' ' || (processed_at is null) from public.webhook_jobs where alert_id = 'bf-c'")" "1 / 3 noreq true"
    q -c "$(hq BF)" >/dev/null
    same "$P late starter (first apply): step 8's remedy, BF, finalizes it (Q5 = 0)" "$(q5)" "0"
    wait "$w" >/dev/null 2>&1 || true
    dropdb_now "${PFX}_x$1"
}
ex_late_rerun() {
    local m w before i rc=0
    newdb "${PFX}_x$1" "${PFX}_gb"
    LAST_OUT="$(migrate "$V089")" || { fail "$P (setup) v0.89 did not apply"; return; }
    held_copy "$MIG" "$WORK/held.$1.sql" "select pg_sleep(1.5);"
    start_bg psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.$1.sql"; m=$BGPID
    wait_for "$(sleeping 'select pg_sleep(1.5)')"
    before="$(q -c "select b1t.snapshot()")"
    start_bg psql "$DB" --no-psqlrc -qtAX -c "select public.process_webhook_jobs()"; w=$BGPID
    for i in $(seq 1 30); do kill -0 "$w" 2>/dev/null || break; sleep 0.1; done
    if ! kill -0 "$w" 2>/dev/null && poll "$(sleeping 'select pg_sleep(1.5)')" 1; then
        pass "$P late starter (re-run): a v0.89 worker call during the apply returns at once (the apply holds the worker's lock)"
    else
        fail "$P late starter (re-run): the v0.89 worker call did not return while the apply held the lock"
    fi
    same "$P late starter (re-run): and touched nothing" "$(q -c "select b1t.snapshot()")" "$before"
    wait "$m" || rc=$?
    same "$P late starter (re-run): the re-run then commits" "$rc / $(worker_md5)" "0 / $RAW89"
    dropdb_now "${PFX}_x$1"
}
P="[access]"
ex_idle idle; ex_reader reader; ex_writer writer; ex_advisory advisory; ex_late_first late1; ex_late_rerun late2

# =============================================================================
echo "== 7c. recovery (APPLY step 6) and restoring the recorded value"
P="[recovery]"
# 6b: a reported error after the replace and the backfill
newdb "${PFX}_y1" "${PFX}_gb"
n="$(q5)"
held_copy "$V089" "$WORK/fail.sql" "select 1/0;"
MIG="$WORK/fail.sql"
refuses "$P (6b) an error after the replace and the backfill (injected just before commit): reported, all rolled back, nothing changed" 'division by zero'
MIG="$V089"
same "$P (6b) Q0 as in step 0 and Q5 = N: the old body, no comment, the stuck rows still stuck" "$(q0) / $(q5)" \
     "$PROD_WORKER_MD5|1|t|t|t|$ACL_UP| / $n"
restore_job true
same "$P ABORT: R9 puts back the recorded value (true)" "$(q3)" "1|true|$JOB_MD5"
dropdb_now "${PFX}_y1"
# 6c: no clear answer, and the apply had in fact committed (sent as one query string, as apply_migration does)
newdb "${PFX}_y2" "${PFX}_gb"
held_copy "$V089" "$WORK/held.y2.sql" "select pg_sleep(1.5);"
start_bg psql "$DB" --no-psqlrc -qtAX -c "$(cat "$WORK/held.y2.sql")"; c=$BGPID
wait_for "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and wait_event = 'PgSleep')"
same "$P (6c) meanwhile another session still sees the old body: an old body_md5 proves nothing" "$(q0 | cut -d'|' -f1)" "$PROD_WORKER_MD5"
same "$P (6c) Q6 sees the apply (sent as one string): the worker's lock, and its session's application_name" "$(q -c "$(hq Q6)")" "1|1"
kill -TERM "$c" 2>/dev/null; wait "$c" >/dev/null 2>&1 || true
if poll_out "$(hq Q6)" "0|0" 150; then pass "$P (6c) the client gone, the server finishes; Q6 reaches 0|0"; else fail "$P (6c) Q6 never reached 0|0"; fi
same "$P (6c) then Q0 and Q5 show it committed" "$(q0) / $(q5)" "$RAW89|1|t|t|t|$ACL_UP|$COMMENT_MD5 / 0"
restore_job true
same "$P (6c) and R9 restores the recorded value (true)" "$(q3)" "1|true|$JOB_MD5"
dropdb_now "${PFX}_y2"
# 6c: no clear answer, and the apply had rolled back (psql -f, statement by
# statement, client killed before the commit); the recorded value was false
newdb "${PFX}_y3" "${PFX}_upbase"; backfill_rows
q -c "update cron.job set active = false where jobid = 3" >/dev/null
same "$P (1) the job was already paused by the owner: the recorded value is false" "$(q3)" "1|false|$JOB_MD5"
pause_job
same "$P (2, 3) P2 changes nothing; Q4 quiet" "$(q3) / $(q -c "$(hq Q4)")" "1|false|$JOB_MD5 / 0|0|0|0"
n="$(q5)"
held_copy "$V089" "$WORK/held.y3.sql" "select pg_sleep(1.5);"
start_bg psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.y3.sql"; c=$BGPID
wait_for "$(sleeping 'select pg_sleep(1.5)')"
same "$P (6c) Q6 sees the apply (statement by statement, now in its sleep): the worker's lock, and its application_name" "$(q -c "$(hq Q6)")" "1|1"
kill -TERM "$c" 2>/dev/null; wait "$c" >/dev/null 2>&1 || true
if poll_out "$(hq Q6)" "0|0" 150; then pass "$P (6c) the session ends; Q6 reaches 0|0"; else fail "$P (6c) Q6 never reached 0|0"; fi
same "$P (6c) then Q0 and Q5 show it rolled back: old body, no comment, Q5 = N" "$(q0) / $(q5)" "$PROD_WORKER_MD5|1|t|t|t|$ACL_UP| / $n"
restore_job false
same "$P ABORT: R9 puts back the recorded value, false: the job stays paused" "$(q3)" "1|false|$JOB_MD5"
dropdb_now "${PFX}_y3"

# =============================================================================
echo "== 7d. the time budget (A0) and alert uploads during the apply"
SVN="$(psql "$DATABASE_URL" -qtAX -c 'show server_version_num')"
if (( SVN >= 170000 )); then BUDGET_RE='terminating connection due to transaction timeout'; else BUDGET_RE='canceling statement due to statement timeout'; fi
P="[budget]"
# alert_insert <alert id> <statement_timeout>: one alert, as PostgREST runs a
# call for the signed-in user (authenticated, its JWT claims), in its own
# transaction; prints psql's output, returns its status
alert_insert() {
    psql "$DB" --no-psqlrc -qtAX -v ON_ERROR_STOP=1 \
        -c "set statement_timeout = '$2'" \
        -c "select set_config('request.jwt.claims', '{\"sub\":\"$UA\",\"role\":\"authenticated\"}', false)" \
        -c "set role authenticated" \
        -c "insert into public.alerts (id, user_id, type, title, grouping_key) values ('$1', '$UA', 'Usage Spike', 't', 'k-$1')" 2>&1
}
inserting() { # inserting <alert id>: that insert waits on a lock
    echo "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query like 'insert into public.alerts%''$1''%' and wait_event_type = 'Lock')"
}
job_of() { q -c "select count(*) filter (where processed_at is null) || ' pending of ' || count(*) from public.webhook_jobs where alert_id = '$1'"; }
alert_of() { q -c "select count(*) from public.alerts where id = '$1'"; }
run_bg_to() { # run_bg_to <output file> <command...>
    local o="$1"; shift
    "$@" > "$o" 2>&1 &
    BGPID=$!; BGPIDS+=("$BGPID"); echo "$BGPID" >> "$WORK/bgpids"
}

# an idle transaction that never touched the queue does not stop the apply
ex_idle_unrelated() {
    newdb "${PFX}_x$1" "${PFX}_gb"
    idle_open "select 1;"
    wait_for "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'idle in transaction')"
    same "$P (setup) Q4: the idle session holds nothing on the queue" "$(q -c "$(hq Q4)")" "0|0|0|0"
    applies "$P an idle transaction that never touched the queue does not stop the apply"
    idle_close
    dropdb_now "${PFX}_x$1"
}
P="[access]"; ex_idle_unrelated unrelated; P="[budget]"

# helper_upload <alert id> <statement_timeout>: one helper_sync carrying one
# alert, as both helpers call it (the anon key: role anon); prints psql's
# output, returns its status
helper_upload() {
    psql "$DB" --no-psqlrc -qtAX -v ON_ERROR_STOP=1 \
        -c "set statement_timeout = '$2'" \
        -c "set role anon" \
        -c "select public.helper_sync('$DEV', 'test-helper-secret', '[]'::jsonb, '[{\"id\": \"$1\", \"type\": \"Usage Spike\", \"severity\": \"Warning\", \"title\": \"t\", \"grouping_key\": \"k-$1\"}]'::jsonb, '{}'::jsonb, '{}'::jsonb)" 2>&1
}
uploading() { # uploading: a helper_sync waits on a lock
    echo "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query like 'select public.helper_sync(%' and wait_event_type = 'Lock')"
}

# while the apply holds the queue lock: a helper upload (anon, statement_timeout 3s,
# as production's anon) and an app-side insert (authenticated, 8s) both wait, then land
newdb "${PFX}_z1" "${PFX}_gb"
held_copy "$V089" "$WORK/held.z1.sql" "select pg_sleep(1.5);"
run_bg_to "$WORK/z1.mig" psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.z1.sql"; m=$BGPID
wait_for "$(sleeping 'select pg_sleep(1.5)')"
run_bg_to "$WORK/z1.up" helper_upload up3 3s; u=$BGPID
run_bg_to "$WORK/z1.ins" alert_insert ins8 8s; w=$BGPID
if poll "$(uploading)" 10; then pass "$P a helper upload (helper_sync as anon, statement_timeout 3s) during the apply waits on the queue lock"
else fail "$P the helper upload did not wait on the queue lock"; fi
if poll "$(inserting ins8)" 10; then pass "$P so does an insert as authenticated (statement_timeout 8s)"
else fail "$P the authenticated insert did not wait on the queue lock"; fi
rc=0; wait "$m" || rc=$?
same "$P the apply commits" "$rc / $(worker_md5)" "0 / $RAW89"
rc=0; wait "$u" || rc=$?
same "$P then the helper upload succeeds, and its alert's webhook job is enqueued" "$rc / $(alert_of up3) / $(job_of up3)" "0 / 1 / 1 pending of 1"
rc=0; wait "$w" || rc=$?
same "$P and so does the authenticated insert" "$rc / $(alert_of ins8) / $(job_of ins8)" "0 / 1 / 1 pending of 1"
dropdb_now "${PFX}_z1"

# an upload whose own statement_timeout runs out first: it fails and rolls back
# entirely; sent again (the helper's next cycle), it lands
newdb "${PFX}_z2" "${PFX}_gb"
held_copy "$V089" "$WORK/held.z2.sql" "select pg_sleep(1.5);"
run_bg_to "$WORK/z2.mig" psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.z2.sql"; m=$BGPID
wait_for "$(sleeping 'select pg_sleep(1.5)')"
out="$(helper_upload upshort 500ms)" && rc=0 || rc=$?
if (( rc != 0 )) && grep -q 'canceling statement due to statement timeout' <<<"$out"; then
    pass "$P a helper upload whose own statement_timeout (500ms here) runs out while it waits fails with a statement timeout"
else fail "$P the short-timeout upload: rc $rc, $(head -1 <<<"$out")"; fi
rc=0; wait "$m" || rc=$?
same "$P the apply commits" "$rc / $(worker_md5)" "0 / $RAW89"
same "$P the failed upload left nothing: no alert row, no job" "$(alert_of upshort) / $(job_of upshort)" "0 / 0 pending of 0"
out="$(helper_upload upshort 3s)" && rc=0 || rc=$?
same "$P sent again (the helper's next cycle sends it while its condition holds), it lands and its job is enqueued" \
     "$rc / $(alert_of upshort) / $(job_of upshort)" "0 / 1 / 1 pending of 1"
dropdb_now "${PFX}_z2"

# an apply made to run past the 2 s budget: it is stopped with nothing changed,
# and a helper upload (anon, 3s) that started waiting at once goes on (its
# timeout counts its own work too, so one already well into it could not)
budget_overrun() { # budget_overrun <tag> <migration> <regex of the abort> <label>
    local m w rc t0 before n
    newdb "${PFX}_z$1" "${PFX}_gb"
    before="$(q0)"; n="$(q5)"
    held_copy "$2" "$WORK/held.z$1.sql" "select pg_sleep(3);"
    t0=$(now_ms)
    run_bg_to "$WORK/z$1.mig" psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.z$1.sql"; m=$BGPID
    wait_for "$(sleeping 'select pg_sleep(3)')"
    run_bg_to "$WORK/z$1.up" helper_upload "up$1" 3s; w=$BGPID
    rc=0; wait "$m" || rc=$?
    t0=$(( $(now_ms) - t0 ))
    if (( rc != 0 )) && grep -q -E -- "$3" "$WORK/z$1.mig" && (( t0 < 2900 )); then
        pass "$P $4: the apply runs past 2 s and is stopped after $t0 ms: /$3/"
    else fail "$P $4: rc $rc after $t0 ms, not /$3/ within 2.9 s: $(grep -m1 -E 'ERROR|FATAL' "$WORK/z$1.mig")"; fi
    same "$P $4: nothing changed (Q0 and Q5 as before)" "$(q0) / $(q5)" "$before / $n"
    rc=0; wait "$w" || rc=$?
    same "$P $4: the helper upload (anon, 3s) that waited goes on, its job enqueued" \
         "$rc / $(alert_of "up$1") / $(job_of "up$1")" "0 / 1 / 1 pending of 1"
    dropdb_now "${PFX}_z$1"
}
if (( SVN >= 170000 )); then
    budget_overrun 3 "$V089" "$BUDGET_RE" "PostgreSQL $((SVN / 10000)), transaction_timeout 2s"
    mutate "$V089" "$WORK/v089.fallback.sql" 1 "current_setting\\('server_version_num'\\)::int >= 170000" "current_setting('server_version_num')::int >= 990000"
    budget_overrun 4 "$WORK/v089.fallback.sql" 'canceling statement due to statement timeout' "the pre-17 branch, forced (statement_timeout 2s per statement)"
else
    budget_overrun 3 "$V089" "$BUDGET_RE" "PostgreSQL $((SVN / 10000)) (before 17), statement_timeout 2s per statement"
fi

# how long the apply holds the queue lock with a full queue: the size guard's
# limit in stuck jobs plus thousands of finalized ones (test environment)
newdb "${PFX}_z5" "${PFX}_upbase"
q >/dev/null <<SQL
insert into public.webhook_jobs (user_id, alert_id, alert_payload, attempt_count, last_error)
select '$UA', 'stuck-' || i, jsonb_build_object('grouping_key', 'stuck-' || i), 4, 'HTTP 502: x' from generate_series(1, 5000) i;
insert into public.webhook_jobs (user_id, alert_id, alert_payload, enqueued_at, processed_at, attempt_count, pg_net_request_id, dispatched_at)
select '$UA', 'done-' || i, jsonb_build_object('grouping_key', 'done-' || i), now() - interval '2 days', now() - interval '2 days', 1, i, now() - interval '2 days' from generate_series(1, 3000) i;
analyze public.webhook_jobs;
SQL
pause_job
applies "$P the apply with 5000 stuck and 3000 finalized jobs"
ms="$(lock_ms "$LAST_OUT")"
same "$P it backfilled the 5000" "$(notice "$LAST_OUT" | cut -d'|' -f2)" "backfilled 5000 stuck job(s): finalized with failure, nothing re-sent"
if [[ -n "$ms" ]] && (( ms < 2000 )); then pass "$P MEASURED (test environment): the queue lock was held $ms ms, inside the 2 s budget"
else fail "$P the queue lock hold time: '$ms' ms"; fi
dropdb_now "${PFX}_z5"

# =============================================================================
echo "== 8. negative controls (each mutant must fail its named assertion)"
M=0
# control <name> <template> <mutant sql> <prep: shell code or ""> <case function> <regex of the FAIL label it must produce>
control() {
    local out hit
    M=$((M + 1)); newdb "${PFX}_m$M" "$2"
    [[ -z "$4" ]] || eval "$4"
    apply "$3"
    out="$( (P="[mutant]"; fails=0; "$5") 2>&1 )" || true
    hit="$(grep -m1 -E -- "^  FAIL  \[mutant\] $6" <<<"$out" || true)"
    if [[ -n "$hit" ]]; then
        pass "control: $1"
        echo "          fails: ${hit#  FAIL  [mutant] }" | cut -c1-200
    else
        fail "control: $1 — did not fail /$6/"
        grep -E 'FAIL|ERROR' <<<"$out" | head -5 >&2 || true
    fi
    dropdb_now "${PFX}_m$M"
}
W="$WORK/worker.sql"; MUT="$WORK/mutant"
mutate "$W" "$MUT.1.sql" 1 'processed_at = case when v_expired and attempt_count >= 3 then now\(\) else processed_at end' 'processed_at = processed_at'
control "1. no-answer branch never finalizes" "${PFX}_up" "$MUT.1.sql" "" case_noresp \
        'no answer: after the third request has had no answer for 5 minutes, the job is finalized'
mutate "$W" "$MUT.2.sql" 1 'processed_at = case when v_expired and attempt_count >= 3' 'processed_at = case when attempt_count >= 3'
control "2. no-answer branch finalizes without the 5-minute test" "${PFX}_up" "$MUT.2.sql" "" case_noresp \
        'no answer: under 5 minutes the third request is live: not finalized'
mutate "$W" "$MUT.3.sql" 1 're-dispatch\n\s*pg_net_request_id = null,\n\s*dispatched_at = null\K,\n\s*processed_at = case when attempt_count \+ 1 >= 3 then now\(\) else processed_at end' ''
control "3. non-2xx branch never finalizes" "${PFX}_up" "$MUT.3.sql" "" case_502 \
        '502: the second 502 finalizes the job'
mutate "$W" "$MUT.4.sql" 1 're-dispatch\n\s*pg_net_request_id = null,\n\s*dispatched_at = null,\n\s*processed_at = case when attempt_count \+ 1 >= \K3' '2'
control "4. non-2xx branch finalizes at 2" "${PFX}_up" "$MUT.4.sql" "" case_502 \
        '502: the first 502 is counted and the job redispatched in the same call, not finalized'
mutate "$W" "$MUT.5.sql" 1 'dispatched_at = now\(\),\n\s*attempt_count = attempt_count \+ 1,\K' $'\n            processed_at = case when attempt_count + 1 >= 3 then now() else processed_at end,'
control "5a. finalized right after the third dispatch (502 path)" "${PFX}_up" "$MUT.5.sql" "" case_502 \
        '502: the first 502 is counted and the job redispatched in the same call, not finalized'
control "5b. finalized right after the third dispatch (no-answer path)" "${PFX}_up" "$MUT.5.sql" "" case_noresp \
        'no answer: the third request goes out and the job stays pending while it is live'
mutate "$W" "$MUT.6.sql" 1 "'http_post failed: ' \\|\\| sqlerrm,\\n\\s*processed_at = case when attempt_count \\+ 1 >= \\K3" '4'
control "6. raise branch finalizes at 4" "${PFX}_up" "$MUT.6.sql" "" case_raise \
        'raise: the third raise finalizes the job'
mutate "$W" "$MUT.7.sql" 1 'if v_status is null and \(coalesce\(v_timed_out, false\) or v_error is not null\) then' 'if false then'
control "7a. a transport failure read as no answer (timed out)" "${PFX}_up" "$MUT.7.sql" "" "case_transport_timeout" \
        'transport \(timeout\): the failure counts at once'
control "7b. a transport failure read as no answer (error)" "${PFX}_up" "$MUT.7.sql" "" "case_transport_error" \
        'transport \(error\): the failure counts at once'
mutate "$W" "$MUT.8a.sql" 2 'coalesce\(dispatched_at, enqueued_at\)' 'dispatched_at'
mutate "$MUT.8a.sql" "$MUT.8.sql" 1 'coalesce\(v_job\.dispatched_at, v_job\.enqueued_at\)' 'v_job.dispatched_at'
control "8a. age without coalesce(dispatched_at, enqueued_at)" "${PFX}_up" "$MUT.8.sql" "" case_malformed \
        'malformed: a request id without dispatched_at, answered 200, is reconciled and finalized'
mutate "$W" "$MUT.9.sql" 1 "  if not pg_try_advisory_xact_lock\\(hashtextextended\\('process_webhook_jobs', 0\\)\\) then\\n    return;\\n  end if;\\n" ''
control "8b. no advisory lock" "${PFX}_up" "$MUT.9.sql" "" case_serialization \
        'one call at a time: while another session holds the lock, a call sends nothing'
B="$WORK/backfill.sql"
mutate "$B" "$MUT.b1.sql" 1 '\n\s*and pg_net_request_id is null' ''
cat "$W" "$MUT.b1.sql" > "$MUT.b1.full.sql"
control "9a. backfill without 'pg_net_request_id is null'" "${PFX}_upbase" "$MUT.b1.full.sql" "backfill_rows" backfill_checks \
        'backfill: row b is untouched'
mutate "$B" "$MUT.b2.sql" 1 '\n\s*and attempt_count >= 3' ''
cat "$W" "$MUT.b2.sql" > "$MUT.b2.full.sql"
control "9b. backfill without 'attempt_count >= 3'" "${PFX}_upbase" "$MUT.b2.full.sql" "backfill_rows" backfill_checks \
        'backfill: row d is untouched'
# the migration's own exclusive-access guards (A5), mutated in the whole file
gcontrol() { # gcontrol <name> <mutant migration> <test function> <regex of the FAIL label it must produce>
    local out hit
    M=$((M + 1))
    out="$( (P="[mutant]"; MIG="$2"; fails=0; "$3" "gm$M") 2>&1 )" || true
    hit="$(grep -m1 -E -- "^  FAIL  \[mutant\] $4" <<<"$out" || true)"
    if [[ -n "$hit" ]]; then
        pass "control: $1"
        echo "          fails: ${hit#  FAIL  [mutant] }" | cut -c1-200
    else
        fail "control: $1 — did not fail /$4/"
        grep -E 'FAIL|ERROR' <<<"$out" | head -5 >&2 || true
    fi
    dropdb_now "${PFX}_xgm$M"
}
mutate "$V089" "$MUT.g1.sql" 1 '(?s)    -- b\. an idle open transaction that touched the queue.*?    end if;\n' ''
gcontrol "G1. the migration without the idle-transaction check (A5b)" "$MUT.g1.sql" ex_idle \
         'an idle transaction that already ran the worker: refused'
mutate "$V089" "$MUT.g2.sql" 1 '(?s)    -- e\. the authority.*?    end if;\n' ''
gcontrol "G2. the migration without the pg_locks check (A5e)" "$MUT.g2.sql" ex_reader \
         'an open transaction that read the queue'
mutate "$V089" "$MUT.g3.sql" 1 '(?s)    -- d\. writers of the queue.*?    end;\n' ''
gcontrol "G3. the migration without LOCK TABLE (A5d)" "$MUT.g3.sql" ex_late_first \
         'late starter \(first apply\): a worker call that starts during the apply waits on the queue lock'
mutate "$V089" "$MUT.g4.sql" 1 "(?s)    -- c\\. the worker's own lock.*?    end;\\n" ''
gcontrol "G4. the migration without the worker's advisory lock (A5c)" "$MUT.g4.sql" ex_advisory \
         "a re-run while a v0.89 worker run holds the worker's lock"
printf -v unscoped '%s\n%s\n' "    select count(*) into v_n from pg_stat_activity a" \
    "     where a.pid <> pg_backend_pid() and a.datname = current_database() and a.state like 'idle in transaction%';"
mutate "$V089" "$MUT.g5.sql" 1 "(?s)    -- b\\. an idle open transaction that touched the queue.*?l\\.relation = 'public\\.webhook_jobs'::regclass;\\n" "$unscoped"
gcontrol "G5. the idle check unscoped again (any idle transaction refuses)" "$MUT.g5.sql" ex_idle_unrelated \
         'an idle transaction that never touched the queue does not stop the apply'
# and the unmutated cut passes the same checks (the controls fail for the mutation, not the harness)
cat "$W" "$B" > "$WORK/unmutated.full.sql"
newdb "${PFX}_m0" "${PFX}_upbase"; backfill_rows; apply "$WORK/unmutated.full.sql"
out="$( (P="[cut]"; fails=0; backfill_checks; case_noresp; case_502; case_raise; case_malformed; exit $fails) 2>&1 )" \
    && pass "control harness: the unmutated cut passes every check the mutants fail" \
    || { fail "control harness: the unmutated cut fails"; grep FAIL <<<"$out" | head -5 >&2; }
dropdb_now "${PFX}_m0"

echo
if (( fails > 0 )); then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all checks passed"

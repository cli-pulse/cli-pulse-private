#!/usr/bin/env bash
# Verify migrate_v0.90 (app-push jobs that keep failing are finalized, instead
# of staying pending until their approval request is deleted) against a real
# Postgres. The app-push twin of run_v089_webhook_jobs_finalize_tests.sh: same
# harness, same kinds of proof, the app-push queue's own objects.
#
# Install path: upgrade only. The baseline files (schema.sql, app_rpc.sql,
# helper_rpc.sql) hold no app-push object and no remote table, so there is no
# fresh path to test; on a baseline-only database the migration must refuse
# (part 7). The upgrade database is production's shape before v0.90, built
# from the files that built production:
#   * the shim and the three baseline files;
#   * tests/rls/20_remote_tables.sql (the remote tables, transcribed from
#     production), plus remote_permission_requests.session_id (v0.26's column,
#     which that transcription leaves out and v0.45's RPC writes);
#   * cut from v0.27: user_settings.remote_control_enabled, which the insert
#     trigger reads, and _remote_authenticate_helper_gated(); cut from v0.45:
#     remote_helper_create_permission_request(), the RPC the helpers call (as
#     anon) to create an approval request, executable by anon as production's
#     default privileges leave it;
#   * cut from v0.32, WITHOUT its comment-only lines, as production runs it
#     (the worker's body md5 is fab8e1a9…, measured 2026-11-12, reproduced
#     here first): section 1 (app_push_tokens, which the trigger reads) and
#     sections 3 to 6 (the request's notification columns, app_push_jobs, its
#     indexes and policy, the insert trigger and its function, the worker and
#     its revoke). Sections 2 (token RPCs), 7 (the cron schedule: environment)
#     and 8 (list_pending_approvals) are not needed. Each expected object is
#     asserted after the cut is applied;
#   * v0.33 as it is (the policy re-emitted, the trigger function revoked, the
#     user_id index), production's default table grants, then v0.77 as it is
#     (anon and authenticated lose them); service_role's EXECUTE grant on the
#     worker, as Supabase's default privileges give it.
# pg_net, vault and pg_cron are not in plain Postgres, so each database gets
# stand-ins: net._http_response with pg_net's columns the worker reads;
# net.http_post with pg_net 0.20's signature, which records each call in
# net.v090_calls and returns its id as the request id (or raises when the
# setting v090.post_mode is 'raise'); vault.decrypted_secrets with both
# secrets; cron.job, cron.job_run_details and cron.alter_job with pg_cron
# 1.6's names, holding production's job (jobid 5, app_push_jobs_drain, '30
# seconds', active) and the webhook queue's (jobid 3).
#
# Users: UA has remote control on and a push token, so an approval request
# of hers makes the trigger enqueue a job and send request 1 at once
# (attempt_count 1). UB has remote control off; UC has it on but no token.
#
# Every behavioural case runs whole worker calls (both passes, each call its
# own transaction, as pg_cron runs it) and asserts the job's state, the
# recorder (how many http_post calls, and which request id the job holds) and
# the approval request's notification_attempts and notification_last_error.
# Time moves by backdating: respond() also backdates the job's dispatched_at
# by 3 s (pass 1 only reads jobs older than 2 s, and these calls take
# milliseconds; without it every reconcile case would silently do nothing), a
# new job's enqueued_at is aged 6 s (pass 2 reads jobs older than 5 s), and
# age() shifts both.
#
# What this proves:
#   0. md5 values: v0.32's worker cut from its file, raw and without its
#      comment-only lines (the latter equals production's measured md5), and
#      v0.90's from between this migration's BEGIN/END worker markers, raw and
#      stripped, are the header's four values and exactly the guard's.
#   1. CONTROL, the old body: a 502 twice ends at attempt 4, pending, and a
#      second job for that approval request cannot be enqueued; no answer
#      ends at 3, pending; a 502 and then raising retries end at 3, pending; a
#      transport failure waits 5 minutes; a request id without dispatched_at
#      is never read.
#   2. upgrade apply, through the header's statements as printed: Q0 (hashes
#      and booleans only) before and after, Q1 (counts only), Q2, Q2b, Q3
#      (by name and by command), R0, the pause P2 and the restore R9 against
#      the cron stand-in, the quiesce checks Q4/Q4b (a stale 'running' row
#      older than 10 minutes does not count), the recount Q5 and Q5r, Q6,
#      Q8r; the
#      header's expected acl_md5, job_md5 and comment_md5 are the real ones;
#      a catalog fingerprint of the app-push objects moves only in the
#      worker's body md5 and the comment on processed_at; the contract
#      (SECURITY DEFINER, search_path, signature, grants); applied twice
#      (same md5 and ACL, nothing backfilled).
#   3. behaviour: 502; transport failures (timed out, error); no answer (a
#      row with nothing completed is no answer; the live third request is
#      not finalized, then it is); a failed answer or a transport failure
#      that reaches attempt 3 after an abandoned first request; raises; 2xx
#      on the first and on the third request; malformed rows; one call at a
#      time; the trigger's gates and
#      the request_id dedup slot (a second job for a request only after its
#      first is finalized). Each path's notification_attempts and
#      notification_last_error on the approval request.
#   4. backfill: exactly the stuck rows (no request id, attempt_count >= 3);
#      rows with a request id are left to the worker; no approval request
#      row changes (Q5r before and Q5r and Q8r after, and row by row); the
#      NOTICE equals
#      the recount Q5 taken after the pause, not Q1's preliminary count (a
#      job stuck in between is counted); above 5000 it refuses, and the
#      header's BF batch then lets it apply, the job still paused; the
#      rollback (R0's saved definition) restores the body and leaves the
#      backfilled rows finalized.
#   5. re-runs: accepted on v0.32 raw, on v0.90 raw and on v0.90 without its
#      comment-only lines (a client that strips them), in every order.
#   6. guards: each refuses and changes nothing (worker, ACL, jobs, approval
#      requests, comment, cron jobs), the baseline-only database included,
#      and EXECUTE that reaches anon only through a role it inherits (no
#      direct grant: the effective has_function_privilege check); a
#      monitoring query and a session in another database do not block; an
#      applier that is a member of the owner role applies; a session holding
#      the worker's catalog row makes it give up at lock_timeout.
#   6b. exclusive access (A5): an idle transaction that already ran the
#      worker is refused, and one that never touched the queue does not
#      stop the apply; an open transaction that read the queue is refused
#      by the pg_locks check; one that wrote it makes the apply wait and give
#      up at lock_timeout; so does a v0.90 worker run holding the worker's
#      lock during a re-run; a worker call that starts during a first apply
#      (against the header's precondition) waits on the queue lock, then runs
#      the old body after the commit and can leave a stuck row: step 7's
#      post-commit drain (Q4, Q6) waits for it, step 8's Q5 shows the row,
#      Q5r then differs from R by that row's request while Q8r (the
#      backfilled cohort) still equals R, BF clears the row, and Q8r after it
#      is the new baseline R', equal to Q5r; during a re-run a v0.90 worker
#      call returns at once and
#      touches nothing.
#   6c. recovery (APPLY step 6): an error injected after the replace and the
#      backfill rolls everything back (old body, no comment, stuck rows still
#      stuck) and R9 restores the recorded value; with the client killed
#      mid-apply, another session still sees the old body while Q6 shows the
#      apply open, and once Q6 is 0, Q0/Q5 tell a commit (sent as one string,
#      as apply_migration does) from a rollback (psql -f, killed before the
#      commit); R9 then restores a recorded value of false as false.
#   6d. the budget (A0, 2 s: how long the apply can block the queue) and the
#      queue's writers: while the apply holds the queue lock, a helper's
#      remote_helper_create_permission_request (as anon, statement_timeout
#      3s) and an account deletion (delete_user_account as authenticated,
#      8s) wait, then complete: the approval request lands with its job
#      enqueued and request 1 sent, the deleted account's jobs are gone; a
#      helper call whose own statement_timeout runs out first fails and
#      leaves nothing, and sent again it lands; an apply made to run past 2 s
#      is stopped (transaction_timeout on PostgreSQL 17, and the pre-17
#      per-statement branch forced) with nothing changed, and a helper call
#      waiting on it goes on; the lock hold time with the size guard's limit
#      of stuck jobs plus thousands of finalized ones is measured from the
#      apply's NOTICE.
#   7. negative controls: mutants of the worker and the backfill, cut from
#      between the markers and applied directly to a throwaway database
#      (bypassing the guards), must each fail the assertion named for them;
#      and copies of the migration without each exclusive-access guard (A5b
#      idle check, A5c advisory lock, A5d LOCK TABLE, A5e pg_locks check),
#      or with the idle check unscoped again, or without the effective
#      EXECUTE check (A3), must each fail theirs.
#
# Usage (creates and drops its own b1b_<pid>_* databases and roles there):
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres \
#     ./backend/supabase/tests/run_v090_app_push_jobs_finalize_tests.sh
# Run it as a superuser (it creates roles and stand-in schemas).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$(cd "$HERE/.." && pwd)"
SHIM="$HERE/rls/00_supabase_shim.sql"
REMOTE="$HERE/rls/20_remote_tables.sql"
V027="$SQL_DIR/migrate_v0.27_remote_control_gate.sql"
V032="$SQL_DIR/migrate_v0.32_remote_approvals_push.sql"
V033="$SQL_DIR/migrate_v0.33_remote_approvals_push_advisor_followups.sql"
V045="$SQL_DIR/migrate_v0.45_multi_cli_managed_sessions.sql"
V077="$SQL_DIR/migrate_v0.77_revoke_remote_table_grants.sql"
V090="$SQL_DIR/migrate_v0.90_app_push_jobs_finalize_failures.sql"

# Measured in production (read-only, 2026-11-12).
PROD_WORKER_MD5=fab8e1a9cfb25294eb7386baa248c236

UA='b1b00000-b1b0-4b1b-8b1b-00000000000a'   # remote control on, one push token
UB='b1b00000-b1b0-4b1b-8b1b-00000000000b'   # remote control off
UC='b1b00000-b1b0-4b1b-8b1b-00000000000c'   # remote control on, no push token
UD='b1b00000-b1b0-4b1b-8b1b-00000000000d'   # remote control on, a token: deletes the account in 6d
DEV='b1b00000-b1b0-4b1b-8b1b-0000000000d1'  # UA's paired Mac; its helper secret is a test value
LOCK_KEY="hashtextextended('process_app_push_jobs', 0)"

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to a database on a disposable server" >&2
    exit 2
fi
for f in "$SHIM" "$REMOTE" "$V027" "$V032" "$V033" "$V045" "$V077" "$V090" \
         "$SQL_DIR/schema.sql" "$SQL_DIR/app_rpc.sql" "$SQL_DIR/helper_rpc.sql"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done
command -v perl >/dev/null || { echo "perl is needed for the negative controls" >&2; exit 2; }

BASE="${DATABASE_URL%/*}"
PFX="b1b_$$"
WORK="$(mktemp -d)"
CREATED=()
BGPIDS=()
STRANGER="${PFX}_stranger"
MEMBER="${PFX}_member"
CARRIER="${PFX}_carrier"   # holds EXECUTE on the worker; anon inherits it in one guard case
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
    PGOPTIONS='-c client_min_messages=warning' psql "$DATABASE_URL" -qtAX -c "do \$\$ begin if to_regrole('$CARRIER') is not null then execute 'revoke $CARRIER from anon'; end if; end \$\$" >/dev/null 2>&1
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

# ── extraction from the files: loud, never silent ───────────────────────────
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
# cut_lines <file> <first line, exact> <last line regex> <out>: from the one line
# equal to <first> to the first line after it matching <last>; both must be
# there, <first> exactly once, or the suite stops.
cut_lines() {
    local f="$1" first="$2" last="$3" out="$4" n
    n="$(grep -c -x -F -- "$first" "$f" || true)"
    [[ "$n" == 1 ]] || { echo "cut: $(basename "$f"): want one line '$first', found $n" >&2; exit 2; }
    CUT_FIRST="$first" CUT_LAST="$last" perl -ne '
        $on = 1 if !$on && $_ eq "$ENV{CUT_FIRST}\n";
        if ($on) { print; exit if /$ENV{CUT_LAST}/ }
    ' "$f" > "$out"
    [[ -s "$out" ]] && tail -n 1 "$out" | grep -q -E -- "$last" \
        || { echo "cut: $(basename "$f"): no line matching /$last/ after '$first'" >&2; exit 2; }
}
# hq <label>: that APPLY line of the header, exactly as printed.
hq() {
    local n; n="$(grep -c -E "^-- +$1: " "$V090" || true)"
    [[ "$n" == 1 ]] || { echo "header: want one '$1:' line, found $n" >&2; exit 2; }
    sed -n -E "s/^-- +$1: //p" "$V090"
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

# ── the cuts from the migrations that built production ──────────────────────
# v0.27: the column the trigger reads, and the helper RPCs' gate
cut_lines "$V027" 'alter table public.user_settings' '^  add column if not exists remote_control_enabled boolean not null default false;$' "$WORK/v027_column.sql"
[[ "$(wc -l < "$WORK/v027_column.sql" | tr -d ' ')" == 2 ]] || { echo "cut: v0.27's column is not two lines" >&2; exit 2; }
cut_lines "$V027" 'create or replace function public._remote_authenticate_helper_gated(' \
    '^\$\$ language plpgsql security definer set search_path = pg_catalog, public, extensions;$' "$WORK/v027_gate.sql"
# v0.45: the RPC the helpers call to create an approval request
cut_lines "$V045" 'create or replace function public.remote_helper_create_permission_request(' '^\$\$;$' "$WORK/v045_rpc.sql"
grep -q 'insert into public.remote_permission_requests' "$WORK/v045_rpc.sql" || { echo "cut: v0.45's RPC does not insert the request" >&2; exit 2; }
# v0.32: section 1, then sections 3 to 6
sec() { # sec <n>: the line that opens v0.32's section <n>
    local n; n="$(grep -c -E "^-- ── $1\. " "$V032" || true)"
    [[ "$n" == 1 ]] || { echo "v0.32: want one section $1 header, found $n" >&2; exit 2; }
    grep -n -E "^-- ── $1\. " "$V032" | cut -d: -f1
}
s1="$(sec 1)"; s2="$(sec 2)"; s3="$(sec 3)"; s7="$(sec 7)"
{ sed -n "${s1},$((s2 - 1))p" "$V032"; sed -n "${s3},$((s7 - 1))p" "$V032"; } > "$WORK/v032_cut.sql"
for s in 'create table if not exists public.app_push_tokens (' 'create table if not exists public.app_push_jobs (' \
         'create unique index if not exists idx_app_push_jobs_pending_dedup' 'create policy "Service role only on app_push_jobs"' \
         'create or replace function public.remote_request_after_insert_push()' 'create trigger remote_permission_requests_after_insert_push' \
         'create or replace function public.process_app_push_jobs()' 'revoke all on function public.process_app_push_jobs()' \
         'add column if not exists notification_last_error text,'; do
    grep -q -F -- "$s" "$WORK/v032_cut.sql" || { echo "cut: v0.32's sections 1, 3-6 lack: $s" >&2; exit 2; }
done
if grep -q -E 'cron\.schedule|remote_app_list_pending_approvals|register_app_push_token' "$WORK/v032_cut.sql"; then
    echo "cut: v0.32's cut holds a section it should not (2, 7 or 8)" >&2; exit 2
fi
strip_comment_lines "$WORK/v032_cut.sql" > "$WORK/v032_cut.prod.sql"
# the worker alone, raw and without its comment-only lines (md5 values)
sed -n '/^create or replace function public\.process_app_push_jobs()$/,/^   set search_path = pg_catalog, extensions, public, net;$/p' "$V032" > "$WORK/w32.sql"
[[ "$(grep -c -x 'create or replace function public.process_app_push_jobs()' "$V032")" == 1 ]] || { echo "v0.32: want one worker CREATE line" >&2; exit 2; }
tail -n 1 "$WORK/w32.sql" | grep -q '^   set search_path = pg_catalog, extensions, public, net;$' || { echo "v0.32: the worker cut does not end on its search_path line" >&2; exit 2; }
strip_comment_lines "$WORK/w32.sql" > "$WORK/w32.prod.sql"

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
create table net.v090_calls (
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
  if current_setting('v090.post_mode', true) = 'raise' then
    raise exception 'v090 stub: http_post refused';
  end if;
  insert into net.v090_calls (url, body, params, headers, timeout_milliseconds)
  values (http_post.url, http_post.body, http_post.params, http_post.headers, http_post.timeout_milliseconds)
  returning id into v_id;
  return v_id;
end $$;
grant usage on schema net to anon, authenticated, service_role;

-- vault: both secrets, each once (the values are placeholders).
create schema if not exists vault;
create table vault.v090_secrets (name text, decrypted_secret text);
create view vault.decrypted_secrets as select name, decrypted_secret from vault.v090_secrets;
insert into vault.v090_secrets values
  ('app_supabase_url', 'https://stub.invalid'),
  ('app_service_role_key', 'stub-key');
grant usage on schema vault to service_role;

-- pg_cron (1.6): cron.job, cron.job_run_details and alter_job with pg_cron's
-- parameter names; production's app-push job (jobid 5) and the webhook one.
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
  (5, 'app_push_jobs_drain',  '30 seconds', 'select public.process_app_push_jobs()', true);
select setval('cron.job_jobid_seq', 5);
insert into cron.job_run_details (jobid, status, start_time, end_time) values
  (5, 'succeeded', now() - interval '1 minute', now() - interval '1 minute'),
  (5, 'running',   now() - interval '20 minutes', null),   -- stale: a crash leftover
  (3, 'running',   now() - interval '1 minute', null);     -- another job's run

-- the suite's own probes, outside public
create schema b1bt;
create function b1bt.snapshot() returns text language plpgsql as $$
declare
  r text;
  x text;
begin
  select coalesce(string_agg(format('%s|%s|%s|%s|%s|%s', p.oid::regprocedure, md5(p.prosrc), p.prosecdef,
                                    p.proconfig, p.proacl, pg_get_userbyid(p.proowner)), ';'
                             order by p.oid::regprocedure::text), 'no worker')
    into r from pg_proc p where p.proname = 'process_app_push_jobs';
  if to_regclass('public.app_push_jobs') is not null then
    execute 'select coalesce(md5(string_agg(t::text, ''|'' order by t.id)), ''empty'') from public.app_push_jobs t' into x;
    r := r || '#jobs=' || x || '#comment=' || coalesce(md5(col_description('public.app_push_jobs'::regclass,
                 (select attnum from pg_attribute where attrelid = 'public.app_push_jobs'::regclass
                    and attname = 'processed_at'))), 'none');
  end if;
  if to_regclass('public.remote_permission_requests') is not null then
    execute 'select coalesce(md5(string_agg(t::text, ''|'' order by t.id)), ''empty'') from public.remote_permission_requests t' into x;
    r := r || '#requests=' || x;
  end if;
  execute 'select string_agg(j::text, ''|'' order by j.jobid) from cron.job j' into x;
  return r || '#cron=' || coalesce(x, 'none') || '#calls=' || (select count(*) from net.v090_calls);
end $$;
SQL

cat > "$WORK/users.sql" <<SQL
insert into auth.users (id, email) values
  ('$UA', 'a@test.local'), ('$UB', 'b@test.local'), ('$UC', 'c@test.local'), ('$UD', 'd@test.local');
insert into public.devices (id, user_id, name, helper_secret)
values ('$DEV', '$UA', 'test-mac', encode(extensions.digest('test-helper-secret', 'sha256'), 'hex'));
update public.user_settings set remote_control_enabled = true where user_id in ('$UA', '$UC', '$UD');
insert into public.app_push_tokens (user_id, platform, bundle_id, token) values
  ('$UA', 'ios', 'test.bundle', 'test-token-aaaaaaaa'),
  ('$UD', 'ios', 'test.bundle', 'test-token-dddddddd');
SQL

# production's default grants on the tables (Supabase's default privileges:
# every API role gets every table), which v0.77 then takes off anon and
# authenticated
cat > "$WORK/prod_grants.sql" <<'SQL'
grant all on public.remote_sessions, public.remote_session_commands, public.remote_session_events,
             public.remote_permission_requests, public.remote_permission_decisions, public.machine_commands,
             public.app_push_tokens, public.app_push_jobs
  to anon, authenticated, service_role;
SQL

# The baseline alone (what a fresh install has): no app-push object.
build_baseline() {
    apply "$SHIM"; apply "$SQL_DIR/schema.sql"; apply "$SQL_DIR/app_rpc.sql"; apply "$SQL_DIR/helper_rpc.sql"
    apply "$WORK/stubs.sql"
}
# The upgrade path's database: production's shape before v0.90.
build_upgrade_base() {
    build_baseline
    apply "$REMOTE"
    q -c "alter table public.remote_permission_requests add column if not exists session_id uuid" >/dev/null
    apply "$WORK/v027_column.sql"; apply "$WORK/v027_gate.sql"; apply "$WORK/v045_rpc.sql"
    q -c "grant execute on function public.remote_helper_create_permission_request(uuid, text, uuid, uuid, text, text, text, jsonb, text, integer) to anon" >/dev/null
    apply "$WORK/v032_cut.prod.sql"
    apply "$V033"
    apply "$WORK/prod_grants.sql"
    apply "$V077"
    q -c "grant execute on function public.process_app_push_jobs() to service_role" >/dev/null
    apply "$WORK/users.sql"
}

# ── the worker, driven the way pg_cron drives it ────────────────────────────
P=""   # the label prefix of the current case: [upgrade], [mutant] ...
invoke() { # one call, its own transaction; anything it prints (a WARNING) fails the case
    local out; out="$(q -c "select public.process_app_push_jobs()" 2>&1)"
    [[ -z "${out//[[:space:]]/}" ]] || fail "$P the worker call printed: $(head -2 <<<"$out" | tr '\n' ' ')"
}
invoke_raise() { # one call with http_post raising
    local out; out="$(q -c "set v090.post_mode = 'raise'; select public.process_app_push_jobs();" 2>&1)"
    [[ -z "${out//[[:space:]]/}" ]] || fail "$P the worker call printed: $(head -2 <<<"$out" | tr '\n' ' ')"
}
reset_queue() {
    q >/dev/null <<'SQL'
truncate public.app_push_jobs restart identity;
delete from public.remote_permission_requests;
truncate net._http_response;
truncate net.v090_calls restart identity;
SQL
}
approval() { # approval <tag> [user] [status]: an approval request, inserted as the helper RPC inserts it; the trigger may enqueue and send
    q -c "insert into public.remote_permission_requests (id, user_id, device_id, provider, tool_name, summary, status)
          values (md5('$1')::uuid, '${2:-$UA}', '$DEV', 'claude', 'Bash', 's', '${3:-pending}')" >/dev/null
}
push() { # push <tag>: UA's approval request; the trigger enqueued its job and sent request 1; the job is aged past pass 2's 5 s; echoes its id
    approval "$1"
    q -c "update public.app_push_jobs set enqueued_at = enqueued_at - interval '6 seconds' where request_id = md5('$1')::uuid returning id"
}
age() { # age <job id> <interval>
    q -c "update public.app_push_jobs set enqueued_at = enqueued_at - interval '$2', dispatched_at = dispatched_at - interval '$2' where id = $1" >/dev/null
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
update public.app_push_jobs set dispatched_at = dispatched_at - interval '3 seconds' where pg_net_request_id = $1;
SQL
}
js() { q -c "select attempt_count || ' ' || coalesce('req' || pg_net_request_id, 'noreq') || ' ' || case when processed_at is null then 'pending' else 'final' end from public.app_push_jobs where id = $1"; }
calls() { q -c "select count(*) from net.v090_calls"; }
st() { echo "$(js "$1") calls=$(calls)"; }
lasterr() { q -c "select coalesce(last_error, '<null>') from public.app_push_jobs where id = $1"; }
pat() { q -c "select processed_at from public.app_push_jobs where id = $1"; }
rq() { # rq <tag>: the approval request's notification_attempts and notification_last_error
    q -c "select notification_attempts || ' ' || coalesce(notification_last_error, '<null>') from public.remote_permission_requests where id = md5('$1')::uuid"
}
req_jobs() { q -c "select count(*) filter (where processed_at is null) || ' pending of ' || count(*) from public.app_push_jobs where request_id = md5('$1')::uuid"; }
second_job() { # second_job <tag>: enqueue a second job for that request, the way the trigger enqueues (on conflict with a pending one, nothing)
    q -c "insert into public.app_push_jobs (user_id, request_id) values ('$UA', md5('$1')::uuid) on conflict (request_id) where processed_at is null do nothing" >/dev/null
}

# ── behavioural cases (P set by the caller) ─────────────────────────────────
case_502() {
    local j t
    reset_queue; j="$(push a502)"
    same "$P 502: the trigger sends request 1 at once (attempt 1)" "$(st "$j") / $(rq a502)" "1 req1 pending calls=1 / 1 <null>"
    check "$P 502: request 1 is the trigger's, to send-approval-push" \
          "(select url = 'https://stub.invalid/functions/v1/send-approval-push' and body = jsonb_build_object('user_id', '$UA', 'request_id', md5('a502')::uuid)
                   and headers->>'X-Internal-Trigger' = 'remote_request_after_insert_push' from net.v090_calls where id = 1)"
    invoke
    same "$P 502: a call before any answer changes nothing" "$(st "$j")" "1 req1 pending calls=1"
    respond 1 502; invoke
    same "$P 502: the first 502 is counted and the retry sent in the same call, not finalized" "$(st "$j")" "3 req2 pending calls=2"
    check "$P 502: request 2 is the worker's retry, carrying the request as before" \
          "(select url = 'https://stub.invalid/functions/v1/send-approval-push' and body = jsonb_build_object('user_id', '$UA', 'request_id', md5('a502')::uuid)
                   and headers->>'Authorization' = 'Bearer stub-key' and headers->>'X-Internal-Trigger' = 'process_app_push_jobs'
                   and timeout_milliseconds = 5000 from net.v090_calls where id = 2)"
    same "$P 502: the request row counts the failed answer and the retry, with the error" "$(rq a502)" "3 edge HTTP 502"
    respond 2 502; invoke
    same "$P 502: the second 502 finalizes the job, and nothing more is sent" "$(st "$j")" "4 noreq final calls=2"
    same "$P 502: its last_error is the second answer" "$(lasterr "$j")" "edge HTTP 502"
    same "$P 502: the request row counts each failed answer; finalizing writes nothing more" "$(rq a502)" "4 edge HTTP 502"
    t="$(pat "$j")"; invoke
    same "$P 502: a further call changes nothing and sends nothing" "$(st "$j") $(pat "$j") / $(rq a502)" "4 noreq final calls=2 $t / 4 edge HTTP 502"
    second_job a502
    same "$P 502: once finalized, a second job for that request can be enqueued (its dedup slot is free)" "$(req_jobs a502)" "1 pending of 2"
    reset_queue; j="$(push a5023)"; respond 1 empty; age "$j" '6 minutes'; invoke
    same "$P 502 at attempt 3: (setup) request 1 abandoned after 5 minutes, request 2 sent" "$(st "$j")" "2 req2 pending calls=2"
    respond 2 502; invoke
    same "$P 502 at attempt 3: a failed answer that reaches attempt 3 finalizes the job (after an abandoned first request)" \
         "$(st "$j") / $(lasterr "$j") / $(rq a5023)" "3 noreq final calls=2 / edge HTTP 502 / 3 edge HTTP 502"
}
case_transport() { # case_transport <timeout|error> <expected detail>
    local j
    reset_queue; j="$(push "at-$1")"
    respond 1 "$1"; invoke
    same "$P transport ($1): the failure counts at once, with no 5-minute wait, and the retry is sent" "$(st "$j")" "3 req2 pending calls=2"
    same "$P transport ($1): the request row counts the failure, with the transport error" "$(rq "at-$1")" "3 edge transport: $2"
    respond 2 "$1"; invoke
    same "$P transport ($1): the second failure finalizes the job" "$(st "$j")" "4 noreq final calls=2"
    same "$P transport ($1): its last_error names the transport failure" "$(lasterr "$j")" "edge transport: $2"
    same "$P transport ($1): the request row as after a failed answer" "$(rq "at-$1")" "4 edge transport: $2"
    reset_queue; j="$(push "at3-$1")"; respond 1 empty; age "$j" '6 minutes'; invoke
    same "$P transport ($1) at attempt 3: (setup) request 1 abandoned after 5 minutes, request 2 sent" "$(st "$j")" "2 req2 pending calls=2"
    respond 2 "$1"; invoke
    same "$P transport ($1): a failure that reaches attempt 3 finalizes the job (after an abandoned first request)" \
         "$(st "$j") / $(lasterr "$j") / $(rq "at3-$1")" "3 noreq final calls=2 / edge transport: $2 / 3 edge transport: $2"
}
case_noresp() {
    local j t
    reset_queue; j="$(push anr)"
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
    same "$P no answer: its last_error says it gave up" "$(lasterr "$j")" "gave up: no response from pg_net (attempt budget used)"
    same "$P no answer: the request row counts the three requests and no error" "$(rq anr)" "3 <null>"
    t="$(pat "$j")"; invoke
    same "$P no answer: a further call changes nothing" "$(st "$j") $(pat "$j")" "3 noreq final calls=3 $t"
}
case_raise() {
    local j t
    reset_queue; j="$(push ars)"; respond 1 502
    invoke_raise
    same "$P raise: a 502 and then a raising retry use the third attempt: finalized" "$(st "$j") / $(lasterr "$j")" \
         "3 noreq final calls=1 / http_post failed: v090 stub: http_post refused"
    same "$P raise: the request row counts the 502 only (a raise writes nothing there)" "$(rq ars)" "2 edge HTTP 502"
    t="$(pat "$j")"; invoke
    same "$P raise: a working http_post afterwards sends nothing for it" "$(st "$j") $(pat "$j")" "3 noreq final calls=1 $t"
    reset_queue; j="$(push ars0)"
    q -c "update public.app_push_jobs set pg_net_request_id = null, dispatched_at = null, attempt_count = 0 where id = $j" >/dev/null
    invoke_raise
    same "$P raise: on a job never sent, the first raise counts attempt 1 and sends nothing" "$(st "$j")" "1 noreq pending calls=1"
    invoke_raise
    same "$P raise: the second raise counts attempt 2, not finalized" "$(st "$j")" "2 noreq pending calls=1"
    invoke_raise
    same "$P raise: the third raise finalizes the job" "$(st "$j")" "3 noreq final calls=1"
}
case_2xx() {
    local j t
    reset_queue; j="$(push a200)"; respond 1 200; invoke
    same "$P 2xx: an answer to the trigger's request finalizes the job successfully" "$(st "$j") / $(lasterr "$j") / $(rq a200)" "1 req1 final calls=1 / <null> / 1 <null>"
    t="$(pat "$j")"; invoke
    same "$P 2xx: a further call leaves processed_at as it was and sends nothing" "$(st "$j") $(pat "$j")" "1 req1 final calls=1 $t"
    reset_queue; j="$(push a2003)"; age "$j" '6 minutes'; invoke; age "$j" '6 minutes'; invoke
    same "$P 2xx on the third request: it goes out, the job pending" "$(st "$j")" "3 req3 pending calls=3"
    respond 3 204; invoke
    same "$P 2xx on the third request: it finalizes the job successfully" "$(st "$j") / $(lasterr "$j")" "3 req3 final calls=3 / <null>"
    t="$(pat "$j")"; invoke
    same "$P 2xx on the third request: a further call changes nothing" "$(st "$j") $(pat "$j")" "3 req3 final calls=3 $t"
}
case_malformed() {
    local j
    reset_queue; j="$(push am1)"
    q >/dev/null <<SQL
update public.app_push_jobs set pg_net_request_id = 900, dispatched_at = null, attempt_count = 1,
       enqueued_at = now() - interval '10 seconds' where id = $j;
insert into net._http_response (id, status_code, content, timed_out) values (900, 200, 'ok', false);
SQL
    invoke
    same "$P malformed: a request id without dispatched_at, answered 200, is reconciled and finalized" "$(st "$j") / $(lasterr "$j")" "1 req900 final calls=1 / <null>"
    reset_queue; j="$(push am2)"
    q -c "update public.app_push_jobs set pg_net_request_id = 901, dispatched_at = null, attempt_count = 1, enqueued_at = now() - interval '10 minutes' where id = $j" >/dev/null
    invoke
    same "$P malformed: one with no answer, enqueued 10 minutes ago, has its request id cleared and a retry sent" "$(st "$j")" "2 req2 pending calls=2"
}
case_serialization() {
    local j bg
    reset_queue; j="$(push asr)"; respond 1 502
    psql "$DB" --no-psqlrc -qtAX -c "select pg_advisory_lock($LOCK_KEY)" -c "select pg_sleep(60)" >/dev/null 2>&1 &
    bg=$!; BGPIDS+=("$bg")
    wait_for "exists (select 1 from pg_locks where locktype = 'advisory' and granted and database = (select oid from pg_database where datname = current_database()))"
    invoke
    same "$P one call at a time: while another session holds the lock, a call reconciles nothing and sends nothing" \
         "$(st "$j") / $(lasterr "$j") / $(rq asr)" "1 req1 pending calls=1 / <null> / 1 <null>"
    q -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() and query = 'select pg_sleep(60)'" >/dev/null
    wait "$bg" >/dev/null 2>&1 || true
    invoke
    same "$P one call at a time: once the lock is free, a call reconciles and sends the retry" "$(st "$j")" "3 req2 pending calls=2"
}
case_dedup() {
    reset_queue
    approval g1; approval g2 "$UB"; approval g3 "$UC"; approval g4 "$UA" approved
    same "$P gates: a pending request of a user with remote control on and a token gets one job; remote control off, no token, or not pending: none" \
         "$(q -c "select string_agg(r.tag, ',' order by r.tag) from (values ('g1'), ('g2'), ('g3'), ('g4')) r(tag) join public.app_push_jobs j on j.request_id = md5(r.tag)::uuid")" "g1"
    same "$P gates: and only g1's request 1 was sent" "$(calls) $(q -c "select string_agg(body->>'request_id', ',' order by id) from net.v090_calls")" "1 $(q -c "select md5('g1')::uuid")"
    second_job g1
    same "$P dedup: while its job is pending, a second job for the request is not enqueued" "$(req_jobs g1)" "1 pending of 1"
    same "$P dedup: the partial unique index is unchanged" \
         "$(q -c "select indexdef from pg_indexes where schemaname = 'public' and indexname = 'idx_app_push_jobs_pending_dedup'")" \
         "CREATE UNIQUE INDEX idx_app_push_jobs_pending_dedup ON public.app_push_jobs USING btree (request_id) WHERE (processed_at IS NULL)"
    local out
    out="$(q -c "set v090.post_mode = 'raise'; insert into public.remote_permission_requests (id, user_id, device_id, provider, status) values (md5('g5')::uuid, '$UA', '$DEV', 'claude', 'pending')" 2>&1)"
    same "$P inherited (header B): when http_post raises inside the trigger, the request is created but its job is rolled back with the trigger's work" \
         "$(grep -c 'remote_request_after_insert_push failed' <<<"$out") / $(q -c "select count(*) from public.remote_permission_requests where id = md5('g5')::uuid and notification_queued_at is null") / $(req_jobs g5)" \
         "1 / 1 / 0 pending of 0"
}
case_transport_timeout() { case_transport timeout "timed out"; }
case_transport_error() { case_transport error "could not connect"; }
run_cases() {
    case_502; case_transport timeout "timed out"; case_transport error "could not connect"; case_noresp
    case_raise; case_2xx; case_malformed; case_serialization; case_dedup
}

# ── backfill fixture: one row per kind the backfill must or must not touch ──
# Each job has its own approval request (expired, so the trigger enqueues
# nothing), with notification columns the backfill must leave alone.
backfill_rows() {
    q >/dev/null <<SQL
insert into public.remote_permission_requests (id, user_id, device_id, provider, status, created_at,
                                               notification_queued_at, notification_attempts, notification_last_error)
select md5('bf-' || t)::uuid, '$UA', '$DEV', 'claude', 'expired', now() - interval '1 day', now() - interval '1 day', n, e
  from (values ('a', 4, 'edge HTTP 502'), ('a3', 2, 'edge HTTP 500'), ('b', 3, null), ('c', 3, null),
               ('d', 2, 'edge HTTP 500'), ('e', 5, 'edge HTTP 500')) v(t, n, e);
insert into public.app_push_jobs (user_id, request_id, enqueued_at, pg_net_request_id, dispatched_at, processed_at, attempt_count, last_error) values
  ('$UA', md5('bf-a')::uuid,  now() - interval '1 day',  null, null, null, 4, 'edge HTTP 502'),
  ('$UA', md5('bf-a3')::uuid, now() - interval '1 day',  null, null, null, 3, 'http_post failed: refused'),
  ('$UA', md5('bf-b')::uuid,  now() - interval '1 hour', 950, now() - interval '1 minute', null, 3, null),
  ('$UA', md5('bf-c')::uuid,  now() - interval '1 hour', 951, now() - interval '10 minutes', null, 3, 'pg_net response not yet available'),
  ('$UA', md5('bf-d')::uuid,  now() - interval '1 hour', null, null, null, 2, 'edge HTTP 500'),
  ('$UA', md5('bf-e')::uuid,  now() - interval '2 days', 940, now() - interval '2 days', now() - interval '2 days', 5, 'edge HTTP 500');
create table b1bt.bf_before as select * from public.app_push_jobs;
create table b1bt.rq_before as select * from public.remote_permission_requests;
SQL
}
row_of() { q -c "select row(enqueued_at, pg_net_request_id, dispatched_at, processed_at, attempt_count, last_error)::text from $2 where request_id = md5('$1')::uuid"; }
backfill_checks() { # what the migration's backfill (or a mutant of it) did to the fixture
    local r
    for r in b c d e; do
        same "$P backfill: row $r is untouched" "$(row_of "bf-$r" public.app_push_jobs)" "$(row_of "bf-$r" b1bt.bf_before)"
    done
    check "$P backfill: rows a and a3 (no request id, attempt_count 4 and 3) are finalized, last_error prefixed, nothing else changed" \
          "(select count(*) = 2 and bool_and(n.processed_at is not null
                   and n.last_error = 'v0.90 backfill: retries exhausted before v0.90; ' || o.last_error
                   and n.attempt_count = o.attempt_count and n.pg_net_request_id is null and n.dispatched_at is null
                   and n.enqueued_at = o.enqueued_at)
              from public.app_push_jobs n join b1bt.bf_before o using (id) where n.request_id in (md5('bf-a')::uuid, md5('bf-a3')::uuid))"
    check "$P backfill: no approval request changed (every column of every request row as before)" \
          "not exists (select * from b1bt.rq_before except select * from public.remote_permission_requests)
           and not exists (select * from public.remote_permission_requests except select * from b1bt.rq_before)"
}

# refuses <label> <regex the error must match> [role]: apply v0.90 to $DB; it
# must fail, on that guard, and leave everything b1bt.snapshot() sees as it was.
refuses() {
    local before after out rc=0
    before="$(q -c "select b1bt.snapshot()")"
    out="$(migrate "$MIG" "${3:-}")" || rc=$?
    after="$(q -c "select b1bt.snapshot()")"
    if (( rc == 0 )); then fail "$1: the migration applied"
    elif ! grep -q -E -- "$2" <<<"$out"; then fail "$1: refused, but not by /$2/: $(grep -m1 -E 'ERROR' <<<"$out")"
    elif [[ "$before" != "$after" ]]; then fail "$1: refused, but something changed"
    else pass "$1"; fi
}
applies() { # applies <label> [role]: apply v0.90 to $DB; it must succeed; echoes nothing, keeps its output in LAST_OUT
    local rc=0
    LAST_OUT="$(migrate "$MIG" "${2:-}")" || rc=$?
    if (( rc == 0 )); then pass "$1"; else fail "$1: $(grep -m1 -E 'ERROR' <<<"$LAST_OUT")"; fi
}
LAST_OUT=""
MIG="$V090"
pause_job() { # the header's P2, as printed; it must touch exactly one job
    local out; out="$(psql "$DB" --no-psqlrc -X -v ON_ERROR_STOP=1 -c "$(hq P2)" 2>&1)"
    grep -q '(1 row)' <<<"$out" || fail "$P P2 (pause) did not return exactly one row: $out"
}
restore_job() { # restore_job <recorded active value>: the header's R9 with that value put in
    local r9 out
    r9="$(hq R9)"
    [[ "$(grep -o '<recorded active>' <<<"$r9" | wc -l | tr -d ' ')" == 1 ]] || { echo "R9: want one <recorded active>" >&2; exit 2; }
    out="$(psql "$DB" --no-psqlrc -X -v ON_ERROR_STOP=1 -c "${r9/<recorded active>/$1}" 2>&1)"
    grep -q '(1 row)' <<<"$out" || fail "$P R9 (restore $1) did not return exactly one row: $out"
}
q0() { q -c "$(hq Q0)"; }
q3() { q -c "$(hq Q3)"; }
q5() { q -c "$(hq Q5)"; }
q5r() { q -c "$(hq Q5r)"; }
q8r() { q -c "$(hq Q8r)"; }
worker_md5() { q -c "select md5(prosrc) from pg_proc where oid = 'public.process_app_push_jobs()'::regprocedure"; }
notice() { grep -E 'NOTICE: +v0\.90: ' <<<"$1" | grep -v 'queue lock was held' | sed -E 's/.*NOTICE: +v0\.90: //' | paste -sd'|' -; }
lock_ms() { grep -oE 'queue lock was held [0-9]+ ms' <<<"$1" | grep -oE '[0-9]+' | tail -1; }
# fingerprint: the app-push objects' catalog (bodies as md5s), one line each
fingerprint() {
    q <<'SQL'
with t(oid) as (select unnest(array['public.app_push_jobs'::regclass, 'public.app_push_tokens'::regclass,
                                    'public.remote_permission_requests'::regclass]::oid[]))
select 'fn|' || p.oid::regprocedure || '|' || md5(p.prosrc) || '|' || p.prosecdef || '|' || coalesce(p.proconfig::text, '')
       || '|' || coalesce(p.proacl::text, '') || '|' || pg_get_userbyid(p.proowner)
  from pg_proc p where p.proname in ('process_app_push_jobs', 'remote_request_after_insert_push', 'remote_helper_create_permission_request')
union all
select 'col|' || c.relname || '|' || a.attname || '|' || format_type(a.atttypid, a.atttypmod) || '|' || a.attnotnull
       || '|' || coalesce(pg_get_expr(d.adbin, d.adrelid), '') || '|' || coalesce(md5(col_description(c.oid, a.attnum)), '')
  from t join pg_class c on c.oid = t.oid
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
union all
select 'rel|' || c.relname || '|' || c.relrowsecurity || '|' || coalesce(c.relacl::text, '') from t join pg_class c on c.oid = t.oid
union all
select 'idx|' || i.indexrelid::regclass || '|' || pg_get_indexdef(i.indexrelid) from t join pg_index i on i.indrelid = t.oid
union all
select 'con|' || conrelid::regclass || '|' || conname || '|' || pg_get_constraintdef(oid) from pg_constraint where conrelid in (select oid from t)
union all
select 'pol|' || polrelid::regclass || '|' || polname || '|' || polcmd::text || '|' || coalesce(pg_get_expr(polqual, polrelid), '')
       || '|' || coalesce(pg_get_expr(polwithcheck, polrelid), '') from pg_policy where polrelid in (select oid from t)
union all
select 'trg|' || tgrelid::regclass || '|' || tgname || '|' || tgenabled::text || '|' || tgfoid::regprocedure
  from pg_trigger where not tgisinternal and tgrelid in (select oid from t)
order by 1;
SQL
}

SU="$(psql "$DATABASE_URL" -qtAX -c 'select current_user')"
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }

# =============================================================================
echo "== 0. md5 values (the header's and the guard's against the files)"
newdb "${PFX}_md5"; apply "$SHIM"
body_md5() { # body_md5 <file holding the worker's CREATE statement>
    q -c "drop function if exists public.process_app_push_jobs()" >/dev/null
    apply "$1"
    worker_md5
}
between "$V090" worker > "$WORK/worker.sql"
between "$V090" backfill > "$WORK/backfill.sql"
grep -q '^create or replace function public\.process_app_push_jobs()$' "$WORK/worker.sql" \
    || { echo "the worker markers do not hold the worker" >&2; exit 2; }
strip_comment_lines "$WORK/worker.sql" > "$WORK/worker.stripped.sql"
FILES32="$(body_md5 "$WORK/w32.sql")"
PROD32="$(body_md5 "$WORK/w32.prod.sql")"
RAW90="$(body_md5 "$WORK/worker.sql")"
STRIP90="$(body_md5 "$WORK/worker.stripped.sql")"
same "0. v0.32's worker without its comment-only lines is production's measured body" "$PROD32" "$PROD_WORKER_MD5"
if [[ "$RAW90" != "$STRIP90" ]]; then pass "0. v0.90's body has comment-only lines, so its two forms differ and both are listed"
else fail "0. v0.90's raw and stripped bodies are equal: the header's two 'after' values would be one"; fi
same "0. the header's MD5 VALUES are the four bodies, in order" \
     "$(grep -E '^--   (before|after) +v0\.(32|90), ' "$V090" | grep -oE '[0-9a-f]{32}$' | paste -sd' ' -)" \
     "$PROD32 $FILES32 $RAW90 $STRIP90"
same "0. the md5 literals in the migration's code are exactly those four" \
     "$(sed -n '/^begin;$/,$p' "$V090" | grep -oE "'[0-9a-f]{32}'" | tr -d "'" | sort -u | paste -sd' ' -)" \
     "$(printf '%s\n' "$PROD32" "$FILES32" "$RAW90" "$STRIP90" | sort -u | paste -sd' ' -)"
same "0. the guard (A2) lists all four" \
     "$(sed -n '/^do \$guard\$$/,/^\$guard\$;$/p' "$V090" | grep -oE "'[0-9a-f]{32}'" | tr -d "'" | sort | paste -sd' ' -)" \
     "$(printf '%s\n' "$PROD32" "$FILES32" "$RAW90" "$STRIP90" | sort | paste -sd' ' -)"
same "0. the verification (E) lists the two 'after' values only" \
     "$(sed -n '/^do \$verify\$$/,/^\$verify\$;$/p' "$V090" | grep -oE "'[0-9a-f]{32}'" | tr -d "'" | sort | paste -sd' ' -)" \
     "$(printf '%s\n' "$RAW90" "$STRIP90" | sort | paste -sd' ' -)"
same "0. step 0 (Q0) expects production's body on a first apply" "$(grep -c -E "^--    FIRST APPLY: expect body_md5 = $PROD_WORKER_MD5,$" "$V090")" "1"
HDR="$(sed -n '1,/^begin;$/p' "$V090" | sed -E 's/^-- ?//' | tr '\n' ' ' | tr -s ' ')"
if [[ "$HDR" == *"RE-RUN OR RECOVERY: body_md5 = $RAW90 or $STRIP90 "* ]]; then pass "0. step 0 accepts the two v0.90 bodies on a re-run or in recovery"
else fail "0. step 0's RE-RUN OR RECOVERY line does not list $RAW90 and $STRIP90"; fi
held="$(grep -c -x 'commit;' "$V090" || true)"
[[ "$held" == 1 ]] || { echo "the migration must end with exactly one 'commit;' line (found $held)" >&2; exit 2; }
if grep -q -i -E 'webhook_jobs|process_webhook_jobs|alerts_enqueue_webhook|alerts_webhook_enqueue' "$V090"; then
    fail "0. the migration names a webhook queue object: B0's raw-text guard (run_webhook_baseline_tests.sh) would need an allowlist line"
else pass "0. the migration names no webhook queue object, so B0's raw-text guard is not tripped"; fi
dropdb_now "${PFX}_md5"

# =============================================================================
echo "== 1. control: the bug, on the old body (production's shape before v0.90)"
newdb "${PFX}_upbase"; build_upgrade_base
same "1. the upgrade base runs production's worker body" "$(worker_md5)" "$PROD_WORKER_MD5"
same "1. and the worker's ACL as Supabase's default privileges leave it after v0.32's revoke" \
     "$(q -c "select proacl::text from pg_proc where oid = 'public.process_app_push_jobs()'::regprocedure")" \
     "{$SU=X/$SU,service_role=X/$SU}"
check "1. the cut built every object (tokens, queue, both indexes, policy, trigger, notification columns)" \
      "to_regclass('public.app_push_tokens') is not null and to_regclass('public.idx_app_push_jobs_pending_dedup') is not null
       and to_regclass('public.idx_app_push_jobs_pending_drain') is not null and to_regclass('public.idx_app_push_jobs_user_id') is not null
       and exists (select 1 from pg_policies where tablename = 'app_push_jobs' and policyname = 'Service role only on app_push_jobs' and qual like '%SELECT auth.role()%')
       and exists (select 1 from pg_trigger where tgname = 'remote_permission_requests_after_insert_push' and tgenabled = 'O')
       and (select count(*) = 4 from pg_attribute where attrelid = 'public.remote_permission_requests'::regclass
            and attname in ('notification_queued_at', 'notification_attempts', 'notification_last_error', 'notified_at'))"
check "1. v0.77's revoke holds: anon and authenticated hold nothing on the queue, service_role does" \
      "not has_table_privilege('anon', 'public.app_push_jobs', 'SELECT') and not has_table_privilege('authenticated', 'public.app_push_jobs', 'SELECT')
       and has_table_privilege('service_role', 'public.app_push_jobs', 'SELECT')"
newdb "${PFX}_ctl" "${PFX}_upbase"
P="[v0.32 control]"
reset_queue; j="$(push c502)"; respond 1 502; invoke; respond 2 502; invoke; invoke
same "$P a 502 twice ends at attempt 4, pending, after 2 requests" "$(st "$j") / $(rq c502)" "4 noreq pending calls=2 / 4 edge HTTP 502"
second_job c502
same "$P and its pending slot keeps a second job for that request out" "$(req_jobs c502)" "1 pending of 1"
reset_queue; j="$(push cnr)"; age "$j" '6 minutes'; invoke; age "$j" '6 minutes'; invoke
age "$j" '6 minutes'; invoke; invoke
same "$P no answer ends at attempt 3, pending, after 3 requests" "$(st "$j")" "3 noreq pending calls=3"
reset_queue; j="$(push crs)"; respond 1 502; invoke_raise; invoke_raise
same "$P a 502 and then a raising retry end at attempt 3, pending" "$(st "$j")" "3 noreq pending calls=1"
reset_queue; j="$(push ctt)"; respond 1 timeout; invoke
same "$P a timed-out request is read as no answer yet (it waits 5 minutes)" "$(st "$j") / $(rq ctt)" "1 req1 pending calls=1 / 1 <null>"
reset_queue; j="$(push cmf)"
q -c "update public.app_push_jobs set pg_net_request_id = 900, dispatched_at = null, attempt_count = 1, enqueued_at = now() - interval '10 minutes' where id = $j; insert into net._http_response (id, status_code, timed_out) values (900, 200, false);" >/dev/null
invoke
same "$P a request id without dispatched_at is never reconciled" "$(st "$j")" "1 req900 pending calls=1"
dropdb_now "${PFX}_ctl"

# =============================================================================
echo "== 2. upgrade: the header's steps, as printed"
newdb "${PFX}_up" "${PFX}_upbase"
P="[upgrade]"
ACL_UP="$(q -c "select md5('{$SU=X/$SU,service_role=X/$SU}')")"
JOB_MD5="$(q -c "select md5('5|app_push_jobs_drain|30 seconds|select public.process_app_push_jobs()|$SU')")"
same "$P Q0 before (hashes and booleans only): production's body, one function, attributes, applier, grants, ACL, no comment" \
     "$(q0)" "$PROD_WORKER_MD5|1|t|t|t|$ACL_UP|"
hvals() { grep -oE "$1 = [0-9a-f]{32}" <<<"$HDR" | grep -oE '[0-9a-f]{32}' | sort -u | paste -sd' ' -; }
if [[ "$SU" == postgres ]]; then   # the header states production's values, whose role is postgres
    same "$P the header's expected acl_md5 is this ACL's" "$(hvals acl_md5)" "$ACL_UP"
    same "$P the header's expected job_md5 is this job's (production's)" "$(hvals job_md5)" "$JOB_MD5"
fi
FP_BEFORE="$(fingerprint)"
for l in Q1 Q1b Q2b Q3b Q8r Q9; do q -c "$(hq "$l")" >/dev/null || fail "$P $l does not run as printed"; done
same "$P Q1 returns counts only (no timestamp column)" \
     "$(psql "$DB" --no-psqlrc -X -A -c "$(hq Q1)" | head -1)" \
     "total|pending|stuck|awaiting|pending_id_without_dispatch|pending_over_1_day|finalized_with_request_id|odd_counts"
same "$P Q2: both secrets once, non-empty (no value selected)" "$(q -c "$(hq Q2)" | sort | paste -sd' ' -)" \
     "app_service_role_key|1|1 app_supabase_url|1|1"
same "$P Q3: one job by command, one by name, the same job, active, its definition's hash" "$(q3)" "1|1|1|true|$JOB_MD5"
q -c "$(hq R0)" > "$WORK/rollback.sql"; echo ';' >> "$WORK/rollback.sql"
grep -q 'CREATE OR REPLACE FUNCTION public.process_app_push_jobs()' "$WORK/rollback.sql" || fail "$P R0 did not print the worker's definition"
pause_job
same "$P P2 paused the app-push job and nothing else" \
     "$(q -c "select string_agg(jobid || '=' || active, ' ' order by jobid) from cron.job")" "3=true 5=false"
same "$P Q3 after the pause" "$(q3)" "1|1|1|false|$JOB_MD5"
same "$P Q4: nothing running, no idle transaction holding the queue, nobody holding the queue, everybody visible" "$(q -c "$(hq Q4)")" "0|0|0|0"
same "$P Q4b: a 'running' row 20 minutes old does not count" "$(q -c "$(hq Q4b)")" "0"
q -c "insert into cron.job_run_details (jobid, status, start_time) values (5, 'starting', now() - interval '1 minute')" >/dev/null
same "$P Q4b: a recent 'starting' row does" "$(q -c "$(hq Q4b)")" "1"
q -c "update cron.job_run_details set status = 'succeeded', end_time = now() where status = 'starting'" >/dev/null
same "$P Q5: the recount right before the apply" "$(q5)" "0"
same "$P Q5r: no stuck job, no request" "$(q5r)" "0|$(q -c "select md5('')")"
same "$P Q6 before the apply: no worker lock, no apply session" "$(q -c "$(hq Q6)")" "0|0"
applies "$P the migration applies on production's shape, the job paused"
ms="$(lock_ms "$LAST_OUT")"
if [[ -n "$ms" ]]; then pass "$P its NOTICE gives the queue lock's hold time ($ms ms here, empty queue)"; else fail "$P no 'queue lock was held' NOTICE"; fi
same "$P its NOTICEs: applier and owner, nothing to backfill, the body it installed" "$(notice "$LAST_OUT")" \
     "applier $SU, worker owner $SU|backfilled 0 stuck job(s): finalized with failure, nothing re-sent|worker replaced (body md5 $RAW90), owner and ACL unchanged"
COMMENT_MD5="$(q -c "select md5(col_description('public.app_push_jobs'::regclass, (select attnum from pg_attribute where attrelid = 'public.app_push_jobs'::regclass and attname = 'processed_at')))")"
same "$P Q0 after: v0.90's body and the comment, everything else as before" "$(q0)" "$RAW90|1|t|t|t|$ACL_UP|$COMMENT_MD5"
same "$P every comment_md5 the header expects is the comment's" \
     "$(grep -oE 'comment_md5 =? ?[0-9a-f]{32}' <<<"$HDR" | grep -oE '[0-9a-f]{32}' | sort -u | paste -sd' ' -)" "$COMMENT_MD5"
same "$P Q3 after the apply: same job, same definition, still paused" "$(q3)" "1|1|1|false|$JOB_MD5"
restore_job true
same "$P R9 restored the recorded value (true); Q3 as in step 0" "$(q3)" "1|1|1|true|$JOB_MD5"
FP_AFTER="$(fingerprint)"
same "$P fingerprint: only the worker's line and processed_at's line changed" \
     "$(diff <(echo "$FP_BEFORE") <(echo "$FP_AFTER") | grep -E '^[<>] ' \
        | sed -E 's/^([<>]) (fn\|process_app_push_jobs\(\)|col\|app_push_jobs\|processed_at)\|.*/\1 \2/' | sort | paste -sd' ' -)" \
     "< col|app_push_jobs|processed_at < fn|process_app_push_jobs() > col|app_push_jobs|processed_at > fn|process_app_push_jobs()"
same "$P fingerprint: the worker's line moved in its body md5 only" \
     "$(diff <(grep '^fn|process_app_push_jobs()|' <<<"$FP_BEFORE" | sed "s/$PROD_WORKER_MD5/X/") <(grep '^fn|process_app_push_jobs()|' <<<"$FP_AFTER" | sed "s/$RAW90/X/") >/dev/null && echo same)" "same"
check "$P contract: SECURITY DEFINER, search_path pinned, no arguments, returns void, plpgsql" \
      "(select p.prosecdef and p.proconfig = array['search_path=pg_catalog, extensions, public, net']
               and pg_get_function_identity_arguments(p.oid) = '' and p.prorettype = 'void'::regtype and l.lanname = 'plpgsql'
          from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = 'public.process_app_push_jobs()'::regprocedure)"
check "$P contract: anon and authenticated cannot execute it, service_role can (as before)" \
      "not has_function_privilege('anon', 'public.process_app_push_jobs()', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.process_app_push_jobs()', 'EXECUTE')
       and has_function_privilege('service_role', 'public.process_app_push_jobs()', 'EXECUTE')"
check "$P the column comment says FINALIZED" \
      "col_description('public.app_push_jobs'::regclass, (select attnum from pg_attribute where attrelid = 'public.app_push_jobs'::regclass and attname = 'processed_at')) like 'FINALIZED, not delivered (v0.90).%'"
pause_job
applies "$P applied a second time"
same "$P second time: nothing backfilled, same body, owner and ACL" "$(notice "$LAST_OUT") / $(q0)" \
     "applier $SU, worker owner $SU|backfilled 0 stuck job(s): finalized with failure, nothing re-sent|worker replaced (body md5 $RAW90), owner and ACL unchanged / $RAW90|1|t|t|t|$ACL_UP|$COMMENT_MD5"
restore_job true

# =============================================================================
echo "== 3. behaviour (upgrade path, after v0.90)"
newdb "${PFX}_cases" "${PFX}_up"
P="[upgrade]"
run_cases
dropdb_now "${PFX}_cases"

# =============================================================================
echo "== 4. backfill"
newdb "${PFX}_bf" "${PFX}_upbase"
P="[upgrade]"
backfill_rows
q1_stuck="$(q -c "select stuck from ($(hq Q1 | sed 's/;$//')) q1")"
same "$P Q1 (preliminary) counts the two stuck rows" "$q1_stuck" "2"
same "$P Q1b, by attempt_count" "$(q -c "$(hq Q1b)" | paste -sd' ' -)" "2|1 3|3 4|1"
pause_job
# the old worker was still running between Q1 and the pause: one more job used its attempts up
q >/dev/null <<SQL
insert into public.remote_permission_requests (id, user_id, device_id, provider, status, notification_attempts, notification_last_error)
values (md5('bf-late')::uuid, '$UA', '$DEV', 'claude', 'expired', 4, 'edge HTTP 502');
insert into public.app_push_jobs (user_id, request_id, attempt_count, last_error) values ('$UA', md5('bf-late')::uuid, 4, 'edge HTTP 502');
drop table b1bt.rq_before; create table b1bt.rq_before as select * from public.remote_permission_requests;
SQL
same "$P Q4 after the pause: quiet" "$(q -c "$(hq Q4)")" "0|0|0|0"
n_stuck="$(q5)"
same "$P Q5, the recount after the pause, sees the job that got stuck after Q1" "$n_stuck" "3"
r_before="$(q5r)"
same "$P Q5r counts their three approval requests" "${r_before%%|*}" "3"
applies "$P the migration applies with stuck rows"
same "$P its NOTICE backfilled the recount (not Q1's preliminary count)" "$(notice "$LAST_OUT" | cut -d'|' -f2)" \
     "backfilled $n_stuck stuck job(s): finalized with failure, nothing re-sent"
backfill_checks
same "$P Q5 after: stuck = 0" "$(q5)" "0"
same "$P Q5r after equals step 4's: the backfill changed no approval request" "$(q5r)" "$r_before"
same "$P Q8r (step 8b: the backfilled cohort only) equals step 4's R as well" "$(q8r)" "$r_before"
restore_job true
invoke
same "$P row b (third request live for 1 minute) stays pending under the new worker" "$(q -c "select attempt_count || ' ' || pg_net_request_id || ' ' || (processed_at is null) from public.app_push_jobs where request_id = md5('bf-b')::uuid")" "3 950 true"
same "$P row c (third request, no answer for 10 minutes) is given up by the new worker" \
     "$(q -c "select (processed_at is not null) || ' ' || coalesce(pg_net_request_id::text, 'noreq') || ' ' || last_error from public.app_push_jobs where request_id = md5('bf-c')::uuid")" \
     "true noreq gave up: no response from pg_net (attempt budget used)"
same "$P row d (attempt 2) gets its third request, counted on its approval request" \
     "$(q -c "select attempt_count || ' req' || pg_net_request_id || ' ' || (processed_at is null) from public.app_push_jobs where request_id = md5('bf-d')::uuid") calls=$(calls) / $(rq bf-d)" \
     "3 req1 true calls=1 / 3 edge HTTP 500"
same "$P Q5 (new stuck) stays 0 under the new worker" "$(q5)" "0"
# rollback: R0's saved definition, the job paused
pause_job
apply "$WORK/rollback.sql"
same "$P rollback: R0's saved definition restores production's body; ACL unchanged, the comment stays" \
     "$(q0)" "$PROD_WORKER_MD5|1|t|t|t|$ACL_UP|$COMMENT_MD5"
check "$P rollback: the backfilled rows stay finalized" \
      "(select bool_and(processed_at is not null and last_error like 'v0.90 backfill: %') from public.app_push_jobs where request_id in (md5('bf-a')::uuid, md5('bf-a3')::uuid))"
restore_job true
dropdb_now "${PFX}_bf"

newdb "${PFX}_bfs" "${PFX}_upbase"
q >/dev/null <<SQL
insert into public.remote_permission_requests (id, user_id, device_id, provider, status, notification_attempts, notification_last_error)
select md5('bulk-' || i)::uuid, '$UA', '$DEV', 'claude', 'expired', 4, 'edge HTTP 502' from generate_series(1, 5001) i;
insert into public.app_push_jobs (user_id, request_id, attempt_count, last_error)
select '$UA', md5('bulk-' || i)::uuid, 4, 'edge HTTP 502' from generate_series(1, 5001) i;
SQL
backfill_rows
pause_job
refuses "$P size guard: 5003 stuck jobs: refused, nothing changed" 'more than 5000'
r_before="$(q5r)"
q -c "$(hq BF)" >/dev/null
n_stuck="$(q5)"
same "$P one BF batch, as printed, finalizes 1000 (job still paused; Q5 recounts)" "$n_stuck / $(q3)" "4003 / 1|1|1|false|$JOB_MD5"
same "$P Q5r still counts the same requests after BF (stuck, or finalized by BF)" "$(q5r)" "$r_before"
applies "$P after it the migration applies"
same "$P and backfills the rest (the recount after the batch)" "$(notice "$LAST_OUT" | cut -d'|' -f2)" \
     "backfilled $n_stuck stuck job(s): finalized with failure, nothing re-sent"
backfill_checks
same "$P Q5r after equals the value before BF and the apply" "$(q5r)" "$r_before"
same "$P Q8r (the backfilled cohort, BF's and the migration's) equals it too" "$(q8r)" "$r_before"
dropdb_now "${PFX}_bfs"

# =============================================================================
echo "== 5. re-runs (bodies with and without comment-only lines)"
strip_comment_lines "$V090" > "$WORK/v090.stripped.sql"
newdb "${PFX}_rr" "${PFX}_upbase"
P="[re-run]"
pause_job
rc=0; LAST_OUT="$(migrate "$WORK/v090.stripped.sql")" || rc=$?
same "$P the migration without its comment-only lines applies on production's body" "$rc / $(worker_md5)" "0 / $STRIP90"
applies "$P then as written, over the stripped v0.90 body"
same "$P which installs the raw body" "$(worker_md5)" "$RAW90"
rc=0; LAST_OUT="$(migrate "$WORK/v090.stripped.sql")" || rc=$?
same "$P and stripped again, over the raw v0.90 body" "$rc / $(worker_md5)" "0 / $STRIP90"
dropdb_now "${PFX}_rr"
newdb "${PFX}_rr32" "${PFX}_upbase"
q -f "$WORK/w32.sql" >/dev/null
same "$P a database on v0.32's body as the file has it" "$(worker_md5)" "$FILES32"
pause_job
applies "$P the migration applies there too"
same "$P installing v0.90's body" "$(worker_md5)" "$RAW90"
dropdb_now "${PFX}_rr32"

# =============================================================================
echo "== 6. guards: each refuses and changes nothing"
psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 \
    -c "create role $STRANGER nologin" -c "create role $MEMBER nologin" -c "grant $SU to $MEMBER" \
    -c "create role $CARRIER nologin" >/dev/null
P="[guard]"
newdb "${PFX}_fresh"; build_baseline
refuses "$P a baseline-only database (a fresh install: no app-push queue): refused, nothing changed" 'public\.app_push_jobs does not exist'
dropdb_now "${PFX}_fresh"
newdb "${PFX}_gb" "${PFX}_upbase"
pause_job; backfill_rows
G=0
guard() { # guard <label> <regex> <setup sql or ""> [role]
    G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_gb"
    [[ -z "$3" ]] || q >/dev/null <<<"$3"
    refuses "$P $1: refused, nothing changed" "$2" "${4:-}"
    dropdb_now "${PFX}_g$G"
}
guard "no app_push_jobs table" 'public\.app_push_jobs does not exist' \
      "drop table public.app_push_jobs cascade;"
guard "the insert trigger disabled" 'trigger remote_permission_requests_after_insert_push on public\.remote_permission_requests is missing, disabled' \
      "alter table public.remote_permission_requests disable trigger remote_permission_requests_after_insert_push;"
guard "the insert trigger calling another function" 'trigger remote_permission_requests_after_insert_push on public\.remote_permission_requests is missing, disabled or calls another function' \
      "create function public.other_push() returns trigger language plpgsql as 'begin return new; end';
       drop trigger remote_permission_requests_after_insert_push on public.remote_permission_requests;
       create trigger remote_permission_requests_after_insert_push after insert on public.remote_permission_requests for each row execute function public.other_push();"
guard "the approval requests without notification_last_error" 'public\.remote_permission_requests lacks notification_last_error' \
      "alter table public.remote_permission_requests drop column notification_last_error;"
guard "a second process_app_push_jobs in another schema" 'expected exactly one function named process_app_push_jobs' \
      "create schema other; create function other.process_app_push_jobs() returns void language sql as 'select';"
guard "an overload in public" 'expected exactly one function named process_app_push_jobs' \
      "create function public.process_app_push_jobs(integer) returns void language sql as 'select';"
guard "net._http_response without timed_out" 'net\._http_response lacks timed_out' \
      "alter table net._http_response drop column timed_out;"
guard "a foreign body that contains the old error text and 'v0.90'" 'unexpected definition \(body md5 [0-9a-f]+\), rebase required' \
      "create or replace function public.process_app_push_jobs() returns void as \$\$
begin
  -- v0.90: pg_net response not yet available
  raise warning 'process_app_push_jobs reconcile (job %): %', 0, 'pg_net response not yet available, v0.90';
end;
\$\$ language plpgsql security definer set search_path = pg_catalog, extensions, public, net;"
guard "SECURITY INVOKER" 'is not SECURITY DEFINER' \
      "alter function public.process_app_push_jobs() security invoker;"
guard "another search_path" 'has proconfig .*expected \{search_path=pg_catalog, extensions, public, net\}' \
      "alter function public.process_app_push_jobs() set search_path = public;"
guard "EXECUTE granted to authenticated" 'PUBLIC, anon or authenticated may execute' \
      "grant execute on function public.process_app_push_jobs() to authenticated;"
guard "EXECUTE granted to PUBLIC" 'PUBLIC, anon or authenticated may execute' \
      "grant execute on function public.process_app_push_jobs() to public;"
guard "an applier that is neither the owner nor a member of it" "$STRANGER is neither the owner .* nor a member" \
      "" "$STRANGER"
guard "the cron job still active" 'cron job 5 \(app_push_jobs_drain\) is active; pause it first' \
      "update cron.job set active = true where jobid = 5;"
guard "a second cron job calling the worker, under another name" 'expected exactly one cron job calling process_app_push_jobs, found 2' \
      "insert into cron.job (jobname, schedule, command, active) values ('push_again', '1 minute', 'SELECT PUBLIC.PROCESS_APP_PUSH_JOBS();', false);"
guard "the job renamed" 'expected exactly one cron job named app_push_jobs_drain, found 0' \
      "update cron.job set jobname = 'app_push_retry' where jobid = 5;"
guard "a second job named app_push_jobs_drain (another user, another command)" 'expected exactly one cron job named app_push_jobs_drain, found 2' \
      "insert into cron.job (jobname, schedule, command, username, active) values ('app_push_jobs_drain', '1 minute', 'select 1', 'service_role', false);"
guard "the name on another command, the worker under another name" 'the cron job calling process_app_push_jobs is job 5 named app_push_retry, not app_push_jobs_drain' \
      "update cron.job set jobname = 'app_push_retry' where jobid = 5;
       insert into cron.job (jobname, schedule, command, active) values ('app_push_jobs_drain', '30 seconds', 'select 1', false);"
guard "a cron job whose user cannot execute the worker" 'cron job 5 runs as anon, which cannot execute' \
      "update cron.job set username = 'anon' where jobid = 5;"
guard "a cron job whose user does not exist" 'cron job 5 runs as no_such_role_v090, which cannot execute' \
      "update cron.job set username = 'no_such_role_v090' where jobid = 5;"
# EXECUTE that reaches anon only through a role it inherits: no direct grant
# to PUBLIC, anon or authenticated, so only the effective check refuses it
# (PostgreSQL 16+: the membership is granted WITH INHERIT TRUE, since the
# shim's anon, like Supabase's, is NOINHERIT)
ex_inherited() {
    newdb "${PFX}_x$1" "${PFX}_gb"
    q -c "grant execute on function public.process_app_push_jobs() to $CARRIER" >/dev/null
    psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 -c "grant $CARRIER to anon with inherit true" >/dev/null
    same "$P (setup) no direct grant to PUBLIC, anon or authenticated, yet anon can execute the worker: Q0's anon_auth_denied is false" \
         "$(q -c "select proacl::text from pg_proc where oid = 'public.process_app_push_jobs()'::regprocedure") / $(q0 | cut -d'|' -f5)" \
         "{$SU=X/$SU,service_role=X/$SU,$CARRIER=X/$SU} / f"
    refuses "$P EXECUTE reaching anon through an inherited role (no direct grant): refused, nothing changed" \
            'anon may execute public\.process_app_push_jobs\(\) through a role it inherits'
    psql "$DATABASE_URL" -qtAX -c "revoke $CARRIER from anon" >/dev/null
    dropdb_now "${PFX}_x$1"
}
ex_inherited inherited
# a session running the worker (upper case: tools may upper-case SQL)
G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_gb"
psql "$DB" --no-psqlrc -qtAX -c "SELECT PUBLIC.PROCESS_APP_PUSH_JOBS(), PG_SLEEP(60)" >/dev/null 2>&1 &
bg=$!; BGPIDS+=("$bg")
wait_for "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'active' and query like '%PG_SLEEP(60)%')"
refuses "$P a session running the worker (its query in upper case): refused, nothing changed" 'another session is running a query that names process_app_push_jobs'
q -c "select pg_terminate_backend(pid) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query like '%PG_SLEEP(60)%'" >/dev/null
wait "$bg" >/dev/null 2>&1 || true
dropdb_now "${PFX}_g$G"
# a session holding the worker's catalog row: the replace gives up at lock_timeout
G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_gb"
psql "$DB" --no-psqlrc -qtAX -c "begin" -c "alter function public.process_app_push_jobs() set work_mem = '64kB'" -c "select pg_sleep(60)" >/dev/null 2>&1 &
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
psql "$DB" --no-psqlrc -qtAX -c "select pg_sleep(60), 'process_app_push_jobs()' as watched, (select count(*) from pg_stat_activity)" >/dev/null 2>&1 &
bg1=$!; BGPIDS+=("$bg1")
psql "$BASE/${PFX}_other" --no-psqlrc -qtAX -c "select pg_sleep(60) /* public.process_app_push_jobs() */" >/dev/null 2>&1 &
bg2=$!; BGPIDS+=("$bg2")
wait_for "(select count(*) from pg_stat_activity where pid <> pg_backend_pid() and state = 'active' and query like '%pg_sleep(60)%process_app_push_jobs()%') = 2"
applies "$P a monitoring query naming the worker, and a session in another database, do not block it"
psql "$DATABASE_URL" -qtAX -c "select pg_terminate_backend(pid) from pg_stat_activity where datname in ('${PFX}_g$G', '${PFX}_other') and pid <> pg_backend_pid()" >/dev/null
wait "$bg1" "$bg2" >/dev/null 2>&1 || true
dropdb_now "${PFX}_g$G"; dropdb_now "${PFX}_other"
# an applier that is a member of the owner role (not superuser) applies
G=$((G + 1)); newdb "${PFX}_g$G" "${PFX}_gb"
applies "$P an applier that is a member of the owner role, not a superuser, applies" "$MEMBER"
same "$P its NOTICE names that applier and the owner; the owner is unchanged" \
     "$(notice "$LAST_OUT" | cut -d'|' -f1) / $(q -c "select pg_get_userbyid(proowner) from pg_proc where oid = 'public.process_app_push_jobs()'::regprocedure")" \
     "applier $MEMBER, worker owner $SU / $SU"
dropdb_now "${PFX}_g$G"

# =============================================================================
echo "== 6b. exclusive access to the queue (A5) and the late caller"
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
    idle_open "select public.process_app_push_jobs();"
    wait_for "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'idle in transaction')"
    check "$P (setup) the idle session ran the worker and holds a write lock on the queue" \
          "exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid where a.state = 'idle in transaction' and a.datname = current_database() and l.relation = 'public.app_push_jobs'::regclass and l.mode = 'RowExclusiveLock')"
    same "$P (setup) Q4 sees it: idle_holding_queue and queue_lock_holders" "$(q -c "$(hq Q4)" | cut -d'|' -f2,3)" "1|1"
    refuses "$P an idle transaction that already ran the worker: refused, nothing changed" 'idle in an open transaction'
    idle_close
    dropdb_now "${PFX}_x$1"
}
ex_reader() {
    newdb "${PFX}_x$1" "${PFX}_gb"
    start_bg psql "$DB" --no-psqlrc -qtAX -c "begin" -c "select count(*) from public.app_push_jobs" -c "select pg_sleep(60)"
    local b=$BGPID
    wait_for "$(sleeping 'select pg_sleep(60)')"
    refuses "$P an open transaction that read the queue (busy, not idle, not naming the worker): refused by the lock check, nothing changed" \
            'other session\(s\) hold a lock on public\.app_push_jobs'
    end_sleepers; wait "$b" >/dev/null 2>&1 || true
    dropdb_now "${PFX}_x$1"
}
ex_writer() {
    local b t0
    newdb "${PFX}_x$1" "${PFX}_gb"
    start_bg psql "$DB" --no-psqlrc -qtAX -c "begin" -c "update public.app_push_jobs set attempt_count = attempt_count where id = -1" -c "select pg_sleep(60)"
    b=$BGPID
    wait_for "$(sleeping 'select pg_sleep(60)')"
    t0=$(now_ms)
    refuses "$P an open transaction that wrote the queue: the apply waits for it, gives up at lock_timeout, nothing changed" \
            'held a write lock on public\.app_push_jobs'
    t0=$(( $(now_ms) - t0 ))
    if (( t0 >= 900 && t0 < 10000 )); then pass "$P and it waited about lock_timeout (1 s; the whole apply took $t0 ms)"
    else fail "$P it gave up after $t0 ms, not about lock_timeout (1 s)"; fi
    end_sleepers; wait "$b" >/dev/null 2>&1 || true
    dropdb_now "${PFX}_x$1"
}
ex_advisory() {
    local b
    newdb "${PFX}_x$1" "${PFX}_gb"
    LAST_OUT="$(migrate "$V090")" || { fail "$P (setup) v0.90 did not apply"; return; }
    start_bg psql "$DB" --no-psqlrc -qtAX -c "select pg_advisory_lock($LOCK_KEY)" -c "select pg_sleep(60)"
    b=$BGPID
    wait_for "$(sleeping 'select pg_sleep(60)')"
    refuses "$P a re-run while a v0.90 worker run holds the worker's lock: it waits, gives up at lock_timeout, nothing changed" \
            "held the worker's advisory lock"
    end_sleepers; wait "$b" >/dev/null 2>&1 || true
    dropdb_now "${PFX}_x$1"
}
ex_late_first() {
    local m w r r2 rc=0
    newdb "${PFX}_x$1" "${PFX}_gb"
    r="$(q5r)"   # step 4's R
    held_copy "$MIG" "$WORK/held.$1.sql" "select pg_sleep(1.5);"
    start_bg psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.$1.sql"; m=$BGPID
    wait_for "$(sleeping 'select pg_sleep(1.5)')"
    start_bg psql "$DB" --no-psqlrc -qtAX -c "select public.process_app_push_jobs()"; w=$BGPID
    if poll "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query = 'select public.process_app_push_jobs()' and wait_event_type = 'Lock')" 30; then
        pass "$P late starter (first apply): a worker call that starts during the apply waits on the queue lock"
    else
        fail "$P late starter (first apply): a worker call that starts during the apply waits on the queue lock (it did not wait)"
    fi
    wait "$m" || rc=$?
    same "$P late starter (first apply): the apply commits regardless" "$rc / $(worker_md5)" "0 / $RAW90"
    # step 7: drain after the commit (no waiting on the caller's process: only Q4 and Q6)
    if poll_out "select (select running = 0 and queue_lock_holders = 0 from ($(hq Q4 | sed 's/;$//')) q4) and (select worker_lock = 0 and apply_sessions = 0 from ($(hq Q6 | sed 's/;$//')) q6)" "t" 150; then
        pass "$P late starter (first apply), against the precondition: step 7's drain (Q4, Q6) waits until the late call has finished"
    else
        fail "$P late starter (first apply): step 7's drain never reached Q4 = 0 and Q6 = 0"
    fi
    same "$P late starter (first apply): it ran the body it started with (v0.32) and abandoned row c's request without finalizing it: step 8's Q5 = 1" \
         "$(q5) / $(q -c "select attempt_count || ' ' || coalesce(pg_net_request_id::text, 'noreq') || ' ' || (processed_at is null) from public.app_push_jobs where request_id = md5('bf-c')::uuid")" "1 / 3 noreq true"
    if [[ "$(q5r)" != "$r" && "$(q5r | cut -d'|' -f1)" == "$(( ${r%%|*} + 1 ))" ]]; then
        pass "$P late starter (first apply): Q5r now also takes the new stuck job's request, so it no longer equals R (step 8c: do not compare it)"
    else fail "$P late starter (first apply): Q5r was expected to differ from R by one request: got '$(q5r)', R '$r'"; fi
    same "$P late starter (first apply): step 8b, before any repair: Q8r (the backfilled cohort only) = R: the backfill changed no approval request" "$(q8r)" "$r"
    q -c "$(hq BF)" >/dev/null
    same "$P late starter (first apply): step 8c's repair, BF, finalizes it (Q5 = 0)" "$(q5)" "0"
    r2="$(q8r)"
    same "$P late starter (first apply): step 8c's new baseline R' (Q8r after BF) counts that job's request too" "${r2%%|*}" "$(( ${r%%|*} + 1 ))"
    same "$P late starter (first apply): with nothing stuck, Q5r and Q8r take the same requests: Q5r = R'" "$(q5r)" "$r2"
    wait "$w" >/dev/null 2>&1 || true
    dropdb_now "${PFX}_x$1"
}
ex_late_rerun() {
    local m w before i rc=0
    newdb "${PFX}_x$1" "${PFX}_gb"
    LAST_OUT="$(migrate "$V090")" || { fail "$P (setup) v0.90 did not apply"; return; }
    held_copy "$MIG" "$WORK/held.$1.sql" "select pg_sleep(1.5);"
    start_bg psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.$1.sql"; m=$BGPID
    wait_for "$(sleeping 'select pg_sleep(1.5)')"
    before="$(q -c "select b1bt.snapshot()")"
    start_bg psql "$DB" --no-psqlrc -qtAX -c "select public.process_app_push_jobs()"; w=$BGPID
    for i in $(seq 1 30); do kill -0 "$w" 2>/dev/null || break; sleep 0.1; done
    if ! kill -0 "$w" 2>/dev/null && poll "$(sleeping 'select pg_sleep(1.5)')" 1; then
        pass "$P late starter (re-run): a v0.90 worker call during the apply returns at once (the apply holds the worker's lock)"
    else
        fail "$P late starter (re-run): the v0.90 worker call did not return while the apply held the lock"
    fi
    same "$P late starter (re-run): and touched nothing" "$(q -c "select b1bt.snapshot()")" "$before"
    wait "$m" || rc=$?
    same "$P late starter (re-run): the re-run then commits" "$rc / $(worker_md5)" "0 / $RAW90"
    dropdb_now "${PFX}_x$1"
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
P="[access]"
ex_idle idle; ex_reader reader; ex_writer writer; ex_advisory advisory; ex_late_first late1; ex_late_rerun late2
ex_idle_unrelated unrelated

# =============================================================================
echo "== 6c. recovery (APPLY step 6) and restoring the recorded value"
P="[recovery]"
# 6b: a reported error after the replace and the backfill
newdb "${PFX}_y1" "${PFX}_gb"
n="$(q5)"
held_copy "$V090" "$WORK/fail.sql" "select 1/0;"
MIG="$WORK/fail.sql"
refuses "$P (6b) an error after the replace and the backfill (injected just before commit): reported, all rolled back, nothing changed" 'division by zero'
MIG="$V090"
same "$P (6b) Q0 as in step 0 and Q5 = N: the old body, no comment, the stuck rows still stuck" "$(q0) / $(q5)" \
     "$PROD_WORKER_MD5|1|t|t|t|$ACL_UP| / $n"
restore_job true
same "$P ABORT: R9 puts back the recorded value (true)" "$(q3)" "1|1|1|true|$JOB_MD5"
dropdb_now "${PFX}_y1"
# 6c: no clear answer, and the apply had in fact committed (sent as one query string, as apply_migration does)
newdb "${PFX}_y2" "${PFX}_gb"
held_copy "$V090" "$WORK/held.y2.sql" "select pg_sleep(1.5);"
start_bg psql "$DB" --no-psqlrc -qtAX -c "$(cat "$WORK/held.y2.sql")"; c=$BGPID
wait_for "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and wait_event = 'PgSleep')"
same "$P (6c) meanwhile another session still sees the old body: an old body_md5 proves nothing" "$(q0 | cut -d'|' -f1)" "$PROD_WORKER_MD5"
same "$P (6c) Q6 sees the apply (sent as one string): the worker's lock, and its session's application_name" "$(q -c "$(hq Q6)")" "1|1"
kill -TERM "$c" 2>/dev/null; wait "$c" >/dev/null 2>&1 || true
if poll_out "$(hq Q6)" "0|0" 150; then pass "$P (6c) the client gone, the server finishes; Q6 reaches 0|0"; else fail "$P (6c) Q6 never reached 0|0"; fi
same "$P (6c) then Q0 and Q5 show it committed" "$(q0) / $(q5)" "$RAW90|1|t|t|t|$ACL_UP|$COMMENT_MD5 / 0"
restore_job true
same "$P (6c) and R9 restores the recorded value (true)" "$(q3)" "1|1|1|true|$JOB_MD5"
dropdb_now "${PFX}_y2"
# 6c: no clear answer, and the apply had rolled back (psql -f, statement by
# statement, client killed before the commit); the recorded value was false
newdb "${PFX}_y3" "${PFX}_upbase"; backfill_rows
q -c "update cron.job set active = false where jobid = 5" >/dev/null
same "$P (1) the job was already paused by the owner: the recorded value is false" "$(q3)" "1|1|1|false|$JOB_MD5"
pause_job
same "$P (2, 3) P2 changes nothing; Q4 quiet" "$(q3) / $(q -c "$(hq Q4)")" "1|1|1|false|$JOB_MD5 / 0|0|0|0"
n="$(q5)"
held_copy "$V090" "$WORK/held.y3.sql" "select pg_sleep(1.5);"
start_bg psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.y3.sql"; c=$BGPID
wait_for "$(sleeping 'select pg_sleep(1.5)')"
same "$P (6c) Q6 sees the apply (statement by statement, now in its sleep): the worker's lock, and its application_name" "$(q -c "$(hq Q6)")" "1|1"
kill -TERM "$c" 2>/dev/null; wait "$c" >/dev/null 2>&1 || true
if poll_out "$(hq Q6)" "0|0" 150; then pass "$P (6c) the session ends; Q6 reaches 0|0"; else fail "$P (6c) Q6 never reached 0|0"; fi
same "$P (6c) then Q0 and Q5 show it rolled back: old body, no comment, Q5 = N" "$(q0) / $(q5)" "$PROD_WORKER_MD5|1|t|t|t|$ACL_UP| / $n"
restore_job false
same "$P ABORT: R9 puts back the recorded value, false: the job stays paused" "$(q3)" "1|1|1|false|$JOB_MD5"
dropdb_now "${PFX}_y3"

# =============================================================================
echo "== 6d. the time budget (A0) and the queue's writers during the apply"
SVN="$(psql "$DATABASE_URL" -qtAX -c 'show server_version_num')"
if (( SVN >= 170000 )); then BUDGET_RE='terminating connection due to transaction timeout'; else BUDGET_RE='canceling statement due to statement timeout'; fi
P="[budget]"
run_bg_to() { # run_bg_to <output file> <command...>
    local o="$1"; shift
    "$@" > "$o" 2>&1 &
    BGPID=$!; BGPIDS+=("$BGPID"); echo "$BGPID" >> "$WORK/bgpids"
}
# helper_request <tag> <statement_timeout>: one approval request, created as
# the helpers create it (remote_helper_create_permission_request with the
# anon key: role anon); prints psql's output, returns its status
helper_request() {
    psql "$DB" --no-psqlrc -qtAX -v ON_ERROR_STOP=1 \
        -c "set statement_timeout = '$2'" \
        -c "set role anon" \
        -c "select public.remote_helper_create_permission_request('$DEV', 'test-helper-secret', md5('$1')::uuid, null, 'claude', 'Bash', 's', '{}'::jsonb, 'medium', 300)" 2>&1
}
requesting() { # requesting: a helper call waits on a lock
    echo "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query like 'select public.remote_helper_create_permission_request(%' and wait_event_type = 'Lock')"
}
# delete_account <user> <statement_timeout>: delete_user_account, as the apps
# call it (the signed-in user, authenticated)
delete_account() {
    psql "$DB" --no-psqlrc -qtAX -v ON_ERROR_STOP=1 \
        -c "set statement_timeout = '$2'" \
        -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false)" \
        -c "set role authenticated" \
        -c "select public.delete_user_account()" 2>&1
}
deleting() { echo "exists (select 1 from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query = 'select public.delete_user_account()' and wait_event_type = 'Lock')"; }
landed() { # landed <tag>: the request, its jobs, and the trigger's calls for it
    q -c "select (select count(*) from public.remote_permission_requests where id = md5('$1')::uuid) || ' / '
              || (select count(*) filter (where processed_at is null) || ' pending of ' || count(*) from public.app_push_jobs where request_id = md5('$1')::uuid) || ' / '
              || (select count(*) from net.v090_calls where body->>'request_id' = md5('$1')::uuid::text
                                                         and headers->>'X-Internal-Trigger' = 'remote_request_after_insert_push')"
}
user_rows() { q -c "select (select count(*) from public.profiles where id = '$1') || ' ' || (select count(*) from public.app_push_jobs where user_id = '$1')"; }

# while the apply holds the queue lock: a helper call (anon, statement_timeout 3s,
# as production's anon) and an account deletion (authenticated, 8s) both wait, then complete
newdb "${PFX}_z1" "${PFX}_gb"
approval ud1 "$UD"
same "$P (setup) the account to delete has a job" "$(user_rows "$UD")" "1 1"
held_copy "$V090" "$WORK/held.z1.sql" "select pg_sleep(1.5);"
run_bg_to "$WORK/z1.mig" psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.z1.sql"; m=$BGPID
wait_for "$(sleeping 'select pg_sleep(1.5)')"
run_bg_to "$WORK/z1.req" helper_request hr3 3s; u=$BGPID
run_bg_to "$WORK/z1.del" delete_account "$UD" 8s; w=$BGPID
if poll "$(requesting)" 10; then pass "$P a helper's remote_helper_create_permission_request (anon, statement_timeout 3s) during the apply waits on the queue lock"
else fail "$P the helper call did not wait on the queue lock"; fi
if poll "$(deleting)" 10; then pass "$P so does delete_user_account (authenticated, statement_timeout 8s)"
else fail "$P the account deletion did not wait on the queue lock"; fi
rc=0; wait "$m" || rc=$?
same "$P the apply commits" "$rc / $(worker_md5)" "0 / $RAW90"
rc=0; wait "$u" || rc=$?
same "$P then the helper call succeeds: its approval request lands, its job is enqueued, request 1 sent" "$rc / $(landed hr3)" "0 / 1 / 1 pending of 1 / 1"
rc=0; wait "$w" || rc=$?
same "$P and the account deletion completes, its jobs gone" "$rc / $(user_rows "$UD")" "0 / 0 0"
dropdb_now "${PFX}_z1"

# a helper call whose own statement_timeout runs out first: it fails and rolls
# back entirely; sent again, it lands
newdb "${PFX}_z2" "${PFX}_gb"
held_copy "$V090" "$WORK/held.z2.sql" "select pg_sleep(1.5);"
run_bg_to "$WORK/z2.mig" psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.z2.sql"; m=$BGPID
wait_for "$(sleeping 'select pg_sleep(1.5)')"
out="$(helper_request hrshort 500ms)" && rc=0 || rc=$?
if (( rc != 0 )) && grep -q 'canceling statement due to statement timeout' <<<"$out"; then
    pass "$P a helper call whose own statement_timeout (500ms here) runs out while it waits fails with a statement timeout"
else fail "$P the short-timeout helper call: rc $rc, $(head -1 <<<"$out")"; fi
rc=0; wait "$m" || rc=$?
same "$P the apply commits" "$rc / $(worker_md5)" "0 / $RAW90"
same "$P the failed call left nothing: no approval request, no job, nothing sent" "$(landed hrshort)" "0 / 0 pending of 0 / 0"
out="$(helper_request hrshort 3s)" && rc=0 || rc=$?
same "$P sent again, it lands, its job enqueued and request 1 sent" "$rc / $(landed hrshort)" "0 / 1 / 1 pending of 1 / 1"
dropdb_now "${PFX}_z2"

# an apply made to run past the 2 s budget: it is stopped with nothing changed,
# and a helper call (anon, 3s) that started waiting at once goes on (its
# timeout counts its own work too, so one already well into it could not)
budget_overrun() { # budget_overrun <tag> <migration> <regex of the abort> <label>
    local m w rc t0 before n
    newdb "${PFX}_z$1" "${PFX}_gb"
    before="$(q0)"; n="$(q5)"
    held_copy "$2" "$WORK/held.z$1.sql" "select pg_sleep(3);"
    t0=$(now_ms)
    run_bg_to "$WORK/z$1.mig" psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX -f "$WORK/held.z$1.sql"; m=$BGPID
    wait_for "$(sleeping 'select pg_sleep(3)')"
    run_bg_to "$WORK/z$1.req" helper_request "hr$1" 3s; w=$BGPID
    rc=0; wait "$m" || rc=$?
    t0=$(( $(now_ms) - t0 ))
    if (( rc != 0 )) && grep -q -E -- "$3" "$WORK/z$1.mig" && (( t0 < 2900 )); then
        pass "$P $4: the apply runs past 2 s and is stopped after $t0 ms: /$3/"
    else fail "$P $4: rc $rc after $t0 ms, not /$3/ within 2.9 s: $(grep -m1 -E 'ERROR|FATAL' "$WORK/z$1.mig")"; fi
    same "$P $4: nothing changed (Q0 and Q5 as before)" "$(q0) / $(q5)" "$before / $n"
    rc=0; wait "$w" || rc=$?
    same "$P $4: the helper call (anon, 3s) that waited goes on, its job enqueued and request 1 sent" \
         "$rc / $(landed "hr$1")" "0 / 1 / 1 pending of 1 / 1"
    dropdb_now "${PFX}_z$1"
}
if (( SVN >= 170000 )); then
    budget_overrun 3 "$V090" "$BUDGET_RE" "PostgreSQL $((SVN / 10000)), transaction_timeout 2s"
    mutate "$V090" "$WORK/v090.fallback.sql" 1 "current_setting\\('server_version_num'\\)::int >= 170000" "current_setting('server_version_num')::int >= 990000"
    budget_overrun 4 "$WORK/v090.fallback.sql" 'canceling statement due to statement timeout' "the pre-17 branch, forced (statement_timeout 2s per statement)"
else
    budget_overrun 3 "$V090" "$BUDGET_RE" "PostgreSQL $((SVN / 10000)) (before 17), statement_timeout 2s per statement"
fi

# how long the apply holds the queue lock with a full queue: the size guard's
# limit in stuck jobs plus thousands of finalized ones (test environment)
newdb "${PFX}_z5" "${PFX}_upbase"
q >/dev/null <<SQL
insert into public.remote_permission_requests (id, user_id, device_id, provider, status, notification_attempts)
select md5('full-' || i)::uuid, '$UA', '$DEV', 'claude', 'expired', 4 from generate_series(1, 8000) i;
insert into public.app_push_jobs (user_id, request_id, attempt_count, last_error)
select '$UA', md5('full-' || i)::uuid, 4, 'edge HTTP 502' from generate_series(1, 5000) i;
insert into public.app_push_jobs (user_id, request_id, enqueued_at, processed_at, attempt_count, pg_net_request_id, dispatched_at)
select '$UA', md5('full-' || i)::uuid, now() - interval '2 days', now() - interval '2 days', 1, i, now() - interval '2 days' from generate_series(5001, 8000) i;
analyze public.app_push_jobs;
SQL
pause_job
applies "$P the apply with 5000 stuck and 3000 finalized jobs"
ms="$(lock_ms "$LAST_OUT")"
same "$P it backfilled the 5000" "$(notice "$LAST_OUT" | cut -d'|' -f2)" "backfilled 5000 stuck job(s): finalized with failure, nothing re-sent"
if [[ -n "$ms" ]] && (( ms < 2000 )); then pass "$P MEASURED (test environment): the queue lock was held $ms ms, inside the 2 s budget"
else fail "$P the queue lock hold time: '$ms' ms"; fi
dropdb_now "${PFX}_z5"

# =============================================================================
echo "== 7. negative controls (each mutant must fail its named assertion)"
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
mutate "$W" "$MUT.1.sql" 1 'processed_at\s+= case when v_expired and attempt_count >= 3 then now\(\) else processed_at end' 'processed_at = processed_at'
control "1. no-answer branch never finalizes" "${PFX}_up" "$MUT.1.sql" "" case_noresp \
        'no answer: after the third request has had no answer for 5 minutes, the job is finalized'
mutate "$W" "$MUT.2.sql" 1 'processed_at\s+= case when v_expired and attempt_count >= 3' 'processed_at = case when attempt_count >= 3'
control "2. no-answer branch finalizes without the 5-minute test" "${PFX}_up" "$MUT.2.sql" "" case_noresp \
        'no answer: under 5 minutes the third request is live: not finalized'
mutate "$W" "$MUT.3.sql" 1 'send the retry\n\s*pg_net_request_id = null,\n\s*dispatched_at\s+= null\K,\n\s*processed_at\s+= case when attempt_count \+ 1 >= 3 then now\(\) else processed_at end' ''
control "3. non-2xx branch never finalizes" "${PFX}_up" "$MUT.3.sql" "" case_502 \
        '502: the second 502 finalizes the job'
mutate "$W" "$MUT.4.sql" 1 'send the retry\n\s*pg_net_request_id = null,\n\s*dispatched_at\s+= null,\n\s*processed_at\s+= case when attempt_count \+ 1 >= \K3' '2'
control "4. non-2xx branch finalizes at 2" "${PFX}_up" "$MUT.4.sql" "" case_502 \
        '502: the first 502 is counted and the retry sent in the same call, not finalized'
mutate "$W" "$MUT.4b.sql" 1 'send the retry\n\s*pg_net_request_id = null,\n\s*dispatched_at\s+= null,\n\s*processed_at\s+= case when attempt_count \+ 1 >= \K3' '4'
control "4b. non-2xx branch finalizes at 4" "${PFX}_up" "$MUT.4b.sql" "" case_502 \
        '502 at attempt 3: a failed answer that reaches attempt 3 finalizes the job'
mutate "$W" "$MUT.5.sql" 1 'dispatched_at\s+= now\(\),\n\s*attempt_count\s+= attempt_count \+ 1,\K' $'\n            processed_at = case when attempt_count + 1 >= 3 then now() else processed_at end,'
control "5a. finalized right after the third dispatch (502 path)" "${PFX}_up" "$MUT.5.sql" "" case_502 \
        '502: the first 502 is counted and the retry sent in the same call, not finalized'
control "5b. finalized right after the third dispatch (no-answer path)" "${PFX}_up" "$MUT.5.sql" "" case_noresp \
        'no answer: the third request goes out and the job stays pending while it is live'
mutate "$W" "$MUT.6.sql" 1 "'http_post failed: ' \\|\\| sqlerrm,\\n\\s*processed_at\\s+= case when attempt_count \\+ 1 >= \\K3" '4'
control "6. raise branch finalizes at 4" "${PFX}_up" "$MUT.6.sql" "" case_raise \
        'raise: a 502 and then a raising retry use the third attempt: finalized'
mutate "$W" "$MUT.7.sql" 1 'if v_status is null and \(coalesce\(v_timed_out, false\) or v_error is not null\) then' 'if false then'
control "7a. a transport failure read as no answer (timed out)" "${PFX}_up" "$MUT.7.sql" "" "case_transport_timeout" \
        'transport \(timeout\): the failure counts at once'
control "7b. a transport failure read as no answer (error)" "${PFX}_up" "$MUT.7.sql" "" "case_transport_error" \
        'transport \(error\): the failure counts at once'
mutate "$W" "$MUT.7c.sql" 1 "last_error\\s+= 'edge transport: ' \\|\\| left\\(coalesce\\(v_error, 'timed out'\\), 200\\),\\n\\s*pg_net_request_id = null,\\n\\s*dispatched_at\\s+= null\\K,\\n\\s*processed_at\\s+= case when attempt_count \\+ 1 >= 3 then now\\(\\) else processed_at end" ''
control "7c. the transport branch never finalizes (its processed_at clause removed)" "${PFX}_up" "$MUT.7c.sql" "" "case_transport_timeout" \
        'transport \(timeout\): the second failure finalizes the job'
mutate "$W" "$MUT.7d.sql" 1 "last_error\\s+= 'edge transport: ' \\|\\| left\\(coalesce\\(v_error, 'timed out'\\), 200\\),\\n\\s*pg_net_request_id = null,\\n\\s*dispatched_at\\s+= null,\\n\\s*processed_at\\s+= case when attempt_count \\+ 1 >= \\K3" '4'
control "7d. the transport branch finalizes at 4" "${PFX}_up" "$MUT.7d.sql" "" "case_transport_timeout" \
        'transport \(timeout\): a failure that reaches attempt 3 finalizes the job'
mutate "$W" "$MUT.8a.sql" 2 'coalesce\(dispatched_at, enqueued_at\)' 'dispatched_at'
mutate "$MUT.8a.sql" "$MUT.8.sql" 1 'coalesce\(v_job\.dispatched_at, v_job\.enqueued_at\)' 'v_job.dispatched_at'
control "8a. age without coalesce(dispatched_at, enqueued_at)" "${PFX}_up" "$MUT.8.sql" "" case_malformed \
        'malformed: a request id without dispatched_at, answered 200, is reconciled and finalized'
mutate "$W" "$MUT.9.sql" 1 "  if not pg_try_advisory_xact_lock\\(hashtextextended\\('process_app_push_jobs', 0\\)\\) then\\n    return;\\n  end if;\\n" ''
control "8b. no advisory lock" "${PFX}_up" "$MUT.9.sql" "" case_serialization \
        'one call at a time: while another session holds the lock, a call reconciles nothing'
mutate "$W" "$MUT.10.sql" 1 "        update public\\.remote_permission_requests\\n          set notification_attempts   = notification_attempts \\+ 1,\\n              notification_last_error = 'edge transport: '[^\\n]*\\n          where id = v_job\\.request_id;\\n" ''
control "10a. a transport failure not recorded on the approval request" "${PFX}_up" "$MUT.10.sql" "" "case_transport_timeout" \
        'transport \(timeout\): the request row counts the failure, with the transport error'
mutate "$W" "$MUT.11.sql" 1 "        update public\\.remote_permission_requests\\n          set notification_attempts   = notification_attempts \\+ 1,\\n              notification_last_error = 'edge HTTP '[^\\n]*\\n          where id = v_job\\.request_id;\\n" ''
control "10b. a failed answer no longer recorded on the approval request (v0.32's side effect)" "${PFX}_up" "$MUT.11.sql" "" case_502 \
        '502: the request row counts the failed answer and the retry, with the error'
B="$WORK/backfill.sql"
mutate "$B" "$MUT.b1.sql" 1 '\n\s*and pg_net_request_id is null' ''
cat "$W" "$MUT.b1.sql" > "$MUT.b1.full.sql"
control "9a. backfill without 'pg_net_request_id is null'" "${PFX}_upbase" "$MUT.b1.full.sql" "backfill_rows" backfill_checks \
        'backfill: row b is untouched'
mutate "$B" "$MUT.b2.sql" 1 '\n\s*and attempt_count >= 3' ''
cat "$W" "$MUT.b2.sql" > "$MUT.b2.full.sql"
control "9b. backfill without 'attempt_count >= 3'" "${PFX}_upbase" "$MUT.b2.full.sql" "backfill_rows" backfill_checks \
        'backfill: row d is untouched'
mutate "$B" "$MUT.b3.sql" 1 "    get diagnostics v_n = row_count;\\n" $'    get diagnostics v_n = row_count;\n    update public.remote_permission_requests set notification_last_error = \'v0.90 backfill\' where id in (select request_id from public.app_push_jobs where last_error like \'v0.90 backfill: %\');\n'
cat "$W" "$MUT.b3.sql" > "$MUT.b3.full.sql"
control "9c. a backfill that also writes the approval requests" "${PFX}_upbase" "$MUT.b3.full.sql" "backfill_rows" backfill_checks \
        'backfill: no approval request changed'
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
mutate "$V090" "$MUT.g1.sql" 1 '(?s)    -- b\. an idle open transaction that touched the queue.*?    end if;\n' ''
gcontrol "G1. the migration without the idle-transaction check (A5b)" "$MUT.g1.sql" ex_idle \
         'an idle transaction that already ran the worker: refused'
mutate "$V090" "$MUT.g2.sql" 1 '(?s)    -- e\. the authority.*?    end if;\n' ''
gcontrol "G2. the migration without the pg_locks check (A5e)" "$MUT.g2.sql" ex_reader \
         'an open transaction that read the queue'
mutate "$V090" "$MUT.g3.sql" 1 '(?s)    -- d\. writers of the queue.*?    end;\n' ''
gcontrol "G3. the migration without LOCK TABLE (A5d)" "$MUT.g3.sql" ex_late_first \
         'late starter \(first apply\): a worker call that starts during the apply waits on the queue lock'
mutate "$V090" "$MUT.g4.sql" 1 "(?s)    -- c\\. the worker's own lock.*?    end;\\n" ''
gcontrol "G4. the migration without the worker's advisory lock (A5c)" "$MUT.g4.sql" ex_advisory \
         "a re-run while a v0.90 worker run holds the worker's lock"
printf -v unscoped '%s\n%s\n' "    select count(*) into v_n from pg_stat_activity a" \
    "     where a.pid <> pg_backend_pid() and a.datname = current_database() and a.state like 'idle in transaction%';"
mutate "$V090" "$MUT.g5.sql" 1 "(?s)    -- b\\. an idle open transaction that touched the queue.*?l\\.relation = 'public\\.app_push_jobs'::regclass;\\n" "$unscoped"
gcontrol "G5. the idle check unscoped again (any idle transaction refuses)" "$MUT.g5.sql" ex_idle_unrelated \
         'an idle transaction that never touched the queue does not stop the apply'
mutate "$V090" "$MUT.g6.sql" 1 '(?s)    -- and in effect: no grant reaches anon or authenticated.*?    end loop;\n' ''
gcontrol "G6. the migration without the effective EXECUTE check (A3)" "$MUT.g6.sql" ex_inherited \
         'EXECUTE reaching anon through an inherited role \(no direct grant\): refused'
# and the unmutated cut passes the same checks (the controls fail for the mutation, not the harness)
cat "$W" "$B" > "$WORK/unmutated.full.sql"
newdb "${PFX}_m0" "${PFX}_upbase"; backfill_rows; apply "$WORK/unmutated.full.sql"
out="$( (P="[cut]"; fails=0; backfill_checks; case_noresp; case_502; case_raise; case_malformed; case_transport_timeout; case_serialization; exit $fails) 2>&1 )" \
    && pass "control harness: the unmutated cut passes every check the mutants fail" \
    || { fail "control harness: the unmutated cut fails"; grep FAIL <<<"$out" | head -5 >&2; }
dropdb_now "${PFX}_m0"

echo
if (( fails > 0 )); then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all checks passed"

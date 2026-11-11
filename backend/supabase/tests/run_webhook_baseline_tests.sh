#!/usr/bin/env bash
# The webhook queue in the fresh-install baseline (B0).
#
# schema.sql / app_rpc.sql carry a copy of production's webhook queue: the
# webhook_jobs table, its two partial indexes, RLS and policy, the
# alerts_enqueue_webhook() trigger function and trigger (all schema.sql), and
# process_webhook_jobs() with its revoke (app_rpc.sql). Production got them from
# migrate_v0.25 (+ v0.55's policy form, + v0.62's revoke). Before B0 a fresh
# install had none of it, so alert fixtures did not enqueue and a later DELETE
# on the queue would have failed there.
#
# What this proves, on a real Postgres:
#   A. HISTORICAL PIN. B0's webhook blocks are frozen as files
#      (tests/fixtures/webhook_baseline_b0/, never edited). Applied to a
#      baseline with the webhook objects removed, they give the same catalog
#      fingerprint (ops/check_webhook_catalog.sql, run as it stands) as the
#      objects rebuilt by cutting v0.25, v0.55's ALTER POLICY and v0.62 out of
#      the migrations. This proves B0's transcription for good, whatever later
#      migrations do to the live files. (A frozen copy, not a git SHA: a branch
#      commit is not in main's history after a squash merge, so `git show` of
#      it would break; a committed file cannot.)
#   B. CURRENT FILES. The same comparison with today's baseline files against
#      the objects rebuilt through WEBHOOK_MIGRATIONS (below), so a later
#      webhook migration that is not mirrored in the baseline fails here. A
#      guard fails if the RAW text of any migrate_v*.sql (comments and strings
#      included, no lexing, so nothing can hide a mention) names a queue object
#      and the file is neither one of the migrations the baseline is built from
#      (WEBHOOK_MIGRATIONS) nor on the reviewed allowlist below (exact file name
#      and a reason). A false positive costs one allowlist line.
#   C. BEHAVIOUR on the fresh baseline: a non-Test alert enqueues one pending
#      job, a Test alert none, the same grouping_key again still one; as
#      `authenticated` the queue is not readable (0 rows: filtering), not
#      writable (denied by RLS) and the worker cannot be executed (42501), nor
#      by anon; with production's default privileges modelled (service_role may
#      execute the worker, every role holds the table grants, RLS is the gate)
#      anon and authenticated stay denied, and service_role's one worker call,
#      against an empty vault stub, returns without touching a job; deleting an
#      account deletes its jobs.
#   D. NEGATIVE CONTROLS: the suite is run against deliberately broken copies
#      of the baseline files and must fail, naming the check that caught it.
#
# Equality of fingerprints proves the repo is self-consistent. That production
# equals the repo is proved only by running ops/check_webhook_catalog.sql there
# and diffing it against this suite's output (set B0_PRINT_CATALOG=<file>).
#
# pg_net, pg_cron and vault are not in plain Postgres. Each database gets an
# INACTIVE stand-in cron.job row named process_webhook_jobs so the catalog
# file's cron section is exercised. The worker is run once, by service_role,
# against an EMPTY vault stub, so it returns at its secrets check with no
# network activity (pg_net is absent).
#
# Usage (creates and drops its own b0_* databases on that server):
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres \
#     ./backend/supabase/tests/run_webhook_baseline_tests.sh
# Database names are b0_<pid>_*, so concurrent runs do not collide.
# Optional: B0_SQL_DIR (use another copy of backend/supabase for the CURRENT
# files; the negative controls use it), B0_PRINT_CATALOG=<path>.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SQL_DIR="$(cd "$HERE/.." && pwd)"
SQL_DIR="${B0_SQL_DIR:-$REAL_SQL_DIR}"
FROZEN="$HERE/fixtures/webhook_baseline_b0"
SHIM="$HERE/rls/00_supabase_shim.sql"
OPS="$SQL_DIR/ops/check_webhook_catalog.sql"
V025="$SQL_DIR/migrate_v0.25_sessions_alerts_hardening.sql"
V055="$SQL_DIR/migrate_v0.55_rls_initplan_and_fk_indexes.sql"
V062="$SQL_DIR/migrate_v0.62_revoke_process_webhook_jobs.sql"
V087="$SQL_DIR/migrate_v0.87_retention_cleanup_and_fresh_counts.sql"

# The migrations that (re)build the webhook objects, in order. Kinds:
#   cut25      v0.25 from its queue-table comment to the end of the worker
#              (its pg_cron block is environment and is not run)
#   policy55   v0.55's ALTER POLICY on webhook_jobs
#   cleanup87  v0.87's _cleanup_expired_data_internal() (put it before a
#              migration that replaces that function)
#   whole      the file, as it is
# A later webhook migration (v0.89, v0.91) is added here by the PR that adds it.
WEBHOOK_MIGRATIONS=(
    "cut25:migrate_v0.25_sessions_alerts_hardening.sql"
    "policy55:migrate_v0.55_rls_initplan_and_fk_indexes.sql"
    "whole:migrate_v0.62_revoke_process_webhook_jobs.sql"
)
# The raw-text guard (part B) fails on any migration that mentions a queue
# object name anywhere, comments included, unless it is in WEBHOOK_MIGRATIONS or
# listed here. Each entry is "<exact file name>|<why it is not a queue change>".
# Reviewed entries only; a new migration that merely mentions the queue (B1b's
# comparison with the app-push queue, say) adds its own line.
QUEUE_NAMES='webhook_jobs|process_webhook_jobs|alerts_enqueue_webhook|alerts_webhook_enqueue'
WEBHOOK_ALLOWLIST=(
    "migrate_v0.32_remote_approvals_push.sql|comments only: app_push_jobs 'mirrors the webhook_jobs pattern'; changes no webhook object"
    "migrate_v0.49_swarm_alerts.sql|comments only: describes the alert path through the queue; changes no webhook object"
    "migrate_v0.78_unschedule_swarm_alert_eval.sql|lists 'process_webhook_jobs' as a cron job name to leave alone; changes no queue object"
    "migrate_v0.87_retention_cleanup_and_fresh_counts.sql|comment only: a fixture alert 'queues a webhook' through alerts_enqueue_webhook; changes no queue object"
    "migrate_v0.88_schedule_prune_anonymous_installs.sql|checks that the process_webhook_jobs cron job is untouched; changes no queue object"
)

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to a database on a disposable server" >&2
    exit 2
fi
for f in "$FROZEN/schema_block.sql" "$FROZEN/app_rpc_block.sql" "$SHIM" "$OPS" "$V025" "$V055" "$V062" "$V087" \
         "$SQL_DIR/schema.sql" "$SQL_DIR/app_rpc.sql" "$SQL_DIR/helper_rpc.sql"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done

BASE="${DATABASE_URL%/*}"
PFX="b0_$$"
WORK="$(mktemp -d)"
CREATED=()
cleanup() { # best-effort: every step runs, failures only warn, the exit status is the script's own
    set +e
    local d
    for d in "${CREATED[@]:-}"; do
        [[ -n "$d" ]] || continue
        PGOPTIONS='-c client_min_messages=warning' psql "$DATABASE_URL" -qtAX -c "drop database if exists $d" >/dev/null 2>&1 \
            || echo "warning: could not drop database $d (drop it by hand)" >&2
    done
    /bin/rm -rf "$WORK" || echo "warning: could not remove $WORK" >&2
}
trap cleanup EXIT

export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
fails=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }
same() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi; }

DB=""
newdb() { # newdb <name>: sets DB to its URL (no subshell, so CREATED survives)
    psql "$DATABASE_URL" -qtAX -v ON_ERROR_STOP=1 \
        -c "drop database if exists $1" -c "create database $1" >/dev/null \
        || { echo "cannot create database $1" >&2; exit 2; }
    CREATED+=("$1")
    DB="$BASE/$1"
}
q() { psql "$DB" -v ON_ERROR_STOP=1 --no-psqlrc -qtAX "$@"; }
apply() { q -f "$1" >/dev/null; }
check() { # check <label> <sql returning boolean>
    local got; got="$(q -c "select ($2)::text" 2>&1)"
    if [[ "$got" == "true" ]]; then pass "$1"; else fail "$1  (got '$got')"; fi
}
fingerprint() { q -f "$OPS"; }

cron_stub() {
    q >/dev/null <<'SQL'
create schema if not exists cron;
create table if not exists cron.job (
  jobid bigserial primary key, schedule text, command text, nodename text, nodeport integer,
  database text, username text default 'postgres', active boolean not null default true, jobname text
);
insert into cron.job (jobname, schedule, command, active)
values ('process_webhook_jobs', '30 seconds', 'select public.process_webhook_jobs()', false);
SQL
}

# build_baseline <dir>: shim + the three baseline files from <dir>, in CI order.
build_baseline() {
    apply "$SHIM"; apply "$1/schema.sql"; apply "$1/app_rpc.sql"; apply "$1/helper_rpc.sql"
    cron_stub
}

# ── extraction: loud, never silent ─────────────────────────────────────────
# cut_between <file> <start regex> <end regex> <min lines> <must contain...>
# (exactly one start marker; the cut ends at the first end marker after it)
cut_between() {
    local file="$1" start="$2" end="$3" min="$4"; shift 4
    local ns ne out="$WORK/cut.$RANDOM.sql" s
    ns="$(grep -c -E "$start" "$file" || true)"; ne="$(grep -c -E "$end" "$file" || true)"
    if [[ "$ns" != 1 || "$ne" -lt 1 ]]; then
        echo "cut: $file: want exactly one start marker ($start) and an end marker ($end), found $ns and $ne" >&2; exit 2
    fi
    sed -n -E "/$start/,/$end/p" "$file" > "$out"
    if (( $(wc -l < "$out") < min )); then echo "cut: $file: fewer than $min lines" >&2; exit 2; fi
    [[ "$(tail -n 1 "$out")" =~ $end ]] \
        || { echo "cut: $file: the cut does not close on its end marker ($end)" >&2; exit 2; }
    for s in "$@"; do
        grep -q -F -- "$s" "$out" || { echo "cut: $file: missing expected text: $s" >&2; exit 2; }
    done
    echo "$out"
}

apply_cut() { local c; c="$(cut_between "$@")" || exit 2; apply "$c"; }

# Remove the webhook objects from the database in $DB, then rebuild them by the
# ordered list (files taken from <dir>).
remove_webhook_objects() {
    q >/dev/null <<'SQL'
drop trigger if exists alerts_webhook_enqueue on public.alerts;
drop function if exists public.alerts_enqueue_webhook();
drop function if exists public.process_webhook_jobs();
drop table if exists public.webhook_jobs;
SQL
}
rebuild_from_migrations() { # rebuild_from_migrations <dir>
    local entry kind file f
    for entry in "${WEBHOOK_MIGRATIONS[@]}"; do
        kind="${entry%%:*}"; file="${entry#*:}"; f="$1/$file"
        [[ -f "$f" ]] || { echo "WEBHOOK_MIGRATIONS names a missing file: $file" >&2; exit 2; }
        case "$kind" in
            cut25) apply_cut "$f" '^-- Queue table\. ' \
                    '^\$\$ language plpgsql security definer set search_path = pg_catalog, extensions, public, net;' 200 \
                    'create unique index' 'create policy' 'create trigger' \
                    '$$ language plpgsql security definer set search_path = pg_catalog, extensions, public, net;' ;;
            policy55) apply_cut "$f" '^ALTER POLICY "Service role only" ON public\.webhook_jobs' \
                    "^  WITH CHECK \\(\\(select auth\\.role\\(\\)\\) = 'service_role'::text\\);\$" 3 'USING' ;;
            cleanup87) apply_cut "$f" '^create or replace function public\._cleanup_expired_data_internal\(\)' \
                    '^\$\$ language plpgsql security definer' 20 'v_failed'
                q -c "revoke all on function public._cleanup_expired_data_internal() from public, anon, authenticated;" >/dev/null ;;
            whole) apply "$f" ;;
            *) echo "unknown kind $kind" >&2; exit 2 ;;
        esac
    done
}

# ── the forgotten-migration guard ───────────────────────────────────────────
# The forgotten-migration guard: raw text, no stripping, no lexing.
guard_forgotten_migrations() { # guard_forgotten_migrations <dir> -> echoes offenders; returns 2 on a setup error
    local f base entry e listed allowed rc
    for e in "${WEBHOOK_ALLOWLIST[@]}"; do
        [[ "${e%%|*}" == migrate_v*.sql && "$e" == *"|"?* ]] || { echo "bad allowlist entry (file|reason): $e" >&2; return 2; }
        [[ -f "$1/${e%%|*}" ]] || { echo "allowlist names a missing file: ${e%%|*}" >&2; return 2; }
    done
    for f in "$1"/migrate_v*.sql; do
        base="$(basename "$f")"
        rc=0; grep -q -E "$QUEUE_NAMES" "$f" || rc=$?
        if (( rc == 1 )); then continue; fi
        (( rc == 0 )) || { echo "cannot read $base" >&2; return 2; }
        listed=0; allowed=0
        for entry in "${WEBHOOK_MIGRATIONS[@]}"; do [[ "${entry#*:}" == "$base" ]] && listed=1; done
        for e in "${WEBHOOK_ALLOWLIST[@]}"; do [[ "${e%%|*}" == "$base" ]] && allowed=1; done
        (( listed || allowed )) || echo "$base"
    done
}

# =============================================================================
if [[ -z "${B0_CONTROL:-}" ]]; then echo "== A. historical pin (frozen B0 blocks)"; fi

# part A rebuilds from the migrations as they are NOW but only the three that
# existed at B0 (a pin must not move when WEBHOOK_MIGRATIONS grows).
SAVED_LIST=("${WEBHOOK_MIGRATIONS[@]}")
WEBHOOK_MIGRATIONS=(
    "cut25:migrate_v0.25_sessions_alerts_hardening.sql"
    "policy55:migrate_v0.55_rls_initplan_and_fk_indexes.sql"
    "whole:migrate_v0.62_revoke_process_webhook_jobs.sql"
)
newdb "${PFX}_a"; build_baseline "$SQL_DIR"; remove_webhook_objects
apply "$FROZEN/schema_block.sql"; apply "$FROZEN/app_rpc_block.sql"; FP_A="$(fingerprint)"
newdb "${PFX}_b"; build_baseline "$SQL_DIR"; remove_webhook_objects; rebuild_from_migrations "$SQL_DIR"; FP_B="$(fingerprint)"
WEBHOOK_MIGRATIONS=("${SAVED_LIST[@]}")

if [[ -n "${B0_PRINT_CATALOG:-}" ]]; then printf '%s\n' "$FP_A" > "$B0_PRINT_CATALOG"; fi

same "A. the frozen B0 blocks' fingerprint equals the one rebuilt from migrate_v0.25 + v0.55 + v0.62" "$FP_A" "$FP_B"
if [[ "$FP_A" != "$FP_B" ]]; then diff <(echo "$FP_A") <(echo "$FP_B") >&2 || true; fi
check "A. the worker's execute is revoked from PUBLIC, anon and authenticated (acl = owner only)" \
      "(select proacl::text from pg_proc where proname='process_webhook_jobs') = '{' || current_user || '=X/' || current_user || '}'"

# =============================================================================
if [[ -z "${B0_CONTROL:-}" ]]; then echo "== B. current baseline vs fully migrated"; fi
newdb "${PFX}_c"; build_baseline "$SQL_DIR"; FP_C="$(fingerprint)"
newdb "${PFX}_d"; build_baseline "$SQL_DIR"; remove_webhook_objects; rebuild_from_migrations "$SQL_DIR"; FP_D="$(fingerprint)"
# the fingerprint must really contain the objects (equal-but-empty must not pass)
for want in '^1a\|count\|process_webhook_jobs\|1$' '^1a\|count\|alerts_enqueue_webhook\|1$' \
            '^1b\|process_webhook_jobs\|.*\|secdef=true\|' '^1b\|alerts_enqueue_webhook\|' \
            '^2a\|col\|1\|id\|bigint' '^3\|con\|webhook_jobs_user_id_fkey\|f\|FOREIGN KEY \(user_id\) REFERENCES profiles\(id\) ON DELETE CASCADE' \
            '^4\|idx\|idx_webhook_jobs_pending_dedup\|' '^4\|idx\|idx_webhook_jobs_pending_enqueued\|' \
            '^5a\|rls\|rowsecurity=true\|' '^5b\|policy\|Service role only\|' \
            '^6\|trigger\|alerts_webhook_enqueue\|' '^8c\|cron\.job\|' ; do
    if grep -q -E -- "$want" <<<"$FP_C"; then :; else fail "fingerprint of the baseline lacks a line matching $want"; fi
done
same "B. the current baseline's fingerprint equals the migration-built one" "$FP_C" "$FP_D"
if [[ "$FP_C" != "$FP_D" ]]; then diff <(echo "$FP_C") <(echo "$FP_D") >&2 || true; fi
offenders="$(guard_forgotten_migrations "$SQL_DIR")" || exit 2
same "B. every migration that mentions the queue (raw text) is in WEBHOOK_MIGRATIONS or the allowlist" "$offenders" ""

# =============================================================================
if [[ -z "${B0_CONTROL:-}" ]]; then echo "== C. behaviour on the fresh baseline"; fi
DB="$BASE/${PFX}_c"
UA='b0000000-b000-4b00-8b00-00000000000a'
UB='b0000000-b000-4b00-8b00-00000000000b'
q >/dev/null <<SQL
insert into auth.users (id, email) values ('$UA', 'a@test.local'), ('$UB', 'b@test.local');
SQL

# as <role> <uuid> <sql>: like PostgREST: that role, the JWT claims, rolled back.
as_role() { # prints the statement's output; errors go to stdout as "ERROR: <sqlstate>: ..."
    local role="$1" sub="$2" sql="$3" claims
    claims="{\"sub\":\"$sub\",\"role\":\"$role\"}"
    psql "$DB" --no-psqlrc -tAX 2>&1 <<SQL | grep -v -E '^(BEGIN|SET|RESET|ROLLBACK)$' | sed -e 's/^psql:[^ ]* //' -e 's/^[A-Z]*:  *\([0-9A-Z]\{5\}\):/ERROR: \1:/'
\set VERBOSITY verbose
begin;
select set_config('request.jwt.claims', '$claims', true) \g /dev/null
set local role $role;
$sql
rollback;
SQL
}
jobs_of() { q -c "select count(*) from public.webhook_jobs where user_id = '$1'"; }

# a non-Test alert, as its owner (the trigger is SECURITY DEFINER)
# the job must be observed: reset to the superuser inside the same transaction, read it, roll back
same "C. authenticated inserts its own alert; the definer trigger queues exactly one job for it (observed, no warning)" \
     "$(as_role authenticated "$UA" "insert into public.alerts (id, user_id, type, title, grouping_key) values ('z1', '$UA', 'Usage Spike', 't', 'gz'); reset role; select count(*) from public.webhook_jobs where alert_id = 'z1' and user_id = '$UA' and processed_at is null;" | paste -sd' ' -)" "INSERT 0 1 1"
q -c "insert into public.alerts (id, user_id, type, title, grouping_key) values ('a1', '$UA', 'Usage Spike', 't', 'g1');" >/dev/null
same "C. a non-Test alert enqueues one pending job" "$(jobs_of "$UA")" "1"
q -c "insert into public.alerts (id, user_id, type, title, grouping_key) values ('a2', '$UA', 'Test', 't', 'g2');" >/dev/null
same "C. a Test alert enqueues nothing" "$(jobs_of "$UA")" "1"
q -c "insert into public.alerts (id, user_id, type, title, grouping_key) values ('a3', '$UA', 'Usage Spike', 't2', 'g1');" >/dev/null
same "C. the same grouping_key again leaves one pending job" "$(jobs_of "$UA")" "1"
q -c "insert into public.alerts (id, user_id, type, title, grouping_key) values ('b1', '$UB', 'Usage Spike', 't', 'g1');" >/dev/null
same "C. the other account's alert with the same key gets its own job" "$(jobs_of "$UB")" "1"
check "C. the job carries the alert's id and payload keys" \
      "(select alert_id = 'a1' and alert_payload ?& array['id','type','severity','title','message','grouping_key','suppression_key','created_at'] and processed_at is null and attempt_count = 0 from public.webhook_jobs where user_id = '$UA')"

# authenticated: filtering is not denial, so say both
same "C. authenticated reads 0 queue rows although 2 exist (RLS filters)" \
     "$(as_role authenticated "$UA" 'select count(*) from public.webhook_jobs;')" "0"
out="$(as_role authenticated "$UA" "insert into public.webhook_jobs (user_id, alert_id, alert_payload) values ('$UA', 'x', '{}');")"
if grep -q 'ERROR: 42501:.*row-level security' <<<"$out"; then pass "C. authenticated cannot insert into the queue (RLS violation)"; else fail "C. authenticated insert: $out"; fi
same "C. authenticated's update and delete touch no queue row" \
     "$(as_role authenticated "$UA" 'update public.webhook_jobs set attempt_count = 9; delete from public.webhook_jobs;' | paste -sd' ' -)" "UPDATE 0 DELETE 0"
check "C. the queue rows are still there" "(select count(*) from public.webhook_jobs) = 2"
for r in authenticated anon; do
    out="$(as_role "$r" "$UA" 'select public.process_webhook_jobs();')"
    if grep -q 'ERROR: 42501:.*permission denied for function process_webhook_jobs' <<<"$out"; then
        pass "C. $r cannot execute the worker (42501)"; else fail "C. $r executing the worker: $out"; fi
done
# Model production's relevant default privileges (measured there, not assumed):
# every role holds all table and sequence privileges on the queue, so RLS is the
# gate; service_role may execute the worker and the cleanup; the trigger function
# keeps PUBLIC's default EXECUTE. Plain Postgres (the shim) has none of that.
# vault is an empty stand-in, so the worker returns at its secrets check.
q >/dev/null <<'SQL'
grant all on public.webhook_jobs to anon, authenticated, service_role;
grant all on sequence public.webhook_jobs_id_seq to anon, authenticated, service_role;
grant execute on function public.process_webhook_jobs() to service_role;
grant execute on function public._cleanup_expired_data_internal() to service_role;
create schema vault;
create view vault.decrypted_secrets as select null::text as name, null::text as decrypted_secret where false;
SQL
check "C. effective EXECUTE: service_role may run the worker and the cleanup; anon and authenticated may not" \
      "has_function_privilege('service_role', 'public.process_webhook_jobs()', 'EXECUTE')
       and has_function_privilege('service_role', 'public._cleanup_expired_data_internal()', 'EXECUTE')
       and not has_function_privilege('anon', 'public.process_webhook_jobs()', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public.process_webhook_jobs()', 'EXECUTE')
       and not has_function_privilege('anon', 'public._cleanup_expired_data_internal()', 'EXECUTE')
       and not has_function_privilege('authenticated', 'public._cleanup_expired_data_internal()', 'EXECUTE')"
check "C. the trigger function keeps PUBLIC's EXECUTE (informational: it returns trigger)" \
      "has_function_privilege('anon', 'public.alerts_enqueue_webhook()', 'EXECUTE')"
same "C. anon (holding every table grant) reads 0 queue rows: RLS filters" \
     "$(as_role anon "$UA" 'select count(*) from public.webhook_jobs;')" "0"
out="$(as_role anon "$UA" "insert into public.webhook_jobs (user_id, alert_id, alert_payload) values ('$UA', 'x', '{}');")"
if grep -q 'ERROR: 42501:.*row-level security' <<<"$out"; then pass "C. anon cannot insert into the queue (RLS violation)"; else fail "C. anon insert: $out"; fi
same "C. authenticated (all grants) still reads 0 rows" "$(as_role authenticated "$UA" 'select count(*) from public.webhook_jobs;')" "0"
for r in authenticated anon; do
    out="$(as_role "$r" "$UA" 'select public.process_webhook_jobs();')"
    if grep -q 'ERROR: 42501:.*permission denied for function process_webhook_jobs' <<<"$out"; then
        pass "C. $r still cannot execute the worker with production's grants (42501)"; else fail "C. $r executing the worker: $out"; fi
done
same "C. service_role runs the worker once against an empty vault: it returns, no error" \
     "$(as_role service_role "$UA" 'select public.process_webhook_jobs();')" ""
check "C. and it touched no job (nothing dispatched, processed or counted)" \
      "(select count(*) from public.webhook_jobs where attempt_count <> 0 or processed_at is not null or pg_net_request_id is not null or dispatched_at is not null or last_error is not null) = 0"
same "C. service_role reads the queue" "$(as_role service_role "$UA" 'select count(*) from public.webhook_jobs;')" "2"
same "C. service_role inserts, updates and deletes queue rows" \
     "$(as_role service_role "$UA" "insert into public.webhook_jobs (user_id, alert_id, alert_payload) values ('$UA', 'svc', '{\"grouping_key\":\"svc\"}'); update public.webhook_jobs set attempt_count = 1 where alert_id = 'svc'; delete from public.webhook_jobs where alert_id = 'svc';" | paste -sd' ' -)" \
     "INSERT 0 1 UPDATE 1 DELETE 1"
# deleting an account deletes its jobs
q -c "delete from public.profiles where id = '$UA'" >/dev/null
same "C. deleting an account deletes its queue rows (cascade)" "$(jobs_of "$UA")" "0"
same "C. and leaves the other account's" "$(jobs_of "$UB")" "1"

# =============================================================================
# D. negative controls: break a copy of the baseline files, run this suite on it
if [[ -z "${B0_CONTROL:-}" ]]; then
    echo "== D. negative controls (the suite must fail, naming the check)"
    CTL="$WORK/ctl"
    fresh_copy() { /bin/rm -rf "$CTL"; mkdir -p "$CTL"; cp -R "$REAL_SQL_DIR/." "$CTL/"; }
    run_control() { # run_control <label> <regex the failure output must match>
        local out rc=0
        out="$(B0_CONTROL=1 B0_SQL_DIR="$CTL" bash "$HERE/run_webhook_baseline_tests.sh" 2>&1)" || rc=$?
        if [[ $rc == 0 ]]; then fail "control: $1 — the suite PASSED on a broken baseline"
        elif grep -q -E "$2" <<<"$out"; then
            pass "control: $1 — fails as it must"
            grep -E '^  FAIL  ' <<<"$out" | cut -c1-96 | sed 's/^/          /' || true
            grep -E '^[<>] ' <<<"$out" | grep -v -E '^[<>] (1a|8)' | sort -u | head -4 | cut -c1-110 | sed 's/^/          diff /' || true
        else fail "control: $1 — failed, but not on /$2/"; echo "$out" | tail -8 >&2; fi
    }
    # block bounds
    drop_schema_block() { sed -i.bak '/^-- ── Webhook queue (B0:/,/^  for each row execute function public\.alerts_enqueue_webhook();/d' "$CTL/schema.sql"; }
    drop_worker_block() { sed -i.bak '/^-- ── Webhook queue worker (B0:/,$d' "$CTL/app_rpc.sql"; }

    fresh_copy; drop_schema_block; drop_worker_block
    run_control "the pre-B0 files (no webhook objects at all)" 'FAIL  B\. the current baseline|FAIL  C\.'
    fresh_copy; drop_schema_block
    run_control "the webhook_jobs block removed from schema.sql" 'FAIL  B\. the current baseline|FAIL  C\. a non-Test'
    fresh_copy; sed -i.bak "s/process_webhook_jobs reconcile (job %): %/process_webhook_jobs reconcile (job %) %/" "$CTL/app_rpc.sql"
    run_control "one character changed in the worker body" 'FAIL  B\. the current baseline'
    fresh_copy; sed -i.bak "s/using ((select auth.role()) = 'service_role'::text)/using (auth.role() = 'service_role')/; s/with check ((select auth.role()) = 'service_role'::text)/with check (auth.role() = 'service_role')/" "$CTL/schema.sql"
    run_control "the policy in v0.25's non-initplan form" 'FAIL  B\. the current baseline'
    fresh_copy; sed -i.bak '/^revoke execute on function public\.process_webhook_jobs() from PUBLIC, anon, authenticated;/d' "$CTL/app_rpc.sql"
    run_control "the v0.62 revoke dropped" 'FAIL  B\. the current baseline|FAIL  C\. (anon|authenticated) cannot execute'
    fresh_copy; printf '%s\n' '-- a later queue change someone forgot to mirror' 'create or replace function public.x() returns void language sql as $$ select 1 from public.webhook_jobs $$;' > "$CTL/migrate_v0.99_x.sql"
X='FAIL  B\. every migration that mentions the queue'
    mention() { # mention <label> <file content, printf args...>: a new migration; the suite must fail naming it
        local label="$1"; shift; fresh_copy; printf '%s\n' "$@" > "$CTL/migrate_v0.99_x.sql"
        run_control "$label" "$X"
    }
    mention "a new migration that uses webhook_jobs in code" '-- a later queue change someone forgot to mirror' 'create or replace function public.x() returns void language sql as $$ select 1 from public.webhook_jobs $$;'
    mention "a new migration that names webhook_jobs only in a comment" '-- webhook_jobs is only named here' 'select 1;'
    mention "a new migration that names it only in a block comment" '/* process_webhook_jobs */' 'select 1;'
    mention "E'it\\'s /*' hiding a later reference (a lexer would lose it)" "select E'it\\'s /*';" 'select 1 from public.webhook_jobs;' '/* actual comment */'
    mention "a non-ASCII identifier ending in E before a quote (éE'a\\') then a reference" "select 1 as éE'a\\';" 'select 1 from public.webhook_jobs;'
    mention "a quoted '/*' hiding a later reference" "select '/*';" 'select 1 from public.webhook_jobs;' '/* a real comment */'
    mention "the trigger's name, alerts_webhook_enqueue" 'drop trigger alerts_webhook_enqueue on public.alerts;'
    fresh_copy; { echo 'create or replace function public.x() returns void language sql as $$ select 1 from public.webhook_jobs $$;'
                  awk 'BEGIN { for (i = 0; i < 400000; i++) print "select 1; -- trailing statements" }'; } > "$CTL/migrate_v0.99_x.sql"
    run_control "an early reference followed by 400000 lines of SQL" "$X"
    # an allowlisted file passes, even when it mentions the queue again
    fresh_copy; echo '-- webhook_jobs, once more, in an allowlisted file' >> "$CTL/migrate_v0.78_unschedule_swarm_alert_eval.sql"
    out="$(B0_CONTROL=1 B0_SQL_DIR="$CTL" bash "$HERE/run_webhook_baseline_tests.sh" 2>&1)" && pass "control: an allowlisted migration that mentions the queue passes" \
        || { fail "control: an allowlisted migration was flagged"; echo "$out" | tail -5 >&2; }
    # removing an allowlist entry makes the suite fail for that file
    fresh_copy; sed '/^    "migrate_v0\.78_unschedule_swarm_alert_eval\.sql|/d' "$HERE/run_webhook_baseline_tests.sh" > "$CTL/tests/run_webhook_baseline_tests.sh"
    if cmp -s "$HERE/run_webhook_baseline_tests.sh" "$CTL/tests/run_webhook_baseline_tests.sh"; then echo "control: the allowlist line was not found" >&2; exit 2; fi
    out="$(B0_CONTROL=1 bash "$CTL/tests/run_webhook_baseline_tests.sh" 2>&1)" && fail "control: the suite passed with the v0.78 allowlist entry removed" \
        || { if grep -q "FAIL  B\. every migration.*migrate_v0\.78_unschedule_swarm_alert_eval\.sql" <<<"$out"; then pass "control: removing the v0.78 allowlist entry fails the suite, naming that file"; else fail "control: removal failed, but not on v0.78"; echo "$out" | tail -5 >&2; fi; }
    /bin/rm -rf "$CTL"
fi

echo
if (( fails > 0 )); then echo "$fails check(s) failed" >&2; exit 1; fi
echo "all checks passed"

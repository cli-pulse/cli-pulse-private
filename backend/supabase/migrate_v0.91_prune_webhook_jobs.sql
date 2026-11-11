-- ============================================================
-- v0.91 — the nightly cleanup also deletes webhook jobs that were finalized
-- more than a day ago; a pending job is never deleted
-- Date: 2026-11-12. Plan B2 (two review rounds). Needs B0 (#756: the queue in
-- the fresh-install baseline) and v0.89 (#760), and v0.89 must be APPLIED IN
-- PRODUCTION AND VERIFIED FIRST: before v0.89 a job whose deliveries failed
-- stayed pending for ever, and this file deletes finalized jobs only. The
-- guard refuses unless the worker is v0.89's. Applying it is the owner's
-- call, with the APPLY steps (a size gate first).
--
-- ── WHY ───────────────────────────────────────────────────────
-- Nothing deletes from public.webhook_jobs. The nightly cleanup
-- (_cleanup_expired_data_internal, v0.87) deletes from sessions, alerts and
-- pairing_attempt_log; v0.22's retention job names other tables. Every
-- non-Test alert leaves a job whose alert_payload copies the alert (its
-- title, message, project name), and the copy outlives the alert: the alert
-- goes after the account's retention (7 days), its job stays until the
-- account is deleted (ON DELETE CASCADE on user_id, v0.25).
-- Nothing needs a finished job after its first minute. The enqueue trigger
-- and the worker read pending jobs only (processed_at is null); send-webhook's
-- client-path dedup probe reads jobs enqueued in the last 60 seconds
-- (DEDUP_WINDOW_MS), far inside a day.
-- Why by processed_at, and never a pending job: a pending job may still be
-- sent or reconciled, and it holds its (user_id, grouping_key) dedup slot.
-- Deleting by enqueued_at would delete live and stuck jobs. Since v0.89 a
-- job is finalized (processed_at set) once the worker is done with it,
-- delivered or not (the comment on processed_at says which).
--
-- ── WHAT THIS DOES (one transaction) ──────────────────────────
-- A0. A time budget for the whole transaction, set first: on PostgreSQL 17
--    and later (production runs 17), transaction_timeout = 2s, counted from
--    the moment it is set; when it runs out the server ends the session and
--    the transaction rolls back, nothing changed. On older servers, which
--    have no transaction_timeout, statement_timeout = 2s instead (a limit
--    PER STATEMENT). lock_timeout = 1s for each lock wait, so a wait ends in
--    a readable error inside the budget. application_name =
--    'v0_91_prune_webhook_jobs', so the session is named in pg_stat_activity
--    until the transaction ends. All three are LOCAL.
--    The apply writes no row and takes no lock that an alert upload, the
--    worker or the cleanup itself waits on: CREATE OR REPLACE locks the
--    function's catalog row only (a call already running goes on with the
--    old body), and COMMENT ON TABLE takes SHARE UPDATE EXCLUSIVE on
--    webhook_jobs, which conflicts with VACUUM and DDL, not with reads or
--    writes. An autovacuum of webhook_jobs can make it wait past
--    lock_timeout: it then refuses with nothing changed; apply it again.
-- A. Refuses, and changes nothing, unless all of this holds:
--    1. public.webhook_jobs exists and has processed_at timestamptz.
--    2. exactly one function is named _cleanup_expired_data_internal, in any
--       schema, and it is public._cleanup_expired_data_internal().
--    3. its body (md5 of prosrc) is one of MD5 VALUES: v0.87's, as
--       production runs it, or this file's (a re-run). Anything else:
--       "unexpected definition, rebase required".
--    4. checked separately: SECURITY DEFINER; proconfig exactly
--       {search_path=pg_catalog, public, extensions}; returns jsonb; plpgsql;
--       the applier may replace it: pg_has_role(current_user, owner,
--       'USAGE'), i.e. it is the owner or a member of the owner role, which
--       is what CREATE OR REPLACE needs (production's owner is postgres; the
--       applier and the owner are logged in a NOTICE); its ACL grants EXECUTE
--       to none of PUBLIC, anon, authenticated, and neither anon nor
--       authenticated can execute it in effect either (has_function_privilege:
--       no grant reaches them through a role they inherit).
--    5. v0.89 is applied: public.process_webhook_jobs()'s body md5 is one of
--       v0.89's two values (MD5 VALUES). Exact, not a marker.
--    6. where pg_cron's cron.job exists: exactly one job is named
--       cleanup_expired_data_nightly, and exactly one job's command names
--       _cleanup_expired_data_internal, and they are the same job; it runs
--       exactly 'SELECT public._cleanup_expired_data_internal();' on
--       '7 3 * * *' (v0.21's), it is active, and its user can execute the
--       cleanup. No new job is scheduled: that job carries the prune.
-- B. Replaces the cleanup: v0.87's body, unchanged, plus a fourth block,
--    placed LAST:
--      delete from public.webhook_jobs
--       where processed_at is not null
--         and processed_at < now() - interval '1 day';
--    in its own BEGIN ... EXCEPTION block (its own savepoint), like the other
--    three: when it fails it is counted in errors, named in failed, reported
--    with RAISE WARNING, and the other three tables are still cleaned. Inside
--    the block, lock_timeout = 5s (set_config, local): a DELETE that waits
--    on a row lock (an account deletion's cascade, say) for 5 s fails into
--    the handler, deletes nothing of this table that night, and the next
--    night retries.
--    Why last: set_config(..., true) lasts until the end of the calling
--    transaction, not of the block (when the block succeeds), so a block
--    after it would run under its lock_timeout too. The function says so,
--    and the test suite checks the order.
--    No statement_timeout (the plan had one, 60 s): set inside the function
--    it would not apply to the statement already running (PostgreSQL arms a
--    statement timeout when a top-level statement starts), and a statement
--    timeout that does fire is a query cancel, which WHEN OTHERS does not
--    catch: it would abort the whole cleanup, the other three tables with
--    it. The suite shows both. How long the DELETE takes is kept short by
--    the size gate (APPLY step 0); above it, re-plan (a bounded nightly
--    delete or an index on processed_at), do not apply.
--    The answer gains webhook_jobs_deleted; errors runs 0 to 4; the warning
--    says "% of 4 tables failed". Every other key is unchanged. Same name,
--    no arguments, returns jsonb, SECURITY DEFINER, the same search_path;
--    owner and grants untouched (CREATE OR REPLACE keeps them; the revoke
--    repeats v0.21's and changes nothing in production).
--    Retention, as it may be described: a finalized job is eligible for
--    deletion 24 hours after it was finalized and is removed by the next
--    successful nightly cleanup (03:07 UTC): normally 24 to 48 hours after
--    finalization, longer after a missed or failed run. Not "deleted a day
--    after". Jobs of an account whose data_retention_days is 0 go the same
--    way: that setting governs sessions and alerts, not these copies.
-- C. comment on table public.webhook_jobs: what the queue is and that
--    retention, in those words.
-- D. Verifies: the body is this file's; attributes, owner and ACL are what
--    they were; every public table the cleanup names exists; the table
--    comment is there. NOTICEs give the applier, the owner and the body.
-- Not changed: the table, its columns, indexes and policy; the worker; the
-- enqueue trigger; the cron jobs (no new job, the 03:07 job's command
-- untouched); the cleanup_expired_data() wrapper; send-webhook.
--
-- ── MD5 VALUES (md5 of pg_proc.prosrc) ────────────────────────
-- public._cleanup_expired_data_internal():
--   before  v0.87, as production runs it (= as the files have it)  119e431b2b0f5c95f52a611e6dd14ac6
--   after   v0.91, this file as written                           66cc459c36eedfdbed41eb2b7b8fb32e
--   after   v0.91, this file without comment-only lines           74c5e98322da9a2af3782091304c750c
-- Production runs v0.87's body as written (B0's catalog check, 2026-11-12):
-- unlike v0.25's bodies, it was not stripped of its comment-only lines.
-- v0.87's body without them (34a80823c92101223a3c86e0892de2c1) is not a
-- body anything installed, and A3 refuses it. apply_migration may or may
-- not strip such lines from this file, so both "after" values are accepted.
-- public.process_webhook_jobs() (A5; v0.89 applied):
--   v0.89, as written                                             0adee6fd24eb7990eee5c3ac66caa8a9
--   v0.89, without comment-only lines                             485ce7e077540f5373eec5e6aeab394a
-- A3 accepts exactly the three cleanup values, A5 exactly the two worker
-- values, D the two "after" values. The test suite recomputes every value
-- from the files and fails on drift.
--
-- ── APPLY (the owner approves each step) ─────────────────────
-- Every Q and G query is read-only and returns counts, hashes and booleans
-- only: never a row's contents, a secret, a function body or a timestamp.
-- The exceptions are labelled: G2 (the table's size and vacuum statistics),
-- G3 (a query plan with its timings) and R0 (the function definition, kept
-- privately). Run each in its own statement (Supabase MCP execute_sql), and
-- keep every answer.
-- PRECONDITION: v0.89 is applied in production and verified (its APPLY step
-- 8 and 10: its Q5 = 0, and its Q9, pending over 1 day, has come down to 0).
-- 0. Before, read-only.
--    Q0: select md5(p.prosrc) as body_md5, (select count(*) from pg_proc where proname = '_cleanup_expired_data_internal') as same_name, (p.prosecdef and p.proconfig = array['search_path=pg_catalog, public, extensions'] and p.prorettype = 'jsonb'::regtype) as attrs_ok, pg_has_role(current_user, p.proowner, 'USAGE') as applier_can_replace, not (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE')) as anon_auth_denied, md5(coalesce(p.proacl::text, '')) as acl_md5, (select md5(w.prosrc) from pg_proc w where w.oid = to_regprocedure('public.process_webhook_jobs()')) as worker_md5, md5(obj_description('public.webhook_jobs'::regclass, 'pg_class')) as table_comment_md5 from pg_proc p where p.oid = 'public._cleanup_expired_data_internal()'::regprocedure;
--    FIRST APPLY: expect body_md5 = 119e431b2b0f5c95f52a611e6dd14ac6,
--    same_name = 1, attrs_ok, applier_can_replace and anon_auth_denied true,
--    acl_md5 = db23e67d6fad77fdfa003856d807d6af
--    ({postgres=X/postgres,service_role=X/postgres}, the cleanup's ACL as
--    B0's catalog check read it; if it differs, record it and go on only if
--    anon_auth_denied is true: the migration compares the ACL before and
--    after, not with this value), worker_md5 = 0adee6fd24eb7990eee5c3ac66caa8a9
--    or 485ce7e077540f5373eec5e6aeab394a (v0.89 is in), table_comment_md5
--    NULL.
--    RE-RUN OR RECOVERY: body_md5 = 66cc459c36eedfdbed41eb2b7b8fb32e or
--    74c5e98322da9a2af3782091304c750c (v0.91 is already in), table_comment_md5 =
--    e76ca42ffb3630f636946796fba14d80, the rest as above.
--    Any other body_md5 or worker_md5: STOP (a body this file was not
--    written against, or v0.89 not applied).
--    The size gate, counts:
--    G1: select count(*) as total, count(*) filter (where processed_at is null) as pending, count(*) filter (where processed_at is not null and processed_at < now() - interval '1 day') as eligible, count(*) filter (where processed_at is null and enqueued_at < now() - interval '1 day') as pending_over_1_day, count(*) filter (where processed_at is null and attempt_count >= 3 and pg_net_request_id is null) as stuck from public.webhook_jobs;
--    Table size and vacuum statistics (metadata, not data):
--    G2: select pg_total_relation_size('public.webhook_jobs') as bytes, s.n_live_tup, s.n_dead_tup, s.autovacuum_count + s.vacuum_count as vacuums, round(extract(epoch from now() - greatest(s.last_autovacuum, s.last_vacuum)) / 3600) as hours_since_vacuum from pg_stat_user_tables s where s.relid = 'public.webhook_jobs'::regclass;
--    What the scan costs, the DELETE's predicate in a SELECT (a plan with
--    timings and row counts; do NOT run EXPLAIN ANALYZE on the DELETE, which
--    would delete):
--    G3: explain (analyze, buffers) select count(*) from public.webhook_jobs where processed_at is not null and processed_at < now() - interval '1 day';
--    GATE, all of: G1 total at most 200000; G2 bytes at most 104857600
--    (100 MB); G3's Execution Time under 2000 ms; G1 pending_over_1_day = 0
--    and stuck = 0 (otherwise v0.89 has not done its work: STOP); G2
--    n_dead_tup not above n_live_tup (autovacuum keeps up). Failing it means
--    re-plan (a bounded nightly delete, or an index on processed_at), not
--    apply.
--    The nightly job, booleans and counts:
--    Q3: select count(*) filter (where jobname = 'cleanup_expired_data_nightly') as by_name, count(*) filter (where strpos(lower(command), '_cleanup_expired_data_internal') > 0) as by_command, bool_and(active) filter (where jobname = 'cleanup_expired_data_nightly') as active, bool_and(command = 'SELECT public._cleanup_expired_data_internal();' and schedule = '7 3 * * *') filter (where jobname = 'cleanup_expired_data_nightly') as definition_ok, bool_and(has_function_privilege(username, 'public._cleanup_expired_data_internal()', 'EXECUTE')) filter (where jobname = 'cleanup_expired_data_nightly') as user_can_execute, coalesce(current_setting('cron.timezone', true), 'GMT') in ('GMT', 'UTC', 'Etc/UTC') as timezone_utc from cron.job;
--    Expect 1|1|t|t|t|t. Anything else: STOP.
--    Q3b: select d.status, count(*) from cron.job_run_details d join cron.job j on j.jobid = d.jobid where j.jobname = 'cleanup_expired_data_nightly' and d.start_time > now() - interval '7 days' group by d.status order by d.status;
--    Expect only succeeded, about 7.
--    The dry run, the DELETE's predicate as a count (the suite checks that
--    the cleanup's webhook_jobs_deleted equals it, in one transaction):
--    DRY: select count(*) as eligible from public.webhook_jobs where processed_at is not null and processed_at < now() - interval '1 day';
--    ROLLBACK SOURCE, keep privately (not in logs, tickets or the PR; it is
--    the whole function definition):
--    R0: select pg_get_functiondef('public._cleanup_expired_data_internal()'::regprocedure);
-- 1. Apply this file as it stands, byte for byte, with the Supabase MCP's
--    `apply_migration` under the name `v0_91_prune_webhook_jobs`. Record the
--    md5 of the text sent next to this file's. Not between 03:00 and 03:15
--    UTC, so that step 3's first run is unambiguous (a cleanup already
--    running when the apply commits finishes with the old body; nothing
--    else follows from the overlap).
-- 2. Read the outcome:
--    a. it reports success: go to step 3.
--    b. it reports an ERROR (a refusal, a lock timeout, anything): the whole
--       transaction rolled back; nothing changed. Confirm with Q0 (as in
--       step 0). Fix the cause and apply again, or stop there.
--    c. no clear answer (client timeout, lost connection; also what the
--       budget of A0 running out looks like on PostgreSQL 17: the server
--       ends the session, "terminating connection due to transaction
--       timeout"): the transaction may still be running. Do not retry yet.
--       Repeat Q6 every few seconds until it is 0 (the apply's session
--       carries this application_name until its transaction ends):
--       Q6: select count(*) as apply_sessions from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and application_name = 'v0_91_prune_webhook_jobs';
--       Then Q0: body_md5 a v0.91 value and table_comment_md5 as in
--       RE-RUN: it committed, go to step 3. body_md5 and table_comment_md5
--       as in step 0: it rolled back, as in b. Anything else: STOP and
--       investigate.
-- 3. Verify, read-only: Q0 as in RE-RUN OR RECOVERY (body_md5 one of the two
--    v0.91 values, the comment, every other column as in step 0); Q3 as in
--    step 0; DRY, recorded as N. The migration's NOTICEs name the applier,
--    the owner and the body it installed.
-- 4. The first run: the 03:07 UTC cron run after the apply, or the owner
--    runs once
--      select public._cleanup_expired_data_internal();
--    This is the real cleanup: it also deletes what is past retention in
--    sessions, alerts and pairing_attempt_log, and its answer counts all
--    four tables. Compare only webhook_jobs_deleted with N (plus the jobs
--    that crossed 24 h since DRY); errors must be 0.
-- 5. After the first cron run after the apply, read-only:
--    * backend/supabase/ops/check_webhook_jobs_retention.sql returns no rows
--      (before that run it returns 'finalized jobs overdue': the backlog the
--      v0.87 body never deleted);
--    * DRY right after the run counts only jobs that crossed 24 h since;
--    * Q3b: the run succeeded;
--    * no WARNING from _cleanup_expired_data_internal in the Postgres log.
--    Do NOT expect G2's bytes to fall: DELETE and plain (auto)vacuum make
--    the space reusable, they do not shrink the file. Check that n_dead_tup
--    comes down after autovacuum and that bytes stop growing. Do NOT read
--    pending counts as proof that pending jobs were kept (they move with
--    enqueues and the worker); that proof is the predicate and the suite.
-- 6. From then on, ops/check_webhook_jobs_retention.sql is part of every
--    release's verification (AGENTS.md). Only after step 5 passes may the
--    privacy text describe this retention, in the words of B above.
--
-- ROLLBACK: re-apply the definition R0 saved (v0.87's body) and drop the
-- retention comment, which would then be untrue:
--    RB: comment on table public.webhook_jobs is null;
-- Future pruning stops; deleted jobs do not come back (they were copies of
-- alerts that themselves go after 7 days; no restore is planned).
-- On suspected over-deletion, FIRST stop further runs (this pauses the whole
-- nightly cleanup, sessions and alerts included; pg_cron's alter_job takes
-- the job id by position), keep the logs, run no VACUUM FULL and no manual
-- cleanup, then ask the owner:
--    P9: select cron.alter_job(jobid, active := false) from cron.job where jobname = 'cleanup_expired_data_nightly';
-- The predicate cannot match a pending job (processed_at NULL) by
-- construction.
--
-- Tested by backend/supabase/tests/run_v091_prune_webhook_jobs_tests.sh
-- (CI job "Webhook jobs prune (v0.91)").
-- ============================================================

begin;
-- A0: each lock wait, the session's name, and the budget for the whole apply
set local lock_timeout = '1s';
set local application_name = 'v0_91_prune_webhook_jobs';
do $budget$
begin
    if current_setting('server_version_num')::int >= 170000 then
        -- the whole transaction, from here (header A0)
        perform set_config('transaction_timeout', '2s', true);
    else
        -- no transaction_timeout before PostgreSQL 17: per statement only
        perform set_config('statement_timeout', '2s', true);
    end if;
end
$budget$;

-- ── A: guards (refuse, change nothing) ────────────────────────
do $guard$
declare
    v_fn        regprocedure := to_regprocedure('public._cleanup_expired_data_internal()');
    v_worker    regprocedure := to_regprocedure('public.process_webhook_jobs()');
    v_md5       text;
    v_wmd5      text;
    v_secdef    boolean;
    v_config    text[];
    v_rettype   oid;
    v_lang      name;
    v_owner     oid;
    v_acl       aclitem[];
    v_named     bigint;
    v_calling   bigint;
    v_job       record;
    v_role      name;
begin
    -- 1. the table
    if to_regclass('public.webhook_jobs') is null then
        raise exception 'v0.91: public.webhook_jobs does not exist; nothing changed';
    end if;
    if not exists (select 1 from pg_attribute a
                    where a.attrelid = 'public.webhook_jobs'::regclass
                      and a.attname = 'processed_at' and a.attnum > 0 and not a.attisdropped
                      and a.atttypid = 'timestamptz'::regtype) then
        raise exception 'v0.91: public.webhook_jobs has no processed_at timestamptz column; nothing changed';
    end if;

    -- 2. the function
    if v_fn is null or (select count(*) from pg_proc where proname = '_cleanup_expired_data_internal') <> 1 then
        raise exception 'v0.91: expected exactly one function named _cleanup_expired_data_internal, public._cleanup_expired_data_internal(), found % (in all schemas); nothing changed',
            (select count(*) from pg_proc where proname = '_cleanup_expired_data_internal');
    end if;

    select md5(p.prosrc), p.prosecdef, p.proconfig, p.prorettype, l.lanname, p.proowner, p.proacl
      into v_md5, v_secdef, v_config, v_rettype, v_lang, v_owner, v_acl
      from pg_proc p join pg_language l on l.oid = p.prolang
     where p.oid = v_fn;

    -- 3. the exact body (MD5 VALUES in the header)
    if v_md5 not in ('119e431b2b0f5c95f52a611e6dd14ac6',   -- v0.87, as production runs it
                     '66cc459c36eedfdbed41eb2b7b8fb32e',   -- v0.91, this file
                     '74c5e98322da9a2af3782091304c750c')   -- v0.91, without comment-only lines
    then
        raise exception 'v0.91: public._cleanup_expired_data_internal() has an unexpected definition (body md5 %), rebase required; nothing changed', v_md5;
    end if;

    -- 4. attributes, owner, ACL
    if not v_secdef then
        raise exception 'v0.91: public._cleanup_expired_data_internal() is not SECURITY DEFINER; nothing changed';
    end if;
    if v_config is distinct from array['search_path=pg_catalog, public, extensions'] then
        raise exception 'v0.91: public._cleanup_expired_data_internal() has proconfig %, expected {search_path=pg_catalog, public, extensions}; nothing changed', v_config;
    end if;
    if v_rettype <> 'jsonb'::regtype or v_lang <> 'plpgsql' then
        raise exception 'v0.91: public._cleanup_expired_data_internal() does not return jsonb in plpgsql; nothing changed';
    end if;
    raise notice 'v0.91: applier %, cleanup owner %', current_user, pg_get_userbyid(v_owner);
    if not pg_has_role(current_user, v_owner, 'USAGE') then
        raise exception 'v0.91: % is neither the owner of public._cleanup_expired_data_internal() (%) nor a member of that role, so it cannot replace it; nothing changed',
            current_user, pg_get_userbyid(v_owner);
    end if;
    if exists (
        select 1 from aclexplode(coalesce(v_acl, acldefault('f', v_owner))) a
        where a.privilege_type = 'EXECUTE'
          and (a.grantee = 0
               or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated')))
    ) then
        raise exception 'v0.91: PUBLIC, anon or authenticated may execute public._cleanup_expired_data_internal() (acl %); nothing changed', v_acl;
    end if;
    -- and in effect: no grant reaches anon or authenticated through a role
    -- they inherit (has_function_privilege, as APPLY Q0 checks)
    for v_role in select r.rolname from pg_roles r where r.rolname in ('anon', 'authenticated') order by 1 loop
        if has_function_privilege(v_role, v_fn, 'EXECUTE') then
            raise exception 'v0.91: % may execute public._cleanup_expired_data_internal() through a role it inherits (has_function_privilege; acl %); nothing changed', v_role, v_acl;
        end if;
    end loop;

    -- 5. v0.89 is applied (exact worker body)
    select md5(prosrc) into v_wmd5 from pg_proc where oid = v_worker;
    if v_wmd5 is null or v_wmd5 not in ('0adee6fd24eb7990eee5c3ac66caa8a9',   -- v0.89, as written
                                        '485ce7e077540f5373eec5e6aeab394a')    -- v0.89, without comment-only lines
    then
        raise exception 'v0.89 is not applied (public.process_webhook_jobs() body md5 %): apply and verify v0.89 first; v0.91 changed nothing',
            coalesce(v_wmd5, 'none');
    end if;

    -- 6. the nightly job that carries the prune
    if to_regclass('cron.job') is not null then
        select count(*) into v_named from cron.job where jobname = 'cleanup_expired_data_nightly';
        select count(*) into v_calling from cron.job where strpos(lower(command), '_cleanup_expired_data_internal') > 0;
        if v_named <> 1 or v_calling <> 1 then
            raise exception 'v0.91: expected exactly one cron job named cleanup_expired_data_nightly (found %) and exactly one calling _cleanup_expired_data_internal (found %); nothing changed',
                v_named, v_calling;
        end if;
        select jobid, schedule, command, active, username into v_job
          from cron.job where jobname = 'cleanup_expired_data_nightly';
        if strpos(lower(v_job.command), '_cleanup_expired_data_internal') = 0 then
            raise exception 'v0.91: the cron job calling _cleanup_expired_data_internal is not cleanup_expired_data_nightly; nothing changed';
        end if;
        if v_job.command <> 'SELECT public._cleanup_expired_data_internal();' or v_job.schedule <> '7 3 * * *' then
            raise exception 'v0.91: cron job % (cleanup_expired_data_nightly) runs % on %, not v0.21''s command and schedule; nothing changed',
                v_job.jobid, v_job.command, v_job.schedule;
        end if;
        if not v_job.active then
            raise exception 'v0.91: cron job % (cleanup_expired_data_nightly) is not active, so nothing would run the prune; nothing changed', v_job.jobid;
        end if;
        if to_regrole(v_job.username) is null
           or not has_function_privilege(v_job.username, v_fn, 'EXECUTE') then
            raise exception 'v0.91: cron job % runs as %, which cannot execute public._cleanup_expired_data_internal(); nothing changed', v_job.jobid, v_job.username;
        end if;
    end if;

    -- what D compares with
    perform set_config('v091.before_owner', v_owner::text, true);
    perform set_config('v091.before_acl', coalesce(v_acl::text, 'NULL'), true);
end
$guard$;

-- ── B: the cleanup ────────────────────────────────────────────
-- _cleanup_expired_data_internal(), v0.91: what pg_cron job
-- cleanup_expired_data_nightly runs at 03:07 UTC (v0.21's schedule,
-- unchanged). v0.87's three blocks unchanged (sessions and alerts past the
-- account's retention, pairing attempts past an hour), and a fourth, last:
-- webhook jobs finalized more than a day ago; a pending job is never
-- deleted. Each block on its own savepoint (header B).
-- BEGIN cleanup
create or replace function public._cleanup_expired_data_internal()
returns jsonb as $$
declare
  v_sessions integer := 0;
  v_running integer := 0;
  v_alerts integer := 0;
  v_pairing integer := 0;
  v_webhook integer := 0;
  v_failed text[] := '{}';
begin
  -- v0.87 one delete per table, each on its own savepoint (BEGIN ... EXCEPTION).

  -- Sessions whose last activity is older than the account's retention,
  -- whatever their status: a live producer rewrites its rows on every sync.
  -- Retention is capped at 36500 days: one account's larger value would
  -- otherwise overflow the timestamp and fail this DELETE for every account.
  begin
    with gone as (
      delete from public.sessions s
       using public.user_settings us
       where us.user_id = s.user_id
         and us.data_retention_days > 0
         and s.last_active_at < now() - make_interval(days => least(us.data_retention_days, 36500))
      returning s.status
    )
    select count(*), count(*) filter (where status = 'Running')
      into v_sessions, v_running
      from gone;
  exception when others then
    v_failed := v_failed || 'sessions'::text;
    raise warning '_cleanup_expired_data_internal: sessions not cleaned: % (SQLSTATE %)', sqlerrm, sqlstate;
  end;

  -- Alerts older than the account's retention, resolved or not (the same cap).
  begin
    delete from public.alerts a
     using public.user_settings us
     where us.user_id = a.user_id
       and us.data_retention_days > 0
       and a.created_at < now() - make_interval(days => least(us.data_retention_days, 36500));
    get diagnostics v_alerts = row_count;
  exception when others then
    v_failed := v_failed || 'alerts'::text;
    raise warning '_cleanup_expired_data_internal: alerts not cleaned: % (SQLSTATE %)', sqlerrm, sqlstate;
  end;

  -- Pairing attempts older than register_helper's one-hour window.
  begin
    delete from public.pairing_attempt_log
     where attempted_at < now() - interval '1 hour';
    get diagnostics v_pairing = row_count;
  exception when others then
    v_failed := v_failed || 'pairing_attempt_log'::text;
    raise warning '_cleanup_expired_data_internal: pairing_attempt_log not cleaned: % (SQLSTATE %)', sqlerrm, sqlstate;
  end;

  -- v0.91 webhook jobs finalized more than a day ago (processed_at set by
  -- process_webhook_jobs, v0.89), whatever the account's retention. A
  -- pending job (processed_at NULL) is never deleted: the worker may still
  -- send or reconcile it, and it holds its dedup slot.
  -- KEEP THIS BLOCK LAST: set_config(..., true) lasts until the end of the
  -- calling transaction, not of this block, so a block after it would run
  -- under its lock_timeout too. lock_timeout bounds a wait on a row lock
  -- (an account deletion's cascade): past 5 s the DELETE fails into the
  -- handler and the next night retries. No statement_timeout: set here it
  -- would not stop the statement already running, and a statement timeout
  -- is a cancel that WHEN OTHERS does not catch (migrate_v0.91 header B).
  begin
    perform set_config('lock_timeout', '5s', true);
    delete from public.webhook_jobs
     where processed_at is not null
       and processed_at < now() - interval '1 day';
    get diagnostics v_webhook = row_count;
  exception when others then
    v_failed := v_failed || 'webhook_jobs'::text;
    raise warning '_cleanup_expired_data_internal: webhook_jobs not cleaned: % (SQLSTATE %)', sqlerrm, sqlstate;
  end;

  if cardinality(v_failed) > 0 then
    raise warning '_cleanup_expired_data_internal: % of 4 tables failed: %',
      cardinality(v_failed), array_to_string(v_failed, ', ');
  end if;

  return jsonb_build_object(
    'sessions_deleted', v_sessions,
    'running_sessions_deleted', v_running,
    'alerts_deleted', v_alerts,
    'pairing_attempt_log_deleted', v_pairing,
    'webhook_jobs_deleted', v_webhook,
    'errors', cardinality(v_failed),
    'failed', to_jsonb(v_failed)
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;
-- END cleanup

revoke all on function public._cleanup_expired_data_internal() from public, anon, authenticated;

-- ── C: the table's retention ──────────────────────────────────
comment on table public.webhook_jobs is
    'Webhook delivery queue (v0.25): one job per non-Test alert, enqueued by '
    'alerts_enqueue_webhook() and delivered by process_webhook_jobs(). '
    'Retention (v0.91): a finalized job (processed_at set) is eligible for '
    'deletion 24 hours after it was finalized and is removed by the next '
    'successful nightly cleanup (_cleanup_expired_data_internal(), pg_cron '
    'job cleanup_expired_data_nightly, 03:07 UTC), whatever the account''s '
    'data_retention_days. A pending job (processed_at NULL) is never deleted '
    'by it. Deleting the account deletes all of its jobs.';

-- ── D: verification ───────────────────────────────────────────
do $verify$
declare
    v_fn       regprocedure := to_regprocedure('public._cleanup_expired_data_internal()');
    v_md5      text;
    v_missing  text;
begin
    select md5(prosrc) into v_md5 from pg_proc where oid = v_fn;
    if v_md5 is null or v_md5 not in ('66cc459c36eedfdbed41eb2b7b8fb32e', '74c5e98322da9a2af3782091304c750c') then
        raise exception 'v0.91: after the replace the cleanup''s body md5 is %, not this file''s', v_md5;
    end if;
    if not exists (
        select 1 from pg_proc p join pg_language l on l.oid = p.prolang
        where p.oid = v_fn
          and p.prosecdef
          and p.proconfig = array['search_path=pg_catalog, public, extensions']
          and p.prorettype = 'jsonb'::regtype
          and l.lanname = 'plpgsql'
          and p.proowner::text = current_setting('v091.before_owner')
          and coalesce(p.proacl::text, 'NULL') = current_setting('v091.before_acl')
    ) then
        raise exception 'v0.91: after the replace the cleanup''s attributes, owner or ACL differ from before';
    end if;
    -- every table the cleanup names exists (v0.87's check, for this function)
    select string_agg(distinct 'public.' || r[1], ', ') into v_missing
      from pg_proc p
     cross join lateral regexp_matches(p.prosrc, 'public\.([a-z_][a-z0-9_]*)', 'g') r
     where p.oid = v_fn
       and to_regclass('public.' || r[1]) is null;
    if v_missing is not null then
        raise exception 'v0.91: the cleanup names %, which does not exist', v_missing;
    end if;
    if coalesce(obj_description('public.webhook_jobs'::regclass, 'pg_class'), '') not like 'Webhook delivery queue (v0.25):%Retention (v0.91):%' then
        raise exception 'v0.91: the comment on public.webhook_jobs is missing';
    end if;
    raise notice 'v0.91: cleanup replaced (body md5 %), owner and ACL unchanged', v_md5;
end
$verify$;

commit;

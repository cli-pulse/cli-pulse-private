-- ============================================================
-- v0.89 — webhook jobs that keep failing are finalized, instead of staying
-- pending forever and silencing that alert's later webhooks
-- Date: 2026-11-12. Plan B1 (two review rounds). Needs B0 (#756: the queue in
-- the fresh-install baseline) and its production catalog check (done
-- 2026-11-12; its findings are in MD5 VALUES and step 0 below).
-- Applying it is the owner's call, with the APPLY steps below.
--
-- ── WHY ───────────────────────────────────────────────────────
-- The worker (public.process_webhook_jobs, v0.25; v0.62 only revoked it) never
-- sets processed_at when a delivery fails. It runs two passes per call,
-- reconcile and then dispatch, so a webhook that answers 502 goes: dispatch
-- (attempt_count 1); next call: reconcile to 2 and redispatch in the same call
-- (3); next call: reconcile to 4. Dispatch only takes attempt_count < 3, so
-- nothing looks at the job again: two real attempts, then pending forever. A
-- request pg_net never answers ends the same way at 3, and so does a third
-- failed http_post.
-- A pending job holds its (user_id, grouping_key) slot in
-- idx_webhook_jobs_pending_dedup, and the enqueue trigger skips an alert while
-- a pending job has its key. So every later alert with that key is never
-- enqueued: for that alert, the user's webhook is silent for good.
-- Also: pg_net records a finished transport failure (timeout, could not
-- connect) as a response row with status_code NULL and timed_out or error_msg
-- set; v0.25 read that as "no answer yet" and waited 5 minutes. And a job with
-- a request id but no dispatched_at was never reconciled at all.
--
-- ── WHAT THIS DOES (one transaction) ──────────────────────────
-- A. Refuses, and changes nothing, unless all of this holds:
--    1. public.webhook_jobs exists; the trigger alerts_webhook_enqueue on
--       public.alerts is enabled and calls alerts_enqueue_webhook(); exactly
--       one function is named process_webhook_jobs, in any schema, and it is
--       public.process_webhook_jobs().
--    2. the worker's body (md5 of prosrc) is one of the four in MD5 VALUES:
--       v0.25's, as production runs it or as the files have it, or this
--       file's (a re-run). Anything else: "unexpected definition, rebase
--       required".
--    3. checked separately: SECURITY DEFINER; proconfig exactly
--       {search_path=pg_catalog, extensions, public, net}; returns void;
--       plpgsql; the applier may replace it: pg_has_role(current_user,
--       owner, 'USAGE'), i.e. it is the owner or a member of the owner role,
--       which is what CREATE OR REPLACE needs (production's owner is
--       postgres, step 0; the applier and the owner are logged in a NOTICE);
--       its ACL grants EXECUTE to none of PUBLIC, anon, authenticated.
--    4. net._http_response, where it exists, has the columns the new
--       worker reads (status_code, content, timed_out, error_msg; pg_net
--       0.20 has them). Where pg_cron's cron.job exists: exactly one job
--       whose command names process_webhook_jobs (a second schedule would be
--       a second caller), that job is paused (active = false; APPLY step 2),
--       and its user can execute the worker. And no other backend in this
--       database is running the worker (pg_stat_activity: state 'active',
--       query naming process_webhook_jobs(), not a query on pg_stat_activity
--       itself).
--    5. at most 5000 jobs need the backfill in D (one transaction holds its
--       row locks until commit; above that, batch first, APPLY step 0).
--    It starts with lock_timeout = 5s, so CREATE OR REPLACE fails fast
--    instead of queueing behind a session that holds a lock on the function.
-- B. Replaces the worker: same signature, SECURITY DEFINER, same search_path,
--    owner and grants untouched (CREATE OR REPLACE keeps them). What changes:
--    * one call at a time: pg_try_advisory_xact_lock first; a second caller
--      (duplicate schedule, manual call) returns at once and does nothing;
--    * a job's age is coalesce(dispatched_at, enqueued_at), so a job with a
--      request id but no dispatched_at is reconciled;
--    * a transport failure is a failed attempt, handled at once like a
--      non-2xx answer;
--    * a failed attempt finalizes the job (processed_at = now(), last_error
--      kept) when attempt_count reaches 3: after a non-2xx answer or a
--      transport failure (attempt_count + 1 >= 3), after a raise from
--      net.http_post (the same), and when the third request has had no answer
--      for 5 minutes (attempt_count >= 3; never earlier, the request may
--      still be live).
--    Attempts per job, unchanged by design: a non-2xx answer or a transport
--    failure gives 2 real requests (the counter also counts the redispatch);
--    no answer, or a raising http_post, gives 3.
-- C. Says what processed_at means, on the column: FINALIZED, not delivered.
--    processed_at set and last_error NULL: finalized successfully (a 2xx
--    answer, which includes send-webhook's 200 "skipped" replies: no webhook
--    configured, filtered, deduped). processed_at set and last_error set:
--    finalized with failure. No outcome column is added.
-- D. Backfill: finalizes the jobs the old worker left stuck, and only those:
--    processed_at NULL, attempt_count >= 3 and no request id (the old worker
--    selects them in neither pass). last_error gets the prefix
--    'v0.89 backfill: retries exhausted before v0.89; '. Jobs with a request
--    id are left to the new worker. Nothing is re-sent: their alerts are old.
--    Their dedup slots free up, so the next alert with each key is enqueued.
-- E. Verifies: the body is this file's, the attributes, owner and ACL are
--    what they were, the column comment is there, and no stuck job is left.
--    NOTICEs give the applier, the owner and the number backfilled.
-- Not changed: the table, its indexes and policy, the enqueue trigger, the
-- cron schedule, send-webhook.
--
-- ── MD5 VALUES (md5 of pg_proc.prosrc of public.process_webhook_jobs) ──
-- Production's function bodies are the migration files' with every line that
-- is only a `--` comment removed (blank lines kept): measured 2026-11-12
-- (B0's catalog check), from how v0.25 was applied. apply_migration may or may
-- not strip such lines from this file too, so each body is listed both ways.
--   before  v0.25, as production runs it (no comment-only lines)  7e7c1040479aa3f0879cbb1b99911c21
--   before  v0.25, as the files have it (B0's baseline)            36305ed8b76ab2f9607943a18672c907
--   after   v0.89, this file as written                            0adee6fd24eb7990eee5c3ac66caa8a9
--   after   v0.89, this file without comment-only lines            485ce7e077540f5373eec5e6aeab394a
-- A2 accepts exactly these four; E accepts the two "after" values. The test
-- suite recomputes all four from the files and fails on drift.
--
-- ── APPLY (the owner approves each step) ─────────────────────
-- 0. Preflight, read-only (Supabase MCP execute_sql). Counts and md5 values
--    only: never a row's contents or a secret's value. Save every answer.
--    Q0: select pg_get_userbyid(p.proowner) as owner, md5(p.prosrc) as body_md5, p.prosecdef as secdef, p.proconfig as config, p.proacl as acl, (select count(*) from pg_proc where proname = 'process_webhook_jobs') as same_name, current_user as applier from pg_proc p where p.oid = 'public.process_webhook_jobs()'::regprocedure;
--    Expect owner = postgres, body_md5 = 7e7c1040479aa3f0879cbb1b99911c21,
--    secdef = true, config = {"search_path=pg_catalog, extensions, public, net"},
--    acl = {postgres=X/postgres,service_role=X/postgres}, same_name = 1, and
--    an applier that is the owner or a member of it. Any other body_md5:
--    STOP (production runs a body this file was not written against).
--    Q1: select count(*) total, count(*) filter (where processed_at is null) pending, count(*) filter (where processed_at is null and attempt_count >= 3 and pg_net_request_id is null) stuck, count(*) filter (where processed_at is null and pg_net_request_id is not null) awaiting, count(*) filter (where pg_net_request_id is not null and dispatched_at is null) malformed_id_without_dispatch, count(*) filter (where processed_at is null and pg_net_request_id is null and attempt_count = 0 and enqueued_at < now() - interval '1 hour') never_dispatched_old, count(*) filter (where processed_at is not null and pg_net_request_id is not null) finalized_with_request_id, count(*) filter (where attempt_count < 0 or attempt_count > 10) odd_counts, min(enqueued_at), max(enqueued_at) from public.webhook_jobs;
--    Q1b: select attempt_count, count(*) from public.webhook_jobs where processed_at is null group by 1 order by 1;
--    Secrets, each exactly once and non-empty, without selecting a value:
--    Q2: select n.name, count(s.name) as copies, count(*) filter (where s.decrypted_secret is not null and s.decrypted_secret <> '') as non_empty from (values ('app_supabase_url'),('app_service_role_key')) n(name) left join vault.decrypted_secrets s on s.name = n.name group by n.name;
--    Expect copies = 1 and non_empty = 1 for both; otherwise STOP (nothing
--    dispatches).
--    Worker and cron: run backend/supabase/ops/check_webhook_catalog.sql and
--    diff it with B0's 2026-11-12 output (only the body md5s and the
--    Supabase-default ACL entries may differ, as recorded then). Then:
--    Q3: select jobid, jobname, schedule, command, active, username from cron.job where command ilike '%process_webhook_jobs%';
--    Expect exactly ONE row (a second one is a duplicate schedule: STOP).
--    On 2026-11-12: 3, process_webhook_jobs, '30 seconds',
--    'select public.process_webhook_jobs()', active true, postgres.
--    Q3b: select d.status, count(*) from cron.job_run_details d join cron.job j on j.jobid = d.jobid where j.command ilike '%process_webhook_jobs%' and d.start_time > now() - interval '24 hours' group by d.status order by d.status;
--    Save the worker's definition, the rollback source:
--    Q4: select pg_get_functiondef('public.process_webhook_jobs()'::regprocedure);
--    If Q1 shows stuck > 5000, run BF below FIRST, each run its own
--    statement (its own committed transaction), repeated until Q1's stuck is
--    5000 or less. It touches only jobs the worker never selects, so no
--    pause is needed, and it resumes safely if interrupted. Only then start
--    the window, so the size guard (A5) cannot fail with the job paused.
--    BF: update public.webhook_jobs set processed_at = now(), last_error = 'v0.89 backfill: retries exhausted before v0.89; ' || coalesce(last_error, '') where id in (select id from public.webhook_jobs where processed_at is null and attempt_count >= 3 and pg_net_request_id is null order by id limit 1000);
-- 1. Record the job's `active` value from Q3 (true on 2026-11-12).
-- 2. Pause it. pg_cron's signature is cron.alter_job(job_id bigint, schedule
--    text default null, command text default null, database text default
--    null, username text default null, active boolean default null), so the
--    id is passed by position; expect exactly one row:
--    P2: select cron.alter_job(jobid, active := false) from cron.job where command ilike '%process_webhook_jobs%';
--    Last resort, only if that function is not available to the role:
--    `update cron.job set active = false where jobid = <that jobid>;` (Q3's jobid)
-- 3. Wait until no run is in flight. pg_stat_activity is the authority:
--    Q6: select count(*) as running from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'active' and query ilike '%process_webhook_jobs()%' and query not ilike '%pg_stat_activity%';
--    Q6b: select count(*) as recent_unfinished from cron.job_run_details d join cron.job j on j.jobid = d.jobid where j.command ilike '%process_webhook_jobs%' and d.status in ('running', 'starting') and d.start_time > now() - interval '10 minutes';
--    Repeat every few seconds until both are 0. A 'running' or 'starting'
--    row older than 10 minutes with no live backend is a leftover from a
--    crash or restart: note it, do not wait on it. Q6 also covers manual
--    callers (query text of another role's session shows only if the
--    applier may read it; the cron job runs as postgres).
-- 4. Apply this file as it stands, byte for byte, with the Supabase MCP's
--    `apply_migration` under the name `v0_89_webhook_jobs_finalize_failures`.
--    Record the md5 of the text sent next to this file's. A3 and A4 are
--    re-checked inside. If it fails or times out, run Q0 before anything
--    else: if body_md5 is one of the two "after" values it went through. The
--    job stays paused until that is decided.
-- 5. Verify, read-only: Q0 again: body_md5 is one of the two "after"
--    values, and owner, secdef, config, acl and same_name are what step 0
--    showed. Q1 again: stuck = 0. Q3 again: still exactly one row, with the
--    schedule and command step 0 showed, active = false. The migration's
--    NOTICE "backfilled N" equals step 0's stuck (the job was paused; alert
--    inserts meanwhile only add jobs with attempt_count 0).
-- 6. Restore the value recorded in step 1 (true on 2026-11-12; put the
--    recorded value in place of true), then run Q3 and see it:
--    R6: select cron.alter_job(jobid, active := true) from cron.job where command ilike '%process_webhook_jobs%';
-- 7. Over the next hours, read-only:
--    Q7: select count(*) as new_stuck from public.webhook_jobs where processed_at is null and attempt_count >= 3 and pg_net_request_id is null;
--    Q8: select count(*) as pending_over_1_day from public.webhook_jobs where processed_at is null and enqueued_at < now() - interval '1 day';
--    Q7 must stay 0. Q8 should trend to 0 (that also needs the secrets and
--    enough worker throughput, which v0.89 does not change). No WARNING from
--    process_webhook_jobs in the Postgres log.
--
-- ROLLBACK: re-apply the definition Q4 saved, with the job paused and the
-- same drain (steps 2, 3, 6). Q0's body_md5 is then step 0's again. The
-- backfill is NOT undone: the jobs it finalized stay finalized (they were
-- unrecoverable, and the prefix is not a restoration record). Undoing it
-- exactly would need its own plan with captured ids and original values,
-- built never to delete newer pending jobs.
--
-- Tested by backend/supabase/tests/run_v089_webhook_jobs_finalize_tests.sh
-- (CI job "Webhook jobs finalize failures (v0.89)").
-- ============================================================

begin;
set local lock_timeout = '5s';

-- ── A: guards (refuse, change nothing) ────────────────────────
do $guard$
declare
    v_fn       regprocedure := to_regprocedure('public.process_webhook_jobs()');
    v_md5      text;
    v_secdef   boolean;
    v_config   text[];
    v_rettype  oid;
    v_lang     name;
    v_owner    oid;
    v_acl      aclitem[];
    v_jobs     bigint;
    v_job      record;
    v_stuck    bigint;
    v_missing  text;
begin
    -- 1. the objects
    if to_regclass('public.webhook_jobs') is null then
        raise exception 'v0.89: public.webhook_jobs does not exist; nothing changed';
    end if;
    if not exists (
        select 1 from pg_trigger t
        where t.tgrelid = to_regclass('public.alerts')
          and t.tgname = 'alerts_webhook_enqueue'
          and not t.tgisinternal
          and t.tgenabled = 'O'
          and t.tgfoid = to_regprocedure('public.alerts_enqueue_webhook()')
    ) then
        raise exception 'v0.89: trigger alerts_webhook_enqueue on public.alerts is missing, disabled or calls another function; nothing changed';
    end if;
    if v_fn is null or (select count(*) from pg_proc where proname = 'process_webhook_jobs') <> 1 then
        raise exception 'v0.89: expected exactly one function named process_webhook_jobs, public.process_webhook_jobs(), found % (in all schemas); nothing changed',
            (select count(*) from pg_proc where proname = 'process_webhook_jobs');
    end if;

    select md5(p.prosrc), p.prosecdef, p.proconfig, p.prorettype, l.lanname, p.proowner, p.proacl
      into v_md5, v_secdef, v_config, v_rettype, v_lang, v_owner, v_acl
      from pg_proc p join pg_language l on l.oid = p.prolang
     where p.oid = v_fn;

    -- 2. the exact body (MD5 VALUES in the header)
    if v_md5 not in ('7e7c1040479aa3f0879cbb1b99911c21',   -- v0.25, as production runs it
                     '36305ed8b76ab2f9607943a18672c907',   -- v0.25, as the files have it
                     '0adee6fd24eb7990eee5c3ac66caa8a9',   -- v0.89, this file
                     '485ce7e077540f5373eec5e6aeab394a')   -- v0.89, without comment-only lines
    then
        raise exception 'v0.89: public.process_webhook_jobs() has an unexpected definition (body md5 %), rebase required; nothing changed', v_md5;
    end if;

    -- 3. attributes, owner, ACL
    if not v_secdef then
        raise exception 'v0.89: public.process_webhook_jobs() is not SECURITY DEFINER; nothing changed';
    end if;
    if v_config is distinct from array['search_path=pg_catalog, extensions, public, net'] then
        raise exception 'v0.89: public.process_webhook_jobs() has proconfig %, expected {search_path=pg_catalog, extensions, public, net}; nothing changed', v_config;
    end if;
    if v_rettype <> 'void'::regtype or v_lang <> 'plpgsql' then
        raise exception 'v0.89: public.process_webhook_jobs() does not return void in plpgsql; nothing changed';
    end if;
    raise notice 'v0.89: applier %, worker owner %', current_user, pg_get_userbyid(v_owner);
    if not pg_has_role(current_user, v_owner, 'USAGE') then
        raise exception 'v0.89: % is neither the owner of public.process_webhook_jobs() (%) nor a member of that role, so it cannot replace it; nothing changed',
            current_user, pg_get_userbyid(v_owner);
    end if;
    if exists (
        select 1 from aclexplode(coalesce(v_acl, acldefault('f', v_owner))) a
        where a.privilege_type = 'EXECUTE'
          and (a.grantee = 0
               or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated')))
    ) then
        raise exception 'v0.89: PUBLIC, anon or authenticated may execute public.process_webhook_jobs() (acl %); nothing changed', v_acl;
    end if;

    -- 4. the environment the new worker reads, and the rollout protocol:
    -- one schedule, paused, nothing running
    if to_regclass('net._http_response') is not null then
        select string_agg(c, ', ' order by c) into v_missing
        from unnest(array['status_code', 'content', 'timed_out', 'error_msg']) c
        where not exists (select 1 from pg_attribute a
                          where a.attrelid = to_regclass('net._http_response')
                            and a.attname = c and a.attnum > 0 and not a.attisdropped);
        if v_missing is not null then
            raise exception 'v0.89: net._http_response lacks %, which the new worker reads; nothing changed', v_missing;
        end if;
    end if;
    if to_regclass('cron.job') is not null then
        select count(*) into v_jobs from cron.job where command ilike '%process_webhook_jobs%';
        if v_jobs <> 1 then
            raise exception 'v0.89: expected exactly one cron job calling process_webhook_jobs, found %; nothing changed', v_jobs;
        end if;
        select jobid, active, username into v_job from cron.job where command ilike '%process_webhook_jobs%';
        if v_job.active then
            raise exception 'v0.89: cron job % (process_webhook_jobs) is active; pause it first (APPLY step 2); nothing changed', v_job.jobid;
        end if;
        if to_regrole(v_job.username) is null
           or not has_function_privilege(v_job.username, v_fn, 'EXECUTE') then
            raise exception 'v0.89: cron job % runs as %, which cannot execute public.process_webhook_jobs(); nothing changed', v_job.jobid, v_job.username;
        end if;
    end if;
    if exists (
        select 1 from pg_stat_activity a
        where a.pid <> pg_backend_pid()
          and a.datname = current_database()
          and a.state = 'active'
          and a.query ilike '%process_webhook_jobs()%'
          and a.query not ilike '%pg_stat_activity%'
    ) then
        raise exception 'v0.89: another session is running process_webhook_jobs(); wait until it ends (APPLY step 3); nothing changed';
    end if;

    -- 5. the backfill fits one transaction
    select count(*) into v_stuck from public.webhook_jobs
     where processed_at is null and attempt_count >= 3 and pg_net_request_id is null;
    if v_stuck > 5000 then
        raise exception 'v0.89: % stuck jobs to backfill, more than 5000; run APPLY step 0''s BF batches first; nothing changed', v_stuck;
    end if;

    -- what E compares with
    perform set_config('v089.before_owner', v_owner::text, true);
    perform set_config('v089.before_acl', coalesce(v_acl::text, 'NULL'), true);
end
$guard$;

-- ── B: the worker ─────────────────────────────────────────────
-- process_webhook_jobs(), v0.89. pg_cron calls it every 30 seconds; each
-- call runs two passes, reconcile then dispatch, as v0.25 did.
--   One call at a time: it first takes a transaction-level advisory lock and
--   returns at once if another call holds it.
--   Pass 1 reconciles pending jobs that have a request id and are older than
--   2 seconds, by coalesce(dispatched_at, enqueued_at), against pg_net's
--   net._http_response row for that request:
--     * no row, or a row with nothing completed (status_code NULL, timed_out
--       not true, error_msg NULL): the request may still be live. After 5
--       minutes this attempt is given up (request id cleared, attempt_count
--       kept, so pass 2 sends a new one); if it was the third, the job is
--       finalized. Under 5 minutes nothing is finalized, even at 3.
--     * 2xx: finalized, last_error NULL.
--     * a transport failure (status_code NULL, timed_out true or error_msg
--       set): a failed attempt, at once, like a non-2xx answer.
--     * any other status: attempt_count + 1; finalized when the new count is
--       3 or more (a second 502 takes it from 3 to 4: the redispatch after
--       the first one was counted too).
--   Pass 2 dispatches pending jobs with no request id and attempt_count < 3
--   (older than 5 seconds, so the alert insert has committed); a raise from
--   net.http_post counts an attempt and finalizes the job at 3.
-- processed_at means FINALIZED, not delivered: see the column comment (C).
-- Attempts per job (by design): a non-2xx answer or a transport failure gives
-- 2 real requests, no answer or a raising http_post gives 3.
-- BEGIN worker
create or replace function public.process_webhook_jobs()
returns void as $$
declare
  v_job record;
  v_url text;
  v_key text;
  v_request_id bigint;
begin
  -- One call at a time: a duplicate schedule or a manual call that overlaps
  -- a running one returns here and dispatches nothing.
  if not pg_try_advisory_xact_lock(hashtextextended('process_webhook_jobs', 0)) then
    return;
  end if;

  -- Read URL + service-role key from supabase_vault. `decrypted_secret` is
  -- only readable by service_role / postgres; the cron worker runs as the
  -- function owner (postgres) so this resolves at runtime.
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'app_supabase_url';
  select decrypted_secret into v_key
  from vault.decrypted_secrets where name = 'app_service_role_key';
  if v_url is null or v_key is null or v_url = '' or v_key = '' then
    raise notice 'process_webhook_jobs: vault secrets app_supabase_url / app_service_role_key not set; skipping';
    return;
  end if;

  -- Pass 1: reconcile dispatched jobs against net._http_response. A job's
  -- age is coalesce(dispatched_at, enqueued_at), so one with a request id
  -- and no dispatched_at is reconciled too.
  for v_job in
    select id, pg_net_request_id, attempt_count, dispatched_at, enqueued_at
    from public.webhook_jobs
    where processed_at is null
      and pg_net_request_id is not null
      and coalesce(dispatched_at, enqueued_at) < now() - interval '2 seconds'
    order by id
    limit 200
  loop
    declare
      v_status int;
      v_body text;
      v_timed_out boolean;
      v_error text;
      v_expired boolean;
    begin
      select status_code, content, timed_out, error_msg
      into v_status, v_body, v_timed_out, v_error
      from net._http_response
      where id = v_job.pg_net_request_id;

      if v_status is null and (coalesce(v_timed_out, false) or v_error is not null) then
        -- pg_net finished the request without an HTTP answer (timed out,
        -- could not connect): a failed attempt, like a non-2xx answer.
        update public.webhook_jobs
          set attempt_count = attempt_count + 1,
              last_error = 'transport failure: ' || left(coalesce(v_error, 'timed out'), 200),
              pg_net_request_id = null,
              dispatched_at = null,
              processed_at = case when attempt_count + 1 >= 3 then now() else processed_at end
          where id = v_job.id;
      elsif v_status is null then
        -- No answer yet (no row, or nothing completed). After 5 minutes give
        -- this attempt up; after the third, give the job up. Never sooner:
        -- the request may still be live.
        v_expired := coalesce(v_job.dispatched_at, v_job.enqueued_at) < now() - interval '5 minutes';
        update public.webhook_jobs
          set pg_net_request_id = case when v_expired then null else pg_net_request_id end,
              processed_at = case when v_expired and attempt_count >= 3 then now() else processed_at end,
              last_error = case when v_expired and attempt_count >= 3
                                then 'gave up: no response from pg_net after 3 attempts'
                                else 'pg_net response not yet available' end
          where id = v_job.id;
      elsif v_status between 200 and 299 then
        update public.webhook_jobs
          set processed_at = now(),
              last_error = null
          where id = v_job.id;
      else
        update public.webhook_jobs
          set attempt_count = attempt_count + 1,
              last_error = 'HTTP ' || v_status::text || ': ' || coalesce(left(v_body, 200), ''),
              -- clear request_id so the next pass can re-dispatch
              pg_net_request_id = null,
              dispatched_at = null,
              processed_at = case when attempt_count + 1 >= 3 then now() else processed_at end
          where id = v_job.id;
      end if;
    exception when others then
      -- Reconcile failure shouldn't poison the loop. Log and move on.
      raise warning 'process_webhook_jobs reconcile (job %): %', v_job.id, sqlerrm;
    end;
  end loop;

  -- Pass 2: dispatch new jobs. enqueued_at < now() - 5s gives the
  -- alert-insert xact time to commit before the cron worker reads.
  for v_job in
    select id, user_id, alert_id, alert_payload
    from public.webhook_jobs
    where processed_at is null
      and pg_net_request_id is null
      and attempt_count < 3
      and enqueued_at < now() - interval '5 seconds'
    order by id
    limit 100
  loop
    begin
      -- iter2 follow-up (Codex bot review on PR #6): pg_net exposes
      -- its request API as `net.http_post`, not `extensions.http_post`.
      -- Calling the wrong schema raises `function does not exist`, which
      -- the EXCEPTION block then silently swallowed — no requests ever
      -- got dispatched. `net` is already in this function's search_path.
      v_request_id := net.http_post(
        url := v_url || '/functions/v1/send-webhook',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_key,
          'X-Internal-Trigger', 'alerts_dispatch_webhook'
        ),
        body := jsonb_build_object(
          'user_id', v_job.user_id,
          'alert', v_job.alert_payload
        ),
        timeout_milliseconds := 5000
      );
      update public.webhook_jobs
        set pg_net_request_id = v_request_id,
            dispatched_at = now(),
            attempt_count = attempt_count + 1,
            last_error = null
        where id = v_job.id;
    exception when others then
      update public.webhook_jobs
        set attempt_count = attempt_count + 1,
            last_error = 'http_post failed: ' || sqlerrm,
            processed_at = case when attempt_count + 1 >= 3 then now() else processed_at end
        where id = v_job.id;
    end;
  end loop;
end;
$$ language plpgsql security definer set search_path = pg_catalog, extensions, public, net;
-- END worker

-- ── C: what processed_at means ────────────────────────────────
comment on column public.webhook_jobs.processed_at is
    'FINALIZED, not delivered (v0.89). NULL while the job is pending: '
    'process_webhook_jobs() may still dispatch or reconcile it, and only a '
    'pending job holds its (user_id, grouping_key) dedup slot. Set once, when '
    'the worker is done with the job. With last_error NULL it was finalized '
    'successfully: send-webhook answered 2xx, which includes its 200 '
    '"skipped" replies (no webhook configured, filtered, deduped). With '
    'last_error set it was finalized with failure: its attempts were used up '
    '(2 requests for non-2xx answers and transport failures, 3 for no answer '
    'or a failed http_post), or the v0.89 backfill finalized it, stuck from '
    'before v0.89.';

-- ── D: backfill the jobs the old worker left stuck ────────────
-- BEGIN backfill
do $backfill$
declare
    v_n bigint;
begin
    update public.webhook_jobs
       set processed_at = now(),
           last_error = 'v0.89 backfill: retries exhausted before v0.89; ' || coalesce(last_error, '')
     where processed_at is null
       and attempt_count >= 3
       and pg_net_request_id is null;
    get diagnostics v_n = row_count;
    raise notice 'v0.89: backfilled % stuck job(s): finalized with failure, nothing re-sent', v_n;
end
$backfill$;
-- END backfill

-- ── E: verification ───────────────────────────────────────────
do $verify$
declare
    v_fn     regprocedure := to_regprocedure('public.process_webhook_jobs()');
    v_md5    text;
    v_stuck  bigint;
begin
    select md5(prosrc) into v_md5 from pg_proc where oid = v_fn;
    if v_md5 is null or v_md5 not in ('0adee6fd24eb7990eee5c3ac66caa8a9', '485ce7e077540f5373eec5e6aeab394a') then
        raise exception 'v0.89: after the replace the worker''s body md5 is %, not this file''s', v_md5;
    end if;
    if not exists (
        select 1 from pg_proc p join pg_language l on l.oid = p.prolang
        where p.oid = v_fn
          and p.prosecdef
          and p.proconfig = array['search_path=pg_catalog, extensions, public, net']
          and p.prorettype = 'void'::regtype
          and l.lanname = 'plpgsql'
          and p.proowner::text = current_setting('v089.before_owner')
          and coalesce(p.proacl::text, 'NULL') = current_setting('v089.before_acl')
    ) then
        raise exception 'v0.89: after the replace the worker''s attributes, owner or ACL differ from before';
    end if;
    if coalesce(col_description('public.webhook_jobs'::regclass,
                                (select attnum from pg_attribute
                                  where attrelid = 'public.webhook_jobs'::regclass
                                    and attname = 'processed_at')), '') not like 'FINALIZED, not delivered (v0.89).%' then
        raise exception 'v0.89: the comment on webhook_jobs.processed_at is missing';
    end if;
    select count(*) into v_stuck from public.webhook_jobs
     where processed_at is null and attempt_count >= 3 and pg_net_request_id is null;
    if v_stuck <> 0 then
        raise exception 'v0.89: % stuck job(s) left after the backfill', v_stuck;
    end if;
    raise notice 'v0.89: worker replaced (body md5 %), owner and ACL unchanged', v_md5;
end
$verify$;

commit;

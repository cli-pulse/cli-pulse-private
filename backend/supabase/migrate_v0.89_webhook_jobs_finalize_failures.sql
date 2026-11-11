-- ============================================================
-- v0.89 — webhook jobs that keep failing are finalized, instead of staying
-- pending forever and silencing that alert's later webhooks
-- Date: 2026-11-12. Plan B1 (two review rounds; PR review: rollout protocol
-- tightened twice). Needs B0 (#756: the queue in the fresh-install baseline)
-- and its production catalog check (done 2026-11-12; its findings are in
-- MD5 VALUES and step 0 below). Applying it is the owner's call, with the
-- APPLY steps.
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
-- A0. A time budget for the whole transaction, set first: on PostgreSQL 17
--    and later (production runs 17), transaction_timeout = 2s, counted from
--    the moment it is set. When it runs out the server ends the session and
--    the transaction rolls back: nothing is changed. On older servers, which
--    have no transaction_timeout, statement_timeout = 2s instead, which is a
--    limit PER STATEMENT, not for the whole transaction. The budget limits
--    how long the apply can block the queue: while it holds the queue lock,
--    alert uploads wait (THE QUEUE LOCK AND ALERT UPLOADS). The helpers
--    upload through helper_sync as anon, statement_timeout 3 s in
--    production; the apps' evaluate_budget_alerts runs as authenticated, 8 s
--    (role settings read 2026-11-12; APPLY Q2b reads them). 2 s keeps the
--    block under anon's timeout, but an upload's timeout also counts its own
--    work before and after the wait, so one already well into its 3 s can
--    still time out while it waits. lock_timeout = 1s for each lock wait (A5c,
--    A5d, and CREATE OR REPLACE behind a session holding the worker's
--    catalog row), so a wait ends in a readable refusal inside the budget.
--    And application_name =
--    'v0_89_webhook_jobs_finalize_failures', set LOCAL, so the session is
--    named in pg_stat_activity until the transaction ends (a query text is
--    cut at track_activity_query_size, and a client may strip the comments
--    that would name it). All three are LOCAL: they end with the transaction.
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
--       postgres; the applier and the owner are logged in a NOTICE); its ACL
--       grants EXECUTE to none of PUBLIC, anon, authenticated.
--    4. net._http_response, where it exists, has the columns the new
--       worker reads (status_code, content, timed_out, error_msg; pg_net
--       0.20 has them). Where pg_cron's cron.job exists: exactly one job
--       whose command names process_webhook_jobs (a second schedule would be
--       a second caller), that job is paused (active = false; APPLY step 2),
--       and its user can execute the worker.
--    5. exclusive access to the queue, in this order:
--       a. no other active session in this database runs a query naming
--          process_webhook_jobs (pg_stat_activity; a query on
--          pg_stat_activity itself does not count). A fast, readable refusal
--          for the usual case, a cron run in flight; not the authority.
--       b. no session in this database that is idle in an open transaction
--          holds a lock on public.webhook_jobs (pg_stat_activity joined to
--          pg_locks): it may already have run the worker and not committed.
--          Idle transactions that never touched the queue do not matter.
--       c. it takes the worker's own advisory lock,
--          pg_advisory_xact_lock(hashtextextended('process_webhook_jobs', 0)),
--          and holds it to commit. A v0.89 worker call takes it with a
--          try-lock, so during a re-run it returns at once and does nothing;
--          a v0.89 call already running makes the apply wait (at most
--          lock_timeout, then it refuses).
--       d. it takes LOCK public.webhook_jobs IN EXCLUSIVE MODE and holds it
--          to commit: every open transaction that wrote the queue makes the
--          apply wait (at most lock_timeout, then it refuses), and a caller
--          that starts during the apply waits for the commit before it can
--          write the queue. Plain reads go on; writers, alert inserts
--          included, wait (see THE QUEUE LOCK AND ALERT UPLOADS).
--       e. no other session holds any lock on public.webhook_jobs
--          (pg_locks): no open transaction that has read the queue. This
--          check and the locks of c and d are the synchronisation; a and b
--          only give a clearer refusal. pg_locks needs no privilege: it
--          shows every session's locks to every role.
--       Visibility: (a) and (b) read other sessions' query and state from
--       pg_stat_activity, which shows them only to a superuser, a member of
--       pg_read_all_stats, or the session's own role; postgres on Supabase
--       sees every session in the database. A session the applier cannot see
--       has query '<insufficient privilege>' and state NULL: the NOTICE
--       counts them, and (d) and (e) still cover whatever they do to the
--       queue.
--    6. at most 5000 jobs need the backfill in D, counted under the lock of
--       5d (one transaction holds its row locks until commit; above that,
--       batch first: APPLY step 4).
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
--      for 5 minutes (attempt_count >= 3).
--    Attempts per job, unchanged by design: a non-2xx answer or a transport
--    failure gives 2 real requests (the counter also counts the redispatch);
--    no answer, or a raising http_post, gives 3.
--    What it does NOT guarantee (inherited from v0.25, unchanged here):
--    * "5 minutes without an answer" is an abandonment policy, not proof the
--      request is gone: pg_net may still hold or send it, so a late delivery
--      after a redispatch can send a webhook twice, and a job finalized as
--      'gave up' may in fact have been delivered;
--    * with a vault secret missing or empty the worker returns before either
--      pass, so nothing is reconciled, dispatched or finalized, and jobs stay
--      pending (APPLY Q2 checks the secrets);
--    * an error while reconciling a row is logged as a WARNING and that row
--      stays pending until the error stops; and each call reconciles at most
--      200 jobs and dispatches at most 100, so a backlog drains over calls.
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
--    NOTICEs give the applier, the owner, the number backfilled, and how
--    long the queue lock has been held (from A5d to the end of E).
-- Not changed: the table, its indexes and policy, the enqueue trigger, the
-- cron schedule, send-webhook.
--
-- ── THE QUEUE LOCK AND ALERT UPLOADS ─────────────────────────
-- Every new alert row fires alerts_enqueue_webhook, which reads and writes
-- webhook_jobs inside the inserting transaction. From A5d to its end the
-- apply holds EXCLUSIVE on the queue, so an alert insert in that time WAITS
-- (and so does one queued behind A5d's own wait for the lock):
--   * when the apply commits, the insert goes on, and its webhook job is
--     enqueued as usual (the trigger sees the committed queue);
--   * when the apply aborts (a refusal, a lock wait past lock_timeout, the
--     budget of A0 running out), the insert goes on the same way;
--   so the apply itself never loses an insert. How long the apply can block
--   it is the budget: on PostgreSQL 17, at most transaction_timeout from A0
--   (2 s). That bounds the block, not the upload (next point). The time the
--   lock is actually held is printed in a NOTICE (from A5d to the end of
--   verification; the commit follows) and was measured in the test suite
--   with a queue at the size guard's limit plus thousands of finalized rows:
--   a small fraction of the budget there.
--   Production's own number is that NOTICE.
--   * An upload can still time out in that window: its OWN statement_timeout
--     (the API role's; APPLY Q2b reads them) counts the wait together with
--     the rest of its work. It is then cancelled, and its whole statement
--     rolls back, the alert row with its job. Who inserts alerts, and what
--     then happens:
--     - helper_sync, called by the macOS helper (HelperDaemon) and by the
--       Python Companion with the anon key, so as role anon. The RPC fails;
--       neither helper keeps a queue of alerts: each cycle computes them
--       again from the current state (AlertGenerator in the macOS helper,
--       collect_alerts in the Python one), and the next cycle's helper_sync
--       sends them again. An alert whose condition still holds
--       then arrives (and is enqueued then); one whose condition has already
--       cleared is not sent again: that transient alert is lost.
--     - evaluate_budget_alerts, called best-effort by the Apple apps
--       (DataRefreshManager) and the Android app (DashboardRepository) as
--       the signed-in user (authenticated): the failure is ignored, and the
--       next refresh evaluates again; it creates an alert only when none
--       with that suppression key exists, so a still-exceeded budget gets
--       its alert then.
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
-- Every Q query is read-only and returns counts, hashes and booleans only:
-- never a row's contents, a secret, a function body or a timestamp. The
-- exceptions are labelled: Q2b (role settings), the catalog file (metadata)
-- and R0 (the function definition, kept privately). Run each in its own
-- statement (Supabase MCP execute_sql), and keep every answer.
-- PRECONDITION for the whole window, from step 2 until step 7 has drained:
-- nothing but the paused cron job calls the worker. No manual call, no
-- service_role client, no second schedule. A call that starts anyway during
-- the apply waits for its commit and then runs the OLD body it started with,
-- which can leave a job stuck again; steps 7 and 8 catch and repair that,
-- but the precondition is what keeps it from happening.
-- 0. Before the window, read-only.
--    Q0: select md5(p.prosrc) as body_md5, (select count(*) from pg_proc where proname = 'process_webhook_jobs') as same_name, (p.prosecdef and p.proconfig = array['search_path=pg_catalog, extensions, public, net'] and p.prorettype = 'void'::regtype) as attrs_ok, pg_has_role(current_user, p.proowner, 'USAGE') as applier_can_replace, not (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE')) as anon_auth_denied, md5(coalesce(p.proacl::text, '')) as acl_md5, (select md5(col_description(a.attrelid, a.attnum)) from pg_attribute a where a.attrelid = 'public.webhook_jobs'::regclass and a.attname = 'processed_at') as comment_md5 from pg_proc p where p.oid = 'public.process_webhook_jobs()'::regprocedure;
--    FIRST APPLY: expect body_md5 = 7e7c1040479aa3f0879cbb1b99911c21,
--    same_name = 1, attrs_ok, applier_can_replace and anon_auth_denied true,
--    acl_md5 = db23e67d6fad77fdfa003856d807d6af (production's
--    {postgres=X/postgres,service_role=X/postgres}), comment_md5 NULL.
--    RE-RUN OR RECOVERY: body_md5 = 0adee6fd24eb7990eee5c3ac66caa8a9 or
--    485ce7e077540f5373eec5e6aeab394a (v0.89 is already in), comment_md5 =
--    0c90c99eb47d4deedf654a2aa8375cb0, the rest as above. The migration
--    accepts all four bodies in MD5 VALUES; seeing a v0.89 value before a
--    first apply means it is already applied: verify (step 8) instead.
--    Any other body_md5: STOP (production runs a body this file was not
--    written against).
--    Q1: select count(*) total, count(*) filter (where processed_at is null) pending, count(*) filter (where processed_at is null and attempt_count >= 3 and pg_net_request_id is null) stuck, count(*) filter (where processed_at is null and pg_net_request_id is not null) awaiting, count(*) filter (where pg_net_request_id is not null and dispatched_at is null) malformed_id_without_dispatch, count(*) filter (where processed_at is null and pg_net_request_id is null and attempt_count = 0 and enqueued_at < now() - interval '1 hour') never_dispatched_old, count(*) filter (where processed_at is not null and pg_net_request_id is not null) finalized_with_request_id, count(*) filter (where attempt_count < 0 or attempt_count > 10) odd_counts from public.webhook_jobs;
--    Q1b: select attempt_count, count(*) from public.webhook_jobs where processed_at is null group by 1 order by 1;
--    Q1's stuck is PRELIMINARY sizing only; the number the apply is checked
--    against is step 4's recount.
--    Secrets, each exactly once and non-empty, without selecting a value:
--    Q2: select n.name, count(s.name) as copies, count(*) filter (where s.decrypted_secret is not null and s.decrypted_secret <> '') as non_empty from (values ('app_supabase_url'),('app_service_role_key')) n(name) left join vault.decrypted_secrets s on s.name = n.name group by n.name;
--    Expect copies = 1 and non_empty = 1 for both; otherwise STOP (nothing
--    dispatches).
--    Role settings (config values, not data): how long an alert upload
--    waits on the queue lock before it gives up (THE QUEUE LOCK AND ALERT
--    UPLOADS):
--    Q2b: select rolname, coalesce((select substr(c, 19) from unnest(rolconfig) c where c like 'statement_timeout=%'), '(database default)') as statement_timeout, coalesce((select substr(c, 14) from unnest(rolconfig) c where c like 'lock_timeout=%'), '(database default)') as lock_timeout from pg_roles where rolname in ('anon', 'authenticated', 'authenticator', 'service_role') order by rolname;
--    On 2026-11-12: anon statement_timeout 3s (the helpers' helper_sync),
--    authenticated 8s (the apps' evaluate_budget_alerts), authenticator
--    (PostgREST's login role) 8s with lock_timeout 8s; service_role is not
--    an alert upload path. The budget of A0 (2 s) must stay below anon's and
--    authenticated's statement_timeout: if either now reads 2 s or less,
--    STOP and lower the budget in this file first.
--    Q3: select count(*) as jobs, string_agg(active::text, ',' order by jobid) as active, md5(string_agg(jobid || '|' || coalesce(jobname, '') || '|' || schedule || '|' || command || '|' || username, ',' order by jobid)) as job_md5 from cron.job where command ilike '%process_webhook_jobs%';
--    Expect jobs = 1 (more is a duplicate schedule: STOP). On 2026-11-12:
--    active true, job_md5 = 83e638ff8913d9c58a400d46a084b26d (jobid 3,
--    process_webhook_jobs, '30 seconds', 'select public.process_webhook_jobs()',
--    postgres).
--    Q3b: select d.status, count(*) from cron.job_run_details d join cron.job j on j.jobid = d.jobid where j.command ilike '%process_webhook_jobs%' and d.start_time > now() - interval '24 hours' group by d.status order by d.status;
--    Metadata, not counts: backend/supabase/ops/check_webhook_catalog.sql
--    (owners, ACLs, attributes, the cron row; no row contents, no bodies).
--    Diff it with B0's 2026-11-12 output: only the body md5s and the
--    Supabase-default ACL entries may differ, as recorded then.
--    ROLLBACK SOURCE, keep privately (not in logs, tickets or the PR; it is
--    the whole function definition):
--    R0: select pg_get_functiondef('public.process_webhook_jobs()'::regprocedure);
--    If Q1's stuck is over 5000, run BF now, each run its own statement (its
--    own committed transaction), until Q1's stuck is 5000 or less. BF touches
--    only jobs the worker never selects, so it needs no pause, and it
--    resumes safely if interrupted:
--    BF: update public.webhook_jobs set processed_at = now(), last_error = 'v0.89 backfill: retries exhausted before v0.89; ' || coalesce(last_error, '') where id in (select id from public.webhook_jobs where processed_at is null and attempt_count >= 3 and pg_net_request_id is null order by id limit 1000);
-- 1. RECORD the job's active value from Q3 (true on 2026-11-12). Every
--    restore below puts back exactly this value, whatever happens.
-- 2. Pause the job. pg_cron's signature is cron.alter_job(job_id bigint,
--    schedule text default null, command text default null, database text
--    default null, username text default null, active boolean default
--    null), so the id is passed by position; expect exactly one row:
--    P2: select cron.alter_job(jobid, active := false) from cron.job where command ilike '%process_webhook_jobs%';
--    Last resort, only if that function is not available to the role:
--    `update cron.job set active = false where jobid = <that jobid>;` (Q3's jobid)
--    Q3 again: active false. (If the recorded value was already false, P2
--    changes nothing.)
-- 3. Quiesce, with the PRECONDITION above in force. Repeat every few
--    seconds until Q4's running, idle_holding_queue and queue_lock_holders
--    are 0 and Q4b is 0:
--    Q4: select (select count(*) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'active' and query ilike '%process_webhook_jobs%' and query not ilike '%pg_stat_activity%') as running, (select count(distinct a.pid) from pg_stat_activity a join pg_locks l on l.pid = a.pid where a.pid <> pg_backend_pid() and a.datname = current_database() and a.state like 'idle in transaction%' and l.locktype = 'relation' and l.database = (select oid from pg_database where datname = current_database()) and l.relation = 'public.webhook_jobs'::regclass) as idle_holding_queue, (select count(distinct pid) from pg_locks where pid <> pg_backend_pid() and granted and locktype = 'relation' and database = (select oid from pg_database where datname = current_database()) and relation = 'public.webhook_jobs'::regclass) as queue_lock_holders, (select count(*) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query = '<insufficient privilege>') as invisible;
--    Q4b: select count(*) as recent_unfinished from cron.job_run_details d join cron.job j on j.jobid = d.jobid where j.command ilike '%process_webhook_jobs%' and d.status in ('running', 'starting') and d.start_time > now() - interval '10 minutes';
--    queue_lock_holders is the authority (pg_locks, no privilege needed).
--    invisible is information, not a blocker: running only covers sessions
--    the applier can see, and pg_locks covers what the others do to the
--    queue. Idle transactions that never touched the queue do not count. A
--    'running' or 'starting' cron row older than 10 minutes with no live
--    backend is a leftover from a crash or restart: note it, do not wait on
--    it. queue_lock_holders may blink to 1 while an alert insert commits;
--    wait for 0.
-- 4. Recount, immediately before the apply (this is the number that
--    counts; the job is paused and quiesced, so it no longer moves):
--    Q5: select count(*) as stuck from public.webhook_jobs where processed_at is null and attempt_count >= 3 and pg_net_request_id is null;
--    If it is over 5000: run BF (step 0) until Q5 is 5000 or less. The job
--    stays paused and the value recorded in step 1 stays the one to restore;
--    then repeat steps 3 and 4. Call the final Q5 answer N.
-- 5. Apply this file as it stands, byte for byte, with the Supabase MCP's
--    `apply_migration` under the name `v0_89_webhook_jobs_finalize_failures`.
--    Record the md5 of the text sent next to this file's.
-- 6. Read the outcome:
--    a. it reports success: go to step 7.
--    b. it reports an ERROR (a refusal, a lock timeout, anything): the whole
--       transaction rolled back; nothing changed. Confirm: Q0 as in step 0,
--       Q5 = N. Then either fix the cause and go back to step 3, or ABORT.
--    c. no clear answer (client timeout, lost connection; also what the
--       budget of A0 running out looks like on PostgreSQL 17: the server
--       ends the session, "terminating connection due to transaction
--       timeout"): the transaction may still be running, and may yet
--       commit; an old body_md5 seen from another session meanwhile proves
--       nothing. Do not retry and do not restore. First wait until it has
--       ended, repeating every few seconds until both columns are 0. The
--       apply's session carries application_name
--       v0_89_webhook_jobs_finalize_failures until its transaction ends, and
--       from A5c to its end it holds the worker's advisory lock (with the job
--       paused, nothing else does):
--       Q6: select (select count(*) from pg_locks where pid <> pg_backend_pid() and locktype = 'advisory' and database = (select oid from pg_database where datname = current_database()) and objsubid = 1 and classid = ((hashtextextended('process_webhook_jobs', 0) >> 32) & 4294967295)::oid and objid = (hashtextextended('process_webhook_jobs', 0) & 4294967295)::oid) as worker_lock, (select count(*) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and application_name = 'v0_89_webhook_jobs_finalize_failures') as apply_sessions;
--       Then decide from Q0 and Q5:
--       - body_md5 one of the two v0.89 values, acl_md5 as in step 0,
--         comment_md5 0c90c99eb47d4deedf654a2aa8375cb0: it committed. Go to
--         step 7 (the NOTICEs are lost; N is the number backfilled).
--       - body_md5 and comment_md5 exactly as in step 0 and Q5 = N: it
--         rolled back. Continue as in b.
--       - anything else: STOP with the job paused, and investigate.
--    ABORT (from b or c): restore the value recorded in step 1 with R9, run
--    Q3 and see it. Nothing else to undo.
-- 7. Drain after the commit, with the job still paused: repeat Q6 and Q4
--    until Q6 is 0 and 0 and Q4's running and queue_lock_holders are 0. A
--    worker call that broke the precondition and waited on the queue lock
--    runs now, with the old body; this step waits until it has finished,
--    so that step 8's Q5 sees what it did.
-- 8. Verify, read-only, with the job still paused: Q0: body_md5 one of the
--    two v0.89 values, comment_md5 0c90c99eb47d4deedf654a2aa8375cb0, every
--    other column as in step 0. Q5 = 0; if not, an old-body call ran during
--    the window (against the precondition): run BF until Q5 = 0. Q3: jobs =
--    1, job_md5 as in step 0, active false. The migration's NOTICE
--    "backfilled N" equals step 4's N, and its NOTICE "the queue lock was
--    held ... ms" is production's hold time.
-- 9. Restore the value recorded in step 1 (put it in place of
--    <recorded active>), then run Q3 and see it:
--    R9: select cron.alter_job(jobid, active := <recorded active>) from cron.job where command ilike '%process_webhook_jobs%';
-- 10. Over the next hours, read-only: Q5 must stay 0, and
--    Q9: select count(*) as pending_over_1_day from public.webhook_jobs where processed_at is null and enqueued_at < now() - interval '1 day';
--    should trend to 0 (that also needs the secrets and enough worker
--    throughput, which v0.89 does not change). No WARNING from
--    process_webhook_jobs in the Postgres log.
--
-- ROLLBACK: steps 1 to 3, then re-apply the definition R0 saved; Q0 then
-- shows step 0's body_md5 (comment_md5 stays: the comment remains true of the
-- rows v0.89 finalized); then step 9. The backfill is NOT undone: the jobs it
-- finalized stay finalized (they were unrecoverable, and the prefix is not a
-- restoration record). Undoing it exactly would need its own plan with
-- captured ids and original values, built never to delete newer pending jobs.
--
-- Tested by backend/supabase/tests/run_v089_webhook_jobs_finalize_tests.sh
-- (CI job "Webhook jobs finalize failures (v0.89)").
-- ============================================================

begin;
-- A0: each lock wait, the session's name, and the budget for the whole apply
set local lock_timeout = '1s';
set local application_name = 'v0_89_webhook_jobs_finalize_failures';
do $budget$
begin
    if current_setting('server_version_num')::int >= 170000 then
        -- the whole transaction, from here: the server ends the session at
        -- 2 s, which bounds how long the apply can block the queue (header A0)
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
    v_fn        regprocedure := to_regprocedure('public.process_webhook_jobs()');
    v_md5       text;
    v_secdef    boolean;
    v_config    text[];
    v_rettype   oid;
    v_lang      name;
    v_owner     oid;
    v_acl       aclitem[];
    v_jobs      bigint;
    v_job       record;
    v_stuck     bigint;
    v_missing   text;
    v_n         bigint;
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

    -- 4. the environment the new worker reads; one schedule, paused
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

    -- 5. exclusive access to the queue (header A5)
    -- a. a readable refusal for the usual case (not the authority)
    if exists (
        select 1 from pg_stat_activity a
        where a.pid <> pg_backend_pid()
          and a.datname = current_database()
          and a.state = 'active'
          and a.query ilike '%process_webhook_jobs%'
          and a.query not ilike '%pg_stat_activity%'
    ) then
        raise exception 'v0.89: another session is running a query that names process_webhook_jobs; wait until it ends (APPLY step 3); nothing changed';
    end if;
    -- b. an idle open transaction that touched the queue may have run the worker
    select count(distinct a.pid) into v_n
      from pg_stat_activity a join pg_locks l on l.pid = a.pid
     where a.pid <> pg_backend_pid()
       and a.datname = current_database()
       and a.state like 'idle in transaction%'
       and l.locktype = 'relation'
       and l.database = (select oid from pg_database where datname = current_database())
       and l.relation = 'public.webhook_jobs'::regclass;
    if v_n > 0 then
        raise exception 'v0.89: % session(s) idle in an open transaction hold a lock on public.webhook_jobs (one may have run the worker); end them first (APPLY step 3); nothing changed', v_n;
    end if;
    -- c. the worker's own lock: v0.89 worker calls try-lock it and return at
    -- once while we hold it; a v0.89 call already running makes us wait
    begin
        perform pg_advisory_xact_lock(hashtextextended('process_webhook_jobs', 0));
    exception when lock_not_available then
        raise exception 'v0.89: another session held the worker''s advisory lock (a v0.89 worker run) for longer than lock_timeout; nothing changed';
    end;
    -- d. writers of the queue: open ones make us wait, new ones wait for us
    begin
        lock table public.webhook_jobs in exclusive mode;
    exception when lock_not_available then
        raise exception 'v0.89: another session held a write lock on public.webhook_jobs (an open transaction that wrote the queue) for longer than lock_timeout; nothing changed';
    end;
    perform set_config('v089.locked_at', clock_timestamp()::text, true);
    -- e. the authority: nobody else holds any lock on the queue
    select count(distinct l.pid) into v_n from pg_locks l
     where l.pid <> pg_backend_pid()
       and l.granted
       and l.locktype = 'relation'
       and l.database = (select oid from pg_database where datname = current_database())
       and l.relation = 'public.webhook_jobs'::regclass;
    if v_n > 0 then
        raise exception 'v0.89: % other session(s) hold a lock on public.webhook_jobs (an open transaction that read the queue); end them first (APPLY step 3); nothing changed', v_n;
    end if;
    select count(*) into v_n from pg_stat_activity a
     where a.pid <> pg_backend_pid()
       and a.datname = current_database()
       and a.query = '<insufficient privilege>';
    if v_n > 0 then
        raise notice 'v0.89: % session(s) in this database are not visible to %; the queue lock (5d, 5e) covers what they do to the queue', v_n, current_user;
    end if;

    -- 6. the backfill fits one transaction (counted under the lock)
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
--   returns at once if another call (or this migration, A5c) holds it.
--   Pass 1 reconciles pending jobs that have a request id and are older than
--   2 seconds, by coalesce(dispatched_at, enqueued_at), against pg_net's
--   net._http_response row for that request:
--     * no row, or a row with nothing completed (status_code NULL, timed_out
--       not true, error_msg NULL): the request may still be live. After 5
--       minutes this attempt is abandoned (request id cleared, attempt_count
--       kept, so pass 2 sends a new one); if it was the third, the job is
--       finalized. Under 5 minutes nothing is finalized, even at 3. Five
--       minutes is a policy, not proof the request is gone (header B).
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
-- Inherited limits (header B): missing vault secrets stop both passes, a row
-- whose reconcile raises stays pending, and each call handles at most 200
-- reconciles and 100 dispatches.
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
    raise notice 'v0.89: the queue lock was held % ms so far (from A5d to the end of verification; the commit follows)',
        round(extract(epoch from clock_timestamp() - current_setting('v089.locked_at')::timestamptz) * 1000);
end
$verify$;

commit;

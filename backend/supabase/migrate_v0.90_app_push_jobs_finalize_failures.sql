-- ============================================================
-- v0.90 — app-push jobs that keep failing are finalized, instead of staying
-- pending until their approval request is deleted
-- Date: 2026-11-12. Plan B1b (two review rounds). The app-push twin of v0.89
-- (the webhook queue): the same defect in the same state machine, fixed the
-- same way, with v0.89's guards and APPLY protocol. Its own approval:
-- applying it is the owner's call, with the APPLY steps. Production's
-- definition of the worker and its cron job were read on 2026-11-12 (MD5
-- VALUES and step 0 below).
--
-- ── WHY ───────────────────────────────────────────────────────
-- The worker (public.process_app_push_jobs, v0.32; nothing later redefines
-- it, v0.77 only revoked the table's grants) never sets processed_at when a
-- delivery fails. The insert trigger on remote_permission_requests
-- (remote_request_after_insert_push, v0.32) sends the push at once and writes
-- attempt_count = 1. The worker runs two passes per call, reconcile and then
-- dispatch, so when send-approval-push answers 502: next call, reconcile to 2
-- and redispatch in the same call (3); next call, reconcile to 4. Dispatch
-- only takes attempt_count < 3, so nothing looks at the job again: two real
-- requests, then pending. Three requests pg_net never answers end the same
-- way at 3, and so does a retry whose http_post raises at 3.
-- Such a job is never finalized. It stays pending until the nightly remote
-- retention (remote_retention_cleanup_nightly, v0.28) deletes its approval
-- request, and the job with it (ON DELETE CASCADE). That run first marks
-- still-pending approval requests 'expired' once they are an hour past
-- their expires_at, then deletes only requests that are not pending and are
-- older than 30 days; so the job goes about 30 days after its request was
-- created. Until then processed_at gives no answer to "is the worker done
-- with it". Its slot in idx_app_push_jobs_pending_dedup (request_id,
-- while pending) only blocks a second job for the same approval request,
-- which the trigger never makes (one job per request): no later push is
-- silenced by it.
-- Also: pg_net records a finished transport failure (timeout, could not
-- connect) as a response row with status_code NULL and timed_out or error_msg
-- set; v0.32 read that as "no answer yet" and waited 5 minutes before the
-- retry, by when an approval request with the default 5-minute lifetime has
-- expired. And a job with a request id but no dispatched_at was never
-- reconciled at all (no code path writes one; APPLY Q1 counts them).
--
-- ── WHAT THIS DOES (one transaction) ──────────────────────────
-- A0. A time budget for the whole transaction, set first: on PostgreSQL 17
--    and later (production runs 17), transaction_timeout = 2s, counted from
--    the moment it is set. When it runs out the server ends the session and
--    the transaction rolls back: nothing is changed. On older servers, which
--    have no transaction_timeout, statement_timeout = 2s instead, which is a
--    limit PER STATEMENT, not for the whole transaction. The budget limits
--    how long the apply can block the queue: while it holds the queue lock,
--    every writer of public.app_push_jobs waits (THE QUEUE LOCK AND ITS
--    WRITERS). The call that creates jobs (the helpers'
--    remote_helper_create_permission_request) runs as anon,
--    statement_timeout 3 s in production; delete_user_account runs as
--    authenticated, 8 s (role settings read 2026-11-12; APPLY Q2b reads
--    them). 2 s keeps the block under anon's timeout, but a call's timeout
--    also counts its own work before and after the wait, so one already
--    well into its 3 s can still time out while it waits. lock_timeout = 1s
--    for each lock wait (A5c, A5d, and CREATE OR REPLACE behind a session
--    holding the worker's catalog row), so a wait ends in a readable
--    refusal inside the budget. And
--    application_name = 'v0_90_app_push_jobs_finalize_failures', set LOCAL,
--    so the session is named in pg_stat_activity until the transaction ends
--    (a query text is cut at track_activity_query_size, and a client may
--    strip the comments that would name it). All three are LOCAL: they end
--    with the transaction.
-- A. Refuses, and changes nothing, unless all of this holds:
--    1. public.app_push_jobs exists; the trigger
--       remote_permission_requests_after_insert_push on
--       public.remote_permission_requests is enabled and calls
--       remote_request_after_insert_push(); that table has the columns the
--       new worker writes (notification_attempts, notification_last_error);
--       exactly one function is named process_app_push_jobs, in any schema,
--       and it is public.process_app_push_jobs().
--    2. the worker's body (md5 of prosrc) is one of the four in MD5 VALUES:
--       v0.32's, as production runs it or as the file has it, or this
--       file's (a re-run). Anything else: "unexpected definition, rebase
--       required".
--    3. checked separately: SECURITY DEFINER; proconfig exactly
--       {search_path=pg_catalog, extensions, public, net}; returns void;
--       plpgsql; the applier may replace it: pg_has_role(current_user,
--       owner, 'USAGE'), i.e. it is the owner or a member of the owner role,
--       which is what CREATE OR REPLACE needs (production's owner is
--       postgres; the applier and the owner are logged in a NOTICE); its ACL
--       grants EXECUTE to none of PUBLIC, anon, authenticated, and neither
--       anon nor authenticated can execute it in effect either
--       (has_function_privilege: no grant reaches them through a role they
--       inherit, as APPLY Q0 also checks).
--    4. net._http_response, where it exists, has the columns the new
--       worker reads (status_code, timed_out, error_msg; pg_net 0.20 has
--       them). Where pg_cron's cron.job exists: exactly one job whose command
--       names process_app_push_jobs (a second schedule would be a second
--       caller), exactly one job named app_push_jobs_drain (v0.32's name),
--       and they are the same job (a renamed job, or the name on another
--       command, refuses); that job is paused (active = false; APPLY step
--       2), and its user can execute the worker.
--    5. exclusive access to the queue, in this order:
--       a. no other active session in this database runs a query naming
--          process_app_push_jobs (pg_stat_activity; a query on
--          pg_stat_activity itself does not count). A fast, readable refusal
--          for the usual case, a cron run in flight; not the authority.
--       b. no session in this database that is idle in an open transaction
--          holds a lock on public.app_push_jobs (pg_stat_activity joined to
--          pg_locks): it may already have run the worker and not committed.
--          Idle transactions that never touched the queue do not matter.
--       c. it takes the worker's own advisory lock,
--          pg_advisory_xact_lock(hashtextextended('process_app_push_jobs', 0)),
--          and holds it to commit. A v0.90 worker call takes it with a
--          try-lock, so during a re-run it returns at once and does nothing;
--          a v0.90 call already running makes the apply wait (at most
--          lock_timeout, then it refuses).
--       d. it takes LOCK public.app_push_jobs IN EXCLUSIVE MODE and holds it
--          to commit: every open transaction that wrote the queue makes the
--          apply wait (at most lock_timeout, then it refuses), and a writer
--          that starts during the apply waits for the commit before it can
--          write the queue. Plain reads go on; writers wait (see THE QUEUE
--          LOCK AND ITS WRITERS).
--       e. no other session holds any lock on public.app_push_jobs
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
--      non-2xx answer, and recorded on the approval request like one:
--      notification_attempts + 1, notification_last_error = 'edge transport:
--      <pg_net error_msg, or timed out>' (a non-2xx answer keeps writing
--      'edge HTTP <status>', as in v0.32);
--    * a failed attempt finalizes the job (processed_at = now(), last_error
--      kept) when attempt_count reaches 3: after a non-2xx answer or a
--      transport failure (attempt_count + 1 >= 3), after a raise from
--      net.http_post (the same), and when the third request has had no
--      answer for 5 minutes (attempt_count >= 3). Finalizing writes nothing
--      on the approval request.
--    Attempts per job, unchanged by design: attempt_count counts the
--    trigger's request, each retry, each failed answer and each failed
--    http_post, so a non-2xx answer or a transport failure gives 2 real
--    requests (the trigger's and one retry) and no answer gives 3. The
--    approval request's notification_attempts moves with it, as in v0.32
--    (a failed http_post is not counted there). A transport failure now
--    leads to its retry within one worker call (30 s) instead of after 5
--    minutes, and to 2 requests instead of 3. Nothing else sends more or
--    sooner than v0.32 did, except for a job with a request id but no
--    dispatched_at, which v0.32 never read (no code path writes one; APPLY
--    Q1 must find none).
--    What it does NOT guarantee (inherited from v0.32, unchanged here):
--    * "5 minutes without an answer" is an abandonment policy, not proof the
--      request is gone: pg_net may still hold or send it, so a late delivery
--      after a retry can push twice, and a job finalized as 'gave up' may in
--      fact have been delivered;
--    * with a vault secret missing or empty the worker returns before either
--      pass, so nothing is reconciled, dispatched or finalized, and jobs stay
--      pending (APPLY Q2 checks the secrets);
--    * an error while reconciling a row is logged as a WARNING and that row
--      stays pending until the error stops; and each call reconciles at most
--      200 jobs and dispatches at most 100, so a backlog drains over calls;
--    * when net.http_post raises inside the trigger, the trigger's own
--      exception handler rolls back its job row too, so that approval
--      request has no job for this worker to retry;
--    * the worker never checks the approval request's status, so a retry
--      can push for a request that is already decided or expired; and a
--      transport failure now gets its retry within about 30 s (one worker
--      call) instead of v0.32's 5 minutes.
-- C. Says what processed_at means, on the column: FINALIZED, not delivered.
--    processed_at set and last_error NULL: finalized successfully (a 2xx
--    answer from send-approval-push, which it also gives when it sent
--    nothing: remote control off, no push token, APNs not configured; and
--    when every APNs send failed, which it records on the approval request).
--    processed_at set and last_error set: finalized with failure. No outcome
--    column is added.
-- D. Backfill: finalizes the jobs the old worker left stuck, and only those:
--    processed_at NULL, attempt_count >= 3 and no request id (the old worker
--    selects them in neither pass). last_error gets the prefix
--    'v0.90 backfill: retries exhausted before v0.90; '. Jobs with a request
--    id are left to the new worker. Nothing is re-sent: their approval
--    requests are old.
--    public.remote_permission_requests is deliberately NOT modified by the
--    backfill. Its notification_attempts and notification_last_error already
--    recorded each failure during the earlier reconciliations (v0.32's
--    worker writes them on every non-2xx answer); finalizing
--    app_push_jobs.processed_at only clears the pending state and the
--    pending dedup index, and does not rewrite the approval request's audit
--    history.
-- E. Verifies: the body is this file's, the attributes, owner and ACL are
--    what they were, the column comment is there, and no stuck job is left.
--    NOTICEs give the applier, the owner, the number backfilled, and how
--    long the queue lock has been held (from A5d to the end of E).
-- Not changed: the table, its indexes and policy, the trigger and its
-- function, the cron schedule (app_push_jobs_drain, every 30 seconds),
-- send-approval-push. On remote_permission_requests the new worker writes
-- what v0.32's wrote, plus the transport-failure line in B; the backfill
-- writes nothing there (D).
--
-- ── THE QUEUE LOCK AND ITS WRITERS ───────────────────────────
-- From A5d to its end the apply holds EXCLUSIVE on public.app_push_jobs, so
-- every statement that writes the queue in that time WAITS (and so does one
-- queued behind A5d's own wait for the lock). When the apply commits or
-- aborts (a refusal, a lock wait past lock_timeout, the budget of A0 running
-- out), the writer goes on as usual, so the apply itself never loses a
-- write. How long the apply can block it is the budget: on PostgreSQL 17, at
-- most transaction_timeout from A0 (2 s). That bounds the block, not the
-- writer (below). The time the lock is actually held is printed in a NOTICE
-- (from A5d to the end of verification; the commit follows) and was
-- measured in the test suite with a queue at the size guard's limit plus
-- thousands of finalized rows: a small fraction of the budget there.
-- Production's own number is that NOTICE.
-- A writer can still time out in that window: its OWN statement_timeout
-- (its role's; APPLY Q2b reads them) counts the wait together with the rest
-- of its work. It is then cancelled, and its whole statement rolls back. The
-- writers of the queue:
--   * the insert trigger, run by remote_helper_create_permission_request
--     (v0.45), which a helper calls with the anon key (role anon) to create
--     an approval request; the trigger inserts the job in the same
--     statement. If it times out, the call fails and neither the approval
--     request nor its job exists; the helper handles that like any failure
--     of that call. Current helpers no longer call it (both retired their
--     remote approval arm: HookAdapter.swift, helper/remote_hook.py); an
--     older helper still can.
--   * delete_user_account, called by the apps as the signed-in user
--     (authenticated): deleting the profile deletes the account's approval
--     requests and jobs (ON DELETE CASCADE). If it times out, the whole call
--     rolls back and nothing is deleted; it can be called again.
--   * the nightly remote retention (pg_cron, as postgres, 03:47 UTC):
--     deleting old approval requests deletes their jobs. It waits and goes
--     on. Its deletions also change APPLY Q5r: keep the window away from
--     03:47 UTC.
--   * this worker (paused for the window).
-- send-approval-push writes remote_permission_requests and app_push_tokens,
-- never the queue, and the apply locks neither: it is not blocked.
--
-- ── MD5 VALUES (md5 of pg_proc.prosrc of public.process_app_push_jobs) ──
-- Production's function bodies are the migration files' with every line that
-- is only a `--` comment removed (blank lines kept): measured 2026-11-12 for
-- this worker, as for v0.89's (B0's catalog check). apply_migration may or
-- may not strip such lines from this file too, so each body is listed both
-- ways.
--   before  v0.32, as production runs it (no comment-only lines)  fab8e1a9cfb25294eb7386baa248c236
--   before  v0.32, as the file has it                             163c3c4f3983e4b4d582ae8109f8b28c
--   after   v0.90, this file as written                           8507646f49cf55e1d0875fb8af635360
--   after   v0.90, this file without comment-only lines           3890319e7b32513b9dd6f0f2f6f3a12d
-- A2 accepts exactly these four; E accepts the two "after" values. The test
-- suite recomputes all four from the files and fails on drift.
--
-- ── APPLY (the owner approves each step) ─────────────────────
-- Every Q query is read-only and returns counts, hashes and booleans only:
-- never a row's contents, a secret, a function body or a timestamp. The
-- exceptions are labelled: Q2b (role settings) and R0 (the function
-- definition, kept privately). Run each in its own statement (Supabase MCP
-- execute_sql), and keep every answer.
-- PRECONDITION for the whole window, from step 2 until step 7 has drained:
-- nothing but the paused cron job calls the worker. No manual call, no
-- service_role client, no second schedule. A call that starts anyway during
-- the apply waits for its commit and then runs the OLD body it started with,
-- which can leave a job stuck again; steps 7 and 8 catch and repair that,
-- but the precondition is what keeps it from happening.
-- 0. Before the window, read-only.
--    Q0: select md5(p.prosrc) as body_md5, (select count(*) from pg_proc where proname = 'process_app_push_jobs') as same_name, (p.prosecdef and p.proconfig = array['search_path=pg_catalog, extensions, public, net'] and p.prorettype = 'void'::regtype) as attrs_ok, pg_has_role(current_user, p.proowner, 'USAGE') as applier_can_replace, not (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE')) as anon_auth_denied, md5(coalesce(p.proacl::text, '')) as acl_md5, (select md5(col_description(a.attrelid, a.attnum)) from pg_attribute a where a.attrelid = 'public.app_push_jobs'::regclass and a.attname = 'processed_at') as comment_md5 from pg_proc p where p.oid = 'public.process_app_push_jobs()'::regprocedure;
--    FIRST APPLY: expect body_md5 = fab8e1a9cfb25294eb7386baa248c236,
--    same_name = 1, attrs_ok, applier_can_replace and anon_auth_denied true,
--    comment_md5 NULL, and probably acl_md5 = db23e67d6fad77fdfa003856d807d6af
--    ({postgres=X/postgres,service_role=X/postgres}: v0.32's revoke on top
--    of Supabase's default privileges, as measured on v0.89's worker; this
--    worker's ACL was not read on 2026-11-12). If acl_md5 differs, record
--    it and go on only if anon_auth_denied is true: the migration requires
--    that, and compares the ACL before and after.
--    RE-RUN OR RECOVERY: body_md5 = 8507646f49cf55e1d0875fb8af635360 or
--    3890319e7b32513b9dd6f0f2f6f3a12d (v0.90 is already in), comment_md5 =
--    71bf2ed678ce3ea230b5bc64690bd6af, the rest as above. The migration
--    accepts all four bodies in MD5 VALUES; seeing a v0.90 value before a
--    first apply means it is already applied: verify (step 8) instead.
--    Any other body_md5: STOP (production runs a body this file was not
--    written against).
--    Q1: select count(*) total, count(*) filter (where processed_at is null) pending, count(*) filter (where processed_at is null and attempt_count >= 3 and pg_net_request_id is null) stuck, count(*) filter (where processed_at is null and pg_net_request_id is not null) awaiting, count(*) filter (where processed_at is null and pg_net_request_id is not null and dispatched_at is null) pending_id_without_dispatch, count(*) filter (where processed_at is null and enqueued_at < now() - interval '1 day') pending_over_1_day, count(*) filter (where processed_at is not null and pg_net_request_id is not null) finalized_with_request_id, count(*) filter (where attempt_count < 0 or attempt_count > 10) odd_counts from public.app_push_jobs;
--    Q1b: select attempt_count, count(*) from public.app_push_jobs where processed_at is null group by 1 order by 1;
--    Q1's stuck is PRELIMINARY sizing only; the number the apply is checked
--    against is step 4's recount. pending_id_without_dispatch must be 0 (no
--    code path writes such a job): the new worker would reconcile them, and
--    one with no answer would be sent again for an old approval request. If
--    it is not 0, STOP and decide first.
--    Secrets, each exactly once and non-empty, without selecting a value:
--    Q2: select n.name, count(s.name) as copies, count(*) filter (where s.decrypted_secret is not null and s.decrypted_secret <> '') as non_empty from (values ('app_supabase_url'),('app_service_role_key')) n(name) left join vault.decrypted_secrets s on s.name = n.name group by n.name;
--    Expect copies = 1 and non_empty = 1 for both; otherwise STOP (nothing
--    dispatches).
--    Role settings (config values, not data): how long a writer of the
--    queue waits on the queue lock before it gives up (THE QUEUE LOCK AND
--    ITS WRITERS):
--    Q2b: select rolname, coalesce((select substr(c, 19) from unnest(rolconfig) c where c like 'statement_timeout=%'), '(database default)') as statement_timeout, coalesce((select substr(c, 14) from unnest(rolconfig) c where c like 'lock_timeout=%'), '(database default)') as lock_timeout from pg_roles where rolname in ('anon', 'authenticated', 'authenticator', 'service_role') order by rolname;
--    On 2026-11-12: anon statement_timeout 3s (the helpers'
--    remote_helper_create_permission_request), authenticated 8s (the apps'
--    delete_user_account). The budget of A0 (2 s) must stay below both: if
--    either now reads 2 s or less, STOP and lower the budget in this file
--    first.
--    Q3: select count(*) filter (where command ilike '%process_app_push_jobs%') as by_command, count(*) filter (where jobname = 'app_push_jobs_drain') as by_name, count(*) filter (where jobname = 'app_push_jobs_drain' and command ilike '%process_app_push_jobs%') as same_job, string_agg(active::text, ',' order by jobid) filter (where jobname = 'app_push_jobs_drain' and command ilike '%process_app_push_jobs%') as active, md5(string_agg(jobid || '|' || coalesce(jobname, '') || '|' || schedule || '|' || command || '|' || username, ',' order by jobid) filter (where jobname = 'app_push_jobs_drain' or command ilike '%process_app_push_jobs%')) as job_md5 from cron.job;
--    Expect by_command = 1, by_name = 1 and same_job = 1 (anything else is a
--    duplicate or renamed schedule: STOP). On 2026-11-12: active true,
--    job_md5 = 906b147cfd3bd3ea3ff05127e596651a (jobid 5,
--    app_push_jobs_drain, '30 seconds', 'select public.process_app_push_jobs()',
--    postgres).
--    Q3b: select d.status, count(*) from cron.job_run_details d join cron.job j on j.jobid = d.jobid where j.jobname = 'app_push_jobs_drain' and d.start_time > now() - interval '24 hours' group by d.status order by d.status;
--    ROLLBACK SOURCE, keep privately (not in logs, tickets or the PR; it is
--    the whole function definition):
--    R0: select pg_get_functiondef('public.process_app_push_jobs()'::regprocedure);
--    If Q1's stuck is over 5000, run BF now, each run its own statement (its
--    own committed transaction), until Q1's stuck is 5000 or less. BF touches
--    only jobs the worker never selects, so it needs no pause, and it
--    resumes safely if interrupted:
--    BF: update public.app_push_jobs set processed_at = now(), last_error = 'v0.90 backfill: retries exhausted before v0.90; ' || coalesce(last_error, '') where id in (select id from public.app_push_jobs where processed_at is null and attempt_count >= 3 and pg_net_request_id is null order by id limit 1000);
-- 1. RECORD the job's active value from Q3 (true on 2026-11-12). Every
--    restore below puts back exactly this value, whatever happens.
-- 2. Pause the job. pg_cron's signature is cron.alter_job(job_id bigint,
--    schedule text default null, command text default null, database text
--    default null, username text default null, active boolean default
--    null), so the id is passed by position; expect exactly one row:
--    P2: select cron.alter_job(jobid, active := false) from cron.job where jobname = 'app_push_jobs_drain' and command ilike '%process_app_push_jobs%';
--    Last resort, only if that function is not available to the role:
--    `update cron.job set active = false where jobid = <that jobid>;` (5)
--    Q3 again: active false. (If the recorded value was already false, P2
--    changes nothing.)
-- 3. Quiesce, with the PRECONDITION above in force. Repeat every few
--    seconds until Q4's running, idle_holding_queue and queue_lock_holders
--    are 0 and Q4b is 0:
--    Q4: select (select count(*) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and state = 'active' and query ilike '%process_app_push_jobs%' and query not ilike '%pg_stat_activity%') as running, (select count(distinct a.pid) from pg_stat_activity a join pg_locks l on l.pid = a.pid where a.pid <> pg_backend_pid() and a.datname = current_database() and a.state like 'idle in transaction%' and l.locktype = 'relation' and l.database = (select oid from pg_database where datname = current_database()) and l.relation = 'public.app_push_jobs'::regclass) as idle_holding_queue, (select count(distinct pid) from pg_locks where pid <> pg_backend_pid() and granted and locktype = 'relation' and database = (select oid from pg_database where datname = current_database()) and relation = 'public.app_push_jobs'::regclass) as queue_lock_holders, (select count(*) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and query = '<insufficient privilege>') as invisible;
--    Q4b: select count(*) as recent_unfinished from cron.job_run_details d join cron.job j on j.jobid = d.jobid where j.jobname = 'app_push_jobs_drain' and d.status in ('running', 'starting') and d.start_time > now() - interval '10 minutes';
--    queue_lock_holders is the authority (pg_locks, no privilege needed).
--    invisible is information, not a blocker: running only covers sessions
--    the applier can see, and pg_locks covers what the others do to the
--    queue. Idle transactions that never touched the queue do not count. A
--    'running' or 'starting' cron row older than 10 minutes with no live
--    backend is a leftover from a crash or restart: note it, do not wait on
--    it. queue_lock_holders may blink to 1 while a writer commits; wait for
--    0.
-- 4. Recount, immediately before the apply (these are the numbers that
--    count; the job is paused and quiesced, so they no longer move):
--    Q5: select count(*) as stuck from public.app_push_jobs where processed_at is null and attempt_count >= 3 and pg_net_request_id is null;
--    and the approval requests of those jobs (and of any BF has already
--    finalized), as a count and a hash of their notification columns (step
--    8 compares it with Q8r):
--    Q5r: select count(*) as requests, md5(coalesce(string_agg(r.id::text || '|' || r.notification_attempts || '|' || coalesce(r.notification_last_error, '~') || '|' || coalesce(r.notified_at::text, '~') || '|' || coalesce(r.notification_queued_at::text, '~'), ',' order by r.id), '')) as notification_md5 from public.remote_permission_requests r where r.id in (select request_id from public.app_push_jobs where (processed_at is null and attempt_count >= 3 and pg_net_request_id is null) or last_error like 'v0.90 backfill: %');
--    If Q5 is over 5000: run BF (step 0) until Q5 is 5000 or less. The job
--    stays paused and the value recorded in step 1 stays the one to restore;
--    then repeat steps 3 and 4. Call the final Q5 answer N, and the final
--    Q5r answer R.
-- 5. Apply this file as it stands, byte for byte, with the Supabase MCP's
--    `apply_migration` under the name `v0_90_app_push_jobs_finalize_failures`.
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
--       v0_90_app_push_jobs_finalize_failures until its transaction ends, and
--       from A5c to its end it holds the worker's advisory lock (with the job
--       paused, nothing else does):
--       Q6: select (select count(*) from pg_locks where pid <> pg_backend_pid() and locktype = 'advisory' and database = (select oid from pg_database where datname = current_database()) and objsubid = 1 and classid = ((hashtextextended('process_app_push_jobs', 0) >> 32) & 4294967295)::oid and objid = (hashtextextended('process_app_push_jobs', 0) & 4294967295)::oid) as worker_lock, (select count(*) from pg_stat_activity where pid <> pg_backend_pid() and datname = current_database() and application_name = 'v0_90_app_push_jobs_finalize_failures') as apply_sessions;
--       Then decide from Q0 and Q5:
--       - body_md5 one of the two v0.90 values, acl_md5 as in step 0,
--         comment_md5 71bf2ed678ce3ea230b5bc64690bd6af: it committed. Go to
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
-- 8. Verify, read-only, with the job still paused, in this order:
--    a. Q0: body_md5 one of the two v0.90 values, comment_md5
--       71bf2ed678ce3ea230b5bc64690bd6af, every other column as in step 0. Q3:
--       by_command, by_name and same_job 1, job_md5 as in step 0, active
--       false. The migration's NOTICE "backfilled N" equals step 4's N, and
--       its NOTICE "the queue lock was held ... ms" is production's hold
--       time.
--    b. The backfill changed no approval request: Q8r = R. Q8r takes only
--       the requests of jobs that carry the backfill prefix. After the
--       commit those are exactly the jobs step 4's Q5r took (stuck then, or
--       finalized by BF before the window), and a job that got stuck after
--       the commit is not among them, so this holds before any repair in c:
--       Q8r: select count(*) as requests, md5(coalesce(string_agg(r.id::text || '|' || r.notification_attempts || '|' || coalesce(r.notification_last_error, '~') || '|' || coalesce(r.notified_at::text, '~') || '|' || coalesce(r.notification_queued_at::text, '~'), ',' order by r.id), '')) as notification_md5 from public.remote_permission_requests r where r.id in (select request_id from public.app_push_jobs where last_error like 'v0.90 backfill: %');
--       Q8r differs from R: STOP with the job paused, and investigate.
--    c. Q5 = 0. If not, an old-body call ran during the window (against the
--       precondition) and left jobs stuck after the commit; Q5r then differs
--       from R for that reason alone, so do not compare it. Run BF until
--       Q5 = 0, then run Q8r again and record its answer as the new
--       baseline R' (it also counts the requests of the jobs that BF just
--       finalized): any later check compares with R', not with R.
-- 9. Restore the value recorded in step 1 (put it in place of
--    <recorded active>), then run Q3 and see it:
--    R9: select cron.alter_job(jobid, active := <recorded active>) from cron.job where jobname = 'app_push_jobs_drain' and command ilike '%process_app_push_jobs%';
-- 10. Over the next hours, read-only: Q5 must stay 0, and
--    Q9: select count(*) as pending_over_1_day from public.app_push_jobs where processed_at is null and enqueued_at < now() - interval '1 day';
--    should trend to 0 (that also needs the secrets and enough worker
--    throughput, which v0.90 does not change). No WARNING from
--    process_app_push_jobs in the Postgres log.
--
-- ROLLBACK: steps 1 to 3, then re-apply the definition R0 saved; Q0 then
-- shows step 0's body_md5 (comment_md5 stays: the comment remains true of the
-- rows v0.90 finalized); then step 9. The backfill is NOT undone: the jobs it
-- finalized stay finalized (they were unrecoverable, and the prefix is not a
-- restoration record). Undoing it exactly would need its own plan with
-- captured ids and original values, built never to delete newer pending jobs.
--
-- Fresh installs: the baseline files (schema.sql, app_rpc.sql,
-- helper_rpc.sql) carry no app-push objects (nor the remote tables), so this
-- file only upgrades an existing app-push queue; on a baseline-only database
-- it refuses at A1 with nothing changed.
--
-- Tested by backend/supabase/tests/run_v090_app_push_jobs_finalize_tests.sh
-- (CI job "App-push jobs finalize failures (v0.90)").
-- ============================================================

begin;
-- A0: each lock wait, the session's name, and the budget for the whole apply
set local lock_timeout = '1s';
set local application_name = 'v0_90_app_push_jobs_finalize_failures';
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
    v_fn        regprocedure := to_regprocedure('public.process_app_push_jobs()');
    v_md5       text;
    v_secdef    boolean;
    v_config    text[];
    v_rettype   oid;
    v_lang      name;
    v_owner     oid;
    v_acl       aclitem[];
    v_jobs      bigint;
    v_named     bigint;
    v_job       record;
    v_stuck     bigint;
    v_missing   text;
    v_n         bigint;
    v_role      name;
begin
    -- 1. the objects
    if to_regclass('public.app_push_jobs') is null then
        raise exception 'v0.90: public.app_push_jobs does not exist; nothing changed';
    end if;
    if not exists (
        select 1 from pg_trigger t
        where t.tgrelid = to_regclass('public.remote_permission_requests')
          and t.tgname = 'remote_permission_requests_after_insert_push'
          and not t.tgisinternal
          and t.tgenabled = 'O'
          and t.tgfoid = to_regprocedure('public.remote_request_after_insert_push()')
    ) then
        raise exception 'v0.90: trigger remote_permission_requests_after_insert_push on public.remote_permission_requests is missing, disabled or calls another function; nothing changed';
    end if;
    select string_agg(c, ', ' order by c) into v_missing
    from unnest(array['notification_attempts', 'notification_last_error']) c
    where not exists (select 1 from pg_attribute a
                      where a.attrelid = to_regclass('public.remote_permission_requests')
                        and a.attname = c and a.attnum > 0 and not a.attisdropped);
    if v_missing is not null then
        raise exception 'v0.90: public.remote_permission_requests lacks %, which the new worker writes; nothing changed', v_missing;
    end if;
    if v_fn is null or (select count(*) from pg_proc where proname = 'process_app_push_jobs') <> 1 then
        raise exception 'v0.90: expected exactly one function named process_app_push_jobs, public.process_app_push_jobs(), found % (in all schemas); nothing changed',
            (select count(*) from pg_proc where proname = 'process_app_push_jobs');
    end if;

    select md5(p.prosrc), p.prosecdef, p.proconfig, p.prorettype, l.lanname, p.proowner, p.proacl
      into v_md5, v_secdef, v_config, v_rettype, v_lang, v_owner, v_acl
      from pg_proc p join pg_language l on l.oid = p.prolang
     where p.oid = v_fn;

    -- 2. the exact body (MD5 VALUES in the header)
    if v_md5 not in ('fab8e1a9cfb25294eb7386baa248c236',   -- v0.32, as production runs it
                     '163c3c4f3983e4b4d582ae8109f8b28c',   -- v0.32, as the file has it
                     '8507646f49cf55e1d0875fb8af635360',   -- v0.90, this file
                     '3890319e7b32513b9dd6f0f2f6f3a12d')   -- v0.90, without comment-only lines
    then
        raise exception 'v0.90: public.process_app_push_jobs() has an unexpected definition (body md5 %), rebase required; nothing changed', v_md5;
    end if;

    -- 3. attributes, owner, ACL
    if not v_secdef then
        raise exception 'v0.90: public.process_app_push_jobs() is not SECURITY DEFINER; nothing changed';
    end if;
    if v_config is distinct from array['search_path=pg_catalog, extensions, public, net'] then
        raise exception 'v0.90: public.process_app_push_jobs() has proconfig %, expected {search_path=pg_catalog, extensions, public, net}; nothing changed', v_config;
    end if;
    if v_rettype <> 'void'::regtype or v_lang <> 'plpgsql' then
        raise exception 'v0.90: public.process_app_push_jobs() does not return void in plpgsql; nothing changed';
    end if;
    raise notice 'v0.90: applier %, worker owner %', current_user, pg_get_userbyid(v_owner);
    if not pg_has_role(current_user, v_owner, 'USAGE') then
        raise exception 'v0.90: % is neither the owner of public.process_app_push_jobs() (%) nor a member of that role, so it cannot replace it; nothing changed',
            current_user, pg_get_userbyid(v_owner);
    end if;
    if exists (
        select 1 from aclexplode(coalesce(v_acl, acldefault('f', v_owner))) a
        where a.privilege_type = 'EXECUTE'
          and (a.grantee = 0
               or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated')))
    ) then
        raise exception 'v0.90: PUBLIC, anon or authenticated may execute public.process_app_push_jobs() (acl %); nothing changed', v_acl;
    end if;
    -- and in effect: no grant reaches anon or authenticated through a role
    -- they inherit (has_function_privilege, as APPLY Q0 checks)
    for v_role in select r.rolname from pg_roles r where r.rolname in ('anon', 'authenticated') order by 1 loop
        if has_function_privilege(v_role, v_fn, 'EXECUTE') then
            raise exception 'v0.90: % may execute public.process_app_push_jobs() through a role it inherits (has_function_privilege; acl %); nothing changed', v_role, v_acl;
        end if;
    end loop;

    -- 4. the environment the new worker reads; one schedule, by name and
    -- by command, paused
    if to_regclass('net._http_response') is not null then
        select string_agg(c, ', ' order by c) into v_missing
        from unnest(array['status_code', 'timed_out', 'error_msg']) c
        where not exists (select 1 from pg_attribute a
                          where a.attrelid = to_regclass('net._http_response')
                            and a.attname = c and a.attnum > 0 and not a.attisdropped);
        if v_missing is not null then
            raise exception 'v0.90: net._http_response lacks %, which the new worker reads; nothing changed', v_missing;
        end if;
    end if;
    if to_regclass('cron.job') is not null then
        select count(*) into v_jobs from cron.job where command ilike '%process_app_push_jobs%';
        if v_jobs <> 1 then
            raise exception 'v0.90: expected exactly one cron job calling process_app_push_jobs, found %; nothing changed', v_jobs;
        end if;
        select count(*) into v_named from cron.job where jobname = 'app_push_jobs_drain';
        if v_named <> 1 then
            raise exception 'v0.90: expected exactly one cron job named app_push_jobs_drain, found %; nothing changed', v_named;
        end if;
        select jobid, jobname, active, username into v_job from cron.job where command ilike '%process_app_push_jobs%';
        if v_job.jobname is distinct from 'app_push_jobs_drain' then
            raise exception 'v0.90: the cron job calling process_app_push_jobs is job % named %, not app_push_jobs_drain; nothing changed',
                v_job.jobid, coalesce(v_job.jobname, '(none)');
        end if;
        if v_job.active then
            raise exception 'v0.90: cron job % (app_push_jobs_drain) is active; pause it first (APPLY step 2); nothing changed', v_job.jobid;
        end if;
        if to_regrole(v_job.username) is null
           or not has_function_privilege(v_job.username, v_fn, 'EXECUTE') then
            raise exception 'v0.90: cron job % runs as %, which cannot execute public.process_app_push_jobs(); nothing changed', v_job.jobid, v_job.username;
        end if;
    end if;

    -- 5. exclusive access to the queue (header A5)
    -- a. a readable refusal for the usual case (not the authority)
    if exists (
        select 1 from pg_stat_activity a
        where a.pid <> pg_backend_pid()
          and a.datname = current_database()
          and a.state = 'active'
          and a.query ilike '%process_app_push_jobs%'
          and a.query not ilike '%pg_stat_activity%'
    ) then
        raise exception 'v0.90: another session is running a query that names process_app_push_jobs; wait until it ends (APPLY step 3); nothing changed';
    end if;
    -- b. an idle open transaction that touched the queue may have run the worker
    select count(distinct a.pid) into v_n
      from pg_stat_activity a join pg_locks l on l.pid = a.pid
     where a.pid <> pg_backend_pid()
       and a.datname = current_database()
       and a.state like 'idle in transaction%'
       and l.locktype = 'relation'
       and l.database = (select oid from pg_database where datname = current_database())
       and l.relation = 'public.app_push_jobs'::regclass;
    if v_n > 0 then
        raise exception 'v0.90: % session(s) idle in an open transaction hold a lock on public.app_push_jobs (one may have run the worker); end them first (APPLY step 3); nothing changed', v_n;
    end if;
    -- c. the worker's own lock: v0.90 worker calls try-lock it and return at
    -- once while we hold it; a v0.90 call already running makes us wait
    begin
        perform pg_advisory_xact_lock(hashtextextended('process_app_push_jobs', 0));
    exception when lock_not_available then
        raise exception 'v0.90: another session held the worker''s advisory lock (a v0.90 worker run) for longer than lock_timeout; nothing changed';
    end;
    -- d. writers of the queue: open ones make us wait, new ones wait for us
    begin
        lock table public.app_push_jobs in exclusive mode;
    exception when lock_not_available then
        raise exception 'v0.90: another session held a write lock on public.app_push_jobs (an open transaction that wrote the queue) for longer than lock_timeout; nothing changed';
    end;
    perform set_config('v090.locked_at', clock_timestamp()::text, true);
    -- e. the authority: nobody else holds any lock on the queue
    select count(distinct l.pid) into v_n from pg_locks l
     where l.pid <> pg_backend_pid()
       and l.granted
       and l.locktype = 'relation'
       and l.database = (select oid from pg_database where datname = current_database())
       and l.relation = 'public.app_push_jobs'::regclass;
    if v_n > 0 then
        raise exception 'v0.90: % other session(s) hold a lock on public.app_push_jobs (an open transaction that read the queue); end them first (APPLY step 3); nothing changed', v_n;
    end if;
    select count(*) into v_n from pg_stat_activity a
     where a.pid <> pg_backend_pid()
       and a.datname = current_database()
       and a.query = '<insufficient privilege>';
    if v_n > 0 then
        raise notice 'v0.90: % session(s) in this database are not visible to %; the queue lock (5d, 5e) covers what they do to the queue', v_n, current_user;
    end if;

    -- 6. the backfill fits one transaction (counted under the lock)
    select count(*) into v_stuck from public.app_push_jobs
     where processed_at is null and attempt_count >= 3 and pg_net_request_id is null;
    if v_stuck > 5000 then
        raise exception 'v0.90: % stuck jobs to backfill, more than 5000; run APPLY step 0''s BF batches first; nothing changed', v_stuck;
    end if;

    -- what E compares with
    perform set_config('v090.before_owner', v_owner::text, true);
    perform set_config('v090.before_acl', coalesce(v_acl::text, 'NULL'), true);
end
$guard$;

-- ── B: the worker ─────────────────────────────────────────────
-- process_app_push_jobs(), v0.90. pg_cron calls it every 30 seconds; each
-- call runs two passes, reconcile then dispatch, as v0.32 did. The insert
-- trigger on remote_permission_requests already sent each job's first
-- request (attempt_count 1); this worker reconciles it and sends the retries.
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
--       3 or more (a second 502 takes it from 3 to 4: the retry after the
--       first one was counted too).
--   A failed answer or a transport failure is also counted on the approval
--   request (notification_attempts + 1, notification_last_error), as v0.32
--   did for non-2xx answers; finalizing writes nothing there.
--   Pass 2 sends a retry for pending jobs with no request id and
--   attempt_count < 3 (older than 5 seconds, so the inserting transaction
--   has committed); a raise from net.http_post counts an attempt and
--   finalizes the job at 3.
-- processed_at means FINALIZED, not delivered: see the column comment (C).
-- Inherited limits (header B): missing vault secrets stop both passes, a row
-- whose reconcile raises stays pending, and each call handles at most 200
-- reconciles and 100 dispatches.
-- BEGIN worker
create or replace function public.process_app_push_jobs()
returns void as $$
declare
  v_job        record;
  v_url        text;
  v_key        text;
  v_request_id bigint;
begin
  -- One call at a time: a duplicate schedule or a manual call that overlaps
  -- a running one returns here and sends nothing.
  if not pg_try_advisory_xact_lock(hashtextextended('process_app_push_jobs', 0)) then
    return;
  end if;

  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'app_supabase_url';
  select decrypted_secret into v_key
  from vault.decrypted_secrets where name = 'app_service_role_key';
  if v_url is null or v_key is null or v_url = '' or v_key = '' then
    raise notice 'process_app_push_jobs: vault secrets not set; skipping';
    return;
  end if;

  -- Pass 1: reconcile dispatched jobs against net._http_response. A job's
  -- age is coalesce(dispatched_at, enqueued_at), so one with a request id
  -- and no dispatched_at is reconciled too.
  for v_job in
    select id, request_id, pg_net_request_id, attempt_count, dispatched_at, enqueued_at
    from public.app_push_jobs
    where processed_at is null
      and pg_net_request_id is not null
      and coalesce(dispatched_at, enqueued_at) < now() - interval '2 seconds'
    order by id
    limit 200
  loop
    declare
      v_status    int;
      v_timed_out boolean;
      v_error     text;
      v_expired   boolean;
    begin
      select status_code, timed_out, error_msg
      into v_status, v_timed_out, v_error
      from net._http_response
      where id = v_job.pg_net_request_id;

      if v_status is null and (coalesce(v_timed_out, false) or v_error is not null) then
        -- pg_net finished the request without an HTTP answer (timed out,
        -- could not connect): a failed attempt, like a non-2xx answer.
        update public.app_push_jobs
          set attempt_count     = attempt_count + 1,
              last_error        = 'edge transport: ' || left(coalesce(v_error, 'timed out'), 200),
              pg_net_request_id = null,
              dispatched_at     = null,
              processed_at      = case when attempt_count + 1 >= 3 then now() else processed_at end
          where id = v_job.id;
        update public.remote_permission_requests
          set notification_attempts   = notification_attempts + 1,
              notification_last_error = 'edge transport: ' || left(coalesce(v_error, 'timed out'), 200)
          where id = v_job.request_id;
      elsif v_status is null then
        -- No answer yet (no row, or nothing completed). After 5 minutes give
        -- this attempt up; after the third, give the job up. Never sooner:
        -- the request may still be live.
        v_expired := coalesce(v_job.dispatched_at, v_job.enqueued_at) < now() - interval '5 minutes';
        update public.app_push_jobs
          set pg_net_request_id = case when v_expired then null else pg_net_request_id end,
              processed_at      = case when v_expired and attempt_count >= 3 then now() else processed_at end,
              last_error        = case when v_expired and attempt_count >= 3
                                       then 'gave up: no response from pg_net (attempt budget used)'
                                       else 'pg_net response not yet available' end
          where id = v_job.id;
      elsif v_status between 200 and 299 then
        update public.app_push_jobs
          set processed_at = now(),
              last_error   = null
          where id = v_job.id;
      else
        update public.app_push_jobs
          set attempt_count     = attempt_count + 1,
              last_error        = 'edge HTTP ' || v_status::text,
              -- clear the request id so pass 2 can send the retry
              pg_net_request_id = null,
              dispatched_at     = null,
              processed_at      = case when attempt_count + 1 >= 3 then now() else processed_at end
          where id = v_job.id;
        update public.remote_permission_requests
          set notification_attempts   = notification_attempts + 1,
              notification_last_error = 'edge HTTP ' || v_status::text
          where id = v_job.request_id;
      end if;
    exception when others then
      -- A reconcile failure must not poison the loop. Log and move on.
      raise warning 'process_app_push_jobs reconcile (job %): %', v_job.id, sqlerrm;
    end;
  end loop;

  -- Pass 2: send the retries. enqueued_at < now() - 5s gives the inserting
  -- transaction time to commit before the cron worker reads.
  for v_job in
    select id, user_id, request_id
    from public.app_push_jobs
    where processed_at is null
      and pg_net_request_id is null
      and attempt_count < 3
      and enqueued_at < now() - interval '5 seconds'
    order by id
    limit 100
  loop
    begin
      v_request_id := net.http_post(
        url := v_url || '/functions/v1/send-approval-push',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_key,
          'X-Internal-Trigger', 'process_app_push_jobs'
        ),
        body := jsonb_build_object(
          'user_id', v_job.user_id,
          'request_id', v_job.request_id
        ),
        timeout_milliseconds := 5000
      );
      update public.app_push_jobs
        set pg_net_request_id = v_request_id,
            dispatched_at     = now(),
            attempt_count     = attempt_count + 1,
            last_error        = null
        where id = v_job.id;
      update public.remote_permission_requests
        set notification_attempts = notification_attempts + 1
        where id = v_job.request_id;
    exception when others then
      update public.app_push_jobs
        set attempt_count = attempt_count + 1,
            last_error    = 'http_post failed: ' || sqlerrm,
            processed_at  = case when attempt_count + 1 >= 3 then now() else processed_at end
        where id = v_job.id;
    end;
  end loop;
end;
$$ language plpgsql security definer
   set search_path = pg_catalog, extensions, public, net;
-- END worker

-- ── C: what processed_at means ────────────────────────────────
comment on column public.app_push_jobs.processed_at is
    'FINALIZED, not delivered (v0.90). NULL while the job is pending: '
    'process_app_push_jobs() may still reconcile it or send a retry, and only '
    'a pending job holds its request_id slot in idx_app_push_jobs_pending_dedup. '
    'Set once, when the worker is done with the job. With last_error NULL it '
    'was finalized successfully: send-approval-push answered 2xx, which it also '
    'does when it sent nothing (remote control off, no push token, APNs not '
    'configured) and when every APNs send failed (recorded on the approval '
    'request). With last_error set it was finalized with failure: attempt_count '
    'reached 3 (the first request, each retry, each failed answer and each '
    'failed http_post count; a request with no answer for 5 minutes is '
    'abandoned), or the v0.90 backfill finalized it, stuck from before v0.90.';

-- ── D: backfill the jobs the old worker left stuck ────────────
-- Writes app_push_jobs only: remote_permission_requests is deliberately not
-- touched (header D).
-- BEGIN backfill
do $backfill$
declare
    v_n bigint;
begin
    update public.app_push_jobs
       set processed_at = now(),
           last_error = 'v0.90 backfill: retries exhausted before v0.90; ' || coalesce(last_error, '')
     where processed_at is null
       and attempt_count >= 3
       and pg_net_request_id is null;
    get diagnostics v_n = row_count;
    raise notice 'v0.90: backfilled % stuck job(s): finalized with failure, nothing re-sent', v_n;
end
$backfill$;
-- END backfill

-- ── E: verification ───────────────────────────────────────────
do $verify$
declare
    v_fn     regprocedure := to_regprocedure('public.process_app_push_jobs()');
    v_md5    text;
    v_stuck  bigint;
begin
    select md5(prosrc) into v_md5 from pg_proc where oid = v_fn;
    if v_md5 is null or v_md5 not in ('8507646f49cf55e1d0875fb8af635360', '3890319e7b32513b9dd6f0f2f6f3a12d') then
        raise exception 'v0.90: after the replace the worker''s body md5 is %, not this file''s', v_md5;
    end if;
    if not exists (
        select 1 from pg_proc p join pg_language l on l.oid = p.prolang
        where p.oid = v_fn
          and p.prosecdef
          and p.proconfig = array['search_path=pg_catalog, extensions, public, net']
          and p.prorettype = 'void'::regtype
          and l.lanname = 'plpgsql'
          and p.proowner::text = current_setting('v090.before_owner')
          and coalesce(p.proacl::text, 'NULL') = current_setting('v090.before_acl')
    ) then
        raise exception 'v0.90: after the replace the worker''s attributes, owner or ACL differ from before';
    end if;
    if coalesce(col_description('public.app_push_jobs'::regclass,
                                (select attnum from pg_attribute
                                  where attrelid = 'public.app_push_jobs'::regclass
                                    and attname = 'processed_at')), '') not like 'FINALIZED, not delivered (v0.90).%' then
        raise exception 'v0.90: the comment on app_push_jobs.processed_at is missing';
    end if;
    select count(*) into v_stuck from public.app_push_jobs
     where processed_at is null and attempt_count >= 3 and pg_net_request_id is null;
    if v_stuck <> 0 then
        raise exception 'v0.90: % stuck job(s) left after the backfill', v_stuck;
    end if;
    raise notice 'v0.90: worker replaced (body md5 %), owner and ACL unchanged', v_md5;
    raise notice 'v0.90: the queue lock was held % ms so far (from A5d to the end of verification; the commit follows)',
        round(extract(epoch from clock_timestamp() - current_setting('v090.locked_at')::timestamptz) * 1000);
end
$verify$;

commit;

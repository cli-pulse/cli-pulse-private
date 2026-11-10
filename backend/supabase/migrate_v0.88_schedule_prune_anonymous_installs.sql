-- ============================================================
-- v0.88 — run prune_anonymous_installs() every night
-- Date: 2026-11-10. The owner decided to schedule it (2026-11-10), knowing the
-- objection below. Apply it on the day the PR that adds this file merges.
--
-- ── WHY ───────────────────────────────────────────────────────
-- PRIVACY.md has said since v0.73: "Anonymous install rows are deleted 400
-- days after they were last touched." `public.prune_anonymous_installs()`
-- (v0.73) does exactly that, `delete … where last_seen_at < now() - interval
-- '400 days'`, but nothing has ever called it, so the sentence is false. This
-- migration adds the pg_cron job that calls it, nightly at 04:37 UTC (the
-- other nightly jobs run at 03:07, 03:27, 03:47 and 04:07). A row goes on the
-- first run after it turns 400 days old, so between 400 and 401 days.
--
-- ── THE OBJECTION ON RECORD, AND WHY IT NO LONGER BLOCKS ─────
-- v0.78 ("WHAT THIS MIGRATION DELIBERATELY DOES NOT DO") refused to schedule
-- this job, and v0.79 put the reason into the table's comments:
-- `last_seen_at` is not liveness. It moves only when the client reports a
-- milestone it has not reported before (install, helper connected, provider
-- detected, first cost, and since v0.80 four remote-control facts), each
-- milestone sits behind a latch on the user's disk, and there is no heartbeat.
-- So an install in daily use stops touching its row after its last milestone,
-- and the prune deletes that row 400 days later.
--
-- That is all still true. What changed is the question being asked:
--   * The policy promises deletion 400 days after the row was last touched,
--     which is `last_seen_at`. Deleting such a row keeps the promise; keeping
--     it breaks the promise. The objection is about how complete the
--     analytics are, not about whether the deletion is right.
--   * The table was created on 2026-08-06 (production's migration ledger:
--     v0_73_anonymous_install_telemetry, 20260806104057), and every write
--     sets `last_seen_at` to now(). So no row can be 400 days old before
--     2027-09-10: until then every run deletes nothing.
--   * That date is the deadline for the fix v0.79's comment names: the client
--     refreshes `last_seen_at` on launch, separately from the milestone
--     latches (a client change, a shipped build, and new consent and policy
--     text, because per-launch reports reveal how often the app is used).
--     Installs that never update to such a build stay affected after it
--     ships.
--
-- What the prune does to the analytics from 2027-09-10 on, which the comments
-- below repeat where a reader will see them:
--   * OLD COHORTS READ HIGH, not just incomplete. Within one `first_seen_at`
--     cohort, an install that reported nothing after installing goes at day
--     400, while one that reported a later milestone stays until 400 days
--     after that milestone. So a read reaching back more than 400 days has
--     lost its non-activated installs first, and its rates are biased upward.
--   * RECENT COHORTS GAIN FAKE INSTANT ACTIVATIONS. The client re-sends every
--     milestone it has already latched with every report
--     (AnonymousInstallTelemetry.send). If a pruned install later reports a
--     milestone it had not reported, `record_anonymous_install` takes its
--     INSERT path: a new row whose `first_seen_at` is that day and whose
--     every already-reached milestone is stamped with the same instant. It
--     reads as a new install that activated on day 0, and `n_tup_ins` counts
--     that install twice. (This is true of ANY deleted row, not only pruned
--     ones: the five rows deleted by hand in August 2026 could already have
--     come back this way once v0.76 and v0.80 added milestones.)
--
-- ── WHAT THIS DOES ────────────────────────────────────────────
-- A. Refuses, and changes nothing, unless all of this holds:
--    pg_cron's `cron.schedule(text,text,text)` exists;
--    `public.prune_anonymous_installs()` exists, is SECURITY DEFINER, pins
--    `search_path=public, pg_temp`, cannot be executed by anon or
--    authenticated, and has exactly v0.73's body (md5 of prosrc
--    29941fa052e043c75ed49fbad5a785d7, the same in this repository and in
--    production on 2026-11-10; a changed body gets its own review before
--    anything runs it every night);
--    and no job of this name belongs to another role (pg_cron's names are
--    unique per role, so that job would be left running beside this one).
-- B. Schedules `prune_anonymous_installs_nightly`, '37 4 * * *',
--    'select public.prune_anonymous_installs()'. pg_cron 1.6's schedule-by-
--    name updates an existing job of that name and role in place, keeping its
--    jobid (and so its run history), so re-running gives one job. (This
--    project's pg_cron takes a 5-field expression or '[1-59] seconds';
--    'N minutes' is rejected, see v0.49.)
-- C. Rewrites seven comments so they say what now happens:
--    from v0.79, the table's, which said "DO NOT DELETE ROWS"; `last_seen_at`'s,
--    which said pruning on it would delete active installs; `first_seen_at`'s,
--    which called it "the only column here that means what a reader expects";
--    and `first_provider_detected_at`'s, which said it never moves
--    (`first_seen_at` is the day a returning install came back; so is
--    `first_provider_detected_at` if it had already reached first value);
--    `anonymous_funnel_summary`'s (v0.76's text, with the two effects above
--    added); and new ones on `anonymous_activation_summary` and
--    `prune_anonymous_installs`, which had none.
-- D. Verifies: one job of that name, with exactly that schedule and command,
--    active, run by a role that can execute the function; the eight jobs
--    production had before are all still there with the same schedule,
--    command and state; the seven comments say what C wrote.
--
-- It changes no table, no function body, no grant and no row: one job and
-- seven comments.
--
-- ── APPLY ─────────────────────────────────────────────────────
-- 0. Preflight, read-only (Supabase MCP execute_sql). Run
--    backend/supabase/ops/check_cron_references.sql first and keep its answer
--    (it should be empty) as the baseline for step 2. Then run Q0 and expect
--    fn_md5 = 29941fa052e043c75ed49fbad5a785d7, fn_ok = true,
--    job_present = false, deletable_now = 0, other_jobs = 8:
--    Q0: select (select md5(prosrc) from pg_proc where oid = 'public.prune_anonymous_installs()'::regprocedure) as fn_md5, (select prosecdef and proconfig = array['search_path=public, pg_temp'] and not has_function_privilege('anon', oid, 'EXECUTE') and not has_function_privilege('authenticated', oid, 'EXECUTE') from pg_proc where oid = 'public.prune_anonymous_installs()'::regprocedure) as fn_ok, exists (select 1 from cron.job where jobname = 'prune_anonymous_installs_nightly') as job_present, (select count(*) from public.anonymous_installs where last_seen_at < now() - interval '400 days') as deletable_now, (select count(*) from cron.job where (jobname, schedule, command, active) in (('app_push_jobs_drain', '30 seconds', 'select public.process_app_push_jobs()', true), ('cleanup_expired_data_nightly', '7 3 * * *', 'SELECT public._cleanup_expired_data_internal();', true), ('m10_send_due_notifications', '* * * * *', 'select public.trigger_send_due_notifications()', true), ('process_webhook_jobs', '30 seconds', 'select public.process_webhook_jobs()', true), ('remote_retention_cleanup_nightly', '47 3 * * *', 'SELECT public._cleanup_remote_retention_internal();', true), ('remote_swarms_cleanup_nightly', '7 4 * * *', 'select public._cleanup_remote_swarms_internal();', true), ('retention_cleanup_nightly', '27 3 * * *', 'SELECT public._cleanup_retention_data_internal(18);', true), ('widget_refresh_hourly', '13 * * * *', 'select public.process_widget_refresh()', true))) as other_jobs;
-- 1. Apply on the day the PR that adds this file merges (merged first, so
--    that what runs is on main). Apply this file as it stands, byte for byte,
--    with the Supabase MCP's `apply_migration` under the name
--    `v0_88_schedule_prune_anonymous_installs` (that also writes its row in
--    `supabase_migrations.schema_migrations`). Record the md5 of the text
--    sent next to this file's. If apply_migration times out, run step 2
--    before trying again: it may have gone through. The file carries its own
--    begin/commit, so a guard in A or a check in D that fails leaves nothing
--    behind: no job, no comment changed.
-- 2. Post-apply, read-only. Expect one row: '37 4 * * *',
--    'select public.prune_anonymous_installs()', active = true,
--    can_execute = true:
--    Q2: select j.schedule, j.command, j.active, has_function_privilege(j.username, 'public.prune_anonymous_installs()', 'EXECUTE') as can_execute from cron.job j where j.jobname = 'prune_anonymous_installs_nightly';
--    Then run backend/supabase/ops/check_cron_references.sql (it must return
--    no rows, AGENTS.md "Backend SQL validation") and
--    backend/supabase/ops/check_anonymous_install_retention.sql: before the
--    job's first run it must return exactly one row, 'no run recorded'.
-- 3. The day after, read-only. Expect status = 'succeeded' and
--    return_message = '1 row' for the first run after 04:37 UTC. '1 row' is
--    the row count of the job's SELECT, not the number deleted; the function
--    returns that number and pg_cron discards it (it is 0 until 2027-09-10):
--    Q3: select d.status, d.return_message, d.start_time from cron.job_run_details d join cron.job j on j.jobid = d.jobid where j.jobname = 'prune_anonymous_installs_nightly' order by d.runid desc limit 3;
--    (By runid, not start_time: pg_cron leaves start_time NULL on a run that
--    never started, and NULLs sort first in a descending order.) Then
--    ops/check_anonymous_install_retention.sql must return no rows. From then
--    on it belongs to each release's verification: a job that runs and
--    deletes nothing looks the same as one that works, and until 2027-09-10
--    it is what shows the job, its command and its function are still the
--    ones that will keep the promise.
--
-- ROLLBACK: select cron.unschedule('prune_anonymous_installs_nightly');
-- The comments from v0.79 and v0.76 can be restored by re-running their
-- `comment on` statements for the table, last_seen_at, first_seen_at,
-- first_provider_detected_at and anonymous_funnel_summary, and `comment on
-- function public.anonymous_activation_summary(integer) is null;` (likewise
-- for prune_anonymous_installs()). Nothing else to undo: no row is deletable
-- before 2027-09-10.
--
-- Tested by backend/supabase/tests/run_v088_prune_anonymous_installs_cron_tests.sh
-- (CI job "Anonymous install prune schedule (v0.88)").
-- ============================================================

begin;

-- ── A + B: guards, then schedule ──────────────────────────────
do $migration$
declare
    v_fn regprocedure := to_regprocedure('public.prune_anonymous_installs()');
begin
    if to_regprocedure('cron.schedule(text,text,text)') is null then
        raise exception 'v0.88: pg_cron (cron.schedule) is not installed; nothing scheduled';
    end if;

    if v_fn is null then
        raise exception 'v0.88: public.prune_anonymous_installs() does not exist (v0.73 not applied?); nothing scheduled';
    end if;

    if (select md5(prosrc) from pg_proc where oid = v_fn) <> '29941fa052e043c75ed49fbad5a785d7' then
        raise exception 'v0.88: public.prune_anonymous_installs() is not v0.73''s body; review the change before scheduling it';
    end if;

    if not (select prosecdef from pg_proc where oid = v_fn) then
        raise exception 'v0.88: public.prune_anonymous_installs() is not SECURITY DEFINER; nothing scheduled';
    end if;

    if (select proconfig from pg_proc where oid = v_fn) is distinct from array['search_path=public, pg_temp'] then
        raise exception 'v0.88: public.prune_anonymous_installs() does not pin search_path=public, pg_temp; nothing scheduled';
    end if;

    if has_function_privilege('anon', v_fn, 'EXECUTE')
       or has_function_privilege('authenticated', v_fn, 'EXECUTE') then
        raise exception 'v0.88: anon or authenticated can execute public.prune_anonymous_installs(); nothing scheduled';
    end if;

    if exists (select 1 from cron.job
               where jobname = 'prune_anonymous_installs_nightly'
                 and username <> current_user) then
        raise exception 'v0.88: a prune_anonymous_installs_nightly job belongs to another role; unschedule it as that role first';
    end if;

    -- pg_cron 1.6: scheduling a name this role already has updates that job in
    -- place (same jobid), so there is no unschedule step and a re-run is safe.
    perform cron.schedule(
        'prune_anonymous_installs_nightly',
        '37 4 * * *',
        'select public.prune_anonymous_installs()'
    );
end
$migration$;

-- ── C: comments ───────────────────────────────────────────────
comment on table public.anonymous_installs is
    'One row per install of CLI Pulse, with no link to any account. Written '
    'only by record_anonymous_install(); readable only by service_role. '
    'Rows are deleted ONLY by the nightly pg_cron job '
    'prune_anonymous_installs_nightly (migrate_v0.88), 400 days after '
    'last_seen_at, as PRIVACY.md promises. Do not delete rows by hand: the '
    'client''s "already reported" latches live in the user''s UserDefaults, '
    'so a deleted row is not sent again, and if that install later reports a '
    'milestone it had not reported, it comes back as a NEW row whose '
    'first_seen_at and every milestone it had already reached are all that '
    'day: an old install that reads as a new one activated on day 0. See '
    'migrate_v0.73 for the collection rationale and migrate_v0.79 / v0.88 '
    'for what last_seen_at means.';

comment on column public.anonymous_installs.last_seen_at is
    'MISNAMED — NOT LIVENESS. It is the last time a MILESTONE was reported, '
    'and each milestone sits behind a persistent client-side latch that '
    'returns early once set. There is no heartbeat, so an install in daily '
    'use stops touching this column after its last milestone and the value '
    'freezes. It IS the retention key: the nightly prune (migrate_v0.88) '
    'deletes rows 400 days after it, which is what PRIVACY.md promises, and '
    'so also deletes installs still in use whose last milestone is that old. '
    'From 2027-09-10 on, reads reaching back more than 400 days have lost '
    'the installs that reported nothing after installing first, so their '
    'rates read high, and recent cohorts can hold pruned installs that came '
    'back (see the table comment). The fix is a client touch on launch, '
    'separate from the latches: a client change, a shipped build, and a '
    'consent and policy change, because per-launch reporting reveals how '
    'often the app is used.';

comment on column public.anonymous_installs.first_seen_at is
    'When this row was created: the install''s first report, unless its row '
    'was deleted and the install came back by reporting a new milestone (see '
    'the table comment), in which case it is the day it came back. Set once '
    'per row and never updated.';

comment on column public.anonymous_installs.first_provider_detected_at is
    'First value: the app found a CLI and had a number to show. Write-once '
    'per row — the upsert coalesces so it never moves, or "time to first '
    'value" would decay into "time since last launch". For an install that '
    'came back after its row was deleted (see the table comment) and had '
    'already reached first value, it is the day it came back, equal to '
    'first_seen_at; one that had not stays NULL until it reaches first '
    'value, which is then a later day.';

comment on function public.anonymous_funnel_summary(integer) is
    'Owner-only funnel readout: installs -> helper connected -> provider '
    'detected -> cost shown, split by channel and resolved UI language. Rows '
    'from before v0.76 report NULL for the new milestones; that is "never '
    'reported", not "did not happen", and a reader who forgets it will see a '
    'cliff on the day this deployed. PRUNING (migrate_v0.88, from '
    '2027-09-10): rows go 400 days after last_seen_at, so with p_days over '
    '400 the oldest cohorts have lost their installs that reported nothing '
    'after installing, and their rates read high; and a pruned install that '
    'reports a new milestone returns as a new row with every milestone it '
    'had reached stamped that day, so recent cohorts can show instant '
    'activations that are not new installs.';

comment on function public.anonymous_activation_summary(integer) is
    'Owner-only readout of installs and first-value activation by day and '
    'channel (migrate_v0.73). PRUNING (migrate_v0.88, from 2027-09-10): rows '
    'go 400 days after last_seen_at, so with p_days over 400 the oldest '
    'cohorts have lost their non-activated installs first, and their '
    'activation reads high; and a pruned install that reports a new '
    'milestone returns as a new row with every milestone it had reached '
    'stamped that day, so recent cohorts can show instant activations that '
    'are not new installs.';

comment on function public.prune_anonymous_installs() is
    'Deletes anonymous_installs rows whose last_seen_at is more than 400 '
    'days old, as PRIVACY.md promises, and returns how many. Run nightly by '
    'the pg_cron job prune_anonymous_installs_nightly (migrate_v0.88); '
    'ops/check_anonymous_install_retention.sql checks that it keeps up. Not '
    'executable by anon or authenticated.';

-- ── D: verification ───────────────────────────────────────────
-- A cron change that silently did nothing looks identical to one that worked.
do $migration$
declare
    v_jobs   integer;
    v_others integer;
begin
    select count(*) into v_jobs
    from cron.job
    where jobname = 'prune_anonymous_installs_nightly';
    if v_jobs <> 1 then
        raise exception 'v0.88: expected one prune_anonymous_installs_nightly job, found %', v_jobs;
    end if;

    if not exists (
        select 1 from cron.job j
        where j.jobname = 'prune_anonymous_installs_nightly'
          and j.schedule = '37 4 * * *'
          and j.command = 'select public.prune_anonymous_installs()'
          and j.active
          and has_function_privilege(j.username, 'public.prune_anonymous_installs()', 'EXECUTE')
    ) then
        raise exception 'v0.88: prune_anonymous_installs_nightly is not scheduled as written (schedule, command, active, or its user cannot execute the function)';
    end if;

    -- Positive control: the jobs production had before are untouched. Without
    -- it, a migration that emptied cron.job and added one job would pass.
    select count(*) into v_others
    from cron.job
    where (jobname, schedule, command, active) in (
        ('app_push_jobs_drain',              '30 seconds', 'select public.process_app_push_jobs()',             true),
        ('cleanup_expired_data_nightly',     '7 3 * * *',  'SELECT public._cleanup_expired_data_internal();',    true),
        ('m10_send_due_notifications',       '* * * * *',  'select public.trigger_send_due_notifications()',     true),
        ('process_webhook_jobs',             '30 seconds', 'select public.process_webhook_jobs()',               true),
        ('remote_retention_cleanup_nightly', '47 3 * * *', 'SELECT public._cleanup_remote_retention_internal();', true),
        ('remote_swarms_cleanup_nightly',    '7 4 * * *',  'select public._cleanup_remote_swarms_internal();',   true),
        ('retention_cleanup_nightly',        '27 3 * * *', 'SELECT public._cleanup_retention_data_internal(18);', true),
        ('widget_refresh_hourly',            '13 * * * *', 'select public.process_widget_refresh()',             true)
    );
    if v_others <> 8 then
        raise exception 'v0.88: % of the 8 existing cron jobs are unchanged; expected all 8', v_others;
    end if;

    -- coalesce: a missing comment is NULL, and `NULL not like …` is NULL,
    -- which `if` reads as false. Without it a dropped statement passes.
    if coalesce(obj_description('public.anonymous_installs'::regclass, 'pg_class'), '') not like '%prune_anonymous_installs_nightly (migrate_v0.88)%activated on day 0%'
       or coalesce(obj_description('public.anonymous_installs'::regclass, 'pg_class'), '') like '%DO NOT DELETE ROWS%' then
        raise exception 'v0.88: the table comment was not rewritten';
    end if;
    if coalesce(col_description('public.anonymous_installs'::regclass,
                                (select attnum from pg_attribute
                                 where attrelid = 'public.anonymous_installs'::regclass
                                   and attname = 'last_seen_at')), '') not like '%NOT LIVENESS%IS the retention key%rates read high%' then
        raise exception 'v0.88: the last_seen_at comment was not rewritten';
    end if;
    if coalesce(col_description('public.anonymous_installs'::regclass,
                                (select attnum from pg_attribute
                                 where attrelid = 'public.anonymous_installs'::regclass
                                   and attname = 'first_seen_at')), '') not like 'When this row was created:%the day it came back%'
       or coalesce(col_description('public.anonymous_installs'::regclass,
                                   (select attnum from pg_attribute
                                    where attrelid = 'public.anonymous_installs'::regclass
                                      and attname = 'first_provider_detected_at')), '') not like 'First value:%Write-once per row%the day it came back%' then
        raise exception 'v0.88: the first_seen_at or first_provider_detected_at comment was not rewritten';
    end if;
    if coalesce(obj_description('public.anonymous_funnel_summary(integer)'::regprocedure, 'pg_proc'), '') not like 'Owner-only funnel readout:%PRUNING (migrate_v0.88%'
       or coalesce(obj_description('public.anonymous_activation_summary(integer)'::regprocedure, 'pg_proc'), '') not like '%PRUNING (migrate_v0.88%'
       or coalesce(obj_description('public.prune_anonymous_installs()'::regprocedure, 'pg_proc'), '') not like '%prune_anonymous_installs_nightly (migrate_v0.88)%' then
        raise exception 'v0.88: a function comment was not rewritten';
    end if;

    raise notice 'v0.88: prune_anonymous_installs_nightly scheduled at 37 4 * * *; the other 8 jobs are unchanged';
end
$migration$;

commit;

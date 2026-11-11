-- check_webhook_jobs_retention.sql — is the webhook queue's retention kept?
--
-- READ-ONLY. Not a migration, consumes no migration number. One SELECT; run it
-- against production (the Supabase MCP's execute_sql, or the SQL editor):
--   * after applying migrate_v0.91 (APPLY step 5), and
--   * in each release's verification.
-- It needs pg_cron: where the cron schema does not exist (plain local
-- Postgres) it fails with "relation cron.job does not exist".
-- Each row it returns names one problem. Once v0.91 is applied and the
-- nightly cleanup has run after it, it must return NO rows. Before that run
-- the one expected row is 'finalized jobs overdue': the backlog that the
-- v0.87 body never deleted. (Before v0.91 is applied it also returns
-- 'cleanup function changed'.)
--
-- WHY: migrate_v0.91 makes the nightly cleanup (pg_cron job
-- cleanup_expired_data_nightly, 03:07 UTC, running
-- _cleanup_expired_data_internal()) delete webhook jobs finalized more than a
-- day ago. That DELETE runs in its own savepoint: when it fails (a lock wait
-- past 5 s, say) the cleanup counts it, warns, cleans the other tables and
-- returns normally, so pg_cron records the run as succeeded. A run that
-- deleted nothing it should have looks like one that worked. So this checks:
--   * the job is there, active, and still runs exactly
--     'SELECT public._cleanup_expired_data_internal();' on '7 3 * * *';
--   * the cleanup is still v0.91's (body md5, as written or without its
--     comment-only lines; SECURITY DEFINER; pinned search_path). A reviewed
--     change to its body must update these md5s in the same PR;
--   * it has run; its last run did not fail (a run cancelled by a statement
--     timeout, which undoes all four tables' deletes, is recorded as failed);
--     a run started in the last 26 hours;
-- and the outcome:
--   * no finalized job is more than 49 hours past its processed_at. A job is
--     eligible 24 hours after it was finalized, and the next 03:07 run comes
--     at most 24 hours later; 1 hour of margin. A row past that means a run
--     that should have deleted it did not (the caught-and-warned failure
--     above, a missed run, or a changed body);
--   * no job is pending more than a day after it was enqueued (since v0.89 a
--     job is finalized within minutes; one pending a day means the worker is
--     not running, its vault secrets are missing, or v0.89 regressed). A
--     pending job is never pruned, so these would pile up unseen;
--   * no job is pending with its attempts used up and no request in flight
--     (attempt_count >= 3, pg_net_request_id NULL): v0.89's bug, back.
--
-- What it prints: problem names, counts, the schedule, a start time, and for
-- a changed command only the command's md5. Never the command itself, and
-- never a run's return_message: either can hold anything (an error message
-- quoting a value, a command someone edited by hand). A failed run is
-- reported with a fixed text. For the raw values, run the PRIVATE
-- INVESTIGATION query below and keep its answer out of logs, tickets and
-- pull requests.
--
-- "Last run" is the highest runid, not the latest start_time: pg_cron leaves
-- start_time NULL on a run that never got going, and NULLs sort first in a
-- descending order. The 26-hour test uses the latest start_time of any run of
-- this job. The job is found by name and its runs through its jobid.
--
-- Counts are of rows, never their contents.
--
-- PRIVATE INVESTIGATION (raw diagnostics, owner only; the answer stays out of
-- logs, tickets and pull requests): the job's command and its last three
-- runs, with their messages:
--   I1: select j.jobid, j.command, d.runid, d.status, d.start_time, d.return_message from cron.job j left join lateral (select runid, status, start_time, return_message from cron.job_run_details where jobid = j.jobid order by runid desc limit 3) d on true where j.jobname = 'cleanup_expired_data_nightly' order by d.runid desc;
--
-- Tested by backend/supabase/tests/run_v091_prune_webhook_jobs_tests.sh,
-- which makes each problem happen and requires this query to name it, and
-- feeds it a command and a run message holding synthetic secret text that
-- must not appear in its output.

with job as (
    select jobid, active, command, schedule
      from cron.job
     where jobname = 'cleanup_expired_data_nightly'
),
runs as (
    select d.runid, d.status, d.start_time
      from cron.job_run_details d
      join job j on j.jobid = d.jobid
),
last_run as (
    select status, start_time
      from runs
     order by runid desc
     limit 1
),
last_start as (
    select max(start_time) as at
      from runs
    having count(*) > 0
),
fn as (
    select p.prosrc, p.prosecdef, p.proconfig
      from pg_proc p
     where p.oid = to_regprocedure('public._cleanup_expired_data_internal()')
)
select 'job missing'::text as problem, null::text as detail
 where not exists (select 1 from job)
union all
select 'job inactive', null
  from job
 where not active
union all
select 'job command changed', 'command md5 ' || md5(command)
  from job
 where command <> 'SELECT public._cleanup_expired_data_internal();'
union all
select 'job schedule changed', schedule
  from job
 where schedule <> '7 3 * * *'
union all
select 'cleanup function changed', null
 where not exists (select 1 from fn
                    where md5(prosrc) in ('66cc459c36eedfdbed41eb2b7b8fb32e',   -- v0.91, as written
                                          '74c5e98322da9a2af3782091304c750c')   -- v0.91, without comment-only lines
                      and prosecdef
                      and proconfig = array['search_path=pg_catalog, public, extensions'])
union all
select 'no run recorded', null
  from job
 where not exists (select 1 from runs)
union all
select 'last run failed', 'status failed (its message: PRIVATE INVESTIGATION I1)'
  from last_run
 where status = 'failed'
union all
select 'no run in the last 26 hours', 'last run started at ' || coalesce(at::text, 'never')
  from last_start
 where coalesce(at, '-infinity') < now() - interval '26 hours'
union all
select 'finalized jobs overdue (finalized more than 49 hours ago)', count(*)::text
  from public.webhook_jobs
 where processed_at < now() - interval '49 hours'
having count(*) > 0
union all
select 'pending jobs older than 1 day', count(*)::text
  from public.webhook_jobs
 where processed_at is null
   and enqueued_at < now() - interval '1 day'
having count(*) > 0
union all
select 'stuck pending jobs (attempts used up, no request: v0.89''s bug)', count(*)::text
  from public.webhook_jobs
 where processed_at is null
   and attempt_count >= 3
   and pg_net_request_id is null
having count(*) > 0;

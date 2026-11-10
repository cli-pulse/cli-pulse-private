-- check_anonymous_install_retention.sql — is the 400-day promise being kept?
--
-- READ-ONLY. Not a migration, consumes no migration number. One SELECT; run it
-- against production (the Supabase MCP's execute_sql, or the SQL editor):
--   * after applying migrate_v0.88, and
--   * in each release's verification.
-- Each row it returns names one problem. It must return NO rows, except on
-- the day v0.88 is applied: until the job's first run (04:37 UTC) the one
-- expected row is 'no run recorded'.
--
-- WHY: PRIVACY.md promises "Anonymous install rows are deleted 400 days after
-- they were last touched". migrate_v0.88 schedules the nightly job that does
-- it, but until 2027-09-10 no row is old enough, so every run deletes nothing,
-- and a job that runs and deletes nothing looks exactly like one that works.
-- pg_cron's own record cannot tell them apart either: a run's return_message
-- is the row count of its SELECT ('1 row'), not the number deleted. So this
-- checks what can be checked before then:
--   * the job is there, active, and still runs exactly
--     'select public.prune_anonymous_installs()';
--   * the function is still v0.73's (body md5, SECURITY DEFINER, pinned
--     search_path). A reviewed change to its body must update this md5 in the
--     same PR, as it must update v0.88's guard;
--   * it has run; its last run did not fail; a run started in the last 26
--     hours (the job runs daily, so a rarer schedule or a stalled scheduler
--     shows up here);
-- and, once rows are old enough, the outcome: no row older than 401 days.
--
-- 401 days, not 400: the job runs once a day, so a row is deleted between 400
-- and 401 days after its last_seen_at. A row past 401 days means the job
-- missed at least one run it should have made.
--
-- "Last run" is the highest runid, not the latest start_time: pg_cron leaves
-- start_time NULL on a run that never got going (and a server restart can
-- leave such rows behind), and NULLs sort first in a descending order. The
-- 26-hour test uses the latest start_time any run of this job has.
--
-- Counts are of rows, never their contents.
--
-- Tested by backend/supabase/tests/run_v088_prune_anonymous_installs_cron_tests.sh,
-- which makes each problem happen and requires this query to name it.

with job as (
    select jobid, active, command
      from cron.job
     where jobname = 'prune_anonymous_installs_nightly'
),
runs as (
    select d.runid, d.status, d.start_time, d.return_message
      from cron.job_run_details d
      join job j on j.jobid = d.jobid
),
last_run as (
    select status, start_time, return_message
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
     where p.oid = to_regprocedure('public.prune_anonymous_installs()')
)
select 'job missing'::text as problem, null::text as detail
 where not exists (select 1 from job)
union all
select 'job inactive', null
  from job
 where not active
union all
select 'job command changed', command
  from job
 where command <> 'select public.prune_anonymous_installs()'
union all
select 'prune function changed', null
 where not exists (select 1 from fn
                    where md5(prosrc) = '29941fa052e043c75ed49fbad5a785d7'
                      and prosecdef
                      and proconfig = array['search_path=public, pg_temp'])
union all
select 'no run recorded', null
  from job
 where not exists (select 1 from runs)
union all
select 'last run failed', coalesce('at ' || start_time::text, return_message)
  from last_run
 where status = 'failed'
union all
select 'no run in the last 26 hours', 'last run started at ' || coalesce(at::text, 'never')
  from last_start
 where coalesce(at, '-infinity') < now() - interval '26 hours'
union all
select 'rows older than 401 days', count(*)::text
  from public.anonymous_installs
 where last_seen_at < now() - interval '401 days'
having count(*) > 0;

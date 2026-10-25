-- check_cron_references.sql — does every table a cron job touches exist?
--
-- READ-ONLY. Not a migration, consumes no migration number. One SELECT; run it
-- against production (the Supabase MCP's execute_sql, or the SQL editor):
--   * in the post-apply step of every migration, and
--   * in each release's verification.
-- It must return NO rows.
--
-- WHY: from v0.21 on, the nightly retention cleanup deleted from
-- `public.device_snapshots`, a table that never existed. The error was caught
-- inside the function, which rolled back every other delete with it, and
-- pg_cron recorded every run as succeeded, so for a year the cleanup deleted
-- nothing and nothing said so (migrate_v0.87 header). A cron job's status
-- cannot show this; reading the names its functions use can.
--
-- WHAT IT DOES: takes every active job in `cron.job`, the `public.<fn>` its
-- command calls, and every `public.<name>` in that function's body, then in
-- the bodies of the public functions those name, four calls deep. A name is
-- MISSING when it is neither a relation (table, view, sequence), a type nor a
-- public function. Each row says which job, which function's body named it,
-- and the missing name.
--
-- LIMITS: it reads only names written `public.<name>` (every cron function in
-- this repo qualifies its tables); a name in a `--` comment or a string counts
-- too, so a row can be a comment naming an old table (read the function, then
-- reword the comment). A function in another schema is not followed.
--
-- On 2026-10-26, before v0.87, production gave exactly one row:
--   cleanup_expired_data_nightly | _cleanup_expired_data_internal | public.device_snapshots
-- backend/supabase/tests/run_v087_retention_cleanup_tests.sh runs this file
-- as it stands, and shows it reports a missing table (negative control) and
-- reports nothing once every name exists.

with recursive walk(jobname, named_in, name, depth) as (
  select j.jobname::text, '(cron command)'::text, m[1] collate "default", 0
    from cron.job j
   cross join lateral regexp_matches(j.command, 'public\.([a-z_][a-z0-9_]*)', 'g') m
   where j.active
  union
  select w.jobname, w.name, r[1] collate "default", w.depth + 1
    from walk w
    join pg_proc p on p.proname::text = w.name
    join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
   cross join lateral regexp_matches(p.prosrc, 'public\.([a-z_][a-z0-9_]*)', 'g') r
   where w.depth < 4
),
named as (
  select distinct jobname, named_in, name from walk
)
select w.jobname, w.named_in, 'public.' || w.name as missing
  from named w
 where to_regclass('public.' || w.name) is null
   and to_regtype('public.' || w.name) is null
   and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname::text = w.name)
 order by 1, 2, 3;

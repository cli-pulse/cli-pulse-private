-- check_webhook_catalog.sql — the webhook queue's catalog fingerprint.
--
-- READ-ONLY. Not a migration, consumes no migration number. ONE select that
-- returns one column of text lines, sorted, so two runs can be diffed:
--   psql "$URL" -qtAX -f backend/supabase/ops/check_webhook_catalog.sql > prod.txt
-- It reads catalog METADATA, counts and md5 values only. It never selects a
-- row of webhook_jobs, alerts, vault.secrets or net._http_response, and it
-- prints no function body (only the body's md5).
--
-- WHY: schema.sql / app_rpc.sql (B0) carry a copy of the queue objects that
-- production got from migrate_v0.25 (+ v0.55's policy form, + v0.62's revoke).
-- The test suite proves the copy equals the migrations. Only running this file
-- in production and diffing it against the CI output (run_webhook_baseline_tests.sh
-- prints it for the fresh baseline) proves production equals the copy. The
-- v0.89 fix that reads net._http_response and the v0.91 prune are applied only
-- after that diff is clean, or every difference is explained.
--
-- Every object is named by schema and exact signature (to_regprocedure /
-- to_regclass), so an overload or a same-named object in another schema is
-- never picked; the first section counts same-named functions in ALL schemas
-- (expected 1 each).
--
-- Differences that are expected between production and the CI database and
-- go in the PR's allowed list: the owner role name (pg_get_userbyid), the
-- role-privilege ACL entries Supabase's default privileges add, the
-- pg_net / pg_cron / vault environment (plain Postgres has none of them;
-- the CI database installs a stand-in cron.job table, inactive), and the
-- ACL of alerts_enqueue_webhook(): it returns `trigger`, so it cannot be
-- called through RPC and its EXECUTE grant is informational. v0.25 never
-- revokes it (only v0.62 revokes the worker), so the baseline keeps
-- PostgreSQL's default for it; production's measured value, not an assumed
-- default, belongs in the allowed list if it differs.
--
-- Line format:  <section>|<key>|<value...>

with
sigs(name, sig) as (values
  ('process_webhook_jobs',             'public.process_webhook_jobs()'),
  ('alerts_enqueue_webhook',           'public.alerts_enqueue_webhook()'),
  ('_cleanup_expired_data_internal',   'public._cleanup_expired_data_internal()')
),
fn as (
  select s.name, s.sig, to_regprocedure(s.sig) as oid from sigs s
),
tbl as (select to_regclass('public.webhook_jobs') as oid),
seq as (select case when to_regclass('public.webhook_jobs') is not null
                then to_regclass(pg_get_serial_sequence('public.webhook_jobs', 'id')) end as oid),
roles(r) as (values ('anon'), ('authenticated'), ('service_role')),
cronjobs as (
  -- cron.job exists only where pg_cron is installed; read it dynamically so
  -- this file still runs where it does not.
  select x from (
    select case when to_regclass('cron.job') is not null then
      query_to_xml(
        $q$select jobid || '|' || coalesce(jobname, '') || '|' || coalesce(schedule, '')
               || '|' || coalesce(command, '') || '|' || coalesce(active::text, '')
               || '|' || coalesce(username, '') as l
             from cron.job where command ilike '%webhook%' order by jobid$q$,
        false, true, '')
    end as x
  ) q
),
lines(line) as (
  -- 1. functions: count in every schema, then attributes of the exact one
  select '1a|count|' || s.name || '|' || (select count(*) from pg_proc p where p.proname = s.name)
    from sigs s
  union all
  select '1b|' || f.name || '|owner=' || pg_get_userbyid(p.proowner)
         || '|secdef=' || p.prosecdef || '|volatility=' || p.provolatile::text
         || '|config=' || coalesce(p.proconfig::text, 'NULL')
         || '|acl=' || coalesce(p.proacl::text, 'NULL')
         || '|result=' || pg_get_function_result(p.oid)
         || '|lang=' || l.lanname
         || '|md5=' || md5(p.prosrc)
         || '|comment=' || coalesce(md5(obj_description(p.oid, 'pg_proc')), 'NULL')
    from fn f join pg_proc p on p.oid = f.oid join pg_language l on l.oid = p.prolang
  -- 2. columns of webhook_jobs
  union all
  select '2a|col|' || a.attnum || '|' || a.attname || '|' || format_type(a.atttypid, a.atttypmod)
         || '|notnull=' || a.attnotnull
         || '|default=' || coalesce(pg_get_expr(d.adbin, d.adrelid), 'NULL')
         || '|identity=' || a.attidentity::text || '|generated=' || a.attgenerated::text
         || '|comment=' || coalesce(md5(col_description(a.attrelid, a.attnum)), 'NULL')
    from tbl t join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  union all
  select '2b|sequence|' || coalesce(s.oid::regclass::text, 'NULL')
         || '|start=' || q.seqstart || '|inc=' || q.seqincrement || '|min=' || q.seqmin
         || '|max=' || q.seqmax || '|cache=' || q.seqcache || '|cycle=' || q.seqcycle
    from seq s join pg_sequence q on q.seqrelid = s.oid
  -- 3. constraints
  union all
  select '3|con|' || c.conname || '|' || c.contype::text || '|' || pg_get_constraintdef(c.oid)
    from tbl t join pg_constraint c on c.conrelid = t.oid
  -- 4. indexes
  union all
  select '4|idx|' || i.indexname || '|' || i.indexdef
    from pg_indexes i where i.schemaname = 'public' and i.tablename = 'webhook_jobs'
  -- 5. RLS, policies, table comment
  union all
  select '5a|rls|rowsecurity=' || c.relrowsecurity || '|force=' || c.relforcerowsecurity
         || '|owner=' || pg_get_userbyid(c.relowner)
         || '|reloptions=' || coalesce(c.reloptions::text, 'NULL')
         || '|acl=' || coalesce(c.relacl::text, 'NULL')
         || '|kind=' || c.relkind::text
         || '|comment=' || coalesce(md5(obj_description(c.oid, 'pg_class')), 'NULL')
    from tbl t join pg_class c on c.oid = t.oid
  union all
  select '5b|policy|' || p.policyname || '|permissive=' || p.permissive || '|roles=' || p.roles::text
         || '|cmd=' || p.cmd || '|using=' || coalesce(p.qual, 'NULL')
         || '|check=' || coalesce(p.with_check, 'NULL')
    from pg_policies p where p.schemaname = 'public' and p.tablename = 'webhook_jobs'
  -- 6. every non-internal trigger on alerts
  union all
  select '6|trigger|' || tg.tgname || '|enabled=' || tg.tgenabled::text || '|' || pg_get_triggerdef(tg.oid)
         || '|fn=' || tg.tgfoid::regprocedure::text
    from pg_trigger tg
   where tg.tgrelid = to_regclass('public.alerts') and not tg.tgisinternal
  -- 7. privileges
  union all
  select '7a|table|' || r.r || '|' || pr.p || '=' || coalesce(has_table_privilege(r.r, t.oid, pr.p)::text, 'NULL')
    from roles r cross join tbl t
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'), ('references'), ('trigger')) pr(p)
  union all
  select '7b|sequence|' || r.r || '|' || pr.p || '=' || coalesce(has_sequence_privilege(r.r, s.oid, pr.p)::text, 'NULL')
    from roles r cross join seq s cross join (values ('usage'), ('select'), ('update')) pr(p)
  union all
  select '7c|execute|' || r.r || '|' || f.name || '=' || coalesce(has_function_privilege(r.r, f.oid, 'EXECUTE')::text, 'NULL')
    from roles r cross join fn f
  union all
  select '7d|schema|' || r.r || '|' || n.n || '='
         || case when to_regnamespace(n.n) is null then 'absent'
                 else has_schema_privilege(r.r, n.n, 'USAGE')::text end
    from roles r cross join (values ('net'), ('vault')) n(n)
  -- 8. the environment v0.89 depends on (metadata only)
  union all
  select '8a|extension|' || e.n || '|' || coalesce((select extversion from pg_extension where extname = e.n), 'absent')
    from (values ('pg_net'), ('pg_cron')) e(n)
  union all
  select '8b|net._http_response|' || a.attnum || '|' || a.attname || '|' || format_type(a.atttypid, a.atttypmod)
    from pg_attribute a
   where a.attrelid = to_regclass('net._http_response') and a.attnum > 0 and not a.attisdropped
  union all
  select '8c|cron.job|' || v::text
    from cronjobs cj
    cross join lateral unnest(xpath('//l/text()', cj.x)) v
  union all
  select '8d|cron.job|count_matching_webhook|' || coalesce(array_length(xpath('//l', cj.x), 1), 0)
    from cronjobs cj
)
select line from lines order by line collate "C";

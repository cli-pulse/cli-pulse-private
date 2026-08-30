-- migrate_v0.77_revoke_remote_table_grants.sql
--
-- Take the blanket table grants off `anon` and `authenticated` for the remote
-- and machine command tables. Every legitimate write already goes through a
-- SECURITY DEFINER RPC, so these grants serve nothing — except one thing they
-- serve that nobody intended.
--
-- THE PART THAT IS NOT "DEFENCE IN DEPTH"
-- ---------------------------------------
-- The retirement plan said the grants "buy nothing, because RLS covers the
-- table". That is true of SELECT, INSERT, UPDATE and DELETE. It is NOT true of
-- TRUNCATE: Postgres does not apply row security policies to TRUNCATE at all.
-- A role holding the grant can empty the table regardless of every policy on
-- it.
--
-- Measured on a real Postgres 17.10, reproducing production's exact shape
-- (RLS on, one `for select using (auth.uid() = user_id)` policy, `grant all`
-- to `authenticated`):
--
--     SELECT    -> correctly scoped to the caller's own row
--     INSERT    -> ERROR: new row violates row-level security policy
--     UPDATE    -> UPDATE 0            (filtered)
--     TRUNCATE  -> TRUNCATE TABLE      ← succeeded; table emptied
--
-- Reachability, stated honestly: `anon` and `authenticated` are reached through
-- PostgREST, which never issues TRUNCATE, so this is a latent hole rather than
-- an open one. It is worth closing anyway, because the usual reassurance —
-- "RLS has it covered, we would need a stray CREATE POLICY to be exposed" —
-- is exactly the reasoning TRUNCATE escapes. It needs no policy at all.
--
-- WHY `machine_commands` IS IN THIS LIST
-- --------------------------------------
-- It is NOT part of the retirement. Machine controls (fan target, low power
-- mode, keep-awake) work and have been used: 5 rows, all `status = 'done'`,
-- picked up within ~0.3 s on 2026-07-09. It is here because it has the same
-- grant, the same TRUNCATE exposure, and unlike the remote_* tables it holds
-- real data. Leaving the live table exposed while hardening six empty ones
-- would be the wrong half.
--
-- WHY THIS IS SAFE — verified, not assumed
-- ----------------------------------------
--   1. NO CLIENT READS THESE TABLES DIRECTLY. `git grep` for
--      `/rest/v1/<table>` and for `.from("<table>")` across Swift, Kotlin and
--      Python returns nothing. The only `.from()` hits are in the
--      `send-approval-push` edge function, which builds its client with
--      SUPABASE_SERVICE_ROLE_KEY.
--   2. ALL 18 `remote_*` RPCs ARE `SECURITY DEFINER` (`pg_proc.prosecdef`),
--      so they execute as the owner and are unaffected by a grant to `anon` or
--      `authenticated`. That includes the machine-control path the live
--      feature depends on: `remote_helper_pull_machine_commands` and
--      `remote_helper_complete_machine_command`, both granted to `anon`.
--   3. `service_role` AND `postgres` HOLD THEIR OWN EXPLICIT GRANTS on every
--      one of these tables — not inherited through PUBLIC — so revoking from
--      PUBLIC cannot strand the edge function.
--   4. Realtime is unaffected: both event streams subscribe with
--      `postgres_changes: []` and use broadcast, so no table-level SELECT is
--      involved.
--
-- The policies are deliberately LEFT IN PLACE. Removing them would make the
-- tables readable again the moment anyone re-granted SELECT; keeping them
-- means the tables stay default-deny under two independent mechanisms.

do $migration$
declare
    t text;
    targets constant text[] := array[
        'remote_sessions',
        'remote_session_commands',
        'remote_session_events',
        'remote_permission_requests',
        'remote_permission_decisions',
        'remote_swarms',
        'machine_commands',
        'app_push_jobs'
    ];
begin
    foreach t in array targets loop
        -- `to_regclass` rather than a bare reference: this migration must be
        -- re-runnable, and must not fail on an environment that never created
        -- one of these tables.
        if to_regclass('public.' || t) is null then
            raise notice 'skipping %: table does not exist here', t;
            continue;
        end if;
        execute format('revoke all on public.%I from anon, authenticated, public', t);
    end loop;
end
$migration$;

-- Verification, in the migration itself. A revoke that silently did nothing
-- looks identical to a revoke that worked, and this repo has shipped guards
-- that were green while guarding nothing.
do $migration$
declare
    t text;
    r text;
    leftover text;
begin
    for t in
        select unnest(array[
            'remote_sessions','remote_session_commands','remote_session_events',
            'remote_permission_requests','remote_permission_decisions','remote_swarms',
            'machine_commands','app_push_jobs'])
    loop
        continue when to_regclass('public.' || t) is null;
        foreach r in array array['anon','authenticated'] loop
            select string_agg(privilege_type, ',') into leftover
            from information_schema.role_table_grants
            where table_schema = 'public' and table_name = t and grantee = r;
            if leftover is not null then
                raise exception 'revoke failed: % still holds % on %', r, leftover, t;
            end if;
        end loop;
        -- Positive control: the roles that MUST keep working still do. Without
        -- this, a migration that revoked from everyone would pass the check
        -- above and take the edge function down with it.
        if not has_table_privilege('service_role', 'public.' || t, 'SELECT') then
            raise exception 'service_role lost SELECT on % — the edge function needs it', t;
        end if;
    end loop;
    raise notice 'v0.77: anon/authenticated hold no privilege on any target table; service_role intact';
end
$migration$;

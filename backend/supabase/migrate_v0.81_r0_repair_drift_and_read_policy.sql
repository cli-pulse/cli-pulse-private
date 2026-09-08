-- ============================================================
-- v0.81 — R0 repair: v0.65 never took effect, and v0.77 killed the READ policy
-- Date: 2026-09-08 · *** ADDITIVE + INERT — SAFE TO APPLY (see below) ***
--
-- Measured 2026-09-07 against prod (gkjwsxotmwrgqsvfijzs):
--   select count(*) from public.user_settings where realtime_private_enabled;  -- 0 of 218 (measured 2026-09-08)
-- The realtime_private cutover is still OFF for 100% of users, so sections
-- (1)-(3) — the role, the two oracles and the two realtime.messages policies
-- — govern NOTHING today.
--
-- Section (4) is different and deserves saying out loud, because "the cutover
-- is off" does NOT cover it: it changes EXECUTE grants on three live RPCs.
-- It is still inert, for its own reasons, each checked rather than assumed:
-- ⚠️ CORRECTED before applying. An earlier draft of this comment said anon
-- was "already revoked by v0.36 / v0.37" for two of the three. That was
-- written from those migrations' intent, not from `pg_proc.proacl`, and it is
-- FALSE. Measured on production 2026-09-08:
--
--   register_desktop_helper(text,text,text,text)
--     proacl {=X/postgres,postgres=X,authenticated=X,service_role=X}
--   get_daily_usage_by_device(integer)                    same shape
--   upsert_daily_usage(jsonb,uuid)                        same, plus anon=X
--   has_function_privilege('anon', …, 'EXECUTE')  →  TRUE for all THREE
--
-- v0.36/v0.37 removed the explicit `anon=X` entries; they left the PUBLIC
-- grant (the leading `=X/postgres`), and anon inherits PUBLIC. So section (4)
-- genuinely REMOVES anon's reach rather than tidying a dead grant.
--
-- It is still inert in OUTCOME, by the third argument applied to all three
-- rather than to one: `pg_get_functiondef` shows every one of them references
-- `auth.uid()` and raises 'Not authenticated', so an anon caller has always
-- received an exception. All three end with
-- `grant execute … to authenticated, service_role`, which is who calls them
-- today. So: no behaviour change — but by a DIFFERENT argument from the one
-- that covers sections (1)-(3), not the same one.
--
-- ── PROBLEM 1: the ledger says v0.65 applied; none of it is there ──
-- `supabase_migrations.schema_migrations` carries
-- `20260704045711 v0_65_r0_token_least_privilege`. Measured on the live DB:
--
--   select count(*) from pg_roles where rolname='r0_broadcast';            -- 0
--   select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--     where n.nspname='public' and p.proname='r0_broadcast_topic_allowed'; -- 0
--   select policyname, roles from pg_policies
--     where schemaname='realtime' and tablename='messages';
--     -- both still {authenticated}, both still v0.56's inlined EXISTS
--
-- So the F1 fix is NOT in effect, and the deployed `mint-realtime-token`
-- (v4, 2026-07-03/04) is likewise still the pre-v0.65 build signing
-- `role: "authenticated"` — the account-wide authority v0.65 exists to remove.
-- The repo's `token.ts` disagrees with production. Re-deploying that function
-- is an OWNER step and is NOT part of this migration; see the runbook note.
--
-- ⚠️ Believe objects, never the ledger row. A ledger entry records that a
--    migration was RUN, not that its objects survived.
--
-- HOW IT GOT THIS WAY IS NOT KNOWN, and this migration does not pretend to
-- know. The script is one implicit transaction, so a partial commit is not
-- the explanation; a ledger row written without the body executing, a later
-- manual revert, or a restore are all consistent with what is observable
-- today. Recording a guess here would be worse than recording the gap.
-- What follows from it regardless: after APPLYING this, run the post-apply
-- queries at the foot of the file and confirm them BY HAND. A green apply is
-- not evidence; `select count(*) from pg_roles where rolname='r0_broadcast'`
-- returning 1 is.
--
-- ── PROBLEM 2: v0.65 and v0.77 are incompatible, and nobody noticed ──
-- v0.65 deliberately left the READ policy exactly as v0.56 defined it —
-- `to authenticated`, with an inlined `exists (select 1 from
-- public.remote_sessions ...)` — because mobile subscribers read with their
-- own GoTrue login token. That was correct at the time.
--
-- v0.77 (2026-08-30) then revoked `authenticated`'s grants on the remote_*
-- tables. A policy expression is evaluated as the CURRENT role, so the READ
-- policy's own body can no longer run. Measured, as a returned value rather
-- than a NOTICE (and not inside a bare `do $$` block — both are invisible or
-- vacuous here):
--
--   as postgres      -> RAN OK
--   as authenticated -> FAILS: 42501 permission denied for table remote_sessions
--
-- The WRITE policy has the same body today and fails the same way. So the R0
-- private terminal is dead on production in BOTH directions; the only reason
-- no user has hit it is that the cutover flag is false for all 218 accounts.
--
-- ── PROBLEM 3: one statement v0.65 needs cannot be issued from here ──
-- v0.65's whole point is that r0_broadcast's ONLY reach is INSERT on
-- realtime.messages. Measured on production 2026-09-08 as the applying role:
--
--   has_table_privilege('postgres','realtime.messages','INSERT')        true
--   has_table_privilege('postgres',…,'INSERT WITH GRANT OPTION')        FALSE
--   pg_has_role('postgres','supabase_realtime_admin','USAGE')           false
--
-- A GRANT whose grantor holds no grant option does not error: PostgreSQL
-- warns 'no privileges were granted' and returns success. Putting it in this
-- file would have granted nothing while every assertion still passed — the
-- apply would have reported green with the write path dead. So it, and the
-- WRITE policy that depends on it, are split into v0.82, which must be run by
-- a supabase_admin-class role (Supabase support, or after they grant postgres
-- membership in supabase_realtime_admin).
--
-- Policy DDL itself is fine from here, despite postgres not owning the table:
-- supautils.policy_grants lists realtime.messages for postgres, and v0.56
-- created the live policies exactly this way.
--
-- ── FIX ───────────────────────────────────────────────────────
-- (1) and (2)  Re-apply v0.65's role, its schema grant and the write oracle,
--              verbatim. Every statement is idempotent by construction, so
--              this is a repair, not a second migration of the same thing.
--              NOT the INSERT grant and NOT the WRITE policy retarget — see
--              PROBLEM 3 above; those are v0.82's.
-- (3)          NEW: give the READ policy the same treatment the WRITE policy
--              got. It keeps `to authenticated` (subscribers really do read
--              with their own login token), but the ownership check moves
--              into a SECURITY DEFINER oracle so the policy body no longer
--              needs a table grant the caller does not have. This is the half
--              v0.65 did not need and v0.77 made necessary.
-- (4)          Re-apply v0.65's three PUBLIC-grant re-scopes, verbatim.
--
-- (The numbers above are the section numbers in the body below. An earlier
--  draft of this summary numbered them 1..3 / 4 and did not match, which in a
--  file someone applies by hand is a defect of its own.)
--
-- ⚠️ OWNER RUNBOOK — unchanged from v0.65, and now with one addition:
--    BEFORE the cutover, RE-DEPLOY `mint-realtime-token`. Production is
--    running the pre-v0.65 build; applying this migration alone would leave a
--    token claiming `role: authenticated` against a WRITE policy that admits
--    only `r0_broadcast`, i.e. broadcast would fail closed. Deploy first or
--    together, never this alone with the cutover flipped.
--    The v0.65 integration gate still stands: mint an r0_broadcast token and
--    confirm POST /realtime/v1/api/broadcast to the session's pterm: topic
--    delivers, and that a cross-session token does not.
--
-- This whole script runs as ONE transaction.
-- ============================================================

-- ------------------------------------------------------------
-- (1) Dedicated least-privilege role for realtime broadcast writes.
--     NOLOGIN: assumed only via the minted JWT's `role` claim. Idempotent.
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'r0_broadcast') then
    create role r0_broadcast nologin;
  end if;
end
$$;

grant r0_broadcast to authenticator;

grant usage on schema realtime to r0_broadcast;

-- NOT HERE: `grant insert on realtime.messages to r0_broadcast`.
-- Measured on production 2026-09-08, as the role that applies this file:
--     has_table_privilege('postgres','realtime.messages','INSERT')  → true
--     …'INSERT WITH GRANT OPTION'                                   → FALSE
--     pg_has_role('postgres','supabase_realtime_admin','USAGE')     → false
-- A GRANT whose grantor holds no grant option does NOT error. Postgres emits
--     WARNING: no privileges were granted for "messages"
-- and returns success. It would have granted nothing, every assertion below
-- would still have passed, and the apply would have reported green while the
-- role this file exists to build had zero privilege on the table.
--
-- That statement, and the WRITE policy that depends on it, are in
-- migrate_v0.82 — which must be run by a supabase_admin-class role. Splitting
-- them is the whole point: each file's assertions are now true of what that
-- file actually does.

-- ------------------------------------------------------------
-- (2) WRITE authorization oracle. Body copied verbatim from v0.65 §2a.
--     NEVER cast realtime.topic() — a ::uuid cast throws 22P02 on a malformed
--     topic → DoS. Compare constructed strings.
-- ------------------------------------------------------------
create or replace function public.r0_broadcast_topic_allowed(p_topic text)
returns boolean
language sql
security definer
stable
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
  select exists (
    select 1 from public.remote_sessions rs
    where rs.user_id = (select auth.uid())
      and rs.realtime_private is true
      and rs.id::text = nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'r0_session_id'
      and 'pterm:' || rs.id::text = p_topic
  );
$function$;

revoke all on function public.r0_broadcast_topic_allowed(text) from public, anon, authenticated;
grant execute on function public.r0_broadcast_topic_allowed(text) to r0_broadcast, service_role;

-- The WRITE policy retarget lives in v0.82, with the grant it depends on.
-- Retargeting it to r0_broadcast HERE would point the only write path at a
-- role that (see above) cannot be given INSERT from this connection — trading
-- one dead write path for another while claiming a repair.

-- ------------------------------------------------------------
-- (3) NEW — READ authorization oracle, and the retargeted READ policy.
--
--     Same shape as (2) and for the same reason, but a DIFFERENT predicate,
--     and the difference is load-bearing: the read side must NOT require the
--     `r0_session_id` claim. Subscribers arrive with their own GoTrue login
--     JWT, which carries no such claim, so requiring it would deny every
--     legitimate reader. Ownership + realtime_private + topic is the whole
--     check, exactly as v0.56 intended — only the evaluation moves.
--
--     Granted to `authenticated` on purpose: that is who the policy targets.
--     Revoked from public/anon first because Supabase auto-grants EXECUTE on
--     every new public function to anon/authenticated/service_role (the
--     v0.65 / v0.59.1 trap). anon would fail closed anyway — auth.uid() is
--     null there, so the exists() finds nothing — but leaving a dead grant
--     in place is how the next reader mis-reads the boundary.
-- ------------------------------------------------------------
create or replace function public.r0_read_topic_allowed(p_topic text)
returns boolean
language sql
security definer
stable
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
  select exists (
    select 1 from public.remote_sessions rs
    where rs.user_id = (select auth.uid())
      and rs.realtime_private is true
      and 'pterm:' || rs.id::text = p_topic
  );
$function$;

revoke all on function public.r0_read_topic_allowed(text) from public, anon;
grant execute on function public.r0_read_topic_allowed(text) to authenticated, service_role;

drop policy if exists "r0 read own remote session terminal" on realtime.messages;
create policy "r0 read own remote session terminal"
  on realtime.messages for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and public.r0_read_topic_allowed(realtime.topic())
  );

-- ------------------------------------------------------------
-- (4) Re-scope the three PUBLIC-granted, auth.uid()-scoped SECURITY DEFINER
--     functions a leaked r0_broadcast token (sub=owner) could otherwise
--     invoke AS the owner. Verbatim from v0.65 §3. Idempotent.
-- ------------------------------------------------------------
revoke execute on function public.register_desktop_helper(text, text, text, text) from public, anon;
grant  execute on function public.register_desktop_helper(text, text, text, text) to authenticated, service_role;

revoke execute on function public.upsert_daily_usage(jsonb, uuid) from public, anon;
grant  execute on function public.upsert_daily_usage(jsonb, uuid) to authenticated, service_role;

revoke execute on function public.get_daily_usage_by_device(integer) from public, anon;
grant  execute on function public.get_daily_usage_by_device(integer) to authenticated, service_role;

-- ------------------------------------------------------------
-- In-transaction assertions.
--
-- Deliberately NOT `raise notice`: notices are invisible to the apply tool
-- that runs this, so an assertion that only warns is an assertion that never
-- fires. Each of these ABORTS the transaction, and each is written so that it
-- would have FAILED against the pre-apply state measured above — a predicate
-- that passes either way certifies nothing.
-- ------------------------------------------------------------
do $$
begin
  -- Would have failed before: the role did not exist.
  if not exists (select 1 from pg_roles where rolname = 'r0_broadcast' and not rolcanlogin) then
    raise exception 'r0_broadcast missing or is a LOGIN role';
  end if;

  -- Would have failed before: neither oracle existed.
  if to_regprocedure('public.r0_broadcast_topic_allowed(text)') is null
     or to_regprocedure('public.r0_read_topic_allowed(text)') is null then
    raise exception 'an authorization oracle is missing';
  end if;

  -- THE ONE THE FIRST DRAFT WAS MISSING. `grant usage on schema realtime`
  -- succeeds (postgres holds USAGE *with grant option* there), but nothing
  -- verified it, and the sibling INSERT grant fails SILENTLY — which is why
  -- it is not in this file at all. Assert the grant that IS issued here, so a
  -- future edit cannot reintroduce a silent no-op unnoticed.
  if not has_schema_privilege('r0_broadcast', 'realtime', 'USAGE') then
    raise exception 'r0_broadcast has no USAGE on schema realtime — the grant no-opped';
  end if;

  -- authenticator must be able to SET ROLE into it, or the minted token can
  -- never assume the role. Would have failed before: the role did not exist.
  --
  -- 'SET', NOT 'USAGE'. `authenticator` is NOINHERIT, and for a NOINHERIT
  -- member `pg_has_role(…,'USAGE')` is FALSE even when the grant is perfect —
  -- so the obvious spelling would have aborted a CORRECT apply. Measured on
  -- production against an existing, working membership rather than reasoned
  -- about: pg_has_role('authenticator','authenticated', …) returns
  -- USAGE=false, SET=true, MEMBER=true on PostgreSQL 17.6.
  if not pg_has_role('authenticator', 'r0_broadcast', 'SET') then
    raise exception 'authenticator cannot SET ROLE into r0_broadcast';
  end if;

  -- And the honest converse: this file deliberately does NOT give r0_broadcast
  -- INSERT on realtime.messages, and must not appear to. If a future edit adds
  -- it back here it will silently no-op, so fail loudly if it is ever present
  -- without v0.82 having run.
  if has_table_privilege('r0_broadcast', 'realtime.messages', 'INSERT') then
    raise exception
      'r0_broadcast already has INSERT on realtime.messages — v0.82 has run, so '
      'this file is not the right place to be asserting the write path';
  end if;

  -- THE POINT OF THIS MIGRATION: neither policy body may name a public table
  -- any more, because the role each targets has no grant on it. Checked
  -- against the catalogue rather than against intent.
  if exists (
    select 1 from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      -- READ only: the WRITE policy is v0.82's to fix, and until then it
      -- legitimately still carries v0.56's inlined body.
      and policyname = 'r0 read own remote session terminal'
      and (coalesce(qual, '') like '%remote_sessions%'
        or coalesce(with_check, '') like '%remote_sessions%')
  ) then
    raise exception 'a policy still inlines remote_sessions — it will fail 42501 for its own role';
  end if;

  -- The read oracle must be callable by the role its policy targets, and the
  -- write oracle must NOT be.
  if not has_function_privilege('authenticated', 'public.r0_read_topic_allowed(text)', 'EXECUTE') then
    raise exception 'authenticated cannot execute the read oracle — the READ policy would abort';
  end if;
  if has_function_privilege('authenticated', 'public.r0_broadcast_topic_allowed(text)', 'EXECUTE') then
    raise exception 'authenticated can execute the write oracle — the v0.59.1 auto-grant trap is back';
  end if;
end
$$;

-- ============================================================
-- Post-apply verification (run manually after APPLY):
--   select rolname, rolcanlogin from pg_roles where rolname='r0_broadcast';   -- 1 row, f
--   select has_table_privilege('r0_broadcast','public.devices','SELECT');     -- false
--   select has_table_privilege('r0_broadcast','realtime.messages','INSERT');  -- FALSE
--       ^ false is CORRECT after this file. postgres cannot grant it (no grant
--         option); v0.82 owes it, run by a supabase_admin-class role. If this
--         is true, v0.82 has already run.
--   select pg_has_role('authenticator','r0_broadcast','SET');                 -- true
--       ^ 'SET', not 'USAGE': authenticator is NOINHERIT, so USAGE is false
--         even when the grant is perfect. Measured on 17.6.
--   select policyname, roles::text, qual, with_check from pg_policies
--     where schemaname='realtime' and tablename='messages';
--     -- read  -> {authenticated}, and its body must NOT name remote_sessions
--     -- write -> still {authenticated} with v0.56's inlined body. That is
--     --          EXPECTED here and is v0.82's to fix; it is dead either way
--     --          until then, and nothing uses it (0 of 218 accounts have the
--     --          cutover flag).
--   select has_function_privilege('anon','public.register_desktop_helper(text,text,text,text)','EXECUTE'); -- false
--
--   -- And the check that actually reproduces the outage this repairs:
--   create or replace function pg_temp.probe(p text) returns text language plpgsql as $$
--   begin perform public.r0_read_topic_allowed(p); return 'RAN OK';
--   exception when others then return 'FAILS: '||sqlstate||' '||sqlerrm; end $$;
--   select (select set_config('role','authenticated',true)),
--          (select pg_temp.probe('pterm:00000000-0000-0000-0000-000000000000'));
--     -- must be 'RAN OK'; it was 'FAILS: 42501 permission denied' before.
-- ============================================================

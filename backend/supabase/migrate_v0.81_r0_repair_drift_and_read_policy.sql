-- ============================================================
-- v0.81 — R0 repair: v0.65 never took effect, and v0.77 killed the READ policy
-- Date: 2026-09-07 · *** ADDITIVE + INERT — SAFE TO APPLY (see below) ***
--
-- Measured 2026-09-07 against prod (gkjwsxotmwrgqsvfijzs):
--   select count(*) from public.user_settings where realtime_private_enabled;  -- 0 of 216
-- The realtime_private cutover is still OFF for 100% of users, so sections
-- (1)-(3) — the role, the two oracles and the two realtime.messages policies
-- — govern NOTHING today.
--
-- Section (4) is different and deserves saying out loud, because "the cutover
-- is off" does NOT cover it: it changes EXECUTE grants on three live RPCs.
-- It is still inert, for its own reasons, each checked rather than assumed:
--   * register_desktop_helper      — anon already revoked by v0.36
--   * get_daily_usage_by_device    — anon already revoked by v0.37
--   * upsert_daily_usage           — raises 'Not authenticated' when
--                                    auth.uid() is null, so its anon grant is
--                                    dead code; every real caller is
--                                    authenticated
-- and all three end with `grant execute … to authenticated, service_role`,
-- which is who calls them today. So: no behaviour change, but by a different
-- argument than sections (1)-(3), not the same one.
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
-- no user has hit it is that the cutover flag is false for all 216 accounts.
--
-- ── FIX ───────────────────────────────────────────────────────
-- (1) and (2)  Re-apply v0.65's role, grants, write oracle and retargeted
--              WRITE policy, verbatim. Every statement there is idempotent by
--              construction, so this is a repair, not a second migration of
--              the same thing.
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
grant insert on realtime.messages to r0_broadcast;

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

drop policy if exists "r0 broadcast own remote session terminal" on realtime.messages;
create policy "r0 broadcast own remote session terminal"
  on realtime.messages for insert to r0_broadcast
  with check (
    realtime.messages.extension = 'broadcast'
    and public.r0_broadcast_topic_allowed(realtime.topic())
  );

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

  -- Would have failed before: the WRITE policy targeted {authenticated}.
  if not exists (
    select 1 from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      and policyname = 'r0 broadcast own remote session terminal'
      and roles::text = '{r0_broadcast}'
  ) then
    raise exception 'the WRITE policy does not target r0_broadcast';
  end if;

  -- THE POINT OF THIS MIGRATION: neither policy body may name a public table
  -- any more, because the role each targets has no grant on it. Checked
  -- against the catalogue rather than against intent.
  if exists (
    select 1 from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      and policyname in ('r0 broadcast own remote session terminal',
                         'r0 read own remote session terminal')
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
--   select has_table_privilege('r0_broadcast','realtime.messages','INSERT');  -- true
--   select pg_has_role('authenticator','r0_broadcast','SET');                 -- true
--   select policyname, roles::text, qual, with_check from pg_policies
--     where schemaname='realtime' and tablename='messages';
--     -- write -> {r0_broadcast}, read -> {authenticated}, NEITHER naming remote_sessions
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

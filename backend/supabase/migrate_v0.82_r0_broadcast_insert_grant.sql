-- ============================================================
-- v0.82 — the one grant v0.81 could not issue, and the policy that needs it
-- Date: 2026-09-08 · *** NOT APPLIED — REQUIRES A supabase_admin-CLASS ROLE ***
--
-- ⚠️ RUN AS `postgres` AND THIS FILE DOES NOT ERROR. It warns and does
--    nothing. The assertion block at the foot turns that silence into an
--    abort, which is the entire reason this is a separate file.
--
-- ── Why it is separate ────────────────────────────────────────
-- v0.65's design gives r0_broadcast exactly one reach: INSERT on
-- realtime.messages. That single grant is the one thing the owner of a hosted
-- Supabase project CANNOT issue. Measured on production 2026-09-08, as the
-- role that applies migrations here:
--
--   pg_get_userbyid(relowner) for realtime.messages     supabase_realtime_admin
--   relacl                          postgres=arwdDxtm/supabase_realtime_admin
--                                   ^ 'a' = INSERT, and NO '*' = no grant option
--   has_table_privilege('postgres','realtime.messages','INSERT')        true
--   has_table_privilege('postgres', …, 'INSERT WITH GRANT OPTION')      FALSE
--   pg_has_role('postgres','supabase_realtime_admin','SET')             false
--   pg_has_role('postgres','supabase_realtime_admin','MEMBER')          false
--
-- (An earlier draft of this header probed that membership with 'USAGE'. That
--  is the NOINHERIT trap v0.81's defect #2 was about — supabase_realtime_admin
--  has rolinherit=false, so USAGE reads false even when membership is perfect,
--  and the probe would have "confirmed" the blocker for the wrong reason. 'SET'
--  is the right question, and it answers false too, so the conclusion survives
--  its own correction. The evidence did not; hence this rewrite.)
--
-- PostgreSQL does not raise when a grantor lacks the grant option. It emits
--   WARNING:  no privileges were granted for "messages"
-- and returns success. That was reasoned about when v0.81 was split; on
-- 2026-09-08 it was REPRODUCED, inside a transaction that was then rolled back:
--
--   begin;
--   grant insert on realtime.messages to r0_broadcast;          -- reports success
--   select has_table_privilege('r0_broadcast','realtime.messages','INSERT');
--     -- => false
--   rollback;
--
-- Had this statement stayed in v0.81 it would have granted nothing, every
-- assertion there would still have passed, and the apply would have reported
-- green with the write path dead — the precise shape of failure that produced
-- PROBLEM 1 in v0.81's own header.
--
-- Note what is NOT the obstacle: policy DDL. `supautils.policy_grants` lists
-- realtime.messages for postgres, and v0.56 created the live policies exactly
-- that way. Only the GRANT needs a higher role.
--
-- ── How to get it applied ─────────────────────────────────────
-- Supabase support, or the platform superuser channel. Ask for exactly these
-- statements as supabase_admin, and nothing else.
--
-- ⛔ DO NOT go looking for a self-service way around this. An earlier draft of
--    this header offered one — "an alternative that would let the owner apply
--    it directly is `grant supabase_realtime_admin to postgres`" — and it does
--    not exist. Tried on production 2026-09-08 inside a transaction that was
--    then aborted:
--
--      ERROR:  42501: "supabase_realtime_admin" role memberships are reserved,
--                     only superusers can grant them
--
--    `supautils.reserved_memberships` names supabase_realtime_admin explicitly,
--    so this is closed by platform configuration, not by an accident of setup.
--    The false alternative is recorded here rather than deleted, because a
--    deleted dead end gets rediscovered.
--
-- ⚠️ What this means for the DESIGN, not just this file: on hosted Supabase a
--    custom Postgres role can never hold INSERT on realtime.messages without
--    the platform's help. v0.65's least-privilege broadcast role is therefore
--    not "pending an owner step" — it is pending a SUPPORT REQUEST, and support
--    may reasonably decline to grant a customer role privileges on a managed
--    schema. If they do, R0's write side needs a different design.
--
--    The obvious candidate is a SECURITY DEFINER function owned by `postgres`,
--    which DOES hold INSERT on realtime.messages, exposed to r0_broadcast by
--    EXECUTE alone. Two things must be said about it in the same breath,
--    because the idea is much more attractive than it is safe:
--
--      * realtime.send cannot be used for this. Checked: prosecdef = false.
--      * `postgres` is rolbypassrls = true, and SECURITY DEFINER runs as the
--        OWNER, so such a function DOES NOT GET CHECKED BY THE WRITE POLICY AT
--        ALL. Measured 2026-09-08 in a transaction that was then aborted: a
--        definer function owned by postgres read a table carrying a
--        `using (false)` deny-all policy and saw its row anyway.
--
--        That inverts the whole authorization story. Today the policy is the
--        boundary and the oracle is its helper; under a definer function there
--        IS no policy in the path, and every topic/ownership check has to live
--        inside the function body — where a missing predicate is not a denied
--        write but an unbounded one, to any topic, for any session.
--
--    So: written down as a direction, explicitly NOT as a recommendation. Do
--    not reach for it because this file made it sound close.
--
-- ── Order ─────────────────────────────────────────────────────
-- v0.81 first (it creates the role this grants to). Then this.
--
-- The re-deploy this file used to demand has ALREADY HAPPENED: production ran
-- the pre-v0.65 build signing `role: "authenticated"` until 2026-09-08, when
-- `mint-realtime-token` was redeployed to v5. Verified against the deployed
-- source, not the repo: v5 signs `role: "r0_broadcast"`.
--
-- So the production write path is currently dead THREE ways, and it is worth
-- being precise about which, because each has a different owner:
--   1. the token says role=r0_broadcast; the WRITE policy still targets
--      {authenticated} — nothing matches                     (this file fixes)
--   2. r0_broadcast holds no INSERT on realtime.messages — denied before any
--      policy is consulted                                   (support fixes)
--   3. the WRITE policy body still inlines remote_sessions, which r0_broadcast
--      cannot SELECT — it would 42501 for its own role        (this file fixes)
--
-- It governs nothing today: `select count(*) from public.user_settings where
-- realtime_private_enabled` = 0 of 216 on 2026-09-08. That is the ONLY reason
-- this is a latent defect and not an outage. Do not flip the cutover for any
-- account until 1-3 are all closed and the integration gate below has run.
-- ============================================================

set lock_timeout = '5s';

-- The statement v0.81 could not issue.
grant insert on realtime.messages to r0_broadcast;

-- And the policy that depends on it. Verbatim from v0.65 §2b.
drop policy if exists "r0 broadcast own remote session terminal" on realtime.messages;
create policy "r0 broadcast own remote session terminal"
  on realtime.messages for insert to r0_broadcast
  with check (
    realtime.messages.extension = 'broadcast'
    and public.r0_broadcast_topic_allowed(realtime.topic())
  );

do $$
begin
  -- v0.81 must have run: this file grants to a role it does not create.
  if not exists (select 1 from pg_roles where rolname = 'r0_broadcast') then
    raise exception 'r0_broadcast does not exist — apply v0.81 first';
  end if;

  -- THE WHOLE POINT. Without this the grant above is a silent no-op and the
  -- apply reports success with the write path dead.
  if not has_table_privilege('r0_broadcast', 'realtime.messages', 'INSERT') then
    raise exception
      'the grant did not take: r0_broadcast still has no INSERT on '
      'realtime.messages. Ran as %, which holds INSERT WITHOUT grant option; '
      'this file must be run by a supabase_admin-class role.', current_user;
  end if;

  -- Least privilege is the reason r0_broadcast exists. If it gained more than
  -- INSERT, the grant was issued too broadly and v0.65's argument collapses.
  if has_table_privilege('r0_broadcast', 'realtime.messages', 'SELECT')
     or has_table_privilege('r0_broadcast', 'realtime.messages', 'UPDATE')
     or has_table_privilege('r0_broadcast', 'realtime.messages', 'DELETE')
     or has_table_privilege('r0_broadcast', 'public.remote_sessions', 'SELECT') then
    raise exception 'r0_broadcast gained more than INSERT — re-read the grant';
  end if;

  -- The policy must target the least-privilege role, not authenticated.
  if not exists (
    select 1 from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      and policyname = 'r0 broadcast own remote session terminal'
      and roles::text = '{r0_broadcast}'
  ) then
    raise exception 'the WRITE policy does not target r0_broadcast';
  end if;

  -- And it must no longer inline the table, for the same reason v0.81 fixed
  -- the READ side: r0_broadcast has no SELECT on remote_sessions, so an
  -- inlined body would 42501 for its own role.
  if exists (
    select 1 from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      and policyname = 'r0 broadcast own remote session terminal'
      and coalesce(with_check, '') like '%remote_sessions%'
  ) then
    raise exception 'the WRITE policy still inlines remote_sessions';
  end if;
end
$$;

reset lock_timeout;

-- ============================================================
-- Post-apply, by hand — a green apply is not evidence:
--   select has_table_privilege('r0_broadcast','realtime.messages','INSERT'); -- true
--   select has_table_privilege('r0_broadcast','realtime.messages','SELECT'); -- false
--   select policyname, roles::text, with_check from pg_policies
--    where schemaname='realtime' and tablename='messages';
--     -- write -> {r0_broadcast}, body calls r0_broadcast_topic_allowed(...)
--
-- Only then the v0.65 cutover gate: re-deploy mint-realtime-token, mint an
-- r0_broadcast token, confirm POST /realtime/v1/api/broadcast to that
-- session's pterm: topic delivers, and that a cross-session token does NOT.
-- ============================================================

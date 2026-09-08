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
-- realtime.messages. Measured on production 2026-09-08, as the role that
-- applies migrations here:
--
--   has_table_privilege('postgres','realtime.messages','INSERT')        true
--   has_table_privilege('postgres', …, 'INSERT WITH GRANT OPTION')      FALSE
--   pg_has_role('postgres','supabase_realtime_admin','USAGE')           false
--   pg_get_userbyid(relowner) for realtime.messages     supabase_realtime_admin
--
-- PostgreSQL does not raise when a grantor lacks the grant option. It emits
--   WARNING:  no privileges were granted for "messages"
-- and returns success. Had this statement stayed in v0.81 it would have
-- granted nothing, every assertion there would still have passed, and the
-- apply would have reported green with the write path dead — the precise
-- shape of failure that produced PROBLEM 1 in v0.81's own header.
--
-- Note what is NOT the obstacle: policy DDL. `supautils.policy_grants` lists
-- realtime.messages for postgres, and v0.56 created the live policies exactly
-- that way. Only the GRANT needs a higher role.
--
-- ── How to get it applied ─────────────────────────────────────
-- Supabase support, or the platform superuser channel. Ask for exactly these
-- statements as supabase_admin, and nothing else. An alternative that would
-- let the owner apply it directly is `grant supabase_realtime_admin to
-- postgres`, but that is a much larger privilege than this needs.
--
-- ── Order ─────────────────────────────────────────────────────
-- v0.81 first (it creates the role this grants to). Then this. Then, BEFORE
-- any cutover, re-deploy `mint-realtime-token`: production still runs the
-- pre-v0.65 build signing `role: "authenticated"`, and after this file the
-- WRITE policy admits only r0_broadcast, so broadcast would fail closed.
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

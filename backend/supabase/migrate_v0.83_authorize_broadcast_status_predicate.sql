-- ============================================================
-- v0.83 — close the server half of R0 revoke
-- Date: 2026-09-09
--
-- ── WHAT IS WRONG ─────────────────────────────────────────────
-- `remote_helper_authorize_broadcast` is the ENTIRE write-side boundary for the
-- private terminal relay: `broadcast-terminal` runs as service_role, which is
-- rolbypassrls, so no RLS policy is consulted on that path. Its own header says
-- so, and then names this gap.
--
-- The function authorizes on exactly four predicates:
--     rs.id = p_session_id
--     rs.device_id = p_device_id
--     rs.user_id = v_user
--     rs.realtime_private is true
-- There is no status predicate and no consent column. M4.4d's `cloudShared` is
-- an IN-MEMORY helper flag never mirrored to the database, and revocation
-- (`unshareAttachedSession` -> `retireMintedRow`) only posts `status='stopped'`,
-- which this function does not read.
--
-- So after a user revokes sharing, the row survives with realtime_private=true
-- and the server keeps authorizing writes to that session's topic. Revocation
-- has been enforced entirely client-side, by a helper that could be stale,
-- buggy, or replaced.
--
-- ── WHAT THIS CHANGES ─────────────────────────────────────────
-- One predicate: the session must not be in a TERMINAL state.
--
--     and rs.status in ('pending', 'running')
--
-- Deliberately an allowlist of live states rather than `<> 'stopped'`: a future
-- terminal state (say 'errored', which `RemoteSessionStatus` already defines)
-- would otherwise keep authorizing. And deliberately including 'pending' rather
-- than requiring 'running': a helper that begins broadcasting in the window
-- between row creation and the first status post would otherwise earn a 42501,
-- which the Swift sink treats as an authoritative denial and suppresses the
-- session for a 60 s backoff. Denying a live session is a worse failure than
-- briefly admitting a pending one.
--
-- ── BLAST RADIUS, MEASURED 2026-09-09 ─────────────────────────
--     remote_sessions            3 rows
--     realtime_private = true    3
--     status                     'stopped' for all 3
--     status = 'running'         0
-- So this authorizes strictly less than before and denies nothing that is
-- currently allowed-and-live: there is no live session to break. The three
-- rows it newly refuses are exactly the class this migration exists to refuse.
--
-- Two callers, both fine with the narrowing:
--   * `mint-realtime-token` — mints for a live session; a stopped one has no
--     terminal to mirror.
--   * `broadcast-terminal` — same, and it maps 42501 to 403, which the Swift
--     sink suppresses for a bounded backoff rather than permanently.
--
-- ── NOT A SUBSTITUTE FOR CONSENT ──────────────────────────────
-- This closes the REVOKE gap, not the consent gap. `cloudShared` is still not
-- in the database, so a session that was never shared but is running would
-- still authorize if a helper asked. Closing that needs a consent column the
-- helper writes, which is a bigger change and a schema the client must
-- maintain. Recorded here so the next reader does not mistake this for the
-- whole fix.
--
-- Body below is the LIVE definition read back with pg_get_functiondef on
-- 2026-09-09, plus the one predicate — not reconstructed from the repo, because
-- production function bodies drift.
--
-- Runs as ONE transaction.
-- ============================================================

create or replace function public.remote_helper_authorize_broadcast(
  p_device_id uuid, p_helper_secret text, p_session_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
declare
  v_user  uuid;
  v_owner uuid;
begin
  v_user := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  select rs.user_id into v_owner
  from public.remote_sessions rs
  where rs.id = p_session_id
    and rs.device_id = p_device_id
    and rs.user_id = v_user
    and rs.realtime_private is true
    -- v0.83: a retired/ended session must stop authorizing. Revocation posts
    -- status='stopped'; without this the server kept saying yes.
    and rs.status in ('pending', 'running');
  if v_owner is null then
    raise exception 'session not authorized for private broadcast' using errcode = '42501';
  end if;

  return v_owner;
end;
$function$;

-- ------------------------------------------------------------
-- In-transaction assertions. Each ABORTS, and each would have FAILED against
-- the pre-apply body measured above.
-- ------------------------------------------------------------
do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'remote_helper_authorize_broadcast';

  if def is null then
    raise exception 'the function vanished';
  end if;

  -- Would have failed before: the predicate did not exist.
  if def not like '%rs.status in (''pending'', ''running'')%' then
    raise exception 'the status predicate is not in the deployed body';
  end if;

  -- The four original predicates must all survive. Narrowing is the point;
  -- accidentally DROPPING one would widen authorization instead.
  if def not like '%rs.realtime_private is true%'
     or def not like '%rs.device_id = p_device_id%'
     or def not like '%rs.user_id = v_user%'
     or def not like '%rs.id = p_session_id%' then
    raise exception 'an original predicate was lost — this would WIDEN authorization';
  end if;

  -- Shape must be unchanged: SECURITY DEFINER with a pinned search_path.
  -- `create or replace` keeps these, but a future edit that retypes the header
  -- could drop them silently, and this function is a write-side boundary.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'remote_helper_authorize_broadcast'
      and p.prosecdef
      and p.proconfig::text like '%search_path=pg_catalog, public, extensions%'
  ) then
    raise exception 'SECURITY DEFINER or the pinned search_path was lost';
  end if;

  -- And EXECUTE must not have widened. anon reaching this would matter: the
  -- helper paths are anon-reachable by design and gated on helper_secret, so
  -- this only pins that the grant set did not CHANGE under us.
  if has_function_privilege('anon', 'public.remote_helper_authorize_broadcast(uuid,text,uuid)', 'EXECUTE')
     is distinct from true then
    raise exception 'anon EXECUTE changed — the helper path is anon-reachable by design; re-read before proceeding';
  end if;
end
$$;

-- ============================================================
-- Post-apply, by hand — a green apply is not evidence:
--   select pg_get_functiondef(oid) from pg_proc
--    where proname='remote_helper_authorize_broadcast';        -- has the predicate
--
--   -- The behaviour this exists for, with a real helper_secret (owner only):
--   -- a session retired to status='stopped' must now raise 42501 where it
--   -- previously returned the owner uuid.
--
--   select count(*) filter (where status in ('pending','running')) as still_authorizable,
--          count(*)                                                as total
--     from public.remote_sessions where realtime_private;
--     -- 2026-09-09: 0 / 3. Every private row is 'stopped', so this migration
--     -- newly refuses all three — which is the point, not a regression.
-- ============================================================

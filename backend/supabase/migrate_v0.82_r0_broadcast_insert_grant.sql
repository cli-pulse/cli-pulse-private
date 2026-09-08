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
-- (An earlier draft probed that membership with 'USAGE', which is unsound
--  here — but NOT for the reason the first correction gave. That correction
--  said supabase_realtime_admin's rolinherit=false made USAGE misleading;
--  `rolinherit` governs what a role inherits FROM ITS OWN memberships, so the
--  attribute that would matter is postgres's, and postgres has rolinherit=true.
--  The real defect is simpler and worse: USAGE answers false both when the
--  membership does not inherit AND when there is no membership at all, so it
--  cannot tell "blocked" from "absent". SET and MEMBER each have one meaning,
--  and both answer false. The conclusion survived two wrong explanations of
--  itself, which is exactly why the probe is recorded and not just the verdict.)
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
-- ── How to get it applied — READ THIS BEFORE OPENING A TICKET ─
--
-- The honest answer is: probably do not, yet. Two facts, both measured
-- 2026-09-08, change what this file is for.
--
-- ⛔ FACT 1 — NOTHING WRITES THIS TOPIC TODAY. The `pterm:` producer does not
--    ship in the app. The bundled Swift helper says so itself, in its own
--    source, in three places:
--      HelperSwift/Sources/HelperKit/RemoteAgentCloud.swift:613
--        "since the Swift helper ships no `pterm:` producer (DEV_PLAN §2 gap 2),
--         output reaches it through the durable event tail at ~3 s poll latency"
--      HelperSwift/Sources/HelperKit/ManagedSessionManager.swift:1122
--      migrate_v0.69_register_session_realtime_private.sql:25
--    The only producer in the tree is `helper/realtime_broadcast.py`, in the
--    separately-installed Python .pkg. So this grant would unblock a path the
--    shipping client cannot exercise. That is the FOURTH and deciding way the
--    write path is dead, and it is the one with no owner named below.
--
-- ✅ FACT 2 — A FALLBACK IS ALREADY PROVISIONED AND NEEDS NO NEW PRIVILEGE.
--    v0.65 recorded it at its own line 65 and this file previously ignored it:
--      "If Realtime rejects the custom role name, fall back to a service-relay
--       broadcast (helper→edge fn→service-role realtime.send)"
--    Measured on production, so it is not speculative:
--      has_table_privilege('service_role','realtime.messages','INSERT')   true
--      has_function_privilege('service_role','realtime.send(...)','EXECUTE') true
--    `mint-realtime-token` already proves the shape works: an edge function
--    that authorizes with `remote_helper_authorize_broadcast` and acts with the
--    service role. The authorization boundary moves from the RLS policy into
--    that function — which is a real cost, and the same cost as the definer
--    trap below, except this one is already built, already reviewed, and does
--    not require asking anyone for anything.
--
-- SO THE ORDER IS: settle the design question first, build a producer second,
-- ask for the grant last — and only if the custom-role design wins on its
-- merits. Asking a platform team to grant a customer role privileges on a
-- managed schema is a one-shot favour; spending it before knowing whether the
-- design survives is backwards.
--
-- IF the ticket is still the right call, ask NARROWLY. Exactly one statement in
-- this file needs a role we do not have — the GRANT. The policy DDL beneath it
-- is available to `postgres` via `supautils.policy_grants`, and v0.81 proved
-- that on production by creating the READ policy from this same connection. A
-- one-line privilege request with a rationale is a plausible ticket; "run this
-- customer DDL against your managed schema as supabase_admin" is the kind that
-- gets declined.
--
-- ⛔ DO NOT go looking for a self-service way around the grant. An earlier draft
--    of this header offered one — "an alternative that would let the owner apply
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
-- ⚠️ And do not reach for the OTHER obvious workaround either: a SECURITY
--    DEFINER function owned by `postgres`, which does hold INSERT, exposed to
--    r0_broadcast by EXECUTE alone. `postgres` is rolbypassrls=true and definer
--    runs as the owner, so such a function IS NOT CHECKED BY THE WRITE POLICY
--    AT ALL. Measured 2026-09-08 in a transaction that was then aborted: a
--    definer function owned by postgres read a row from a table with RLS
--    enabled and a `using (false)` deny-all policy. Every ownership and topic
--    check would have to move inside the function body, where a missing
--    predicate is not a denied write but an unbounded one. `realtime.send`
--    cannot serve as one either — `prosecdef = false`.
--
--    Note that FACT 2's service relay has the same property and is still the
--    better option: service_role is also rolbypassrls, but its boundary is an
--    edge function that already exists and already does the authorization,
--    rather than a new definer function written to dodge a grant.
--
-- ── Order ─────────────────────────────────────────────────────
-- v0.81 first (it creates the role this grants to). Then this.
--
-- The re-deploy this file used to demand has ALREADY HAPPENED: production ran
-- the pre-v0.65 build signing `role: "authenticated"` until 2026-09-08, when
-- `mint-realtime-token` was redeployed to v5. Verified against the deployed
-- source, not the repo: v5 signs `role: "r0_broadcast"`.
--
-- So the production write path is currently dead FOUR ways, and it is worth
-- being precise about which, because each has a different owner — and because
-- the last one decides whether the others are worth fixing at all:
--   1. the token says role=r0_broadcast; the WRITE policy still targets
--      {authenticated} — nothing matches                     (this file fixes)
--   2. r0_broadcast holds no INSERT on realtime.messages — denied before any
--      policy is consulted                                   (support fixes)
--   3. the WRITE policy body still inlines remote_sessions, which r0_broadcast
--      cannot SELECT — it would 42501 for its own role        (this file fixes)
--   4. the shipped Swift helper contains no `pterm:` producer, so nothing
--      attempts this write in the first place              (NOBODY — see above)
--
-- Why this is a latent defect and not an outage — stated carefully, because an
-- earlier version of this paragraph got the reason wrong:
--   It is NOT "the cutover flag is false for all accounts". Nothing in the R0
--   path reads `user_settings.realtime_private_enabled`; both policies and both
--   oracles key on `remote_sessions.realtime_private`. Measured 2026-09-08:
--     user_settings    218 rows, realtime_private_enabled = 0
--     remote_sessions    3 rows, realtime_private        = 3   <— the real gate
--   All three are `status='stopped'`, one account, last event 2026-07-16, and
--   are due to be deleted by `remote_retention_cleanup_nightly` on 2026-09-14.
--   So these policies govern three dead rows, plus reason 4 above. Re-measure;
--   do not trust this count, which is why v0.81's post-apply block now carries
--   the query instead of the answer.
-- Do not flip realtime_private for any live session until 1-4 are all closed
-- and the integration gate below has run.
-- ============================================================

-- ⚠️ THE `begin;` BELOW IS LOAD-BEARING, not decoration. This file's headline
--    promise is that running it as `postgres` "does nothing" because the
--    assertion block turns the silent no-op into an abort. An assertion can
--    only abort statements it shares a transaction with. Without the explicit
--    BEGIN/COMMIT, a client in autocommit would commit the GRANT (a no-op) and
--    the policy retarget (NOT a no-op — postgres can do policy DDL here) and
--    only then hit the raise — leaving production in the crossed state where
--    the WRITE policy targets a role that cannot insert. v0.81 declared "this
--    whole script runs as ONE transaction" in prose and relied on the runner;
--    this file makes it a statement instead, because here the two DDL effects
--    genuinely differ and the residue would be real.
--    v0.81 now carries an assertion that DETECTS that crossed state; this
--    prevents it.
begin;

set local lock_timeout = '5s';

-- Fail before touching anything if v0.81 has not run. This has to come FIRST:
-- the GRANT below names r0_broadcast, and GRANT to a missing role raises its
-- own 42704 with a far less useful message. An earlier draft put this check in
-- the assertion block at the foot, where it could never fire.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'r0_broadcast') then
    raise exception 'r0_broadcast does not exist — apply v0.81 first';
  end if;
  -- Same reason, one link further along: this file's policy body calls the
  -- write oracle, and v0.81 is what creates it and grants EXECUTE on it.
  if to_regprocedure('public.r0_broadcast_topic_allowed(text)') is null then
    raise exception 'the write oracle is missing — apply v0.81 first';
  end if;
end
$$;

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

  -- The last link in the write chain, and the only one no file checked. The
  -- policy body above calls public.r0_broadcast_topic_allowed(...), evaluated
  -- as r0_broadcast. The EXECUTE grant for it is issued in a DIFFERENT file
  -- (v0.81), so nothing here guaranteed it survived — and the failure mode is
  -- identical to the 42501 the previous assertion exists to prevent: the
  -- policy looks right, targets the right role, does not inline the table, and
  -- still aborts for its own role the moment it is evaluated.
  if not has_function_privilege('r0_broadcast', 'public.r0_broadcast_topic_allowed(text)', 'EXECUTE') then
    raise exception
      'r0_broadcast cannot EXECUTE its own write oracle — the WRITE policy '
      'would abort 42501 on every insert. v0.81 grants this; check it survived.';
  end if;
end
$$;

commit;

-- ============================================================
-- Post-apply, by hand — a green apply is not evidence:
--   select has_table_privilege('r0_broadcast','realtime.messages','INSERT'); -- true
--   select has_table_privilege('r0_broadcast','realtime.messages','SELECT'); -- false
--   select policyname, roles::text, with_check from pg_policies
--    where schemaname='realtime' and tablename='messages';
--     -- write -> {r0_broadcast}, body calls r0_broadcast_topic_allowed(...)
--
-- Only then the v0.65 cutover gate. The re-deploy it used to open with is
-- DONE (v5, signing role: "r0_broadcast" — see the Order section above); what
-- remains is the integration test itself: mint an r0_broadcast token, confirm
-- POST /realtime/v1/api/broadcast to that session's pterm: topic delivers, and
-- that a cross-session token does NOT.
--
-- And before any of that, answer death #4: there is still no `pterm:` producer
-- in the shipped Swift helper, so a passing integration test proves the
-- plumbing works, not that the feature does.
-- ============================================================

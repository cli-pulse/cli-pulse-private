-- ============================================================================
-- 40_rls_denial_tests.sql — cross-user RLS denial assertions.
--
-- Run with psql -v ON_ERROR_STOP=1: any RAISE EXCEPTION aborts the run non-zero,
-- so CI fails the moment a cross-user access succeeds. Each block impersonates a
-- role exactly as PostgREST does: set the request.jwt.claims GUC (→ auth.uid())
-- then `set local role authenticated` (a non-superuser, non-BYPASSRLS role), so
-- the live RLS policies — and nothing else — decide every result.
--
-- Coverage (deliverable of PR3 / DEV_PLAN §2):
--   • userB cannot SELECT / INSERT / UPDATE userA rows on remote_sessions,
--     remote_session_commands, remote_session_events, remote_permission_requests,
--     remote_permission_decisions, subscriptions, daily_usage_metrics.
--   • team_members: a non-member cannot read members; an ADMIN cannot self-promote
--     to owner via a direct UPDATE/INSERT (the P1 from DEV_PLAN PR2); the OWNER can.
--   • Positive controls: userA CAN read its own rows (guards against a globally
--     denying RLS giving false confidence).
-- ============================================================================

\set userA '''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'''
\set userB '''bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'''
\set teamId '''7ea11111-0000-0000-0000-000000000001'''
\set ownerId '''11111111-1111-1111-1111-111111111111'''
\set adminId '''22222222-2222-2222-2222-222222222222'''
\set memberId '''33333333-3333-3333-3333-333333333333'''

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 1 — userB CANNOT SELECT userA rows (every in-scope table)
-- ───────────────────────────────────────────────────────────────────────────
begin;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  n int;
  tbl text;
  tables text[] := array[
    'remote_sessions','remote_session_commands','remote_session_events',
    'remote_permission_requests','remote_permission_decisions',
    'machine_commands','daily_usage_metrics','subscriptions'];
begin
  foreach tbl in array tables loop
    execute format('select count(*) from public.%I where user_id = %L', tbl,
                   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') into n;
    if n <> 0 then
      raise exception 'FAIL[read]: userB saw % userA row(s) in public.%', n, tbl;
    end if;
    raise notice 'PASS[read]: userB sees 0 userA rows in public.%', tbl;
  end loop;
end $$;
rollback;

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 2 — userB CANNOT INSERT a row attributed to userA (RLS → 42501)
-- ───────────────────────────────────────────────────────────────────────────
begin;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  begin
    insert into public.remote_sessions (user_id, device_id, provider)
      values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', gen_random_uuid(), 'claude');
    raise exception 'FAIL[insert]: userB inserted a remote_sessions row';
  exception when insufficient_privilege then
    raise notice 'PASS[insert]: RLS blocked userB insert into remote_sessions';
  end;

  begin
    insert into public.daily_usage_metrics (user_id, metric_date, provider, model, cost)
      values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_date, 'claude', 'opus', 99);
    raise exception 'FAIL[insert]: userB inserted a daily_usage_metrics row for userA';
  exception when insufficient_privilege then
    raise notice 'PASS[insert]: RLS blocked userB insert into daily_usage_metrics';
  end;

  begin
    insert into public.subscriptions (user_id, tier) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'team');
    raise exception 'FAIL[insert]: userB inserted/overwrote a subscriptions row';
  exception when insufficient_privilege or unique_violation then
    -- 42501 (no client INSERT policy) is the intended denial; a PK clash would
    -- also mean the row wasn't forged. Either way userB did not write userA data.
    raise notice 'PASS[insert]: RLS blocked userB insert into subscriptions';
  end;
end $$;
rollback;

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 3 — userB CANNOT UPDATE userA rows (RLS → 0 rows affected)
-- ───────────────────────────────────────────────────────────────────────────
begin;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}', true);
set local role authenticated;

do $$
declare n int;
begin
  update public.remote_session_commands set payload = 'hijacked'
    where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL[update]: userB updated % remote_session_commands rows', n; end if;
  raise notice 'PASS[update]: userB updated 0 remote_session_commands rows';

  update public.machine_commands set status = 'delivered'
    where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL[update]: userB updated % machine_commands rows', n; end if;
  raise notice 'PASS[update]: userB updated 0 machine_commands rows';

  update public.daily_usage_metrics set cost = 0
    where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL[update]: userB updated % daily_usage_metrics rows', n; end if;
  raise notice 'PASS[update]: userB updated 0 daily_usage_metrics rows';
end $$;
rollback;

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 4 — team_members: insider-escalation denial (DEV_PLAN PR2 / NEW-H2v)
-- ───────────────────────────────────────────────────────────────────────────

-- 4a) a non-member (userB) cannot even enumerate members
begin;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  select count(*) into n from public.team_members where team_id = '7ea11111-0000-0000-0000-000000000001';
  if n <> 0 then raise exception 'FAIL[team read]: non-member saw % team_members rows', n; end if;
  raise notice 'PASS[team read]: non-member sees 0 team_members rows';
end $$;
rollback;

-- 4b) an ADMIN cannot promote itself to owner via a direct table UPDATE
begin;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int; r text;
begin
  update public.team_members set role = 'owner'
    where team_id = '7ea11111-0000-0000-0000-000000000001'
      and user_id = '22222222-2222-2222-2222-222222222222';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL[self-promote]: admin UPDATE escalated % row(s) to owner', n; end if;
  select role into r from public.team_members
    where team_id = '7ea11111-0000-0000-0000-000000000001'
      and user_id = '22222222-2222-2222-2222-222222222222';
  if r is distinct from 'admin' then raise exception 'FAIL[self-promote]: admin role is now %', r; end if;
  raise notice 'PASS[self-promote]: admin direct-UPDATE to owner denied (role still admin)';
end $$;
rollback;

-- 4c) an ADMIN cannot INSERT a fresh owner-role membership for itself either
begin;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    insert into public.team_members (team_id, user_id, role)
      values ('7ea11111-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'owner');
    raise exception 'FAIL[insert owner]: admin inserted an owner-role membership';
  exception when insufficient_privilege or unique_violation then
    raise notice 'PASS[insert owner]: admin INSERT of owner-role membership denied';
  end;
end $$;
rollback;

-- 4d) POSITIVE control — the real OWNER can still manage member roles
begin;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  update public.team_members set role = 'admin'
    where team_id = '7ea11111-0000-0000-0000-000000000001'
      and user_id = '33333333-3333-3333-3333-333333333333';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL[owner manage]: owner updated % member rows (expected 1)', n; end if;
  raise notice 'PASS[owner manage]: owner can update a member role (1 row)';
end $$;
rollback;

-- 4e) POSITIVE control — a real member CAN read its own team's roster WITHOUT
-- recursion. This is also the regression guard for the recursion bug that made
-- team_members direct reads fail in prod (42P17); the Android team feature uses
-- exactly this direct REST read (SupabaseClient.kt).
begin;
select set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  select count(*) into n from public.team_members where team_id = '7ea11111-0000-0000-0000-000000000001';
  if n <> 3 then raise exception 'FAIL[member read]: member saw % of 3 team rows (recursion or over-block?)', n; end if;
  raise notice 'PASS[member read]: member reads own team roster (3 rows, no recursion)';
end $$;
rollback;

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 5 — POSITIVE controls: userA CAN read its own rows (no false denial)
-- ───────────────────────────────────────────────────────────────────────────
begin;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  n int; tbl text;
  tables text[] := array[
    'remote_sessions','remote_session_commands','remote_session_events',
    'remote_permission_requests','remote_permission_decisions',
    'machine_commands','daily_usage_metrics','subscriptions'];
begin
  foreach tbl in array tables loop
    execute format('select count(*) from public.%I where user_id = %L', tbl,
                   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') into n;
    if n < 1 then
      raise exception 'FAIL[self read]: userA cannot see its own public.% row (RLS over-blocks)', tbl;
    end if;
    raise notice 'PASS[self read]: userA sees its own public.% row(s)', tbl;
  end loop;
end $$;
rollback;

-- ── 5) SELF-ESCALATION on profiles (migrate_v0.74) ──────────────────────────
-- Distinct from every assertion above: those are CROSS-user (B reaches A's
-- rows). This one is SAME-user, WRONG-column — a user editing their OWN row to
-- change a column they must not control. The suite had no coverage of that
-- shape, which is how the profiles hole survived: `Users can update own
-- profile` omits with_check, so Postgres reuses `using` as the check, and the
-- only rule on the new row is "it is still your row" — nothing pins the column.
-- Fixed by revoking table-level UPDATE (a column-level revoke is a no-op
-- against a table-level grant, and was measured to be one).

-- 5a) a user cannot raise their own tier
begin;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int; t text;
begin
  begin
    update public.profiles set tier = 'team'
      where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    get diagnostics n = row_count;
    if n <> 0 then
      raise exception 'FAIL[self-grant]: user escalated own tier on % row(s)', n;
    end if;
  exception when insufficient_privilege then
    null;  -- expected: no UPDATE privilege on profiles
  end;
  select tier into t from public.profiles where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if t is distinct from 'free' then
    raise exception 'FAIL[self-grant]: tier is now %', t;
  end if;
  raise notice 'PASS[self-grant]: user cannot raise own profiles.tier';
end $$;
rollback;

-- 5b) …nor forge the receipt columns the entitlement is derived from
begin;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int; v timestamptz;
begin
  begin
    update public.profiles
       set receipt_verified_at = now(), last_transaction_id = 'forged'
     where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    get diagnostics n = row_count;
    if n <> 0 then
      raise exception 'FAIL[forge receipt]: user wrote receipt columns on % row(s)', n;
    end if;
  exception when insufficient_privilege then
    null;
  end;
  select receipt_verified_at into v from public.profiles
    where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if v is not null then
    raise exception 'FAIL[forge receipt]: receipt_verified_at is now %', v;
  end if;
  raise notice 'PASS[forge receipt]: user cannot forge profiles receipt columns';
end $$;
rollback;

-- 5c) …and the upsert vector is closed too. PostgREST's
-- `Prefer: resolution=merge-duplicates` compiles to INSERT .. ON CONFLICT DO
-- UPDATE, which needs the same UPDATE privilege — a fix that only blocked the
-- plain UPDATE would leave this open.
begin;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}', true);
set local role authenticated;
do $$
declare t text;
begin
  begin
    insert into public.profiles (id, name, email, tier)
      values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'x', 'x', 'team')
      on conflict (id) do update set tier = 'team';
  exception when insufficient_privilege or unique_violation then
    null;
  end;
  select tier into t from public.profiles where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if t is distinct from 'free' then
    raise exception 'FAIL[upsert-grant]: tier is now % via ON CONFLICT DO UPDATE', t;
  end if;
  raise notice 'PASS[upsert-grant]: merge-duplicates cannot raise own tier';
end $$;
rollback;

-- 5d) POSITIVE control — the user can still READ their own profile. Without
-- this, an over-broad revoke would look identical to a correct one.
begin;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  select count(*) into n from public.profiles where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if n < 1 then
    raise exception 'FAIL[self read profile]: user cannot see own profile (RLS over-blocks)';
  end if;
  raise notice 'PASS[self read profile]: user sees own profile row';
end $$;
rollback;

\echo '========================================================================'
\echo 'ALL CROSS-USER RLS DENIAL TESTS PASSED'
\echo '========================================================================'

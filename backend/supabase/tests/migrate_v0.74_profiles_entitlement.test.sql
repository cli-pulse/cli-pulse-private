-- Regression test for migrate_v0.74_profiles_entitlement_not_self_writable.sql
--
-- Run against a database that has v0.74 applied. Every block rolls back, so it
-- is safe to run against production.
--
--     supabase db query --file backend/supabase/tests/migrate_v0.74_profiles_entitlement.test.sql
--
-- The test is written to FAIL LOUDLY rather than to pass quietly: each branch
-- raises with the observed value, so "it printed nothing" can never be read as
-- "it passed". See feedback_guards_that_never_run — the first version of this
-- fix was a column-level revoke that this exact test proved was a no-op.

-- ── T1: `authenticated` must NOT hold table-level UPDATE on profiles ────────
do $$
declare v_has boolean;
begin
  select bool_or(privilege_type='UPDATE') into v_has
  from information_schema.table_privileges
  where table_schema='public' and table_name='profiles'
    and grantee in ('authenticated','anon');
  if coalesce(v_has,false) then
    raise exception 'T1 FAIL: authenticated/anon still hold UPDATE on public.profiles';
  end if;
  raise notice 'T1 pass: no table-level UPDATE for authenticated/anon';
end $$;

-- ── T2: the actual attack, executed as a real user, must be refused ─────────
-- Also covers the PostgREST upsert vector (Prefer: resolution=merge-duplicates
-- compiles to INSERT ... ON CONFLICT DO UPDATE, which needs UPDATE privilege).
do $$
declare v_uid uuid; v_attack text; v_upsert text; v_read text;
begin
  select id into v_uid from public.profiles where tier='free' order by created_at limit 1;
  if v_uid is null then
    raise exception 'T2 INCONCLUSIVE: no free-tier profile to impersonate — '
                    'this test proves nothing, do not read it as a pass';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  begin
    update public.profiles set tier='team' where id=v_uid;
    v_attack := 'STILL EXPLOITABLE (rows=' || (select count(*) from public.profiles where id=v_uid and tier='team') || ')';
  exception when insufficient_privilege then v_attack := 'BLOCKED';
            when others then v_attack := 'blocked-other: ' || substr(SQLERRM,1,60);
  end;

  begin
    insert into public.profiles (id,name,email,tier) values (v_uid,'x','x','team')
      on conflict (id) do update set tier='team';
    v_upsert := 'UPSERT EXPLOITABLE';
  exception when insufficient_privilege then v_upsert := 'BLOCKED';
            when others then v_upsert := 'blocked-other: ' || substr(SQLERRM,1,60);
  end;

  -- the user must still be able to read their own row (no over-revoke)
  begin
    select tier into v_read from public.profiles where id=v_uid;
    v_read := 'ok(' || coalesce(v_read,'null') || ')';
  exception when others then v_read := 'READ BROKE: ' || substr(SQLERRM,1,60);
  end;

  perform set_config('role','postgres', true);

  if v_attack <> 'BLOCKED' or v_upsert <> 'BLOCKED' or v_read not like 'ok(%' then
    raise exception 'T2 FAIL attack=[%] upsert=[%] read=[%]', v_attack, v_upsert, v_read;
  end if;
  raise exception 'T2 pass attack=[%] upsert=[%] read=[%] — rolling back',
                  v_attack, v_upsert, v_read;
exception when others then
  perform set_config('role','postgres', true);
  raise;
end $$;

-- ── T3: the legitimate writer is unaffected ────────────────────────────────
-- validate-receipt uses SERVICE_ROLE, and `paired` is written by SECURITY
-- DEFINER RPCs. Both run as roles that keep UPDATE. Proven by writing as owner.
do $$
declare v_uid uuid; v_ok text;
begin
  select id into v_uid from public.profiles order by created_at limit 1;
  begin
    update public.profiles set paired = paired where id = v_uid;
    v_ok := 'definer/service path ok';
  exception when others then v_ok := 'REGRESSION: ' || substr(SQLERRM,1,60);
  end;
  if v_ok <> 'definer/service path ok' then
    raise exception 'T3 FAIL: %', v_ok;
  end if;
  raise exception 'T3 pass: % — rolling back', v_ok;
end $$;

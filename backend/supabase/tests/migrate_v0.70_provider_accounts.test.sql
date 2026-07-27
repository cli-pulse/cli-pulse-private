-- ============================================================================
-- migrate_v0.70_provider_accounts.test.sql
-- Plain-Postgres contract test for account-scoped provider quotas.
--
-- Run in two independent disposable databases:
--   A. upgrade path: pre-v0.70 baseline, then migrate_v0.70 only;
--   B. fresh path: tests/rls/00_supabase_shim.sql, schema.sql, app_rpc.sql,
--      helper_rpc.sql, with no migration replay afterward.
-- Never load the migration after the canonical files in path B: that would
-- overwrite a drifting canonical function and create a false-positive PASS.
--
-- The script is self-rolling-back. With psql -v ON_ERROR_STOP=1, any failed
-- assertion exits non-zero.
-- ============================================================================

\set ON_ERROR_STOP on

begin;

-- Fixed identities keep failures reproducible.
\set userA '''a7000000-7000-4700-8700-700000000001'''
\set userB '''b7000000-7000-4700-8700-700000000002'''
\set userC '''c7000000-7000-4700-8700-700000000003'''
\set deviceA '''d7000000-7000-4700-8700-700000000001'''
\set deviceB '''e7000000-7000-4700-8700-700000000002'''
\set accountA1 '''17000000-7000-4700-8700-700000000001'''
\set accountA2 '''27000000-7000-4700-8700-700000000002'''
\set accountUnknown '''37000000-7000-4700-8700-700000000003'''
\set accountHelper '''47000000-7000-4700-8700-700000000004'''
\set accountB '''57000000-7000-4700-8700-700000000005'''
\set accountBig '''67000000-7000-4700-8700-700000000006'''
\set accountClock '''77000000-7000-4700-8700-700000000007'''
\set accountDisabledFirst '''87000000-7000-4700-8700-700000000008'''

insert into auth.users (id, email) values
  (:userA, 'owner@example.test'),
  (:userB, 'attacker@example.test'),
  (:userC, 'bounded@example.test');

insert into public.devices (id, user_id, name, helper_secret) values
  (:deviceA, :userA, 'owner-device',
   encode(extensions.digest('owner-helper-secret', 'sha256'), 'hex')),
  (:deviceB, :userB, 'attacker-device',
   encode(extensions.digest('attacker-helper-secret', 'sha256'), 'hex'));

-- --------------------------------------------------------------------------
-- App RPC: one user may persist two accounts for the same provider. A forged
-- user_id in the JSON must be ignored; auth.uid() is the only owner source.
-- Unknown remaining/quota stay NULL rather than becoming a false zero.
-- --------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_provider_account_quotas(
  jsonb_build_array(
    jsonb_build_object(
      'user_id', :userB,
      'account_id', :accountA1,
      'provider', 'Claude',
      'account_label', 'Work',
      'plan_type', 'Max 20x',
      'plan_source', 'providerAPI',
      'plan_confidence', 'high',
      'plan_observed_at', '2026-07-24T01:00:00Z',
      'remaining', 80,
      'quota', 100,
      'reset_time', '2026-07-24T06:00:00Z',
      'tiers', jsonb_build_array(
        jsonb_build_object('name', '5h Window', 'quota', 100, 'remaining', 80)
      ),
      'observed_at', '2026-07-24T01:01:00Z',
      'source_device_id', :deviceA
    ),
    jsonb_build_object(
      'user_id', :userB,
      'account_id', :accountA2,
      'provider', 'Claude',
      'account_label', 'Personal',
      'plan_type', 'Pro',
      'plan_source', 'userConfirmed',
      'plan_confidence', 'high',
      'plan_observed_at', '2026-07-24T01:00:00Z',
      'remaining', 20,
      'quota', 100,
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T01:02:00Z'
    ),
    jsonb_build_object(
      'account_id', :accountUnknown,
      'provider', 'OpenRouter',
      'account_label', 'Credits',
      'plan_source', 'unknown',
      'plan_confidence', 'unavailable',
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T01:03:00Z'
    ),
    jsonb_build_object(
      'account_id', :accountBig,
      'provider', 'Kimi',
      'account_label', 'Large quota',
      'plan_source', 'providerAPI',
      'plan_confidence', 'high',
      'remaining', 3000000000,
      'quota', 4000000000,
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T01:03:30Z'
    )
  )
);
reset role;

do $$
declare
  v_count integer;
  v_remaining bigint;
  v_quota bigint;
  v_plan text;
begin
  select count(*) into v_count
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider = 'Claude';
  if v_count <> 2 then
    raise exception 'FAIL[multi-account]: expected 2 Claude accounts, got %', v_count;
  end if;

  select count(*) into v_count
  from public.provider_accounts
  where user_id = 'b7000000-7000-4700-8700-700000000002'
    and id in (
      '17000000-7000-4700-8700-700000000001',
      '27000000-7000-4700-8700-700000000002'
    );
  if v_count <> 0 then
    raise exception 'FAIL[forged owner]: RPC trusted payload user_id';
  end if;

  select count(*) into v_count
  from public.provider_account_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider_account_id = '37000000-7000-4700-8700-700000000003';
  if v_count <> 1 then
    raise exception 'FAIL[unknown quota]: expected one stored quota row, got %',
      v_count;
  end if;

  select remaining, quota into v_remaining, v_quota
  from public.provider_account_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider_account_id = '37000000-7000-4700-8700-700000000003';
  if v_remaining is not null or v_quota is not null then
    raise exception 'FAIL[unknown quota]: NULL became remaining=% quota=%',
      v_remaining, v_quota;
  end if;

  -- The legacy row uses the most constrained comparable account (20/100);
  -- it never sums two independent quota windows.
  select remaining, quota, plan_type
    into v_remaining, v_quota, v_plan
  from public.provider_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider = 'Claude';
  if v_remaining <> 20 or v_quota <> 100 or v_plan <> 'Multiple accounts' then
    raise exception
      'FAIL[compat projection]: expected 20/100 Multiple accounts, got %/% %',
      v_remaining, v_quota, v_plan;
  end if;

  select count(*) into v_count
  from public.provider_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider = 'OpenRouter';
  if v_count <> 0 then
    raise exception 'FAIL[unknown compat]: fabricated provider-level zero row';
  end if;

  select remaining, quota into v_remaining, v_quota
  from public.provider_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider = 'Kimi';
  if v_remaining <> 3000000000 or v_quota <> 4000000000 then
    raise exception 'FAIL[bigint compat]: expected 3000000000/4000000000, got %/%',
      v_remaining, v_quota;
  end if;
end $$;

-- Out-of-order completion must be monotonic. Once a newer account snapshot
-- lands, a delayed older request cannot roll back quota freshness or metadata.
select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_provider_account_quotas(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountA1,
    'provider', 'Claude',
    'account_label', 'Fresh label',
    'plan_type', 'Fresh plan',
    'plan_source', 'providerAPI',
    'plan_confidence', 'high',
    'plan_observed_at', '2026-07-24T02:59:00Z',
    'remaining', 10,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T03:00:00Z'
  )
));
select public.upsert_provider_account_quotas(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountA1,
    'provider', 'Claude',
    'account_label', 'Stale label',
    'plan_type', 'Stale plan',
    'plan_source', 'unknown',
    'plan_confidence', 'low',
    'plan_observed_at', '2026-07-24T01:59:00Z',
    'remaining', 90,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T02:00:00Z'
  )
));
reset role;

do $$
declare
  v_label text;
  v_plan text;
  v_remaining bigint;
  v_observed_at timestamptz;
begin
  select display_label, plan_type into v_label, v_plan
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and id = '17000000-7000-4700-8700-700000000001';
  select remaining, observed_at into v_remaining, v_observed_at
  from public.provider_account_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider_account_id = '17000000-7000-4700-8700-700000000001';

  if v_label is distinct from 'Fresh label'
     or v_plan is distinct from 'Fresh plan'
     or v_remaining is distinct from 10
     or v_observed_at is distinct from
       '2026-07-24T03:00:00Z'::timestamptz then
    raise exception
      'FAIL[monotonic freshness]: label=% plan=% remaining=% observed=%',
      v_label, v_plan, v_remaining, v_observed_at;
  end if;
end $$;

-- Quota freshness and plan evidence are independent clocks. A newer quota
-- snapshot without fresh plan evidence may update label/quota but must
-- preserve the existing plan. Conversely, an older quota snapshot carrying
-- newer plan evidence must update only the plan fields.
select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_provider_account_quotas(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountClock,
    'provider', 'ClockTest',
    'account_label', 'Clock baseline',
    'plan_type', 'Plan baseline',
    'plan_source', 'providerAPI',
    'plan_confidence', 'medium',
    'plan_observed_at', '2026-07-24T02:59:00Z',
    'remaining', 10,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T03:00:00Z'
  )
));
select public.upsert_provider_account_quotas(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountClock,
    'provider', 'ClockTest',
    'account_label', 'Quota-new label',
    'plan_type', 'Unclocked plan must not win',
    'plan_source', 'unknown',
    'plan_confidence', 'low',
    'remaining', 5,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T04:00:00Z'
  )
));
select public.upsert_provider_account_quotas(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountClock,
    'provider', 'ClockTest',
    'account_label', 'Quota-old label must not win',
    'plan_type', 'Plan-new independent',
    'plan_source', 'userConfirmed',
    'plan_confidence', 'high',
    'plan_observed_at', '2026-07-24T05:00:00Z',
    'remaining', 95,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T02:30:00Z'
  )
));
reset role;

do $$
declare
  v_label text;
  v_plan text;
  v_plan_source text;
  v_plan_confidence text;
  v_plan_observed_at timestamptz;
  v_remaining bigint;
  v_observed_at timestamptz;
begin
  select
    display_label,
    plan_type,
    plan_source,
    plan_confidence,
    plan_observed_at
  into
    v_label,
    v_plan,
    v_plan_source,
    v_plan_confidence,
    v_plan_observed_at
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and id = '77000000-7000-4700-8700-700000000007';

  select remaining, observed_at into v_remaining, v_observed_at
  from public.provider_account_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider_account_id = '77000000-7000-4700-8700-700000000007';

  if v_label is distinct from 'Quota-new label'
     or v_plan is distinct from 'Plan-new independent'
     or v_plan_source is distinct from 'userConfirmed'
     or v_plan_confidence is distinct from 'high'
     or v_plan_observed_at is distinct from
       '2026-07-24T05:00:00Z'::timestamptz
     or v_remaining is distinct from 5
     or v_observed_at is distinct from
       '2026-07-24T04:00:00Z'::timestamptz then
    raise exception
      'FAIL[independent clocks]: label=% plan=% source=% confidence=% plan_observed=% remaining=% quota_observed=%',
      v_label, v_plan, v_plan_source, v_plan_confidence,
      v_plan_observed_at, v_remaining, v_observed_at;
  end if;
end $$;

-- Provider costs remain provider-scoped. Two Claude accounts must not double
-- the single provider/model cost series in provider_account_summary.
insert into public.daily_usage_metrics (
  user_id, metric_date, provider, model,
  input_tokens, cached_tokens, output_tokens, cost
) values (
  :userA, date '2026-07-24', 'Claude', 'claude-opus',
  100, 20, 30, 10.500000
);

select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
do $$
declare
  v_payload jsonb;
  v_claude jsonb;
  v_unknown jsonb;
begin
  select public.provider_account_summary(date '2026-07-24') into v_payload;
  select value into v_claude
  from jsonb_array_elements(v_payload)
  where value->>'provider' = 'Claude';
  select value into v_unknown
  from jsonb_array_elements(v_payload)
  where value->>'provider' = 'OpenRouter';

  if v_claude is null or jsonb_array_length(v_claude->'accounts') <> 2 then
    raise exception 'FAIL[summary accounts]: Claude does not contain 2 accounts';
  end if;
  if (v_claude->>'estimated_cost')::numeric <> 10.500000 then
    raise exception 'FAIL[cost duplication]: expected 10.5, got %',
      v_claude->>'estimated_cost';
  end if;
  if v_unknown is null
     or not ((v_unknown->'accounts'->0) ? 'remaining')
     or jsonb_typeof(v_unknown->'accounts'->0->'remaining') <> 'null' then
    raise exception 'FAIL[summary unknown]: unknown remaining was not JSON null';
  end if;
end $$;
reset role;

-- --------------------------------------------------------------------------
-- Helper RPC: device secret chooses the owner and source device. Payload
-- user_id/source_device_id values cannot redirect a helper write.
-- --------------------------------------------------------------------------
set local role anon;
select public.helper_sync_provider_account_quotas(
  :deviceA,
  'owner-helper-secret',
  jsonb_build_array(
    jsonb_build_object(
      'user_id', :userB,
      'account_id', :accountHelper,
      'provider', 'Codex',
      'account_label', 'Helper account',
      'plan_source', 'accountMetadata',
      'plan_confidence', 'medium',
      'remaining', 55,
      'quota', 100,
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T01:04:00Z',
      'source_device_id', :deviceB
    )
  )
);
reset role;

do $$
declare
  v_user uuid;
  v_device uuid;
begin
  select user_id, source_device_id into v_user, v_device
  from public.provider_account_quotas
  where provider_account_id = '47000000-7000-4700-8700-700000000004';
  if v_user <> 'a7000000-7000-4700-8700-700000000001'
     or v_device <> 'd7000000-7000-4700-8700-700000000001' then
    raise exception 'FAIL[helper ownership]: user=% device=%', v_user, v_device;
  end if;
end $$;

set local role anon;
do $$
declare
  v_rejected boolean := false;
begin
  begin
    perform public.helper_sync_provider_account_quotas(
      'd7000000-7000-4700-8700-700000000001',
      'wrong-secret',
      '[]'::jsonb
    );
  exception when others then
    v_rejected := position('Device not found or unauthorized' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[helper auth]: wrong helper secret was accepted';
  end if;
end $$;
reset role;

-- --------------------------------------------------------------------------
-- Cross-user RLS: user B cannot enumerate or forge rows owned by user A.
-- Positive control: user B can persist and read its own account through RPC.
-- --------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"b7000000-7000-4700-8700-700000000002","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_provider_account_quotas(
  jsonb_build_array(
    jsonb_build_object(
      'user_id', :userA,
      'account_id', :accountB,
      'provider', 'Gemini',
      'account_label', 'B account',
      'plan_source', 'unknown',
      'plan_confidence', 'low',
      'remaining', 60,
      'quota', 100,
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T01:05:00Z'
    )
  )
);

do $$
declare
  v_count integer;
  v_blocked boolean := false;
begin
  select count(*) into v_count
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001';
  if v_count <> 0 then
    raise exception 'FAIL[RLS read]: user B saw % user A accounts', v_count;
  end if;

  select count(*) into v_count
  from public.provider_accounts
  where user_id = 'b7000000-7000-4700-8700-700000000002'
    and id = '57000000-7000-4700-8700-700000000005';
  if v_count <> 1 then
    raise exception 'FAIL[RLS positive]: user B cannot read own account';
  end if;

  begin
    insert into public.provider_accounts (user_id, id, provider)
    values (
      'a7000000-7000-4700-8700-700000000001',
      gen_random_uuid(),
      'Claude'
    );
  exception when insufficient_privilege then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'FAIL[RLS insert]: user B forged a user A account';
  end if;
end $$;
reset role;

do $$
declare
  v_count integer;
begin
  select count(*) into v_count
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and id = '57000000-7000-4700-8700-700000000005';
  if v_count <> 0 then
    raise exception 'FAIL[RPC owner]: user B payload wrote account under user A';
  end if;
end $$;

-- --------------------------------------------------------------------------
-- Input boundaries and immutable account/provider mapping.
-- --------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
do $$
declare
  v_payload jsonb;
  v_rejected boolean;
begin
  select jsonb_agg(jsonb_build_object(
    'account_id', gen_random_uuid(),
    'provider', 'Claude',
    'plan_source', 'unknown',
    'plan_confidence', 'unavailable',
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T01:06:00Z'
  )) into v_payload
  from generate_series(1, 101);

  v_rejected := false;
  begin
    perform public.upsert_provider_account_quotas(v_payload);
  exception when others then
    v_rejected := position('Too many provider accounts' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[input count]: 101 rows were accepted';
  end if;

  select jsonb_build_array(jsonb_build_object(
    'account_id', gen_random_uuid(),
    'provider', 'Claude',
    'plan_source', 'unknown',
    'plan_confidence', 'unavailable',
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T01:06:00Z',
    'padding', string_agg(md5(g::text), '')
  )) into v_payload
  from generate_series(1, 9000) g;

  v_rejected := false;
  begin
    perform public.upsert_provider_account_quotas(v_payload);
  exception when others then
    v_rejected := position('Provider account payload too large' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[input size]: oversized payload was accepted';
  end if;

  v_rejected := false;
  begin
    perform public.upsert_provider_account_quotas(jsonb_build_array(
      jsonb_build_object(
        'account_id', gen_random_uuid(),
        'provider', 'Claude',
        'account_label', repeat('x', 121),
        'plan_source', 'unknown',
        'plan_confidence', 'unavailable',
        'tiers', '[]'::jsonb,
        'observed_at', '2026-07-24T01:06:00Z'
      )
    ));
  exception when others then
    v_rejected := position('Account label too long' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[label size]: 121-character label was accepted';
  end if;

  v_rejected := false;
  begin
    perform public.upsert_provider_account_quotas(jsonb_build_array(
      jsonb_build_object(
        'account_id', gen_random_uuid(),
        'provider', 'Claude',
        'api_key', 'must-never-cross-the-cloud-boundary',
        'plan_source', 'unknown',
        'plan_confidence', 'unavailable',
        'tiers', '[]'::jsonb,
        'observed_at', '2026-07-24T01:06:00Z'
      )
    ));
  exception when others then
    v_rejected := position('Provider secrets are not accepted' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[secret boundary]: secret-shaped payload was accepted';
  end if;

  v_rejected := false;
  begin
    perform public.upsert_provider_account_quotas(jsonb_build_array(
      jsonb_build_object(
        'account_id', gen_random_uuid(),
        'provider', 'Claude',
        'plan_source', 'unknown',
        'plan_confidence', 'unavailable',
        'tiers', jsonb_build_array(
          jsonb_build_object(
            'name', '5h Window',
            'quota', 100,
            'remaining', 50,
            'token', 'must-never-cross-the-cloud-boundary'
          )
        ),
        'observed_at', '2026-07-24T01:06:00Z'
      )
    ));
  exception when others then
    v_rejected :=
      position('Provider secrets are not accepted' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[nested secret boundary]: secret-shaped tier was accepted';
  end if;

  v_rejected := false;
  begin
    perform public.upsert_provider_account_quotas(jsonb_build_array(
      jsonb_build_object(
        'account_id', gen_random_uuid(),
        'provider', jsonb_build_object(
          'token', 'must-never-cross-the-cloud-boundary'
        ),
        'plan_source', 'unknown',
        'plan_confidence', 'unavailable',
        'tiers', '[]'::jsonb,
        'observed_at', '2026-07-24T01:06:00Z'
      )
    ));
  exception when others then
    v_rejected :=
      position(
        'Provider account field provider must be a string or null'
        in sqlerrm
      ) > 0;
  end;
  if not v_rejected then
    raise exception
      'FAIL[scalar secret boundary]: nested provider object was accepted';
  end if;

  v_rejected := false;
  begin
    perform public.upsert_provider_account_quotas(jsonb_build_array(
      jsonb_build_object(
        'account_id', gen_random_uuid(),
        'provider', 'Claude',
        'private_credential', 'unknown-secret-field',
        'plan_source', 'unknown',
        'plan_confidence', 'unavailable',
        'tiers', '[]'::jsonb,
        'observed_at', '2026-07-24T01:06:00Z'
      )
    ));
  exception when others then
    v_rejected := position('Unknown provider account field' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[field allowlist]: unknown payload key was accepted';
  end if;

  v_rejected := false;
  begin
    perform public.upsert_provider_account_quotas(jsonb_build_array(
      jsonb_build_object(
        'account_id', '27000000-7000-4700-8700-700000000002',
        'provider', 'Codex',
        'plan_source', 'unknown',
        'plan_confidence', 'unavailable',
        'tiers', '[]'::jsonb,
        'observed_at', '2026-07-24T01:06:00Z'
      )
    ));
  exception when others then
    v_rejected := position('Provider account does not match existing provider' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[provider mutation]: account provider was changed';
  end if;
end $$;
reset role;

-- The per-request limit is not enough: repeated batches must not make account
-- summary/storage unbounded. Existing rows remain updateable at the cap.
insert into public.provider_accounts (
  user_id, id, provider, display_label
)
select
  :userC,
  gen_random_uuid(),
  'Claude',
  'Seed ' || n
from generate_series(1, 100) n;

select set_config(
  'request.jwt.claims',
  '{"sub":"c7000000-7000-4700-8700-700000000003","role":"authenticated"}',
  true
);
set local role authenticated;
do $$
declare
  v_rejected boolean := false;
begin
  begin
    perform public.upsert_provider_account_quotas(jsonb_build_array(
      jsonb_build_object(
        'account_id', gen_random_uuid(),
        'provider', 'Claude',
        'plan_source', 'unknown',
        'plan_confidence', 'unavailable',
        'tiers', '[]'::jsonb,
        'observed_at', '2026-07-24T01:06:00Z'
      )
    ));
  exception when others then
    v_rejected := position('Too many stored provider accounts' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[stored account limit]: account 101 was accepted';
  end if;
end $$;
reset role;

-- Direct table writes must not bypass the bounded, strict RPC contract.
select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
do $$
declare
  v_rejected boolean := false;
begin
  begin
    insert into public.provider_accounts (
      user_id, id, provider, display_label
    ) values (
      'a7000000-7000-4700-8700-700000000001',
      gen_random_uuid(),
      'Claude',
      'Direct write must fail'
    );
  exception when insufficient_privilege then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'FAIL[table ACL]: authenticated direct insert was accepted';
  end if;
end $$;
reset role;

-- Account lifecycle is caller-owned and independent from quota freshness.
-- An attacker cannot mutate another user, and a late quota snapshot cannot
-- reactivate an account after the owner disables it.
select set_config(
  'request.jwt.claims',
  '{"sub":"b7000000-7000-4700-8700-700000000002","role":"authenticated"}',
  true
);
set local role authenticated;
select public.set_provider_account_statuses(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountA2,
    'status', 'disabled'
  )
));
select public.delete_provider_account(:accountA2);
reset role;

do $$
declare
  v_status text;
begin
  select status into v_status
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and id = '27000000-7000-4700-8700-700000000002';
  if v_status is distinct from 'active' then
    raise exception 'FAIL[lifecycle ownership]: attacker changed owner status';
  end if;
end $$;

select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.set_provider_account_statuses(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountDisabledFirst,
    'status', 'disabled'
  )
));
select public.upsert_provider_account_quotas(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountDisabledFirst,
    'provider', 'DeepSeek',
    'account_label', 'Disabled before first observation',
    'plan_source', 'unknown',
    'plan_confidence', 'unavailable',
    'remaining', 99,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T05:59:00Z'
  )
));
reset role;

do $$
declare
  v_status text;
  v_count integer;
begin
  select status into v_status
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and id = '87000000-7000-4700-8700-700000000008';
  if v_status is distinct from 'disabled' then
    raise exception
      'FAIL[disable before first upsert]: expected disabled, got %',
      v_status;
  end if;

  select count(*) into v_count
  from public.provider_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider = 'DeepSeek';
  if v_count <> 0 then
    raise exception
      'FAIL[disable before first upsert]: disabled account entered projection';
  end if;
end $$;

select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.set_provider_account_statuses(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountA2,
    'status', 'disabled'
  )
));
select public.upsert_provider_account_quotas(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountA2,
    'provider', 'Claude',
    'account_label', 'Late snapshot',
    'plan_source', 'unknown',
    'plan_confidence', 'unavailable',
    'remaining', 1,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T06:00:00Z'
  )
));
reset role;

do $$
declare
  v_status text;
  v_remaining bigint;
begin
  select status into v_status
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and id = '27000000-7000-4700-8700-700000000002';
  if v_status is distinct from 'disabled' then
    raise exception 'FAIL[status authority]: late quota reactivated account';
  end if;

  select remaining into v_remaining
  from public.provider_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider = 'Claude';
  if v_remaining is distinct from 10 then
    raise exception
      'FAIL[disabled projection]: expected active sibling 10, got %',
      v_remaining;
  end if;
end $$;

-- Status payload validation rejects secret-shaped or unknown fields.
select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
do $$
declare
  v_rejected boolean := false;
begin
  begin
    perform public.set_provider_account_statuses(jsonb_build_array(
      jsonb_build_object(
        'account_id', '27000000-7000-4700-8700-700000000002',
        'status', 'active',
        'access_token', 'must-not-be-accepted'
      )
    ));
  exception when others then
    v_rejected :=
      position('Provider secrets are not accepted' in sqlerrm) > 0;
  end;
  if not v_rejected then
    raise exception 'FAIL[status secret boundary]: secret was accepted';
  end if;
end $$;

select public.set_provider_account_statuses(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountA2,
    'status', 'active'
  )
));
reset role;

do $$
declare
  v_remaining bigint;
begin
  select remaining into v_remaining
  from public.provider_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider = 'Claude';
  if v_remaining is distinct from 1 then
    raise exception
      'FAIL[reenable projection]: expected restored account 1, got %',
      v_remaining;
  end if;
end $$;

-- Deleting the most-constrained account cascades only its own quota row and
-- immediately refreshes the provider-level compatibility projection.
select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.delete_provider_account(:accountA2);
select public.upsert_provider_account_quotas(jsonb_build_array(
  jsonb_build_object(
    'account_id', :accountA2,
    'provider', 'Claude',
    'account_label', 'Stale app snapshot after delete',
    'plan_source', 'unknown',
    'plan_confidence', 'unavailable',
    'remaining', 0,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T07:00:00Z'
  )
));
reset role;

do $$
declare
  v_count integer;
  v_remaining bigint;
  v_plan text;
begin
  select count(*) into v_count
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and id = '17000000-7000-4700-8700-700000000001';
  if v_count <> 1 then
    raise exception 'FAIL[delete isolation]: sibling account was deleted';
  end if;

  select count(*) into v_count
  from public.provider_account_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider_account_id = '27000000-7000-4700-8700-700000000002';
  if v_count <> 0 then
    raise exception 'FAIL[delete cascade]: deleted account quota remains';
  end if;

  select count(*) into v_count
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and id = '27000000-7000-4700-8700-700000000002';
  if v_count <> 0 then
    raise exception 'FAIL[delete tombstone]: stale app upsert restored account';
  end if;

  select count(*) into v_count
  from public.provider_account_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider_account_id = '17000000-7000-4700-8700-700000000001';
  if v_count <> 1 then
    raise exception 'FAIL[delete isolation]: sibling quota was deleted';
  end if;

  select remaining, plan_type into v_remaining, v_plan
  from public.provider_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider = 'Claude';
  if v_remaining is distinct from 10 or v_plan is distinct from 'Fresh plan' then
    raise exception
      'FAIL[delete projection]: expected 10/Fresh plan, got %/%',
      v_remaining, v_plan;
  end if;
end $$;

-- A helper snapshot already in flight at deletion time must observe the same
-- durable server tombstone as the authenticated app writer.
select set_config(
  'request.jwt.claims',
  '{"sub":"a7000000-7000-4700-8700-700000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.delete_provider_account(:accountHelper);
reset role;

set local role anon;
select public.helper_sync_provider_account_quotas(
  :deviceA,
  'owner-helper-secret',
  jsonb_build_array(
    jsonb_build_object(
      'account_id', :accountHelper,
      'provider', 'Codex',
      'account_label', 'Stale helper snapshot after delete',
      'plan_source', 'accountMetadata',
      'plan_confidence', 'medium',
      'remaining', 1,
      'quota', 100,
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T07:01:00Z'
    )
  )
);
reset role;

do $$
declare
  v_count integer;
  v_status text;
begin
  select count(*) into v_count
  from public.provider_accounts
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and id = '47000000-7000-4700-8700-700000000004';
  if v_count <> 0 then
    raise exception
      'FAIL[delete tombstone]: stale helper upsert restored account';
  end if;

  select status into v_status
  from public.provider_account_lifecycle
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider_account_id = '47000000-7000-4700-8700-700000000004';
  if v_status is distinct from 'deleted' then
    raise exception
      'FAIL[delete tombstone]: helper lifecycle status is %',
      v_status;
  end if;

  select count(*) into v_count
  from public.provider_quotas
  where user_id = 'a7000000-7000-4700-8700-700000000001'
    and provider = 'Codex';
  if v_count <> 0 then
    raise exception
      'FAIL[delete tombstone]: stale helper entered projection';
  end if;
end $$;

-- ACL boundary: app RPCs are authenticated-only; helper RPC remains callable
-- with the anon key plus device credentials.
do $$
begin
  if has_function_privilege(
    'anon', 'public.upsert_provider_account_quotas(jsonb)', 'execute'
  ) then
    raise exception 'FAIL[ACL]: anon can execute app upsert';
  end if;
  if not has_function_privilege(
    'authenticated', 'public.upsert_provider_account_quotas(jsonb)', 'execute'
  ) then
    raise exception 'FAIL[ACL]: authenticated cannot execute app upsert';
  end if;
  if has_function_privilege(
    'anon', 'public.set_provider_account_statuses(jsonb)', 'execute'
  ) or has_function_privilege(
    'anon', 'public.delete_provider_account(uuid)', 'execute'
  ) then
    raise exception 'FAIL[ACL]: anon can mutate provider account lifecycle';
  end if;
  if not has_function_privilege(
    'authenticated',
    'public.set_provider_account_statuses(jsonb)',
    'execute'
  ) or not has_function_privilege(
    'authenticated', 'public.delete_provider_account(uuid)', 'execute'
  ) then
    raise exception
      'FAIL[ACL]: authenticated cannot mutate provider account lifecycle';
  end if;
  if has_function_privilege(
    'anon', 'public.provider_account_summary(date)', 'execute'
  ) then
    raise exception 'FAIL[ACL]: anon can execute account summary';
  end if;
  if not has_function_privilege(
    'authenticated', 'public.provider_account_summary(date)', 'execute'
  ) then
    raise exception 'FAIL[ACL]: authenticated cannot execute account summary';
  end if;
  if not has_function_privilege(
    'anon',
    'public.helper_sync_provider_account_quotas(uuid,text,jsonb)',
    'execute'
  ) then
    raise exception 'FAIL[ACL]: anon cannot execute helper account sync';
  end if;
  if has_table_privilege(
    'authenticated', 'public.provider_accounts', 'insert'
  ) or has_table_privilege(
    'authenticated', 'public.provider_accounts', 'update'
  ) or has_table_privilege(
    'authenticated', 'public.provider_accounts', 'delete'
  ) or has_table_privilege(
    'authenticated', 'public.provider_account_quotas', 'insert'
  ) or has_table_privilege(
    'authenticated', 'public.provider_account_quotas', 'update'
  ) or has_table_privilege(
    'authenticated', 'public.provider_account_quotas', 'delete'
  ) or has_table_privilege(
    'authenticated', 'public.provider_account_lifecycle', 'select'
  ) or has_table_privilege(
    'authenticated', 'public.provider_account_lifecycle', 'insert'
  ) or has_table_privilege(
    'authenticated', 'public.provider_account_lifecycle', 'update'
  ) or has_table_privilege(
    'authenticated', 'public.provider_account_lifecycle', 'delete'
  ) then
    raise exception 'FAIL[ACL]: authenticated can bypass account RPC writes';
  end if;
  if not has_table_privilege(
    'authenticated', 'public.provider_accounts', 'select'
  ) or not has_table_privilege(
    'authenticated', 'public.provider_account_quotas', 'select'
  ) then
    raise exception 'FAIL[ACL]: authenticated cannot read own account rows';
  end if;
  if has_function_privilege(
    'authenticated',
    'public._refresh_provider_quota_projection(uuid,text)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public._refresh_provider_quota_after_account_delete()',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public._lock_provider_account_owner_before_delete()',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public._upsert_provider_account_quotas_for_user(uuid,jsonb,uuid)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public._upsert_provider_account_quotas_for_user(uuid,jsonb,uuid)',
    'execute'
  ) then
    raise exception 'FAIL[ACL]: client role can execute internal account writer';
  end if;
end $$;

\echo 'provider-account v0.70 SQL contract: PASS'
rollback;

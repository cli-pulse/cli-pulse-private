#!/usr/bin/env bash
# Two-connection regression for provider-account delete serialization.
#
# Prerequisite: run against a disposable database with schema.sql, app_rpc.sql,
# and helper_rpc.sql already loaded (or the equivalent pre-v0.72 + migration).
#
# Usage:
#   DATABASE_URL=postgres://... ./migrate_v0.72_provider_accounts.concurrent.sh
#   # or rely on libpq PGHOST/PGPORT/PGUSER/PGDATABASE.
set -euo pipefail

PSQL=(psql --no-psqlrc -X -q -v ON_ERROR_STOP=1)
if [[ -n "${DATABASE_URL:-}" ]]; then
  PSQL+=("$DATABASE_URL")
fi

cleanup() {
  "${PSQL[@]}" -c "
    delete from auth.users
    where id = 'a7100000-7100-4710-8710-710000000001';
  " >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

"${PSQL[@]}" <<'SQL'
insert into auth.users (id, email)
values (
  'a7100000-7100-4710-8710-710000000001',
  'provider-delete-race@example.test'
);

begin;
select set_config(
  'request.jwt.claims',
  '{"sub":"a7100000-7100-4710-8710-710000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_provider_account_quotas(jsonb_build_array(
  jsonb_build_object(
    'account_id', '17100000-7100-4710-8710-710000000001',
    'provider', 'Claude',
    'account_label', 'Race A',
    'plan_type', 'Max',
    'plan_source', 'userConfirmed',
    'plan_confidence', 'high',
    'plan_observed_at', '2026-07-24T01:59:00Z',
    'remaining', 80,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T02:00:00Z'
  ),
  jsonb_build_object(
    'account_id', '27100000-7100-4710-8710-710000000002',
    'provider', 'Claude',
    'account_label', 'Race B',
    'plan_type', 'Pro',
    'plan_source', 'userConfirmed',
    'plan_confidence', 'high',
    'plan_observed_at', '2026-07-24T02:00:00Z',
    'remaining', 20,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T02:00:01Z'
  )
));
commit;
SQL

# Connection A holds the per-user transaction lock through the authenticated
# delete RPC. Connection B starts from the overlapping state and must wait
# before deleting account B. Direct table DELETE is intentionally not part of
# the supported service-role path because acquiring an advisory lock from a
# row trigger creates the reverse tuple-lock/advisory-lock order.
"${PSQL[@]}" -c "
  begin;
  select set_config(
    'request.jwt.claims',
    '{\"sub\":\"a7100000-7100-4710-8710-710000000001\",\"role\":\"authenticated\"}',
    true
  );
  set local role authenticated;
  select public.delete_provider_account(
    '17100000-7100-4710-8710-710000000001',
    'Claude'
  );
  select pg_sleep(1);
  commit;
" >/dev/null &
PID_A=$!

sleep 0.1

"${PSQL[@]}" -c "
  begin;
  select set_config(
    'request.jwt.claims',
    '{\"sub\":\"a7100000-7100-4710-8710-710000000001\",\"role\":\"authenticated\"}',
    true
  );
  set local role authenticated;
  select public.delete_provider_account(
    '27100000-7100-4710-8710-710000000002',
    'Claude'
  );
  commit;
" >/dev/null &
PID_B=$!

wait "$PID_A"
wait "$PID_B"

"${PSQL[@]}" <<'SQL'
do $$
declare
  v_accounts integer;
  v_account_quotas integer;
  v_legacy integer;
begin
  select count(*) into v_accounts
  from public.provider_accounts
  where user_id = 'a7100000-7100-4710-8710-710000000001';

  select count(*) into v_account_quotas
  from public.provider_account_quotas
  where user_id = 'a7100000-7100-4710-8710-710000000001';

  select count(*) into v_legacy
  from public.provider_quotas
  where user_id = 'a7100000-7100-4710-8710-710000000001'
    and provider = 'Claude';

  if v_accounts <> 0 or v_account_quotas <> 0 or v_legacy <> 0 then
    raise exception
      'FAIL[delete race]: accounts=% account_quotas=% legacy=%',
      v_accounts, v_account_quotas, v_legacy;
  end if;
end $$;
SQL

# A delayed stale write must not roll back a newer snapshot that commits first.
# Connection A starts first but sleeps before its stale RPC; connection B lands
# the fresh observation while A is still in flight.
"${PSQL[@]}" -c "
  begin;
  select set_config(
    'request.jwt.claims',
    '{\"sub\":\"a7100000-7100-4710-8710-710000000001\",\"role\":\"authenticated\"}',
    true
  );
  set local role authenticated;
  select pg_sleep(1);
  select public.upsert_provider_account_quotas(jsonb_build_array(
    jsonb_build_object(
      'account_id', '37100000-7100-4710-8710-710000000003',
      'provider', 'Claude',
      'account_label', 'Stale completion',
      'plan_type', 'Stale plan',
      'plan_source', 'unknown',
      'plan_confidence', 'low',
      'plan_observed_at', '2026-07-24T02:59:00Z',
      'remaining', 90,
      'quota', 100,
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T03:00:00Z'
    )
  ));
  commit;
" >/dev/null &
PID_STALE=$!

sleep 0.1

"${PSQL[@]}" -c "
  begin;
  select set_config(
    'request.jwt.claims',
    '{\"sub\":\"a7100000-7100-4710-8710-710000000001\",\"role\":\"authenticated\"}',
    true
  );
  set local role authenticated;
  select public.upsert_provider_account_quotas(jsonb_build_array(
    jsonb_build_object(
      'account_id', '37100000-7100-4710-8710-710000000003',
      'provider', 'Claude',
      'account_label', 'Fresh completion',
      'plan_type', 'Fresh plan',
      'plan_source', 'providerAPI',
      'plan_confidence', 'high',
      'plan_observed_at', '2026-07-24T03:59:00Z',
      'remaining', 10,
      'quota', 100,
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T04:00:00Z'
    )
  ));
  commit;
" >/dev/null

wait "$PID_STALE"

"${PSQL[@]}" <<'SQL'
do $$
declare
  v_label text;
  v_plan text;
  v_remaining bigint;
  v_observed_at timestamptz;
begin
  select a.display_label, a.plan_type, q.remaining, q.observed_at
    into v_label, v_plan, v_remaining, v_observed_at
  from public.provider_accounts a
  join public.provider_account_quotas q
    on q.user_id = a.user_id and q.provider_account_id = a.id
  where a.user_id = 'a7100000-7100-4710-8710-710000000001'
    and a.id = '37100000-7100-4710-8710-710000000003';

  if v_label is distinct from 'Fresh completion'
     or v_plan is distinct from 'Fresh plan'
     or v_remaining is distinct from 10
     or v_observed_at is distinct from
       '2026-07-24T04:00:00Z'::timestamptz then
    raise exception
      'FAIL[write freshness race]: label=% plan=% remaining=% observed=%',
      v_label, v_plan, v_remaining, v_observed_at;
  end if;
end $$;
SQL

# Quota and plan evidence have independent clocks. The delayed request carries
# an older quota snapshot but newer plan evidence; it must update only the plan
# after the newer quota request commits.
"${PSQL[@]}" -c "
  begin;
  select set_config(
    'request.jwt.claims',
    '{\"sub\":\"a7100000-7100-4710-8710-710000000001\",\"role\":\"authenticated\"}',
    true
  );
  set local role authenticated;
  select pg_sleep(1);
  select public.upsert_provider_account_quotas(jsonb_build_array(
    jsonb_build_object(
      'account_id', '37100000-7100-4710-8710-710000000003',
      'provider', 'Claude',
      'account_label', 'Old quota completion',
      'plan_type', 'Newest independent plan',
      'plan_source', 'userConfirmed',
      'plan_confidence', 'high',
      'plan_observed_at', '2026-07-24T06:00:00Z',
      'remaining', 95,
      'quota', 100,
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T03:30:00Z'
    )
  ));
  commit;
" >/dev/null &
PID_NEW_PLAN=$!

sleep 0.1

"${PSQL[@]}" -c "
  begin;
  select set_config(
    'request.jwt.claims',
    '{\"sub\":\"a7100000-7100-4710-8710-710000000001\",\"role\":\"authenticated\"}',
    true
  );
  set local role authenticated;
  select public.upsert_provider_account_quotas(jsonb_build_array(
    jsonb_build_object(
      'account_id', '37100000-7100-4710-8710-710000000003',
      'provider', 'Claude',
      'account_label', 'Newest quota completion',
      'plan_type', 'Older plan evidence',
      'plan_source', 'providerAPI',
      'plan_confidence', 'medium',
      'plan_observed_at', '2026-07-24T05:00:00Z',
      'remaining', 7,
      'quota', 100,
      'tiers', '[]'::jsonb,
      'observed_at', '2026-07-24T05:00:00Z'
    )
  ));
  commit;
" >/dev/null

wait "$PID_NEW_PLAN"

"${PSQL[@]}" <<'SQL'
do $$
declare
  v_label text;
  v_plan text;
  v_plan_observed_at timestamptz;
  v_remaining bigint;
  v_observed_at timestamptz;
begin
  select
    a.display_label,
    a.plan_type,
    a.plan_observed_at,
    q.remaining,
    q.observed_at
  into
    v_label,
    v_plan,
    v_plan_observed_at,
    v_remaining,
    v_observed_at
  from public.provider_accounts a
  join public.provider_account_quotas q
    on q.user_id = a.user_id and q.provider_account_id = a.id
  where a.user_id = 'a7100000-7100-4710-8710-710000000001'
    and a.id = '37100000-7100-4710-8710-710000000003';

  if v_label is distinct from 'Newest quota completion'
     or v_plan is distinct from 'Newest independent plan'
     or v_plan_observed_at is distinct from
       '2026-07-24T06:00:00Z'::timestamptz
     or v_remaining is distinct from 7
     or v_observed_at is distinct from
       '2026-07-24T05:00:00Z'::timestamptz then
    raise exception
      'FAIL[independent clock race]: label=% plan=% plan_observed=% remaining=% quota_observed=%',
      v_label, v_plan, v_plan_observed_at, v_remaining, v_observed_at;
  end if;
end $$;
SQL

echo "provider-account v0.72 concurrent delete/freshness/clock contract: PASS"

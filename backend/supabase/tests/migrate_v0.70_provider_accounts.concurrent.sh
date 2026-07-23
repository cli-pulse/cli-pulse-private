#!/usr/bin/env bash
# Two-connection regression for provider-account delete serialization.
#
# Prerequisite: run against a disposable database with schema.sql, app_rpc.sql,
# and helper_rpc.sql already loaded (or the equivalent pre-v0.70 + migration).
#
# Usage:
#   DATABASE_URL=postgres://... ./migrate_v0.70_provider_accounts.concurrent.sh
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
    'remaining', 20,
    'quota', 100,
    'tiers', '[]'::jsonb,
    'observed_at', '2026-07-24T02:00:01Z'
  )
));
commit;
SQL

# Connection A holds the per-user transaction lock after deleting account A.
# Connection B starts from the overlapping state and must wait before deleting
# account B. Without a shared delete/upsert lock, B can re-project the already
# deleted A account after A commits.
"${PSQL[@]}" -c "
  begin;
  delete from public.provider_accounts
  where user_id = 'a7100000-7100-4710-8710-710000000001'
    and id = '17100000-7100-4710-8710-710000000001';
  select pg_sleep(1);
  commit;
" >/dev/null &
PID_A=$!

sleep 0.1

"${PSQL[@]}" -c "
  begin;
  delete from public.provider_accounts
  where user_id = 'a7100000-7100-4710-8710-710000000001'
    and id = '27100000-7100-4710-8710-710000000002';
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

echo "provider-account v0.70 concurrent delete contract: PASS"

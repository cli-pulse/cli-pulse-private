-- ============================================================================
-- v0.70 — account-scoped provider quotas
-- Date: 2026-07-24
--
-- Additive migration:
--   * keeps provider_quotas/provider_summary/helper_sync unchanged for old apps;
--   * stores multiple stable accounts for the same provider;
--   * exposes authenticated app and device-authenticated helper RPCs;
--   * projects the most constrained comparable account back to provider_quotas.
--
-- Privacy boundary:
--   provider credentials and external account identifiers are not columns.
--   Secret-shaped JSON keys are rejected rather than silently ignored.
--
-- Unknown quota boundary:
--   remaining/quota are nullable. NULL means unknown; it must never be coerced
--   to zero because old clients interpret zero as exhausted.
--
-- Rollback (before clients depend on v2):
--   drop the three public RPCs, five internal functions, three triggers, then
--   the two tables. provider_quotas/provider_summary remain intact throughout.
-- ============================================================================

-- v0.43 already widened the live table. Reassert the canonical type here so
-- an environment bootstrapped from an older/stale schema cannot overflow when
-- v0.70 projects a 64-bit account quota to the legacy row.
alter table public.provider_quotas
  alter column remaining type bigint using remaining::bigint,
  alter column quota type bigint using quota::bigint;

create table if not exists public.provider_accounts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  id uuid not null,
  provider text not null
    check (char_length(provider) between 1 and 64),
  display_label text
    check (display_label is null or char_length(display_label) <= 120),
  plan_type text
    check (plan_type is null or char_length(plan_type) <= 120),
  plan_source text not null default 'unknown'
    check (plan_source in (
      'providerAPI', 'accountMetadata', 'localCredential',
      'webFallback', 'userConfirmed', 'unknown'
    )),
  plan_confidence text not null default 'unavailable'
    check (plan_confidence in ('high', 'medium', 'low', 'unavailable')),
  plan_observed_at timestamptz,
  status text not null default 'active'
    check (status in ('active', 'disabled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, id),
  unique (user_id, id, provider)
);

create table if not exists public.provider_account_quotas (
  user_id uuid not null references public.profiles(id) on delete cascade,
  provider_account_id uuid not null,
  provider text not null
    check (char_length(provider) between 1 and 64),
  remaining bigint
    check (remaining is null or remaining >= 0),
  quota bigint
    check (quota is null or quota >= 0),
  reset_time timestamptz,
  tiers jsonb not null default '[]'::jsonb
    check (jsonb_typeof(tiers) = 'array'),
  observed_at timestamptz not null,
  source_device_id uuid references public.devices(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (user_id, provider_account_id),
  foreign key (user_id, provider_account_id, provider)
    references public.provider_accounts(user_id, id, provider)
    on delete cascade
);

alter table public.provider_accounts enable row level security;
alter table public.provider_account_quotas enable row level security;

drop policy if exists "Users can manage own provider accounts"
  on public.provider_accounts;
drop policy if exists "Users can read own provider accounts"
  on public.provider_accounts;
create policy "Users can read own provider accounts"
  on public.provider_accounts for select
  using ((select auth.uid()) = user_id);

drop policy if exists "Users can manage own provider account quotas"
  on public.provider_account_quotas;
drop policy if exists "Users can read own provider account quotas"
  on public.provider_account_quotas;
create policy "Users can read own provider account quotas"
  on public.provider_account_quotas for select
  using ((select auth.uid()) = user_id);

create index if not exists idx_provider_accounts_user_provider
  on public.provider_accounts(user_id, provider);
create index if not exists idx_provider_accounts_updated_at
  on public.provider_accounts(updated_at);
create index if not exists idx_provider_account_quotas_user_provider
  on public.provider_account_quotas(user_id, provider);
create index if not exists idx_provider_account_quotas_updated_at
  on public.provider_account_quotas(updated_at);
create index if not exists idx_provider_account_quotas_source_device
  on public.provider_account_quotas(source_device_id)
  where source_device_id is not null;

revoke all on public.provider_accounts
  from public, anon, authenticated;
revoke all on public.provider_account_quotas
  from public, anon, authenticated;
grant select on public.provider_accounts, public.provider_account_quotas
  to authenticated;
grant select, insert, update, delete
  on public.provider_accounts, public.provider_account_quotas
  to service_role;

-- Defense in depth for privileged writes: source-device provenance must still
-- belong to the account owner even when a trusted server role writes directly.
create or replace function public._validate_provider_account_quota_device()
returns trigger as $$
begin
  if new.source_device_id is not null
     and not exists (
       select 1
       from public.devices d
       where d.id = new.source_device_id
         and d.user_id = new.user_id
     ) then
    raise exception 'Source device does not belong to provider account owner';
  end if;
  return new;
end;
$$ language plpgsql security definer
set search_path = pg_catalog, public, extensions;

revoke execute on function public._validate_provider_account_quota_device()
  from public, anon, authenticated;

drop trigger if exists validate_provider_account_quota_device
  on public.provider_account_quotas;
create trigger validate_provider_account_quota_device
  before insert or update of user_id, source_device_id
  on public.provider_account_quotas
  for each row execute function public._validate_provider_account_quota_device();

-- Maintain the single provider-level compatibility row from the account-scoped
-- source of truth. This shared routine is used after both account upserts and
-- deletes so old clients never retain a stale account.
create or replace function public._refresh_provider_quota_projection(
  p_user_id uuid,
  p_provider text
)
returns void as $$
declare
  v_active_count integer;
  v_best_remaining bigint;
  v_best_quota bigint;
  v_best_plan text;
  v_best_reset timestamptz;
  v_best_tiers jsonb;
  v_best_found boolean;
begin
  if p_user_id is null or p_provider is null then
    return;
  end if;

  -- During profile deletion the compatibility row is already being cascaded.
  if not exists (
    select 1 from public.profiles where id = p_user_id
  ) then
    return;
  end if;

  select
    q.remaining, q.quota, a.plan_type, q.reset_time, q.tiers
  into
    v_best_remaining, v_best_quota, v_best_plan, v_best_reset, v_best_tiers
  from public.provider_accounts a
  join public.provider_account_quotas q
    on q.user_id = a.user_id
   and q.provider_account_id = a.id
   and q.provider = a.provider
  where a.user_id = p_user_id
    and a.provider = p_provider
    and a.status = 'active'
    and q.remaining is not null
  order by
    case when q.quota is not null and q.quota > 0
      then q.remaining::numeric / q.quota::numeric
    end asc nulls last,
    q.remaining asc,
    q.observed_at desc,
    a.id
  limit 1;
  v_best_found := found;

  select count(*) into v_active_count
  from public.provider_accounts
  where user_id = p_user_id
    and provider = p_provider
    and status = 'active';

  if v_best_found then
    insert into public.provider_quotas (
      user_id, provider, remaining, quota, plan_type,
      reset_time, tiers, updated_at
    ) values (
      p_user_id, p_provider, v_best_remaining, v_best_quota,
      case when v_active_count > 1 then 'Multiple accounts' else v_best_plan end,
      v_best_reset, coalesce(v_best_tiers, '[]'::jsonb), now()
    )
    on conflict (user_id, provider) do update set
      remaining = excluded.remaining,
      quota = excluded.quota,
      plan_type = excluded.plan_type,
      reset_time = excluded.reset_time,
      tiers = excluded.tiers,
      updated_at = now();
  else
    delete from public.provider_quotas
    where user_id = p_user_id and provider = p_provider;
  end if;
end;
$$ language plpgsql security definer
set search_path = pg_catalog, public, extensions;

revoke execute on function public._refresh_provider_quota_projection(
  uuid, text
) from public, anon, authenticated;

create or replace function public._lock_provider_account_owner_before_delete()
returns trigger as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(old.user_id::text, 70));
  return old;
end;
$$ language plpgsql security definer
set search_path = pg_catalog, public, extensions;

revoke execute on function public._lock_provider_account_owner_before_delete()
  from public, anon, authenticated;

drop trigger if exists lock_provider_account_owner_before_delete
  on public.provider_accounts;
create trigger lock_provider_account_owner_before_delete
  before delete on public.provider_accounts
  for each row
  execute function public._lock_provider_account_owner_before_delete();

create or replace function public._refresh_provider_quota_after_account_delete()
returns trigger as $$
begin
  perform public._refresh_provider_quota_projection(
    old.user_id, old.provider
  );
  return old;
end;
$$ language plpgsql security definer
set search_path = pg_catalog, public, extensions;

revoke execute on function public._refresh_provider_quota_after_account_delete()
  from public, anon, authenticated;

drop trigger if exists refresh_provider_quota_after_account_delete
  on public.provider_accounts;
create trigger refresh_provider_quota_after_account_delete
  after delete on public.provider_accounts
  for each row
  execute function public._refresh_provider_quota_after_account_delete();

-- Shared writer used by the app and helper wrappers. It is intentionally not
-- client-callable because p_user_id is a trusted argument supplied only after
-- auth.uid() or helper-secret authentication.
create or replace function public._upsert_provider_account_quotas_for_user(
  p_user_id uuid,
  p_rows jsonb,
  p_source_device_id uuid default null
)
returns jsonb as $$
declare
  v_row jsonb;
  v_account_id uuid;
  v_provider text;
  v_existing_provider text;
  v_label text;
  v_plan_type text;
  v_plan_source text;
  v_plan_confidence text;
  v_plan_observed_at timestamptz;
  v_status text;
  v_remaining bigint;
  v_quota bigint;
  v_reset_time timestamptz;
  v_tiers jsonb;
  v_tier jsonb;
  v_tier_name text;
  v_tier_quota bigint;
  v_tier_remaining bigint;
  v_tier_reset_time timestamptz;
  v_tier_window_minutes bigint;
  v_tier_role text;
  v_observed_at timestamptz;
  v_row_source_device_id uuid;
  v_effective_source_device_id uuid;
  v_synced integer := 0;
  v_stored_account_count integer;
  v_touched_providers text[] := array[]::text[];
  v_field text;
begin
  if p_user_id is null then
    raise exception 'Provider account owner is required';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Provider account payload must be an array';
  end if;
  if pg_column_size(p_rows) > 262144 then
    raise exception 'Provider account payload too large (max 262144 bytes)';
  end if;
  if jsonb_array_length(p_rows) > 100 then
    raise exception 'Too many provider accounts (max 100)';
  end if;

  if p_source_device_id is not null
     and not exists (
       select 1 from public.devices
       where id = p_source_device_id and user_id = p_user_id
     ) then
    raise exception 'Source device does not belong to provider account owner';
  end if;

  -- Serialize the user's account snapshot and compatibility projection.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 70));
  select count(*) into v_stored_account_count
  from public.provider_accounts
  where user_id = p_user_id;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception 'Provider account row must be an object';
    end if;
    if v_row ?| array[
      'api_key', 'apiKey', 'cookie', 'cookie_header', 'manualCookieHeader',
      'access_token', 'accessToken', 'refresh_token', 'refreshToken', 'token'
    ] then
      raise exception 'Provider secrets are not accepted';
    end if;
    if exists (
      select 1
      from jsonb_object_keys(v_row) as fields(field_name)
      where field_name not in (
        'user_id', 'account_id', 'provider', 'account_label',
        'plan_type', 'plan_source', 'plan_confidence', 'plan_observed_at',
        'status', 'remaining', 'quota', 'reset_time', 'tiers',
        'observed_at', 'source_device_id'
      )
    ) then
      raise exception 'Unknown provider account field';
    end if;
    foreach v_field in array array[
      'user_id', 'account_id', 'provider', 'account_label',
      'plan_type', 'plan_source', 'plan_confidence', 'plan_observed_at',
      'status', 'reset_time', 'observed_at', 'source_device_id'
    ] loop
      if v_row ? v_field
         and v_row->v_field <> 'null'::jsonb
         and jsonb_typeof(v_row->v_field) <> 'string' then
        raise exception
          'Provider account field % must be a string or null', v_field;
      end if;
    end loop;

    begin
      v_account_id := nullif(v_row->>'account_id', '')::uuid;
    exception when invalid_text_representation then
      raise exception 'Invalid provider account_id';
    end;
    if v_account_id is null then
      raise exception 'Provider account_id is required';
    end if;

    v_provider := btrim(coalesce(v_row->>'provider', ''));
    if char_length(v_provider) < 1 or char_length(v_provider) > 64 then
      raise exception 'Invalid provider name';
    end if;

    v_label := nullif(btrim(coalesce(v_row->>'account_label', '')), '');
    if v_label is not null and char_length(v_label) > 120 then
      raise exception 'Account label too long (max 120 characters)';
    end if;

    v_plan_type := nullif(btrim(coalesce(v_row->>'plan_type', '')), '');
    if v_plan_type is not null and char_length(v_plan_type) > 120 then
      raise exception 'Plan type too long (max 120 characters)';
    end if;

    v_plan_source := coalesce(nullif(v_row->>'plan_source', ''), 'unknown');
    if v_plan_source not in (
      'providerAPI', 'accountMetadata', 'localCredential',
      'webFallback', 'userConfirmed', 'unknown'
    ) then
      raise exception 'Invalid plan_source';
    end if;

    v_plan_confidence :=
      coalesce(nullif(v_row->>'plan_confidence', ''), 'unavailable');
    if v_plan_confidence not in ('high', 'medium', 'low', 'unavailable') then
      raise exception 'Invalid plan_confidence';
    end if;

    v_status := coalesce(nullif(v_row->>'status', ''), 'active');
    if v_status not in ('active', 'disabled') then
      raise exception 'Invalid provider account status';
    end if;

    begin
      v_plan_observed_at :=
        nullif(v_row->>'plan_observed_at', '')::timestamptz;
      v_reset_time := nullif(v_row->>'reset_time', '')::timestamptz;
      v_observed_at := nullif(v_row->>'observed_at', '')::timestamptz;
    exception when invalid_datetime_format or datetime_field_overflow then
      raise exception 'Invalid provider account timestamp';
    end;
    if v_observed_at is null then
      raise exception 'Provider account observed_at is required';
    end if;

    if v_row ? 'remaining'
       and v_row->'remaining' <> 'null'::jsonb
       and jsonb_typeof(v_row->'remaining') <> 'number' then
      raise exception 'Provider account remaining must be a number or null';
    end if;
    if v_row ? 'quota'
       and v_row->'quota' <> 'null'::jsonb
       and jsonb_typeof(v_row->'quota') <> 'number' then
      raise exception 'Provider account quota must be a number or null';
    end if;
    begin
      v_remaining := nullif(v_row->>'remaining', '')::bigint;
      v_quota := nullif(v_row->>'quota', '')::bigint;
    exception when invalid_text_representation or numeric_value_out_of_range then
      raise exception 'Invalid provider account quota value';
    end;
    if v_remaining is not null and v_remaining < 0 then
      raise exception 'Provider account remaining cannot be negative';
    end if;
    if v_quota is not null and v_quota < 0 then
      raise exception 'Provider account quota cannot be negative';
    end if;

    v_tiers := coalesce(v_row->'tiers', '[]'::jsonb);
    if jsonb_typeof(v_tiers) <> 'array' then
      raise exception 'Provider account tiers must be an array';
    end if;
    if jsonb_array_length(v_tiers) > 24 then
      raise exception 'Too many provider account tiers (max 24)';
    end if;
    for v_tier in select value from jsonb_array_elements(v_tiers) loop
      if jsonb_typeof(v_tier) <> 'object' then
        raise exception 'Provider account tier must be an object';
      end if;
      if v_tier ?| array[
        'api_key', 'apiKey', 'cookie', 'cookie_header',
        'manualCookieHeader', 'access_token', 'accessToken',
        'refresh_token', 'refreshToken', 'token'
      ] then
        raise exception 'Provider secrets are not accepted';
      end if;
      if exists (
        select 1
        from jsonb_object_keys(v_tier) as fields(field_name)
        where field_name not in (
          'name', 'quota', 'remaining', 'reset_time',
          'windowMinutes', 'role'
        )
      ) then
        raise exception 'Unknown provider account tier field';
      end if;

      if not (v_tier ? 'name')
         or jsonb_typeof(v_tier->'name') <> 'string' then
        raise exception 'Provider account tier name is required';
      end if;
      v_tier_name := btrim(v_tier->>'name');
      if char_length(v_tier_name) < 1 or char_length(v_tier_name) > 120 then
        raise exception 'Invalid provider account tier name';
      end if;

      if not (v_tier ? 'quota')
         or jsonb_typeof(v_tier->'quota') <> 'number'
         or not (v_tier ? 'remaining')
         or jsonb_typeof(v_tier->'remaining') <> 'number' then
        raise exception 'Provider account tier quota values must be numbers';
      end if;
      begin
        v_tier_quota := (v_tier->>'quota')::bigint;
        v_tier_remaining := (v_tier->>'remaining')::bigint;
      exception when invalid_text_representation or numeric_value_out_of_range then
        raise exception 'Invalid provider account tier quota value';
      end;
      if v_tier_quota < 0 or v_tier_remaining < 0 then
        raise exception 'Provider account tier quota values cannot be negative';
      end if;

      v_tier_reset_time := null;
      if v_tier ? 'reset_time'
         and v_tier->'reset_time' <> 'null'::jsonb then
        if jsonb_typeof(v_tier->'reset_time') <> 'string' then
          raise exception 'Invalid provider account tier reset_time';
        end if;
        begin
          v_tier_reset_time := (v_tier->>'reset_time')::timestamptz;
        exception when invalid_datetime_format or datetime_field_overflow then
          raise exception 'Invalid provider account tier reset_time';
        end;
      end if;

      v_tier_window_minutes := null;
      if v_tier ? 'windowMinutes'
         and v_tier->'windowMinutes' <> 'null'::jsonb then
        if jsonb_typeof(v_tier->'windowMinutes') <> 'number' then
          raise exception 'Invalid provider account tier windowMinutes';
        end if;
        begin
          v_tier_window_minutes := (v_tier->>'windowMinutes')::bigint;
        exception when invalid_text_representation or numeric_value_out_of_range then
          raise exception 'Invalid provider account tier windowMinutes';
        end;
        if v_tier_window_minutes < 0 then
          raise exception 'Invalid provider account tier windowMinutes';
        end if;
      end if;

      v_tier_role := null;
      if v_tier ? 'role' and v_tier->'role' <> 'null'::jsonb then
        if jsonb_typeof(v_tier->'role') <> 'string' then
          raise exception 'Invalid provider account tier role';
        end if;
        v_tier_role := v_tier->>'role';
        if v_tier_role not in (
          'primary', 'secondary', 'modelSpecific', 'credits'
        ) then
          raise exception 'Invalid provider account tier role';
        end if;
      end if;
    end loop;

    v_row_source_device_id := null;
    if nullif(v_row->>'source_device_id', '') is not null then
      begin
        v_row_source_device_id := (v_row->>'source_device_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'Invalid source_device_id';
      end;
    end if;
    v_effective_source_device_id :=
      coalesce(p_source_device_id, v_row_source_device_id);
    if v_effective_source_device_id is not null
       and not exists (
         select 1 from public.devices
         where id = v_effective_source_device_id and user_id = p_user_id
       ) then
      raise exception 'Source device does not belong to provider account owner';
    end if;

    v_existing_provider := null;
    select provider into v_existing_provider
    from public.provider_accounts
    where user_id = p_user_id and id = v_account_id
    for update;
    if v_existing_provider is not null
       and v_existing_provider <> v_provider then
      raise exception 'Provider account does not match existing provider';
    end if;
    if v_existing_provider is null then
      if v_stored_account_count >= 100 then
        raise exception 'Too many stored provider accounts (max 100)';
      end if;
      v_stored_account_count := v_stored_account_count + 1;
    end if;

    insert into public.provider_accounts (
      user_id, id, provider, display_label, plan_type,
      plan_source, plan_confidence, plan_observed_at, status, updated_at
    ) values (
      p_user_id, v_account_id, v_provider, v_label, v_plan_type,
      v_plan_source, v_plan_confidence, v_plan_observed_at, v_status, now()
    )
    on conflict (user_id, id) do update set
      display_label = excluded.display_label,
      plan_type = excluded.plan_type,
      plan_source = excluded.plan_source,
      plan_confidence = excluded.plan_confidence,
      plan_observed_at = excluded.plan_observed_at,
      status = excluded.status,
      updated_at = now();

    insert into public.provider_account_quotas (
      user_id, provider_account_id, provider, remaining, quota,
      reset_time, tiers, observed_at, source_device_id, updated_at
    ) values (
      p_user_id, v_account_id, v_provider, v_remaining, v_quota,
      v_reset_time, v_tiers, v_observed_at,
      v_effective_source_device_id, now()
    )
    on conflict (user_id, provider_account_id) do update set
      provider = excluded.provider,
      remaining = excluded.remaining,
      quota = excluded.quota,
      reset_time = excluded.reset_time,
      tiers = excluded.tiers,
      observed_at = excluded.observed_at,
      source_device_id = excluded.source_device_id,
      updated_at = now();

    if not (v_provider = any(v_touched_providers)) then
      v_touched_providers := array_append(v_touched_providers, v_provider);
    end if;
    v_synced := v_synced + 1;
  end loop;

  -- Old clients keep one provider-level row. Pick the lowest comparable
  -- remaining ratio, never sum independent account windows, and never emit a
  -- fabricated zero when every account has unknown remaining.
  foreach v_provider in array v_touched_providers loop
    perform public._refresh_provider_quota_projection(
      p_user_id, v_provider
    );
  end loop;

  return jsonb_build_object('accounts_synced', v_synced);
end;
$$ language plpgsql security definer
set search_path = pg_catalog, public, extensions;

revoke execute on function public._upsert_provider_account_quotas_for_user(
  uuid, jsonb, uuid
) from public, anon, authenticated;

-- Authenticated app writer. p_rows.user_id is intentionally ignored.
create or replace function public.upsert_provider_account_quotas(
  p_rows jsonb
)
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  return public._upsert_provider_account_quotas_for_user(
    v_user_id, p_rows, null
  );
end;
$$ language plpgsql security definer
set search_path = pg_catalog, public, extensions;

revoke execute on function public.upsert_provider_account_quotas(jsonb)
  from public, anon;
grant execute on function public.upsert_provider_account_quotas(jsonb)
  to authenticated, service_role;

-- Provider-level usage/cost is computed once, while quota accounts remain a
-- nested array. This avoids multiplying token/cost totals by account count.
create or replace function public.provider_account_summary(
  p_user_today date default null
)
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := coalesce(p_user_today, current_date);
  v_week_start date := v_today - 6;
  v_month_start date := v_today - 29;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return (
    with usage_agg as (
      select
        provider,
        sum(case when metric_date = v_today
              then coalesce(input_tokens, 0)
                 + coalesce(cached_tokens, 0)
                 + coalesce(output_tokens, 0)
              else 0 end) as today_usage,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then coalesce(input_tokens, 0)
                 + coalesce(cached_tokens, 0)
                 + coalesce(output_tokens, 0)
              else 0 end) as total_usage,
        sum(case when metric_date = v_today then cost else 0 end) as today_cost,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then cost else 0 end) as week_cost,
        sum(case when metric_date >= v_month_start and metric_date <= v_today
              then cost else 0 end) as month_cost
      from public.daily_usage_metrics
      where user_id = v_user_id
        and metric_date >= v_month_start
        and metric_date <= v_today
      group by provider
    ),
    account_rows as (
      select
        a.provider,
        coalesce(a.display_label, '') as sort_label,
        a.id as sort_id,
        jsonb_build_object(
          'id', a.id,
          'provider', a.provider,
          'account_label', a.display_label,
          'plan_evidence', jsonb_build_object(
            'raw_value', a.plan_type,
            'display_value', a.plan_type,
            'source', a.plan_source,
            'confidence', a.plan_confidence,
            'observed_at', a.plan_observed_at
          ),
          'quota', q.quota,
          'remaining', q.remaining,
          'tiers', coalesce(q.tiers, '[]'::jsonb),
          'reset_time', q.reset_time,
          'observed_at', q.observed_at,
          'source_device_id', q.source_device_id,
          'status_text', '',
          'status', a.status,
          'updated_at', greatest(a.updated_at, q.updated_at)
        ) as account_data
      from public.provider_accounts a
      left join public.provider_account_quotas q
        on q.user_id = a.user_id
       and q.provider_account_id = a.id
       and q.provider = a.provider
      where a.user_id = v_user_id
    ),
    account_agg as (
      select
        provider,
        jsonb_agg(account_data order by sort_label, sort_id) as accounts
      from account_rows
      group by provider
    )
    select coalesce(
      jsonb_agg(row_data order by sort_key desc, provider_key),
      '[]'::jsonb
    )
    from (
      select
        coalesce(u.provider, a.provider) as provider_key,
        coalesce(u.total_usage, 0) as sort_key,
        jsonb_build_object(
          'provider', coalesce(u.provider, a.provider),
          'today_usage', coalesce(u.today_usage, 0),
          'total_usage', coalesce(u.total_usage, 0),
          'estimated_cost', coalesce(u.week_cost, 0),
          'estimated_cost_today', coalesce(u.today_cost, 0),
          'estimated_cost_30_day', coalesce(u.month_cost, 0),
          'accounts', coalesce(a.accounts, '[]'::jsonb)
        ) as row_data
      from usage_agg u
      full outer join account_agg a on a.provider = u.provider
    ) rows
  );
end;
$$ language plpgsql security definer
set search_path = pg_catalog, public, extensions;

revoke execute on function public.provider_account_summary(date)
  from public, anon;
grant execute on function public.provider_account_summary(date)
  to authenticated, service_role;

-- Device-authenticated helper writer. The authenticated device always
-- overrides payload source_device_id and payload user_id is ignored.
create or replace function public.helper_sync_provider_account_quotas(
  p_device_id uuid,
  p_helper_secret text,
  p_rows jsonb default '[]'::jsonb
)
returns jsonb as $$
declare
  v_user_id uuid;
begin
  select user_id into v_user_id
  from public.devices
  where id = p_device_id
    and helper_secret = encode(
      extensions.digest(p_helper_secret, 'sha256'),
      'hex'
    );

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  return public._upsert_provider_account_quotas_for_user(
    v_user_id, p_rows, p_device_id
  );
end;
$$ language plpgsql security definer
set search_path = pg_catalog, public, extensions;

revoke execute on function public.helper_sync_provider_account_quotas(
  uuid, text, jsonb
) from public;
grant execute on function public.helper_sync_provider_account_quotas(
  uuid, text, jsonb
) to anon, authenticated, service_role;

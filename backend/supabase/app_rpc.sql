-- ============================================================
-- CLI Pulse — App RPC Functions
-- Called by the iOS/macOS/watchOS app via authenticated user JWT.
-- All use security definer so they bypass RLS with internal auth.
-- ============================================================

-- dashboard_summary: returns overview stats for the authenticated user.
-- v1.10.5+: sources today_usage/today_cost from daily_usage_metrics
-- (populated by CostUsageScanner via JSONL bookmarks, unaffected by the
-- MAS sandbox gap that made `sessions` unreliable).
-- v0.42 (2026-05-08): added p_user_today parameter so the "today" boundary
-- aligns with the user's local timezone instead of the server's UTC clock.
-- Old callers without the param keep prior behavior via the NULL default.
-- See migrate_v0.42_user_tz_today.sql for the bug write-up.
create or replace function public.dashboard_summary(
  p_user_today date default null
)
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := coalesce(p_user_today, current_date);
  v_today_usage bigint;
  v_today_cost numeric;
  v_today_rows integer;
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select
    coalesce(sum(coalesce(input_tokens,0) + coalesce(cached_tokens,0) + coalesce(output_tokens,0)), 0),
    coalesce(sum(cost), 0),
    count(*)
  into v_today_usage, v_today_cost, v_today_rows
  from public.daily_usage_metrics
  where user_id = v_user_id
    and metric_date = v_today;

  select jsonb_build_object(
    'today_usage', v_today_usage,
    'today_cost', v_today_cost,
    'active_sessions', (
      select count(*) from public.sessions
      where user_id = v_user_id and status = 'Running'
    ),
    'online_devices', (
      select count(*) from public.devices
      where user_id = v_user_id and status = 'Online'
    ),
    'unresolved_alerts', (
      select count(*) from public.alerts
      where user_id = v_user_id and is_resolved = false
    ),
    'today_sessions', v_today_rows
  ) into v_result;

  return v_result;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- provider_summary: per-provider usage (today / 7-day / 30-day) for the
-- authenticated user.
-- v1.10.6: emits `estimated_cost_today`, `estimated_cost` (= week_cost)
-- AND `estimated_cost_30_day` so iOS/Watch/Android can show actual 30-day
-- cost without extrapolating from 7 days. Sources all windows from
-- `daily_usage_metrics`.
-- v0.42 (2026-05-08): added p_user_today parameter — same fix as
-- dashboard_summary. All windows (today / 7-day / 30-day) key off the
-- client-supplied local date when present.
create or replace function public.provider_summary(
  p_user_today date default null
)
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := coalesce(p_user_today, current_date);
  -- Rolling-7-day window = today + previous 6 days inclusive (= 7 calendar days).
  -- Same convention as Swift `DateRange.rollingWeekStart`.
  v_week_start date := v_today - interval '6 days';
  -- Rolling-30-day window = today + previous 29 days inclusive.
  v_month_start date := v_today - interval '29 days';
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return (
    with usage_agg as (
      select
        provider,
        -- Codex P2 (PR #41 review, 2026-05-08): clamp upper bound to
        -- v_today so multi-timezone users can't sum future-dated metrics
        -- written by a device ahead of the querying client's local day.
        -- See migrate_v0.42_user_tz_today.sql for the full rationale.
        sum(case when metric_date = v_today
              then coalesce(input_tokens,0) + coalesce(cached_tokens,0) + coalesce(output_tokens,0)
              else 0 end) as today_usage,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then coalesce(input_tokens,0) + coalesce(cached_tokens,0) + coalesce(output_tokens,0)
              else 0 end) as total_usage,
        sum(case when metric_date = v_today then cost else 0 end) as today_cost,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then cost else 0 end) as week_cost,
        sum(case when metric_date <= v_today then cost else 0 end) as month_cost
      from public.daily_usage_metrics
      where user_id = v_user_id
        and metric_date >= v_month_start
        and metric_date <= v_today
      group by provider
    ),
    quota_agg as (
      -- v0.43 (2026-05-04): added `updated_at` so cli-pulse-desktop can
      -- render a "stale" badge when cached server data is older than ~6 min.
      select provider, remaining, quota, plan_type, reset_time, tiers, updated_at
      from public.provider_quotas
      where user_id = v_user_id
    )
    select coalesce(jsonb_agg(row_data order by sort_key desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'provider', coalesce(u.provider, q.provider),
        'today_usage', coalesce(u.today_usage, 0),
        'total_usage', coalesce(u.total_usage, 0),
        'estimated_cost', coalesce(u.week_cost, 0),
        'estimated_cost_today', coalesce(u.today_cost, 0),
        'estimated_cost_30_day', coalesce(u.month_cost, 0),
        'remaining', q.remaining,
        'quota', q.quota,
        'plan_type', q.plan_type,
        'reset_time', q.reset_time,
        'tiers', coalesce(q.tiers, '[]'::jsonb),
        'updated_at', q.updated_at
      ) as row_data,
      coalesce(u.total_usage, 0) as sort_key
      from usage_agg u
      full outer join quota_agg q on q.provider = u.provider
    ) sub
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- v0.70: maintain the single provider-level compatibility row from the
-- account-scoped source of truth. This shared routine is used after both
-- account upserts and deletes so old clients never retain a stale account.
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

-- v0.70: shared account-quota writer. Client wrappers supply the trusted
-- owner from auth.uid() or helper device authentication.
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

-- get_user_tier: returns the user's subscription tier
--
-- v0.35 (2026-05-01): rank-safe precedence so an `pro` promo
-- redemption never downgrades an `team` admin grant on
-- profiles.tier. See migrate_v0.35_promo_redemptions.sql for the
-- canonical definition — keep this body in sync.
--
-- Precedence:
--   1. active paid subscription with tier != 'free' wins outright
--   2. otherwise return the highest of:
--        - active promo (granted_until > now())
--        - profiles.tier  (legacy admin override)
--        - 'free'
--      under rank: team > pro > free
create or replace function public.get_user_tier()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_paid_tier text;
  v_promo_tier text;
  v_profile_tier text;
  v_tier text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select s.tier into v_paid_tier
  from public.subscriptions s
  where s.user_id = v_user_id
    and s.status = 'active'
    and s.tier != 'free'
    and (s.current_period_end is null or s.current_period_end > now())
  limit 1;

  if v_paid_tier is not null then
    return jsonb_build_object('tier', v_paid_tier);
  end if;

  select tier_granted into v_promo_tier
  from public.promo_redemptions
  where user_id = v_user_id and granted_until > now()
  order by granted_until desc
  limit 1;

  select p.tier into v_profile_tier
  from public.profiles p where p.id = v_user_id;

  v_tier := case
    when v_promo_tier = 'team' or v_profile_tier = 'team' then 'team'
    when v_promo_tier = 'pro'  or v_profile_tier = 'pro'  then 'pro'
    else 'free'
  end;

  return jsonb_build_object('tier', v_tier);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- delete_user_account: cascading delete of all user data
create or replace function public.delete_user_account()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  delete from public.usage_snapshots where user_id = v_user_id;
  delete from public.alerts where user_id = v_user_id;
  delete from public.sessions where user_id = v_user_id;
  delete from public.devices where user_id = v_user_id;
  delete from public.provider_quotas where user_id = v_user_id;
  delete from public.pairing_codes where user_id = v_user_id;
  -- Transfer team ownership or delete orphaned teams
  declare
    v_team record;
    v_new_owner uuid;
  begin
    for v_team in select id from public.teams where owner_id = v_user_id loop
      -- Find next admin, then any member to promote
      select tm.user_id into v_new_owner
      from public.team_members tm
      where tm.team_id = v_team.id and tm.user_id != v_user_id
      order by case when tm.role = 'admin' then 0 else 1 end, tm.joined_at asc
      limit 1;

      if v_new_owner is not null then
        update public.teams set owner_id = v_new_owner where id = v_team.id;
        update public.team_members set role = 'owner'
          where team_id = v_team.id and user_id = v_new_owner;
      else
        delete from public.team_invites where team_id = v_team.id;
        delete from public.teams where id = v_team.id;
      end if;
    end loop;
  end;
  delete from public.team_members where user_id = v_user_id;
  delete from public.subscriptions where user_id = v_user_id;
  delete from public.user_settings where user_id = v_user_id;
  delete from public.profiles where id = v_user_id;

  -- Delete from auth.users to comply with GDPR right to erasure
  delete from auth.users where id = v_user_id;

  return jsonb_build_object('status', 'deleted');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- cleanup_expired_data: delete sessions/alerts/snapshots older than retention period
-- Restricted to service_role only (pg_cron or admin). Not callable by regular users.
create or replace function public.cleanup_expired_data()
returns jsonb as $$
declare
  v_user record;
  v_total_sessions integer := 0;
  v_total_alerts integer := 0;
  v_total_snapshots integer := 0;
  v_deleted integer;
begin
  -- Only allow service_role (pg_cron, admin dashboard) — block regular users
  if current_setting('request.jwt.claims', true)::jsonb ->> 'role' != 'service_role' then
    raise exception 'Forbidden: service_role required';
  end if;

  for v_user in
    select us.user_id, us.data_retention_days
    from public.user_settings us
    where us.data_retention_days > 0
  loop
    -- Wrap per-user cleanup in a savepoint so one user's failure
    -- does not abort cleanup for all remaining users.
    begin
      -- Clean sessions
      delete from public.sessions
      where user_id = v_user.user_id
        and status = 'Ended'
        and last_active_at < now() - (v_user.data_retention_days || ' days')::interval;
      get diagnostics v_deleted = row_count;
      v_total_sessions := v_total_sessions + v_deleted;

      -- Clean resolved alerts
      delete from public.alerts
      where user_id = v_user.user_id
        and is_resolved = true
        and created_at < now() - (v_user.data_retention_days || ' days')::interval;
      get diagnostics v_deleted = row_count;
      v_total_alerts := v_total_alerts + v_deleted;

      -- Clean usage snapshots
      delete from public.usage_snapshots
      where user_id = v_user.user_id
        and recorded_at < now() - (v_user.data_retention_days || ' days')::interval;
      get diagnostics v_deleted = row_count;
      v_total_snapshots := v_total_snapshots + v_deleted;

      -- Clean stale provider quotas (not updated in retention period)
      delete from public.provider_quotas
      where user_id = v_user.user_id
        and updated_at < now() - (v_user.data_retention_days || ' days')::interval;
    exception when others then
      raise notice 'cleanup_expired_data: failed for user %, skipping: %', v_user.user_id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object(
    'sessions_deleted', v_total_sessions,
    'alerts_deleted', v_total_alerts,
    'snapshots_deleted', v_total_snapshots
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- evaluate_budget_alerts: check project costs against budget thresholds
-- Creates alerts for projects exceeding budget, with suppression to prevent spam.
create or replace function public.evaluate_budget_alerts()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_threshold numeric;
  v_cooldown integer;
  -- Rolling-7-day window = today + previous 6 days inclusive.
  v_week_start date := current_date - interval '6 days';
  v_project record;
  v_alert_count integer := 0;
  v_suppression_key text;
  v_week_label text := to_char(current_date, 'IYYY-IW');
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- Load user thresholds
  select us.project_budget_threshold_usd, us.alert_cooldown_minutes
  into v_threshold, v_cooldown
  from public.user_settings us
  where us.user_id = v_user_id;

  if v_threshold is null or v_threshold <= 0 then
    return jsonb_build_object('alerts_created', 0);
  end if;

  -- Check per-project weekly cost against threshold
  for v_project in
    select
      s.project,
      coalesce(sum(s.estimated_cost), 0) as week_cost,
      max(s.provider) as top_provider
    from public.sessions s
    where s.user_id = v_user_id
      and s.last_active_at >= v_week_start
      and s.project != ''
    group by s.project
    having coalesce(sum(s.estimated_cost), 0) > v_threshold
    order by week_cost desc
    limit 200
  loop
    v_suppression_key := 'budget:' || v_user_id || ':' || v_project.project || ':' || v_week_label;

    -- Skip if already alerted this week (strict existence — no cooldown for budget alerts)
    if not exists (
      select 1 from public.alerts
      where user_id = v_user_id and suppression_key = v_suppression_key
    ) then
      insert into public.alerts (id, user_id, type, severity, title, message,
        related_project_name, related_provider, suppression_key, grouping_key)
      values (
        gen_random_uuid()::text, v_user_id,
        'Project Budget Exceeded', 'Warning',
        'Budget exceeded: ' || v_project.project,
        'Project "' || v_project.project || '" has accumulated $' ||
          round(v_project.week_cost::numeric, 2) || ' this week (threshold: $' ||
          round(v_threshold::numeric, 2) || ')',
        v_project.project, v_project.top_provider,
        v_suppression_key, 'budget:' || v_project.project
      );
      v_alert_count := v_alert_count + 1;
    end if;
  end loop;

  -- Cost spike detection: today's total cost > 2x yesterday's
  declare
    v_today_cost numeric;
    v_yesterday_cost numeric;
    v_spike_key text := 'costspike:' || v_user_id || ':' || current_date;
  begin
    select coalesce(sum(estimated_cost), 0) into v_today_cost
    from public.sessions
    where user_id = v_user_id
      and last_active_at >= current_date and last_active_at < current_date + interval '1 day';

    select coalesce(sum(estimated_cost), 0) into v_yesterday_cost
    from public.sessions
    where user_id = v_user_id
      and last_active_at >= current_date - interval '1 day'
      and last_active_at < current_date;

    -- Require minimum $1 yesterday to avoid trivial false positives
    if v_yesterday_cost >= 1.0 and v_today_cost > v_yesterday_cost * 2 then
      if not exists (
        select 1 from public.alerts
        where user_id = v_user_id and suppression_key = v_spike_key
      ) then
        insert into public.alerts (id, user_id, type, severity, title, message,
          suppression_key, grouping_key)
        values (
          gen_random_uuid()::text, v_user_id,
          'Cost Spike', 'Warning',
          'Unusual cost spike detected',
          'Today''s cost ($' || round(v_today_cost::numeric, 2) ||
            ') is more than 2x yesterday ($' || round(v_yesterday_cost::numeric, 2) || ')',
          v_spike_key, 'costspike:daily'
        );
        v_alert_count := v_alert_count + 1;
      end if;
    end if;
  end;

  return jsonb_build_object('alerts_created', v_alert_count);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ============================================================
-- Team Management RPCs
-- ============================================================

-- create_team: create a new team with the caller as owner
create or replace function public.create_team(p_name text)
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_team_id uuid;
  v_tier text;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;

  if trim(p_name) = '' then raise exception 'Team name cannot be empty'; end if;

  -- Require Pro or Team subscription
  select coalesce(
    (select s.tier from public.subscriptions s
     where s.user_id = v_user_id and s.status = 'active' and s.tier != 'free'),
    (select p.tier from public.profiles p where p.id = v_user_id),
    'free'
  ) into v_tier;
  if v_tier = 'free' then raise exception 'Team features require Pro or Team subscription'; end if;

  insert into public.teams (name, owner_id) values (left(p_name, 100), v_user_id)
  returning id into v_team_id;

  insert into public.team_members (team_id, user_id, role) values (v_team_id, v_user_id, 'owner');

  return jsonb_build_object('team_id', v_team_id, 'name', p_name);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- team_details: return team info + members + invites
create or replace function public.team_details(p_team_id uuid)
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_team jsonb;
  v_members jsonb;
  v_invites jsonb;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;

  -- Verify caller is a member
  if not exists (select 1 from public.team_members where team_id = p_team_id and user_id = v_user_id) then
    raise exception 'Not a member of this team';
  end if;

  select jsonb_build_object('id', t.id, 'name', t.name, 'owner_id', t.owner_id, 'created_at', t.created_at)
  into v_team from public.teams t where t.id = p_team_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', tm.user_id, 'name', p.name, 'email', p.email,
    'role', tm.role, 'joined_at', tm.joined_at
  )), '[]'::jsonb)
  into v_members
  from public.team_members tm
  join public.profiles p on p.id = tm.user_id
  where tm.team_id = p_team_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', ti.id, 'email', ti.email, 'role', ti.role,
    'created_at', ti.created_at, 'expires_at', ti.expires_at
  )), '[]'::jsonb)
  into v_invites
  from public.team_invites ti
  where ti.team_id = p_team_id and ti.expires_at > now();

  return jsonb_build_object('team', v_team, 'members', v_members, 'invites', v_invites);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- invite_member: send an invite to a team
create or replace function public.invite_member(p_team_id uuid, p_email text, p_role text default 'member')
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_invite_id uuid;
  v_member_count integer;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;

  -- Verify caller is owner or admin
  if not exists (
    select 1 from public.team_members
    where team_id = p_team_id and user_id = v_user_id and role in ('owner', 'admin')
  ) then raise exception 'Only owners and admins can invite members'; end if;

  -- Enforce role constraint: can only invite as 'member'
  if p_role not in ('member') then raise exception 'Can only invite as member role'; end if;

  -- Check for existing invite
  if exists (
    select 1 from public.team_invites
    where team_id = p_team_id and email = p_email and expires_at > now()
  ) then raise exception 'Invite already pending for this email'; end if;

  insert into public.team_invites (team_id, email, role)
  values (p_team_id, left(p_email, 255), p_role)
  returning id into v_invite_id;

  return jsonb_build_object('invite_id', v_invite_id, 'email', p_email);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- accept_invite: join a team via invite
create or replace function public.accept_invite(p_invite_id uuid)
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_user_email text;
  v_invite record;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;

  select email into v_user_email from public.profiles where id = v_user_id;

  select * into v_invite from public.team_invites
  where id = p_invite_id and expires_at > now();

  if v_invite is null then raise exception 'Invite not found or expired'; end if;

  -- Verify email matches
  if v_user_email != v_invite.email then
    raise exception 'This invite was sent to a different email address';
  end if;

  -- Already a member?
  if exists (select 1 from public.team_members where team_id = v_invite.team_id and user_id = v_user_id) then
    delete from public.team_invites where id = p_invite_id;
    raise exception 'Already a member of this team';
  end if;

  insert into public.team_members (team_id, user_id, role)
  values (v_invite.team_id, v_user_id, v_invite.role);

  delete from public.team_invites where id = p_invite_id;

  return jsonb_build_object('team_id', v_invite.team_id, 'role', v_invite.role);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- remove_member: remove a member from a team
create or replace function public.remove_member(p_team_id uuid, p_user_id uuid)
returns jsonb as $$
declare
  v_caller_id uuid := auth.uid();
  v_caller_role text;
begin
  if v_caller_id is null then raise exception 'Not authenticated'; end if;

  select role into v_caller_role from public.team_members
  where team_id = p_team_id and user_id = v_caller_id;

  if v_caller_role is null or v_caller_role not in ('owner', 'admin') then
    raise exception 'Only owners and admins can remove members';
  end if;

  -- Cannot remove the owner
  if exists (select 1 from public.teams where id = p_team_id and owner_id = p_user_id) then
    raise exception 'Cannot remove the team owner';
  end if;

  -- Admins can only remove members, not other admins (owner can remove anyone)
  if v_caller_role = 'admin' then
    if exists (select 1 from public.team_members where team_id = p_team_id and user_id = p_user_id and role = 'admin') then
      raise exception 'Only the owner can remove admins';
    end if;
  end if;

  delete from public.team_members where team_id = p_team_id and user_id = p_user_id;

  return jsonb_build_object('removed', p_user_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- update_member_role: change a member's role (owner only)
create or replace function public.update_member_role(p_team_id uuid, p_user_id uuid, p_role text)
returns jsonb as $$
declare
  v_caller_id uuid := auth.uid();
begin
  if v_caller_id is null then raise exception 'Not authenticated'; end if;

  -- Only team owner can change roles
  if not exists (select 1 from public.teams where id = p_team_id and owner_id = v_caller_id) then
    raise exception 'Only the team owner can change roles';
  end if;

  if p_role not in ('admin', 'member') then raise exception 'Invalid role'; end if;

  update public.team_members set role = p_role
  where team_id = p_team_id and user_id = p_user_id and user_id != v_caller_id;

  return jsonb_build_object('user_id', p_user_id, 'role', p_role);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- team_usage_summary: aggregated usage for a team
create or replace function public.team_usage_summary(p_team_id uuid)
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  -- Rolling-7-day window = today + previous 6 days inclusive.
  v_week_start date := current_date - interval '6 days';
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;

  if not exists (select 1 from public.team_members where team_id = p_team_id and user_id = v_user_id) then
    raise exception 'Not a member of this team';
  end if;

  return (
    select jsonb_build_object(
      'team_id', p_team_id,
      'member_count', (select count(*) from public.team_members where team_id = p_team_id),
      'total_usage', coalesce(sum(s.total_usage), 0),
      'total_cost', coalesce(sum(s.estimated_cost), 0),
      'provider_breakdown', coalesce((
        select jsonb_agg(jsonb_build_object(
          'provider', sub.provider, 'usage', sub.usage, 'cost', sub.cost
        ))
        from (
          select s2.provider, sum(s2.total_usage) as usage, sum(s2.estimated_cost) as cost
          from public.sessions s2
          where s2.user_id in (select tm.user_id from public.team_members tm where tm.team_id = p_team_id)
            and s2.last_active_at >= v_week_start
          group by s2.provider order by sum(s2.total_usage) desc
        ) sub
      ), '[]'::jsonb)
    )
    from public.sessions s
    where s.user_id in (select tm.user_id from public.team_members tm where tm.team_id = p_team_id)
      and s.last_active_at >= v_week_start
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Grant hygiene (audit F13): Supabase grants EXECUTE to anon at CREATE time, so
-- SECURITY DEFINER RPCs meant only for signed-in users must explicitly revoke
-- anon (same convention as migrate_v0.53 / v0.59.1). These 7 team RPCs already
-- reject anon internally (`if v_user_id is null then raise 'Not authenticated'`),
-- so this is defense-in-depth + clears the `anon_security_definer_function`
-- advisor for a fresh restore. (Not applied as a prod migration: these functions
-- are not currently deployed to the live DB — the team feature is unshipped.)
revoke execute on function public.create_team(text) from public, anon;
revoke execute on function public.team_details(uuid) from public, anon;
revoke execute on function public.invite_member(uuid, text, text) from public, anon;
revoke execute on function public.accept_invite(uuid) from public, anon;
revoke execute on function public.remove_member(uuid, uuid) from public, anon;
revoke execute on function public.update_member_role(uuid, uuid, text) from public, anon;
revoke execute on function public.team_usage_summary(uuid) from public, anon;
grant execute on function public.create_team(text), public.team_details(uuid),
  public.invite_member(uuid, text, text), public.accept_invite(uuid),
  public.remove_member(uuid, uuid), public.update_member_role(uuid, uuid, text),
  public.team_usage_summary(uuid) to authenticated;

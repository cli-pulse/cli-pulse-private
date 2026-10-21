-- ============================================================
-- rollback for v0.86 (migrate_v0.86_summary_tokens_each_once.sql)
--
-- Puts back the three summary functions as production ran them before
-- v0.86: dashboard_summary and provider_summary from v0.44, and
-- provider_account_summary from v0.72, byte for byte (the bodies below are
-- copied from those files; CI checks that each function's body after this
-- file equals the one those files install). Their tokens are then
-- input + cached + output again, which counts Codex's cached input twice.
--
-- Use it only when v0.86's APPLY step 0 found these bodies (its body_md5
-- values were the three it lists); otherwise apply the definitions saved in
-- that step. Same signatures and
-- return type, so `create or replace` keeps every grant. Changes no row.
-- ============================================================

begin;

set local lock_timeout = '30s';

create or replace function public.dashboard_summary(
  p_user_today date default null
)
returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  -- Use the client-supplied local date when present; otherwise fall back
  -- to server `current_date` (UTC) so legacy clients keep the prior
  -- behavior until they update.
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
$$;

create or replace function public.provider_summary(
  p_user_today date default null
)
returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := coalesce(p_user_today, current_date);
  -- Rolling-7-day window = today + previous 6 days inclusive (= 7 days).
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
        -- Codex P2 (PR #41 review, 2026-05-08): clamp the upper bound to
        -- v_today so a multi-timezone user (Mac in CN UTC+8 + iPhone
        -- queried from US Pacific, say) cannot have the iPhone's 7-day
        -- and 30-day totals include CN-tomorrow rows the Mac already
        -- wrote. Pre-v0.42 the boundary was the server's `current_date`,
        -- which always trailed any local-TZ writer; with `p_user_today`
        -- the upper edge is now client-controlled, so the explicit
        -- `metric_date <= v_today` clamp restores the implicit guarantee.
        -- The `today_usage` and `today_cost` cases already use equality,
        -- so they do not need the clamp.
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
      -- v0.43 (2026-05-04): added updated_at projection so cli-pulse-desktop
      -- can render a "stale" badge when cached server data is older than
      -- ~6 minutes. Preserved here in v0.44.
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
$$;

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

commit;

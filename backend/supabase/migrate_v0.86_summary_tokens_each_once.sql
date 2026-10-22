-- ============================================================
-- v0.86 — dashboard_summary / provider_summary / provider_account_summary
--         count each token once
-- Date: 2026-10-20
-- Written for 1.58 and NOT applied by the PR that adds it. Applying it to
-- production is the owner's decision (APPLY below).
--
-- ── WHY ───────────────────────────────────────────────────────
-- `daily_usage_metrics` keeps each row as its writer sent it. For Codex the
-- writers (the Mac app's log scan, and the Windows/Linux desktop app's) send
-- OpenAI's convention: `input_tokens` already includes `cached_tokens`. For
-- Claude, `input_tokens` leaves cache out and `cached_tokens` holds the cache
-- reads and the cache writes.
--
-- The three summary RPCs added `input + cached + output` for every provider,
-- so every Codex figure they return counted Codex's cached input twice. Cached
-- input is most of a Codex user's input, so Codex's Today and 7-day tokens
-- wherever the apps show these figures (WHAT THE APPS SHOW, below) read close
-- to twice what was used. The Mac stopped doing the same in its usage history in 1.55
-- (`ArchiveTokenBasis`, "each token once"), and the iPhone's usage dashboard
-- counts the same rows that way, so on one account the Overview's Usage Today
-- and the usage dashboard's today disagreed for every Codex user.
--
-- ── THE RULE, EXACTLY ─────────────────────────────────────────
-- Per row of `daily_usage_metrics`, the Mac's `ArchiveTokenBasis.tokens`
-- (CLIPulseCore, DailyUsageArchive.swift), each token once:
--   provider = 'Codex'   greatest(input, 0) + greatest(output, 0)
--                        Cached input is part of input. The Mac clamps it to
--                        [0, input] and adds `input - cached` and `cached`,
--                        which is `input`; so cached adds nothing here, and
--                        a row whose cached exceeds its input (the writers
--                        clamp it; a row that did not would add tokens nobody
--                        used) still counts its input once.
--   any other provider   greatest(input, 0) + greatest(cached, 0)
--                        + greatest(output, 0)
--                        Claude: input + cache reads + cache writes + output.
-- NULL counts as 0, as before. The provider name is compared exactly, as the
-- app compares `ProviderKind.codex.rawValue`; every writer sends "Codex".
-- Rows are summed after the rule, so each row is clamped on its own, as the
-- Mac adds rows up.
-- `backend/supabase/tests/fixtures/summary_tokens_each_once.json` holds rows
-- and the figures this rule gives them; the Mac's code is asserted against the
-- same file (`SummaryTokensEachOnceFixtureTests`) and these functions in CI
-- (`run_v086_summary_tokens_each_once_tests.sh`).
--
-- So Codex's figures drop to input + output; Claude's and every other
-- provider's do not move, except where a row holds a negative count: no
-- column has a check against one, and such a count now adds 0 instead of
-- taking tokens away, as on the Mac (step 0 counts those rows; expect none).
-- Costs never counted tokens and do not move either.
--
-- ── WHAT THE APPS SHOW ────────────────────────────────────────
-- These figures reach the apps as bare token counts. No label in any app
-- names a basis ("Usage Today", "Usage", "Today · N tokens", "N tokens",
-- "Today's Usage"), and nothing in the answer says which rule the server
-- runs, so no label becomes false and none is added here. Where they show:
--   * iPhone / iPad Overview: the Usage Today tile (dashboard_summary) and
--     the Provider Usage rows (provider_summary / provider_account_summary
--     today_usage); the Apple Watch's Pulse, rings and provider detail
--     (Today, This Week); the widgets, Siri's status and the PDF / CSV export
--     where they carry the iPhone's figure;
--   * the iPhone / iPad provider card's Today and This Week, only for a
--     provider with no daily rows in the 30 days (with rows the card counts
--     the rows' "I/O" and does not move);
--   * the Mac's Overview Usage Today and the widgets' Usage figure only when
--     the Mac has no log scan, or its provider cards count no tokens today
--     (otherwise they are the cards' I/O);
--   * on a signed-in Mac, the Overview's Provider Usage rows (a bare number
--     beside the cost) and the single-provider widget (a bare number, "used"
--     after it when the provider has a quota): both read the providers'
--     today_usage, which there is provider_account_summary's
--     (provider_summary's on the fallback), unless that provider's collector
--     on the Mac reports a non-zero figure of its own, which replaces it
--     (Codex's reports the used percent of its headline window);
--   * Android's Overview, Providers list, provider detail and export.
-- After this, a Codex figure equals the iPhone card's I/O for the same rows
-- (Codex's input holds its cached input). A Claude figure still counts its
-- cache reads and writes, each once, so it stays above the card's I/O by
-- design: the card labels I/O, these count every token.
--
-- ── WHAT DOES NOT CHANGE (apps up to 1.57 keep working) ───────
--   * the three signatures: one overload each, `(p_user_today date default
--     null)`, returning jsonb. `create or replace` with the same arguments
--     and return type, so no second overload, and the grants, owner,
--     SECURITY DEFINER and pinned search_path carry over (nothing here
--     re-grants: production keeps exactly the grants it has);
--   * every key of every answer, and its type (`today_usage` and
--     `total_usage` stay token counts, summed over the same rows);
--   * the windows (today; today and the 6 days before; today and the 29
--     before; nothing after the client's today), the costs, the quota and
--     account fields, the dashboard's session, device and alert counts.
-- What changes: `today_usage` / `total_usage` of a provider with Codex rows,
-- `dashboard_summary.today_usage` of an account with Codex rows today (and
-- of any provider with a row holding a negative count), and, because both
-- lists are sorted by the 7-day tokens, where Codex sits in the order of
-- provider_summary's and provider_account_summary's rows.
-- No row of any table is written.
--
-- ── HOW ───────────────────────────────────────────────────────
-- Each body starts from the logic production runs, in the files' text:
-- v0.44's for dashboard_summary and provider_summary (comment lines
-- included; production runs them without, see APPLY step 0) and v0.72's for
-- provider_account_summary. Each adds the token sum computed once per row by
-- the rule, in a `metric_rows` step, and the comment
-- `-- v0.86 each token once` inside it for the checks below.
-- The canonical fresh-install definitions in app_rpc.sql are the same text
-- (ci_check_rpc_contract.py's mirror check holds them together).
--
-- ── APPLY (owner) ─────────────────────────────────────────────
-- 0. Preflight, read-only. Run this and keep its answer (step 2 compares
--    with it):
--
--      select p.proname, pg_get_function_identity_arguments(p.oid) as args,
--             p.prosecdef, p.prosrc like '%v0.86 each token once%' as rule,
--             md5(p.prosrc) as body_md5,
--             has_function_privilege('anon', p.oid, 'EXECUTE') as anon,
--             has_function_privilege('authenticated', p.oid, 'EXECUTE')
--               as authenticated
--        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public'
--         and p.proname in ('dashboard_summary', 'provider_summary',
--                           'provider_account_summary')
--       order by 1;
--
--    Expect three rows, each args `p_user_today date`, prosecdef = true,
--    rule = false (v0.44 / v0.72 in place, this not yet), anon = false and
--    authenticated = true (v0.44's and v0.72's grants), and body_md5 exactly
--    the bodies production runs, as measured there on 2026-10-22 (CI computes
--    these from the files and fails when they go stale):
--
--      v0.44  dashboard_summary         afd6f78d41dc740cda0880183324447f
--      v0.72  provider_account_summary  9ee3b5ed4ea4d9471fec611686d4020e
--      v0.44  provider_summary          6854ffde714ea2709e855463b6190bdf
--
--    The two v0.44 values are not the file's own: production runs
--    migrate_v0.44's bodies without their whole-line `--` comments (3 lines
--    in dashboard_summary, 15 in provider_summary) and otherwise byte for
--    byte the same, so the logic is identical.
--
--    If any body_md5 differs, STOP. Production runs a body this repo does not
--    have, and v0.86 replaces whole bodies, so that difference would be lost
--    without anyone seeing it; rollback_v0.86.sql would not bring it back
--    either. Diff the definitions saved below against migrate_v0.44 /
--    migrate_v0.72 and decide before going on; if you go on, roll back only
--    from the saved definitions. If anon or authenticated differs from the
--    expected values, v0.86 keeps production's grants as they are; step 2
--    expects exactly step 0's values again.
--
--    Save the current definitions (the exact rollback source):
--      select pg_get_functiondef(p.oid) from pg_proc p
--       join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public'
--         and p.proname in ('dashboard_summary', 'provider_summary',
--                           'provider_account_summary');
--
--    The writers' provider names (expect "Codex", no other spelling of it):
--      select provider, count(*) from public.daily_usage_metrics
--       where lower(provider) like '%codex%' group by 1;
--
--    What the change does to Codex's figures, over the last 30 days, totals
--    only (before, after):
--      select sum(greatest(input_tokens, 0) + greatest(cached_tokens, 0)
--                 + greatest(output_tokens, 0)) as before_tokens,
--             sum(greatest(input_tokens, 0) + greatest(output_tokens, 0))
--               as after_tokens,
--             count(*) filter (where cached_tokens > input_tokens)
--               as rows_cached_over_input
--        from public.daily_usage_metrics
--       where provider = 'Codex' and metric_date >= current_date - 29;
--
--    Rows whose figure the clamp at 0 would change, any provider (expect 0;
--    a count above 0 means those providers' figures move too):
--      select count(*) as rows_with_a_negative_count
--        from public.daily_usage_metrics
--       where input_tokens < 0 or cached_tokens < 0 or output_tokens < 0;
--
-- 1. Apply this file as it stands, with the Supabase MCP's `apply_migration`
--    under the name `v0_86_summary_tokens_each_once`: that also writes its
--    row in `supabase_migrations.schema_migrations`. Any other route
--    (`supabase db query --file`, the SQL editor) runs the SQL without
--    writing that row, which is how the ledger lost v0.72's; record the row
--    by hand then. If apply_migration times out, run step 2 before trying
--    again: it may have gone through. The ledger row is not the proof; step
--    2's checks are. The file carries its own begin/commit, refuses to run
--    without the three functions, and changes no row.
--
--    "As it stands" means byte for byte, comments included: send the whole
--    file, never a cleaned-up copy. The marker `-- v0.86 each token once`
--    that the file's last check and step 2 look for is a comment on its own
--    line inside each body, and step 0's v0.44 difference came from such a
--    copy (the ledger's v0_44 row holds no `--` at all), while
--    apply_migration itself keeps comments (production's replace_daily_usage
--    body is migrate_v0.85's, comment lines included). A copy without the
--    marker fails safe, since the last check raises "v0.86 did not replace"
--    and nothing commits, but it stops the apply. Before sending, record in
--    the apply log the md5 of the text about to be sent next to the md5 of
--    this file; if they differ, find out why before applying.
--
-- 2. Post-apply, read-only: step 0's query again gives three rows with
--    rule = true, the same args and prosecdef, anon and authenticated exactly
--    as step 0 recorded them (v0.86 grants and revokes nothing), and
--    body_md5 exactly v0.86's bodies (CI checks these too):
--
--      v0.86  dashboard_summary         293d69f4f49ce4be45d96df8a0f6b388
--      v0.86  provider_account_summary  5b3a9271536ba43d45e41c725b7c643b
--      v0.86  provider_summary          b6c0a8723dbeffda85e3783d5d8091ea
--
--    Three rows means one overload of each, as before.
--
--    Then open the iPhone app signed in to an account with Codex usage today:
--    the Overview's Usage Today equals the Activity heatmap's today, and the
--    Overview's Codex row equals the Codex card's Today (I/O).
--
-- ROLLBACK: apply the definitions saved in step 0. When step 0's body_md5
-- values were the three listed there, applying `rollback_v0.86.sql` gives
-- the same logic: it puts back v0.44's and v0.72's bodies as the files have
-- them, whole-line comments included, so dashboard_summary's and
-- provider_summary's md5 then differ from step 0's by those lines only. CI
-- applies it after this file and checks both: the bodies are the files',
-- and without their whole-line comments they are step 0's. Otherwise use
-- only the saved definitions. Nothing to restore in any table.
-- ============================================================

begin;

set local lock_timeout = '30s';

-- The three functions must be in place with the signatures this replaces:
-- `create or replace` of a missing one would add an RPC (and
-- provider_account_summary without v0.72's tables would fail on every call
-- instead of answering 404, which the apps take as "not deployed yet").
do $$
begin
  if to_regprocedure('public.dashboard_summary(date)') is null
     or to_regprocedure('public.provider_summary(date)') is null then
    raise exception 'dashboard_summary(date) / provider_summary(date) missing — apply v0.44 first; stop';
  end if;
  if to_regprocedure('public.provider_account_summary(date)') is null
     or to_regclass('public.provider_accounts') is null then
    raise exception 'provider_account_summary(date) missing — apply v0.72 first; stop';
  end if;
end $$;

-- dashboard_summary: returns overview stats for the authenticated user.
-- v1.10.5+: sources today_usage/today_cost from daily_usage_metrics
-- (populated by CostUsageScanner via JSONL bookmarks, unaffected by the
-- MAS sandbox gap that made `sessions` unreliable).
-- v0.42 (2026-05-08): added p_user_today parameter so the "today" boundary
-- aligns with the user's local timezone instead of the server's UTC clock.
-- Old callers without the param keep prior behavior via the NULL default.
-- See migrate_v0.42_user_tz_today.sql for the bug write-up.
-- v0.86: today_usage counts each token once (migrate_v0.86 header): Codex's
-- input already includes its cached input.
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
    -- v0.86 each token once: Codex's input already includes its cached
    -- input; every other provider's leaves cache out. Same rule as the Mac's
    -- ArchiveTokenBasis.tokens, row by row.
    coalesce(sum(
      case when provider = 'Codex'
           then greatest(coalesce(input_tokens, 0), 0)
              + greatest(coalesce(output_tokens, 0), 0)
           else greatest(coalesce(input_tokens, 0), 0)
              + greatest(coalesce(cached_tokens, 0), 0)
              + greatest(coalesce(output_tokens, 0), 0)
      end
    ), 0),
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
-- v0.86: today_usage / total_usage count each token once (migrate_v0.86
-- header): Codex's input already includes its cached input.
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
    with metric_rows as (
      select
        provider,
        metric_date,
        cost,
        -- v0.86 each token once: Codex's input already includes its cached
        -- input; every other provider's leaves cache out. Same rule as the
        -- Mac's ArchiveTokenBasis.tokens, row by row.
        case when provider = 'Codex'
             then greatest(coalesce(input_tokens, 0), 0)
                + greatest(coalesce(output_tokens, 0), 0)
             else greatest(coalesce(input_tokens, 0), 0)
                + greatest(coalesce(cached_tokens, 0), 0)
                + greatest(coalesce(output_tokens, 0), 0)
        end as tokens
      from public.daily_usage_metrics
      where user_id = v_user_id
        -- Codex P2 (PR #41 review, 2026-05-08): clamp upper bound to
        -- v_today so multi-timezone users can't sum future-dated metrics
        -- written by a device ahead of the querying client's local day.
        -- See migrate_v0.42_user_tz_today.sql for the full rationale.
        and metric_date >= v_month_start
        and metric_date <= v_today
    ),
    usage_agg as (
      select
        provider,
        sum(case when metric_date = v_today then tokens else 0 end) as today_usage,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then tokens else 0 end) as total_usage,
        sum(case when metric_date = v_today then cost else 0 end) as today_cost,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then cost else 0 end) as week_cost,
        sum(case when metric_date <= v_today then cost else 0 end) as month_cost
      from metric_rows
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

-- Provider-level usage/cost is computed once, while quota accounts remain a
-- nested array. This avoids multiplying token/cost totals by account count.
-- v0.86: today_usage / total_usage count each token once (migrate_v0.86
-- header): Codex's input already includes its cached input.
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
    with metric_rows as (
      select
        provider,
        metric_date,
        cost,
        -- v0.86 each token once: Codex's input already includes its cached
        -- input; every other provider's leaves cache out. Same rule as the
        -- Mac's ArchiveTokenBasis.tokens, row by row.
        case when provider = 'Codex'
             then greatest(coalesce(input_tokens, 0), 0)
                + greatest(coalesce(output_tokens, 0), 0)
             else greatest(coalesce(input_tokens, 0), 0)
                + greatest(coalesce(cached_tokens, 0), 0)
                + greatest(coalesce(output_tokens, 0), 0)
        end as tokens
      from public.daily_usage_metrics
      where user_id = v_user_id
        and metric_date >= v_month_start
        and metric_date <= v_today
    ),
    usage_agg as (
      select
        provider,
        sum(case when metric_date = v_today then tokens else 0 end) as today_usage,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then tokens else 0 end) as total_usage,
        sum(case when metric_date = v_today then cost else 0 end) as today_cost,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then cost else 0 end) as week_cost,
        sum(case when metric_date >= v_month_start and metric_date <= v_today
              then cost else 0 end) as month_cost
      from metric_rows
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

-- The bodies above must be the ones that ran: a failed replace aborts here.
do $$
declare
  v_missing text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_missing
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('dashboard_summary', 'provider_summary', 'provider_account_summary')
     and p.prosrc not like '%v0.86 each token once%';
  if v_missing is not null then
    raise exception 'v0.86 did not replace: %', v_missing;
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('dashboard_summary', 'provider_summary', 'provider_account_summary')) <> 3 then
    raise exception 'v0.86: expected exactly one overload of each summary function';
  end if;
end $$;

commit;

-- ============================================================
-- v0.87 — the nightly retention cleanup deletes again; dashboard_summary
--         counts only fresh sessions and devices
-- Date: 2026-10-26
-- Written for 1.59 and NOT applied by the PR that adds it. Applying it to
-- production is the owner's decision, after reading the dry-run counts
-- (APPLY step 0). Its first nightly run deletes rows for good.
--
-- ── WHY ───────────────────────────────────────────────────────
-- 1. The retention cleanup has never deleted anything in production.
--    pg_cron job `cleanup_expired_data_nightly` (03:07 UTC, v0.21) runs
--    `public._cleanup_expired_data_internal()`, which production still runs as
--    migrate_v0.21 wrote it (APPLY step 0's md5). For every account it deletes
--    from `public.sessions`, `public.alerts` and then `public.device_snapshots`
--    in one block. No `device_snapshots` table exists (none of these files
--    creates one), so the third DELETE fails, and the block's
--    `EXCEPTION WHEN OTHERS ... skipping` rolls back the first two with it,
--    for every account, every night, while cron records the run as
--    succeeded. Its answer does not show it either: the counts are
--    variables, which the rollback leaves as they were, so a call reports as
--    deleted the Ended sessions and the alerts it has just put back (the
--    suite's control shows it). PRIVACY.md's Data retention section says
--    ended sessions and alerts are deleted once older than the account's
--    retention setting (7 days for every account); in production they were
--    not.
--    Measured read-only on 2026-10-26: rows older than their account's
--    retention go back to April; the dry run (APPLY step 0) counts them.
-- 2. dashboard_summary's `active_sessions` counted every row with status
--    'Running', and `online_devices` every device with status 'Online'. A
--    producer that stops (a Mac switched off, a helper that is gone, a Mac
--    whose answer to the local-scan question is "Not now") never ends its
--    rows or marks its device offline, and no SQL ever sets 'Offline'
--    (helper_rpc.sql only writes 'Online'). So the counts never came down:
--    on 2026-10-26 every device in production was 'Online', most of them not
--    seen for over a month, and 'Running' rows last active in August were
--    still counted.
--
-- ── WHAT CHANGES ──────────────────────────────────────────────
-- A. `_cleanup_expired_data_internal()` (what the cron job runs) is
--    rewritten. Same name, no arguments, returns jsonb, SECURITY DEFINER,
--    the same pinned search_path; the cron job and its command are not
--    touched.
--    * One DELETE per table, each in its own BEGIN ... EXCEPTION block, so
--      each has its own savepoint: a table that fails is counted, reported
--      with RAISE WARNING (which reaches the Postgres log, unlike the old
--      NOTICE), and does not undo or stop the others.
--    * sessions: every row whose `last_active_at` is older than its
--      account's `user_settings.data_retention_days`, whatever its status.
--      For 'Ended' rows this is what v0.21 meant to do. A 'Running' row
--      that old belongs to a producer that stopped: a live one rewrites its
--      rows on every sync (true of scan rows, which are every row uploaded
--      today), and no producer syncs less often than every 15 minutes (THE
--      TWO WINDOWS, below), so the zombie rows go now and any later ones go
--      once they are a retention period old. ('Idle', 'Failed' and
--      'Syncing' rows, which the apps' model allows and production has none
--      of, go the same way.)
--    * alerts: every row whose `created_at` is older than its account's
--      retention, resolved or not, as v0.21 wrote it. (app_rpc.sql's
--      resolved-only variant never ran in production; it is replaced below.)
--      Consequence, for the owner to weigh before applying: a resolved CPU
--      alert comes back. The Mac's device-CPU alert keeps one row per
--      device (id `cpu-spike-<device>`, AlertGenerator) so that, once the
--      user resolves it, helper_sync's ON CONFLICT keeps `is_resolved`
--      and later spikes stay quiet. helper_sync refreshes neither
--      `created_at` nor `is_resolved` on that conflict, so the resolved row
--      is deleted a retention period (7 days) after it was first created,
--      and the next spike above 85 % inserts it again, unresolved, and
--      alerts_enqueue_webhook queues a webhook for it (it deduplicates only
--      jobs still pending). Keeping
--      these rows out of the cleanup would make PRIVACY.md's alerts line
--      untrue, so they are not kept; the fix belongs to 1.60 (the helper
--      stops sending ids the user resolved, or the suppression moves to a
--      small table of its own that retention does not prune). The dry-run
--      note counts the rows concerned.
--    * pairing_attempt_log: rows older than an hour, as v0.21 did.
--    * Not deleted: `device_snapshots` (no such table); `usage_snapshots`
--      (production's function never deleted it, nothing writes it, it has
--      no rows); `provider_quotas` (the latest quota per provider, current
--      state rather than history; PRIVACY.md promises nothing for it).
--    * Accounts with `data_retention_days <= 0` keep their sessions and
--      alerts, as before. A retention above 36500 days (100 years) counts as
--      36500: the column has no CHECK, the account's owner can set it
--      through PostgREST (policy "Users can manage own settings"), and
--      `now() - make_interval(days => 2147483647)` raises 22008 "timestamp
--      out of range". Each DELETE covers every account in one statement, so
--      without the cap one such value would stop that table's cleanup for
--      every account, every night (v0.21's per-account loop confined it to
--      that account). The dry run and step 4 below cap it the same way.
--    * It returns
--        { "sessions_deleted": n, "running_sessions_deleted": n,
--          "alerts_deleted": n, "pairing_attempt_log_deleted": n,
--          "errors": n, "failed": ["<table>", ...] }
--      where running_sessions_deleted is the part of sessions_deleted that
--      was still 'Running', and errors counts the tables whose DELETE
--      failed (0 to 3). The old answer's `snapshots_deleted` is gone; nothing
--      reads the answer (cron discards it).
-- B. `dashboard_summary(p_user_today date)`: v0.86's function, copied
--    byte for byte, with one line added to each of the two counts (both
--    marked `-- v0.87 fresh rows only`; the suite checks that nothing else
--    in the body differs from v0.86's):
--      active_sessions  'Running' and last_active_at within 300 seconds
--      online_devices   'Online'  and last_seen_at  within 1800 seconds
--    Every app that shows these two figures reads them from here, so they
--    come right for every version on every platform without an app release:
--    the iPhone / iPad Overview tiles, the Mac's Overview, the Watch, the
--    widgets and Siri where they carry the figure, the PDF / CSV export, and
--    the Android and desktop apps' Overview.
--    Not changed: each device's own status in the device lists (still
--    'Online' until a later release reads `last_seen_at` itself).
-- C. app_rpc.sql (the fresh-install definitions) is brought in line with
--    production: it gains `_cleanup_expired_data_internal()` as above, and
--    its `cleanup_expired_data()`, which had drifted into a body of its own
--    (resolved alerts only, usage_snapshots, provider_quotas) that never
--    ran in production, becomes production's service_role wrapper, the body
--    migrate_v0.22 installed, byte for byte. This migration does not touch
--    the wrapper in production.
--    schema.sql gains `pairing_attempt_log` (migrate_v0.16's table), which
--    the cleanup and register_helper name and a fresh install lacked.
--
-- ── THE TWO WINDOWS ───────────────────────────────────────────
-- active_sessions, 300 s: the window the apps already use for a running
-- session (CLIPulseCore `SessionFreshnessFilter.freshnessWindow` and
-- `SessionFreshnessTierClassifier.processFreshnessWindow`, 2 x 120 s + 60 s).
-- Rows are compared the way `filterCurrent` compares them
-- (`last_active_at >= now - 300 s`). A desktop app on battery rewrites its
-- rows every 300 or 900 s, so its running sessions can drop out of the count
-- between syncs, as they drop out of the apps' session lists.
--
-- online_devices, 1800 s = twice the longest interval at which any producer
-- writes `devices.last_seen_at` (helper_heartbeat and helper_sync both set
-- it):
--   * the Mac's LoginItem helper (HelperDaemon.syncInterval): 120 s; the
--     app group's `helper_sync_interval` could raise it (a value of 60 or
--     more), but nothing in the apps writes that key;
--   * the Companion CLI (helper/cli_pulse_helper.py, `daemon --interval`):
--     default 120 s, at least 60; the launchd plists the app and the .pkg
--     install pass 120 or nothing;
--   * the Windows / Linux desktop app (cli-pulse-desktop,
--     src-tauri/src/lib.rs `adaptive_sync_interval`): 120 s on AC power,
--     300 s on battery, 900 s on low battery, the longest of any producer.
-- Twice 900 s leaves room for one missed sync. Someone who runs the CLI by
-- hand with `--interval` above 900 sees that device drop out of the count
-- between syncs. `user_settings.offline_grace_period_minutes` (default 5) is
-- not used: nothing decides with it (the Android app only shows and edits
-- it), and 5 minutes would drop a desktop on battery between syncs.
--
-- Whose clock: `devices.last_seen_at` is the server's now() (helper_sync and
-- helper_heartbeat set it), but `sessions.last_active_at` is the time the
-- producer sends; helper_sync caps it at 10 minutes ahead of the server and
-- puts no floor under it. So the 300 s window, and the cleanup's retention for sessions, compare
-- against the producer's clock. A Mac whose clock is more than 5 minutes
-- slow never shows in active_sessions (the apps' SessionFreshnessFilter
-- drops its rows the same way); one more than a retention period slow has
-- its live rows deleted each night and written again by its next sync,
-- which is churn, not loss.
--
-- ── WHAT DOES NOT CHANGE ──────────────────────────────────────
--   * dashboard_summary's signature (one overload, `(p_user_today date
--     default null)`, jsonb), every key of its answer and the other four
--     values (today_usage, today_cost, unresolved_alerts, today_sessions);
--     its grants, owner, SECURITY DEFINER and search_path (`create or
--     replace` with the same arguments keeps them; nothing here grants);
--   * `_cleanup_expired_data_internal()`'s grants: the REVOKE below repeats
--     v0.21's and changes nothing in production, where only postgres and
--     service_role can execute it;
--   * the `cleanup_expired_data()` wrapper in production, the cron jobs and
--     every table's structure (`user_settings.data_retention_days` gains no
--     CHECK here; a later migration can add `CHECK (data_retention_days
--     between 0 and 36500)` as NOT VALID, then VALIDATE). No row of any
--     table is written by applying this file; the rows go when the function
--     first runs (APPLY step 3);
--   * the server-side Yield pipeline, which today has nothing to work on
--     (commits, session_commit_links and yield_score_daily are empty). Note
--     for whoever brings it back: `_recompute_yield_scores_for_user_internal`
--     (called by recompute_yield_scores_for_user and ingest_commits) deletes
--     an account's yield_score_daily rows and rebuilds them from `sessions`,
--     which this cleanup now keeps for the retention period only (7 days),
--     while PRIVACY.md lists yield_score_daily as kept for 18 months: a
--     rebuild would silently cut Yield history to 7 days.
-- What the first run deletes cannot be brought back except from a backup.
--
-- ── APPLY (owner) ─────────────────────────────────────────────
-- 0. Preflight, read-only. Run this and keep its answer:
--
--      select p.proname, pg_get_function_identity_arguments(p.oid) as args,
--             p.prosecdef, p.prosrc like '%v0.87%' as v087,
--             md5(p.prosrc) as body_md5,
--             has_function_privilege('anon', p.oid, 'EXECUTE') as anon,
--             has_function_privilege('authenticated', p.oid, 'EXECUTE')
--               as authenticated
--        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public'
--         and p.proname in ('_cleanup_expired_data_internal',
--                           'cleanup_expired_data', 'dashboard_summary')
--       order by 1;
--
--    Expect three rows, prosecdef = true and v087 = false in each; args
--    empty for the two cleanup functions and `p_user_today date` for
--    dashboard_summary; anon = false everywhere; authenticated = false for
--    the two cleanup functions and true for dashboard_summary; and body_md5
--    exactly the bodies production runs, as measured there on 2026-10-26
--    (CI computes these from the files and fails when they go stale):
--
--      v0.21  _cleanup_expired_data_internal  6f49015b40891d6c916ed8fa4e2e75f4
--      v0.22  cleanup_expired_data            de73a4e04618edd359ddeead7354cfa5
--      v0.86  dashboard_summary               293d69f4f49ce4be45d96df8a0f6b388
--
--    If any body_md5 differs, STOP: production runs a body this repo does
--    not have, and v0.87 replaces two of them whole. Diff the saved
--    definitions below against those files and decide before going on.
--
--    Save the current definitions (the exact rollback source):
--      select pg_get_functiondef(p.oid) from pg_proc p
--       join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public'
--         and p.proname in ('_cleanup_expired_data_internal',
--                           'cleanup_expired_data', 'dashboard_summary');
--
--    The dry run: what the first run will delete, counts only. Same
--    predicates as the function's DELETEs (the suite checks it predicts the
--    function's answer exactly); run it again just before the first run,
--    since rows keep crossing their retention:
--
--      with keep as (
--        select user_id, make_interval(days => least(data_retention_days, 36500)) as keep
--          from public.user_settings
--         where data_retention_days > 0
--      )
--      select 'sessions' as table_name, count(*) as rows_to_delete,
--             count(*) filter (where s.status = 'Running') as of_them_running
--        from public.sessions s join keep k on k.user_id = s.user_id
--       where s.last_active_at < now() - k.keep
--      union all
--      select 'alerts', count(*), null
--        from public.alerts a join keep k on k.user_id = a.user_id
--       where a.created_at < now() - k.keep
--      union all
--      select 'pairing_attempt_log', count(*), null
--        from public.pairing_attempt_log
--       where attempted_at < now() - interval '1 hour'
--      order by 1;
--
--    The ops check (backend/supabase/ops/check_cron_references.sql),
--    read-only: every `public.<name>` that an active cron job's command, or a
--    function it calls, names must exist. Before v0.87 it returns one row:
--      cleanup_expired_data_nightly | _cleanup_expired_data_internal | public.device_snapshots
--
-- 1. Apply on the day the PR that adds this file merges: PRIVACY.md's Data
--    retention section, published with it, describes what this file makes
--    production do (merged first, so that what runs is on main). Apply this
--    file as it stands, byte for byte, comments included, with the Supabase
--    MCP's `apply_migration` under the name
--    `v0_87_retention_cleanup_and_fresh_counts` (that also writes its row in
--    `supabase_migrations.schema_migrations`; any other route runs the SQL
--    without the row, so record it by hand then). Record in the apply log
--    the md5 of the text sent next to this file's. If apply_migration times
--    out, run step 2 before trying again: it may have gone through. The file
--    carries its own begin/commit, refuses to run without v0.86's
--    dashboard_summary or v0.21's cleanup function, or when a table the new
--    cleanup names is missing, and writes no row.
--
-- 2. Post-apply, read-only:
--    * step 0's query gives three rows with the same args, prosecdef, anon
--      and authenticated as step 0 recorded, v087 = true for
--      _cleanup_expired_data_internal and dashboard_summary (false for the
--      wrapper, whose body is unchanged), and body_md5 exactly (CI checks
--      these too):
--
--      v0.87  _cleanup_expired_data_internal  119e431b2b0f5c95f52a611e6dd14ac6
--      v0.22  cleanup_expired_data            de73a4e04618edd359ddeead7354cfa5
--      v0.87  dashboard_summary               2dad9b1af717d9921a75d4dc95a26b1f
--
--    * the ops check returns no rows;
--    * signed in to a test account, the iPhone's Overview shows Online
--      Devices 1 while its Mac is paired and syncing, and 0 once that Mac has
--      been switched off for 30 minutes.
--
-- 3. The first run deletes what step 0's dry run counted (plus the rows that
--    crossed their retention since). It is the 03:07 UTC cron run after the
--    apply, or, to see its answer, the owner runs once
--      select public._cleanup_expired_data_internal();
--    whose answer gives each table's count and errors = 0.
--
-- 4. The day after the first cron run, read-only: the dry run counts only
--    rows that crossed their retention since that run, and no row is a day
--    past it (both counts 0):
--      select (select count(*) from public.sessions s
--                join public.user_settings us on us.user_id = s.user_id
--               where us.data_retention_days > 0
--                 and s.last_active_at < now() - make_interval(days => least(us.data_retention_days, 36500) + 1)),
--             (select count(*) from public.alerts a
--                join public.user_settings us on us.user_id = a.user_id
--               where us.data_retention_days > 0
--                 and a.created_at < now() - make_interval(days => least(us.data_retention_days, 36500) + 1));
--    cron.job_run_details shows the run succeeded, and the Postgres log has
--    no WARNING from _cleanup_expired_data_internal.
--
-- The ops check also belongs in every later migration's post-apply step and
-- in each release's verification (AGENTS.md, Backend SQL validation).
--
-- ROLLBACK: apply the definitions saved in step 0 (the suite does this and
-- gets step 0's bodies back). Deleted rows do not come back.
-- ============================================================

begin;

set local lock_timeout = '30s';

-- What this replaces must be in place: v0.86's dashboard_summary (v0.87's
-- body is v0.86's, so applying it over an older one would bring v0.86's
-- token rule in unannounced) and v0.21's cleanup function.
do $$
begin
  if to_regprocedure('public.dashboard_summary(date)') is null
     or not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'dashboard_summary'
                       and p.prosrc like '%v0.86 each token once%') then
    raise exception 'dashboard_summary(date) is not v0.86''s — apply v0.86 first; stop';
  end if;
  if to_regprocedure('public._cleanup_expired_data_internal()') is null then
    raise exception '_cleanup_expired_data_internal() missing — apply v0.21 first; stop';
  end if;
end $$;

-- _cleanup_expired_data_internal: what the nightly cron job runs (v0.21's
-- schedule, unchanged). v0.87: one DELETE per table on its own savepoint, so
-- one table's failure is counted and reported and the others still go;
-- sessions of any status older than the account's retention (the zombie
-- 'Running' rows included); no device_snapshots, which never existed.
create or replace function public._cleanup_expired_data_internal()
returns jsonb as $$
declare
  v_sessions integer := 0;
  v_running integer := 0;
  v_alerts integer := 0;
  v_pairing integer := 0;
  v_failed text[] := '{}';
begin
  -- v0.87 one delete per table, each on its own savepoint (BEGIN ... EXCEPTION).

  -- Sessions whose last activity is older than the account's retention,
  -- whatever their status: a live producer rewrites its rows on every sync.
  -- Retention is capped at 36500 days: one account's larger value would
  -- otherwise overflow the timestamp and fail this DELETE for every account.
  begin
    with gone as (
      delete from public.sessions s
       using public.user_settings us
       where us.user_id = s.user_id
         and us.data_retention_days > 0
         and s.last_active_at < now() - make_interval(days => least(us.data_retention_days, 36500))
      returning s.status
    )
    select count(*), count(*) filter (where status = 'Running')
      into v_sessions, v_running
      from gone;
  exception when others then
    v_failed := v_failed || 'sessions'::text;
    raise warning '_cleanup_expired_data_internal: sessions not cleaned: % (SQLSTATE %)', sqlerrm, sqlstate;
  end;

  -- Alerts older than the account's retention, resolved or not (the same cap).
  begin
    delete from public.alerts a
     using public.user_settings us
     where us.user_id = a.user_id
       and us.data_retention_days > 0
       and a.created_at < now() - make_interval(days => least(us.data_retention_days, 36500));
    get diagnostics v_alerts = row_count;
  exception when others then
    v_failed := v_failed || 'alerts'::text;
    raise warning '_cleanup_expired_data_internal: alerts not cleaned: % (SQLSTATE %)', sqlerrm, sqlstate;
  end;

  -- Pairing attempts older than register_helper's one-hour window.
  begin
    delete from public.pairing_attempt_log
     where attempted_at < now() - interval '1 hour';
    get diagnostics v_pairing = row_count;
  exception when others then
    v_failed := v_failed || 'pairing_attempt_log'::text;
    raise warning '_cleanup_expired_data_internal: pairing_attempt_log not cleaned: % (SQLSTATE %)', sqlerrm, sqlstate;
  end;

  if cardinality(v_failed) > 0 then
    raise warning '_cleanup_expired_data_internal: % of 3 tables failed: %',
      cardinality(v_failed), array_to_string(v_failed, ', ');
  end if;

  return jsonb_build_object(
    'sessions_deleted', v_sessions,
    'running_sessions_deleted', v_running,
    'alerts_deleted', v_alerts,
    'pairing_attempt_log_deleted', v_pairing,
    'errors', cardinality(v_failed),
    'failed', to_jsonb(v_failed)
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

revoke all on function public._cleanup_expired_data_internal() from public, anon, authenticated;

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
-- v0.87: active_sessions counts 'Running' rows active in the last 300 s and
-- online_devices 'Online' devices seen in the last 1800 s (migrate_v0.87
-- header, THE TWO WINDOWS): rows nothing has rewritten no longer count.
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
        and last_active_at >= now() - interval '300 seconds' -- v0.87 fresh rows only
    ),
    'online_devices', (
      select count(*) from public.devices
      where user_id = v_user_id and status = 'Online'
        and last_seen_at >= now() - interval '1800 seconds' -- v0.87 fresh rows only
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

-- The bodies above must be the ones that ran, and every table the cleanup
-- names must exist (the ops check, for this one function): a cleanup naming
-- a missing table is how v0.21 failed for a year without anyone seeing it.
do $$
declare
  v_missing text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_missing
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('_cleanup_expired_data_internal', 'dashboard_summary')
     and p.prosrc not like '%v0.87%';
  if v_missing is not null then
    raise exception 'v0.87 did not replace: %', v_missing;
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('_cleanup_expired_data_internal', 'dashboard_summary')) <> 2 then
    raise exception 'v0.87: expected exactly one overload of each replaced function';
  end if;
  select string_agg(distinct 'public.' || r[1], ', ') into v_missing
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   cross join lateral regexp_matches(p.prosrc, 'public\.([a-z_][a-z0-9_]*)', 'g') r
   where n.nspname = 'public'
     and p.proname = '_cleanup_expired_data_internal'
     and to_regclass('public.' || r[1]) is null;
  if v_missing is not null then
    raise exception 'v0.87: the cleanup names %, which does not exist; stop', v_missing;
  end if;
end $$;

commit;

-- ============================================================
-- v0.84 — replace_daily_usage: a device's day and provider are replaced
--         whole, so a renamed model does not stay behind under its old name
-- Date: 2026-10-03
-- Written for 1.56 and NOT applied by the PR that adds it: the owner applies
-- it, with the steps at the end of this header.
--
-- ── WHAT IS WRONG ─────────────────────────────────────────────
-- `upsert_daily_usage` (v0.37) inserts or overwrites one row per
-- (user, device, day, provider, model). It never deletes. The Mac names each
-- row by its model, and that name can change between versions of the app:
--
--   * `normalizeClaudeModel` drops a `-YYYYMMDD` suffix only when the base
--     name has a price row, so the release that adds a price row renames the
--     model (`claude-haiku-4-5-20251001` -> `claude-haiku-4-5`).
--   * Before v1.50 an unpriced model was labelled as its priced sibling
--     (`claude-opus-4-8` was recorded as `claude-opus-4-7` until it got a
--     row of its own).
--
-- After such an update the Mac uploads each day of its 31-day read under the
-- new name, and the old row stays. `get_daily_usage` groups by
-- (day, provider, model), the iPhone adds the models of a day together, and
-- every day in the window counts the renamed model twice: once at the old
-- version's figures, once at the new.
--
-- ── WHAT THIS ADDS ────────────────────────────────────────────
-- One function, `replace_daily_usage(metrics, p_device_id)`. Same arguments,
-- same auth, same device-ownership check and same row writes as
-- `upsert_daily_usage` (it calls it), plus one rule:
--
--   For every (metric_date, provider) that appears in `metrics`, the caller's
--   rows under the same device for that day and provider whose model is NOT
--   in `metrics` are deleted. In the same transaction as the writes.
--
-- So the rows a device holds for a day and provider are exactly the set it
-- sent last. Days and providers absent from `metrics` are not touched, nor
-- are other devices' rows or other users'.
--
-- ── WHY A NEW FUNCTION, NOT A CHANGE TO upsert_daily_usage ────
--   * Apps up to 1.55 keep calling `upsert_daily_usage`. This file does not
--     touch it, so what they do is exactly what they did.
--   * The desktop app writes through `helper_sync_daily_usage`. Not touched.
--   * A new parameter on `upsert_daily_usage` would mean drop + create (a
--     `create or replace` with an extra argument makes a second overload:
--     v0.37's lesson) and re-granting. This file only adds.
--   * The 1.56 Mac calls `replace_daily_usage` first. When the server answers
--     404 (this file not applied yet, or rolled back), it sends the same body
--     to `upsert_daily_usage` and asks again an hour later. So the app can
--     ship before this is applied, but only by days: see WHEN under APPLY.
--
-- ── WHY THE MAC'S SET FOR A DAY AND PROVIDER IS COMPLETE ──────
-- The rule is only safe if a (day, provider) the Mac sends carries every
-- model it has for that day. `APIClient.dailyUsageRowsToUpload` leaves out
--   * Claude on the days Claude Code's cleanup is working through: ALL of
--     Claude's rows for those days, so the group is absent and untouched (its
--     complete figures, sent earlier, stay);
--   * the synthetic `__claude_msg__` bucket, which is not a model. Older apps
--     uploaded it; this removes it, which is right.
-- `DailyUsageReplaceUploadTests` pins that property: whatever the filter
-- drops, it drops whole (day, provider) groups.
--
-- "Complete" means everything the Mac's read found. The read can find less
-- than the day held:
--   * a Claude Code `cleanupPeriodDays` shorter than 30, from user, project,
--     local or managed settings, deletes transcripts before the day the app
--     leaves out (reading the effective setting is a separate 1.56 item);
--   * a log folder or file the app can no longer read;
--   * a Codex session that ran for days or was resumed later. The scan picks
--     Codex rollout files by their start-date folder, from the day before the
--     window's first day (`listCodexSessionFiles`, as CodexBar does). Such a
--     session keeps writing to its original file, so once that folder leaves
--     the window the file is no longer read, while the days it wrote to are
--     still in the window and still uploaded. Measured on one Mac on
--     2026-10-07: 18 of 1,093 rollout files were last written 2 or more days
--     after their start folder, the longest 157 days.
-- `upsert_daily_usage` already overwrote every model such a read still found
-- with the lowered figure; this also removes a model it no longer found at
-- all. That is the rule the Mac's own archive applies to the routine read
-- (days after the cleanup reach are replaced whole, #632), so the iPhone
-- shows what the Mac shows. Rows lost to an unreadable folder come back with
-- the first upload after it is readable again, for days still in the window.
-- The Codex case is the scanner's own limit, older than this file, which
-- only widens it (from a lowered figure to a missing model). The fix belongs
-- in the scanner: list Codex files by modification time on or after the
-- window's first instant as well, as the Claude scan has since 1.55. That is
-- a follow-up, and it needs a decision on parity with CodexBar.
--
-- ── THE SHARED "NO DEVICE" ROWS: AN OWNER DECISION ────────────
-- A Mac without a paired helper sends no `p_device_id`, and its rows land
-- under the nil UUID, which every such Mac on the account shares (v0.37).
-- Pairing is a manual code flow, so unpaired Macs are not rare. The rule
-- applies under the nil UUID too:
--   * One unpaired Mac on the account: the double count is fixed.
--   * Two or more unpaired Macs on one account. BEFORE (upsert only): a model
--     only one Mac used was written by that Mac alone, so its row was exact;
--     only a model both Macs used was wrong (the last writer's figure won).
--     When the Macs used different models, the day's total was right.
--     AFTER (this function): every upload deletes, for each (day, provider)
--     in its 31-day window, every model the other Mac sent and it did not.
--     The Mac that uploaded last holds those days whole. Each Mac uploads on
--     every refresh (every 2 minutes by default), so the iPhone's daily and
--     30-day figures swing between the two Macs' totals. Two Macs using
--     different models of one provider is common, for example haiku from
--     Claude Code's background tasks on only one of them.
-- Pairing each Mac avoids it (each gets its own device id). If the trade is
-- not accepted, the Mac sends uploads without a `p_device_id` to
-- `upsert_daily_usage` instead: one line in `APIClient.syncDailyUsage`, no
-- schema change. Unpaired Macs then keep the double count after a rename,
-- and paired ones get the fix. The choice is the owner's and must be made
-- before 1.56 is released; it is not among the decisions delegated for 1.56.
--
-- ── WHAT THIS DOES NOT FIX ────────────────────────────────────
--   * Days the Mac no longer uploads keep any duplicate an earlier rename
--     left. The Mac sends its 31-day read; the iPhone's heatmap reads 365
--     days. Query (A) below counts them. No cleanup is attempted here: which
--     of two names is stale is not decidable in SQL for every past rename
--     (the v1.50 one relabelled, it did not strip a suffix), and choosing by
--     `updated_at` would also delete models only an older, complete upload
--     carried (apps before 1.55 uploaded the oldest Claude day partly).
--   * A provider that vanishes from a day entirely keeps its old rows: no
--     row of that day and provider is sent, so there is no group to replace.
--   * A Mac that pairs, unpairs or re-pairs inside its window. Its earlier
--     rows stay under the device id they were sent under (the nil UUID, or
--     the previous device). This function only touches the device id an
--     upload is sent under, so it never removes them, and `get_daily_usage`
--     counts those days twice on the iPhone, as it has since v0.37. The fix
--     belongs in the pairing flow (for example, moving the nil-UUID rows when
--     a Mac pairs).
--   * The desktop app's rows (`helper_sync_daily_usage`).
--
-- ── APPLY (owner) ─────────────────────────────────────────────
-- WHEN: before 1.56 is released, or within days of it. The order of app and
-- migration does not matter only inside that time. While this is not
-- applied, a 1.56 Mac falls back to `upsert_daily_usage`, so a model that
-- 1.56 renames leaves its old row next to the new one on every day of the
-- Mac's 31-day window. Each such day that leaves the window before this is
-- applied keeps both rows for good, because nothing here cleans older days.
-- 1.56 itself is the likely next rename: #647 adds Claude price rows, and a
-- dated spelling of those models then loses its date suffix. Keep the
-- fallback anyway, for a rollback and for an app that reaches users first.
--
-- 0. Preflight, read-only. Expect exactly one row, `metrics jsonb,
--    p_device_id uuid`, prosecdef = true:
--
--      select pg_get_function_identity_arguments(p.oid), p.prosecdef
--        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public' and p.proname = 'upsert_daily_usage';
--
--    And expect no row (nobody created the new name by hand):
--
--      select 1 from pg_proc where proname = 'replace_daily_usage';
--
-- 1. Apply this file as it stands (it carries its own begin/commit and
--    aborts on any failed assertion). It changes no row and no existing
--    function.
--
-- 2. Post-apply, read-only:
--
--      select has_function_privilege('anon',          'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE');  -- false
--      select has_function_privilege('authenticated', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE');  -- true
--
--    PostgREST picks the function up from the `notify` at the end. A 1.56
--    Mac that was answered 404 before asks again within the hour; from then
--    on it logs no `[syncDailyUsage] replace_daily_usage unavailable` line,
--    and its next upload replaces the days of its window.
--
-- 3. (A) How many duplicate rows a past rename left, by suffix pattern only
--    (a lower bound; read-only):
--
--      select count(*)
--        from public.daily_usage_metrics d
--        join public.daily_usage_metrics b
--          on b.user_id = d.user_id and b.device_id = d.device_id
--         and b.metric_date = d.metric_date and b.provider = d.provider
--         and d.model ~ '-[0-9]{8}$'
--         and b.model = regexp_replace(d.model, '-[0-9]{8}$', '');
--
-- ROLLBACK: `drop function public.replace_daily_usage(jsonb, uuid);` then
-- `notify pgrst, 'reload schema';`. The 1.56 Mac gets 404 and goes back to
-- `upsert_daily_usage` by itself. Rows deleted by the rule are not restored;
-- each was a model name the same device no longer sent for that day.
-- ============================================================

begin;

-- The function this one delegates its writes to must be the v0.37 shape.
-- Fails before anything is created if production has drifted from it.
do $$
begin
  if to_regprocedure('public.upsert_daily_usage(jsonb,uuid)') is null then
    raise exception 'public.upsert_daily_usage(jsonb, uuid) is missing — v0.37 is not in place; stop';
  end if;
end
$$;

create or replace function public.replace_daily_usage(
  metrics jsonb,
  p_device_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_device_id uuid := coalesce(
    p_device_id, '00000000-0000-0000-0000-000000000000'::uuid);
  v_written jsonb;
  v_removed int := 0;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- One replace at a time per (user, device): two overlapping refreshes from
  -- the same device must not end with the union of their sets. A hash
  -- collision only serializes two unrelated calls.
  perform pg_advisory_xact_lock(
    hashtextextended(v_user_id::text || '/' || v_device_id::text, 84));

  -- The writes, exactly as upsert_daily_usage makes them. It also checks
  -- that p_device_id belongs to the caller and raises 42501 if not, so
  -- nothing below runs for a foreign device.
  v_written := public.upsert_daily_usage(metrics, p_device_id);

  -- The rule: within each (day, provider) sent, a model not sent is gone.
  -- The date range only lets the delete use the (user, device, date) index
  -- instead of reading all of the device's rows; the two `exists` clauses
  -- decide what goes. An empty upload gives a null range, so nothing goes.
  with sent as (
    select distinct
      (e->>'metric_date')::date as metric_date,
      e->>'provider'            as provider,
      e->>'model'               as model
    from jsonb_array_elements(coalesce(metrics, '[]'::jsonb)) as e
  )
  delete from public.daily_usage_metrics d
   where d.user_id = v_user_id
     and d.device_id = v_device_id
     and d.metric_date between (select min(s.metric_date) from sent s)
                           and (select max(s.metric_date) from sent s)
     and exists (
       select 1 from sent s
        where s.metric_date = d.metric_date and s.provider = d.provider)
     and not exists (
       select 1 from sent s
        where s.metric_date = d.metric_date and s.provider = d.provider
          and s.model = d.model);
  get diagnostics v_removed = row_count;

  return jsonb_build_object(
    'upserted', coalesce((v_written->>'upserted')::int, 0),
    'removed',  v_removed
  );
end;
$$;

-- Supabase grants EXECUTE on new public functions to anon by default.
revoke all on function public.replace_daily_usage(jsonb, uuid) from public, anon;
grant execute on function public.replace_daily_usage(jsonb, uuid) to authenticated, service_role;

-- ------------------------------------------------------------
-- In-transaction assertions. Each ABORTS the apply.
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'replace_daily_usage'
       and p.prosecdef
       and p.proconfig::text like '%search_path=pg_catalog, public, extensions%'
  ) then
    raise exception 'replace_daily_usage is not SECURITY DEFINER with the pinned search_path';
  end if;

  if has_function_privilege('anon', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE') then
    raise exception 'anon can execute replace_daily_usage — the default grant was not revoked';
  end if;
  if not has_function_privilege('authenticated', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE') then
    raise exception 'a real caller cannot execute replace_daily_usage';
  end if;

  -- The old path stays: apps up to 1.55 call it, and this one delegates to it.
  if to_regprocedure('public.upsert_daily_usage(jsonb,uuid)') is null
     or not has_function_privilege('authenticated', 'public.upsert_daily_usage(jsonb,uuid)', 'EXECUTE') then
    raise exception 'upsert_daily_usage(jsonb, uuid) is gone or no longer callable by authenticated';
  end if;
end
$$;

commit;

notify pgrst, 'reload schema';

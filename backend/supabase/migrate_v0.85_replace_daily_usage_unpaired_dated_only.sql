-- ============================================================
-- v0.85 — replace_daily_usage: under the shared "no device" id, an upload
--         removes only a dated spelling of a model it sends
-- Date: 2026-10-07
-- Written for 1.56 and NOT applied by the PR that adds it. Apply it right
-- after v0.84, in the same sitting (APPLY below).
--
-- ── WHY ───────────────────────────────────────────────────────
-- v0.84 adds `replace_daily_usage`: for every (day, provider) an upload
-- carries, the device's rows whose model the upload does not carry are
-- deleted, so a model the app renamed stops counting twice. Its header left
-- one case to the owner: a Mac without a paired helper sends no
-- `p_device_id`, its rows land under the nil UUID, and every unpaired Mac on
-- the account shares that id. Under v0.84 each such upload deletes the models
-- only the other unpaired Macs used, across its whole 31-day window, and the
-- iPhone's figures swing between the Macs' totals on every refresh.
--
-- The owner's decision (2026-10-07): "targeted cleanup only". Under the nil
-- UUID an upload deletes only a row whose model is a date-suffixed spelling
-- of a model it sends (`claude-x-YYYYMMDD` when `claude-x` is sent). It never
-- deletes another unpaired Mac's different model. Paired devices keep v0.84's
-- full replace. v0.84's file is left as it was merged and reviewed (#648):
-- its section on the shared "no device" rows, an owner decision, describes v0.84
-- on its own, and this file is the answer to it.
--
-- ── THE RULE, EXACTLY ─────────────────────────────────────────
-- Paired device (`p_device_id` sent, owned by the caller): unchanged from
-- v0.84. Within each (metric_date, provider) the upload carries, every row
-- of that device whose model the upload does not carry for that
-- (metric_date, provider) is deleted.
--
-- No `p_device_id` (the nil UUID, `00000000-0000-0000-0000-000000000000`):
-- a row of the caller under the nil UUID is deleted only when ALL of these
-- hold:
--   1. the upload carries a row with the same metric_date and provider;
--   2. no row of the upload has the same metric_date, provider and model;
--   3. its model ends in a hyphen and exactly 8 digits, `-[0-9]{8}$` (the
--      `-YYYYMMDD` suffix `normalizeClaudeModel` drops, with the same
--      pattern, once the rest of the name has a price row: that is how a Mac
--      update renames a Claude model). The digits are not checked as a
--      calendar date, as the app does not check them either;
--   4. `regexp_replace(model, '-[0-9]{8}$', '')`, the name without that
--      suffix, IS a model the upload carries for the same metric_date and
--      provider.
-- (3 follows from 2 and 4: without the suffix the name is unchanged, and 2
-- excludes it. The code states 3 anyway, for whoever reads it.)
-- So sending `claude-haiku-4-5` on day D removes `claude-haiku-4-5-20251001`
-- on D, and nothing else: not `claude-sonnet-5`, not
-- `claude-sonnet-4-5-20250929` (its base is not sent), not the dated row on
-- a day the upload does not send `claude-haiku-4-5`, not the same name under
-- another provider, not another user's rows, not a paired device's rows.
-- An explicit nil UUID as `p_device_id` is refused as before (42501, from
-- `upsert_daily_usage`; `devices_id_not_nil_uuid` keeps it out of `devices`),
-- so this branch is reached only by sending no id.
--
-- Deliberately NOT covered under the nil UUID (rows stay, as with
-- `upsert_daily_usage`):
--   * Codex's `-YYYY-MM-DD` suffix, `openai/` and `anthropic.` prefixes,
--     Bedrock's `-v1:0`, and the pre-v1.50 relabel (`claude-opus-4-8`
--     recorded as `claude-opus-4-7`). The owner's rule names the Claude form.
--     Measured read-only in production on 2026-10-07: one row in all of
--     `daily_usage_metrics` has a date suffix at all (`-YYYYMMDD`, under the
--     nil UUID, its base not on the same day), and none has the Codex form.
--     The Codex history rebuild (#649) zeroes older Codex spellings for the
--     days before the routine window itself.
--   * A rename that is not a date suffix keeps the double count on an
--     unpaired Mac, as before v0.84. Pairing the Mac gives it v0.84's full
--     replace.
--
-- ── WHAT CAN STILL MOVE UNDER THE NIL UUID ────────────────────
-- A dated spelling is deleted on the assumption that it is a renamed copy of
-- the model sent. Two narrow cases make that wrong for a while:
--   * Two unpaired Macs on different app versions: one still names a model
--     `claude-x-YYYYMMDD` (its version has no price row for `claude-x`), the
--     other sends `claude-x` for the same day. Each upload of the newer one
--     removes the older one's row, and the older one writes it back on its
--     next refresh, so that day's figure for that model moves by the older
--     Mac's share until it updates.
--   * Two unpaired Macs on one version whose logs name one unpriced model
--     differently (one dated, one not): the same back and forth.
-- Both need two unpaired Macs on one account using the same model on the
-- same day. Different models, the common case, are never touched. A model
-- both Macs use under one name is last-writer-wins, as it has been since
-- v0.37.
--
-- ── HOW ───────────────────────────────────────────────────────
-- `create or replace` of v0.84's function with the same arguments and return
-- type, so no second overload is created and the grants carry over (they are
-- re-stated below anyway). The body is v0.84's with the nil UUID named as a
-- constant and one clause added to the delete, which applies only to the nil
-- UUID; the rest differs in comments only. Same per-device advisory lock
-- (same key), same delegation to `upsert_daily_usage`, same return value.
-- `upsert_daily_usage`, which apps up to 1.55 call, is not touched; nor is
-- anything else.
--
-- ── APPLY (owner; release step) ───────────────────────────────
-- ORDER: v0.84 first, then this file, in the same sitting. This file refuses
-- to run when v0.84's function is missing. Between the two, unpaired 1.56
-- Macs would get v0.84's full replace; only 1.56 calls the function, so
-- before 1.56 is out nothing calls it in between.
-- NEVER re-apply v0.84 after this file: its `create or replace` would put the
-- full replace back for the nil UUID. If that happens, apply this file again.
--
-- 0. Preflight, read-only. Expect one row, `metrics jsonb, p_device_id uuid`,
--    prosecdef = true, has_rule = false (v0.84 in place, this not yet):
--
--      select pg_get_function_identity_arguments(p.oid), p.prosecdef,
--             p.prosrc like '%v0.85 targeted rule%' as has_rule
--        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public' and p.proname = 'replace_daily_usage';
--
--    Save the current definition first:
--      select pg_get_functiondef('public.replace_daily_usage(jsonb,uuid)'::regprocedure);
--
-- 1. Apply this file as it stands. It carries its own begin/commit and
--    aborts on any failed assertion. It changes no row.
--
-- 2. Post-apply, read-only: the preflight query again gives one row with
--    has_rule = true, and
--
--      select has_function_privilege('anon',          'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE');  -- false
--      select has_function_privilege('authenticated', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE');  -- true
--      select count(*) from pg_proc where proname = 'replace_daily_usage';                                    -- 1
--
-- ROLLBACK: to v0.84's behaviour, apply v0.84 again (full replace for the nil
-- UUID too); to no function at all, v0.84's rollback (`drop function
-- public.replace_daily_usage(jsonb, uuid);` then `notify pgrst, 'reload
-- schema';`). Rows deleted by the rule are not restored; under the nil UUID
-- each was a dated spelling of a model sent for the same day.
-- ============================================================

begin;

-- v0.84 must be in place (number order), and the function it delegates to.
do $$
begin
  if to_regprocedure('public.replace_daily_usage(jsonb,uuid)') is null then
    raise exception 'public.replace_daily_usage(jsonb, uuid) is missing — apply v0.84 first; stop';
  end if;
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
  -- The server's stand-in for "no device", shared by every unpaired Mac of
  -- the account (v0.37).
  v_unpaired constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
  v_device_id uuid := coalesce(p_device_id, v_unpaired);
  v_written jsonb;
  v_removed int := 0;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- One replace at a time per (user, device): two overlapping refreshes from
  -- the same device must not end with the union of their sets. A hash
  -- collision only serializes two unrelated calls. Same key as v0.84.
  perform pg_advisory_xact_lock(
    hashtextextended(v_user_id::text || '/' || v_device_id::text, 84));

  -- The writes, exactly as upsert_daily_usage makes them. It also checks
  -- that p_device_id belongs to the caller and raises 42501 if not, so
  -- nothing below runs for a foreign device (or an explicit nil UUID).
  v_written := public.upsert_daily_usage(metrics, p_device_id);

  -- The rule: within each (day, provider) sent, a model not sent is gone.
  -- The date range only lets the delete use the (user, device, date) index
  -- instead of reading all of the device's rows; the `exists` clauses
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
          and s.model = d.model)
     -- v0.85 targeted rule: under the stand-in every unpaired Mac shares,
     -- only a `-YYYYMMDD` spelling of a model sent for the same day and
     -- provider goes. Another unpaired Mac's different model stays.
     -- (The words "v0.85 targeted rule" are what the apply checks look for
     -- in the function's source; keep them.)
     and (
       v_device_id <> v_unpaired
       or (
         d.model ~ '-[0-9]{8}$'
         and exists (
           select 1 from sent s
            where s.metric_date = d.metric_date and s.provider = d.provider
              and s.model = regexp_replace(d.model, '-[0-9]{8}$', ''))
       )
     );
  get diagnostics v_removed = row_count;

  return jsonb_build_object(
    'upserted', coalesce((v_written->>'upserted')::int, 0),
    'removed',  v_removed
  );
end;
$$;

-- Unchanged from v0.84; re-stated so this file alone leaves them right.
revoke all on function public.replace_daily_usage(jsonb, uuid) from public, anon;
grant execute on function public.replace_daily_usage(jsonb, uuid) to authenticated, service_role;

-- ------------------------------------------------------------
-- In-transaction assertions. Each ABORTS the apply.
-- ------------------------------------------------------------
do $$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'replace_daily_usage') <> 1 then
    raise exception 'replace_daily_usage has more than one overload';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'replace_daily_usage'
       and p.prosecdef
       and p.proconfig::text like '%search_path=pg_catalog, public, extensions%'
       and p.prosrc like '%v0.85 targeted rule%'
  ) then
    raise exception 'replace_daily_usage is not the v0.85 body, SECURITY DEFINER with the pinned search_path';
  end if;

  if has_function_privilege('anon', 'public.replace_daily_usage(jsonb,uuid)', 'EXECUTE') then
    raise exception 'anon can execute replace_daily_usage';
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

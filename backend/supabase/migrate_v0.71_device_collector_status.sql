-- migrate_v0.71 — observability: why does an installed, running device deliver
-- NO usage data?
--
-- WHY
-- ---
-- Activation diagnosis (2026-07-25) found that 9 of 25 currently-alive devices
-- send neither metrics nor sessions: they heartbeat fine, so the app is running
-- and paired, but the core value — provider usage — never materialises. From the
-- backend the three very different causes are indistinguishable:
--
--   * the provider CLI isn't installed / has no credentials  (nothing to read)
--   * the collector RAN and threw                            (auth expired, parse
--                                                             break, sandbox
--                                                             bookmark not active
--                                                             → silent zero, the
--                                                             1.30.1 bug class)
--   * the user simply disabled that provider                 (working as intended)
--
-- `HelperDaemon.collectProviderQuotas` already distinguishes all of these — it
-- just logs them locally, where nobody can see them. This migration gives that
-- existing state machine a place to land so it can be correlated with
-- `devices.app_version` (v0.70).
--
-- SHAPE
-- -----
-- `collector_status` is a small map covering only the providers that actually
-- exist on the machine, plus a counts summary, e.g.
--   {"claude":"ok","codex":"error","_counts":"d=0 u=47 p=2"}
-- Outcomes are short opaque tokens; no usage numbers, no paths, no credentials —
-- nothing that isn't already implied by the provider list the device syncs.
-- Providers that are disabled or absent are counted rather than listed: a stock
-- install enables EVERY registered ProviderKind (~50), so listing them would
-- crowd out the handful of real failures this field exists to surface.
-- Bounded exactly like the v0.66 `machine_controls` fold (key length, entry
-- count, payload size) so a misbehaving client can't bloat the row.
--
-- RPC
-- ---
-- Rather than add a second diagnostics RPC, this GENERALISES the v0.70 one:
-- `helper_report_app_version` gains an optional `p_collector_status`, and each
-- field is coalesced independently so a caller can report either or both. That
-- matters because the two have different reporters: the app reports its version
-- (it is guaranteed to be the new binary), while only the sync daemon knows the
-- collector outcomes.
--
-- The 3-arg version is DROPped first so the two do not become an ambiguous
-- overload for PostgREST. Safe to drop: v0.70 shipped less than a day ago, no
-- released build calls it yet (verified: zero rows with app_version set), and
-- callers that send only `p_app_version` still resolve to the new function.

alter table public.devices
  add column if not exists collector_status jsonb;

comment on column public.devices.collector_status is
  'Observability only. { provider -> "ok" | "empty" | "error" } for the '
  'providers that actually exist on the machine, from the last collector run, '
  'plus a "_counts" key ("d=<disabled> u=<unavailable> p=<listed>"). Providers '
  'the user disabled, or that are simply not installed, are COUNTED rather than '
  'listed — a stock install enables ~50 collectors and listing them all would '
  'crowd out the real failures. "empty" means the collector completed without '
  'error but produced no usable data (the silent-zero class). Never used for '
  'capability decisions.';

drop function if exists public.helper_report_app_version(uuid, text, text);

create or replace function public.helper_report_app_version(
  p_device_id uuid,
  p_helper_secret text,
  p_app_version text default null,
  p_collector_status jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
declare
  v_user_id uuid;
  v_clean text;
  v_status jsonb;
begin
  select user_id into v_user_id
  from public.devices
  where id = p_device_id
    and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  -- App version: blank is treated as "not reported" so a misconfigured client
  -- cannot blank out a previously-good value.
  v_clean := nullif(btrim(coalesce(p_app_version, '')), '');
  if v_clean is not null then
    v_clean := left(v_clean, 32);
  end if;

  -- Collector status: bounded like the v0.66 machine_controls fold — object
  -- only, payload cap, key-length cap, entry cap, value cap.
  --
  -- The entry cap is 64, not v0.66's 16/32: `ProviderConfig.defaults()` enables
  -- EVERY registered ProviderKind (~50 and growing), so a tighter cap would
  -- silently drop whichever providers sort last and make the row look complete
  -- while hiding real failures. The client already sends only the providers that
  -- actually exist on the machine plus a `_counts` summary, so 64 is pure
  -- headroom rather than the expected size — but the server must not be the
  -- thing that loses data (codex review).
  if p_collector_status is not null
     and jsonb_typeof(p_collector_status) = 'object'
     and pg_column_size(p_collector_status) <= 4096 then
    select coalesce(jsonb_object_agg(k, left(v, 24)), '{}'::jsonb) into v_status
    from (
      select key as k, value as v
      from jsonb_each_text(p_collector_status)
      where char_length(key) <= 32
      order by key
      limit 64
    ) s;
  end if;

  if v_clean is null and v_status is null then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_report');
  end if;

  -- Per-field coalesce: an omitted field preserves the last-known value, so the
  -- app (version) and the daemon (collector status) can report independently.
  -- Deliberately does NOT touch last_seen_at / status: liveness is owned by
  -- helper_heartbeat, and a diagnostics report must never fake a heartbeat.
  update public.devices
     set app_version      = coalesce(v_clean, app_version),
         collector_status = coalesce(v_status, collector_status)
   where id = p_device_id;

  return jsonb_build_object(
    'ok', true,
    'app_version', v_clean,
    'collector_status', v_status
  );
end;
$function$;

grant execute on function public.helper_report_app_version(uuid, text, text, jsonb)
  to anon, authenticated, service_role;

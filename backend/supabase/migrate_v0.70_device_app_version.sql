-- migrate_v0.70 — observability: record the APP version each device runs.
--
-- WHY
-- ---
-- Found 2026-07-24 while investigating low activation. `devices.helper_version`
-- was supposed to answer "what version is this device running", but in
-- production 62 of ~68 Macs report "1.0.0":
--
--   * `HelperAPIClient.registerHelper` defaults `helperVersion` to a hardcoded
--     "1.0.0" and its ONLY caller (the Pairing UI) never passes one, so every
--     APP-paired device registers as "1.0.0". (The separately-installed Python
--     `.pkg` helper registers itself with its real HELPER_VERSION — those are
--     the handful of rows with real versions.)
--   * `helper_heartbeat` takes no version input at all, so the column is
--     write-once-at-pairing and never refreshes on upgrade. Even the real
--     values are frozen at whatever the device paired with (1.10.4 … 1.20.1).
--
-- Net effect: the fleet's real version is unobservable from the backend, which
-- blocks diagnosing why installed-and-running devices deliver no usage data
-- (9 of 25 currently-alive devices send neither metrics nor sessions).
--
-- WHY A NEW COLUMN INSTEAD OF FIXING helper_version
-- --------------------------------------------------
-- `helper_version` is OVERLOADED: besides observability it is a CAPABILITY
-- GATE — the client's `Device.helperVersionAtLeast(1,15,0)` extracts the first
-- semver out of it to decide whether to offer remote Codex/Gemini session
-- starts. The MAS (App Store) build ships NO command-capable helper (the Swift
-- LaunchAgent helper is stripped from App Store archives), and its accidental
-- "1.0.0" is what makes those devices correctly FAIL that gate. Writing the
-- real app version into `helper_version` would flip MAS devices to "capable"
-- and surface remote-start UI whose commands can never be executed — they would
-- sit pending forever. So `helper_version` keeps its exact current semantics
-- and this migration adds a SEPARATE, purely-observational field.
--
-- WHY A DEDICATED RPC INSTEAD OF EXTENDING helper_heartbeat
-- ---------------------------------------------------------
-- `helper_heartbeat` is the critical ingest path for every device's metrics
-- (~8.6 KB body). Re-emitting it via CREATE OR REPLACE just to add one field
-- risks the whole fleet's metrics ingestion for a diagnostic nicety. This
-- migration is therefore strictly ADDITIVE: a new nullable column plus a small
-- dedicated RPC. `helper_heartbeat` is left untouched.
--
-- Backward compatible in both directions: old clients simply never call the new
-- RPC (column stays null); the new RPC is a no-op for anything else.

-- 1. The column. Nullable on purpose — null means "this device has not yet
--    reported an app version" (old client), which is distinguishable from any
--    real value.
alter table public.devices
  add column if not exists app_version text;

comment on column public.devices.app_version is
  'Observability only: the CLI Pulse app version this device last reported '
  '(e.g. "1.43.0 (96)"), refreshed by helper_report_app_version. NEVER use for '
  'capability decisions — see devices.helper_version and the client-side '
  'helperVersionAtLeast gate.';

-- 2. The reporting RPC. Same auth model as helper_heartbeat: the caller proves
--    device ownership with the device's helper_secret (stored sha256-hashed).
--    SECURITY DEFINER + pinned search_path to match the rest of the helper RPC
--    surface (and to satisfy the SECURITY DEFINER search_path CI guard).
create or replace function public.helper_report_app_version(
  p_device_id uuid,
  p_helper_secret text,
  p_app_version text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
declare
  v_user_id uuid;
  v_clean text;
begin
  select user_id into v_user_id
  from public.devices
  where id = p_device_id
    and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  -- Bound the value: this is free-form text off a client. Empty/blank is
  -- treated as "no report" so a misconfigured client cannot blank out a
  -- previously-good value.
  v_clean := nullif(btrim(coalesce(p_app_version, '')), '');
  if v_clean is null then
    return jsonb_build_object('ok', false, 'reason', 'empty_version');
  end if;
  v_clean := left(v_clean, 32);

  -- Deliberately does NOT touch last_seen_at / status: liveness is owned by
  -- helper_heartbeat, and a version report must never fake a heartbeat.
  update public.devices
     set app_version = v_clean
   where id = p_device_id;

  return jsonb_build_object('ok', true, 'app_version', v_clean);
end;
$function$;

grant execute on function public.helper_report_app_version(uuid, text, text)
  to anon, authenticated, service_role;

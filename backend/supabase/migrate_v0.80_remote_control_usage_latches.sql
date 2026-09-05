-- migrate_v0.80_remote_control_usage_latches.sql
-- Four once-ever latches that answer the three questions the remote-control
-- plan says decide whether the self-built transport lives.
--
-- ⚠️ OWNER GATE — NOT APPLIED BY THE AUTHOR OF THIS FILE.
--    Backend schema is the owner's to apply. The client that fills these
--    columns ships first and degrades to the v0.76 parameter set until this
--    runs (PostgREST answers an unknown parameter set with PGRST202 and the
--    transport retries in the older shape), so applying this is what turns
--    the data on, and never applying it costs nothing but the data.
--
-- WHY THIS EXISTS
-- ---------------
-- Remote control (a paired iPhone watching and driving AI-CLI sessions on the
-- Mac) shipped across #527-#534 behind a dark-ship gate that is OFF by
-- default. The plan's exit condition is explicit: after ~14 days of real use,
-- answer three questions, and if all three are "no", cut the self-built
-- transport and keep only the vendor hand-off and read-only LAN. That is a
-- planned ending, not a failure — but it cannot be reached without evidence,
-- and today there is none, because nothing about remote control is observed
-- at all.
--
--   1. Is anyone using LAN or tailnet?   If every user is on a relay, the
--      end-to-end encryption is the only thing distinguishing us from the
--      three vendors, and it had better be built. If nobody leaves the LAN,
--      the relay should never be built at all.
--   2. Is anyone remote-controlling something other than Claude?  If not,
--      the vendor hand-off (`claude --remote-control`) already covers the
--      need and the self-built transport is redundant.
--   3. Did anyone use the vendor hand-off?  If that is what people reach
--      for, the product's value is "one entry point", not "our transport".
--
-- WHAT IS COLLECTED -- four booleans, latched to a first-time timestamp
-- --------------------------------------------------------------------
--   remote_lan_used_at        a phone connected over a private LAN address
--   remote_tailnet_used_at    ... over a Tailscale/CGNAT address
--   remote_delegate_used_at   a session was started asking for the Claude
--                             hand-off (`--remote-control`)
--   remote_nonclaude_used_at  a session driven over the link was codex,
--                             gemini, or anything that is not claude
--
-- Each is a once-ever latch on the EXISTING one-row-per-install
-- `anonymous_installs` table, set with `coalesce` exactly as v0.76's
-- `helper_connected_at` and `first_cost_at` are. The table does not grow: no
-- new rows, no per-event records, no time series.
--
-- WHAT IS NOT COLLECTED, AND WHAT THESE CANNOT ANSWER
-- ---------------------------------------------------
-- No session content, no command, no output, no provider credential, no
-- device name, no phone identifier, no address (the LAN/tailnet distinction
-- is derived on the Mac from the peer's address class and only the CLASS is
-- reported), no counts, no durations, no timestamps beyond the first.
--
-- Being latches, they answer "did this ever happen for this install" and
-- NOT "how often". The plan asks for a click-through RATE on the hand-off
-- entry; this does not provide one. A rate needs an offered/taken pair of
-- counters, which is more data than the go/no-go decision requires, so it is
-- deliberately not here. If the answer to question 3 is "yes, some", THAT is
-- when a counter earns its own migration and its own justification.
--
-- The install id is the same client-generated random v4 UUID v0.73
-- introduced: not derived from the machine, dies with an uninstall, and the
-- same single opt-out switch silences all of it.
--
-- ABUSE SURFACE
-- -------------
-- Unchanged from v0.73/v0.76. The RPC remains the only way in, still
-- `security definer` with a fixed `search_path`, still upsert-keyed on
-- install_id so a replayed call updates one row, and `anon` still has no
-- read path. The new parameters are booleans; there is no new free-text
-- surface and nothing here can be used to store an attacker's string.

begin;

-- ---------------------------------------------------------------------------
-- Columns — additive, nullable, no default backfill
-- ---------------------------------------------------------------------------
alter table public.anonymous_installs
    add column if not exists remote_lan_used_at       timestamptz,
    add column if not exists remote_tailnet_used_at   timestamptz,
    add column if not exists remote_delegate_used_at  timestamptz,
    add column if not exists remote_nonclaude_used_at timestamptz;

comment on column public.anonymous_installs.remote_lan_used_at is
    'First time a paired phone reached this install over a private LAN address. Latched; never updated after the first.';
comment on column public.anonymous_installs.remote_tailnet_used_at is
    'First time a paired phone reached this install over a Tailscale/CGNAT address. Latched.';
comment on column public.anonymous_installs.remote_delegate_used_at is
    'First time a session was started asking for the Claude --remote-control hand-off. Latched.';
comment on column public.anonymous_installs.remote_nonclaude_used_at is
    'First time a session driven over the remote-control link was a provider other than claude. Latched.';

-- ---------------------------------------------------------------------------
-- RPC — four more boolean parameters, defaulted so the v0.76 call still works
-- ---------------------------------------------------------------------------
create or replace function public.record_anonymous_install(
    p_install_id            uuid,
    p_channel               text,
    p_app_version           text,
    p_os_version            text,
    p_provider_detected     boolean default false,
    p_helper_connected      boolean default false,
    p_cost_shown            boolean default false,
    p_ui_language           text    default null,
    p_remote_lan            boolean default false,
    p_remote_tailnet        boolean default false,
    p_remote_delegate       boolean default false,
    p_remote_nonclaude      boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_channel     text;
    v_app_version text;
    v_os_version  text;
    v_ui_language text;
    v_now         timestamptz := now();
begin
    if p_install_id is null then
        return;
    end if;

    -- Validation is unchanged from v0.76: unrecognised values are refused
    -- rather than stored, so this cannot become free-text storage.
    v_channel := lower(coalesce(p_channel, ''));
    if v_channel not in ('mas', 'devid', 'homebrew', 'testflight', 'unknown') then
        v_channel := 'unknown';
    end if;

    v_app_version := coalesce(p_app_version, '');
    if v_app_version !~ '^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$' then
        v_app_version := '';
    end if;

    v_os_version := coalesce(p_os_version, '');
    if v_os_version !~ '^[0-9]{1,3}(\.[0-9]{1,3})?$' then
        v_os_version := '';
    end if;

    if p_ui_language is null then
        v_ui_language := null;
    elsif lower(p_ui_language) ~ '^[a-z]{2}(-[a-z]{2,8})?$' then
        v_ui_language := lower(p_ui_language);
    else
        v_ui_language := null;
    end if;

    insert into public.anonymous_installs as ai (
        install_id, channel, app_version, os_version, ui_language,
        first_seen_at, last_seen_at,
        first_provider_detected_at, helper_connected_at, first_cost_at,
        remote_lan_used_at, remote_tailnet_used_at,
        remote_delegate_used_at, remote_nonclaude_used_at
    )
    values (
        p_install_id, v_channel, v_app_version, v_os_version, v_ui_language,
        v_now, v_now,
        case when p_provider_detected then v_now end,
        case when p_helper_connected  then v_now end,
        case when p_cost_shown        then v_now end,
        case when p_remote_lan        then v_now end,
        case when p_remote_tailnet    then v_now end,
        case when p_remote_delegate   then v_now end,
        case when p_remote_nonclaude  then v_now end
    )
    on conflict (install_id) do update set
        channel      = excluded.channel,
        app_version  = excluded.app_version,
        os_version   = excluded.os_version,
        ui_language  = coalesce(excluded.ui_language, ai.ui_language),
        last_seen_at = v_now,
        -- Every milestone is a LATCH: the first time wins and later calls
        -- cannot move it. `coalesce(existing, new)` and never the reverse.
        first_provider_detected_at = coalesce(ai.first_provider_detected_at, excluded.first_provider_detected_at),
        helper_connected_at        = coalesce(ai.helper_connected_at,        excluded.helper_connected_at),
        first_cost_at              = coalesce(ai.first_cost_at,              excluded.first_cost_at),
        remote_lan_used_at         = coalesce(ai.remote_lan_used_at,         excluded.remote_lan_used_at),
        remote_tailnet_used_at     = coalesce(ai.remote_tailnet_used_at,     excluded.remote_tailnet_used_at),
        remote_delegate_used_at    = coalesce(ai.remote_delegate_used_at,    excluded.remote_delegate_used_at),
        remote_nonclaude_used_at   = coalesce(ai.remote_nonclaude_used_at,   excluded.remote_nonclaude_used_at);
end;
$$;

grant execute on function public.record_anonymous_install(
    uuid, text, text, text, boolean, boolean, boolean, text,
    boolean, boolean, boolean, boolean
) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Verification — run these after applying; each must hold
-- ---------------------------------------------------------------------------
do $$
declare
    v_cols integer;
begin
    select count(*) into v_cols
    from information_schema.columns
    where table_schema = 'public' and table_name = 'anonymous_installs'
      and column_name in ('remote_lan_used_at', 'remote_tailnet_used_at',
                          'remote_delegate_used_at', 'remote_nonclaude_used_at');
    if v_cols <> 4 then
        raise exception 'expected 4 remote-control columns, found %', v_cols;
    end if;
end;
$$;

-- The latch must not move once set. Proven on a throwaway id inside a
-- transaction that is rolled back, because a `do` block cannot observe its
-- own `now()` changing (see the sql-verification-predicates note: a
-- timestamp assertion inside one block is otherwise vacuous).
do $$
declare
    v_id  uuid := gen_random_uuid();
    v_one timestamptz;
    v_two timestamptz;
begin
    perform public.record_anonymous_install(v_id, 'devid', '1.53.0', '26.5',
                                            false, false, false, null, true);
    select remote_lan_used_at into v_one from public.anonymous_installs where install_id = v_id;
    if v_one is null then
        raise exception 'the LAN latch did not set';
    end if;
    perform pg_sleep(0.01);
    perform public.record_anonymous_install(v_id, 'devid', '1.53.0', '26.5',
                                            false, false, false, null, true);
    select remote_lan_used_at into v_two from public.anonymous_installs where install_id = v_id;
    if v_two is distinct from v_one then
        raise exception 'the LAN latch moved on a second call: % -> %', v_one, v_two;
    end if;
    -- A call that does NOT claim the milestone must not clear it either.
    perform public.record_anonymous_install(v_id, 'devid', '1.53.0', '26.5');
    select remote_lan_used_at into v_two from public.anonymous_installs where install_id = v_id;
    if v_two is distinct from v_one then
        raise exception 'a later call without the flag cleared the latch';
    end if;
    delete from public.anonymous_installs where install_id = v_id;
end;
$$;

commit;

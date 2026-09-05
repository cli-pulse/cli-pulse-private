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
-- Postgres identifies a function by name + ARGUMENT TYPES, so adding
-- parameters with `create or replace` does not replace anything: it creates a
-- second overload. Both would carry defaults, so a 5- or 8-key body could
-- match either and PostgREST answers "could not choose the best candidate
-- function" -- every install goes silent, which is the exact failure this
-- telemetry exists to end. v0.76 dropped its predecessors for this reason;
-- do the same, inside the transaction so there is no window with no function.
-- Postgres identifies a function by name + ARGUMENT TYPES, so adding
-- parameters with `create or replace` would not replace anything: it would
-- create a second overload, both with defaults, and a 5- or 8-key body could
-- match either -- PostgREST then answers "could not choose the best candidate
-- function" and EVERY install goes silent, the exact failure this telemetry
-- exists to end. v0.76 dropped its predecessors for the same reason. The
-- 12-arg drop makes a second apply a no-op rather than "already exists".
drop function if exists public.record_anonymous_install(uuid, text, text, text, boolean);
drop function if exists public.record_anonymous_install(uuid, text, text, text, boolean, boolean, boolean, text);
drop function if exists public.record_anonymous_install(uuid, text, text, text, boolean, boolean, boolean, text, boolean, boolean, boolean, boolean);

-- The body below is v0.76's, VERBATIM, with four parameters, four insert
-- columns, four values and four coalesce latches added and nothing else
-- touched. This function replaces the one every install already calls, so
-- restating its validation from memory would silently change it: an earlier
-- draft of this file did exactly that and would have recorded every Homebrew
-- install as `unknown` and blanked every `zh-Hans`.
create function public.record_anonymous_install(
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
set search_path = public, pg_temp
as $migration$
declare
    v_channel     text;
    v_app_version text;
    v_os_version  text;
    v_language    text;
    v_today_count bigint;
begin
    if p_install_id is null then
        raise exception 'install_id is required' using errcode = '22023';
    end if;

    -- Reject rather than coerce. An unrecognised value is a client bug or an
    -- abuse attempt; filing it under "unknown" would hide both, and storing it
    -- verbatim would turn this column into free text.
    v_channel := lower(coalesce(p_channel, ''));
    if v_channel not in ('mas', 'devid', 'brew', 'unknown') then
        raise exception 'unsupported channel' using errcode = '22023';
    end if;

    v_app_version := coalesce(p_app_version, '');
    if v_app_version !~ '^[0-9]{1,4}(\.[0-9]{1,4}){0,4}$' then
        raise exception 'unsupported app_version' using errcode = '22023';
    end if;

    v_os_version := coalesce(p_os_version, '');
    if v_os_version !~ '^[0-9]{1,4}(\.[0-9]{1,4}){0,2}$' then
        raise exception 'unsupported os_version' using errcode = '22023';
    end if;

    -- NULL is allowed and means "client did not report one" -- a pre-v0.77
    -- binary, which must keep working. A NON-NULL value outside the closed set
    -- is a client bug, and is rejected for the same reason `channel` is: the
    -- client coarsens to this set, so anything else means the shaping broke,
    -- and silently storing it would make this a free-text column.
    if p_ui_language is null then
        v_language := null;
    else
        v_language := p_ui_language;
        if v_language not in ('en', 'es', 'ja', 'ko', 'zh-Hans', 'zh-Hant', 'other') then
            raise exception 'unsupported ui_language' using errcode = '22023';
        end if;
    end if;

    -- Ceiling on NEW installs per day. Counts inserts only, on purpose: an
    -- existing install updating its row is not growth, and throttling
    -- returning users would corrupt the very activation ratio this table
    -- exists to measure. 20k/day is roughly 100x the current install base.
    if not exists (
        select 1 from public.anonymous_installs where install_id = p_install_id
    ) then
        select count(*) into v_today_count
        from public.anonymous_installs
        where first_seen_at >= date_trunc('day', now());

        if v_today_count >= 20000 then
            -- Drop silently. Raising would tell a prober exactly where the
            -- ceiling sits, and a client can do nothing useful with the error.
            return;
        end if;
    end if;

    insert into public.anonymous_installs as ai (
        install_id, channel, app_version, os_version,
        first_provider_detected_at, helper_connected_at, first_cost_at,
        ui_language,
        remote_lan_used_at, remote_tailnet_used_at,
        remote_delegate_used_at, remote_nonclaude_used_at
    )
    values (
        p_install_id, v_channel, v_app_version, v_os_version,
        case when p_provider_detected then now() else null end,
        case when p_helper_connected  then now() else null end,
        case when p_cost_shown        then now() else null end,
        v_language,
        case when p_remote_lan        then now() else null end,
        case when p_remote_tailnet    then now() else null end,
        case when p_remote_delegate   then now() else null end,
        case when p_remote_nonclaude  then now() else null end
    )
    on conflict (install_id) do update set
        last_seen_at = now(),
        channel      = excluded.channel,
        app_version  = excluded.app_version,
        os_version   = excluded.os_version,
        -- Latest wins, like channel and version above: someone who switches the
        -- in-app language switcher is now running the new catalogue, and that
        -- is what the next launch's funnel row describes. `coalesce` keeps a
        -- known value when an older client omits the field, so a mixed fleet
        -- does not erase what a newer build already reported.
        ui_language  = coalesce(excluded.ui_language, ai.ui_language),
        -- Each milestone happens once. Never overwrite the original timestamp,
        -- or "time to first value" silently becomes "time since last launch".
        first_provider_detected_at = coalesce(
            ai.first_provider_detected_at, excluded.first_provider_detected_at
        ),
        helper_connected_at = coalesce(
            ai.helper_connected_at, excluded.helper_connected_at
        ),
        first_cost_at = coalesce(
            ai.first_cost_at, excluded.first_cost_at
        ),
        -- Remote-control latches, same rule: the first time wins.
        remote_lan_used_at = coalesce(
            ai.remote_lan_used_at, excluded.remote_lan_used_at
        ),
        remote_tailnet_used_at = coalesce(
            ai.remote_tailnet_used_at, excluded.remote_tailnet_used_at
        ),
        remote_delegate_used_at = coalesce(
            ai.remote_delegate_used_at, excluded.remote_delegate_used_at
        ),
        remote_nonclaude_used_at = coalesce(
            ai.remote_nonclaude_used_at, excluded.remote_nonclaude_used_at
        );
end;
$migration$;

comment on function public.record_anonymous_install(uuid, text, text, text, boolean, boolean, boolean, text, boolean, boolean, boolean, boolean) is
    'Upsert one anonymous install row. v0.80 adds four once-ever remote-control '
    'latches; every other rule is v0.76 unchanged.';
revoke all on function public.record_anonymous_install(uuid, text, text, text, boolean, boolean, boolean, text, boolean, boolean, boolean, boolean) from public;
grant execute on function public.record_anonymous_install(uuid, text, text, text, boolean, boolean, boolean, text, boolean, boolean, boolean, boolean) to anon, authenticated;


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

-- What CAN be proven inside one transaction.
--
-- NOT provable here: "a second call does not move the timestamp". `now()` is
-- TRANSACTION-scoped, so both calls stamp the identical value and the
-- assertion passes whether or not `coalesce` is the right way round --
-- exactly the vacuous predicate this repo has been bitten by before. The
-- ordering of `coalesce(existing, excluded)` is pinned by the Swift drift
-- test instead, which reads this file's text.
do $$
declare
    v_id  uuid := gen_random_uuid();
    v_one timestamptz;
    v_two timestamptz;
begin
    -- Setting the flag sets the column.
    perform public.record_anonymous_install(v_id, 'devid', '1.53.0', '26.5',
                                            false, false, false, null, true);
    select remote_lan_used_at into v_one from public.anonymous_installs where install_id = v_id;
    if v_one is null then
        raise exception 'the LAN latch did not set';
    end if;

    -- The OTHER latches stay null: one flag must not set its neighbours.
    perform 1 from public.anonymous_installs
        where install_id = v_id
          and (remote_tailnet_used_at is not null
               or remote_delegate_used_at is not null
               or remote_nonclaude_used_at is not null);
    if found then
        raise exception 'setting the LAN flag also set another latch';
    end if;

    -- A later call that does NOT claim the milestone must not clear it. This
    -- one is real: it fails if `coalesce` is dropped or inverted.
    perform public.record_anonymous_install(v_id, 'devid', '1.53.0', '26.5');
    select remote_lan_used_at into v_two from public.anonymous_installs where install_id = v_id;
    if v_two is null then
        raise exception 'a later call without the flag cleared the latch';
    end if;

    delete from public.anonymous_installs where install_id = v_id;
end;
$$;


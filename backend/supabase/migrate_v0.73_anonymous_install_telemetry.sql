-- migrate_v0.73_anonymous_install_telemetry.sql
--
-- Two counters for people who never sign in.
--
-- WHY THIS EXISTS
-- ---------------
-- v1.44 removed the login wall so CLI Pulse could be used without an account.
-- It worked, and it made us blind: `devices.user_id` is NOT NULL, there is no
-- anonymous table, and so a local-mode user leaves no trace anywhere. Six days
-- after 1.44 shipped, `profiles` had gained one row -- a number that means
-- nothing, because the feature's whole point is that those users do not appear
-- in `profiles`.
--
-- The activation investigation of 2026-07-25 concluded the problem is FIRST
-- VALUE, not churn and not the backend. We cannot act on that conclusion while
-- unable to observe whether first value happens.
--
-- WHAT IS COLLECTED -- deliberately two events, nothing else
-- ----------------------------------------------------------
--   install                  the app ran for the first time
--   first_provider_detected  it found a CLI on this machine and had a number
--                            to show
--
-- The ratio between them IS the first-value funnel. Anything beyond it is a
-- future migration with its own justification, not a field added quietly here.
--
-- WHAT IS NOT COLLECTED
-- ---------------------
-- No account, e-mail, device name, hostname, serial, IP (Postgres never sees
-- one -- PostgREST terminates the connection), file path, project name,
-- provider credential, token count, cost, or even which provider was found.
-- The install id is a random v4 UUID generated on the client and stored in
-- UserDefaults, so it dies with an uninstall. It is not derived from anything
-- about the machine and is not a device identifier.
--
-- Opt-out is a single switch in Settings; the client sends nothing at all when
-- it is off, and the first launch discloses this before the first send.
--
-- ABUSE SURFACE -- callable by `anon`, so assume it is called by anyone
-- --------------------------------------------------------------------
-- The RPC is the only way in; the table grants nothing to anon.
--   * upsert keyed on install_id, so a replayed call updates one row rather
--     than growing the table
--   * every input validated and shape-bounded; unrecognised values are
--     rejected rather than stored, so this cannot become free text storage
--   * no read path for anon at all -- you may write your own row and can never
--     read anybody's, including your own
--   * a per-day ceiling on NEW installs, because "cannot grow without bound"
--     is worth more than the events lost in an implausible legitimate spike

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

create table if not exists public.anonymous_installs (
    install_id                  uuid primary key,
    first_seen_at               timestamptz not null default now(),
    last_seen_at                timestamptz not null default now(),
    -- 'mas' | 'devid' | 'brew' | 'unknown'. Which channel an install came from
    -- is the one question App Store analytics cannot answer for us.
    channel                     text not null,
    -- Marketing version only ("1.44.0"). No build number: it narrows the
    -- population without answering anything we ask.
    app_version                 text not null,
    -- Major.minor only ("15.1"), coarsened on the client. A full OS build
    -- string is meaningfully identifying in a population this size.
    os_version                  text not null,
    -- The whole point: did this install ever reach first value?
    first_provider_detected_at  timestamptz
);

comment on table public.anonymous_installs is
    'One row per install of CLI Pulse, with no link to any account. Written '
    'only by record_anonymous_install(); readable only by service_role. See '
    'migrate_v0.73 for the collection rationale and abuse analysis.';

create index if not exists anonymous_installs_first_seen_idx
    on public.anonymous_installs (first_seen_at desc);

create index if not exists anonymous_installs_activation_idx
    on public.anonymous_installs (first_seen_at desc)
    where first_provider_detected_at is not null;

-- ---------------------------------------------------------------------------
-- Lockdown. Default-deny, then grant back only the RPC.
-- ---------------------------------------------------------------------------

alter table public.anonymous_installs enable row level security;

revoke all on public.anonymous_installs from public, anon, authenticated;

-- No policies are created on purpose. RLS is on, no policy exists, and no role
-- holds a grant, so every direct client path -- PostgREST included -- is denied
-- three times over. The SECURITY DEFINER function below is the only door. Same
-- posture as provider_account_lifecycle in v0.72: an empty policy list here is
-- the strictest possible state, not an oversight.

-- ---------------------------------------------------------------------------
-- Ingest
-- ---------------------------------------------------------------------------

create or replace function public.record_anonymous_install(
    p_install_id            uuid,
    p_channel               text,
    p_app_version           text,
    p_os_version            text,
    p_provider_detected     boolean default false
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
        first_provider_detected_at
    )
    values (
        p_install_id, v_channel, v_app_version, v_os_version,
        case when p_provider_detected then now() else null end
    )
    on conflict (install_id) do update set
        last_seen_at = now(),
        channel      = excluded.channel,
        app_version  = excluded.app_version,
        os_version   = excluded.os_version,
        -- First value happens once. Never overwrite the original timestamp, or
        -- "time to first value" silently becomes "time since last launch".
        first_provider_detected_at = coalesce(
            ai.first_provider_detected_at,
            excluded.first_provider_detected_at
        );
end;
$migration$;

comment on function public.record_anonymous_install(uuid, text, text, text, boolean) is
    'Upsert one anonymous install row. Callable by anon by design -- this is '
    'the only write path for users with no account. Validates and bounds every '
    'input; there is no read path for anon.';

revoke all on function public.record_anonymous_install(uuid, text, text, text, boolean)
    from public;
grant execute on function public.record_anonymous_install(uuid, text, text, text, boolean)
    to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Readout (owner only)
-- ---------------------------------------------------------------------------

create or replace function public.anonymous_activation_summary(
    p_days integer default 30
)
returns table (
    day               date,
    channel           text,
    installs          bigint,
    activated         bigint,
    activation_pct    numeric
)
language sql
security definer
set search_path = public, pg_temp
as $migration$
    select
        date_trunc('day', first_seen_at)::date as day,
        channel,
        count(*) as installs,
        count(*) filter (where first_provider_detected_at is not null) as activated,
        round(
            100.0 * count(*) filter (where first_provider_detected_at is not null)
            / nullif(count(*), 0),
            1
        ) as activation_pct
    from public.anonymous_installs
    where first_seen_at >= now() - make_interval(days => greatest(p_days, 1))
    group by 1, 2
    order by 1 desc, 2;
$migration$;

-- Owner-only readout. `anon` and `authenticated` are deliberately NOT granted:
-- aggregate counts of the whole install base are business data, and no client
-- needs them.
revoke all on function public.anonymous_activation_summary(integer)
    from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Retention
-- ---------------------------------------------------------------------------
--
-- 400 days: long enough for a year-over-year read, short enough that this never
-- becomes a permanent record of anything. The rows are already anonymous, so
-- this bounds the table rather than protecting identity.

create or replace function public.prune_anonymous_installs()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $migration$
declare
    v_deleted integer;
begin
    delete from public.anonymous_installs
    where last_seen_at < now() - interval '400 days';
    get diagnostics v_deleted = row_count;
    return v_deleted;
end;
$migration$;

revoke all on function public.prune_anonymous_installs()
    from public, anon, authenticated;

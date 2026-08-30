-- migrate_v0.76_activation_funnel.sql
--
-- Two more steps in the funnel, and the first locale column in the database.
--
-- WHY THIS EXISTS
-- ---------------
-- v0.73 records two facts: the app ran, and it later found a CLI. That ratio
-- answers "did first value happen?" and nothing about WHERE it stopped when it
-- did not. 79% of accounts sign up once and never return, and the 2026-07-25
-- activation investigation concluded the problem is first value rather than
-- churn -- but with two points on the line, every failure looks the same.
--
-- The chain a Mac install actually walks is:
--
--   app opened  ->  helper connected  ->  provider detected  ->  cost shown
--
-- Step 2 is the one nobody can currently see, and it is the step with the most
-- ways to fail in this codebase's own history: SMAppService registration bound
-- to a stale bundle path, a socket shadowed by a stale .pkg helper, a
-- LaunchAgent that died silently 22138 times over 11 days, TCC prompts that
-- never return. Every one of those presents to the user as "no providers", the
-- same as having no CLI installed at all, and today they are the same row.
--
-- Step 4 separates "found a CLI" from "had a number to show". They are not the
-- same event: a provider can be detected and still price at zero, which is
-- exactly what happened when `claude-opus-5` shipped and the fallback table
-- valued 15.4 billion tokens at $0.
--
-- THE LOCALE COLUMN
-- -----------------
-- There is currently NO locale, language, timezone, region or country column
-- anywhere in this schema -- verified by scanning information_schema, not
-- assumed. So "four of six shipped locales rendered raw dotted keys on the
-- first-run wizard" is a confirmed defect whose impact is not merely unproven
-- but unmeasurable. `ui_language` is the smallest column that makes it
-- measurable: does anyone run those locales, and do they activate worse?
--
-- It records the `.lproj` catalogue the app RESOLVED, not the user's preferred
-- languages. Those are different questions and only the first one is ours: a
-- French user resolves to `en`, and what that tells us is that they saw
-- English, which is the fact the funnel needs. Demand for languages we do not
-- ship is a separate question and does not get a column here on the way past.
--
-- WHAT IS STILL NOT COLLECTED
-- ---------------------------
-- Unchanged from v0.73, and the list is the point: no account, e-mail, device
-- name, hostname, serial, IP, file path, project name, provider credential,
-- token count, cost amount, or which provider was found. The three new fields
-- are two booleans-as-timestamps and one value from a seven-item closed set.
-- There is still no free-text column and still no read path for anon.
--
-- ORDERING -- READ THIS BEFORE APPLYING
-- -------------------------------------
-- `record_anonymous_install` is DROPPED and recreated with three additional
-- defaulted parameters. `create or replace` cannot add parameters: it would
-- create a second overload and every call would then be ambiguous.
--
-- Old clients keep working. PostgREST resolves by the names present in the
-- body, and the three new parameters have defaults, so a 5-key payload from a
-- shipped 1.52 binary still binds. New clients must tolerate the pre-migration
-- state as well -- see the PGRST202 fallback in
-- `SupabaseAnonymousTelemetryTransport`.
--
-- Grants do not survive a drop. They are re-granted below; a migration that
-- forgot that would leave the only write path for anonymous users closed, and
-- the failure would look exactly like "nobody installed the app".
--
-- PRE-APPLY CHECK (production function bodies drift; verify before replacing):
--   select md5(pg_get_functiondef(p.oid)), pg_get_function_identity_arguments(p.oid)
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.proname = 'record_anonymous_install';
-- Measured 2026-08-30, before this migration:
--   6f3bafa889c0757bd424cada74486b0c
--   (p_install_id uuid, p_channel text, p_app_version text, p_os_version text,
--    p_provider_detected boolean)
-- If that digest differs when you apply this, production has drifted from the
-- repo and this file is not what you think it is. Stop and diff first.

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------

alter table public.anonymous_installs
    add column if not exists helper_connected_at  timestamptz,
    add column if not exists first_cost_at        timestamptz,
    add column if not exists ui_language          text;

comment on column public.anonymous_installs.helper_connected_at is
    'First successful hello handshake with the local helper over UDS -- an '
    'observed round trip, not a launchd registration claim. Separates "no CLI '
    'installed" from "helper never came up", which look identical today.';

comment on column public.anonymous_installs.first_cost_at is
    'First time the app computed a non-zero cost for today. COMPUTED, not '
    'rendered: MenuBarExtra builds its content lazily, so a signal taken from '
    'a view would measure menu-opening instead. Same reasoning as the '
    'ProviderState subscription in AnonymousTelemetryCoordinator.';

comment on column public.anonymous_installs.ui_language is
    'The .lproj catalogue the app resolved -- one of en/es/ja/ko/zh-Hans/'
    'zh-Hant, or ''other''. Not the user''s preferred languages. The first '
    'locale column in this schema; before it, localization impact was '
    'unmeasurable rather than merely unproven.';

-- Rows written before this migration have all three NULL, which is honest:
-- NULL means "never reported", not "did not happen". Any readout must treat
-- pre-migration installs as unknown rather than as failures, or the funnel
-- will show a cliff on the day this deployed.
create index if not exists anonymous_installs_ui_language_idx
    on public.anonymous_installs (ui_language, first_seen_at desc)
    where ui_language is not null;

-- ---------------------------------------------------------------------------
-- Ingest -- drop and recreate, see ORDERING above
-- ---------------------------------------------------------------------------

-- Both signatures, so this migration is re-runnable. The 5-arg drop is the
-- upgrade path; the 8-arg drop is what makes a second apply a no-op instead of
-- "function already exists". `run_v073_anonymous_telemetry_tests.sh` applies
-- its migration twice on purpose -- a migration that only works on a database
-- that has never seen it cannot be re-run after a partial failure.
drop function if exists public.record_anonymous_install(uuid, text, text, text, boolean);
drop function if exists public.record_anonymous_install(uuid, text, text, text, boolean, boolean, boolean, text);

create function public.record_anonymous_install(
    p_install_id            uuid,
    p_channel               text,
    p_app_version           text,
    p_os_version            text,
    p_provider_detected     boolean default false,
    p_helper_connected      boolean default false,
    p_cost_shown            boolean default false,
    p_ui_language           text    default null
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
        ui_language
    )
    values (
        p_install_id, v_channel, v_app_version, v_os_version,
        case when p_provider_detected then now() else null end,
        case when p_helper_connected  then now() else null end,
        case when p_cost_shown        then now() else null end,
        v_language
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
        );
end;
$migration$;

comment on function public.record_anonymous_install(uuid, text, text, text, boolean, boolean, boolean, text) is
    'Upsert one anonymous install row. Callable by anon by design -- this is '
    'the only write path for users with no account. Validates and bounds every '
    'input; there is no read path for anon. The last three parameters are '
    'defaulted so a pre-v0.76 client still binds.';

-- Grants do NOT survive the drop above. Re-granting is what keeps the only
-- anonymous write path open.
revoke all on function public.record_anonymous_install(uuid, text, text, text, boolean, boolean, boolean, text)
    from public;
grant execute on function public.record_anonymous_install(uuid, text, text, text, boolean, boolean, boolean, text)
    to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Readout (owner only)
-- ---------------------------------------------------------------------------
--
-- A NEW function rather than a change to `anonymous_activation_summary`.
-- Postgres cannot alter a function's return type in place, so extending the
-- existing one would mean dropping it -- and a `drop`+`create` of a function
-- whose production body may have drifted is exactly the pattern that has
-- silently clobbered live definitions in this project before. The old readout
-- keeps working, unchanged and unqueried by this file.

create or replace function public.anonymous_funnel_summary(
    p_days integer default 30
)
returns table (
    day                date,
    channel            text,
    ui_language        text,
    installs           bigint,
    helper_connected   bigint,
    provider_detected  bigint,
    cost_shown         bigint
)
language sql
security definer
set search_path = public, pg_temp
as $migration$
    select
        date_trunc('day', first_seen_at)::date                          as day,
        channel,
        coalesce(ui_language, 'unreported')                             as ui_language,
        count(*)                                                        as installs,
        count(*) filter (where helper_connected_at is not null)         as helper_connected,
        count(*) filter (where first_provider_detected_at is not null)  as provider_detected,
        count(*) filter (where first_cost_at is not null)               as cost_shown
    from public.anonymous_installs
    where first_seen_at >= now() - make_interval(days => greatest(p_days, 1))
    group by 1, 2, 3
    order by 1 desc, 2, 3;
$migration$;

comment on function public.anonymous_funnel_summary(integer) is
    'Owner-only funnel readout: installs -> helper connected -> provider '
    'detected -> cost shown, split by channel and resolved UI language. Rows '
    'from before v0.76 report NULL for the new milestones; that is "never '
    'reported", not "did not happen", and a reader who forgets it will see a '
    'cliff on the day this deployed.';

-- Owner-only, same posture as `anonymous_activation_summary`: aggregate counts
-- of the whole install base are business data and no client needs them.
revoke all on function public.anonymous_funnel_summary(integer)
    from public, anon, authenticated;

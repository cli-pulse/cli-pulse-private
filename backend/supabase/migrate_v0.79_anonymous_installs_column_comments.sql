-- migrate_v0.79_anonymous_installs_column_comments.sql
--
-- Documentation only. No schema change, no data change.
--
-- WHY THIS IS WORTH A MIGRATION
-- -----------------------------
-- `anonymous_installs.last_seen_at` is a name that lies, and the lie is
-- load-bearing: on 2026-08-31 it nearly produced a nightly cron job that would
-- have deleted rows of ACTIVE installs, permanently.
--
-- It does not mean "the last time we saw this install". It means "the last
-- time a MILESTONE was reported", and there are only four milestones ever.
-- Each sits behind a persistent UserDefaults latch on the client —
-- `installReported`, `activationReported`, `helperConnectedReported`,
-- `costReported` — and each returns early once set
-- (`AnonymousInstallTelemetry.swift:380/407/434/460`). There is no heartbeat.
--
-- So a person using the app every day stops touching their row after the last
-- milestone, and `last_seen_at` freezes forever while they keep using it.
--
-- That matters because the row cannot come back. The client latches are on the
-- USER'S disk; deleting server-side does not clear them, so a deleted install
-- is permanently absent from every future read.
-- `backend/supabase/analysis/phase1_menu_open_to_provider.sql:49` records that
-- five installs were already lost this way by 2026-08-12, including the
-- owner's own Developer ID install.
--
-- The analysis file says all this. A migration file says it. Neither is
-- visible to someone inspecting the table in psql or the Supabase dashboard,
-- which is exactly where the mistake gets made — so it is said here too.

comment on table public.anonymous_installs is
    'One row per install of CLI Pulse, with no link to any account. Written '
    'only by record_anonymous_install(); readable only by service_role. '
    'DO NOT DELETE ROWS: the client''s "already reported" latches live in the '
    'user''s UserDefaults, so a deleted row is never re-sent and that install '
    'disappears from every future read. See migrate_v0.73 for the collection '
    'rationale and migrate_v0.79 for why last_seen_at cannot be used as a '
    'retention key.';

comment on column public.anonymous_installs.install_id is
    'Random v4 UUID generated on the client and stored in UserDefaults. Not '
    'derived from anything about the machine, and dies with an uninstall.';

comment on column public.anonymous_installs.first_seen_at is
    'When the install first reported. The only column here that means what a '
    'reader expects; it is set once and never updated.';

comment on column public.anonymous_installs.last_seen_at is
    'MISNAMED — NOT LIVENESS, AND NOT A SAFE RETENTION KEY. It is the last '
    'time a MILESTONE was reported, and there are only four, each behind a '
    'persistent client-side latch that returns early once set. There is no '
    'heartbeat, so an install in daily use stops touching this column after '
    'its last milestone and the value freezes. Pruning on it would delete '
    'ACTIVE installs, and they never come back (see the table comment). '
    'Before any retention job can use this, the client must refresh it on '
    'launch INDEPENDENTLY of the milestone latches — a touch, not a '
    'milestone — which is a client change, a shipped build, and a disclosure '
    'change, because per-launch reporting reveals usage frequency that the '
    'current consent text does not mention.';

comment on column public.anonymous_installs.channel is
    'mas | devid | brew | unknown. Which distribution channel this copy came '
    'from — the one question App Store Connect analytics cannot answer.';

comment on column public.anonymous_installs.app_version is
    'Marketing version only ("1.52.0"). No build number: it narrows the '
    'population without answering anything asked.';

comment on column public.anonymous_installs.os_version is
    'Major.minor only ("15.1"), coarsened on the client. A full OS build '
    'string is meaningfully identifying in a population this size.';

comment on column public.anonymous_installs.first_provider_detected_at is
    'First value: the app found a CLI and had a number to show. Write-once — '
    'the upsert coalesces so it never moves, or "time to first value" would '
    'decay into "time since last launch".';

-- Verification. `comment on` cannot fail loudly, so a typo'd column name would
-- error but a MISSING statement would not — check the ones that matter.
do $migration$
declare
    v_missing text;
begin
    select string_agg(a.attname, ', ')
    into v_missing
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
    where n.nspname = 'public' and c.relname = 'anonymous_installs'
      and col_description(c.oid, a.attnum) is null;

    if v_missing is not null then
        raise exception 'columns still undocumented: %', v_missing;
    end if;

    if obj_description('public.anonymous_installs'::regclass) not like '%DO NOT DELETE ROWS%' then
        raise exception 'the table comment lost its deletion warning';
    end if;
    if col_description('public.anonymous_installs'::regclass,
                       (select attnum from pg_attribute
                        where attrelid = 'public.anonymous_installs'::regclass
                          and attname = 'last_seen_at')) not like '%NOT LIVENESS%' then
        raise exception 'last_seen_at lost its misnaming warning';
    end if;

    raise notice 'v0.79: every column documented; deletion and last_seen_at warnings present';
end
$migration$;

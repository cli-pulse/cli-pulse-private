-- ============================================================
-- pgTAP — migrate_v0.73 anonymous install telemetry
-- ============================================================
-- OWNER-RUN (not CI): pgTAP is NOT installed in prod. Run AFTER applying
-- migrate_v0.73 against a BRANCH database as a privileged role. One
-- transaction, rolls back — no fixtures left behind.
--
--   create extension if not exists pgtap;
--   \i backend/supabase/tests/migrate_v0.73_anonymous_install_telemetry.test.sql
--
-- WHAT THIS PROVES — the security posture first, because this is the only RPC
-- in the schema callable by an UNAUTHENTICATED caller:
--   * anon may EXECUTE record_anonymous_install and may NOT read the table
--     (three independent denials: RLS on, zero policies, zero grants)
--   * anon may not read the owner-only summary or run the pruner
--   * every input is validated: an unknown channel, a junk app_version and a
--     junk os_version are REJECTED, not stored — so this cannot be used as
--     free-text storage by an anonymous caller
--   * the upsert is idempotent on install_id: replaying a call updates one row
--     instead of growing the table (the anti-abuse property)
--   * first_provider_detected_at is written ONCE and never overwritten — if a
--     later launch could move it, "time to first value" would silently decay
--     into "time since last launch", which is the metric bug that would make
--     this whole table lie
-- ============================================================

begin;
select plan(17);

-- ------------------------------------------------------------
-- Shape
-- ------------------------------------------------------------
select has_table('public', 'anonymous_installs', 'anonymous_installs exists');
select col_is_pk('public', 'anonymous_installs', 'install_id', 'install_id is the PK');
select has_function('public', 'record_anonymous_install',
    array['uuid','text','text','text','boolean'], 'ingest RPC exists');

-- ------------------------------------------------------------
-- Lockdown
-- ------------------------------------------------------------
select ok(
    (select relrowsecurity from pg_class
     where oid = 'public.anonymous_installs'::regclass),
    'RLS is enabled on anonymous_installs'
);

select is(
    (select count(*)::int from pg_policies
     where schemaname = 'public' and tablename = 'anonymous_installs'),
    0,
    'zero policies — deliberate: the SECURITY DEFINER RPC is the only door'
);

select ok(
    not has_table_privilege('anon', 'public.anonymous_installs', 'SELECT'),
    'anon cannot SELECT the table'
);
select ok(
    not has_table_privilege('anon', 'public.anonymous_installs', 'INSERT'),
    'anon cannot INSERT into the table directly'
);
select ok(
    not has_table_privilege('authenticated', 'public.anonymous_installs', 'SELECT'),
    'a signed-in user cannot read the table either'
);

select ok(
    has_function_privilege('anon',
        'public.record_anonymous_install(uuid,text,text,text,boolean)', 'EXECUTE'),
    'anon CAN execute the ingest RPC — the whole point'
);
select ok(
    not has_function_privilege('anon',
        'public.anonymous_activation_summary(integer)', 'EXECUTE'),
    'anon cannot read the aggregate summary'
);
select ok(
    not has_function_privilege('anon',
        'public.prune_anonymous_installs()', 'EXECUTE'),
    'anon cannot run the pruner'
);

-- ------------------------------------------------------------
-- Input validation — reject, never store
-- ------------------------------------------------------------
select throws_ok(
    $$select public.record_anonymous_install(
        '11111111-1111-1111-1111-111111111111'::uuid,
        'definitely-not-a-channel', '1.44.0', '15.1')$$,
    '22023',
    NULL,
    'an unrecognised channel is rejected, not filed under unknown'
);

select throws_ok(
    $$select public.record_anonymous_install(
        '11111111-1111-1111-1111-111111111111'::uuid,
        'mas', 'not-a-version; drop table x', '15.1')$$,
    '22023',
    NULL,
    'a junk app_version is rejected — this column is not free text'
);

select throws_ok(
    $$select public.record_anonymous_install(
        '11111111-1111-1111-1111-111111111111'::uuid,
        'mas', '1.44.0', '15.1.1-custom-build-string')$$,
    '22023',
    NULL,
    'a junk os_version is rejected'
);

-- ------------------------------------------------------------
-- Idempotence and the write-once timestamp
-- ------------------------------------------------------------
select public.record_anonymous_install(
    '22222222-2222-2222-2222-222222222222'::uuid, 'devid', '1.44.0', '15.1', false);
select public.record_anonymous_install(
    '22222222-2222-2222-2222-222222222222'::uuid, 'devid', '1.44.0', '15.1', false);
select public.record_anonymous_install(
    '22222222-2222-2222-2222-222222222222'::uuid, 'devid', '1.45.0', '15.2', false);

select is(
    (select count(*)::int from public.anonymous_installs
     where install_id = '22222222-2222-2222-2222-222222222222'),
    1,
    'three calls with one install_id produce exactly one row'
);

-- Activate, then launch again. The timestamp must not move.
--
-- This is the assertion the table's usefulness rests on. If a later launch
-- could overwrite first_provider_detected_at, then "time to first value"
-- silently becomes "time since last launch" — the metric would still populate,
-- still look plausible, and be wrong in the direction that flatters us.
select public.record_anonymous_install(
    '22222222-2222-2222-2222-222222222222'::uuid, 'devid', '1.45.0', '15.2', true);

select ok(
    (select first_provider_detected_at is not null
     from public.anonymous_installs
     where install_id = '22222222-2222-2222-2222-222222222222'),
    'activation is recorded when the client reports it'
);

create temp table v073_first_activation on commit drop as
select first_provider_detected_at as ts
from public.anonymous_installs
where install_id = '22222222-2222-2222-2222-222222222222';

-- Two more launches that also report activation. A naive `excluded.` assignment
-- would move the timestamp on each one.
select public.record_anonymous_install(
    '22222222-2222-2222-2222-222222222222'::uuid, 'devid', '1.45.0', '15.2', true);
select public.record_anonymous_install(
    '22222222-2222-2222-2222-222222222222'::uuid, 'devid', '1.45.0', '15.2', true);

select is(
    (select first_provider_detected_at from public.anonymous_installs
     where install_id = '22222222-2222-2222-2222-222222222222'),
    (select ts from v073_first_activation),
    'first_provider_detected_at is written once and never overwritten'
);

rollback;

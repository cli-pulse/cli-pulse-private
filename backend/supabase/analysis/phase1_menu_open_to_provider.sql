-- phase1_menu_open_to_provider.sql
--
-- READ-ONLY. Not a migration, not a function, consumes no migration number.
-- Run against production with the service role -- the table grants nothing to
-- anon or authenticated by design (see migrate_v0.73).
--
-- Every query below was executed against production on 2026-08-12 and the
-- negative controls in section 4 were confirmed to FIRE on synthetic input,
-- not merely to pass on real input.
--
-- WHY THIS FILE EXISTS RATHER THAN A CALL TO anonymous_activation_summary()
-- -------------------------------------------------------------------------
-- `anonymous_activation_summary(p_days)` groups by `day, channel` and selects
-- no `app_version` at all. It also applies no maturity window, so it counts an
-- install that first reported ten minutes ago as a failed activation. It
-- cannot express the cohort Phase 1 needs.
--
-- Verified against the LIVE function body (pg_get_functiondef, 2026-08-12):
-- the deployed definition matches the migration byte for byte. This is a
-- limitation of the helper, not production drift.
--
-- WHAT THE NUMBER MEANS -- say this in full or do not quote it
-- ------------------------------------------------------------
--   Among installs that opened the menu bar popover, acknowledged the
--   disclosure card, left telemetry enabled, were not in local-only mode, and
--   completed at least one successful network send -- what fraction ever
--   produced a non-empty provider list?
--
-- That is a MENU-OPEN -> PROVIDER funnel. It is not install -> value, and it
-- must never be called "activation rate" unqualified. The denominator is
-- structurally invisible above the disclosure card: a menu bar app has no
-- window at launch, so someone who never opens the menu sends nothing at all
-- and never appears in this table.
--
-- Being signed in, or having chosen local mode, is NOT a denominator
-- qualifier. `install` is reported before either choice exists. Conditioning
-- those away would erase the onboarding failure this metric exists to reveal.
--
-- FIVE TRAPS, ALL LOAD-BEARING
-- ----------------------------
--  1. `app_version` IS MUTABLE. The upsert does
--     `app_version = excluded.app_version`, so a 1.45 install that later
--     updates reports as 1.47. Cohort by `first_seen_at`, NEVER by version.
--     The version columns below are diagnostics, labelled as such.
--  2. iOS CONTRIBUTES NOTHING. `AnonymousTelemetryCoordinator` is constructed
--     only in `CLIPulseBarApp` (macOS); `CLI Pulse Bar iOS` contains no
--     reference to it. The iOS 1.47 approval date is irrelevant to this table
--     -- do not add it to the availability list and do not wait on it.
--  3. A DELETED ROW IS GONE FOREVER, NOT RE-SENT. `installReported` and
--     `activationReported` are client-side UserDefaults latches set only on a
--     2xx. Deleting a row server-side does not clear them, so that install is
--     permanently absent from every future read. As of 2026-08-12
--     pg_stat_user_tables reports 7 inserts / 5 deletes / 2 live rows: five
--     installs were already removed this way, including the owner's own
--     Developer ID install (id 01784A9A..., both latches still true on disk).
--     DO NOT DELETE ROWS FROM THIS TABLE.
--  4. A NON-ACTIVATED ROW IS NOT EVIDENCE OF ANYTHING ON ITS OWN. See 4c.
--  5. `last_seen_at` IS NOT A LIVENESS SIGNAL, and for a non-activated install
--     it is FROZEN AT INSTALL TIME FOREVER. It advances only on an upsert, an
--     upsert happens only on a SEND, and the client sends exactly twice ever:
--     `install`, then `first_provider_detected`. Both are latched in
--     UserDefaults (trap 3). So an install that has relaunched a hundred times
--     and never found a CLI is byte-identical to one that ran once and was
--     deleted the same hour.
--     Verified 2026-08-18: `count(*) where last_seen_at <> first_seen_at` is
--     **0** across the whole table, and `AnonymousInstallTelemetry` has no code
--     path that sends a third time.
--     Consequence, which this file itself got wrong until then: any predicate
--     of the form `last_seen_at = first_seen_at AND first_provider_detected_at
--     IS NULL` is TAUTOLOGICAL -- it selects every non-activated row and
--     discriminates nothing. Whether an install relaunched is simply NOT
--     OBSERVABLE here. Do not write a query that claims otherwise, and do not
--     add one to `prune_anonymous_installs()`' 400-day window either: that
--     window is "400 days since we last heard from them", which for a
--     non-activated install means 400 days since INSTALL.
--
-- CONSTRUCT VALIDITY -- what `providers.isEmpty == false` actually proves
-- ----------------------------------------------------------------------
-- The activation event is driven by a Combine subscription on
-- `ProviderState.$providers`, whose only production writer is
-- `AppState.applyRefreshPayload` <- `DataRefreshManager` merged provider list.
-- That merge includes cloud-synced rows, so for a SIGNED-IN user the list can
-- go non-empty from data collected on a DIFFERENT machine. "Reached a
-- provider" therefore means "had a number to show", not "detected a CLI on
-- this machine". The two diverge exactly for multi-Mac signed-in users.

-- ===========================================================================
-- 1. Stage-by-stage attrition -- RUN THIS FIRST, ALWAYS
-- ===========================================================================
--
-- A single cohort count can read zero for at least five different reasons, and
-- "0 rows" is an empty conclusion, not a finding. This attributes the zero.

with availability(channel, available_from) as (
    -- Per-channel 1.47 availability. An install whose FIRST report predates
    -- its channel's 1.47 cannot be trusted for activation, because #418
    -- suppressed the activation event on the one launch that shows the
    -- disclosure card. Deliberately a visible VALUES list, not a buried
    -- constant -- edit it when a later version supersedes the cohort.
    values ('devid', timestamptz '2026-08-08 00:00:00+00'),
           ('brew',  timestamptz '2026-08-08 00:00:00+00'),
           ('mas',   timestamptz '2026-08-10 00:00:00+00')
),
classified as (
    select i.*,
           a.channel is null                                    as unknown_channel,
           a.available_from is not null
               and i.first_seen_at >= a.available_from          as post_147,
           i.first_seen_at <= now() - make_interval(days => 7)  as matured
    from public.anonymous_installs i
    left join availability a on a.channel = i.channel
)
select stage, stage_name, rows, note from (
    values
      (1, 'all rows in table',
          (select count(*) from classified),
          'total ever recorded, MINUS ANY DELETED -- cross-check against 4d'),
      (2, 'channel recognised',
          (select count(*) from classified where not unknown_channel),
          'a drop here means the availability VALUES list is stale'),
      (3, 'first_seen_at >= channel 1.47 availability',
          (select count(*) from classified where post_147),
          'excludes installs whose activation #418 could have suppressed'),
      (4, 'AND matured >= 7 days',
          (select count(*) from classified where post_147 and matured),
          'ELIGIBLE COHORT -- late activation is not miscounted as failure'),
      (5, 'eligible AND activated',
          (select count(*) from classified where post_147 and matured
             and first_provider_detected_at is not null),
          'numerator')
) as t(stage, stage_name, rows, note)
order by stage;

-- ===========================================================================
-- 2. The cohort read, with the predeclared gate
-- ===========================================================================
--
-- The verdict column is the point. Reading the percentage descriptively before
-- the gate is fine; making a product decision from it is not.
--
--   ~100 mature rows -> +/-10 pp
--   ~355 mature rows -> +/-5 pp
--   a per-channel split needs its own N, never a share of the total

with availability(channel, available_from) as (
    values ('devid', timestamptz '2026-08-08 00:00:00+00'),
           ('brew',  timestamptz '2026-08-08 00:00:00+00'),
           ('mas',   timestamptz '2026-08-10 00:00:00+00')
),
eligible as (
    select i.*
    from public.anonymous_installs i
    join availability a on a.channel = i.channel
    where i.first_seen_at >= a.available_from
      and i.first_seen_at <= now() - make_interval(days => 7)
),
rolled as (
    select coalesce(channel, 'ALL CHANNELS') as channel,
           channel is null                   as is_total,
           count(*)                          as cohort_n,
           count(*) filter (where first_provider_detected_at is not null) as reached_provider,
           round(100.0 * count(*) filter (where first_provider_detected_at is not null)
                 / nullif(count(*), 0), 1)   as pct_menu_open_to_provider
    from eligible
    group by rollup (channel)
)
select channel,
       cohort_n,
       reached_provider,
       pct_menu_open_to_provider,
       case
           when not is_total then 'per-channel split needs its own N, not a share of the total'
           when cohort_n = 0   then 'NO DATA -- run section 1 to find which stage dropped the rows'
           when cohort_n < 100 then 'BELOW GATE (n<100) -- descriptive only, NO product decision'
           when cohort_n < 355 then 'gate met at ~+/-10pp -- +/-5pp needs ~355'
           else                     'gate met at ~+/-5pp'
       end as verdict
from rolled
order by is_total, channel;

-- ===========================================================================
-- 3. Escape-hatch clock
-- ===========================================================================
--
-- Predeclared: if fewer than 100 eligible mature rows arrive within 30 days of
-- the last channel's 1.47 availability, STOP WAITING. The finding is
-- "insufficient observable acquisition", and the next task is external
-- denominator reconciliation plus a qualitative onboarding study -- not more
-- waiting. Deadline below is computed, not remembered.

with availability(channel, available_from) as (
    values ('devid', timestamptz '2026-08-08 00:00:00+00'),
           ('brew',  timestamptz '2026-08-08 00:00:00+00'),
           ('mas',   timestamptz '2026-08-10 00:00:00+00')
)
select max(available_from)                            as last_channel_live,
       max(available_from) + interval '30 days'       as stop_waiting_on,
       greatest(0, extract(day from
           max(available_from) + interval '30 days' - now())::int) as days_remaining,
       case when now() >= max(available_from) + interval '30 days'
            then 'DEADLINE PASSED -- switch to external denominator reconciliation'
            else 'still inside the waiting window' end as verdict
from availability;

-- ===========================================================================
-- 4. Negative controls -- these must be CHECKED, not assumed
-- ===========================================================================
--
-- Every defect this project shipped in 2026 was a status signal that was green
-- and lying. A cohort query returning a clean number while silently dropping
-- rows is the same failure in a new costume. Section 4e proves each control
-- still fires; run it whenever you touch the predicates above.

-- 4a. Rows whose channel is not in the availability list. Expected: 0 rows.
--     Non-zero means section 2 is silently under-counting.
select 'unlisted channel' as control,
       channel, count(*) as rows,
       'expected 0 -- non-zero means section 2 silently drops these' as expectation
from public.anonymous_installs
where channel not in ('devid', 'brew', 'mas')
group by channel;

-- 4b. Eligible rows still reporting a pre-1.47 CURRENT version. A hit means
--     someone installed an old artefact after 1.47 shipped (stale GitHub
--     asset, stale cask) and may still carry #418.
--
--     The version array is PADDED to three components. The naive comparison
--     `string_to_array(v,'.')::int[] < array[1,47,0]` reports "1.47" as
--     pre-1.47, because a shorter array sorts before its own prefix. Confirmed
--     wrong on 2026-08-12; do not simplify this back.
select 'pre-1.47 artefact after cutover' as control,
       i.install_id, i.channel, i.app_version, i.first_seen_at,
       'app_version is MUTABLE -- this is current, not first-seen' as caveat
from public.anonymous_installs i
join (values ('devid', timestamptz '2026-08-08 00:00:00+00'),
             ('brew',  timestamptz '2026-08-08 00:00:00+00'),
             ('mas',   timestamptz '2026-08-10 00:00:00+00')) a(channel, available_from)
  on a.channel = i.channel
where i.first_seen_at >= a.available_from
  and (string_to_array(i.app_version, '.')::int[] || array[0,0,0])[1:3] < array[1,47,0];

-- 4c. Non-activated installs. A row here is AMBIGUOUS and must not be reported
--     as a first-value failure: it is equally consistent with #418 suppression
--     on a 1.45 client, with a genuine "no CLI on this machine", and with the
--     app having been deleted within the hour. Nothing in this table separates
--     them.
--
--     This used to be titled "installs that have never relaunched" and carried
--     an extra `last_seen_at = first_seen_at` conjunct. Both were wrong: by
--     trap 5 that conjunct is true for EVERY non-activated row, so it filtered
--     nothing while asserting a fact about relaunch behaviour that this table
--     cannot observe. The verdict (AMBIGUOUS) survived; the reasoning behind it
--     did not, which is the more dangerous kind of error -- a reader would have
--     acted on "never relaunched".
select 'not activated' as control,
       install_id, channel, app_version, os_version, first_seen_at,
       'AMBIGUOUS: #418 suppression vs no-provider vs deleted -- do not classify'
         as reading,
       'relaunch behaviour is NOT observable here -- see trap 5' as caveat
from public.anonymous_installs
where first_provider_detected_at is null;

-- 4d. Write history. Deletions are invisible in the table itself and
--     permanently remove an install from all future reads (trap 3).
select 'write history' as control,
       n_tup_ins as inserts, n_tup_upd as updates, n_tup_del as deletes,
       n_live_tup as live_rows,
       n_tup_ins - n_tup_del as expected_live,
       case when n_tup_ins - n_tup_del = n_live_tup
            then 'reconciles'
            else 'MISMATCH -- investigate before reading any percentage' end as verdict
from pg_stat_user_tables
where relname = 'anonymous_installs';

-- 4e. Proof the controls above are alive. Feeds synthetic rows through the
--     SAME predicates without touching the table. Every count must be >= 1; a
--     zero means that control is dead and would never fire on real data.
with synthetic(install_id, channel, app_version, first_seen_at, last_seen_at, first_provider_detected_at) as (
    values ('11111111-1111-4111-8111-111111111111'::uuid, 'unknown', '1.47.0',
            now() - interval '9 days', now(),                    null::timestamptz),
           ('22222222-2222-4222-8222-222222222222'::uuid, 'mas',     '1.45.0',
            now() - interval '9 days', now(),                    null::timestamptz),
           ('33333333-3333-4333-8333-333333333333'::uuid, 'mas',     '1.47.0',
            now() - interval '9 days', now() - interval '9 days', null::timestamptz),
           ('44444444-4444-4444-8444-444444444444'::uuid, 'devid',   '1.47.0',
            now() - interval '9 days', now(),                    now())
)
-- NOTE ON THE SHAPES ABOVE. Rows 1 and 2 carry `last_seen_at = now()` with a
-- NULL `first_provider_detected_at`. Trap 5 says production can never emit
-- that: a non-activated install sends exactly once, so its `last_seen_at`
-- equals `first_seen_at`. They are kept deliberately, as ILLEGAL shapes that
-- exercise 4a and 4b, and they are the reason the old 4c control looked alive
-- when it was tautological -- it "discriminated" only against rows reality
-- does not produce. Never add a control whose only negative examples are
-- impossible.
select
  (select count(*) from synthetic
    where channel not in ('devid','brew','mas'))                            as ctl_4a_unlisted_channel,
  (select count(*) from synthetic s
     join (values ('devid', now() - interval '30 days'),
                  ('brew',  now() - interval '30 days'),
                  ('mas',   now() - interval '30 days')) a(channel, af)
       on a.channel = s.channel
    where s.first_seen_at >= a.af
      and (string_to_array(s.app_version,'.')::int[] || array[0,0,0])[1:3]
          < array[1,47,0])                                                  as ctl_4b_stale_artefact,
  (select count(*) from synthetic
    where first_provider_detected_at is null)                               as ctl_4c_not_activated,
  'each must be >= 1, or that control is dead' as expectation;

-- 4f. TAUTOLOGY GUARD, run against the LIVE table rather than synthetic rows.
--
--     A predicate that selects every row discriminates nothing, however
--     confident its label. 4c carried exactly such a conjunct for months and
--     the synthetic check above could not see it, because the synthetic rows
--     included shapes production cannot emit.
--
--     This asks the only question that matters: does adding the
--     `last_seen_at` conjunct change what is selected? If not, it is inert and
--     any query using it is asserting something the data does not support.
--     `resent_rows` is the same fact from the other side -- it must stay 0
--     until the client is changed to send more than twice.
select 'tautology guard: last_seen_at' as control,
       (select count(*) from public.anonymous_installs
         where first_provider_detected_at is null)                as without_conjunct,
       (select count(*) from public.anonymous_installs
         where first_provider_detected_at is null
           and last_seen_at = first_seen_at)                      as with_conjunct,
       (select count(*) from public.anonymous_installs
         where last_seen_at <> first_seen_at)                     as resent_rows,
       -- TWO outcomes, not three. A first draft had an `else 'UNEXPECTED -- the
       -- conjunct filtered something'` arm; a negative control over synthetic
       -- populations showed it is UNREACHABLE BY CONSTRUCTION. For the conjunct
       -- to filter a non-activated row, that row must have
       -- `last_seen_at <> first_seen_at`, which makes `resent_rows > 0` and
       -- takes the first arm every time. A branch that can never fire is the
       -- mirror image of the tautology this guard exists to catch, so it is
       -- gone rather than left to reassure someone.
       case
         when (select count(*) from public.anonymous_installs
                where last_seen_at <> first_seen_at) > 0
           then 'CLIENT NOW RE-SENDS -- trap 5 is stale, re-read it before using last_seen_at'
         else 'INERT as expected -- last_seen_at adds nothing, per trap 5'
       end as verdict;

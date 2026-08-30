-- migrate_v0.78_unschedule_swarm_alert_eval.sql
--
-- Stop a per-minute cron job for a feature that was retired in v1.52.1.
--
-- `swarm_alert_eval` calls `_evaluate_swarm_alerts_internal()`, whose first
-- statement is
--
--     select user_id, swarms from public.remote_swarms
--     where updated_at > now() - interval '90 seconds'
--
-- `remote_swarms` has 0 rows and no producer on any shipped helper — the Swarm
-- tab was hidden precisely because nothing writes it. So the loop body has
-- never executed and cannot: 1440 no-op queries a day, forever.
--
-- UNSCHEDULED, NOT DROPPED. The function and its table stay, so re-enabling is
-- one `cron.schedule` call. Same posture as the rest of the retirement: stop
-- the behaviour, keep the code, decide about deletion separately.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES **NOT** DO
-- ------------------------------------------------
-- An earlier draft also scheduled `prune_anonymous_installs()`, on the grounds
-- that v0.73 promised a 400-day retention bound and never scheduled it. That
-- was WRONG and the draft is not merely deferred, it is refuted. Two reasons,
-- the second of which is already written down in this repository:
--
--   1. `last_seen_at` IS NOT LIVENESS. Every client path that would refresh it
--      is behind a persistent UserDefaults latch — `installReported`,
--      `activationReported`, `helperConnectedReported`, `costReported` — and
--      each returns early once set (`AnonymousInstallTelemetry.swift:380,407,
--      434,460`). There is no heartbeat. So a CONTINUOUSLY USED install stops
--      touching the row after its last milestone, and 400 days later a prune
--      would delete it.
--
--   2. IT WOULD NOT COME BACK. `backend/supabase/analysis/
--      phase1_menu_open_to_provider.sql:49` already says this in capitals:
--      "A DELETED ROW IS GONE FOREVER, NOT RE-SENT ... DO NOT DELETE ROWS FROM
--      THIS TABLE." It records that five installs had already been lost this
--      way by 2026-08-12, including the owner's own Developer ID install,
--      whose latches remain true on disk.
--
-- So scheduling that job would have quietly shrunk the very install base this
-- table exists to measure, and the draft's comment claiming "a still-active
-- install is never pruned" was an assumption stated as a fact. (Codex review,
-- 2026-08-31.)
--
-- THE PREREQUISITE, if the retention bound is ever to be honoured: the client
-- must refresh `last_seen_at` on launch INDEPENDENTLY of the milestone latches
-- — a touch, not a milestone. Only then does `last_seen_at` mean what a prune
-- needs it to mean. That is a client change plus a shipped build, and it must
-- land before any prune is scheduled.
--
-- SCHEDULE SYNTAX -- this project's pg_cron accepts ONLY a 5-field cron
-- expression or '[1-59] seconds'; 'N minutes' is rejected (v0.49 failed on it).

do $migration$
begin
    -- Idempotent: only unschedule when it is actually there, so a re-run is a
    -- no-op rather than an error. Verified empirically that
    -- `perform f() where exists (...)` does NOT evaluate f() when the
    -- condition is false.
    perform cron.unschedule('swarm_alert_eval')
    where exists (select 1 from cron.job where jobname = 'swarm_alert_eval');
end
$migration$;

-- ---------------------------------------------------------------------------
-- Verification. A cron change that silently did nothing looks identical to one
-- that worked.
-- ---------------------------------------------------------------------------

do $migration$
begin
    if exists (select 1 from cron.job where jobname = 'swarm_alert_eval') then
        raise exception 'swarm_alert_eval is still scheduled';
    end if;

    -- Positive control: everything else is untouched. Without it, a migration
    -- that emptied cron.job entirely would satisfy the check above.
    if (select count(*) from cron.job
        where jobname in ('cleanup_expired_data_nightly', 'retention_cleanup_nightly',
                          'remote_retention_cleanup_nightly', 'app_push_jobs_drain',
                          'm10_send_due_notifications', 'process_webhook_jobs',
                          'remote_swarms_cleanup_nightly', 'widget_refresh_hourly')) <> 8 then
        raise exception 'an unrelated cron job went missing';
    end if;

    raise notice 'v0.78: swarm_alert_eval unscheduled; the other 8 jobs are intact';
end
$migration$;

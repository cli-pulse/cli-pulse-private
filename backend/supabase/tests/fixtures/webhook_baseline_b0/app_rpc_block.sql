-- FROZEN COPY. Never edit. B0's app_rpc.sql webhook worker block exactly as merged (see run_webhook_baseline_tests.sh, part A).
-- ── Webhook queue worker (B0: transcribed unchanged from production's history) ──
-- process_webhook_jobs() is migrate_v0.25_sessions_alerts_hardening.sql's body,
-- followed by migrate_v0.62's revoke. The queue table, its indexes, policy and
-- the enqueue trigger are in schema.sql. Not here by design: the pg_cron job
-- that calls it and the vault secrets it reads (environment, not schema).
-- Behaviour changes belong to later migrations; do not "improve" this copy.
-- Cron worker. Runs on a schedule; drains pending jobs in two passes:
--   1. Reconcile: for jobs already dispatched (pg_net_request_id set,
--      processed_at null), look up `net._http_response` and finalize.
--      2xx → mark processed_at; non-2xx → bump attempt_count + last_error.
--   2. Dispatch: for jobs not yet dispatched (pg_net_request_id null and
--      attempt_count < 3), call `net.http_post`, capture the request_id,
--      and stamp dispatched_at.
--
-- Iter2 follow-up (Codex): the prior implementation marked processed_at
-- right after `http_post` returned, but pg_net is itself async — that
-- recorded "queued for dispatch", not "delivered". Now we read
-- net._http_response and only finalize after the actual HTTP call
-- completes. Jobs older than 5 minutes with no response are
-- considered timed out and retried.
--
-- Iter2 follow-up (deploy-time): Supabase managed Postgres doesn't allow
-- non-superuser ALTER DATABASE for `app.*` GUCs, so the original plan to
-- store secrets via `current_setting` failed at deploy. Switched to the
-- supabase_vault path, which is the recommended secret store for pg_cron
-- workers per Supabase docs. Operators must populate two named secrets
-- before this function works (otherwise it logs a notice and returns):
--
--   select vault.create_secret('https://<ref>.supabase.co', 'app_supabase_url', 'desc');
--   select vault.create_secret('<service_role_jwt>',         'app_service_role_key', 'desc');
create or replace function public.process_webhook_jobs()
returns void as $$
declare
  v_job record;
  v_url text;
  v_key text;
  v_request_id bigint;
begin
  -- Read URL + service-role key from supabase_vault. `decrypted_secret` is
  -- only readable by service_role / postgres; the cron worker runs as the
  -- function owner (postgres) so this resolves at runtime.
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'app_supabase_url';
  select decrypted_secret into v_key
  from vault.decrypted_secrets where name = 'app_service_role_key';
  if v_url is null or v_key is null or v_url = '' or v_key = '' then
    raise notice 'process_webhook_jobs: vault secrets app_supabase_url / app_service_role_key not set; skipping';
    return;
  end if;

  -- Pass 1: reconcile dispatched jobs against net._http_response.
  -- net._http_response.status_code is null while pending, populated on
  -- completion. Status 200..299 is success; anything else is recorded
  -- and may be retried on the next pass.
  for v_job in
    select id, pg_net_request_id, attempt_count
    from public.webhook_jobs
    where processed_at is null
      and pg_net_request_id is not null
      and dispatched_at < now() - interval '2 seconds'
    order by id
    limit 200
  loop
    declare
      v_status int;
      v_body text;
    begin
      select status_code, content
      into v_status, v_body
      from net._http_response
      where id = v_job.pg_net_request_id;

      if v_status is null then
        -- Still pending in pg_net. If it's been pending >5 min, give up
        -- this attempt and let the next pass dispatch a fresh one.
        update public.webhook_jobs
          set last_error = 'pg_net response not yet available',
              -- only retry-eligible after the timeout window
              pg_net_request_id = case
                when dispatched_at < now() - interval '5 minutes'
                then null else pg_net_request_id end
          where id = v_job.id;
      elsif v_status between 200 and 299 then
        update public.webhook_jobs
          set processed_at = now(),
              last_error = null
          where id = v_job.id;
      else
        update public.webhook_jobs
          set attempt_count = attempt_count + 1,
              last_error = 'HTTP ' || v_status::text || ': ' || coalesce(left(v_body, 200), ''),
              -- clear request_id so the next pass can re-dispatch
              pg_net_request_id = null,
              dispatched_at = null
          where id = v_job.id;
      end if;
    exception when others then
      -- Reconcile failure shouldn't poison the loop. Log and move on.
      raise warning 'process_webhook_jobs reconcile (job %): %', v_job.id, sqlerrm;
    end;
  end loop;

  -- Pass 2: dispatch new jobs. enqueued_at < now() - 5s gives the
  -- alert-insert xact time to commit before the cron worker reads.
  for v_job in
    select id, user_id, alert_id, alert_payload
    from public.webhook_jobs
    where processed_at is null
      and pg_net_request_id is null
      and attempt_count < 3
      and enqueued_at < now() - interval '5 seconds'
    order by id
    limit 100
  loop
    begin
      -- iter2 follow-up (Codex bot review on PR #6): pg_net exposes
      -- its request API as `net.http_post`, not `extensions.http_post`.
      -- Calling the wrong schema raises `function does not exist`, which
      -- the EXCEPTION block then silently swallowed — no requests ever
      -- got dispatched. `net` is already in this function's search_path.
      v_request_id := net.http_post(
        url := v_url || '/functions/v1/send-webhook',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_key,
          'X-Internal-Trigger', 'alerts_dispatch_webhook'
        ),
        body := jsonb_build_object(
          'user_id', v_job.user_id,
          'alert', v_job.alert_payload
        ),
        timeout_milliseconds := 5000
      );
      update public.webhook_jobs
        set pg_net_request_id = v_request_id,
            dispatched_at = now(),
            attempt_count = attempt_count + 1,
            last_error = null
        where id = v_job.id;
    exception when others then
      update public.webhook_jobs
        set attempt_count = attempt_count + 1,
            last_error = 'http_post failed: ' || sqlerrm
        where id = v_job.id;
    end;
  end loop;
end;
$$ language plpgsql security definer set search_path = pg_catalog, extensions, public, net;

revoke execute on function public.process_webhook_jobs() from PUBLIC, anon, authenticated;

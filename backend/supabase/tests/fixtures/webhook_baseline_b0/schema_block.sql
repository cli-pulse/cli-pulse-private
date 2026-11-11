-- FROZEN COPY. Never edit. B0's schema.sql webhook block exactly as merged (see run_webhook_baseline_tests.sh, part A).
-- ── Webhook queue (B0: transcribed unchanged from production's history) ──
-- Source: migrate_v0.25_sessions_alerts_hardening.sql (table, indexes, RLS,
-- trigger function, trigger), with the policy in migrate_v0.55's initplan
-- form. The worker, process_webhook_jobs(), is in app_rpc.sql. Nothing here
-- is changed from production; the comments are v0.25's, kept so the function
-- body stays byte-identical to it (the claim below that an expression-based
-- ON CONFLICT is impossible is v0.25's historical commentary, not endorsed:
-- PostgreSQL accepts a conflict target with a predicate for partial indexes).
-- Not here by design: pg_net, the pg_cron job and the vault secrets, which
-- are environment, not schema. Behaviour changes belong to later migrations.

-- Queue table. The unique partial index acts as a 60-second dedup window
-- for the (user_id, grouping_key) pair while a row is still pending —
-- this catches the rollout-period overlap where old macOS clients still
-- POST to send-webhook directly while the new trigger also enqueues.
create table if not exists public.webhook_jobs (
  id              bigserial primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  alert_id        text not null,
  alert_payload   jsonb not null,
  enqueued_at     timestamptz not null default now(),
  -- iter2 follow-up (Codex): pg_net.http_post is itself async. We need a
  -- request_id handle so a later cron pass can join net._http_response
  -- and decide whether the request actually succeeded. Without this,
  -- "processed_at = now()" right after http_post() means "queued in
  -- pg_net" not "delivered to webhook target".
  pg_net_request_id bigint,
  dispatched_at   timestamptz,
  processed_at    timestamptz,
  attempt_count   int not null default 0,
  last_error      text
);

-- Pending-job dedup: at most one un-processed job per (user, grouping_key).
-- Rapid duplicates within the worker's 30s drain window collapse here.
create unique index if not exists idx_webhook_jobs_pending_dedup
  on public.webhook_jobs (user_id, (alert_payload->>'grouping_key'))
  where processed_at is null;

-- Drain order index for the cron worker.
create index if not exists idx_webhook_jobs_pending_enqueued
  on public.webhook_jobs (enqueued_at)
  where processed_at is null;

-- RLS: only service role reads the queue. Edge functions and pg_cron
-- both run with service role; users never query webhook_jobs directly.
-- (Policy in migrate_v0.55's initplan form.)
alter table public.webhook_jobs enable row level security;
create policy "Service role only"
  on public.webhook_jobs for all
  using ((select auth.role()) = 'service_role'::text)
  with check ((select auth.role()) = 'service_role'::text);

-- Trigger function. Runs as security definer so it can write into
-- webhook_jobs regardless of caller. Postgres `AFTER INSERT FOR EACH ROW`
-- triggers do NOT fire for the UPDATE branch of an `INSERT ... ON CONFLICT
-- DO UPDATE`, so we don't need an xmax guard — Codex's review caught that
-- the v1-plan guard was dead code.
--
-- We deliberately exclude `Test` rows so the test-webhook flow (which
-- inserts a fake AlertRecord through the JWT path) can still validate a
-- user's URL without enqueueing a real fan-out.
--
-- search_path is the minimum needed: pg_catalog for built-ins, public
-- for the table itself. extensions and net are not referenced here.
create or replace function public.alerts_enqueue_webhook()
returns trigger as $$
begin
  if NEW.type is null or NEW.type = 'Test' then
    return NEW;
  end if;
  -- Iter2 follow-up (Codex + Gemini both flagged): Postgres rejects
  -- `on conflict on constraint <partial-unique-index-name>` because a
  -- partial unique index is NOT a constraint. The right form for a
  -- partial unique index is `on conflict (cols) where <predicate>`,
  -- which Postgres matches against the index. We can't reference the
  -- jsonb expression directly in `on conflict (...)` either — Postgres
  -- requires the EXPR set match the index expression text. Easiest
  -- correct form: explicit pre-INSERT existence check; the partial
  -- unique index still protects against truly concurrent races.
  if exists (
    select 1 from public.webhook_jobs
    where user_id = NEW.user_id
      and alert_payload->>'grouping_key' is not distinct from NEW.grouping_key
      and processed_at is null
  ) then
    return NEW;
  end if;

  insert into public.webhook_jobs (user_id, alert_id, alert_payload)
  values (
    NEW.user_id, NEW.id,
    jsonb_build_object(
      'id', NEW.id, 'type', NEW.type, 'severity', NEW.severity,
      'title', NEW.title, 'message', NEW.message,
      'related_provider', NEW.related_provider,
      'related_project_name', NEW.related_project_name,
      'grouping_key', NEW.grouping_key,
      'suppression_key', NEW.suppression_key,
      'created_at', NEW.created_at
    )
  );
  return NEW;
exception
  -- A concurrent inserter beat us to the partial unique index. That IS
  -- the dedup we want — silently swallow it, no notice (it's expected).
  when unique_violation then
    return NEW;
  -- Anything else is a real failure. Don't block the alert insert
  -- (webhook delivery is best-effort), but log loudly so the failure
  -- is observable in pg logs / Supabase dashboard.
  when others then
    raise warning 'alerts_enqueue_webhook: enqueue failed for alert % (sqlstate %): %',
      NEW.id, sqlstate, sqlerrm;
    return NEW;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

drop trigger if exists alerts_webhook_enqueue on public.alerts;
create trigger alerts_webhook_enqueue
  after insert on public.alerts
  for each row execute function public.alerts_enqueue_webhook();

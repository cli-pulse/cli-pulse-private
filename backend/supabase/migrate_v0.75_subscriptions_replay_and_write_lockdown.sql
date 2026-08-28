-- migrate_v0.75_subscriptions_replay_and_write_lockdown.sql
--
-- Restores the anti-replay guarantees `migrate_v0.7.sql` was written to provide
-- and never delivered, and closes the same write hole on `subscriptions` that
-- v0.74 closed on `profiles`.
--
-- ── Why this is needed now ────────────────────────────────────────────────
--
-- Until 2026-08-28, `validate-receipt` had never successfully written a row:
-- the Apple root certificates were passed to `SignedDataVerifier` as
-- `ArrayBuffer` instead of `Buffer`, so the constructor threw before any
-- database write (fixed in PR #476). Every anti-replay code path in that
-- function has therefore NEVER RUN against a real receipt.
--
-- When the fixed function is deployed, those paths start executing for the
-- first time. They must not be the only thing standing between one purchase
-- and unlimited accounts. Today nothing else is:
--
--     select indexname, indexdef from pg_indexes
--      where schemaname='public' and tablename='subscriptions';
--
--     idx_subscriptions_play_order_id | CREATE INDEX ... (play_order_id)
--                                       WHERE (play_order_id IS NOT NULL)   <- NOT unique
--     subscriptions_pkey              | CREATE UNIQUE INDEX ... (user_id)
--
-- That is the entire list, measured against production 2026-08-28. There is no
-- uniqueness on the Apple side at all, and the Play-side index is non-unique.
-- The application-level check in validate-receipt is a `maybeSingle()` lookup
-- immediately followed by an upsert — a textbook check-then-act race that two
-- concurrent requests interleave straight through.
--
-- ── Why migrate_v0.7 does not cover this ──────────────────────────────────
--
-- It was never applied to production. Confirmed three independent ways:
--   * `play_purchase_token` is absent from `information_schema.columns`
--   * none of its three UNIQUE indexes exist (see the listing above)
--   * neither of its unrelated CHECK constraints (`sessions_id_length`,
--     `alerts_id_length`) appears in `pg_constraint`
--
-- It is left in place, unedited: these files are the record of what was
-- *intended*, and rewriting history to match reality would destroy the only
-- evidence that this drift happened. This migration supersedes its
-- `subscriptions` half. Its `profiles` half was already satisfied by
-- `schema.sql`, which is why `receipt_verified_at` and `last_transaction_id`
-- do exist.
--
-- `play_purchase_token` is deliberately NOT recreated. PR #476 removed the last
-- two references to it from `validate-receipt`, and v1.52 withdrew Android
-- purchasing entirely. Adding a column nothing writes would be re-creating the
-- drift, not fixing it.
--
-- ── Safety ────────────────────────────────────────────────────────────────
--
-- Both unique indexes build trivially: every value is currently NULL.
--
--     select count(*) from public.subscriptions
--      where apple_original_transaction_id is not null;  -- 0
--     select count(*) from public.subscriptions
--      where play_order_id is not null;                  -- 0
--
-- Partial (`WHERE ... IS NOT NULL`) so the 210 existing rows, which are all
-- signup-trigger rows with NULL identifiers, do not collide with each other.

begin;

-- ── 1. Anti-replay: one Apple original transaction, one account ───────────
--
-- `apple_original_transaction_id` is the stable identifier for a subscription
-- across renewals, so this is the correct replay key — `apple_transaction_id`
-- changes every billing period and would not prevent anything.

create unique index if not exists idx_sub_apple_orig_txn_unique
  on public.subscriptions (apple_original_transaction_id)
  where apple_original_transaction_id is not null;

-- ── 2. Anti-replay: one Play order, one account ───────────────────────────
--
-- The existing `idx_subscriptions_play_order_id` (v0.6) is non-unique and has
-- the identical column and predicate, so it becomes pure overhead once the
-- unique index exists — every read it could serve, the unique one serves.
-- Dropped rather than left to accumulate.

create unique index if not exists idx_sub_play_order_unique
  on public.subscriptions (play_order_id)
  where play_order_id is not null;

drop index if exists public.idx_subscriptions_play_order_id;

-- ── 3. Writes are the server's job, not the client's ──────────────────────
--
-- `anon` and `authenticated` currently hold table-level INSERT, UPDATE and
-- DELETE on `subscriptions` (measured via
-- `information_schema.role_table_grants`, 2026-08-28). Only the absence of a
-- permissive write policy stops a self-grant today — RLS is enabled with just
-- "Service can manage subscriptions" and "Users can view own subscription".
--
-- That is one careless `for all using (auth.uid() = user_id)` away from being
-- exactly the v0.74 bypass, on the table that will shortly hold real billing
-- state. Defence in depth: remove the privilege at the level it was granted.
--
-- MUST be table-level. A column-level revoke cannot subtract from a
-- table-level grant — v0.74 measured that the obvious column-scoped form is a
-- silent no-op.
--
-- Safe: `service_role` (which `validate-receipt` uses) bypasses both grants and
-- RLS, and no client writes this table. Reads are untouched, so
-- "Users can view own subscription" keeps working.

revoke insert, update, delete on public.subscriptions from authenticated;
revoke insert, update, delete on public.subscriptions from anon;

-- ── 4. updated_at must not depend on the caller remembering ───────────────
--
-- `validate-receipt` sets `updated_at` by hand in its upsert. Anything else
-- that touches the row — a manual comp grant, a support fix — does not, and
-- two of the four existing non-free rows were hand-written. That makes
-- "when did this change?" unanswerable for exactly the rows where it matters.

create or replace function public.touch_subscriptions_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_subscriptions_updated_at on public.subscriptions;

create trigger trg_subscriptions_updated_at
  before update on public.subscriptions
  for each row
  execute function public.touch_subscriptions_updated_at();

commit;

-- ── Verification (run AFTER applying; each has a negative control) ────────
--
-- 1. Both unique indexes exist AND say UNIQUE. A plain index enforces nothing,
--    and the difference is invisible in a pass/fail summary.
--
--    select indexname, indexdef from pg_indexes
--     where schemaname='public' and tablename='subscriptions' order by 1;
--
--    expect: idx_sub_apple_orig_txn_unique  CREATE UNIQUE INDEX ...
--            idx_sub_play_order_unique      CREATE UNIQUE INDEX ...
--            subscriptions_pkey             CREATE UNIQUE INDEX ...
--    negative control: `idx_subscriptions_play_order_id` must be GONE. If it is
--    still listed, the drop silently did nothing and step 2 may not have run.
--
-- 2. Uniqueness actually bites. In a transaction you roll back:
--
--    begin;
--      update public.subscriptions set apple_original_transaction_id = 'dup-probe'
--       where user_id = (select user_id from public.subscriptions limit 1);
--      update public.subscriptions set apple_original_transaction_id = 'dup-probe'
--       where user_id = (select user_id from public.subscriptions offset 1 limit 1);
--    rollback;
--
--    expect: the SECOND update raises
--            'duplicate key value violates unique constraint'.
--    negative control: the FIRST must succeed. If both fail, something else is
--    wrong and the test proves nothing about uniqueness.
--
-- 3. The write revoke took effect.
--
--    select grantee, privilege_type from information_schema.role_table_grants
--     where table_schema='public' and table_name='subscriptions'
--       and grantee in ('anon','authenticated');
--
--    expect: SELECT only (or no rows).
--    negative control: `service_role` must STILL hold INSERT/UPDATE/DELETE —
--    otherwise validate-receipt itself is broken and the fix is worse than the
--    bug.
--
-- 4. The trigger fires.
--
--    begin;
--      update public.subscriptions set status = status
--       where user_id = (select user_id from public.subscriptions limit 1);
--      select updated_at from public.subscriptions
--       where user_id = (select user_id from public.subscriptions limit 1);
--    rollback;
--
--    expect: updated_at is now() even though the statement never mentioned it.
--    negative control: note the value BEFORE the update in the same
--    transaction; if they are equal the trigger did not run. Do not assert on
--    `now()` inside a `do $$` block — it is frozen for the transaction, which
--    makes such assertions vacuously true.

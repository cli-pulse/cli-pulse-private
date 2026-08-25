-- migrate_v0.74_profiles_entitlement_not_self_writable.sql
--
-- Closes a live entitlement bypass: any signed-in user could grant themselves
-- Pro or Team with a single PostgREST call.
--
-- ── The hole ──────────────────────────────────────────────────────────────
--
-- `profiles` carries the entitlement columns (`tier`, `receipt_verified_at`,
-- `last_transaction_id`) in the same row as the user's own editable profile,
-- and the UPDATE policy is:
--
--     create policy "Users can update own profile"
--       on public.profiles for update using (auth.uid() = id);
--
-- With `with_check` omitted, Postgres reuses the `using` expression as the
-- check. So the only constraint on the NEW row is "it is still your row" —
-- nothing constrains WHICH COLUMNS changed. RLS is row-level; it cannot pin a
-- column. Combined with a table-level UPDATE grant to `authenticated`, that is:
--
--     PATCH /rest/v1/profiles?id=eq.<own-uid>   {"tier":"team"}
--
-- and `get_user_tier()` — the server's authority, read by every tier check —
-- returns 'team' from then on. Verified against production on 2026-08-25 by
-- impersonating a real free user inside a transaction and rolling back:
--
--     role=authenticated | before=free | rows_updated=1 | after=team
--     get_user_tier={"tier":"team"}
--
-- ── Why this is a table-level REVOKE and not a column-level one ────────────
--
-- The obvious-looking fix
--
--     revoke update (tier, receipt_verified_at, last_transaction_id) ...
--
-- IS A NO-OP HERE and was measured to be one: a column-level revoke cannot
-- subtract from a TABLE-level grant. `authenticated` holds `UPDATE` on the
-- whole table, so the attack still succeeded (`rows=1`) after running it. The
-- privilege has to be dropped at the level it was granted.
--
-- ── Why revoking outright is safe ─────────────────────────────────────────
--
-- Nothing legitimate updates `profiles` as `authenticated`. Verified:
--   * validate-receipt (the ONLY writer of tier/receipt_verified_at/
--     last_transaction_id) uses `adminClient` = SERVICE_ROLE, which bypasses
--     both RLS and column grants — functions/validate-receipt/index.ts:358,536
--   * `paired` is written only by SECURITY DEFINER RPCs (helper_rpc.sql:103,
--     migrate_v0.36_desktop_otp.sql:96, …), which run as the function owner
--   * no client on any platform PATCHes profiles — macOS/iOS APIClient.swift
--     and Android SupabaseClient.kt only ever `select`
-- SELECT and INSERT policies are deliberately left alone; DELETE has no policy
-- and is already denied.

begin;

revoke update on public.profiles from authenticated, anon;

-- Document the intent on the policy itself, so the next person reading
-- `pg_policies` sees why the row-level rule is not the whole story.
comment on table public.profiles is
  'User profile + entitlement. `tier`, `receipt_verified_at` and '
  '`last_transaction_id` are SERVICE-ROLE ONLY (written by the validate-receipt '
  'edge function). `authenticated` has no UPDATE on this table at all — see '
  'migrate_v0.74. Do not re-grant table-level UPDATE to add a "user edits their '
  'display name" feature; grant only the specific column.';

commit;

-- ── Verification (run after applying; expects BLOCKED / BLOCKED / ok / ok) ──
--
-- do $$
-- declare v_uid uuid; v_attack text; v_upsert text; v_read text; v_tier text;
-- begin
--   select id into v_uid from public.profiles where tier='free' order by created_at limit 1;
--   perform set_config('request.jwt.claims',
--     json_build_object('sub', v_uid,'role','authenticated')::text, true);
--   perform set_config('role','authenticated', true);
--   begin update public.profiles set tier='team' where id=v_uid; v_attack:='STILL EXPLOITABLE';
--   exception when insufficient_privilege then v_attack:='BLOCKED'; end;
--   begin insert into public.profiles (id,name,email,tier) values (v_uid,'x','x','team')
--           on conflict (id) do update set tier='team'; v_upsert:='UPSERT EXPLOITABLE';
--   exception when insufficient_privilege then v_upsert:='BLOCKED'; end;
--   select tier into v_read from public.profiles where id=v_uid;
--   perform set_config('role','postgres', true);
--   select tier into v_tier from public.profiles where id=v_uid;
--   raise exception 'attack=[%] upsert=[%] read=[%] tier=% (rolled back)',
--     v_attack, v_upsert, v_read, v_tier;
-- end $$;

#!/usr/bin/env bash
# Verify migrate_v0.77 against a real Postgres.
#
# The claim being tested is not "the grants were removed" — that is trivial. It
# is that removing them CLOSES the TRUNCATE hole while LEAVING the live machine
# -control path working. Those two must be asserted together: a revoke broad
# enough to close the hole is also broad enough to break the feature, and only
# `SECURITY DEFINER` keeps the second from following from the first.
#
# So the fixture reproduces production's real shape: RLS on, a SELECT-only
# policy, the blanket `grant all` to anon/authenticated, and a SECURITY DEFINER
# RPC granted to anon that writes the table.
#
# Usage:
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/v077 \
#     ./backend/supabase/tests/run_v077_revoke_grants_tests.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATION="$HERE/../migrate_v0.77_revoke_remote_table_grants.sql"

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "DATABASE_URL must point to an empty disposable database" >&2
    exit 2
fi
[[ -f "$MIGRATION" ]] || { echo "missing $MIGRATION" >&2; exit 2; }

psql_q() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qtAX "$@"; }

fails=0
check() { # check <label> <sql returning t/f>
    local label="$1" sql="$2" got
    got="$(psql_q -c "select ($sql)::text")"
    if [[ "$got" == "true" ]]; then
        echo "  PASS  $label"
    else
        echo "  FAIL  $label  (got '$got')" >&2
        fails=$((fails + 1))
    fi
}

echo "building a fixture in production's shape ..."
psql_q <<'SQL' >/dev/null
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

create table if not exists public.machine_commands(
    id bigserial primary key, user_id text, kind text, status text default 'pending');
create table if not exists public.remote_sessions(
    id bigserial primary key, user_id text);

insert into public.machine_commands(user_id, kind) values ('me','set_fan_target');
insert into public.remote_sessions(user_id) values ('me'), ('someone-else');

alter table public.machine_commands enable row level security;
alter table public.remote_sessions  enable row level security;

drop policy if exists "read own machine commands" on public.machine_commands;
create policy "read own machine commands" on public.machine_commands
  for select using (user_id = current_setting('request.jwt.claim.sub', true));
drop policy if exists "read own remote sessions" on public.remote_sessions;
create policy "read own remote sessions" on public.remote_sessions
  for select using (user_id = current_setting('request.jwt.claim.sub', true));

-- Exactly what production has.
grant all on public.machine_commands, public.remote_sessions to anon, authenticated;
grant all on public.machine_commands, public.remote_sessions to service_role;
grant usage, select on all sequences in schema public to anon, authenticated, service_role;

-- The live machine-control path: a SECURITY DEFINER RPC granted to anon, the
-- shape `remote_helper_complete_machine_command` actually has.
create or replace function public.repro_helper_complete_machine_command(p_id bigint)
returns void language plpgsql security definer set search_path = public, pg_temp as $f$
begin
  update public.machine_commands set status = 'done' where id = p_id;
end $f$;
revoke all on function public.repro_helper_complete_machine_command(bigint) from public;
grant execute on function public.repro_helper_complete_machine_command(bigint) to anon, authenticated;
SQL

# ── BEFORE: the hole is open ────────────────────────────────────────────────
echo "before the migration:"
check "authenticated holds privileges on remote_sessions" \
      "select count(*) > 0 from information_schema.role_table_grants
         where table_schema='public' and table_name='remote_sessions' and grantee='authenticated'"

# The negative control for the whole migration: prove TRUNCATE gets through RLS
# TODAY. If this ever stops reproducing, the migration is closing a hole that is
# not there and the test is measuring nothing.
if psql_q -c "set role authenticated; truncate public.remote_sessions;" >/dev/null 2>&1; then
    echo "  PASS  [control] authenticated CAN truncate through RLS before the revoke"
else
    echo "  FAIL  [control] TRUNCATE was already blocked — this test proves nothing" >&2
    fails=$((fails + 1))
fi
psql_q -c "insert into public.remote_sessions(user_id) values ('me'),('someone-else')" >/dev/null

# ── the migration ───────────────────────────────────────────────────────────
echo "applying $(basename "$MIGRATION") ..."
psql_q -f "$MIGRATION" >/dev/null
psql_q -f "$MIGRATION" >/dev/null
echo "  re-applied cleanly (idempotent)"

# ── AFTER: the hole is closed ───────────────────────────────────────────────
echo "after:"
for tbl in remote_sessions machine_commands; do
    for role in anon authenticated; do
        check "$role holds nothing on $tbl" \
              "select count(*) = 0 from information_schema.role_table_grants
                 where table_schema='public' and table_name='$tbl' and grantee='$role'"
    done
done

if psql_q -c "set role authenticated; truncate public.remote_sessions;" >/dev/null 2>&1; then
    echo "  FAIL  authenticated can STILL truncate remote_sessions" >&2
    fails=$((fails + 1))
else
    echo "  PASS  authenticated can no longer truncate remote_sessions"
fi

# ── the part that must NOT break ────────────────────────────────────────────
echo "the live machine-control path:"
check "service_role kept SELECT on machine_commands" \
      "select has_table_privilege('service_role','public.machine_commands','SELECT')"
check "service_role kept SELECT on remote_sessions" \
      "select has_table_privilege('service_role','public.remote_sessions','SELECT')"

if psql_q -c "set role anon; select public.repro_helper_complete_machine_command(1);" >/dev/null 2>&1; then
    echo "  PASS  anon can still complete a machine command through the SECURITY DEFINER RPC"
else
    echo "  FAIL  the SECURITY DEFINER machine-control path BROKE — this revoke is too broad" >&2
    fails=$((fails + 1))
fi
check "and the write actually landed" \
      "select status = 'done' from public.machine_commands where id = 1"

echo
if (( fails > 0 )); then
    echo "✗ $fails check(s) failed" >&2
    exit 1
fi
echo "✓ v0.77: TRUNCATE hole closed, SECURITY DEFINER paths and service_role intact"

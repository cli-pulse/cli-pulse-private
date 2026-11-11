# Deleting an account on request (without the app)

PRIVACY.md, *Deleting your account*, promises this: someone can email
clipulse.support@gmail.com from the address their account uses, with the
subject "Delete my CLI Pulse account". We may reply to that address to confirm
the request is theirs, then delete the account **as the app would**, **within 30
days**. This file is how that promise is kept. It is not a migration and uses no
migration number.

**Who runs it: the owner.** Steps 1, 3 and 4 read and delete one person's
account in production. Agents do not run them; an agent may only prepare the
SQL and check this file against the schema. Run the SQL in the Supabase SQL
editor of the production project, as its default `postgres` role: that role
bypasses row-level security, which the checks below rely on to see every row
(setting the JWT claims in step 3 does not change the database role). When you
paste an address into SQL, double any `'` in it (`o'neil@…` → `o''neil@…`).

**Nothing about a request goes into this repository** (it is public), nor into
a commit, PR, issue, CI log or session note: no address, no user ID, no dates.
The support mailbox thread is the record (see *Keeping the deadline*).

---

## 0. Before the first request, and after any change to `delete_user_account`

Step 3 calls `public.delete_user_account()`, the function the app's Delete
Account calls. Check that production still has the body this file was written
against (`migrate_v0.72_provider_accounts.sql`):

```sql
select md5(prosrc) = '6e8d5599eb78c5ba8b0d071dcaeda80d' as body_unchanged,
       prosecdef, proconfig
  from pg_proc
 where oid = to_regprocedure('public.delete_user_account()');
```

Expect `true`, `true`, `{"search_path=pg_catalog, public, extensions"}`
(true on 2026-11-12). If `body_unchanged` is false, read the function before
using step 3, and update the md5 here in the same PR that changes the function.

## 1. Find the account

Read-only. Use the address the request came from **and** any address the
person names in it (an Apple relay address, or a different sign-in address).

```sql
select u.id, u.email, u.created_at, u.last_sign_in_at,
       array(select i.provider from auth.identities i where i.user_id = u.id) as sign_in_methods
  from auth.users u
 where lower(u.email) = lower('<ADDRESS>')
    or u.id in (select i.user_id from auth.identities i
                 where lower(i.identity_data ->> 'email') = lower('<ADDRESS>'));
```

* **One row:** continue with step 2. Note `u.email`: it is the address you
  write to, even if the request came from another one.
* **No row:** no account uses that address. Reply to that address saying so
  (and nothing else about any account). Done.
* **More than one row:** stop, and handle each account as its own request.

## 2. Confirm the request is theirs

The sender address of an email can be forged, so a request that merely comes
from the account's address proves nothing. Prove control of the mailbox:

1. Make a confirmation phrase: `openssl rand -hex 4`.
2. From the support mailbox, send a **new** email (not a reply: a forged
   request can carry a Reply-To) to the account's address from step 1,
   subject "Confirm: delete your CLI Pulse account", saying that a deletion
   was requested, what deletion removes and keeps (step 5's list), and that
   replying with the phrase confirms it; if they did not ask for this, they
   can ignore the email and nothing happens.
3. Go on to step 3 only after a reply that contains the phrase arrives in that
   thread (see *Keeping the deadline* for late replies). If none comes, nothing
   is deleted: PRIVACY.md says an unconfirmed request is not carried out.

Shortcut worth offering in that email: if they can still sign in, Settings →
Delete Account in the Mac, iPhone or Android app does the same at once.

**Sign in with Apple with a hidden address** (`…@privaterelay.appleid.com`):
Apple forwards mail to a relay address only from senders registered for the app
(Apple Developer › Certificates, Identifiers & Profiles › Services › Sign in
with Apple for Email Communication). Mail from an unregistered sender is
dropped, so step 2 cannot reach the person.

* **One-time setup:** register the support address there as an email source,
  then check it works by sending a test to the relay address of an Apple
  sign-in you own and seeing it arrive. Then change this bullet to say it is
  done, and when (status on 2026-11-12: **not confirmed**).
* **Once registered:** a request naming a relay address is confirmed exactly
  as above: step 2's email goes to the relay address (the account's
  `u.email`), Apple forwards it to the person's real mailbox, and their reply
  with the phrase confirms it. Replies come back through the relay too.
* **Until then:** the only proof available is the person signing in with that
  Apple ID: in any CLI Pulse app (then Delete Account does it). Tell them so,
  and do not delete on any other evidence.

A request made on someone else's behalf is confirmed the same way: by the
account's own mailbox.

## 3. Delete

Run as **one script** in the Supabase SQL editor (production project, `postgres`
role). Fill in the user ID and the account address from step 1. It refuses to
run unless both name the same account and every link to the account is one it
can check; deletes through `delete_user_account()` exactly as the app does;
then checks that nothing linked to the account is left. If any check fails it
raises, and the whole transaction rolls back (nothing is deleted).

The links are read from the schema each time it runs, so a table added later
is covered as long as its link has the shape checked here: a single-column
foreign key to `auth.users(id)` or `public.profiles(id)`. Any other shape stops
the script before it deletes anything (update this file to handle it). A link
that would survive the delete by being set to NULL (`auth.scim_users`; unused
here, no rows on 2026-11-12) stops it too if the account has such a row,
because after the delete that row could no longer be found by the account's ID.

```sql
begin;

select set_config('cli_pulse.delete_uid',   '<USER-ID>', true),
       set_config('cli_pulse.delete_email', '<ACCOUNT-ADDRESS>', true);

-- Both values must name the same account; every link to it must be checkable.
do $$
declare
  v_uid uuid := current_setting('cli_pulse.delete_uid')::uuid;
  r record;
  n bigint;
begin
  if not exists (
       select 1 from auth.users
        where id = v_uid
          and lower(email) = lower(current_setting('cli_pulse.delete_email'))) then
    raise exception 'user id and address do not name the same account; nothing deleted';
  end if;
  for r in
    select c.conname, c.conrelid::regclass as tbl, c.confdeltype,
           cardinality(c.conkey) as ncols,
           (select attname from pg_attribute
             where attrelid = c.confrelid and attnum = c.confkey[1]) as refcol,
           (select attname from pg_attribute
             where attrelid = c.conrelid and attnum = c.conkey[1]) as col
      from pg_constraint c
     where c.contype = 'f'
       and c.confrelid in ('auth.users'::regclass, 'public.profiles'::regclass)
  loop
    if r.ncols <> 1 or r.refcol <> 'id' then
      raise exception 'foreign key % on % has a shape this script cannot check; nothing deleted', r.conname, r.tbl;
    end if;
    if r.confdeltype <> 'c' then
      execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into n using v_uid;
      if n > 0 then
        raise exception '% has % row(s) for this account that the delete would keep (on delete %); nothing deleted',
          r.tbl, n, r.confdeltype;
      end if;
    end if;
  end loop;
end $$;

-- Act as that user for this transaction only, so auth.uid() returns its id.
select set_config('request.jwt.claim.sub', current_setting('cli_pulse.delete_uid'), true),
       set_config('request.jwt.claims',
                  json_build_object('sub', current_setting('cli_pulse.delete_uid'),
                                    'role', 'authenticated')::text, true);

select public.delete_user_account();   -- returns {"status": "deleted"}

-- Nothing linked to the account may be left: every table with a foreign key to
-- auth.users or public.profiles, read now (so a table added later is covered).
do $$
declare
  v_uid uuid := current_setting('cli_pulse.delete_uid')::uuid;
  r record;
  n bigint;
  v_left text := '';
begin
  for r in
    select c.conrelid::regclass as tbl, a.attname as col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f'
       and cardinality(c.conkey) = 1
       and c.confrelid in ('auth.users'::regclass, 'public.profiles'::regclass)
  loop
    execute format('select count(*) from %s where %I = $1', r.tbl, r.col)
       into n using v_uid;
    if n > 0 then
      v_left := v_left || format(' %s.%s=%s', r.tbl, r.col, n);
    end if;
  end loop;
  if exists (select 1 from auth.users where id = v_uid) then
    v_left := v_left || ' auth.users';
  end if;
  if exists (select 1 from public.profiles where id = v_uid) then
    v_left := v_left || ' public.profiles';
  end if;
  if v_left <> '' then
    raise exception 'rows left:%; rolled back, nothing deleted', v_left;
  end if;
  raise notice 'verified: no rows left for this account';
end $$;

commit;
```

If it raises, nothing changed: read the message, fix the cause, run it again.

**Do not use the dashboard's Authentication › Users › Delete user instead.** It
deletes the `auth.users` row directly, and every table cascades from it,
including `teams.owner_id`: a team the person owns is then deleted, with every
other member's membership, instead of passing to another member as
`delete_user_account()` does and as PRIVACY.md promises.

## 4. Check afterwards (read-only)

```sql
select (select count(*) from auth.users      where id = '<USER-ID>') as users,
       (select count(*) from auth.identities where user_id = '<USER-ID>') as identities,
       (select count(*) from auth.sessions   where user_id = '<USER-ID>') as sessions,
       (select count(*) from public.profiles where id = '<USER-ID>') as profiles;
```

All four must be 0.

## 5. Reply, then close

Reply in the step 2 thread that the account is deleted, and say what stays,
in PRIVACY.md's words:

* entries already written to Supabase's request and sign-in logs (deleted after
  about 90 days);
* crash reports already sent to Sentry, anonymous install statistics, the
  Firebase registration Google keeps for an Android install, and invitations to
  someone else's team sent to their address (none of these are linked to the
  account);
* this email thread, in our mailbox;
* what an app keeps on their own devices until they sign out there or
  uninstall it.

Also tell them that **an App Store or Google Play subscription is not
cancelled** by deleting the account: Apple or Google bills it until they cancel
it in their Apple ID or Google Play subscriptions.

## Keeping the deadline

The 30 days run from the day the request arrived: the due date is that day
plus 30. Keep the request's thread in the support mailbox (label it, for
example, `account-deletion`) and set a reminder for day 21 outside this
repository. The thread holds the request date, the confirmation and the reply;
nothing else is recorded anywhere.

* **Confirmed:** delete the same day or the next; do not wait for the due date.
* **Confirmation arrives late, even after the due date:** delete the day it
  arrives, and say in the reply when the request came and when it was done.
* **No confirmation by the due date:** send one last note to the account's
  address (step 2's thread) that the account was not deleted and how to ask
  again; close the thread.
* **Step 3 fails** (it raised): nothing was deleted. Fix the cause and run it
  again before the due date; if that cannot happen in time, tell the person
  why and by when it will be done.

## Not covered here

* Deleting crash reports from Sentry: they carry no account (see PRIVACY.md).
* The Windows/Linux desktop app, which PRIVACY.md does not cover.

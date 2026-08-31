# CLI Pulse Agent Guide

This file is the canonical quick-start context for any AI or automation working
in this repository.

## Product State

CLI Pulse is a paid product shipping on the App Store (iPhone, iPad, Watch, Mac),
Google Play, a signed Developer ID DMG, and Homebrew (`brew install --cask cli-pulse`).

Current active architecture:

- `CLI Pulse Bar/`
  - Main app codebase for macOS, iOS, watchOS, widgets, and the shared
    `CLIPulseCore` package
- `helper/`
  - Local helper CLI used for pairing, daemon sync, local provider detection,
    and quota collection
- `backend/supabase/`
  - Active backend contract: SQL schema, migrations, and RPC definitions
- `docs/`
  - Public website/legal/distribution pages used by GitHub Pages

## Repository Visibility Rule

The product is **closed-source commercially** — the licence grants no right to
copy or redistribute it. That is a legal position, not a statement about where
the code sits, and the two used to be confused here.

### `origin` IS PUBLIC. All of it.

This section previously listed `CLI Pulse Bar/`, `helper/`, `backend/` and
`archive/` under "Must stay private", and said "`origin` is the private source
repository". **Both statements were false**, and had been since the repository
was made public. Every path that list called private has been world-readable
the whole time.

That is not a harmless doc bug: it is an instruction to treat this repo as a
safe place for internal material, and it was followed. 91 `PROJECT_FIX_*.md`
files and ~46 planning documents under `docs/` are published right now because
of it.

The repository is named `cli-pulse-private` and it is **public**. The name is
the trap; assume nothing from it.

| Remote   | Repository                    | Visibility |
| -------- | ----------------------------- | ---------- |
| `origin` | `cli-pulse/cli-pulse-private` | **PUBLIC** |
| `public` | `cli-pulse/cli-pulse`         | **PUBLIC** |
| —        | `cli-pulse/cli-pulse-internal`| private    |

So the rule is not "which directories are private" — none are. It is:

- **Never commit a secret, credential, token, private key, or internal document
  to `origin`.** There is no directory in it where that is safe.
- Internal material — planning docs, session checkpoints, credential inventories,
  anything you would not want a competitor or a stranger to read — goes to
  `cli-pulse-internal`.
- Secrets live in 1Password and `~/.appstoreconnect/`, never in a file the repo
  tracks. `~/Documents/credits.md` holds the subscription/credit ledger and is
  deliberately outside every repo.

### `public` (`cli-pulse/cli-pulse`) — the marketing + Pages repo

Serves https://cli-pulse.github.io/cli-pulse/ from `docs/` on `main`:
`index.html`, `privacy.html`, `terms.html`, `support.html`, `security.html`,
`data-handling.html`, `release-notes.html`.

**`docs/` in THIS repo is not that site.** It is a stale divergent copy that is
served nowhere and still advertises v1.10.7. Editing it changes nothing a user
sees. To change the live site, edit `docs/` in the `public` remote.

### The legacy Pages host is load-bearing — do not break it

Shipped app builds hardcode `https://jasonyeyuhe.github.io/cli-pulse/privacy.html`
and `/terms.html` in the paywall, the iOS settings screen and the
account-deletion screen. Those binaries cannot be changed.

The 2026-07-18 org move stopped that host serving — GitHub does not redirect
`<user>.github.io/<repo>` after a transfer — and every one of those links was a
404 for twelve days, for users of the live build, while App Review's Guideline
3.1.2 requires them to work. `JasonYeYuhe/cli-pulse` now exists solely to serve
redirect stubs. **Do not delete that repository.**
`scripts/check_legal_urls.sh` fails CI if either host stops serving.

## Git Rules

- `origin` is the source repository. It is PUBLIC — see above.
- `public` is the marketing + GitHub Pages repository. Also public.
- Do **not** push product source changes to `public` unless the task is
  explicitly about public website/distribution content only.
- Treat the public repo as distribution-facing unless explicitly told
  otherwise.
- Before any push, check whether the target remote is `origin` or `public`.
- The public `main` branch has been rewritten to distribution-only history.
- Public releases/tags are expected to point to distribution-only commits, not
  source commits.

## Branching Rule

- Treat private `main` as the integration branch.
- Start normal feature work from private `main`, not from older task branches.
- Use one task branch per unit of work, for example:
  - `onboarding-pairing-ux`
  - `provider-fix-gemini`
  - `release-1-1-4`
- Do not stack unrelated work onto `provider-sync-repo-cleanup` or other
  long-lived branches unless the intent is to ship those changes together.
- Keep public distribution work isolated from app/helper/backend feature work.
- If the user gives a new task without specifying a branch, inspect the current
  branch and decide:
  - same task family as current branch: reuse it
  - unrelated task: create a new task-named branch from private `main`
  - release work: use a release branch
  - public docs/distribution work: use the `public` workflow only
- Prefer opening a new branch over silently mixing unrelated work into an old
  feature branch.

## Current Repo Reality

- `origin` points to the private `cli-pulse-private` repo.
- `public` points to the public `cli-pulse` repo.
- Public GitHub Pages and GitHub Releases are still used for:
  - website pages
  - legal pages
  - macOS release downloads
  - support links
- Public repo contents are intentionally minimal:
  - `.gitignore`
  - `README.md`
  - `PRIVACY.md`
  - `TERMS.md`
  - `docs/`

## Public Release Workflow

If a task is specifically about the public repo, keep it distribution-only.

- Update website/legal/support content only.
- Upload notarized macOS artifacts to GitHub Releases in `public`.
- Do not add app source, helper source, backend code, tests, fixtures, or
  internal notes to `public`.
- If a release tag must be recreated, ensure it is recreated on a
  distribution-only commit.

## App Store listing preflight — run before every ASC submission

```bash
python3 scripts/asc_listing_preflight.py
```

`scripts/check_paywall_claims.sh` guards the repo *sources*. It cannot see what
App Store Connect is actually serving, and the gap between those two has bitten
three times:

| date | source | what the store served |
|---|---|---|
| 2026-08-28 | caption fixed in v1.51 | 1.52.0 screenshots still sold Team + Lifetime |
| 2026-08-30 | PR #484 re-shot the paywall screenshot | never uploaded |
| 2026-08-31 | description fixed in v1.52.1 | live macOS copy still sold Team at $9.99/$99.99 |

The preflight reads ASC (read-only, GETs only) and checks three things the repo
cannot answer:

1. **SKU-vs-copy** — the description must not name a tier whose SKU is not
   `APPROVED`. This compares the store's words against the store's own product
   catalogue, so it needs no repo source and cannot go stale.
2. **Description drift** — live en-US vs both repo pushers
   (`appstore_metadata.py`, `resubmit.py`).
3. **Screenshot drift** — every live screenshot vs the local composed PNG of the
   same name, compared on decoded pixels because ASC re-encodes on ingest.

⚠️ **Drift runs in both directions.** On 2026-08-31 the store was stale on the
subscription paragraph *and* newer than the repo on the privacy section.
Pushing either side verbatim would have regressed the other. Read both lists the
script prints before acting.

It needs the ASC key, so it cannot run in CI — it is a release-time step on the
owner's machine. Exit 2 means it could not check, which is not a pass.

## Active vs Archived

### Active

- `CLI Pulse Bar/`
- `helper/`
- `backend/supabase/`
- `docs/`
- `PRIVACY.md`
- `TERMS.md`

### Archived or historical

- `archive/legacy-root/`
- `archive/backend-fastapi-legacy/`

## Current Technical Direction

- App auth and sync are Supabase-based
- Cloud Sync is account-based, not direct device-to-device pairing
- The Mac helper is the source of local collection and sync
- Claude, Gemini, Codex, and other provider collectors are implemented inside
  `CLIPulseCore` and helper-side parsing logic

## Safe Validation Commands

Run these before shipping collector or helper changes:

```bash
(cd helper && python3 -m pytest -q)   # the WHOLE directory — see below
swift test --package-path "CLI Pulse Bar/CLIPulseCore"
```

Run the whole `helper/` suite, not one file. Helper CI's step is bare
`pytest -q` under `working-directory: helper`, so any single-file command is
weaker than the gate. This line used to name `helper/test_system_collector.py`
alone, and on 2026-08-31 that cost a red CI on PR #500: deleting `helper/swarm.py`
broke `helper/test_remote_hook.py`, which imports it — a file the documented
command never collected.

When touching `backend/supabase/` SQL, app/helper/Android RPC call sites,
or edge functions, also run the static contract smoke (no network, no
credentials):

```bash
python3 backend/supabase/ci_check_rpc_contract.py
```

### Android validation (requires Java runtime)

```bash
cd android && ./gradlew testDebugUnitTest
```

If the machine lacks a Java runtime, state this explicitly rather than
skipping Android validation silently.

### Live integration tests

The default `swift test` run is deterministic and offline. To also run
the live Claude collector chain (requires real credentials on the machine):

```bash
RUN_LIVE_TESTS=1 swift test --package-path "CLI Pulse Bar/CLIPulseCore"
```

### Backend SQL validation

There is no automated SQL test runner yet. When touching files in
`backend/supabase/`, manually verify:

- SQL syntax via `psql` or Supabase dashboard query editor
- RPC contracts match app/helper call sites
- Migration ordering is consistent with `schema.sql`

### Migration numbering — one number, one migration, forever

**Before you name a new `backend/supabase/migrate_vX.YY_*.sql`, run:**

```bash
ls backend/supabase/migrate_v*.sql | sort -V | tail -5
```

Take the next unused number. Never reuse one, **even if the existing file is on
a branch you have not merged yet** — parallel work is normal here and two
sessions picking "the next number" at the same time is exactly how this breaks.

Why it matters: these files are the only record of what has actually been
applied to production, and they are matched **by number**. Two different
migrations sharing a number means nobody can later answer "did v0.70 run?" —
the answer becomes "which v0.70?". The database will not stop you: both apply
cleanly, and the damage only surfaces months later during an incident.

If your branch already carries a number that has since been taken on `main`,
**renumber yours** — `main` wins, because its migration has usually already
been applied to production. Rename the file, update any reference to it, and
say so in the PR.

CI enforces this: `scripts/check_migration_numbers.sh` fails the build on a
duplicate. Run it locally before pushing.

**Real example this rule came from (2026-07-28):** `main` had
`migrate_v0.70_device_app_version.sql`, already applied to production, while
PR #393 independently added `migrate_v0.70_provider_accounts.sql`. Different
schema, same number, neither author aware. Caught by review, not by tooling —
hence the CI guard.

## If You Are a New AI Starting Work

1. Read this file first.
2. Read `/Users/jason/Documents/cli pulse/README.md`.
3. Read `/Users/jason/Documents/cli pulse/REPO_VISIBILITY_STRATEGY.md` (untracked-local; canonical copy: cli-pulse-internal/private-repo-root-docs/).
4. Read `/Users/jason/Documents/cli pulse/BRANCHING.md` before starting a new
   task branch or reusing an existing branch.
5. Read `/Users/jason/Documents/cli pulse/RELEASE_WORKFLOW.md` (untracked-local; canonical copy: cli-pulse-internal/private-repo-root-docs/) before doing
   release or distribution work.
6. Treat the app/helper/backend logic as private product IP.
7. Do not publish source changes to the public repo by default.

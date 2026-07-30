# CLI Pulse — read this first

Claude Code loads this file automatically at session start. Codex and other
tools read `AGENTS.md`. To keep one source of truth, **the full guide lives in
[`AGENTS.md`](AGENTS.md)** — read it now, before touching anything.

The few rules below are repeated here because breaking them is expensive and
the mistake is invisible until much later.

## Migration numbering — one number, one migration, forever

Before naming a new `backend/supabase/migrate_vX.YY_*.sql`:

```bash
ls backend/supabase/migrate_v*.sql | sort -V | tail -5
scripts/check_migration_numbers.sh
```

Take the next unused number. **Never reuse one — including a number that is
only used on a branch nobody has merged yet.** Several people work this repo in
parallel, and two sessions independently picking "the next number" is exactly
how it breaks.

These files are the only record of what has actually been applied to
production, and they are matched **by number**. Two migrations sharing one
means nobody can later answer "did v0.70 run?" — it becomes "which v0.70?".
Postgres applies both without complaint; the damage surfaces months later,
during an incident, when you least want an unanswerable question.

If your branch carries a number that has since been taken on `main`,
**renumber yours**. `main` wins, because its migration has usually already run
against production. Rename the file, update references, mention it in the PR.

> This rule exists because it happened on 2026-07-28: `main` carried
> `migrate_v0.70_device_app_version.sql`, already applied to production, and
> PR #393 independently added `migrate_v0.70_provider_accounts.sql`. Different
> schema, same number, neither author aware. Review caught it; nothing in the
> toolchain did — hence `scripts/check_migration_numbers.sh` and the CI job.

## Repo visibility

`cli-pulse-private` is a **public** repository despite the name. No secrets, no
internal documents, ever. Internal material goes to `cli-pulse-internal`.
See the visibility section of `AGENTS.md`.

## Branching

Do not develop directly on `main`. See `BRANCHING.md`.

## Before you conclude something is missing or broken

List what *is* there first. Several past sessions burned hours on a wrong
premise — "the app isn't installed", "the dSYMs never uploaded" — that one
`ls` would have settled.

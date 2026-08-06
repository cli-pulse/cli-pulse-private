# This folder does not serve anything

`cli-pulse-private/docs/` is **not** published. The live site is served from
[`cli-pulse/cli-pulse`](https://github.com/cli-pulse/cli-pulse) `main:/docs`,
at <https://cli-pulse.github.io/cli-pulse/>.

Editing files here has **zero effect on users**. Two sessions have now started
to edit `docs/privacy.html` believing it was live; the second one only caught
it by fetching the served URL and diffing.

## Where the real pages live

| Page | Edit here |
|---|---|
| Privacy policy | `cli-pulse/cli-pulse` → `docs/privacy.html` |
| Terms | `cli-pulse/cli-pulse` → `docs/terms.html` |

`PRIVACY.md` at the repo root is the source of truth for *what we collect*, and
the served HTML must be kept in step with it by hand — they are separate files
in separate repositories, and nothing enforces the match.

⛔ The old `jasonyeyuhe.github.io/cli-pulse/` Pages site still exists and must
keep working: shipped app binaries hard-code those URLs and cannot be changed.
See `reference_public_urls_and_pins` for the full URL topology.

## What was removed and why

`index.html`, `privacy.html` and `terms.html` used to sit here. All three were a
v1.10.7-era snapshot that nothing served, and they had drifted far enough to be
actively wrong — `privacy.html` claimed the app did not ship Sentry (it does,
in every client), and `index.html` still advertised v1.10.7 downloads.

They are in git history if anything ever needs them. Removing them is the point:
a stale privacy policy sitting in the repo is worse than no copy, because the
next person to edit "the privacy policy" finds this one first.

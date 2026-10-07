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

## Releasing a version to the App Store — the order

Four scripts write to App Store Connect, and the order matters. The listing and
screenshot pushers write only to an editable version, and a submitted version
is waiting for review and no longer editable, so the submission goes last. Each
script is a dry run unless given `--apply`: run it dry first, read what it
would change, then run it again with `--apply`. The 1.54.0 release, per
platform (IOS / MAC_OS, `ios` / `macos`):

```bash
# 0. Repo only, no key: listing texts and the release notes
python3 scripts/asc_listing_preflight.py --texts-only --whatsnew-dir whatsnew_154

# 1. The version row. App Store Connect gives it the previous version's locales
#    (en-US and zh-Hans for 1.53.0); nothing else is written.
python3 scripts/asc_submit.py --create-version ios --version 1.54.0 \
    --release-type AFTER_APPROVAL                                            # then --apply

# 2. Listing texts. This creates the zh-Hant, ja, ko, es-ES and es-MX locales.
#    App Store Connect then adds them, empty and without URLs, to the Mac
#    version as well; the MAC_OS run fills those in.
python3 scripts/asc_push_listing.py --version 1.54.0 --platform IOS
python3 scripts/asc_push_listing.py --apply --version 1.54.0 --platform IOS

# 3. Screenshots, per locale (scripts/asc_push_screenshots.py): iPhone, the
#    13" iPad and the Apple Watch on IOS, the six-language Mac set on MAC_OS.
#    App Store Connect copies the previous version's screenshots onto a new
#    version, so a set not pushed is the old one, not none (step 4 fails on it)
python3 scripts/asc_push_screenshots.py --platform IOS --version 1.54.0      # then --apply
python3 scripts/asc_push_screenshots.py --platform IOS --display-type APP_IPAD_PRO_3GEN_129 \
    --version 1.54.0                                                         # then --apply
python3 scripts/asc_push_screenshots.py --platform IOS --display-type APP_WATCH_ULTRA \
    --version 1.56.0                                                         # then --apply

# 4. The store against the repo, for the version being prepared. What's New is
#    still empty here (step 5 writes it): --whatsnew-unwritten-ok reports that
#    as NOT WRITTEN instead of failing, on an editable version only.
python3 scripts/asc_listing_preflight.py --version 1.54.0 --whatsnew-dir whatsnew_154 \
    --whatsnew-unwritten-ok

# 5. App Review notes, What's New, build, submission, once the build is VALID
#    (--list-builds ios). The notes file is this version's, written for it.
python3 scripts/asc_submit.py --submit ios --build <BUILD_ID> --version 1.54.0 \
    --whatsnew-dir whatsnew_154 --review-notes <notes-ios.txt>               # then --apply

# 6. After submitting: the same preflight WITHOUT --whatsnew-unwritten-ok. What's
#    New must now be on the store in every localization of both platforms.
python3 scripts/asc_listing_preflight.py --version 1.54.0 --whatsnew-dir whatsnew_154
```

Repeat 1, 2, 3 and 5 with `macos` / `MAC_OS` (step 3 then pushes the Mac
set: see "Mac screenshots" below).

**Release type.** Both versions are created with `--release-type
AFTER_APPROVAL`: App Store Connect releases each one as soon as Apple approves
it, with no one clicking Release. That is what 1.53.0 and 1.54.0 did, on the
owner's instruction: an approved version should reach users without waiting
for someone to release it by hand (the Developer ID build of the same version
was already out both times). Some earlier releases were MANUAL — 1.41.0,
1.49.0, 1.52.0 — so check, do not assume.
`asc_submit.py --create-version` still defaults to MANUAL, deliberately: a
forgotten flag then leaves an approved version waiting for one click in App
Store Connect, while the opposite mistake publishes a version the moment Apple
approves it, with no chance to hold it. So the flag has to be passed. The
script never changes a version's releaseType; `--create-version` prints the
one an existing version has and warns when it is not the one asked for, and
`--submit`'s dry run prints it with what it means, so it is read before the
version goes to review.

**App Review notes.** App Store Connect copies the previous version's App
Review notes onto a new version word for word — 1.54.0 arrived carrying
1.53.0's, which told the reviewer that "THE MAIN FEATURE IN 1.53.0" needs a
second device. `asc_submit.py --submit` prints the notes the version holds in
its dry run (never the contact or demo-account fields) and refuses, before any
write, notes that name an older version and never this one, or that present an
older version as the one under review ("this 1.53.0 build"; a comparison such
as "unchanged since 1.53.0" is fine). `--review-notes FILE` replaces them: the
file is checked the same way before App Store Connect is contacted, and
`--apply` PATCHes only `notes`, before What's New, and reads back that the
notes are the file and the contact and demo-account fields are unchanged.
`--accept-review-notes` submits flagged notes when the mention is deliberate.
A refusal that is really another product's version (the helper, a CLI tool the
app monitors) is fixed by naming that product in `_OTHER_PRODUCT` in the
script, not by `--accept-review-notes`, which switches the check off.
Write the notes per platform, and check what actually changed in Info.plist
and the entitlements since the last version before claiming anything about
permissions.

**What's New** lives in `whatsnew_<version>/`: `<locale>.txt` is the iOS text
and `macos-<locale>.txt` the macOS text, one file per App Store locale (seven:
es-ES and es-MX are separate files and must be identical, like the listing's
shared `es/`). The Mac falls back to `<locale>.txt` only in a directory with no
`macos-*.txt` at all; in a split directory a missing Mac file is refused, since
the fallback would be the iPhone text. `scripts/appstore_listing.py`
(`load_whatsnew`) decides which file a locale gets and checks them: at most 4000
characters, no other platform named in any of the six languages (Guideline
2.3.10; `check_release_notes_platforms.sh` only knows the Latin spellings), no
English left in a translation, the zh-Hant terms, and nothing in the macOS text
that only the direct-download Mac build has (Remote Control, fan control).

`asc_submit.py --submit` refuses before its first write when the texts fail
those checks, the version is missing or not editable, any localization of the
version has no text for that platform, a repo locale is not on the version yet
(step 2 has not run; `--allow-missing-locales` overrides), the build is not
`VALID`, is for another platform or version, or the store does not say which
platform and version it belongs to, or the App Review notes read as an older
version's. With `--apply` it writes the review notes (if `--review-notes`
differs) and What's New where it differs, reads both back, and only then
attaches the build and submits. The old `--whatsnew` fallback file is retired:
it is how English notes once reached every storefront.

The preflight's `--whatsnew-dir` checks the files (step 0) and, against the
store, that every localization of the checked version holds its platform's
text (steps 4 and 6). It used to check only the files: on 2026-09-28 it
printed PREFLIGHT OK for 1.54.0 while What's New was empty in all 14
localizations. Without `--whatsnew-dir` it now says What's New was not
compared, in its summary.

Tests, all run by `repo-hygiene.yml`: `scripts/test_asc_submit.py` (offline,
against a fake App Store Connect: What's New, review notes, release type), the
What's New cases in `scripts/test_asc_listing_preflight.sh`, and
`scripts/test_asc_listing_preflight_store.py` (the preflight's store half
against a fake: the What's New comparison).

## Releasing the Developer ID build — three surfaces

The direct-download Mac build (the one with Remote Control and machine
controls) reaches users through three places, each changed by its own command.
Publishing one is not publishing the release: 1.45.0 went out with
`latest.json` and the Homebrew tap still on 1.44.0, so almost no existing user
was offered it, and 1.53.0 never reached Homebrew at all (the tap went from
1.52.1 to 1.54.0 on 2026-09-28). A merged cask PR in this repo changes nothing
for `brew` users.

| surface | where | who reads it |
|---|---|---|
| 1. the release | `app-vX.Y.Z` on `cli-pulse/cli-pulse-distrib`, marked Latest: the DMG, its `.sha256`, `manifest-fragment-arm64.json` | people downloading by hand |
| 2. `latest.json` | the `latest` release of `cli-pulse/cli-pulse-distrib` | the in-app updater, at the `JasonYeYuhe/` URL compiled into `AppUpdater.swift` |
| 3. the cask | `Casks/cli-pulse.rb` on `cli-pulse/homebrew-tap`, branch **master** | `brew upgrade` |

```bash
# Build, notarize and staple (needs an unlocked console for the keychain
# profile; the inline APPLE_NOTARY_* mode does not). Hash only the final,
# stapled DMG: stapling changes it.
DEV_ID_APP="Developer ID Application: <Name> (<TEAMID>)" \
    scripts/build_devid_dmg.sh --arch arm64 --output-dir <dir>

# Before publishing: spctl --assess --type open (context:primary-signature) on
# the DMG, the app against a requirement pinning bundle id AND team,
# spctl --assess --type execute on the app, its version/build above the last
# release's, and a launch smoke test (docs/DEVID_TERMINAL_SMOKE.md).

# 1. the release
gh release create app-v1.54.0 --repo cli-pulse/cli-pulse-distrib --latest \
    --title "CLI Pulse Mac 1.54.0 (Developer ID)" --notes-file <release-notes.md> \
    <dir>/CLI-Pulse-1.54.0-arm64.dmg <dir>/CLI-Pulse-1.54.0-arm64.dmg.sha256 \
    <dir>/manifest-fragment-arm64.json

# 2. latest.json, only once the DMG downloaded back from the release has the
#    sha256 you verified: a copy of the manifest fragment, uploaded under that
#    exact name. Its url keeps the JasonYeYuhe/ owner segment: the updater
#    refuses any other.
cp <dir>/manifest-fragment-arm64.json <tmp>/latest.json
gh release upload latest --repo cli-pulse/cli-pulse-distrib --clobber <tmp>/latest.json

# 3. the cask, generated from the published DMG and style-checked
#    (brew style on the new file; a failure leaves the cask unchanged)
scripts/update_cask.sh 1.54.0
#    ...then a small PR with Casks/cli-pulse.rb here, AND the same file pushed to
#    the tap, committed with hooks off (a hook in a tap checkout once ran
#    `brew fetch` for minutes).
git clone git@github.com:cli-pulse/homebrew-tap.git <tap>
cp Casks/cli-pulse.rb <tap>/Casks/
git -C <tap> add Casks/cli-pulse.rb
git -C <tap> -c core.hooksPath=/dev/null commit --no-verify -m "cask: 1.54.0"
git -C <tap> push origin master

# Afterwards, read all three back (GET only; exit 0 only if every one serves it)
scripts/check_release_surfaces.sh 1.54.0 --download
```

`check_release_surfaces.sh` checks that the release is published, Latest and
carries the three assets, that the pinned download URL answers, that
`latest.json` (through the API and at the URL the app fetches) is the
release's manifest with the DMG's version, URL, sha256 and size, and that the
tap's cask says the version and sha256, downloads from the pinned URL, and is
the same file as `Casks/cli-pulse.rb` on `main`. `--download` also fetches the
DMG `latest.json` points at, hashes it and runs `spctl` on it: the bytes users
get are the bytes that were verified. Right after the `latest.json` upload,
GitHub's download CDN can serve the old file for a few minutes; the check says
so, and a re-run settles it. `update_cask.sh` fails if the style check finds a
problem or does not run (no Homebrew: `--skip-style`, on purpose only). Tests,
offline, in `repo-hygiene.yml`: `scripts/test_check_release_surfaces.sh` and
`scripts/test_update_cask.sh` (which also runs the real `brew style` where
Homebrew is installed).

## Releasing the Companion CLI — a 1.55 release gate

The Companion CLI (`helper/`, the `.pkg`) ships on its own line: the release
`latest` on `cli-pulse-helper-releases` carries `latest.json`, which the app's
`HelperInstaller` reads (at the `JasonYeYuhe/` URL compiled into it) to offer
Install and Update. `scripts/build_helper_pkg.sh` takes the version from
`helper/system_collector.py:HELPER_VERSION`, and
`scripts/check_helper_version_sync.sh` keeps HelperSwift's `kHelperVersion` and
the embedded Uninstaller's `helper-uninstaller/Info.plist` on the same number.

**Gate for 1.55.** The 1.55 app says, in its Companion CLI install text and in
the notes under the local-scan answer and the Claude keychain switches, that
Companion CLI 1.30.0 and earlier do not follow the answer, and tells their
users to update it in Settings › Companion CLI. That is true only once a
Companion that does follow it (1.31.0: #626, #627, #630, #634, #636 and #635)
is published as the `.pkg` and in `latest.json`. Until then Install downloads
1.30.0, and an installed 1.30.0 is offered no update, because the installer
compares its version with `latest.json`'s. Publish Companion CLI 1.31.0 before,
or together with, the 1.55 app, and read `latest.json` back at the app's URL
before submitting the app. `test_a_companion_that_follows_the_answer_is_newer_than_1_30_0`
(helper) fails if a Companion that says `follows_app_answer` reports 1.30.0.

## App Store listing — texts, pusher, preflight

The listing texts (description, keywords, subtitle, promotional text) live in
`CLI Pulse Bar/appstore/<locale>/`, one directory per app language (en-US,
zh-Hans, zh-Hant, ja, ko, es — `es/` feeds both es-ES and es-MX). The layout,
the ASC locale mapping and the checks are in `scripts/appstore_listing.py`;
every pusher reads the files through it. iOS and macOS share one text per
locale, so every claim must be true on both — a sentence true on one platform
only goes in a `description.ios.txt` / `description.macos.txt` override (a line
telling people to add a Home Screen widget, for example: the Mac app has none).
Features that only the direct-download Mac build has (Remote Control, fan
control) are not advertised in any App Store listing, override or not.

```bash
python3 scripts/asc_push_listing.py                     # dry run: per-locale, per-field diff
python3 scripts/asc_push_listing.py --apply --version 1.54.0 --platform IOS
python3 scripts/asc_listing_preflight.py --texts-only   # what CI runs; no key needed
python3 scripts/asc_listing_preflight.py --version 1.54.0   # before every ASC submission
```

The pusher writes only to an editable version (PREPARE_FOR_SUBMISSION /
*_REJECTED), creates missing locales, never deletes one, gives a localization
with no support or marketing URL en-US's (the store will not submit a version
while any localization lacks a support URL, and the read-back checks it), and
never touches What's New (that is `asc_submit.py --whatsnew-dir`; the order of
the release steps is in "Releasing a version to the App Store" above).

`scripts/check_paywall_claims.sh` guards the repo *sources*. It cannot see what
App Store Connect is actually serving, and the gap between those two has bitten
three times:

| date | source | what the store served |
|---|---|---|
| 2026-08-28 | caption fixed in v1.51 | 1.52.0 screenshots still sold Team + Lifetime |
| 2026-08-30 | PR #484 re-shot the paywall screenshot | never uploaded |
| 2026-08-31 | description fixed in v1.52.1 | live macOS copy still sold Team at $9.99/$99.99 |

The preflight reads ASC (read-only, GETs only) and checks what the repo
cannot answer:

1. **SKU-vs-copy** — the description must not name a tier whose SKU is not
   `APPROVED`. This compares the store's words against the store's own product
   catalogue, so it needs no repo source and cannot go stale.
2. **Listing drift** — every live locale's description, keywords, promotional
   text and subtitle vs `CLI Pulse Bar/appstore/<locale>/`, and every repo
   locale present on the store.
3. **Screenshot drift** — every live screenshot vs the local composed PNG of the
   same name, compared on decoded pixels because ASC re-encodes on ingest. In
   the iPhone, iPad, Apple Watch and Mac sets, which this repo composes whole per locale, a
   live screenshot with no local panel of its name fails: that is a set nobody
   replaced (the April 2026 iPad set would have reached 1.55.0 that way). So
   does a locale with its own panels (`SHOT_SOURCES`) and no set of one of its
   platform's types: App Store Connect shows it another locale's panels (an
   iPad push stopped part-way would have left ja, ko, es and zh-Hant on the
   English ones).

Check 5, **What's New** (with `--whatsnew-dir`), compares every localization of
the version, per platform, with the text `asc_submit.py` would write; empty
counts as different (see "Releasing a version to the App Store" above). Check
4, the panels, is repo-only (`--require-shots`, below).

⚠️ **Drift runs in both directions.** On 2026-08-31 the store was stale on the
subscription paragraph *and* newer than the repo on the privacy section.
Pushing either side verbatim would have regressed the other. Read both lists the
script prints before acting.

The store comparison needs the ASC key, so it cannot run in CI — it is a
release-time step on the owner's machine. Exit 2 means it could not check, which
is not a pass. The repo-text half (`--texts-only`: limits, keyword format,
Guideline 2.3.10 platform names in six languages, untranslated English, inline
copies in pushers) runs in `repo-hygiene.yml`, with `--require-shots` (every
listing locale's five composed iPhone panels, four composed iPad panels, four
Apple Watch panels and six composed Mac panels, their `compose.json`, the committed raws they were drawn
from, and for the Mac a `render.json` that says a clean store render drew them).

### iPhone screenshots (six languages)

Captured without a tap from a DEBUG simulator build, composed with per-language
captions, pushed per locale. Layout and locale mapping: `scripts/appstore_screenshots.py`.

```bash
"CLI Pulse Bar/scripts/capture_ios_screenshots.sh"            # -> screenshots/ios-raw/<lang>/
python3 "CLI Pulse Bar/scripts/compose_appstore_ios_screenshots.py" --all   # -> ios-composed/<lang>/
python3 scripts/asc_push_screenshots.py --version 1.54.0     # dry run: per-locale files + md5
python3 scripts/asc_push_screenshots.py --apply --platform IOS --version 1.54.0
python3 scripts/asc_listing_preflight.py --texts-only --require-shots
```

The capture launches the app with `-CLIPulseScreenshotDemo YES
-CLIPulseScreenshotScreen <screen>` (compiled out of Release; see
`ScreenshotLaunch.swift`), which enters the shipped Demo mode on that screen with
no network and no permission prompt. The capture uninstalls CLI Pulse from the
simulator first (its data there goes) and refuses a device with any app running
on it, CLI Pulse included, unless `--force` (iOS's own `com.apple.*` jobs do not
count). The compositor publishes a set only when every panel passed, with a
`compose.json` of their md5s; a failing or interrupted run leaves its panels in
`ios-composed/<lang>.rejected/` or discards them, withdraws the old
`compose.json`, and nothing pushes a set without one. The pusher replaces only
the `APP_IPHONE_67` set, uploads and waits for the new panels before deleting
the old, removes its own uploads on any failure (a rerun reuses the finished
ones), and refuses while the version waits for review (withdraw the iOS
submission only). App Store Connect reports a panel COMPLETE before it fills
in its checksum, so the read-back, and a rerun that finds such a panel, wait
for the checksum rather than calling it a mismatch or replacing it.

The same launch, capture script and compositor make the iPad set (below): a
caption change recomposes both.

The raw captures and the composed sets are committed (`ios-raw/<lang>/`,
`ios-composed/<lang>/` with `compose.json`), and CI fails if a listing locale's
set is missing or not what a clean compose run wrote, including a set whose
recorded captions are no longer the compositor's `COPY`: a caption change in
`compose_appstore_ios_screenshots.py` needs its recompose committed with it
(`--all` recomposes from the committed captures; no simulator needed). CI also
fails when `ios-raw/<lang>/` is not exactly the captures that `compose.json`
records the set was drawn from (by md5: a missing, changed or stray capture),
so a recapture needs its recompose committed with it too, and the committed
captures are always the ones behind the committed panels. The hand-shot 1.53.0
set (`screenshots/ios/`, `screenshots/ios-zh/`) was retired with the first
capture in this layout.

### iPad screenshots (six languages)

The iOS app runs on iPad (`TARGETED_DEVICE_FAMILY = 1,2`), so App Store Connect
requires a 13" iPad set (`APP_IPAD_PRO_3GEN_129`) to submit it. It is four
of the iPhone set's five screens, with their captions, captured by the same DEBUG launch on
the existing `iPad Pro 13-inch (M5)` simulator, where the app shows its own
regular-width layout (`iPadSplitView`), in portrait, 2064x2752, the size of the
panel (App Store Connect takes it for the 13" display, and a headless
simulator cannot be rotated). In portrait the split view keeps its sidebar
beside the screen (measured on the 1.55 capture), so the panels show the iPad
layout without a rotation step. The iPad status bar also shows the date, drawn
by SpringBoard in the simulator's own language, which `-AppleLanguages` on the
launch does not reach: for the iPad set the capture script sets the simulator's
language to each capture language (restarting SpringBoard) and puts the old one
back at the end. Never put iPhone captures on an iPad canvas: App Review rejects
iPhone screenshots dressed as iPad ones (guideline 2.3.3), and every step here
refuses them (the capture script checks the simulator's family and each
capture's size, the compositor each raw's size, the pusher and
`--require-shots` each panel's).

**Four panels, not five (1.56, owner's decision).** On the 13" iPad the
Overview fits without scrolling, so the `cost` capture repeated the overview
panel's Cost Summary and Provider Usage under a faded strip of its tiles. The
iPad set is `IPAD_SCREENS` (overview, providers, sessions, alerts), and each
panel keeps its iPhone number (`01`, `02`, `04`, `05`; `Platform.numbering`
in `scripts/appstore_screenshots.py`), so it shares the iPhone's file names and
captions. The capture script refuses `--set ipad --screens cost`, and the
compositor and `--require-shots` refuse a `03_cost` left in `ipad-raw/` or
`ipad-composed/`.

```bash
"CLI Pulse Bar/scripts/capture_ios_screenshots.sh" --set ipad --app <Debug iphonesimulator .app>
                                                   # -> screenshots/ipad-raw/<lang>/
python3 "CLI Pulse Bar/scripts/compose_appstore_ios_screenshots.py" --set ipad --all   # -> ipad-composed/<lang>/
python3 scripts/asc_push_screenshots.py --display-type APP_IPAD_PRO_3GEN_129 --version 1.55.0   # dry run
python3 scripts/asc_push_screenshots.py --apply --platform IOS --display-type APP_IPAD_PRO_3GEN_129 \
    --version 1.55.0
python3 scripts/asc_listing_preflight.py --texts-only --require-shots
```

The capture's READY line is printed only when the requested tab's screen
reports itself showing (`ScreenshotLaunch.ShowsTab`), not only when
`state.selectedTab` names it: until 1.55 the iPad split view kept a selection
of its own that started on the Overview and followed `selectedTab` only
through `.onChange`, which does not fire for the value a view starts with. By
that code, an iPad capture of any screen would have been the Overview under
that screen's name, READY and all. Found by reading the code, then confirmed:
a build with the old selection stops the capture with `ERROR alerts: showing
the Overview screen, not Alerts`. The
pusher treats the iPad set as it does the iPhone's (compose.json, upload
before delete, rollback, read-back) and touches only the `APP_IPAD_PRO_3GEN_129`
sets of the IOS version, creating the ones a locale lacks (1.54.0 had an iPad
set on en-US and zh-Hans only, both English). Its `compose.json` records the
Pillow it was composed with, and the committed sets recompose byte for byte
with that version (`scripts/test_appstore_screenshots.py`).

The April 2026 set (`screenshots/ipad/`: English only, captured on a real iPad
signed in to the owner's account, with real project names, paths, alerts and
subscriptions, and cards and settings the app no longer has), its compositor
`compose_appstore_ipad_screenshots.py` and `generate_ipad_screenshots.swift`
were retired for 1.55.0. Git history keeps them; nothing reads them.

### Apple Watch screenshots (six languages)

The iOS version also carries an Apple Watch set (`APP_WATCH_ULTRA`, 422x514,
the size App Store Connect takes for the Apple Watch Ultra 3): the Watch app's
four pages (Pulse, Quota, Live, Alerts), captured from the Watch app itself on
the existing `Apple Watch Ultra 3 (49mm)` simulator by the same capture script.
The Watch app has a capture launch of its own (`WatchScreenshotLaunch.swift`,
DEBUG only, the same two arguments): it opens the requested page and holds
Demo's data as the Watch's own refresh would, since a Watch never sees the
phone's Demo (the phone relays nothing without a signed-in identity). That is
the dashboard through the cloud mapping (`APIClient.dashboardSummary(from:)`),
the legacy provider summary projected as `refreshAll` projects it, machine
cards only for devices that report machine health (`WatchDeviceTrim`), and each
list in its REST query's order. It never restores a session, activates
WatchConnectivity or refreshes. watchOS has no status-bar override and no
light appearance, so the Watch's clock reads the time of the capture.

A Watch panel is the capture itself, without a caption (a caption at 422x514
would be unreadable). simctl writes Watch screenshots with an alpha channel,
which App Store Connect refuses, so the compositor writes each one as opaque
8-bit RGB (any transparent pixel on black) and records `compose.json` like the
other sets, without captions.

```bash
# the "CLI Pulse iOS" Debug simulator build also builds the Watch app:
"CLI Pulse Bar/scripts/capture_ios_screenshots.sh" --set watch \
    --app <DerivedData>/Build/Products/Debug-watchsimulator/"CLI Pulse Watch.app"
                                                   # -> screenshots/watch-raw/<lang>/
python3 "CLI Pulse Bar/scripts/compose_appstore_watch_screenshots.py" --all   # -> watch-composed/<lang>/
python3 scripts/asc_push_screenshots.py --display-type APP_WATCH_ULTRA --version 1.56.0   # dry run
python3 scripts/asc_push_screenshots.py --apply --platform IOS --display-type APP_WATCH_ULTRA \
    --version 1.56.0
python3 scripts/asc_listing_preflight.py --texts-only --require-shots
```

Until 1.56 the store's Watch sets (en-US and zh-Hans only; every other locale
showed en-US's) were older captures, and `screenshots/watch/` held images
an AppKit script (`generate_watch_screenshots.swift`) drew with figures of its
own; that script and those images were retired for 1.56.0.

### Mac screenshots (six languages)

The Mac App Store set is drawn from the real SwiftUI views by the QA build's
offscreen renderer (docs/qa/macos-offscreen-renders.md, "The store set"), with
Demo data, composed with the iPhone set's caption code, and pushed per locale to
the macOS version's `APP_DESKTOP` sets. Seven store locales, six sets (es-ES and
es-MX share `es`).

```bash
xcodebuild build -project "CLI Pulse Bar/CLI Pulse Bar.xcodeproj" -scheme "CLIPulse QA" \
  -configuration "Debug QA" -destination platform=macOS -derivedDataPath build/qa   # restore Package.resolved after
scripts/render_macos_qa_views.sh --set store --app "build/qa/Build/Products/Debug QA/CLIPulse QA.app"
                                                   # -> screenshots/macos-raw/<lang>/ (+ render.json)
python3 "CLI Pulse Bar/scripts/compose_appstore_macos_screenshots.py" --all   # -> macos-composed/<lang>/
python3 scripts/asc_push_screenshots.py --platform MAC_OS --version 1.54.0     # dry run
python3 scripts/asc_push_screenshots.py --apply --platform MAC_OS --version 1.54.0
python3 scripts/asc_listing_preflight.py --texts-only --require-shots
```

**It shows only what the Mac App Store build has.** The QA build is Debug,
unsandboxed and on the `qa` channel, so the store set (`-CLIPulseRenderSet
store`, `QARenderSnapshot.storeCatalog`) draws only surfaces whose visible UI is
the same in the Mac App Store build: Overview (first and last page), Providers,
Alerts, the first page of Pet, and the usage panel that slides out of the
Overview. It leaves out Sessions (sells helper control and, unsandboxed, the
in-app terminal), Machine (reads a helper; differs sandboxed), Settings
(Companion CLI is hidden in QA only), the provider editor (a QA-only banner),
Subscription (no StoreKit products in QA), setup and signed-out pages (setup v2
flags are on in QA), and every Pet page after the first (the Debug build's test
buttons). `QARenderSnapshot.storeSurfaceProblem` refuses anything else, and
`QARenderSnapshotTests` plants each one. The store set refuses to run in a build
with `DEVID_BUILD`, and **`DEVID_BUILD` must never be defined in either `Debug
QA` configuration** (`scripts/ci_check_qa_scheme.py` fails if it is). The
Overview's Activity card and the usage panel read this Mac's local-scan archive,
so the store set writes a sample one (Claude and Codex only, what the scanner
records) inside the QA home before the app reads it, and refuses to write it
anywhere else.

Each language's `render.json` records what the build that drew it measured:
`devidBuild`, `remoteControlAvailable`, the language in effect and the region
it was formatted on (`-AppleLocale`, the iPhone capture's regions; Spanish on
Mexico's for both es-ES and es-MX), the backing scale, overlay scroll bars, the
local history's providers, the panel's settle and dark backdrop, the cost
shot's shortened popover (so the Overview scrolled to its end opens just above
a whole card, `QARenderSnapshot.alignedCard`), every file's md5, warnings and refused requests. The compositor,
`--require-shots` and the Mac pusher refuse raws whose `render.json` is not a
clean store render (`render_problems` in `scripts/appstore_screenshots.py`). A Mac `compose.json` also records the app
version that drew the set; the footer of every popover shows it ("CLI Pulse
v1.54.0"), so the pusher refuses `--apply --platform MAC_OS` unless it equals
`--version`: **each release that pushes Mac screenshots renders and composes
them again.** The raws and the sets are committed like the iPhone's; a caption
change in `compose_appstore_macos_screenshots.py` needs its recompose committed
with it (`--all`, from the committed raws; no QA build needed). The pusher
creates a missing `APP_DESKTOP` set, and when the old set and the new one would
not fit in App Store Connect's 10 it deletes only the overflow first (the rest
once the new ones are COMPLETE).

**What that costs the repository.** This repository is public and its history
keeps every committed PNG. One Mac set is about 46 MB (the raws about 29 MB, of
which the six 3x usage panels are about 15 MB; the composed panels about 17
MB), and because the footer carries the version, each release that pushes Mac
screenshots adds a new one rather than reusing blobs. Push new Mac screenshots
only in releases whose Mac UI changed; a release that keeps the listing's
screenshots needs no render. If that becomes routine, move the raws out of git
(a release asset, with render.json's md5s committed) rather than keep adding
them.

The v1.28 set (`screenshots/macos/`: English only, captured from a real signed-in
account, with the removed Swarm tab) and its generators
(`compose_appstore_screenshots.py`, `capture_macos_screenshots.sh`,
`generate_screenshots.swift`) were retired with the first set in this layout;
`appstore_metadata.py` and `resubmit.py` no longer upload Mac screenshots.

### Names that stay English in every language

"CLI Pulse", "Companion CLI" and "Yield Score" are names, not words to
translate: every `.lproj` catalogue, listing text, What's New and caption keeps
them in English, capitalized as here ("Yield Score" is the owner's call of
2026-09-30). `CompositionGrammarTests` pins Yield Score key by key in every
catalogue. For CLI Pulse it only keeps the name from breaking across lines and
checks that each catalogue uses it in more than 50 strings, so a single
translated "CLI Pulse" would still pass. `MacSettingsCopyTests` pins Companion
CLI, and the listing check's English-leftover heuristic accepts CLI Pulse and
Yield Score inside CJK text (`_ALLOWED_LATIN_NAMES` in
`scripts/appstore_listing.py`). The Yield Score card's hint names its switch by
the whole label, "Track git activity (Yield Score)", suffix included;
`MacSettingsCopyTests` pins that in every language. Traditional Chinese word
choices are a different list: `scripts/zh_hant_terms.json`.

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

## Remote Control (phone → Mac) — read this before touching `LAN*` files

Shipped 2026-09-04/05 in PRs #527, #528, #529, #530, #531, #532. A paired
iPhone watches, types into, starts, stops and approves AI-CLI sessions on the
Mac. Developer ID only: the MAS build has no `com.apple.security.network.server`
entitlement, so `MASSandboxGate` reports it unavailable there.

### Shape

```
iPhone  LANSessionControlClient ─┐                    ┌─ LocalSessionControlClient ── UDS ── helper
                                 │  TLS-PSK + frames  │
                                 └─ LANLinkAgentSession (in the APP, not the helper)
```

- **The frame layer is one thing**: 4-byte big-endian length + UTF-8 JSON, 1 MiB
  cap, four envelope kinds, per-subscription monotonic `seq`. `LANLinkChannel`
  is the seam; both a real `NWConnection` and an in-memory test pair conform, so
  the whole router is tested without sockets.
- **The agent lives in the app.** It holds the helper's auth token, which never
  crosses the network.
- **Redaction happens at egress**, in `LANEgressRedactor`, per session. The
  Swift helper's `output_delta` is NOT redacted (the Python one is) — this is
  the only thing standing between a secret and the network. Proven live at both
  layers 2026-09-04.

### Invariants — breaking one of these is the whole point of the feature

1. **No polling.** Nothing pulls; the socket and the helper's event stream push.
2. **No public or plaintext mode.** There is no unencrypted path and no
   unauthenticated topic.
3. **Pairing is QR + SAS + a Mac-side Approve**, 60 s, one at a time. The QR's
   expiry is enforced on BOTH the shown-QR and awaiting-approval states.
4. **Per-phone permission is proven at the application layer**: hello carries
   the phone's did plus an HMAC over the connection's RFC 5705 exporter, keyed
   by the shared per-peer key. Do NOT try to read the TLS PSK identity on the
   server — it works on macOS 26.5 and returns nothing on CI's older macOS, and
   installing a selection block CHANGED the handshake there.
   ⚠️ The paired records are **asymmetric**: on the Mac `id` is the phone's did,
   on the phone `id` is the MAC's did. The phone must bind with
   `PairedPeer.phoneDeviceID`, never `peer.id`. Sending the wrong one silently
   downgrades the link to read-only, and a symmetric test id will not catch it.
5. **`local_control_enabled` is the user's revocation lever** and is re-checked
   every heartbeat, fail-closed. The helper checks it only once per
   subscription, so the agent must keep asking.
6. **Do not touch `RemoteSessionPlane.isEnabled`.** That is the RETIRED cloud
   session plane's switch, mirrored in the app and the helper and drift-gated.
   It is unrelated to this feature.

### Gotchas that have already cost time

- The Mac's listener is **not** Wi-Fi-only: nothing constrains its interfaces.
  It binds a remembered port (default 51000) so a typed address stays valid.
- `posix_spawnp` searches the PARENT's PATH. The helper's LaunchAgent PATH is
  bare, so provider argv[0] must be an absolute path resolved through the
  augmented search — otherwise "available" providers fail to spawn.
- Approvals expire. `decide` refuses a past-TTL row, `waitForDecision` expires
  the row it timed out on, and the daemon sweeps every 5 s. Before this, a late
  approval "succeeded" after Claude had already fallen back to deny.
- A short PTY write is lost input, not success. The master is non-blocking.
- Driving Claude Code's TUI blind: text and the carriage return in one burst is
  treated as a PASTE and the return is swallowed. Send the text, wait ~10 s,
  then send `\r`.
- `swift test` here compiles macOS only; the iOS-only screens
  (`LANRemoteScreens.swift`) need the `CLI Pulse iOS` scheme to be type-checked.
- 🚨 **A green `swift test` is HALF the suite.** CI runs it twice —
  plain, and `swift test -Xswiftc -DDEVID_BUILD`
  (`.github/workflows/swift-ci.yml:240`). `Package.swift` does not define
  `DEVID_BUILD`, so the default pass compiles every `#if DEVID_BUILD` file —
  `AppUpdater.swift` among them — to NOTHING. Measured 2026-09-08: plain
  = 3020 tests, DEVID = **3057**. Adding one field to `AppUpdater.Manifest`
  built and tested clean locally and broke `AppUpdaterTests` in CI, because
  neither the change nor its existing tests were compiled here. **Run both
  passes before trusting a green run on anything DEVID-gated**, and prefer a
  `#if DEVID_BUILD` behavioural test to a source guard — the source guard was
  written on the false belief that CI could not compile the file either.
- 🚨 **This Mac's SDK is a generation ahead of CI's, so a local green does not
  mean CI compiles.** `swift-ci.yml` runs on `macos-15` (`lint-ci.yml` on
  `macos-14`); a dev machine here is macOS/Xcode 26.x. Measured 2026-09-07:
  `case .wifiAware` on `NWError` — a case the macOS 26 SDK added and the
  compiler explicitly suggests adding — compiled locally, passed 3005 tests
  and an iOS Simulator archive, and was `error: type 'NWError' has no member
  'wifiAware'` on the runner. For a non-frozen enum from a framework, prefer a
  plain `default:`; `@unknown default` is only safe once every case you NAME
  exists on `macos-15` too. The same caution applies to any recently-added
  API, and to `xcodebuild -destination 'generic/platform=iOS Simulator'` run
  here — it uses the local SDK, not CI's.

- ⭐ **Before building a mechanism to collect evidence, count the population
  that could ever supply it.** 2026-09-08: a staged rollout was designed —
  allowlist, `rollout_percent`, hash bucketing — to make the §8 remote-control
  latches produce readings. The addressable population was **one**: of 12
  installs, 10 are `mas` (`MASSandboxGate` refuses before the feature gate is
  read) and the 2 `devid` are the owner plus one install seen once and never
  again. The bucketing alone produced three of that review's seven findings.
  The bottleneck was distribution, not instrumentation, and no mechanism fixes
  that. Run the channel counts first; they are one query.

### Verification tooling

`/tmp/pairprobe` is a scripted phone built against `CLIPulseCore`, so it drives
the SHIPPING code paths: `pairprobe <clipulse://pair…>` to pair, `resume` for
the read surface, `control` for M1 (env `PAIRPROBE_START/CWD/RC/SESSION/INPUT/
DECIDE/STOP`). When a hardware check has two possible causes, log the
discriminator — a "Forget closed the link" result was once fully explained by
the probe's own timeout firing at the same moment.

### Owner gates

The ciphertext relay (plan M2) is NOT built. Its design failed review on five
blockers, and Tailnet connect-by-address shipped instead. If it is ever built,
its `realtime.messages` RLS migration is an **owner gate** — do not apply
migrations. The Phoenix client it needs already exists in git history at
`e067c4fb^` (`RemoteSessionEventStream.swift`, 591 lines); port it rather than
writing one.

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

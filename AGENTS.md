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

# 3. Screenshots, per locale (scripts/asc_push_screenshots.py): iPhone on IOS,
#    the six-language Mac set on MAC_OS
python3 scripts/asc_push_screenshots.py --platform IOS --version 1.54.0      # then --apply

# 4. The store against the repo, for the version being prepared
python3 scripts/asc_listing_preflight.py --version 1.54.0 --whatsnew-dir whatsnew_154

# 5. What's New, build, submission, once the build is VALID (--list-builds ios)
python3 scripts/asc_submit.py --submit ios --build <BUILD_ID> --version 1.54.0 \
    --whatsnew-dir whatsnew_154                                              # then --apply
```

Repeat 1, 2, 3 and 5 with `macos` / `MAC_OS` (step 3 then pushes the Mac
set: see "Mac screenshots" below). Both versions are created with
`--release-type AFTER_APPROVAL` (the owner's choice for 1.53.0 and 1.54.0): App
Store Connect releases each one as soon as it is approved. `asc_submit.py`
defaults to MANUAL, which waits for the owner to release it in App Store
Connect, so the flag has to be passed.

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
(step 2 has not run; `--allow-missing-locales` overrides), or the build is not
`VALID`, is for another platform or version, or the store does not say which
platform and version it belongs to. With `--apply` it writes What's New where it
differs, reads it back, and only then attaches the build and submits. The old
`--whatsnew` fallback file is retired: it is how English notes once reached
every storefront. Tests, both run by `repo-hygiene.yml`:
`scripts/test_asc_submit.py` (offline, against a fake App Store Connect) and the
What's New cases in `scripts/test_asc_listing_preflight.sh`.

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

The preflight reads ASC (read-only, GETs only) and checks three things the repo
cannot answer:

1. **SKU-vs-copy** — the description must not name a tier whose SKU is not
   `APPROVED`. This compares the store's words against the store's own product
   catalogue, so it needs no repo source and cannot go stale.
2. **Listing drift** — every live locale's description, keywords, promotional
   text and subtitle vs `CLI Pulse Bar/appstore/<locale>/`, and every repo
   locale present on the store.
3. **Screenshot drift** — every live screenshot vs the local composed PNG of the
   same name, compared on decoded pixels because ASC re-encodes on ingest.

⚠️ **Drift runs in both directions.** On 2026-08-31 the store was stale on the
subscription paragraph *and* newer than the repo on the privacy section.
Pushing either side verbatim would have regressed the other. Read both lists the
script prints before acting.

The store comparison needs the ASC key, so it cannot run in CI — it is a
release-time step on the owner's machine. Exit 2 means it could not check, which
is not a pass. The repo-text half (`--texts-only`: limits, keyword format,
Guideline 2.3.10 platform names in six languages, untranslated English, inline
copies in pushers) runs in `repo-hygiene.yml`, with `--require-shots` (every
listing locale's five composed iPhone panels and six composed Mac panels, their
`compose.json`, the committed raws they were drawn from, and for the Mac a
`render.json` that says a clean store render drew them).

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
shot's shortened popover (so the Overview scrolled to its end opens above a
card), every file's md5, warnings and refused requests. The compositor,
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
2026-09-30). `CompositionGrammarTests` pins CLI Pulse and Yield Score in every
catalogue, `MacSettingsCopyTests` pins Companion CLI, and the listing check's
English-leftover heuristic accepts CLI Pulse and Yield Score inside CJK text
(`_ALLOWED_LATIN_NAMES` in `scripts/appstore_listing.py`). A string that sends
people to a switch names it by its whole label: the Yield Score card's hint says
"Track git activity (Yield Score)", suffix included. Traditional Chinese word
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

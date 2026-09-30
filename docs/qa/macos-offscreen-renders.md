# macOS views, rendered offscreen in every language

The Mac app's six languages were checked by unit tests, which prove a key
resolves, not that the result fits, reads well or sits where it should. This
renders the real SwiftUI views of the QA build, offscreen, once per language,
and writes PNGs plus a `manifest.json` for native review. Nothing is shown on
the screen of whoever is using the Mac while it runs.

## Run it

1. Build the QA app (`CLIPulse QA` scheme, `Debug QA` configuration):

   ```bash
   xcodebuild build \
     -project "CLI Pulse Bar/CLI Pulse Bar.xcodeproj" \
     -scheme "CLIPulse QA" -configuration "Debug QA" \
     -destination platform=macOS -derivedDataPath build/qa
   ```

   A local Xcode build rewrites
   `CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`;
   restore it before committing.

2. Render all six languages:

   ```bash
   scripts/render_macos_qa_views.sh \
     --app "build/qa/Build/Products/Debug QA/CLIPulse QA.app" \
     --out build/qa-renders
   ```

   Options: `--lang ja` (repeatable; default en, zh-Hans, zh-Hant, ja, ko, es),
   `--appearance dark`, `--replace` to overwrite an earlier run, `--timeout`
   seconds per language (default 600). Measured on 2026-09-27: about 70
   seconds and 72–78 PNGs per language, seven minutes and 61 MB for all six.

Output: `build/qa-renders/<lang>/NN-<id>.png`, `NN-<id>-p2.png` … for the
further pages of a view taller than its window, `manifest.json` and
`render.log`. Files are numbered in drawing order.

### What the script checks before it starts

- the app is the QA build (`app.clipulse.qa.local`, channel `qa`);
- no `CLIPulse QA` process is running (it would share the QA defaults domain);
- the login keychain holds no `com.clipulse.app.qa` or
  `com.clipulse.app.quarantine` item. The QA build is ad-hoc signed, so an item
  one QA build wrote makes macOS ask on screen when a rebuilt one reads it. It
  checks again afterwards that the run created none;
- `/private/tmp/clipulse-qa-home` exists, is a directory, not a symlink, owned
  by you, mode 700 — the scheme pre-action's own steps. Each language runs with
  `CFFIXED_USER_HOME` set to a fresh subdirectory of it, removed afterwards.

## How it works

`-CLIPulseRenderSnapshots <dir>` on the QA app's executable, with the language
given twice, `-AppleLanguages "(ja)"` for AppKit and formatters and
`-cli_pulse_locale_override ja` for the app's own catalogue. Both go through
the argument domain, so the run writes no language choice anywhere.
`QARenderSnapshot.resolve` (CLIPulseCore) refuses anything else: a build that
is not QA or not launched with its isolated home, a missing or unshipped
language, languages that disagree, a repeated argument. A refusal exits with
status 64 and never starts the app.

The render mode is compiled only into the QA app. `QASnapshotRenderer.swift`
and the small hooks in `SettingsTab` and the two setup wizards are inside
`#if CLIPULSE_QA_RENDER`, which only the app target's `Debug QA` configuration
defines; `scripts/ci_check_qa_scheme.py` fails if any other configuration does.
In the QA app the entry point is `CLIPulseQAEntryPoint`, which calls
`CLIPulseBarApp.main()` whenever the argument is absent; in every other build
`CLIPulseBarApp` is `@main` as before. CI builds the QA scheme in the full
matrix so the renderer cannot stop compiling unnoticed.

In render mode the process:

- sets its activation policy to `.prohibited` (no Dock icon, no menu bar, never
  frontmost) and never creates `CLIPulseBarApp`, so there is no status item;
- draws each view in a borderless `NSWindow` that is never ordered in, through
  `NSHostingView` and `cacheDisplay`, at 2 pixels per point (3 for the store
  set), with the window reporting that backing scale whatever the screen;
- uses the QA runtime, which already refuses the helper, collectors, StoreKit,
  telemetry, widgets and production endpoints, and in addition switches off
  notifications (the Alerts tab would ask macOS for permission, a prompt on
  screen) and provider status checks, and refuses every request through the
  shared URL session, listing any in `blockedRequests`. That list only covers
  `URLSession.shared`: a session built from its own configuration, such as
  APIClient's, is not routed through it, so an empty list is not proof that
  nothing left the process. Sampling the process's sockets during a run
  (`lsof -nP -a -p <pid> -i`) is; it showed none in the runs so far;
- empties the QA defaults domain for a reproducible run and restores it as it
  was before exiting (the script restores it too, in case the process died).

Note that `CFFIXED_USER_HOME` does not redirect preferences on current macOS:
`defaults` writes land in `~/Library/Preferences/app.clipulse.qa.local.plist`
whatever it is set to. The QA build's preferences are isolated from
production's by bundle identifier, not by the QA home. The home does isolate
files: Application Support, discovery's look for `~/.codex` and the like.

It does not isolate `PATH`. Discovery also looks for installed `codex`,
`claude` and `gemini` commands on the `PATH` the script inherits, so the setup
v2 discovery, review and connection pages say "CLI installed" for whichever of
them the Mac running the script has. The manifest's `dataSource` covers the QA
sample accounts, not that signal.

## What is drawn

The popover is `MenuBarView` with the environment the `MenuBarExtra` scene gives
it, 380×580 points (its default height). Windows are drawn as their content,
without title bar; the manifest note gives each window's localized title.
Popovers and windows get an opaque window-background fill, standing in for the
material an offscreen window does not have. A view taller than its window is
drawn page by page by scrolling its main scroll view, pages overlapping by 48
points.

Setup and signed-out screens use the QA build's five sample accounts; the rest
use Demo mode (`DemoDataProvider`, the iPhone app's Try Demo data), entered the
way the QA build enters local mode, with the five sample accounts switched on
as finishing setup with them would (the seed leaves them off, and Providers
would show only "All providers hidden").

Views are told they are in the key window (`controlActiveState`), as the open
popover is, so prominent buttons take the accent colour. AppKit-drawn switches
and segmented controls keep their inactive tint: a process that may never be
activated cannot have active controls. Read a switch's state from its knob.

| id | what |
| --- | --- |
| `first-launch` | First open on a new install: the anonymous-statistics notice, which scrolls together with the setup wizard below it (`-p2` is the wizard) |
| `setup-step-1` … `setup-step-5` | The production setup wizard: welcome, features, privacy, sign in, all set |
| `setup-v2-welcome` … `setup-v2-sync-mode` | Setup v2, off in production and on in QA; discovery onwards as the existing-user flow with three of the five accounts chosen |
| `setup-v2-finished-local`, `-sync` | Setup v2's finish page, local-only and cloud-sync |
| `local-scan-consent` | Local mode asking before it reads the Mac |
| `local-scan-consent-older-logs` | A 30-day "yes" on file, asked once about reading up to a year of older logs (disclosure v2) |
| `signed-out-overview` … `signed-out-settings` | Signed out: Overview, Providers, Sessions, Alerts, Settings (email code) |
| `signed-out-settings-password` | Signed out, Settings with password sign-in |
| `demo-overview` … `demo-pet` | Demo data: Overview, Machine, Providers, Sessions, Alerts, Pet |
| `demo-settings-general` … `-advanced` | Demo data, Settings, each of the four sections |
| `demo-setup-v2-upgrade-prompt` | Setup v2's prompt to existing users (QA flags) |
| `demo-settings-setup-v2-rerun` | Settings with setup v2's rerun card (QA flags) |
| `window-about` | About |
| `window-subscription` | Subscription (the QA build loads no StoreKit products); drawn at 460×700 |
| `window-provider-codex`, `-claude`, `-gemini` | Provider account editor |
| `panel-usage-dashboard` | The usage dashboard panel that slides out of the popover, dark as always. Drawn from the Demo archive so its layout can be read with data; the real panel, and the Overview's usage card, read this Mac's local-scan archive, which the QA home leaves empty. The Demo archive has Gemini in it and the local-scan archive never does (the scanner records Claude and Codex), so the "Claude + Codex" caption over Gemini rows is the render's, not the app's. The headline number counts up for 2.2 seconds and may be caught short of the total below it |
| `window-first-run-welcome` | Where-the-app-lives window shown once after install |
| `language-menu` | The globe menu's items, read from its real `NSMenu` (see below) |

`manifest.json` lists every PNG with its id, kind, page, size in points and
pixels, and a `suspectBlank` flag; the language actually in effect three ways
(`localeOverride`, `resolvedLocalization` for the catalogue, `appKitLocalization`
for AppKit) and a `localizationProbe` of catalogue keys next to their English;
the settings the run changed (`forcedSettings`); the surfaces it cannot draw and
why (`skipped`); `blockedRequests`; and `warnings`.

### The language menu

SwiftUI fills the globe button's menu only as it opens. The popup button's
delegate does that in `popUpButtonCell:willShowMenu:`, which the renderer
calls without opening the menu, then reads the real `NSMenu`: titles in order,
which is checked, separators. `languageMenu.source` is `nsmenu` in that case,
and the `language-menu` picture is drawn from those items (a menu cannot be
drawn without opening it on screen). Because the picture is redrawn, it cannot
show the size the real menu opens in, so `languageMenu.fontPointSize` records
the real menu's font and a warning fires when it is smaller than the system
font: `.controlSize(.mini)` on the globe button once shrank the whole menu to
9 pt while every picture looked right. If a future SwiftUI drops that hook, the
source becomes `languageOptions-fallback`, the items are rebuilt the way
`LanguagePickerMenu` builds them, the picture is named
`language-menu-fallback`, and a warning says so.

### Not drawn

Listed in `skipped` with reasons: the status item, the terminal window (needs
a helper session), the Developer ID-only terminal menu and updater section,
confirmation alerts and the pet naming sheet (they need a window on screen),
Settings' Companion CLI section (hidden in QA) and pairing section (needs a
real sign-in), and the remote-control card when the build does not offer it.

## The store set: the Mac App Store screenshots

`--set store` (the app's `-CLIPulseRenderSet store`) draws the raw material of
the Mac App Store screenshots instead of every view:

```bash
scripts/render_macos_qa_views.sh --set store \
  --app "build/qa/Build/Products/Debug QA/CLIPulse QA.app"
```

It writes `CLI Pulse Bar/screenshots/macos-raw/<lang>/` (or `--out`), rendering
each language into a hidden staging directory beside it and swapping it in
whole only when the app exited 0; a failed language is left in
`<lang>.rejected/` with its log, and the folder stays as it was. Measured on
2026-09-28: about 25 seconds per language.

**Why a subset.** The QA build is not the Mac App Store build. It is Debug
(`DEBUG` is defined), unsandboxed (`MASSandboxGate.isSandboxed` is false) and on
the `qa` channel; the Mac App Store build is Release, sandboxed and production.
Neither defines `DEVID_BUILD`: it is passed only by `build_signed_app.sh` for the
Developer ID archive, `ci_check_qa_scheme.py` fails if either `Debug QA`
configuration gains it, and the store set refuses to run (exit 64) in a build
that has it. So the store set draws only surfaces whose visible UI depends on
none of the three differences (`QARenderSnapshot.storeCatalog`, checked by
`storeSurfaceProblem`):

| file | what |
| --- | --- |
| `01_overview.png` | Overview, first page |
| `02_providers.png` | Providers, first page |
| `03_usage_history.png` + `03_usage_history.panel.png` | Overview, first page, and the usage panel that slides out to its left |
| `04_cost.png` | Overview, scrolled to its end, in a shorter popover so it opens just above a card: the first one `01_overview` did not show whole, or the one above it when that would need a popover under 400 points (`lastAligned`, below) |
| `05_alerts.png` | Alerts |
| `06_pulse_cat.png` | Pet, first page |

Left out, and why: Sessions (offers helper control of Claude sessions and,
unsandboxed, the in-app terminal; the Mac App Store build ships neither),
Machine (reads a helper the QA build refuses, and shows a different affordance
sandboxed), Settings (Companion CLI is hidden in QA and shown in the Mac App
Store build), the provider editor (a QA-only banner), Subscription (no StoreKit
products in QA), setup and signed-out pages (setup v2 is on in QA and off in
production), Pet after its first page (the Debug build's test buttons), the
language menu (drawn from menu items, not a screenshot).

**What is different from the review set.**

- 3 pixels per point, and the offscreen window reports that backing scale
  itself (`QARenderWindow`). Views rasterize their layers at their window's
  scale; a window never ordered in takes the main screen's, which was 1 on a
  Mac whose main display is not Retina, and a 3x bitmap then held 1x text blown
  up threefold. `render.json` records `windowBackingScale`, and the App Store
  pipeline refuses anything but 3.
- The popover height is pinned to its default, 580 points
  (`cli_pulse_menubar_height`), except for `04_cost`. The Overview scrolled
  flush to its end opens wherever its length puts it: in 1.54 on half a line
  of the Yield Score card's text, in 1.55 (no Top Projects or Risk Signals in
  Demo) on the bottom edge of the Activity card, followed by the Hourly
  Activity card `01_overview` already shows. A `lastAligned` page is drawn
  once at 580 and its scroll content measured from its layer tree
  (`ScrollLayout`: each card is `glassCard`'s frosted-glass backdrop layer,
  each run of text or shape a layer of its own). `QARenderSnapshot.alignedCard`
  picks the first card that reaches below the first page and starts at or
  below the last page's top edge (Provider Usage in 1.54), and the page is
  drawn again in a popover shortened by `alignedTrim`, so its top edge falls
  4 points above that card, where the first page left off. When that would
  take the popover under the 400 points users can drag it to, it picks the
  card above instead (1.55: Demo's Gemini has no cost row, so the first page
  shows the whole Cost Summary, and a page opening on Provider Usage alone
  would need 276 points; it opens on Cost Summary). It must then cut through
  no layer and open on that card, or the run
  fails. Pixels could not do this: the cards' shadows fill the 12 points
  between them, so no row there is plain background, and 1.55's page read as
  one card from the top edge down. Users drag the popover anywhere from 400
  to 900 points, so the shorter one is a real state; `render.json` records its
  height (`shots[].popoverHeight`: 406 in 1.55, 552 in 1.54), and the
  compositor draws it at the set's scale, centred in the room a full popover fills.
- Overlay scroll bars: the script passes `-AppleShowScrollBars WhenScrolling`.
  A Mac set to show scroll bars "Always" (the render Mac of 2026-09-28 was)
  gives every scrolling tab a legacy scroller's gutter, which the offscreen
  drawing leaves empty: the content sat 12 points from the left edge and 29
  from the right. `variant.scrollerStyle` must be `overlay`.
- Each language on its own region: `-AppleLocale` (`locale_for` in the script,
  the iPhone capture's list: en_US, zh_CN, zh_TW, ja_JP, ko_KR, es_MX), so
  separators, the clock and the first weekday are that region's, not the
  render Mac's. `displayLocale` must name it. Spanish serves es-ES and es-MX
  with one set, drawn on Mexico's region like the app's own Spanish ("costo"),
  so es-ES shoppers see "12,175,297", not Spain's "12.175.297".
- **The local usage history.** The Overview's Activity card and the usage panel
  read this Mac's local-scan archive (`DailyUsageArchiveManager`), which the QA
  home leaves empty ("No local usage history yet"). Before anything reads it,
  the store set writes `QARenderSnapshot.storeLocalScanSample` there: the Demo
  archive's days without Gemini, so Claude and Codex only (what the scanner
  records, which keeps the panel's own "Claude + Codex local history" line
  true), with Claude's message counts, today's figures equal to the Demo
  dashboard's. It writes only when both the home and the archive's directory
  resolve (realpath) inside `/private/tmp/clipulse-qa-home`, reads the archive
  back through the app's own manager, and refuses a history holding any other
  provider, no days or no messages, before and after drawing.
- The usage panel is built as `DashboardPanelController` builds it: from the
  local history the app loaded, 520 points wide (its width whenever the popover
  sits at the right of an ordinary screen), dark, with its close button, and
  drawn only once two drawings half a second apart are identical (its headline
  counts up for 2.2 seconds). Its HUD backdrop (`NSVisualEffectView`,
  `.behindWindow`) has no desktop behind it offscreen and drew as a flat
  mid-gray slab, so the renderer switches it to `.withinWindow` over the
  panel's dark fill; `variant.panelBackdropLuminance` (measured in the corner)
  must be at most 0.25 (it measures 0.13; the gray slab was about 0.36).
- Stricter exit: any warning, refused request or blank-looking render fails the
  run (5, 3), and so does a local history it could not write or read back (66).

`render.json` (instead of `manifest.json`) adds `set: "store"`, the `variant`
the build measured about itself (`devidBuild`, `debugBuild`, `sandboxed`,
`channel`, `remoteControlAvailable`, the popover and panel sizes, the panel's
settle and backdrop luminance, the scroll bar style, and the local history's
days, providers and messages), `displayLocale`, and `shots`: each shot's page,
a shortened popover's height and every file's md5. The App Store compositor
(`compose_appstore_macos_screenshots.py`) and `asc_listing_preflight.py
--require-shots` refuse raws whose `render.json` is not a clean store render in
that language (`render_problems` in `scripts/appstore_screenshots.py`), and so
does `asc_push_screenshots.py --platform MAC_OS` before it contacts the store. How the
panels are composed and pushed: AGENTS.md, "Mac screenshots (six languages)".

## Exit status

The app: 0 clean; 3 some render looks blank; 4 a coverage warning (for example
`SettingsTab` gained a section the catalog does not name); 5 a store-set
warning (including legacy scroll bars, a gray usage panel, and a cost page
that cannot open above a card); 64 refused (including the store set in a `DEVID_BUILD` build); 65 the
language was not in effect; 66 the store set's local history could not be
written inside the QA home or read back; 67 a store shot that is not allowed;
70 watchdog (15 minutes); 73 output directory not usable or not empty; 74
manifest not written. The script returns 2 if any language did not exit 0.

## Adding a view

Add a case to `QARenderSurface` and to `QARenderSnapshot.catalog`
(CLIPulseCore), and draw it in `QASnapshotRenderer.render`. The switch there is
exhaustive, so the app will not build until the new case is drawn.
`QARenderSnapshotTests` checks that every visible tab, every setup step and the
known windows are in the catalog.

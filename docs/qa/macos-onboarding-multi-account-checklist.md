# macOS Onboarding + Multi-Account QA Checklist

> This document was originally headed "Internal/private-source QA only". That
> was written on the assumption that `cli-pulse-private` is a private
> repository. It is public — the name is the trap, and AGENTS.md stated the
> false version until #402. Nothing here is sensitive: every value in the table
> below is already a literal in `CLIPulseRuntimeEnvironment.swift`, which ships
> in this repo. So the note is corrected rather than the file hidden.
>
> The original warning's real content still stands, and is narrower than it
> looked: do not copy this file or the app source into **`cli-pulse-distrib`**,
> the release-artifact repository.

## Purpose

Use the `CLIPulse QA` Xcode scheme to experience the real macOS onboarding and
multi-account UI with deterministic, non-secret sample accounts. This build is
for product review only; it is not a production-signed build and does not prove
release readiness.

The QA build is expected to use:

| Item | Expected value |
| --- | --- |
| Scheme | `CLIPulse QA` |
| Build configuration | `Debug QA` |
| Main bundle ID | `app.clipulse.qa.local` |
| Helper bundle ID | `app.clipulse.qa.local.helper` |
| QA home | `/private/tmp/clipulse-qa-home` |
| Signing | Local ad-hoc; no development team |
| App Group / production entitlements | None embedded |

## Safety rules

- Do not enter a real email, password, OTP, API key, cookie, or provider
  credential.
- Do not install or register the Companion CLI helper from this build.
- Do not change `CFFIXED_USER_HOME`; it must remain exactly
  `/private/tmp/clipulse-qa-home`.
- Do not run the production `CLI Pulse Bar` scheme for this review.
- Use Xcode Stop (`Command-.`) when the review is finished.
- The QA build blocks production telemetry, StoreKit bootstrap, helper
  registration/control, production Supabase endpoints, live quota collection,
  widget publishing, and production Keychain namespaces.
- Provider status badges use separate, read-only public status-page requests
  when the Providers screen is shown. A zero-network/offline audit is outside
  this checklist.

## Start the QA app

1. Open
   `CLI Pulse Bar/CLI Pulse Bar.xcodeproj` in Xcode.
2. Select scheme `CLIPulse QA`.
3. Select destination `My Mac`.
4. Open **Product → Scheme → Edit Scheme… → Run → Arguments** and confirm:
   - `CFFIXED_USER_HOME` is enabled and equals
     `/private/tmp/clipulse-qa-home`;
   - `CLIPULSE_QA_RESET_ON_LAUNCH` is enabled and equals `0`.
5. Press Run (`Command-R`).
6. The app is a menu-bar app (`LSUIElement`), so it does not normally appear in
   the Dock. Click the CLIPulse icon in the macOS menu bar to open it.

Expected startup result:

- Xcode runs a process/product named `CLIPulse QA`;
- no Keychain, folder-access, helper-installation, StoreKit, login, or telemetry
  prompt appears;
- the first-run onboarding opens in the menu-bar popover;
- the production app's preferences and accounts are not shown.

Stop immediately and record an issue if the app launches as `CLI Pulse Bar`,
shows a production account, or asks for a real credential/permission.

## Fresh onboarding flow

Mark each item after checking it.

- [ ] **Welcome:** the first screen explains agent usage, multiple accounts,
  and local credential handling.
- [ ] **Welcome escape:** `Set Up Later` and the top-right close button are
  reachable.
- [ ] **Privacy:** the privacy cards are readable without clipping at the
  default popover height.
- [ ] **Back navigation:** Back returns to the preceding screen without losing
  already selected information.
- [ ] **Discovery:** passive discovery finishes without a permission or
  credential prompt.
- [ ] **Discovery accounts:** all five sample accounts are distinguishable:

  | Provider | Account label | Plan |
  | --- | --- | --- |
  | Codex | `Codex · Personal` | `Plus` |
  | Codex | `Codex · Work` | `Team` |
  | Claude | `Claude · Personal` | `Pro` |
  | Claude | `Claude · Work` | `Max` |
  | Gemini | `Gemini · Personal` | `Advanced` |

- [ ] **Selection:** select and deselect accounts individually; one account's
  toggle must not change another account.
- [ ] **Review:** the review screen contains exactly the selected accounts,
  preserving provider, account label, and plan.
- [ ] **Review round trip:** go Back to Discovery, change the selection, then
  return to Review and confirm the new selection.
- [ ] **Close and resume:** close the wizard on Review, stop the app, relaunch
  with reset still set to `0`, and confirm the flow resumes at the saved step
  with the saved selection.
- [ ] **Connection:** selected accounts can reach the optional connection
  screen. Do not enter or save a credential. If `Open Account Settings` is
  inspected, close the window without saving.
- [ ] **Mode choice:** the final choice clearly distinguishes cloud sync from
  local-only use. You may inspect the sync form, but do not submit it.
- [ ] **Local-only completion:** choose Local Only, continue to the completion
  screen, verify the selected account summary, and press Done.

## Demo dashboard and multi-account review

After Local Only completion:

- [ ] the app enters the normal tab shell instead of starting a live collector;
- [ ] Overview renders in-memory demo content without an empty-state trap;
- [ ] Providers shows separate Codex, Claude, and Gemini provider cards;
- [ ] Codex and Claude expose two distinct account rows/counts;
- [ ] account labels remain `Personal` versus `Work`, with no ambiguous
  duplicate row;
- [ ] enabling/disabling one sample account does not toggle its sibling;
- [ ] navigating Overview → Providers → Sessions → Alerts → Settings does not
  trigger a credential, Keychain, helper, StoreKit, or folder-access prompt;
- [ ] stopping and relaunching with reset `0` resumes the QA/demo state.

The demo values are synthetic and may vary where the existing demo generator
uses randomized chart points. Do not evaluate token accuracy, cost accuracy, or
quota freshness from this build.

## Replay from a clean QA state

`CLIPULSE_QA_RESET_ON_LAUNCH=1` removes only the QA home's onboarding,
provider-metadata, and demo-state keys before reseeding. It does not delete
production preferences or production Keychain items.

1. Stop the QA app in Xcode.
2. Open **Edit Scheme… → Run → Arguments**.
3. Change `CLIPULSE_QA_RESET_ON_LAUNCH` from `0` to `1`.
4. Run once and confirm the Welcome screen appears with all five seeded sample
   accounts available later in Discovery.
5. While that run is active, change the scheme value back to `0`. The running
   process keeps its launch-time value, while the next launch will preserve
   progress.
6. Never leave reset set to `1` when testing relaunch/resume behavior.

The scheme's pre-action may create the fixed QA directory and set its mode to
`0700`. It deliberately refuses a symlink, a non-directory path, or a directory
owned by another user; it does not delete the directory.

## Not validated by this QA build

- real Codex, Claude, Gemini, or other provider credentials;
- real quota/token/cost collection or first-party freshness comparison;
- Supabase sign-in, cloud sync, pairing, or production backend behavior;
- production Keychain access-group sharing or App Group behavior;
- Companion CLI helper installation, registration, IPC, or launch-at-login;
- StoreKit products, purchase, restore, or entitlement transitions;
- production Developer ID/App Store signing, sandboxing, notarization, update,
  archive, or distribution;
- iOS, watchOS, widgets, Live Activities, or cross-device behavior;
- telemetry delivery, notification delivery, or external status-page accuracy.

## Issue record

Capture screenshots without real account information. One row per issue:

| ID | Step/screen | Expected | Actual | Severity | Screenshot/log |
| --- | --- | --- | --- | --- | --- |
| QA-001 |  |  |  | Blocker / Major / Minor |  |

Before proposing a PR or merge, record:

- completed checklist items;
- every reproducible issue and exact navigation path;
- whether the issue also occurs after a clean QA reset;
- macOS and Xcode versions;
- the tested commit SHA;
- any unexpected prompt, external request, or production-looking data.

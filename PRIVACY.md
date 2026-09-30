# Privacy Policy

**CLI Pulse**
**Last Updated: October 1, 2026**

CLI Pulse is a developer tool for monitoring usage, quotas, and cost across AI
coding providers (Claude, Codex, Gemini, OpenRouter, and others). Our privacy
goal is straightforward: **your provider API keys never reach our servers**
(CLI Pulse sends each one only to the provider it belongs to). Apart from what
signing in needs, crash reports, the anonymous install statistics, and a few
diagnostic readings about each Mac (all described below), everything CLI Pulse
uploads is there to show your usage and alerts on your other devices, or
wherever you asked for alerts to go, and this document lists all of it,
including the parts that are not numbers.

This document is the single source of truth for what we collect. If you find
anything in the app, App Store listing, or GitHub README that contradicts this
file, **the file wins** — please open an issue.

It describes CLI Pulse 1.55.

---

## What this covers

* **The Mac app**, which comes in two builds:
    * the **App Store build**, which runs in Apple's App Sandbox: outside its
      own container it reads files only through the folder access you grant it
      in Settings › Advanced › CLI Tool Access;
    * the **direct-download build** (from our website or GitHub, and the one
      Homebrew installs), which is not sandboxed and reads the files named in
      this document directly.
* **The app's background helper**, which runs the same collectors as the app
  on its own schedule (every 2 minutes by default) and uploads what it finds
  for your iPhone and Apple Watch. It is switched on when you pair this Mac with
  your account, and off with Settings › Advanced › "Enable background sync".
  It is sandboxed in the App Store build and not in the direct-download build.
* In the direct-download build only, **a local agent built into the app**
  (shown as "Built-in" under Settings › Companion CLI). It runs the sessions you
  start from CLI Pulse and answers the app's questions about this Mac. It
  uploads nothing.
* **The Companion CLI**, an optional, separate program you can install from
  Settings › Companion CLI. It has its own schedule and its own pairing with
  your account, and is described in its own section below.
* **The iPhone app** (with its widgets) and **the Apple Watch app**. They show
  what your Macs synced. They read nothing from AI tools on the phone or watch.

Remote control between an iPhone and a Mac is built into the direct-download
build but is off in this release: the Mac shows no Remote Control section in
Settings until the feature is switched on, and we can switch it on later through
the update information the app downloads. Once it is offered and you turn it on,
the iPhone and the Mac connect to each other directly, over your local network
or your own private network (such as Tailscale), encrypted with TLS 1.2 using a
key the two devices agree on when you pair them; what they exchange does not
pass through our servers.

---

## Data-by-data breakdown

| Data | Stored where | Sent to our server? | Purpose |
|---|---|---|---|
| **Provider API keys you enter** (OpenAI, Anthropic, Google, OpenRouter, etc.) | macOS Keychain on this Mac | ❌ Never | Sent only to that provider, to ask for your usage and quota |
| **Provider session cookies you paste** (manual cookie headers) | macOS Keychain on this Mac | ❌ Never | Sent only to that provider, as a `Cookie` header |
| **Provider cookies read from your browsers**, only for a provider whose cookie source is "Automatic" (Cursor's is until you change it; any other provider's only if you choose it), and not while Strict privacy mode is on | Read from that browser's cookie store (macOS may ask you to let CLI Pulse use the browser's "Safe Storage" Keychain item) | ❌ Never | Sent only to that provider |
| **Tokens that AI CLIs keep on your Mac**: `~/.codex/auth.json`, `~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json`, `~/.local/share/kilo/auth.json`, and Claude Code's Keychain item | Read where each CLI keeps them. The app copies the file-based ones into a Keychain item that only CLI Pulse's own programs can read | ❌ Never | Sent only to that provider, for live quota |
| **Contents of your session logs** (`~/.codex/sessions/`, `~/.codex/archived_sessions/`, `~/.claude/projects/`, `~/.config/claude/projects/`) | Read on your Mac: in the App Store build through folder access you grant, in the direct-download build directly | ❌ Never | Token counts and costs are worked out on your Mac |
| **Daily usage** (per day, provider and model: input, cached and output token counts and a cost estimate; which of your Macs it came from, once that Mac is paired) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in | So iPhone and Apple Watch show the same history as your Mac |
| **Provider quota state** (remaining, limit, plan, reset times; the label you gave the account, if any; which Mac reported it) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in | So mobile clients display current quotas without running the scanner themselves |
| **AI CLI sessions running on your Mac** (the program's name; the name of its project folder, never the full path; a keyed hash of that folder's path; when it started and was last active; an activity estimate based on how long it has run and its CPU use) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in and this Mac is paired | So iPhone and Apple Watch can show what is running on your Mac. The App Store build's sandbox usually hides other programs from it, and then it has none to send. The Companion CLI sends more; see its section |
| **Alerts**: your Mac or a program using a lot of CPU, or a session running a long time (with that program's name, provider and folder name), budget alerts our server works out from your daily usage, and whether you resolved or snoozed each one | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in | So your other devices can show them |
| **Your alert webhook**, if you add one: the address, and which alerts go to it | Supabase, linked to your CLI Pulse account | ✅ Yes | Our server posts each matching alert (its title, message, type, severity and provider) to that address |
| **Settings kept with your account** (such as alert thresholds and budget, and whether Yield Score and remote control are on) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in | So every device uses the same settings |
| **This Mac's helper readings**: CPU and memory load, how many AI CLI sessions are running, whether each installed AI CLI is signed in with a subscription or an API key (where the built-in agent or the Companion CLI can tell), and whether each provider's check worked (ok / no data / error) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in and this Mac is paired | Load and session count show on your other devices. The rest are diagnostics for us, such as why a provider shows nothing |
| **Device name** (your Mac's name as set in System Settings, which often contains your own name), **macOS version, app version and helper version** | Supabase, linked to your CLI Pulse account | ✅ Yes, when you pair this Mac, and the app version while it is paired | Shows which of your Macs are reporting. The versions are diagnostics for us |
| **Machine readings** (Companion CLI only): battery charge, health, cycle count and temperature, thermal state, temperature and fan sensors, load, uptime, memory pressure, swap and disk space, Low Power Mode, and the state of machine controls | Supabase, linked to your CLI Pulse account | ✅ Yes, while the Companion CLI is allowed to upload | The Machine view on iPhone and Apple Watch |
| **Requests you send from your iPhone to a Mac** (fan boost, fan back to automatic, Low Power Mode, Keep Awake) | Supabase, linked to your CLI Pulse account | ✅ Yes, when you send one | Carried to that Mac, which acts on them only if you allowed it there |
| **Your iPhone's notification token**, only if you allow notifications while signed in | Supabase, linked to your CLI Pulse account | ✅ Yes | Lets our server ask your iPhone, through Apple, to refresh its widgets or to look at a pending request. These pushes carry none of your data |
| **Your CLI Pulse login email** | Supabase Auth | ✅ Yes | Required to authenticate you. We may also use it to email you **occasionally** about the product itself — a short survey, or notice of a change that affects you. Never marketing, never sold, never shared, and every such email carries a one-click opt out. See *Product email* below. |
| **Your name and profile details from Apple, Google or GitHub**, if you sign in with one of them (on iPhone) | Supabase Auth | ✅ Yes, if that provider shares them | Supabase keeps what the sign-in provider hands it |
| **Apple / Google / GitHub sign-in tokens** (during sign-in) | Not persisted — exchanged once for a Supabase session | ✅ Yes (during sign-in only) | Identity verification with the original OAuth provider |
| **Supabase session access / refresh token** | Keychain on each device you sign in on. Your iPhone passes it to your paired Apple Watch over Apple's own watch connection | ❌ Never re-uploaded (only received) | Keeps you signed in |
| **Git activity metadata** (commit hash, keyed hash of the project path, commit timestamp, merge flag) | Supabase — only when the "Track git activity (Yield Score)" toggle is ON, and only collected by the Companion CLI | ✅ Yes (opt-in only) | Powers the Yield Score feature |
| **Git commit messages, diffs, file paths, author identity** | — | ❌ Never | Explicitly excluded even when Yield Score is on |
| **Quota alerts you dismiss** | UserDefaults on that device | ❌ Never | Suppression list to prevent re-firing |
| **Codex accounts seen with credits** (a digest of the ChatGPT account ID, never the ID itself) | UserDefaults (app group) on this device | ❌ Never | Keeps a spent Codex credits balance visible as "0 credits left" |
| **Crash reports** from the Mac, iPhone and Apple Watch apps (see *Security practices* for what they contain) | Sentry (sentry.io), scrubbed before leaving the device | ✅ Yes, when a crash or error happens, whether or not you are signed in; the same SDK also reports each app session's start and whether it ended in a crash | So crashes are visible to us without waiting for an App Store review |
| **Anonymous install statistics** (random install id, install channel, app version, OS major.minor, display language, and a few once-ever yes/no milestones listed below) | Supabase, **not linked to any account** | ✅ Yes, unless you turn it off | Tells us whether the app actually works for people who never sign in |

**The key point:** the two categories of data you'd be most worried about —
provider API keys and raw session-log contents — never touch our servers, full
stop.

### When uploads happen

Everything above marked ✅ is attached to your account and is uploaded only
while you are signed in, with three exceptions:

* **Crash reports** are sent whether or not you are signed in, and whatever you
  answer to the scan question below. They are not linked to your account, and
  since v1.55 the list of recent web requests a report carries keeps no query
  strings, and replaces the parts of an address that look like an account or
  other identifier (see *Security practices*).
* **Anonymous install statistics** carry no account at all. They are spelled out
  in the next section rather than buried in a table cell.
* **The Companion CLI** uploads with its own pairing. See its section.

The app's own uploads go to the account you are signed in to. The background
helper uploads with the pairing this Mac made when you set up background sync.
Since v1.55 it uploads only while the app is signed in to that same account:
after you switch to another account it uploads nothing until you pair this Mac
again, and after you sign out it stops reading altogether (see *When the
scanning starts* below for how that applies right after an update).

### Anonymous install statistics

Since v1.44 you can use CLI Pulse without an account. That means we cannot tell
whether the app works for the people using it that way — whether it found their
CLIs, whether they ever saw a number. So the Mac app reports how far it got,
and nothing else; each step is recorded once:

1. **CLI Pulse was installed** — recorded on first launch.
2. **The local helper answered** — the first time the direct-download build's
   built-in agent, or the Companion CLI, answers the app.
3. **CLI Pulse found a CLI to track** — recorded the first time this happens.
4. **CLI Pulse had a cost to show** — the first time it has a cost for today.

If you use remote control, four more facts, each a yes/no recorded once: a phone
reached this Mac over your local network; a phone reached it over your own
private network; a session was started asking Claude to hand off to claude.ai;
and a session driven over remote control was a tool other than Claude.

Sent with each report: a **random** identifier generated on your Mac, which
channel the app came from (App Store, direct download, or Homebrew), the app
version, your macOS version rounded to major.minor (`15.1`, never the full
build string), which of the app's six languages it is displaying (or "other"),
and the current state of every fact above. Our server records when it first and
last heard from the install, and when each fact was first reported.

Not sent, ever: your account or email (there is no account involved and no login
token is attached to the request), your name, your device's name, serial number
or hardware identifiers, any file path or project name, which providers you use
(beyond the remote-control fact above), or any token count or cost figure. Your
IP address is not stored with the report, though, like any request over the
internet, the connection itself reaches our hosting provider.

The identifier is random — not derived from your hardware, and not a hash of
anything about it. It is kept in the app's preferences on your Mac. Moving the
app to the Trash does not delete those preferences (macOS leaves them behind),
so a reinstall reuses the identifier; deleting the preferences deletes it, and
the next launch then makes a new, unrelated one. We cannot connect it to you,
and we cannot connect two identifiers to each other.

**Turning it off:** Settings → Privacy → "Send anonymous install statistics".
Off means nothing is sent at all. **Strict privacy mode (called Local-only mode
in earlier versions) also turns it off** — you do not need to set both. The app
tells you about this on first launch, before it sends anything. Neither switch
affects crash reports.

---

## How data moves

```
┌──────────────────────────┐          ┌──────────────────┐
│  Your Mac                │          │  AI provider     │
│  ┌──────────────────┐    │          │  (OpenAI,        │
│  │ API keys, tokens │─── Direct ───▶│  Anthropic,      │
│  │ (Keychain, CLI   │    │  HTTPS   │  Google, ...)    │
│  │ credential files)│    │          └──────────────────┘
│  └──────────────────┘    │
│  ┌──────────────────┐    │
│  │ JSONL session    │    │  (read on the Mac only, never sent)
│  │ logs             │    │
│  └──────────────────┘    │          ┌──────────────────┐
│  ┌──────────────────┐    │          │ CLI Pulse        │
│  │ Daily usage,     │    │          │ Supabase backend │
│  │ quotas, running  │─── HTTPS ────▶│ (your account)   │
│  │ AI CLI sessions, │    │          └────────┬─────────┘
│  │ alerts, device   │    │                   │
│  │ readings         │    │                   ▼
│  └──────────────────┘    │          ┌──────────────────┐
│                          │          │  Your iPhone /   │
│                          │          │  Apple Watch     │
│                          │          └──────────────────┘
│  ┌──────────────────┐    │          ┌──────────────────┐
│  │ Install          │─── HTTPS ────▶│ Anonymous install│
│  │ milestones       │    │          │ table: NO account│
│  │ (opt-out)        │    │          └──────────────────┘
│  └──────────────────┘    │          ┌──────────────────┐
│  ┌──────────────────┐    │          │ Sentry           │
│  │ Crash reports    │─── HTTPS ────▶│ (crash reports)  │
│  └──────────────────┘    │          └──────────────────┘
└──────────────────────────┘
```

The scanner runs entirely on your Mac. Your API key never passes through our
servers — it goes directly from your Mac to the provider.

---

## When the scanning starts, and what you agree to first

*(Added in v1.50. It corrects something this document previously left implied,
and the correction is a change to the app, not only to the wording here.)*

Everything above describes what CLI Pulse does once it is running. It did not
say clearly enough **when** that begins, and until v1.50 the answer was: as soon
as you chose to use the app without an account, which you could do from the very
first screen of the setup wizard — two screens before the one explaining what
gets read. We found this by testing a fresh install and watching what it did.

Since v1.50, choosing to use CLI Pulse without an account asks a separate
question before anything is read. Until you answer, the app — and, since v1.55,
its background helper — reads none of your session logs or credential files,
contacts no AI provider, and reads no Keychain item except CLI Pulse's own. Since
v1.55 the question has three answers: **"Start local scan"**, **"Last 30 days
only"** and **"Not now"** (see the next section for why). "Not now" is
remembered, is not overridden by signing in later, and is reversible from
Settings → Privacy at any time: without an account, with the scan switch; while
signed in, with **"Choose again…"**, which shows the same question with its
three answers.

Starting the scan turns on:

* **Session logs: the last 30 days, and a one-time read of up to a year** —
  `~/.codex/sessions/`, `~/.codex/archived_sessions/`, `~/.claude/projects/` and
  `~/.config/claude/projects/`. Every refresh uses the last 30 days: a log last
  written before then is not opened, and older lines in a log that is still in
  use are skipped, not kept. Once, and only if you allow it, CLI Pulse also reads
  up to a year of older logs to fill in your usage history. Parsed on your Mac
  for usage records; the results are cached on your Mac.
* **What is derived from them** — token counts, cost estimates, model names and
  dates, plus each conversation's file path, project folder and session id. Those
  last three are how the Sessions list can name your conversations. They stay on
  your Mac; of what the logs give, only the daily numbers in the table sync, and
  only when you are signed in.
* **The programs running on your Mac.** To find AI CLI sessions that are running
  now, CLI Pulse reads the command line of each running program and looks for a
  project marker (such as `.git`) in the folders it names. What it keeps from
  that, and what syncs while you are signed in, is the *AI CLI sessions running
  on your Mac* row in the table.
* **Calls to the providers you use**, made with the OAuth tokens their own CLIs
  already stored on your Mac. This is the part most easily missed: "local mode"
  refers to *your data staying local*, not to the app being offline. To show live
  quota it talks to OpenAI, Anthropic and others directly.
* **Renewing an expired provider token rewrites that CLI's own credential file**
  (for example `~/.codex/auth.json`). CLI Pulse has always done this; it is now
  disclosed, and v1.50 also fixed a bug that made it happen far more often than
  intended — a date-parsing error meant a check written as "renew if the token is
  more than 8 days old" renewed it on essentially every refresh.
* **macOS Keychain prompts, which macOS shows you itself**: once for Claude
  Code's token; in the direct-download build, possibly once for Zed's own
  credential, if you use Zed; and, for a provider whose cookie source is
  "Automatic" (Cursor's is by default), for your browser's "Safe Storage"
  item. Declining costs you that provider's quota figures and nothing else.
  With Strict privacy mode on (Settings → Privacy), CLI Pulse reads none of
  these on its own, so macOS has nothing to ask (a Companion CLI 1.30.0 or
  earlier is the exception: see its section).
* **Anonymous install statistics are separate** and are not part of this choice.
  See the section above.

Signing in implies consent to the 30-day scan, because the sign-in step comes
after the wizard's privacy screen and because syncing to an account is a larger
commitment than scanning locally. It does not imply consent to reading older
logs: see the next section. While you are signed in, the 30-day scan has no
switch of its own; signing out stops it, in the app and in its background
helper, whatever you answered. Signing out does not revoke the consent, though:
if you then use CLI Pulse without an account, an earlier "Start local scan" or
"Last 30 days only" applies again (the scan runs on this Mac, and nothing is
uploaded), and the Settings toggle turns it off.

### Which parts follow your answer, and when

* **The app** acts on your answer from its next refresh. A refresh already
  running when you answer finishes.
* **The background helper** (v1.55) asks before it reads anything, again after
  reading, and again before each upload; the app tells it about a new answer or
  a sign-in change at once. An answer that arrives while it is part-way through
  a refresh does not stop the reads already under way, which run to the end of
  that pass; what they read is then dropped, neither saved for the app nor sent.
  A sign-out that arrives during an upload lets that one upload finish and stops
  the ones after it.
* **After an update from a version before 1.55**, the background helper that
  was already running is still the earlier version until it restarts, and that
  version follows neither your answer nor your sign-in: it keeps collecting and
  syncing as before. The 1.55 app restarts it the first time the app opens
  after the update; logging out of your Mac or restarting it does too. Until the
  app has recorded, on that first launch, whether you are signed in, the new
  helper goes by this Mac's pairing, as earlier versions did. If the restart
  fails while your answer or sign-in calls for the helper to pause, Settings ›
  Advanced says "Restart needed: turn background sync off and on again".
* **The built-in agent** (direct-download build) reads these files to answer
  the app's hello only when the app tells it your answer allows the scan: a
  provider's credential file, to say whether that CLI is signed in with a
  subscription, and Claude Code's settings and credentials files, to say
  whether Claude's Remote Control can be offered to a phone. After "Not now"
  its hello reads neither. Starting a Claude session is separate: see the next
  list.
* **The Companion CLI** follows the answer only from the release after 1.30.0.
  See its section.
* **Three things happen whatever you answered.** In the direct-download build,
  opening the Sessions tab while the built-in agent or the Companion CLI is
  running reads Claude Code's settings file, `~/.claude/settings.json`, to check
  whether CLI Pulse's approval hook is installed. In the same build, starting a
  Claude session from CLI Pulse, in the Sessions tab or from a paired phone over
  your network, makes the built-in agent read `~/.claude/.credentials.json` to
  sign the session in, and, when that token has expired, renew it and rewrite
  the file. And the app
  contacts services that are not AI providers: our server (for anonymous
  install statistics, and for your account if you are signed in), Sentry for
  crash reports, GitHub to check for updates, and an exchange-rate service
  (see *Third-party sub-processors*).

## Reading more than 30 days back, and what the question used to leave out

*(Added in v1.55. Like the section above, it corrects this document, and the
correction is a change to the app.)*

The question above said **"Session logs, last 30 days"** from v1.50 to v1.54,
and this document said the same. That was incomplete. Ever since CLI Pulse has
kept a usage history (the year-long heatmap and the Usage Dashboard), the first
successful scan on a Mac has also read **up to a year** of older session logs,
once, to fill that history in. It did this for everyone whose scan was running,
including people who had just agreed to "30 days". The history it built stayed
on the Mac: the one-time read was not uploaded.

Since v1.55 that read is its own question:

* **New users** choose on the same screen. "Start local scan" includes the
  one-time read of older logs; "Last 30 days only" leaves it out; "Not now"
  turns the scan off.
* **People who agreed to the 30-day scan before v1.55**, and **signed-in users
  who were never shown the question**, are shown it once, with both answers
  keeping the 30-day scan running: **"Include older history"** or **"Last 30 days
  only"**. Refusing the older logs does not take back the 30-day scan. This
  screen records only your answer about older logs. For a signed-in user the
  account stands in for a yes to the 30-day scan, so none is stored; if you
  later sign out and use CLI Pulse without an account, you are asked the first
  question.
* **"Last 30 days only" deletes nothing.** Usage history already built on your
  Mac stays there, including what the one-time read built in versions before
  v1.55; the screens that offer this answer say so.
* Until you say yes, CLI Pulse uses nothing older than 30 days, in the sense
  given under "Session logs" above. Signing in is not a yes to this.
* **Settings → Privacy → "Include older usage history"** changes the answer at
  any time. Turning it off stops further reads of older logs; it does not
  delete history that was already built, which stays on your Mac.

The routine scan had a smaller gap of the same kind. On its first run, and
whenever its cache was reset, it opened Claude Code logs of any age and
discarded their lines older than 30 days without using them. Since v1.55 a log
last written before the 30-day window is not opened.

---

## The Companion CLI (optional, installed separately)

*(Added in v1.55. Earlier versions of this document described the app and its
built-in helper only, and the promises above do not all hold for this program.)*

The Companion CLI is a separate program you can install from Settings ›
Companion CLI. It runs in the background whenever you are logged in to your
Mac, is not sandboxed, and keeps its own pairing with your account in
`~/.cli-pulse-helper.json`.

While it is paired and allowed to (see below), every 2 minutes by default it:

* reads the command line of each running program to find AI CLI sessions, and
  uploads each one's name — up to 48 characters of its command line, which can
  include folder paths and arguments — with a project name taken from its
  command line, a keyed hash of its project folder's path, its start and
  last-active times, and alerts about it;
* uploads this Mac's CPU and memory load, its session count and the machine
  readings listed in the table, and reads `~/.codex/auth.json` to report whether
  Codex is signed in with a subscription or an API key;
* when it finds a Claude, Codex or Gemini session running, reads that
  provider's credentials (Claude Code's Keychain item, `~/.codex/auth.json`,
  `~/.gemini/oauth_creds.json`) to ask it for your quota, uploads the quota
  figures, and renews an expired Gemini token, which rewrites
  `~/.gemini/oauth_creds.json`;
* if Claude's token does not work, reads your claude.ai sign-in cookie from the
  Claude desktop app, Chrome, Edge, Brave, Chromium or Arc, which needs that
  browser's "Safe Storage" Keychain item (macOS may ask you), unless Strict
  privacy mode is on (releases after 1.30.0), and may run `claude /usage`;
* writes that claude.ai cookie, in a plain-text file only your user account can
  read, to `~/.clipulse/claude_session.json` and to CLI Pulse's app-group folder,
  where the app can use it (not in Strict privacy mode: see below);
* if "Track git activity (Yield Score)" is on, runs `git log` in the project
  folders of running sessions and uploads the commit metadata listed in the
  table.

While it is paired it also asks our server about once a second whether a
remote-control or machine-control request is waiting for this Mac (sending only
its own device identifier and secret). Releases after 1.30.0 ask only while
they are allowed to upload (see below); 1.30.0 and earlier ask whatever the app
says. Whatever its state, it answers the CLI Pulse app on this Mac when the app
asks it something, such as the Machine view's readings; while your answer
allows the scan, with or without an account, that answer can include whether
Codex is signed in with a subscription, which it reads from `~/.codex/auth.json`.

**Which versions follow your answer.** Companion CLI 1.30.0 (the latest release
when this was written) and earlier versions do not read the app's answer, its
sign-in or its Privacy switches at all: while installed and paired they keep
collecting and uploading, to the account they were paired with, whatever you
choose in the app, including after you sign out. Releases after 1.30.0 follow
them:

* **Paused** — nothing read or sent in its cycle, and our server not asked
  for remote-control or machine-control requests — when the app is signed out
  (the Sign-In form, or Demo mode), signed in to a different account than the
  one it was paired with, set to "Not now", or used without an account (its
  cycle reads in order to upload, so in local mode it runs none of it; the app
  does its own collection), and when it cannot read the app's answer. Sessions
  it is already running are not stopped: their redacted output and status are
  still posted to our server with its pairing, and a session the app starts
  through it is registered there with its program, folder name and label. Our
  server accepts these only while remote control is on for the paired account.
* **As before** when the app is signed in to the account it was paired with and
  the answer is a yes or none yet, and with an app older than 1.55, which never
  writes an answer for it.
* **Strict privacy mode** and **"Skip Claude Code keychain access"** stop its
  reads of Claude Code's Keychain item. Strict privacy mode also stops the
  browser-cookie fallback: no browser's cookie store is opened and no "Safe
  Storage" item is read, so no new claude.ai cookie is written for the app
  either, and the one it wrote earlier is deleted at its next cycle. The app,
  in Strict privacy mode, does not use such a cookie, including one written by
  Companion CLI 1.30.0 or earlier. Neither switch stops `claude /usage`.
* It checks before each upload and before each credential write, so its cycle
  sees a change within one cycle, and before it asks our server for
  remote-control or machine-control requests, about once a second; it has no
  way to be told sooner.

**To stop it entirely:** Settings › Companion CLI › Uninstall….

---

## Security practices

- **macOS Keychain** is used for every secret the app stores: provider API keys,
  manual cookies, Supabase session tokens, this Mac's pairing secret, and the key
  behind the project-path hashes. Keychain is encrypted at rest, unlocked
  alongside your login, and other apps cannot read CLI Pulse's items without your
  permission. The Companion CLI is the exception: it keeps its pairing secret,
  its hash key and the claude.ai cookie in files only your user account can read
  (see its section).
- **App Sandbox** is enabled in the App Store build
  (`com.apple.security.app-sandbox`), for the app and its background helper;
  there, file access outside the app container requires security-scoped
  bookmarks you grant explicitly in Settings → Advanced → CLI Tool Access. The
  direct-download build, its background helper and built-in agent, and the
  Companion CLI are not sandboxed: they read the files named in this document
  directly.
- **TLS 1.2+** for every network connection.
- **Supabase server-side encryption at rest** (AES-256) for the database and
  storage backing your account. We do **not** currently offer end-to-end
  encryption — what we store is usage numbers and the descriptive details listed
  above, not secrets. See "Roadmap" below.
- **No third-party analytics SDKs.** We do not ship Google Analytics,
  Firebase Analytics, Amplitude, Mixpanel, Crashlytics, or any similar
  product-analytics tool. There is no fingerprinting and no ad network
  integration. This is a statement about SDKs, and we would rather over-explain
  than let it read as more than it is: we do collect the anonymous install
  milestones described above, ourselves, to our own database. They are opt-out,
  carry no account, and go nowhere else.
- **Sentry for crash reports.** We ship the Sentry SDK in the Mac, iPhone and
  Apple Watch apps (and in our Android app) for crash and error reporting; the
  background helper, the built-in agent and the Companion CLI do not use it. PII
  is disabled (`sendDefaultPii = false`), and a local `beforeSend` hook scrubs
  JWTs, strings shaped like `sk-…` API keys, Bearer headers, `/Users/<name>`
  paths, and any field whose name contains common sensitive fragments (`token`,
  `secret`, `password`, `api_key`, `supabase`, etc.) before the event leaves your
  device; it also clears the report's IP-address field. A report carries the
  stack trace, the app and OS version, the device model and the other device
  details the SDK attaches, and up to 50 recent "breadcrumbs" (steps the app
  took before the error). In the Mac, iPhone and Apple Watch apps a breadcrumb
  for a web request the app made keeps its method, status, sizes and timing,
  and its address without the query string or fragment; since v1.55 any part
  of that address that looks like an identifier (an account, organization or
  session ID, a long number, an email address), and the part after a word such
  as `workspace`, `organizations` or `users`, is replaced before the report
  leaves your device, and so are UUIDs and email addresses anywhere else in
  the report's breadcrumbs and error messages. This works by the shape and
  place of each part, so a part that looks like an ordinary word and follows
  no such word is kept. (Before v1.55 the query string was sent too, and a
  request to our server named your account's internal ID in it.) The Android app records no web requests. The SDK also reports, for each app session, that it started
  and whether it ended in a crash, with a random installation identifier the SDK
  generates. Performance tracing is disabled
  (`tracesSampleRate = 0`). There is no switch to turn crash reporting off.

---

## Your controls

- **Folder access (App Store build):** Settings → Advanced → CLI Tool Access
  grants it. The app has no button to take back a single grant: turning the
  local scan off, or signing out, stops every read, and the grants are kept in
  CLI Pulse's app-group folder (`~/Library/Group Containers/group.yyh.CLI-Pulse`)
  until that folder is deleted.
- **Disable Yield Score / git tracking:** Settings → Advanced → "Track git
  activity (Yield Score)" toggle (Mac). Off by default. Only the Companion CLI
  collects git activity, and it checks the toggle every cycle, so turning it off
  stops uploads within one cycle (two minutes by default).
- **Stop background uploads from this Mac:** sign out, or turn off Settings →
  Advanced → "Enable background sync". (The Companion CLI is separate: see the
  next item.)
- **Stop the Companion CLI:** Settings → Companion CLI → Uninstall….
- **Keychain switches:** Settings → Privacy → "Strict privacy mode" and "Skip
  Claude Code keychain access" stop CLI Pulse reading Claude Code's Keychain item
  on its own. Strict privacy mode goes further: CLI Pulse reads no secret that
  another app keeps in your keychain or your browsers on its own, so not Zed's
  keychain item, and not browser cookies or their "Safe Storage" items, even for
  a provider set to read cookies automatically, and it does not use a claude.ai
  cookie the Companion CLI took from a browser or the Claude desktop app. The
  sign-in files AI CLIs keep in your home folder are still read, for quota, and
  crash reports are still sent. Settings says whether the
  background helper has confirmed it follows the Claude switches; for the
  Companion CLI see its section.
- **Disable anonymous install statistics:** Settings → Privacy → "Send
  anonymous install statistics". On by default, disclosed on first launch
  before anything is sent. Strict privacy mode disables it too.
- **Delete API keys:** Remove any provider config in Settings → Providers;
  the Keychain entry is deleted.
- **Delete your account:** "Delete Account" (at the bottom of Settings on the
  Mac, and in Settings on iPhone) deletes your account and all associated usage
  metrics from Supabase.
- **Export:** Use the Export menu in the Overview tab (Mac) to save a PDF or
  CSV of the data it shows.
- **Stop product email:** every product email we send carries a one-click opt
  out, and honouring it is immediate and permanent. You can also email
  yyyyy.yeyuhe@gmail.com and ask. Opting out never affects your account, your
  subscription, or anything the app does.

---

## Product email

Your login email is collected to authenticate you. We may also use it, rarely,
to contact you about CLI Pulse itself:

- a short survey asking how the app is working for you, or why you stopped
  using it;
- notice of a change that materially affects you.

What this is **not**, stated as commitments rather than intentions:

- **Not marketing.** No newsletters, no feature announcements, no discounts as
  a reason to write to you.
- **Not shared.** Your address is never sold, rented, or handed to any third
  party. The sub-processor list below is exhaustive.
- **Not frequent.** As a working limit, at most a handful of such emails in a
  year.
- **Not a condition of anything.** Opting out costs you nothing — no feature,
  no data, no support.

Every product email carries a one-click opt out, honoured immediately and
permanently. If you would rather not receive any, opt out of the first one and
that is the end of it.

If a survey ever offers something in return for your time, that offer is
unconditional on what you say. We will not ask you to review the app in
exchange for anything — the App Store forbids it and so do we.

---

## Data retention

- **Local Keychain entries** persist until you remove the provider (or, for
  the session token, sign out). Moving the app to the Trash does not remove
  them: macOS keeps Keychain items until they are deleted, for example in
  Keychain Access.
- **Usage history** on Supabase is kept for **up to 18 months** of rolling
  history. A nightly job deletes rows older than that from the long-tail
  analytical tables (`commits`, `sessions`, `session_commit_links`,
  `daily_usage_metrics`, `yield_score_daily`). 18 months is long enough to
  support year-over-year cost comparisons with one month of buffer; beyond that
  the historical detail adds no product value and we'd rather delete it.
- **Ended AI CLI sessions, alerts, and device snapshots** are deleted by a
  nightly job once they are older than your account's retention setting: 7
  days, unless an earlier version of the app changed it. The current apps offer
  no way to change it. (Earlier versions of this document pointed to a setting
  in Settings → Privacy that does not exist.)
- **Account deletion** removes all associated rows within 30 days
  (cascading deletes handled at the database level).
- **Anonymous install rows** are deleted 400 days after they were last
  touched. They are not attached to an account, so account deletion does not
  reach them — there is no link to follow. Apart from that row, the identifier
  exists only in the app's preferences on your Mac.

---

## Third-party sub-processors

- **Supabase (hosted in Tokyo region, Japan)** — provides authentication,
  Postgres storage, and edge functions for the metrics sync described above.
- **Apple** — used for Sign in with Apple, App Store payments,
  StoreKit-based subscription management, and the notifications our server
  sends your iPhone. Receipt validation forwards only the StoreKit JWS and
  product ID.
- **Google** — used for Sign in with Google at the user's option.
- **GitHub** — used for Sign in with GitHub at the user's option. GitHub also
  hosts the direct-download build's update information and downloads, and the
  Companion CLI's, so checking for an update is a request to GitHub.
- **Sentry (sentry.io)** — receives the crash reports described above.

We do not share data with any party not listed above, except where you direct
it: the AI providers you use receive the requests CLI Pulse makes to them with
your own credentials, and an alert webhook you add receives your alerts. CLI
Pulse also fetches exchange rates from open.er-api.com, at most once a day, to
show costs in other currencies; that request carries nothing about you or your
usage. We do not sell data.

---

## Children's privacy

CLI Pulse is a developer tool intended for users 17 or older. We do not
knowingly collect data from children.

---

## Changes to this policy

We will update the "Last Updated" date above when this policy changes and
note material changes in release notes. The authoritative version lives at
<https://cli-pulse.github.io/cli-pulse/privacy.html>, which says the same as
this file.

---

## Roadmap: end-to-end encryption

We've looked at adding E2EE to the Supabase-stored metrics. Today, the most
sensitive data (API keys, session log contents) already never reaches our
servers, so the marginal privacy gain from encrypting what we do store is
smaller than it sounds. Implementing E2EE also conflicts with cross-device
sync, which requires multi-device key management we don't want to ship
half-built. If you have a specific threat model where E2EE on metrics
matters to you, please open an issue — we'd rather hear the use case than
guess.

---

## Contact

- Email: yyyyy.yeyuhe@gmail.com
- GitHub issues: <https://github.com/cli-pulse/cli-pulse/issues>

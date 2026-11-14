# Privacy Policy

**CLI Pulse**
**Last Updated: November 12, 2026**

CLI Pulse is a developer tool for monitoring usage, quotas, and cost across AI
coding providers (Claude, Codex, Gemini, OpenRouter, and others). Our privacy
goal is straightforward: **your provider API keys never reach our servers** (CLI
Pulse sends each one only to the provider it belongs to). Apart from what
signing in needs, crash reports, the anonymous install statistics, a few
diagnostic readings about each Mac, the record your Android phone adds to your
account each time you sign in on it (with that phone's notification token if it
was sent), the network details every request carries, a subscription's receipt
sent to us for checking, and what sessions you run through the optional
Companion CLI print (all described below), everything else CLI Pulse uploads is
there to run the features you use across your devices (showing your usage and
alerts, keeping your settings in step, carrying the requests you send to a Mac)
or to send alerts where you asked. We also count some of what is linked to
your account, in our own database, to understand how the apps are used (see
*Analytics we do ourselves* under *Security practices*), and this document
lists all of it, including
the parts that are not numbers.

This document is the single source of truth for what we collect. If you find
anything in the apps, their App Store or Google Play listings, or the GitHub
README that contradicts this file, **the file wins** — please open an issue.

It describes CLI Pulse 1.63.

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
  for your iPhone, Apple Watch and Android phone. It is switched on when you pair this Mac with
  your account, and on or off with Settings › Advanced › "Enable background sync",
  which since v1.56 is there whether or not you are signed in or this Mac is
  paired. It uploads only with that pairing (see *When uploads happen*).
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
* **The Android app** (from Google Play). This document describes Android version
  1.63.0; earlier Android versions, such as 1.62.0 and 1.37.0, differ and are not
  described here, except where noted, such as their Sign Out, which also signs
  your other devices out (see *Your controls*). It shows what your Macs synced to
  your account and reads nothing from AI tools on the phone. This release has
  no place to enter a provider API key, so it contacts no AI provider. While
  you are signed out it sends our server only what signing in needs (and, right
  after you sign out, the requests that end that sign-in on our server), and
  in "Try Demo" (which shows built-in sample data) it sends our server
  nothing; in both cases Sentry still receives a record of each
  app session and any crash report, and Google's Firebase and Google Play are
  contacted as described under *When uploads happen*. Earlier versions of this
  document mentioned the Android app only for its crash reports.

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
| **Provider API keys you enter** (OpenAI, Anthropic, Google, OpenRouter, etc.) | macOS Keychain on this Mac. The Android app has no place to enter one | ❌ Never | Sent only to that provider, to ask for your usage and quota |
| **Provider session cookies you paste** (manual cookie headers) | macOS Keychain on this Mac | ❌ Never | Sent only to that provider, as a `Cookie` header |
| **Provider cookies read from your browsers**, only for a provider whose cookie source is "Automatic" (Cursor's is until you change it; any other provider's only if you choose it), and not while Strict privacy mode is on | Read from that browser's cookie store (macOS may ask you to let CLI Pulse use the browser's "Safe Storage" Keychain item) | ❌ Never | Sent only to that provider |
| **Tokens that AI CLIs keep on your Mac**: `~/.codex/auth.json`, `~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json`, `~/.local/share/kilo/auth.json`, and Claude Code's Keychain item | Read where each CLI keeps them. The app copies the file-based ones into a Keychain item that only CLI Pulse's own programs can read | ❌ Never | Sent only to that provider, for live quota (and, since v1.57, Codex's limit reset credits) |
| **Contents of your session logs** (`~/.codex/sessions/`, `~/.codex/archived_sessions/`, `~/.claude/projects/`, `~/.config/claude/projects/`) | Read on your Mac: in the App Store build through folder access you grant, in the direct-download build directly | ❌ Never | Token counts and costs are worked out on your Mac |
| **Daily usage** (per day, provider and model: input, cached and output token counts and a cost estimate; which of your Macs it came from, once that Mac is paired) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in | So iPhone, Apple Watch and the Android app show the same history as your Mac |
| **Provider quota state** (remaining, limit, plan, reset times; for a provider that sells prepaid credit, such as OpenRouter, DeepSeek or Venice, the credit balance and, where the provider reports it, how much credit was bought; the label you gave the account, if any; which Mac reported it) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in | So mobile clients display current quotas without running the scanner themselves |
| **AI CLI sessions running on your Mac** (the program's name; the name of its project folder, never the full path; a keyed hash of that folder's path; when it started and was last active; an activity estimate based on how long it has run and its CPU use) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in and this Mac is paired | So iPhone, Apple Watch and the Android app can show what is running on your Mac. The App Store build's sandbox usually hides other programs from it, and then it has none to send. The Companion CLI sends more; see its section |
| **Alerts**: your Mac or a program using a lot of CPU (with that program's name, provider and folder name; CLI Pulse 1.56 and earlier also raised one for a session running a long time), budget alerts our server works out from your daily usage, and whether and when you acknowledged each one (which marks it read), whether you resolved it, and until when you snoozed it | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in | So your other devices can show them |
| **Your alert webhook**, if you add one: the address, and which alerts go to it | Supabase, linked to your CLI Pulse account | ✅ Yes | Our server posts each matching alert (its title, message, type, severity and provider) to that address |
| **Settings kept with your account** (such as alert thresholds and budget, how many days ended sessions and alerts are kept, and whether Yield Score and remote control are on) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in | So every device uses the same settings |
| **This Mac's helper readings**: CPU and memory load, how many AI CLI sessions are running, whether each installed AI CLI is signed in with a subscription or an API key (where the built-in agent or the Companion CLI can tell), and whether each provider's check worked, or why not (for example not signed in, or keychain access declined) | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in and this Mac is paired | Load and session count show on your other devices. The rest are diagnostics for us, such as why a provider shows nothing |
| **Device name** (your Mac's name as set in System Settings, which often contains your own name), **macOS version, app version and helper version** | Supabase, linked to your CLI Pulse account | ✅ Yes, when you pair this Mac, and the app version while it is paired | Shows which of your Macs are reporting. The versions are diagnostics for us |
| **Your Android phone's maker and model** (such as "Google Pixel 8", not a name you gave it) **and its Android version**, with fixed labels and the time the record was added. The app's background sync sends it the first time it runs after you sign in (at most every 15 minutes, while the phone is online and its battery is not low) | Supabase, linked to your CLI Pulse account | ✅ Yes, once per sign-in | Lists the phone among your devices. Signing out does not remove it, and each later sign-in on the phone adds another; the app cannot remove them, and they are deleted with your account |
| **Machine readings** (Companion CLI only): battery charge, health, cycle count and temperature, thermal state, temperature and fan sensors, load, uptime, memory pressure, swap and disk space, Low Power Mode, and the state of machine controls | Supabase, linked to your CLI Pulse account | ✅ Yes, while the Companion CLI is allowed to upload | The Machine view on iPhone and Apple Watch, and the Devices screen in the Android app |
| **Requests you send from your iPhone to a Mac** (fan boost, fan back to automatic, Low Power Mode, Keep Awake) | Supabase, linked to your CLI Pulse account | ✅ Yes, when you send one | Carried to that Mac, which acts on them only if you allowed it there |
| **Your iPhone's notification token**, only if you allow notifications while signed in | Supabase, linked to your CLI Pulse account | ✅ Yes | Lets our server ask your iPhone, through Apple, to refresh its widgets or to look at a pending request. These pushes carry none of your data |
| **Your Android phone's notification token**, which Google's Firebase Cloud Messaging gives the app. It is sent when Firebase hands the app a token while you are signed in and the phone is already listed in your account. Firebase usually hands over the first token when the app first starts, before you have signed in, so usually only a later replacement, if Firebase issues one while you are signed in, is sent | Supabase, with the phone's record in your account | ✅ Yes, if handed over while signed in | None yet: our server sends no notifications to Android phones and does not read this token, and the app does not ask for permission to show notifications. A token that was sent stays with that record after you sign out |
| **Your CLI Pulse login email** | Supabase Auth | ✅ Yes | Required to authenticate you. Asking for a sign-in code for an address creates an account for it, even if the code is never entered. We may also use it to email you **occasionally** about the product itself — a short survey, or notice of a change that affects you. Never marketing, never sold, never shared, and every such email carries a one-click opt out. See *Product email* below. The surveys are part of the analytics we do ourselves (see *Analytics we do ourselves*). |
| **Your password**, if you sign in with one | Supabase Auth | ✅ Yes, when you sign in with it | Signs you in. Supabase keeps it only as a hash |
| **Your name and profile details from Apple, Google or GitHub**, if you sign in with one of them (on iPhone, including one you link in Settings › Linked Accounts; on Android, Google or GitHub, including one you link in the Android app's Settings › Linked Accounts) | Supabase Auth | ✅ Yes, if that provider shares them | Supabase keeps what the sign-in provider hands it. When you sign in with Apple on iPhone, or with Google on Android, the app also passes on the name Apple or Google gives it |
| **Apple / Google / GitHub sign-in tokens** (during sign-in) | Not persisted — exchanged once for a Supabase session | ✅ Yes (during sign-in only) | Identity verification with the original OAuth provider |
| **Supabase session access / refresh token** | Keychain on each Apple device you sign in on; on Android, the app's encrypted preferences (`cli_pulse_secure_prefs`). Your iPhone passes it to your paired Apple Watch over Apple's own watch connection | ❌ Not uploaded as data: sent only to authenticate your requests and to renew your session | Keeps you signed in |
| **What else the Android app keeps on the phone**: your account's ID, name and email; the ID of the phone's record in your account; whether Try Demo is on; while a GitHub sign-in or account link you started in the browser is unfinished, a one-time code for finishing it; a random ID the app gives each sign-in on the phone, and when the phone received its current sign-in token; as last fetched from your account, the Overview's totals for today (tokens, estimated cost, and how many sessions, devices and open alerts) and up to 30 days of daily usage (per day, provider and model: token counts and cost); and files you export from the Overview (CSV and PDF of what the Overview has loaded; in this release, for a signed-in account, that is the totals and daily usage per provider and model) | The totals and daily usage in the app's own database (`cli_pulse_cache`), which the app does not encrypt; exported files in the app's cache folder; everything else in the app's encrypted preferences (`cli_pulse_secure_prefs`). Sign Out deletes all of it except exported files before it contacts our server, without waiting for the network (only a count of sign-in attempts and a note that the one-time clean-up below has run stay), and Delete Account does the same once our server has deleted the account. Exit Demo Mode deletes the encrypted preferences. The same deletion happens, and the app returns to the sign-in screen (saying your session expired, if the app is open at the time), when our server definitively refuses the saved sign-in: when it answers that the sign-in or your account no longer exists, or refuses to renew the sign-in. That happens, for example, after the account is deleted from another device, or after a sign-out on a device running an older version (see *Your controls*); the app finds out when it starts, while it is open, or in its background sync, whichever asks our server first. Any other answer (no connection, a server error, or a refusal our server does not explain that way) keeps you signed in and deletes nothing. The saved sign-in lasts an hour, and the app renews it before any request that needs it, its check at start-up included, so coming back to the app after some time away does not sign you out. If the app is closed before such a deletion has finished, it finishes the next time the app starts. The first time this release starts with no one signed in and Try Demo off, it also deletes totals and daily usage that an earlier version left on the phone. A sign-in code you abandon stays until you start another, sign in, start Try Demo or sign out (it is no longer used after 10 minutes). Exported files stay until Android clears the app's cache or you uninstall the app (each of the four kinds of CSV export replaces the previous file of its kind; PDF reports are named by date, so one stays for each day you export one). Uninstalling the app deletes all of it | ❌ No (the one-time code goes to Supabase Auth once, to finish that sign-in) | Shows who is signed in, tells one sign-in on the phone from the next, finishes a browser sign-in, and lets you share an export. This release saves the totals and daily usage but never reads them back |
| **What the Android app's libraries keep on the phone**: Google's Firebase keeps a random ID for this install of the app, a sign-in token of its own, the notification token, and a record of the days it was used, which it sends to Google with its requests; Google's log uploader may keep events it has not yet sent to Google (Google Play's billing library can add some once you open Settings › Subscription); Sentry keeps its own random installation ID, a running copy of its latest breadcrumbs and device details, and any crash reports not yet sent; Android keeps the background sync's schedule | The app's private storage | ❌ Not to our server, except the notification token (see its row) | Firebase, Google's log uploader and Sentry use them as described under *Security practices* and *Third-party sub-processors*. Neither Sign Out nor Delete Account deletes them; uninstalling the app does |
| **Git activity metadata** (commit hash, keyed hash of the project path, commit timestamp, merge flag) | Supabase — only when the "Track git activity (Yield Score)" toggle is ON, and only collected by the Companion CLI | ✅ Yes (opt-in only) | Powers the Yield Score feature |
| **Git commit messages, diffs, file paths, author identity** | — | ❌ Never | Explicitly excluded even when Yield Score is on |
| **Quota alerts you dismiss** | UserDefaults on that device | ❌ Never | Suppression list to prevent re-firing |
| **Codex accounts seen with credits** (a digest of the ChatGPT account ID, never the ID itself) | UserDefaults (app group) on this device | ❌ Never | Keeps a spent Codex credits balance visible as "0 credits left" |
| **Codex limit reset credits** (since v1.57, Mac app only): how many limit resets OpenAI has granted the ChatGPT account Codex is signed in to on this Mac, and when each expires. The app asks OpenAI for them (a read-only request to `chatgpt.com`) with the same Codex sign-in, in the same refresh as Codex's quota. It never asks OpenAI to use one | Kept in memory in the Mac app while it runs, each credit's ID and the ChatGPT account ID only as hashes; never written to disk | ❌ Never, and not to your iPhone or Apple Watch either | Shown on the Codex card |
| **Your subscription**, if you buy one in the App Store or Google Play reports one for your Google account: the plan, that it is active, when the current period ends, which store, the App Store's product and transaction IDs or Google Play's order ID (or, if Google gives none, the start of the purchase token), and when it was last checked. To check it, the app sends our server the App Store's signed transaction and product ID, or Google Play's purchase token, product ID and the app's package name | Supabase, linked to your CLI Pulse account | ✅ Yes, while signed in | Keeps your plan with your account, so every device shows it; deleted with your account |
| **Crash reports** from the Mac, iPhone, Apple Watch and Android apps (see *Security practices* for what they contain) | Sentry (sentry.io), scrubbed before leaving the device | ✅ Yes, when a crash or error happens, whether or not you are signed in; the same SDK also reports each app session's start and whether it ended in a crash | So crashes are visible to us without waiting for an App Store or Google Play review |
| **Anonymous install statistics** (Mac app only: random install id, install channel, app version, OS major.minor, display language, and a few once-ever yes/no milestones listed below) | Supabase, **not linked to any account** | ✅ Yes, unless you turn it off | Tells us whether the app actually works for people who never sign in |
| **Network details of every request to our server**, from every app: your IP address, and the approximate location (city and country) that our hosting provider works out from it and records with the request; the label each request carries, which names the app, or the library or browser making the request, usually with version numbers (for the Mac, iPhone and Apple Watch apps, also the system's); and the address each request asks for, which can include your account's ID | Supabase's request and sign-in logs, kept for about 90 days; with each sign-in, Supabase Auth's record of that session, removed when you delete your account, and when you sign out only if our server accepts the app's sign-out request (from 1.63 an app renews a sign-in that has expired, or is about to, before sending the request, or else, if our server refuses the request because of its sign-in, renews it then and sends the request once more; it renews at most once and spends at most 20 seconds on the network. 1.62 and earlier send the request once, without renewing first. Signing out while offline, or with an expired sign-in that can no longer be renewed, leaves the record; records of expired sessions are cleaned up later). From 1.63 a sign-out removes only that device's record; in 1.62 and earlier it removed the records of all your devices. Linking a sign-in method on iPhone (Settings › Linked Accounts) can start a new session there, and from 1.63 the record of the session it replaced is not removed by a later Sign Out on that iPhone; Android 1.63.0 asks our server to remove that record as soon as the link completes; for each attempt to pair a Mac, our own database, until the cleanup after it is an hour old (at most about a day) | ✅ Yes, with every request | Running and protecting the service (pairing attempts are counted to limit their rate). Deleting your account does not remove log entries already written |

**The key point:** the two categories of data you'd be most worried about —
provider API keys and raw session-log contents — never touch our servers, full
stop.

### When uploads happen

Everything above marked ✅ that is attached to your account is uploaded only
while you are signed in, apart from what signing in itself sends (asking for a
sign-in code already creates the account), with these exceptions:

* **Crash reports** are sent whether or not you are signed in, and whatever you
  answer to the scan question below. They carry no account ID, but they are not
  anonymous: they can be tied to your device, and those from the iPhone can name
  your Mac (see *Security practices*), and
  since v1.55 the list of recent web requests a report carries keeps no query
  strings, and replaces the parts of an address that look like an account or
  other identifier (see *Security practices*).
* **Anonymous install statistics** carry no account at all. They are spelled out
  in the next section rather than buried in a table cell.
* **The Companion CLI** uploads with its own pairing. See its section.
* **Network details** (your IP address and each request's label) reach Supabase
  with every request, signed in or not (see the table).

The app's own uploads go to the account you are signed in to. The background
helper uploads with the pairing this Mac made when you set up background sync.
Since v1.55 it uploads only while the app is signed in to that same account:
after you switch to another account it uploads nothing until you pair this Mac
again, and after you sign out it stops reading altogether (see *When the
scanning starts* below for how that applies right after an update).

The Android app, too, uploads only while you are signed in, and then also in
the background, even when the app is closed: about every 15 minutes, while the
phone is online and its battery is not low, it asks our server for your
Overview totals, and the first time after you sign in it adds the phone to your
account. Each request for totals sends the phone's current date (the day only),
so that "today" matches your calendar; our server uses it to answer and does
not keep it. While the app is open, the screen you are on refreshes from our
server every 30 to 60 seconds, and the Alerts tab asks our server, at most every
5 minutes, to work out budget alerts from your daily usage. Three things happen
whether or not you are signed in, in Try Demo too: Sentry receives a record of
each app session and any crash report (see *Crash reports*); Google's Firebase
registers the app with Google and gets it a notification token when the app
starts (Firebase's own default, which our code does not change); and opening
Settings › Subscription asks Google Play on the phone which CLI Pulse
subscriptions exist and whether you have one. None of these goes to our server,
except, while you are signed in, a notification token Firebase hands over or a
CLI Pulse subscription Google Play reports, as the table and *Third-party
sub-processors* describe.

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
internet, the connection itself reaches our hosting provider, whose request
logs keep it, with the city and country it points to, for about 90 days (see
*Network details* in the table).

The identifier is random — not derived from your hardware, and not a hash of
anything about it. It is kept in the app's preferences on your Mac. Moving the
app to the Trash does not delete those preferences (macOS leaves them behind),
so a reinstall reuses the identifier; deleting the preferences deletes it, and
the next launch then makes a new, unrelated one. Nothing in the report connects
it to you or one identifier to another, and we do not use our hosting
provider's logs to try.

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
│                          │          │  Apple Watch /   │
│                          │          │  Android phone   │
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

The Android app runs no scanner and holds no provider keys. It reads what your
account holds and sends back the changes you make in it: settings, alert
states, a webhook and its test, and your linked sign-in methods. It also sends
the record of the phone, sometimes its notification token, and requests for our
server to work out budget alerts. It sends its crash reports to Sentry,
registers with Google's Firebase for its notification token, and asks Google
Play about subscriptions when you open Settings › Subscription; if Google Play
reports one, the app sends our server its purchase token, product ID and the
app's package name, for checking.

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

**Versions 1.50 through 1.54 did not keep that promise on a Mac synced to your
account**, although this document made it from v1.50. There the app never
checked the answer: after "Not now" it kept reading this Mac and syncing what
it found anyway, as if you had started the scan. It read your session logs,
including the one-time read of older logs if that had not yet run on the Mac;
it read the credentials your AI CLIs keep and asked their providers for your
quota; and it uploaded what it found, such as that quota and your daily usage,
to your account. Without an account, and on a signed-in Mac that was not
synced, the app honored "Not now". Since v1.55 it honors it on a synced Mac
too, where it still shows what your account already holds. "Choose again…" is
also new in v1.55; before, the only way to change the answer while signed in
was to sign out.

Starting the scan turns on:

* **Session logs: the last 30 days, and up to a year if you allow it** —
  `~/.codex/sessions/`, `~/.codex/archived_sessions/`, `~/.claude/projects/` and
  `~/.config/claude/projects/`. Every refresh uses the last 30 days: a log last
  written before then is not opened, and older lines in a log that is still in
  use are skipped, not kept. Only if you allow it, CLI Pulse also reads up to a
  year of older logs to fill in your usage history: once, and the Codex logs
  again whenever a CLI Pulse update changes how it counts Codex usage, or when
  the account you're signed in to has older Codex figures from this Mac to
  correct (see *Reading more than 30 days back*). Parsed on your Mac for usage
  records; the results are cached on your Mac.
* **What is derived from them** — token counts, cost estimates, model names and
  dates, plus each conversation's file path, project folder and session id, and
  for a Codex conversation a one-way hash of its repository's address (the
  address itself is never kept: it can hold a token). Those are how the Sessions
  list can name your conversations, how Projects (the usage panel and the
  Overview's Top Projects card) adds up usage by folder and counts a Codex
  worktree or a clone in `/private/tmp` for the checkout it came from, and how
  the usage panel's Sessions list adds up the last 30 days by session, a
  session's subagents included, named by its project folder. They stay on your
  Mac; of what the logs give, only the daily numbers in the table sync, and only
  when you are signed in.
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
* **The Companion CLI** follows the answer only from 1.31.0, the release after
  1.30.0. See its section.
* **The Sessions tab** follows it too. While the built-in agent or the
  Companion CLI is running, the direct-download build reads Claude Code's
  settings file, `~/.claude/settings.json`, to check whether CLI Pulse's
  approval hook is installed, and the Companion CLI, asked which sessions to
  list there, reads the command lines of the running programs to find AI CLI
  sessions. After "Not now" neither happens, and the tab lists only the
  sessions CLI Pulse started (Companion CLI 1.30.0 and earlier still read the
  running programs).
* **Two things happen whatever you answered.** In the direct-download build,
  starting a Claude session from CLI Pulse, in the Sessions tab or from a
  paired phone over your network, makes the built-in agent read
  `~/.claude/.credentials.json` to sign the session in, and, when that token
  has expired, renew it and rewrite the file. And the app
  contacts services other than the AI providers' own APIs: our server (for anonymous
  install statistics, and for your account if you are signed in), Sentry for
  crash reports, GitHub to check for updates, the providers' public status pages
  (unless you turn off Settings › Check provider status), and an exchange-rate
  service
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
  read of older logs; "Last 30 days only" leaves it out; "Not now" turns the
  scan off.
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
* **Since v1.56, a CLI Pulse update that changes how it counts Codex usage reads
  up to a year of Codex logs again** — only with this yes, once for each such
  change, and once more if a later sign-in finds older Codex numbers from this
  Mac in that account. A read that could not finish is tried again a day later.
  (1.56 is the first: it counts Codex's cached input once, counts subagent
  sessions, and prices requests at OpenAI's published rates.) No Claude log is
  read for it. The older Codex days of your usage history are counted anew from
  what is read; a day whose Codex log is no longer on the Mac keeps the figure
  it had. While you are signed in, the daily Codex numbers this Mac had already
  synced for those days are replaced with the new ones (the fields of the
  *Daily usage* row above), so on those days your iPhone, Apple Watch and Android app show
  the same figures as the Mac. A paired Mac uploads nothing for a day that has no Codex
  numbers from it in the cloud, and numbers it synced before it was paired keep
  their old figures. A Mac that is not paired keeps its numbers in one place it
  shares with the account's other unpaired Macs, so it replaces figures on any
  day where that shared place has Codex numbers, whichever unpaired Mac they
  came from. There, only the models this Mac's logs report are replaced, and a
  row under an older spelling of one of those model names (a dated one, say) is
  set to zero.

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
Codex is signed in with a subscription, which it reads from `~/.codex/auth.json`,
and the AI CLI sessions it finds among the running programs, for the Sessions
tab. Releases after 1.30.0 read neither while the answer pauses the scan.

It also runs the AI CLI sessions you start through it from the app's Sessions
tab. While it is allowed to upload (see below), it registers each one with our
server, with its program, the name of its project folder and its label, and
posts what the session prints, with secrets redacted, its status and short
notes about it, such as an exit code. Our server accepts these only while
"Mac control requests from your other devices" is on for the paired account,
and no CLI Pulse app shows them any more.

**Which versions follow your answer.** Companion CLI 1.30.0 and earlier versions
do not read the app's answer, its
sign-in or its Privacy switches at all: while installed and paired they keep
collecting and uploading, to the account they were paired with, whatever you
choose in the app, including after you sign out. Companion CLI 1.31.0, released
with CLI Pulse 1.55, and later releases follow them:

* **Paused** — nothing read or sent in its cycle, nothing sent about the
  sessions it runs, and our server not asked for remote-control or
  machine-control requests — when the app is signed out
  (the Sign-In form, or Demo mode), signed in to a different account than the
  one it was paired with, set to "Not now", or used without an account (its
  cycle reads in order to upload, so in local mode it runs none of it; the app
  does its own collection), and when it cannot read the app's answer. Sessions
  it is already running are not stopped, and you can go on using them in the
  app, but nothing about them is sent: no output, status or note is posted, a
  session the app starts through it is not registered with our server, and
  what a session prints during the pause is not sent afterwards.
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
  sees a change within one cycle; before it asks our server for
  remote-control or machine-control requests, about once a second; and before
  each thing it sends about a session. It has no way to be told sooner.

**To stop it entirely:** Settings › Companion CLI › Uninstall….

---

## Security practices

- **macOS Keychain** is used for every secret the app stores: provider API keys,
  manual cookies, Supabase session tokens, this Mac's pairing secret, and the key
  behind the project-path hashes. Keychain is encrypted at rest, unlocked
  alongside your login, and other apps cannot read CLI Pulse's items without your
  permission. The Companion CLI is the exception: it keeps its pairing secret,
  its hash key and the claude.ai cookie in files only your user account can read
  (see its section). The Android app has no Keychain: it keeps its sign-in
  tokens and account details in Android's EncryptedSharedPreferences (AES-256,
  with the key in the phone's Android Keystore), and its saved usage figures in
  its private storage without that extra layer.
- **App Sandbox** is enabled in the App Store build
  (`com.apple.security.app-sandbox`), for the app and its background helper;
  there, file access outside the app container requires security-scoped
  bookmarks you grant explicitly in Settings → Advanced → CLI Tool Access. The
  direct-download build, its background helper and built-in agent, and the
  Companion CLI are not sandboxed: they read the files named in this document
  directly.
- **Android permissions and backup.** The Android app asks Android for no
  access to your files, photos, contacts, location, camera, microphone, calls
  or list of other apps (our hosting provider still works out an approximate
  location from the IP address of each request: see *Network details* in the
  table). The permissions it declares let it go online and see
  whether the phone is connected, receive notifications through Google, keep
  its background sync running (also after the phone restarts) and use Google
  Play billing; two more, for fingerprint or face unlock, come with Google's
  sign-in library, and the app never uses them. One more, which an Android
  library adds, only lets the app's own parts send each other messages. It
  declares the notification permission but never asks you for it. It opts out
  of Android's backup to Google's cloud (`android:allowBackup="false"`), and on
  Android 12 and later its data extraction rules ask Android to leave every one
  of the app's files out of both that backup and a direct transfer to a new
  phone. (Android 1.62.0 and earlier did not ask this for a direct transfer, so
  on Android 12 and later one could copy the app's files to the new phone: its
  sign-in tokens could not be read there, because Android does not move
  Keystore keys, but the saved totals and daily usage could.) Exported files
  are in the app's cache folder, which Android does not copy either.
- **TLS 1.2+** for every network connection. The Android app also refuses any
  unencrypted connection, and trusts only the certificate authorities built
  into the phone.
- **Credentials are not written to disk caches.** Since v1.57 every request
  that the Mac app, its background helper, and the iPhone and Apple Watch apps
  send with a sign-in token, API key or cookie goes through a connection that
  keeps no cache and no cookies. The direct-download build's built-in agent
  keeps none of its requests on disk either, and the Android app's requests
  keep no web cache and no cookies. When you sign in on a web page,
  that page opens in your browser, which keeps its own cookies as it does for
  any website. Earlier versions could leave copies of such requests, and the
  answers to them, in an app's own web cache, and cookies that providers set
  in its cookie file. Each app, and the Mac's background helper, empties both
  once, the first time it starts after updating to v1.57. A background helper
  that does not start, for example while background sync is off, cannot do
  that itself. Since v1.58 the direct-download app empties both for its
  helper, once, at the first launch when the helper is not running and
  background sync is off, unless the helper already has. The App Store
  build's app cannot reach its helper's folders, so in that build the helper
  still empties them itself, the first time it starts.
  Each Mac build empties only its own: if you switched between the App Store
  build and the direct-download build before v1.57, what the other build left
  stays until that build runs v1.57 or later. You can delete that build's web
  cache yourself. For the App Store build it is the folders
  `~/Library/Containers/yyh.CLI-Pulse/Data/Library/Caches/yyh.CLI-Pulse` and
  `~/Library/Containers/yyh.CLI-Pulse.helper/Data/Library/Caches/yyh.CLI-Pulse.helper`;
  for the direct-download build, `~/Library/Caches/yyh.CLI-Pulse` and
  `~/Library/Caches/yyh.CLI-Pulse.helper`.
- **Supabase server-side encryption at rest** (AES-256) for the database and
  storage backing your account. We do **not** currently offer end-to-end
  encryption — what we store is usage numbers and the descriptive details listed
  above, not secrets. See "Roadmap" below.
- **No third-party analytics SDKs.** We do not ship Google Analytics,
  Firebase Analytics, Amplitude, Mixpanel, Crashlytics, or any similar
  product-analytics tool. The Android app includes Google's Firebase Cloud
  Messaging, for its notification token, with the Firebase parts it needs
  (Firebase Installations, which gives the install the random ID described under
  *Third-party sub-processors*), and no other Firebase product: no Firebase
  Analytics and no Crashlytics. There is no ad network integration, and nothing
  we ship tracks you across other companies' apps or websites; the one value
  worked out from the device itself is the Sentry SDK's hash described under
  *Sentry for crash reports*. This is a statement about SDKs, and we would rather over-explain
  than let it read as more than it is: we do collect the anonymous install
  milestones described above, ourselves, to our own database. They are opt-out,
  carry no account, and go nowhere else.
- **Analytics we do ourselves, on data linked to your account.** We count
  things in our own database from the records linked to accounts (devices,
  their app versions and when they last checked in, usage uploads, and
  sign-ins): for example how many paired Macs send usage, which versions are in
  use, or how many people come back after signing up. We may also email a short
  survey (see *Product email*). This uses data linked to your account; we do it
  ourselves and share it with no one. Our App Store and Google Play privacy
  listings declare it as Analytics.
- **Sentry for crash reports.** We ship the Sentry SDK in the Mac, iPhone and
  Apple Watch apps (and in our Android app) for crash and error reporting; the
  background helper, the built-in agent and the Companion CLI do not use it. PII
  is disabled (`sendDefaultPii = false`), and a local `beforeSend` hook scrubs
  JWTs, strings shaped like `sk-…` API keys, Bearer headers, `/Users/<name>`
  paths (in the Apple apps), and any field whose name contains common sensitive fragments (`token`,
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
  request to our server named your account's internal ID in it.) The Android
  app records no web requests. Since Android 1.63.0 its hook, besides removing
  the secrets named above, replaces UUIDs and email addresses and drops the
  query string and fragment of any web address, in a report's error messages,
  breadcrumbs, tags and extras; it checks field names in tags, extras, contexts
  and breadcrumb data, at every level of nesting. Unlike the Apple apps' hook,
  it does not look for other parts of an address that look like an
  identifier. Its breadcrumbs come from the Sentry SDK's own defaults: the
  app's screens opening and closing, the app moving to the background, and
  changes on the phone such as the network connection, the battery, the screen
  turning on or off, and the time zone or language. By the same defaults it
  sends a report, with the stack trace, when the app has not responded for about
  five seconds (what Android calls "not responding"). Android reports carry no
  screenshots.
  The SDK also reports, for each app session, that it started
  and whether it ended in a crash, with a random installation identifier the SDK
  generates. Every report from the Mac and iPhone apps also carries a one-way
  hash the SDK works out from the device and the app (on an iPhone from the
  identifier iOS gives all apps from one maker, on a Mac from its network
  hardware address); on a Mac it stays the same if you reinstall the app, and
  so, usually, does the installation identifier, which the SDK keeps in a
  folder a reinstall leaves in place. In the iPhone app the breadcrumbs also name the
  screens you opened, by their titles: the screen for a paired Mac is titled
  with the Mac's name, which often contains your own name, and a session's
  screen with the session's title, which can name its project folder (for a
  session the Companion CLI reported, a folder name taken from its command
  line). With
  Settings › Hide personal information on, these titles are masked. So crash
  reports carry no account ID, but they are not anonymous, and the App Store
  listing counts them as linked to you. In the Mac and iPhone apps the SDK also
  sends a report, with the stack trace and breadcrumbs, when the app has frozen
  (its main thread has not responded) for about two seconds (three on the Mac),
  and the iPhone app sends one, with the breadcrumbs, on the launch after iOS
  ended it while it was open. Since v1.59 the Mac app also sends an error report when three
  refreshes in a row have failed (a request to our server failed, or a
  refresh had not finished after ten minutes), at most one a day. Besides
  what every report carries (the stack trace, the app and OS version, the
  device details, the device hash described above and the SDK's random
  installation identifier), it holds
  only a fixed word for the reason (such as `rejected` or `network_failed`),
  the HTTP status, which of the app's two refresh paths it was and how many
  refreshes in a row had failed. It has no breadcrumbs. When pairing this Mac
  with your account fails, the Mac app also sends a report that adds only an
  error code (a fixed code, or the system's error domain and number) to what
  every report carries; unlike the reports around it, this one keeps the usual
  breadcrumbs. Since v1.60 the Mac app also sends a separate report of its own
  when its main thread has not answered for ten
  seconds, at most two a launch. Besides what every report carries (the app
  and OS version, the device details, the device hash described above and the
  SDK's random installation identifier), it holds only the number of seconds, a fixed word for what the
  main thread was doing (running, waiting, stopped, uninterruptible, halted or
  unknown), how many times it was suspended, how much processor time it used
  while we looked, a fixed word for the kind of event loop it was in
  (`default`, `event_tracking`, `modal_panel`, `none`, `unreadable` or
  `other`), which install channel this Mac has, and whether it was waiting in
  a loop that waits for you on purpose (a menu held open or a dialog). It has no stack trace and no breadcrumbs, and no
  window title, file name or account detail. Since v1.62 the Mac app outside
  the App Store also sends an error report when, on a refresh you started, the
  Keychain answered "cancelled" or "authentication failed" for a browser's
  "Safe Storage" item, and when a background refresh was told by the Keychain
  that reading such an item would need a dialog (which a locked keychain also
  says); and the iPhone app sends one when the Keychain did not accept the new
  sign-in tokens and the app kept them in memory, when it wrote them later,
  and when it opened and found that its last run had ended still holding
  some. Each of these outcomes is sent at most once a UTC day. Besides what
  every report carries (the stack trace, the app and OS version, the device
  details, the device hash described above and the SDK's random installation
  identifier), each holds only a
  fixed word for what happened and, for the Mac one, the browser's name from a
  fixed list, the install channel and whether the screen was locked (when the system says). It has
  no breadcrumbs, no tokens, no error text from the system, and no account
  detail. Performance tracing
  is disabled
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
  Mac and on Android, and in Settings on iPhone) deletes your account and the
  records linked to it in our database (see *Deleting your account* for what
  stays). On Android it then deletes what the
  app itself keeps on the phone, except files you exported, and returns to the
  sign-in screen; what its libraries keep stays until you uninstall the app (see
  the table). If our server cannot delete the account, for example because the
  phone is offline, the app says so, keeps you signed in and deletes nothing
  (unless our server refuses its sign-in meanwhile, as the table describes).
  You can also have your account deleted without any of the apps: see
  *Deleting your account* below.
- **Sign out on the Mac, iPhone and Apple Watch:** from 1.63, Sign Out asks
  our server to end that device's sign-in only; your other devices stay signed
  in. If the sign-in has expired, or is about to, the app renews it first so
  that the request is accepted; otherwise, if our server refuses the request
  because of its sign-in, the app renews it then and tries once more. It
  renews at most once, and the renewed sign-in is used for this alone and not
  kept. It spends at most 20 seconds on the network and does not try again
  later, so a sign-out while offline leaves that sign-in on our server (see
  *Network details* in the table). An Apple
  Watch that uses the sign-in your iPhone passed it shares the iPhone's: its
  own Sign Out sends our server nothing, and the iPhone's Sign Out ends it. A
  Watch signed in by itself, with a code sent to your email, has a sign-in of
  its own, which its Sign Out ends. In 1.62 and earlier, Sign Out asked our
  server once, without renewing the sign-in first, to end your account's
  sign-ins on every device.
- **Sign out on Android:** Settings → Sign Out deletes the app's sign-in
  details and saved usage figures from the phone first, without waiting for
  the network, then asks our server to end this phone's sign-in only, in the
  same way as the item above (renewing it first if needed, at most 20 seconds
  on the network, no later retry). Your other devices stay signed in. After
  that the app sends nothing linked to your account. The phone's record in
  your account (maker, model, Android version and any notification token)
  stays until you delete the account, and each later sign-in adds a new one.
- **Older versions still sign out all your devices.** When our
  server accepts a sign-out request from the Mac, iPhone or Apple Watch app in
  1.62 or earlier, or from the Android app in 1.62.0 or earlier, it ends your
  account's sign-ins on every device, those on 1.63 included: your other
  devices can no longer renew their sign-in and have to sign in again once
  their current one runs out (normally within an hour); a sign-in check, such
  as the one an app makes when it starts, may sign them out sooner.
- **Stop the Android app's background uploads:** sign out (Settings → Sign
  Out). The background job stays scheduled (Android runs it at most about
  every 15 minutes, and only with a network connection and a battery that is
  not low), but sends nothing while no one is signed in; uninstalling the app
  removes it. The app has no separate switch for it.
- **Sign-in methods on iPhone and Android:** Settings → Linked Accounts adds
  Apple (iPhone only), Google or GitHub as a way to sign in to your account, or removes one while another way
  to sign in remains.
- **Export:** Use the Export menu in the Overview tab (Mac and Android) to save
  a PDF or CSV of the data it shows. On Android the file is first written to
  the app's cache folder and then handed to the app you pick in Android's share
  menu. It stays in that folder, also after you sign out or delete your
  account, until Android clears the app's cache or you uninstall the app. Each
  of the four kinds of CSV export replaces the previous file of its kind, so up
  to four CSV files stay; PDF reports are named by date, so one stays for each
  day you export one.
- **Stop product email:** every product email we send carries a one-click opt
  out, and honouring it is immediate and permanent. You can also email
  yyyyy.yeyuhe@gmail.com and ask. Opting out never affects your account, your
  subscription, or anything the app does.

---

## Deleting your account

**In an app:** Settings → Delete Account, on the Mac, iPhone or Android, while
signed in (see *Your controls* for what the Android app then removes from the
phone).

**Without an app**, for example after you uninstalled it, or if someone asked
for a sign-in code for your address: email clipulse.support@gmail.com from the
address your account uses, with the subject "Delete my CLI Pulse account". We
may reply to that address to confirm the request is yours, and then delete the
account as the app would; if the request cannot be confirmed as yours, the
account is not deleted. If you signed in with Apple and hid your email
address, write from any address, tell us the relay address, and we will agree
with you how to confirm the request.

Either way, deleting the account removes your sign-in, settings, alert
webhook, usage history, quotas, sessions, alerts, device records and the other
records linked to your account, within 30 days (see *Data retention*); a team
you own passes to another member, if one remains. It does not remove what is
stored apart from your account (anonymous install statistics, crash reports already
sent to Sentry, the Firebase registration Google keeps for an Android install,
and invitations to someone else's team sent to your email address), nor
entries already written to Supabase's request and sign-in logs, which are
deleted after about 90 days, nor the emails you sent us, including the
request, which stay in our mailbox. Nor does it reach copies on your devices
at once: an Android phone that was signed in keeps what it saved until our
server refuses its sign-in, which the app finds out when it starts, while it is
open, or in its background sync (not while the phone is offline). It then
deletes its sign-in details and saved usage figures together, as Sign Out does.
Until then it goes on sending its usual requests, its background sync's
included, with the old sign-in.

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
exchange for anything — the App Store and Google Play forbid it, and so do we.

---

## Data retention

- **Local Keychain entries** persist until you remove the provider (or, for
  the session token, sign out). Moving the app to the Trash does not remove
  them: macOS keeps Keychain items until they are deleted, for example in
  Keychain Access.
- **What the Android app keeps on the phone** stays until you sign out, delete
  your account in the app, our server refuses its sign-in, or you uninstall the
  app (the table above lists the exceptions, including what its libraries
  keep). Files you export stay in the
  app's cache folder until Android clears it or you uninstall the app.
- **Your Android phone's record in your account** (its maker, model, Android
  version and any notification token) stays until you delete your account.
  Signing out does not remove it and the app has no way to; each sign-in after
  a sign-out adds a new one.
- **Usage history** on Supabase is kept for **up to 18 months** of rolling
  history. A nightly job deletes rows older than that from the long-tail
  analytical tables (`commits`, `sessions`, `session_commit_links`,
  `daily_usage_metrics`, `yield_score_daily`). 18 months is long enough to
  support year-over-year cost comparisons with one month of buffer; beyond that
  the historical detail adds no product value and we'd rather delete it.
- **Ended AI CLI sessions and alerts** are deleted by a nightly job once they
  are older than your account's retention setting: 7 days, unless you changed
  it in the Android app or an earlier version of an app changed it. A session
  still marked as running is deleted too once nothing has updated it for that
  long. Of the current apps, only the Android app can change the setting:
  Settings → Thresholds → "Data Retention (days)", any whole number of days
  from 1 up. The job counts at most 36,500 days (about 100 years), and sessions
  are deleted after 18 months whatever the setting (see *Usage history*
  above), so a setting longer than that keeps only alerts longer. (Earlier
  versions of this document pointed to a setting in Settings → Privacy that
  does not exist.)
- **Everything else stored with your account** (your login email, name,
  password hash, linked sign-in methods, settings, alert webhook, quota state,
  subscription and device records) is kept while the account exists and deleted
  with it.
- **A copy of each new alert.** When an alert is made, our server also stores a
  copy to send to an alert webhook, even if you have not added one: its title,
  message, type, severity, provider, folder name, time and grouping keys (for a
  Mac's CPU alert, these include that Mac's ID), when our server passed it on
  for delivery and how many tries that took, and, if your webhook refused it,
  the HTTP status it answered with. Once our server is done with a copy (it was
  sent, skipped, for example because no webhook takes it, or given up after its
  tries), the nightly job that deletes ended sessions and alerts deletes it at
  its first run more than a day later, whatever your retention setting:
  normally 24 to 48 hours after our server finished with it, longer if a
  nightly run is missed or fails. That job never deletes a copy our server has
  not finished with; such a copy stays, even after the alert itself is gone,
  until our server finishes with it or you delete your account.
- **Network details of requests** are kept in Supabase's request and sign-in
  logs for about 90 days (the request logs also hold the city and country worked
  out from your IP address), and with each sign-in session until you delete your
  account or sign out on that device (a sign-out removes it only when our
  server accepts the app's sign-out request, and *Network details* in the table
  says which records each version's sign-out removes; records of expired
  sessions are cleaned up later); a
  Mac pairing attempt's IP address is deleted at the cleanup after it is an
  hour old. Deleting your account does not remove log entries already written.
- **Crash reports** are kept by Sentry for the retention period of our Sentry
  plan and then deleted. They carry no account, so deleting your account does
  not remove them. Google keeps the Firebase registration of an Android install
  under Firebase's own terms.
- **Account deletion** removes the rows associated with your account within 30
  days (cascading deletes handled at the database level; see
  *Deleting your account* for what stays).
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
- **Google** — used for Sign in with Google at the user's option. The Android
  app also uses two other Google services. **Firebase Cloud Messaging:** when
  the app starts, whether or not you are signed in and in Try Demo too,
  Firebase registers this install of the app with Google and renews the
  registration from time to time. It sends Google a random installation ID and
  a sign-in token of its own, the app's and Android's versions, the versions of
  Google Play services and of its own code, and the phone's model details,
  through Google Play services on the phone, which identifies the phone to
  Google in its own way, and gets back the notification token. That is
  Firebase's default, which our code does not change; signing out does not
  remove the registration, and our server sends nothing through it. **Google
  Play:** the first time you open Settings ›
  Subscription (also in Try Demo), and again whenever Google Play's billing
  service reconnects while the app stays open, the app asks Google Play on the
  phone which CLI Pulse subscriptions exist and whether your Google account has
  one, and Google's billing library may send Google its own records of those
  requests. Nothing can be bought on Android. Only if Google Play reported a CLI
  Pulse subscription would the app confirm it to Google Play (if it was not yet
  confirmed) and send our server its purchase token, product ID and the app's
  package name, for us to check with Google Play. **Gmail** hosts our support
  and security mailboxes (see *Contact*), so an email you send us, including a
  request to delete your account, is kept by Google.
- **GitHub** — used for Sign in with GitHub at the user's option. GitHub also
  hosts the direct-download build's update information and downloads, and the
  Companion CLI's, so checking for an update is a request to GitHub.
- **Sentry (sentry.io)** — receives the crash reports described above.

We do not share data with any party not listed above, except where you direct
it: the AI providers you use receive the requests CLI Pulse makes to them with
your own credentials, and an alert webhook you add receives your alerts. CLI
Pulse also fetches exchange rates from open.er-api.com, at most once a day, to
show costs in other currencies; that request carries nothing about you or your
usage. The Mac and iPhone apps also ask the public status pages of the providers
you track (such as status.claude.com or status.openai.com) whether a provider
has an outage, unless you turn off Settings › Check provider status. Those
requests carry no credentials and none of your usage, but which pages are asked
shows which providers you track, and, like any web request, they show your IP
address. We do not sell data.

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

- Email: clipulse.support@gmail.com
- Security disclosures: yyyyy.yeyuhe@gmail.com (subject `[CLI Pulse Security]`)
- GitHub issues: <https://github.com/cli-pulse/cli-pulse/issues>

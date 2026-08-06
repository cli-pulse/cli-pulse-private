# Privacy Policy

**CLI Pulse**
**Last Updated: August 6, 2026**

CLI Pulse is a developer tool for monitoring usage, quotas, and cost across AI
coding providers (Claude, Codex, Gemini, OpenRouter, and others). Our privacy
goal is straightforward: **your provider API keys never leave your device**, and
everything else we sync is kept to the minimum needed for cross-device viewing.

This document is the single source of truth for what we collect. If you find
anything in the app, App Store listing, or GitHub README that contradicts this
file, **the file wins** — please open an issue.

---

## Data-by-data breakdown

| Data | Stored where | Sent to our server? | Purpose |
|---|---|---|---|
| **Provider API keys** (OpenAI, Anthropic, Google, OpenRouter, etc.) | macOS Keychain on this device | ❌ Never | Used locally to call the provider's own API directly |
| **Provider session cookies** (manual cookie headers) | macOS Keychain on this device | ❌ Never | Used locally as `Cookie` header to the provider |
| **Bridged OAuth tokens** from `~/.codex/auth.json`, `~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json` | macOS Keychain (app-group shared) | ❌ Never | Shared between the sandboxed main app and the local helper only |
| **Contents of your `~/.codex/sessions/` and `~/.claude/projects/` JSONL files** | Read on-device via security-scoped bookmarks you explicitly grant | ❌ Never | Scanner computes token counts locally |
| **Aggregated usage metrics** (per-day token counts, cost estimate, model name, provider name, date) | Supabase, linked to your CLI Pulse account | ✅ Yes | So iPhone and Apple Watch show the same history as your Mac |
| **Provider quota state** (remaining, limit, plan tier, reset time) | Supabase, linked to your CLI Pulse account | ✅ Yes | So mobile clients display current quotas without running the scanner themselves |
| **Your CLI Pulse login email** | Supabase Auth | ✅ Yes | Required to authenticate you |
| **Apple / Google sign-in tokens** (during sign-in) | Not persisted — exchanged once for a Supabase session | ✅ Yes (during sign-in only) | Identity verification with the original OAuth provider |
| **Supabase session access / refresh token** | macOS Keychain on this device | ❌ Never re-uploaded (only received) | Keeps you signed in |
| **Device name, OS version, helper version** | Supabase | ✅ Yes | Shows which Macs/iPhones are reporting |
| **Git activity metadata** (commit hash, HMAC of project path, commit timestamp, merge flag) | Supabase — only when "Track git activity" toggle is ON | ✅ Yes (opt-in only) | Powers the Yield Score feature |
| **Git commit messages, diffs, file paths, author identity** | — | ❌ Never | Explicitly excluded even when Yield Score is on |
| **Alerts you resolve locally** (quota depletion alerts) | UserDefaults on this device | ❌ Never | Suppression list to prevent re-firing |
| **Crash reports** (stack trace, app version, OS version, non-PII device model) | Sentry (sentry.io), scrubbed before leaving the device | ✅ Yes (when a crash/error happens) | So crashes are visible to us without waiting for an App Store review |
| **Anonymous install statistics** (random install id, install channel, app version, OS major.minor, and whether a CLI was ever found) | Supabase, **not linked to any account** | ✅ Yes, unless you turn it off | Tells us whether the app actually works for people who never sign in |

**The key point:** the two categories of data you'd be most worried about —
provider API keys and raw session-log contents — never touch our servers, full
stop.

### About that last row

Every other upload in this table happens only when you are signed in and is
attached to your account. **Anonymous install statistics are the one exception**,
so they get spelled out rather than buried in a table cell.

Since v1.44 you can use CLI Pulse without an account. That means we cannot tell
whether the app works for the people using it that way — whether it found their
CLIs, whether they ever saw a number. Two counters, and nothing else:

1. **CLI Pulse was installed** — recorded on first launch.
2. **CLI Pulse found a CLI to track** — recorded the first time this happens,
   and never updated afterwards.

Sent with each: a **random** identifier generated on your Mac, which channel the
app came from (App Store, direct download, or Homebrew), the app version, and
your macOS version rounded to major.minor (`15.1`, never the full build string).

Not sent, ever: your account or email (there is no account involved and no login
token is attached to the request), your name, your device's name, serial number
or hardware identifiers, your IP address, any file path or project name, which
provider you use, or any token count or cost figure.

The identifier is random — not derived from your hardware, and not a hash of
anything about it. It is stored in the app's preferences, so **uninstalling CLI
Pulse deletes it**; reinstalling produces a new, unrelated one. We cannot connect
it to you, and we cannot connect two installs to each other.

**Turning it off:** Settings → Privacy → "Send anonymous install statistics".
Off means nothing is sent at all. **Local-only mode also turns it off** — you do
not need to set both. The app tells you about this on first launch, before it
sends anything.

---

## How data moves

```
┌─────────────────────────┐         ┌──────────────────┐
│  Your Mac               │         │  AI provider     │
│  ┌─────────────────┐    │         │  (OpenAI,        │
│  │ API key in      │─── Direct ──▶│  Anthropic,      │
│  │ macOS Keychain  │    │ HTTPS   │  Google, ...)    │
│  └─────────────────┘    │         └──────────────────┘
│                         │
│  ┌─────────────────┐    │
│  │ JSONL session   │    │         ┌──────────────────┐
│  │ logs (local)    │──── read ────│ CLI Pulse        │
│  └─────────────────┘    │  only   │ Supabase backend │
│                         │         │                  │
│  ┌─────────────────┐    │         │ - Email          │
│  │ Token counts,   │─── HTTPS ───▶│ - Usage numbers  │
│  │ costs (numbers) │    │         │ - Quota state    │
│  └─────────────────┘    │         │ - Device list    │
│                         │         └──────────────────┘
│  ┌─────────────────┐    │         ┌──────────────────┐
│  │ 2 counters:     │    │         │ Anonymous install│
│  │ installed /     │─── HTTPS ───▶│ table            │
│  │ found a CLI     │    │         │                  │
│  │ (opt-out)       │    │         │ NO account, NO   │
│  └─────────────────┘    │         │ link to the above│
└─────────────────────────┘         └──────────────────┘
                                             │
                                             ▼
                                     ┌──────────────────┐
                                     │  Your iPhone /   │
                                     │  Apple Watch     │
                                     └──────────────────┘
```

The scanner runs entirely on your Mac. Your API key never passes through our
servers — it goes directly from your Keychain to the provider.

---

## Security practices

- **macOS Keychain** is used for every secret (provider API keys, manual
  cookies, Supabase session tokens). Keychain is encrypted at rest, unlocked
  alongside your login, and inaccessible to other apps.
- **App Sandbox** is enabled (`com.apple.security.app-sandbox`). File access
  outside the app container requires security-scoped bookmarks you grant
  explicitly in Settings → CLI Tool Access.
- **TLS 1.2+** for every network connection.
- **Supabase server-side encryption at rest** (AES-256) for the database and
  storage backing your account. We do **not** currently offer end-to-end
  encryption — the metrics we store are aggregate numbers, not secrets. See
  "Roadmap" below.
- **No third-party analytics SDKs.** We do not ship Google Analytics,
  Firebase Analytics, Amplitude, Mixpanel, Crashlytics, or any similar
  product-analytics tool. There is no fingerprinting and no ad network
  integration. This is a statement about SDKs, and we would rather over-explain
  than let it read as more than it is: we do collect the two install counters
  described above, ourselves, to our own database. They are opt-out, carry no
  account, and go nowhere else.
- **Sentry for crash reports only.** We ship the Sentry SDK in all four
  clients (macOS, iOS, watchOS, Android) strictly for crash and error
  reporting. PII is disabled (`sendDefaultPii = false`), IP addresses are
  dropped at the Sentry ingest layer, and a local `beforeSend` hook scrubs
  API keys, OAuth tokens, JWTs, Bearer headers, `/Users/<name>` paths, and
  any field whose name contains common sensitive fragments (`token`,
  `secret`, `password`, `api_key`, `supabase`, etc.) before the event
  leaves your device. Performance tracing is disabled
  (`tracesSampleRate = 0`); only crashes and explicit error reports are
  sent.

---

## Your controls

- **Revoke folder access:** Settings → CLI Tool Access → specific directory
  → remove bookmark.
- **Disable Yield Score / git tracking:** Settings → Privacy → "Track git
  activity" toggle. Off by default; the toggle stops uploads immediately.
- **Disable anonymous install statistics:** Settings → Privacy → "Send
  anonymous install statistics". On by default, disclosed on first launch
  before anything is sent. Local-only mode disables it too.
- **Delete API keys:** Remove any provider config in Settings → Providers;
  the Keychain entry is deleted.
- **Delete your account:** Settings → Account → Delete Account purges the
  Supabase row and all associated usage metrics.
- **Export:** Use "Export Report" in the Overview tab to download a PDF or
  CSV of your own data.

---

## Data retention

- **Local Keychain entries** persist until you delete the provider or the
  app.
- **Account-active metrics** on Supabase are retained for **up to 18
  months** of rolling history. A nightly job prunes rows older than that
  from the long-tail analytical tables (`commits`, `sessions`,
  `session_commit_links`, `daily_usage_metrics`, `yield_score_daily`). 18
  months is long enough to support year-over-year cost comparisons with
  one month of buffer; beyond that the historical detail adds no product
  value and we'd rather delete it.
- **Per-user retention overrides:** if you set a shorter `data_retention`
  in Settings → Privacy, that value applies to your sessions, alerts, and
  device snapshots (it overrides the 18-month default for those tables).
- **Account deletion** removes all associated rows within 30 days
  (cascading deletes handled at the database level).
- **Anonymous install rows** are deleted 400 days after they were last
  touched. They are not attached to an account, so account deletion does not
  reach them — there is no link to follow. Deleting the app deletes the only
  copy of the identifier, which is on your Mac.

---

## Third-party sub-processors

- **Supabase (hosted in Tokyo region, Japan)** — provides authentication,
  Postgres storage, and edge functions for the metrics sync described above.
- **Apple** — used for Sign in with Apple, App Store payments, and
  StoreKit-based subscription management. Receipt validation forwards only
  the StoreKit JWS and product ID.
- **Google** — used for Sign in with Google at the user's option. Only the
  ID token and nonce are exchanged during sign-in.

We do not share data with any party not listed above. We do not sell data.

---

## Children's privacy

CLI Pulse is a developer tool intended for users 17 or older. We do not
knowingly collect data from children.

---

## Changes to this policy

We will update the "Last Updated" date above when this policy changes and
note material changes in release notes. The authoritative version lives at
<https://github.com/cli-pulse/cli-pulse/blob/main/PRIVACY.md>.

---

## Roadmap: end-to-end encryption

We've looked at adding E2EE to the Supabase-stored metrics. Today, the
sensitive data (API keys, session log contents) already never leaves your
device, so the marginal privacy gain from encrypting the numeric metrics is
smaller than it sounds. Implementing E2EE also conflicts with cross-device
sync, which requires multi-device key management we don't want to ship
half-built. If you have a specific threat model where E2EE on metrics
matters to you, please open an issue — we'd rather hear the use case than
guess.

---

## Contact

- Email: yyyyy.yeyuhe@gmail.com
- GitHub issues: <https://github.com/cli-pulse/cli-pulse/issues>

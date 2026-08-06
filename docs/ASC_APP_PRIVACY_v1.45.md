# App Store Connect — App Privacy answers for v1.45

Prepared, **not applied**. Changing App Privacy edits the live App Store listing,
and release-surface changes are the owner's call (`feedback_appstore_update`).
Everything else for this feature is already merged.

Apply this **when v1.45 is submitted**, together with merging
[cli-pulse/cli-pulse#28](https://github.com/cli-pulse/cli-pulse/pull/28) (the
live privacy policy). Doing it earlier would describe collection that is not
happening yet; doing it later means shipping collection that is not disclosed.

---

## What actually changed

v1.45 adds two counters for users who never sign in. Everything already declared
stays as it is — this **adds one data type**, it does not modify any existing
answer.

- `install` — the app ran for the first time
- `first_provider_detected` — it later found a CLI and had a number to show

Sent with each: a random install id, the install channel, the app version, and
the OS version as major.minor. See `PRIVACY.md` for the full statement.

---

## The answers

**Path:** App Store Connect → CLI Pulse → App Privacy → Edit

### 1. Add data type: `Product Interaction`

Under **Usage Data → Product Interaction**.

| Question | Answer |
|---|---|
| Is this data used for tracking? | **No** |
| Is this data linked to the user's identity? | **No** |
| Purposes | **Analytics** only |

Rationale for each, in case review asks:

- **Not tracking.** Apple defines tracking as linking this data with third-party
  data for advertising or measurement, or sharing it with a data broker. Neither
  happens: the rows sit in our own Supabase project and are shared with nobody.
- **Not linked to identity.** The request carries no account token — literally
  cannot, the transport has no access to one — and the row has no user column.
  The identifier is a random UUID generated on device, not derived from the
  hardware, stored in app preferences and destroyed on uninstall.
- **Analytics only.** Not used for personalisation, not for advertising, not for
  product functionality.

### 2. Do NOT add `Device ID` or `User ID`

This is the answer most likely to be second-guessed, so the reasoning is here.

`Identifiers → Device ID` covers values that identify a device — IDFV, IDFA,
hardware identifiers, or anything derived from them. Our install id is none of
these. It is `UUID()`, generated once, with no input from the machine. Two
installs on the same Mac produce two unrelated ids; reinstalling produces a
third. It cannot be correlated back to a device or joined against anything.

Declaring `Device ID` would be *over*-declaring, and over-declaring is not the
safe choice here — it would tell users on the product page that we collect a
device identifier when we deliberately went out of our way not to.

### 3. Everything else stays unchanged

No change to Contact Info, Identifiers, Diagnostics (Sentry crash data is
already declared), Usage Data beyond the addition above, or the tracking answer
for the app as a whole.

---

## Both platforms?

**macOS: yes.** The feature ships in the Mac app.

**iOS / watchOS: no.** The counters are wired only into the macOS target —
`AnonymousTelemetryCoordinator` exists in the Mac app, and nothing on iOS
constructs it. The shared `CLIPulseCore` package contains the code, but code
that is never called collects nothing, and App Privacy asks what the app
collects.

If that ever changes, this file changes with it.

---

## Privacy manifest (`PrivacyInfo.xcprivacy`)

**No change needed, and none was made.**

Apple's privacy-manifest requirement covers iOS, iPadOS, tvOS, watchOS and
visionOS. macOS is not in that list, and the macOS target has never shipped a
manifest. The iOS, Watch and Widgets targets each have one, and all three keep
`NSPrivacyCollectedDataTypes` empty — correctly, because none of them collects
this.

Adding a manifest to the macOS target would be inventing a requirement.
Adding a collected-data entry to the iOS manifest would be declaring a
collection that does not happen on iOS.

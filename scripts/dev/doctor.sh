#!/usr/bin/env bash
# CLI Pulse — onboarding doctor.
#
# Run this first, on a new machine, before asking anyone anything:
#
#     scripts/dev/doctor.sh
#
# It reports exactly what you have, what you are missing, and for each missing
# item who issues it and how to get it. Nothing here is destructive and nothing
# prints a secret value — checks are exit-code or fingerprint based, so the
# output is safe to paste into a chat when asking for help.
#
# Capability tiers. You do NOT need all of them, and most contributors should
# stop at tier 2:
#
#   1  develop            edit code, run the app from Xcode
#   2  verify             run the full test suite and every CI gate locally
#   3  sign locally       produce a signed .app for your own testing
#   4  publish DEVID DMG  cut the direct-download release
#   5  upload to ASC      push a build to App Store Connect
#   6  submit / release    put a version in front of review, then in front of users
#   7  backend            apply Supabase migrations
#
# Tiers 4-7 are OWNER-LEVEL. Getting them wrong is visible to every user, so
# they are deliberately gated on credentials that are not handed out casually.
#
# Exit code is the highest tier you are fully equipped for (0 if not even tier 1).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[[ -t 1 ]] || { BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; OFF=""; }

tier_ok=(1 1 1 1 1 1 1)   # index 0..6 == tier 1..7
notes=()

ok()   { printf "  ${GRN}✓${OFF} %s\n" "$1"; }
bad()  { printf "  ${RED}✗${OFF} %s\n" "$1"; tier_ok[$(( $2 - 1 ))]=0; notes+=("$3"); }
warn() { printf "  ${YEL}!${OFF} %s\n" "$1"; }
hdr()  { printf "\n${BOLD}%s${OFF}\n" "$1"; }

# ---------------------------------------------------------------- tier 1 ----
hdr "Tier 1 — develop"

if command -v xcodebuild >/dev/null 2>&1; then
    ok "Xcode $(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"
else
    bad "Xcode not found" 1 "Xcode: install from the Mac App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
fi

if xcode-select -p >/dev/null 2>&1; then
    ok "xcode-select → $(xcode-select -p)"
else
    bad "xcode-select is not pointed at an Xcode install" 1 "run: sudo xcode-select -s /Applications/Xcode.app"
fi

if command -v swift >/dev/null 2>&1; then
    ok "swift $(swift --version 2>/dev/null | head -1 | grep -oE 'Swift version [0-9.]+' | awk '{print $3}')"
else
    bad "swift not found" 1 "comes with Xcode; check xcode-select above"
fi

for t in git gh python3; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else
        bad "$t not found" 1 "install: brew install $t"
    fi
done

if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated as $(gh api user --jq .login 2>/dev/null || echo '?')"
else
    bad "gh not authenticated" 1 "run: gh auth login"
fi

# ---------------------------------------------------------------- tier 2 ----
hdr "Tier 2 — verify (tests + gates)"

gates=(check-versions check_migration_numbers check_helper_version_sync
       check_helper_method_parity check_helper_no_container_touch
       check_no_internal_docs check_copyright)
missing_gate=0
for g in "${gates[@]}"; do
    [[ -f "scripts/$g.sh" ]] || { missing_gate=1; continue; }
done
if [[ $missing_gate -eq 0 ]]; then ok "all offline gates present"; else
    warn "some gate scripts are missing — you may be on an old branch"
fi

# check_legal_urls needs network; treat absence of network as a warning, not a failure
if [[ -f scripts/check_legal_urls.sh ]]; then
    if bash scripts/check_legal_urls.sh >/dev/null 2>&1; then
        ok "legal-URL gate passes (both hosts serve)"
    else
        warn "legal-URL gate failed — offline, or a host really is down. Run it directly to see."
    fi
fi

# The Keychain test trap: tests that build AppState and sign in will hang on a
# real login keychain unless KeychainHelper.inMemoryStoreForTesting is set.
if grep -rq "inMemoryStoreForTesting" "CLI Pulse Bar/CLIPulseCore/Sources" 2>/dev/null; then
    ok "Keychain test seam present (suite will not hang on your login keychain)"
else
    warn "Keychain test seam missing — 'swift test' may hang waiting on an invisible auth dialog"
fi

# ---------------------------------------------------------------- tier 3 ----
hdr "Tier 3 — sign locally"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Distribution"; then
    ok "Apple Distribution certificate present"
else
    bad "no Apple Distribution certificate" 3 \
        "Apple Distribution cert: join the team in Apple Developer, then Xcode → Settings → Accounts → Manage Certificates → + Apple Distribution. Get your OWN — do not import the owner's."
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    ok "Developer ID Application certificate present"
else
    bad "no Developer ID Application certificate" 3 \
        "Developer ID cert: only an Account Holder / Admin can create these, and a team has a limited number. Ask the owner whether to issue you one or to keep DMG cutting with them."
fi

# ---------------------------------------------------------------- tier 4 ----
hdr "Tier 4 — publish DEVID DMG"

if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-AC_NOTARY_PROFILE}" >/dev/null 2>&1; then
    ok "notarytool keychain profile '${NOTARY_PROFILE:-AC_NOTARY_PROFILE}' works"
elif [[ -n "${APPLE_NOTARY_USER:-}" && -n "${APPLE_NOTARY_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    ok "inline notary credentials present in env"
elif [[ "$(ioreg -n Root -d1 -a 2>/dev/null | grep -c '<key>IOConsoleLocked</key>[[:space:]]*<true/>')" != "0" ]] \
     || ioreg -n Root -d1 -a 2>/dev/null | grep -A1 'IOConsoleLocked' | grep -q '<true/>'; then
    # THE SCREEN IS LOCKED, AND THAT IS THE WHOLE PROBLEM.
    #
    # notarytool's credential lives in the DATA-PROTECTION keychain, whose
    # keybag locks with the console — independently of `security
    # show-keychain-info`, which will happily report the login keychain as
    # "no-timeout". When it is locked, secd fails to decrypt the item
    # (OSStatus -25308, errSecInteractionNotAllowed) and returns
    # "no matching items" to the caller. notarytool renders that as
    #
    #     Error: No Keychain password item found for profile: AC_NOTARY_PROFILE
    #
    # which is simply untrue: the item is there and intact.
    #
    # This misreading cost three separate investigations (2026-05-12,
    # 2026-08-01, 2026-08-07) that all concluded the profile had "evaporated"
    # and all "fixed" it by running store-credentials again — which works only
    # because recreating it requires sitting at the machine, i.e. unlocking the
    # screen. The unlock was the fix; the recreation was cargo cult, and it
    # burned a one-time Apple password each round.
    #
    # Verified on 2026-08-07: while locked, `security` lists 465 generic-password
    # items normally and only this one is unfindable. Nothing was deleted.
    bad "cannot read the notarization profile — THE SCREEN IS LOCKED" 4 \
        "Unlock the Mac and run this again. notarytool reports a locked keychain as 'No Keychain password item found', which is a lie — the credential is intact. Do NOT run store-credentials to 'fix' this; it wastes a one-time Apple password and hides the real cause. For unattended/agent builds, use the inline path instead (APPLE_NOTARY_USER / APPLE_NOTARY_APP_PASSWORD / APPLE_TEAM_ID from ~/Library/Application Support/CLI-Pulse-Secrets/notarytool-app-password-*.txt), which does not touch the keychain and is immune to screen lock."
else
    # Screen is unlocked and the profile still cannot be read, so this is a
    # genuine absence — first setup, a different user, or an actual deletion.
    if compgen -G "$HOME/Library/Application Support/CLI-Pulse-Secrets/notarytool-app-password-*.txt" >/dev/null 2>&1; then
        bad "notarization profile genuinely missing — but a saved password exists" 4 \
            "Screen is unlocked and the profile still is not readable, so it really is absent. Recreate with: xcrun notarytool store-credentials AC_NOTARY_PROFILE --apple-id <owner-apple-id> --team-id KHMK6Q3L3K --password <from ~/Library/Application Support/CLI-Pulse-Secrets/notarytool-app-password-*.txt>."
    else
        bad "no working notarization credential" 4 \
            "Notarization: create an app-specific password at appleid.apple.com for YOUR OWN Apple ID, then: xcrun notarytool store-credentials AC_NOTARY_PROFILE --apple-id <you@example.com> --team-id KHMK6Q3L3K --password <app-specific-password>. Per-person — never share the owner's. SAVE the password to ~/Library/Application Support/CLI-Pulse-Secrets/ (chmod 600) immediately: Apple shows it exactly once."
    fi
fi

if gh api repos/cli-pulse/cli-pulse-distrib --jq .name >/dev/null 2>&1; then
    perm="$(gh api "repos/cli-pulse/cli-pulse-distrib/collaborators/$(gh api user --jq .login 2>/dev/null)/permission" --jq .permission 2>/dev/null || echo '?')"
    if [[ "$perm" == "write" || "$perm" == "admin" ]]; then ok "cli-pulse-distrib: $perm"; else
        bad "cli-pulse-distrib permission is '$perm' (need write)" 4 "ask the owner for write on cli-pulse/cli-pulse-distrib"
    fi
else
    bad "cannot reach cli-pulse-distrib" 4 "ask the owner for access to cli-pulse/cli-pulse-distrib"
fi

# ---------------------------------------------------------------- tier 5 ----
hdr "Tier 5 — upload to App Store Connect"

asc_key=""
for p in "${ASC_KEY_PATH:-}" "$HOME/.appstoreconnect/private_keys"/AuthKey_*.p8; do
    [[ -n "$p" && -f "$p" ]] && { asc_key="$p"; break; }
done
if [[ -n "$asc_key" ]]; then
    ok "ASC API key present ($(basename "$asc_key"))"
    if [[ -n "${ASC_API_ISSUER:-}" ]]; then ok "ASC_API_ISSUER set"; else
        warn "ASC_API_ISSUER not set in env — scripts may still find it in their own config"
    fi
else
    bad "no App Store Connect API key (.p8)" 5 \
        "ASC API key: get your OWN. Owner adds you to App Store Connect → Users and Access with the App Manager role; you then create your own key under Integrations → App Store Connect API and save it to ~/.appstoreconnect/private_keys/. A .p8 downloads exactly once."
fi

# ---------------------------------------------------------------- tier 6 ----
hdr "Tier 6 — submit / release"

printf "  ${DIM}Not machine-checkable — it is an ASC role, not a file.${OFF}\n"
printf "  ${DIM}Uploading a build needs App Manager. Submitting for review and pressing${OFF}\n"
printf "  ${DIM}Release both need App Manager too, but they are the actions users see${OFF}\n"
printf "  ${DIM}immediately and cannot be undone — agree with the owner who presses them.${OFF}\n"

# ---------------------------------------------------------------- tier 7 ----
hdr "Tier 7 — backend"

if [[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
    ok "SUPABASE_ACCESS_TOKEN set in env"
else
    warn "SUPABASE_ACCESS_TOKEN not set — only needed to apply migrations, not to write SQL"
fi
printf "  ${DIM}Writing and reviewing migrations needs nothing but the repo. Only APPLYING${OFF}\n"
printf "  ${DIM}them to production needs credentials, and per CLAUDE.md a schema change is${OFF}\n"
printf "  ${DIM}an owner decision regardless of who holds the token.${OFF}\n"

# ------------------------------------------------------------------ report --
hdr "Result"

highest=0
for i in 0 1 2 3 4 5 6; do
    if [[ ${tier_ok[$i]} -eq 1 ]]; then highest=$(( i + 1 )); else break; fi
done

names=("develop" "verify" "sign locally" "publish DEVID DMG" "upload to ASC" "submit/release" "backend")
if [[ $highest -eq 0 ]]; then
    printf "  ${RED}Not ready for tier 1.${OFF} Fix the items above and re-run.\n"
else
    printf "  You are equipped through ${BOLD}tier %d — %s${OFF}.\n" "$highest" "${names[$(( highest - 1 ))]}"
    [[ $highest -lt 7 ]] && printf "  ${DIM}Higher tiers are owner-level; most work needs only tiers 1-2.${OFF}\n"
fi

if [[ ${#notes[@]} -gt 0 ]]; then
    printf "\n${BOLD}How to get what is missing${OFF}\n"
    for n in "${notes[@]}"; do printf "  • %s\n" "$n"; done
fi

printf "\n${DIM}Full handover doc: cli-pulse-internal/ONBOARDING.md${OFF}\n"
printf "${DIM}Nothing above printed a secret — this output is safe to paste when asking for help.${OFF}\n"

exit "$highest"

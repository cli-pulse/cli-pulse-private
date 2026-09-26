#!/usr/bin/env bash
# Render the real macOS views of the QA build, offscreen, once per shipped
# language: PNGs plus a manifest.json per language, for native review.
#
# Nothing appears on screen. The QA app's render mode (QASnapshotRenderer.swift,
# compiled only into the `Debug QA` configuration) creates no status item and
# never orders a window in, and its activation policy forbids it from coming to
# the front. How it works and what it draws: docs/qa/macos-offscreen-renders.md.
#
# Usage:
#   scripts/render_macos_qa_views.sh --app "<path>/CLIPulse QA.app" --out <dir>
#       [--lang ja]... [--appearance light|dark] [--replace] [--timeout 600]
#
# Build the app first (the QA scheme, `Debug QA`):
#   xcodebuild build -project "CLI Pulse Bar/CLI Pulse Bar.xcodeproj" \
#     -scheme "CLIPulse QA" -configuration "Debug QA" -destination platform=macOS \
#     -derivedDataPath build/qa
#   → build/qa/Build/Products/Debug QA/CLIPulse QA.app
#
# Exit status: 0 when every language rendered cleanly; 1 on a usage or safety
# refusal; 2 when at least one language failed or reported a problem.

set -euo pipefail

QA_BUNDLE_ID="app.clipulse.qa.local"
QA_ROOT="/private/tmp/clipulse-qa-home"
ALL_LANGUAGES=(en zh-Hans zh-Hant ja ko es)

app=""
out=""
languages=()
appearance="light"
replace=0
timeout_seconds=600

die() { echo "render_macos_qa_views: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) app="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        --lang) languages+=("${2:-}"); shift 2 ;;
        --appearance) appearance="${2:-}"; shift 2 ;;
        --replace) replace=1; shift ;;
        --timeout) timeout_seconds="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$app" && -n "$out" ]] || die "--app and --out are required (see --help)"
[[ ${#languages[@]} -gt 0 ]] || languages=("${ALL_LANGUAGES[@]}")
# Checked before anything else happens, because each language names a folder
# under --out that --replace deletes: "--lang .." would have removed the parent
# of the output folder, and "--lang ''" the output folder itself. The app also
# refuses a language it does not ship, but only after that deletion.
seen=" "
for lang in "${languages[@]}"; do
    [[ " ${ALL_LANGUAGES[*]} " == *" $lang "* ]] \
        || die "unknown language '$lang' (one of: ${ALL_LANGUAGES[*]})"
    [[ "$seen" != *" $lang "* ]] || die "language '$lang' given twice"
    seen+="$lang "
done
[[ "$appearance" == light || "$appearance" == dark ]] || die "--appearance must be light or dark"
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || die "--timeout must be a number of seconds"

# --- The app must be the QA build, not anything that could be production. ---
info="$app/Contents/Info.plist"
[[ -f "$info" ]] || die "no app at $app"
bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info")
channel=$(/usr/bin/plutil -extract CLIPULSE_CHANNEL raw -o - "$info" 2>/dev/null || true)
executable=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info")
[[ "$bundle_id" == "$QA_BUNDLE_ID" && "$channel" == qa ]] \
    || die "$app is $bundle_id (channel '${channel:-none}'), not the QA build"
binary="$app/Contents/MacOS/$executable"
[[ -x "$binary" ]] || die "no executable at $binary"

mkdir -p "$out"
out=$(cd "$out" && pwd -P)

# --- Things that would reach the screen or someone else's state. ---
# A QA app already running shares the QA defaults domain this run empties and
# restores; running both would lose that app's changes.
if /usr/bin/pgrep -x "$executable" >/dev/null 2>&1; then
    die "a '$executable' process is running; quit it first (it shares the QA defaults domain)"
fi
# The QA build is ad-hoc signed, so a keychain item one QA build wrote makes
# macOS ask on screen when a rebuilt one reads it. The render mode reads none
# it could find, but only an empty QA keychain namespace makes that certain.
# `find-generic-password` without -g/-w reads attributes only: no prompt.
for service in com.clipulse.app.qa com.clipulse.app.quarantine; do
    if /usr/bin/security find-generic-password -s "$service" >/dev/null 2>&1; then
        die "the login keychain holds a '$service' item; a render could raise a keychain prompt on screen. Remove it in Keychain Access first."
    fi
done

# --- QA home root: the same fail-closed steps as the scheme's pre-action. ---
if [[ -L "$QA_ROOT" ]]; then die "refusing symlink QA root: $QA_ROOT"; fi
if [[ -e "$QA_ROOT" && ! -d "$QA_ROOT" ]]; then die "refusing non-directory QA root: $QA_ROOT"; fi
if [[ ! -e "$QA_ROOT" ]]; then /bin/mkdir -m 700 "$QA_ROOT"; fi
qa_owner=$(/usr/bin/stat -f '%u' "$QA_ROOT")
[[ "$qa_owner" == "$(/usr/bin/id -u)" ]] || die "refusing QA root owned by uid $qa_owner"
/bin/chmod 700 "$QA_ROOT"

# --- QA defaults: the app restores them itself; this is the net under a crash. ---
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipulse-qa-render.XXXXXX")
defaults_backup="$work/qa-defaults.plist"
had_defaults=0
if /usr/bin/defaults export "$QA_BUNDLE_ID" "$defaults_backup" >/dev/null 2>&1; then
    had_defaults=1
fi
restore_defaults() {
    if [[ $had_defaults == 1 ]]; then
        /usr/bin/defaults delete "$QA_BUNDLE_ID" >/dev/null 2>&1 || true
        /usr/bin/defaults import "$QA_BUNDLE_ID" "$defaults_backup"
    else
        /usr/bin/defaults delete "$QA_BUNDLE_ID" >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap restore_defaults EXIT

status=0
for lang in "${languages[@]}"; do
    dest="$out/$lang"
    if [[ -e "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
        if [[ $replace == 1 ]]; then
            rm -rf "$dest"
        else
            echo "[$lang] $dest is not empty; pass --replace to overwrite" >&2
            status=2
            continue
        fi
    fi
    home="$QA_ROOT/render-$lang-$$"
    /bin/mkdir -m 700 "$home"
    log="$work/$lang.log"

    echo "[$lang] rendering into $dest"
    CFFIXED_USER_HOME="$home" CLIPULSE_QA_RESET_ON_LAUNCH=0 \
        "$binary" \
        -CLIPulseRenderSnapshots "$dest" \
        -CLIPulseRenderAppearance "$appearance" \
        -AppleLanguages "($lang)" \
        -cli_pulse_locale_override "$lang" \
        >"$log" 2>&1 &
    pid=$!
    waited=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
        if (( waited >= timeout_seconds )); then
            echo "[$lang] timed out after ${timeout_seconds}s; stopping it" >&2
            /bin/kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            /bin/kill -KILL "$pid" 2>/dev/null || true
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    set +e
    wait "$pid"
    code=$?
    set -e
    rm -rf "$home"
    mkdir -p "$dest"
    cp "$log" "$dest/render.log"

    pngs=$(/usr/bin/find "$dest" -name '*.png' | wc -l | tr -d ' ')
    if [[ $code != 0 || ! -f "$dest/manifest.json" ]]; then
        echo "[$lang] FAILED (exit $code, $pngs PNGs); see $dest/render.log" >&2
        status=2
    else
        echo "[$lang] ok: $pngs PNGs, $dest/manifest.json"
    fi
done

for service in com.clipulse.app.qa com.clipulse.app.quarantine; do
    if /usr/bin/security find-generic-password -s "$service" >/dev/null 2>&1; then
        echo "a '$service' keychain item exists after the run; the render mode must not write one" >&2
        status=2
    fi
done

exit $status

#!/usr/bin/env bash
# Capture the iPhone App Store screenshots in every language, without a tap.
#
# Each screen is one launch of a DEBUG build with
#     -CLIPulseScreenshotDemo YES -CLIPulseScreenshotScreen <screen>
# which enters the app's own Demo mode (the Try Demo data), opens that screen
# and cannot reach the network (see ScreenshotLaunch.swift). The language comes
# from -AppleLanguages / -AppleLocale on the same launch, so nothing on the
# simulator's own settings changes per language.
#
# Output: <out>/<lang>/NN_<screen>.png, raw simulator captures. The App Store
# panels are composed from them by compose_appstore_ios_screenshots.py.
#
# Usage:
#   capture_ios_screenshots.sh [--device NAME | --udid UDID] [--app PATH.app] [--out DIR]
#                              [--langs en,ja] [--screens overview,cost]
#                              [--derived-data DIR] [--log-dir DIR]
#                              [--settle SECONDS] [--keep-data] [--force]
#
#   --device     simulator to use, by name (default "iPhone 17 Pro Max", the 6.9"
#                size App Store Connect's APP_IPHONE_67 set takes)
#   --udid       simulator to use, by UDID (overrides --device)
#   --app        a DEBUG simulator build to install; without it the script
#                builds the "CLI Pulse iOS" scheme (Debug) into --derived-data,
#                and deletes that build when it is done unless --derived-data
#                was given (a Debug build of the app is several GB)
#   --keep-data  install over the existing app instead of reinstalling it.
#                The default UNINSTALLS CLI Pulse from that simulator first,
#                which DELETES ITS DATA there (sign-in, settings, caches), so
#                every capture starts from the same, empty preferences.
#   --force      use the simulator even though an app is running on it,
#                CLI Pulse included (another session may be using it). iOS's
#                own com.apple.* jobs (Spotlight, widget rendering) do not
#                count, since an idle booted device always runs some
#
# Refuses a Release build: without DEBUG the capture arguments are ignored and
# every "screenshot" would be the sign-in screen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"          # CLI Pulse Bar/

# The App Store set, in listing order. ScreenshotLaunchTests (Swift) and
# scripts/test_appstore_screenshots.py hold these to the app and to the
# compositor; keep the one-line form.
SCREENS=(overview providers cost sessions alerts)
LANGS=(en zh-Hans zh-Hant ja ko es)

# -AppleLocale per language. Spanish serves es-ES and es-MX with one set of
# images; es_MX formats money and numbers the way Mexico and Latin America do
# ("$1.75", "154.1 k"), which is where most Spanish-language storefronts are.
locale_for() {
  case "$1" in
    en) echo en_US ;;
    zh-Hans) echo zh_CN ;;
    zh-Hant) echo zh_TW ;;
    ja) echo ja_JP ;;
    ko) echo ko_KR ;;
    es) echo es_MX ;;
    *) return 1 ;;
  esac
}

DEVICE="iPhone 17 Pro Max"
UDID=""
APP=""
OUT="$APP_ROOT/screenshots/ios-raw"
DERIVED=""
LOG_DIR=""
SETTLE=1.5
READY_TIMEOUT=60
BOOT_TIMEOUT=300      # simctl boot + bootstatus on a cold device
STEP_TIMEOUT=120      # install, launch, a screenshot
KEEP_DATA=0
FORCE=0
log_dir_here=""      # set when this script made LOG_DIR (removed after a clean run)
want_langs=""
want_screens=""

die() { echo "capture_ios_screenshots: $*" >&2; exit 1; }

# with_timeout SECONDS CMD...: run CMD, killing it after SECONDS. simctl can
# hang on a wedged device (measured: a launch, then `status_bar clear` and `ui
# appearance` each stuck for minutes on a simulator booted with 4 GB of disk
# free); without a bound the script, and its cleanup, would wait forever.
# (No coreutils timeout on a stock Mac, hence this.)
with_timeout() {
  local secs="$1" rc=0 pid watchdog
  shift
  "$@" &
  pid=$!
  ( sleep "$secs" && kill -TERM "$pid" ) 2>/dev/null &
  watchdog=$!
  wait "$pid" || rc=$?
  pkill -P "$watchdog" sleep 2>/dev/null || true   # its sleep, so none lingers
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --langs) want_langs="$2"; shift 2 ;;
    --screens) want_screens="$2"; shift 2 ;;
    --derived-data) DERIVED="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --keep-data) KEEP_DATA=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ── what to capture ─────────────────────────────────────────────────────────
index_of_screen() {
  local i=0 known
  for known in "${SCREENS[@]}"; do
    i=$((i + 1))
    if [ "$known" = "$1" ]; then printf '%02d' "$i"; return 0; fi
  done
  return 1
}

langs=("${LANGS[@]}")
if [ -n "$want_langs" ]; then
  IFS=',' read -r -a langs <<< "$want_langs"
  for want in "${langs[@]}"; do locale_for "$want" >/dev/null || die "unknown language '$want' (known: ${LANGS[*]})"; done
fi
screens=("${SCREENS[@]}")
if [ -n "$want_screens" ]; then
  IFS=',' read -r -a screens <<< "$want_screens"
  for want in "${screens[@]}"; do index_of_screen "$want" >/dev/null || die "unknown screen '$want' (known: ${SCREENS[*]})"; done
fi

# ── launch logs ─────────────────────────────────────────────────────────────
# The app's stdout (where the READY line arrives) goes to the file named by
# `simctl launch --stdout`. Measured with the same app and launch: a file under
# /var/folders/…/T ($TMPDIR) or /private/tmp stayed empty, so every capture
# would time out waiting, while a file under the home directory got READY in
# 4 s, and so did this script's default, ~/Library/Logs/clipulse-capture.*.
# (The likely reason is that a simulated process sees the device's own temp
# directories, but only the measurement is established.) So the default is
# under ~/Library/Logs (made below, once the cleanup is in place), and a
# --log-dir under a temp path is refused before anything boots.
case "$LOG_DIR" in
  /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*)
    die "--log-dir $LOG_DIR is under a temp directory; the app's READY line never arrives in a log there (measured), so every capture would time out. Use a path under your home directory." ;;
esac

# ── the simulator ───────────────────────────────────────────────────────────
# An existing device, never a new one: every simulator that gets used collects
# gigabytes of data. The first available device with this exact name.
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl list devices available \
    | awk -v name="$DEVICE" '{ line = $0; sub(/^ +/, "", line)
        if (index(line, name " (") == 1) { match(line, /\([0-9A-F-]{36}\)/)
          if (RSTART) { print substr(line, RSTART + 1, 36); exit } } }')"
  [ -n "$UDID" ] || die "no available simulator named '$DEVICE' (xcrun simctl list devices available)"
fi

# ── the app (checked before anything boots) ─────────────────────────────────────────────────────────────────
built_here=""
if [ -z "$APP" ]; then
  if [ -z "$DERIVED" ]; then
    DERIVED="${TMPDIR:-/tmp}/clipulse-ios-screenshots-build"
    built_here="$DERIVED"
  fi
  echo "building CLI Pulse iOS (Debug) into $DERIVED"
  (cd "$APP_ROOT" && xcodebuild build \
      -project "CLI Pulse Bar.xcodeproj" -scheme "CLI Pulse iOS" -configuration Debug \
      -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" -quiet)
  APP="$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name '*.app' -print -quit)"
fi
[ -d "$APP" ] || die "no .app at '$APP'"
if ! grep -rqaF -- "-CLIPulseScreenshotDemo" "$APP"; then
  die "$APP does not contain the capture arguments: it is not a DEBUG build, and every capture would be the sign-in screen"
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
echo "app: $APP ($BUNDLE_ID)"

# ── boot (or share) the simulator ───────────────────────────────────────────
device_line="$(xcrun simctl list devices | grep -F "($UDID)" || true)"
[ -n "$device_line" ] || die "no simulator with UDID $UDID (xcrun simctl list devices available)"
echo "device: $(echo "$device_line" | sed 's/^ *//')"

# Registered before the boot, so a failure anywhere after it still puts the
# status bar and appearance back, and shuts down a device this script booted.
booted_here=0
prev_appearance=unknown
status_bar_set=0
prev_status_bar=""
cleanup() {
  local rc=$?
  if [ "$status_bar_set" -eq 1 ]; then
    if [ -n "$prev_status_bar" ]; then
      # Someone had overridden it before this run; clearing would undo theirs
      # too, and theirs cannot be read back exactly. Say so instead.
      echo "note: the status bar had an override before this run; left as this run set it" >&2
    else
      with_timeout 30 xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
    fi
  fi
  if [ "$prev_appearance" = "dark" ] || [ "$prev_appearance" = "light" ]; then
    with_timeout 30 xcrun simctl ui "$UDID" appearance "$prev_appearance" >/dev/null 2>&1 || true
  fi
  if [ "$booted_here" -eq 1 ]; then
    echo "shutting down $UDID (booted by this script)"
    with_timeout "$STEP_TIMEOUT" xcrun simctl shutdown "$UDID" >/dev/null 2>&1 \
      || echo "shutdown of $UDID failed or timed out; shut it down by hand" >&2
  fi
  if [ -n "$built_here" ] && [ -d "$built_here" ]; then
    echo "deleting the build this script made ($(du -sh "$built_here" 2>/dev/null | cut -f1)): $built_here"
    rm -rf "$built_here"
  fi
  if [ -n "$log_dir_here" ] && [ "$rc" -eq 0 ]; then
    rm -rf "$log_dir_here"
  elif [ -n "$LOG_DIR" ] && [ "$rc" -ne 0 ]; then
    echo "launch logs kept: $LOG_DIR" >&2
  fi
}
trap cleanup EXIT

if echo "$device_line" | grep -q "(Booted)"; then
  # Another session may be driving this device: its apps show up as
  # UIKitApplication jobs. CLI Pulse counts too. This script never has an
  # instance of its own running at this point (it terminates the app before
  # every launch), so a running CLI Pulse is someone else's, and the default
  # reinstall below would kill it and delete its data.
  # iOS itself always runs a few UIKitApplication jobs on an idle booted
  # device (com.apple.Spotlight and com.apple.chrono.WidgetRenderer-Default,
  # read on two idle simulators), so com.apple.* jobs are left out; counting
  # them made every booted device look busy and --force the routine answer.
  others="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null \
    | grep -o 'UIKitApplication:[^[]*' | grep -v '^UIKitApplication:com\.apple\.' || true)"
  if [ -n "$others" ] && [ "$FORCE" -ne 1 ]; then
    echo "$others" | sed 's/^/  running: /' >&2
    die "the simulator is running apps; another session may be using it. Pick another --device or --udid, or --force."
  fi
else
  echo "booting $UDID (headless; no Simulator window)"
  booted_here=1
  with_timeout "$BOOT_TIMEOUT" xcrun simctl boot "$UDID" \
    || die "simctl boot $UDID failed or took over ${BOOT_TIMEOUT}s"
fi
with_timeout "$BOOT_TIMEOUT" xcrun simctl bootstatus "$UDID" -b >/dev/null \
  || die "$UDID did not finish booting within ${BOOT_TIMEOUT}s"
prev_appearance="$(xcrun simctl ui "$UDID" appearance 2>/dev/null || echo unknown)"
prev_status_bar="$(xcrun simctl status_bar "$UDID" list 2>/dev/null | sed '1,2d' | grep -v '^[[:space:]]*$' || true)"

if [ "$KEEP_DATA" -eq 0 ]; then
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
with_timeout "$STEP_TIMEOUT" xcrun simctl install "$UDID" "$APP" || die "installing $APP failed"

with_timeout "$STEP_TIMEOUT" xcrun simctl ui "$UDID" appearance light || die "setting light appearance failed"
# A full battery, not charging: 'charged' draws the charging bolt on iOS 26.
status_bar_set=1
with_timeout "$STEP_TIMEOUT" xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi \
  --wifiBars 3 --cellularBars 4 --batteryState discharging --batteryLevel 100 \
  || die "overriding the status bar failed"

if [ -z "$LOG_DIR" ]; then
  mkdir -p "$HOME/Library/Logs"
  LOG_DIR="$(mktemp -d "$HOME/Library/Logs/clipulse-capture.XXXXXX")"
  log_dir_here="$LOG_DIR"
fi
mkdir -p "$LOG_DIR" "$OUT"
echo "launch logs: $LOG_DIR"

# ── capture ─────────────────────────────────────────────────────────────────
capture_one() {
  local lang="$1" screen="$2" nn log dest waited=0
  nn="$(index_of_screen "$screen")"
  log="$LOG_DIR/${lang}_${nn}_${screen}.log"
  dest="$OUT/$lang/${nn}_${screen}.png"
  mkdir -p "$OUT/$lang"
  : > "$log"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  with_timeout "$STEP_TIMEOUT" xcrun simctl launch --stdout="$log" --stderr="$log" "$UDID" "$BUNDLE_ID" \
    -AppleLanguages "($lang)" -AppleLocale "$(locale_for "$lang")" \
    -CLIPulseScreenshotDemo YES -CLIPulseScreenshotScreen "$screen" >/dev/null \
    || die "$lang/$screen: simctl launch failed (log: $log)"
  until grep -q "CLIPULSE_SCREENSHOT_READY $screen" "$log" 2>/dev/null; do
    if grep -q "CLIPULSE_SCREENSHOT_ERROR" "$log" 2>/dev/null; then
      die "$lang/$screen: $(grep "CLIPULSE_SCREENSHOT_ERROR" "$log" | head -1)"
    fi
    if [ "$waited" -ge "$((READY_TIMEOUT * 4))" ]; then
      die "$lang/$screen: the app never reported ready within ${READY_TIMEOUT}s (log: $log)"
    fi
    sleep 0.25; waited=$((waited + 1))
  done
  sleep "$SETTLE"
  rm -f "$dest"
  # --mask=black: the Dynamic Island is part of the display mask, so it is in
  # every capture. With the default (ignored) mask it appears only when
  # SpringBoard happens to be drawing it: 1 of 30 captures in the first trial.
  # The compositor rounds the phone's corners enough to clip the black ones.
  if ! with_timeout "$STEP_TIMEOUT" xcrun simctl io "$UDID" screenshot --type=png --mask=black "$dest" \
      >>"$log" 2>&1; then
    die "$lang/$screen: simctl io screenshot failed: $(tail -1 "$log")"
  fi
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  [ -s "$dest" ] || die "$lang/$screen: no screenshot written"
  local size
  size="$(sips -g pixelWidth -g pixelHeight "$dest" | awk '/pixel/{printf "%s%s", sep, $2; sep="x"}')"
  echo "  $lang/${nn}_${screen}.png  $size"
}

for lang in "${langs[@]}"; do
  echo "[$lang] -AppleLanguages ($lang) -AppleLocale $(locale_for "$lang")"
  for screen in "${screens[@]}"; do
    capture_one "$lang" "$screen"
  done
done

echo "done: $OUT"

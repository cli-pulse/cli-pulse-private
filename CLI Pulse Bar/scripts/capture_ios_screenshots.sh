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
#                builds the "CLI Pulse iOS" scheme (Debug) into --derived-data
#   --keep-data  install over the existing app instead of reinstalling it.
#                The default reinstall gives every capture the same, empty
#                preferences (display currency, appearance, language override).
#   --force      use the simulator even though another app is running on it
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
KEEP_DATA=0
FORCE=0
want_langs=""
want_screens=""

die() { echo "capture_ios_screenshots: $*" >&2; exit 1; }

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
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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
if [ -z "$APP" ]; then
  DERIVED="${DERIVED:-${TMPDIR:-/tmp}/clipulse-ios-screenshots-build}"
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
cleanup() {
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
  if [ "$prev_appearance" = "dark" ] || [ "$prev_appearance" = "light" ]; then
    xcrun simctl ui "$UDID" appearance "$prev_appearance" >/dev/null 2>&1 || true
  fi
  if [ "$booted_here" -eq 1 ]; then
    echo "shutting down $UDID (booted by this script)"
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if echo "$device_line" | grep -q "(Booted)"; then
  # Another session may be driving this device. Its apps show up as
  # UIKitApplication jobs; ours is replaced below, anything else is theirs.
  others="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null \
    | grep -o 'UIKitApplication:[^[]*' | grep -v 'yyh.CLI-Pulse' || true)"
  if [ -n "$others" ] && [ "$FORCE" -ne 1 ]; then
    echo "$others" | sed 's/^/  running: /' >&2
    die "the simulator is running other apps; another session may be using it. Pick another --device or --udid, or --force."
  fi
else
  echo "booting $UDID (headless; no Simulator window)"
  booted_here=1
  xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null
prev_appearance="$(xcrun simctl ui "$UDID" appearance 2>/dev/null || echo unknown)"

if [ "$KEEP_DATA" -eq 0 ]; then
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
xcrun simctl install "$UDID" "$APP"

xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiBars 3 \
  --cellularBars 4 --batteryState charged --batteryLevel 100

[ -n "$LOG_DIR" ] || LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipulse-capture.XXXXXX")"
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
  xcrun simctl launch --stdout="$log" --stderr="$log" "$UDID" "$BUNDLE_ID" \
    -AppleLanguages "($lang)" -AppleLocale "$(locale_for "$lang")" \
    -CLIPulseScreenshotDemo YES -CLIPulseScreenshotScreen "$screen" >/dev/null
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
  xcrun simctl io "$UDID" screenshot --type=png --mask=black "$dest" >/dev/null 2>&1
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

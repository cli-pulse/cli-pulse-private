#!/bin/bash
# The apps and CLIPulseCore's own tests must resolve the same sentry-cocoa.
#
# WHY THIS EXISTS
# The apps build against the Xcode workspace's Package.resolved; CI's
# `swift test` of CLIPulseCore resolves CLIPulseCore/Package.resolved. In 1.62
# the first said 9.12.1 and the second 9.11.0, so the tests that pin what the
# crash-report scrubber removes (`SentryLogger`, keys the SDK writes such as
# `device_app_hash` and breadcrumb `title`) ran against an SDK the apps did not
# ship. A rename in the shipped SDK would have passed CI.
#
# The two files are different Package.resolved formats (v3 with originHash, v2
# without), so the sentry-cocoa pin's version and revision are compared, not
# the files.
#
# usage: check_sentry_pins.sh [--root DIR]   (DIR defaults to this repo)
# exit:  0 the pins match, 1 they differ or cannot be read, 2 bad usage.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            [ $# -ge 2 ] || { echo "usage: $0 [--root DIR]" >&2; exit 2; }
            ROOT="$2"; shift 2 ;;
        *) echo "usage: $0 [--root DIR]" >&2; exit 2 ;;
    esac
done

APPS="$ROOT/CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
CORE="$ROOT/CLI Pulse Bar/CLIPulseCore/Package.resolved"

python3 - "$APPS" "$CORE" <<'PY'
import json, sys

def pin(path):
    try:
        with open(path) as f:
            root = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit(f"::error::check_sentry_pins: cannot read {path}: {e}")
    pins = root.get("pins") if isinstance(root, dict) else None
    if not isinstance(pins, list):
        sys.exit(f"::error::check_sentry_pins: {path} has no pins list")
    found = [p for p in pins if isinstance(p, dict) and p.get("identity") == "sentry-cocoa"]
    if len(found) != 1:
        sys.exit(f"::error::check_sentry_pins: {path} has {len(found)} sentry-cocoa pins, expected 1")
    state = found[0].get("state")
    state = state if isinstance(state, dict) else {}
    version, revision = state.get("version"), state.get("revision")
    if not (isinstance(version, str) and version and isinstance(revision, str) and revision):
        sys.exit(f"::error::check_sentry_pins: {path}: sentry-cocoa pin lacks a version or a revision")
    return version, revision

apps, core = pin(sys.argv[1]), pin(sys.argv[2])
if apps != core:
    sys.exit("::error::check_sentry_pins: the apps resolve sentry-cocoa %s (%s) but CLIPulseCore's tests "
             "resolve %s (%s); update CLI Pulse Bar/CLIPulseCore/Package.resolved to the apps' pin"
             % (apps[0], apps[1][:12], core[0], core[1][:12]))
print("check_sentry_pins: sentry-cocoa %s (%s) in both" % (apps[0], apps[1][:12]))
PY

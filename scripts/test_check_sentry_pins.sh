#!/bin/bash
# Positive and negative controls for check_sentry_pins.sh.
#
# The guard exists because 1.62's apps resolved sentry-cocoa 9.12.1 while
# CLIPulseCore's tests resolved 9.11.0. That exact case is planted below, with
# the near-misses a loose comparison would let through (same version, other
# revision; the pin missing; two pins). The fixtures are synthetic. Only the
# first case reads the real repository. Every negative case must exit with
# exactly 1 (a crash or a usage error is not a rejection).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check_sentry_pins.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APPS_REL="CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
CORE_REL="CLI Pulse Bar/CLIPulseCore/Package.resolved"
REV_A="54d5fbcdea46c37a5de01bab5fef48dc78baec84"
REV_B="a49e7c2148ac9e38bd35ef4f13bc9d6ea3ff0b81"

pass=0
fail=0

# write_v3 FILE VERSION REVISION   (the Xcode workspace's format)
write_v3() {
    mkdir -p "$(dirname "$1")"
    cat >"$1" <<JSON
{
  "originHash" : "0000",
  "pins" : [
    { "identity" : "sentry-cocoa", "kind" : "remoteSourceControl",
      "location" : "https://github.com/getsentry/sentry-cocoa",
      "state" : { "revision" : "$3", "version" : "$2" } },
    { "identity" : "sweetcookiekit", "kind" : "remoteSourceControl",
      "location" : "https://example.invalid/sweetcookiekit",
      "state" : { "revision" : "1111", "version" : "1.0.0" } }
  ],
  "version" : 3
}
JSON
}

# write_v2 FILE VERSION REVISION   (CLIPulseCore's format)
write_v2() {
    mkdir -p "$(dirname "$1")"
    cat >"$1" <<JSON
{
  "pins" : [
    { "identity" : "sentry-cocoa", "kind" : "remoteSourceControl",
      "location" : "https://github.com/getsentry/sentry-cocoa",
      "state" : { "revision" : "$3", "version" : "$2" } }
  ],
  "version" : 2
}
JSON
}

expect() {   # expect NAME WANT_EXIT [MESSAGE_FRAGMENT]
    local name="$1" want="$2" frag="${3:-}" out code
    out="$(bash "$GUARD" --root "$TMP/case" 2>&1)"; code=$?
    if [ "$code" = "$want" ] && { [ -z "$frag" ] || grep -qF -- "$frag" <<<"$out"; }; then
        echo "ok   $name"; pass=$((pass + 1))
    else
        echo "FAIL $name (exit $code, wanted $want${frag:+, message containing \"$frag\"})"; echo "$out" | sed 's/^/     /'
        fail=$((fail + 1))
    fi
}

fresh() { rm -rf "$TMP/case"; mkdir -p "$TMP/case"; }

# 0. The real repository passes.
if bash "$GUARD" >/dev/null 2>&1; then echo "ok   the repository's pins match"; pass=$((pass + 1));
else echo "FAIL the repository's pins differ"; bash "$GUARD"; fail=$((fail + 1)); fi

fresh; write_v3 "$TMP/case/$APPS_REL" 9.12.1 "$REV_A"; write_v2 "$TMP/case/$CORE_REL" 9.12.1 "$REV_A"
expect "same version and revision in both formats" 0

fresh; write_v3 "$TMP/case/$APPS_REL" 9.12.1 "$REV_A"; write_v2 "$TMP/case/$CORE_REL" 9.11.0 "$REV_B"
expect "1.62's case: apps 9.12.1, tests 9.11.0" 1 "9.11.0"

fresh; write_v3 "$TMP/case/$APPS_REL" 9.12.1 "$REV_A"; write_v2 "$TMP/case/$CORE_REL" 9.12.1 "$REV_B"
expect "same version, other revision" 1 "a49e7c2148ac"

fresh; write_v3 "$TMP/case/$APPS_REL" 9.12.1 "$REV_A"
mkdir -p "$(dirname "$TMP/case/$CORE_REL")"; printf '{ "pins" : [], "version" : 2 }\n' >"$TMP/case/$CORE_REL"
expect "no sentry-cocoa pin in CLIPulseCore" 1 "0 sentry-cocoa pins"

fresh; write_v2 "$TMP/case/$CORE_REL" 9.12.1 "$REV_A"
expect "the apps' file is missing" 1 "cannot read"

fresh; write_v3 "$TMP/case/$APPS_REL" 9.12.1 "$REV_A"; write_v2 "$TMP/case/$CORE_REL" 9.12.1 "$REV_A"
python3 - "$TMP/case/$CORE_REL" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["pins"].append(dict(d["pins"][0])); json.dump(d, open(p, "w"))
PY
expect "two sentry-cocoa pins" 1 "2 sentry-cocoa pins"

fresh; write_v3 "$TMP/case/$APPS_REL" 9.12.1 ""; write_v2 "$TMP/case/$CORE_REL" 9.12.1 ""
expect "a pin without a revision" 1 "lacks a version or a revision"

echo "check_sentry_pins controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

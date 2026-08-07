#!/bin/bash
# Fail the build if any UI surface offers the anonymous-telemetry switch without
# also disclosing that local-only mode may already be forcing it off.
#
# WHY THIS EXISTS
# ---------------
# `privacy.localOnlyMode` overrides the telemetry switch inside
# `UserDefaultsAnonymousTelemetryStore.isEnabled`. That is deliberate — the
# master switch promises to skip all cross-app data sources, and making someone
# find a second switch would make the first one a lie.
#
# The consequence is that the switch's own value is NOT what the app does. Any
# surface that renders it must consult `telemetrySuppressedByLocalOnly`, or it
# will show ON while nothing is being sent.
#
# v1.45 shipped exactly that. `PrivacySettingsSection` got it right and disabled
# the control with "Off — local-only mode covers this too."; the first-launch
# disclosure card did not, and told local-only users in the present tense that
# CLI Pulse "reports two things" above a switch reading ON that did nothing. Two
# surfaces in the same app disagreed about whether data was leaving the machine,
# and the one that was wrong was the one making the legal disclosure.
#
# Unit tests cannot catch this: both surfaces are SwiftUI views in the app
# target, which has no test bundle. `AnonymousTelemetryDisclosureGateTests
# .test_aShutGateAlwaysHasAUserVisibleReason` pins that the flag is CORRECT;
# only this guard pins that every surface USES it.
#
# The cost of a false negative is an untrue privacy disclosure. The cost of a
# false positive is thirty seconds adding an exemption below. Bias toward
# failing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The flag every rendering surface must consult.
REQUIRED='telemetrySuppressedByLocalOnly'

# Binding the switch two-way is what makes a file a "surface". A file that only
# reads the value for non-UI purposes is matched too, which is the safe
# direction — add an exemption if that ever produces a false positive.
BINDING='\$[a-zA-Z_][a-zA-Z0-9_]*\.anonymousTelemetryEnabled'

failed=0
while IFS= read -r file; do
    [ -z "$file" ] && continue
    if ! grep -q "$REQUIRED" "$file"; then
        rel="${file#"$ROOT"/}"
        echo "ERROR: $rel binds the anonymous-telemetry switch but never mentions"
        echo "       $REQUIRED, so it will show the switch as ON while local-only"
        echo "       mode is silently forcing telemetry OFF."
        echo "       Disable the control and say so, as PrivacySettingsSection does."
        failed=1
    fi
done < <(grep -rlE "$BINDING" --include="*.swift" "$ROOT" 2>/dev/null \
         | grep -v "/build/" | grep -v "/.build/")

if [ "$failed" -ne 0 ]; then
    echo
    echo "See scripts/check_telemetry_switch_discloses_suppression.sh for why."
    exit 1
fi

# A guard that matches nothing is not a guard. If the binding pattern stops
# matching — a refactor renames the property, or the surfaces move — this script
# would pass forever while checking nothing.
count=$(grep -rlE "$BINDING" --include="*.swift" "$ROOT" 2>/dev/null \
        | grep -v "/build/" | grep -vc "/.build/")
if [ "$count" -lt 2 ]; then
    echo "ERROR: expected at least 2 telemetry-switch surfaces, found $count."
    echo "       Either a surface was removed, or the pattern in this guard has"
    echo "       stopped matching and the guard is now vacuous. Fix the pattern."
    exit 1
fi

echo "✓ all $count telemetry-switch surfaces disclose local-only suppression"

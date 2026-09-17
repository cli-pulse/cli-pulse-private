#!/bin/bash
# Negative controls for check_alert_templates.py.
#
# Each case builds a small tree — a Python producer, the AlertPresentation
# matchers and the XCTest fixtures, written the way the real files are — plants
# ONE defect, and requires the guard to fail on the message only that defect
# produces. The positive control comes first: a guard that rejects every tree
# looks identical to one that works.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check_alert_templates.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

CORE="CLI Pulse Bar/CLIPulseCore"
PY="$TMP/case/helper/system_collector.py"
SWIFT="$TMP/case/$CORE/Sources/CLIPulseCore/AlertPresentation.swift"
TESTS="$TMP/case/$CORE/Tests/CLIPulseCoreTests/AlertPresentationTests.swift"

build() {
    rm -rf "$TMP/case"
    mkdir -p "$(dirname "$PY")" "$(dirname "$SWIFT")" "$(dirname "$TESTS")"
    cat > "$PY" <<'PYTHON'
from dataclasses import dataclass

@dataclass
class CollectedAlert:
    alert_id: str
    type: str
    severity: str
    title: str
    message: str
    created_at: str

def collect_alerts(device_snapshot, sessions, device_key, now):
    alerts = []
    if device_snapshot.cpu_usage >= 85:
        alerts.append(CollectedAlert(
            alert_id=f"cpu-spike-{device_key}",
            type="Usage Spike",
            severity="Warning",
            title="Device CPU usage is elevated",
            message=f"helper sampled CPU usage at {device_snapshot.cpu_usage}%.",
            created_at=now,
        ))
    for session in sessions:
        # CollectedAlert(alert_id="commented-out", ...) in a comment is not a call.
        alerts.append(
            CollectedAlert(
                alert_id=f"session-spike-{session.sid}",
                type="Usage Spike",
                severity="Warning",
                title=f"{session.name} is consuming high CPU",
                message=f"Process CPU is {session.cpu_usage:.1f}% for {session.provider}.",
                created_at=now,
            )
        )
        alerts.append(CollectedAlert(
            alert_id=f"session-long-{session.sid}",
            type="Session Too Long",
            severity="Info",
            title=f"{session.name} has been running for a long time",
            message="Long-running local agent session detected by helper.",
            created_at=now,
        ))
    return alerts
PYTHON
    cat > "$SWIFT" <<'SWIFT'
public enum AlertPresentation {
    private static func deviceCPU(_ a: AlertRecord) -> Text? {
        guard a.type == "Usage Spike", a.id.hasPrefix("cpu-spike-"),
              a.title == "Device CPU usage is elevated",
              let pct = capture(a.message, #"^helper sampled CPU usage at (\d+(?:\.\d+)?)%\.$"#)?.first
        else { return nil }
        return Text(title: "x", message: pct, recognized: true)
    }

    private static func sessionCPU(_ a: AlertRecord) -> Text? {
        guard a.type == "Usage Spike", a.id.hasPrefix("session-spike-") else { return nil }
        let name = stripSuffix(a.title, " is consuming high CPU")
        // if let m = capture(a.message, #"^(.*)$"#) {
        if let m = capture(a.message, #"^Process CPU is (\d+(?:\.\d+)?)% for (.+)\.$"#) {
            return Text(title: name, message: m[0], recognized: true)
        }
        return nil
    }

    private static func sessionLong(_ a: AlertRecord) -> Text? {
        guard a.type == "Session Too Long", a.id.hasPrefix("session-long-"),
              a.message == "Long-running local agent session detected by helper."
        else { return nil }
        return Text(title: stripSuffix(a.title, " has been running for a long time"), message: "", recognized: true)
    }

    private static func quota(_ a: AlertRecord) -> Text? {
        guard a.type == "Quota Warning", a.id.hasPrefix("quota-") else { return nil }
        return Text(title: stripSuffix(a.title, " \(a.id) at 5%"), message: "", recognized: true)
    }
}
SWIFT
    cat > "$TESTS" <<'SWIFT'
final class AlertPresentationTests: XCTestCase {
    func testPythonHelperTemplatesAreRecognized() {
        let cases = [
            record(id: "cpu-spike-mac-1", type: "Usage Spike",
                   title: "Device CPU usage is elevated",
                   message: "helper sampled CPU usage at 91%."),
            record(id: "session-spike-s1", type: "Usage Spike",
                   title: "api-gateway is consuming high CPU",
                   message: "Process CPU is 184.5% for Claude."),
            record(id: "session-long-s1", type: "Session Too Long",
                   title: "api-gateway has been running for a long time",
                   message: "Long-running local agent session detected by helper."),
        ]
        for c in cases { XCTAssertTrue(AlertPresentation.text(for: c).recognized) }
    }

    func testDesktopTemplatesAreRecognized() {
        let cases = [
            record(id: "session-spike-s1", type: "Usage Spike",
                   title: "api-gateway is consuming high CPU",
                   message: "Process CPU is 184.5% for Claude in acme."),
        ]
        _ = cases
    }
}
SWIFT
}

edit() {  # edit <file> <old> <new>  — a no-op plant fails the case instead of passing it
    python3 - "$@" <<'PYEDIT'
import sys
path, old, new = sys.argv[1:4]
s = open(path, encoding="utf-8").read()
if old not in s:
    sys.exit(f"plant did not land: {old!r} not in {path}")
open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYEDIT
}

expect_fail() {  # expect_fail <name> <needle>
    local name="$1" needle="$2" out rc
    out="$(python3 "$GUARD" --root "$TMP/case" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: [$name] guard PASSED a tree it should have rejected."
        fail=$((fail + 1)); return
    fi
    if ! printf '%s' "$out" | grep -qF -- "$needle"; then
        echo "FAIL: [$name] guard failed (rc=$rc), but not for the expected reason."
        echo "      wanted substring: $needle"
        printf '%s\n' "$out" | sed 's/^/      /'
        fail=$((fail + 1)); return
    fi
    echo "ok:   [$name] guard rejected it, for the right reason."
    pass=$((pass + 1))
}

expect_ok() {  # expect_ok <name>
    local name="$1" out rc
    out="$(python3 "$GUARD" --root "$TMP/case" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: [$name] guard REJECTED a tree it should have accepted."
        printf '%s\n' "$out" | sed 's/^/      /'
        fail=$((fail + 1)); return
    fi
    echo "ok:   [$name] guard accepted it."
    pass=$((pass + 1))
}

plant() {  # plant <name> <needle> <file> <old> <new>
    build
    if edit "$3" "$4" "$5"; then
        expect_fail "$1" "$2"
    else
        echo "FAIL: [$1] the mutation did not land, so the case proves nothing."
        fail=$((fail + 1))
    fi
}

# ── positive control ────────────────────────────────────────────────────────
build
expect_ok "three templates, each recognised by a matcher and pinned by a fixture"

# ── the producer is reworded: the stored English no longer matches ──────────
plant "session CPU message reworded (the audit's case)" \
    "'Process CPU at 91.2% for api gateway.' is recognised by no AlertPresentation matcher" \
    "$PY" 'f"Process CPU is {session.cpu_usage:.1f}%' 'f"Process CPU at {session.cpu_usage:.1f}%'

plant "session-too-long message reworded" \
    "'Long-running agent session detected by helper.' is recognised by no AlertPresentation matcher" \
    "$PY" '"Long-running local agent session' '"Long-running agent session'

plant "session-too-long title reworded — recognised, but the name would be mistranslated" \
    "ends with none of [' has been running for a long time']" \
    "$PY" '{session.name} has been running for a long time' '{session.name} has run for a long time'

plant "device CPU title reworded" \
    "title 'Device CPU is elevated' is not ['Device CPU usage is elevated']" \
    "$PY" 'title="Device CPU usage is elevated"' 'title="Device CPU is elevated"'

plant "alert id prefix changed" \
    "starts with none of ['session-spike-']" \
    "$PY" 'alert_id=f"session-spike-' 'alert_id=f"spike-'

plant "alert type renamed" \
    "'CPU Spike' / 'Device CPU usage is elevated'" \
    "$PY" 'type="Usage Spike",
            severity="Warning",
            title="Device' 'type="CPU Spike",
            severity="Warning",
            title="Device'

# ── the matcher changes on the Swift side ──────────────────────────────────
plant "matcher regex changed in AlertPresentation.swift" \
    "'Process CPU is 91.2% for api gateway.' is recognised by no AlertPresentation matcher" \
    "$SWIFT" '#"^Process CPU is (' '#"^Process CPU was ('

# A commented-out matcher must not count: with the real one removed, the
# comment's accept-anything regex would otherwise recognise every message.
plant "only a commented-out matcher remains" \
    "is recognised by no AlertPresentation matcher" \
    "$SWIFT" 'if let m = capture(a.message, #"^Process CPU is' 'if let m = capture(a.message, #"^Process load is'

# ── the fixture the XCTest runs through the real matcher ───────────────────
plant "fixture drifted from the producer's template" \
    "has no fixture in testPythonHelperTemplatesAreRecognized()" \
    "$TESTS" 'message: "Process CPU is 184.5% for Claude."),' 'message: "Process CPU was 184.5% for Claude."),'

plant "fixture that no producer writes any more" \
    "fixture 'Process CPU was 184.5% for Claude.' matches no template" \
    "$TESTS" 'message: "Process CPU is 184.5% for Claude."),' 'message: "Process CPU was 184.5% for Claude."),'

plant "fixture test renamed away" \
    "testPythonHelperTemplatesAreRecognized() is gone" \
    "$TESTS" 'func testPythonHelperTemplatesAreRecognized()' 'func testPythonTemplates()'

# A desktop fixture with the same shape is in a different test and is not a pin.
plant "a fixture only in the DESKTOP test does not pin the Python template" \
    "has no fixture in testPythonHelperTemplatesAreRecognized()" \
    "$TESTS" 'record(id: "session-spike-s1", type: "Usage Spike",
                   title: "api-gateway is consuming high CPU",
                   message: "Process CPU is 184.5% for Claude."),' ''

# ── the reader itself must not go blind ─────────────────────────────────────
plant "an alert field built from something other than a literal" \
    "CollectedAlert message= is not a string literal or f-string" \
    "$PY" 'message="Long-running local agent session detected by helper.",' 'message=LONG_RUNNING_MESSAGE,'

build
printf 'def nothing():\n    return []\n' > "$PY"
expect_fail "a producer with no templates is not a pass" "no CollectedAlert templates found"

build
printf 'public enum AlertPresentation {}\n' > "$SWIFT"
expect_fail "a presentation file with no matchers is not a pass" "no \`static func …(_ a: AlertRecord) -> Text?\` matchers found"

echo
echo "check_alert_templates negative controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

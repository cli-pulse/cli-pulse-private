#!/usr/bin/env bash
# Fail when the Swift helper's advertised method set drifts from the Python
# helper's, other than by a deliberate, listed exception.
#
# Protocol.swift has said this since the Swift port landed:
#
#     /// Methods this revision of the helper advertises in `hello`. Must
#     /// match `helper/local_session_server.py:SUPPORTED_METHODS`
#     /// element-for-element so the macOS app's capability negotiation
#     /// produces the same result.
#
# Nothing checked it. check_helper_version_sync.sh compares only the two
# version STRINGS, so a Swift helper reporting the same helper_version as the
# Python one while implementing six fewer methods was indistinguishable from a
# correct build — to CI, and to the app's capability negotiation.
#
# That is how it reached users: the app-bundled Swift helper (the default
# install) answered `get_machine_snapshot` with `unknown_method`, and the
# Machine tab was blank for everyone who never installed the .pkg. The tab
# offered advice about the helper "not running" while `hello` on the same
# socket was succeeding. v1.44 ports get_machine_snapshot; the rest stay
# listed below so their absence is a decision on the record rather than a
# silent gap.
#
# Usage: scripts/check_helper_method_parity.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/helper/local_session_server.py"
SWIFT="$ROOT/HelperSwift/Sources/HelperKit/Protocol.swift"

for f in "$PY" "$SWIFT"; do
    [[ -f "$f" ]] || { echo "ERROR: $f not found" >&2; exit 2; }
done

# Methods the Swift helper deliberately does not implement.
#
# All three of the machine-control relay verbs plus the two process actions.
# They are process CONTROL, not health: implementing them means porting the
# same-UID guard matrix in helper/machine_actions.py, which is its own body of
# work. Until then the Swift helper omits `kill_process`/`suspend_process` from
# the machine snapshot's capability map, so the app hides those affordances
# instead of showing buttons that fail — MachineControlGate documents the
# capability key as precisely that mechanism.
#
# To implement one: port it, add the case to SupportedMethod, and DELETE the
# line here. Never add a line to silence a diff you did not intend.
KNOWN_ABSENT=(
    kill_process
    signal_process
    pull_machine_commands
    complete_machine_command
    report_machine_control_state
)

# Python: the SUPPORTED_METHODS tuple literal, up to its closing paren.
# `|| true`: without it, `set -e` + `pipefail` kills the script the instant the
# extraction yields nothing, so the "parser broke" guard below — the one that
# distinguishes "the enum changed shape" from "real drift" — could never fire.
# A blind gate that dies silently reads exactly like a passing one in a log.
py_methods="$(
    awk '/^SUPPORTED_METHODS = \(/{f=1} f{print} f&&/^\)/{exit}' "$PY" \
        | grep -oE '"[A-Za-z0-9_]+"' | tr -d '"' | sort -u || true
)"

# Swift: the raw values of SupportedMethod's cases. Cases without an explicit
# raw value take the case name verbatim (`hello`, `ping`), so both forms count.
swift_methods="$(
    awk '/public enum SupportedMethod: String/{f=1} f{print} f&&/^\}/{exit}' "$SWIFT" \
        | sed -nE 's/^[[:space:]]*case[[:space:]]+([a-zA-Z0-9]+)[[:space:]]*=[[:space:]]*"([A-Za-z0-9_]+)".*/\2/p;
                   s/^[[:space:]]*case[[:space:]]+([a-zA-Z0-9]+)[[:space:]]*$/\1/p' \
        | sort -u || true
)"

if [[ -z "$py_methods" || -z "$swift_methods" ]]; then
    echo "ERROR: failed to extract methods (py=$(wc -w <<< "$py_methods"), swift=$(wc -w <<< "$swift_methods"))" >&2
    echo "       The parser broke, which is worse than a drift — it means this gate is blind." >&2
    exit 2
fi

# `${KNOWN_ABSENT[@]+"${KNOWN_ABSENT[@]}"}`: under macOS's system bash 3.2, an
# EMPTY array expands as an unbound variable and `set -u` aborts. Emptying this
# list is the end state the comment above deliberately pushes toward — porting
# the last method would have broken the gate that proves it was ported.
allowed="$(printf '%s\n' ${KNOWN_ABSENT[@]+"${KNOWN_ABSENT[@]}"} | sort -u)"

# In Python but not Swift, minus the allowlist.
missing="$(comm -23 <(printf '%s\n' "$py_methods") <(printf '%s\n' "$swift_methods") | comm -23 - <(printf '%s\n' "$allowed"))"
# In Swift but not Python — always wrong: the app negotiates against Python's set.
extra="$(comm -13 <(printf '%s\n' "$py_methods") <(printf '%s\n' "$swift_methods"))"
# Allowlisted but actually implemented — stale entry, delete it.
stale="$(comm -12 <(printf '%s\n' "$swift_methods") <(printf '%s\n' "$allowed"))"

status=0

if [[ -n "$missing" ]]; then
    echo "✗ Python advertises methods the Swift helper does not implement:" >&2
    sed 's/^/    /' <<< "$missing" >&2
    echo "" >&2
    echo "  A user on the Swift helper gets unknown_method for each of these." >&2
    echo "  Implement it, or add it to KNOWN_ABSENT with a comment saying why." >&2
    status=1
fi

if [[ -n "$extra" ]]; then
    echo "✗ Swift advertises methods Python does not:" >&2
    sed 's/^/    /' <<< "$extra" >&2
    echo "" >&2
    echo "  The app negotiates capabilities against Python's set, so this is" >&2
    echo "  either a typo in a raw value or a method that needs adding to" >&2
    echo "  helper/local_session_server.py:SUPPORTED_METHODS." >&2
    status=1
fi

if [[ -n "$stale" ]]; then
    echo "✗ Listed in KNOWN_ABSENT but actually implemented in Swift:" >&2
    sed 's/^/    /' <<< "$stale" >&2
    echo "" >&2
    echo "  Delete these lines from KNOWN_ABSENT — a stale allowlist entry hides" >&2
    echo "  the next real drift." >&2
    status=1
fi

if [[ $status -eq 0 ]]; then
    n_py="$(wc -l <<< "$py_methods" | tr -d ' ')"
    n_absent="$(wc -l <<< "$allowed" | tr -d ' ')"
    echo "✓ helper method parity: $n_py Python methods, $n_absent deliberately absent from Swift"
fi

exit $status

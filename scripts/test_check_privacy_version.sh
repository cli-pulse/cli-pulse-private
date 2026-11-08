#!/bin/bash
# Positive and negative controls for check_privacy_version.sh.
#
# The guard exists because 1.62.0's release PR moved MARKETING_VERSION to 1.62.0
# while PRIVACY.md kept saying "It describes CLI Pulse 1.60." A guard is worth
# what the proof that it fires is worth, so that exact case is planted below,
# along with the near-misses a loose parse would let through (1.6 vs 1.62,
# 1.62 vs 1.620, trailing words, a second copy of the line, one odd site in the
# Xcode project).
#
# The fixtures are synthetic and pinned at 1.62.0 / 1.62, so the next version
# bump cannot turn a case into a no-op or a false failure. Only the first case
# reads the real repository. Every negative case must exit with exactly 1 (a
# crash or a usage error is not a rejection) and name its reason; every
# mutation must change the file, or the case proves nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check_privacy_version.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CASE="$TMP/case"
PBX="$CASE/CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj"
POL="$CASE/PRIVACY.md"

pass=0
fail=0

build_fixture() {
    rm -rf "$CASE"
    mkdir -p "$(dirname "$PBX")"
    cat > "$PBX" <<'PBXPROJ'
// !$*UTF8*$!
{
	objects = {
		A1 /* Debug */ = {
			buildSettings = {
				CURRENT_PROJECT_VERSION = 117;
				MARKETING_VERSION = 1.62.0;
			};
		};
		A2 /* Release */ = {
			buildSettings = {
				CURRENT_PROJECT_VERSION = 117;
				MARKETING_VERSION = 1.62.0;
			};
		};
		A3 /* Watch Release */ = {
			buildSettings = {
				MARKETING_VERSION = 1.62.0;
			};
		};
	};
}
PBXPROJ
    cat > "$POL" <<'POLICY'
# Privacy Policy

**CLI Pulse**
**Last Updated: November 11, 2026**

This document is the single source of truth for what we collect.

It describes CLI Pulse 1.62.

---

## Alerts

CLI Pulse 1.56 and earlier also raised one for a session running a long time.
POLICY
}

# subst FILE OLD NEW [COUNT] — literal replacement, every occurrence or the
# first COUNT. Python, not `sed -i`, which differs between macOS and Linux.
subst() {
    python3 - "$@" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
count = int(sys.argv[4]) if len(sys.argv) > 4 else -1
with open(path, newline="") as f:
    text = f.read()
with open(path, "w", newline="") as f:
    f.write(text.replace(old, new, count))
PY
}

digest() { shasum "$1" | cut -d' ' -f1; }

record_ok()   { echo "ok:   [$1] $2"; pass=$((pass + 1)); }
record_fail() { echo "FAIL: [$1] $2"; fail=$((fail + 1)); }

# expect_pass NAME [guard args...]
expect_pass() {
    local name="$1" out rc; shift
    out="$(bash "$GUARD" "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        record_ok "$name" "guard accepts it."
    else
        record_fail "$name" "guard rejected it (exit $rc): $out"
    fi
}

# expect_fail NAME NEEDLE — run against the fixture; exit must be exactly 1
# and the output must contain NEEDLE (the reason, not just any error).
expect_fail() {
    local name="$1" needle="$2" out rc
    out="$(bash "$GUARD" --root "$CASE" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        record_fail "$name" "guard PASSED a tree it should have rejected."
    elif [ "$rc" -ne 1 ]; then
        record_fail "$name" "guard exited $rc, not 1 — that is a crash or a usage error, not a rejection: $out"
    elif ! printf '%s' "$out" | grep -qF -- "$needle"; then
        record_fail "$name" "guard failed, but not for the expected reason. wanted: $needle  got: $out"
    else
        record_ok "$name" "guard rejected it, for the right reason."
    fi
}

# mutate NAME FILE OLD NEW [COUNT] — apply, and refuse a no-op.
mutate() {
    local name="$1" file="$2" before; shift 2
    before="$(digest "$file")"
    subst "$file" "$@"
    if [ "$(digest "$file")" = "$before" ]; then
        record_fail "$name" "the mutation was a NO-OP — the case proves nothing."
        return 1
    fi
}

# ── positive controls ───────────────────────────────────────────────────────
expect_pass "the real repository"

build_fixture
expect_pass "fixture baseline (1.62.0 / 1.62)" --root "$CASE"

build_fixture
mutate "patch release" "$PBX" "1.62.0;" "1.62.3;" \
    && expect_pass "patch release 1.62.3 still describes 1.62" --root "$CASE"

build_fixture
mutate "two-part version" "$PBX" "1.62.0;" "1.62;" \
    && expect_pass "MARKETING_VERSION 1.62 describes 1.62" --root "$CASE"

build_fixture
mutate "quoted version" "$PBX" "= 1.62.0;" '= "1.62.0";' \
    && expect_pass "quoted MARKETING_VERSION" --root "$CASE"

build_fixture
mutate "CRLF policy" "$POL" $'\n' $'\r\n' \
    && expect_pass "PRIVACY.md saved with CRLF line endings" --root "$CASE"

# ── the header names a different version ────────────────────────────────────
build_fixture
mutate "1.62 release, policy says 1.60 (#748)" "$POL" "Pulse 1.62." "Pulse 1.60." \
    && expect_fail "1.62 release, policy says 1.60 (#748)" "says it describes CLI Pulse 1.60, but MARKETING_VERSION is 1.62.0"

build_fixture
mutate "1.6 is not 1.62" "$POL" "Pulse 1.62." "Pulse 1.6." \
    && expect_fail "1.6 is not 1.62" "says it describes CLI Pulse 1.6, but MARKETING_VERSION is 1.62.0"

build_fixture
mutate "1.62 is not 1.620" "$PBX" "1.62.0;" "1.620.0;" \
    && expect_fail "1.62 is not 1.620" "says it describes CLI Pulse 1.62, but MARKETING_VERSION is 1.620.0"

build_fixture
mutate "next minor not yet described" "$PBX" "1.62.0;" "1.63.0;" \
    && expect_fail "next minor not yet described" "says it describes CLI Pulse 1.62, but MARKETING_VERSION is 1.63.0"

# ── the header line is missing, doubled or malformed ────────────────────────
build_fixture
mutate "line removed" "$POL" $'It describes CLI Pulse 1.62.\n' "" \
    && expect_fail "line removed" "has no line starting 'It describes CLI Pulse'"

build_fixture
mutate "line doubled" "$POL" "---" $'It describes CLI Pulse 1.60.\n\n---' \
    && expect_fail "line doubled" "has 2 lines starting 'It describes CLI Pulse'"

build_fixture
mutate "only mid-paragraph" "$POL" "It describes CLI Pulse 1.62." "Read it all. It describes CLI Pulse 1.62." \
    && expect_fail "only mid-paragraph" "has no line starting 'It describes CLI Pulse'"

build_fixture
mutate "indented" "$POL" "It describes CLI Pulse 1.62." "  It describes CLI Pulse 1.62." \
    && expect_fail "indented" "has no line starting 'It describes CLI Pulse'"

while IFS='|' read -r label replacement; do
    [ -z "$label" ] && continue
    build_fixture
    mutate "$label" "$POL" "It describes CLI Pulse 1.62." "$replacement" \
        && expect_fail "$label" "must be exactly 'It describes CLI Pulse 1.62.'"
done <<'CASES'
three-part version|It describes CLI Pulse 1.62.0.
trailing words|It describes CLI Pulse 1.62 and later.
no full stop|It describes CLI Pulse 1.62
comma separator|It describes CLI Pulse 1,62.
words after the full stop|It describes CLI Pulse 1.62. Earlier versions differ.
CASES

# ── the Xcode project cannot be read as one version ─────────────────────────
build_fixture
mutate "one site on another version" "$PBX" "1.62.0;" "1.63.0;" 1 \
    && expect_fail "one site on another version" "2 different MARKETING_VERSION values"

build_fixture
mutate "one malformed site" "$PBX" "1.62.0;" "1.62.0beta;" 1 \
    && expect_fail "one malformed site" "2 different MARKETING_VERSION values"

build_fixture
mutate "every site a build variable" "$PBX" "1.62.0;" '"$(APP_VERSION)";' \
    && expect_fail "every site a build variable" "is not X.Y or X.Y.Z"

build_fixture
mutate "four-part version" "$PBX" "1.62.0;" "1.62.0.1;" \
    && expect_fail "four-part version" "MARKETING_VERSION '1.62.0.1' is not X.Y or X.Y.Z"

build_fixture
mutate "a site the parse cannot read" "$PBX" "MARKETING_VERSION = 1.62.0;" "MARKETING_VERSION=1.70.0;" 1 \
    && expect_fail "a site the parse cannot read" "mentions MARKETING_VERSION 3 times but has 2"

build_fixture
mutate "no MARKETING_VERSION" "$PBX" "MARKETING_VERSION = 1.62.0;" "CURRENT_PROJECT_VERSION = 117;" \
    && expect_fail "no MARKETING_VERSION" "found no MARKETING_VERSION"

# ── files missing, bad usage ────────────────────────────────────────────────
build_fixture
rm -f "$POL"
expect_fail "no PRIVACY.md" "no PRIVACY.md at"

build_fixture
rm -f "$PBX"
expect_fail "no Xcode project" "no Xcode project at"

out="$(bash "$GUARD" --root "$TMP/does-not-exist" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "no Xcode project at"; then
    record_ok "nonexistent --root" "guard rejected it, for the right reason."
else
    record_fail "nonexistent --root" "wanted exit 1 and 'no Xcode project at', got exit $rc: $out"
fi

for args in "--root" "--bogus"; do
    out="$(bash "$GUARD" $args 2>&1)"; rc=$?
    if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF "usage:"; then
        record_ok "usage: $args" "guard refuses with exit 2."
    else
        record_fail "usage: $args" "wanted exit 2 and a usage line, got exit $rc: $out"
    fi
done

echo
echo "test_check_privacy_version: $pass passed, $fail failed."
[ "$fail" -eq 0 ]

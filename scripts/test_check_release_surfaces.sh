#!/bin/bash
# Negative controls for scripts/check_release_surfaces.sh, offline.
#
# The check reads three surfaces of a Developer ID release (the GitHub
# release, latest.json, the Homebrew tap) and must say which one does not
# serve the version. Its --fixtures mode reads the fetched files from a
# directory instead of the network, so this builds the files a correct 1.60.0
# release would serve, asserts that passes, then breaks one surface at a time
# the ways past releases actually broke — latest.json left on the previous
# version (1.45.0), the tap left behind (1.53.0) — and asserts each is
# reported, for the right reason. It also asserts the fixture run never calls
# gh or curl, and that the script contains no write command at all.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check_release_surfaces.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"
V=1.60.0

# gh and curl stand-ins that only record being called: fixture mode must not.
mkdir -p "$TMP/bin"
for tool in gh curl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$tool" "$TMP/net.log" > "$TMP/bin/$tool"
    chmod +x "$TMP/bin/$tool"
done

# build_fixture: the files check_release_surfaces.sh fetches, for a correct 1.60.0.
build_fixture() {
    rm -rf "$FX"; mkdir -p "$FX"
    python3 - "$FX" "$V" "$ROOT/Casks/cli-pulse.rb" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
fx, v, cask_src = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
dmg = f"CLI-Pulse-{v}-arm64.dmg"
blob = b"fixture dmg bytes\n"
sha = hashlib.sha256(blob).hexdigest()
url = f"https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v{v}/{dmg}"
(fx / "download.dmg").write_bytes(blob)
manifest = {"version": v, "build": "113", "channel": "devid", "arch": "arm64", "url": url,
            "sha256": sha, "size_bytes": len(blob), "min_os_version": "13.0",
            "release_notes_url": f"https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/tag/app-v{v}"}
text = json.dumps(manifest, indent=2) + "\n"
for name in ("manifest.json", "latest.api.json", "latest.cdn.json"):
    (fx / name).write_text(text)
release = {"tag_name": f"app-v{v}", "draft": False, "prerelease": False, "assets": [
    {"name": dmg, "size": len(blob), "digest": f"sha256:{sha}"},
    {"name": f"{dmg}.sha256", "size": 93, "digest": "sha256:" + "1" * 64},
    {"name": "manifest-fragment-arm64.json", "size": len(text), "digest": "sha256:" + "2" * 64}]}
(fx / "release.json").write_text(json.dumps(release))
(fx / "latest_release.json").write_text(json.dumps({"tag_name": f"app-v{v}"}))
(fx / "dmg.sha256").write_text(f"{sha}  {dmg}\n")
(fx / "dmg_url_status").write_text("200")
cask = cask_src.read_text()
cask = re.sub(r'^(\s*version\s+)"[^"]*"', rf'\g<1>"{v}"', cask, count=1, flags=re.M)
cask = re.sub(r'^(\s*sha256\s+)"[^"]*"', rf'\g<1>"{sha}"', cask, count=1, flags=re.M)
(fx / "tap_cask.rb").write_text(cask)
(fx / "repo_cask.rb").write_text(cask)
PY
}

# edit <file> <python expression over s>: rewrite a fixture file; refuses a
# no-op, which would make the case prove nothing.
edit() {
    python3 - "$FX/$1" "$2" <<'PY'
import json, re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
new = eval(sys.argv[2], {"s": s, "json": json, "re": re})
if new == s:
    sys.exit(f"edit of {p} changed nothing — the case would prove nothing")
p.write_text(new)
PY
}
# jset <file> <key> <json value>: set one key of a JSON fixture.
jset() { edit "$1" "json.dumps({**json.loads(s), '$2': json.loads('$3')}, indent=2) + '\\n'"; }

pass=0
fail=0
run_check() { PATH="$TMP/bin:$PATH" bash "$CHECK" "$V" --fixtures "$FX" "$@" >"$TMP/out" 2>&1; }

expect_pass() {
    if run_check "${@:2}"; then echo "ok:   [$1] passes."; pass=$((pass + 1))
    else echo "FAIL: [$1] was rejected, but it should pass:"; sed 's/^/        /' "$TMP/out"; fail=$((fail + 1)); fi
}
expect_fail() {   # expect_fail <name> <substring the report must contain> [args...]
    local name="$1" why="$2"; shift 2
    if run_check "$@"; then
        echo "FAIL: [$name] the check PASSED a broken release."; sed 's/^/        /' "$TMP/out"
        fail=$((fail + 1))
    elif grep -qF -- "$why" "$TMP/out"; then
        echo "ok:   [$name] reported, for the right reason."; pass=$((pass + 1))
    else
        echo "FAIL: [$name] reported, but not for '$why':"; sed 's/^/        /' "$TMP/out"
        fail=$((fail + 1))
    fi
}

# ── positive control ─────────────────────────────────────────────────────────
rm -f "$TMP/net.log"
build_fixture; expect_pass "a correct release on all three surfaces"
grep -q "SURFACES OK" "$TMP/out" && [ "$(grep -c '^  ok ' "$TMP/out")" -ge 13 ] \
    && { echo "ok:   [every surface reported ok, line by line]"; pass=$((pass + 1)); } \
    || { echo "FAIL: [every surface reported ok, line by line]"; sed 's/^/        /' "$TMP/out"; fail=$((fail + 1)); }
build_fixture; expect_pass "--download: the DMG latest.json points at is the release's" --download
if [ -s "$TMP/net.log" ]; then
    echo "FAIL: [fixture mode never touches the network] it called:"; sed 's/^/        /' "$TMP/net.log"
    fail=$((fail + 1))
else
    echo "ok:   [fixture mode never touches the network]"; pass=$((pass + 1))
fi

# ── 1. the GitHub release ────────────────────────────────────────────────────
build_fixture; rm "$FX/release.json"; echo "HTTP 404: Not Found" > "$FX/release.json.err"
expect_fail "the release does not exist" "release app-v1.60.0: could not be read (HTTP 404: Not Found)"
build_fixture; jset release.json draft true
expect_fail "the release is a draft" "app-v1.60.0 is a DRAFT"
build_fixture; jset release.json prerelease true
expect_fail "the release is a pre-release" "app-v1.60.0 is a pre-release"
build_fixture; edit release.json 's.replace("CLI-Pulse-1.60.0-arm64.dmg\"", "CLI-Pulse-1.60.0-x86_64.dmg\"", 1)'
expect_fail "the DMG asset is missing" "asset CLI-Pulse-1.60.0-arm64.dmg is missing"
build_fixture; edit release.json 's.replace("manifest-fragment-arm64.json", "manifest.json")'
expect_fail "the manifest fragment is missing" "asset manifest-fragment-arm64.json is missing"
build_fixture; edit dmg.sha256 '"0" * 64 + s[64:]'
expect_fail "GitHub's digest and the .sha256 file disagree" "digest of CLI-Pulse-1.60.0-arm64.dmg and CLI-Pulse-1.60.0-arm64.dmg.sha256 disagree"
build_fixture; jset latest_release.json tag_name '"app-v1.59.0"'
expect_fail "the release is not marked Latest" "the Latest release is 'app-v1.59.0', not app-v1.60.0"
build_fixture; edit dmg_url_status '"404"'
expect_fail "the pinned download URL answers 404" "the pinned download URL answers 404"

# ── 2. latest.json ───────────────────────────────────────────────────────────
# The 1.45.0 case: release published, latest.json never promoted.
build_fixture; jset latest.api.json version '"1.59.0"'; cp "$FX/latest.api.json" "$FX/latest.cdn.json"
expect_fail "latest.json left on the previous version (1.45.0)" "latest.json version is '1.59.0', not '1.60.0'"
build_fixture
edit latest.api.json 's.replace("github.com/JasonYeYuhe/", "github.com/cli-pulse/")'
cp "$FX/latest.api.json" "$FX/latest.cdn.json"
expect_fail "latest.json on the cli-pulse/ owner the updater refuses" "the in-app updater refuses any URL outside https://github.com/JasonYeYuhe/"
build_fixture; jset latest.api.json sha256 "\"$(printf 'f%.0s' $(seq 64))\""; cp "$FX/latest.api.json" "$FX/latest.cdn.json"
expect_fail "latest.json with another DMG's sha256" "latest.json sha256 is 'ffff"
build_fixture; jset latest.api.json size_bytes 1; cp "$FX/latest.api.json" "$FX/latest.cdn.json"
expect_fail "latest.json with the wrong size" "latest.json size_bytes is 1"
build_fixture; jset latest.api.json build '"112"'; cp "$FX/latest.api.json" "$FX/latest.cdn.json"
expect_fail "latest.json that is not the release's manifest" "latest.json is not the release's manifest-fragment-arm64.json; differs in: build"
build_fixture; jset latest.cdn.json version '"1.59.0"'
expect_fail "the CDN still serving the old latest.json" "GitHub's download CDN can serve the old asset for minutes"
build_fixture; rm "$FX/latest.api.json"
expect_fail "latest.json could not be read" "latest.json from the API: could not be read"
build_fixture; printf 'other bytes\n' > "$FX/download.dmg"
expect_fail "--download: the DMG latest.json points at is not the release's" "the DMG downloaded through latest.json is not the release's" --download
build_fixture; rm "$FX/download.dmg"
expect_fail "--download: the DMG could not be downloaded" "could not be downloaded" --download

# ── 3. the Homebrew tap ──────────────────────────────────────────────────────
# The 1.53.0 case: release and latest.json moved, the tap never did.
build_fixture; edit tap_cask.rb 're.sub(r"version \"1.60.0\"", "version \"1.52.1\"", s)'
expect_fail "the tap left on an older version (1.53.0)" "the tap's cask says version '1.52.1', not '1.60.0'"
build_fixture; edit tap_cask.rb 're.sub(r"sha256 \"[0-9a-f]{64}\"", "sha256 \"" + "e" * 64 + "\"", s)'
expect_fail "the tap with another sha256" "the tap's cask sha256 is 'eeee"
build_fixture; edit tap_cask.rb 's.replace("github.com/JasonYeYuhe/", "github.com/cli-pulse/")'
expect_fail "the tap's URL off the pinned owner" "the tap's cask does not download from the pinned URL"
build_fixture; edit repo_cask.rb 're.sub(r"version \"1.60.0\"", "version \"1.59.0\"", s)'
expect_fail "this repo's cask not merged / tap edited by hand" "this repo's Casks/cli-pulse.rb on main differs from the tap's"
build_fixture; rm "$FX/tap_cask.rb"; echo "HTTP 404: Not Found" > "$FX/tap_cask.rb.err"
expect_fail "the tap's cask could not be read" "the tap's cask could not be read (HTTP 404: Not Found)"

# ── usage ────────────────────────────────────────────────────────────────────
build_fixture
for args in "" "1.60" "1.60.0 --bogus" "1.60.0 1.61.0" "1.60.0 --fixtures"; do
    # shellcheck disable=SC2086
    PATH="$TMP/bin:$PATH" bash "$CHECK" $args >"$TMP/out" 2>&1; rc=$?
    if [ "$rc" -eq 2 ]; then echo "ok:   [usage: '$args' exits 2]"; pass=$((pass + 1))
    else echo "FAIL: [usage: '$args' exits 2] got $rc"; sed 's/^/        /' "$TMP/out"; fail=$((fail + 1)); fi
done

# ── read-only by construction ────────────────────────────────────────────────
# No command that writes to GitHub may appear in the script. The pattern is
# run on a copy with one planted, so a pattern that matches nothing is noticed.
WRITES='gh release (create|upload|edit|delete)|git push|--clobber|--method|-X *(POST|PATCH|PUT|DELETE)|--field|--raw-field|gh api [^|]* -[fF] '
if grep -nE -- "$WRITES" "$CHECK" >"$TMP/out"; then
    echo "FAIL: [the script contains no write command]"; sed 's/^/        /' "$TMP/out"; fail=$((fail + 1))
else
    echo "ok:   [the script contains no write command]"; pass=$((pass + 1))
fi
{ cat "$CHECK"; echo 'gh release upload latest latest.json --repo "$DISTRIB" --clobber'; } > "$TMP/planted.sh"
if grep -qE -- "$WRITES" "$TMP/planted.sh"; then
    echo "ok:   [... and the pattern notices a planted upload]"; pass=$((pass + 1))
else
    echo "FAIL: [... and the pattern notices a planted upload]"; fail=$((fail + 1))
fi

echo "test_check_release_surfaces: $pass passed, $fail failed."
[ "$fail" -eq 0 ] || exit 1
exit 0

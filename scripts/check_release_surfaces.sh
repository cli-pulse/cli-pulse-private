#!/usr/bin/env bash
# Does every surface of a Developer ID release actually serve VERSION?
#
# WHY THIS EXISTS
# ---------------
# Publishing the Mac Developer ID build means changing THREE places, by three
# separate commands, and users only get the version from the ones that moved:
#
#   1. the GitHub release app-vX.Y.Z on cli-pulse/cli-pulse-distrib — the DMG,
#      its .sha256, the manifest fragment, marked Latest;
#   2. latest.json on that repo's `latest` release — what the in-app updater
#      reads, at the JasonYeYuhe/ URL compiled into AppUpdater.swift;
#   3. Casks/cli-pulse.rb on cli-pulse/homebrew-tap, branch master — what
#      `brew upgrade` reads (the copy in this repo is only its source).
#
# Each has been missed: 1.45.0 shipped with latest.json and the tap still on
# 1.44.0, so almost no existing user was offered it; 1.53.0 never reached
# Homebrew at all (the tap went from 1.52.1 straight to 1.54.0 on 2026-09-28).
# A merged cask PR looks like a release and is not one. So this reads all
# three back and says, per surface, whether it serves VERSION.
#
# READ-ONLY. Every request is a GET (gh api, gh release download to a scratch
# directory, curl). It writes nothing anywhere but a temporary directory.
#
# Usage:
#   scripts/check_release_surfaces.sh 1.54.0              # after publishing
#   scripts/check_release_surfaces.sh 1.54.0 --download   # also fetch the DMG
#                                    # latest.json points at, hash it, spctl it
#   scripts/check_release_surfaces.sh 1.54.0 --fixtures DIR   # offline: read
#                                    # the fetched files from DIR (the test)
# Exit 0 = every surface serves VERSION. 1 = at least one does not, or could
# not be read (which is not a pass). 2 = usage.
#
# The procedure around it: AGENTS.md, "Releasing the Developer ID build — three
# surfaces". Negative controls: scripts/test_check_release_surfaces.sh.

set -uo pipefail

usage() {
    echo "usage: $0 <version> [--download] [--fixtures DIR]   e.g. $0 1.54.0" >&2
    exit 2
}

VERSION=""
DOWNLOAD=0
FIXTURES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --download) DOWNLOAD=1 ;;
        --fixtures) [ $# -ge 2 ] || usage; FIXTURES="$2"; shift ;;
        -*) usage ;;
        *) [ -z "$VERSION" ] || usage; VERSION="$1" ;;
    esac
    shift
done
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a version: $VERSION" >&2; usage; }

# PINNED: the distrib repo, the JasonYeYuhe/ owner segment the shipped updater
# validates URLs against (UpdateVerifier.allowedURLPrefix), the arm64 asset
# names, and the tap's branch. See Casks/cli-pulse.rb and AppUpdater.swift.
DISTRIB="cli-pulse/cli-pulse-distrib"
TAP="cli-pulse/homebrew-tap"
TAP_BRANCH="master"
PRIVATE="cli-pulse/cli-pulse-private"
TAG="app-v${VERSION}"
DMG="CLI-Pulse-${VERSION}-arm64.dmg"
MANIFEST="manifest-fragment-arm64.json"
DMG_URL="https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/${TAG}/${DMG}"
LATEST_URL="https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/latest/latest.json"

if [ -n "$FIXTURES" ]; then
    [ -d "$FIXTURES" ] || { echo "no such fixtures directory: $FIXTURES" >&2; exit 2; }
    D="$FIXTURES"
    MODE="fixtures ($FIXTURES)"
else
    D="$(mktemp -d)"
    trap 'rm -rf "$D"' EXIT
    MODE="live"
    for tool in gh curl python3; do
        command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool not installed" >&2; exit 1; }
    done
    # fetch <name> <command...>: stdout to $D/<name>; on failure $D/<name>.err
    fetch() {
        local name="$1"; shift
        if ! "$@" >"$D/$name" 2>"$D/$name.err"; then
            rm -f "$D/$name"
        else
            rm -f "$D/$name.err"
        fi
    }
    echo "==> reading the three surfaces of $VERSION (GET only)"
    fetch release.json        gh api "repos/$DISTRIB/releases/tags/$TAG"
    fetch latest_release.json gh api "repos/$DISTRIB/releases/latest"
    fetch dmg.sha256          gh release download "$TAG" --repo "$DISTRIB" --pattern "$DMG.sha256" --output -
    fetch manifest.json       gh release download "$TAG" --repo "$DISTRIB" --pattern "$MANIFEST" --output -
    fetch latest.api.json     gh release download latest --repo "$DISTRIB" --pattern latest.json --output -
    fetch latest.cdn.json     curl -fsSL --max-time 60 "$LATEST_URL"
    fetch dmg_url_status      curl -sSIL -o /dev/null --max-time 60 -w '%{http_code}' "$DMG_URL"
    fetch tap_cask.rb         gh api -H "Accept: application/vnd.github.raw" \
                                  "repos/$TAP/contents/Casks/cli-pulse.rb?ref=$TAP_BRANCH"
    fetch repo_cask.rb        gh api -H "Accept: application/vnd.github.raw" \
                                  "repos/$PRIVATE/contents/Casks/cli-pulse.rb?ref=main"
    if [ "$DOWNLOAD" = 1 ]; then
        # The URL latest.json names, which is what the updater downloads.
        url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("url",""))' \
               "$D/latest.api.json" 2>/dev/null || true)"
        if [ -n "$url" ]; then
            fetch download.dmg curl -fsSL --max-time 600 "$url"
            if [ -f "$D/download.dmg" ] && command -v spctl >/dev/null 2>&1; then
                spctl --assess --type open --context context:primary-signature --ignore-cache -v \
                    "$D/download.dmg" >"$D/spctl.out" 2>&1
                echo "$?" > "$D/spctl.rc"
            fi
        else
            echo "latest.json has no url to download" > "$D/download.dmg.err"
        fi
    fi
fi

python3 - "$D" "$VERSION" "$TAG" "$DMG" "$MANIFEST" "$DMG_URL" "$DOWNLOAD" "$MODE" \
    "$DISTRIB" "$TAP" "$TAP_BRANCH" <<'PY'
import hashlib, json, re, sys
from pathlib import Path

d = Path(sys.argv[1])
version, tag, dmg, manifest_name, dmg_url, download, mode = sys.argv[2:9]
distrib, tap, tap_branch = sys.argv[9:12]
PREFIX = "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/"
CASK_URL = PREFIX + "app-v#{version}/CLI-Pulse-#{version}-#{arch}.dmg"
failures = 0


def ok(msg):
    print(f"  ok    {msg}")


def fail(msg, *more):
    global failures
    failures += 1
    print(f"  FAIL  {msg}")
    for m in more:
        print(f"          {m}")


def read(name):
    """The fetched file's text, or None if it could not be fetched (err_of says why)."""
    p = d / name
    return p.read_text(encoding="utf-8", errors="replace") if p.is_file() else None


def err_of(name):
    e = d / f"{name}.err"
    why = " ".join(e.read_text(errors="replace").split())[:200] if e.is_file() else ""
    return why or "not fetched"


def load_json(name, what):
    text = read(name)
    if text is None:
        fail(f"{what}: could not be read ({err_of(name)})")
        return None
    try:
        return json.loads(text)
    except ValueError as exc:
        fail(f"{what}: not JSON ({exc})")
        return None


def cask_field(text, field):
    m = re.search(rf'^\s*{field}\s+"([^"]*)"', text, flags=re.M)
    return m.group(1) if m else None


print(f"Developer ID release {version}, {mode}")

# ── 1. the GitHub release ────────────────────────────────────────────────────
print(f"\n1. GitHub release {tag} on {distrib}")
dmg_sha = dmg_size = None
rel = load_json("release.json", f"release {tag}")
if rel is not None:
    if rel.get("tag_name") != tag:
        fail(f"the release read back is {rel.get('tag_name')!r}, not {tag}")
    if rel.get("draft"):
        fail(f"{tag} is a DRAFT: nobody can download it")
    if rel.get("prerelease"):
        fail(f"{tag} is a pre-release: GitHub's Latest, and the cask's livecheck, skip it")
    if not rel.get("draft") and not rel.get("prerelease") and rel.get("tag_name") == tag:
        ok(f"{tag} is published")
    assets = {a.get("name"): a for a in rel.get("assets") or []}
    for name in (dmg, f"{dmg}.sha256", manifest_name):
        if name in assets:
            ok(f"asset {name} ({assets[name].get('size')} bytes)")
        else:
            fail(f"asset {name} is missing from {tag}")
    if dmg in assets:
        dmg_size = assets[dmg].get("size")
        digest = re.sub(r"^sha256:", "", assets[dmg].get("digest") or "") or None
        side = read("dmg.sha256")
        side_sha = side.split()[0] if side and side.split() else None
        if side is None:
            fail(f"{dmg}.sha256 could not be read ({err_of('dmg.sha256')})")
        if digest and side_sha and digest != side_sha:
            fail(f"GitHub's digest of {dmg} and {dmg}.sha256 disagree",
                 f"digest:  {digest}", f".sha256: {side_sha}")
        dmg_sha = digest or side_sha
        if dmg_sha:
            ok(f"{dmg} sha256 {dmg_sha[:12]}… ({'GitHub digest' if digest else '.sha256 file'}"
               f"{', = .sha256 file' if digest and side_sha == digest else ''})")
latest_rel = load_json("latest_release.json", "the repo's Latest release")
if latest_rel is not None:
    if latest_rel.get("tag_name") == tag:
        ok(f"{tag} is marked Latest")
    else:
        fail(f"the Latest release is {latest_rel.get('tag_name')!r}, not {tag}")
status = (read("dmg_url_status") or "").strip()
if status == "200":
    ok(f"the pinned download URL answers 200: {dmg_url}")
elif status:
    fail(f"the pinned download URL answers {status}", dmg_url)
else:
    fail(f"the pinned download URL could not be reached ({err_of('dmg_url_status')})", dmg_url)

# ── 2. latest.json ───────────────────────────────────────────────────────────
print(f"\n2. latest.json (the in-app updater) on {distrib}@latest")
frag = load_json("manifest.json", f"{manifest_name} on {tag}")
api = load_json("latest.api.json", "latest.json from the API")
if api is not None:
    want = {"version": version, "url": dmg_url}
    if dmg_sha:
        want["sha256"] = dmg_sha
    if dmg_size is not None:
        want["size_bytes"] = dmg_size
    bad = {k: (api.get(k), v) for k, v in want.items() if api.get(k) != v}
    if not bad:
        ok(f"latest.json says {version}, build {api.get('build')}, points at the pinned URL, "
           "and its sha256 and size are the DMG's")
    for k, (got, exp) in bad.items():
        why = ""
        if k == "version":
            why = f" — the in-app updater offers existing users {got!r}"
        elif k == "url" and not str(got).startswith(PREFIX):
            why = f" — the in-app updater refuses any URL outside {PREFIX}"
        elif k == "url":
            why = " — another release's DMG"
        fail(f"latest.json {k} is {got!r}, not {exp!r}{why}")
    if frag is not None:
        if api == frag:
            ok(f"latest.json is the release's {manifest_name}")
        else:
            diff = sorted(k for k in set(api) | set(frag) if api.get(k) != frag.get(k))
            fail(f"latest.json is not the release's {manifest_name}; differs in: {', '.join(diff)}")
cdn = load_json("latest.cdn.json", "latest.json at the URL the app fetches")
if cdn is not None and api is not None:
    if cdn == api:
        ok("the URL the app fetches serves the same latest.json")
    else:
        fail(f"the URL the app fetches serves version {cdn.get('version')!r}, the API "
             f"{api.get('version')!r}",
             "GitHub's download CDN can serve the old asset for minutes after it is replaced:",
             "wait and re-run before concluding the upload failed.")
if download == "1":
    blob = d / "download.dmg"
    if not blob.is_file():
        fail(f"the DMG latest.json points at could not be downloaded ({err_of('download.dmg')})")
    else:
        data = blob.read_bytes()
        got_sha = hashlib.sha256(data).hexdigest()
        if dmg_sha and got_sha == dmg_sha and (dmg_size is None or len(data) == dmg_size):
            ok(f"downloaded through latest.json: {len(data)} bytes, sha256 {got_sha[:12]}…, "
               "the release's")
        else:
            fail("the DMG downloaded through latest.json is not the release's",
                 f"downloaded: {len(data)} bytes, sha256 {got_sha}",
                 f"release:    {dmg_size} bytes, sha256 {dmg_sha}")
        rc = d / "spctl.rc"
        if rc.is_file():
            out = (d / "spctl.out").read_text(errors="replace").strip()
            if rc.read_text().strip() == "0" and "Notarized Developer ID" in out:
                ok("spctl: accepted, Notarized Developer ID")
            else:
                fail("spctl did not accept the downloaded DMG as notarized", out[:300])
        else:
            print("  note  spctl not run (not macOS, or fixtures)")

# ── 3. the Homebrew tap ──────────────────────────────────────────────────────
print(f"\n3. Homebrew: Casks/cli-pulse.rb on {tap}@{tap_branch}")
tap_cask = read("tap_cask.rb")
if tap_cask is None:
    fail(f"the tap's cask could not be read ({err_of('tap_cask.rb')})")
else:
    tv, ts = cask_field(tap_cask, "version"), cask_field(tap_cask, "sha256")
    if tv == version:
        ok(f'the tap\'s cask says version "{version}"')
    else:
        fail(f"the tap's cask says version {tv!r}, not {version!r} — `brew upgrade` offers "
             f"{tv!r}: push Casks/cli-pulse.rb to the tap")
    if dmg_sha and ts == dmg_sha:
        ok("the tap's cask carries the DMG's sha256")
    elif dmg_sha:
        fail(f"the tap's cask sha256 is {ts!r}, not the DMG's {dmg_sha!r} — brew would refuse "
             "the download")
    if f'url "{CASK_URL}"' in tap_cask:
        ok("the tap's cask downloads from the pinned JasonYeYuhe/ URL")
    else:
        fail("the tap's cask does not download from the pinned URL", CASK_URL)
    repo_cask = read("repo_cask.rb")
    if repo_cask is None:
        fail(f"this repo's Casks/cli-pulse.rb on main could not be read ({err_of('repo_cask.rb')})")
    elif repo_cask == tap_cask:
        ok("this repo's Casks/cli-pulse.rb on main is the same file")
    else:
        fail("this repo's Casks/cli-pulse.rb on main differs from the tap's: the cask PR is "
             "not merged, or the tap was edited by hand",
             f"main says version {cask_field(repo_cask, 'version')!r}")

print()
if failures:
    print(f"SURFACES NOT OK — {failures} check(s) failed. Users are not all offered {version}.")
    sys.exit(1)
print(f"SURFACES OK — the release, latest.json and the Homebrew tap all serve {version}.")
PY

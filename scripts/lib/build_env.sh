#!/bin/bash
# The Swift package checkout that local, non-release xcodebuild runs share, resolved once.
# Bash 3.2 (macOS /bin/bash).
#
# Why: every new derived-data directory used to resolve its own SourcePackages, and about
# 2.4 GB of each ~3 GB root is sentry-cocoa, whose package unpacks five xcframeworks (measured
# 2026-10-14). Agents that built into a fresh root per step and trashed it afterwards unpacked
# the same package each time. Only the packages are shared: each checkout that builds keeps its
# own derived data.
#
# Sourced:
#   source scripts/lib/build_env.sh
#   spm_cache_args "<repo>/CLI Pulse Bar" [the caller's xcodebuild args...]
#     Sets the array SPM_ARGS, for the caller to splice into its xcodebuild line as
#     "${SPM_ARGS[@]+"${SPM_ARGS[@]}"}" (a bare "${SPM_ARGS[@]}" of an empty array is an
#     unbound-variable error under bash 3.2's set -u):
#       -clonedSourcePackagesDirPath <dir> -disableAutomaticPackageResolution
#     after making sure <dir> holds a finished resolve. SPM_ARGS stays empty (xcodebuild
#     resolves into the derived data, as before) when:
#       - CI=true: CI keeps its own behaviour;
#       - the caller's args already name -clonedSourcePackagesDirPath;
#       - CLIPULSE_SPM_DIR=off;
#       - the project has no Package.resolved;
#       - the directory would be inside ~/Documents or ~/Desktop (iCloud stamps FinderInfo on
#         the Sentry framework, which fails codesign --deep --strict) or $TMPDIR (purged by
#         age, which can leave a marker over missing files), or its parent cannot be created;
#       - the resolve fails (a warning, with its log): no network, or a Package.resolved that
#         no longer satisfies the package requirements. The build then behaves as before.
#     Returns 1 only when another process holds the resolve lock for too long.
#   Non-release builds also pass COMPILER_INDEX_STORE_ENABLE=NO: nothing reads the index.
#
# Run (one xcodebuild, with SPM_ARGS and COMPILER_INDEX_STORE_ENABLE=NO appended):
#   scripts/lib/build_env.sh xcodebuild build -project "CLI Pulse Bar/CLI Pulse Bar.xcodeproj" ...
#   Run the copy in the checkout you are building. The key comes from this checkout's files, so
#   a project elsewhere (-project, or without it the current directory, as xcodebuild finds it)
#   gets only a warning and no shared packages.
#
# The directory: ${CLIPULSE_SPM_ROOT:-~/Library/Caches/CLIPulse-build}/SourcePackages-<8 hex>,
# the sha256 of the project's Package.resolved, its package references (project.pbxproj's
# XCRemote/XCLocalSwiftPackageReference sections) and CLIPulseCore's package requirements (its
# `.package(` lines). A branch that bumps a package therefore gets its own directory instead of
# re-resolving the one every other checkout builds from. Every checkout with the same packages
# shares that directory by default, worktrees included, also when they build at the same time.
# Each build rewrites the directory's workspace-state.json (measured 2026-10-15), and two builds
# from different worktrees on one directory at once have not been measured, so work that builds
# in several worktrees concurrently gives each its own CLIPULSE_SPM_ROOT.
# CLIPULSE_SPM_DIR=<dir> names one directory instead; it is re-resolved whenever the key
# changes, so never give one to trees that differ in packages. A relative CLIPULSE_SPM_ROOT or
# CLIPULSE_SPM_DIR is taken from the current directory.
#
# Resolution happens here, once per directory, under the mkdir lock <dir>.lock, with
# -onlyUsePackageVersionsFromResolvedFile. <dir>/.clipulse-resolved (the key) marks a finished
# resolve, so one killed half-way is resolved again rather than trusted. Never rename or move
# the directory: its workspace-state.json records absolute paths. Deleting it while no build
# uses it is safe; the next build resolves it again.
#
# Environment:
#   CLIPULSE_SPM_ROOT        where the keyed directories go (default ~/Library/Caches/CLIPulse-build)
#   CLIPULSE_SPM_DIR         one directory instead, or `off`
#   CLIPULSE_BUILD_LOCK_WAIT seconds to wait for a held resolve lock (default 2400)

SPM_ARGS=()

# 0 when the lock's holder, or the resolve it recorded, is alive.
_build_lock_alive() {
    local p
    for p in "$(cat "$1/pid" 2>/dev/null || true)" "$(cat "$1/child" 2>/dev/null || true)"; do
        [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && return 0
    done
    return 1
}

# Removes a lock whose holder is gone, but only if it still shows the state the caller saw:
# under <lock>.reap, so two waiters that saw the same dead holder cannot have the second remove
# the lock the first has just retaken.
#   0 removed, or the lock changed since the caller looked (try mkdir again)
#   1 someone else is reaping (retry shortly)
#   2 it could not be removed (treat it as held)
_build_lock_reap() {
    local lock="$1" seen="$2" holder age now rc=0
    now=$(date +%s)
    if ! mkdir "$lock.reap" 2>/dev/null; then
        # Held for microseconds; a minute old means its holder died inside it.
        age=$(( now - $(stat -f %m "$lock.reap" 2>/dev/null || echo "$now") ))
        (( age > 60 )) && rmdir "$lock.reap" 2>/dev/null
        return 1
    fi
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    age=$(( now - $(stat -f %m "$lock" 2>/dev/null || echo "$now") ))
    if [[ -n "$seen" && "$holder" == "$seen" ]] && ! _build_lock_alive "$lock"; then
        echo "==> $lock was left by pid $seen, which is gone; taking it over" >&2
        rm -f "$lock/pid" "$lock/child" "$lock/what"
        rmdir "$lock" 2>/dev/null || rc=2
    elif [[ -z "$seen" && -d "$lock" && -z "$holder" ]] && (( age > 60 )); then
        # mkdir and the pid write are microseconds apart: no pid a minute later means the
        # holder died in between.
        echo "==> $lock has had no pid for ${age}s; taking it over" >&2
        rm -f "$lock/child" "$lock/what"
        rmdir "$lock" 2>/dev/null || rc=2
    fi
    rmdir "$lock.reap" 2>/dev/null || true
    return $rc
}

# build_lock_take <lock dir> <what>: wait for, then take, a mkdir lock (pid inside). 0 taken,
# 1 gave up after CLIPULSE_BUILD_LOCK_WAIT seconds, 2 the lock cannot be created at all.
build_lock_take() {
    local lock="$1" what="$2" holder age now rc stuck=0 next_note=0
    local deadline=$(( $(date +%s) + ${CLIPULSE_BUILD_LOCK_WAIT:-2400} ))
    while ! mkdir "$lock" 2>/dev/null; do
        if [[ ! -d "$lock" ]]; then
            # No lock there, yet mkdir failed: once more in case its holder just left, then it
            # is a missing or unwritable parent, which waiting does not fix.
            mkdir "$lock" 2>/dev/null && break
            [[ -d "$lock" ]] || { echo "✗ Cannot create $lock" >&2; return 2; }
        fi
        now=$(date +%s)
        if (( now >= deadline )); then
            echo "✗ $lock is still held ($(cat "$lock/what" 2>/dev/null || echo '?'), pid $(cat "$lock/pid" 2>/dev/null || echo '?')); gave up after ${CLIPULSE_BUILD_LOCK_WAIT:-2400}s" >&2
            return 1
        fi
        holder="$(cat "$lock/pid" 2>/dev/null || true)"
        rc=3
        if [[ -n "$holder" ]] && ! _build_lock_alive "$lock"; then
            rc=0; _build_lock_reap "$lock" "$holder" || rc=$?
        elif [[ -z "$holder" ]]; then
            age=$(( now - $(stat -f %m "$lock" 2>/dev/null || echo "$now") ))
            if (( age > 60 )); then rc=0; _build_lock_reap "$lock" "" || rc=$?; fi
        fi
        (( rc == 0 )) && continue
        if (( rc == 2 && stuck == 0 )); then
            echo "⚠ $lock belongs to nobody but cannot be removed (not empty?); waiting as if it were held" >&2
            stuck=1
        fi
        if (( rc == 3 && now >= next_note )); then
            echo "==> Waiting for $lock ($(cat "$lock/what" 2>/dev/null || echo '?'), pid ${holder:-?})" >&2
            next_note=$(( now + 300 ))
        fi
        if (( rc == 1 )); then sleep 1; else sleep 5; fi
    done
    # This shell's own pid: inside a ( subshell ) $$ is still the parent's, and a subshell killed
    # mid-resolve would then leave a lock that looks held for as long as the parent lives.
    # shellcheck disable=SC2016
    echo "$(exec sh -c 'echo $PPID')" >"$lock/pid"
    echo "$what" >"$lock/what"
}

# build_lock_release <lock dir>: only after build_lock_take succeeded, and once the resolve it
# recorded has exited.
build_lock_release() {
    rm -f "$1/pid" "$1/child" "$1/what"
    rmdir "$1" 2>/dev/null || true
}

# spm_cache_key <app dir>: the 64-hex key (header), or nothing without a Package.resolved.
spm_cache_key() {
    local app="$1"
    local resolved="$app/CLI Pulse Bar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    [[ -f "$resolved" ]] || return 0
    { cat "$resolved"
      sed -n -e '/Begin XCRemoteSwiftPackageReference section/,/End XCRemoteSwiftPackageReference section/p' \
             -e '/Begin XCLocalSwiftPackageReference section/,/End XCLocalSwiftPackageReference section/p' \
             "$app/CLI Pulse Bar.xcodeproj/project.pbxproj" 2>/dev/null || true
      grep -E '^[[:space:]]*\.package\(' "$app/CLIPulseCore/Package.swift" 2>/dev/null || true
    } | shasum -a 256 | awk '{print $1}'
}

spm_cache_args() {
    local app="$1" a key dir marker lock log rpid rc
    shift
    SPM_ARGS=()
    [[ "${CI:-}" == "true" ]] && return 0
    [[ "${CLIPULSE_SPM_DIR:-}" == "off" ]] && return 0
    for a in "$@"; do
        [[ "$a" == "-clonedSourcePackagesDirPath" ]] && return 0
    done
    key="$(spm_cache_key "$app")"
    if [[ -z "$key" ]]; then
        echo "==> No Package.resolved in $app: packages resolve into the derived data" >&2
        return 0
    fi
    dir="${CLIPULSE_SPM_DIR:-${CLIPULSE_SPM_ROOT:-$HOME/Library/Caches/CLIPulse-build}/SourcePackages-${key:0:8}}"
    dir="${dir%/}"
    case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac
    case "$dir/" in
        "$HOME/Documents/"*|"$HOME/Desktop/"*)
            echo "⚠ $dir is in iCloud's Documents or Desktop; packages resolve into the derived data instead" >&2
            return 0 ;;
    esac
    if [[ -n "${TMPDIR:-}" && ( "$dir/" == "${TMPDIR%/}/"* || "$dir/" == "/private${TMPDIR%/}/"* ) ]]; then
        echo "⚠ $dir is in \$TMPDIR, which macOS purges by age; packages resolve into the derived data instead" >&2
        return 0
    fi
    marker="$dir/.clipulse-resolved"
    if [[ "$(cat "$marker" 2>/dev/null || true)" != "$key" ]]; then
        lock="$dir.lock"
        if ! mkdir -p "$(dirname "$dir")"; then
            echo "⚠ Cannot create $(dirname "$dir"); packages resolve into the derived data instead" >&2
            return 0
        fi
        rc=0
        build_lock_take "$lock" "resolving packages for $app" || rc=$?
        if (( rc == 2 )); then
            echo "⚠ Packages resolve into the derived data instead" >&2
            return 0
        fi
        (( rc == 0 )) || return 1
        # Someone else may have finished the same resolve while this waited.
        if [[ "$(cat "$marker" 2>/dev/null || true)" != "$key" ]]; then
            log="$dir.resolve.log"
            echo "==> Resolving Swift packages into $dir (once per package set; log $log)" >&2
            rm -f "$marker"
            mkdir -p "$dir"
            # In the background with its pid in the lock, so a waiter never takes the lock over
            # from a resolve that outlived its shell.
            xcodebuild -resolvePackageDependencies -project "$app/CLI Pulse Bar.xcodeproj" \
                -clonedSourcePackagesDirPath "$dir" -onlyUsePackageVersionsFromResolvedFile \
                >"$log" 2>&1 &
            rpid=$!
            echo "$rpid" >"$lock/child"
            if ! wait "$rpid"; then
                tail -8 "$log" | sed 's/^/    /' >&2
                echo "⚠ Could not resolve into $dir (log $log); this build resolves into its own derived data instead" >&2
                build_lock_release "$lock"
                return 0
            fi
            if ! echo "$key" 2>/dev/null >"$marker"; then
                echo "⚠ Could not write $marker; this build resolves into its own derived data instead" >&2
                build_lock_release "$lock"
                return 0
            fi
        fi
        build_lock_release "$lock"
    fi
    SPM_ARGS=(-clonedSourcePackagesDirPath "$dir" -disableAutomaticPackageResolution)
}

# Run rather than sourced: `build_env.sh xcodebuild <args...>` (header).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    [[ "${1:-}" == "xcodebuild" ]] || { echo "usage: $0 xcodebuild <args...>  (or source it)" >&2; exit 2; }
    shift
    # The project xcodebuild will build: -project, else the one in the current directory. The
    # key is this checkout's, so another checkout's project must not get this directory.
    project="CLI Pulse Bar.xcodeproj" prev=""
    for a in "$@"; do
        [[ "$prev" == "-project" ]] && project="$a"
        prev="$a"
    done
    own="$(cd "$(dirname "$0")/../.." && pwd -P)/CLI Pulse Bar"
    if [[ "$(basename "$project")" == "CLI Pulse Bar.xcodeproj" &&
          "$(cd "$(dirname "$project")" 2>/dev/null && pwd -P || true)" == "$own" ]]; then
        spm_cache_args "$own" "$@" || exit 1
    else
        echo "⚠ $0 shares packages only for $own/CLI Pulse Bar.xcodeproj, not $project (from $PWD); this build resolves into its derived data. Run the build_env.sh of the checkout you are building." >&2
    fi
    exec xcodebuild "$@" "${SPM_ARGS[@]+"${SPM_ARGS[@]}"}" COMPILER_INDEX_STORE_ENABLE=NO
fi

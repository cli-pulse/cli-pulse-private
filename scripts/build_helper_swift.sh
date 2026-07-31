#!/bin/bash
# Phase 4D: Swift helper build script.
#
# Replaces the Phase 4 PyInstaller-based `build_helper_binary.sh`
# with a `swift build -c release` invocation. Same contract: the
# Xcode "Run Script" build phase calls this; the output binary
# lands in a fixed path the "Copy Files" phase picks up.
#
# Output: HelperSwift/.build/release/cli_pulse_helper
#         (single Mach-O, no Python interpreter, ~480 KB arm64)
#
# Build phases the macOS app target needs (manually configured
# in Xcode UI — see PHASE4D_XCODE_SETUP.md):
#
#   1. "Build Helper Binary (Swift)" — Run Script that calls this
#      file. Lives BEFORE the Copy Files phase.
#   2. "Embed Helper Binary" — Copy Files into Wrapper at
#      `Contents/Helpers`, including
#      `$(PROJECT_ROOT)/../HelperSwift/.build/release/cli_pulse_helper`.
#      Tick "Code Sign On Copy" so the embedded binary inherits
#      the app's signing identity / entitlements.
#   3. "Embed HelperAgent.plist" — Copy Bundle Resources phase
#      includes `CLI Pulse Bar/HelperAgent.plist`. Same as Phase 4
#      (PR #19) — unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SWIFT_PKG_DIR="$PROJECT_ROOT/HelperSwift"
OUTPUT_BIN="$SWIFT_PKG_DIR/.build/release/cli_pulse_helper"

cd "$SWIFT_PKG_DIR"

# Cache check: rebuild when any source .swift is newer than the
# output. Swift Package Manager has its own incremental cache, but
# we still want to short-circuit when nothing changed so the Xcode
# incremental build stays sub-second.
if [[ -f "$OUTPUT_BIN" ]]; then
    NEED_REBUILD=0
    # v1.44: SensorProbe is scanned too, not just this package.
    #
    # `get_machine_snapshot` links SensorKit via a path dependency, so
    # SensorProbe's sources are now part of this binary. Scanning only
    # HelperSwift/Sources would report "cached output is fresh" after a SensorKit
    # edit, and Xcode's Copy Files phase would embed and CODE-SIGN the stale
    # binary — a wrong helper shipped with no error anywhere. SwiftPM's own
    # incremental build would have caught it; this short-circuit runs before
    # SwiftPM is ever invoked, which is exactly what makes it dangerous.
    SCAN_DIRS=("Sources")
    [[ -d "$PROJECT_ROOT/SensorProbe/Sources" ]] && SCAN_DIRS+=("$PROJECT_ROOT/SensorProbe/Sources")
    while IFS= read -r -d '' src; do
        if [[ "$src" -nt "$OUTPUT_BIN" ]]; then
            NEED_REBUILD=1
            break
        fi
    done < <(find "${SCAN_DIRS[@]}" -type f \( -name '*.swift' -o -name '*.c' -o -name '*.h' \) -print0)
    # Also check both manifests.
    if [[ "Package.swift" -nt "$OUTPUT_BIN" ]]; then NEED_REBUILD=1; fi
    if [[ -f "$PROJECT_ROOT/SensorProbe/Package.swift" \
          && "$PROJECT_ROOT/SensorProbe/Package.swift" -nt "$OUTPUT_BIN" ]]; then NEED_REBUILD=1; fi
    if [[ $NEED_REBUILD -eq 0 ]]; then
        echo "build_helper_swift.sh: cached output is fresh ($OUTPUT_BIN)"
        exit 0
    fi
fi

echo "build_helper_swift.sh: building $OUTPUT_BIN ..."
swift build -c release

if [[ ! -x "$OUTPUT_BIN" ]]; then
    echo "error: swift build did not produce $OUTPUT_BIN" >&2
    exit 1
fi

echo "build_helper_swift.sh: built $OUTPUT_BIN ($(du -h "$OUTPUT_BIN" | cut -f1))"

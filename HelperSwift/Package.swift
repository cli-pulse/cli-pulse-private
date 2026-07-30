// swift-tools-version: 5.9
//
// Phase 4D: Swift port of the cli_pulse_helper daemon.
//
// Replaces the PyInstaller-frozen Python helper that Phase 4C ships
// in `Contents/Helpers/cli_pulse_helper`. Same UDS protocol, same
// `~/.claude/settings.json` semantics, same Supabase RPC surface —
// the macOS app + iPhone app + paired-device Supabase contract all
// stay backward-compatible. The win is:
//
//   * No bundled Python interpreter (~12 MB → ~3 MB binary)
//   * No PyInstaller signing edge cases (allow-jit etc.)
//   * One language stack across the whole macOS surface; reviewer
//     fatigue from Python+Swift concurrency models drops
//   * Faster startup; Swift binaries cold-start in ~30 ms vs
//     PyInstaller's ~400 ms
//
// Layout:
//   - HelperKit (library): protocol, registry, broker, PTY,
//     Supabase RPC, redaction, settings.json install.
//   - cli_pulse_helper (executable): thin main.swift wrapping
//     HelperKit's `daemon` / `pair` / `heartbeat` / `sync` /
//     `inspect` / `remote-approval-hook` / `remote-approvals`
//     subcommands. Same CLI surface as the Python version so the
//     LaunchAgent plist and dev-time invocations don't change.
//   - HelperKitTests: XCTest port of the Python pytest suite.
//     Aim is parity, not 1:1 file structure — the Swift module
//     boundaries are different, so tests group differently.

import PackageDescription

let package = Package(
    name: "HelperSwift",
    platforms: [
        // Helper runs unsandboxed via launchd; can target the
        // newest stable macOS without breaking App Store reach
        // (the SANDBOXED app's deployment target stays the
        // CLIPulseCore-declared minimum).
        .macOS(.v13),
    ],
    products: [
        .library(name: "HelperKit", targets: ["HelperKit"]),
        .executable(name: "cli_pulse_helper", targets: ["cli_pulse_helper"]),
    ],
    dependencies: [
        // v1.44: `get_machine_snapshot` needs real sensor readings. SensorKit
        // already implements SMC / HID / IOReport correctly; rewriting that
        // here would be a second, worse copy of the hardest code in the repo.
        //
        // Path dependency, not versioned — `.unsafeFlags` below is only
        // permitted for local packages, and SensorKit cannot link without it.
        .package(path: "../SensorProbe"),
    ],
    targets: [
        .target(
            name: "HelperKit",
            dependencies: [
                .product(name: "SensorKit", package: "SensorProbe"),
            ]
        ),
        .executableTarget(
            name: "cli_pulse_helper",
            dependencies: ["HelperKit"],
            linkerSettings: [
                // SensorKit references private IOReport / IOHID symbols that
                // have no SDK stub, so they must resolve from the dyld shared
                // cache at runtime. SensorProbe puts these flags on its OWN
                // executable and test targets but NOT on the SensorKit library
                // target, so every consumer has to repeat them — omitting them
                // fails at link with 7 undefined `_IOReport*` symbols.
                //
                // Hardened runtime does not break this — measured, not argued:
                // a release build signed `--options runtime` launches and reads
                // real values (cpu_temp 61.7 C, fan 1666 RPM). `clipulse-sensors`
                // has shipped the same symbols under the same flag for releases.
                //
                // The difference here is blast radius: if this ever DID fail to
                // load, the whole helper dies rather than just sensors. So the
                // guard is the `Signed-helper dynamic_lookup smoke` step in
                // .github/workflows/swift-ci.yml, which signs and runs the
                // binary on every PR.
                //
                // The first version of that guard lived in
                // embed_helper_in_archive.sh and this comment claimed it was
                // "mandatory on both the MAS and DEVID paths". It was neither —
                // devid-dmg.yml never calls that script, and swift-ci mentioned
                // it only in a `paths:` filter. Naming the real job here is the
                // point: a guard that is only asserted, never run, is worse than
                // no guard, because the assertion gets quoted as evidence.
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
            ]
        ),
        .testTarget(
            name: "HelperKitTests",
            dependencies: ["HelperKit"],
            linkerSettings: [
                // The test bundle links HelperKit, which links SensorKit —
                // without these, `swift test` fails at link in CI.
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
            ]
        ),
    ]
)

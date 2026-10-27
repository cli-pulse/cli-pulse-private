// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CLIPulseCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "CLIPulseCore",
            targets: ["CLIPulseCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0")
        // CodexBar-parity G1: SweetCookieKit (MIT, steipete) is NOT an SPM
        // dependency — its Package.swift requires swift-tools 6.2 while CI
        // runs Swift 6.1, which would block clean resolution. The source is
        // vendored under Sources/CLIPulseCore/Vendor/SweetCookieKit/ (each
        // file `#if os(macOS)`-wrapped). sqlite3 is linked on macOS below.
    ],
    targets: [
        // zstd's single-file decoder, for the Codex sessions the Codex CLI
        // archives as `rollout-*.jsonl.zst` (1.59.1, N1). Vendored unmodified:
        //   zstddeclib.c   generated from the official v1.5.7 release
        //                  (https://github.com/facebook/zstd/releases/tag/v1.5.7,
        //                  zstd-1.5.7.tar.gz, sha256 eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3)
        //                  by its build/single_file_libs/create_single_file_decoder.sh
        //                  (`combine.py -r lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c`)
        //   include/zstd.h, include/zstd_errors.h, LICENSE   copied from that release
        // zstd is dual-licensed BSD-3-Clause / GPLv2; CLI Pulse uses it under
        // the BSD license (LICENSE, and ThirdPartyNotices.txt). Decoding only:
        // no compressor, no legacy formats. Linked on macOS only, the one
        // platform that reads Codex logs.
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            exclude: ["LICENSE"],
            sources: ["zstddeclib.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CLIPulseCore",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
                .target(name: "CZstd", condition: .when(platforms: [.macOS]))
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // Required by the vendored SweetCookieKit cookie-DB reader
                // (macOS only — guarded by `#if os(macOS)` in source).
                .linkedLibrary("sqlite3", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "CLIPulseCoreTests",
            dependencies: ["CLIPulseCore"]
        ),
    ]
)

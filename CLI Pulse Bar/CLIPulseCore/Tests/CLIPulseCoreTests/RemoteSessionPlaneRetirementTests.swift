import XCTest
@testable import CLIPulseCore

/// Phase C — the remote SESSION plane is retired in the app.
///
/// The plane is: start a CLI session on another device, stream its terminal,
/// approve its tool-permission prompts. Production, 2026-08-30:
/// `remote_sessions` 4 (all the owner's), `remote_session_commands` 0,
/// `remote_permission_requests` 0, `app_push_jobs` 0.
///
/// The tests that matter here are the ones about what is NOT retired.
/// `remote_control_enabled` also authorises machine controls — fan target, low
/// power mode, keep-awake — which work and have been used (`machine_commands`:
/// 5 rows, all `done`). Retiring the setting instead of the plane would have
/// killed a live feature.
final class RemoteSessionPlaneRetirementTests: XCTestCase {

    @MainActor
    func test_theSessionPlaneIsOffEvenWhenTheUserSettingIsOn() {
        let state = AppState()
        state.remoteControlEnabled = true

        XCTAssertFalse(state.remoteSessionsEnabled,
                       "the session plane is retired regardless of the user setting")
        XCTAssertTrue(state.remoteControlEnabled,
                      "the setting itself must survive — it still gates machine controls")
    }

    /// The predicate is a CONJUNCTION, not a hard-coded `false`. If the plane
    /// is ever re-enabled, the user's own opt-in must still govern; a flag that
    /// short-circuits the consent check would be a different and worse change.
    @MainActor
    func test_thePredicateStillHonoursTheUserSetting() {
        let state = AppState()
        state.remoteControlEnabled = false
        XCTAssertFalse(state.remoteSessionsEnabled)

        // Both inputs false today, so the asymmetry is only visible in the
        // expression itself — which is exactly what this pins.
        state.remoteControlEnabled = true
        XCTAssertEqual(state.remoteSessionsEnabled,
                       RemoteSessionPlane.isEnabled && state.remoteControlEnabled)
    }

    /// v1.52.1 deleted the remote session plane's surfaces outright rather than
    /// hiding them: the approvals UI (`RemoteApprovalsSheet`,
    /// `iOSRemoteApprovalsView`, `RemoteApprovalsEntryState`) and then the iOS
    /// terminal + managed-session UI (`RemoteTerminalView` and its
    /// representable and key bar, `RemoteSessionEventStream`,
    /// `RemoteSessionControlClient`, `ManagedSessionDetailView`).
    ///
    /// This has to be a source scan. The deleted types cannot be named in Swift
    /// — the test would not compile — and several lived in app targets that have
    /// no test bundle at all, which is exactly how the Swarm tab shipped visible
    /// for thirty versions while its release notes called it dark. A grep is the
    /// only assertion that reaches them.
    ///
    /// NOTE the near-misses this list is written around. `TerminalView`,
    /// `TerminalAttachView`, `TerminalSessionAdapter` and
    /// `TerminalNavigationGuard` are the LIVE macOS local in-app terminal and
    /// must never appear below — `TerminalNavigationGuard` in particular is the
    /// control that stops a crafted escape sequence navigating that WebView off
    /// its bundle. Matching on "Terminal" instead of the full symbol names would
    /// have deleted a security control from a working feature.
    func test_theRetiredPlanesSurfacesAreGoneFromEverySource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .deletingLastPathComponent()   // CLI Pulse Bar
        let dirs = ["CLI Pulse Bar", "CLI Pulse Bar iOS", "CLIPulseCore/Sources/CLIPulseCore"]

        var scanned = 0
        var sawLivingSymbol = false
        for dir in dirs {
            let base = root.appendingPathComponent(dir)
            let files = try FileManager.default
                .contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            XCTAssertFalse(files.isEmpty, "no sources under \(dir) — the scan path is wrong")
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                if text.contains("RemoteSessionPlane") { sawLivingSymbol = true }
                for dead in Self.deletedSymbols {
                    XCTAssertFalse(
                        text.contains(dead),
                        "\(file.lastPathComponent) still references \(dead)"
                    )
                }
            }
        }

        // Positive controls. Without these a mistyped path, an empty directory
        // or a scanner that reads nothing would pass silently — the failure
        // mode this repo has already shipped four times.
        XCTAssertGreaterThan(scanned, 50, "scanned too few files to be believable")
        XCTAssertTrue(sawLivingSymbol,
                      "the scanner never matched a symbol that DOES exist, so its "
                      + "negative findings prove nothing")
    }

    /// Every symbol the retirement removed. Kept as one list so the scan above
    /// and the file check below cannot drift apart.
    static let deletedSymbols = [
        // approvals (PR #501)
        "RemoteApprovalsSheet", "iOSRemoteApprovalsView", "RemoteApprovalsEntryState",
        // iOS terminal + managed sessions (PR #502).
        //
        // `RemoteTerminalView` itself is NOT here any more: remote-control M0
        // restored it, byte-for-byte from e067c4fb1^, as the WKWebView host
        // for the LAN transport. It never touched the cloud plane — only its
        // Representable did, which stays listed. A WebView that renders
        // xterm.js is transport-agnostic; the retirement deleted it for lack
        // of a consumer, not because it was part of the plane.
        "RemoteTerminalViewRepresentable", "RemoteTerminalKeyBar",
        "RemoteSessionEventStream", "RemoteSessionControlClient", "ManagedSessionDetailView",
    ]

    /// The symbol scan cannot see Kotlin, and it cannot see a file that has been
    /// re-added but not yet referenced. This checks the paths directly, so a
    /// revert shows up as a failure the moment the file lands.
    func test_theDeletedFilesAreStillDeleted() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()   // repo root

        let gone = [
            "CLI Pulse Bar/CLI Pulse Bar/RemoteApprovalsSheet.swift",
            "CLI Pulse Bar/CLI Pulse Bar iOS/iOSRemoteApprovalsView.swift",
            "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/RemoteApprovalsEntryState.swift",
            // RemoteTerminalView.swift is deliberately absent — see deletedSymbols.
            "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/RemoteTerminalViewRepresentable.swift",
            "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/RemoteTerminalKeyBar.swift",
            "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/RemoteSessionEventStream.swift",
            "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/RemoteSessionControlClient.swift",
            // Android (PR #503) — unreachable from any Swift symbol scan.
            "android/app/src/main/java/com/clipulse/android/terminal/RemoteTerminalPanel.kt",
            "android/app/src/main/java/com/clipulse/android/ui/sessions/ManagedSessionsScreen.kt",
            "android/app/src/main/java/com/clipulse/android/ui/sessions/ManagedSessionsViewModel.kt",
            "android/app/src/main/java/com/clipulse/android/data/model/RemoteSession.kt",
            "android/app/src/main/assets/terminal/xterm.js",
        ]
        for path in gone {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                "\(path) is back — the retirement was reverted"
            )
        }

        // Positive controls, one per platform, so a wrong repo root cannot make
        // every path "absent" and pass. These are the LIVE local terminal and a
        // live Android source: if either is missing, the root is wrong (or
        // something far worse happened) and the absences above prove nothing.
        for alive in [
            "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/TerminalView.swift",
            "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/TerminalNavigationGuard.swift",
            "android/app/src/main/java/com/clipulse/android/ui/sessions/SessionsScreen.kt",
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(alive).path),
                "\(alive) is missing — the repo root is wrong, so the absence "
                + "assertions above are vacuous"
            )
        }
    }

    /// DRIFT GUARD. `RemoteSessionPlane` is duplicated in HelperKit because the
    /// two SwiftPM packages cannot import each other. A copied constant without
    /// a drift gate is how a retired feature comes back on one side only — the
    /// app hiding its UI while the helper keeps polling once a second, or the
    /// reverse.
    func test_theHelperCopyOfTheFlagAgrees() throws {
        let helperSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .deletingLastPathComponent()   // CLI Pulse Bar
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("HelperSwift/Sources/HelperKit/RemoteSessionPlane.swift")
        let text = try String(contentsOf: helperSource, encoding: .utf8)

        let line = try XCTUnwrap(
            text.split(separator: "\n").first { $0.contains("static let isEnabled") },
            "the helper's RemoteSessionPlane.isEnabled declaration moved"
        )
        let helperValue = line.contains("= true")
        XCTAssertEqual(
            helperValue, RemoteSessionPlane.isEnabled,
            "app and helper disagree about whether the session plane is on"
        )
    }

    /// The switch now authorises ONLY machine requests, so its label may not go
    /// on describing the retired plane. This is the same class of defect the
    /// telemetry disclosure guard covers: consent copy that outlived the thing
    /// it described.
    func test_theToggleCopyNoLongerSellsTheRetiredPlane() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("en")

        let label = L10n.advanced.remoteControl
        let hint = L10n.advanced.remoteControlHint

        for forbidden in ["approval", "approve", "Claude", "session", "terminal"] {
            XCTAssertFalse(label.lowercased().contains(forbidden.lowercased()),
                           "the toggle label still promises \"\(forbidden)\": \(label)")
            XCTAssertFalse(hint.lowercased().contains(forbidden.lowercased()),
                           "the toggle hint still promises \"\(forbidden)\": \(hint)")
        }
        // …and still says what it DOES do, so the test cannot pass by the copy
        // having been emptied.
        XCTAssertTrue(hint.lowercased().contains("fan"))
    }

    /// The consent body must disclose the withdrawal rather than silently drop
    /// it — someone who opted in for approvals deserves to be told those are
    /// gone, in every language that carries the string.
    func test_everyLocaleDisclosesTheWithdrawal() throws {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }

        for locale in ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"] {
            LocaleOverrideStore.shared.set(locale)
            let body = L10n.advanced.remoteConsentBody
            XCTAssertFalse(body.isEmpty)
            XCTAssertFalse(body.hasPrefix("advanced."), "\(locale) renders the raw key")
            XCTAssertTrue(body.contains("\n"), "\(locale): the \\n escapes did not resolve")
            // Every translation names the fan, which is the capability that
            // replaced the retired one.
            let mentionsFan = ["fan", "ventilador", "ファン", "팬", "风扇", "風扇"]
                .contains { body.lowercased().contains($0.lowercased()) }
            XCTAssertTrue(mentionsFan, "\(locale) consent body does not describe machine requests")
        }
    }

    /// Copy that outlived the feature it described.
    ///
    /// `SessionsTab` branches on `shouldRouteSessionLocally`. That predicate
    /// used to separate "local row" from "remote row"; with the plane retired
    /// `remoteSessions` is permanently empty, so every rendered row is local
    /// and the false branch means only one thing: **the helper stopped
    /// answering**. `refreshLocalSessionControlState` returns early on a
    /// `hello()` failure WITHOUT clearing `localManagedSessions` (the clear is
    /// in the gate-off branch, reached only when hello succeeded), so those
    /// stale rows keep rendering and land there.
    ///
    /// The copy had not caught up. It told that user "Remote Control is off —
    /// output won't stream" and offered "⌘↩ to approve pending" — a switch that
    /// could not help and an action that could not run.
    ///
    /// This is a source scan for the same reason as the test above: the strings
    /// live in an app target with no test bundle.
    func test_theDeadHelperStateDoesNotBlameRemoteControl() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CLI Pulse Bar/SessionsTab.swift")
        let text = try String(contentsOf: file, encoding: .utf8)

        // Scan CODE only. The first version of this test matched comments too
        // and failed on the comment that documents the very change it guards —
        // a guard cannot forbid explaining itself.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for dead in ["Remote Control is off — output won't stream",
                     "⌘↩ to approve pending"] {
            XCTAssertFalse(code.contains(dead),
                           "SessionsTab still tells a helper-down user: \(dead)")
        }

        // Positive controls. Without these a renamed file or a bad path would
        // make both absences vacuous — the failure mode this repo keeps hitting.
        XCTAssertTrue(code.contains("can't reach the helper"),
                      "the replacement copy is missing — wrong file?")
        XCTAssertTrue(code.contains("shouldRouteSessionLocally"),
                      "this is not SessionsTab; the scan path is wrong")
        // …and the comment-stripping must not have eaten the file.
        XCTAssertGreaterThan(code.count, text.count / 2,
                             "comment filter removed too much to be a real scan")
    }
}

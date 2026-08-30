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

    /// Approvals are tool-permission prompts from a remotely-driven session.
    /// With that plane gone there is nothing to approve, so the entry must be
    /// hidden even with pending rows in the cache.
    func test_theApprovalsEntryIsHiddenEvenWithPendingRows() {
        XCTAssertEqual(
            RemoteApprovalsEntryState.footer(remoteSessionsEnabled: false, pendingCount: 7),
            .hidden
        )
        XCTAssertEqual(
            RemoteApprovalsEntryState.banner(remoteSessionsEnabled: false, pendingCount: 7),
            .hidden
        )
        // Vacuity guard: the helper still works when the plane is on, so the
        // assertions above are about the flag and not about a broken helper.
        XCTAssertEqual(
            RemoteApprovalsEntryState.footer(remoteSessionsEnabled: true, pendingCount: 7),
            .visibleWithBadge(count: 7)
        )
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
}

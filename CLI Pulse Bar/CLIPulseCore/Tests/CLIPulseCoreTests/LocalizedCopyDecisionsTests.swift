import XCTest
@testable import CLIPulseCore

/// Pins three localization fixes whose failure mode is silent: nothing crashes,
/// a user just sees English, or the wrong advice, again.
final class LocalizedCopyDecisionsTests: XCTestCase {

    #if os(macOS)
    /// The folder-access rows are localized at render time, keyed by the stable id.
    /// A renamed id would quietly fall back to the English table title — so check
    /// every localized id still names a real row, and product names stay as written.
    func testEveryLocalizedFolderRowStillMatchesARealDirectory() {
        // Assert in a locale where the translation differs from the English table
        // title. In English they are the same text, so an English-only check passed
        // with the id lookup deliberately broken (a typo'd `case "codex-session"`) —
        // the negative control caught this test testing nothing.
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set("zh-Hans")
        defer { store.set(previous) }

        let expected: [String: String] = [
            "clipulse-config": L10n.folderAccess.dirClipulseConfig,
            "clipulse-data": L10n.folderAccess.dirClipulseData,
            "codex-sessions": L10n.folderAccess.dirCodexSessionLogs,
            "codex-archived-sessions": L10n.folderAccess.dirCodexArchivedLogs,
            "claude-projects": L10n.folderAccess.dirClaudeSessionLogs,
        ]
        for (id, title) in expected {
            let dir = BookmarkManager.knownDirectories.first { $0.id == id }
            XCTAssertNotNil(dir, "no known directory has id \(id) — the localized title is unreachable")
            XCTAssertEqual(dir?.localizedDisplayName, title)
            XCTAssertNotEqual(dir?.localizedDisplayName, dir?.displayName,
                              "\(id) still shows its English table title in zh-Hans")
        }
        XCTAssertEqual(
            BookmarkManager.knownDirectories.first { $0.id == "codex" }?.localizedDisplayName, "Codex CLI",
            "product-name rows keep their written title")
    }
    #endif

    /// register_helper returns English text with a stable code. Known codes are
    /// localized; a code the app has never seen must keep the server's own
    /// wording rather than degrading to a generic or empty message.
    func testKnownPairingCodesAreLocalizedAndUnknownCodesKeepTheServerMessage() {
        let known: [(String, String)] = [
            ("invalid_code", L10n.pairing.errorInvalidCode),
            ("expired", L10n.pairing.errorCodeExpired),
            ("rate_limited", L10n.pairing.errorRateLimited),
            ("too_many_failed_attempts", L10n.pairing.errorTooManyAttempts),
        ]
        for (code, localized) in known {
            XCTAssertEqual(
                HelperAPIError.pairingRejected(code: code, message: "server text").errorDescription, localized)
        }
        XCTAssertEqual(
            HelperAPIError.pairingRejected(code: "some_future_code", message: "Server wording").errorDescription,
            "Server wording")
    }

    /// The first version of this message told users to check "local session
    /// control" — a name no toggle on screen has. It now interpolates the toggle's
    /// own localized title, so the two cannot drift apart again.
    func testHelperUnavailableMessageNamesTheToggleUsersCanSee() {
        let toggle = L10n.sessions.localFastPathTitle
        let message = L10n.sessions.actionHelperUnavailable(toggle)
        XCTAssertTrue(message.contains(toggle), "message does not name the \(toggle) toggle: \(message)")
        XCTAssertFalse(message.contains("%"), "an unfilled format specifier leaked: \(message)")
    }
}

#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.55: Strict privacy mode means CLI Pulse uses no other app's secret it
/// did not get from the user. The Companion CLI decrypts a claude.ai
/// `sessionKey` from a browser's or the Claude desktop app's cookie store and
/// writes it to `claude_session.json` for the app. The app, and the LoginItem
/// helper that runs the same collectors, kept reading that file and sending
/// the cookie to claude.ai whatever the switch said, including a file a
/// Companion 1.30.0 (which ignores the switch) keeps rewriting.
final class ClaudeHelperSessionKeyStrictModeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `claude_session.json` as `system_collector._write_claude_session_key`
    /// writes it.
    private func sessionFile(_ key: String, name: String = "claude_session.json") throws -> String {
        let url = dir.appendingPathComponent(name)
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionKey": key, "source": "chrome:Default", "fetched_at": "2026-10-01T00:00:00Z",
        ])
        try data.write(to: url)
        return url.path
    }

    func test_strictPrivacyMode_doesNotUseTheCookieTheCompanionCopied() throws {
        let group = try sessionFile("sk-ant-sid01-GROUP", name: "group.json")
        let legacy = try sessionFile("sk-ant-sid01-LEGACY", name: "legacy.json")
        XCTAssertNil(ClaudeWebStrategy.helperSessionKey(strictPrivacyMode: true, paths: [group, legacy]))
        // Negative control: the same files are read, in order, with the switch off.
        XCTAssertEqual(ClaudeWebStrategy.helperSessionKey(strictPrivacyMode: false, paths: [group, legacy]),
                       "sk-ant-sid01-GROUP")
        XCTAssertEqual(ClaudeWebStrategy.helperSessionKey(strictPrivacyMode: false, paths: [dir.appendingPathComponent("missing").path, legacy]),
                       "sk-ant-sid01-LEGACY")
    }

    func test_theProductionReadAsksTheSwitchFirst() {
        let saved = ClaudeWebStrategy.strictPrivacyModeSkipsHelperSessionKey
        defer { ClaudeWebStrategy.strictPrivacyModeSkipsHelperSessionKey = saved }
        var asked = 0
        ClaudeWebStrategy.strictPrivacyModeSkipsHelperSessionKey = {
            asked += 1
            return true
        }
        XCTAssertNil(ClaudeWebStrategy.findSessionKeyFromFile())
        XCTAssertEqual(asked, 1)
    }

    /// The production seam follows the real switch when no test replaces it
    /// (in the LoginItem helper, `PrivacySettings.shared` follows the app's
    /// copy of it).
    func test_theDefaultSeam_followsTheRealSwitch() {
        let shared = PrivacySettings.shared
        let (strict, skip) = (shared.localOnlyMode, shared.skipClaudeKeychain)
        defer {
            shared.localOnlyMode = strict
            shared.skipClaudeKeychain = skip
        }
        shared.localOnlyMode = false
        XCTAssertFalse(ClaudeWebStrategy.strictPrivacyModeSkipsHelperSessionKey())
        shared.localOnlyMode = true
        XCTAssertTrue(ClaudeWebStrategy.strictPrivacyModeSkipsHelperSessionKey())
    }
}
#endif

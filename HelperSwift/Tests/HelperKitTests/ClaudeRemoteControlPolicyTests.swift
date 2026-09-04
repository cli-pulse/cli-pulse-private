import XCTest
@testable import HelperKit

/// Remote-control M1a — "is Remote Control allowed by policy on this Mac?"
/// answered BEFORE spawning, so the phone can hide the delegation toggle
/// instead of offering it and failing. Claude Code's key is
/// `disableRemoteControl` (read out of the 2.1.259 binary); any settings
/// file in its precedence chain setting it true disables the feature.
final class ClaudeRemoteControlPolicyTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipulse-rc-policy-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ json: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try json.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func testNoFilesMeansAllowed() {
        XCTAssertEqual(ClaudeRemoteControlPolicy.evaluate(settingsFiles: [dir.appendingPathComponent("absent.json")]), .allowed)
    }

    func testDisableKeyTrueInAnyFileDisables() throws {
        let user = try write("settings.json", #"{"model":"opus"}"#)
        let managed = try write("managed-settings.json", #"{"disableRemoteControl": true}"#)
        XCTAssertEqual(ClaudeRemoteControlPolicy.evaluate(settingsFiles: [user, managed]), .disabled)
        XCTAssertEqual(ClaudeRemoteControlPolicy.evaluate(settingsFiles: [managed, user]), .disabled)
    }

    func testDisableKeyFalseOrAbsentStaysAllowed() throws {
        let a = try write("a.json", #"{"disableRemoteControl": false}"#)
        let b = try write("b.json", #"{"permissions": {"allow": []}}"#)
        XCTAssertEqual(ClaudeRemoteControlPolicy.evaluate(settingsFiles: [a, b]), .allowed)
    }

    func testUnreadableOrMalformedFileIsNotADisable() throws {
        // Negative control on the fail direction: a broken settings file
        // must not hide the feature (that would be a silent regression
        // for everyone with a stray comma), and must not enable it past a
        // real managed disable either.
        let broken = try write("broken.json", "{ not json")
        XCTAssertEqual(ClaudeRemoteControlPolicy.evaluate(settingsFiles: [broken]), .allowed)
        let managed = try write("managed-settings.json", #"{"disableRemoteControl": true}"#)
        XCTAssertEqual(ClaudeRemoteControlPolicy.evaluate(settingsFiles: [broken, managed]), .disabled)
    }

    func testStringTrueIsNotTrue() throws {
        // Claude Code reads a boolean; a string "true" is not a disable.
        let s = try write("s.json", #"{"disableRemoteControl": "true"}"#)
        XCTAssertEqual(ClaudeRemoteControlPolicy.evaluate(settingsFiles: [s]), .allowed)
    }

    func testDefaultChainIsUserLocalAndManaged() {
        let chain = ClaudeRemoteControlPolicy.defaultSettingsFiles(home: "/Users/x")
        XCTAssertEqual(chain.map(\.path), [
            "/Users/x/.claude/settings.json",
            "/Users/x/.claude/settings.local.json",
            "/Library/Application Support/ClaudeCode/managed-settings.json",
        ])
    }

    func testWireValueIsStable() {
        XCTAssertEqual(ClaudeRemoteControlPolicy.allowed.rawValue, "allowed")
        XCTAssertEqual(ClaudeRemoteControlPolicy.disabled.rawValue, "disabled")
    }
}

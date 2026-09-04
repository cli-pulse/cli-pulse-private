import XCTest
@testable import HelperKit

/// Remote-control M1a — the helper must exec the SAME binary it said was
/// available.
///
/// Measured 2026-09-04 on the owner's Mac: the LaunchAgent's PATH is
/// `/usr/bin:/bin:/usr/sbin:/sbin`; `claude` lives in `~/.local/bin`.
/// `defaultIsAvailable()` searched the AUGMENTED path and said yes; the
/// spawn passed a bare `claude` to `posix_spawnp`, which searches the
/// PARENT's PATH — so every managed Claude/Codex session failed to start
/// while the picker offered them. These tests pin the fix: argv[0] is
/// resolved to an absolute path through the same augmented search.
final class SpawnPathResolutionTests: XCTestCase {

    /// A spawner that resolves its binary the way the shipped ones do,
    /// with the environment and home injected so the test controls
    /// exactly which directories exist on which PATH.
    struct PathSpawner: ProviderSpawner {
        let name: String
        let env: [String: String]
        let home: String?
        func isAvailable() -> Bool { true }
        func argv(extraEnv: [String: String], helperArgv0: String?) -> [String] {
            defaultArgv0(env: env, home: home)
        }
        func supportsRemoteApproval() -> Bool { false }
    }

    private var tmpHome: URL!
    private var binDir: URL!
    private var toolName = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipulse-m1-home-\(UUID().uuidString.prefix(8))")
        binDir = tmpHome.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        toolName = "clipulse-m1-fake-\(UUID().uuidString.prefix(6))"
        let script = binDir.appendingPathComponent(toolName)
        try "#!/bin/sh\necho \"M1_FAKE_CLI_OK argv0=$0\"\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        try super.tearDownWithError()
    }

    /// The bare launchd PATH the helper actually runs with.
    private let bareEnv = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    // MARK: - Pure resolution

    func testFindOnPathSearchesTheAugmentedDirsWithTheInjectedHome() {
        let found = ClaudeSpawner.findOnPath(toolName, env: bareEnv, home: tmpHome.path)
        XCTAssertEqual(found, binDir.appendingPathComponent(toolName).path)
    }

    func testFindOnPathReturnsNilWhenTheBinaryIsNowhere() {
        // Negative control: same environment, a name that exists in no
        // searched directory. If this ever returns non-nil the positive
        // test above is proving nothing.
        XCTAssertNil(ClaudeSpawner.findOnPath("clipulse-does-not-exist-\(UUID().uuidString)", env: bareEnv, home: tmpHome.path))
        // And a home whose `.local/bin` does not hold the tool.
        XCTAssertNil(ClaudeSpawner.findOnPath(toolName, env: bareEnv, home: "/nonexistent-home"))
    }

    func testDefaultArgv0IsAbsoluteWhenResolvableAndBareOtherwise() {
        let s = PathSpawner(name: toolName, env: bareEnv, home: tmpHome.path)
        XCTAssertEqual(s.argv(extraEnv: [:], helperArgv0: nil), [binDir.appendingPathComponent(toolName).path])
        // Unresolvable ⇒ unchanged legacy behaviour (bare name), so the
        // spawn error names the missing binary rather than a nil.
        let missing = PathSpawner(name: "clipulse-missing-\(UUID().uuidString.prefix(6))", env: bareEnv, home: tmpHome.path)
        XCTAssertEqual(missing.argv(extraEnv: [:], helperArgv0: nil), [missing.name])
    }

    func testExplicitArgv0OverrideStillWins() {
        let s = PathSpawner(name: toolName,
                            env: ["PATH": "/usr/bin:/bin", "CLI_PULSE_\(toolName.uppercased())_ARGV0": "/opt/x/tool --flag"],
                            home: tmpHome.path)
        XCTAssertEqual(s.argv(extraEnv: [:], helperArgv0: nil), ["/opt/x/tool", "--flag"])
    }

    // MARK: - Through the manager (real PTY)

    /// THE regression: a binary that exists only in `<home>/.local/bin`,
    /// with the parent process on the bare launchd PATH, must spawn.
    func testManagedSessionSpawnsABinaryThatIsOnlyOnTheAugmentedPath() throws {
        let registry = ProviderSpawnerRegistry(spawners: [
            PathSpawner(name: toolName, env: bareEnv, home: tmpHome.path),
        ])
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: registry)
        let summary = try manager.startSession(provider: toolName, clientLabel: "m1-test")
        defer { _ = manager.stopSession(summary.sessionId) }

        var seen = ""
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let d = manager.getTailSnapshot(sessionId: summary.sessionId, maxBytes: 4096) {
                seen = String(decoding: d, as: UTF8.self)
                if seen.contains("M1_FAKE_CLI_OK") { break }
            }
            usleep(50_000)
        }
        XCTAssertTrue(seen.contains("M1_FAKE_CLI_OK"), "fake CLI never ran; tail: \(seen)")
        XCTAssertTrue(seen.contains("argv0=\(binDir.appendingPathComponent(toolName).path)"),
                      "the child must have been exec'd by absolute path; tail: \(seen)")
    }

    /// Negative control for the mechanism: hand the manager a BARE name
    /// that is not on the parent's PATH and the spawn fails — that is the
    /// bug, reproduced on purpose, so the positive test above cannot pass
    /// for the wrong reason (e.g. the test process's own PATH happening to
    /// contain the directory).
    func testBareNameOffTheParentPathDoesNotSpawn() {
        struct BareSpawner: ProviderSpawner {
            let name: String
            func isAvailable() -> Bool { true }
            func argv(extraEnv: [String: String], helperArgv0: String?) -> [String] { [name] }
            func supportsRemoteApproval() -> Bool { false }
        }
        let registry = ProviderSpawnerRegistry(spawners: [BareSpawner(name: toolName)])
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: registry)
        XCTAssertThrowsError(try manager.startSession(provider: toolName, clientLabel: "m1-test")) { e in
            guard case ManagedSessionManager.ManagerError.spawnFailed = e else {
                return XCTFail("expected spawnFailed, got \(e)")
            }
        }
    }
}

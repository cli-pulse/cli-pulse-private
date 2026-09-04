import XCTest
@testable import HelperKit

/// Remote-control M1a — delegation end to end inside the helper: the
/// `claude_remote_control` start flag becomes `--remote-control`, the
/// drain loop feeds the banner scanner, and the outcome reaches the
/// session row, the event stream, and (policy) the hello reply.
///
/// The "claude" binary here is a shell script that prints whatever banner
/// the test wants — the real CLI on the dev Mac is not logged in, so the
/// positive path is exercised against the contract, not a recording.
final class RemoteControlDelegationTests: XCTestCase {

    private var tmp: URL!
    private let url = "https://claude.ai/code/019a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipulse-m1-rc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    /// A fake `claude` that records its argv and prints `banner`.
    private func fakeClaude(printing banner: String) throws -> String {
        let script = tmp.appendingPathComponent("claude")
        let argvLog = tmp.appendingPathComponent("argv.txt").path
        let body = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argvLog)'\nprintf '\(banner)'\nsleep 5\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func recordedArgv() -> [String] {
        (try? String(contentsOf: tmp.appendingPathComponent("argv.txt"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    private func registry(claudePath: String) -> ProviderSpawnerRegistry {
        ProviderSpawnerRegistry(spawners: [
            ClaudeSpawner(buildInlineSettings: nil, environment: ["CLI_PULSE_CLAUDE_ARGV0": claudePath]),
        ])
    }

    private func waitForRemoteControl(_ manager: ManagedSessionManager, _ sid: String,
                                      timeout: TimeInterval = 4) -> ManagedSessionManager.RemoteControlSummary? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let rc = manager.listSessions().first(where: { $0.sessionId == sid })?.remoteControl,
               rc.status != "requested" { return rc }
            usleep(50_000)
        }
        return manager.listSessions().first(where: { $0.sessionId == sid })?.remoteControl
    }

    // MARK: - Spawner

    func testFlagAppendsRemoteControlOnlyWhenRequested() {
        let s = ClaudeSpawner(buildInlineSettings: nil, environment: ["CLI_PULSE_CLAUDE_ARGV0": "/x/claude"])
        XCTAssertEqual(s.argv(extraEnv: [:], helperArgv0: nil), ["/x/claude"])
        XCTAssertEqual(s.argv(extraEnv: [ClaudeSpawner.remoteControlEnvKey: "1"], helperArgv0: nil),
                       ["/x/claude", "--remote-control"])
        // Anything but "1" is not a request — an env var that leaked in
        // from the user's shell must not silently ship transcripts.
        XCTAssertEqual(s.argv(extraEnv: [ClaudeSpawner.remoteControlEnvKey: "true"], helperArgv0: nil), ["/x/claude"])
        XCTAssertEqual(s.argv(extraEnv: [ClaudeSpawner.remoteControlEnvKey: "0"], helperArgv0: nil), ["/x/claude"])
    }

    // MARK: - Manager

    func testRequestedSessionSpawnsWithTheFlagAndPublishesTheURL() throws {
        let path = try fakeClaude(printing: "\\033[32m✓\\033[39m connected\\n  see this session at\\n  \(url)\\n  space to show QR code\\n")
        let broker = EventBroker()
        var events: [[String: Any]] = []
        let lock = NSLock()
        broker.subscribe(sessionFilter: nil) { e in
            if (e["event"] as? String) == "session_remote_control" { lock.lock(); events.append(e); lock.unlock() }
        }
        let manager = ManagedSessionManager(transport: PtyTransport(), broker: broker, providerRegistry: registry(claudePath: path))
        let summary = try manager.startSession(provider: "claude", clientLabel: "t", claudeRemoteControl: true)
        defer { _ = manager.stopSession(summary.sessionId) }

        XCTAssertEqual(summary.remoteControl?.status, "requested")
        let rc = waitForRemoteControl(manager, summary.sessionId)
        XCTAssertEqual(rc?.status, "ready")
        XCTAssertEqual(rc?.url, url)
        XCTAssertNil(rc?.reason)
        XCTAssertEqual(recordedArgv(), ["--remote-control"])

        lock.lock(); let seen = events; lock.unlock()
        XCTAssertEqual(seen.count, 1, "exactly one outcome event")
        XCTAssertEqual(seen.first?["session_id"] as? String, summary.sessionId)
        XCTAssertEqual(seen.first?["status"] as? String, "ready")
        XCTAssertEqual(seen.first?["url"] as? String, url)
    }

    func testRefusalBecomesUnavailableWithReason() throws {
        let path = try fakeClaude(printing: "Remote Control is disabled by your organization'\"'\"'s policy. Contact your organization admin for access.\\n")
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: registry(claudePath: path))
        let summary = try manager.startSession(provider: "claude", clientLabel: "t", claudeRemoteControl: true)
        defer { _ = manager.stopSession(summary.sessionId) }
        let rc = waitForRemoteControl(manager, summary.sessionId)
        XCTAssertEqual(rc?.status, "unavailable")
        XCTAssertEqual(rc?.reason, "disabled_by_policy")
        XCTAssertNil(rc?.url)
    }

    func testNotRequestedMeansNoFlagAndNoRemoteControlState() throws {
        // Negative control: the default must be OFF. A session started
        // without the flag never carries a transcript to Anthropic.
        let path = try fakeClaude(printing: "  see this session at \(url)\\n")
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: registry(claudePath: path))
        let summary = try manager.startSession(provider: "claude", clientLabel: "t")
        defer { _ = manager.stopSession(summary.sessionId) }
        usleep(300_000)
        XCTAssertEqual(recordedArgv(), [])
        XCTAssertNil(summary.remoteControl)
        XCTAssertNil(manager.listSessions().first?.remoteControl,
                     "a URL printed by a session that did not ask for remote control is not picked up")
    }

    func testFlagIsIgnoredForOtherProviders() throws {
        struct Echo: ProviderSpawner {
            let name = "codex"
            func isAvailable() -> Bool { true }
            func argv(extraEnv: [String: String], helperArgv0: String?) -> [String] { ["/bin/sh", "-c", "sleep 5"] }
            func supportsRemoteApproval() -> Bool { false }
        }
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: ProviderSpawnerRegistry(spawners: [Echo()]))
        let summary = try manager.startSession(provider: "codex", clientLabel: "t", claudeRemoteControl: true)
        defer { _ = manager.stopSession(summary.sessionId) }
        XCTAssertNil(summary.remoteControl)
    }

    func testNoBannerBeforeTheDeadlineIsATimeout() throws {
        let path = try fakeClaude(printing: "just a prompt ❯ \\n")
        var cfg = ManagedSessionManager.Config()
        cfg.remoteControlBannerDeadlineSeconds = 0.4
        let manager = ManagedSessionManager(transport: PtyTransport(), config: cfg, providerRegistry: registry(claudePath: path))
        let summary = try manager.startSession(provider: "claude", clientLabel: "t", claudeRemoteControl: true)
        defer { _ = manager.stopSession(summary.sessionId) }
        let rc = waitForRemoteControl(manager, summary.sessionId, timeout: 3)
        XCTAssertEqual(rc?.status, "unavailable")
        XCTAssertEqual(rc?.reason, "timeout")
    }
}

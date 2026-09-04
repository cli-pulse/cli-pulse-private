import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// Remote-control M1a — the additive wire fields as a UDS client sees them:
/// hello's `claude_remote_control`, `start_session`'s flag, and the
/// `remote_control` row on `list_sessions`.
final class RemoteControlServerWireTests: XCTestCase {

    private var dir: URL!
    private var server: LocalSessionServer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let parent = FileManager.default.fileExists(atPath: "/tmp") ? "/tmp" : NSTemporaryDirectory()
        dir = URL(fileURLWithPath: parent).appendingPathComponent("clipulse-rc-wire-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func start(settings: URL?, manager: ManagedSessionManager?) throws -> URL {
        let sock = dir.appendingPathComponent("clipulse-helper.sock")
        let s = LocalSessionServer(
            config: LocalSessionServer.Configuration(socketPath: sock),
            hooks: LocalSessionServer.Hooks(
                getAuthToken: { "T" },
                isLocalControlEnabled: { true },
                setLocalControlEnabled: { _ in },
                sessionManager: manager,
                listDetectedSessions: { [] },
                claudeSettingsPathOverride: { settings }
            )
        )
        try s.start()
        usleep(50_000)
        server = s
        return sock
    }

    private func call(_ sock: URL, _ body: [String: Any]) throws -> [String: Any] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = (sock.path as NSString).fileSystemRepresentation
        withUnsafeMutableBytes(of: &addr.sun_path) { memcpy($0.baseAddress!, path, strlen(path)) }
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(r, 0)
        try Framing.writeFrame(to: fd, body: try JSONSerialization.data(withJSONObject: body))
        guard let reply = try Framing.readFrame(from: fd) else { throw NSError(domain: "test", code: 1) }
        return (try JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
    }

    private func hello(_ sock: URL) throws -> [String: Any] {
        let r = try call(sock, ["id": "1", "method": "hello", "auth_token": "T", "params": [:]])
        return (r["result"] as? [String: Any]) ?? [:]
    }

    func testHelloReportsPolicyFromTheSettingsChain() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"disableRemoteControl": true}"#.write(to: settings, atomically: true, encoding: .utf8)
        let sock = try start(settings: settings, manager: nil)
        let rc = try XCTUnwrap(try hello(sock)["claude_remote_control"] as? [String: Any])
        XCTAssertEqual(rc["supported"] as? Bool, true)
        XCTAssertEqual(rc["policy"] as? String, "disabled")
        XCTAssertNotNil(rc["auth"] as? String)
    }

    func testHelloReportsAllowedWhenNothingDisablesIt() throws {
        // Negative control for the test above: the same server with a
        // settings file that says nothing.
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"model": "opus"}"#.write(to: settings, atomically: true, encoding: .utf8)
        let sock = try start(settings: settings, manager: nil)
        let rc = try XCTUnwrap(try hello(sock)["claude_remote_control"] as? [String: Any])
        XCTAssertEqual(rc["policy"] as? String, "allowed")
    }

    func testStartSessionFlagShowsUpOnTheReplyAndTheRow() throws {
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/sh\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let registry = ProviderSpawnerRegistry(spawners: [
            ClaudeSpawner(buildInlineSettings: nil, environment: ["CLI_PULSE_CLAUDE_ARGV0": script.path]),
        ])
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: registry)
        let sock = try start(settings: nil, manager: manager)

        let started = try call(sock, ["id": "2", "method": "start_session", "auth_token": "T",
                                      "params": ["provider": "claude", "claude_remote_control": true]])
        let result = try XCTUnwrap(started["result"] as? [String: Any], "reply: \(started)")
        let sid = try XCTUnwrap(result["session_id"] as? String)
        defer { _ = manager.stopSession(sid) }
        XCTAssertEqual((result["remote_control"] as? [String: Any])?["status"] as? String, "requested")

        let listed = try call(sock, ["id": "3", "method": "list_sessions", "auth_token": "T", "params": [:]])
        let rows = try XCTUnwrap((listed["result"] as? [String: Any])?["managed"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { ($0["session_id"] as? String) == sid })
        XCTAssertEqual((row["remote_control"] as? [String: Any])?["status"] as? String, "requested")

        // And a session started WITHOUT the flag has no such field at all.
        let plain = try call(sock, ["id": "4", "method": "start_session", "auth_token": "T", "params": ["provider": "claude"]])
        let sid2 = try XCTUnwrap((plain["result"] as? [String: Any])?["session_id"] as? String)
        defer { _ = manager.stopSession(sid2) }
        XCTAssertNil((plain["result"] as? [String: Any])?["remote_control"])
    }

    func testFlagMustBeAJSONBoolean() throws {
        // "true" the string, 1 the number — neither is a request.
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/sh\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let registry = ProviderSpawnerRegistry(spawners: [
            ClaudeSpawner(buildInlineSettings: nil, environment: ["CLI_PULSE_CLAUDE_ARGV0": script.path]),
        ])
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: registry)
        let sock = try start(settings: nil, manager: manager)
        for bad in ["true", "1"] as [Any] {
            let r = try call(sock, ["id": "5", "method": "start_session", "auth_token": "T",
                                    "params": ["provider": "claude", "claude_remote_control": bad]])
            let res = try XCTUnwrap(r["result"] as? [String: Any], "reply: \(r)")
            let sid = try XCTUnwrap(res["session_id"] as? String)
            XCTAssertNil(res["remote_control"], "\(bad) must not request remote control")
            _ = manager.stopSession(sid)
        }
    }
}

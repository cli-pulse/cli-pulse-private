import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// Remote-control M1a — defects the design review found in the helper
/// that a phone with control would turn into user-visible lies:
///
///   * approvals never expired (`expireOld` had no caller; `decide` did
///     not look at the TTL), so a late Approve "succeeded" after Claude
///     had already fallen back to deny;
///   * a short PTY write counted as success, so a paste longer than the
///     kernel's tty input queue silently lost its tail;
///   * `start_session` accepted any `cwd`/`client_label`, so a typo became
///     an `internal` spawn error indistinguishable from "claude missing";
///   * hello's `auth` looked at file presence, not at the OAuth object;
///   * the banner scanner kept trusting output after the user had typed.
final class M1aHelperHardeningTests: XCTestCase {

    // MARK: - Approval expiry

    private func registryWithPending(ttl: TimeInterval) throws -> (ApprovalRegistry, PendingApproval, EventBroker) {
        let broker = EventBroker()
        let r = ApprovalRegistry(broker: broker)
        _ = r.registerSession("s1", claudePid: nil)
        let row = try r.createPending(sessionId: "s1", kind: "PermissionRequest", title: "Bash",
                                      summary: "rm -rf build", toolMetadata: [:], ttlSeconds: ttl)
        return (r, row, broker)
    }

    func testDecideAfterTTLIsRefusedAsExpiredAndPublished() throws {
        let (r, row, broker) = try registryWithPending(ttl: 0.05)
        var resolved: [[String: Any]] = []
        let lock = NSLock()
        broker.subscribe(sessionFilter: nil) { e in
            if (e["event"] as? String) == "approval_resolved" { lock.lock(); resolved.append(e); lock.unlock() }
        }
        usleep(120_000)
        XCTAssertThrowsError(try r.decide(sessionId: "s1", approvalId: row.approvalId, decision: "approve")) { e in
            guard case ApprovalRegistry.RegistryError.approvalAlreadyResolved(let s) = e else {
                return XCTFail("expected approvalAlreadyResolved(expired), got \(e)")
            }
            XCTAssertEqual(s, "expired")
        }
        lock.lock(); let seen = resolved; lock.unlock()
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?["status"] as? String, "expired")
        XCTAssertEqual(r.listPending(sessionId: "s1").count, 0, "an expired row is no longer pending")
    }

    func testDecideBeforeTTLStillWorks() throws {
        // Negative control for the test above.
        let (r, row, _) = try registryWithPending(ttl: 30)
        let d = try r.decide(sessionId: "s1", approvalId: row.approvalId, decision: "approve")
        XCTAssertEqual(d.status, .approved)
    }

    func testWaitTimeoutPastTTLExpiresTheRowItWaitedFor() throws {
        // The hook's wait and the row's TTL are the same 60 s in
        // production; when the wait gives up AND the TTL has passed, the
        // row must not stay pending — that is the exact window in which a
        // phone tapped Approve for a tool Claude had already denied.
        let (r, row, _) = try registryWithPending(ttl: 0.05)
        XCTAssertThrowsError(try r.waitForDecision(sessionId: "s1", approvalId: row.approvalId, timeout: 0.1)) { e in
            guard case ApprovalRegistry.RegistryError.waitTimeout = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(r.listPending(sessionId: "s1").count, 0)
        XCTAssertThrowsError(try r.decide(sessionId: "s1", approvalId: row.approvalId, decision: "approve"))
    }

    // MARK: - PTY full write

    func testWriteStdinDeliversMoreThanOneKernelQueueWhenTheChildReads() throws {
        // `cat` echoes what it reads, so a write larger than the tty input
        // queue (~1 KiB on Darwin) only completes if writeStdin keeps
        // going as the child drains.
        //
        // Raw mode matters: in canonical mode the kernel ACCEPTS the whole
        // write and silently discards everything past 1024 bytes of an
        // unfinished line (measured here: 6001 written, 1024 echoed) — the
        // master cannot see that. Real CLIs run their tty raw, where a
        // full queue answers EAGAIN and the loop below is what saves the
        // tail.
        let t = PtyTransport()
        let h = try t.start(sessionId: "w1", argv: ["/bin/sh", "-c", "stty raw -echo; exec /bin/cat"], env: [:], cwd: nil)
        defer { t.terminate(h); t.close(h) }
        usleep(300_000)   // let stty run before the bytes arrive
        let payload = Data(String(repeating: "x", count: 6000).utf8) + Data("\n".utf8)
        // Drain the master concurrently, as the helper's drain loop does in
        // production: with nobody reading, cat blocks on its own output
        // once the slave→master queue fills, stops reading stdin, and the
        // write stalls for a reason that has nothing to do with input.
        let echoed = NSLock(); var echoedCount = 0
        let stop = AtomicBool()
        let reader = Thread {
            while !stop.get() {
                if let d = try? t.readStdout(h, maxBytes: 65536), !d.isEmpty {
                    echoed.lock(); echoedCount += d.count; echoed.unlock()
                }
                usleep(5_000)
            }
        }
        reader.start()
        defer { stop.set(true) }
        let n = try t.writeStdin(h, payload)
        XCTAssertEqual(n, payload.count, "short write reported as \(n) of \(payload.count)")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            echoed.lock(); let c = echoedCount; echoed.unlock()
            if c >= payload.count { break }
            usleep(20_000)
        }
        echoed.lock(); let total = echoedCount; echoed.unlock()
        XCTAssertGreaterThanOrEqual(total, payload.count, "cat never echoed the whole payload")
    }

    func testWriteStdinReportsAShortWriteWhenTheChildNeverReads() throws {
        // Negative control: a child that does not read its stdin cannot
        // accept more than the kernel queue. The transport must give up
        // within its deadline and REPORT the short count — not hang, and
        // not claim success.
        let t = PtyTransport(writeDeadlineSeconds: 0.3)
        let h = try t.start(sessionId: "w2", argv: ["/bin/sh", "-c", "stty raw -echo; sleep 5"], env: [:], cwd: nil)
        defer { t.terminate(h); t.close(h) }
        usleep(300_000)
        let payload = Data(String(repeating: "y", count: 8192).utf8)
        let t0 = Date()
        let n = try t.writeStdin(h, payload)
        XCTAssertLessThan(n, payload.count)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0, "must not block past the deadline")
    }

    func testManagerTreatsAShortWriteAsAFailureNotASuccess() throws {
        struct Sleeper: ProviderSpawner {
            let name = "sleeper"
            func isAvailable() -> Bool { true }
            func argv(extraEnv: [String: String], helperArgv0: String?) -> [String] { ["/bin/sh", "-c", "stty raw -echo; sleep 5"] }
            func supportsRemoteApproval() -> Bool { false }
        }
        let manager = ManagedSessionManager(transport: PtyTransport(writeDeadlineSeconds: 0.3),
                                            providerRegistry: ProviderSpawnerRegistry(spawners: [Sleeper()]))
        let s = try manager.startSession(provider: "sleeper", clientLabel: nil)
        defer { _ = manager.stopSession(s.sessionId) }
        usleep(300_000)
        XCTAssertThrowsError(try manager.sendInputRaw(sessionId: s.sessionId, bytes: Data(repeating: 0x7a, count: 8192))) { e in
            guard case ManagedSessionManager.ManagerError.writeFailed(let m) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(m.contains("short write"), m)
        }
    }

    // MARK: - start_session validation (server)

    private var dir: URL!
    private var server: LocalSessionServer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let parent = FileManager.default.fileExists(atPath: "/tmp") ? "/tmp" : NSTemporaryDirectory()
        dir = URL(fileURLWithPath: parent).appendingPathComponent("clipulse-m1a-h-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func startServer(manager: ManagedSessionManager?, credentials: URL? = nil) throws -> URL {
        let sock = dir.appendingPathComponent("clipulse-helper.sock")
        let s = LocalSessionServer(
            config: LocalSessionServer.Configuration(socketPath: sock),
            hooks: LocalSessionServer.Hooks(
                getAuthToken: { "T" },
                isLocalControlEnabled: { true },
                setLocalControlEnabled: { _ in },
                sessionManager: manager,
                listDetectedSessions: { [] },
                claudeCredentialsPathOverride: { credentials }
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

    private func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    func testStartSessionRefusesRelativeMissingAndOversizedInputs() throws {
        struct Sleeper: ProviderSpawner {
            let name = "claude"
            func isAvailable() -> Bool { true }
            func argv(extraEnv: [String: String], helperArgv0: String?) -> [String] { ["/bin/sh", "-c", "sleep 5"] }
            func supportsRemoteApproval() -> Bool { false }
        }
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: ProviderSpawnerRegistry(spawners: [Sleeper()]))
        let sock = try startServer(manager: manager)
        func start(_ params: [String: Any]) throws -> [String: Any] {
            try call(sock, ["id": "1", "method": "start_session", "auth_token": "T", "params": params])
        }
        XCTAssertEqual(errorCode(try start(["provider": "claude", "cwd": "relative/path"])), "bad_request")
        XCTAssertEqual(errorCode(try start(["provider": "claude", "cwd": "/definitely/not/here/\(UUID().uuidString)"])), "bad_request")
        XCTAssertEqual(errorCode(try start(["provider": "claude", "client_label": String(repeating: "a", count: 300)])), "bad_request")
        XCTAssertEqual(errorCode(try start(["provider": "claude", "cwd": String(repeating: "/a", count: 3000)])), "bad_request")
        // Positive control: a real directory and a sane label spawn.
        let ok = try start(["provider": "claude", "cwd": dir.path, "client_label": "phone"])
        let sid = try XCTUnwrap((ok["result"] as? [String: Any])?["session_id"] as? String, "\(ok)")
        _ = manager.stopSession(sid)
    }

    // MARK: - rows say what the helper owns

    func testRowsCarryAttachedAndLocalOnly() throws {
        // A hand-launched session the shell integration parked in tmux is
        // ATTACHED and local-only until the user opts it in; a session the
        // helper spawned is neither. Before this, every managed row said
        // `controllable: true` and nothing else — a phone could not tell.
        let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tmux else { throw XCTSkip("tmux not available") }
        struct Sleeper: ProviderSpawner {
            let name = "claude"
            func isAvailable() -> Bool { true }
            func argv(extraEnv: [String: String], helperArgv0: String?) -> [String] { ["/bin/sh", "-c", "sleep 5"] }
            func supportsRemoteApproval() -> Bool { false }
        }
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: ProviderSpawnerRegistry(spawners: [Sleeper()]))
        defer { manager.shutdown() }
        let tmuxSock = dir.appendingPathComponent("t.sock").path
        let owner = TmuxTransport(socketPath: tmuxSock, tmuxBin: tmux)
        let oh = try owner.start(sessionId: "clipulse-claude-77", argv: ["cat"])
        defer { owner.close(oh) }
        XCTAssertTrue(manager.attachWrappedSession(sessionId: "att-77", tmuxSessionName: "clipulse-claude-77",
                                                   tmuxBin: tmux, socketPath: tmuxSock))
        let spawned = try manager.startSession(provider: "claude", clientLabel: "mine")

        let sock = try startServer(manager: manager)
        let listed = try call(sock, ["id": "1", "method": "list_sessions", "auth_token": "T", "params": [:]])
        let rows = try XCTUnwrap((listed["result"] as? [String: Any])?["managed"] as? [[String: Any]])
        let att = try XCTUnwrap(rows.first { ($0["session_id"] as? String) == "att-77" })
        XCTAssertEqual(att["attached"] as? Bool, true)
        XCTAssertEqual(att["local_only"] as? Bool, true)
        let own = try XCTUnwrap(rows.first { ($0["session_id"] as? String) == spawned.sessionId })
        XCTAssertEqual(own["attached"] as? Bool, false)
        XCTAssertEqual(own["local_only"] as? Bool, false)
    }

    // MARK: - hello auth

    func testHelloAuthReflectsTheOAuthObjectNotTheFile() throws {
        func auth(_ contents: String?) throws -> String? {
            server?.stop(); server = nil
            let creds = dir.appendingPathComponent("creds-\(UUID().uuidString.prefix(4)).json")
            if let contents { try contents.write(to: creds, atomically: true, encoding: .utf8) }
            let sock = try startServer(manager: nil, credentials: creds)
            let r = try call(sock, ["id": "1", "method": "hello", "auth_token": "T", "params": [:]])
            return ((r["result"] as? [String: Any])?["claude_remote_control"] as? [String: Any])?["auth"] as? String
        }
        XCTAssertEqual(try auth(nil), "none")
        XCTAssertEqual(try auth(#"{"something":"else"}"#), "none")
        XCTAssertEqual(try auth(#"{"claudeAiOauth":{"accessToken":"","refreshToken":""}}"#), "none")
        XCTAssertEqual(try auth(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1}}"#), "oauth")
    }

    // MARK: - scan window closes at first input

    func testURLPrintedAfterTheUserTypedIsNotTrusted() throws {
        let script = dir.appendingPathComponent("claude")
        // Prints the banner only after reading a line from stdin.
        try "#!/bin/sh\nread line\nprintf 'see this session at https://claude.ai/code/019a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8\\n'\nsleep 5\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let registry = ProviderSpawnerRegistry(spawners: [
            ClaudeSpawner(buildInlineSettings: nil, environment: ["CLI_PULSE_CLAUDE_ARGV0": script.path]),
        ])
        let manager = ManagedSessionManager(transport: PtyTransport(), providerRegistry: registry)
        let s = try manager.startSession(provider: "claude", clientLabel: nil, claudeRemoteControl: true)
        defer { _ = manager.stopSession(s.sessionId) }
        usleep(200_000)
        _ = try manager.sendInputRaw(sessionId: s.sessionId, bytes: Data("hello\n".utf8))
        var rc: ManagedSessionManager.RemoteControlSummary?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            rc = manager.listSessions().first?.remoteControl
            if rc?.status != "requested" { break }
            usleep(50_000)
        }
        XCTAssertEqual(rc?.status, "unavailable")
        XCTAssertEqual(rc?.reason, "input_before_banner")
        XCTAssertNil(rc?.url, "a URL that appears after user input must never become the row's target")
    }
}

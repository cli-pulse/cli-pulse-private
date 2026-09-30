import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// v1.55: `hello` works out `provider_plan_status` by reading each provider's
/// credential file (`~/.codex/auth.json` for Codex). Before 1.55 it did that on
/// every `hello`, whatever the app's local-scan answer, so after "Not now" the
/// bundled helper still opened `auth.json` each time the app or its LoginItem
/// said hello. The answer lives in the app group, which this helper must not
/// open, so the caller says it: `local_scan_allowed: true` is the only thing
/// that lets `hello` read the files.
///
/// The spawner below counts the reads. Its `planAuthStatus` stands in for
/// `CodexSpawner.planAuthStatus`, which is where `auth.json` is opened.
final class HelloLocalScanAnswerTests: XCTestCase {

    /// Counts `planAuthStatus` calls: each one is a credential-file read in the
    /// real spawners.
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func hit() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private struct CountingSpawner: ProviderSpawner {
        let name = "codex"
        let reads: ReadCounter
        func isAvailable() -> Bool { true }
        func argv(extraEnv: [String: String], helperArgv0: String?) -> [String] { ["/usr/bin/true"] }
        func supportsRemoteApproval() -> Bool { false }
        func planAuthStatus(resolvedHome: String?) -> String {
            reads.hit()
            return "off_plan"
        }
    }

    private var dir: URL!
    private var server: LocalSessionServer?
    private var manager: ManagedSessionManager?
    private var reads: ReadCounter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let parent = FileManager.default.fileExists(atPath: "/tmp") ? "/tmp" : NSTemporaryDirectory()
        dir = URL(fileURLWithPath: parent).appendingPathComponent("clipulse-hello-lsa-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reads = ReadCounter()
    }

    override func tearDownWithError() throws {
        server?.stop()
        manager?.shutdown()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func startServer(withManager: Bool = true) throws -> URL {
        let sock = dir.appendingPathComponent("clipulse-helper.sock")
        let manager = withManager
            ? ManagedSessionManager(
                transport: PtyTransport(),
                providerRegistry: ProviderSpawnerRegistry(spawners: [CountingSpawner(reads: reads)])
            )
            : nil
        self.manager = manager
        let s = LocalSessionServer(
            config: LocalSessionServer.Configuration(socketPath: sock),
            hooks: LocalSessionServer.Hooks(
                getAuthToken: { "T" },
                sessionManager: manager
            )
        )
        try s.start()
        usleep(50_000)
        server = s
        return sock
    }

    private func hello(_ sock: URL, params: [String: Any]) throws -> [String: Any] {
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
        let body: [String: Any] = ["id": "1", "method": "hello", "params": params]
        try Framing.writeFrame(to: fd, body: try JSONSerialization.data(withJSONObject: body))
        guard let reply = try Framing.readFrame(from: fd) else { throw NSError(domain: "test", code: 1) }
        let dict = (try JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        XCTAssertEqual(dict["ok"] as? Bool, true, "\(dict)")
        return (dict["result"] as? [String: Any]) ?? [:]
    }

    func testTheParameterNameIsTheOneTheAppSends() {
        // The app's LocalSessionControlClient.localScanAllowedParam and the
        // Companion CLI's local_session_server.py spell the same string.
        XCTAssertEqual(LocalSessionServer.localScanAllowedParam, "local_scan_allowed")
    }

    func testAllowedAnswerReadsAndReportsPlanStatus() throws {
        let sock = try startServer()
        let result = try hello(sock, params: ["client_protocol_version": 1, "local_scan_allowed": true])
        XCTAssertEqual(result["provider_plan_status"] as? [String: String], ["codex": "off_plan"])
        XCTAssertEqual(reads.value, 1)
    }

    func testDeclinedAnswerReadsNothing() throws {
        let sock = try startServer()
        let result = try hello(sock, params: ["client_protocol_version": 1, "local_scan_allowed": false])
        XCTAssertNil(result["provider_plan_status"], "a paused scan must not report what it would have read")
        XCTAssertEqual(reads.value, 0, "\"Not now\" must not open a provider credential file")
        // The rest of the reply is unchanged: the app still sees a running helper.
        XCTAssertEqual(result["helper_version"] as? String, kHelperVersion)
        XCTAssertEqual(result["provider_availability"] as? [String], ["codex"])
    }

    func testNoAnswerReadsNothing() throws {
        // A status probe (the app's HelperInstaller, the LAN agent) has no
        // answer to give; missing is read as no, not as the pre-1.55 "always".
        let sock = try startServer()
        let requests: [[String: Any]] = [
            ["client_protocol_version": 1],
            [:],
            // Only a JSON true counts.
            ["local_scan_allowed": "true"],
            ["local_scan_allowed": 1],
            ["local_scan_allowed": NSNull()],
        ]
        for params in requests {
            let result = try hello(sock, params: params)
            XCTAssertNil(result["provider_plan_status"], "params: \(params)")
        }
        XCTAssertEqual(reads.value, 0)
    }

    func testEachHelloFollowsItsOwnAnswer() throws {
        // The answer is per request: nothing is remembered between them.
        let sock = try startServer()
        _ = try hello(sock, params: ["local_scan_allowed": true])
        XCTAssertEqual(reads.value, 1)
        _ = try hello(sock, params: ["local_scan_allowed": false])
        _ = try hello(sock, params: [:])
        XCTAssertEqual(reads.value, 1)
        _ = try hello(sock, params: ["local_scan_allowed": true])
        XCTAssertEqual(reads.value, 2)
    }

    func testWithoutASessionManagerTheFieldFollowsTheAnswerToo() throws {
        let sock = try startServer(withManager: false)
        XCTAssertNil(try hello(sock, params: [:])["provider_plan_status"])
        XCTAssertEqual(
            try hello(sock, params: ["local_scan_allowed": true])["provider_plan_status"] as? [String: String],
            [:]
        )
    }

    // MARK: - claude_remote_control

    /// `claude_remote_control` is worked out by reading Claude Code's settings
    /// files and its credentials file (~/.claude/.credentials.json). Before
    /// 1.55 every hello read them, "Not now" included; the app's LAN agent
    /// says hello for every phone that connects. The seams below are where
    /// `claudeRemoteControlHello` gets each path, so counting their calls
    /// counts the reads.
    private func startRemoteControlServer(settings: URL, credentials: URL, lookups: ReadCounter) throws -> URL {
        let sock = dir.appendingPathComponent("clipulse-helper.sock")
        let s = LocalSessionServer(
            config: LocalSessionServer.Configuration(socketPath: sock),
            hooks: LocalSessionServer.Hooks(
                getAuthToken: { "T" },
                claudeSettingsPathOverride: { lookups.hit(); return settings },
                claudeCredentialsPathOverride: { lookups.hit(); return credentials }
            )
        )
        try s.start()
        usleep(50_000)
        server = s
        return sock
    }

    private func remoteControlFixtures() throws -> (settings: URL, credentials: URL) {
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"disableRemoteControl": true}"#.write(to: settings, atomically: true, encoding: .utf8)
        let credentials = dir.appendingPathComponent(".credentials.json")
        try #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#
            .write(to: credentials, atomically: true, encoding: .utf8)
        return (settings, credentials)
    }

    func testClaudeRemoteControlIsReadOnlyWhenTheAnswerAllowsIt() throws {
        let (settings, credentials) = try remoteControlFixtures()
        let lookups = ReadCounter()
        let sock = try startRemoteControlServer(settings: settings, credentials: credentials, lookups: lookups)
        // The positive control: allowed, both files are read and reported.
        let allowed = try hello(sock, params: ["local_scan_allowed": true])
        let rc = try XCTUnwrap(allowed["claude_remote_control"] as? [String: Any])
        XCTAssertEqual(rc["policy"] as? String, "disabled")
        XCTAssertEqual(rc["auth"] as? String, "oauth")
        XCTAssertEqual(lookups.value, 2)
    }

    func testClaudeRemoteControlReadsNothingWithoutAYes() throws {
        let (settings, credentials) = try remoteControlFixtures()
        let lookups = ReadCounter()
        let sock = try startRemoteControlServer(settings: settings, credentials: credentials, lookups: lookups)
        let requests: [[String: Any]] = [
            ["local_scan_allowed": false],
            ["client_protocol_version": 1],
            [:],
            ["local_scan_allowed": "true"],
            ["local_scan_allowed": 1],
            ["local_scan_allowed": NSNull()],
        ]
        for params in requests {
            let result = try hello(sock, params: params)
            XCTAssertNil(result["claude_remote_control"], "params: \(params)")
            // The rest of the reply is unchanged: the app still sees a running helper.
            XCTAssertEqual(result["helper_version"] as? String, kHelperVersion, "params: \(params)")
        }
        XCTAssertEqual(lookups.value, 0, "\"Not now\" must not open Claude Code's settings or credentials")
        // And the next yes reads again: nothing is remembered between hellos.
        XCTAssertNotNil(try hello(sock, params: ["local_scan_allowed": true])["claude_remote_control"])
        XCTAssertEqual(lookups.value, 2)
    }
}

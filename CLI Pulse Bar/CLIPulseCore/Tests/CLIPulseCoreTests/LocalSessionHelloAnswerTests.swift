import XCTest
import Darwin
@testable import CLIPulseCore

#if os(macOS)

/// v1.55: the app tells the helper, in `hello`, whether the local-scan answer
/// allows reading this Mac (`local_scan_allowed`). The bundled Swift helper
/// reads provider credential files for `provider_plan_status` only when told
/// `true`, because it must not open the app group where the answer is kept;
/// the Companion CLI stops on an explicit `false`. So what the app puts on the
/// wire is the whole gate for the bundled helper, and this checks it at the
/// wire, against a socket that records the request.
final class LocalSessionHelloAnswerTests: XCTestCase {

    /// Accepts one connection, records the request's `params`, and answers
    /// with a minimal valid `hello` reply.
    private final class RecordingServer {
        let socketPath: String
        let tokenPath: String
        private let fd: Int32
        private let lock = NSLock()
        private var recorded: [String: Any]?
        private let done = DispatchSemaphore(value: 0)

        init() throws {
            let unique = UUID().uuidString.prefix(8)
            socketPath = "\(NSTemporaryDirectory())cps-hello-\(unique).sock"
            tokenPath = "\(NSTemporaryDirectory())cps-hello-token-\(unique).txt"
            try "T".write(toFile: tokenPath, atomically: true, encoding: .utf8)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8)
            precondition(bytes.count < 104, "socket path too long")
            withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: 104) { cstr in
                    for (i, b) in bytes.enumerated() { cstr[i] = CChar(bitPattern: b) }
                    cstr[bytes.count] = 0
                }
            }
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(fd, 1) == 0 else {
                close(fd)
                throw NSError(domain: "RecordingServer", code: Int(errno))
            }
            let serverFD = fd
            Thread { [weak self] in
                let client = accept(serverFD, nil, nil)
                guard client >= 0 else { self?.done.signal(); return }
                defer { close(client) }
                var header = [UInt8](repeating: 0, count: 4)
                guard recv(client, &header, 4, MSG_WAITALL) == 4 else { self?.done.signal(); return }
                let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16
                                 | UInt32(header[2]) << 8 | UInt32(header[3]))
                var body = [UInt8](repeating: 0, count: length)
                _ = recv(client, &body, length, MSG_WAITALL)
                let request = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
                self?.record((request?["params"] as? [String: Any]) ?? [:])
                let reply: [String: Any] = [
                    "id": request?["id"] ?? "1",
                    "ok": true,
                    "result": [
                        "protocol_version": 1,
                        "supported_methods": ["hello"],
                        "capabilities": [:] as [String: Any],
                    ] as [String: Any],
                ]
                if let data = try? JSONSerialization.data(withJSONObject: reply) {
                    var size = UInt32(data.count).bigEndian
                    _ = withUnsafeBytes(of: &size) { send(client, $0.baseAddress, 4, 0) }
                    _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) }
                }
                self?.done.signal()
            }.start()
        }

        private func record(_ params: [String: Any]) {
            lock.withLock { recorded = params }
        }

        /// The params of the one request this server saw.
        func params() -> [String: Any]? {
            _ = done.wait(timeout: .now() + 5)
            return lock.withLock { recorded }
        }

        func stop() {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
    }

    private func helloParams(_ call: (LocalSessionControlClient) async throws -> SessionControlHello) async throws -> [String: Any] {
        let server = try RecordingServer()
        defer { server.stop() }
        let client = LocalSessionControlClient(
            socketPath: server.socketPath,
            tokenPath: server.tokenPath,
            connectTimeout: 2,
            requestTimeout: 2,
            runtimeEnvironment: TestRuntimeFixtures.productionApp
        )
        _ = try await call(client)
        return try XCTUnwrap(server.params(), "the server saw no request")
    }

    func testTheParameterNameIsTheOneBothHelpersRead() {
        // HelperKit's LocalSessionServer.localScanAllowedParam and
        // helper/local_session_server.py spell the same string.
        XCTAssertEqual(LocalSessionControlClient.localScanAllowedParam, "local_scan_allowed")
    }

    func testAnAnswerThatAllowsReadingSaysTrue() async throws {
        let params = try await helloParams { try await $0.hello(localScanAllowed: true) }
        XCTAssertEqual(params["local_scan_allowed"] as? Bool, true)
        XCTAssertEqual(params["client_protocol_version"] as? Int, 1)
    }

    func testNotNowSaysFalse() async throws {
        let params = try await helloParams { try await $0.hello(localScanAllowed: false) }
        let flag = try XCTUnwrap(params["local_scan_allowed"] as? NSNumber)
        // A JSON boolean, which is all the bundled helper accepts as an answer.
        XCTAssertEqual(CFGetTypeID(flag), CFBooleanGetTypeID())
        XCTAssertFalse(flag.boolValue)
    }

    func testAStatusProbeSaysNothing() async throws {
        // The protocol's `hello()`, for "is it running, which version": no
        // answer, which the bundled helper reads as no.
        let params = try await helloParams { try await $0.hello() }
        XCTAssertNil(params["local_scan_allowed"])
        XCTAssertEqual(params["client_protocol_version"] as? Int, 1)
    }

    func testTheSessionsTabAsksWithTheConsentRule() throws {
        // The one app call that uses the plan status passes the same rule the
        // refresh uses (`LocalCollectionPolicy.allowsCollection`).
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/CLIPulseCore/LocalSessionControlState.swift"),
            encoding: .utf8
        )
        let call = try XCTUnwrap(source.range(of: "let hello = try await client.hello(\n"))
        let tail = source[call.upperBound...].prefix(400)
        XCTAssertTrue(tail.contains("localScanAllowed: LocalCollectionPolicy.allowsCollection("), String(tail))
    }
}

#endif

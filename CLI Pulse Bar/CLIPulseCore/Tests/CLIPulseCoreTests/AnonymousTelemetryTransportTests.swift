import XCTest
@testable import CLIPulseCore

/// Captures the outgoing request so the privacy claim can be asserted rather
/// than believed.
private final class CapturingProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var status = 204

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips the body into a stream; read it back so the test
        // can assert on what was actually queued.
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            captured.httpBody = data
        }
        Self.lastRequest = captured

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AnonymousTelemetryTransportTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingProtocol.self]
        return URLSession(configuration: config)
    }

    private let payload = AnonymousInstallPayload(
        installID: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
        channel: .devid, appVersion: "1.45.0", osVersion: "15.1", providerDetected: false
    )

    override func setUp() {
        super.setUp()
        CapturingProtocol.lastRequest = nil
        CapturingProtocol.status = 204
    }

    /// THE privacy invariant.
    ///
    /// If this request ever carried a signed-in user's JWT, the row would be
    /// anonymous in the schema and not in fact — the association would exist in
    /// the request itself. That would make the first-launch disclosure and the
    /// App Store nutrition label untrue, which is a worse outcome than never
    /// shipping the feature.
    func test_theRequestCarriesTheAnonKeyAndNothingElse() async throws {
        let transport = SupabaseAnonymousTelemetryTransport(
            configuration: RuntimeCloudConfiguration(
                url: "https://example.invalid", anonKey: "ANON-KEY"
            ),
            session: makeSession()
        )
        try await transport.send(payload)

        let request = try XCTUnwrap(CapturingProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "ANON-KEY")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ANON-KEY")

        // Nothing that could identify a person may ride along.
        for header in ["X-Client-Info", "X-User-Id", "Cookie"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header), "\(header) must not be set")
        }
    }

    func test_theBodyIsExactlyThePayload() async throws {
        let transport = SupabaseAnonymousTelemetryTransport(
            configuration: RuntimeCloudConfiguration(url: "https://example.invalid", anonKey: "K"),
            session: makeSession()
        )
        try await transport.send(payload)

        let body = try XCTUnwrap(CapturingProtocol.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys),
            ["p_install_id", "p_channel", "p_app_version", "p_os_version", "p_provider_detected"]
        )
    }

    func test_itPostsToTheIngestRPCOnly() async throws {
        let transport = SupabaseAnonymousTelemetryTransport(
            configuration: RuntimeCloudConfiguration(url: "https://example.invalid", anonKey: "K"),
            session: makeSession()
        )
        try await transport.send(payload)
        XCTAssertEqual(
            CapturingProtocol.lastRequest?.url?.absoluteString,
            "https://example.invalid/rest/v1/rpc/record_anonymous_install"
        )
        XCTAssertEqual(CapturingProtocol.lastRequest?.httpMethod, "POST")
    }

    /// A QA or quarantine build resolves to the invalid local URL with a
    /// placeholder key. It must fail rather than reach anything — the QA
    /// runtime landed two days before this feature, and a telemetry sender that
    /// bypassed that gate would poison the exact numbers it exists to produce.
    func test_aQABuildCannotReachProduction() async {
        let transport = SupabaseAnonymousTelemetryTransport(
            configuration: RuntimeCloudConfiguration(
                url: RuntimeCloudConfiguration.localInvalidURL,
                anonKey: RuntimeCloudConfiguration.localInvalidAnonKey
            ),
            session: makeSession()
        )
        // The stub would answer anything, so assert on the destination: it is
        // the dead local address, never the production host.
        try? await transport.send(payload)
        let url = CapturingProtocol.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.hasPrefix(RuntimeCloudConfiguration.localInvalidURL), "got \(url)")
        XCTAssertFalse(url.contains("supabase.co"))
    }

    func test_anUnconfiguredBuildSendsNothing() async {
        let transport = SupabaseAnonymousTelemetryTransport(
            configuration: RuntimeCloudConfiguration(url: "https://example.invalid", anonKey: ""),
            session: makeSession()
        )
        do {
            try await transport.send(payload)
            XCTFail("an empty anon key must not produce a request")
        } catch {
            XCTAssertNil(CapturingProtocol.lastRequest)
        }
    }

    func test_aRejectedCallThrowsSoTheCallerRetriesNextLaunch() async {
        CapturingProtocol.status = 400
        let transport = SupabaseAnonymousTelemetryTransport(
            configuration: RuntimeCloudConfiguration(url: "https://example.invalid", anonKey: "K"),
            session: makeSession()
        )
        do {
            try await transport.send(payload)
            XCTFail("a 400 must surface as a failure, not a silent success")
        } catch {}
    }
}

// MARK: - Drift gate

/// The client shapes versions to match CHECKs written in the migration. A
/// client that drifts does not degrade — the server rejects the call and we go
/// silent, which is precisely the blindness this feature exists to end.
///
/// So this reads the migration file itself. If someone loosens or tightens the
/// SQL without touching the Swift, this fails.
final class AnonymousTelemetryMigrationDriftTests: XCTestCase {

    private func migrationSource() throws -> String {
        // Tests/CLIPulseCoreTests/ -> Tests/ -> CLIPulseCore/ -> CLI Pulse Bar/ -> repo
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CLIPulseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // CLIPulseCore
            .deletingLastPathComponent()  // CLI Pulse Bar
            .deletingLastPathComponent()  // repo root
        let migration = repoRoot
            .appendingPathComponent("backend/supabase/migrate_v0.73_anonymous_install_telemetry.sql")
        return try String(contentsOf: migration, encoding: .utf8)
    }

    func test_theMigrationStillEnforcesTheVersionShapesTheClientProduces() throws {
        let sql = try migrationSource()
        XCTAssertTrue(
            sql.contains(#"'^[0-9]{1,4}(\.[0-9]{1,4}){0,4}$'"#),
            "app_version CHECK changed; AnonymousTelemetryVersionShaping must change with it"
        )
        XCTAssertTrue(
            sql.contains(#"'^[0-9]{1,4}(\.[0-9]{1,4}){0,2}$'"#),
            "os_version CHECK changed; coarsenedOSVersion must change with it"
        )
    }

    func test_theMigrationStillAcceptsExactlyTheChannelsTheClientCanSend() throws {
        let sql = try migrationSource()
        XCTAssertTrue(sql.contains("('mas', 'devid', 'brew', 'unknown')"))
        XCTAssertEqual(
            Set(DistributionChannel.allCases.map(\.rawValue)),
            ["mas", "devid", "brew", "unknown"],
            "a new channel case needs the migration's allowlist extended first, or it is rejected"
        )
    }

    /// Every version the client is willing to send must satisfy the server's
    /// pattern. This is the property that actually matters; the two above just
    /// localise the blame when it breaks.
    func test_everyShapedVersionSatisfiesTheServerPattern() throws {
        let appPattern = try NSRegularExpression(pattern: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,4}$"#)
        let osPattern = try NSRegularExpression(pattern: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,2}$"#)

        for raw in ["1.45.0", "1.45.0-beta.2", "2", "10.20.30.40.50", "1.2.3.4.5.6", "0.0.1"] {
            guard let shaped = AnonymousTelemetryVersionShaping.sanitizedAppVersion(raw) else { continue }
            let range = NSRange(shaped.startIndex..., in: shaped)
            XCTAssertNotNil(
                appPattern.firstMatch(in: shaped, range: range),
                "client would send '\(shaped)' (from '\(raw)') and the server would reject it"
            )
        }

        for (major, minor) in [(15, 1), (26, 0), (9999, 9999), (0, 0)] {
            let shaped = AnonymousTelemetryVersionShaping.coarsenedOSVersion(major: major, minor: minor)
            let range = NSRange(shaped.startIndex..., in: shaped)
            XCTAssertNotNil(osPattern.firstMatch(in: shaped, range: range), "would send '\(shaped)'")
        }
    }
}

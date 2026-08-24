import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.50 W-A. Two defects that let an unauthenticated Mac in "local mode" talk
/// to the network before its owner had been shown anything.
///
/// Both were found by reading the source, then observed at runtime on
/// 2026-08-24 with a fresh Developer ID install of 1.49.0: pressing the
/// onboarding wizard's close button on step 0 — the Welcome card, two steps
/// before the privacy card — put the app into local mode and, 1.5 s later,
/// rotated the OpenAI credentials in `auth.json`.
///
/// The tests below pin the decisions, not the plumbing. Break either one and
/// they go red:
///
///   * flip `>` to `>=` (or drop the `jwtExpiry` branch) in
///     `CodexCollector.needsRefresh` → the credential-rotation tests fail;
///   * revert `requireUserID()` to `userId ?? ""` → the silence test fails,
///     because the stub counts a request that should never have been made.
final class LocalModeOutboundSilenceTests: XCTestCase {

    // MARK: - No user id, no request

    /// `refreshLocal` finishes by calling `completeRefresh()`, which starts
    /// `refreshYieldScore()`, which calls `settings()`. On an unauthenticated
    /// Mac that used to become `GET /rest/v1/user_settings?user_id=eq.&select=*`
    /// on every refresh tick. Production edge logs for 2026-08-24 show a real
    /// 1.49.0 install doing exactly that, roughly every two minutes, answered
    /// 400 each time.
    ///
    /// The assertion that matters is `requestCount == 0`. Throwing is the
    /// mechanism; not reaching the wire is the requirement.
    func testUserScopedCallWithNoSessionMakesNoRequest() async {
        CountingStubProtocol.reset()
        let api = APIClient(
            supabaseURL: "https://stub.cli-pulse.test",
            supabaseAnonKey: "anon",
            session: CountingStubProtocol.makeSession()
        )

        do {
            _ = try await api.settings()
            XCTFail("settings() must not succeed without a signed-in user")
        } catch let error as APIError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(
            CountingStubProtocol.requestCount, 0,
            "an unauthenticated user-scoped call must not reach the network at all"
        )
    }

    /// Same guard, exercised through the other user-scoped readers, so a future
    /// change that re-opens one of them is caught. `alerts`, `devices` and
    /// `sessions` all run on the authenticated refresh path; `settings` is the
    /// one the local-mode path reaches, and it is covered above.
    func testEveryUserScopedReaderStaysSilentWithoutASession() async {
        CountingStubProtocol.reset()
        let api = APIClient(
            supabaseURL: "https://stub.cli-pulse.test",
            supabaseAnonKey: "anon",
            session: CountingStubProtocol.makeSession()
        )

        for call in [
            ("alerts", { try await api.alerts() as Any }),
            ("devices", { try await api.devices() as Any }),
            ("sessions", { try await api.sessions() as Any }),
        ] as [(String, () async throws -> Any)] {
            do {
                _ = try await call.1()
                XCTFail("\(call.0)() must not succeed without a signed-in user")
            } catch let error as APIError {
                XCTAssertEqual(error, .notAuthenticated, "\(call.0)")
            } catch {
                XCTFail("\(call.0): unexpected error \(error)")
            }
        }

        XCTAssertEqual(CountingStubProtocol.requestCount, 0)
    }

    /// A `.notAuthenticated` raised locally says nothing about whether the
    /// stored credentials are good, so it must never be a reason to delete them.
    /// `.tokenExpired` and a 401 still are.
    func testNotAuthenticatedNeverDeletesPersistedCredentials() {
        XCTAssertFalse(
            WatchSessionRestoreCredentialPolicy
                .shouldDeletePersistedCredentials(after: .notAuthenticated)
        )
        XCTAssertTrue(
            WatchSessionRestoreCredentialPolicy
                .shouldDeletePersistedCredentials(after: .tokenExpired)
        )
    }

    // MARK: - Credential rotation

    private static let now = Date(timeIntervalSince1970: 1_787_000_000)

    /// The exact string the Codex CLI writes. `sharedISO8601Formatter` — the
    /// strict one `readAuthFile` used to call — returns nil for it, and nil used
    /// to mean "rotate". This is the regression pin: if the tolerant parser is
    /// swapped back out, `lastRefresh` goes nil and this fails.
    func testCodexCLITimestampParses() {
        XCTAssertNotNil(
            sharedISO8601Parse("2026-08-23T05:57:04.859771Z"),
            "the fractional-second form the Codex CLI writes must parse"
        )
        XCTAssertNil(
            ISO8601DateFormatter().date(from: "2026-08-23T05:57:04.859771Z"),
            "…and the strict formatter must still be the thing that could not"
        )
    }

    func testFreshJWTAccessTokenIsNotRotated() {
        let token = Self.jwt(expiringAt: Self.now.addingTimeInterval(240 * 3600))
        XCTAssertFalse(
            CodexCollector.needsRefresh(
                accessToken: token,
                lastRefresh: nil,
                now: Self.now
            ),
            "a token with 10 days of life left must not be rotated, even with no last_refresh"
        )
    }

    /// Brackets `renewalWindow` with absolute lifetimes rather than deriving the
    /// fixtures from the constant itself — a test written as
    /// `renewalWindow - 60` moves with the constant and therefore cannot
    /// notice it changing. These four cases pin it to somewhere in (24 h, 96 h],
    /// which is the range where "renew with slack in hand" is true and
    /// "renew on the refresh loop's cadence" is not.
    func testRenewalWindowBracket() {
        func rotates(hoursOfLifeLeft hours: Double) -> Bool {
            CodexCollector.needsRefresh(
                accessToken: Self.jwt(expiringAt: Self.now.addingTimeInterval(hours * 3600)),
                lastRefresh: nil,
                now: Self.now
            )
        }
        XCTAssertTrue(rotates(hoursOfLifeLeft: 1), "1 h of life left must renew")
        XCTAssertTrue(rotates(hoursOfLifeLeft: 24), "24 h of life left must renew")
        XCTAssertFalse(rotates(hoursOfLifeLeft: 96), "4 days of life left must not renew")
        XCTAssertFalse(rotates(hoursOfLifeLeft: 240), "a freshly issued token must not renew")
    }

    func testExpiredJWTAccessTokenIsRotated() {
        let token = Self.jwt(expiringAt: Self.now.addingTimeInterval(-3600))
        XCTAssertTrue(
            CodexCollector.needsRefresh(
                accessToken: token,
                lastRefresh: nil,
                now: Self.now
            )
        )
    }

    /// The whole defect in one assertion. Before the fix this combination —
    /// a live token and a timestamp written minutes ago — evaluated to `true`
    /// on every single collector pass.
    func testLiveTokenWithFractionalTimestampIsNotRotated() {
        let token = Self.jwt(expiringAt: Self.now.addingTimeInterval(200 * 3600))
        let lastRefresh = sharedISO8601Parse(
            sharedISO8601FractionalString(from: Self.now.addingTimeInterval(-600))
        )
        XCTAssertNotNil(lastRefresh)
        XCTAssertFalse(
            CodexCollector.needsRefresh(
                accessToken: token,
                lastRefresh: lastRefresh,
                now: Self.now
            )
        )
    }

    /// The call site, not just the parser. `testCodexCLITimestampParses` proves
    /// `sharedISO8601Parse` handles the fractional form, but it would stay green
    /// if `readAuthFile` were switched back to the strict formatter — so this
    /// drives the real file through the real reader.
    ///
    /// The fixture is byte-shaped like a Codex CLI `auth.json`: a JWT access
    /// token with a live `exp`, and a `last_refresh` in the fractional spelling
    /// the CLI actually writes. Before the fix, `needsRefresh` on this file was
    /// `true` — on every pass, forever.
    func testReadAuthFileOnACodexCLIShapedFileDoesNotAskForRotation() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-codex-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            unsetenv("CODEX_HOME")
            try? FileManager.default.removeItem(at: home)
        }

        let liveToken = Self.jwt(expiringAt: Date().addingTimeInterval(240 * 3600))
        let fixture: [String: Any] = [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-08-23T05:57:04.859771Z",
            "tokens": [
                "access_token": liveToken,
                "refresh_token": "rt-fixture",
                "id_token": "it-fixture",
                "account_id": UUID().uuidString,
            ],
        ]
        try JSONSerialization
            .data(withJSONObject: fixture)
            .write(to: home.appendingPathComponent("auth.json"))
        setenv("CODEX_HOME", home.path, 1)

        let auth = try XCTUnwrap(CodexCollector().readAuthFile())
        XCTAssertNotNil(
            auth.lastRefresh,
            "readAuthFile must parse the fractional-second last_refresh the Codex CLI writes"
        )
        XCTAssertFalse(
            auth.needsRefresh,
            "a live token plus a recent last_refresh must not trigger credential rotation"
        )
    }

    // MARK: - Non-JWT fallback

    func testOpaqueTokenFallsBackToLastRefreshAge() {
        XCTAssertFalse(
            CodexCollector.needsRefresh(
                accessToken: "sk-not-a-jwt",
                lastRefresh: Self.now.addingTimeInterval(-7 * 86400),
                now: Self.now
            ),
            "7 days old is inside the 8-day fallback window"
        )
        XCTAssertTrue(
            CodexCollector.needsRefresh(
                accessToken: "sk-not-a-jwt",
                lastRefresh: Self.now.addingTimeInterval(-9 * 86400),
                now: Self.now
            )
        )
    }

    /// Documented, deliberate: when neither the token nor the timestamp says
    /// anything, we still refresh. `fetchUsage` has no 401-retry, so refusing
    /// here would strand that user on a token nothing can renew. Written down
    /// so a future reader sees it as a decision rather than an oversight.
    func testUnknownAgeStillRefreshes() {
        XCTAssertTrue(
            CodexCollector.needsRefresh(
                accessToken: "sk-not-a-jwt",
                lastRefresh: nil,
                now: Self.now
            )
        )
        XCTAssertTrue(
            CodexCollector.needsRefresh(
                accessToken: nil,
                lastRefresh: nil,
                now: Self.now
            )
        )
    }

    func testMalformedJWTDoesNotCrashAndFallsBack() {
        for token in ["a.b", "a.b.c", "..", "a.!!!.c", ""] {
            XCTAssertNil(
                CodexCollector.jwtExpiry(token),
                "\(token) is not a readable JWT"
            )
            XCTAssertFalse(
                CodexCollector.needsRefresh(
                    accessToken: token,
                    lastRefresh: Self.now.addingTimeInterval(-3600),
                    now: Self.now
                ),
                "\(token) must fall back to the timestamp, not to rotation"
            )
        }
    }

    // MARK: - Helpers

    /// An unsigned JWT carrying one `exp` claim. `jwtExpiry` never verifies the
    /// signature — it only decides whether to ask for a new token — so a
    /// placeholder signature is the honest fixture here.
    private static func jwt(expiringAt date: Date) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = segment(["alg": "RS256", "typ": "JWT"])
        let payload = segment(["exp": Int(date.timeIntervalSince1970), "sub": "test"])
        return "\(header).\(payload).signature-not-verified"
    }
}

/// Counts every request that reaches the transport and answers 200 with an empty
/// JSON array. A test that expects silence asserts on the count; answering
/// successfully means a leak shows up as "0 expected, 1 recorded" rather than as
/// a decoding error somewhere else.
final class CountingStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingStubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); count += 1; lock.unlock()
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

#endif

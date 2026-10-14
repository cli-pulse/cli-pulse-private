import XCTest
@testable import CLIPulseCore

/// 1.57: a request that carries a credential is never written to a disk cache.
///
/// Up to 1.56 the collectors went through `URLSession.shared` and `APIClient`
/// through a `.default` configuration, and both store every cacheable
/// exchange in the app's `Cache.db`: the request with its headers and body,
/// and the answer. On a real Mac that file held bearer tokens for Codex,
/// Claude, Gemini and Vertex AI, the account's Supabase token, and a sign-in
/// POST with its password and the tokens it got back. Now every such request
/// goes through `CredentialedURLSession`, which keeps nothing, and each app
/// empties what earlier versions left, once.
///
/// What is pinned here: the session's configuration; that a cacheable answer
/// to a credentialed request reaches no cache through it, with a control that
/// shows the same answer IS stored the old way; that every injectable client
/// defaults to it; that no shipping source sends a credential through another
/// session (the guard a new collector meets); the one-time purge; and that
/// every app runs it before it sends anything.
final class CredentialedRequestsNoStoreTests: XCTestCase {

    // MARK: - The session

    func testTheSessionKeepsNothing() {
        let configurations = [
            ("CredentialedURLSession.shared", CredentialedURLSession.shared.configuration),
            ("makeConfiguration()", CredentialedURLSession.makeConfiguration()),
        ]
        for (label, configuration) in configurations {
            XCTAssertNil(configuration.urlCache, "\(label): a URL cache stores the token, the body and the answer")
            XCTAssertNil(configuration.httpCookieStorage, "\(label): a cookie jar keeps what providers set")
            XCTAssertFalse(configuration.httpShouldSetCookies, label)
            XCTAssertNil(configuration.urlCredentialStorage, label)
            XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData, label)
        }
    }

    /// The renderer's refuser has to be handed over before the session is
    /// made; once it exists, a late hand-over says so instead of pretending.
    func testALateInterceptorIsRefusedOutLoud() {
        _ = CredentialedURLSession.shared
        XCTAssertFalse(CredentialedURLSession.installInterceptor(CacheableAnswerProtocol.self))
        XCTAssertFalse(
            (CredentialedURLSession.shared.configuration.protocolClasses ?? [])
                .contains { ObjectIdentifier($0) == ObjectIdentifier(CacheableAnswerProtocol.self) }
        )
    }

    // MARK: - What reaches a cache

    /// A credentialed request whose answer a cache may store (200, max-age,
    /// `.allowed`) leaves nothing on disk through the session or through
    /// `APIClient`'s configuration. The control, the `.default` configuration
    /// `APIClient` used up to 1.56, stores the same answer, token included,
    /// in the very cache checked here: without it, "nothing stored" could
    /// mean the stub's answers are never stored at all.
    func testACacheableCredentialedAnswerReachesNoCache() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratch = URLCache(memoryCapacity: 0, diskCapacity: 20_000_000, directory: directory)
        let saved = URLCache.shared
        URLCache.shared = scratch
        defer { URLCache.shared = saved }

        let control = URLSessionConfiguration.default
        control.protocolClasses = [CacheableAnswerProtocol.self]
        let controlRequest = Self.credentialedRequest(path: "control", token: "control-canary-7f3a")
        _ = try await URLSession(configuration: control).data(for: controlRequest)
        let controlStored = await Self.eventually { scratch.cachedResponse(for: controlRequest) != nil }
        XCTAssertTrue(controlStored, "the control was not stored: this test would pass whatever the sessions did")
        let controlOnDisk = await Self.eventually { Self.files(in: directory, contain: "control-canary-7f3a") }
        XCTAssertTrue(controlOnDisk, "the control's token never reached the cache's files")

        let apiClient = APIClient(token: "t", supabaseURL: "https://example.invalid", supabaseAnonKey: "anon")
        let checked: [(String, URLSessionConfiguration)] = [
            ("CredentialedURLSession.shared", CredentialedURLSession.shared.configuration),
            ("APIClient", await apiClient.session.configuration),
        ]
        for (index, (label, configuration)) in checked.enumerated() {
            configuration.protocolClasses = [CacheableAnswerProtocol.self] + (configuration.protocolClasses ?? [])
            let canary = "nostore-canary-\(index)-c41d"
            let request = Self.credentialedRequest(path: "nostore-\(index)", token: canary)
            let (data, _) = try await URLSession(configuration: configuration).data(for: request)
            XCTAssertEqual(String(data: data, encoding: .utf8), CacheableAnswerProtocol.body, label)
            // Long enough for the control above to have landed on disk.
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertNil(scratch.cachedResponse(for: request), "\(label) stored a credentialed answer in URLCache.shared")
            XCTAssertNil(configuration.urlCache?.cachedResponse(for: request), "\(label) stored it in its own cache")
            XCTAssertFalse(Self.files(in: directory, contain: canary), "\(label)'s token reached the cache's files")
        }
    }

    // MARK: - Every injectable caller

    /// The clients that take a session default to the one that keeps nothing,
    /// and `APIClient`'s own session is made from its configuration, keeping
    /// the timeouts and the wait for connectivity it had.
    func testEveryInjectableCallerDefaultsToTheSession() async {
        let apiConfiguration = await APIClient().session.configuration
        XCTAssertNil(apiConfiguration.urlCache, "APIClient: the account's token and sign-in answers would be stored")
        XCTAssertNil(apiConfiguration.httpCookieStorage)
        XCTAssertFalse(apiConfiguration.httpShouldSetCookies)
        XCTAssertNil(apiConfiguration.urlCredentialStorage)
        XCTAssertEqual(apiConfiguration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(apiConfiguration.timeoutIntervalForResource, 30)
        XCTAssertTrue(apiConfiguration.waitsForConnectivity)

        let telemetry = SupabaseAnonymousTelemetryTransport(runtimeEnvironment: .current)
        XCTAssertTrue(telemetry.session === CredentialedURLSession.shared, "the telemetry POST")

        #if os(macOS)
        let helper = HelperAPIClient()
        let helperSession = await helper.session
        XCTAssertTrue(helperSession === CredentialedURLSession.shared, "the helper's RPCs carry its secret")
        let configured = HelperAPIClient(supabaseURL: "https://example.invalid", anonKey: "anon")
        let configuredSession = await configured.session
        XCTAssertTrue(configuredSession === CredentialedURLSession.shared)
        #endif
    }

    // MARK: - The guard a new collector meets

    /// Every network call in shipping Swift (CLIPulseCore and every app
    /// target) goes through `CredentialedURLSession`, except four fetches of
    /// public, unauthenticated data, which may use `URLSession.shared` as
    /// long as nothing in them looks like a credential. No other source may
    /// touch `URLSession.shared`, pass `.shared` as a session, or make a
    /// configuration of its own (`APIClient` makes its session from
    /// `CredentialedURLSession.makeConfiguration()`).
    func testNoShippingSourceSendsACredentialThroughAnotherSession() throws {
        let sources = try Self.shippingSources()
        var violations: [String] = []
        var networkFiles: Set<String> = []
        var credentialedFiles: Set<String> = []

        for (path, code) in sources {
            let name = (path as NSString).lastPathComponent
            let callsTheNetwork = Self.matches(code, Self.networkCall)
            let sharedSession = Self.matches(code, Self.sharedSession)
            let ownConfiguration = Self.matches(code, Self.ownConfiguration)
            let credential = Self.credentialMarkers(in: code)
            if callsTheNetwork { networkFiles.insert(name) }
            if !credential.isEmpty { credentialedFiles.insert(name) }
            guard callsTheNetwork || sharedSession || ownConfiguration else { continue }

            if name == "CredentialedURLSession.swift" {
                if sharedSession { violations.append("\(path): the session itself touches .shared") }
                continue
            }
            if let reason = Self.publicFetchers[name] {
                if !credential.isEmpty {
                    violations.append("\(path) (\(reason)) uses the shared session and sends \(credential.sorted())")
                }
                if ownConfiguration { violations.append("\(path): makes a session configuration of its own") }
                continue
            }
            if sharedSession {
                violations.append("\(path): uses URLSession.shared or passes .shared as a session")
            }
            if ownConfiguration {
                let fromTheSession = name == "APIClient.swift"
                    && code.contains("CredentialedURLSession.makeConfiguration()")
                    && !Self.matches(code, "URLSessionConfiguration\\s*\\.")
                if !fromTheSession {
                    violations.append("\(path): makes a session configuration of its own")
                }
            }
            if callsTheNetwork && !code.contains("CredentialedURLSession") {
                violations.append("\(path): calls the network without CredentialedURLSession")
            }
        }

        XCTAssertEqual(violations, [], "\n" + violations.joined(separator: "\n"))

        // The guard sees what it guards: a pattern that matched nothing would
        // pass every source, including a broken one.
        for known in ["CodexCollector.swift", "ClaudeOAuthStrategy.swift", "ClaudeWebStrategy.swift",
                      "CodexResetCreditsReader.swift", "APIClient.swift", "CurrencyConverter.swift",
                      "ProviderHTTPRetryPolicy.swift", "GeminiStatusProbe+DataLoader.swift"] {
            XCTAssertTrue(networkFiles.contains(known), "the guard no longer sees \(known)'s network call")
        }
        for known in ["CodexCollector.swift", "ClaudeOAuthStrategy.swift", "ClaudeWebStrategy.swift",
                      "APIClient.swift", "SupabaseAnonymousTelemetryTransport.swift", "GeminiCollector.swift",
                      "CursorCollector.swift", "WindsurfCollector.swift", "BedrockCollector.swift"] {
            XCTAssertTrue(credentialedFiles.contains(known), "the guard no longer sees \(known)'s credential")
        }
        XCTAssertGreaterThanOrEqual(networkFiles.count, 55, "fewer network call sites than 1.57 had: \(networkFiles.count)")
        #if os(macOS)
        XCTAssertTrue(networkFiles.contains("HelperAPIClient.swift"))
        XCTAssertTrue(credentialedFiles.contains("HelperAPIClient.swift"))
        #endif
    }

    /// The marker list catches each kind of credential the collectors send.
    func testTheCredentialMarkersCatchEveryKindOfCredential() {
        let samples = [
            #"request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")"#,
            #"request.setValue(cookie, forHTTPHeaderField: "Cookie")"#,
            #"request.setValue(key, forHTTPHeaderField: "xi-api-key")"#,
            #"request.setValue(key, forHTTPHeaderField: "X-DashScope-API-Key")"#,
            #"request.setValue(t, forHTTPHeaderField: "x-devin-session-token")"#,
            #"request.setValue(t, forHTTPHeaderField: "X-CSRFTOKEN")"#,
            #"request.addValue(anon, forHTTPHeaderField: "apikey")"#,
            #"let body = ["refresh_token": token]"#,
            #""p_helper_secret": config.helperSecret,"#,
            #"URLQueryItem(name: "key", value: apiKey)"#,
            #"request.allHTTPHeaderFields = ["Authorization": value]"#,
        ]
        for sample in samples {
            XCTAssertFalse(Self.credentialMarkers(in: sample).isEmpty, sample)
        }
        for harmless in [#"request.setValue("application/json", forHTTPHeaderField: "Accept")"#,
                         #"request.setValue("CLIPulseBar", forHTTPHeaderField: "User-Agent")"#] {
            XCTAssertTrue(Self.credentialMarkers(in: harmless).isEmpty, harmless)
        }
    }

    // MARK: - What earlier versions left

    /// The purge empties the URL cache, down to its files, and the cookie
    /// jar, once. Entries stored after it stay: a second launch does not
    /// purge again.
    func testThePurgeEmptiesTheCacheAndTheJarOnce() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = URLCache(memoryCapacity: 0, diskCapacity: 20_000_000, directory: directory)
        let defaults = isolatedDefaults()
        let jar = HTTPCookieStorage.shared
        let savedCookies = jar.cookies ?? []
        defer {
            jar.removeCookies(since: .distantPast)
            savedCookies.forEach(jar.setCookie)
        }

        let get = Self.credentialedRequest(path: "legacy-get", token: "legacy-header-canary-91be")
        var post = Self.credentialedRequest(path: "legacy-post", token: "legacy-post-header-canary")
        post.httpMethod = "POST"
        post.httpBody = Data(#"{"refresh_token":"legacy-body-canary-0d2e"}"#.utf8)
        for request in [get, post] {
            cache.storeCachedResponse(Self.cacheableAnswer(for: request, body: #"{"access_token":"legacy-answer-canary-5a8c"}"#),
                                      for: request)
        }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "purge-check.invalid", .path: "/", .name: "legacy", .value: "jar-canary",
            .expires: Date().addingTimeInterval(3_600),
        ]))
        jar.setCookie(cookie)

        let canaries = ["legacy-header-canary-91be", "legacy-body-canary-0d2e", "legacy-answer-canary-5a8c"]
        for canary in canaries {
            let stored = await Self.eventually { Self.files(in: directory, contain: canary) }
            XCTAssertTrue(stored, "precondition: \(canary) never reached the cache's files")
        }

        XCTAssertTrue(CredentialedURLSession.purgeLegacyStorageIfNeeded(defaults: defaults, cache: cache, cookies: jar))
        for canary in canaries {
            let gone = await Self.eventually { !Self.files(in: directory, contain: canary) }
            XCTAssertTrue(gone, "\(canary) is still in the cache's files after the purge")
        }
        XCTAssertNil(cache.cachedResponse(for: get))
        XCTAssertNil(cache.cachedResponse(for: post))
        XCTAssertFalse((jar.cookies ?? []).contains { $0.domain.contains("purge-check.invalid") }, "the jar kept its cookie")
        XCTAssertEqual(defaults.integer(forKey: CredentialedURLSession.purgeDoneKey), CredentialedURLSession.purgeVersion)

        // Once: the next launch leaves the cache alone.
        let later = Self.credentialedRequest(path: "after-purge", token: "after-purge")
        cache.storeCachedResponse(Self.cacheableAnswer(for: later, body: "{}"), for: later)
        let laterStored = await Self.eventually { cache.cachedResponse(for: later) != nil }
        XCTAssertTrue(laterStored)
        XCTAssertFalse(CredentialedURLSession.purgeLegacyStorageIfNeeded(defaults: defaults, cache: cache, cookies: jar))
        XCTAssertNotNil(cache.cachedResponse(for: later), "a second launch purged again")
    }

    /// The done-flag stays out of the app-owned namespace: the App Store to
    /// Developer ID move must not carry it (each build has its own cache to
    /// empty), and a new install with nothing but the flag is still new.
    func testThePurgeFlagIsNotAnAppOwnedKey() {
        let key = CredentialedURLSession.purgeDoneKey
        XCTAssertFalse(UnsandboxedDataMigration.appOwnedKeyPrefixes.contains { key.hasPrefix($0) })
        XCTAssertTrue(FirstRunPresentation.shouldPresent(existingKeys: [key], alreadyShown: false, hasSentinel: false))
    }

    /// Every app, and the LoginItem helper, purges at launch, before the
    /// first thing that can send a request is made; the QA renderer hands its
    /// refuser to the session before anything uses it.
    func testEveryAppPurgesBeforeItSendsAnything() throws {
        let purge = "CredentialedURLSession.purgeLegacyStorageIfNeeded()"
        let entries: [(file: String, before: String)] = [
            ("CLI Pulse Bar/CLIPulseBarApp.swift", "let state = AppState(runtimeEnvironment: runtimeEnvironment)"),
            ("CLIPulseHelper/HelperAppDelegate.swift", "let daemon = HelperDaemon("),
            ("CLI Pulse Bar iOS/CLIPulseApp_iOS.swift", "let state = AppState()"),
            ("CLI Pulse Bar Watch/CLIPulseApp_Watch.swift", "var body: some Scene"),
        ]
        for entry in entries {
            let code = try Self.shippingCode(at: entry.file)
            let purgeAt = try XCTUnwrap(code.range(of: purge), "\(entry.file) does not purge at launch")
            let firstUse = try XCTUnwrap(code.range(of: entry.before), "\(entry.file): '\(entry.before)' moved")
            XCTAssertTrue(purgeAt.lowerBound < firstUse.lowerBound, "\(entry.file) purges after '\(entry.before)'")
        }
        let renderer = try Self.shippingCode(at: "CLI Pulse Bar/QASnapshotRenderer.swift")
        let handOver = try XCTUnwrap(
            renderer.range(of: "CredentialedURLSession.installInterceptor(QARenderRefusingURLProtocol.self)"),
            "the QA renderer no longer refuses the collectors' requests"
        )
        let appMade = try XCTUnwrap(renderer.range(of: "let app = NSApplication.shared"))
        XCTAssertTrue(handOver.lowerBound < appMade.lowerBound)
    }

    // MARK: - Source scanning

    /// A network call.
    static let networkCall = #"\.(data|download|upload|bytes)\((for|from|with):|\b(data|download|upload|webSocket|stream)Task\(with"#
    /// `URLSession.shared`, or `.shared` handed over as a session.
    /// (Not `CredentialedURLSession.shared`: the look-behind.)
    static let sharedSession = #"(?<![A-Za-z0-9_])URLSession\s*\.\s*shared\b|(?i:session)\s*(:\s*URLSession\s*)?[:=]\s*\.shared\b"#
    /// A session made from a configuration of its own.
    static let ownConfiguration = #"URLSessionConfiguration\s*\.\s*(default|ephemeral|background)|(?<![A-Za-z0-9_])URLSession\s*(\.init)?\(\s*configuration:"#

    /// Public, unauthenticated fetches that may stay on `URLSession.shared`.
    static let publicFetchers: [String: String] = [
        "CurrencyConverter.swift": "exchange rates from a public endpoint",
        "ServiceStatus.swift": "providers' public status pages",
        "AppUpdater.swift": "the Developer ID update manifest and DMG",
        "HelperInstaller.swift": "the Companion manifest and package",
    ]

    /// What in a source looks like a credential: a header named for one, or
    /// a token, secret or password field in a body, an answer or a URL.
    static func credentialMarkers(in code: String) -> Set<String> {
        var found: Set<String> = []
        let header = try! NSRegularExpression(pattern: #"forHTTPHeaderField:\s*"([^"]+)""#)
        let range = NSRange(code.startIndex..., in: code)
        for match in header.matches(in: code, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: code) else { continue }
            let name = String(code[nameRange])
            if matches(name, #"(?i)auth|cookie|key|token|secret|session|csrf|password"#) { found.insert(name) }
        }
        let literals = #""(Authorization|Cookie|access_token|refresh_token|id_token|client_secret|p_helper_secret|helper_secret|sec_token|session_token|password|api_key)"\s*[:,\]]"#
        let literal = try! NSRegularExpression(pattern: literals)
        for match in literal.matches(in: code, range: range) {
            if let r = Range(match.range(at: 1), in: code) { found.insert(String(code[r])) }
        }
        let query = try! NSRegularExpression(pattern: #"URLQueryItem\(name:\s*"(key|api_key|token|access_token|sec_token)""#)
        for match in query.matches(in: code, range: range) {
            if let r = Range(match.range(at: 1), in: code) { found.insert("query \(code[r])") }
        }
        return found
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The directory holding the app targets and CLIPulseCore.
    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CLIPulseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // CLIPulseCore
            .deletingLastPathComponent()  // CLI Pulse Bar
    }

    /// Every shipping target's sources: CLIPulseCore and the five app targets.
    private static let sourceRoots = [
        "CLIPulseCore/Sources/CLIPulseCore", "CLI Pulse Bar", "CLI Pulse Bar iOS",
        "CLI Pulse Bar Watch", "CLI Pulse Widgets", "CLIPulseHelper",
    ]

    private static func shippingSources() throws -> [(path: String, code: String)] {
        var sources: [(String, String)] = []
        for root in sourceRoots {
            let base = projectRoot.appendingPathComponent(root)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = root + url.path.dropFirst(base.path.count)
                sources.append((relative, try shippingCode(at: relative)))
            }
        }
        XCTAssertGreaterThan(sources.count, 300, "the scan found too few sources: wrong root?")
        return sources
    }

    /// A source with its comments taken out: a call in a comment is not a
    /// call, and a doc comment may well say `URLSession.shared`.
    private static func shippingCode(at relativePath: String) throws -> String {
        let text = try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                // Cut a `//` comment that is not inside a string literal
                // (an even number of quotes before it), so URLs survive.
                var quotes = 0
                var previous: Character = " "
                for index in line.indices {
                    let character = line[index]
                    if character == "\"" { quotes += 1 }
                    if character == "/", previous == "/", quotes % 2 == 0 {
                        return line[line.startIndex..<line.index(before: index)]
                    }
                    previous = character
                }
                return line
            }
            .joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func credentialedRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://no-store-check.invalid/\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func cacheableAnswer(for request: URLRequest, body: String) -> CachedURLResponse {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: CacheableAnswerProtocol.headers)!
        return CachedURLResponse(response: response, data: Data(body.utf8), userInfo: nil, storagePolicy: .allowed)
    }

    private static func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-no-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "CredentialedRequestsNoStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// Whether any file under `directory` holds `canary`'s bytes.
    private static func files(in directory: URL, contain canary: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        let needle = Data(canary.utf8)
        for case let url as URL in enumerator {
            if let data = try? Data(contentsOf: url), data.range(of: needle) != nil { return true }
        }
        return false
    }

    /// True as soon as `condition` holds, polling for up to five seconds: the
    /// URL cache writes on a queue of its own.
    private static func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}

/// Answers every request with a 200 a cache may keep for an hour.
private final class CacheableAnswerProtocol: URLProtocol {
    static let body = #"{"ok":true}"#
    static let headers = ["Content-Type": "application/json", "Cache-Control": "max-age=3600"]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: Self.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

#if os(macOS)
import XCTest
import SQLite3
@testable import CLIPulseCore

/// 1.57 measurements on a real Mac. Both are off unless asked for, and both
/// print only hosts, paths with IDs cut out, header NAMES, the NAMES of
/// credential fields and HTTP status codes: no header value, no body, no
/// usage figure.
///
/// 1. The live Codex and Claude usage reads, sent as the app sends them now,
///    leave nothing in the URL cache; the same requests sent the way 1.56
///    sent them do, which shows the check can see a credentialed entry when
///    there is one. It sends this Mac's own Codex and Claude sign-ins, which
///    no test may do for whoever happens to run the suite:
///
///        CLIPULSE_LOCAL_CACHE_CHECK=1 swift test --filter CredentialedRequestsLocalCheckTests
///
///    The tokens come from `~/.codex/auth.json` and
///    `~/.claude/.credentials.json` (never the keychain), are never refreshed
///    and never printed. Both caches are throwaway directories, deleted at
///    the end.
///
/// 2. The caches the apps really keep hold no credentialed entry, whichever
///    caller it would have come from: this reads what every collector, the
///    account's client and the helper actually left, not a replay of chosen
///    requests. Read-only; it sends nothing. After a release has run once:
///
///        CLIPULSE_CACHE_INVENTORY="$HOME/Library/Caches/yyh.CLI-Pulse:$HOME/Library/Caches/yyh.CLI-Pulse.helper" \
///          swift test --filter CredentialedRequestsLocalCheckTests/testTheAppsRealCachesHoldNoCredential
final class CredentialedRequestsLocalCheckTests: XCTestCase {
    func testTheLiveUsageReadsLeaveNothingInTheCache() async throws {
        guard ProcessInfo.processInfo.environment["CLIPULSE_LOCAL_CACHE_CHECK"] == "1" else {
            throw XCTSkip("set CLIPULSE_LOCAL_CACHE_CHECK=1 to send this Mac's own Codex and Claude sign-ins")
        }
        let codex = Self.codexSignIn()
        let claude = Self.claudeToken()
        print("LOCAL_CACHE_CHECK sign-ins: Codex \(codex == nil ? "none usable" : "yes"), "
              + "Claude \(claude == nil ? "none usable" : "yes")")
        guard codex != nil || claude != nil else { throw XCTSkip("no usable Codex or Claude sign-in on this Mac") }

        let saved = URLCache.shared
        defer { URLCache.shared = saved }
        let after = try Self.scratchDirectory("after")
        let control = try Self.scratchDirectory("control")
        defer {
            try? FileManager.default.removeItem(at: after)
            try? FileManager.default.removeItem(at: control)
        }

        // 1. As the app sends them now. If anything still went through
        //    `URLSession.shared` or a `.default` configuration, it would land
        //    in this cache.
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 50_000_000, directory: after)
        if let codex {
            let usage = await Self.outcome {
                _ = try await CodexCollector().fetchUsage(accessToken: codex.token, accountId: codex.accountID)
            }
            let credits = await CodexResetCreditsFetcher.fetch(accessToken: codex.token, chatGPTAccountID: codex.accountID)
            print("LOCAL_CACHE_CHECK app: Codex /wham/usage \(usage); reset credits \(Self.describe(credits))")
        }
        if let claude {
            let usage = await Self.outcome { _ = try await ClaudeOAuthStrategy().fetchUsage(token: claude) }
            print("LOCAL_CACHE_CHECK app: Claude /api/oauth/usage \(usage)")
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let afterEntries = try Self.inventory(of: after)
        Self.report(afterEntries, label: "app")
        XCTAssertEqual(afterEntries.count, 0, "the app's reads left entries in the URL cache")
        XCTAssertFalse(afterEntries.contains(where: \.carriesACredential), "a credentialed entry")

        // 2. The control: the same requests through a session made the way
        //    1.56's APIClient made its own (`.default`, so this cache).
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 50_000_000, directory: control)
        let old = URLSession(configuration: .default)
        defer { old.invalidateAndCancel() }
        if let codex {
            let request = CodexCollector.usageRequest(accessToken: codex.token, accountId: codex.accountID)
            let status = await Self.status { try await old.data(for: request) }
            print("LOCAL_CACHE_CHECK control: Codex /wham/usage \(status)")
        }
        if let claude {
            let status = await Self.status { try await old.data(for: ClaudeOAuthStrategy.usageRequest(token: claude)) }
            print("LOCAL_CACHE_CHECK control: Claude /api/oauth/usage \(status)")
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let controlEntries = try Self.inventory(of: control)
        Self.report(controlEntries, label: "control")
        XCTAssertTrue(controlEntries.contains(where: \.carriesACredential),
                      "the control stored no credentialed entry: the check above would pass whatever the app did")
    }

    /// The real caches, read by names only: no stored request carries a
    /// credential header, a credential in its body or its query, and no
    /// stored answer carries a token. Before 1.57 the Mac app's held the
    /// Codex, Claude, Gemini, Vertex AI and Supabase requests with their
    /// tokens, so on a Mac still running 1.56 this fails, by name: that is
    /// its control.
    func testTheAppsRealCachesHoldNoCredential() throws {
        guard let list = ProcessInfo.processInfo.environment["CLIPULSE_CACHE_INVENTORY"], !list.isEmpty else {
            throw XCTSkip("set CLIPULSE_CACHE_INVENTORY to the cache directories to read, separated by ':'")
        }
        for path in list.split(separator: ":").map(String.init) {
            let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            let label = directory.lastPathComponent
            guard FileManager.default.fileExists(atPath: directory.path) else {
                Swift.print("LOCAL_CACHE_CHECK \(label): no such cache directory")
                continue
            }
            let entries = try Self.inventory(of: directory)
            Self.report(entries, label: label)
            let credentialed = entries.filter(\.carriesACredential)
            XCTAssertEqual(credentialed.count, 0, "\(label): \(credentialed.count) of \(entries.count) entries carry a credential")
        }
    }

    /// The inventory sees each place a credential can sit in a stored
    /// exchange: a header, the request body, the query, the answer.
    func testTheInventorySeesEveryPlaceACredentialSits() throws {
        let directory = try Self.scratchDirectory("inventory")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = URLCache(memoryCapacity: 0, diskCapacity: 20_000_000, directory: directory)

        func store(_ request: URLRequest, answer: String) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json", "Cache-Control": "max-age=3600"])!
            cache.storeCachedResponse(CachedURLResponse(response: response, data: Data(answer.utf8),
                                                        userInfo: nil, storagePolicy: .allowed), for: request)
        }
        var header = URLRequest(url: URL(string: "https://inventory.invalid/header")!)
        header.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        store(header, answer: "{}")
        var body = URLRequest(url: URL(string: "https://inventory.invalid/body")!)
        body.httpMethod = "POST"
        body.httpBody = Data(#"{"email":"e","password":"p"}"#.utf8)
        store(body, answer: "{}")
        store(URLRequest(url: URL(string: "https://inventory.invalid/query?key=k")!), answer: "{}")
        store(URLRequest(url: URL(string: "https://inventory.invalid/answer")!), answer: #"{"access_token":"a"}"#)
        store(URLRequest(url: URL(string: "https://inventory.invalid/public")!), answer: #"{"rates":{}}"#)

        var entries: [Entry] = []
        for _ in 0..<50 where entries.count < 5 {
            Thread.sleep(forTimeInterval: 0.1)
            entries = try Self.inventory(of: directory)
        }
        let byPlace = Dictionary(entries.map { ($0.place, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byPlace["inventory.invalid/header"]?.credentialHeaders, ["Authorization"])
        XCTAssertEqual(byPlace["inventory.invalid/body"]?.credentialFields, ["body password"])
        XCTAssertEqual(byPlace["inventory.invalid/query"]?.credentialFields, ["query key"])
        XCTAssertEqual(byPlace["inventory.invalid/answer"]?.credentialFields, ["answer access_token"])
        XCTAssertEqual(byPlace["inventory.invalid/public"]?.carriesACredential, false)
        XCTAssertEqual(entries.filter(\.carriesACredential).count, 4)
        XCTAssertFalse(entries.contains { $0.place.contains("password") || $0.place.contains("{") },
                       "a stored body leaked into what is printed: \(entries.map(\.place))")
        XCTAssertEqual(Self.redactedPlace("https://abcdefghijklmnop.supabase.co/rest/v1/rpc/x"), "<ref>.supabase.co/rest/v1/rpc/x")
        XCTAssertEqual(Self.redactedPlace("https://monitoring.googleapis.com/v3/projects/my-project/timeSeries"),
                       "monitoring.googleapis.com/v3/projects/<id>/timeSeries")
        XCTAssertEqual(Self.redactedPlace("https://h.invalid/oauth/tokengrant_type=x&secret=y"), "h.invalid/oauth/<id>")
    }

    // MARK: - Sign-ins (read, never printed, never refreshed)

    private struct CodexSignIn {
        let token: String
        let accountID: String?
    }

    private static func codexSignIn() -> CodexSignIn? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (realUserHome() as NSString).appendingPathComponent(".codex")
        guard let data = FileManager.default.contents(atPath: (home as NSString).appendingPathComponent("auth.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let expiry = CodexCollector.jwtExpiry(token), expiry > Date().addingTimeInterval(60)
        else { return nil }
        return CodexSignIn(token: token, accountID: tokens["account_id"] as? String)
    }

    private static func claudeToken() -> String? {
        let path = (realUserHome() as NSString).appendingPathComponent(".claude/.credentials.json")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
              Date(timeIntervalSince1970: expiresAt / 1000) > Date().addingTimeInterval(60)
        else { return nil }
        return token
    }

    // MARK: - Outcomes, without figures

    private static func outcome(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "answered"
        } catch let error as CollectorError {
            return "failed (\(CollectorError.logText(for: error)))"
        } catch {
            return "failed (\(type(of: error)))"
        }
    }

    private static func status(_ body: () async throws -> (Data, URLResponse)) async -> String {
        do {
            let (_, response) = try await body()
            return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
        } catch {
            return "failed (\(type(of: error)))"
        }
    }

    private static func describe(_ outcome: CodexResetCreditsFetcher.Outcome) -> String {
        switch outcome {
        case .fetched: return "answered"
        case .skippedStaleCredential: return "skipped (stale credential)"
        case .failed(let failure): return "failed (\(failure))"
        }
    }

    // MARK: - The cache, read by names only

    private struct Entry {
        let place: String
        let headerNames: [String]
        /// Credential fields found in the stored request's body or query, or
        /// in the stored answer: names only.
        var credentialFields: [String] = []
        var credentialHeaders: [String] {
            headerNames.filter { CredentialedRequestsLocalCheckTests.credentialHeaderNames.contains($0.lowercased()) }
        }
        var carriesACredential: Bool { !credentialHeaders.isEmpty || !credentialFields.isEmpty }
    }

    static let credentialHeaderNames: Set<String> = [
        "authorization", "cookie", "chatgpt-account-id", "apikey", "x-api-key", "x-goog-api-key",
        "proxy-authorization",
    ]

    /// Field names that hold a credential in a JSON or form body.
    static let credentialFieldNames = [
        "password", "refresh_token", "access_token", "id_token", "client_secret", "p_helper_secret",
        "helper_secret", "session_token", "sec_token", "api_key",
    ]

    /// Query items that carry a credential.
    static let credentialQueryNames: Set<String> = ["key", "api_key", "access_token", "token", "sec_token"]

    /// The credential field names in `data`, as a JSON key or a form field.
    private static func credentialFields(in data: Data) -> [String] {
        credentialFieldNames.filter { name in
            data.range(of: Data("\"\(name)\"".utf8)) != nil || data.range(of: Data("\(name)=".utf8)) != nil
        }
    }

    /// Every entry in the cache's `Cache.db`: host, path with IDs cut out,
    /// the stored request's header names, and the names of the credential
    /// fields in its body, its query or its stored answer (which sits in
    /// `fsCachedData` when it is large). No Cache.db means nothing was stored.
    private static func inventory(of directory: URL) throws -> [Entry] {
        let path = directory.appendingPathComponent("Cache.db").path
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw XCTSkip("could not open the throwaway Cache.db")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let query = """
            SELECT r.request_key, b.request_object, d.isDataOnFS, d.receiver_data FROM cfurl_cache_response r
            LEFT JOIN cfurl_cache_blob_data b ON b.entry_ID = r.entry_ID
            LEFT JOIN cfurl_cache_receiver_data d ON d.entry_ID = r.entry_ID
            """
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            // A database the cache created but never wrote a table to.
            return []
        }
        defer { sqlite3_finalize(statement) }
        var entries: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var key = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            var names: [String] = []
            var fields: Set<String> = []
            if let bytes = sqlite3_column_blob(statement, 1) {
                let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                if let plist = try? PropertyListSerialization.propertyList(from: blob, format: nil) {
                    names = headerNames(in: plist)
                    for body in dataValues(in: plist) {
                        credentialFields(in: body).forEach { fields.insert("body \($0)") }
                        // CFNetwork keys a request with a body by its URL with
                        // the body appended: cut it off before reading the URL.
                        if let text = String(data: body, encoding: .utf8), !text.isEmpty, key.hasSuffix(text) {
                            key = String(key.dropLast(text.count))
                        }
                    }
                }
            }
            for item in URLComponents(string: key)?.queryItems ?? [] where credentialQueryNames.contains(item.name.lowercased()) {
                fields.insert("query \(item.name)")
            }
            if let bytes = sqlite3_column_blob(statement, 3) {
                var answer = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
                if sqlite3_column_int(statement, 2) == 1,
                   let name = String(data: answer, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters),
                   !name.contains("/"), !name.isEmpty {
                    answer = (try? Data(contentsOf: directory.appendingPathComponent("fsCachedData").appendingPathComponent(name))) ?? Data()
                }
                credentialFields(in: answer).forEach { fields.insert("answer \($0)") }
            }
            entries.append(Entry(place: redactedPlace(key), headerNames: names.sorted(), credentialFields: fields.sorted()))
        }
        return entries
    }

    /// The keys of the dictionary that holds the request's headers (less
    /// CFNetwork's own `__hhaa__` copy of them).
    private static func headerNames(in plist: Any) -> [String] {
        if let dictionary = plist as? [String: Any] {
            if dictionary.values.allSatisfy({ $0 is String }), dictionary.keys.contains(where: { $0.contains("-") || $0.first?.isUppercase == true }) {
                return dictionary.keys.filter { !$0.hasPrefix("__") }
            }
            return dictionary.values.flatMap(headerNames(in:))
        }
        if let array = plist as? [Any] {
            return array.flatMap(headerNames(in:))
        }
        return []
    }

    /// The data values in the stored request: its body.
    private static func dataValues(in plist: Any) -> [Data] {
        if let data = plist as? Data { return [data] }
        if let dictionary = plist as? [String: Any] { return dictionary.values.flatMap(dataValues(in:)) }
        if let array = plist as? [Any] { return array.flatMap(dataValues(in:)) }
        return []
    }

    /// Host and path, with anything that could name an account cut out: a
    /// Supabase project's own host label, a segment after `projects`,
    /// `accounts` and the like, any long or numbered segment, and any that
    /// looks like a body or a form field. No query.
    static func redactedPlace(_ key: String) -> String {
        guard let components = URLComponents(string: key) else { return "<unparsed>" }
        var host = components.host ?? "?"
        if host.hasSuffix(".supabase.co") { host = "<ref>.supabase.co" }
        let owners: Set<String> = ["projects", "accounts", "organizations", "orgs", "users", "workspaces", "teams",
                                   "locations", "members", "subscriptions"]
        var previous = ""
        let path = components.path.split(separator: "/").map { segment -> String in
            defer { previous = segment.lowercased() }
            let digits = segment.filter(\.isNumber).count
            let bodyLike = segment.contains { "{}\"=&:%@".contains($0) }
            if owners.contains(previous) || segment.count > 24 || digits >= 4 || bodyLike { return "<id>" }
            return String(segment)
        }
        return host + "/" + path.joined(separator: "/")
    }

    private static func report(_ entries: [Entry], label: String) {
        Swift.print("LOCAL_CACHE_CHECK \(label): \(entries.count) cached entr\(entries.count == 1 ? "y" : "ies"), "
                    + "\(entries.filter(\.carriesACredential).count) with a credential")
        for entry in entries {
            let fields = entry.credentialFields.isEmpty ? "" : " credential fields=\(entry.credentialFields)"
            Swift.print("LOCAL_CACHE_CHECK \(label):   \(entry.place) headers=\(entry.headerNames)\(fields)")
        }
    }

    private static func scratchDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-cache-check-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif

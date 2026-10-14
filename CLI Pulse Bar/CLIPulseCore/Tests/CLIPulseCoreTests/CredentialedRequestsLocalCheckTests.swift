#if os(macOS)
import XCTest
import SQLite3
@testable import CLIPulseCore

/// 1.57 measurement on a real Mac: the live Codex and Claude usage reads, sent
/// as the app sends them now, leave nothing in the URL cache; the same
/// requests sent the way 1.56 sent them do, which shows the check can see a
/// credentialed entry when there is one.
///
/// Off unless asked for. It sends this Mac's own Codex and Claude sign-ins,
/// which no test may do for whoever happens to run the suite:
///
///     CLIPULSE_LOCAL_CACHE_CHECK=1 swift test --filter CredentialedRequestsLocalCheckTests
///
/// The tokens come from `~/.codex/auth.json` and `~/.claude/.credentials.json`
/// (never the keychain), are never refreshed and never printed. Both caches
/// are throwaway directories, deleted at the end. What is printed is hosts,
/// paths with IDs cut out, header NAMES and HTTP status codes: no header
/// value, no body, no usage figure.
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
        XCTAssertFalse(afterEntries.contains { !$0.credentialHeaders.isEmpty }, "a credentialed entry")

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
        XCTAssertTrue(controlEntries.contains { !$0.credentialHeaders.isEmpty },
                      "the control stored no credentialed entry: the check above would pass whatever the app did")
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
        var credentialHeaders: [String] {
            headerNames.filter { CredentialedRequestsLocalCheckTests.credentialHeaderNames.contains($0.lowercased()) }
        }
    }

    static let credentialHeaderNames: Set<String> = [
        "authorization", "cookie", "chatgpt-account-id", "apikey", "x-api-key",
    ]

    /// Every entry in the cache's `Cache.db`: host, path with IDs cut out, and
    /// the stored request's header names. No Cache.db means nothing was stored.
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
            SELECT r.request_key, b.request_object FROM cfurl_cache_response r
            LEFT JOIN cfurl_cache_blob_data b ON b.entry_ID = r.entry_ID
            """
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            // A database the cache created but never wrote a table to.
            return []
        }
        defer { sqlite3_finalize(statement) }
        var entries: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            var names: [String] = []
            if let bytes = sqlite3_column_blob(statement, 1) {
                let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                if let plist = try? PropertyListSerialization.propertyList(from: blob, format: nil) {
                    names = headerNames(in: plist)
                }
            }
            entries.append(Entry(place: redactedPlace(key), headerNames: names.sorted()))
        }
        return entries
    }

    /// The keys of the dictionary that holds the request's headers.
    private static func headerNames(in plist: Any) -> [String] {
        if let dictionary = plist as? [String: Any] {
            if dictionary.values.allSatisfy({ $0 is String }), dictionary.keys.contains(where: { $0.contains("-") || $0.first?.isUppercase == true }) {
                return Array(dictionary.keys)
            }
            return dictionary.values.flatMap(headerNames(in:))
        }
        if let array = plist as? [Any] {
            return array.flatMap(headerNames(in:))
        }
        return []
    }

    private static func redactedPlace(_ key: String) -> String {
        guard let components = URLComponents(string: key) else { return "<unparsed>" }
        let path = components.path.split(separator: "/").map { segment -> String in
            let digits = segment.filter(\.isNumber).count
            return segment.count > 24 || digits >= 4 ? "<id>" : String(segment)
        }
        return (components.host ?? "?") + "/" + path.joined(separator: "/")
    }

    private static func report(_ entries: [Entry], label: String) {
        Swift.print("LOCAL_CACHE_CHECK \(label): \(entries.count) cached entr\(entries.count == 1 ? "y" : "ies"), "
                    + "\(entries.filter { !$0.credentialHeaders.isEmpty }.count) with a credential header")
        for entry in entries {
            Swift.print("LOCAL_CACHE_CHECK \(label):   \(entry.place) headers=\(entry.headerNames)")
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

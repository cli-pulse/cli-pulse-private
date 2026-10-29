#if os(macOS)
import XCTest
import CommonCrypto
import Security
import SQLite3
@testable import CLIPulseCore

/// 1.60 (N2): the Chromium Safe Storage key is asked for only when a
/// host-matching row needs it, and the Keychain dialog only on a refresh a
/// person started.
///
/// Before, `ChromeCookieImporter.loadCookies` derived the key before reading
/// the database and always allowed interaction, so a Mac with Cursor (imported
/// by default) and several Chromium browsers could see one Keychain dialog per
/// browser on a timer refresh, even when no browser had a Cursor cookie.
///
/// The fixtures are real SQLite files in a temporary home folder laid out the
/// way Chrome lays out its profile, read through the production importer. The
/// Keychain is replaced by a recorder that answers a no-UI read with
/// "interaction not allowed" (an item this app is not yet trusted for) and an
/// interactive read with the password.
final class ChromeSafeStorageOrderTests: XCTestCase {

    private var home: URL!
    private let password = "fixture-safe-storage-password"

    override func setUpWithError() throws {
        try super.setUpWithError()
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-storage-order-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        if let home { try? FileManager.default.removeItem(at: home) }
        try super.tearDownWithError()
    }

    // MARK: - Keychain recorder

    private final class KeychainRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Bool] = []
        let password: String

        init(password: String) { self.password = password }

        var interactive: [Bool] { lock.lock(); defer { lock.unlock() }; return calls }
        var interactiveCount: Int { interactive.filter { $0 }.count }

        var lookup: ChromeCookieImporter.SafeStoragePasswordLookup {
            { [self] _, _, allowInteraction in
                lock.lock(); calls.append(allowInteraction); lock.unlock()
                return allowInteraction
                    ? (errSecSuccess, password)
                    : (errSecInteractionNotAllowed, nil)
            }
        }
    }

    // MARK: - Fixtures

    private struct Row {
        let host: String
        let name: String
        let plain: String
        let encrypted: Data
    }

    /// Writes `Library/Application Support/Google/Chrome/Default/Cookies`.
    @discardableResult
    private func makeChromeProfile(rows: [Row]) throws -> URL {
        let profile = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let url = profile.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db); throw XCTSkip("sqlite open failed")
        }
        defer { sqlite3_close(db) }
        let create = """
        CREATE TABLE cookies (
            host_key TEXT, name TEXT, path TEXT, expires_utc INTEGER,
            is_secure INTEGER, is_httponly INTEGER, value TEXT, encrypted_value BLOB
        );
        """
        XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)
        for row in rows {
            var stmt: OpaquePointer?
            let insert = "INSERT INTO cookies VALUES (?, ?, '/', 0, 1, 1, ?, ?)"
            XCTAssertEqual(sqlite3_prepare_v2(db, insert, -1, &stmt, nil), SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, row.host, -1, transient)
            sqlite3_bind_text(stmt, 2, row.name, -1, transient)
            sqlite3_bind_text(stmt, 3, row.plain, -1, transient)
            _ = row.encrypted.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, 4, bytes.baseAddress, Int32(row.encrypted.count), transient)
            }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        return url
    }

    private func store(_ url: URL) -> BrowserCookieStore {
        BrowserCookieStore(
            browser: .chrome,
            profile: BrowserProfile(id: "test", name: "Default"),
            kind: .primary,
            label: "Chrome Default",
            databaseURL: url)
    }

    /// Chrome's macOS key: PBKDF2-SHA1(password, "saltysalt", 1003), 16 bytes.
    private func derivedKey() -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress, passBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress, keyLength)
                }
            }
        }
        return key
    }

    /// Chrome's `v10` value: AES-128-CBC, IV of 16 spaces, PKCS7.
    private func encryptV10(_ value: String) -> Data {
        let key = derivedKey()
        let plaintext = Data(value.utf8)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outLen = 0
        let cap = out.count
        let status = out.withUnsafeMutableBytes { o in
            plaintext.withUnsafeBytes { p in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { ivb in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, ivb.baseAddress,
                                p.baseAddress, plaintext.count,
                                o.baseAddress, cap, &outLen)
                    }
                }
            }
        }
        precondition(status == Int32(kCCSuccess))
        out.count = outLen
        return Data("v10".utf8) + out
    }

    private func load(
        _ url: URL,
        interactive: Bool,
        recorder: KeychainRecorder
    ) throws -> [ChromeCookieImporter.CookieRecord] {
        try ChromeCookieImporter.$passwordLookupOverrideForTesting.withValue(recorder.lookup) {
            try ChromeCookieImporter.loadCookies(
                from: store(url),
                matchingDomains: ["cursor.com"],
                domainMatch: .contains,
                allowKeychainInteraction: interactive)
        }
    }

    // MARK: - Order: rows first, key second

    /// No host-matching row: the Keychain is not touched at all, not even by
    /// the no-UI read. Before N2 the key was derived first, unconditionally.
    func test_noMatchingRow_asksForNoKey() throws {
        let url = try makeChromeProfile(rows: [
            Row(host: ".example.com", name: "sid", plain: "", encrypted: encryptV10("elsewhere")),
        ])
        let recorder = KeychainRecorder(password: password)
        let records = try load(url, interactive: true, recorder: recorder)
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(recorder.interactive, [], "no matching row must mean no Keychain read")
    }

    /// Matching rows that are stored in plain text need no key either.
    func test_matchingPlainRowOnly_asksForNoKey() throws {
        let url = try makeChromeProfile(rows: [
            Row(host: ".cursor.com", name: "plain", plain: "visible", encrypted: Data()),
            Row(host: ".example.com", name: "sid", plain: "", encrypted: encryptV10("elsewhere")),
        ])
        let recorder = KeychainRecorder(password: password)
        let records = try load(url, interactive: true, recorder: recorder)
        XCTAssertEqual(records.map(\.value), ["visible"])
        XCTAssertEqual(recorder.interactive, [])
    }

    /// A matching encrypted row on a refresh a person started: the no-UI read
    /// first, then exactly one interactive request, and the value decrypts.
    func test_matchingEncryptedRow_userInitiated_asksExactlyOnce() throws {
        let url = try makeChromeProfile(rows: [
            Row(host: ".cursor.com", name: "WorkosCursorSessionToken", plain: "", encrypted: encryptV10("tok-1")),
            Row(host: "www.cursor.com", name: "other", plain: "", encrypted: encryptV10("tok-2")),
        ])
        let recorder = KeychainRecorder(password: password)
        let records = try load(url, interactive: true, recorder: recorder)
        XCTAssertEqual(Set(records.map(\.value)), ["tok-1", "tok-2"])
        XCTAssertEqual(recorder.interactive, [false, true], "one no-UI read, then exactly one request")
    }

    /// The same row on a background refresh: only the no-UI read, and an
    /// error that is not a denial.
    func test_matchingEncryptedRow_background_neverInteractive() throws {
        let url = try makeChromeProfile(rows: [
            Row(host: ".cursor.com", name: "WorkosCursorSessionToken", plain: "", encrypted: encryptV10("tok-1")),
        ])
        let recorder = KeychainRecorder(password: password)
        XCTAssertThrowsError(try load(url, interactive: false, recorder: recorder)) { error in
            guard case ChromeCookieImporter.ImportError.keychainApprovalNeeded = error else {
                return XCTFail("expected keychainApprovalNeeded, got \(error)")
            }
        }
        XCTAssertEqual(recorder.interactive, [false])
    }

    // MARK: - The refresh's origin reaches the Keychain read

    private func importer() -> BrowserCookieAutoImporter {
        BrowserCookieAutoImporter(
            client: BrowserCookieClient(configuration: .init(homeDirectories: [home])),
            browsers: [.chrome])
    }

    @MainActor
    private func importHeader(
        _ importer: BrowserCookieAutoImporter,
        recorder: KeychainRecorder,
        through manager: DataRefreshManager,
        as interaction: RefreshInteraction
    ) async -> String? {
        let box = HeaderBox()
        await ChromeCookieImporter.$passwordLookupOverrideForTesting.withValue(recorder.lookup) {
            await manager.requestRefresh(interaction) {
                box.header = await importer.importCookieHeader(
                    domains: CursorCollector.cookieDomains,
                    knownSessionCookieNames: [],
                    logger: nil)
            }.value
        }
        return box.header
    }

    @MainActor
    private final class HeaderBox { var header: String? }

    @MainActor
    private func manager() -> DataRefreshManager {
        DataRefreshManager(api: APIClient(
            supabaseURL: "https://stub.cli-pulse.test",
            supabaseAnonKey: "anon"))
    }

    /// Timer, adaptive tick and helper notice call `requestRefresh(using:)`
    /// with no interaction: never a dialog. A manual refresh afterwards still
    /// asks once — the background miss was not remembered as a refusal.
    @MainActor
    func test_backgroundRefresh_neverInteractive_thenManualRefreshAsksOnce() async throws {
        try makeChromeProfile(rows: [
            Row(host: ".cursor.com", name: "WorkosCursorSessionToken", plain: "", encrypted: encryptV10("tok-1")),
        ])
        let recorder = KeychainRecorder(password: password)
        let importer = importer()
        let manager = manager()

        let background = await importHeader(importer, recorder: recorder, through: manager, as: .background)
        XCTAssertNil(background)
        XCTAssertFalse(recorder.interactive.isEmpty, "the no-UI read still runs")
        XCTAssertEqual(recorder.interactiveCount, 0, "a background refresh never allows the dialog")

        let manual = await importHeader(importer, recorder: recorder, through: manager, as: .userInitiated)
        XCTAssertEqual(manual, "WorkosCursorSessionToken=tok-1")
        XCTAssertEqual(recorder.interactiveCount, 1, "a manual refresh asks exactly once")
    }

    /// The default of `requestRefresh(using:)` is background.
    @MainActor
    func test_requestRefreshDefault_isBackground() async {
        let manager = manager()
        let box = InteractionBox()
        await manager.requestRefresh { box.value = RefreshInteraction.current }.value
        XCTAssertEqual(box.value, .background)
        await manager.requestRefresh(.userInitiated) { box.value = RefreshInteraction.current }.value
        XCTAssertEqual(box.value, .userInitiated)
    }

    @MainActor
    private final class InteractionBox { var value: RefreshInteraction? }

    // MARK: - Wiring the tests above cannot see

    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar

    private func source(_ relative: String) throws -> String {
        let raw = try String(contentsOf: Self.appSources.appendingPathComponent(relative), encoding: .utf8)
        return raw.components(separatedBy: "\n").map { line -> String in
            guard let comment = line.range(of: "//") else { return line }
            return String(line[..<comment.lowerBound])
        }.joined(separator: "\n")
    }

    /// The Mac's three refresh controls are the manual refresh, and the
    /// manual refresh is the one that passes `.userInitiated`.
    func test_macRefreshControls_requestTheManualRefresh() throws {
        for file in ["CLI Pulse Bar/OverviewTab.swift", "CLI Pulse Bar/MenuBarView.swift", "CLI Pulse Bar/CLIPulseBarApp.swift"] {
            XCTAssertTrue(try source(file).contains("requestManualRefresh()"), "\(file) refresh control")
        }
        let core = try source("CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift")
        guard let start = core.range(of: "public func requestManualRefresh() {") else {
            return XCTFail("requestManualRefresh is gone")
        }
        let body = core[start.upperBound...].prefix { $0 != "}" }
        XCTAssertTrue(body.contains("requestRefresh(.userInitiated)"), String(body))
    }
}
#endif

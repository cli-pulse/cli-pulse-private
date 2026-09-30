import XCTest
@testable import CLIPulseCore

/// G1 (CodexBar-parity Phase A) — verifies the shared cookie resolution
/// ladder: manual > env > (opt-in) auto-import > unavailable, and that the
/// dark-ship guarantee holds (no auto-import unless `.automatic`).
final class CookieResolverTests: XCTestCase {

    /// Stub importer returning a fixed header, recording whether it was called.
    private actor StubImporter: CookieImporting {
        let header: String?
        private(set) var callCount = 0
        init(header: String?) { self.header = header }
        func wasCalled() -> Int { callCount }
        func importCookieHeader(
            domains: [String],
            knownSessionCookieNames: Set<String>,
            logger: (@Sendable (String) -> Void)?
        ) async -> String? {
            callCount += 1
            return header
        }
    }

    private func config(cookieSource: CookieSource?, manual: String? = nil) -> ProviderConfig {
        var c = ProviderConfig(kind: .cursor, cookieSource: cookieSource)
        c.manualCookieHeader = manual
        return c
    }

    func test_manual_header_takes_precedence_and_skips_importer() async {
        let importer = StubImporter(header: "auto=1")
        let result = await CookieResolver.resolve(
            config: config(cookieSource: .automatic, manual: "manual=abc"),
            envVarNames: [],
            domains: ["cursor.com"],
            knownSessionCookieNames: [],
            importer: importer)
        XCTAssertEqual(result.headerValue, "manual=abc")
        if case .manual = result {} else { XCTFail("expected .manual") }
        let calls = await importer.wasCalled()
        XCTAssertEqual(calls, 0, "importer must not run when a manual header exists")
    }

    func test_automatic_not_attempted_when_source_is_nil_or_manual() async {
        for src in [CookieSource?.none, .some(.manual), .some(.safari)] {
            let importer = StubImporter(header: "auto=1")
            let result = await CookieResolver.resolve(
                config: config(cookieSource: src),
                envVarNames: [],
                domains: ["cursor.com"],
                knownSessionCookieNames: [],
                importer: importer)
            XCTAssertEqual(result.headerValue, nil)
            if case .unavailable = result {} else { XCTFail("expected .unavailable for \(String(describing: src))") }
            let calls = await importer.wasCalled()
            XCTAssertEqual(calls, 0, "auto-import must be opt-in (dark-ship)")
        }
    }

    func test_automatic_uses_importer_when_opted_in() async {
        let importer = StubImporter(header: "WorkosCursorSessionToken=xyz")
        let result = await CookieResolver.resolve(
            config: config(cookieSource: .automatic),
            envVarNames: [],
            domains: ["cursor.com"],
            knownSessionCookieNames: [],
            importer: importer)
        XCTAssertEqual(result.headerValue, "WorkosCursorSessionToken=xyz")
        if case .automatic = result {} else { XCTFail("expected .automatic") }
    }

    func test_automatic_falls_through_to_unavailable_when_importer_finds_nothing() async {
        let importer = StubImporter(header: nil)
        let result = await CookieResolver.resolve(
            config: config(cookieSource: .automatic),
            envVarNames: [],
            domains: ["cursor.com"],
            knownSessionCookieNames: [],
            importer: importer)
        if case .unavailable = result {} else { XCTFail("expected .unavailable") }
    }

    // MARK: - Strict privacy mode (v1.55)

    /// A browser's cookies, and the "Safe Storage" keychain item that
    /// decrypts them, are another app's secrets: under Strict privacy mode the
    /// importer is not run, even for a provider set to read them automatically.
    func test_strict_privacy_mode_skips_the_browser_import() async {
        let importer = StubImporter(header: "WorkosCursorSessionToken=xyz")
        let result = await CookieResolver.resolve(
            config: config(cookieSource: .automatic),
            envVarNames: [],
            domains: ["cursor.com"],
            knownSessionCookieNames: [],
            importer: importer,
            browserImportAllowed: false)
        if case .unavailable = result {} else { XCTFail("expected .unavailable under Strict privacy mode") }
        let calls = await importer.wasCalled()
        XCTAssertEqual(calls, 0, "Strict privacy mode must not open a browser's cookie store")
    }

    func test_strict_privacy_mode_keeps_the_cookie_the_user_entered() async {
        let importer = StubImporter(header: "auto=1")
        let result = await CookieResolver.resolve(
            config: config(cookieSource: .automatic, manual: "manual=abc"),
            envVarNames: [],
            domains: ["cursor.com"],
            knownSessionCookieNames: [],
            importer: importer,
            browserImportAllowed: false)
        XCTAssertEqual(result.headerValue, "manual=abc")
    }

    func test_the_privacy_overload_follows_the_switch_in_the_app_and_the_helper() async {
        let name = "CookieResolverTests-\(UUID().uuidString)"
        let groupName = name + "-group"
        defer {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            UserDefaults(suiteName: groupName)?.removePersistentDomain(forName: groupName)
        }
        let app = PrivacySettings(defaults: UserDefaults(suiteName: name)!)

        func imports(_ privacy: PrivacySettings) async -> Int {
            let importer = StubImporter(header: "WorkosCursorSessionToken=xyz")
            _ = await CookieResolver.resolve(
                config: config(cookieSource: .automatic),
                envVarNames: [],
                domains: ["cursor.com"],
                importer: importer,
                privacy: privacy)
            return await importer.wasCalled()
        }

        // Negative control: Strict privacy mode off, the import runs.
        let offCalls = await imports(app)
        XCTAssertEqual(offCalls, 1)
        app.localOnlyMode = true
        let onCalls = await imports(app)
        XCTAssertEqual(onCalls, 0)

        // The LoginItem helper: the app's copy decides, and no copy means skip.
        let group = UserDefaults(suiteName: groupName)!
        let helper = PrivacySettings(defaults: UserDefaults(suiteName: name + "-helper")!)
        defer { UserDefaults(suiteName: name + "-helper")?.removePersistentDomain(forName: name + "-helper") }
        helper.followAppCopy(in: group)
        let noCopyCalls = await imports(helper)
        XCTAssertEqual(noCopyCalls, 0)
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: false, localOnlyMode: false), to: group)
        let copyOffCalls = await imports(helper)
        XCTAssertEqual(copyOffCalls, 1)
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: true), to: group)
        let copyOnCalls = await imports(helper)
        XCTAssertEqual(copyOnCalls, 0)
        // "Skip Claude Code keychain access" alone names Claude Code's item only.
        HelperPrivacyInputs.mirror(HelperPrivacyInputs(skipClaudeKeychain: true, localOnlyMode: false), to: group)
        let skipOnlyCalls = await imports(helper)
        XCTAssertEqual(skipOnlyCalls, 1)
    }

    func test_null_importer_is_safe_default_off_macos_path() async {
        let result = await CookieResolver.resolve(
            config: config(cookieSource: .automatic),
            envVarNames: [],
            domains: ["cursor.com"],
            knownSessionCookieNames: [],
            importer: NullCookieImporter())
        if case .unavailable = result {} else { XCTFail("NullCookieImporter must yield .unavailable") }
    }
}

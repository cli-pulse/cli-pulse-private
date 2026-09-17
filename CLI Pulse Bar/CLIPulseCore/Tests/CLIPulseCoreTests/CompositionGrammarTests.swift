import XCTest
@testable import CLIPulseCore

/// Sentences the app builds out of pieces: counts, tokens from the helper and the
/// server, names, and captions. Each failure here is text a user reads as broken
/// grammar ("1 sesiones", "已安装：replaced", "Claude Estado del servicio", "总 TOKEN").
///
/// Asserted in es, ja and the Chinese locales. English passes most of these with
/// the fix removed, because the English fallback and the English plural often
/// read the same.
final class CompositionGrammarTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    private func use(_ localization: String) {
        LocaleOverrideStore.shared.set(localization)
    }

    // MARK: - Singular counts

    /// Every count accessor picks its `_one` key for 1 and the plural key for
    /// anything else. Spanish is where the two forms differ for all of them.
    func testCountsUseTheSingularFormForOneInSpanish() {
        use("es")
        let cases: [(String, (Int) -> String, String)] = [
            ("watch.sessions_count", L10n.watch.sessionsCount, "1 sesión"),
            ("watch.devices_count", L10n.watch.devicesCount, "1 dispositivo"),
            ("watch.alerts_count", L10n.watch.alertsCount, "1 alerta"),
            ("watch.active_count", L10n.watch.activeCount, "1 activo"),
            ("widget.alerts_summary", L10n.widget.alertsSummary, "1 alerta • CLI\u{00A0}Pulse"),
            ("yield.commits_count", L10n.yield.commitsCount, "1 commit"),
            ("onboarding_wizard.undetected_providers", L10n.onboardingWizard.undetectedProviders,
             "No se encontró 1 agente optimizado"),
            ("providers.tracked_count", L10n.providers.trackedCount, "1 supervisado"),
        ]
        for (key, accessor, expectedOne) in cases {
            XCTAssertEqual(accessor(1), expectedOne, key)
            XCTAssertEqual(accessor(2), String(format: L10n.displayFormat(key), 2), "\(key) plural")
            XCTAssertNotEqual(accessor(2).replacingOccurrences(of: "2", with: "1"), expectedOne,
                              "\(key): es singular and plural are the same text, so this case proves nothing")
        }
    }

    /// `messagesShort` used to take the already-formatted number, so it could not
    /// know the count was 1. It now takes the count and formats it itself.
    func testMessageCountPicksTheSingularAndStillCompactsLargeNumbers() {
        use("es")
        XCTAssertEqual(L10n.providers.messagesShort(1), "1 mensaje")
        XCTAssertEqual(L10n.providers.messagesShort(12), "12 mensajes")
        XCTAssertEqual(L10n.providers.messagesShort(1_500), CostFormatter.formatUsage(1_500) + " mensajes")
    }

    /// The free-plan migration banner: `disabled` is the count that can be 1.
    func testTierMigrationVerbAgreesWithOneDisabledProvider() {
        use("es")
        let one = L10n.menuBar.tierMigration(kept: 3, disabled: 1)
        XCTAssertTrue(one.contains("Se desactivó 1: edítalo "), one)
        let two = L10n.menuBar.tierMigration(kept: 3, disabled: 2)
        XCTAssertTrue(two.contains("Se desactivaron 2: edítalos "), two)
    }

    // MARK: - Helper tokens inside sentences

    /// The hook banner used to print the helper's protocol token in the sentence:
    /// "已安装：replaced — …", "Removed: removed (1 hooks)". The token is data;
    /// the sentence is chosen from it.
    func testHookResultSentencesNeverShowTheHelperToken() {
        use("zh-Hans")
        let path = "/Users/me/.claude/settings.json"
        for token in ["created", "added", "replaced", "noop"] {
            let line = L10n.sessions.hookInstallOutcome(action: token, settingsPath: path)
            XCTAssertFalse(line.contains(token), "install \(token): \(line)")
            XCTAssertTrue(line.hasSuffix(path), line)
            XCTAssertFalse(line.contains("%"), line)
        }
        XCTAssertEqual(
            Set(["created", "added", "replaced", "noop"].map {
                L10n.sessions.hookInstallOutcome(action: $0, settingsPath: path)
            }).count, 4, "each install outcome needs its own sentence")

        let removed = L10n.sessions.hookUninstallOutcome(action: "removed", removed: 2, settingsPath: path)
        XCTAssertFalse(removed.contains("removed"), removed)
        XCTAssertTrue(removed.contains("2"), removed)
        let nothing = L10n.sessions.hookUninstallOutcome(action: "noop", removed: 0, settingsPath: path)
        XCTAssertFalse(nothing.contains("noop"), nothing)
        XCTAssertFalse(nothing.contains("0"), "nothing was removed, so there is no count to show: \(nothing)")

        // A token from a newer helper still says what happened, in the old template.
        let future = L10n.sessions.hookInstallOutcome(action: "merged", settingsPath: path)
        XCTAssertTrue(future.contains("merged"), future)
    }

    func testOneRemovedHookIsSingularInSpanish() {
        use("es")
        XCTAssertEqual(
            L10n.sessions.hookUninstallOutcome(action: "removed", removed: 1, settingsPath: "/p"),
            "Se quitó 1 hook — /p")
        XCTAssertEqual(
            L10n.sessions.hookUninstallOutcome(action: "removed", removed: 3, settingsPath: "/p"),
            "Se quitaron 3 hooks — /p")
    }

    /// The permission migration banner inserted "Notifications, Accessibility" into
    /// Chinese and Japanese sentences and buttons.
    func testPermissionNamesAreTranslatedAndJoinedInTheSentencesLanguage() {
        use("zh-Hans")
        XCTAssertEqual(L10n.appUpdater.permissionName("Notifications"), "通知")
        XCTAssertEqual(L10n.appUpdater.permissionName("Accessibility"), "辅助功能")
        XCTAssertEqual(L10n.appUpdater.permissionName("FullDiskAccess"), "FullDiskAccess",
                       "an id with no translation is shown as it is, not dropped")

        let list = L10n.appUpdater.permissionList(["Notifications", "Accessibility"])
        XCTAssertTrue(list.contains("通知") && list.contains("辅助功能"), list)
        XCTAssertFalse(list.contains("Notifications") || list.contains("Accessibility"), list)
        XCTAssertFalse(list.contains(", "), "English list separator in a Chinese sentence: \(list)")

        use("ja")
        let japanese = L10n.appUpdater.permissionList(["Notifications", "Accessibility"])
        XCTAssertFalse(japanese.contains(", "), japanese)
        XCTAssertEqual(L10n.appUpdater.permissionList(["Accessibility"]), "アクセシビリティ")
    }

    /// The re-grant buttons. The CJK templates kept the space they needed when the
    /// argument was the English id, so the translated name read "打开 通知…" and
    /// "アクセシビリティ を開く…". The name is quoted as a pane name instead.
    func testOpenPermissionButtonHasNoSpaceInsideTheCJKPhrase() {
        use("zh-Hans")
        XCTAssertEqual(L10n.appUpdater.openPermissionButton("Notifications"), "打开「通知」…")
        XCTAssertEqual(L10n.appUpdater.openPermissionButton("Accessibility"), "打开「辅助功能」…")
        use("zh-Hant")
        XCTAssertEqual(L10n.appUpdater.openPermissionButton("Accessibility"), "開啟「輔助使用」…")
        use("ja")
        XCTAssertEqual(L10n.appUpdater.openPermissionButton("Notifications"), "「通知」を開く…")
        XCTAssertEqual(L10n.appUpdater.openPermissionButton("Accessibility"), "「アクセシビリティ」を開く…")
        // Languages that separate words keep the space. ko marks the pane name the way
        // its catalogue marks UI labels, as in machine.fan_approve_prompt's
        // '로그인 항목 및 확장 프로그램', where zh and ja use 「」.
        use("ko")
        XCTAssertEqual(L10n.appUpdater.openPermissionButton("Accessibility"), "'손쉬운 사용' 열기…")
        XCTAssertEqual(L10n.appUpdater.openPermissionButton("Notifications"), "'알림' 열기…")
        use("es")
        XCTAssertEqual(L10n.appUpdater.openPermissionButton("Notifications"), "Abrir Notificaciones…")
    }

    /// `cost_status` is a server token; the badge shows it as its capsule abbreviation.
    func testCostStatusTokenIsShownTranslated() {
        use("zh-Hant")
        XCTAssertEqual(CostStatusBadge.label(for: "Estimated"), L10n.badge.estimated)
        XCTAssertEqual(CostStatusBadge.label(for: "Exact"), L10n.badge.exact)
        XCTAssertEqual(CostStatusBadge.label(for: "Unavailable"), L10n.badge.unavailable)
        XCTAssertFalse(CostStatusBadge.label(for: "Estimated").lowercased().contains("estimated"))
    }

    /// The macOS cost tile printed the token in English, then briefly the badge's
    /// abbreviation as plain text: "EST" beside a price reads as a time zone, and
    /// es "ESTIMADO" shouts. Plain text gets the sentence-case words.
    func testCostStatusAsPlainTextIsSentenceCaseNotTheBadgeAbbreviation() {
        use("es")
        XCTAssertEqual(L10n.cost.statusLabel("Estimated"), "Estimado")
        XCTAssertEqual(L10n.cost.statusLabel("Exact"), "Exacto")
        XCTAssertEqual(L10n.cost.statusLabel("Unavailable"), "No disponible")
        XCTAssertNotEqual(L10n.cost.statusLabel("Estimated"), L10n.badge.estimated)
        XCTAssertNotEqual(L10n.cost.statusLabel("Unavailable"), L10n.badge.unavailable)

        use("en")
        XCTAssertEqual(L10n.cost.statusLabel("Estimated"), "Estimated")
        XCTAssertNotEqual(L10n.cost.statusLabel("Estimated"), "EST")
        XCTAssertEqual(L10n.cost.statusLabel("Unavailable"), "Unavailable")

        use("zh-Hant")
        XCTAssertEqual(L10n.cost.statusLabel("Estimated"), "預估")
        use("ja")
        XCTAssertEqual(L10n.cost.statusLabel("Unavailable"), "不明")
        XCTAssertEqual(L10n.cost.statusLabel("SomethingNew"), "SomethingNew",
                       "an unknown token is shown as it arrived, as the subtitle did before")
    }

    // MARK: - Word order and labels

    func testServiceStatusLabelUsesSpanishWordOrder() {
        use("es")
        XCTAssertEqual(L10n.providers.serviceStatusFor("Claude"), "Estado del servicio de Claude")
    }

    /// The Watch account row with no observation time read "数据已过期 · —更新".
    func testStaleAccountWithoutTimestampGetsItsOwnLabel() {
        use("zh-Hans")
        let account = ProviderAccountUsage(
            id: UUID(),
            provider: .claude,
            accountLabel: nil,
            planEvidence: ProviderPlanEvidence(
                rawValue: "pro", displayValue: "Pro", source: .providerAPI,
                confidence: .high, observedAt: nil),
            quota: 100, remaining: 50, tiers: [], resetTime: nil,
            observedAt: nil, sourceDeviceID: nil, statusText: "Operational")

        let label = ProviderAccountPresentation.freshnessLabel(for: account)
        XCTAssertEqual(label, L10n.watch.staleNoTimestamp)
        XCTAssertEqual(label, "数据已过期")
        XCTAssertFalse(label.contains("—"), label)
    }

    /// A bare 高 beside an icon does not say what is high.
    func testConfidenceBadgeNamesWhatItMeasures() {
        use("ja")
        let high = L10n.badge.confidence("high")
        XCTAssertNotEqual(high, L10n.badge.high, "still the bare adjective")
        XCTAssertTrue(high.contains("信頼度") && high.contains("高"), high)
        XCTAssertNotEqual(L10n.badge.confidence("medium"), L10n.badge.confidence("low"))
        XCTAssertEqual(L10n.badge.confidence("weird"), "Weird",
                       "an unrecognised value keeps the raw token, as before")
    }

    // MARK: - Captions

    /// `uppercased()` on a Chinese caption shouts only its Latin loanwords.
    func testCaptionCaseLeavesScriptsWithoutCaseAlone() {
        use("zh-Hant")
        XCTAssertEqual(L10n.captionCase("Token 總數"), "Token 總數")
        use("ja")
        XCTAssertEqual(L10n.captionCase("API キー"), "API キー")
        use("es")
        XCTAssertEqual(L10n.captionCase("Costo total"), "COSTO TOTAL")
    }

    // MARK: - The brand

    /// No catalogue string, in any shipped language, can break a line inside
    /// "CLI Pulse". The sweep reads every key from the shipped `.strings` files, so
    /// a new string is covered the moment it is added.
    func testCLIPulseIsUnbreakableInEveryDisplayedString() throws {
        for localization in LocaleOverrideStore.shippedLocalizations {
            use(localization)
            let values = try catalogue(localization)
            let brandKeys = values.filter { $0.value.contains("CLI Pulse") }.map(\.key)
            XCTAssertGreaterThan(brandKeys.count, 50, "\(localization): the sweep found too few brand strings to mean anything")
            for key in brandKeys {
                let shown = L10n.displayFormat(key)
                XCTAssertFalse(shown.contains("CLI Pulse"), "\(localization) \(key) can still break inside the brand")
                XCTAssertEqual(
                    shown.components(separatedBy: "CLI\u{00A0}Pulse").count,
                    values[key]!.components(separatedBy: "CLI Pulse").count,
                    "\(localization) \(key): brand count changed")
            }
        }
        use("zh-Hans")
        XCTAssertTrue(L10n.account.linkedAccountsFooter.contains("同一 CLI\u{00A0}Pulse 账户"))
    }

    /// The swap starts where the search found the first brand, so the text before
    /// it survives and every later brand is joined too; text with no brand, most of
    /// every catalogue, comes back as it was.
    func testBrandSwapJoinsEveryOccurrenceAndLeavesBrandlessTextAlone() {
        XCTAssertEqual(L10n.keepingBrandUnbroken("同一 CLI Pulse 账户与 CLI Pulse Helper"),
                       "同一 CLI\u{00A0}Pulse 账户与 CLI\u{00A0}Pulse Helper")
        XCTAssertEqual(L10n.keepingBrandUnbroken("打开「通知」…"), "打开「通知」…")
        XCTAssertEqual(L10n.keepingBrandUnbroken(""), "")
    }

    /// Text written to logs keeps the plain space, so it can still be grepped.
    func testLoggedEnglishKeepsThePlainSpace() {
        use("zh-Hans")
        XCTAssertEqual(CredentialProblem(nil, .tokenExpiredReconnectOAuth).englishText,
                       "token expired — reconnect via CLI Pulse OAuth")
    }

    /// Arguments are user data and stay exactly as given.
    func testBrandSwapDoesNotTouchInterpolatedArguments() {
        use("en")
        XCTAssertEqual(L10n.providers.serviceStatusFor("CLI Pulse Helper"), "CLI Pulse Helper Service Status")
    }

    private func catalogue(_ localization: String) throws -> [String: String] {
        let bundle = try XCTUnwrap(LocaleOverrideStore.bundle(forLocalization: localization))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }
}

/// Input typed through a Japanese or Chinese input source in full-width mode.
final class UserInputNormalizationTests: XCTestCase {

    func testFullWidthSignInCodeIsSentAsASCIIDigits() {
        XCTAssertEqual(UserInputNormalization.otpCode("１２３４５６"), "123456")
        XCTAssertEqual(UserInputNormalization.otpCode("　１２３ ４５６\n"), "123456")
        XCTAssertEqual(UserInputNormalization.otpCode("123456"), "123456")
    }

    func testFullWidthDeleteConfirmsButOtherWordsDoNot() {
        XCTAssertTrue(UserInputNormalization.isDeleteConfirmation("DELETE"))
        XCTAssertTrue(UserInputNormalization.isDeleteConfirmation("ＤＥＬＥＴＥ"))
        XCTAssertFalse(UserInputNormalization.isDeleteConfirmation("delete"), "the typed word stays exact")
        XCTAssertFalse(UserInputNormalization.isDeleteConfirmation("DELET"))
        XCTAssertFalse(UserInputNormalization.isDeleteConfirmation(""))
    }

    func testFullWidthSearchFindsTheProvider() {
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "Claude", query: "ｃｌａｕｄｅ"))
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "OpenRouter", query: "ＲＯＵＴＥＲ"))
    }
}

#if os(macOS)

/// The call that sends the code, not only the helper that folds it.
///
/// `testFullWidthSignInCodeIsSentAsASCIIDigits` passes even when `verifyOTP`
/// stops calling the helper, and the server then gets "１２３４５６" again. This
/// one reads the body of the request that actually leaves `APIClient`.
final class VerifyOTPRequestBodyTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        // The app in Japanese, with a Japanese input source in full-width mode.
        LocaleOverrideStore.shared.set("ja")
        VerifyOTPStubProtocol.reset()
    }

    override func tearDown() {
        VerifyOTPStubProtocol.reset()
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    func testFullWidthCodeLeavesAPIClientAsASCIIDigits() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerifyOTPStubProtocol.self]
        let api = APIClient(
            supabaseURL: "https://stub.cli-pulse.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: config)
        )

        // The stub rejects the code, so the call throws before any profile fetch.
        _ = try? await api.verifyOTP(email: "a@b.c", code: "　１２３ ４５６")

        let bodies = VerifyOTPStubProtocol.verifyBodies()
        XCTAssertEqual(bodies.count, 1, "exactly one request to /auth/v1/verify")
        let body = try XCTUnwrap(bodies.first)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["token"] as? String, "123456")
        XCTAssertEqual(root["email"] as? String, "a@b.c")
        XCTAssertEqual(root["type"] as? String, "email")
    }
}

/// Records the body of every /auth/v1/verify request and answers 400.
private final class VerifyOTPStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [Data] = []

    static func reset() {
        lock.lock(); bodies = []; lock.unlock()
    }

    static func verifyBodies() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/auth/v1/verify" {
            let body = Self.materializedBody(of: request)
            Self.lock.lock(); Self.bodies.append(body); Self.lock.unlock()
        }
        let url = request.url ?? URL(string: "https://stub.cli-pulse.test")!
        let response = HTTPURLResponse(
            url: url, statusCode: 400, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"otp_invalid"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not as `httpBody`.
    private static func materializedBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

#endif

/// Sign in with Apple names are written in the order of their own script.
final class AppleSignInNameTests: XCTestCase {

    private func name(given: String?, family: String?) -> PersonNameComponents {
        var components = PersonNameComponents()
        components.givenName = given
        components.familyName = family
        return components
    }

    func testEastAsianNamesAreFamilyFirstWithoutASpace() {
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "太郎", family: "山田")), "山田太郎")
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "小明", family: "王")), "王小明")
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "민준", family: "김")), "김민준")
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "花子", family: "佐々木")), "佐々木花子")
    }

    /// Katakana alone is how Japanese writes a foreign name, and the name keeps its
    /// own given-first order. Reordering it would store "ジャクソンマイケル" as the account name.
    func testKatakanaOnlyNamesAreForeignNamesAndKeepGivenFirstOrder() {
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "マイケル", family: "ジャクソン")), "マイケル ジャクソン")
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "ﾏｲｹﾙ", family: "ｼﾞｬｸｿﾝ")), "ﾏｲｹﾙ ｼﾞｬｸｿﾝ",
                       "half-width katakana is still katakana")
    }

    /// Katakana beside Han or hiragana is a Japanese name with a katakana part.
    func testKatakanaBesideHanOrHiraganaStaysFamilyFirst() {
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "エミ", family: "山田")), "山田エミ")
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "メイ", family: "さとう")), "さとうメイ")
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "さくら", family: "やまだ")), "やまださくら")
    }

    func testOtherNamesKeepGivenFamilyOrder() {
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "John", family: "Appleseed")), "John Appleseed")
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "Taro", family: "山田")), "Taro 山田",
                       "a mixed-script name has no single convention, so it is left as given")
    }

    func testPartialOrMissingNames() {
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: "太郎", family: nil)), "太郎")
        XCTAssertEqual(AppleSignInName.fullName(from: name(given: nil, family: "Appleseed")), "Appleseed")
        XCTAssertNil(AppleSignInName.fullName(from: name(given: " ", family: "")))
        XCTAssertNil(AppleSignInName.fullName(from: nil))
    }
}

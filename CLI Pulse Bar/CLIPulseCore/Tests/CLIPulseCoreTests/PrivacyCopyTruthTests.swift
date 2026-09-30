import XCTest
@testable import CLIPulseCore
#if os(macOS)
import Darwin
#endif

/// v1.55 — the in-app privacy copy says what 1.55 does, not what an earlier
/// promise said. Each claim below was false before this change; the policy
/// (PRIVACY.md, "It describes CLI Pulse 1.55") is what it was checked against.
///
/// Asserted in a non-English locale wherever the point is the translation: in
/// English a broken lookup returns English, so an en-only check passes with
/// every catalogue still saying the old thing. The English checks pin only the
/// sentences that were false in English.
final class PrivacyCopyTruthTests: XCTestCase {

    private static let locales = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]

    private var saved: String?
    override func setUp() { super.setUp(); saved = LocaleOverrideStore.shared.override }
    override func tearDown() { LocaleOverrideStore.shared.set(saved); super.tearDown() }

    private func inLocale<T>(_ locale: String, _ body: () throws -> T) rethrows -> T {
        LocaleOverrideStore.shared.set(locale)
        return try body()
    }

    /// Every string this change rewrote or added, by key.
    private func changed() -> [String: String] {
        [
            "onboarding_wizard.privacy_raw_detail": L10n.onboardingWizard.privacyRawDetail,
            "onboarding_wizard.privacy_keys_detail": L10n.onboardingWizard.privacyKeysDetail,
            "onboarding_wizard.helper_hint": L10n.onboardingWizard.helperHint,
            "advanced.privacy_keys_detail": L10n.advanced.privacyKeysDetail,
            "advanced.privacy_logs_detail": L10n.advanced.privacyLogsDetail,
            "advanced.privacy_sessions_title": L10n.advanced.privacySessionsTitle,
            "advanced.privacy_sessions_detail": L10n.advanced.privacySessionsDetail,
            "advanced.track_git_hint": L10n.advanced.trackGitHint,
            "local_scan_consent.derived_title": L10n.localScanConsent.derivedTitle,
            "local_scan_consent.derived_detail": L10n.localScanConsent.derivedDetail,
            "local_scan_consent.keychain_title": L10n.localScanConsent.keychainTitle,
            "local_scan_consent.keychain_detail": L10n.localScanConsent.keychainDetail,
            "local_scan_consent.declined_body": L10n.localScanConsent.declinedBody,
            "local_scan_consent.settings_toggle_detail": L10n.localScanConsent.settingsToggleDetail,
            "local_scan_consent.companion_not_covered": L10n.localScanConsent.companionNotCovered("v1.30.0"),
            "telemetry.not_collected": L10n.telemetry.notCollected,
            "telemetry.settings_body": L10n.telemetry.settingsBody,
            "settings.privacy_redacted_hint": L10n.settings.privacyRedactedHint,
            "settings.skip_claude_keychain_hint": L10n.settings.skipClaudeKeychainHint,
            "settings.companion_ignores_switches": L10n.settings.companionIgnoresSwitches("v1.30.0"),
            "helper.install_intro": L10n.helper.installIntro,
        ]
    }

    func test_everyRewrittenStringIsTranslatedInEveryLanguage() {
        let english = inLocale("en") { changed() }
        for locale in Self.locales {
            let localized = inLocale(locale) { changed() }
            for (key, text) in localized {
                XCTAssertFalse(text.isEmpty, "\(locale): \(key) is empty")
                XCTAssertFalse(text.hasPrefix(key), "\(locale): \(key) renders the raw key")
                if locale != "en" {
                    XCTAssertNotEqual(text, english[key], "\(locale): \(key) is the English text")
                }
            }
        }
    }

    // MARK: - The sentences that were false

    /// "Sync mode uploads only…" left out the running sessions the helper
    /// uploads; "live only in your Keychain" covered cookies read from a
    /// browser; "only in folders you've given access to" is the App Store
    /// build only; "reads nothing" and "not reading anything" missed the
    /// Sessions tab's read of Claude Code's settings; "deleted when you
    /// uninstall" is not what moving an app to the Trash does; and remote
    /// control is not the only way data leaves the Mac.
    func test_theEnglishNoLongerMakesTheFalseClaims() {
        inLocale("en") {
            XCTAssertFalse(L10n.onboardingWizard.privacyRawDetail.contains("uploads only"))
            XCTAssertTrue(L10n.onboardingWizard.privacyRawDetail.contains("project folder"))
            XCTAssertTrue(L10n.onboardingWizard.privacyKeysDetail.contains("you enter"))
            XCTAssertTrue(L10n.advanced.privacyKeysDetail.contains("you enter"))
            XCTAssertTrue(L10n.advanced.privacyLogsDetail.contains("The App Store version reads only"))
            XCTAssertFalse(L10n.localScanConsent.declinedBody.contains("reading anything"))
            XCTAssertFalse(L10n.localScanConsent.settingsToggleDetail.contains("reads nothing"))
            XCTAssertTrue(L10n.localScanConsent.settingsToggleDetail.contains("the app and its background helper"))
            for text in [L10n.telemetry.notCollected, L10n.telemetry.settingsBody] {
                XCTAssertFalse(text.contains("uninstall"), text)
                XCTAssertTrue(text.hasSuffix("moving the app to the Trash leaves behind."), text)
            }
            XCTAssertFalse(L10n.settings.privacyRedactedHint.contains("Nothing else leaves"))
            XCTAssertTrue(L10n.settings.privacyRedactedHint.contains("Remote control sends no"))
            XCTAssertFalse(L10n.settings.skipClaudeKeychainHint.contains("owned by other apps"))
        }
    }

    /// The same corrections, spelled out once in Simplified Chinese, the
    /// locale these catalogues are checked in.
    func test_zhHansSaysWhat155Does() {
        inLocale("zh-Hans") {
            let raw = L10n.onboardingWizard.privacyRawDetail
            XCTAssertFalse(raw.contains("只上传"), raw)
            XCTAssertTrue(raw.contains("程序名和项目文件夹名"), raw)
            XCTAssertTrue(L10n.onboardingWizard.privacyKeysDetail.hasPrefix("你输入的"))
            XCTAssertTrue(L10n.advanced.privacyKeysDetail.hasPrefix("你输入的"))
            XCTAssertEqual(L10n.advanced.privacyLogsDetail, "在本机扫描，永不上传。App Store 版只读取你授权的文件夹。")
            XCTAssertEqual(L10n.advanced.privacySessionsTitle, "正在运行的 AI CLI 会话")
            XCTAssertTrue(L10n.localScanConsent.derivedDetail.contains("正在运行的程序"))
            XCTAssertTrue(L10n.localScanConsent.derivedDetail.contains("开启后台同步"))
            XCTAssertTrue(L10n.localScanConsent.keychainDetail.contains("Zed"))
            XCTAssertTrue(L10n.localScanConsent.keychainDetail.contains("Cookie 密钥"))
            let declined = L10n.localScanConsent.declinedBody.replacingOccurrences(of: "\u{00A0}", with: " ")
            XCTAssertEqual(declined, "CLI Pulse 没有扫描这台 Mac，所以暂时没有可显示的数据。")
            XCTAssertTrue(L10n.localScanConsent.settingsToggleDetail.hasSuffix("关闭后，应用及其后台 Helper 都不会扫描这台 Mac。"))
            for text in [L10n.telemetry.notCollected, L10n.telemetry.settingsBody] {
                XCTAssertFalse(text.contains("卸载即删除"), text)
                XCTAssertTrue(text.hasSuffix("把应用移到废纸篓不会删除它。"), text)
            }
            XCTAssertFalse(L10n.settings.privacyRedactedHint.contains("任何内容都不会离开"))
            XCTAssertTrue(L10n.settings.skipClaudeKeychainHint.contains("凭据文件，仍会读取"))
            XCTAssertTrue(L10n.advanced.trackGitHint.hasSuffix("由 Companion CLI 收集。"))
            let intro = L10n.helper.installIntro
            XCTAssertTrue(intro.contains("每 2 分钟"), intro)
            XCTAssertTrue(intro.contains("1.30.0 及更早的版本不做这项检查"), intro)
            XCTAssertTrue(intro.contains("隐私政策"), intro)
            XCTAssertTrue(L10n.onboardingWizard.helperHint.contains("隐私政策"))
        }
    }

    /// The Companion's notes name the version the app found, and the settings
    /// path that fixes it, in every language.
    func test_theCompanionNotesNameTheVersionAndTheWayOut() {
        for locale in Self.locales {
            inLocale(locale) {
                for note in [L10n.localScanConsent.companionNotCovered("v1.30.0"),
                             L10n.settings.companionIgnoresSwitches("v1.30.0")] {
                    XCTAssertTrue(note.contains("v1.30.0"), "\(locale): \(note)")
                    XCTAssertFalse(note.contains("%@"), "\(locale): \(note)")
                    // Sent to the section that updates or removes it, named
                    // the way this language's helper hint names it.
                    XCTAssertTrue(note.contains(" › Companion CLI"), "\(locale): \(note)")
                    XCTAssertTrue(L10n.onboardingWizard.helperHint.contains(" › Companion CLI"), locale)
                }
                XCTAssertTrue(L10n.localScanConsent.companionNotCovered("v1.30.0").contains("2"), locale)
                XCTAssertTrue(L10n.helper.installIntro.contains("1.30.0"), locale)
                XCTAssertTrue(L10n.localScanConsent.keychainDetail.contains("Zed"), locale)
                XCTAssertTrue(L10n.advanced.trackGitHint.contains("Companion CLI"), locale)
            }
        }
        inLocale("ko") {
            // Korean keeps no particle straight after the version's closing
            // bracket, where a line could start with it.
            let note = L10n.localScanConsent.companionNotCovered("v1.30.0")
            XCTAssertTrue(note.contains("(설치된 버전: v1.30.0)."), note)
        }
    }

    /// Each language's old claim about the install id, gone.
    func test_noLanguageSaysTheInstallIDIsDeletedOnUninstall() {
        let old = ["en": "deleted when you uninstall", "es": "se elimina al desinstalar",
                   "ja": "アンインストールすると削除", "ko": "앱을 삭제하면 함께 삭제",
                   "zh-Hans": "卸载即删除", "zh-Hant": "解除安裝即刪除"]
        for locale in Self.locales {
            inLocale(locale) {
                for text in [L10n.telemetry.notCollected, L10n.telemetry.settingsBody] {
                    XCTAssertFalse(text.contains(old[locale]!), "\(locale): \(text)")
                }
            }
        }
    }

    // MARK: - Which Companion the notes are about

    private func hello(
        implementation: String? = "python-pkg",
        version: String = "1.30.0",
        paired: Bool? = true,
        follows: Bool = false
    ) -> SessionControlHello {
        SessionControlHello(
            protocolVersion: 1,
            supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(sendInput: true, subscribeEvents: false, approvals: false),
            helperVersion: version,
            paired: paired,
            implementation: implementation,
            followsAppAnswer: follows
        )
    }

    func test_aPairedCompanionThatDoesNotSaySoIsNamed() {
        XCTAssertEqual(CompanionAnswerCoverage.ignoringVersion(hello: hello()), "1.30.0")
        // Before 1.43 the Companion did not say which helper it was.
        XCTAssertEqual(CompanionAnswerCoverage.ignoringVersion(hello: hello(implementation: nil)), "1.30.0")
        // Before 1.30.2 it did not say whether it was paired, so it may be.
        XCTAssertEqual(CompanionAnswerCoverage.ignoringVersion(hello: hello(paired: nil)), "1.30.0")
        // Before 1.16 it reported no version at all.
        XCTAssertEqual(CompanionAnswerCoverage.ignoringVersion(hello: hello(version: "")), "")
    }

    /// Not a version floor: the Companion that follows the answer still said
    /// 1.30.0 when it learned to.
    func test_aCompanionThatFollowsTheAnswerIsNotNamedWhateverItsVersion() {
        XCTAssertNil(CompanionAnswerCoverage.ignoringVersion(hello: hello(follows: true)))
        XCTAssertNil(CompanionAnswerCoverage.ignoringVersion(hello: hello(version: "1.29.0", follows: true)))
    }

    func test_nothingIsNamedWhenNothingThatUploadsAnswers() {
        XCTAssertNil(CompanionAnswerCoverage.ignoringVersion(hello: nil))
        // The built-in agent uploads nothing.
        XCTAssertNil(CompanionAnswerCoverage.ignoringVersion(hello: hello(implementation: "swift-bundled")))
        // Not paired: no account to send to.
        XCTAssertNil(CompanionAnswerCoverage.ignoringVersion(hello: hello(paired: false)))
    }

    func test_theVersionLabelFollowsTheDisplayLanguage() {
        XCTAssertEqual(CompanionAnswerCoverage.versionLabel("1.30.0"), "v1.30.0")
        inLocale("zh-Hans") {
            XCTAssertEqual(CompanionAnswerCoverage.versionLabel(""), "旧版本")
            XCTAssertEqual(CompanionAnswerCoverage.versionLabel(" "), "旧版本")
        }
    }
}

#if os(macOS)

/// The app learns `follows_app_answer` from the Companion's `hello` and keeps
/// it on `HelperInstaller`, which the popover probes when it opens, so the
/// first ask can show the note.
final class CompanionAnswerCoverageWiringTests: XCTestCase {

    private func hello(follows: Bool, implementation: String = "python-pkg") -> SessionControlHello {
        SessionControlHello(
            protocolVersion: 1,
            supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(sendInput: true, subscribeEvents: false, approvals: false),
            helperVersion: "1.30.0",
            paired: true,
            implementation: implementation,
            followsAppAnswer: follows
        )
    }

    @MainActor
    func test_theInstallerKeepsWhatTheLastProbeFound() async {
        var reply: SessionControlHello? = hello(follows: false)
        let installer = makeProbeOnlyHelperInstaller { ScriptedHelloClient(reply: reply, delayNanoseconds: 0) }
        XCTAssertNil(installer.companionIgnoringAnswerVersion, "nothing probed yet")

        await installer.refresh()
        XCTAssertEqual(installer.companionIgnoringAnswerVersion, "1.30.0")

        reply = hello(follows: true)
        await installer.refresh()
        XCTAssertNil(installer.companionIgnoringAnswerVersion, "updated to one that follows the answer")

        reply = hello(follows: false, implementation: "swift-bundled")
        await installer.refresh()
        XCTAssertNil(installer.companionIgnoringAnswerVersion)

        reply = hello(follows: false)
        await installer.refresh()
        XCTAssertEqual(installer.companionIgnoringAnswerVersion, "1.30.0")
        reply = nil
        await installer.refresh()
        XCTAssertNil(installer.companionIgnoringAnswerVersion, "uninstalled")
    }

    /// Answers one `hello` with `result`.
    private final class ReplyingServer {
        let socketPath: String
        let tokenPath: String
        private let fd: Int32

        init(result: [String: Any]) throws {
            let unique = UUID().uuidString.prefix(8)
            socketPath = "\(NSTemporaryDirectory())cps-cov-\(unique).sock"
            tokenPath = "\(NSTemporaryDirectory())cps-cov-token-\(unique).txt"
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
                throw NSError(domain: "ReplyingServer", code: Int(errno))
            }
            let serverFD = fd
            let replyData = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
            Thread {
                let client = accept(serverFD, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var header = [UInt8](repeating: 0, count: 4)
                guard recv(client, &header, 4, MSG_WAITALL) == 4 else { return }
                let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16
                                 | UInt32(header[2]) << 8 | UInt32(header[3]))
                var body = [UInt8](repeating: 0, count: length)
                _ = recv(client, &body, length, MSG_WAITALL)
                let request = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
                var reply = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any] ?? [:]
                reply["id"] = request?["id"] ?? "1"
                guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
                var size = UInt32(data.count).bigEndian
                _ = withUnsafeBytes(of: &size) { send(client, $0.baseAddress, 4, 0) }
                _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) }
            }.start()
        }

        func stop() {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
    }

    private func parsed(_ flag: Any?) async throws -> Bool {
        var result: [String: Any] = [
            "protocol_version": 1,
            "supported_methods": ["hello"],
            "capabilities": [:] as [String: Any],
            "helper_version": "1.30.0",
            "implementation": "python-pkg",
        ]
        if let flag { result["follows_app_answer"] = flag }
        let server = try ReplyingServer(result: result)
        defer { server.stop() }
        let client = LocalSessionControlClient(
            socketPath: server.socketPath,
            tokenPath: server.tokenPath,
            connectTimeout: 2,
            requestTimeout: 2,
            runtimeEnvironment: TestRuntimeFixtures.productionApp
        )
        return try await client.hello().followsAppAnswer
    }

    /// Only a JSON true counts, as `helper/local_session_server.py` sends it.
    func test_theClientReadsOnlyAJSONTrue() async throws {
        XCTAssertEqual(SessionControlHello.followsAppAnswerKey, "follows_app_answer")
        let trueValue = try await parsed(true)
        XCTAssertTrue(trueValue)
        let absent = try await parsed(nil)
        XCTAssertFalse(absent, "1.30.0 and earlier send nothing")
        let falseValue = try await parsed(false)
        XCTAssertFalse(falseValue)
        let one = try await parsed(1)
        XCTAssertFalse(one, "a number is not the answer")
        let text = try await parsed("true")
        XCTAssertFalse(text, "a string is not the answer")
    }

    /// The notes are shown where the answer is: the first ask, Overview's
    /// declined card, both of Settings › Privacy's scan rows and under the
    /// Claude keychain switches; and "Where Your Data Goes" lists the running
    /// sessions. Read from the app's sources, which `swift test` does not build.
    func test_theAppShowsTheNotesWhereTheAnswerIs() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // …/CLIPulseCore
            .deletingLastPathComponent()    // …/CLI Pulse Bar
            .appending(path: "CLI Pulse Bar")
        func source(_ name: String) throws -> String {
            try String(contentsOf: app.appending(path: name), encoding: .utf8)
        }
        func count(_ needle: String, in text: String) -> Int {
            text.components(separatedBy: needle).count - 1
        }
        let note = "CompanionNotCoveredNote(installer: state.helperInstaller"

        let consent = try source("LocalScanConsentView.swift")
        XCTAssertEqual(count(note, in: consent), 2, "the first ask and the declined card")
        XCTAssertTrue(consent.contains("if mode == .firstAsk {\n                        \(note)"))
        XCTAssertTrue(consent.contains("installer.companionIgnoringAnswerVersion"))
        XCTAssertTrue(consent.contains("L10n.localScanConsent.companionNotCovered(label)"))
        XCTAssertTrue(consent.contains("L10n.settings.companionIgnoresSwitches(label)"))

        let privacy = try source("PrivacySettingsSection.swift")
        XCTAssertEqual(count(note, in: privacy), 3, "the scan switch, the way back from Not now, the keychain switches")
        XCTAssertEqual(count("\(note), subject: .switches)", in: privacy), 1)

        let advanced = try source("AdvancedSection.swift")
        XCTAssertTrue(advanced.contains("title: L10n.advanced.privacySessionsTitle"))
        XCTAssertTrue(advanced.contains("detail: L10n.advanced.privacySessionsDetail"))
    }
}

#endif

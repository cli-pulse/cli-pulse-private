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
            "onboarding_wizard.sync_mode_body": L10n.onboardingWizard.syncModeBody,
            "onboarding_wizard.privacy_body": L10n.onboardingWizard.privacyBody,
            "advanced.remote_consent_body": L10n.advanced.remoteConsentBody,
            "helper.running_unpaired_hint": L10n.helper.runningUnpairedHint(.signedIn(userId: "u")),
            "helper.running_unpaired_hint_no_account": L10n.helper.runningUnpairedHint(.localMode),
        ]
    }

    /// Keys this change added: a revert removes them, and the raw-key check
    /// above catches that.
    private static let added: Set<String> = [
        "advanced.privacy_sessions_title", "advanced.privacy_sessions_detail",
        "local_scan_consent.companion_not_covered", "settings.companion_ignores_switches",
        "helper.running_unpaired_hint_no_account",
    ]

    /// For every rewritten key, in every language: the old false phrase
    /// (`was`, gone) and a phrase the correction added (`now`, present). One
    /// language per row is not enough: in English a broken lookup still reads
    /// right, and a translator working from the old copy can put one language
    /// back on its own. The `was` phrases are the pre-1.55 catalogues'.
    private static let claims: [(key: String, was: [String: String], now: [String: String])] = [
        ("onboarding_wizard.privacy_raw_detail",
         was: ["en": "uploads only", "zh-Hans": "只上传", "zh-Hant": "只上傳",
               "ja": "集計値だけ", "ko": "요약 필드만", "es": "solo sube"],
         now: ["en": "project folder", "zh-Hans": "项目文件夹名", "zh-Hant": "專案資料夾名稱",
               "ja": "プロジェクトフォルダ名", "ko": "프로젝트 폴더 이름", "es": "carpeta de proyecto"]),
        ("onboarding_wizard.privacy_keys_detail",
         was: [:],
         now: ["en": "you enter", "zh-Hans": "你输入的", "zh-Hant": "你輸入的",
               "ja": "入力した", "ko": "직접 입력한", "es": "que introduces"]),
        ("advanced.privacy_keys_detail",
         was: [:],
         now: ["en": "you enter", "zh-Hans": "你输入的", "zh-Hant": "你輸入的",
               "ja": "入力した", "ko": "직접 입력한", "es": "introduces"]),
        ("advanced.privacy_logs_detail",
         was: ["en": "only in folders you've given CLI Pulse access to",
               "zh-Hans": "通过你授权的文件夹在本机扫描", "zh-Hant": "透過你授權的資料夾在本機掃描",
               "ja": "許可したフォルダだけを、この Mac 上でスキャン", "ko": "허용한 폴더만 이 Mac에서 스캔",
               "es": "solo en las carpetas a las que diste acceso a CLI Pulse"],
         now: ["en": "App Store", "zh-Hans": "App Store", "zh-Hant": "App Store",
               "ja": "App Store", "ko": "App Store", "es": "App Store"]),
        ("onboarding_wizard.helper_hint",
         was: [:],
         now: ["en": "Privacy Policy", "zh-Hans": "隐私政策", "zh-Hant": "隱私權政策",
               "ja": "プライバシーポリシー", "ko": "개인정보 처리방침", "es": "Política de privacidad"]),
        ("advanced.track_git_hint",
         was: [:],
         now: ["en": "Only the Companion CLI", "zh-Hans": "仅由 Companion CLI", "zh-Hant": "僅由 Companion CLI",
               "ja": "Companion CLI だけ", "ko": "Companion CLI만", "es": "Solo los recopila Companion CLI"]),
        ("local_scan_consent.derived_title",
         was: [:],
         now: ["en": "which programs are running", "zh-Hans": "正在运行的程序", "zh-Hant": "正在執行的程式",
               "ja": "実行中のプログラム", "ko": "실행 중인 프로그램", "es": "qué programas se están ejecutando"]),
        ("local_scan_consent.derived_detail",
         was: [:],
         now: ["en": "checks which programs are running", "zh-Hans": "正在运行的程序", "zh-Hant": "正在執行的程式",
               "ja": "実行中のプログラムを確認", "ko": "실행 중인 프로그램을 확인", "es": "qué programas se están ejecutando"]),
        ("local_scan_consent.keychain_title",
         was: [:],
         now: ["en": "and a few others", "zh-Hans": "令牌等", "zh-Hant": "權杖等",
               "ja": "トークンなど", "ko": "토큰 등", "es": "y algunos más"]),
        ("local_scan_consent.keychain_detail",
         was: [:],
         now: ["en": "Zed", "zh-Hans": "Zed", "zh-Hant": "Zed", "ja": "Zed", "ko": "Zed", "es": "Zed"]),
        // The browser's cookie key is read for Cursor without anyone setting
        // anything: its cookie source is Automatic until changed
        // (`CursorCollector.autoImportEligible`), so "a provider you set to
        // read cookies automatically" left out the one read by default.
        ("local_scan_consent.keychain_detail",
         was: ["en": "for a provider you set to read cookies automatically",
               "zh-Hans": "你设为自动读取 Cookie 的服务商所用的", "zh-Hant": "你設為自動讀取 Cookie 的服務商所用的",
               "ja": "Cookie を自動で読み取るよう設定したプロバイダー用の", "ko": "쿠키를 자동으로 읽도록 설정한 공급자를 위한",
               "es": "para los proveedores cuyas cookies se leen automáticamente"],
         now: ["en": "Cursor", "zh-Hans": "Cursor", "zh-Hant": "Cursor", "ja": "Cursor", "ko": "Cursor", "es": "Cursor"]),
        ("local_scan_consent.declined_body",
         was: ["en": "not reading anything", "zh-Hans": "没有读取这台 Mac 上的任何内容",
               "zh-Hant": "沒有讀取這台 Mac 上的任何內容", "ja": "何も読み取っていない",
               "ko": "아무것도 읽지 않고", "es": "no está leyendo nada"],
         now: ["en": "not scanning", "zh-Hans": "没有扫描", "zh-Hant": "沒有掃描",
               "ja": "スキャンしていない", "ko": "스캔하지 않고", "es": "no está analizando"]),
        ("local_scan_consent.settings_toggle_detail",
         was: ["en": "reads nothing", "zh-Hans": "不会读取这台 Mac 上的任何内容",
               "zh-Hant": "不會讀取這台 Mac 上的任何內容", "ja": "何も読み取りません",
               "ko": "아무것도 읽지 않습니다", "es": "no lee nada"],
         now: ["en": "the app and its background helper", "zh-Hans": "应用及其后台 Helper",
               "zh-Hant": "App 及其背景 Helper", "ja": "アプリもバックグラウンドヘルパーも",
               "ko": "앱도 백그라운드 헬퍼도", "es": "ni la app ni su helper"]),
        ("telemetry.not_collected",
         was: ["en": "deleted when you uninstall", "zh-Hans": "卸载即删除", "zh-Hant": "解除安裝即刪除",
               "ja": "アンインストールすると削除", "ko": "앱을 삭제하면 함께 삭제", "es": "se elimina al desinstalar"],
         now: [:]),
        ("telemetry.settings_body",
         was: ["en": "deleted when you uninstall", "zh-Hans": "卸载即删除", "zh-Hant": "解除安裝即刪除",
               "ja": "アンインストールすると削除", "ko": "앱을 삭제하면 함께 삭제", "es": "se elimina al desinstalar"],
         now: [:]),
        ("settings.privacy_redacted_hint",
         was: ["en": "Nothing else leaves", "zh-Hans": "任何内容都不会离开", "zh-Hant": "任何內容都不會離開",
               "ja": "一切送信されません", "ko": "아무것도 기기를 벗어나지", "es": "Nada más sale"],
         now: ["en": "These requests carry no", "zh-Hans": "这些请求不含", "zh-Hant": "這些請求不含",
               "ja": "これらのリクエストに", "ko": "이 요청에는", "es": "Estas solicitudes no llevan"]),
        ("settings.skip_claude_keychain_hint",
         was: ["en": "owned by other apps", "zh-Hans": "其他应用持有", "zh-Hant": "其他 App 擁有",
               "ja": "他のアプリが所有する", "ko": "다른 앱이 소유한", "es": "pertenecen a otras apps"],
         now: ["en": "On its own", "zh-Hans": "不会自行读取", "zh-Hant": "不會自行讀取",
               "ja": "自分から読み取ることはなくなります", "ko": "스스로 읽지 않도록", "es": "por su cuenta"]),
        ("helper.install_intro",
         was: [:],
         now: ["en": "1.30.0", "zh-Hans": "1.30.0", "zh-Hant": "1.30.0", "ja": "1.30.0", "ko": "1.30.0", "es": "1.30.0"]),
        ("onboarding_wizard.sync_mode_body",
         was: ["en": "never leave this Mac", "zh-Hans": "绝不会离开这台 Mac", "zh-Hant": "絕不會離開這台 Mac",
               "ja": "この Mac から出ることはありません", "ko": "이 Mac 밖으로 나가지 않습니다", "es": "nunca salen de este Mac"],
         now: ["en": "never reach our servers", "zh-Hans": "我们的服务器", "zh-Hant": "我們的伺服器",
               "ja": "当社のサーバー", "ko": "저희 서버", "es": "nuestros servidores"]),
        ("onboarding_wizard.privacy_body",
         was: ["en": "exactly", "zh-Hans": "清楚说明", "zh-Hant": "清楚說明",
               "ja": "正確に", "ko": "정확히", "es": "exactamente"],
         now: ["en": "Privacy Policy", "zh-Hans": "隐私政策", "zh-Hant": "隱私權政策",
               "ja": "プライバシーポリシー", "ko": "개인정보 처리방침", "es": "Política de privacidad"]),
        ("advanced.remote_consent_body",
         was: ["en": "What never leaves your device", "zh-Hans": "始终不会离开你设备的内容",
               "zh-Hant": "永遠不會離開你裝置的內容", "ja": "デバイスから決して送信されないもの",
               "ko": "기기를 절대 벗어나지 않는 것", "es": "Lo que nunca sale de tu dispositivo"],
         now: ["en": "What these requests never carry", "zh-Hans": "这些请求绝不包含",
               "zh-Hant": "這些請求絕不包含", "ja": "これらのリクエストに決して含まれないもの",
               "ko": "이 요청에 절대 담기지 않는 것", "es": "Lo que estas solicitudes nunca llevan"]),
        // The same body listed "full project paths": a Companion session's
        // name is up to 48 characters of its command line, which can hold one.
        ("advanced.remote_consent_body",
         was: ["en": "full project paths", "zh-Hans": "完整项目路径", "zh-Hant": "完整專案路徑",
               "ja": "プロジェクトの完全なパス", "ko": "전체 프로젝트 경로", "es": "rutas completas de proyectos"],
         now: [:]),
        // "Withdrawn" missed what is left: a paired Companion CLI's own
        // sessions post their redacted output and status, which the server
        // takes only while this switch is on (`_remote_authenticate_helper_gated`).
        ("advanced.remote_consent_body",
         was: ["en": "Those have been withdrawn", "zh-Hans": "这两项已经下线", "zh-Hant": "這兩項已經下線",
               "ja": "どちらも提供を終了しました。", "ko": "두 기능 모두 종료되었습니다", "es": "Ambas se han retirado"],
         now: ["en": "Our server accepts these only while this is on",
               "zh-Hans": "只有在此开关打开时，服务器才会接收", "zh-Hant": "只有在此開關開啟時，伺服器才會接收",
               "ja": "このスイッチがオンの間だけ", "ko": "켜져 있는 동안에만",
               "es": "solo aceptan estos datos mientras esto está activado"]),
        // "Pair this Mac (above)": this app cannot pair the Companion, and in
        // local mode the section above is the sign-in form.
        ("helper.running_unpaired_hint",
         was: PrivacyCopyTruthTests.pairAbove,
         now: ["en": "doesn't pair it", "zh-Hans": "并不会配对它", "zh-Hant": "並不會配對它",
               "ja": "ペアリングはされません", "ko": "페어링되지 않습니다", "es": "no lo vincula"]),
        ("helper.running_unpaired_hint_no_account",
         was: PrivacyCopyTruthTests.pairAbove,
         // (No "CLI Pulse" here: the name is shown with a no-break space.)
         now: ["en": "isn't signed in to one", "zh-Hans": "没有登录任何账户", "zh-Hant": "沒有登入任何帳號",
               "ja": "どのアカウントにもサインインしていません", "ko": "어떤 계정에도 로그인되어 있지 않습니다",
               "es": "no tiene la sesión iniciada en ninguna"]),
    ]

    /// The not-paired hint's old instruction, in each language.
    private static let pairAbove: [String: String] = [
        "en": "(above)", "zh-Hans": "在上方配对", "zh-Hant": "在上方配對",
        "ja": "上でこの Mac をペアリング", "ko": "위에서 이 Mac을 페어링", "es": "(arriba)",
    ]

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

    func test_everyLanguageDropsTheOldClaimAndSaysTheNewOne() {
        let covered = Set(Self.claims.map(\.key))
        let english = inLocale("en") { changed() }
        for key in english.keys where !Self.added.contains(key) {
            XCTAssertTrue(covered.contains(key), "\(key) has no row in `claims`")
        }
        for locale in Self.locales {
            let texts = inLocale(locale) { changed() }
            for claim in Self.claims {
                guard let text = texts[claim.key] else {
                    XCTFail("\(claim.key) is not in changed()")
                    continue
                }
                XCTAssertFalse(claim.was.isEmpty && claim.now.isEmpty, claim.key)
                if !claim.was.isEmpty {
                    if let was = claim.was[locale] {
                        XCTAssertFalse(text.contains(was), "\(locale): \(claim.key) still says \"\(was)\": \(text)")
                    } else {
                        XCTFail("\(claim.key): no \(locale) phrase in `was`")
                    }
                }
                if !claim.now.isEmpty {
                    if let now = claim.now[locale] {
                        XCTAssertTrue(text.contains(now), "\(locale): \(claim.key) lost \"\(now)\": \(text)")
                    } else {
                        XCTFail("\(claim.key): no \(locale) phrase in `now`")
                    }
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
                XCTAssertTrue(text.hasSuffix("moving the app to the Trash does not delete it."), text)
            }
            XCTAssertFalse(L10n.settings.privacyRedactedHint.contains("Nothing else leaves"))
            // Scoped to the four requests: the same Settings screen has a
            // "Remote Control" section, which does show terminal output.
            XCTAssertTrue(L10n.settings.privacyRedactedHint.contains("These requests carry no"))
            XCTAssertFalse(L10n.settings.privacyRedactedHint.contains("Remote control sends"))
            XCTAssertFalse(L10n.settings.skipClaudeKeychainHint.contains("owned by other apps"))
            // Connect Claude Code reads the item anyway: the user asked.
            XCTAssertTrue(L10n.settings.skipClaudeKeychainHint.hasPrefix("On its own, "))
            // Provider credentials go to their own provider.
            XCTAssertFalse(L10n.onboardingWizard.syncModeBody.contains("never leave"))
            XCTAssertTrue(L10n.onboardingWizard.syncModeBody.contains("never reach our servers"))
            // The cards leave out alerts, the device name and the readings.
            XCTAssertFalse(L10n.onboardingWizard.privacyBody.contains("exactly"))
            let consent = L10n.advanced.remoteConsentBody
            XCTAssertFalse(consent.contains("What never leaves your device"), consent)
            XCTAssertFalse(consent.contains("full project paths"), consent)
            XCTAssertTrue(consent.contains("What these requests never carry:"), consent)
            XCTAssertFalse(consent.contains("withdrawn"), consent)
            XCTAssertTrue(consent.contains("a Companion CLI paired with this account can send our server"), consent)
            let keychain = L10n.localScanConsent.keychainDetail
            XCTAssertFalse(keychain.contains("for a provider you set to read cookies automatically"), keychain)
            XCTAssertTrue(keychain.contains("for Cursor, whose cookie source is “Automatic” until you change it"), keychain)
            for account in [HelperAccountRecord.signedIn(userId: "u"), .localMode, .signedOut] {
                let hint = L10n.helper.runningUnpairedHint(account)
                XCTAssertFalse(hint.contains("above"), hint)
                XCTAssertTrue(hint.hasPrefix("Installed and running, but not paired with an account"), hint)
            }
        }
    }

    /// The not-paired hint depends on the account, in every language: signed
    /// in, it says this Mac's sync setup does not pair the Companion; without
    /// an account (local mode, Demo mode), that there is none to pair it with.
    func test_theUnpairedHintFollowsTheAccount() {
        for locale in Self.locales {
            inLocale(locale) {
                let signedIn = L10n.helper.runningUnpairedHint(.signedIn(userId: "u"))
                let local = L10n.helper.runningUnpairedHint(.localMode)
                let signedOut = L10n.helper.runningUnpairedHint(.signedOut)
                XCTAssertNotEqual(signedIn, local, locale)
                XCTAssertEqual(local, signedOut, "\(locale): no account either way")
                for hint in [signedIn, local] {
                    XCTAssertFalse(hint.hasPrefix("helper."), "\(locale): raw key \(hint)")
                    XCTAssertFalse(hint.contains(Self.pairAbove[locale]!), "\(locale): \(hint)")
                }
            }
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

    /// The install flow's own liveness checks (`pollHelperUntilReady`) set the
    /// state from a `hello` and return without a `refresh()`, so they record
    /// through the same place: after an in-app Update from 1.30.0 the note
    /// goes at once, and a fresh install of 1.30.0 shows it at once.
    @MainActor
    func test_everyProbeRecordsTheCompanionThroughOnePlace() throws {
        let installer = makeProbeOnlyHelperInstaller { ScriptedHelloClient(reply: nil, delayNanoseconds: 0) }
        installer.record(hello: hello(follows: false))
        XCTAssertEqual(installer.companionIgnoringAnswerVersion, "1.30.0")
        XCTAssertEqual(installer.helperPaired, true)
        installer.record(hello: hello(follows: true))
        XCTAssertNil(installer.companionIgnoringAnswerVersion, "updated in place to one that follows the answer")
        installer.record(hello: nil)
        XCTAssertNil(installer.companionIgnoringAnswerVersion)
        XCTAssertNil(installer.helperPaired)

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/CLIPulseCore/HelperInstaller.swift"),
            encoding: .utf8
        )
        func count(_ needle: String) -> Int { source.components(separatedBy: needle).count - 1 }
        XCTAssertEqual(count("helperPaired = "), 1, "set only inside record(hello:)")
        XCTAssertEqual(count("companionIgnoringAnswerVersion = "), 1, "set only inside record(hello:)")
        // Its definition, refresh() and the install flow's two liveness checks.
        XCTAssertEqual(count("record(hello: "), 4)
    }

    /// v1.55: the approval-hook status the Sessions tab polls opens
    /// `~/.claude/settings.json`; after "Not now" it is not opened.
    func test_theSessionsTabReadsClaudesSettingsOnlyWhileTheAnswerAllowsIt() {
        var reads = 0
        let read: () -> ClaudeHookDetector.Status = { reads += 1; return .wired }
        XCTAssertNil(AppState.approvalHookStatus(mayReadThisMac: false, read: read))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(AppState.approvalHookStatus(mayReadThisMac: true, read: read), .wired)
        XCTAssertEqual(reads, 1)
    }

    /// Answers one request with `result`, and keeps the request.
    private final class ReplyingServer: @unchecked Sendable {
        let socketPath: String
        let tokenPath: String
        private let fd: Int32
        private let lock = NSLock()
        private var _request: [String: Any]?
        private let answered = DispatchSemaphore(value: 0)

        /// The request the server answered, once it has.
        func request(timeout: TimeInterval = 2) -> [String: Any]? {
            _ = answered.wait(timeout: .now() + timeout)
            lock.lock(); defer { lock.unlock() }
            return _request
        }

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
            Thread { [self] in
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
                lock.lock(); _request = request; lock.unlock()
                answered.signal()
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

    private func listRequest(_ localScanAllowed: Bool?) async throws -> [String: Any]? {
        let none: [[String: Any]] = []
        let server = try ReplyingServer(result: ["managed": none, "detected": none])
        defer { server.stop() }
        let client = LocalSessionControlClient(
            socketPath: server.socketPath,
            tokenPath: server.tokenPath,
            connectTimeout: 2,
            requestTimeout: 2,
            runtimeEnvironment: TestRuntimeFixtures.productionApp
        )
        let rows = try await client.listSessions(localScanAllowed: localScanAllowed)
        XCTAssertEqual(rows.count, 0)
        return server.request()
    }

    /// v1.55: `list_sessions` tells the helper the answer, so the Companion
    /// runs no process scan for the `detected` rows after "Not now"
    /// (`helper/local_session_server.py`); without it the helper asks its own
    /// copy, as older apps' requests leave it to.
    func test_listSessionsTellsTheHelperTheAnswer() async throws {
        let no = try await listRequest(false)
        XCTAssertEqual(no?["method"] as? String, "list_sessions")
        let noParams = no?["params"] as? [String: Any]
        XCTAssertEqual(noParams?[LocalSessionControlClient.localScanAllowedParam] as? Bool, false)
        let yes = try await listRequest(true)
        XCTAssertEqual((yes?["params"] as? [String: Any])?["local_scan_allowed"] as? Bool, true)
        let unsaid = try await listRequest(nil)
        XCTAssertNotNil(unsaid, "the server saw the request")
        XCTAssertNil((unsaid?["params"] as? [String: Any])?["local_scan_allowed"])
    }

    /// The keychain line names Cursor because Cursor is the one provider
    /// whose browser cookies are read without anyone choosing it: a config
    /// that never set a cookie source imports them. Any other provider reads
    /// them only once set to Automatic. If another provider gains Cursor's
    /// default, or Cursor loses it, the line is wrong and this fails.
    func test_theKeychainLineNamesEveryProviderThatReadsCookiesByDefault() throws {
        XCTAssertTrue(CursorCollector.autoImportEligible(nil), "Cursor imports by default")
        XCTAssertTrue(CursorCollector.autoImportEligible(.automatic))
        XCTAssertFalse(CursorCollector.autoImportEligible(.manual), "the user turned it off")
        XCTAssertTrue(ProviderConfig.defaults().allSatisfy { $0.cookieSource == nil },
                      "a default config that set a cookie source would read cookies by default")
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/CLIPulseCore")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var turnsImportOn: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("cookieSource = .automatic") || text.contains("autoImportEligible(") {
                turnsImportOn.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(turnsImportOn, ["CursorCollector.swift"])
        // Control: the reader finds the Cursor file at all.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources.appending(path: "Collectors/CursorCollector.swift").path))
    }

    /// Settings › Companion CLI picks the not-paired hint by the account the
    /// app is in; the one string it used before sent everyone "above".
    func test_theCompanionSectionPicksTheUnpairedHintByAccount() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "CLI Pulse Bar")
        let section = try String(contentsOf: app.appending(path: "CompanionCLISection.swift"), encoding: .utf8)
        XCTAssertTrue(section.contains("L10n.helper.runningUnpairedHint(state.accountRecordForHelper)"))
        XCTAssertTrue(section.contains("@EnvironmentObject private var state: AppState"))
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

    /// The notes send people to Settings › Companion CLI, and the first ask
    /// and the telemetry card to Settings › Privacy. The first ask, Overview's
    /// declined card and the scan switch are local-mode screens, and until 1.55
    /// a Mac without an account saw only the sign-in form in Settings. Both
    /// sections now render wherever those screens can: signed in (with the
    /// account paired, where "Choose again…" is) and in local mode.
    func test_theSectionsTheNotesNameAreThereWhereverTheNotesAre() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "CLI Pulse Bar")
        let settings = try String(contentsOf: app.appending(path: "SettingsTab.swift"), encoding: .utf8)
        func body(of name: String) throws -> String {
            let start = try XCTUnwrap(settings.range(of: "private var \(name): some View {"), name)
            let rest = settings[start.upperBound...]
            let end = try XCTUnwrap(rest.range(of: "\n    }\n"), name)
            return String(rest[..<end.lowerBound])
        }
        let companion = "CompanionCLISection(installer: state.helperInstaller)"
        let privacy = "PrivacySettingsSection()"

        func squeezed(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        XCTAssertTrue(
            squeezed(settings).contains("} else { loginSection if state.isLocalMode { localModeSections } }"),
            "local mode renders its sections under the sign-in form"
        )
        let local = try body(of: "localModeSections")
        XCTAssertTrue(local.contains(companion), local)
        XCTAssertTrue(local.contains(privacy), local)

        let signedIn = try body(of: "authenticatedSection")
        let paired = try XCTUnwrap(signedIn.range(of: "if authState.isPaired {"))
        XCTAssertTrue(signedIn[paired.upperBound...].contains(companion))
        XCTAssertTrue(signedIn[paired.upperBound...].contains(privacy))

        // And the call that fills the Sessions tab passes the answer on.
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/CLIPulseCore/LocalSessionControlState.swift")
        let state = try String(contentsOf: core, encoding: .utf8)
        XCTAssertTrue(state.contains("client.listSessions(localScanAllowed: mayReadThisMac)"))
        XCTAssertTrue(state.contains("client.hello(localScanAllowed: mayReadThisMac)"))
        XCTAssertTrue(state.contains("Self.approvalHookStatus(mayReadThisMac: mayReadThisMac)"))
    }
}

#endif

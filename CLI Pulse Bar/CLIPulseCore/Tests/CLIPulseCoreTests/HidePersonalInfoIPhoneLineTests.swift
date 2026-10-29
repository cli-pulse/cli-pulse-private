import XCTest
@testable import CLIPulseCore

/// v1.58 (D5): the line under "Hide personal information" on iPhone and iPad,
/// and the scan consent's account of what the scan derives.
///
/// The Mac's line says the switch hides project folders and session names "on
/// screen and in exports". On iPhone that is not true: Remote Control's New
/// session sheet lists the Mac's working directories, its terminal shows a
/// session's own output, its approval cards show a tool's command or file, and
/// Settings shows the account's name. So the iPhone has a line of its own,
/// which names the places the switch works by the names the app gives them and
/// says what it leaves alone. Since 1.60 (C9) it also hides device names,
/// everywhere, Remote Control included.
///
/// The same line is shown on iPad, which cannot pair with an Apple Watch
/// (`PhoneSessionManager` sends nothing unless `WCSession.isSupported()`), and
/// the switch is kept on each device. So the line says the Watch follows the
/// switch on the iPhone it is paired with, which is true on both.
///
/// Asserted in Simplified Chinese, where a broken lookup cannot pass for the
/// translation, and in every language against the app's own names for those
/// places, so a tab or section renamed in one catalogue shows up here.
final class HidePersonalInfoIPhoneLineTests: XCTestCase {

    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]

    private var saved: String?
    override func setUp() { super.setUp(); saved = LocaleOverrideStore.shared.override }
    override func tearDown() { LocaleOverrideStore.shared.set(saved); super.tearDown() }

    // MARK: - The line

    func testTheLineInSimplifiedChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(
            L10n.settings.hidePersonalInfoIPhoneHint,
            "隐藏邮箱地址和设备名称；在「概览」「会话」「告警」和导出的文件中，还会隐藏项目文件夹的名称和会话名称。"
                + "Apple\u{00A0}Watch 遵循与其配对的 iPhone 上的此开关。"
                + "账户名称，以及「远程控制」中显示的会话内容（例如会话的文件夹、命令和终端输出），都不会被隐藏。")
    }

    /// What each language says stays visible: the account's name and what
    /// Remote Control shows of a session, and the words that say they are
    /// not hidden.
    private static let notHidden: [String: [String]] = [
        "en": ["Not hidden:", "your account name", "what Remote Control shows of a session"],
        "zh-Hans": ["都不会被隐藏", "账户名称", "「远程控制」中显示的会话内容"],
        "zh-Hant": ["都不會隱藏", "帳號名稱", "「遠端控制」中顯示的工作階段內容"],
        "ja": ["表示されたまま", "アカウント名", "「リモート操作」に表示されるセッションの内容"],
        "ko": ["숨기지 않습니다", "계정 이름", "'원격 제어'에 표시되는 세션 내용"],
        "es": ["Siguen visibles", "el nombre de tu cuenta", "lo que Control remoto muestra de una sesión"],
    ]

    /// 1.60 (C9): device names, in the first sentence, which says what is
    /// hidden everywhere, not in the one that says what is not.
    private static let deviceNames: [String: String] = [
        "en": "device names", "zh-Hans": "设备名称", "zh-Hant": "裝置名稱",
        "ja": "デバイス名", "ko": "기기 이름", "es": "los nombres de dispositivos",
    ]

    /// The Watch sentence, in each language: it follows the switch on the
    /// iPhone it is paired with. Not "this switch" alone, which on iPad is
    /// false: an iPad sends the Watch nothing, and its switch is its own.
    private static let watchFollowsItsIPhone: [String: String] = [
        "en": "Apple Watch follows the switch on the iPhone it is paired with.",
        "zh-Hans": "Apple\u{00A0}Watch 遵循与其配对的 iPhone 上的此开关。",
        "zh-Hant": "Apple\u{00A0}Watch 會遵循與其配對的 iPhone 上的此開關。",
        "ja": "Apple\u{00A0}Watch はペアリングした iPhone のこの設定に従います。",
        "ko": "Apple\u{00A0}Watch는 페어링된 iPhone의 이 설정을 따릅니다.",
        "es": "El Apple Watch sigue este ajuste del iPhone con el que está enlazado.",
    ]

    /// How each catalogue marks a screen's name inside a sentence (ja and zh
    /// 「」, ko '…'); en and es name it bare.
    private static func marked(_ name: String, _ language: String) -> String {
        switch language {
        case "ja", "zh-Hans", "zh-Hant": return "「\(name)」"
        case "ko": return "'\(name)'"
        default: return name
        }
    }

    /// The line's sentences, split after each full stop.
    private static func sentences(_ line: String) -> [String] {
        line.components(separatedBy: CharacterSet(charactersIn: ".。"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Wherever the line mentions the Watch, it says whose switch the Watch
    /// follows: the iPhone's. The iPad shows this line too.
    func testTheWatchSentenceIsTrueOnIPadToo() {
        for language in Self.languages {
            LocaleOverrideStore.shared.set(language)
            let line = L10n.settings.hidePersonalInfoIPhoneHint
            XCTAssertTrue(line.contains(Self.watchFollowsItsIPhone[language]!), "\(language): \(line)")
            let aboutTheWatch = Self.sentences(line).filter { $0.contains("Watch") }
            XCTAssertEqual(aboutTheWatch.count, 1, "\(language): \(line)")
            for sentence in aboutTheWatch {
                XCTAssertTrue(sentence.contains("iPhone"),
                              "\(language): the Watch follows the iPhone's switch, not this device's: \(sentence)")
            }
        }
    }

    /// The Mac line's "paths", which the iPhone does not hide everywhere (the
    /// New session sheet), in each language.
    private static let paths: [String: String] = [
        "en": "path", "zh-Hans": "路径", "zh-Hant": "路徑", "ja": "パス", "ko": "경로", "es": "ruta",
    ]

    func testEveryLanguageNamesWhereItHidesAndWhatItLeaves() {
        LocaleOverrideStore.shared.set("en")
        let english = L10n.settings.hidePersonalInfoIPhoneHint
        for language in Self.languages {
            LocaleOverrideStore.shared.set(language)
            let line = L10n.settings.hidePersonalInfoIPhoneHint
            XCTAssertFalse(line.isEmpty, language)
            XCTAssertNotEqual(line, "settings.hide_personal_info_iphone_hint", "\(language): raw key")
            if language != "en" {
                XCTAssertNotEqual(line, english, "\(language): the English line")
            }
            // The tabs it works in, and the section it does not, by the names
            // this language gives them on the iPhone.
            // ja, ko and zh mark them as names, as their catalogues do, so
            // zh-Hans 会话 reads as the tab and not the ordinary word.
            for place in [L10n.tab.overview, L10n.tab.sessions, L10n.tab.alerts, L10n.remote.title] {
                let name = Self.marked(place, language)
                XCTAssertTrue(line.contains(name), "\(language): \"\(name)\" is not named in: \(line)")
            }
            // CJK and Korean keep the name whole with a no-break space
            // (`MacSettingsCopyTests.test_appleWatch_isNeverSplitInCJKOrKorean`).
            XCTAssertTrue(line.contains(["en", "es"].contains(language) ? "Apple Watch" : "Apple\u{00A0}Watch"),
                          "\(language): \(line)")
            for phrase in Self.notHidden[language]! {
                XCTAssertTrue(line.contains(phrase), "\(language): lost \"\(phrase)\": \(line)")
            }
            let devices = Self.deviceNames[language]!
            XCTAssertTrue(Self.sentences(line).first?.contains(devices) == true,
                          "\(language): the first sentence does not say it hides \"\(devices)\": \(line)")
            XCTAssertEqual(line.components(separatedBy: devices).count - 1, 1,
                           "\(language): \"\(devices)\" is named twice, once perhaps as not hidden: \(line)")
            // Not the Mac's promise.
            XCTAssertNotEqual(line, L10n.advanced.hidePersonalInfoHelp, language)
            XCTAssertFalse(line.contains(Self.paths[language]!), "\(language): claims paths: \(line)")
        }
    }

    // MARK: - Where it is shown

    /// The iPhone and iPad show this line under the switch, and nothing on
    /// them shows the Mac's.
    func testTheIPhoneShowsThisLineUnderTheSwitch() throws {
        let settings = try Self.code("CLI Pulse Bar iOS/iOSSettingsTab.swift")
        let toggle = "Toggle(isOn: $state.hidePersonalInfo) {"
        XCTAssertEqual(settings.components(separatedBy: "$state.hidePersonalInfo").count - 1, 1,
                       "one switch, and it is the one below")
        let start = try XCTUnwrap(settings.range(of: toggle), "the switch no longer has a label of its own")
        let rest = settings[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "Button {"), "the Force Refresh button no longer follows the switch")
        let label = rest[..<end.lowerBound]
        XCTAssertTrue(label.contains("Text(L10n.settings.hidePersonalInfo)"), String(label))
        XCTAssertTrue(label.contains("Text(L10n.settings.hidePersonalInfoIPhoneHint)"), String(label))

        for file in try Self.swiftFiles(in: "CLI Pulse Bar iOS") {
            XCTAssertFalse(try Self.code("CLI Pulse Bar iOS/" + file).contains("hidePersonalInfoHelp"),
                           "\(file) shows the Mac's line, which is not true on iPhone")
        }
        let mac = try Self.code("CLI Pulse Bar/AdvancedSection.swift")
        XCTAssertTrue(mac.contains("Text(L10n.advanced.hidePersonalInfoHelp)"))
        XCTAssertFalse(mac.contains("hidePersonalInfoIPhoneHint"))
    }

    /// What the line says, the code does. Hidden: the three tabs it names read
    /// the switch, both exports it offers are told it, the Watch is sent it,
    /// and device names go through the mask, Remote Control's included. Not
    /// hidden: the New session sheet's folders and the terminal never read it.
    /// If one of these changes, change the line.
    func testTheLineSaysWhatTheIPhoneDoes() throws {
        let reads = "@AppStorage(PersonalInfoMask.defaultsKey) private var hidePersonalInfo"
        for file in ["iOSOverviewTab.swift", "iOSSessionsTab.swift", "iOSAlertsTab.swift"] {
            XCTAssertTrue(try Self.code("CLI Pulse Bar iOS/" + file).contains(reads), "\(file) no longer reads the switch")
        }
        let overview = try Self.code("CLI Pulse Bar iOS/iOSOverviewTab.swift")
        for export in ["ExportService.exportCostReportCSV(", "ExportService.exportSessionsCSV("] {
            let call = try XCTUnwrap(overview.range(of: export), "\(export) is gone from the Overview")
            XCTAssertTrue(overview[call.upperBound...].prefix(300).contains("hidePersonalInfo: hidePersonalInfo"),
                          "\(export) is not told the switch")
        }
        XCTAssertTrue(try Self.code("CLI Pulse Bar iOS/PhoneSessionManager.swift")
            .contains("PersonalInfoMask.addPhoneChoice("), "the Watch is no longer sent the switch")

        let remote = try Self.code("CLIPulseCore/Sources/CLIPulseCore/LANRemoteScreens.swift")
        // The session's own content is not masked: the New session sheet (the
        // Mac's folders) never reads the switch, and the terminal reads it for
        // its title alone (the session's label, which an iPhone sets to its
        // own name), never for the output.
        func body(of screen: String) throws -> Substring {
            let start = try XCTUnwrap(remote.range(of: screen), "\(screen) moved; recheck what it shows")
            let next = [remote[start.upperBound...].range(of: "\nstruct ")?.lowerBound,
                        remote[start.upperBound...].range(of: "\npublic struct ")?.lowerBound]
                .compactMap { $0 }.min() ?? remote.endIndex
            return remote[start.lowerBound..<next]
        }
        XCTAssertFalse(try body(of: "struct LANNewSessionSheet").contains("hidePersonalInfo"),
                       "the New session sheet now reads the switch: the line still says its folders are not hidden")
        let terminal = try body(of: "public struct LANTerminalScreen")
        // The declaration, and the one argument `hidePersonalInfo: hidePersonalInfo`.
        XCTAssertEqual(terminal.components(separatedBy: "hidePersonalInfo").count - 1, 3,
                       "the terminal reads the switch for more than its title: the line still says its output is not hidden")
        XCTAssertTrue(terminal.contains("PersonalInfoMask.managedSessionTitle("), "the terminal's title is not masked")
        // Device names: Remote Control's lists and titles go through the mask.
        XCTAssertGreaterThanOrEqual(remote.components(separatedBy: "PersonalInfoMask.pairedDeviceName(").count - 1
                                    + remote.components(separatedBy: "PersonalInfoMask.listedDeviceName(").count - 1, 6,
                                    "Remote Control shows a device's name outside the mask")
        let mask = try Self.code("CLIPulseCore/Sources/CLIPulseCore/PersonalInfoMaskDevices.swift")
        XCTAssertNotNil(mask.range(of: #"static\s+func\s+deviceName\("#, options: .regularExpression),
                        "the device-name mask is gone: the line says device names are hidden")
    }

    // MARK: - The scan consent (local_scan_consent.derived_detail)

    func testTheConsentSaysWhatPrivacyMdSaysInSimplifiedChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(
            L10n.localScanConsent.derivedDetail,
            "token 数、费用预估、模型名称和日期，以及每次会话的文件路径、项目文件夹和会话 ID；"
                + "Codex 会话还有其仓库地址的单向哈希（从不保留地址本身）。"
                + "「会话」列表靠这些来命名你的会话，「项目」靠它们按项目文件夹汇总用量"
                + "（Codex 的 worktree 或临时 clone 计入它所来自的那份仓库副本），"
                + "「用量历史」中的「会话」列表靠它们按会话汇总最近 30 天。"
                + "它还会查看正在运行的程序，以发现 AI CLI 会话；"
                + "登录且开启后台同步时，每个会话的程序名和项目文件夹名会同步到你的账户。")
    }

    /// The two lists it names, by the names the Mac gives them, in every
    /// language; and PRIVACY.md still says what the English says.
    func testTheConsentNamesTheListsByTheirOwnNames() throws {
        for language in Self.languages {
            LocaleOverrideStore.shared.set(language)
            let detail = L10n.localScanConsent.derivedDetail
            for name in [L10n.projects.title, L10n.providerPanel.title, L10n.sessions.title] {
                XCTAssertTrue(detail.contains(name), "\(language): \"\(name)\" is not named in: \(detail)")
            }
            // Marked as names where the catalogue marks them, so ko's
            // '프로젝트' reads as the list and not "the project".
            for name in [L10n.projects.title, L10n.providerPanel.title] {
                let marked = Self.marked(name, language)
                XCTAssertTrue(detail.contains(marked), "\(language): \"\(marked)\" is not marked in: \(detail)")
            }
        }
        let policy = try String(contentsOf: Self.repoRoot.appendingPathComponent("PRIVACY.md"), encoding: .utf8)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for claim in ["a one-way hash of its repository's address",
                      "how Projects (the usage panel and the Overview's Top Projects card) adds up usage by folder",
                      "the usage panel's Sessions list adds up the last 30 days by session"] {
            XCTAssertTrue(policy.contains(claim), "PRIVACY.md no longer says \"\(claim)\": recheck the consent")
        }
    }

    // MARK: - Sources

    /// `CLI Pulse Bar`.
    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .deletingLastPathComponent()   // CLI Pulse Bar
    }

    private static var repoRoot: URL { appRoot.deletingLastPathComponent() }

    /// A source file under `CLI Pulse Bar`, without its comment lines.
    private static func code(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func swiftFiles(in folder: String) throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(atPath: appRoot.appendingPathComponent(folder).path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty, folder)
        return files
    }
}

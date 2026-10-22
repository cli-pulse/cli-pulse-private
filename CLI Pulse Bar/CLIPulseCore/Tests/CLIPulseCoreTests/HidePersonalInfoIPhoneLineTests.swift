import XCTest
@testable import CLIPulseCore

/// v1.58 (D5): the line under "Hide personal information" on iPhone and iPad,
/// and the scan consent's account of what the scan derives.
///
/// The Mac's line says the switch hides project folders and session names "on
/// screen and in exports". On iPhone that is not true: Remote Control's New
/// session sheet lists the Mac's working directories, its terminal shows a
/// session's own output, and no device's name is masked anywhere. So the
/// iPhone has a line of its own, which names the places the switch works by
/// the names the app gives them and says what it leaves alone.
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
            "隐藏邮箱地址；在概览、会话、告警和导出的文件中，还会隐藏项目文件夹的名称和会话名称。"
                + "Apple\u{00A0}Watch 也遵循此开关。设备名称，以及远程控制中的工作目录和终端输出，不会被隐藏。")
    }

    /// What each language says stays visible: device names and terminal
    /// output, and the words that say they are not hidden.
    private static let notHidden: [String: [String]] = [
        "en": ["Not hidden:", "device names", "working directories", "terminal output"],
        "zh-Hans": ["不会被隐藏", "设备名称", "工作目录", "终端输出"],
        "zh-Hant": ["不會隱藏", "裝置名稱", "工作目錄", "終端機輸出"],
        "ja": ["表示されたまま", "デバイス名", "作業ディレクトリ", "ターミナル出力"],
        "ko": ["숨기지 않습니다", "기기 이름", "작업 디렉터리", "터미널 출력"],
        "es": ["No se ocultan", "nombres de los dispositivos", "directorios de trabajo", "salida del terminal"],
    ]

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
            for place in [L10n.tab.overview, L10n.tab.sessions, L10n.tab.alerts, L10n.remote.title] {
                XCTAssertTrue(line.contains(place), "\(language): \"\(place)\" is not named in: \(line)")
            }
            // CJK and Korean keep the name whole with a no-break space
            // (`MacSettingsCopyTests.test_appleWatch_isNeverSplitInCJKOrKorean`).
            XCTAssertTrue(line.contains(["en", "es"].contains(language) ? "Apple Watch" : "Apple\u{00A0}Watch"),
                          "\(language): \(line)")
            for phrase in Self.notHidden[language]! {
                XCTAssertTrue(line.contains(phrase), "\(language): lost \"\(phrase)\": \(line)")
            }
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
    /// the switch, both exports it offers are told it, and the Watch is sent
    /// it. Not hidden: Remote Control's screens never read it, and there is no
    /// mask for a device's name. If one of these changes, change the line.
    func testTheLineSaysWhatTheIPhoneDoes() throws {
        let reads = "@AppStorage(PersonalInfoMask.defaultsKey) private var hidePersonalInfo"
        for file in ["iOSOverviewTab.swift", "iOSSessionsTab.swift", "iOSAlertsTab.swift"] {
            XCTAssertTrue(try Self.code("CLI Pulse Bar iOS/" + file).contains(reads), "\(file) no longer reads the switch")
        }
        let overview = try Self.code("CLI Pulse Bar iOS/iOSOverviewTab.swift")
        for export in ["ExportService.exportCostReportCSV(", "ExportService.exportSessionsCSV("] {
            let call = try XCTUnwrap(overview.range(of: export), "\(export) is gone from the Overview")
            XCTAssertTrue(overview[call.upperBound...].prefix(200).contains("hidePersonalInfo: hidePersonalInfo"),
                          "\(export) is not told the switch")
        }
        XCTAssertTrue(try Self.code("CLI Pulse Bar iOS/PhoneSessionManager.swift")
            .contains("PersonalInfoMask.addPhoneChoice("), "the Watch is no longer sent the switch")

        let remote = try Self.code("CLIPulseCore/Sources/CLIPulseCore/LANRemoteScreens.swift")
        XCTAssertTrue(remote.contains("struct LANNewSessionSheet"), "the New session sheet moved; recheck what it shows")
        for word in ["PersonalInfoMask", "hidePersonalInfo"] {
            XCTAssertFalse(remote.contains(word),
                           "Remote Control now reads the switch: the line still says it does not hide it")
        }
        for file in ["PersonalInfoMask.swift", "PersonalInfoMaskSessions.swift"] {
            let mask = try Self.code("CLIPulseCore/Sources/CLIPulseCore/" + file)
            XCTAssertFalse(mask.range(of: #"func\s+device"#, options: .regularExpression) != nil,
                           "\(file) masks a device's name now: the line still says it does not")
        }
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

import XCTest
@testable import CLIPulseCore
#if canImport(PDFKit)
import PDFKit
#endif

/// v1.58 (P1-6): "Hide personal information" past account labels: projects a
/// surface knows by name, session titles, alerts, the exports and paths into
/// the home folder. With the switch on no project's folder name, folder path
/// or session's stored name is shown or exported; with it off everything is
/// as before (each test's negative control).
///
/// Asserted in Simplified Chinese: in English "Project 2" and "Hidden
/// project" are also what a missing translation falls back to, so an English
/// check could not tell the catalogue lookup worked.
final class PersonalInfoMaskSessionsTests: XCTestCase {

    private var previousLocale: String?
    private let today = "2026-10-21"
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() {
        super.setUp()
        previousLocale = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(previousLocale)
        super.tearDown()
    }

    // MARK: - Fixtures (invented names and paths)

    private func folder(_ path: String) -> ProjectIdentity { .folder(path) }

    private func entry(_ project: ProjectIdentity, cost: Double, input: Int = 1_000) -> CostUsageScanResult.ProjectEntry {
        .init(provider: "Codex", project: project, date: today, model: "gpt-5.5",
              inputTokens: input, cachedTokens: 0, outputTokens: 100, costUSD: cost)
    }

    /// demo-app is Projects' first, sample-service its second; two folders
    /// share the name "web"; an unknown project takes no number.
    private var scan: [CostUsageScanResult.ProjectEntry] {
        [
            entry(folder("/Users/sample/Projects/demo-app"), cost: 9),
            entry(folder("/Users/sample/Projects/sample-service"), cost: 5),
            entry(folder("/Users/sample/Projects/web"), cost: 3),
            entry(folder("/Users/sample/Work/web"), cost: 2),
            entry(.unknown, cost: 20),
        ]
    }

    private var numbers: ProjectNameNumbers {
        .scan(scan, todayKey: today, timeZone: utc, rankByCost: true)
    }

    private func session(
        _ id: String, name: String, provider: String = "Codex", project: String
    ) -> SessionRecord {
        SessionRecord(
            id: id, name: name, provider: provider, project: project, device_name: "build-box",
            started_at: "2026-10-21T08:00:00Z", last_active_at: "2026-10-21T09:00:00Z", status: "Running",
            total_usage: 12_000, estimated_cost: 1.25, cost_status: "Estimated", requests: 4, error_count: 0)
    }

    private func alert(
        id: String, type: String = "Usage Spike", title: String, message: String, project: String?,
        session: String?, provider: String?
    ) -> AlertRecord {
        AlertRecord(
            id: id, type: type, severity: "Warning", title: title, message: message,
            created_at: "2026-10-21T09:00:00Z", is_read: false, is_resolved: false, acknowledged_at: nil,
            snoozed_until: nil, related_project_id: nil, related_project_name: project,
            related_session_id: nil, related_session_name: session, related_provider: provider,
            related_device_name: "build-box", source_kind: "session")
    }

    // MARK: - Projects known by name

    func testANameIsTheNumberProjectsGivesItsFolder() {
        let anonymous = ProjectUsageRanking.anonymousNumbers(scan, todayKey: today, timeZone: utc)
        XCTAssertEqual(numbers.number(forName: "demo-app"), anonymous["/Users/sample/Projects/demo-app"])
        XCTAssertEqual(numbers.number(forName: "sample-service"), anonymous["/Users/sample/Projects/sample-service"])
        XCTAssertEqual(numbers.numbersByName, ["demo-app": 1, "sample-service": 2])
        XCTAssertEqual(
            PersonalInfoMask.projectName("demo-app", numbers: numbers, hidePersonalInfo: true), "项目 1")
    }

    /// A name two folders share says nothing about which one, and a name the
    /// scan does not have (another device's) has no number: both are hidden,
    /// not given a number that could be another folder's.
    func testANameWithoutOneFolderIsAHiddenProject() {
        XCTAssertNil(numbers.number(forName: "web"))
        for name in ["web", "other-device-app"] {
            XCTAssertEqual(PersonalInfoMask.projectName(name, numbers: numbers, hidePersonalInfo: true), "隐藏的项目")
        }
        XCTAssertEqual(
            PersonalInfoMask.projectName("demo-app", numbers: .none, hidePersonalInfo: true), "隐藏的项目",
            "a device without a scan has no numbers")
        XCTAssertEqual(ProjectNameNumbers.scan([], todayKey: today, rankByCost: true), .none)
    }

    func testTheSwitchOffShowsTheNameAndNothingIsNotAProject() {
        XCTAssertEqual(PersonalInfoMask.projectName(" demo-app ", numbers: numbers, hidePersonalInfo: false), "demo-app")
        XCTAssertNil(PersonalInfoMask.projectName("  ", numbers: numbers, hidePersonalInfo: true))
        XCTAssertNil(PersonalInfoMask.projectName(nil, numbers: numbers, hidePersonalInfo: true))
    }

    /// With costs hidden Projects ranks by tokens, and so do these numbers.
    func testNumbersFollowProjectsRankingWithCostsHidden() {
        let byTokens = [
            entry(folder("/Users/sample/Projects/demo-app"), cost: 9, input: 100),
            entry(folder("/Users/sample/Projects/sample-service"), cost: 1, input: 50_000),
        ]
        XCTAssertEqual(
            ProjectNameNumbers.scan(byTokens, todayKey: today, timeZone: utc, rankByCost: false).numbersByName,
            ["sample-service": 1, "demo-app": 2])
    }

    @MainActor
    func testTheAppNumbersThisMacsProjectsOnlyWithTheSwitchOn() {
        let state = AppState()
        state.costUsageScanResult = CostUsageScanResult(entries: [], projects: scan)
        let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
        XCTAssertEqual(state.projectNameNumbers(hidePersonalInfo: false, now: now), .none)
        XCTAssertFalse(state.projectNameNumbers(hidePersonalInfo: true, now: now).numbersByName.isEmpty)
        state.costUsageScanResult = nil
        XCTAssertEqual(state.projectNameNumbers(hidePersonalInfo: true, now: now), .none)
    }

    /// The answer is kept between redraws, and a new scan, the other ranking
    /// or another day asks again.
    @MainActor
    func testTheAppKeepsItsNumbersUntilTheScanTheRankingOrTheDayChanges() {
        let state = AppState()
        let savedShowCost = state.showCost
        defer { state.showCost = savedShowCost }
        state.showCost = true
        let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
        let byTokens = [
            entry(folder("/Users/sample/Projects/demo-app"), cost: 9, input: 100),
            entry(folder("/Users/sample/Projects/sample-service"), cost: 1, input: 50_000),
        ]
        state.costUsageScanResult = CostUsageScanResult(entries: [], projects: byTokens)
        XCTAssertNil(state.projectNameNumbersMemo)
        let first = state.projectNameNumbers(hidePersonalInfo: true, now: now)
        XCTAssertEqual(first.numbersByName, ["demo-app": 1, "sample-service": 2])
        XCTAssertEqual(state.projectNameNumbersMemo?.numbers, first, "kept for the next redraw")

        state.showCost = false
        XCTAssertEqual(state.projectNameNumbers(hidePersonalInfo: true, now: now).numbersByName,
                       ["sample-service": 1, "demo-app": 2], "costs hidden: ranked by tokens, not the kept answer")

        state.costUsageScanResult = CostUsageScanResult(
            entries: [], projects: [entry(folder("/Users/sample/Projects/web"), cost: 1)])
        XCTAssertNil(state.projectNameNumbersMemo, "a new scan empties it")
        XCTAssertEqual(state.projectNameNumbers(hidePersonalInfo: true, now: now).numbersByName, ["web": 1])

        let later = now.addingTimeInterval(40 * 86_400)
        XCTAssertEqual(state.projectNameNumbers(hidePersonalInfo: true, now: later), .none,
                       "another day asks again: the entry is older than 30 days then")
    }

    // MARK: - Sessions

    func testAScanRowIsItsProviderAndItsMaskedProject() {
        let row = session("local-4242", name: "codex", project: "demo-app")
        XCTAssertEqual(PersonalInfoMask.sessionTitle(row, numbers: numbers, hidePersonalInfo: false), "Codex · demo-app")
        XCTAssertEqual(PersonalInfoMask.sessionTitle(row, numbers: numbers, hidePersonalInfo: true), "Codex · 项目 1")
        let elsewhere = session("proc-7311", name: QARenderSnapshot.privacyCommandLine, provider: "Claude",
                                project: "other-device-app")
        XCTAssertEqual(PersonalInfoMask.sessionTitle(elsewhere, numbers: numbers, hidePersonalInfo: true),
                       "Claude · 隐藏的项目")
        let placeholder = session("local-1", name: "codex", project: SessionRecord.scanRowUnknownProject)
        XCTAssertEqual(PersonalInfoMask.sessionTitle(placeholder, numbers: numbers, hidePersonalInfo: true), "Codex 进程")
    }

    /// Any other row's title was its stored name, which can carry a path.
    /// With the switch on it never is.
    func testAnyOtherRowsStoredNameIsNeverItsTitleWithTheSwitchOn() {
        let named = session("6c1d2e3f", name: "codex exec --cd /Users/sample/Projects/demo-app", project: "demo-app")
        XCTAssertEqual(
            PersonalInfoMask.sessionTitle(named, numbers: numbers, hidePersonalInfo: false),
            "codex exec --cd /Users/sample/Projects/demo-app", "negative control: the switch off shows the name")
        XCTAssertEqual(PersonalInfoMask.sessionTitle(named, numbers: numbers, hidePersonalInfo: true), "Codex 会话")
        let log = session("jsonl-claude-1", name: "Claude · demo-app", provider: "Claude", project: "demo-app")
        XCTAssertEqual(PersonalInfoMask.sessionTitle(log, numbers: numbers, hidePersonalInfo: true), "Claude 会话")
        XCTAssertEqual(PersonalInfoMask.sessionProject(log, numbers: numbers, hidePersonalInfo: true), "项目 1")
    }

    func testTheDetailsProjectFieldIsMaskedOrUnknown() {
        let row = session("jsonl-codex-2", name: "Codex session", project: "sample-service")
        XCTAssertEqual(PersonalInfoMask.sessionDetailProject(row, numbers: numbers, hidePersonalInfo: true), "项目 2")
        XCTAssertEqual(PersonalInfoMask.sessionDetailProject(row, numbers: numbers, hidePersonalInfo: false),
                       "sample-service")
        let none = session("local-9", name: "codex", project: "")
        XCTAssertEqual(PersonalInfoMask.sessionDetailProject(none, numbers: numbers, hidePersonalInfo: true), "未知")
        XCTAssertNil(PersonalInfoMask.sessionProject(none, numbers: numbers, hidePersonalInfo: true))
    }

    // MARK: - Alerts

    /// The Companion CLI's session alert is titled with the stored name, the
    /// start of a command line: with the switch on it names the provider.
    func testASessionAlertNamesItsProviderNotTheCommandLine() {
        let companion = alert(
            id: "session-spike-proc-7311", title: "\(QARenderSnapshot.privacyCommandLine) is consuming high CPU",
            message: "Process CPU is 85.0% for Claude.", project: "sample-service",
            session: QARenderSnapshot.privacyCommandLine, provider: "Claude")
        let off = PersonalInfoMask.alertText(companion, numbers: numbers, hidePersonalInfo: false)
        XCTAssertEqual(off.title, "\(QARenderSnapshot.privacyCommandLine) 正占用大量 CPU", "negative control")
        let on = PersonalInfoMask.alertText(companion, numbers: numbers, hidePersonalInfo: true)
        XCTAssertTrue(on.recognized)
        XCTAssertEqual(on.title, "Claude 正占用大量 CPU")
        XCTAssertEqual(on.message, "Claude 进程的 CPU 占用为 85.0%。")
        XCTAssertEqual(PersonalInfoMask.alertProject(companion, numbers: numbers, hidePersonalInfo: true), "项目 2")
        XCTAssertEqual(PersonalInfoMask.alertSessionName(companion, hidePersonalInfo: true), "会话")
        XCTAssertEqual(PersonalInfoMask.alertSessionName(companion, hidePersonalInfo: false),
                       QARenderSnapshot.privacyCommandLine)
    }

    /// The desktop app's message names the project; the Swift generator's
    /// names the provider, which the title uses with the switch on.
    func testTheDesktopsProjectAndTheSwiftGeneratorsTitleAreMasked() {
        let desktop = alert(
            id: "session-spike-proc-8840", title: "codex-demo-app is consuming high CPU",
            message: "Process CPU is 72.5% for Codex in demo-app.", project: "demo-app",
            session: "codex-demo-app", provider: "Codex")
        let on = PersonalInfoMask.alertText(desktop, numbers: numbers, hidePersonalInfo: true)
        XCTAssertEqual(on.title, "Codex 正占用大量 CPU")
        XCTAssertEqual(on.message, "项目 1 中 Codex 进程的 CPU 占用为 72.5%。")
        XCTAssertFalse((on.title + on.message).contains("demo-app"))

        // A project with no number is said in the sentence's own words, not
        // the "Hidden project" label put into it (which left "隐藏的项目 中",
        // a stray space, and "in Hidden project" in English). On iPhone and
        // the Watch (no numbers) every desktop alert with a project reads so.
        let elsewhere = alert(
            id: "session-spike-proc-8841", title: "codex-other is consuming high CPU",
            message: "Process CPU is 72.5% for Codex in other-device-app.", project: "other-device-app",
            session: "codex-other", provider: "Codex")
        for (record, numbers) in [(elsewhere, numbers), (desktop, ProjectNameNumbers.none)] {
            let hidden = PersonalInfoMask.alertText(record, numbers: numbers, hidePersonalInfo: true)
            XCTAssertEqual(hidden.message, "隐藏的项目中 Codex 进程的 CPU 占用为 72.5%。")
            XCTAssertFalse(hidden.message.contains("隐藏的项目 "), hidden.message)
        }
        XCTAssertEqual(
            PersonalInfoMask.alertText(elsewhere, numbers: numbers, hidePersonalInfo: false).message,
            "other-device-app 中 Codex 进程的 CPU 占用为 72.5%。", "negative control: the switch off")

        let swift = alert(
            id: "session-spike-local-1-3f9a2c1e", title: "ios-dashboard is consuming high CPU",
            message: "Using ~46% of total system CPU (10 cores) for Codex.", project: "demo-app",
            session: "ios-dashboard", provider: nil)
        XCTAssertEqual(PersonalInfoMask.alertText(swift, numbers: numbers, hidePersonalInfo: true).title,
                       "Codex 正占用大量 CPU", "the provider the message names, when the record names none")

        LocaleOverrideStore.shared.set("en")
        XCTAssertEqual(PersonalInfoMask.alertText(elsewhere, numbers: numbers, hidePersonalInfo: true).message,
                       "Process CPU is 72.5% for Codex in a hidden project.")
    }

    /// An alert no template recognises shows its stored English: with the
    /// switch on, with the session's name and the project replaced.
    func testAnUnrecognisedAlertHasItsNamesReplaced() {
        let newer = alert(
            id: "newer-kind-1", title: "codex-demo-app stalled in demo-app",
            message: "No output from codex-demo-app for 20 minutes.", project: "demo-app",
            session: "codex-demo-app", provider: "Codex")
        let on = PersonalInfoMask.alertText(newer, numbers: numbers, hidePersonalInfo: true)
        XCTAssertFalse(on.recognized)
        // The stored English keeps to English: the stand-ins are not the
        // reader's "项目 1" inside an English sentence.
        XCTAssertEqual(on.title, "Codex stalled in Project 1")
        XCTAssertEqual(on.message, "No output from Codex for 20 minutes.")
        XCTAssertEqual(PersonalInfoMask.alertText(newer, numbers: numbers, hidePersonalInfo: false).title,
                       "codex-demo-app stalled in demo-app")
        let stored = PersonalInfoMask.alertStoredText(newer, numbers: numbers, hidePersonalInfo: true)
        XCTAssertEqual(stored.title, "Codex stalled in Project 1")
        let unnamed = alert(
            id: "newer-kind-2", title: "codex-other stalled in other-device-app",
            message: "No output from codex-other.", project: "other-device-app",
            session: "codex-other", provider: nil)
        let hidden = PersonalInfoMask.alertStoredText(unnamed, numbers: numbers, hidePersonalInfo: true)
        XCTAssertEqual(hidden.title, "Session stalled in Hidden project")
        XCTAssertEqual(hidden.message, "No output from Session.")
    }

    /// A session alert that names no provider (the record has none, and the
    /// helper's long-running template names none) says "a session" in the
    /// title's own words: "Session" put into the template doubled the noun
    /// in Korean ("세션 세션이…") and had no article in Spanish.
    func testASessionAlertWithNoProviderNamesNoSession() {
        let longAlert = alert(
            id: "session-long-proc-7311", type: "Session Too Long",
            title: "\(QARenderSnapshot.privacyCommandLine) has been running for a long time",
            message: "Long-running local agent session detected by helper.", project: nil,
            session: QARenderSnapshot.privacyCommandLine, provider: nil)
        let on = PersonalInfoMask.alertText(longAlert, numbers: numbers, hidePersonalInfo: true)
        XCTAssertTrue(on.recognized)
        XCTAssertEqual(on.title, "会话已运行很长时间")
        XCTAssertEqual(
            PersonalInfoMask.alertText(longAlert, numbers: numbers, hidePersonalInfo: false).title,
            "\(QARenderSnapshot.privacyCommandLine) 已运行很长时间", "negative control: the switch off")
        LocaleOverrideStore.shared.set("ko")
        XCTAssertEqual(PersonalInfoMask.alertText(longAlert, numbers: numbers, hidePersonalInfo: true).title,
                       "세션이 오랫동안 실행 중입니다")
        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(PersonalInfoMask.alertText(longAlert, numbers: numbers, hidePersonalInfo: true).title,
                       "Una sesión lleva mucho tiempo en ejecución")
    }

    /// The server's project budget alert (app_rpc.sql: "Budget exceeded:
    /// <project>"), which no template recognises: the Alerts tab, the banner
    /// (`DataRefreshManager.sendNotification`, the same call with the same
    /// numbers) and the export all give the project the number Projects
    /// gives it.
    func testTheServersProjectBudgetAlertNamesTheProjectByItsNumber() {
        let budget = AlertRecord(
            id: "4f6c2a7e-qa", type: "Project Budget Exceeded", severity: "Warning",
            title: "Budget exceeded: sample-service",
            message: "Project \"sample-service\" has accumulated $12.34 this week (threshold: $10.00)",
            created_at: "2026-10-21T09:00:00Z", is_read: false, is_resolved: false, acknowledged_at: nil,
            snoozed_until: nil, related_project_id: nil, related_project_name: "sample-service",
            related_session_id: nil, related_session_name: nil, related_provider: "Claude",
            related_device_name: nil, source_kind: nil)
        let on = PersonalInfoMask.alertText(budget, numbers: numbers, hidePersonalInfo: true)
        XCTAssertFalse(on.recognized)
        XCTAssertEqual(on.title, "Budget exceeded: Project 2")
        XCTAssertEqual(on.message, "Project \"Project 2\" has accumulated $12.34 this week (threshold: $10.00)")
        XCTAssertEqual(PersonalInfoMask.alertProject(budget, numbers: numbers, hidePersonalInfo: true), "项目 2",
                       "the chip, in the reader's language, names the same number")
        let stored = PersonalInfoMask.alertStoredText(budget, numbers: numbers, hidePersonalInfo: true)
        XCTAssertEqual(stored.title, "Budget exceeded: Project 2")
        XCTAssertEqual(PersonalInfoMask.alertText(budget, numbers: .none, hidePersonalInfo: true).title,
                       "Budget exceeded: Hidden project", "a device without a scan")
        let off = PersonalInfoMask.alertText(budget, numbers: numbers, hidePersonalInfo: false)
        XCTAssertEqual(off.title, "Budget exceeded: sample-service", "negative control: the switch off")
        XCTAssertEqual(PersonalInfoMask.alertStoredText(budget, numbers: numbers, hidePersonalInfo: false).message,
                       budget.message)
    }

    // MARK: - Exports

    private var exportSessions: [SessionRecord] {
        QARenderSnapshot.privacySessionsSample(now: Date())
            + [session("jsonl-claude-qa", name: "Claude · demo-app", provider: "Claude", project: "demo-app")]
    }

    private var needles: [String] {
        QARenderSnapshot.personalStrings(
            sessions: exportSessions, alerts: QARenderSnapshot.privacyAlertsSample(now: Date()),
            projects: scan.map(\.project))
    }

    private func leaks(_ text: String) -> [String] {
        needles.filter { text.contains($0) }
    }

    func testTheSessionsExportShowsNoNameOrPathWithTheSwitchOn() {
        let on = ExportService.sessionsCSV(sessions: exportSessions, hidePersonalInfo: true, projectNumbers: numbers)
        XCTAssertEqual(leaks(on), [])
        // A data file: the app's words are English like its headers and
        // Status, whatever the reader's language (zh-Hans here).
        XCTAssertTrue(on.contains(",Claude · Project 2,Claude,Project 2,"), on)
        XCTAssertTrue(on.contains(",Codex session,Codex,Project 1,"), on)
        XCTAssertFalse(on.contains("项目") || on.contains("会话"), on)
        let off = ExportService.sessionsCSV(sessions: exportSessions, hidePersonalInfo: false, projectNumbers: .none)
        XCTAssertTrue(off.contains(QARenderSnapshot.privacyCommandLine), "negative control: the switch off")
        XCTAssertFalse(leaks(off).isEmpty)
    }

    func testTheCostReportShowsNoProjectWithTheSwitchOn() {
        func report(_ hide: Bool) -> String {
            ExportService.costReportCSV(
                dashboard: nil, counts: DashboardCounts(activeSessions: 0, onlineDevices: 0),
                providers: [], sessions: exportSessions, hidePersonalInfo: hide,
                projectNumbers: hide ? numbers : .none)
        }
        XCTAssertEqual(leaks(report(true)), [])
        XCTAssertTrue(report(true).contains("Codex,项目 1,"))
        XCTAssertTrue(report(false).contains("Codex,demo-app,"), "negative control: the switch off")
    }

    func testTheAlertsExportShowsNoNameWithTheSwitchOn() {
        let alerts = QARenderSnapshot.privacyAlertsSample(now: Date())
        let on = ExportService.alertsCSV(alerts: alerts, hidePersonalInfo: true, projectNumbers: numbers)
        XCTAssertEqual(leaks(on), [])
        XCTAssertTrue(on.contains("Claude is consuming high CPU"), on)
        XCTAssertTrue(on.contains("Process CPU is 72.5% for Codex in Project 1."), on)
        XCTAssertFalse(on.contains("项目") || on.contains("会话"), "every sentence in one language: \(on)")
        let hidden = ExportService.alertsCSV(alerts: alerts, hidePersonalInfo: true, projectNumbers: .none)
        XCTAssertTrue(hidden.contains("Process CPU is 72.5% for Codex in Hidden project.,Codex,Hidden project,"), hidden)
        let off = ExportService.alertsCSV(alerts: alerts, hidePersonalInfo: false, projectNumbers: .none)
        XCTAssertTrue(off.contains(QARenderSnapshot.privacyCommandLine), "negative control: the switch off")
    }

    #if canImport(PDFKit) && !os(watchOS)
    /// The PDF's text, read back from the file as the renderer reads it.
    func testThePDFShowsNoProjectWithTheSwitchOn() throws {
        func pdfText(_ hide: Bool) throws -> String {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-privacy.pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            let written = PDFReportGenerator.generateReport(
                dashboard: nil, counts: DashboardCounts(activeSessions: 0, onlineDevices: 0),
                providers: [], sessions: exportSessions, dailyUsage: [], costForecast: nil,
                hidePersonalInfo: hide, projectNumbers: hide ? numbers : .none, destinationURL: url)
            let document = try XCTUnwrap(written.flatMap(PDFDocument.init(url:)))
            return try XCTUnwrap(document.string)
        }
        let on = try pdfText(true)
        XCTAssertEqual(leaks(on), [])
        XCTAssertTrue(on.contains("项目 1"), on)
        XCTAssertTrue(try pdfText(false).contains("sample-service"), "negative control: the switch off")
    }
    #endif

    // MARK: - Paths into the home folder

    func testAPathIntoTheHomeFolderStartsWithATilde() {
        let home = "/Users/sample"
        XCTAssertEqual(
            PersonalInfoMask.homeFolder(in: "/Users/sample/.claude/settings.json", hidePersonalInfo: true, home: home),
            "~/.claude/settings.json")
        XCTAssertEqual(
            PersonalInfoMask.homeFolder(
                in: "无法读取 /Users/sample/.claude/settings.json：权限不足", hidePersonalInfo: true, home: home + "/"),
            "无法读取 ~/.claude/settings.json：权限不足")
        XCTAssertEqual(PersonalInfoMask.homeFolder(in: "/Users/sample", hidePersonalInfo: true, home: home), "~")
        XCTAssertEqual(
            PersonalInfoMask.homeFolder(in: "/Users/samples/x", hidePersonalInfo: true, home: home),
            "/Users/samples/x", "another account's folder is not this one")
        XCTAssertEqual(
            PersonalInfoMask.homeFolder(in: "/Users/sample/x", hidePersonalInfo: false, home: home),
            "/Users/sample/x", "negative control: the switch off")
    }

    // MARK: - The switch's line in Settings

    /// Settings › Advanced says what the switch hides, in every language.
    func testTheSwitchsLineNamesWhatItHides() {
        XCTAssertEqual(L10n.advanced.hidePersonalInfoHelp, "在屏幕上和导出的文件中隐藏邮箱地址、项目文件夹的名称和路径，以及会话名称。")
        XCTAssertEqual(L10n.projects.hidden, "隐藏的项目")
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"] {
            LocaleOverrideStore.shared.set(language)
            let line = L10n.advanced.hidePersonalInfoHelp
            XCTAssertNotEqual(line, "advanced.hide_personal_info_help", language)
            XCTAssertFalse(line.isEmpty, language)
            if language != "en" {
                XCTAssertNotEqual(line, "Hides email addresses, project folder names and paths, and session names, on screen and in exports.", language)
            }
        }
    }
}

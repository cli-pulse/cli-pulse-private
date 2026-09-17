// The cost report CSV is a document for people — the CSV twin of the PDF
// report — so its words follow the app's language while its values stay raw.
// The three data CSVs stay English (see `ExportService.costReportCSV`).
//
// Asserted in ja: English is the fallback copy, so an English assertion
// still passes when the lookup is broken.
import XCTest
@testable import CLIPulseCore

final class CostReportCSVLocalizationTests: XCTestCase {
    private var savedLocaleOverride: String?

    override func setUp() {
        super.setUp()
        savedLocaleOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("ja")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedLocaleOverride)
        super.tearDown()
    }

    private let generatedAt = Date(timeIntervalSince1970: 1_750_000_000)

    private func report() -> String {
        let dashboard = DashboardSummary(
            total_usage_today: 12345, total_estimated_cost_today: 1.25,
            cost_status: "Estimated", total_requests_today: 0,
            active_sessions: 4, online_devices: 2, unresolved_alerts: 3,
            provider_breakdown: [], top_projects: [], trend: [], recent_activity: [],
            risk_signals: [], alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0))
        let providers = [
            ProviderUsage(
                provider: "Cursor", today_usage: 0, week_usage: 500,
                estimated_cost_today: 0, estimated_cost_week: 1.5,
                cost_status_today: "ok", cost_status_week: "ok",
                quota: nil, remaining: nil, status_text: "",
                trend: [], recent_sessions: [], recent_errors: []),
        ]
        let sessions = [
            SessionRecord(
                id: "s1", name: "Chat", provider: "Claude", project: "Proj",
                device_name: "Mac", started_at: "2026-04-01T10:00:00Z", last_active_at: "2026-04-01T11:00:00Z",
                status: "Running", total_usage: 100, estimated_cost: 0.05,
                cost_status: "normal", requests: 10, error_count: 0),
        ]
        return ExportService.costReportCSV(dashboard: dashboard, providers: providers,
                                           sessions: sessions, generatedAt: generatedAt)
    }

    func test_wordsFollowTheAppLanguage() {
        let lines = report().components(separatedBy: "\n")
        // The title is catalogue copy, so the brand keeps its no-break space
        // (`L10n.keepingBrandUnbroken`) like every other displayed string.
        XCTAssertEqual(lines.first, "\u{FEFF}CLI\u{00A0}Pulse コストレポート")
        // Two cells, label then timestamp, as the English report always had.
        XCTAssertEqual(lines[1], "生成,\(sharedISO8601Formatter.string(from: generatedAt))")
        for expected in [
            "概要",
            "今日の使用量,12345",
            "今日の推定コスト,$1.25",
            "アクティブセッション,4",
            "オンラインデバイス,2",
            "未解決のアラート,3",
            "プロバイダー別内訳",
            "プロバイダー,週間使用量,推定コスト,残量,クォータ",
            "Cursor,500,1.5,該当なし,該当なし",
            "コスト上位セッション",
            "プロバイダー,プロジェクト,コスト,使用量,ステータス",
        ] {
            XCTAssertTrue(lines.contains(expected), "missing line: \(expected)")
        }
    }

    /// Values a spreadsheet sorts, sums or filters on do not change with the
    /// language: numbers unformatted, status as the server sent it.
    func test_valuesStayRaw() {
        let lines = report().components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Claude,Proj,0.05,100,Running"))
        for english in ["Cost Report", "Summary", "Today Usage", "Provider Breakdown",
                        "Top Sessions by Cost", "N/A", "Generated"] {
            XCTAssertFalse(report().contains(english), "English heading left in a ja report: \(english)")
        }
    }

    /// The data exports are keyed on by scripts and imports: English headers
    /// in every language, by decision.
    func test_dataExportsKeepEnglishHeaders() throws {
        let url = try XCTUnwrap(ExportService.exportSessionsCSV(sessions: []))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("ID,Name,Provider,Project,Status,Usage,Cost,Requests,Errors,Started,Last Active\n"))
    }
}

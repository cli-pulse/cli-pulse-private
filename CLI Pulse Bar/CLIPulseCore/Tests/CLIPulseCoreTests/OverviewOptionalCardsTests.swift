import XCTest
@testable import CLIPulseCore

/// The Overview's Top Projects and Risk Signals cards: one rule decides when
/// they draw (Mac, iPhone, Watch), and Demo builds its dashboard from the same
/// producers a real account does. Every App Store screenshot is drawn from
/// Demo, and until 1.55 it showed both cards filled in six languages while no
/// customer could see either.
///
/// Runs in Simplified Chinese: risk signals are text resolved when they are
/// made, and under English a broken lookup still passes, because the fallback
/// copy is English.
final class OverviewOptionalCardsTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    private func dashboard(projects: [TopProject], signals: [String]) -> DashboardSummary {
        DashboardSummary(
            total_usage_today: 1, total_estimated_cost_today: 1, cost_status: "Estimated",
            total_requests_today: 1, active_sessions: 1, online_devices: 1, unresolved_alerts: 0,
            provider_breakdown: [], top_projects: projects, trend: [], recent_activity: [],
            risk_signals: signals, alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0))
    }

    /// Every risk signal the local refresh can raise, over every input it takes.
    private var producibleRiskSignals: Set<String> {
        var all = Set<String>()
        for sessions in [false, true] {
            for providerData in [false, true] {
                all.formUnion(DashboardRiskSignals.local(foundSessions: sessions, foundProviderData: providerData))
            }
        }
        return all
    }

    // MARK: - The rule

    func testTheCardsDrawOnlyWithRows() {
        let empty = dashboard(projects: [], signals: [])
        XCTAssertFalse(empty.showsTopProjectsCard, "an empty Top Projects card is drawn")
        XCTAssertFalse(empty.showsRiskSignalsCard, "an empty Risk Signals card is drawn")

        let filled = dashboard(
            projects: [TopProject(id: "p", name: "app", usage: 1, estimated_cost: 0.01, cost_status: "Estimated")],
            signals: [L10n.dashboard.noAiToolsDetected])
        XCTAssertTrue(filled.showsTopProjectsCard, "a Top Projects card with rows is hidden")
        XCTAssertTrue(filled.showsRiskSignalsCard, "a Risk Signals card with a signal is hidden")
    }

    // MARK: - Production

    /// The cloud dashboard has no project or risk column, whatever the row holds.
    func testTheCloudDashboardFillsNeitherCard() throws {
        let row = Data("""
            {"today_usage": 120000, "today_cost": 3.5, "active_sessions": 4,
             "online_devices": 2, "unresolved_alerts": 3, "today_sessions": 9}
            """.utf8)
        let payload = try JSONDecoder().decode(APIClient.DashboardSummaryPayload.self, from: row)
        let dash = APIClient.dashboardSummary(from: payload)

        XCTAssertEqual(dash.total_usage_today, 120000, "the row did not decode, so this proves nothing")
        XCTAssertFalse(dash.showsTopProjectsCard)
        XCTAssertFalse(dash.showsRiskSignalsCard)
    }

    /// The local refresh raises one signal, only when it found nothing at all,
    /// and raises it in the user's language.
    func testTheLocalRefreshRaisesOnlyNoAIToolsDetectedInTheUsersLanguage() throws {
        XCTAssertEqual(DashboardRiskSignals.local(foundSessions: false, foundProviderData: false),
                       [L10n.dashboard.noAiToolsDetected])
        XCTAssertEqual(DashboardRiskSignals.local(foundSessions: true, foundProviderData: false), [])
        XCTAssertEqual(DashboardRiskSignals.local(foundSessions: false, foundProviderData: true), [])
        XCTAssertEqual(DashboardRiskSignals.local(foundSessions: true, foundProviderData: true), [])

        let chinese = try XCTUnwrap(DashboardRiskSignals.local(foundSessions: false, foundProviderData: false).first)
        LocaleOverrideStore.shared.set("en")
        let english = try XCTUnwrap(DashboardRiskSignals.local(foundSessions: false, foundProviderData: false).first)
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertNotEqual(chinese, english, "the risk signal is not localized: \(chinese)")
        XCTAssertNil(chinese.range(of: "[A-Za-z]{3,}", options: .regularExpression),
                     "English words in the Chinese risk signal: \(chinese)")
    }

    // MARK: - Demo

    /// No real producer fills `top_projects`, so Demo must not either: the
    /// card would appear in every screenshot and on no customer's Mac.
    func testDemoShowsNoTopProjectsCard() {
        let demo = DemoDataProvider.generate().dashboard
        XCTAssertFalse(demo.showsTopProjectsCard, """
            Demo fills Top Projects (\(demo.top_projects.map(\.name))), which no real account can see. \
            Restore the rows only with a real producer.
            """)
    }

    /// Demo raises only signals the local refresh can raise. It has sessions
    /// and provider data, so it raises none and the card hides. That Demo
    /// calls the producer at all is a call site, held by the wiring test below.
    func testDemoRaisesOnlyTheRiskSignalsARealAccountCan() {
        let demo = DemoDataProvider.generate()
        let producible = producibleRiskSignals
        XCTAssertEqual(producible, [L10n.dashboard.noAiToolsDetected],
                       "the local refresh's signals changed; recheck Demo against them")

        for signal in demo.dashboard.risk_signals {
            XCTAssertTrue(producible.contains(signal), "Demo raises a risk signal nothing real raises: \(signal)")
        }
        XCTAssertFalse(demo.dashboard.showsRiskSignalsCard, """
            Demo shows a Risk Signals card (\(demo.dashboard.risk_signals)), which an account with \
            sessions and provider data does not.
            """)
    }

    // MARK: - Wiring

    /// Source-level, because what the tests above cannot reach is call sites.
    /// The local refresh builds its dashboard inside a private async method,
    /// and the three Overviews are views. Put an inline signal back into
    /// `DataRefreshManager`, or draw a card without the rule, and every
    /// behavioural test above still passes.
    ///
    /// Every dashboard built in CLIPulseCore fills the two cards only with
    /// nothing (`[]`), with another dashboard's rows, or, for risk signals,
    /// from `DashboardRiskSignals.local`.
    func testEveryDashboardInCoreFillsTheCardsOnlyFromTheRealProducers() throws {
        let sources = Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let argument = try NSRegularExpression(pattern: #"\b(top_projects|risk_signals):\s*([^\n]*)"#)

        var sitesPerFile: [String: [String]] = [:]
        for file in files {
            let code = Self.codeOnly(try String(contentsOf: file, encoding: .utf8))
            let whole = NSRange(code.startIndex..., in: code)
            for match in argument.matches(in: code, range: whole) {
                guard let labelRange = Range(match.range(at: 1), in: code),
                      let valueRange = Range(match.range(at: 2), in: code) else { continue }
                let label = String(code[labelRange])
                var value = code[valueRange].trimmingCharacters(in: .whitespaces)
                if value.hasSuffix(",") { value.removeLast() }
                // A declaration (`let top_projects: [TopProject]`, an init
                // parameter), not a value. Only a bare type name: a value
                // such as `[L10n.dashboard.…]` also opens with a capital.
                if value.range(of: #"^\[[A-Z]\w*\](,|$)"#, options: .regularExpression) != nil { continue }

                let name = file.lastPathComponent
                sitesPerFile[name, default: []].append("\(label): \(value)")
                let passthrough = value.range(of: #"^\w+\.\#(label)$"#, options: .regularExpression) != nil
                var allowed = value == "[]" || passthrough
                if label == "risk_signals" {
                    let boundLocal = value.range(of: #"^\w+$"#, options: .regularExpression) != nil
                        && code.contains("let \(value) = DashboardRiskSignals.local(")
                    allowed = allowed || value.hasPrefix("DashboardRiskSignals.local(") || boundLocal
                }
                XCTAssertTrue(allowed, """
                    \(name) fills \(label) with `\(value)`. Nothing real produces Top Projects rows, and the \
                    only risk signal a real account can see comes from DashboardRiskSignals.local. If this \
                    is a new real producer, give Demo the same rows in the same change and update this test.
                    """)
            }
        }

        // Positive controls: a wrong path or a broken pattern would make every
        // assertion above vacuous.
        XCTAssertTrue(sitesPerFile["DataRefreshManager.swift", default: []]
            .contains { $0.hasPrefix("risk_signals: DashboardRiskSignals.local(") },
                      "the local refresh's producer was not found: \(sitesPerFile["DataRefreshManager.swift"] ?? [])")
        XCTAssertTrue(sitesPerFile["DemoDataProvider.swift", default: []].contains("top_projects: []"),
                      "Demo's dashboard was not found: \(sitesPerFile["DemoDataProvider.swift"] ?? [])")
        XCTAssertTrue(sitesPerFile["APIClient.swift", default: []].contains("risk_signals: []"),
                      "the cloud mapping was not found: \(sitesPerFile["APIClient.swift"] ?? [])")
    }

    /// The Mac, iPhone and Watch Overviews draw each card only under the rule:
    /// every place a card's title is drawn sits just inside
    /// `if dash.showsTopProjectsCard {` (or the Risk Signals one).
    func testEveryOverviewDrawsTheCardsOnlyUnderTheRule() throws {
        let cards = [("L10n.dashboard.topProjects", "if dash.showsTopProjectsCard {"),
                     ("L10n.dashboard.riskSignals", "if dash.showsRiskSignalsCard {")]
        for path in ["CLI Pulse Bar/OverviewTab.swift",
                     "CLI Pulse Bar iOS/iOSOverviewTab.swift",
                     "CLI Pulse Bar Watch/PulseHomeView.swift"] {
            let text = try String(contentsOf: Self.appSourceRoot.appendingPathComponent(path), encoding: .utf8)
            let lines = Self.codeOnly(text).components(separatedBy: "\n")
            for (title, rule) in cards {
                let titleLines = lines.indices.filter { lines[$0].contains(title) }
                // Positive control: the card is still in this Overview.
                XCTAssertFalse(titleLines.isEmpty, "\(path) no longer draws \(title); is this still the Overview?")
                for line in titleLines {
                    let above = lines[max(0, line - 8)..<line]
                    XCTAssertTrue(above.contains { $0.contains(rule) }, """
                        \(path):\(title) is drawn without `\(rule)` just above it. An empty card, or one \
                        no customer can fill, is back on this Overview.
                        """)
                }
            }
        }
    }

    // MARK: - Source helpers

    /// The `CLIPulseCore` package root.
    private static var coreRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
    }

    /// `CLI Pulse Bar/`, which holds the app targets and `CLIPulseCore`.
    private static var appSourceRoot: URL {
        coreRoot.deletingLastPathComponent()
    }

    /// Whole-line comments dropped: the comments explaining the rule name the
    /// very symbols these scans look for.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

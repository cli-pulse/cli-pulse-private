import XCTest
@testable import CLIPulseCore

/// Two iPhone screens said the same word twice in a row.
///
/// * Overview: the heatmap card is titled Activity, and the hourly bar chart
///   right below it was titled Activity as well.
/// * Sessions: the large navigation title said Sessions, and a headline under
///   it said Sessions again (and the iPad sidebar list repeated it as a section
///   header).
///
/// The views are in the iPhone app target, which `swift test` does not build,
/// so their titles are read from the source; the words are checked in every
/// shipped language.
final class IPhoneSectionTitleTests: XCTestCase {

    override func tearDown() {
        LocaleOverrideStore.shared.set(nil)
        super.tearDown()
    }

    private static let iOSApp = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // …/CLIPulseCore
        .deletingLastPathComponent()    // …/CLI Pulse Bar
        .appending(path: "CLI Pulse Bar iOS")

    private func source(_ file: String) throws -> String {
        try String(contentsOf: Self.iOSApp.appending(path: file), encoding: .utf8)
    }

    func test_theHourlyCard_isNotTitledLikeTheHeatmapAboveIt() throws {
        let overview = try source("iOSOverviewTab.swift")
        let start = try XCTUnwrap(overview.range(of: "private func activityTimeline("))
        let card = String(overview[start.upperBound...].prefix(500))
        XCTAssertTrue(card.contains("Text(L10n.dashboard.hourlyActivity)"), card)
        XCTAssertFalse(card.contains("L10n.dashboard.activity"), card)
        let heatmap = try source("iOSUsageHeatmapView.swift")
        XCTAssertTrue(heatmap.contains("SectionHeader(title: L10n.usageDashboard.activity"),
                      "the heatmap title this is kept apart from has moved")

        for localization in LocaleOverrideStore.shippedLocalizations {
            LocaleOverrideStore.shared.set(localization)
            let hourly = L10n.dashboard.hourlyActivity
            XCTAssertNotEqual(hourly, L10n.usageDashboard.activity, localization)
            XCTAssertNotEqual(hourly, "dashboard.hourly_activity", localization)
            if localization != "en" {
                XCTAssertNotEqual(hourly, "Hourly activity", "\(localization) is not translated")
            }
        }
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(L10n.dashboard.hourlyActivity, "每小时活动")
        XCTAssertEqual(L10n.dashboard.activity, "活动", "the Watch keeps the shared title")
    }

    /// The Mac Overview has the same two cards in the same order: the usage card
    /// (`CompactUsageCard`, titled Activity) and the hourly chart right below it,
    /// which was titled Activity as well. Seen in the offscreen renders in all
    /// six languages.
    func test_theMacHourlyCard_isNotTitledLikeTheUsageCardAboveIt() throws {
        let app = Self.iOSApp.deletingLastPathComponent().appending(path: "CLI Pulse Bar")
        let overview = try String(contentsOf: app.appending(path: "OverviewTab.swift"), encoding: .utf8)
        let start = try XCTUnwrap(overview.range(of: "private func activityTimeline("))
        let card = String(overview[start.upperBound...].prefix(300))
        XCTAssertTrue(card.contains("SectionHeader(title: L10n.dashboard.hourlyActivity"), card)
        XCTAssertFalse(card.contains("L10n.dashboard.activity"), card)

        let usageCard = try XCTUnwrap(overview.range(of: "CompactUsageCard()"))
        let timeline = try XCTUnwrap(overview.range(of: "activityTimeline(dash.trend)"))
        XCTAssertLessThan(usageCard.lowerBound, timeline.lowerBound,
                          "the two cards this keeps apart are no longer in this order")

        let core = Self.iOSApp.deletingLastPathComponent()
            .appending(path: "CLIPulseCore/Sources/CLIPulseCore/UsageDashboardView.swift")
        let compact = try String(contentsOf: core, encoding: .utf8)
        XCTAssertTrue(compact.contains("Text(L10n.usageDashboard.activity)"),
                      "the usage card title this is kept apart from has moved")
    }

    func test_theSessionsScreen_saysSessionsOnce() throws {
        let sessions = try source("iOSSessionsTab.swift")
        let uses = sessions.components(separatedBy: "L10n.tab.sessions").count - 1
        let titles = sessions.components(separatedBy: ".navigationTitle(L10n.tab.sessions)").count - 1
        XCTAssertEqual(titles, 2, "the iPhone stack and the iPad sidebar each name the screen")
        XCTAssertEqual(uses, titles, "Sessions is repeated under its own navigation title")
    }
}

// 1.60 (59-12): two Mac layout fixes, checked in the app target's source,
// which this package does not compile.
//
//   C14: the webhook filter's labels ("Severidades", "Tipos de alerta") sit
//        above their chips, not in a 70 pt column that broke them.
//   C25: every banner at the top of the menu bar popover shows its message as
//        primary text on the tinted fill and has a 16 pt close target.
//
// C26 (the Data source picker's names) is in ProviderCardSourceLineTests.

import Foundation
import XCTest

final class MacPolish160Tests: XCTestCase {

    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func code(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheWebhookFilterLabelsSitAboveTheirChips() throws {
        let general = try Self.code("CLI Pulse Bar/GeneralSection.swift")
        for label in ["L10n.integrations.filterSeverities", "L10n.integrations.filterTypes"] {
            let at = try XCTUnwrap(general.range(of: "Text(\(label))"), "\(label) is gone")
            let before = general[..<at.lowerBound].suffix(80)
            XCTAssertTrue(before.contains("VStack(alignment: .leading"), "\(label) is not stacked above its chips")
            let after = general[at.upperBound...].prefix(260)
            XCTAssertTrue(after.contains("WebhookChipFlowLayout(spacing: 4)"), "\(label) is not followed by its chips")
            XCTAssertFalse(after.prefix(200).contains(".frame(width:"), "\(label) is in a fixed-width column again")
        }
    }

    /// Each banner's close: the 8 pt glyph in a 16 pt square that takes the
    /// click. Each banner's message: primary text.
    func testEveryBannerHasALegibleMessageAndARealCloseTarget() throws {
        let menu = try Self.code("CLI Pulse Bar/MenuBarView.swift")
        let closes = menu.components(separatedBy: #"Image(systemName: "xmark")"#).dropFirst()
        XCTAssertEqual(closes.count, 4, "the error, migration, retired-provider and tier banners; recheck if this changed")
        for (index, after) in closes.enumerated() {
            let label = after.prefix(300)
            XCTAssertTrue(label.contains(".frame(width: 16, height: 16"), "close \(index) is an 8 pt target")
            XCTAssertTrue(label.contains(".contentShape(Rectangle())"), "close \(index) does not take the click across its frame")
        }
        for message in ["Text(error)", "Text(L10n.menuBar.tierMigration(", "Text(L10n.menuBar.retiredProvidersNotice)",
                        "Text(warning)"] {
            let at = try XCTUnwrap(menu.range(of: message), "\(message) is gone")
            XCTAssertTrue(menu[at.upperBound...].prefix(260).contains(".foregroundStyle(Color.primary)"),
                          "\(message) is drawn in the banner's tint, which is under 3:1 on its fill")
        }
    }
}

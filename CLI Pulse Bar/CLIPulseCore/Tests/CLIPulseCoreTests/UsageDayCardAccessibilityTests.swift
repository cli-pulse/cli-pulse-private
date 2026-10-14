import SwiftUI
import XCTest
@testable import CLIPulseCore

/// v1.57 release gate (b), run on an iPhone 17 Pro simulator: the iPhone
/// provider card's day detail at large text sizes.
///
/// - In a row of name, cost and tokens the figures keep their full width and
///   the name takes what is left. At XXL and XXXL that is enough; at AX1 the
///   names were cut to "claude…us-4-1", and at AX5 to "…" alone. At
///   accessibility sizes the card puts each model's figures under its name.
/// - At AX1 the day's line wrapped inside "I/O" ("2.5M I/" over "O tokens"):
///   a slash is a line-break opportunity. The card's line keeps it together.
///
/// The layout itself was looked at on the simulator; these pin the rules it
/// follows. Text is asserted in zh-Hans, ja and es: an English assertion
/// passes with the lookup broken, because the fallback is English.
final class UsageDayCardAccessibilityTests: XCTestCase {
    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    /// The card stacks a model's figures under its name from AX1 up, and
    /// keeps the grid, whose columns line up, at every size below. The Mac
    /// panel's sizes are fixed, so it never stacks.
    func testCardStacksFiguresUnderTheNameFromTheFirstAccessibilitySize() {
        // The sizes the gate ran.
        XCTAssertFalse(UsageDayModelRows.stacksFigures(style: .card, dynamicTypeSize: .large))
        XCTAssertFalse(UsageDayModelRows.stacksFigures(style: .card, dynamicTypeSize: .xxLarge))
        XCTAssertFalse(UsageDayModelRows.stacksFigures(style: .card, dynamicTypeSize: .xxxLarge))
        XCTAssertTrue(UsageDayModelRows.stacksFigures(style: .card, dynamicTypeSize: .accessibility1))
        XCTAssertTrue(UsageDayModelRows.stacksFigures(style: .card, dynamicTypeSize: .accessibility5))

        let stacked = DynamicTypeSize.allCases.filter {
            UsageDayModelRows.stacksFigures(style: .card, dynamicTypeSize: $0)
        }
        XCTAssertEqual(stacked, [.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5])
        for size in DynamicTypeSize.allCases {
            XCTAssertFalse(UsageDayModelRows.stacksFigures(style: .panel, dynamicTypeSize: size), "\(size)")
        }
    }

    /// "I/O" (Spanish "E/S") keeps its letters on one line in the card's day
    /// line, in each language's own words; nothing else in the line changes.
    func testTheDayLineKeepsIOOnOneLine() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(
            ProviderUsageHistorySection.keepingSlashAbbreviationsUnbroken(
                L10n.providerPanel.dayIOSummary("10月8日", "≥$22.99", "2.5M")),
            "10月8日：≥$22.99 · 2.5M I/\u{2060}O token")
        XCTAssertEqual(
            ProviderUsageHistorySection.keepingSlashAbbreviationsUnbroken(
                L10n.providerPanel.dayIOTokens("10月8日", "2.5M")),
            "10月8日：2.5M I/\u{2060}O token")

        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(
            ProviderUsageHistorySection.keepingSlashAbbreviationsUnbroken(
                L10n.providerPanel.dayIOSummary("10月8日", "$2.02", "168.9K")),
            "10月8日: $2.02 · 168.9K I/\u{2060}O トークン")

        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(
            ProviderUsageHistorySection.keepingSlashAbbreviationsUnbroken(
                L10n.providerPanel.dayIOSummary("29 sept", "2,02 US$", "168,9 mil")),
            "29 sept: 2,02 US$ · 168,9 mil tokens de E/\u{2060}S")
    }

    /// Only a slash with a letter on each side is joined: a date written with
    /// slashes, a figure, a slash at either end or beside a space keep theirs.
    func testOnlyASlashBetweenTwoLettersIsJoined() {
        let keep = ProviderUsageHistorySection.keepingSlashAbbreviationsUnbroken
        XCTAssertEqual(keep("10/8: $1.00 · 2/3"), "10/8: $1.00 · 2/3")
        XCTAssertEqual(keep("I/ O · I /O"), "I/ O · I /O")
        XCTAssertEqual(keep("/O"), "/O")
        XCTAssertEqual(keep("I/"), "I/")
        XCTAssertEqual(keep("Oct 8: no usage"), "Oct 8: no usage")
        XCTAssertEqual(keep(""), "")
        XCTAssertEqual(keep("A/B/C"), "A/\u{2060}B/\u{2060}C")
    }
}

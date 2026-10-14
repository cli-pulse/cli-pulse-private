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
/// follows, and `UsageDayModelRowsLayoutTests` below checks that the rows
/// view follows them. Text is asserted in zh-Hans, ja and es: an English
/// assertion passes with the lookup broken, because the fallback is English.
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

    /// The line the card's day detail draws (`dayLine`, which the view
    /// calls) is the joined one, in zh-Hans through the real catalogue: with
    /// and without the cost, and unchanged where the count has no "I/O".
    func testTheCardsDayLineKeepsIOOnOneLineInZhHans() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let day = ProviderUsageDays.Day(dateKey: "2026-10-08", models: [
            .init(model: "claude-opus-4-1", tokens: 1_200_000, cost: 4.10),
            .init(model: "glm-4.6", tokens: 900_000, cost: 0, unpricedTokens: 900_000),
        ])
        let count = CostFormatter.formatUsage(day.tokens)

        XCTAssertEqual(
            ProviderUsageHistorySection.dayLine(day: day, basis: .inputOutput, showsCost: true),
            day.dateText + "：" + day.costText + " · " + count + " I/\u{2060}O token")
        XCTAssertEqual(
            ProviderUsageHistorySection.dayLine(day: day, basis: .inputOutput, showsCost: false),
            day.dateText + "：" + count + " I/\u{2060}O token")

        let eachOnce = ProviderUsageHistorySection.dayLine(day: day, basis: .eachOnce, showsCost: true)
        XCTAssertEqual(eachOnce, day.summary(basis: .eachOnce, showsCost: true))
        XCTAssertFalse(eachOnce.contains("\u{2060}"), eachOnce)
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

#if os(macOS)
/// The rows view follows `stacksFigures`: hosted at a fixed width, the
/// card's rows take two lines a model at an accessibility size and one
/// below it, and the Mac panel's rows are the same height at both. Heights
/// are counted in lines of the card's text at the same size, so a larger
/// font is not mistaken for a second line.
@MainActor
final class UsageDayModelRowsLayoutTests: XCTestCase {
    private let rows: [ProviderUsageDays.ModelRow] = [
        .init(model: "claude-opus-4-1", tokens: 1_200_000, cost: 4.10),
        .init(model: "claude-sonnet-4-5", tokens: 2_400_000, cost: 2.05),
        .init(model: "claude-haiku-4-5", tokens: 600_000, cost: 0.28),
        .init(model: "glm-4.6", tokens: 900_000, cost: 0, unpricedTokens: 900_000),
    ]

    private func height<Content: View>(_ content: Content, at size: DynamicTypeSize) -> CGFloat {
        let host = NSHostingController(rootView: content
            .environment(\.dynamicTypeSize, size)
            .frame(width: 300))
        return host.sizeThatFits(in: CGSize(width: 300, height: 10_000)).height
    }

    private func rowsHeight(_ style: UsageDayModelRows.Style, at size: DynamicTypeSize) -> CGFloat {
        height(UsageDayModelRows(rows: rows, basis: .inputOutput, accent: .blue, showsCost: true, style: style),
               at: size)
    }

    /// One line of the card's text.
    private func lineHeight(at size: DynamicTypeSize) -> CGFloat {
        height(Text(verbatim: "Mg").font(.caption), at: size)
    }

    func testTheCardsRowsStackAtAnAccessibilitySizeAndThePanelsNever() {
        let models = CGFloat(rows.count)

        let line = lineHeight(at: .large)
        let card = rowsHeight(.card, at: .large)
        XCTAssertGreaterThan(line, 0)
        XCTAssertGreaterThan(card, 0)
        XCTAssertLessThan(card, 2 * models * line,
                          "at the default size each model is one line of the grid (\(card) pt, line \(line) pt)")

        let axLine = lineHeight(at: .accessibility1)
        let axCard = rowsHeight(.card, at: .accessibility1)
        XCTAssertGreaterThanOrEqual(axCard, 2 * models * axLine,
                                    "at AX1 each model's figures go under its name (\(axCard) pt, line \(axLine) pt)")

        let panel = rowsHeight(.panel, at: .large)
        XCTAssertGreaterThan(panel, 0)
        XCTAssertEqual(rowsHeight(.panel, at: .accessibility1), panel,
                       "the Mac panel keeps its grid at every size")
    }
}
#endif

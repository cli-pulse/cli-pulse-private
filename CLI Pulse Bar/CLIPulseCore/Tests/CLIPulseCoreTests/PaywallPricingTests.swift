import XCTest
@testable import CLIPulseCore

/// "Yearly (Save 17%)" shipped in six locales while the yearly plan was the
/// more expensive option. These pin the arithmetic and the absence of the
/// literal that made it possible.
final class PaywallPricingTests: XCTestCase {

    private func pct(_ m: Decimal, _ y: Decimal) -> Int? {
        PaywallPricing.yearlySavingPercent(monthly: m, yearly: y)
    }

    /// The prices actually in App Store Connect on 2026-09-01. Twelve monthly
    /// payments are $11.88 against $12.99 for the year, so there is no saving
    /// and the badge must not appear at all.
    func test_theLivePricesOfferNoSaving() {
        XCTAssertNil(pct(0.99, 12.99),
                     "yearly costs MORE than 12x monthly — claiming a discount is what this fixes")
    }

    /// The prices the "17%" literal was written for. Kept so the arithmetic is
    /// shown to be right, not merely different.
    func test_theOldPricesReallyDidSaveSeventeenPercent() {
        XCTAssertEqual(pct(4.99, 49.99), 17)
    }

    func test_boundaries() {
        XCTAssertNil(pct(1.00, 12.00), "identical cost is not a saving")
        XCTAssertNil(pct(1.00, 12.05), "a yearly premium is never a saving")
        XCTAssertNil(pct(0, 12.99), "no monthly price to compare against")
        XCTAssertNil(pct(0.99, 0), "no yearly price to compare against")
        XCTAssertNil(pct(-1, 12), "negative prices are not a discount")
        XCTAssertEqual(pct(1.00, 10.00), 17, "(12 - 10) / 12 = 16.67% -> 17%")
        XCTAssertEqual(pct(10.00, 60.00), 50)
        XCTAssertNil(pct(100.00, 1199.95), "0.004% rounds to 0 — do not claim it")
    }

    /// The literal is what made the claim outlive the prices. Every locale's
    /// format string must carry the placeholder and no baked-in number.
    func test_noLocaleHardcodesASavingPercentage() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .appendingPathComponent("Sources/CLIPulseCore/Resources")

        var checked = 0
        for locale in ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"] {
            let url = resources.appendingPathComponent("\(locale).lproj/Localizable.strings")
            let text = try String(contentsOf: url, encoding: .utf8)
            // Positive control: a wrong path would make this vacuous.
            XCTAssertTrue(text.contains("subscription.monthly"),
                          "\(locale): scan path is wrong")

            let line = text.split(separator: "\n")
                .first { $0.contains("\"subscription.yearly_save\"") }
            let value = try XCTUnwrap(line, "\(locale) has no subscription.yearly_save")
            XCTAssertTrue(value.contains("%@"),
                          "\(locale) dropped the placeholder: \(value)")
            XCTAssertNil(value.range(of: #"[0-9]+ ?%"#, options: .regularExpression),
                         "\(locale) hardcodes a percentage again: \(value)")
            checked += 1
        }
        XCTAssertEqual(checked, 6, "a locale was skipped; the scan is incomplete")
    }
}

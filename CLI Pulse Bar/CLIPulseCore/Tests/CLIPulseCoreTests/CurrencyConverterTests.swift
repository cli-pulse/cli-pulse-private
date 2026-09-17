// Unit tests for the v1.40 PR-7 CurrencyConverter: display-time USD→currency
// conversion, per-currency formatting (symbol + fraction digits + grouping +
// small-value convention), open.er-api rate parse, and 24h TTL freshness.

import XCTest
@testable import CLIPulseCore

final class CurrencyConverterTests: XCTestCase {

    /// Digits follow the display locale; these tests pin symbols, rates and
    /// rounding, so they format as en_US wherever they run.
    private let en = Locale(identifier: "en_US")

    override func tearDown() {
        LocaleOverrideStore.shared.set(nil)
        super.tearDown()
    }

    private func makeConverter() -> CurrencyConverter {
        // Empty suite ⇒ hardcoded fallback rates (USD 1, CNY 7.15, JPY 150, …).
        let suite = UserDefaults(suiteName: "fx-\(UUID().uuidString)")!
        return CurrencyConverter(defaults: suite)
    }

    func test_format_usd_default() {
        let c = makeConverter()
        c.setCurrency(.usd)
        XCTAssertEqual(c.format(12.5, locale: en), "$12.50")
        XCTAssertEqual(c.format(1234.5, locale: en), "$1,234.50")
    }

    func test_format_cny_uses_yen_symbol_and_rate() {
        let c = makeConverter()
        c.setCurrency(.cny)
        // 10 USD × 7.15 = 71.50
        XCTAssertEqual(c.format(10, locale: en), "¥71.50")
    }

    func test_format_jpy_zero_decimals_grouped() {
        let c = makeConverter()
        c.setCurrency(.jpy)
        // 12.5 USD × 150 = 1875 → ¥1,875 (no decimals)
        XCTAssertEqual(c.format(12.5, locale: en), "¥1,875")
    }

    func test_format_twd_symbol() {
        let c = makeConverter()
        c.setCurrency(.twd)
        XCTAssertTrue(c.format(10, locale: en).hasPrefix("NT$"), c.format(10, locale: en))
    }

    func test_format_small_value_convention() {
        let c = makeConverter()
        c.setCurrency(.usd)
        XCTAssertEqual(c.format(0.001, locale: en), "<$0.01")
        XCTAssertEqual(c.format(0, locale: en), "$0.00")     // exactly zero is not "<"
        c.setCurrency(.jpy)
        XCTAssertEqual(c.format(0.001, locale: en), "<¥1")   // 0-decimal smallest unit is 1
    }

    /// Only the digits follow the reader. The symbol stays where
    /// `DisplayCurrency.symbol` puts it, so a Japanese reader's CNY is still
    /// "¥", not a locale's "CN¥", and Spain does not move it behind the number.
    func test_format_digitsFollowTheLocale_symbolStaysInFront() {
        let c = makeConverter()
        c.setCurrency(.usd)
        XCTAssertEqual(c.format(12_345.67, locale: Locale(identifier: "es_ES")), "$12.345,67")
        c.setCurrency(.eur)
        XCTAssertEqual(c.format(100, locale: Locale(identifier: "es_ES")), "€92,00")
        c.setCurrency(.cny)
        XCTAssertEqual(c.format(10, locale: Locale(identifier: "ja_JP")), "¥71.50")
    }

    func test_formatWholeUnits_convertsBeforeRounding() {
        let c = makeConverter()
        c.setCurrency(.usd)
        XCTAssertEqual(c.formatWholeUnits(146.7, locale: en), "$147")
        c.setCurrency(.cny)
        // 146.03 USD × 7.15 = 1044.11
        XCTAssertEqual(c.formatWholeUnits(146.03, locale: en), "¥1,044")
    }

    /// Siri said "$7.31" to a user who picked yuan. It now speaks the chosen
    /// currency, and a sub-unit amount in words rather than with a "<".
    func test_spokenFormat_speaksTheChosenCurrency() {
        LocaleOverrideStore.shared.set("ja")
        let c = makeConverter()
        XCTAssertEqual(c.spokenFormat(10, as: .cny), c.format(10, as: .cny))
        XCTAssertTrue(c.spokenFormat(10, as: .cny).hasPrefix("¥71"), c.spokenFormat(10, as: .cny))
        XCTAssertEqual(c.spokenFormat(0.001, as: .cny), "¥0.01 未満")
        // The dollar keeps its own words.
        XCTAssertEqual(c.spokenFormat(0.004, as: .usd), "1セント未満")
    }

    // MARK: - Handoff to the widgets and the Watch

    /// The widgets and the Watch showed "$7.31" to a user who picked yuan: they
    /// run in processes that cannot read the app's defaults. The app hands its
    /// converter's currency and rate over, and the other process formats with
    /// both. The rate travels too: the app's fetched 7.0 is not the fallback
    /// 7.15 the other process would otherwise convert at.
    func test_handoff_letsAnotherProcessShowTheAppsCurrencyAtTheAppsRate() {
        let appDefaults = UserDefaults(suiteName: "fx-\(UUID().uuidString)")!
        appDefaults.set(["CNY": 7.0], forKey: CurrencyConverter.ratesKey)
        let app = CurrencyConverter(defaults: appDefaults)
        app.setCurrency(.cny)
        let handoff = app.handoff()
        XCTAssertEqual(handoff.currencyCode, "CNY")
        XCTAssertEqual(handoff.rate, 7.0)

        let widget = makeConverter()
        XCTAssertEqual(widget.format(10, locale: en), "$10.00", "control: a new process shows dollars")
        widget.adopt(currencyCode: handoff.currencyCode, rate: handoff.rate)

        XCTAssertEqual(widget.format(10, locale: en), "¥70.00")
        XCTAssertEqual(widget.format(10, locale: en), app.format(10, locale: en))
        // The Watch's hero rung, which went through its own "$" before.
        XCTAssertEqual(WatchPulseFormat.abbreviatedCost(146.03, converter: widget, locale: en), "¥1,022")
    }

    /// A payload from an app that predates the handoff has no currency. That
    /// app showed dollars there, so dollars it stays, even in a process that
    /// adopted something else earlier.
    func test_adopt_withoutACurrency_showsDollars() {
        let c = makeConverter()
        c.adopt(currencyCode: "JPY", rate: 150)
        XCTAssertEqual(c.format(10, locale: en), "¥1,500")
        c.adopt(currencyCode: nil, rate: nil)
        XCTAssertEqual(c.format(10, locale: en), "$10.00")
        c.adopt(currencyCode: "XYZ", rate: 3)
        XCTAssertEqual(c.format(10, locale: en), "$10.00")
    }

    func test_adopt_keepsItsOwnRateWhenTheHandedOneIsUnusable() {
        let c = makeConverter()
        for bad in [nil, 0, -1, Double.nan, Double.infinity] as [Double?] {
            c.adopt(currencyCode: "EUR", rate: bad)
            XCTAssertEqual(c.rate(), 0.92, accuracy: 0.0001, String(describing: bad))
        }
    }

    func test_storedCurrency_readsTheAppsOwnKey() {
        let suite = UserDefaults(suiteName: "fx-\(UUID().uuidString)")!
        XCTAssertEqual(DisplayCurrency.stored(in: suite), .usd)
        suite.set("JPY", forKey: DisplayCurrency.defaultsKey)
        XCTAssertEqual(DisplayCurrency.stored(in: suite), .jpy)
        suite.set("XYZ", forKey: DisplayCurrency.defaultsKey)
        XCTAssertEqual(DisplayCurrency.stored(in: suite), .usd)
    }

    func test_convert_and_rate() {
        let c = makeConverter()
        c.setCurrency(.eur)
        XCTAssertEqual(c.rate(), 0.92, accuracy: 0.0001)
        XCTAssertEqual(c.convert(100), 92, accuracy: 0.001)
    }

    func test_cached_rates_override_fallback() {
        let suite = UserDefaults(suiteName: "fx-\(UUID().uuidString)")!
        suite.set(["CNY": 7.0], forKey: CurrencyConverter.ratesKey)
        let c = CurrencyConverter(defaults: suite)
        c.setCurrency(.cny)
        XCTAssertEqual(c.rate(), 7.0, accuracy: 0.0001)   // cached beats fallback 7.15
        XCTAssertEqual(c.convert(10), 70, accuracy: 0.001)
    }

    // MARK: - parseRates

    func test_parseRates_success_shape() {
        let json = #"{"result":"success","base_code":"USD","rates":{"USD":1,"CNY":7.1,"EUR":0.92}}"#
        let parsed = CurrencyConverter.parseRates(Data(json.utf8))
        XCTAssertEqual(parsed?["CNY"] ?? -1, 7.1, accuracy: 0.001)
        XCTAssertEqual(parsed?["EUR"] ?? -1, 0.92, accuracy: 0.001)
    }

    func test_parseRates_non_success_is_nil() {
        XCTAssertNil(CurrencyConverter.parseRates(Data(#"{"result":"error","rates":{"CNY":7}}"#.utf8)))
    }

    func test_parseRates_invalid_is_nil() {
        XCTAssertNil(CurrencyConverter.parseRates(Data("not json".utf8)))
        XCTAssertNil(CurrencyConverter.parseRates(Data(#"{"result":"success"}"#.utf8)))   // no rates
    }

    // MARK: - TTL

    func test_refreshRatesIfStale_skips_when_fresh() async {
        let suite = UserDefaults(suiteName: "fx-\(UUID().uuidString)")!
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        suite.set(now.timeIntervalSince1970, forKey: CurrencyConverter.fetchedAtKey)
        suite.set(["CNY": 7.0], forKey: CurrencyConverter.ratesKey)
        let c = CurrencyConverter(defaults: suite)
        // 1 hour later → within 24h TTL → no fetch, cached rate preserved.
        await c.refreshRatesIfStale(now: now.addingTimeInterval(3600))
        c.setCurrency(.cny)
        XCTAssertEqual(c.rate(), 7.0, accuracy: 0.0001)
    }
}

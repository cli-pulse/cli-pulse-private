import XCTest
@testable import CLIPulseCore

/// Displayed dates and numbers follow the reader's language and region; stored
/// values do not.
///
/// Separators come from the region, and CI (like most dev Macs here) runs in
/// en_US, where a Spanish choice still formats "2.5". So the separator tests
/// replace the system locale `displayLocale` starts from with es_ES. Without
/// that, a formatter that ignored the display locale would pass them.
final class DisplayFormatTests: XCTestCase {

    private var savedSystemLocale: (() -> Locale)!

    override func setUp() {
        super.setUp()
        savedSystemLocale = LocaleOverrideStore.systemLocale
    }

    override func tearDown() {
        LocaleOverrideStore.systemLocale = savedSystemLocale
        LocaleOverrideStore.shared.set(nil)
        super.tearDown()
    }

    private func readInSpain() {
        LocaleOverrideStore.systemLocale = { Locale(identifier: "es_ES") }
        LocaleOverrideStore.shared.set("es")
    }

    // MARK: - Numbers

    /// "12.5 W", "1.52 · 1.40" and "2.5 commits" on a Spanish Mac, where the
    /// point reads as a thousands separator.
    func test_shownDecimals_takeTheDisplayLocaleSeparator() {
        readInSpain()
        XCTAssertEqual(DisplayFormat.string("%.1f W", 12.5), "12,5 W")
        XCTAssertEqual(DisplayFormat.string("%.2f · %.2f", 1.52, 1.4), "1,52 · 1,40")
        XCTAssertEqual(DisplayFormat.decimal(2.5, fractionDigits: 1), "2,5")
        XCTAssertEqual(L10n.yield.commitsCountDecimal(2.5), "2,5 commits", "a catalogue decimal ignores the display locale")
        XCTAssertEqual(L10n.dashboard.utilizedPercent(42.4), "42% utilizado")
        XCTAssertEqual(CostFormatter.formatUsage(154_100), "154,1K")
    }

    /// A catalogue `%d` is as often an OSStatus, a byte count or an RPM as a
    /// count, and must read as the number: "estado -25.308" cannot be searched
    /// for. A locale groups `%d` too, so `L10n` formats arguments without one.
    ///
    /// Each check first shows the region really would group that number:
    /// Spanish leaves four digits alone ("1234"), so a four-digit case there
    /// could not fail.
    func test_catalogueIntegers_stayUngroupedInTheReadersRegion() {
        readInSpain()
        XCTAssertEqual(DisplayFormat.string("%d", -25_308), "-25.308", "control: Spain groups five digits")
        XCTAssertEqual(L10n.collectorStatus.zedKeychainReadFailed(-25_308),
                       "Zed: no se pudo leer el Llavero (estado -25308)")
        XCTAssertEqual(L10n.collectorCredential.text(.zedKeychainReadFailed(-25_308), english: false),
                       "Zed: no se pudo leer el Llavero (estado -25308)")

        LocaleOverrideStore.systemLocale = { Locale(identifier: "ja_JP") }
        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(DisplayFormat.string("%d", 5_779), "5,779", "control: Japan groups four digits")
        XCTAssertEqual(L10n.machine.fanMaxRpm(5_779), "最大 5779 rpm")
        XCTAssertEqual(L10n.dashboard.utilizedPercent(42), "使用率 42%")
    }

    /// With no in-app language the system's own region applies.
    func test_shownDecimals_withoutAChoice_followTheSystemRegion() {
        LocaleOverrideStore.systemLocale = { Locale(identifier: "es_ES") }
        XCTAssertEqual(DisplayFormat.string("%.1f", 2.5), "2,5")
    }

    func test_countUpHeadline_groupsTheReadersWay() {
        XCTAssertEqual(CountUpNumber.grouped(12_345_678, locale: Locale(identifier: "en_US")), "12,345,678")
        XCTAssertEqual(CountUpNumber.grouped(12_345_678, locale: Locale(identifier: "es_ES")), "12.345.678")
    }

    // MARK: - Day keys

    func test_dayKey_rendersAsADateInTheLocale() {
        let key = "2026-09-17"
        XCTAssertEqual(DisplayFormat.day(key, locale: Locale(identifier: "ja_JP")), "2026年9月17日")
        XCTAssertEqual(DisplayFormat.day(key, locale: Locale(identifier: "ko_KR")), "2026년 9월 17일")
        XCTAssertEqual(DisplayFormat.day(key, locale: Locale(identifier: "en_US")), "Sep 17, 2026")
        // The PDF's narrow column: "09-17" read as day 9 of month 17 in Spanish.
        XCTAssertEqual(DisplayFormat.day(key, style: .numeric, locale: Locale(identifier: "es_ES")), "17/9")
        XCTAssertEqual(DisplayFormat.day(key, style: .numeric, locale: Locale(identifier: "en_US")), "9/17")
    }

    func test_dayKey_defaultsToTheDisplayLanguage() {
        LocaleOverrideStore.shared.set("ja")
        let shown = DisplayFormat.day("2026-09-17")
        XCTAssertEqual(shown, "2026年9月17日")
    }

    /// The Pet tab's "Hatched …" line, built the way PetTab builds it. Its
    /// templates were written for the raw key ("2026-09-17 に孵化"), and the
    /// space before the particle stayed when the value became a date that ends
    /// in 日: "2026年9月17日 に孵化" reads as a stray gap. Spanish needs the
    /// article before a date, as the quota reset template does ("el …").
    func test_petHatchedLine_joinsTheDateTheReadersWay() throws {
        let key = "2026-09-17"
        LocaleOverrideStore.systemLocale = { Locale(identifier: "en_US") }  // as on CI
        func line(_ language: String) throws -> (date: String, line: String) {
            LocaleOverrideStore.shared.set(language)
            let date = try XCTUnwrap(DisplayFormat.day(key), language)
            return (date, L10n.pet.ownedOn(date))
        }
        XCTAssertEqual(try line("ja").line, "2026年9月17日に孵化")
        XCTAssertEqual(try line("zh-Hans").line, "2026年9月17日孵化")
        XCTAssertEqual(try line("zh-Hant").line, "2026年9月17日孵化")
        // Korean spaces before a noun, so its template keeps the gap.
        XCTAssertEqual(try line("ko").line, "2026년 9월 17일 부화")
        // A reader in Spain. The date is ICU's ("17 sept 2026") and varies by
        // release; the template around it is what is pinned.
        readInSpain()
        let spanish = try line("es")
        XCTAssertEqual(spanish.line, "Eclosionado el \(spanish.date)")
        XCTAssertTrue(spanish.date.hasPrefix("17 "), spanish.date)
    }

    /// A key names a day, not a moment. Rendered in the device's zone, its UTC
    /// midnight is the evening before anywhere west of Greenwich. This Mac and
    /// CI are not, so the zone itself is pinned rather than an output.
    func test_dayKey_rendersInUTC_soItCannotSlipToThePreviousDay() throws {
        for style in [DisplayFormat.DayStyle.full, .numeric] {
            let format = DisplayFormat.dayFormat(style, locale: Locale(identifier: "en_US"))
            XCTAssertEqual(format.timeZone.secondsFromGMT(), 0, "\(style) renders in \(format.timeZone.identifier)")
        }
        let key = try XCTUnwrap(DisplayFormat.date(ofDayKey: "2026-09-17"))
        XCTAssertEqual(key, try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-17T00:00:00Z")))
    }

    func test_dayKey_thatIsNotADay_isNil() {
        for key in ["2026-02-30", "2026-9-17", "2026-13-01", "not a key", ""] {
            XCTAssertNil(DisplayFormat.day(key, locale: Locale(identifier: "en_US")), key)
        }
    }

    // MARK: - Moments

    func test_dateTime_isAShortLocalDateAndTime() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-16T14:00:00Z"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(DisplayFormat.dateTime(date, locale: Locale(identifier: "ja_JP"), timeZone: utc), "9月16日 14:00")
        XCTAssertEqual(DisplayFormat.dateTime(date, locale: Locale(identifier: "ko_KR"), timeZone: utc), "9월 16일 오후 2:00")
    }

    // MARK: - Heatmap tooltip

    /// It read "2026-09-17: 1.2K tokens · $0.40" under Japanese headings.
    func test_heatmapTooltip_isLocalized() {
        LocaleOverrideStore.shared.set("ja")
        let ja = Locale(identifier: "ja_JP")
        let day = DayRollup(tokens: 1_200, cost: 0.4, messages: 3)

        let shown = UsageHeatmapGrid.tooltip("2026-09-17", day: day, locale: ja)

        XCTAssertTrue(shown.hasPrefix("2026年9月17日: 1.2K トークン · "), shown)
        XCTAssertFalse(shown.contains("tokens"), shown)
        XCTAssertEqual(UsageHeatmapGrid.tooltip("2026-09-17", day: nil, locale: ja), "2026年9月17日")
    }
}

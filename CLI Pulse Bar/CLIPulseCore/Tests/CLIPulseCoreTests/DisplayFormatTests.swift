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
    ///
    /// Only the digits are checked, not the sentences around them, so a
    /// wording pass on these keys cannot break the test.
    func test_catalogueIntegers_stayUngroupedInTheReadersRegion() {
        readInSpain()
        XCTAssertEqual(DisplayFormat.string("%d", -25_308), "-25.308", "control: Spain groups five digits")
        for shown in [L10n.collectorStatus.zedKeychainReadFailed(-25_308),
                      L10n.collectorCredential.text(.zedKeychainReadFailed(-25_308), english: false)] {
            XCTAssertTrue(shown.contains("-25308"), shown)
            XCTAssertFalse(shown.contains("25.308"), shown)
            XCTAssertFalse(shown.contains("status"), "control: not the English text: \(shown)")
        }

        LocaleOverrideStore.systemLocale = { Locale(identifier: "ja_JP") }
        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(DisplayFormat.string("%d", 5_779), "5,779", "control: Japan groups four digits")
        let rpm = L10n.machine.fanMaxRpm(5_779)
        XCTAssertTrue(rpm.contains("5779"), rpm)
        XCTAssertFalse(rpm.contains("5,779"), rpm)
        XCTAssertFalse(rpm.contains("max"), "control: not the English text: \(rpm)")
        XCTAssertTrue(L10n.dashboard.utilizedPercent(42).contains("42%"), L10n.dashboard.utilizedPercent(42))
    }

    /// The Mac's process list printed CPU with `DisplayFormat.string`, which
    /// groups: a process at 1234.5% on a many-core Mac read "1,234.5%" in a
    /// fixed 48pt column, where the extra character can truncate it.
    func test_processCPU_isNeverGrouped() {
        let japan = Locale(identifier: "ja_JP")
        XCTAssertEqual(DisplayFormat.decimal(1_234.5, fractionDigits: 1, locale: japan), "1,234.5",
                       "control: Japan groups four digits")
        XCTAssertEqual(MachineFormat.processCPU(1_234.5, locale: japan), "1234.5%")
        XCTAssertEqual(MachineFormat.processCPU(12_345.6, locale: Locale(identifier: "es_ES")), "12345,6%")
        XCTAssertEqual(MachineFormat.processCPU(12.5, locale: Locale(identifier: "es_ES")), "12,5%")
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
    /// in 日: "2026年9月17日 に孵化" reads as a stray gap.
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
        // Spanish on a US region writes the month first ("sept 17, 2026"), and
        // "Eclosionado el sept 17, 2026" is not Spanish. The date's own text is
        // ICU's and varies by release, so only what comes before it is checked.
        let usRegion = try line("es")
        XCTAssertTrue(usRegion.date.hasPrefix("sept"), "control: month first on a US region: \(usRegion.date)")
        XCTAssertTrue(usRegion.line.contains(usRegion.date), usRegion.line)
        XCTAssertFalse(usRegion.line.contains("el \(usRegion.date)"), usRegion.line)
        readInSpain()
        let spain = try line("es")
        XCTAssertTrue(spain.date.hasPrefix("17 "), spain.date)
        XCTAssertTrue(spain.line.contains(spain.date), spain.line)
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

    /// Both Chinese catalogues write "token" in lower case inside a phrase and
    /// capitalize it only where a label starts with it. The tooltip said
    /// "1.2K Token".
    func test_heatmapTooltip_writesTokenTheWayChineseDoes() {
        let day = DayRollup(tokens: 1_200, cost: 0.4, messages: 3)
        for (language, locale) in [("zh-Hans", "zh_CN"), ("zh-Hant", "zh_TW")] {
            LocaleOverrideStore.shared.set(language)
            let shown = UsageHeatmapGrid.tooltip("2026-09-17", day: day, locale: Locale(identifier: locale))
            XCTAssertTrue(shown.hasPrefix("2026年9月17日"), "control: a Chinese date: \(shown)")
            XCTAssertTrue(shown.contains(" token"), "\(language): \(shown)")
            XCTAssertFalse(shown.contains("Token"), "\(language): \(shown)")
        }
    }
}

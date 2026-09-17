import Foundation

/// Dates, times and numbers the way the reader expects to see them.
///
/// Everything here is for displayed text, and formats in
/// `LocaleOverrideStore.shared.displayLocale` unless the caller passes the
/// locale its view environment holds (the same value on macOS, the system
/// locale on iPhone and Watch). Values that are stored, synced, exported for
/// machines, logged or used as keys keep their fixed POSIX formats and never
/// come through here.
///
/// Dates use CLDR skeletons through `Date.FormatStyle`, never fixed patterns: a
/// fixed `ha` once printed "3下午" under Chinese, and pinning it to English to
/// avoid that printed "3pm" in every language instead. A skeleton lets each
/// locale order its own fields.
public enum DisplayFormat {

    // MARK: - Numbers

    /// A decimal as the reader writes it: "2.5", "2,5" in Spain. Grouped like
    /// any quantity ("1,234.5"), so it is for amounts, never for a code.
    public static func decimal(
        _ value: Double,
        fractionDigits: Int,
        locale: Locale = LocaleOverrideStore.shared.displayLocale
    ) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    /// `String(format:)` in the display locale, for a literal format of
    /// measurements: "12,5 W" in Spain.
    ///
    /// A locale groups every numeric conversion, `%d` as much as `%f`:
    /// "51,000" in the US, "51.000" in Spain. So this is not for catalogue
    /// values, whose `%d` can be an OSStatus or a byte count (`L10n.tr` formats
    /// those without a locale), nor for any format with a number meant to be
    /// read or searched as written.
    public static func string(_ format: String, _ arguments: CVarArg...) -> String {
        string(format, arguments: arguments)
    }

    public static func string(_ format: String, arguments: [CVarArg]) -> String {
        String(format: format, locale: LocaleOverrideStore.shared.displayLocale, arguments: arguments)
    }

    // MARK: - Dates and times

    /// An hour of the day on a chart axis, in the locale's own clock:
    /// "3 PM", "15時", "오후 3시", "下午3时".
    public static func hour(
        _ date: Date,
        locale: Locale = LocaleOverrideStore.shared.displayLocale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(style(locale: locale, timeZone: timeZone)
            .hour(.defaultDigits(amPM: .abbreviated)))
    }

    /// A moment as a short date and time, for text that may be read after the
    /// moment has passed, so a relative "in 3h" would be wrong:
    /// "Sep 20 at 3:00 PM", "9月20日 15:00".
    public static func dateTime(
        _ date: Date,
        locale: Locale = LocaleOverrideStore.shared.displayLocale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(style(locale: locale, timeZone: timeZone)
            .month(.abbreviated).day()
            .hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
    }

    /// How much of a date a stored day key is shown with.
    public enum DayStyle: Sendable {
        /// "Sep 17, 2026", "2026年9月17日", "17 sept 2026".
        case full
        /// Month and day in digits, for a narrow column: "9/17", "17/9".
        case numeric
    }

    /// A stored day key ("2026-09-17") as a date to read, or nil when the key
    /// is not a real Gregorian day, so the caller can show the key itself.
    ///
    /// The key names a calendar day, not a moment, so it is rendered in UTC,
    /// where its midnight lives, and cannot slip to the day before west of
    /// Greenwich. The locale's own calendar still numbers it: a Japanese
    /// calendar shows the imperial year, which is what that reader chose.
    public static func day(
        _ dayKey: String,
        style dayStyle: DayStyle = .full,
        locale: Locale = LocaleOverrideStore.shared.displayLocale
    ) -> String? {
        guard let date = date(ofDayKey: dayKey) else { return nil }
        return date.formatted(dayFormat(dayStyle, locale: locale))
    }

    /// The format `day` renders with. Internal so a test can pin its zone to
    /// UTC: no machine that runs the tests is west of Greenwich, so the output
    /// alone could not show a formatter that fell back to the device's zone.
    static func dayFormat(_ dayStyle: DayStyle, locale: Locale) -> Date.FormatStyle {
        let base = style(locale: locale, timeZone: utc)
        switch dayStyle {
        case .full: return base.year().month(.abbreviated).day()
        case .numeric: return base.month(.defaultDigits).day()
        }
    }

    // MARK: - Helpers

    /// UTC. Unlike `TimeZone(secondsFromGMT: 0)`, `.gmt` is not optional, so
    /// nothing here force-unwraps.
    static let utc: TimeZone = .gmt

    /// The locale's calendar rather than the device's: with an in-app language
    /// the display locale carries the user's calendar already, and a formatter
    /// that took `Calendar.autoupdatingCurrent` separately could disagree with
    /// the locale it was given.
    private static func style(locale: Locale, timeZone: TimeZone) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: locale.calendar, timeZone: timeZone)
    }

    /// Midnight UTC of a `yyyy-MM-dd` key, read by splitting rather than with a
    /// date formatter: a key is Gregorian and POSIX by definition, so there is
    /// nothing locale-dependent to parse, and a formatter left to any other
    /// calendar misreads the year.
    static func date(ofDayKey dayKey: String) -> Date? {
        let parts = dayKey.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day)
        // `date(from:)` rolls 2026-02-30 over into March; a key that does not
        // survive the round trip is not a day.
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components
        else { return nil }
        return date
    }
}

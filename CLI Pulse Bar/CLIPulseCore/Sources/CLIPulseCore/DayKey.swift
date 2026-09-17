import Foundation

/// Machine day keys: the `"2026-09-17"` strings the app stores, uploads,
/// compares and looks up — scan buckets, `metric_date`, `p_user_today`, the
/// usage archive, the pet ledger, Codex's `YYYY/MM/DD` session directories,
/// the PDF export's file name.
///
/// They are always Gregorian and always POSIX, whatever calendar the user
/// picked in Language & Region. `Calendar.current` and a bare `DateFormatter()`
/// follow that setting instead: on 2026-09-17 the Japanese calendar numbers the
/// year 8, the Republic of China calendar 115 and the Buddhist calendar
/// (Thailand's default) 2569, and a bare `yyyy-MM-dd` formatter under the
/// Japanese calendar reads "2026-09-17" as the year 4044. Keys built that way
/// match nothing written by the server, by other devices or by the Codex CLI,
/// so usage went missing, uploads were dated year 0008, and the Yield card
/// dropped every row.
///
/// Only the numbering is pinned. Where a day starts is still a time-zone
/// question, and every function here takes the zone whose midnight splits days
/// (the device's unless the caller says otherwise). Dates shown to the user are
/// a different matter and should keep following the user's calendar.
///
/// This file is the one place allowed to build a key: `DayKeySourceGuardTests`
/// fails if a `"yyyy-MM-dd"` formatter or a `%04d-%02d-%02d` key appears
/// anywhere else in the app's sources. That guard only knows those spellings;
/// the device calendar can leak into a key many other ways, so swift-ci.yml
/// also runs the whole test suite under the Japanese, ROC and Buddhist calendars.
public enum DayKey {

    /// UTC, for keys whose days split at UTC midnight (server dates, the
    /// heatmap's string arithmetic). `TimeZone(identifier: "UTC")` cannot fail
    /// on any OS this package supports; `.gmt` is the same offset and keeps the
    /// constant non-optional without a force unwrap.
    public static let utc: TimeZone = TimeZone(identifier: "UTC") ?? .gmt

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// A Gregorian calendar with the POSIX locale in `timeZone`. Use it for any
    /// arithmetic whose year, month or day numbers end up in a key or a path.
    public static func calendar(in timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = posixLocale
        calendar.timeZone = timeZone
        return calendar
    }

    /// The key of the day containing `date`, with days split at midnight in
    /// `timeZone`.
    public static func string(from date: Date, in timeZone: TimeZone = .current) -> String {
        let c = calendar(in: timeZone).dateComponents([.year, .month, .day], from: date)
        return string(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// The key for a year, month and day that are already Gregorian — taken
    /// from `calendar(in:)`, never from `Calendar.current`.
    public static func string(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// A `yyyy-MM-dd` formatter that reads and writes keys in `timeZone`.
    ///
    /// The calendar is set explicitly, not left to the POSIX locale: the locale
    /// supplies a Gregorian calendar only to a formatter that was never given
    /// one, and a calendar set earlier survives it (measured).
    public static func formatter(in timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = posixLocale
        f.calendar = calendar(in: timeZone)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Year, month and day of a key, without judging whether they form a
    /// Gregorian date. nil unless the key is `dddd-dd-dd` in ASCII digits.
    ///
    /// Walks the UTF-8 view in place rather than copying it into an array: the
    /// scanner cache checks every key it holds on every load (`isPlausible`).
    static func fields(of key: String) -> (year: Int, month: Int, day: Int)? {
        let utf8 = key.utf8
        guard utf8.count == 10 else { return nil }
        var year = 0, month = 0, day = 0
        var position = 0
        for byte in utf8 {
            if position == 4 || position == 7 {
                guard byte == 0x2D else { return nil }   // "-"
            } else {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                let digit = Int(byte &- 0x30)
                switch position {
                case 0..<4: year = year * 10 + digit
                case 5..<7: month = month * 10 + digit
                default: day = day * 10 + digit
                }
            }
            position += 1
        }
        return (year, month, day)
    }

    /// Days in a Gregorian month (1-12). The leap rule is the Gregorian one,
    /// which is what `Calendar(identifier: .gregorian)` applies to every year
    /// since 1582, so for the years `isPlausible` accepts it gives the same
    /// answer as asking the calendar.
    static func daysInGregorianMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// The moment `hour` o'clock on the day `key` names, in `timeZone`. nil when
    /// the key does not name a real Gregorian date.
    public static func date(from key: String, hour: Int = 0, in timeZone: TimeZone = .current) -> Date? {
        guard let f = fields(of: key) else { return nil }
        let cal = calendar(in: timeZone)
        var comps = DateComponents()
        comps.year = f.year; comps.month = f.month; comps.day = f.day; comps.hour = hour
        // A lenient calendar rolls 2026-02-30 into March; a key must name the
        // day it spells.
        guard let date = cal.date(from: comps),
              string(from: date, in: timeZone) == key else { return nil }
        return date
    }

    // MARK: - Keys written before the calendar was pinned

    /// The first year a key written by this app can name. Local usage history
    /// begins with the Codex and Claude CLIs (2025); the margin is for clocks
    /// and fixtures, and it still sits above the Ethiopic calendar's year
    /// (2019 until September 2027), the closest any Foundation calendar gets
    /// to Gregorian numbering from below. An Ethiopic-calendar Mac that first
    /// runs this code after September 2027 keeps its old keys; every other
    /// calendar stays years outside the window.
    static let earliestPlausibleYear = 2020

    /// The last year a key can name. It is a fixed year, not "next year" by the
    /// device clock: with the clock set years behind, a clock-relative bound
    /// turns every real key into a foreign one that cannot be read back, and
    /// the usage archive and the pet ledger drop them on load and save the
    /// loss, while the scanner cache starts over on every scan.
    ///
    /// The nearest numbering above the window is Vikram Samvat, and Gujarati,
    /// which counts from it: 2076 on 2020-01-01 and 2083 on 2026-09-17.
    /// Foundation has offered both since macOS 26 and iOS 26, so a year like
    /// 2400 would let their keys pass as Gregorian. Buddhist, the next one up,
    /// starts at 2563. With 2075, a Vikram key for any day since 2020 stays
    /// outside the window, and Gregorian keys fit through 2075.
    static let latestPlausibleYear = 2075

    /// Whether `key` names a real Gregorian date this app could have recorded,
    /// in a year from `earliestPlausibleYear` through `latestPlausibleYear`.
    ///
    /// Other calendars number the years since 2020 outside that window — on
    /// 2026-09-17 Japanese 8, ROC 115, Persian 1405, Islamic 1448, Indian 1948,
    /// Ethiopic 2019, Vikram 2083, Buddhist 2569, Hebrew 5787 — so a key inside
    /// it was written in Gregorian. Ethiopic alone enters it, in September 2027.
    /// `DayKeyTests` checks every calendar Foundation offers, month by month
    /// from 2020 through 2075. Nothing here reads the clock, so a wrong device
    /// clock cannot make real history look foreign.
    ///
    /// Pure arithmetic, no `Calendar`, `Locale` or allocation: the scanner
    /// cache runs it on every day key of every file entry on each scan, and
    /// building calendars for that cost about 3.4 µs a key. Every year in the
    /// window is a Gregorian-era year, so the arithmetic gives the same answer
    /// as round-tripping the key through a Gregorian calendar, which is what
    /// this did before; `test_plausible_matches_a_gregorian_calendar_round_trip`
    /// holds the two equal.
    public static func isPlausible(_ key: String) -> Bool {
        guard let f = fields(of: key),
              f.year >= earliestPlausibleYear, f.year <= latestPlausibleYear,
              f.month >= 1, f.month <= 12, f.day >= 1 else { return false }
        return f.day <= daysInGregorianMonth(f.month, year: f.year)
    }

    /// A key read back from local storage, in Gregorian numbering.
    ///
    /// Before the calendar was pinned, a device set to another calendar wrote
    /// keys in that calendar's numbering. Those keys still name the right day
    /// when read in the calendar that wrote them, which is almost always the
    /// device's calendar now. Returns `key` unchanged when it is already
    /// plausible, the Gregorian key of the day it names when read in
    /// `writtenIn`, and nil when neither reading gives a plausible day — the
    /// caller drops it rather than keep a key nothing will ever look up.
    public static func normalizedStoredKey(_ key: String, writtenIn source: Calendar = .current) -> String? {
        if isPlausible(key) { return key }
        guard let f = fields(of: key) else { return nil }
        var comps = DateComponents()
        comps.year = f.year; comps.month = f.month; comps.day = f.day
        comps.hour = 12   // clear of any midnight a DST change could skip
        guard let date = source.date(from: comps) else { return nil }
        // The source calendar must read the same fields back, or it rolled an
        // impossible date (month 13, day 31 of a 30-day month) into another one.
        let back = source.dateComponents([.year, .month, .day], from: date)
        guard back.year == f.year, back.month == f.month, back.day == f.day else { return nil }
        let converted = string(from: date, in: source.timeZone)
        return isPlausible(converted) ? converted : nil
    }
}

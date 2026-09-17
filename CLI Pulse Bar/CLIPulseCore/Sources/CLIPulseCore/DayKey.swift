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
/// anywhere else in the app's sources.
public enum DayKey {

    /// A Gregorian calendar with the POSIX locale in `timeZone`. Use it for any
    /// arithmetic whose year, month or day numbers end up in a key or a path.
    public static func calendar(in timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
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
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar(in: timeZone)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Year, month and day of a key, without judging whether they form a
    /// Gregorian date. nil unless the key is `dddd-dd-dd`.
    static func fields(of key: String) -> (year: Int, month: Int, day: Int)? {
        let utf8 = Array(key.utf8)
        guard utf8.count == 10, utf8[4] == 45, utf8[7] == 45 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in utf8[range] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let y = number(0..<4), let m = number(5..<7), let d = number(8..<10) else { return nil }
        return (y, m, d)
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

    /// Whether `key` names a real Gregorian date this app could have recorded:
    /// no earlier than `earliestPlausibleYear`, no later than next year.
    ///
    /// Calendars other than Gregorian are years away in both directions — on
    /// 2026-09-17 Japanese 8, ROC 115, Islamic 1448, Persian 1405, Ethiopic
    /// 2019, Buddhist 2569, Hebrew 5787 — so a key outside that window was
    /// written in one of them (`DayKeyTests` checks every calendar Foundation
    /// offers). The upper bound is a year rather than days so a wrong device
    /// clock never gets real history thrown away.
    public static func isPlausible(_ key: String, now: Date = Date()) -> Bool {
        guard let f = fields(of: key) else { return false }
        let thisYear = calendar(in: TimeZone(secondsFromGMT: 0)!).component(.year, from: now)
        guard f.year >= earliestPlausibleYear, f.year <= thisYear + 1 else { return false }
        return date(from: key, hour: 12, in: TimeZone(secondsFromGMT: 0)!) != nil
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
    public static func normalizedStoredKey(_ key: String,
                                           writtenIn source: Calendar = .current,
                                           now: Date = Date()) -> String? {
        if isPlausible(key, now: now) { return key }
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
        return isPlausible(converted, now: now) ? converted : nil
    }
}

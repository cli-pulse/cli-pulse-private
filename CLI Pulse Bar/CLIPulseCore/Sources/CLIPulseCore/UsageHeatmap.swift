// UsageHeatmap.swift — the reusable GitHub-style usage-activity heatmap.
//
// v1.41 (2026-07-09): extracted verbatim from the macOS-only UsageDashboardView
// so the iOS Overview can render the same year heatmap. The grid + palette have
// ZERO AppKit dependency — they were macOS-only purely by the enclosing
// `#if os(macOS)`, so they live here (un-gated) and both the macOS dashboard
// and the iOS heatmap card consume them. The intensity/column math is already
// cross-platform (DailyUsageStats), as is the archive (DailyUsageArchive).

import SwiftUI

// MARK: - Heatmap blue ramp (token-monitor palette)

public enum UsageHeatmapPalette {
    /// 0…4 intensity → the token-monitor blue ramp (lvl0 faint → lvl4 solid).
    public static func color(_ level: Int) -> Color {
        switch level {
        case 4: return Color(.sRGB, red: 180 / 255, green: 230 / 255, blue: 255 / 255, opacity: 1.0)
        case 3: return Color(.sRGB, red: 150 / 255, green: 210 / 255, blue: 255 / 255, opacity: 0.8)
        case 2: return Color(.sRGB, red: 120 / 255, green: 190 / 255, blue: 255 / 255, opacity: 0.45)
        case 1: return Color(.sRGB, red: 90 / 255, green: 170 / 255, blue: 255 / 255, opacity: 0.18)
        default: return Color.white.opacity(0.05)
        }
    }
}

// MARK: - Reusable heatmap grid

public struct UsageHeatmapGrid: View {
    let archive: DailyUsageArchive
    let weeks: Int
    var cell: CGFloat = 13
    var gap: CGFloat = 4
    var showMonthLabels: Bool = true
    /// The macOS roots set this from `LocaleOverrideStore.displayLocale`; on
    /// iPhone it is the system locale.
    @Environment(\.locale) private var locale

    public init(archive: DailyUsageArchive, weeks: Int, cell: CGFloat = 13, gap: CGFloat = 4,
                showMonthLabels: Bool = true) {
        self.archive = archive; self.weeks = weeks; self.cell = cell; self.gap = gap
        self.showMonthLabels = showMonthLabels
    }

    private static let monthFmt: DateFormatter = DayKey.formatter(in: DayKey.utc)
    private static let monthCalendar: Calendar = DayKey.calendar(in: DayKey.utc)

    public var body: some View {
        let today = DailyUsageStats.localDayKey()
        let peak = DailyUsageStats.peakDayCost(archive)
        let columns = DailyUsageStats.heatmapColumns(todayKey: today, weeks: weeks)
        VStack(alignment: .leading, spacing: gap) {
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: gap) {
                        ForEach(week, id: \.self) { dayKey in
                            cellView(dayKey, today: today, peak: peak)
                        }
                    }
                }
            }
            if showMonthLabels { monthLabels(columns) }
        }
    }

    @ViewBuilder
    private func cellView(_ dayKey: String, today: String, peak: Double) -> some View {
        let isFuture = dayKey > today
        let level = isFuture ? 0 : DailyUsageStats.intensity(archive, dayKey: dayKey, peakCost: peak)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(isFuture ? Color.clear : UsageHeatmapPalette.color(level))
            .frame(width: cell, height: cell)
            .help(tooltip(dayKey, isFuture: isFuture))
    }

    private func tooltip(_ dayKey: String, isFuture: Bool) -> String {
        Self.tooltip(dayKey, day: isFuture ? nil : archive.days[dayKey], locale: locale)
    }

    /// The hover text of one cell. It showed the raw key and an English
    /// "tokens" in every language ("2026-09-17: 1.2K tokens · $0.40"); the date
    /// and the sentence now follow the reader, and the key stays a key.
    static func tooltip(_ dayKey: String, day: DayRollup?, locale: Locale) -> String {
        let date = DisplayFormat.day(dayKey, locale: locale) ?? dayKey
        guard let day, day.tokens > 0 || day.messages > 0 else { return date }
        return L10n.usageDashboard.dayTooltip(date, TokenFormatter.format(day.tokens, locale: locale),
                                              CurrencyConverter.shared.format(day.cost, locale: locale))
    }

    @ViewBuilder
    private func monthLabels(_ columns: [[String]]) -> some View {
        let names = Self.shortMonthNames(locale: locale)
        HStack(spacing: gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { idx, _ in
                let label = monthLabel(forColumn: idx, columns: columns, names: names)
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: cell + gap, alignment: .leading)
                    .fixedSize()
            }
        }
    }

    /// Show a short month name on the first column whose Sunday falls in a new month.
    private func monthLabel(forColumn idx: Int, columns: [[String]], names: [String]) -> String {
        guard let month = monthComponent(columns[idx].first) else { return "" }
        if idx == 0 {
            return Self.name(ofMonth: month, in: names)
        }
        guard let prev = monthComponent(columns[idx - 1].first) else { return Self.name(ofMonth: month, in: names) }
        return month != prev ? Self.name(ofMonth: month, in: names) : ""
    }

    private func monthComponent(_ dayKey: String?) -> Int? {
        guard let dayKey, let date = Self.monthFmt.date(from: dayKey) else { return nil }
        return Self.monthCalendar.component(.month, from: date)
    }

    /// Short month names for Gregorian months 1-12, in `locale`'s language.
    ///
    /// The view passes its environment locale, which the macOS roots set from
    /// `LocaleOverrideStore.displayLocale` and which is the system locale on
    /// iPhone. A bare `DateFormatter()` used the system language, which put
    /// "Jan Feb Mar" under Chinese headings when the app was switched to 简体中文
    /// on an English Mac.
    ///
    /// The month numbers come from day keys, which are Gregorian, so the names
    /// must be too. A `DateFormatter` left to its locale uses the locale's
    /// calendar: under Persian (fa_IR's default) its ninth short name is Azar,
    /// under islamic-umalqura (ar_SA's) Ramadan, and September's column was
    /// labelled with them. Only the calendar is pinned, after `locale` (setting
    /// the locale resets it); the language is still the locale's.
    static func shortMonthNames(locale: Locale) -> [String] {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = Calendar(identifier: .gregorian)
        return f.shortStandaloneMonthSymbols ?? []
    }

    static func name(ofMonth month: Int, in names: [String]) -> String {
        guard month >= 1, month <= names.count else { return "" }
        return names[month - 1]
    }
}

// MARK: - Shared heatmap legend (Less ▁▂▃▄▅ More)

/// The 5-swatch intensity legend, extracted so iOS reuses it verbatim.
public struct UsageHeatmapLegend: View {
    var swatch: CGFloat = 11
    public init(swatch: CGFloat = 11) { self.swatch = swatch }
    public var body: some View {
        HStack(spacing: 4) {
            Text(L10n.usageDashboard.less).font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(UsageHeatmapPalette.color(level))
                    .frame(width: swatch, height: swatch)
            }
            Text(L10n.usageDashboard.more).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

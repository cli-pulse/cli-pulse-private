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

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

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
        let symbols = Self.shortMonthSymbols(locale: locale)
        HStack(spacing: gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { idx, _ in
                let label = monthLabel(forColumn: idx, columns: columns, symbols: symbols)
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: cell + gap, alignment: .leading)
                    .fixedSize()
            }
        }
    }

    /// Show a short month name on the first column whose Sunday falls in a new month.
    private func monthLabel(forColumn idx: Int, columns: [[String]], symbols: [String]) -> String {
        guard let month = monthComponent(columns[idx].first) else { return "" }
        if idx == 0 {
            return Self.shortMonth(month, symbols: symbols)
        }
        guard let prev = monthComponent(columns[idx - 1].first) else { return Self.shortMonth(month, symbols: symbols) }
        return month != prev ? Self.shortMonth(month, symbols: symbols) : ""
    }

    private func monthComponent(_ dayKey: String?) -> Int? {
        guard let dayKey, let date = Self.monthFmt.date(from: dayKey) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.component(.month, from: date)
    }

    /// Month names in `locale`. A bare `DateFormatter()` uses the system
    /// language, which put "Jan Feb Mar" under Chinese headings when the app
    /// was switched to 简体中文 on an English Mac.
    static func shortMonthSymbols(locale: Locale) -> [String] {
        let f = DateFormatter()
        f.locale = locale
        // After `locale`, which resets the calendar: `monthComponent` counts
        // Gregorian months, so the names must be Gregorian too.
        f.calendar = Calendar(identifier: .gregorian)
        return f.shortMonthSymbols ?? []
    }

    static func shortMonth(_ month: Int, symbols: [String]) -> String {
        guard month >= 1, month <= symbols.count else { return "" }
        return symbols[month - 1]
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

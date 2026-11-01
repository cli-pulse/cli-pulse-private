import Foundation

/// 1.61 (P3): the length of Copilot's monthly quota windows.
///
/// Copilot's Premium and chat quotas reset on a calendar month, and the API
/// gives only the reset date (`quota_reset_date`, often a bare `yyyy-MM-dd`).
/// The window is the calendar month that ends at the reset, in UTC (upstream
/// CodexBar #4847), so the pace text and the bar's pace marker work
/// (`UsagePaceText`, `QuotaBarMarkers`). Not gated to macOS: the collector
/// writes it there, and every platform reads it back for the pace.
public enum CopilotQuotaWindow {
    /// The calendar month ending at `reset`, in minutes; nil if it cannot be
    /// computed. A window that cannot be derived gets no pace (#708).
    public static func minutes(endingAt reset: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = calendar.date(byAdding: .month, value: -1, to: reset) else { return nil }
        let minutes = Int((reset.timeIntervalSince(start) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    /// The reset, from an ISO 8601 timestamp or a bare date (midnight UTC).
    public static func parseResetDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let date = sharedISO8601Parse(raw) { return date }
        return DayKey.date(from: raw, in: TimeZone(secondsFromGMT: 0)!)
    }
}

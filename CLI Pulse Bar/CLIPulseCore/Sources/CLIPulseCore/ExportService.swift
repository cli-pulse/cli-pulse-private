import Foundation

/// Generates CSV export files from CLI Pulse data.
/// Used by iOS, macOS, and watchOS for data export.
public enum ExportService {

    // MARK: - Sessions CSV

    /// Export sessions to a CSV file. Returns the temporary file URL.
    public static func exportSessionsCSV(sessions: [SessionRecord]) -> URL? {
        var csv = "ID,Name,Provider,Project,Status,Usage,Cost,Requests,Errors,Started,Last Active\n"
        for s in sessions {
            csv += "\(esc(s.id)),\(esc(s.name)),\(esc(s.provider)),\(esc(s.project)),"
            csv += "\(esc(s.status)),\(s.total_usage),\(s.estimated_cost),"
            csv += "\(s.requests),\(s.error_count),\(esc(s.started_at)),\(esc(s.last_active_at))\n"
        }
        return writeTemp(csv, name: "cli-pulse-sessions.csv")
    }

    // MARK: - Provider Summary CSV

    /// Export provider usage summary to a CSV file.
    public static func exportProviderSummaryCSV(providers: [ProviderUsage]) -> URL? {
        var csv = "Provider,Today Usage,Week Usage,Est. Cost (Week),Remaining,Quota,Plan Type,Reset Time\n"
        for p in providers {
            csv += "\(esc(p.provider)),\(p.today_usage),\(p.week_usage),"
            csv += "\(p.estimated_cost_week),"
            csv += "\(p.remaining.map(String.init) ?? "N/A"),"
            csv += "\(p.quota.map(String.init) ?? "N/A"),"
            csv += "\(esc(p.plan_type ?? "")),\(esc(p.reset_time ?? ""))\n"
        }
        return writeTemp(csv, name: "cli-pulse-providers.csv")
    }

    // MARK: - Alerts CSV

    /// Export alerts to a CSV file.
    public static func exportAlertsCSV(alerts: [AlertRecord]) -> URL? {
        var csv = "ID,Type,Severity,Title,Message,Provider,Project,Created,Read,Resolved\n"
        for a in alerts {
            csv += "\(esc(a.id)),\(esc(a.type)),\(esc(a.severity)),\(esc(a.title)),"
            csv += "\(esc(a.message)),\(esc(a.related_provider ?? "")),"
            csv += "\(esc(a.related_project_name ?? "")),\(esc(a.created_at)),"
            csv += "\(a.is_read),\(a.is_resolved)\n"
        }
        return writeTemp(csv, name: "cli-pulse-alerts.csv")
    }

    // MARK: - Cost Report CSV

    /// Export a combined cost report with dashboard + provider breakdown.
    public static func exportCostReportCSV(
        dashboard: DashboardSummary?,
        providers: [ProviderUsage],
        sessions: [SessionRecord]
    ) -> URL? {
        writeTemp(costReportCSV(dashboard: dashboard, providers: providers, sessions: sessions),
                  name: "cli-pulse-cost-report.csv")
    }

    /// The two kinds of CSV in this file are localized differently, on purpose.
    ///
    /// The sessions / providers / alerts exports above are DATA files: their
    /// header rows are column identifiers that a script, an import or a pivot
    /// table keys on, so they stay English in every language.
    ///
    /// This cost report is a DOCUMENT: the CSV twin of the PDF report, offered
    /// beside it under the same translated Export menu, and read by a person in
    /// Numbers or Excel. So its title, section headings, row labels, column
    /// headers and "N/A" are translated, from the keys the PDF already uses
    /// (plus a title and a "Generated" label of its own; the PDF's versions are
    /// "Monthly Report" and a single "Generated: %@" string).
    /// Only the words are: every value cell stays raw — numbers unformatted so
    /// a spreadsheet can still sum them, the timestamp ISO 8601, and session
    /// status as the server sends it (the PDF keeps it raw too), so a filter on
    /// it does not depend on the language the file was exported in.
    ///
    /// It starts with a UTF-8 byte-order mark. Excel opens a CSV without one in
    /// the system's legacy code page, which would turn every translated heading
    /// into mojibake for exactly the ja/zh/ko readers this is for; Numbers and
    /// other readers skip the mark.
    static func costReportCSV(
        dashboard: DashboardSummary?,
        providers: [ProviderUsage],
        sessions: [SessionRecord],
        generatedAt: Date = Date()
    ) -> String {
        func row(_ cells: [String]) -> String {
            cells.joined(separator: ",") + "\n"
        }
        let na = esc(L10n.pdf.na)

        var csv = "\u{FEFF}" + row([esc(L10n.dashboard.costReportTitle)])
        // Label and timestamp in two cells, as the English report always had
        // them, so the timestamp stays a value a spreadsheet can read on its own.
        csv += row([esc(L10n.dashboard.costReportGenerated), sharedISO8601Formatter.string(from: generatedAt)]) + "\n"

        if let d = dashboard {
            csv += row([esc(L10n.pdf.summary)])
            csv += row([esc(L10n.pdf.todayUsage), "\(d.total_usage_today)"])
            csv += row([esc(L10n.pdf.todayEstimatedCost), "$\(d.total_estimated_cost_today)"])
            csv += row([esc(L10n.pdf.activeSessions), "\(d.active_sessions)"])
            csv += row([esc(L10n.pdf.onlineDevices), "\(d.online_devices)"])
            csv += row([esc(L10n.pdf.unresolvedAlerts), "\(d.unresolved_alerts)"]) + "\n"
        }

        csv += row([esc(L10n.pdf.providerBreakdown)])
        csv += row([L10n.pdf.hProvider, L10n.pdf.hWeekUsage, L10n.pdf.hEstCost,
                    L10n.pdf.hRemaining, L10n.pdf.hQuota].map(esc))
        for p in providers {
            csv += row([esc(p.provider), "\(p.week_usage)", "\(p.estimated_cost_week)",
                        p.remaining.map(String.init) ?? na, p.quota.map(String.init) ?? na])
        }

        csv += "\n" + row([esc(L10n.pdf.topSessions)])
        csv += row([L10n.pdf.hProvider, L10n.pdf.hProject, L10n.pdf.hCost,
                    L10n.pdf.hUsage, L10n.pdf.hStatus].map(esc))
        let topSessions = sessions.sorted { $0.estimated_cost > $1.estimated_cost }.prefix(20)
        for s in topSessions {
            csv += row([esc(s.provider), esc(s.project), "\(s.estimated_cost)", "\(s.total_usage)", esc(s.status)])
        }
        return csv
    }

    // MARK: - PDF Report

    #if canImport(PDFKit) && !os(watchOS)
    /// Export a monthly PDF report. Returns the saved file URL.
    ///
    /// iter23: `destinationURL` lets a caller (e.g. the macOS
    /// `OverviewTab` Export menu) hand the user-selected URL from
    /// `NSSavePanel` straight through to the generator — the panel's
    /// security-scoped URL is what makes Downloads writes work
    /// inside the App Store sandbox. When `nil`, the generator
    /// resolves a Downloads-or-temp default.
    public static func exportPDFReport(
        dashboard: DashboardSummary?,
        providers: [ProviderUsage],
        sessions: [SessionRecord],
        dailyUsage: [DailyUsage],
        costForecast: CostForecast?,
        destinationURL: URL? = nil
    ) -> URL? {
        PDFReportGenerator.generateReport(
            dashboard: dashboard,
            providers: providers,
            sessions: sessions,
            dailyUsage: dailyUsage,
            costForecast: costForecast,
            destinationURL: destinationURL
        )
    }
    #endif

    // MARK: - Helpers

    private static func esc(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func writeTemp(_ content: String, name: String) -> URL? {
        // v1.10.6: prefix with a UUID so parallel callers (especially
        // `swift test --parallel`) don't clobber each other's output when
        // two tests both hit e.g. exportProviderSummaryCSV — race between
        // atomic writes silently produced stale reads and crashed consumers
        // that assumed their own data was on disk.
        let unique = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(unique)-\(name)")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

import Foundation

/// Localized rendering for an alert row, derived from the English an alert
/// generator already produced.
///
/// WHY THIS PARSES ENGLISH INSTEAD OF READING STRUCTURED FIELDS
/// `public.alerts` has no `kind` or `params` column, and every device receives
/// the PRODUCING device's `title`/`message` bytes unchanged. Adding columns is
/// a backend migration; recovering the parameters from the template is not. So
/// the stored row stays byte-identical English — it is also the alert's
/// `suppression_key` neighbourhood, the webhook payload, and what the Watch
/// relay carries — and only the rendering is translated.
///
/// THREE PRODUCERS, NOT ONE
/// The same alert kind is written by three codebases with different wording:
/// the in-app Swift generator (`AlertGenerator`), the Python helper
/// (`helper/system_collector.py`) and the Tauri desktop app
/// (`src-tauri/src/alerts.rs`, a separate repository). A user with a Mac and a
/// Windows desktop sees rows from both in one list. Every template below names
/// the producer it came from.
///
/// ANY MISS RENDERS THE RAW ENGLISH
/// Retired kinds, rows from a newer client, and any template edit fall
/// through to the stored text unchanged. That is a visible, honest
/// degradation rather than a wrong translation — and
/// `AlertPresentationRoundTripTests` runs the REAL generator output through
/// this type so a template edit fails CI instead of silently reverting a
/// locale to English. Demo mode's rows are real producer templates too, and
/// `DemoDataLocalizationTests` holds them to that.
public enum AlertPresentation {

    public struct Text: Equatable, Sendable {
        public let title: String
        public let message: String
        /// False when nothing matched and the stored English is being shown.
        /// Tests assert on this; the UI does not care.
        public let recognized: Bool
    }

    public static func text(for alert: AlertRecord) -> Text {
        if let t = deviceCPU(alert) ?? sessionCPU(alert) ?? sessionLong(alert)
            ?? quota(alert) ?? budget(alert) {
            return t
        }
        return Text(title: alert.title, message: alert.message, recognized: false)
    }

    // MARK: - Kinds

    /// Swift `AlertGenerator` and the Python helper emit an identical template.
    private static func deviceCPU(_ a: AlertRecord) -> Text? {
        guard a.type == "Usage Spike", a.id.hasPrefix("cpu-spike-"),
              a.title == "Device CPU usage is elevated",
              let pct = capture(a.message, #"^helper sampled CPU usage at (\d+(?:\.\d+)?)%\.$"#)?.first
        else { return nil }
        return Text(title: L10n.alertKind.deviceCPUTitle,
                    message: L10n.alertKind.deviceCPUMessage(pct),
                    recognized: true)
    }

    private static func sessionCPU(_ a: AlertRecord) -> Text? {
        guard a.type == "Usage Spike", a.id.hasPrefix("session-spike-") else { return nil }
        let name = stripSuffix(a.title, " is consuming high CPU")

        // Swift AlertGenerator: normalized against total system capacity.
        if let m = capture(a.message, #"^Using ~(\d+)% of total system CPU \((\d+) cores\) for (.+)\.$"#) {
            return Text(title: L10n.alertKind.sessionCPUTitle(name),
                        message: L10n.alertKind.sessionCPUMessageSystem(m[0], m[1], m[2]),
                        recognized: true)
        }
        // Tauri desktop: raw process CPU, WITH a trailing project. Must be
        // tried before the Python form below, whose greedy `(.+)` would
        // otherwise swallow " in <project>" into the provider.
        if let m = capture(a.message, #"^Process CPU is (\d+(?:\.\d+)?)% for (.+) in (.+)\.$"#) {
            return Text(title: L10n.alertKind.sessionCPUTitle(name),
                        message: L10n.alertKind.sessionCPUMessageProcessInProject(m[0], m[1], m[2]),
                        recognized: true)
        }
        // Python helper: raw process CPU, no project.
        if let m = capture(a.message, #"^Process CPU is (\d+(?:\.\d+)?)% for (.+)\.$"#) {
            return Text(title: L10n.alertKind.sessionCPUTitle(name),
                        message: L10n.alertKind.sessionCPUMessageProcess(m[0], m[1]),
                        recognized: true)
        }
        return nil
    }

    private static func sessionLong(_ a: AlertRecord) -> Text? {
        guard a.type == "Session Too Long", a.id.hasPrefix("session-long-"),
              a.message == "Long-running local agent session detected by helper."
        else { return nil }
        return Text(title: L10n.alertKind.sessionLongTitle(stripSuffix(a.title, " has been running for a long time")),
                    message: L10n.alertKind.sessionLongMessage,
                    recognized: true)
    }

    /// Quota alerts are generated locally only, so the whole record is present.
    /// The tier name goes through the same display mapper the provider cards
    /// use, so one window reads the same wherever it appears.
    private static func quota(_ a: AlertRecord) -> Text? {
        guard a.type == "Quota Warning", a.id.hasPrefix("quota-"),
              let m = capture(a.message,
                              #"^Quota window '(.+)' is (\d+)% used \((\d+)% remaining\)(?: \(resets (.+)\))?\.$"#)
        else { return nil }
        let tier = L10n.quotaTier.localized(m[0])
        let used = m[1]
        let remaining = m[2]
        let reset = m.count > 3 ? m[3] : ""

        // The title is "<provider> <tier> at <used>%". Prefer the stored
        // provider; fall back to removing that exact suffix, which is anchored
        // and so is exact even when a provider name contains a template word.
        let provider = a.related_provider ?? stripSuffix(a.title, " \(m[0]) at \(used)%")
        let message = reset.isEmpty
            ? L10n.alertKind.quotaMessage(tier, used, remaining)
            : L10n.alertKind.quotaMessageReset(tier, used, remaining, displayReset(reset))
        return Text(title: L10n.alertKind.quotaTitle(provider, tier, used),
                    message: message,
                    recognized: true)
    }

    /// Tauri desktop only — the Apple apps never generate these, but they sync
    /// through the cloud and render in the same list. Amounts are carried
    /// through verbatim, including their `$`, rather than being re-formatted:
    /// the desktop already chose a currency rendering and second-guessing it
    /// here would make one row disagree with another.
    private static func budget(_ a: AlertRecord) -> Text? {
        if a.type == "Daily Budget Exceeded", a.id.hasPrefix("budget-daily-"),
           let t = capture(a.title, #"^Daily budget exceeded — \$(.+)$"#),
           let m = capture(a.message, #"^Today's spend of \$(.+) is above your daily budget of \$(.+)\.$"#) {
            return Text(title: L10n.alertKind.budgetDailyTitle(t[0]),
                        message: L10n.alertKind.budgetDailyMessage(m[0], m[1]),
                        recognized: true)
        }
        if a.type == "Weekly Budget Exceeded", a.id.hasPrefix("budget-weekly-"),
           let t = capture(a.title, #"^Weekly budget exceeded — \$(.+)$"#),
           let m = capture(a.message, #"^Last 7 days of spend totals \$(.+), above your weekly budget of \$(.+)\.$"#) {
            return Text(title: L10n.alertKind.budgetWeeklyTitle(t[0]),
                        message: L10n.alertKind.budgetWeeklyMessage(m[0], m[1]),
                        recognized: true)
        }
        return nil
    }

    // MARK: - Labels

    /// Severity as a display word. The raw value stays English everywhere: it
    /// is a filter value, a webhook field, and what `AlertSeverity(rawValue:)`
    /// parses.
    public static func severityLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "critical": return L10n.alertKind.severityCritical
        case "warning": return L10n.alertKind.severityWarning
        case "info": return L10n.alertKind.severityInfo
        default: return raw
        }
    }

    /// `source_kind` as a display word. "swarm" is retired but still present on
    /// historical rows, so it keeps a label.
    public static func sourceKindLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "device": return L10n.alertKind.sourceDevice
        case "session": return L10n.alertKind.sourceSession
        case "quota": return L10n.alertKind.sourceQuota
        case "budget": return L10n.alertKind.sourceBudget
        case "provider": return L10n.alertKind.sourceProvider
        case "project": return L10n.alertKind.sourceProject
        case "swarm": return L10n.alertKind.sourceSwarm
        default: return raw
        }
    }

    // MARK: - Helpers

    /// The stored reset is the collector's `reset_time`, almost always an
    /// ISO-8601 UTC timestamp, which read as "2026-09-16T14:00:00Z" inside every
    /// translated sentence and in UTC rather than the reader's clock. It is
    /// shown as a local date and time, not "in 3h": an alert is often read
    /// after its window has already reset. A value that is not ISO (a vendor's
    /// own wording) stays as it was.
    static func displayReset(_ raw: String) -> String {
        guard let date = sharedISO8601Parse(raw) else { return raw }
        return DisplayFormat.dateTime(date)
    }

    /// Capture groups of an anchored match, or nil. A group that did not
    /// participate is dropped, so an optional trailing group simply shortens
    /// the result.
    private static func capture(_ s: String, _ pattern: String) -> [String]? {
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: s) else { continue }
            out.append(String(s[r]))
        }
        return out
    }

    /// Removes an anchored English suffix. Returns the input unchanged when the
    /// suffix is absent, so a row whose title was written by something else
    /// still shows its own text.
    private static func stripSuffix(_ s: String, _ suffix: String) -> String {
        s.hasSuffix(suffix) ? String(s.dropLast(suffix.count)) : s
    }
}

import Foundation

/// The status lines collectors compose ("5h 60% left · Weekly 40% left",
/// "12/100 used", "$4.20 this month"), written as fixed English data and
/// translated only where they are shown.
///
/// `status_text` is data for the reasons `ClaudeStatusSentinel` gives: collectors
/// run in the Login Item helper as well as the app, the value crosses the App
/// Group and is uploaded for other devices, and `ProviderAccountPresentation`
/// compares it. Localizing it at the producer would make its language whichever
/// process wrote it, not the reader's. So collectors build their line from these
/// builders, and `L10n.providers.localizedStatusText` recognizes the builders'
/// output and re-renders it in the reader's language.
///
/// A line is a list of segments joined by `separator`. Each segment is recognized
/// on its own, so a line that mixes our words with a vendor's — a plan name in
/// front ("Pro · $18.00 of $30.00"), T3 Chat's usage band, Zed's "edit
/// predictions" — translates the part that is ours and keeps the vendor's text
/// verbatim.
///
/// Builders and recognizers sit side by side so they change together.
/// `CollectorStatusTextTests` checks every builder against the English catalogue
/// (English users see exactly what was stored) and under zh-Hans (everyone else
/// sees a translation), and `scripts/check_collector_status_text.py` fails a
/// collector that writes English status copy of its own instead of calling one.
public enum CollectorStatusText {

    public static let separator = " · "

    public static func join(_ segments: [String]) -> String {
        segments.joined(separator: separator)
    }

    // MARK: - Percentages

    /// Quota windows that appear in front of a percentage. The raw values are the
    /// tier names the same collectors give their bars, so a window reads the same
    /// on the bar and in the line under it.
    public enum Window: String, CaseIterable, Sendable {
        case fiveHour = "5h"
        case fourHour = "4-hour"
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
        case rolling = "Rolling"
    }

    public static func percentLeft(_ percent: Int) -> String { "\(percent)% left" }

    public static func windowPercentLeft(_ window: Window, _ percent: Int) -> String {
        "\(window.rawValue) \(percent)% left"
    }

    // MARK: - Counts against a limit

    public static func usedOf(_ used: String, _ limit: String) -> String { "\(used)/\(limit) used" }
    public static func creditsUsedOf(_ used: String, _ limit: String) -> String { "\(used)/\(limit) credits used" }
    public static func tokensOf(_ used: String, _ limit: String) -> String { "\(used)/\(limit) tokens" }
    public static func keysOf(_ active: String, _ total: String) -> String { "\(active)/\(total) keys" }
    public static func charactersOf(_ used: String, _ limit: String) -> String { "\(used) / \(limit) characters" }

    public static func charactersOf(_ used: String, _ limit: String, overage amount: String, currency: String) -> String {
        "\(used) / \(limit) characters (Overage: \(amount) \(currency))"
    }

    public static func creditsLeftOf(_ remaining: String, _ total: String) -> String {
        "\(remaining) / \(total) credits left"
    }

    /// `unit` is the vendor's own name for what it counts, so it stays as written.
    public static func unitsLeftOf(_ remaining: String, _ total: String, unit: String) -> String {
        "\(remaining) / \(total) \(unit) left"
    }

    /// A named pool against its cap, "Refresh: 40/100". `pool` is rendered through
    /// the quota tier mapper, so a generic name translates and a vendor's does not.
    public static func poolCount(_ pool: String, _ current: String, _ max: String) -> String {
        "\(pool): \(current)/\(max)"
    }

    public static func requestsLeft(_ count: Int) -> String {
        count == 1 ? "1 request left" : "\(count) requests left"
    }

    // MARK: - Amounts

    public static func creditsRemaining(_ amount: String) -> String { "\(amount) credits remaining" }
    public static func creditsLeft(_ amount: String) -> String { "\(amount) credits left" }
    public static func credits(_ amount: String) -> String { "\(amount) credits" }
    public static func credit(_ amount: String) -> String { "\(amount) credit" }
    public static func balance(_ amount: String) -> String { "\(amount) balance" }
    public static func balanceOf(_ amount: String) -> String { "Balance: \(amount)" }
    public static func balanceOfCredits(_ amount: String) -> String { "Balance: \(amount) credits" }
    public static func thisMonth(_ amount: String) -> String { "\(amount) this month" }
    public static func remaining(_ amount: String) -> String { "\(amount) remaining" }
    public static func amountOf(_ part: String, _ whole: String) -> String { "\(part) of \(whole)" }
    public static func inDeficit(_ amount: String) -> String { "\(amount) in deficit" }
    public static func uncollected(_ amount: String) -> String { "\(amount) uncollected" }
    public static func today(_ amount: String) -> String { "Today \(amount)" }
    public static func month(_ amount: String) -> String { "Month \(amount)" }

    public static func deepSeekEmptyBalance(_ zero: String) -> String {
        "\(zero) — add credits at platform.deepseek.com"
    }

    public static func deepSeekBalance(total: String, paid: String, granted: String) -> String {
        "\(total) (Paid: \(paid) / Granted: \(granted))"
    }

    // MARK: - Usage volumes

    public static func requests(_ count: String) -> String { "\(count) requests" }
    public static func audioHours(_ hours: String) -> String { "\(hours) audio hrs" }
    public static func billableHours(_ hours: String) -> String { "\(hours) billable hrs" }
    public static func tokens(_ count: String) -> String { "\(count) tokens" }
    public static func ttsCharacters(_ count: String) -> String { "\(count) TTS chars" }
    public static func requestsShort(_ count: String) -> String { "\(count) req" }
    public static func tokensShort(_ count: String) -> String { "\(count) tok" }
    public static func requestsPerMinute(_ rate: String) -> String { "\(rate) req/min" }
    public static func tokensPerMinute(_ rate: String) -> String { "\(rate) tok/min" }
    public static func cachePerMinute(_ rate: String) -> String { "\(rate) cache/min" }

    public static func modelsAvailable(_ count: Int) -> String {
        count == 1 ? "1 model available" : "\(count) models available"
    }

    public static func modelsInstalled(_ count: Int) -> String {
        count == 1 ? "1 model installed" : "\(count) models installed"
    }

    public static func runningInstalled(running: Int, installed: Int) -> String {
        "\(running) running, \(installed) installed"
    }

    // MARK: - Fixed phrases

    public static let unlimited = "Unlimited"
    public static let balanceUnavailable = "Balance unavailable"
    public static let balanceUnavailableForAPICalls = "Balance unavailable for API calls"
    public static let creditsDataUnavailable = "Credits data unavailable"
    public static let noVeniceBalance = "No Venice API balance available"
    public static let autoTopUp = "auto top-up"
    public static let planExpired = "plan expired"
    public static let overdueInvoices = "⚠︎ overdue invoices"

    public static func deployment(_ name: String) -> String { "Deployment: \(name)" }
    public static func model(_ name: String) -> String { "Model: \(name)" }

    // MARK: - Rendering

    /// The line in the reader's language, or nil when no segment is one of ours.
    /// Unrecognized segments are kept verbatim; nil lets the caller keep the raw
    /// line byte-identical.
    static func localized(_ raw: String) -> String? {
        let segments = raw.components(separatedBy: separator)
        var recognized = false
        let rendered = segments.map { segment -> String in
            guard let shown = localizedSegment(segment) else { return segment }
            recognized = true
            return shown
        }
        return recognized ? join(rendered) : nil
    }

    private static func localizedSegment(_ segment: String) -> String? {
        for rule in rules {
            if let captures = capture(segment, rule.regex), let shown = rule.render(captures) {
                return shown
            }
        }
        return nil
    }

    private struct Rule {
        let regex: NSRegularExpression?
        let render: ([String]) -> String?

        /// `pattern` is anchored here, so every rule matches a whole segment and a
        /// segment that merely contains a template is left alone.
        init(_ pattern: String, _ render: @escaping ([String]) -> String?) {
            regex = try? NSRegularExpression(pattern: "^" + pattern + "$")
            self.render = render
        }
    }

    /// First match wins, so a more specific template sits above the general one
    /// it would otherwise be swallowed by ("12/100 credits used" above "12/100 used").
    private static let rules: [Rule] = [
        Rule(#"(\d+)% left"#) { c in Int(c[0]).map(L10n.statusText.percentLeft) },
        Rule(#"(5h|4-hour|Daily|Weekly|Monthly|Rolling) (\d+)% left"#) { c in
            guard let percent = Int(c[1]) else { return nil }
            // "5h" is kept compact in every locale (scripts/quota_tier_names.json).
            let window = c[0] == Window.fiveHour.rawValue ? c[0] : L10n.quotaTier.localized(c[0])
            return L10n.statusText.windowPercentLeft(window, percent)
        },
        Rule(#"(.+)/(.+) credits used"#) { c in L10n.statusText.creditsUsedOf(c[0], c[1]) },
        Rule(#"(.+)/(.+) used"#) { c in L10n.statusText.usedOf(c[0], c[1]) },
        Rule(#"(.+)/(.+) tokens"#) { c in L10n.statusText.tokensOf(c[0], c[1]) },
        Rule(#"(.+)/(.+) keys"#) { c in L10n.statusText.keysOf(c[0], c[1]) },
        Rule(#"(.+) / (.+) characters \(Overage: (.+) (.+)\)"#) { c in
            L10n.statusText.charactersOfWithOverage(c[0], c[1], c[2], c[3])
        },
        Rule(#"(.+) / (.+) characters"#) { c in L10n.statusText.charactersOf(c[0], c[1]) },
        Rule(#"(.+) / (.+) credits left"#) { c in L10n.statusText.creditsLeftOf(c[0], c[1]) },
        Rule(#"(\S+) / (\S+) (\S+) left"#) { c in L10n.statusText.unitsLeftOf(c[0], c[1], c[2]) },
        Rule(#"(\d+) requests? left"#) { c in Int(c[0]).map(L10n.statusText.requestsLeft) },
        Rule(#"(.+) credits remaining"#) { c in L10n.statusText.creditsRemaining(c[0]) },
        Rule(#"(.+) credits left"#) { c in L10n.statusText.creditsLeft(c[0]) },
        Rule(#"Balance: (.+) credits"#) { c in L10n.statusText.balanceOfCredits(c[0]) },
        Rule(#"Balance: (.+)"#) { c in L10n.statusText.balanceOf(c[0]) },
        Rule(#"Balance unavailable for API calls"#) { _ in L10n.statusText.balanceUnavailableForAPICalls },
        Rule(#"Balance unavailable"#) { _ in L10n.statusText.balanceUnavailable },
        Rule(#"(.+) balance"#) { c in L10n.statusText.balance(c[0]) },
        Rule(#"(.+) this month"#) { c in L10n.statusText.thisMonth(c[0]) },
        Rule(#"(.+) remaining"#) { c in L10n.statusText.remaining(c[0]) },
        Rule(#"(.+) credits"#) { c in L10n.statusText.credits(c[0]) },
        Rule(#"(.+) credit"#) { c in L10n.statusText.credit(c[0]) },
        // Amounts only: " of " is common enough in free text that the two sides
        // must at least carry a digit before this counts as ours.
        Rule(#"(\S*\d\S*) of (\S*\d\S*)"#) { c in L10n.statusText.amountOf(c[0], c[1]) },
        Rule(#"(.+) in deficit"#) { c in L10n.statusText.inDeficit(c[0]) },
        Rule(#"(.+) uncollected"#) { c in L10n.statusText.uncollected(c[0]) },
        Rule(#"Today (.+)"#) { c in L10n.statusText.today(c[0]) },
        Rule(#"Month (.+)"#) { c in L10n.statusText.month(c[0]) },
        Rule(#"(.+) — add credits at platform\.deepseek\.com"#) { c in L10n.statusText.deepSeekEmptyBalance(c[0]) },
        Rule(#"(.+) \(Paid: (.+) / Granted: (.+)\)"#) { c in L10n.statusText.deepSeekBalance(c[0], c[1], c[2]) },
        Rule(#"(.+) requests"#) { c in L10n.statusText.requests(c[0]) },
        Rule(#"(.+) audio hrs"#) { c in L10n.statusText.audioHours(c[0]) },
        Rule(#"(.+) billable hrs"#) { c in L10n.statusText.billableHours(c[0]) },
        Rule(#"(.+) tokens"#) { c in L10n.statusText.tokens(c[0]) },
        Rule(#"(.+) TTS chars"#) { c in L10n.statusText.ttsCharacters(c[0]) },
        Rule(#"(.+) req"#) { c in L10n.statusText.requestsShort(c[0]) },
        Rule(#"(.+) tok"#) { c in L10n.statusText.tokensShort(c[0]) },
        Rule(#"(.+) req/min"#) { c in L10n.statusText.requestsPerMinute(c[0]) },
        Rule(#"(.+) tok/min"#) { c in L10n.statusText.tokensPerMinute(c[0]) },
        Rule(#"(.+) cache/min"#) { c in L10n.statusText.cachePerMinute(c[0]) },
        Rule(#"(\d+) models? available"#) { c in Int(c[0]).map(L10n.statusText.modelsAvailable) },
        Rule(#"(\d+) models? installed"#) { c in Int(c[0]).map(L10n.statusText.modelsInstalled) },
        Rule(#"(\d+) running, (\d+) installed"#) { c in
            guard let running = Int(c[0]), let installed = Int(c[1]) else { return nil }
            return L10n.statusText.runningInstalled(running, installed)
        },
        Rule(#"Unlimited"#) { _ in L10n.statusText.unlimited },
        Rule(#"Credits data unavailable"#) { _ in L10n.statusText.creditsDataUnavailable },
        Rule(#"No Venice API balance available"#) { _ in L10n.statusText.noVeniceBalance },
        Rule(#"auto top-up"#) { _ in L10n.statusText.autoTopUp },
        Rule(#"plan expired"#) { _ in L10n.statusText.planExpired },
        Rule(#"⚠︎ overdue invoices"#) { _ in L10n.statusText.overdueInvoices },
        Rule(#"Deployment: (.+)"#) { c in L10n.statusText.deployment(c[0]) },
        Rule(#"Model: (.+)"#) { c in L10n.statusText.model(c[0]) },
        Rule(#"([A-Z][a-z]+): (\S+)/(\S+)"#) { c in
            L10n.statusText.poolCount(L10n.quotaTier.localized(c[0]), c[1], c[2])
        },
    ]

    private static func capture(_ s: String, _ regex: NSRegularExpression?) -> [String]? {
        guard let regex,
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            out.append(String(s[r]))
        }
        return out
    }
}

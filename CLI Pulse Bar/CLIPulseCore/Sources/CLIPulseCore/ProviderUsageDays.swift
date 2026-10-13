import Foundation

// v1.57 (P1-2): one provider's last 30 days, day by day and model by model,
// for the panel that slides out of the Mac popover and for the chart on the
// iPhone's provider card.
//
// The panel used to be built from the usage archive alone, which keeps one
// figure per day and provider and a per-model split that mixes providers, so
// it could not say which of a day's models were Codex's. The local scan keeps
// every row as (day, provider, model), and so does the cloud's
// `get_daily_usage`; this shapes either into the same days.
//
// Pure Foundation and cross-platform: the views only render it.

/// Which number a usage chart plots. The slide-out panel remembers the last
/// choice under `defaultsKey`, in both of its modes.
public enum UsageChartMetric: String, CaseIterable, Sendable, Identifiable {
    case tokens
    case cost

    public var id: String { rawValue }

    /// Where the panel keeps the last choice. A chart elsewhere that should
    /// follow the panel (the provider card's) reads the same key.
    public static let defaultsKey = "cli_pulse_usage_chart_metric"

    /// The stored choice, tokens when there is none or it is unreadable.
    public static func stored(_ raw: String?) -> UsageChartMetric {
        raw.flatMap(UsageChartMetric.init(rawValue:)) ?? .tokens
    }

    public var label: String {
        switch self {
        case .tokens: return L10n.providerPanel.metricTokens
        case .cost: return L10n.providerPanel.metricCost
        }
    }

    /// A value on a chart's y axis whose highest value is `top`. Costs are
    /// whole units ("$33") once the axis reaches 10 of them, and keep the
    /// currency's cents below that, where whole units would label every
    /// line "$0".
    public func axisText(_ value: Double, top: Double) -> String {
        switch self {
        case .tokens:
            return CostFormatter.formatUsage(Int(value.rounded()))
        case .cost:
            let converter = CurrencyConverter.shared
            return converter.convert(top, to: converter.currentCurrency()) >= 10
                ? converter.formatWholeUnits(value)
                : converter.format(value)
        }
    }
}

/// Whose usage a figure counts: this Mac's own logs, or what every device
/// synced to the account.
public enum UsageDataScope: String, CaseIterable, Sendable, Identifiable {
    case thisMac
    case allDevices

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .thisMac: return L10n.providerPanel.scopeThisMac
        case .allDevices: return L10n.providerPanel.scopeAllDevices
        }
    }
}

public struct ProviderUsageDays: Sendable, Equatable {

    /// How a row's tokens are added up. Every view that shows these says
    /// which one it uses.
    public enum TokenBasis: Sendable, Equatable {
        /// Every token once: input not served from cache, cached input and
        /// output (`ArchiveTokenBasis`), as the Usage Dashboard counts. Claude's
        /// cache reads and writes are in it; Codex's cached input is counted
        /// once, not added to an input that already includes it.
        case eachOnce
        /// Input + output, the "I/O" the provider cards show. Codex's input
        /// includes its cached input (OpenAI's convention); Claude's leaves
        /// cache out.
        case inputOutput
    }

    /// One model's share of one day.
    public struct ModelRow: Sendable, Equatable, Identifiable {
        public let model: String
        public let tokens: Int
        /// The cost of the tokens that had a rate. A model with no rate at all
        /// has 0 here and `unpricedTokens == tokens`.
        public let cost: Double
        /// Tokens that had no rate, so they added nothing to `cost`.
        public let unpricedTokens: Int
        /// Part of `cost` was charged at a rate borrowed from a neighbouring
        /// model (`CostUsageScanResult.DailyEntry.priceIsApproximate`).
        public let isApproximate: Bool

        public var id: String { model }
        /// Some of its tokens had no rate: its cost is a lower bound.
        public var isPartlyUnpriced: Bool { unpricedTokens > 0 }
        /// None of its tokens had a rate: it has no cost to show at all.
        public var hasNoRate: Bool { unpricedTokens > 0 && unpricedTokens >= tokens && cost == 0 }

        public init(model: String, tokens: Int, cost: Double, unpricedTokens: Int = 0, isApproximate: Bool = false) {
            self.model = model
            self.tokens = tokens
            self.cost = cost
            self.unpricedTokens = unpricedTokens
            self.isApproximate = isApproximate
        }
    }

    /// One calendar day. Its totals are the sums of its model rows, so the
    /// rows a day lists always add up to the figure shown for the day.
    public struct Day: Sendable, Equatable, Identifiable {
        public let dateKey: String
        /// Most expensive first, then most tokens, then by name.
        public let models: [ModelRow]
        public let tokens: Int
        public let cost: Double

        public var id: String { dateKey }

        public init(dateKey: String, models: [ModelRow]) {
            self.dateKey = dateKey
            self.models = ProviderUsageDays.ordered(models)
            // Summed over the rows as they are listed, so a day's figure is
            // exactly the sum of what it lists.
            self.tokens = self.models.reduce(0) { $0 + $1.tokens }
            self.cost = self.models.reduce(0) { $0 + $1.cost }
        }

        public var hasUsage: Bool { tokens > 0 || cost > 0 }
        /// Some of the day's tokens had no rate: its cost is a lower bound.
        public var hasUnpriced: Bool { models.contains { $0.isPartlyUnpriced } }
        public var isApproximate: Bool { models.contains { $0.isApproximate } }

        public func value(_ metric: UsageChartMetric) -> Double {
            switch metric {
            case .tokens: return Double(tokens)
            case .cost: return cost
            }
        }
    }

    public let provider: String
    public let scope: UsageDataScope
    public let basis: TokenBasis
    /// Contiguous, oldest first, ending today. A day with no usage is there
    /// with no rows, so the chart keeps one slot per day.
    public let days: [Day]
    /// What share of the tokens had a rate. Known only for this Mac's logs;
    /// `CostCoverage.unknown` for synced rows.
    public let coverage: CostCoverage
    public let totalTokens: Int
    public let totalCost: Double

    public init(provider: String, scope: UsageDataScope, basis: TokenBasis, days: [Day], coverage: CostCoverage) {
        self.provider = provider
        self.scope = scope
        self.basis = basis
        self.days = days
        self.coverage = coverage
        self.totalTokens = days.reduce(0) { $0 + $1.tokens }
        self.totalCost = days.reduce(0) { $0 + $1.cost }
    }

    public var hasUsage: Bool { days.contains { $0.hasUsage } }
    /// Some tokens in the window had no rate: the total cost is a lower bound.
    public var hasUnpriced: Bool { days.contains { $0.hasUnpriced } }
    public var isApproximate: Bool { days.contains { $0.isApproximate } }

    public func day(_ dateKey: String?) -> Day? {
        guard let dateKey else { return nil }
        return days.first { $0.dateKey == dateKey }
    }

    /// The day selected when nothing is: the latest day with usage.
    public var latestActiveDayKey: String? {
        days.last { $0.hasUsage }?.dateKey
    }

    /// The model that cost the most over the window (tokens, then name,
    /// break a tie). nil unless every token had a rate and the coverage is
    /// known: with an unpriced model, or with synced rows whose pricing this
    /// device cannot see, the ranking could be wrong, so none is claimed.
    public var topModelByCost: String? {
        guard coverage.basis == .localScan, coverage.isFullyPriced, !hasUnpriced else { return nil }
        var cost: [String: Double] = [:]
        var tokens: [String: Int] = [:]
        for day in days {
            for row in day.models {
                cost[row.model, default: 0] += row.cost
                tokens[row.model, default: 0] += row.tokens
            }
        }
        let ranked = cost.keys.sorted { lhs, rhs in
            let (lc, rc) = (cost[lhs] ?? 0, cost[rhs] ?? 0)
            if lc != rc { return lc > rc }
            let (lt, rt) = (tokens[lhs] ?? 0, tokens[rhs] ?? 0)
            if lt != rt { return lt > rt }
            return lhs < rhs
        }
        guard let top = ranked.first, (cost[top] ?? 0) > 0 else { return nil }
        return top
    }

    /// Most expensive first, then most tokens, then by name, so the order is
    /// the same on every run.
    static func ordered(_ rows: [ModelRow]) -> [ModelRow] {
        rows.sorted { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            return lhs.model < rhs.model
        }
    }

    // MARK: - Building

    /// One provider's days from this Mac's scan (`CostUsageScanResult.entries`):
    /// the `days` calendar days ending at `todayKey`, inclusive.
    public static func fromScan(
        _ entries: [CostUsageScanResult.DailyEntry],
        provider: String,
        basis: TokenBasis = .eachOnce,
        days count: Int = 30,
        todayKey: String,
        timeZone: TimeZone = .current) -> ProviderUsageDays
    {
        let keys = dayKeys(count: count, endingAt: todayKey, timeZone: timeZone)
        let window = Set(keys)
        let rows = entries.filter {
            $0.provider == provider && window.contains($0.date) && $0.model != ScanEntry.messageBucketModel
        }
        var byDay: [String: [String: Acc]] = [:]
        for e in rows {
            let tokens = Self.tokens(of: e, basis: basis)
            var acc = byDay[e.date, default: [:]][e.model] ?? Acc()
            acc.tokens += tokens
            if let cost = e.costUSD {
                acc.cost += max(0, cost)
                if e.priceIsApproximate { acc.approximate = true }
            } else {
                acc.unpriced += tokens
            }
            byDay[e.date, default: [:]][e.model] = acc
        }
        return ProviderUsageDays(
            provider: provider, scope: .thisMac, basis: basis,
            days: keys.map { day($0, byDay[$0]) },
            coverage: CostCoverage.from(entries: rows))
    }

    /// One provider's days from the rows synced to the account
    /// (`get_daily_usage`, day × model across every device).
    ///
    /// Each row's cost is taken as it was uploaded: which of it had a rate is
    /// not in the row, so nothing is marked unpriced and the coverage is
    /// unknown.
    public static func fromCloud(
        _ rows: [DailyUsage],
        provider: String,
        basis: TokenBasis = .eachOnce,
        days count: Int = 30,
        todayKey: String,
        timeZone: TimeZone = .current) -> ProviderUsageDays
    {
        let keys = dayKeys(count: count, endingAt: todayKey, timeZone: timeZone)
        let window = Set(keys)
        var byDay: [String: [String: Acc]] = [:]
        for r in rows where r.provider == provider && window.contains(r.date) && r.model != ScanEntry.messageBucketModel {
            let tokens = Self.tokens(of: r, basis: basis)
            var acc = byDay[r.date, default: [:]][r.model] ?? Acc()
            acc.tokens += tokens
            acc.cost += max(0, r.cost)
            byDay[r.date, default: [:]][r.model] = acc
        }
        return ProviderUsageDays(
            provider: provider, scope: .allDevices, basis: basis,
            days: keys.map { day($0, byDay[$0]) },
            coverage: .unknown)
    }

    /// Whether `provider` has any usage in the `days` days ending at
    /// `todayKey`, on this Mac or in the synced rows: what `fromScan` and
    /// `fromCloud` would call `hasUsage`, without building the days. The
    /// provider cards ask it on every redraw.
    public static func hasUsage(
        provider: String,
        scan: [CostUsageScanResult.DailyEntry],
        cloud: [DailyUsage],
        days count: Int = 30,
        todayKey: String,
        timeZone: TimeZone = .current) -> Bool
    {
        let window = Set(dayKeys(count: count, endingAt: todayKey, timeZone: timeZone))
        let bucket = ScanEntry.messageBucketModel
        return scan.contains {
            $0.provider == provider && $0.model != bucket && window.contains($0.date)
                && (tokens(of: $0, basis: .eachOnce) > 0 || ($0.costUSD ?? 0) > 0)
        } || cloud.contains {
            $0.provider == provider && $0.model != bucket && window.contains($0.date)
                && (tokens(of: $0, basis: .eachOnce) > 0 || $0.cost > 0)
        }
    }

    static func tokens(of e: CostUsageScanResult.DailyEntry, basis: TokenBasis) -> Int {
        switch basis {
        case .eachOnce: return ArchiveTokenBasis.tokens(of: e)
        case .inputOutput: return max(0, e.inputTokens) + max(0, e.outputTokens)
        }
    }

    static func tokens(of r: DailyUsage, basis: TokenBasis) -> Int {
        switch basis {
        case .eachOnce:
            return ArchiveTokenBasis.tokens(
                provider: r.provider, inputTokens: r.inputTokens,
                cachedTokens: r.cachedTokens, outputTokens: r.outputTokens)
        case .inputOutput:
            return max(0, r.inputTokens) + max(0, r.outputTokens)
        }
    }

    private struct Acc {
        var tokens = 0
        var cost = 0.0
        var unpriced = 0
        var approximate = false
    }

    private static func day(_ key: String, _ models: [String: Acc]?) -> Day {
        let rows = (models ?? [:]).compactMap { model, acc -> ModelRow? in
            // A model with neither tokens nor cost that day says nothing.
            guard acc.tokens > 0 || acc.cost > 0 else { return nil }
            return ModelRow(model: model, tokens: acc.tokens, cost: acc.cost,
                            unpricedTokens: acc.unpriced, isApproximate: acc.approximate)
        }
        return Day(dateKey: key, models: rows)
    }

    /// The `count` day keys ending at `todayKey`, oldest first. Gregorian
    /// numbering in `timeZone`, as the scanner and the server write them.
    /// An unreadable `todayKey` gives none.
    static func dayKeys(count: Int, endingAt todayKey: String, timeZone: TimeZone) -> [String] {
        guard count > 0, let today = DayKey.formatter(in: timeZone).date(from: todayKey) else { return [] }
        let calendar = DayKey.calendar(in: timeZone)
        return (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { DayKey.string(from: $0, in: timeZone) }
        }
    }
}

// MARK: - Text

public extension ProviderUsageDays.TokenBasis {
    /// A token count as this basis labels it: "17M tokens" or "17M I/O".
    func tokensText(_ tokens: Int) -> String {
        let count = CostFormatter.formatUsage(tokens)
        switch self {
        case .eachOnce: return L10n.providerPanel.modelTokens(count)
        case .inputOutput: return L10n.providerPanel.modelIOTokens(count)
        }
    }
}

public extension ProviderUsageDays.Day {
    /// The day as a date to read: "Sep 29", "9月29日".
    var dateText: String { DisplayFormat.day(dateKey, style: .monthDay) ?? dateKey }

    /// The day's cost, "≥" when some of its tokens had no rate, "≈" when part
    /// of it was charged at a borrowed rate.
    var costText: String {
        CostFormatter.format(cost, approximate: isApproximate, atLeast: hasUnpriced)
    }

    /// The selected day's line: "Sep 29: $30.27 · 17M tokens", in the
    /// counting `basis` names, without the cost when costs are hidden.
    func summary(basis: ProviderUsageDays.TokenBasis, showsCost: Bool) -> String {
        guard hasUsage else { return L10n.providerPanel.noUsageDay(dateText) }
        let count = CostFormatter.formatUsage(tokens)
        switch (basis, showsCost) {
        case (.eachOnce, true): return L10n.providerPanel.daySummary(dateText, costText, count)
        case (.eachOnce, false): return L10n.providerPanel.dayTokens(dateText, count)
        case (.inputOutput, true): return L10n.providerPanel.dayIOSummary(dateText, costText, count)
        case (.inputOutput, false): return L10n.providerPanel.dayIOTokens(dateText, count)
        }
    }
}

public extension ProviderUsageDays.ModelRow {
    /// "No rate" for a model none of whose tokens had a rate, otherwise its
    /// cost, marked "≥" or "≈" as a day's is.
    var costText: String {
        hasNoRate
            ? L10n.providerPanel.noRate
            : CostFormatter.format(cost, approximate: isApproximate, atLeast: isPartlyUnpriced)
    }
}

public extension ProviderUsageDays {
    /// The window's total cost, marked as a day's is.
    var totalCostText: String {
        CostFormatter.format(totalCost, approximate: isApproximate, atLeast: hasUnpriced)
    }
}

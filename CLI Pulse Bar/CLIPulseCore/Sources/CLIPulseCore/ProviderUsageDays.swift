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

    /// v1.58: how tall a cost chart draws a day that has usage and no known
    /// cost (`ProviderUsageDays.Day.costIsUnknown`), as a share of the
    /// chart's tallest bar: a grey stub on the baseline, so the day does not
    /// read as one with no usage, and short enough that it cannot be read as
    /// a cost. When no day has a known cost the charts draw it against an
    /// axis of 1 without figures (`unknownCostStubValue(top:)`).
    public static let unknownCostStubShare = 0.04

    /// The value a cost chart plots for an unknown-cost day, on an axis
    /// whose tallest known day is `top`.
    public static func unknownCostStubValue(top: Double) -> Double {
        top > 0 ? top * unknownCostStubShare : unknownCostStubShare
    }

    /// v1.58: whether a chart of this measure draws `day` as the stub of a
    /// day with usage and no known cost. Only in Cost: in Tokens the day has
    /// its bar.
    public func drawsUnknownCostStub(_ day: ProviderUsageDays.Day) -> Bool {
        self == .cost && day.costIsUnknown
    }

    /// The height a bar chart gives `day` on an axis whose tallest known day
    /// is `top`: its value, or the stub's (`unknownCostStubValue(top:)`).
    public func plottedValue(_ day: ProviderUsageDays.Day, top: Double) -> Double {
        drawsUnknownCostStub(day) ? Self.unknownCostStubValue(top: top) : day.value(self)
    }

    /// A value on a chart's y axis whose highest value is `top`. Costs are
    /// whole units ("$50") once the axis reaches 10 of them, and keep the
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
        /// Synced tokens whose row arrived with a cost of 0. The device that
        /// uploaded them sends a missing cost as 0 (`APIClient.syncDailyUsage`),
        /// and a model priced at 0 sends 0 too, so the row cannot say which:
        /// what they cost is not known here. Always 0 for this Mac's scan,
        /// which knows (`unpricedTokens`).
        public let unknownCostTokens: Int
        /// Part of `cost` was charged at a rate borrowed from a neighbouring
        /// model (`CostUsageScanResult.DailyEntry.priceIsApproximate`).
        public let isApproximate: Bool

        public var id: String { model }
        /// Some of its tokens had no rate: its cost is a lower bound.
        public var isPartlyUnpriced: Bool { unpricedTokens > 0 }
        /// None of its tokens had a rate: it has no cost to show at all.
        public var hasNoRate: Bool { unpricedTokens > 0 && unpricedTokens >= tokens && cost == 0 }
        /// What none of its tokens cost is known (synced rows, all at 0): it
        /// shows no price, not "$0.00".
        public var costIsUnknown: Bool { unknownCostTokens > 0 && unknownCostTokens >= tokens && cost == 0 }
        /// Its cost leaves out tokens that had no rate, or whose cost is not
        /// known: the figure is a lower bound.
        public var isLowerBound: Bool { unpricedTokens > 0 || unknownCostTokens > 0 }

        public init(
            model: String, tokens: Int, cost: Double, unpricedTokens: Int = 0, unknownCostTokens: Int = 0,
            isApproximate: Bool = false)
        {
            self.model = model
            self.tokens = tokens
            self.cost = cost
            self.unpricedTokens = unpricedTokens
            self.unknownCostTokens = unknownCostTokens
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
        /// Some of the day's synced tokens arrived with no cost: its cost is
        /// a lower bound.
        public var hasUnknownCost: Bool { models.contains { $0.unknownCostTokens > 0 } }
        public var isApproximate: Bool { models.contains { $0.isApproximate } }
        /// v1.58: the day has usage and none of it has a known cost: every
        /// model either had no rate on this Mac or arrived synced with a cost
        /// of 0. Its cost bar would be empty, the same as a day with no usage,
        /// so the charts draw it as a grey stub instead
        /// (`UsageChartMetric.unknownCostStubShare`). A day whose models are
        /// priced at 0 has a known cost, $0, and is not one.
        public var costIsUnknown: Bool {
            tokens > 0 && cost == 0 && models.allSatisfy { $0.tokens == 0 || $0.hasNoRate || $0.costIsUnknown }
        }

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
    /// v1.58: a chart of these days in `metric` draws a grey stub for a day
    /// with usage and no known cost, so the chart says what one is.
    public func drawsUnknownCostStub(_ metric: UsageChartMetric) -> Bool {
        days.contains(where: metric.drawsUnknownCostStub)
    }
    /// Some tokens in the window had no rate: the total cost is a lower bound.
    public var hasUnpriced: Bool { days.contains { $0.hasUnpriced } }
    /// Some synced tokens in the window arrived with no cost: the total cost
    /// is a lower bound.
    public var hasUnknownCost: Bool { days.contains { $0.hasUnknownCost } }
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

    /// A day's rows in the order a list shows them: by cost while costs are
    /// shown (`Day.models`), by tokens, then name, while they are hidden, so
    /// the list does not follow, or give away, a ranking the reader chose
    /// not to see.
    public static func displayOrder(_ rows: [ModelRow], showsCost: Bool) -> [ModelRow] {
        guard !showsCost else { return rows }
        return rows.sorted { lhs, rhs in
            lhs.tokens != rhs.tokens ? lhs.tokens > rhs.tokens : lhs.model < rhs.model
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
        let (keys, window) = windowCache.window(count: count, endingAt: todayKey, timeZone: timeZone)
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
    /// unknown. A row with tokens and a cost of 0 may be a model with no rate
    /// on the device that uploaded it, so its tokens are `unknownCostTokens`
    /// and are never shown as "$0.00".
    public static func fromCloud(
        _ rows: [DailyUsage],
        provider: String,
        basis: TokenBasis = .eachOnce,
        days count: Int = 30,
        todayKey: String,
        timeZone: TimeZone = .current) -> ProviderUsageDays
    {
        let (keys, window) = windowCache.window(count: count, endingAt: todayKey, timeZone: timeZone)
        var byDay: [String: [String: Acc]] = [:]
        for r in rows where r.provider == provider && window.contains(r.date) && r.model != ScanEntry.messageBucketModel {
            let tokens = Self.tokens(of: r, basis: basis)
            let cost = max(0, r.cost)
            var acc = byDay[r.date, default: [:]][r.model] ?? Acc()
            acc.tokens += tokens
            acc.cost += cost
            if tokens > 0, cost == 0 { acc.unknownCost += tokens }
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
        let window = windowCache.window(count: count, endingAt: todayKey, timeZone: timeZone).set
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
        var unknownCost = 0
        var approximate = false
    }

    private static func day(_ key: String, _ models: [String: Acc]?) -> Day {
        let rows = (models ?? [:]).compactMap { model, acc -> ModelRow? in
            // A model with neither tokens nor cost that day says nothing.
            guard acc.tokens > 0 || acc.cost > 0 else { return nil }
            return ModelRow(model: model, tokens: acc.tokens, cost: acc.cost,
                            unpricedTokens: acc.unpriced, unknownCostTokens: acc.unknownCost,
                            isApproximate: acc.approximate)
        }
        return Day(dateKey: key, models: rows)
    }

    /// The `count` day keys ending at `todayKey`, oldest first. Gregorian
    /// numbering in `timeZone`, as the scanner and the server write them.
    /// An unreadable `todayKey` gives none.
    static func dayKeys(count: Int, endingAt todayKey: String, timeZone: TimeZone) -> [String] {
        windowCache.window(count: count, endingAt: todayKey, timeZone: timeZone).keys
    }

    static func buildDayKeys(count: Int, endingAt todayKey: String, timeZone: TimeZone) -> [String] {
        guard count > 0, let today = DayKey.formatter(in: timeZone).date(from: todayKey) else { return [] }
        let calendar = DayKey.calendar(in: timeZone)
        return (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { DayKey.string(from: $0, in: timeZone) }
        }
    }

    /// The last window built: the provider cards ask `hasUsage` on every
    /// redraw, and the iPhone card builds its days on every body, so the
    /// formatter and calendars behind a window are made once per day, not
    /// each time.
    static let windowCache = WindowCache()

    final class WindowCache: @unchecked Sendable {
        private let lock = NSLock()
        private var id: String?
        private var keys: [String] = []
        private var set: Set<String> = []

        func window(count: Int, endingAt todayKey: String, timeZone: TimeZone) -> (keys: [String], set: Set<String>) {
            let id = "\(count)|\(todayKey)|\(timeZone.identifier)|\(timeZone.secondsFromGMT())"
            lock.lock()
            defer { lock.unlock() }
            if id == self.id { return (keys, set) }
            let built = ProviderUsageDays.buildDayKeys(count: count, endingAt: todayKey, timeZone: timeZone)
            self.id = id
            keys = built
            set = Set(built)
            return (built, set)
        }
    }
}

// MARK: - Text

public extension ProviderUsageDays {
    /// The cost of a row, a day or the window when none of it is known: a
    /// dash, never "$0.00".
    static let unknownCostText = "—"
}

public extension ProviderUsageDays.TokenBasis {
    /// A token count as this basis labels it: "6.5M tokens" or "6.5M I/O".
    func tokensText(_ tokens: Int) -> String {
        let count = CostFormatter.formatUsage(tokens)
        switch self {
        case .eachOnce: return L10n.providerPanel.modelTokens(count)
        case .inputOutput: return L10n.providerPanel.modelIOTokens(count)
        }
    }
}

public extension ProviderUsageDays.Day {
    /// The day as a date to read: "Oct 3", "10月3日".
    var dateText: String { DisplayFormat.day(dateKey, style: .monthDay) ?? dateKey }

    /// The day's cost, "≥" when some of its tokens had no rate or arrived
    /// with no cost, "≈" when part of it was charged at a borrowed rate, and
    /// a dash when none of it is known.
    var costText: String {
        if cost == 0, hasUnknownCost, !hasUnpriced { return ProviderUsageDays.unknownCostText }
        return CostFormatter.format(cost, approximate: isApproximate, atLeast: hasUnpriced || hasUnknownCost)
    }

    /// Why the day's cost is a lower bound, for its tooltip; empty when it
    /// is not one.
    var costHelp: String {
        if hasUnpriced { return L10n.providerPanel.atLeastHelp }
        if hasUnknownCost { return L10n.providerPanel.scopeAllDevicesHelp }
        return ""
    }

    /// The selected day's line: "Oct 3: $11.42 · 6.5M tokens", in the
    /// counting `basis` names, without the cost when costs are hidden.
    func summary(basis: ProviderUsageDays.TokenBasis, showsCost: Bool) -> String {
        summary(basis: basis, showsCost: showsCost, cost: costText)
    }

    /// What VoiceOver reads for the day on a chart: `summary`, except that a
    /// day none of whose cost is known (`costIsUnknown`) says so in words
    /// ("Oct 3: cost unknown · 6.5M tokens"), where the line on screen has a
    /// dash, which VoiceOver reads as nothing or as "em dash", or "≥$0.00".
    /// v1.58: the grey stub a cost chart draws for such a day is read this
    /// way.
    func spokenSummary(basis: ProviderUsageDays.TokenBasis, showsCost: Bool) -> String {
        guard costIsUnknown else { return summary(basis: basis, showsCost: showsCost) }
        return summary(basis: basis, showsCost: showsCost, cost: L10n.providerPanel.costUnknown)
    }

    private func summary(basis: ProviderUsageDays.TokenBasis, showsCost: Bool, cost: String) -> String {
        guard hasUsage else { return L10n.providerPanel.noUsageDay(dateText) }
        let count = CostFormatter.formatUsage(tokens)
        switch (basis, showsCost) {
        case (.eachOnce, true): return L10n.providerPanel.daySummary(dateText, cost, count)
        case (.eachOnce, false): return L10n.providerPanel.dayTokens(dateText, count)
        case (.inputOutput, true): return L10n.providerPanel.dayIOSummary(dateText, cost, count)
        case (.inputOutput, false): return L10n.providerPanel.dayIOTokens(dateText, count)
        }
    }
}

public extension ProviderUsageDays.ModelRow {
    /// "No rate" for a model none of whose tokens had a rate, a dash for one
    /// whose synced cost is not known, otherwise its cost, marked "≥" or "≈"
    /// as a day's is.
    var costText: String {
        if hasNoRate { return L10n.providerPanel.noRate }
        if costIsUnknown { return ProviderUsageDays.unknownCostText }
        return CostFormatter.format(cost, approximate: isApproximate, atLeast: isLowerBound)
    }

    /// The tooltip of its cost; empty when there is nothing to explain.
    var costHelp: String {
        if hasNoRate { return L10n.providerPanel.noRateHelp }
        if isPartlyUnpriced { return L10n.providerPanel.atLeastHelp }
        if unknownCostTokens > 0 { return L10n.providerPanel.scopeAllDevicesHelp }
        return ""
    }
}

public extension ProviderUsageDays {
    /// What the window's tokens count, for the line under the panel's total:
    /// each token once, as the Usage Dashboard counts; or, opened from a
    /// provider card, the card's input + output, as this provider counts its
    /// input.
    var tokenBasisHelp: String {
        switch basis {
        case .eachOnce: return L10n.providerPanel.tokenBasis
        case .inputOutput: return Self.ioTokensHelp(provider: provider)
        }
    }

    /// What "I/O tokens" count for `provider`, naming no other provider:
    /// Codex's input already includes its cached input, Claude's leaves cache
    /// out, and anything else's input is as that provider counts it. The
    /// Overview, which adds Claude and Codex together, says both
    /// (`L10n.cost.ioTokensHelp`); a card and the panel it opens show one.
    static func ioTokensHelp(provider: String) -> String {
        switch provider {
        case ProviderKind.codex.rawValue: return L10n.providers.codexIOTokensHelp
        case ProviderKind.claude.rawValue: return L10n.providers.claudeIOTokensHelp
        default: return L10n.providers.ioTokensHelp
        }
    }

    /// The window's total, cost then tokens, in the counting `basis` names:
    /// "$23.83 · 2M tokens", or "$23.83 · 2M I/O tokens".
    var totalValueText: String {
        let count = CostFormatter.formatUsage(totalTokens)
        switch basis {
        case .eachOnce: return L10n.providerPanel.totalValue(totalCostText, count)
        case .inputOutput: return L10n.providerPanel.totalIOValue(totalCostText, count)
        }
    }

    /// The window's total cost, marked as a day's is.
    var totalCostText: String {
        if totalCost == 0, hasUnknownCost, !hasUnpriced { return Self.unknownCostText }
        return CostFormatter.format(totalCost, approximate: isApproximate, atLeast: hasUnpriced || hasUnknownCost)
    }

    /// Why the total is a lower bound, for its tooltip; empty when it is not.
    var totalCostHelp: String {
        if hasUnpriced { return L10n.providerPanel.atLeastHelp }
        if hasUnknownCost { return L10n.providerPanel.scopeAllDevicesHelp }
        return ""
    }
}

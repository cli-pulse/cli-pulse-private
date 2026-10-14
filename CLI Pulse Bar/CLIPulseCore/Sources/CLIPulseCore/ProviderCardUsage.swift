import Foundation

/// The three windows a provider card adds up: today, the rolling week (today
/// and the six days before it) and the last 30 days (today and the 29 before
/// it). The same windows the server's `provider_summary` uses
/// (`v_today - 6`, `v_today - 29`), so a figure from either side covers the
/// same days.
public enum ProviderUsageWindow: CaseIterable, Sendable {
    case today
    case week
    case thirtyDays

    public var dayCount: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .thirtyDays: return 30
        }
    }
}

/// The day keys of those windows, ending at the day that holds `now` in
/// `timeZone`. Keys are Gregorian (`DayKey`), the scanner's and the server's.
///
/// The 30 keys are the usage panel's (`ProviderUsageDays.dayKeys`), so a day
/// on the card's chart is the same day in the panel it opens.
public struct ProviderUsageWindows: Sendable, Equatable {
    /// The 30 days the card covers, oldest first; the last one is today.
    public let dayKeys: [String]
    public let timeZone: TimeZone

    public var todayKey: String { dayKeys[dayKeys.count - 1] }

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        let days = ProviderUsageWindow.thirtyDays.dayCount
        let todayKey = DayKey.string(from: now, in: timeZone)
        let shared = ProviderUsageDays.dayKeys(count: days, endingAt: todayKey, timeZone: timeZone)
        if shared.count == days, shared.last == todayKey {
            self.dayKeys = shared
        } else {
            // The panel's keys start from today's midnight; in a zone where
            // that midnight does not exist they cannot be built, so count
            // back from `now` instead. Same keys on every other day.
            let calendar = DayKey.calendar(in: timeZone)
            self.dayKeys = (0..<days).reversed().map { offset in
                DayKey.string(from: calendar.date(byAdding: .day, value: -offset, to: now) ?? now, in: timeZone)
            }
        }
        self.timeZone = timeZone
    }

    /// The first day of `window`.
    public func startKey(_ window: ProviderUsageWindow) -> String {
        dayKeys[dayKeys.count - window.dayCount]
    }

    /// Whether the day `key` falls in `window`. Keys compare as text because
    /// they are zero-padded `yyyy-MM-dd`.
    public func contains(_ key: String, in window: ProviderUsageWindow) -> Bool {
        key >= startKey(window) && key <= todayKey
    }
}

/// What a provider card's usage row and its small chart show.
public struct ProviderCardUsage: Sendable, Equatable {

    public struct Cell: Sendable, Equatable {
        /// Estimated cost in USD. nil when nothing reports a cost for this
        /// provider at all (Gemini's quota-only figures), so the card says
        /// "—" instead of a "$0.00" that reads as "free".
        public let cost: Double?
        /// Part of this Mac's share of `cost` was priced at a rate borrowed
        /// from a neighbouring model ("≈"). It says nothing about other
        /// devices' share, which this Mac cannot see.
        public let costIsApproximate: Bool
        /// Input + output tokens, as each provider counts its input: Claude's
        /// leaves cache out, Codex's already holds its cached input. nil when
        /// there are none.
        public let ioTokens: Int?
        /// Claude's message count. Only this Mac's logs have it: no device
        /// uploads it.
        public let messages: Int?

        public init(cost: Double?, costIsApproximate: Bool, ioTokens: Int?, messages: Int?) {
            self.cost = cost
            self.costIsApproximate = costIsApproximate
            self.ioTokens = ioTokens
            self.messages = messages
        }
    }

    public let today: Cell
    public let week: Cell
    public let thirtyDays: Cell
    /// This Mac's last 30 days, built as the usage panel builds its This Mac
    /// view (`ProviderUsageDays.fromScan`), in input + output tokens: every
    /// day present, oldest first, a day with nothing there with nothing.
    public let thisMac: ProviderUsageDays
    /// The account's synced last 30 days, built as the panel's All devices
    /// view (`fromCloud`). nil when the card does not read the account
    /// (signed out).
    public let account: ProviderUsageDays?
    public let scope: UsageDataScope

    public init(
        today: Cell, week: Cell, thirtyDays: Cell,
        thisMac: ProviderUsageDays, account: ProviderUsageDays?, scope: UsageDataScope
    ) {
        self.today = today
        self.week = week
        self.thirtyDays = thirtyDays
        self.thisMac = thisMac
        self.account = account
        self.scope = scope
    }

    public func cell(_ window: ProviderUsageWindow) -> Cell {
        switch window {
        case .today: return today
        case .week: return week
        case .thirtyDays: return thirtyDays
        }
    }

    /// The chart's bars for `metric`, oldest first: day by day, whichever of
    /// this Mac's day and the account's is larger in `metric`, the rule the
    /// figures beside the chart use. So today's bar is the Today figure, and
    /// each bar is one source's day as the panel lists it, never a mix of two.
    public func chartDays(_ metric: UsageChartMetric) -> [ProviderUsageDays.Day] {
        let local = thisMac.days
        guard let synced = account?.days, !synced.isEmpty else { return local }
        guard !local.isEmpty else { return synced }
        let byKey = Dictionary(synced.map { ($0.dateKey, $0) }, uniquingKeysWith: { first, _ in first })
        return local.map { day in
            guard let other = byKey[day.dateKey] else { return day }
            return other.value(metric) > day.value(metric) ? other : day
        }
    }

    /// Whether any window has a figure. A card with none (a provider nothing
    /// counts usage for) has no scope to name.
    public var hasAnyFigure: Bool {
        [today, week, thirtyDays].contains {
            $0.cost != nil || $0.ioTokens != nil || $0.messages != nil
        }
    }

    /// Whether the chart has a bar to draw for `metric`.
    public func chartHasData(_ metric: UsageChartMetric) -> Bool {
        chartDays(metric).contains { $0.value(metric) > 0 }
    }

    /// The tallest bar, for the chart's scale and its help text.
    public func chartMaximum(_ metric: UsageChartMetric) -> Double {
        chartDays(metric).map { $0.value(metric) }.max() ?? 0
    }

    /// The messages a signed-in card shows are this Mac's alone, beside
    /// tokens and cost from every device, so the card has to say so.
    public var messagesAreThisMacOnly: Bool {
        scope == .allDevices && [today, week, thirtyDays].contains { $0.messages != nil }
    }

    /// What the card's chart measures: what the usage panel was last set to
    /// (`storedMetric`, the raw value under `UsageChartMetric.defaultsKey`),
    /// except that with costs hidden (Settings › Display) it is tokens. A
    /// cost bar, and its "highest day: $…" help, would show what that switch
    /// hides.
    public static func chartMetric(storedMetric: String?, showsCost: Bool) -> UsageChartMetric {
        showsCost ? UsageChartMetric.stored(storedMetric) : .tokens
    }

    /// What the card's scope label means, on hover. Signed in, the card takes
    /// this Mac's own count where it is larger than what has synced so far,
    /// which the panel's own words for the scope do not say.
    public static func scopeHelp(_ scope: UsageDataScope) -> String {
        switch scope {
        case .thisMac: return L10n.providerCard.scopeThisMacHelp
        case .allDevices: return L10n.providerCard.scopeAllDevicesHelp
        }
    }

    /// Where a card opens the usage panel's provider mode from: one place at
    /// a time.
    public enum PanelEntry: Equatable, Sendable {
        /// The small chart: click it.
        case chart
        /// The chart is not drawn (hidden from the card, or nothing in it for
        /// the measure it shows) while the panel has days to show: a button
        /// in the card's header.
        case headerButton
        /// The panel would have nothing to show.
        case none
    }

    /// `chartDrawn`: the card draws its chart. `panelHasHistory`: the panel
    /// has usage for the provider in the window
    /// (`UsagePanelModel.hasHistory`).
    public static func panelEntry(chartDrawn: Bool, panelHasHistory: Bool) -> PanelEntry {
        if chartDrawn { return .chart }
        return panelHasHistory ? .headerButton : .none
    }
}

/// Builds `ProviderCardUsage`, and the per-provider figures the Providers tab's
/// cost bar and the Overview's Cost Summary add up, from one rule, so the same
/// provider's Today (and 30 days) reads the same on all three.
///
/// The rule is the one the card's Today already used (`applyCostScan`): for
/// each window, the larger of this Mac's own count and the account's synced
/// one. Signed in, the synced figure holds every device, this Mac's earlier
/// uploads included, so the larger one is every device's usage with this
/// Mac's latest refresh in it; signed out there is no synced figure and the
/// rule leaves this Mac's own. The larger is taken, never the sum, because the
/// synced figure already contains what this Mac sent.
///
/// The chart takes the larger day by day (`ProviderCardUsage.chartDays`), from
/// the days the usage panel lists (`ProviderUsageDays`).
public enum ProviderCardUsageBuilder {

    /// - Parameters:
    ///   - provider: the provider's raw name ("Codex").
    ///   - usage: its `ProviderUsage`, whose cost fields already hold the
    ///     larger of this Mac's and the account's figures for today and the
    ///     week (`applyCostScan`) and the account's 30-day figure.
    ///   - scanEntries: this Mac's session-log scan, every provider.
    ///   - cloudRows: the account's synced daily rows (`get_daily_usage`).
    ///     Ignored unless `readsCloud`.
    ///   - readsCloud: whether the card reads the account (signed in).
    ///   - usesProviderTokenCounts: a provider whose own collector reports
    ///     token counts in `today_usage` / `week_usage` (one without quota
    ///     windows); those counts join the rule for today and the week.
    public static func build(
        provider: String,
        usage: ProviderUsage?,
        scanEntries: [CostUsageScanResult.DailyEntry],
        cloudRows: [DailyUsage],
        readsCloud: Bool,
        usesProviderTokenCounts: Bool = false,
        windows: ProviderUsageWindows = ProviderUsageWindows()
    ) -> ProviderCardUsage {
        let local = scanEntries.filter { $0.provider == provider }
        let cloud = readsCloud ? cloudRows.filter { $0.provider == provider } : []
        let reportsCost = Self.reportsCost(usage: usage, localEntries: local, windows: windows)

        func cell(_ window: ProviderUsageWindow) -> ProviderCardUsage.Cell {
            let inWindow = local.filter { windows.contains($0.date, in: window) }
            var tokens = max(
                Self.localIOTokens(inWindow),
                Self.cloudIOTokens(cloud.filter { windows.contains($0.date, in: window) })
            )
            if usesProviderTokenCounts, let usage {
                switch window {
                case .today: tokens = max(tokens, usage.today_usage)
                case .week: tokens = max(tokens, usage.week_usage)
                case .thirtyDays: break
                }
            }
            let messages = inWindow.reduce(0) { $0 + $1.messageCount }
            return ProviderCardUsage.Cell(
                cost: reportsCost
                    ? Self.cost(window, localEntries: inWindow, usage: usage)
                    : nil,
                costIsApproximate: inWindow.contains { $0.priceIsApproximate },
                ioTokens: tokens > 0 ? tokens : nil,
                messages: messages > 0 ? messages : nil
            )
        }

        return ProviderCardUsage(
            today: cell(.today),
            week: cell(.week),
            thirtyDays: cell(.thirtyDays),
            thisMac: ProviderUsageDays.fromScan(
                local, provider: provider, basis: .inputOutput,
                days: ProviderUsageWindow.thirtyDays.dayCount,
                todayKey: windows.todayKey, timeZone: windows.timeZone),
            account: readsCloud
                ? ProviderUsageDays.fromCloud(
                    cloud, provider: provider, basis: .inputOutput,
                    days: ProviderUsageWindow.thirtyDays.dayCount,
                    todayKey: windows.todayKey, timeZone: windows.timeZone)
                : nil,
            scope: readsCloud ? .allDevices : .thisMac
        )
    }

    /// `provider`'s cost for `window` under the rule: what its card shows, and
    /// what the cost bar and the Cost Summary add up.
    public static func cost(
        _ window: ProviderUsageWindow,
        provider: String,
        usage: ProviderUsage?,
        scanEntries: [CostUsageScanResult.DailyEntry],
        windows: ProviderUsageWindows
    ) -> Double {
        cost(
            window,
            localEntries: scanEntries.filter {
                $0.provider == provider && windows.contains($0.date, in: window)
            },
            usage: usage
        )
    }

    /// `provider`'s input + output tokens for `window` under the rule.
    public static func ioTokens(
        _ window: ProviderUsageWindow,
        provider: String,
        scanEntries: [CostUsageScanResult.DailyEntry],
        cloudRows: [DailyUsage],
        windows: ProviderUsageWindows
    ) -> Int {
        max(
            localIOTokens(scanEntries.filter {
                $0.provider == provider && windows.contains($0.date, in: window)
            }),
            cloudIOTokens(cloudRows.filter {
                $0.provider == provider && windows.contains($0.date, in: window)
            })
        )
    }

    /// `localEntries` are already this provider's, inside the window.
    static func cost(
        _ window: ProviderUsageWindow,
        localEntries: [CostUsageScanResult.DailyEntry],
        usage: ProviderUsage?
    ) -> Double {
        let local = localEntries.compactMap(\.costUSD).reduce(0, +)
        let synced: Double
        switch window {
        case .today: synced = usage?.estimated_cost_today ?? 0
        case .week: synced = usage?.estimated_cost_week ?? 0
        case .thirtyDays: synced = usage?.estimated_cost_30_day ?? 0
        }
        return max(local, synced)
    }

    static func localIOTokens(_ entries: [CostUsageScanResult.DailyEntry]) -> Int {
        entries.reduce(0) { $0 + max(0, $1.inputTokens) + max(0, $1.outputTokens) }
    }

    static func cloudIOTokens(_ rows: [DailyUsage]) -> Int {
        rows.filter { $0.model != ScanEntry.messageBucketModel }
            .reduce(0) { $0 + max(0, $1.inputTokens) + max(0, $1.outputTokens) }
    }

    /// Whether anything reports a cost for this provider: this Mac's logs
    /// within the 30 days, a cost figure, or a cost status other than
    /// "Unavailable" (what every quota-only collector writes).
    static func reportsCost(
        usage: ProviderUsage?,
        localEntries: [CostUsageScanResult.DailyEntry],
        windows: ProviderUsageWindows
    ) -> Bool {
        if localEntries.contains(where: { windows.contains($0.date, in: .thirtyDays) }) { return true }
        guard let usage else { return false }
        if usage.estimated_cost_today > 0 || usage.estimated_cost_week > 0 || usage.estimated_cost_30_day > 0 {
            return true
        }
        let silent: Set<String> = ["", "Unavailable"]
        return !silent.contains(usage.cost_status_today) || !silent.contains(usage.cost_status_week)
    }
}

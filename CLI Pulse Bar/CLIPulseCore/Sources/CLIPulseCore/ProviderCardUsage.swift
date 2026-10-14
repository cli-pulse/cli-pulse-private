import Foundation

/// The three windows a provider card adds up: today, the rolling week (today
/// and the six days before it) and the last 30 days (today and the 29 before
/// it). The same windows the server's `provider_summary` uses
/// (`v_today - 6`, `v_today - 29`, from the day the app sends as
/// `p_user_today`).
///
/// `get_daily_usage` counts its days back from the server's own date, which
/// is UTC, not from the user's. West of UTC in the evening that date is
/// already tomorrow, and 30 days from it leave out the user's oldest day, so
/// the app asks for one day more (`AppState.dailyUsageFetchDays`) and keeps
/// the rows of these keys: a figure from either side then covers the same
/// days.
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

    /// How the card counts tokens: input + output ("I/O"), as every figure
    /// on the card says. The usage panel a card opens counts the same way
    /// (`DashboardPanelController.toggle(provider:state:scope:basis:)`), so
    /// the click lands on the card's numbers.
    public static let tokenBasis: ProviderUsageDays.TokenBasis = .inputOutput

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
    /// this Mac's day and the account's is larger in `metric`. The figures
    /// beside the chart are these bars added up (`ProviderCardUsageBuilder`),
    /// so This Week is the last seven bars and 30 Days all of them, and each
    /// bar is one source's day as the panel lists it, never a mix of two.
    public func chartDays(_ metric: UsageChartMetric) -> [ProviderUsageDays.Day] {
        Self.dailyMaxima(metric, thisMac: thisMac, account: account)
    }

    /// Day by day, the larger in `metric` of this Mac's day and the
    /// account's. The larger, never the sum: the account's day already holds
    /// what this Mac uploaded. A day this Mac has counted and not yet synced
    /// (today, or every day since an upload failed) is this Mac's; a day only
    /// the account has (another device's) is the account's.
    static func dailyMaxima(
        _ metric: UsageChartMetric, thisMac: ProviderUsageDays, account: ProviderUsageDays?
    ) -> [ProviderUsageDays.Day] {
        let local = thisMac.days
        guard let synced = account?.days, !synced.isEmpty else { return local }
        guard !local.isEmpty else { return synced }
        let byKey = Dictionary(synced.map { ($0.dateKey, $0) }, uniquingKeysWith: { first, _ in first })
        return local.map { day in
            guard let other = byKey[day.dateKey] else { return day }
            return other.value(metric) > day.value(metric) ? other : day
        }
    }

    /// Whether the figures come from days the usage panel can show: this
    /// Mac's scan or the account's synced rows. A provider whose figures are
    /// only what its own collector reports (an API key's usage, which the
    /// provider counts for the key, wherever it was used) has neither, and
    /// its card names no scope: "This Mac" or "All devices" would not be
    /// true of those figures.
    public var hasScope: Bool {
        thisMac.hasUsage || (account?.hasUsage ?? false)
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

    /// What the card's scope label means, on hover. This Mac reads as the
    /// panel's This Mac does (one string). Signed in, the card takes this
    /// Mac's own day where it is larger than what has synced so far, which
    /// the panel's words for All devices do not say, so that one is the
    /// card's own.
    public static func scopeHelp(_ scope: UsageDataScope) -> String {
        switch scope {
        case .thisMac: return L10n.providerPanel.scopeThisMacHelp
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

/// Builds `ProviderCardUsage`, the card the Providers tab draws for a
/// provider. The Providers tab's cost bar and the Overview's Cost Summary add
/// up the same cards (`AppState.updateCostSummary`), so the same provider's
/// Today (and 30 days) reads the same on all three.
///
/// The rule: day by day, the larger of this Mac's own count and the account's
/// synced one (`ProviderCardUsage.dailyMaxima`), added up over each window.
/// Signed in, a synced day holds every device's usage, this Mac's earlier
/// uploads included, so the larger one is every device's usage with this
/// Mac's latest count in it; signed out there is no synced day and the rule
/// leaves this Mac's own. The larger is taken, never the sum, because the
/// synced day already contains what this Mac sent.
///
/// Day by day, not window by window: when this Mac has counted days the
/// account has not received yet (an upload failed, or the next sync has not
/// run) while the account holds more over the month, the larger window would
/// drop this Mac's unsynced days. The figures are the chart's bars added up,
/// so This Week is never less than its seven bars.
///
/// The account's own window figures (`provider_summary`, the same rows
/// summed by the server) are a floor under each cost: they are what the card
/// shows before the daily rows arrive, and what a provider with no rows (an
/// API key's collector) reports.
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
        let thisMac = ProviderUsageDays.fromScan(
            local, provider: provider, basis: ProviderCardUsage.tokenBasis,
            days: ProviderUsageWindow.thirtyDays.dayCount,
            todayKey: windows.todayKey, timeZone: windows.timeZone)
        let account = readsCloud
            ? ProviderUsageDays.fromCloud(
                cloud, provider: provider, basis: ProviderCardUsage.tokenBasis,
                days: ProviderUsageWindow.thirtyDays.dayCount,
                todayKey: windows.todayKey, timeZone: windows.timeZone)
            : nil
        let tokenDays = ProviderCardUsage.dailyMaxima(.tokens, thisMac: thisMac, account: account)
        let costDays = ProviderCardUsage.dailyMaxima(.cost, thisMac: thisMac, account: account)
        let reportsCost = Self.reportsCost(usage: usage, localEntries: local, cloudRows: cloud, windows: windows)

        func cell(_ window: ProviderUsageWindow) -> ProviderCardUsage.Cell {
            let inWindow = local.filter { windows.contains($0.date, in: window) }
            let hasRows = !inWindow.isEmpty || cloud.contains { windows.contains($0.date, in: window) }
            var tokens = tokenDays
                .filter { windows.contains($0.dateKey, in: window) }
                .reduce(0) { $0 + $1.tokens }
            // The provider's collector counts today and the week itself; no
            // collector counts 30 days.
            let countsOwnTokens = usesProviderTokenCounts && usage != nil && window != .thirtyDays
            if countsOwnTokens, let usage {
                tokens = max(tokens, window == .today ? usage.today_usage : usage.week_usage)
            }
            let summary = Self.summaryCost(window, usage: usage)
            let rowCost = costDays
                .filter { windows.contains($0.dateKey, in: window) }
                .reduce(0) { $0 + $1.cost }
            // Today and the week are reported by every collector that reports
            // a cost; 30 days only by this Mac's scan, the account's rows or
            // the account's 30-day figure. With none of them, a 30-day cost
            // of $0.00 beside a Today of $1.20 would be a figure nothing
            // counted: "—".
            let coversWindow = window != .thirtyDays || hasRows || summary > 0
            let messages = inWindow.reduce(0) { $0 + $1.messageCount }
            return ProviderCardUsage.Cell(
                cost: reportsCost && coversWindow ? max(rowCost, summary) : nil,
                costIsApproximate: inWindow.contains { $0.priceIsApproximate },
                // A collector's own count of 0 is a count: "0", as before.
                // Nothing counting the window is "—".
                ioTokens: tokens > 0 ? tokens : (countsOwnTokens ? 0 : nil),
                messages: messages > 0 ? messages : nil
            )
        }

        return ProviderCardUsage(
            today: cell(.today),
            week: cell(.week),
            thirtyDays: cell(.thirtyDays),
            thisMac: thisMac,
            account: account,
            scope: readsCloud ? .allDevices : .thisMac
        )
    }

    /// The account's (or the provider's collector's) own figure for `window`.
    static func summaryCost(_ window: ProviderUsageWindow, usage: ProviderUsage?) -> Double {
        switch window {
        case .today: return usage?.estimated_cost_today ?? 0
        case .week: return usage?.estimated_cost_week ?? 0
        case .thirtyDays: return usage?.estimated_cost_30_day ?? 0
        }
    }

    /// Whether anything reports a cost for this provider: this Mac's logs
    /// within the 30 days, the account's rows with a cost, a cost figure, or
    /// a cost status other than "Unavailable" (what every quota-only
    /// collector writes).
    static func reportsCost(
        usage: ProviderUsage?,
        localEntries: [CostUsageScanResult.DailyEntry],
        cloudRows: [DailyUsage],
        windows: ProviderUsageWindows
    ) -> Bool {
        if localEntries.contains(where: { windows.contains($0.date, in: .thirtyDays) }) { return true }
        if cloudRows.contains(where: { $0.cost > 0 && windows.contains($0.date, in: .thirtyDays) }) { return true }
        guard let usage else { return false }
        if usage.estimated_cost_today > 0 || usage.estimated_cost_week > 0 || usage.estimated_cost_30_day > 0 {
            return true
        }
        let silent: Set<String> = ["", "Unavailable"]
        return !silent.contains(usage.cost_status_today) || !silent.contains(usage.cost_status_week)
    }
}

import Foundation

// v1.58 (P1-5): Sessions · last 30 days. Which session this Mac's Codex and
// Claude usage was spent in, worked out from the session logs on this Mac and
// never uploaded.
//
// The scanner keeps, next to its (day, provider, model) rows and their split by
// project (`ProjectEntry`), the same rows split by session
// (`CostUsageScanResult.SessionEntry`), and what each session is
// (`SessionDetail`): the project it ran in, when its logs were last written and
// its subagents. This lists them for the slide-out panel's provider mode. The
// rows of one provider add up to that provider's scan rows, day by day and
// model by model, so the sessions of a window add up to the window's total.
//
// A session is:
//   * Codex: the conversation its rollouts name (`session_meta.payload
//     .session_id`, kept by P0-1a as `CostUsageFileUsage.sessionId`). A
//     subagent's rollout carries its parent's, so its usage counts in its
//     parent's row, which says how many subagents it includes. A file that
//     continues another (the same `payload.id`) is the same conversation.
//   * Claude: the transcript `<project>/<id>.jsonl`, with everything Claude
//     Code writes under `<project>/<id>/` (its subagents and workflow runs).
//
// Only the days in the window count. A file's own rows are not trimmed to the
// scan's days (a Codex file also carries the day before them), so the scanner
// keeps a session's rows of the scan's days only, and a list keeps those of its
// window, as the panel's total does.
//
// Privacy: a row names the project a session ran in (its folder's last
// component, or "Project N" with "Hide personal information" on), never
// anything taken from the conversation, and no session id.

extension CostUsageScanResult {

    /// One session's share of one (day, provider, model) row of the scan.
    public struct SessionEntry: Sendable, Equatable {
        public let provider: String
        /// `SessionDetail.key` of the session.
        public let session: String
        public let date: String
        public let model: String
        public let inputTokens: Int
        public let cachedTokens: Int
        public let outputTokens: Int
        /// nil when the model has no rate, as `DailyEntry.costUSD`.
        public let costUSD: Double?
        public let priceIsApproximate: Bool

        public init(
            provider: String, session: String, date: String, model: String,
            inputTokens: Int, cachedTokens: Int, outputTokens: Int,
            costUSD: Double?, priceIsApproximate: Bool = false)
        {
            self.provider = provider
            self.session = session
            self.date = date
            self.model = model
            self.inputTokens = inputTokens
            self.cachedTokens = cachedTokens
            self.outputTokens = outputTokens
            self.costUSD = costUSD
            self.priceIsApproximate = costUSD != nil && priceIsApproximate
        }
    }

    /// What one session is, apart from its rows.
    public struct SessionDetail: Sendable, Equatable {
        public let provider: String
        /// Unique among the provider's sessions; never shown.
        public let key: String
        /// The project it ran in, as Projects counts it.
        public let project: ProjectIdentity
        /// When its logs with usage were last written.
        public let lastActivity: Date
        /// One day per subagent log with usage in the scan's days: the latest
        /// day it has usage on. A subagent counts for a window that holds it.
        public let subagentLastDays: [String]

        public init(
            provider: String, key: String, project: ProjectIdentity, lastActivity: Date,
            subagentLastDays: [String] = [])
        {
            self.provider = provider
            self.key = key
            self.project = project
            self.lastActivity = lastActivity
            self.subagentLastDays = subagentLastDays
        }
    }
}

// MARK: - Ranking

/// One session's figures over a window.
public struct SessionUsageRow: Sendable, Equatable, Identifiable {
    public let provider: String
    public let key: String
    public let project: ProjectIdentity
    /// Its models over the window, most expensive first (then most tokens,
    /// then by name).
    public let models: [String]
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    /// The cost of the tokens that had a rate.
    public let cost: Double
    /// Some of its tokens had no rate, so they added nothing to `cost`.
    public let hasUnpriced: Bool
    /// Some of its tokens had a rate.
    public let hasPriced: Bool
    /// Part of `cost` was charged at a rate borrowed from a neighbouring model.
    public let isApproximate: Bool
    public let lastActivity: Date
    /// Its subagents with usage in the window.
    public let subagents: Int

    public var id: String { provider + "|" + key }

    /// Input + output, the "I/O" the provider cards count: Codex's input
    /// includes its cached input, Claude's leaves cache out.
    public var ioTokens: Int { SessionUsageRanking.plusSaturating(max(0, inputTokens), max(0, outputTokens)) }

    public init(
        provider: String, key: String, project: ProjectIdentity, models: [String],
        inputTokens: Int, cachedTokens: Int, outputTokens: Int, cost: Double,
        hasUnpriced: Bool = false, hasPriced: Bool = true, isApproximate: Bool = false,
        lastActivity: Date, subagents: Int = 0)
    {
        self.provider = provider
        self.key = key
        self.project = project
        self.models = models
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.cost = cost
        self.hasUnpriced = hasUnpriced
        self.hasPriced = hasPriced
        self.isApproximate = isApproximate
        self.lastActivity = lastActivity
        self.subagents = subagents
    }

    /// None of its tokens had a rate: there is no cost to show.
    public var hasNoRate: Bool { hasUnpriced && !hasPriced && cost == 0 }

    /// "$12.40", "≥$3.10" when some of its tokens had no rate, "≈$0.80" when
    /// part was charged at a borrowed rate, "No rate" when none had one: as
    /// the panel marks a model's cost.
    public var costText: String {
        if hasNoRate { return L10n.providerPanel.noRate }
        return CostFormatter.format(cost, approximate: isApproximate, atLeast: hasUnpriced)
    }

    /// Why the cost is marked, for its tooltip; empty when it is not.
    public var costHelp: String {
        if hasNoRate { return L10n.providerPanel.noRateHelp }
        if hasUnpriced { return L10n.providerPanel.atLeastHelp }
        return ""
    }
}

public enum SessionUsageRanking {

    /// How many days a list covers: the panel's window
    /// (`ProviderUsagePanelView.windowDays`), today and the 29 before.
    public static let windowDays = 30

    /// How a list is ordered.
    public enum Order: String, CaseIterable, Sendable, Identifiable {
        /// Most expensive first; most tokens first while costs are hidden.
        case cost
        /// Latest activity first.
        case latest

        public var id: String { rawValue }

        /// The picker's label: "Cost", or "Tokens" while costs are hidden
        /// (Settings › Display), when this order ranks by tokens.
        public func label(showsCost: Bool) -> String {
            switch self {
            case .cost: return showsCost ? L10n.providerPanel.metricCost : L10n.providerPanel.metricTokens
            case .latest: return L10n.sessionHistory.sortLatest
            }
        }
    }

    /// Every `provider` session of `entries` with usage over the `days` days
    /// ending at `todayKey`, unordered (`ordered`). A session's figures are
    /// those of its rows in the window only, and its subagents those with
    /// usage in it.
    public static func rows(
        _ entries: [CostUsageScanResult.SessionEntry],
        details: [CostUsageScanResult.SessionDetail],
        provider: String,
        days count: Int = windowDays,
        todayKey: String,
        timeZone: TimeZone = .current) -> [SessionUsageRow]
    {
        let window = ProviderUsageDays.windowCache.window(count: count, endingAt: todayKey, timeZone: timeZone).set
        struct Acc {
            var input = 0
            var cached = 0
            var output = 0
            var cost = 0.0
            var unpriced = false
            var priced = false
            var approximate = false
            var modelCost: [String: Double] = [:]
            var modelTokens: [String: Int] = [:]
        }
        var byKey: [String: Acc] = [:]
        for entry in entries where entry.provider == provider && window.contains(entry.date) {
            var acc = byKey[entry.session] ?? Acc()
            acc.input = plusSaturating(acc.input, max(0, entry.inputTokens))
            acc.cached = plusSaturating(acc.cached, max(0, entry.cachedTokens))
            acc.output = plusSaturating(acc.output, max(0, entry.outputTokens))
            let tokens = ArchiveTokenBasis.tokens(
                provider: entry.provider, inputTokens: entry.inputTokens,
                cachedTokens: entry.cachedTokens, outputTokens: entry.outputTokens)
            if let cost = entry.costUSD {
                acc.cost += max(0, cost)
                acc.modelCost[entry.model, default: 0] += max(0, cost)
                if tokens > 0 { acc.priced = true }
                if entry.priceIsApproximate { acc.approximate = true }
            } else if tokens > 0 {
                acc.unpriced = true
            }
            acc.modelTokens[entry.model] = plusSaturating(acc.modelTokens[entry.model] ?? 0, tokens)
            byKey[entry.session] = acc
        }
        let detailByKey = Dictionary(
            details.filter { $0.provider == provider }.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first })
        return byKey.compactMap { key, acc -> SessionUsageRow? in
            guard acc.input > 0 || acc.cached > 0 || acc.output > 0 || acc.cost > 0 else { return nil }
            let detail = detailByKey[key]
            let models = acc.modelTokens.keys.sorted { lhs, rhs in
                let (lc, rc) = (acc.modelCost[lhs] ?? 0, acc.modelCost[rhs] ?? 0)
                if lc != rc { return lc > rc }
                let (lt, rt) = (acc.modelTokens[lhs] ?? 0, acc.modelTokens[rhs] ?? 0)
                if lt != rt { return lt > rt }
                return lhs < rhs
            }
            return SessionUsageRow(
                provider: provider, key: key, project: detail?.project ?? .unknown, models: models,
                inputTokens: acc.input, cachedTokens: acc.cached, outputTokens: acc.output, cost: acc.cost,
                hasUnpriced: acc.unpriced, hasPriced: acc.priced, isApproximate: acc.approximate,
                lastActivity: detail?.lastActivity ?? .distantPast,
                subagents: detail?.subagentLastDays.filter { window.contains($0) }.count ?? 0)
        }
    }

    /// `rows` in `order`: by cost (then I/O tokens) while costs are shown,
    /// by I/O tokens while they are hidden, so a list whose costs are hidden
    /// does not follow, or give away, a ranking by cost; or latest activity
    /// first. Ties go to the more recent, then by key, so the order is the
    /// same on every run.
    public static func ordered(
        _ rows: [SessionUsageRow], by order: Order, showsCost: Bool) -> [SessionUsageRow]
    {
        rows.sorted { lhs, rhs in
            switch order {
            case .cost:
                if showsCost, lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
                if lhs.ioTokens != rhs.ioTokens { return lhs.ioTokens > rhs.ioTokens }
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            case .latest:
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                if showsCost, lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
                if lhs.ioTokens != rhs.ioTokens { return lhs.ioTokens > rhs.ioTokens }
            }
            return lhs.key < rhs.key
        }
    }

    static func plusSaturating(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
    }
}

// MARK: - What a list shows

/// One line of the Sessions list, as it is shown.
public struct SessionUsageLine: Sendable, Equatable, Identifiable {
    public let id: String
    /// The project's folder name, "Unknown", or with "Hide personal
    /// information" on "Project N".
    public let title: String
    /// What hovering the title shows: the project's full path, why it is
    /// unknown, or nothing (Hide personal information on, or a folder whose
    /// path is not known).
    public let hoverText: String?
    public let isUnknown: Bool
    /// "gpt-5.5 +1 · 1.2M I/O · 980K cached": its model (the most expensive,
    /// and how many more), I/O tokens and cached tokens.
    public let usageText: String
    /// "Last active Oct 20 at 2:05 PM · includes 3 subagents".
    public let activityText: String
    /// "$12.40", marked as a model's cost is; nil while costs are hidden.
    public let costText: String?
    /// Why the cost is marked; empty when it is not.
    public let costHelp: String
    /// None of its tokens had a rate: "No rate", drawn in secondary.
    public let hasNoRate: Bool

    public init(
        id: String, title: String, hoverText: String?, isUnknown: Bool, usageText: String,
        activityText: String, costText: String?, costHelp: String, hasNoRate: Bool = false)
    {
        self.id = id
        self.title = title
        self.hoverText = hoverText
        self.isUnknown = isUnknown
        self.usageText = usageText
        self.activityText = activityText
        self.costText = costText
        self.costHelp = costHelp
        self.hasNoRate = hasNoRate
    }

    /// What VoiceOver reads for the line: "name, cost, usage, activity".
    public var accessibilityText: String {
        ([title] + (costText.map { [$0] } ?? []) + [usageText, activityText]).joined(separator: ", ")
    }
}

/// The usage panel's Sessions list for one provider.
public struct SessionUsageList: Sendable, Equatable {
    public let lines: [SessionUsageLine]
    /// Whether the lines carry costs (Settings › Display).
    public let showsCost: Bool
    /// Whether "Hide personal information" numbered the projects.
    public let namesHidden: Bool
    public let order: SessionUsageRanking.Order

    public init(
        lines: [SessionUsageLine], showsCost: Bool = true, namesHidden: Bool = false,
        order: SessionUsageRanking.Order = .cost)
    {
        self.lines = lines
        self.showsCost = showsCost
        self.namesHidden = namesHidden
        self.order = order
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// "12 sessions".
    public var countText: String { L10n.sessionHistory.count(lines.count) }

    /// The card's footnote, a line each: what a row is and that the list is
    /// not synced; while costs are shown, that they are estimates (the rows
    /// sit well below the total that says so); and with "Hide personal
    /// information" on, how the projects are numbered.
    public var footnote: [String] {
        [L10n.sessionHistory.help]
            + (showsCost ? [L10n.usageDashboard.costDisclaimer] : [])
            + (namesHidden ? [L10n.projects.numberedHelp] : [])
    }

    /// The `provider` sessions of `entries` over the last `days` days.
    ///
    /// - Parameters:
    ///   - projects: this Mac's rows by project, every provider's: with "Hide
    ///     personal information" on, a session's project goes by the number
    ///     Projects gives it (`ProjectUsageRanking.anonymousNumbers`), so
    ///     "Project 2" is the same folder in both lists.
    ///   - showsCost: whether costs are shown (Settings › Display); without
    ///     them the lines carry no cost, and "cost" order ranks by tokens.
    ///   - hidePersonalInfo: the switch (`PersonalInfoMask`).
    public static func build(
        _ entries: [CostUsageScanResult.SessionEntry],
        details: [CostUsageScanResult.SessionDetail],
        projects: [CostUsageScanResult.ProjectEntry],
        provider: String,
        days: Int = SessionUsageRanking.windowDays,
        todayKey: String,
        timeZone: TimeZone = .current,
        showsCost: Bool,
        hidePersonalInfo: Bool,
        order: SessionUsageRanking.Order = .cost) -> SessionUsageList
    {
        let rows = SessionUsageRanking.ordered(
            SessionUsageRanking.rows(
                entries, details: details, provider: provider, days: days, todayKey: todayKey,
                timeZone: timeZone),
            by: order, showsCost: showsCost)
        let numbers = hidePersonalInfo
            ? ProjectUsageRanking.anonymousNumbers(
                projects, days: days, todayKey: todayKey, timeZone: timeZone, rankByCost: showsCost)
            : [:]
        let lines = rows.map { row in
            SessionUsageLine(
                id: row.id,
                title: PersonalInfoMask.projectTitle(
                    row.project, number: numbers[row.project.key], hidePersonalInfo: hidePersonalInfo),
                hoverText: row.project.isUnknown
                    ? L10n.projects.unknownHelp
                    : PersonalInfoMask.projectPath(row.project, hidePersonalInfo: hidePersonalInfo),
                isUnknown: row.project.isUnknown,
                usageText: usageText(row),
                activityText: activityText(row),
                costText: showsCost ? row.costText : nil,
                costHelp: showsCost ? row.costHelp : "",
                hasNoRate: showsCost && row.hasNoRate)
        }
        return SessionUsageList(lines: lines, showsCost: showsCost, namesHidden: hidePersonalInfo, order: order)
    }

    /// "gpt-5.5 +1 · 1.2M I/O · 980K cached".
    static func usageText(_ row: SessionUsageRow) -> String {
        let tokens = L10n.sessionHistory.ioCached(
            CostFormatter.formatUsage(row.ioTokens), CostFormatter.formatUsage(row.cachedTokens))
        return modelText(row.models).map { $0 + " · " + tokens } ?? tokens
    }

    /// The most expensive model, and how many others the session used:
    /// "gpt-5.5", "gpt-5.5 +2". nil for none.
    static func modelText(_ models: [String]) -> String? {
        guard let first = models.first else { return nil }
        return models.count > 1 ? first + " +" + String(models.count - 1) : first
    }

    /// "Last active Oct 20 at 2:05 PM", and "· includes 3 subagents" when
    /// it has some.
    static func activityText(_ row: SessionUsageRow) -> String {
        let active = L10n.sessionHistory.lastActive(DisplayFormat.dateTime(row.lastActivity))
        guard row.subagents > 0 else { return active }
        return active + " · " + L10n.sessionHistory.subagents(row.subagents)
    }
}

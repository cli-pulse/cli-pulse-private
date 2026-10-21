import Foundation

// v1.58 (P1-4): Projects. Which folder this Mac's Codex and Claude usage was
// spent in, worked out from the session logs on this Mac and never uploaded.
//
// The scanner keeps, next to its (day, provider, model) rows, the same rows
// split by project (`CostUsageScanResult.ProjectEntry`); this ranks them for
// the slide-out panel's provider mode and the Mac Overview's Top Projects
// card, and decides what each line shows. The rows of one provider add up to
// that provider's scan rows, day by day and model by model, so the projects of
// a window add up to the window's total.
//
// A project is a folder:
//   * Codex: the working directory a rollout's first line records
//     (`session_meta.payload.cwd`).
//   * Claude: the folder its project directory under `~/.claude/projects/`
//     was made from, read from a transcript's `cwd`
//     (`CostUsageScanner.claudeProjectAttribution`, the P0-13 function), else
//     the directory name decoded as well as it can be. A subagent's
//     transcript sits under its session's directory, so it counts for the
//     session's project.
//   * A log that names no folder is "Unknown".
//
// Two kinds of folder are temporary copies of a project rather than projects
// (`ProjectPathNormalizer`): Codex's own worktrees under `~/.codex/worktrees`,
// and anything under `/private/tmp`. Nothing is asked of git: a sandboxed app
// may not run it, and may not look inside the folders either. Every other
// worktree is a folder of its own and gets a line of its own.
//
// Privacy: a line shows the folder's last component; the full path appears
// only on hover, and with "Hide personal information" on neither does: each
// named project is "Project N" (`PersonalInfoMask.projectTitle`). A Codex
// rollout's `repository_url` can carry a token or `user@host`: it is only ever
// kept as a hash, used to match a temporary worktree to its checkout, and
// never shown, stored as written or uploaded.

extension CostUsageScanResult {

    /// One project's share of one (day, provider, model) row of the scan.
    public struct ProjectEntry: Sendable, Equatable {
        public let provider: String
        public let project: ProjectIdentity
        public let date: String
        public let model: String
        public let inputTokens: Int
        public let cachedTokens: Int
        public let outputTokens: Int
        /// nil when the model has no rate, as `DailyEntry.costUSD`.
        public let costUSD: Double?
        public let priceIsApproximate: Bool

        public init(
            provider: String, project: ProjectIdentity, date: String, model: String,
            inputTokens: Int, cachedTokens: Int, outputTokens: Int,
            costUSD: Double?, priceIsApproximate: Bool = false)
        {
            self.provider = provider
            self.project = project
            self.date = date
            self.model = model
            self.inputTokens = inputTokens
            self.cachedTokens = cachedTokens
            self.outputTokens = outputTokens
            self.costUSD = costUSD
            self.priceIsApproximate = costUSD != nil && priceIsApproximate
        }
    }
}

/// Which project a row belongs to.
public struct ProjectIdentity: Hashable, Sendable {
    /// Equal for the rows of one project, across providers when both name the
    /// same folder. Empty for an unknown project.
    public let key: String
    /// The folder's own name; nil for an unknown project, which shows as
    /// "Unknown".
    public let name: String?
    /// The folder's full path, for the line's hover text; nil when it is not
    /// known (a Claude directory whose transcripts never recorded a `cwd`).
    public let path: String?

    public init(key: String, name: String?, path: String?) {
        self.key = key
        self.name = name
        self.path = path
    }

    public static let unknown = ProjectIdentity(key: "", name: nil, path: nil)

    public var isUnknown: Bool { name == nil }

    /// A project that is the folder at `root` (already normalised).
    public static func folder(_ root: String) -> ProjectIdentity {
        ProjectIdentity(key: root, name: ProjectPathNormalizer.name(of: root), path: root)
    }

    /// The project Codex worktrees of one repository share when none of them
    /// could be matched to the checkout they were made from. Its key is not a
    /// path, so it never joins a folder's line by accident.
    static func codexWorktrees(named name: String, shownPath: String, home: String) -> ProjectIdentity {
        ProjectIdentity(
            key: ProjectPathNormalizer.codexWorktreesPrefix(home: home) + "/*/" + name,
            name: name,
            path: shownPath)
    }
}

// MARK: - Folders

/// Turns a recorded working directory into the folder a project is counted
/// under. Pure string work: it never touches the file system or runs git.
public enum ProjectPathNormalizer {

    /// `cwd` as a project folder: `~` expanded, `.` and `..` resolved by
    /// spelling, trailing slashes dropped, `/tmp` spelled `/private/tmp` (the
    /// same folder on macOS), and a Codex worktree cut to its checkout folder
    /// (`~/.codex/worktrees/<id>/<repo>`, whatever subfolder the session ran
    /// in). nil for nothing, or for a path that is not absolute.
    public static func root(_ cwd: String?, home: String) -> String? {
        guard var path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + String(path.dropFirst(1))
        }
        guard path.hasPrefix("/") else { return nil }
        path = lexicallyStandardized(path)
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            path = "/private" + path
        }
        let prefix = codexWorktreesPrefix(home: home)
        if path.hasPrefix(prefix + "/") {
            let below = path.dropFirst(prefix.count + 1).split(separator: "/")
            if below.count > 2 {
                path = prefix + "/" + below.prefix(2).joined(separator: "/")
            }
        }
        return path
    }

    /// Whether `root` is one of the temporary places a project is copied to
    /// for a while: Codex's worktrees and `/private/tmp`, the two CodexBar
    /// also treats as temporary. Only these are ever folded into another line.
    public static func isTemporary(_ root: String, home: String) -> Bool {
        let prefix = codexWorktreesPrefix(home: home)
        return root == prefix || root.hasPrefix(prefix + "/")
            || root == "/private/tmp" || root.hasPrefix("/private/tmp/")
    }

    /// The checkout folder's name of a Codex worktree,
    /// `~/.codex/worktrees/<id>/<repo>`; nil for any other folder.
    public static func codexWorktreeRepository(_ root: String, home: String) -> String? {
        let prefix = codexWorktreesPrefix(home: home)
        guard root.hasPrefix(prefix + "/") else { return nil }
        let below = root.dropFirst(prefix.count + 1).split(separator: "/")
        guard below.count == 2 else { return nil }
        return String(below[1])
    }

    /// What a folder is called: its last component ("/" for the root).
    public static func name(of root: String) -> String {
        let last = (root as NSString).lastPathComponent
        return last.isEmpty ? root : last
    }

    static func codexWorktreesPrefix(home: String) -> String {
        lexicallyStandardized(home + "/.codex/worktrees")
    }

    /// `path` with empty and `.` components dropped and each `..` removing
    /// the one before it, by spelling alone.
    static func lexicallyStandardized(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// A Codex rollout's `repository_url` as the scanner keeps it: a SHA-256,
    /// never the URL, which can carry a token or `user@host`. nil for none.
    public static func repositoryHash(_ url: String?) -> String? {
        guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
        return CryptoHelpers.sha256HexUtf8("cli-pulse-project-repository\u{1F}" + url)
    }
}

// MARK: - Ranking

/// One project's figures over a window.
public struct ProjectUsageRow: Sendable, Equatable, Identifiable {
    public let project: ProjectIdentity
    /// The providers whose rows it holds, sorted.
    public let providers: [String]
    /// In the basis the rows were counted in (`ProjectUsageRanking.rows`).
    public let tokens: Int
    /// The cost of the tokens that had a rate.
    public let cost: Double
    /// Tokens that had no rate, so they added nothing to `cost`.
    public let unpricedTokens: Int
    /// Part of `cost` was charged at a rate borrowed from a neighbouring model.
    public let isApproximate: Bool

    public var id: String { project.key }

    public init(
        project: ProjectIdentity, providers: [String], tokens: Int, cost: Double,
        unpricedTokens: Int = 0, isApproximate: Bool = false)
    {
        self.project = project
        self.providers = providers
        self.tokens = tokens
        self.cost = cost
        self.unpricedTokens = unpricedTokens
        self.isApproximate = isApproximate
    }

    /// None of its tokens had a rate: there is no cost to show.
    public var hasNoRate: Bool { unpricedTokens > 0 && unpricedTokens >= tokens && cost == 0 }

    /// "$12.40", "≥$3.10" when some of its tokens had no rate, "≈$0.80" when
    /// part was charged at a borrowed rate, "No rate" when none had one: as
    /// the panel marks a model's cost.
    public var costText: String {
        if hasNoRate { return L10n.providerPanel.noRate }
        return CostFormatter.format(cost, approximate: isApproximate, atLeast: unpricedTokens > 0)
    }

    /// Why the cost is marked, for its tooltip; empty when it is not.
    public var costHelp: String {
        if hasNoRate { return L10n.providerPanel.noRateHelp }
        if unpricedTokens > 0 { return L10n.providerPanel.atLeastHelp }
        return ""
    }
}

public enum ProjectUsageRanking {

    /// How many projects a list shows.
    public static let shownCount = 5

    /// How many days a list covers: the panel's window
    /// (`ProviderUsagePanelView.windowDays`), today and the 29 before.
    public static let windowDays = 30

    /// Every project of `entries` with usage over the `days` days ending at
    /// `todayKey`, most expensive first (then most tokens, then by name), or,
    /// with `rankByCost` false, most tokens first, so a list whose costs are
    /// hidden does not follow, or give away, a ranking by cost.
    ///
    /// - Parameters:
    ///   - provider: one provider's rows ("Codex"); nil for every provider's,
    ///     a project both name counted once.
    ///   - basis: how a row's tokens add up, as the view beside it counts
    ///     them (`ProviderUsageDays.TokenBasis`).
    public static func rows(
        _ entries: [CostUsageScanResult.ProjectEntry],
        provider: String? = nil,
        basis: ProviderUsageDays.TokenBasis,
        days count: Int = windowDays,
        todayKey: String,
        timeZone: TimeZone = .current,
        rankByCost: Bool = true) -> [ProjectUsageRow]
    {
        let window = ProviderUsageDays.windowCache.window(count: count, endingAt: todayKey, timeZone: timeZone).set
        struct Acc {
            var project: ProjectIdentity
            var providers: Set<String> = []
            var tokens = 0
            var cost = 0.0
            var unpriced = 0
            var approximate = false
        }
        var byKey: [String: Acc] = [:]
        for entry in entries where window.contains(entry.date) && (provider == nil || entry.provider == provider) {
            let tokens = Self.tokens(of: entry, basis: basis)
            var acc = byKey[entry.project.key] ?? Acc(project: entry.project)
            acc.providers.insert(entry.provider)
            acc.tokens = plusSaturating(acc.tokens, tokens)
            if let cost = entry.costUSD {
                acc.cost += max(0, cost)
                if entry.priceIsApproximate { acc.approximate = true }
            } else {
                acc.unpriced = plusSaturating(acc.unpriced, tokens)
            }
            // A project two providers name keeps the identity with a path.
            if acc.project.path == nil, entry.project.path != nil { acc.project = entry.project }
            byKey[entry.project.key] = acc
        }
        let rows = byKey.values
            .filter { $0.tokens > 0 || $0.cost > 0 }
            .map {
                ProjectUsageRow(
                    project: $0.project, providers: $0.providers.sorted(), tokens: $0.tokens, cost: $0.cost,
                    unpricedTokens: $0.unpriced, isApproximate: $0.approximate)
            }
        return ordered(rows, rankByCost: rankByCost)
    }

    /// The number each named project goes by with "Hide personal
    /// information" on: its place among every named project of every
    /// provider over the window, ranked as the Overview's Top Projects
    /// ranks them (by cost while costs are shown, by input + output tokens
    /// while they are hidden: `ProjectUsageList.overview`). So the Overview
    /// reads "Project 1, Project 2, …" in order, and "Project 2" is the same
    /// project in a provider's panel, where it keeps its number among fewer
    /// projects ranked by that provider's share (so a panel can read
    /// "Project 3, Project 1, Project 5": `L10n.projects.numberedHelp` says
    /// why). An unknown project names nothing personal and takes no number.
    public static func anonymousNumbers(
        _ entries: [CostUsageScanResult.ProjectEntry],
        days count: Int = windowDays,
        todayKey: String,
        timeZone: TimeZone = .current,
        rankByCost: Bool = true) -> [String: Int]
    {
        let all = rows(
            entries, basis: ProjectUsageList.overviewBasis, days: count, todayKey: todayKey, timeZone: timeZone,
            rankByCost: rankByCost)
        var numbers: [String: Int] = [:]
        for row in all where !row.project.isUnknown {
            numbers[row.project.key] = numbers.count + 1
        }
        return numbers
    }

    /// Most expensive first, then most tokens, then by name (an unknown
    /// project after a named one), then by key, so the order is the same on
    /// every run; by tokens first when `rankByCost` is false.
    static func ordered(_ rows: [ProjectUsageRow], rankByCost: Bool) -> [ProjectUsageRow] {
        rows.sorted { lhs, rhs in
            if rankByCost, lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            switch (lhs.project.name, rhs.project.name) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.project.key < rhs.project.key
            }
        }
    }

    static func tokens(of entry: CostUsageScanResult.ProjectEntry, basis: ProviderUsageDays.TokenBasis) -> Int {
        switch basis {
        case .eachOnce:
            return ArchiveTokenBasis.tokens(
                provider: entry.provider, inputTokens: entry.inputTokens,
                cachedTokens: entry.cachedTokens, outputTokens: entry.outputTokens)
        case .inputOutput:
            return plusSaturating(max(0, entry.inputTokens), max(0, entry.outputTokens))
        }
    }

    private static func plusSaturating(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
    }
}

// MARK: - What a list shows

/// One line of a project list, as it is shown.
public struct ProjectUsageLine: Sendable, Equatable, Identifiable {
    public let id: String
    /// The folder's name, "Unknown", or with "Hide personal information" on
    /// "Project N".
    public let title: String
    /// What hovering the line shows: the folder's full path, why a project
    /// is unknown, or nothing (Hide personal information on, or a folder
    /// whose path is not known).
    public let hoverText: String?
    /// The line's tokens with their unit, as the list counts them: "1.2M
    /// tokens", "1.2M I/O". What VoiceOver reads.
    public let tokensText: String
    /// The same figure without its unit, "1.2M", as the line shows it: the
    /// model rows beside it show bare figures too, and the list states the
    /// unit once (the panel's total, the Overview card's footnote).
    public let tokensFigure: String
    /// "$12.40", marked as a model's cost is; nil while costs are hidden
    /// (Settings › Display).
    public let costText: String?
    /// Why the cost is marked; empty when it is not.
    public let costHelp: String
    /// None of its tokens had a rate: its cost reads "No rate", drawn as a
    /// model's "No rate" is (secondary), not as a figure.
    public let hasNoRate: Bool
    public let isUnknown: Bool

    public init(
        id: String, title: String, hoverText: String?, tokensText: String, tokensFigure: String,
        costText: String?, costHelp: String, hasNoRate: Bool = false, isUnknown: Bool)
    {
        self.id = id
        self.title = title
        self.hoverText = hoverText
        self.tokensText = tokensText
        self.tokensFigure = tokensFigure
        self.costText = costText
        self.costHelp = costHelp
        self.hasNoRate = hasNoRate
        self.isUnknown = isUnknown
    }

    /// What VoiceOver reads for the line: "name, cost, tokens" with the
    /// tokens' unit, as a model row is read.
    public var accessibilityText: String {
        ([title] + (costText.map { [$0] } ?? []) + [tokensText]).joined(separator: ", ")
    }
}

/// A project list: the slide-out panel's for one provider, or the Mac
/// Overview's Top Projects for both.
public struct ProjectUsageList: Sendable, Equatable {
    public let lines: [ProjectUsageLine]
    /// How many projects had usage in the window: more than `lines.count`
    /// when the list is cut to `ProjectUsageRanking.shownCount`.
    public let projectCount: Int
    /// Whether the lines carry costs (Settings › Display): a card says its
    /// costs are estimates only when it shows some.
    public let showsCost: Bool
    /// Whether "Hide personal information" numbered the lines: a card then
    /// says how they are numbered (`L10n.projects.numberedHelp`).
    public let namesHidden: Bool

    public var isEmpty: Bool { lines.isEmpty }
    /// "Top 5 of 12 projects", or nil when every project is listed.
    public var shownOfText: String? {
        projectCount > lines.count ? L10n.projects.shownOf(lines.count, projectCount) : nil
    }

    public init(lines: [ProjectUsageLine], projectCount: Int, showsCost: Bool = true, namesHidden: Bool = false) {
        self.lines = lines
        self.projectCount = projectCount
        self.showsCost = showsCost
        self.namesHidden = namesHidden
    }

    /// The top projects of `entries` over the last `days` days.
    ///
    /// - Parameters:
    ///   - provider: one provider's projects; nil for every provider's.
    ///   - basis: how the lines count tokens, as the view beside them does.
    ///   - showsCost: whether costs are shown (Settings › Display); without
    ///     them the lines carry no cost and are ranked by tokens.
    ///   - hidePersonalInfo: the switch (`PersonalInfoMask`).
    public static func build(
        _ entries: [CostUsageScanResult.ProjectEntry],
        provider: String?,
        basis: ProviderUsageDays.TokenBasis,
        days: Int = ProjectUsageRanking.windowDays,
        todayKey: String,
        timeZone: TimeZone = .current,
        showsCost: Bool,
        hidePersonalInfo: Bool,
        limit: Int = ProjectUsageRanking.shownCount) -> ProjectUsageList
    {
        let all = ProjectUsageRanking.rows(
            entries, provider: provider, basis: basis, days: days, todayKey: todayKey, timeZone: timeZone,
            rankByCost: showsCost)
        let numbers = hidePersonalInfo
            ? ProjectUsageRanking.anonymousNumbers(
                entries, days: days, todayKey: todayKey, timeZone: timeZone, rankByCost: showsCost)
            : [:]
        let lines = all.prefix(max(0, limit)).map { row in
            ProjectUsageLine(
                id: row.project.key,
                title: PersonalInfoMask.projectTitle(
                    row.project, number: numbers[row.project.key], hidePersonalInfo: hidePersonalInfo),
                hoverText: row.project.isUnknown
                    ? L10n.projects.unknownHelp
                    : PersonalInfoMask.projectPath(row.project, hidePersonalInfo: hidePersonalInfo),
                tokensText: basis.tokensText(row.tokens),
                tokensFigure: CostFormatter.formatUsage(row.tokens),
                costText: showsCost ? row.costText : nil,
                costHelp: showsCost ? row.costHelp : "",
                hasNoRate: showsCost && row.hasNoRate,
                isUnknown: row.project.isUnknown)
        }
        return ProjectUsageList(
            lines: Array(lines), projectCount: all.count, showsCost: showsCost, namesHidden: hidePersonalInfo)
    }

    /// "This Mac · Last 30 days": where a list's figures come from. The
    /// projects are this Mac's alone, whatever the view beside them shows.
    public static func scopeText(days: Int = ProjectUsageRanking.windowDays) -> String {
        UsageDataScope.thisMac.label + " · " + L10n.providerPanel.lastDays(days)
    }

    /// How the Mac Overview's Top Projects counts tokens: input + output, as
    /// the Cost Summary directly above it counts its 30 days ("· 2.6M I/O
    /// tokens"), so no project reads more tokens than that total. Counting
    /// each token once, Claude's cache reads made one project's figure
    /// several times the total above it.
    public static let overviewBasis: ProviderUsageDays.TokenBasis = .inputOutput

    /// The Mac Overview's Top Projects: this Mac's top projects over the last
    /// 30 days, Codex and Claude together, in input + output tokens
    /// (`overviewBasis`). `OverviewTab` and the QA renders build it here.
    public static func overview(
        _ entries: [CostUsageScanResult.ProjectEntry],
        todayKey: String,
        timeZone: TimeZone = .current,
        showsCost: Bool,
        hidePersonalInfo: Bool) -> ProjectUsageList
    {
        build(
            entries, provider: nil, basis: overviewBasis, todayKey: todayKey, timeZone: timeZone,
            showsCost: showsCost, hidePersonalInfo: hidePersonalInfo)
    }

    /// What the Overview card's footnote says: what its tokens count (input
    /// + output, which part of input is cached depending on the provider),
    /// and, while costs are shown, that they are estimates, as the rest of
    /// the Overview labels its costs. Both are sentences the app already
    /// says elsewhere.
    public static func overviewFootnote(showsCost: Bool) -> String {
        showsCost
            ? L10n.providers.ioTokensHelp + " " + L10n.usageDashboard.costDisclaimer
            : L10n.providers.ioTokensHelp
    }

    /// Why a provider's projects are missing: the App Store build may not
    /// read its log folder on this Mac
    /// (`CostUsageScanner.logProvidersWithoutFolderAccess`), so the scan has
    /// none of its usage to split. nil when `provider` is not among
    /// `unreadable`. In the panel it stands where the Projects card would;
    /// on the Overview, under the card, for the first such provider.
    public static func folderNote(provider: String, unreadable: Set<String>) -> String? {
        unreadable.contains(provider) ? L10n.projects.folderBlocked(provider) : nil
    }

    /// The Overview's note: the first provider by name of `unreadable` the
    /// scan reads (Claude, Codex), or nil when it can read them all.
    public static func overviewFolderNote(unreadable: Set<String>) -> String? {
        unreadable.sorted().first.flatMap { folderNote(provider: $0, unreadable: unreadable) }
    }
}

// MARK: - Hide personal information

public extension PersonalInfoMask {

    /// What a project is called on screen: its folder's name, or "Unknown";
    /// with "Hide personal information" on, a named project is "Project N",
    /// `number` being its place among every project
    /// (`ProjectUsageRanking.anonymousNumbers`). An unknown project names
    /// nothing personal and keeps its name.
    static func projectTitle(_ project: ProjectIdentity, number: Int?, hidePersonalInfo: Bool) -> String {
        guard let name = project.name else { return L10n.projects.unknown }
        guard hidePersonalInfo else { return name }
        return L10n.projects.anonymous(number ?? 0)
    }

    /// The full path a project's line shows on hover: none with "Hide
    /// personal information" on, and none for a project whose folder is not
    /// known.
    static func projectPath(_ project: ProjectIdentity, hidePersonalInfo: Bool) -> String? {
        hidePersonalInfo ? nil : project.path
    }
}

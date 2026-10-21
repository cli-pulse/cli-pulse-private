#if os(macOS)
import Foundation

// v1.58 (P1-4): the scan's rows split by project (`ProjectUsage.swift`).
//
// Both caches already keep every log's own rows (`CostUsageFileUsage.days`),
// so a project's rows are the sum of its logs' rows: no log is read again for
// its usage. What each log needs is its folder:
//   * Codex: the rollout's first line, read once and kept in the cache entry
//     (`CostUsageFileUsage.project`). Only the logs whose rows count
//     (`CodexCopyResolver`) are added up, as the scan's own Codex rows are.
//   * Claude: the project directory the transcript sits under, and the folder
//     that directory was made from, looked up once per directory and kept in
//     the cache (`CostUsageCache.projectRoots`).
//
// Nothing here runs git, starts a process or looks at the folders themselves:
// a sandboxed app may do none of it, and the logs already say where each
// session ran.

extension CostUsageScanner {

    /// How many transcripts of one Claude project directory a refresh opens to
    /// find the folder the directory was made from, when no earlier refresh
    /// has. Nearly every transcript records it in its first lines. A
    /// directory none of whose chosen transcripts does is tried again on the
    /// next refresh with the same choice (the shallowest, newest first), so
    /// until a newer transcript records it, it keeps its decoded name
    /// (`humanReadableClaudeProject`); no older transcript is tried.
    static let claudeProjectLookupLimit = 3

    // MARK: - Codex

    /// The Codex logs whose rows count: `rebuildCodexDays` adds up exactly
    /// these.
    static func codexCountedPaths(_ cache: CostUsageCache) -> Set<String> {
        let candidates = cache.files.map { path, usage in
            CodexCopyResolver.File(
                path: path,
                rolloutId: usage.codex?.rolloutId,
                eventCount: usage.codex?.eventCount ?? 0,
                firstEventUnixMs: usage.codex?.firstEventUnixMs,
                lastEventUnixMs: usage.codex?.lastEventUnixMs,
                finalTokens: (usage.lastTotals?.input ?? 0) + (usage.lastTotals?.output ?? 0)
            )
        }
        return CodexCopyResolver.countedPaths(candidates)
    }

    /// What a session_meta line says about where the session ran: its `cwd`,
    /// and a hash of its repository's URL (never the URL).
    static func codexFileProject(sessionMeta line: [String: Any]) -> CostUsageFileProject {
        let payload = line["payload"] as? [String: Any]
        let cwd = (payload?["cwd"] as? String) ?? (line["cwd"] as? String)
        let git = payload?["git"] as? [String: Any]
        return CostUsageFileProject(
            cwd: cwd,
            repository: ProjectPathNormalizer.repositoryHash(git?["repository_url"] as? String))
    }

    /// What a log's first line, as `readCodexFirstLine` returned it, says
    /// about where the session ran. nil when the line is not there yet (still
    /// being written, or unreadable), so the question stays open; a first line
    /// that is no session_meta, or too long to read, answers "nowhere known".
    static func codexFileProject(firstLine: CodexFirstLine) -> CostUsageFileProject? {
        switch firstLine {
        case .line(let bytes):
            guard bytes.asciiContains(#""type":"session_meta""#),
                  let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  (object["type"] as? String) == "session_meta"
            else { return CostUsageFileProject(cwd: nil, repository: nil) }
            return codexFileProject(sessionMeta: object)
        case .tooLong:
            return CostUsageFileProject(cwd: nil, repository: nil)
        case .incomplete, .unreadable:
            return nil
        }
    }

    /// Gives each Codex entry without a `project` one, from one read of the
    /// log's first line: entries written before 1.58, which an unchanged or
    /// incrementally read log would otherwise never get. A first line not
    /// readable yet is left for the next refresh. Returns how many entries
    /// changed.
    @discardableResult
    static func fillCodexProjects(cache: inout CostUsageCache) -> Int {
        var filled = 0
        for (path, usage) in cache.files where usage.project == nil {
            guard let project = codexFileProject(firstLine: readCodexFirstLine(fileURL: URL(fileURLWithPath: path)))
            else { continue }
            var entry = usage
            entry.project = project
            cache.files[path] = entry
            filled += 1
        }
        return filled
    }

    /// The Codex rows of the reported days, by project.
    ///
    /// A log's folder is its `cwd` (`ProjectPathNormalizer.root`). A log that
    /// ran in a temporary folder (`ProjectPathNormalizer.isTemporary`) counts
    /// for the checkout it was copied from when the logs alone can tell which:
    /// the folder, not temporary, whose logs name the same repository (by its
    /// hash; the one with the most tokens when several do), or else, for a
    /// Codex worktree whose log names no repository, the one folder not
    /// temporary that has the worktree's folder name. A Codex worktree that
    /// matches neither is grouped with the other worktrees of that name;
    /// anything else temporary keeps a row of its own. Every folder that is
    /// not temporary (another git worktree, a subfolder of a checkout) is a
    /// project of its own.
    static func codexProjectEntries(
        cache: CostUsageCache, range: DayRange, home: String
    ) -> [CostUsageScanResult.ProjectEntry] {
        codexProjects(cache: cache, range: range, home: home).entries
    }

    /// What the Codex logs tell about temporary copies, for the Claude
    /// sessions that ran in the same ones (`claudeProjectEntries`): the
    /// checkout each temporary folder was counted for, and the folders not
    /// temporary, by name.
    struct CodexFolding: Equatable {
        var checkoutForTemporary: [String: String] = [:]
        var checkoutsByName: [String: Set<String>] = [:]
    }

    /// `codexProjectEntries`, and how it folded temporary folders.
    static func codexProjects(
        cache: CostUsageCache, range: DayRange, home: String
    ) -> (entries: [CostUsageScanResult.ProjectEntry], folding: CodexFolding) {
        struct Log {
            let root: String?
            let repository: String?
            let days: [String: [String: [Int]]]
            let tokens: Int
        }
        var logs: [Log] = []
        for path in codexCountedPaths(cache).sorted() {
            guard let usage = cache.files[path] else { continue }
            var days: [String: [String: [Int]]] = [:]
            var tokens = 0
            for (day, models) in usage.days
            where DayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey) {
                for (model, packed) in models {
                    let input = packed[safeIdx: 0] ?? 0
                    let cached = packed[safeIdx: 1] ?? 0
                    let output = packed[safeIdx: 2] ?? 0
                    // The same rows `entriesFromCodexCache` keeps.
                    guard input > 0 || cached > 0 || output > 0 else { continue }
                    days[day, default: [:]][model] = packed
                    tokens = plusSaturating(tokens, plusSaturating(max(0, input), max(0, output)))
                }
            }
            guard !days.isEmpty else { continue }
            let project = usage.project
                ?? codexFileProject(firstLine: readCodexFirstLine(fileURL: URL(fileURLWithPath: path)))
            logs.append(Log(
                root: ProjectPathNormalizer.root(project?.cwd, home: home),
                repository: project?.repository,
                days: days,
                tokens: tokens))
        }

        // The folders that are not temporary: by repository, with their
        // tokens, and by name.
        var checkoutsByRepository: [String: [String: Int]] = [:]
        var checkoutsByName: [String: Set<String>] = [:]
        for log in logs {
            guard let root = log.root, !ProjectPathNormalizer.isTemporary(root, home: home) else { continue }
            if let repository = log.repository {
                checkoutsByRepository[repository, default: [:]][root, default: 0] += log.tokens
            }
            checkoutsByName[ProjectPathNormalizer.name(of: root), default: []].insert(root)
        }
        let checkoutForRepository = checkoutsByRepository.compactMapValues(heaviest)

        func checkout(for log: Log, root: String) -> String? {
            if let repository = log.repository, let found = checkoutForRepository[repository] {
                return found
            }
            if log.repository == nil,
               let name = ProjectPathNormalizer.codexWorktreeRepository(root, home: home),
               let only = checkoutsByName[name], only.count == 1 {
                return only.first
            }
            return nil
        }

        // Codex worktrees that matched no checkout, by folder name: one row
        // for each name, shown under the path of the one with the most tokens.
        var worktreeWeights: [String: [String: Int]] = [:]
        for log in logs {
            guard let root = log.root, ProjectPathNormalizer.isTemporary(root, home: home),
                  checkout(for: log, root: root) == nil,
                  let name = ProjectPathNormalizer.codexWorktreeRepository(root, home: home)
            else { continue }
            worktreeWeights[name, default: [:]][root, default: 0] += log.tokens
        }

        func identity(_ log: Log) -> ProjectIdentity {
            guard let root = log.root else { return .unknown }
            guard ProjectPathNormalizer.isTemporary(root, home: home) else { return .folder(root) }
            if let found = checkout(for: log, root: root) { return .folder(found) }
            if let name = ProjectPathNormalizer.codexWorktreeRepository(root, home: home),
               let weights = worktreeWeights[name] {
                return .codexWorktrees(named: name, shownPath: heaviest(weights) ?? root, home: home)
            }
            return .folder(root)
        }

        var folding = CodexFolding(checkoutsByName: checkoutsByName)
        for log in logs {
            guard let root = log.root, ProjectPathNormalizer.isTemporary(root, home: home),
                  folding.checkoutForTemporary[root] == nil,
                  let found = checkout(for: log, root: root)
            else { continue }
            folding.checkoutForTemporary[root] = found
        }

        var rows: [ProjectIdentity: [String: [String: [Int]]]] = [:]
        for log in logs {
            let project = identity(log)
            for (day, models) in log.days {
                for (model, packed) in models {
                    let existing = rows[project]?[day]?[model] ?? []
                    rows[project, default: [:]][day, default: [:]][model] = addPacked(a: existing, b: packed, sign: 1)
                }
            }
        }
        var entries: [CostUsageScanResult.ProjectEntry] = []
        for (project, days) in rows {
            for (day, models) in days {
                for (model, packed) in models {
                    // Priced as `entriesFromCodexCache` prices the day's row:
                    // each request at its own time (slot 3), so the projects
                    // of a row add up to the row to the nanodollar.
                    entries.append(.init(
                        provider: "Codex", project: project, date: day, model: model,
                        inputTokens: packed[safeIdx: 0] ?? 0,
                        cachedTokens: packed[safeIdx: 1] ?? 0,
                        outputTokens: packed[safeIdx: 2] ?? 0,
                        costUSD: codexCost(model: model, packed: packed),
                        priceIsApproximate: Pricing.codexPriceResolution(model)?.isApproximate ?? false))
                }
            }
        }
        return (entries, folding)
    }

    /// The key of `weights` with the largest weight; the smaller key wins a
    /// tie, so the answer is the same on every run.
    private static func heaviest(_ weights: [String: Int]) -> String? {
        weights.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?.key
    }

    private static func plusSaturating(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
    }

    // MARK: - Claude

    /// Where Claude transcripts sit: each projects root under every spelling
    /// a path below it can have (`/var/…` and `/private/var/…`), so a
    /// transcript's directory is found by comparing text, without a file
    /// system call per transcript.
    struct ClaudeProjectPlaces {
        private let prefixes: [(prefix: String, root: URL)]
        private let roots: [URL]

        init(roots: [URL]) {
            self.roots = roots
            prefixes = roots.flatMap { root -> [(String, URL)] in
                var spellings = [root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
                for spelling in spellings where spelling.hasPrefix("/var/") { spellings.append("/private" + spelling) }
                for spelling in spellings where spelling.hasPrefix("/private/var/") {
                    spellings.append(String(spelling.dropFirst("/private".count)))
                }
                var seen: Set<String> = []
                return spellings.compactMap { spelling in
                    let prefix = spelling.hasSuffix("/") ? spelling : spelling + "/"
                    return seen.insert(prefix).inserted ? (prefix, root) : nil
                }
            }
        }

        /// The project directory a transcript at `path` sits under (the first
        /// directory below its projects root), how deep below the root it
        /// sits, and the root. nil for a transcript directly in a root.
        func place(_ path: String) -> (directory: String, depth: Int, root: URL)? {
            for (prefix, root) in prefixes where path.hasPrefix(prefix) {
                let relative = path.dropFirst(prefix.count).split(separator: "/")
                guard relative.count >= 2 else { return nil }
                return (String(relative[0]), relative.count, root)
            }
            for root in roots {
                if let relative = CostUsageScanner.claudeTranscriptPath(URL(fileURLWithPath: path), under: root) {
                    return (relative[0], relative.count, root)
                }
            }
            return nil
        }
    }

    /// Whether a Claude log has rows in the reported days.
    private static func claudeHasUsage(_ usage: CostUsageFileUsage, range: DayRange) -> Bool {
        usage.days.contains { day, models in
            DayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
                && models.keys.contains { $0 != claudeMsgBucketModel }
        }
    }

    /// Finds, for every Claude project directory with usage in the reported
    /// days that `cache.projectRoots` does not know yet, the folder it was
    /// made from, with the function the Sessions list names projects with
    /// (`claudeProjectAttribution`, P0-13): the session transcripts directly
    /// in the directory first, newest first, at most
    /// `claudeProjectLookupLimit` of them. Forgets directories that no
    /// longer hold a log in the cache. Returns whether `projectRoots` changed.
    @discardableResult
    static func learnClaudeProjectRoots(cache: inout CostUsageCache, roots: [URL], range: DayRange) -> Bool {
        struct Transcript {
            let path: String
            let root: URL
            let depth: Int
            let modified: Int64
        }
        let places = ClaudeProjectPlaces(roots: roots)
        var transcripts: [String: [Transcript]] = [:]   // directory → its transcripts with usage
        var present: Set<String> = []
        for (path, usage) in cache.files {
            guard let found = places.place(path) else { continue }
            present.insert(found.directory)
            guard claudeHasUsage(usage, range: range) else { continue }
            transcripts[found.directory, default: []].append(Transcript(
                path: path, root: found.root, depth: found.depth, modified: usage.mtimeUnixMs))
        }

        let before = cache.projectRoots ?? [:]
        var known = before.filter { present.contains($0.key) }
        for (directory, files) in transcripts where known[directory] == nil {
            let ordered = files.sorted {
                if $0.depth != $1.depth { return $0.depth < $1.depth }
                if $0.modified != $1.modified { return $0.modified > $1.modified }
                return $0.path < $1.path
            }
            for transcript in ordered.prefix(claudeProjectLookupLimit) {
                if let root = claudeProjectAttribution(
                    transcript: URL(fileURLWithPath: transcript.path), projectsRoot: transcript.root)?.root {
                    known[directory] = root
                    break
                }
            }
        }
        guard known != before else { return false }
        cache.projectRoots = known.isEmpty ? nil : known
        return true
    }

    /// The Claude rows of the reported days, by project.
    ///
    /// A transcript counts for the directory directly under the projects root
    /// it sits in, however deep (subagents and workflow runs sit below their
    /// session's), so a subagent counts for the project of the session that
    /// started it. The directory's folder is the one `learnClaudeProjectRoots`
    /// found; a directory none of whose transcripts recorded one is named
    /// after the directory, decoded (`humanReadableClaudeProject`), with no
    /// path. A transcript directly in a projects root, which Claude Code does
    /// not write, is "Unknown".
    ///
    /// A folder that is a temporary copy counts as Codex counts it
    /// (`codexFolding`): for the checkout Codex's logs of the same folder were
    /// counted for; else, a Codex worktree, for the one folder not temporary
    /// of the worktree's name among both providers' folders; else a Codex
    /// worktree joins the other worktrees of its name, and anything else
    /// temporary keeps a line of its own. So a repository Codex and Claude
    /// both worked on in a worktree is one line, not two of the same name.
    static func claudeProjectEntries(
        cache: CostUsageCache, roots: [URL], range: DayRange, home: String,
        codexFolding: CodexFolding = CodexFolding()
    ) -> [CostUsageScanResult.ProjectEntry] {
        let places = ClaudeProjectPlaces(roots: roots)
        let known = cache.projectRoots ?? [:]
        var identities: [String: ProjectIdentity] = [:]
        var checkoutsByName = codexFolding.checkoutsByName
        for recorded in known.values {
            let root = ProjectPathNormalizer.root(recorded, home: home) ?? recorded
            guard !ProjectPathNormalizer.isTemporary(root, home: home) else { continue }
            checkoutsByName[ProjectPathNormalizer.name(of: root), default: []].insert(root)
        }

        func identity(directory: String?) -> ProjectIdentity {
            guard let directory else { return .unknown }
            if let made = identities[directory] { return made }
            let made: ProjectIdentity
            if let recorded = known[directory] {
                let root = ProjectPathNormalizer.root(recorded, home: home) ?? recorded
                if !ProjectPathNormalizer.isTemporary(root, home: home) {
                    made = .folder(root)
                } else if let checkout = codexFolding.checkoutForTemporary[root] {
                    made = .folder(checkout)
                } else if let name = ProjectPathNormalizer.codexWorktreeRepository(root, home: home) {
                    if let only = checkoutsByName[name], only.count == 1, let checkout = only.first {
                        made = .folder(checkout)
                    } else {
                        made = .codexWorktrees(named: name, shownPath: root, home: home)
                    }
                } else {
                    made = .folder(root)
                }
            } else {
                made = ProjectIdentity(
                    key: "claude-directory:" + directory,
                    name: humanReadableClaudeProject(encodedDir: directory),
                    path: nil)
            }
            identities[directory] = made
            return made
        }

        var rows: [ProjectIdentity: [String: [String: [Int]]]] = [:]
        var totals: [String: [String: [Int]]] = [:]
        for (path, usage) in cache.files where claudeHasUsage(usage, range: range) {
            let project = identity(directory: places.place(path)?.directory)
            for (day, models) in usage.days
            where DayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey) {
                for (model, packed) in models where model != claudeMsgBucketModel {
                    let existing = rows[project]?[day]?[model] ?? []
                    rows[project, default: [:]][day, default: [:]][model] = addPacked(a: existing, b: packed, sign: 1)
                    totals[day, default: [:]][model] = addPacked(a: totals[day]?[model] ?? [], b: packed, sign: 1)
                }
            }
        }

        let costScale = 1_000_000_000.0
        var entries: [CostUsageScanResult.ProjectEntry] = []
        for (project, days) in rows {
            for (day, models) in days {
                for (model, packed) in models {
                    let input = packed[safeIdx: 0] ?? 0
                    let cacheRead = packed[safeIdx: 1] ?? 0
                    let cacheCreate = packed[safeIdx: 2] ?? 0
                    let output = packed[safeIdx: 3] ?? 0
                    let costNanos = packed[safeIdx: 4] ?? 0
                    guard input > 0 || cacheRead > 0 || cacheCreate > 0 || output > 0 else { continue }
                    // As `entriesFromClaudeCache` prices the day's row: its
                    // stored cost, or, when the whole row stored none, its
                    // tokens priced as a sum. With a stored cost each project
                    // takes its own stored share, which may be 0, so the
                    // projects of a row add up to the row.
                    let rowHasCost = (totals[day]?[model]?[safeIdx: 4] ?? 0) > 0
                    let cost: Double? = rowHasCost
                        ? Double(max(0, costNanos)) / costScale
                        : Pricing.claudeAggregateCostUSD(
                            model: model, inputTokens: input, cacheReadInputTokens: cacheRead,
                            cacheCreationInputTokens: cacheCreate, outputTokens: output)
                    entries.append(.init(
                        provider: "Claude", project: project, date: day, model: model,
                        inputTokens: input, cachedTokens: cacheRead + cacheCreate, outputTokens: output,
                        costUSD: cost,
                        priceIsApproximate: Pricing.claudePriceResolution(model)?.isApproximate ?? false))
                }
            }
        }
        return entries
    }
}
#endif

import Foundation

// v1.58 (P1-6): "Hide personal information" past account labels. With the
// switch on, no project's name, no folder path and no session's stored name
// reaches the screen or an export:
//
//   * Projects and the usage panel's Sessions list (this Mac's scan) name a
//     project "Project N" and show no path (`projectTitle`, `projectPath`,
//     ProjectUsage.swift).
//   * Everything else knows a project only by its folder's name: the Sessions
//     tab's rows and a session's detail (`SessionRecord.project`), an alert's
//     project (`AlertRecord.related_project_name`), and the exports. Such a
//     name is "Project N" when it is the name of exactly one of the folders
//     Projects numbers (`ProjectNameNumbers`), so "Project 2" is the same
//     folder in the Sessions tab as in Projects; any other name, a folder of
//     another device's, an older one or a name two folders share, is "Hidden
//     project".
//   * A session's stored name is never shown: it can be a command line with a
//     path in it (the Companion CLI writes the first 48 characters of one), and
//     a row's title is rebuilt from its provider and its project instead
//     (`sessionTitle`). An alert that names a session names its provider.
//   * A path that leads into the home folder starts with "~" instead
//     (`homeFolder`): the Sessions tab's diagnostics and the approval hook's
//     settings file.
//
// With the switch off everything shows as before. iPhone and Apple Watch read
// the same switch (the Watch the iPhone's): they have no scan, so a project
// they name is "Hidden project".
//
// `SessionRecord.displayName`, `displayProject`, `detailProject` and
// `AlertPresentation.text(for:)` are internal to CLIPulseCore: an app target
// cannot show a session's or an alert's text except through these functions.
// scripts/check_personal_info_mask.py checks the stored fields the apps can
// still read.

/// The number "Project N" gives a project that a surface knows only by its
/// folder's name.
public struct ProjectNameNumbers: Sendable, Equatable {
    /// No numbers: with the switch on, every named project is "Hidden
    /// project". What a device without a scan (iPhone, Apple Watch) has, and
    /// what there is to know with the switch off.
    public static let none = ProjectNameNumbers(numbersByName: [:])

    /// Folder name → its number in Projects.
    public let numbersByName: [String: Int]

    public init(numbersByName: [String: Int]) {
        self.numbersByName = numbersByName
    }

    /// The numbers Projects gives this Mac's projects
    /// (`ProjectUsageRanking.anonymousNumbers`, ranked by cost while costs
    /// are shown and by tokens while they are hidden, over the 30 days ending
    /// at `todayKey`), by folder name, for the names exactly one folder of
    /// the scan has. A name two folders share (two checkouts called `app`)
    /// says nothing about which of them a session ran in, so it gets no
    /// number.
    public static func scan(
        _ entries: [CostUsageScanResult.ProjectEntry],
        todayKey: String,
        timeZone: TimeZone = .current,
        rankByCost: Bool
    ) -> ProjectNameNumbers {
        let numbers = ProjectUsageRanking.anonymousNumbers(
            entries, todayKey: todayKey, timeZone: timeZone, rankByCost: rankByCost)
        guard !numbers.isEmpty else { return .none }
        var keysByName: [String: Set<String>] = [:]
        for entry in entries {
            guard let name = entry.project.name else { continue }
            keysByName[name, default: []].insert(entry.project.key)
        }
        var byName: [String: Int] = [:]
        for (name, keys) in keysByName where keys.count == 1 {
            if let key = keys.first, let number = numbers[key] {
                byName[name] = number
            }
        }
        return ProjectNameNumbers(numbersByName: byName)
    }

    /// The number of the folder called `name`, or nil.
    public func number(forName name: String) -> Int? {
        numbersByName[name]
    }
}

public extension PersonalInfoMask {

    // MARK: - Projects known by name

    /// A project a surface knows only by its folder's name (a session row, an
    /// alert, an export), or nil when there is none: with the switch off the
    /// name, with it on "Project N" (`numbers`) or "Hidden project".
    static func projectName(
        _ name: String?,
        numbers: ProjectNameNumbers,
        hidePersonalInfo: Bool
    ) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard hidePersonalInfo else { return trimmed }
        if let number = numbers.number(forName: trimmed) {
            return L10n.projects.anonymous(number)
        }
        return L10n.projects.hidden
    }

    // MARK: - Sessions

    /// A session row's title. With the switch off, `SessionRecord.displayName`
    /// ("Codex · cli-pulse-ios" for a scan row, the stored name for others).
    /// With it on, never the stored name: a scan row is its provider and its
    /// masked project ("Codex · Project 2"), or "Codex process" without one;
    /// any other row is "Codex session".
    static func sessionTitle(
        _ session: SessionRecord,
        numbers: ProjectNameNumbers,
        hidePersonalInfo: Bool
    ) -> String {
        guard hidePersonalInfo else { return session.displayName }
        guard session.isProcessScanRow else {
            return L10n.sessions.rowFallbackLabel(session.provider)
        }
        if let project = sessionProject(session, numbers: numbers, hidePersonalInfo: true) {
            return "\(session.provider) · \(project)"
        }
        return L10n.sessions.rowProcessLabel(session.provider)
    }

    /// The project under a session's title, or nil when there is none to show
    /// (`SessionRecord.displayProject`), masked by `projectName`.
    static func sessionProject(
        _ session: SessionRecord,
        numbers: ProjectNameNumbers,
        hidePersonalInfo: Bool
    ) -> String? {
        projectName(session.displayProject, numbers: numbers, hidePersonalInfo: hidePersonalInfo)
    }

    /// A session detail's Project field, and the documents' (the cost report
    /// and the PDF): `sessionProject`, or "Unknown" in the reader's language.
    static func sessionDetailProject(
        _ session: SessionRecord,
        numbers: ProjectNameNumbers,
        hidePersonalInfo: Bool
    ) -> String {
        sessionProject(session, numbers: numbers, hidePersonalInfo: hidePersonalInfo) ?? L10n.status.unknown
    }

    // MARK: - Alerts

    /// An alert's title and message in the reader's language
    /// (`AlertPresentation`). With the switch on, a session the alert names
    /// is its provider ("Codex is consuming high CPU": the stored name can be
    /// a command line), and a project is masked by `projectName`; in an alert
    /// no template recognises, the stored English, with the session's stored
    /// name and the project's replaced the same way wherever they occur.
    static func alertText(
        _ alert: AlertRecord,
        numbers: ProjectNameNumbers,
        hidePersonalInfo: Bool
    ) -> AlertPresentation.Text {
        guard hidePersonalInfo else { return AlertPresentation.text(for: alert) }
        let naming = AlertPresentation.Naming(
            session: { _, provider in alertSessionStandIn(alert, provider: provider) },
            project: { projectName($0, numbers: numbers, hidePersonalInfo: true) ?? $0 })
        let shown = AlertPresentation.text(for: alert, naming: naming)
        guard !shown.recognized else { return shown }
        return AlertPresentation.Text(
            title: maskedStoredText(shown.title, of: alert, numbers: numbers),
            message: maskedStoredText(shown.message, of: alert, numbers: numbers),
            recognized: false)
    }

    /// The project an alert names, for its chip, or nil when it names none.
    static func alertProject(
        _ alert: AlertRecord,
        numbers: ProjectNameNumbers,
        hidePersonalInfo: Bool
    ) -> String? {
        projectName(alert.related_project_name, numbers: numbers, hidePersonalInfo: hidePersonalInfo)
    }

    /// The session an alert names, for its chip, or nil when it names none:
    /// the stored name, or with the switch on "Session" (the chip still says
    /// which kind of thing the alert is about, and on iPhone still opens the
    /// Sessions tab).
    static func alertSessionName(
        _ alert: AlertRecord,
        hidePersonalInfo: Bool
    ) -> String? {
        guard let name = alert.related_session_name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return hidePersonalInfo ? L10n.alertKind.sourceSession : name
    }

    /// The stored English of an alert with its personal parts replaced, for
    /// the alerts export (a data file, so not translated): the session's
    /// stored name by its provider, the project by `projectName`.
    static func alertStoredText(
        _ alert: AlertRecord,
        numbers: ProjectNameNumbers,
        hidePersonalInfo: Bool
    ) -> (title: String, message: String) {
        guard hidePersonalInfo else { return (alert.title, alert.message) }
        return (maskedStoredText(alert.title, of: alert, numbers: numbers),
                maskedStoredText(alert.message, of: alert, numbers: numbers))
    }

    /// What an alert's session is called with the switch on: its provider,
    /// as the alert's template or `related_provider` names it, or "Session".
    private static func alertSessionStandIn(_ alert: AlertRecord, provider: String?) -> String {
        for candidate in [alert.related_provider, provider] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return L10n.alertKind.sourceSession
    }

    /// `text` with every occurrence of the alert's session name and project
    /// name replaced (the longer first, so a name inside the other is not
    /// split). A value shorter than two characters is left alone: replacing
    /// it would rewrite ordinary words.
    private static func maskedStoredText(_ text: String, of alert: AlertRecord, numbers: ProjectNameNumbers) -> String {
        var replacements: [(String, String)] = []
        if let session = alert.related_session_name?.trimmingCharacters(in: .whitespacesAndNewlines),
           session.count >= 2 {
            replacements.append((session, alertSessionStandIn(alert, provider: nil)))
        }
        if let project = alert.related_project_name?.trimmingCharacters(in: .whitespacesAndNewlines),
           project.count >= 2,
           let shown = projectName(project, numbers: numbers, hidePersonalInfo: true) {
            replacements.append((project, shown))
        }
        var result = text
        for (from, to) in replacements.sorted(by: { $0.0.count > $1.0.count }) {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    // MARK: - Paths

    /// `text` with the home folder spelled "~" wherever a path into it
    /// starts (`/Users/name/.claude/settings.json` → `~/.claude/settings.json`),
    /// with the switch on; as it is with the switch off. For the few places
    /// that show a path the app works with rather than a project's (the
    /// Sessions tab's diagnostics, the approval hook's settings file): the
    /// account's short name is in every such path.
    static func homeFolder(
        in text: String,
        hidePersonalInfo: Bool,
        home: String? = nil
    ) -> String {
        guard hidePersonalInfo else { return text }
        #if os(macOS)
        var folder = home ?? realUserHome()
        #else
        var folder = home ?? NSHomeDirectory()
        #endif
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        guard folder.count > 1 else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: folder) {
            let after = rest[range.upperBound...]
            // Only the whole folder: "/Users/sample" and "/Users/sample/…",
            // not "/Users/samples".
            let continuesName = after.first.map { $0.isLetter || $0.isNumber || "-_.".contains($0) } ?? false
            result += continuesName ? rest[..<range.upperBound] : rest[..<range.lowerBound] + "~"
            rest = after
        }
        return result + rest
    }
}

public extension AppState {

    /// The numbers the Sessions tab, Alerts and the exports give the
    /// projects they name (`ProjectNameNumbers.scan`): Projects' numbers over
    /// this Mac's last 30 days, ranked as Projects ranks them with costs
    /// shown or hidden. `.none` with the switch off (nothing is masked, so
    /// nothing is numbered) and on a device without a scan.
    func projectNameNumbers(hidePersonalInfo: Bool, now: Date = Date()) -> ProjectNameNumbers {
        guard hidePersonalInfo, let projects = costUsageScanResult?.projects, !projects.isEmpty else {
            return .none
        }
        return .scan(projects, todayKey: DayKey.string(from: now), rankByCost: showCost)
    }
}

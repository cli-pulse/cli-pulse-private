import Foundation

// v1.58 (P1-6): what the QA renders with "Hide personal information" on
// (`hide-personal-info-*`) put in, and how the renderer checks what they
// show. There is no UI test target and no OCR: the renderer reads back the
// text of what it drew (the accessibility tree of the drawn view, which holds
// every label, value and hover text, or the file an export wrote) and looks
// for every project name, folder path and session name of the data it drew.
// It reads the same surface with the switch off first, as the control: a
// check that finds nothing then could not have found a leak either.
//
// Every name and path here is invented.

public extension QARenderSnapshot {

    /// Sessions only the privacy renders put in, beside Demo's and the log
    /// sessions (`logSessionsSample`): rows other devices sync whose stored
    /// names carry a path, which the Sessions tab, the alerts and the
    /// sessions export showed with the switch off.
    ///   * The Companion CLI on another Mac: a process-scan row whose stored
    ///     name is the start of a command line (the Companion writes the
    ///     first 48 characters of one). The row's title is its provider and
    ///     project; the name is in the sessions export and its alert.
    ///   * A row a client wrote under an id that is neither a scan's nor a
    ///     log's, whose title is its stored name, here a command line with a
    ///     path in it.
    static func privacySessionsSample(now: Date) -> [SessionRecord] {
        let formatter = ISO8601DateFormatter()
        func at(_ ago: TimeInterval) -> String { formatter.string(from: now.addingTimeInterval(-ago)) }
        return [
            SessionRecord(
                id: "proc-7311", name: privacyCommandLine, provider: "Claude", project: "sample-service",
                device_name: "build-box", started_at: at(5_400), last_active_at: at(60), status: "Running",
                total_usage: 41_000, estimated_cost: 0, cost_status: "Estimated", requests: 120, error_count: 0),
            SessionRecord(
                id: "6c1d2e3f-qa-cloud", name: "codex exec --cd /Users/sample/Projects/demo-app",
                provider: "Codex", project: "demo-app", device_name: "build-box",
                started_at: at(2_400), last_active_at: at(180), status: "Running",
                total_usage: 88_000, estimated_cost: 0.21, cost_status: "Estimated", requests: 9, error_count: 0),
        ]
    }

    /// The Companion CLI's name for `proc-7311`: the first 48 characters of
    /// its command line.
    static let privacyCommandLine = "/Users/sample/.local/bin/claude --resume 1f2e3d4c"

    /// Alerts only the privacy renders put in, beside Demo's: the session
    /// CPU alert as the Companion CLI raises it for `proc-7311` (its title
    /// is the stored name, a command line) and as the desktop app raises it
    /// (its message names the project). Real producer templates
    /// (`AlertPresentation`).
    static func privacyAlertsSample(now: Date) -> [AlertRecord] {
        let formatter = ISO8601DateFormatter()
        func at(_ ago: TimeInterval) -> String { formatter.string(from: now.addingTimeInterval(-ago)) }
        return [
            AlertRecord(
                id: "session-spike-proc-7311", type: "Usage Spike", severity: "Warning",
                title: "\(privacyCommandLine) is consuming high CPU",
                message: "Process CPU is 85.0% for Claude.",
                created_at: at(600), is_read: false, is_resolved: false, acknowledged_at: nil,
                snoozed_until: nil, related_project_id: nil, related_project_name: "sample-service",
                related_session_id: "proc-7311", related_session_name: privacyCommandLine,
                related_provider: "Claude", related_device_name: "build-box", source_kind: "session",
                source_id: nil, grouping_key: "Usage Spike:Claude", suppression_key: "Usage Spike:proc-7311"),
            AlertRecord(
                id: "session-spike-proc-8840", type: "Usage Spike", severity: "Warning",
                title: "codex-demo-app is consuming high CPU",
                message: "Process CPU is 72.5% for Codex in demo-app.",
                created_at: at(1_500), is_read: true, is_resolved: false, acknowledged_at: nil,
                snoozed_until: nil, related_project_id: nil, related_project_name: "demo-app",
                related_session_id: "proc-8840", related_session_name: "codex-demo-app",
                related_provider: "Codex", related_device_name: "build-box", source_kind: "session",
                source_id: nil, grouping_key: "Usage Spike:Codex", suppression_key: "Usage Spike:proc-8840"),
        ]
    }

    /// Every personal string a surface drawn from these records could show:
    /// each session's project and stored name, each alert's project and
    /// session name, each project's folder name and path, and "/Users/", the
    /// start of any home folder path. Left out: a producer's placeholder
    /// project ("unknown"), the name the scanner gives a log session ("Claude
    /// session", the app's own words), a name that is a provider's ("claude",
    /// a process's name, shows inside model names), and anything shorter than
    /// four characters. Sorted, without duplicates.
    static func personalStrings(
        sessions: [SessionRecord],
        alerts: [AlertRecord],
        projects: [ProjectIdentity]
    ) -> [String] {
        let providers = Set(ProviderKind.allCases.map { $0.rawValue.lowercased() })
        var found: Set<String> = ["/Users/"]
        func add(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.count >= 4, !providers.contains(value.lowercased())
            else { return }
            found.insert(value)
        }
        for session in sessions {
            add(session.displayProject)
            if session.name != SessionRecord.jsonlSessionName(provider: session.provider) {
                add(session.name)
            }
        }
        for alert in alerts {
            add(alert.related_project_name)
            add(alert.related_session_name)
        }
        for project in projects {
            add(project.name)
            add(project.path)
        }
        return found.sorted()
    }

    /// The check of one `hide-personal-info-*` surface: which of `needles`
    /// its text showed with the switch on (`textsOn`) and off (`textsOff`,
    /// the control). Case-sensitive substrings: a name inside a longer line
    /// counts.
    static func privacyCheck(
        id: String,
        source: String,
        needles: [String],
        textsOn: [String],
        textsOff: [String]
    ) -> QARenderManifest.PrivacyCheck {
        func shown(_ texts: [String]) -> [String] {
            needles.filter { needle in texts.contains { $0.contains(needle) } }
        }
        return QARenderManifest.PrivacyCheck(
            id: id, source: source, textsRead: textsOn.count, lookedFor: needles.count,
            shownWithSwitchOff: shown(textsOff), leaks: shown(textsOn))
    }

    /// A failed check, for the run's warnings; nil when it passed.
    static func privacyProblem(_ check: QARenderManifest.PrivacyCheck) -> String? {
        if check.textsRead == 0 {
            return "privacy: \(check.id) (\(check.source)): no text was read with the switch on"
        }
        if check.shownWithSwitchOff.isEmpty {
            return "privacy: \(check.id) (\(check.source)): the control showed none of the \(check.lookedFor)"
                + " personal strings with the switch off, so the check could not have seen a leak"
        }
        if !check.leaks.isEmpty {
            return "privacy: \(check.id) (\(check.source)) shows with the switch on: "
                + check.leaks.joined(separator: ", ")
        }
        return nil
    }
}

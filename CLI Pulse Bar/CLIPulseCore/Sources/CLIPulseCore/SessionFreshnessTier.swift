import Foundation

/// Tier classification for the macOS / iOS Sessions tab Active vs
/// Recent split. Replaces the binary 300s "fresh or drop" decision
/// in `SessionFreshnessFilter.filterCurrent` with a richer
/// 4-state model so the UI can show:
///
///   * **Active** section — process-confirmed sessions whose helper
///     is still emitting them, plus JSONL-only sessions whose JSONL
///     mtime is within the last 5 min.
///   * **Recent** section — JSONL-only sessions whose JSONL mtime
///     is between 5 min and 30 min old.
///   * Hidden — anything older, plus helper / process-path
///     artifacts that should never appear in Sessions.
///
/// Evidence axis:
///   * Process-scan rows (`SessionRecord.isProcessScanRow`): `local-{pid}`
///     from `LocalScanner` (the Developer ID app's own scan, and the
///     LoginItem helper's upload), `proc-{pid}` from the Companion CLI
///     (`helper/system_collector.py`'s ps-based `collect_sessions()`) and
///     the desktop app. Their `last_active_at` is the time of the scan that
///     saw the process, rewritten every producer cycle, so a stale scan row
///     is genuinely stale (producer offline or the process just died).
///   * `jsonl-…` ids come from `CostUsageScanner.synthesizeSessions`
///     reading provider JSONL mtimes — no live-process check.
///   * Rows with neither prefix fall through to the JSONL age tiers. No
///     producer uploads one today: every session in the cloud is a scan row.
///
/// Process confirmation is the "Running" tier; a scan row past its window is
/// hidden, not demoted to Recent, which the legend defines as a log written
/// in the last 30 minutes. The window covers a producer's cycle plus the
/// app's refresh, so a healthy producer always keeps its sessions Running.
public enum FreshnessTier: String, Sendable, Equatable, CaseIterable {
    case activeProcess
    case activeJsonl
    case recentJsonl
    case hidden

    /// True iff the tier should appear in either UI section.
    public var isVisible: Bool { self != .hidden }

    /// Section assignment for the UI split.
    public var section: Section {
        switch self {
        case .activeProcess, .activeJsonl: return .active
        case .recentJsonl: return .recent
        case .hidden: return .hidden
        }
    }

    public enum Section: String, Sendable, Equatable {
        case active
        case recent
        case hidden
    }

    /// Short user-visible label for the row badge. Kept short so it
    /// fits in a small `StatusBadge`-style chip.
    public var badge: String {
        switch self {
        case .activeProcess: return L10n.sessions.running
        case .activeJsonl:   return L10n.sessions.tierBadgeRecentActivity
        case .recentJsonl:   return L10n.sessions.tierBadgeRecent
        case .hidden:        return ""
        }
    }
}

/// Pure tier classifier. Same input as `SessionFreshnessFilter.filterCurrent`,
/// richer output. The `.hidden` case is the union of (a) process-path
/// artifact rows, (b) sessions whose `last_active_at` exceeds the
/// recent-JSONL window — i.e. exactly the rows `filterCurrent` would
/// drop, so behavior remains backward-compatible at the filter contract.
public enum SessionFreshnessTierClassifier {
    /// How often each producer of scan rows rewrites them by default, each
    /// time with `last_active_at` = the scan's time: the LoginItem helper
    /// (`HelperDaemon.syncInterval`, 120 s unless the app group sets 60 s or
    /// more), the Companion CLI (`daemon --interval`, default 120, at least
    /// 60) and the desktop app (a 120 s sync tick on AC power).
    public static let scanRowRewriteInterval: TimeInterval = 120

    /// Process-confirmed rows stay Active ("Running") for this long after
    /// the scan that last saw them. A live row is up to one rewrite old when
    /// a refresh reads it, and the tab goes on drawing it until the next
    /// refresh, by default two minutes later (`AppState.refreshInterval`):
    /// up to 240 s. A minute more covers a late upload. That is 300 s, the
    /// window `SessionFreshnessFilter.filterCurrent` keeps a row for, so a
    /// row its producer rewrote on its normal cycle reads Running until the
    /// next refresh. (A row the refresh lists at 181–300 s old, from a
    /// producer that missed a cycle, can be hidden before then: the tab
    /// classifies again as it draws.)
    ///
    /// It was 180 s, for a helper heartbeat of 60 s that no producer has: on
    /// the default cadences a live process dropped out of the list between
    /// two refreshes.
    public static let processFreshnessWindow: TimeInterval = 2 * scanRowRewriteInterval + 60

    /// JSONL-only rows newer than this are Active. Matches the
    /// existing `SessionFreshnessFilter.freshnessWindow` (300 s) so
    /// the cloud-route filter contract is preserved.
    public static let jsonlActiveWindow: TimeInterval = 300

    /// JSONL-only rows newer than this are Recent (and visible).
    /// Above this they're hidden.
    public static let jsonlRecentWindow: TimeInterval = 1800

    /// Returns the tier the session should occupy.
    public static func classify(_ session: SessionRecord, now: Date) -> FreshnessTier {
        // Helper-emitted process-path artifacts are never visible.
        if SessionFreshnessFilter.isProcessPathArtifact(session) {
            return .hidden
        }
        guard let lastActive = session.lastActiveDate else { return .hidden }
        let age = now.timeIntervalSince(lastActive)
        if age < 0 { return .hidden }    // future timestamp = bad clock data, drop

        // Process-confirmed sessions: `local-<pid>` (LocalScanner) and
        // `proc-<pid>` (the Companion CLI, the desktop app). Testing one
        // prefix left the other "Recent activity" and out of "N running".
        if session.isProcessScanRow {
            return age <= processFreshnessWindow ? .activeProcess : .hidden
        }

        // JSONL-synthesized sessions (`jsonl-…` ids from
        // CostUsageScanner) and any row without a scan prefix fall
        // through to the age-tier rules.
        if age <= jsonlActiveWindow { return .activeJsonl }
        if age <= jsonlRecentWindow { return .recentJsonl }
        return .hidden
    }

    /// Bin a session list into the two visible sections, dropping
    /// hidden rows. Both buckets are sorted most-recently-active
    /// first so the UI doesn't need a second sort.
    public static func partition(
        _ sessions: [SessionRecord],
        now: Date
    ) -> (active: [SessionRecord], recent: [SessionRecord]) {
        var active: [SessionRecord] = []
        var recent: [SessionRecord] = []
        for s in sessions {
            switch classify(s, now: now).section {
            case .active: active.append(s)
            case .recent: recent.append(s)
            case .hidden: break
            }
        }
        // Use the robust shared parser — same fractional-second
        // tolerance fix as in SessionFreshnessFilter.merge sort.
        let order: (SessionRecord, SessionRecord) -> Bool = { lhs, rhs in
            let l = sharedISO8601Parse(lhs.last_active_at) ?? .distantPast
            let r = sharedISO8601Parse(rhs.last_active_at) ?? .distantPast
            return l > r
        }
        return (active.sorted(by: order), recent.sorted(by: order))
    }
}

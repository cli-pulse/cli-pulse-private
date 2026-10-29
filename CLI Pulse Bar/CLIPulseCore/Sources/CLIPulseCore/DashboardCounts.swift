import Foundation

/// 1.60 (59-05): the two counts the Overview, the exports, the widgets, Siri
/// and the Watch show, counted on the device from the rows it holds, at the
/// moment they are shown.
///
/// They read `dashboard_summary`'s `active_sessions` and `online_devices`,
/// figures fixed at the last refresh. Before the server's v0.87 those counted
/// every row marked Running or Online with no time window, so a Mac that went
/// to sleep with AI tools open left its sessions counted for days, and every
/// device ever paired read Online. v0.87 gave both a window, but a figure taken
/// at a refresh still goes on being drawn after the window it was counted in
/// has passed: a widget published with one session showed it for as long as
/// the widget lived. The Mac also raised the server's figure to the rows it
/// listed and never lowered it.
///
/// So the figures are counted here, against the time they are drawn for:
///
/// * Active sessions: the rows the Sessions tab lists under Active
///   (`SessionListCount`, `SessionFreshnessTierClassifier`), so the tile and
///   the tab never disagree.
/// * Online devices: a device whose stored status is Online and that was last
///   seen within `deviceOnlineGrace`, the window `dashboard_summary` uses
///   since v0.87.
///
/// `DashboardCountsSourceScanTests` holds every read of the dashboard's own
/// two figures to an allowlist.
public struct DashboardCounts: Equatable, Sendable {
    public let activeSessions: Int
    public let onlineDevices: Int

    public init(activeSessions: Int, onlineDevices: Int) {
        self.activeSessions = activeSessions
        self.onlineDevices = onlineDevices
    }

    /// The counts of these rows at `now`.
    public init(sessions: [SessionRecord], devices: [DeviceRecord], now: Date) {
        self.init(
            activeSessions: Self.activeSessions(sessions, now: now),
            onlineDevices: Self.onlineDevices(devices, now: now)
        )
    }

    // MARK: - Sessions

    /// How long a session row counts after its `last_active_at`. Both kinds of
    /// row the Active section lists (a process-scan row, `activeProcess`, and
    /// a row known only from its log, `activeJsonl`) stay there this long, so
    /// one window recounts either from its time alone.
    /// `testOneWindowRecountsEveryActiveTier` keeps the two equal.
    public static let sessionActiveWindow: TimeInterval = SessionFreshnessTierClassifier.processFreshnessWindow

    /// The sessions the Sessions tab lists under Active at `now`.
    public static func activeSessions(_ sessions: [SessionRecord], now: Date) -> Int {
        SessionListCount.active(sessions, now: now)
    }

    /// The `last_active_at` of each session counted at `now`, oldest first:
    /// what the widget payload carries so a widget or Siri can count again
    /// at the time it shows the figure.
    public static func activeSessionTimes(_ sessions: [SessionRecord], now: Date) -> [Date] {
        sessions.compactMap { session -> Date? in
            guard SessionFreshnessTierClassifier.classify(session, now: now).section == .active else { return nil }
            return session.lastActiveDate
        }.sorted()
    }

    /// The sessions among `lastActiveAt` still counted at `now`: active no
    /// more than `sessionActiveWindow` before it, and not after it.
    public static func activeSessions(lastActiveAt: [Date], now: Date) -> Int {
        lastActiveAt.reduce(0) { count, time in
            let age = now.timeIntervalSince(time)
            return count + (age >= 0 && age <= sessionActiveWindow ? 1 : 0)
        }
    }

    /// The moments after `now`, up to `end`, at which the count of
    /// `lastActiveAt` drops: a second after each time leaves the window,
    /// oldest first. A widget puts a timeline entry at each, so the figure it
    /// shows falls when the session stops counting, not at its next
    /// five-minute entry.
    public static func countDrops(lastActiveAt: [Date]?, after now: Date, until end: Date) -> [Date] {
        let drops = (lastActiveAt ?? []).map { $0.addingTimeInterval(sessionActiveWindow + 1) }
        return Array(Set(drops.filter { $0 > now && $0 <= end })).sorted()
    }

    /// The figure a widget or Siri shows at `now`: counted again from the
    /// times the app published, or, when it published none (a payload from
    /// before 1.60, or Demo, which never refreshes), the figure it published.
    public static func activeSessions(published: Int, lastActiveAt: [Date]?, now: Date) -> Int {
        guard let lastActiveAt else { return published }
        return activeSessions(lastActiveAt: lastActiveAt, now: now)
    }

    // MARK: - Devices

    /// A device counts as online for this long after it was last seen: twice
    /// the longest interval any producer writes `devices.last_seen_at` at
    /// (the desktop app on low battery, 900 s). `dashboard_summary` uses the
    /// same 1800 s since v0.87 (`migrate_v0.87_retention_cleanup_and_fresh_counts.sql`).
    public static let deviceOnlineGrace: TimeInterval = 1800

    /// Whether a device with this stored status, last seen at `lastSeenAt`
    /// (ISO 8601), is online at `now`. The cloud stores "Online"; this Mac's
    /// own row in local mode reads "online".
    public static func isOnline(status: String, lastSeenAt: String?, now: Date) -> Bool {
        guard status.caseInsensitiveCompare(DeviceStatus.online.rawValue) == .orderedSame,
              let seen = sharedISO8601Parse(lastSeenAt ?? "") else { return false }
        return now.timeIntervalSince(seen) <= deviceOnlineGrace
    }

    public static func isOnline(_ device: DeviceRecord, now: Date) -> Bool {
        isOnline(status: device.status, lastSeenAt: device.last_sync_at, now: now)
    }

    public static func onlineDevices(_ devices: [DeviceRecord], now: Date) -> Int {
        devices.reduce(0) { $0 + (isOnline($1, now: now) ? 1 : 0) }
    }

    /// The status a device list shows: the stored one, except that a device
    /// stored as Online but not seen within the grace reads Offline. The cloud
    /// never writes another status (`DemoDataProvider`'s devices say why), so
    /// without this every device ever paired read Online.
    public static func displayStatus(status: String, lastSeenAt: String?, now: Date) -> String {
        guard status.caseInsensitiveCompare(DeviceStatus.online.rawValue) == .orderedSame else { return status }
        return isOnline(status: status, lastSeenAt: lastSeenAt, now: now) ? status : DeviceStatus.offline.rawValue
    }
}

public extension DeviceRecord {
    /// `DashboardCounts.isOnline`.
    func isOnline(now: Date) -> Bool { DashboardCounts.isOnline(self, now: now) }
}

public extension WatchDeviceSummary {
    /// `DashboardCounts.isOnline`. An iPhone from before 1.60 sends no
    /// `lastSyncAt`; the stored status then stands, as it did.
    func isOnline(now: Date) -> Bool {
        guard lastSyncAt != nil else { return deviceStatus == .online }
        return DashboardCounts.isOnline(status: status, lastSeenAt: lastSyncAt, now: now)
    }

    /// `DashboardCounts.displayStatus`, with the same fallback.
    func displayStatus(now: Date) -> String {
        guard lastSyncAt != nil else { return status }
        return DashboardCounts.displayStatus(status: status, lastSeenAt: lastSyncAt, now: now)
    }
}

/// The moment session rows are classified against: now, and in Demo the
/// moment its one refresh is shown at (its refresh plus
/// `DemoDataProvider.refreshAge`). `AppState.sessionsClock` and the Watch's.
public enum SessionsClock {
    public static func at(_ now: Date, demoRefresh: Date?) -> Date {
        guard let demoRefresh else { return now }
        return min(now, demoRefresh.addingTimeInterval(DemoDataProvider.refreshAge))
    }
}

public extension AppState {
    /// The two counts at `sessionsClock()` (or `now`), from this state's rows.
    func dashboardCounts(now: Date? = nil) -> DashboardCounts {
        DashboardCounts(sessions: sessions, devices: devices, now: now ?? sessionsClock())
    }
}

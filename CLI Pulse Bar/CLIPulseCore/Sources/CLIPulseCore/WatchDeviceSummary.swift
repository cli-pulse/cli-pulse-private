// WatchDeviceSummary.swift — v1.41 "Mobile Machine", watch side (PR-7).
//
// A TRIMMED, read-only device-health record for the watch: only the fields the
// glance card + drill-in render, so the phone→watch WatchConnectivity context
// stays small (updateApplicationContext has a ~256 KB ceiling) and the watch
// never carries the control-plane fields (machine_controls, fan target, etc. —
// the watch has no controls, by design). Codable both ways with the default
// camelCase keys (this is internal WC serialization, not the snake_case REST
// wire), so the phone encodes and the watch decodes the same type.

import Foundation

public struct WatchDeviceSummary: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let status: String
    public let cpuUsage: Int?
    public let memoryUsage: Int?
    public let cpuTempC: Double?
    public let fanRpm: Int?
    public let thermalState: Int?
    public let batteryChargePct: Int?
    public let batteryState: String?
    public let batteryHealthPct: Double?
    public let uptimeSeconds: Int?
    public let loadAvg1m: Double?
    public let memoryPressure: String?
    public let diskFreeBytes: Int?
    public let diskTotalBytes: Int?
    public let lpmOn: Bool?
    public let fanBoostActive: Bool?
    public let fanBoostTargetRpm: Int?
    public let sensorsUpdatedAt: String?
    /// 1.60: when the device was last seen (`DeviceRecord.last_sync_at`, the
    /// cloud's `last_seen_at`), so the card can say Offline once it has not
    /// been seen for `DashboardCounts.deviceOnlineGrace`. Optional: an iPhone
    /// from before 1.60 sends none, and the card then shows the stored status.
    public var lastSyncAt: String? = nil

    public var deviceStatus: DeviceStatus? { DeviceStatus(rawValue: status) }

    /// Grey stale readings (>5 min), matching iOSMachineView.
    public func isReadingStale(after: TimeInterval = 300, now: Date = Date()) -> Bool {
        guard let ts = sharedISO8601Parse(sensorsUpdatedAt ?? "") else { return false }
        return now.timeIntervalSince(ts) > after
    }

    public init(from d: DeviceRecord) {
        id = d.id
        name = d.name
        status = d.status
        cpuUsage = d.cpu_usage
        memoryUsage = d.memory_usage
        cpuTempC = d.cpu_temp_c
        fanRpm = d.fan_rpm
        thermalState = d.thermal_state
        batteryChargePct = d.battery_charge_pct
        batteryState = d.battery_state
        batteryHealthPct = d.battery_health_pct
        uptimeSeconds = d.uptime_seconds
        loadAvg1m = d.load_avg_1m
        memoryPressure = d.memory_pressure
        diskFreeBytes = d.disk_free_bytes
        diskTotalBytes = d.disk_total_bytes
        lpmOn = d.lpm_on
        fanBoostActive = d.fan_boost_active
        fanBoostTargetRpm = d.fan_boost_target_rpm
        sensorsUpdatedAt = d.sensors_updated_at
        lastSyncAt = d.last_sync_at
    }

    // Memberwise init for tests / previews.
    public init(id: String, name: String, status: String,
                cpuUsage: Int? = nil, memoryUsage: Int? = nil, cpuTempC: Double? = nil,
                fanRpm: Int? = nil, thermalState: Int? = nil, batteryChargePct: Int? = nil,
                batteryState: String? = nil, batteryHealthPct: Double? = nil,
                uptimeSeconds: Int? = nil, loadAvg1m: Double? = nil, memoryPressure: String? = nil,
                diskFreeBytes: Int? = nil, diskTotalBytes: Int? = nil,
                lpmOn: Bool? = nil, fanBoostActive: Bool? = nil, fanBoostTargetRpm: Int? = nil,
                sensorsUpdatedAt: String? = nil, lastSyncAt: String? = nil) {
        self.id = id; self.name = name; self.status = status
        self.cpuUsage = cpuUsage; self.memoryUsage = memoryUsage; self.cpuTempC = cpuTempC
        self.fanRpm = fanRpm; self.thermalState = thermalState; self.batteryChargePct = batteryChargePct
        self.batteryState = batteryState; self.batteryHealthPct = batteryHealthPct
        self.uptimeSeconds = uptimeSeconds; self.loadAvg1m = loadAvg1m; self.memoryPressure = memoryPressure
        self.diskFreeBytes = diskFreeBytes; self.diskTotalBytes = diskTotalBytes
        self.lpmOn = lpmOn; self.fanBoostActive = fanBoostActive; self.fanBoostTargetRpm = fanBoostTargetRpm
        self.sensorsUpdatedAt = sensorsUpdatedAt
        self.lastSyncAt = lastSyncAt
    }
}

public enum WatchDeviceTrim {
    /// Default cap on devices synced to the watch (WC context size + glance density).
    public static let watchDeviceLimit = 4

    /// Keep only devices that report machine health, cap to `limit`, preserving
    /// the caller's order (the phone lists devices last-seen-desc). Used for BOTH
    /// the WC payload the phone sends and the watch's own live `api.devices()`.
    public static func summaries(from devices: [DeviceRecord],
                                 limit: Int = watchDeviceLimit) -> [WatchDeviceSummary] {
        devices.filter { $0.hasDeviceHealth }
            .prefix(max(0, limit))
            .map(WatchDeviceSummary.init(from:))
    }
}

/// 1.61 (B4, 59-09): what the Watch needs to count the account's online
/// devices itself, for every device (not only the ones with machine health that
/// `WatchDeviceTrim` keeps): its stored status and when it was last seen. Sent
/// by the iPhone with its snapshot and read from the Watch's own device fetch,
/// so the Devices chip counts on `DashboardCounts`' rule at the Watch's
/// `sessionsClock`, as the iPhone, the Mac and the widgets do, instead of
/// showing `dashboard_summary`'s figure from the last refresh.
public struct WatchDevicePresence: Codable, Sendable, Equatable {
    /// The iPhone's WatchConnectivity context key. Absent from an iPhone
    /// before 1.61.
    public static let contextKey = "device_presence"

    public let status: String
    public let lastSyncAt: String?

    public init(status: String, lastSyncAt: String?) {
        self.status = status
        self.lastSyncAt = lastSyncAt
    }

    public init(from device: DeviceRecord) {
        self.init(status: device.status, lastSyncAt: device.last_sync_at)
    }

    /// The devices stored as Online: no other status can count, so the rest
    /// would only add bytes to the iPhone's context (an account keeps every
    /// device it ever paired). An empty list is a count of zero.
    public static func list(from devices: [DeviceRecord]) -> [WatchDevicePresence] {
        devices
            .filter { $0.status.caseInsensitiveCompare(DeviceStatus.online.rawValue) == .orderedSame }
            .map(WatchDevicePresence.init(from:))
    }
}

public extension DashboardCounts {
    /// The account's online devices among `presence` at `now`
    /// (`isOnline(status:lastSeenAt:now:)`).
    static func onlineDevices(_ presence: [WatchDevicePresence], now: Date) -> Int {
        presence.reduce(0) { $0 + (isOnline(status: $1.status, lastSeenAt: $1.lastSyncAt, now: now) ? 1 : 0) }
    }

    /// The Watch's Devices chip: counted from the presence list it holds,
    /// obtained at `presenceAt`. The server's `dashboardFigure` (from the
    /// refresh at `dashboardAt`) instead when there is no list (an iPhone
    /// before 1.61 sent the snapshot, and the Watch has not fetched devices
    /// itself yet), or when the list is older than that refresh by more than
    /// `deviceOnlineGrace`: the Watch's device fetch kept failing while its
    /// dashboard did not, and every device in the old list would have aged
    /// out of the count while the account's devices were still online.
    static func watchOnlineDevices(
        presence: [WatchDevicePresence]?,
        presenceAt: Date?,
        dashboardFigure: Int,
        dashboardAt: Date?,
        now: Date
    ) -> Int {
        guard let presence else { return dashboardFigure }
        if let presenceAt, let dashboardAt, dashboardAt.timeIntervalSince(presenceAt) > deviceOnlineGrace {
            return dashboardFigure
        }
        return onlineDevices(presence, now: now)
    }
}

/// 1.61 (B4, 59-09): the Watch's Live page, classified as the iPhone's and the
/// Mac's Sessions tabs are (`SessionFreshnessTierClassifier`) at the Watch's
/// `sessionsClock`, instead of by each row's stored status: a row stays
/// "Running" in the cloud until its device syncs again, so a Mac asleep with
/// AI tools open kept them on the Live page. `live` is what the Pulse chip
/// counts (`DashboardCounts.activeSessions`), so the page and the chip agree.
public enum WatchLivePage {
    public static func sections(
        _ sessions: [SessionRecord],
        now: Date
    ) -> (live: [SessionRecord], recent: [SessionRecord]) {
        let parts = SessionFreshnessTierClassifier.partition(sessions, now: now)
        return (parts.active, parts.recent)
    }
}

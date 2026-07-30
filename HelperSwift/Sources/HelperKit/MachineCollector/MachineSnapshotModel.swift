import Foundation

// The value model for `get_machine_snapshot`, ported from the .pkg Python
// helper (`helper/machine_collector.py`).
//
// Why this exists: `get_machine_snapshot` lives ONLY in the Python helper, so
// every user whose socket is owned by the app-bundled Swift helper gets
// `unknown_method` and an empty Machine tab. Verified on a real machine —
// `hello` reports `implementation: swift-bundled`, 27 methods, none of them
// this one.
//
// THE WIRE SHAPE IS A CONTRACT, AND THE CLIENT CANNOT DEFEND ITSELF.
// `MachineSnapshot(dict:)` on the client is non-failable and non-throwing, with
// `?? 0` / `?? [:]` / `?? -1` on every field, and the Machine tab shows its
// error UI only when the CALL threw. So a successful response with a
// wrong-shaped dict does not surface as an error — it renders a confident
// "0% CPU, 0% memory, no battery" cockpit. Every key name, type, and unit below
// is therefore load-bearing, and the tests that pin them are the only thing
// standing between a typo and a dashboard that lies.
//
// Units that are easy to get wrong, all matching Python exactly:
//   - memory_used_bytes / memory_total_bytes / swap_* / disk_*  → BYTES
//   - rss_mb                                                    → MiB (ps gives KiB)
//   - battery_temp_c                                            → °C (ioreg gives 0.01 °C)
//   - design_capacity / current_capacity                        → mAh
//   - cpu_percent (top level)                                   → 0…100, clamped
//   - cpu_percent (per process)                                 → per-core, UNCAPPED

// MARK: - Process

public struct MachineProcess: Equatable, Sendable {
    public var pid: Int
    public var name: String
    /// `ps` %CPU. Per-core, so it can exceed 100. Deliberately NOT clamped —
    /// Python does not clamp it either, and a 400% row is meaningful.
    public var cpuPercent: Double
    /// MiB. `ps` reports rss in KiB; Python divides by 1024.0 and rounds to 1dp.
    public var rssMB: Double
    /// -1 when `ps` gave something non-numeric.
    public var uid: Int
    /// `running` | `stopped` | `other`
    public var state: String

    public init(pid: Int, name: String, cpuPercent: Double, rssMB: Double, uid: Int, state: String) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.rssMB = rssMB
        self.uid = uid
        self.state = state
    }

    public var wireDict: [String: Any] {
        [
            "pid": pid,
            "name": name,
            "cpu_percent": cpuPercent,
            "rss_mb": rssMB,
            "uid": uid,
            "state": state,
        ]
    }
}

// MARK: - Battery

public struct MachineBattery: Equatable, Sendable {
    /// The only field that is never null.
    public var hasBattery: Bool = false
    /// From `pmset -g batt` ONLY — ioreg never sets it. So a battery Mac whose
    /// pmset call fails reports has_battery=true with charge_pct=null.
    public var chargePct: Int?
    /// `charging` | `discharging` | `charged` | `none` | `unknown`
    public var state: String?
    public var cycleCount: Int?
    /// AppleRawMaxCapacity / DesignCapacity * 100, 1dp.
    public var healthPct: Double?
    /// mAh
    public var designCapacity: Int?
    /// mAh
    public var currentCapacity: Int?
    /// °C. ioreg reports 0.01 °C; only 0 < raw < 20000 is accepted.
    public var batteryTempC: Double?
    /// Tri-state, and NOT simply "the charger wattage":
    ///   0.0  = on battery (ExternalConnected false)
    ///   >0   = plugged, wattage known
    ///   nil  = plugged, wattage unknown
    /// The client swaps which card it renders based on this, so collapsing
    /// nil into 0.0 would claim "on battery" while plugged in.
    public var adapterWatts: Double?
    /// 0…3, bucketed from CPU_Speed_Limit in `pmset -g therm`.
    /// NOT `ProcessInfo.thermalState` — see MachinePmsetParsers.
    public var thermalState: Int?

    public init() {}

    /// Absent values encode as JSON `null` (matching Python), via `NSNull()`
    /// rather than `Optional.none as Any` — the latter happens to serialize
    /// correctly but is inconsistent with the rest of this server.
    public var wireDict: [String: Any] {
        [
            "has_battery": hasBattery,
            "charge_pct": chargePct.map { $0 as Any } ?? NSNull(),
            "state": state.map { $0 as Any } ?? NSNull(),
            "cycle_count": cycleCount.map { $0 as Any } ?? NSNull(),
            "health_pct": healthPct.map { $0 as Any } ?? NSNull(),
            "design_capacity": designCapacity.map { $0 as Any } ?? NSNull(),
            "current_capacity": currentCapacity.map { $0 as Any } ?? NSNull(),
            "battery_temp_c": batteryTempC.map { $0 as Any } ?? NSNull(),
            "adapter_watts": adapterWatts.map { $0 as Any } ?? NSNull(),
            "thermal_state": thermalState.map { $0 as Any } ?? NSNull(),
        ]
    }
}

// MARK: - System

/// Unlike `battery`, these sub-keys are OMITTED on failure rather than set to
/// null — `memory_pressure` is the only unconditional one. Emitting nulls here
/// instead would change the key set, which is exactly the kind of drift the
/// differential harness exists to catch.
public struct MachineSystem: Equatable, Sendable {
    public var uptimeSeconds: Int?
    public var loadAvg: [Double]?
    public var swapUsedBytes: Int?
    public var swapTotalBytes: Int?
    public var diskFreeBytes: Int?
    public var diskTotalBytes: Int?
    /// `nominal` | `warn` | `critical` — always present.
    public var memoryPressure: String = "nominal"

    public init() {}

    public var wireDict: [String: Any] {
        var d: [String: Any] = ["memory_pressure": memoryPressure]
        if let v = uptimeSeconds { d["uptime_seconds"] = v }
        if let v = loadAvg { d["load_avg"] = v }
        if let v = swapUsedBytes { d["swap_used_bytes"] = v }
        if let v = swapTotalBytes { d["swap_total_bytes"] = v }
        if let v = diskFreeBytes { d["disk_free_bytes"] = v }
        if let v = diskTotalBytes { d["disk_total_bytes"] = v }
        return d
    }
}

// MARK: - Snapshot

public struct MachineSnapshotValue: Sendable {
    public var collectedAt: String = ""
    public var cpuPercent: Int = 0
    public var memoryPercent: Int = 0
    public var memoryUsedBytes: Int = 0
    public var memoryTotalBytes: Int = 0
    public var battery = MachineBattery()
    public var topProcesses: [MachineProcess] = []
    public var capability: [String: Bool] = [:]
    /// `null` — not `{}` — when nothing could be read. Python's
    /// `sensor_bridge` returns `out or None`, and the client distinguishes the
    /// two, so an empty dict here would misreport a fanless or Intel Mac.
    public var sensors: [String: Any]?
    public var system = MachineSystem()

    public init() {}

    public var wireDict: [String: Any] {
        [
            "collected_at": collectedAt,
            "cpu_percent": cpuPercent,
            "memory_percent": memoryPercent,
            "memory_used_bytes": memoryUsedBytes,
            "memory_total_bytes": memoryTotalBytes,
            "battery": battery.wireDict,
            "top_processes": topProcesses.map(\.wireDict),
            "capability": capability,
            "sensors": sensors.map { $0 as Any } ?? NSNull(),
            "system": system.wireDict,
        ]
    }
}

// MARK: - Capability

public enum MachineCapability {
    /// The six keys the Swift helper can honestly claim.
    ///
    /// Python also hardcodes `kill_process: true` and `suspend_process: true`
    /// (`machine_collector.py:546`), and those are DELIBERATELY absent here:
    /// this helper implements neither `kill_process` nor `signal_process`, and
    /// `MachineControlGate` documents the capability key as precisely the
    /// mechanism for not offering an affordance that would fail —
    ///
    ///   "An M1-era helper that advertises `kill_process` but not
    ///    `suspend_process` (and has no `signal_process` verb) therefore shows
    ///    End Process but NOT Suspend — instead of a Suspend button that would
    ///    fail with `not_implemented`."
    ///
    /// Copying Python's map verbatim would put End/Suspend buttons on a DEVID
    /// build that call methods this helper answers with `unknown_method`. An
    /// absent key hides the affordance, which is the honest state: the tab
    /// shows real health and simply offers no controls.
    public static func build(battery: MachineBattery, sensors: [String: Bool]) -> [String: Bool] {
        var cap: [String: Bool] = [
            "process_table": true,
            "battery": battery.hasBattery,
            "thermal_state": battery.thermalState != nil,
            "temps": false,
            "fans": false,
            "power": false,
        ]
        for (k, v) in sensors { cap[k] = v }
        return cap
    }
}

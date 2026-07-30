import Foundation
import SensorKit

/// Assembles the `get_machine_snapshot` payload: runs the shell oracles, reads
/// the sensors, and hands the pure parsers their text.
///
/// The parsers in this directory are all pure functions taking a String, so the
/// only thing that lives here is I/O and assembly. That split is what makes the
/// port testable against the Python fixtures at all.
///
/// Fail-soft everywhere, matching `machine_collector.py:_run`: a non-zero exit,
/// a timeout, and a missing binary all become `nil`, and every field derived
/// from that oracle drops out of the payload rather than failing the call. A
/// half-populated snapshot is worth more than an error — the Machine tab can
/// render what it has.
public enum MachineSnapshotCollector {
    /// `ps` column set. Must stay in this order: the parser splits positionally
    /// and `comm` is last precisely because it can contain spaces.
    private static let psColumns = "pid,uid,pcpu,rss,state,comm"

    // MARK: - Entry points

    /// Blocking entry point, for the sync RPC dispatch and the
    /// `machine-snapshot` subcommand.
    ///
    /// `LocalSessionServer.dispatch` / `handleAuthenticated` return
    /// `WireResponse` synchronously, while `SubprocessRunner.run` is async, so
    /// something has to bridge. Blocking a thread is safe HERE specifically
    /// because each connection is served on its own dedicated `Thread`
    /// (`LocalSessionServer` spawns one per accept) rather than on the
    /// cooperative pool — so this cannot starve other requests. That is a
    /// property of the server's threading model, not a general licence: moving
    /// dispatch onto the cooperative pool would make this a deadlock risk.
    /// The wire dict, with any non-finite Double removed.
    ///
    /// This is not defensive tidiness — it is the difference between a missing
    /// field and a dead daemon. `JSONSerialization.data(withJSONObject:)` raises
    /// an **NSException** on NaN or ±infinity, and an ObjC exception cannot be
    /// caught by Swift `try`, so the response encoder at
    /// `LocalSessionServer.swift:1139` would abort the whole helper process —
    /// taking every PTY session, hook and approval subscription with it.
    ///
    /// The CLI path guards with `isValidJSONObject` and exits 1; the RPC path
    /// has no such guard, and that asymmetry is easy to miss because the CLI is
    /// what a developer runs by hand.
    ///
    /// Reachable in principle from two directions: `Double(cpuS)` on the `ps`
    /// %CPU column returns `+infinity` for an overflowing literal and `nan` for
    /// the text "nan", and SensorKit's Doubles reach here unvalidated by this
    /// module. Neither is expected from a healthy machine, which is exactly why
    /// it would surface as an unexplained daemon death rather than a bug report.
    ///
    /// Dropping the key rather than substituting 0 is deliberate: the client
    /// coerces a missing key to a sane default, whereas a fabricated 0 would be
    /// indistinguishable from a real reading.
    public static func jsonSafeWireDict(_ snapshot: MachineSnapshotValue) -> [String: Any] {
        func clean(_ value: Any) -> Any? {
            if let d = value as? Double { return d.isFinite ? d : nil }
            if let dict = value as? [String: Any] {
                return dict.compactMapValues(clean)
            }
            if let array = value as? [[String: Any]] {
                return array.map { $0.compactMapValues(clean) }
            }
            return value
        }
        return snapshot.wireDict.compactMapValues(clean)
    }

    public static func collectSync() -> MachineSnapshotValue {
        let semaphore = DispatchSemaphore(value: 0)
        // `nonisolated(unsafe)` is sound here: exactly one task writes it, and
        // the semaphore establishes the happens-before edge to this thread's read.
        nonisolated(unsafe) var result = MachineSnapshotValue()
        Task {
            result = await collect()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    public static func collect() async -> MachineSnapshotValue {
        var snap = MachineSnapshotValue()
        snap.collectedAt = isoTimestamp()

        // Fan the oracles out concurrently. Python runs them serially for ~0.12s
        // total; the client's request timeout is 5s and the Machine tab polls
        // every 2s, so serial would still fit — but the sensor read alone costs
        // ~0.3s of deliberate IOReport sampling, and there is no reason to add
        // the text oracles on top of it.
        async let psCPU = run("/bin/ps", ["-Aceo", psColumns, "-r"], timeout: 10)
        async let psMem = run("/bin/ps", ["-Aceo", psColumns, "-m"], timeout: 10)
        async let ioreg = run("/usr/sbin/ioreg", ["-r", "-c", "AppleSmartBattery", "-a"])
        async let pmsetBatt = run("/usr/bin/pmset", ["-g", "batt"])
        async let pmsetTherm = run("/usr/bin/pmset", ["-g", "therm"])
        async let vmStat = run("/usr/bin/vm_stat", [])
        async let memsize = run("/usr/sbin/sysctl", ["-n", "hw.memsize"])
        async let swapusage = run("/usr/sbin/sysctl", ["-n", "vm.swapusage"])
        async let boottime = run("/usr/sbin/sysctl", ["-n", "kern.boottime"])
        async let sensorSnapshot = readSensors()

        // MARK: memory

        let totalBytes = MachineMemoryProbe.parseMemsize(await memsize ?? "")
        if let vm = await vmStat {
            let mem = MachineMemoryProbe.parseVMStat(vm, totalBytes: totalBytes)
            snap.memoryUsedBytes = mem.usedBytes
            snap.memoryPercent = mem.percent
        }
        snap.memoryTotalBytes = totalBytes

        // MARK: cpu

        snap.cpuPercent = MachineSystemExtras.liveCPUPercent()

        // MARK: battery
        //
        // ioreg first, then pmset. The order is load-bearing: ioreg owns
        // has_battery / state / capacities, and pmset is the ONLY source of
        // charge_pct and can also flip has_battery true on a machine whose ioreg
        // plist failed to parse.

        var battery = MachineBattery()
        if let raw = await ioreg, let data = raw.data(using: .utf8) {
            battery = MachineBatteryProbe.parseIoregBattery(data)
        }
        if let pm = await pmsetBatt {
            let parsed = MachinePmsetParsers.parsePmsetCharge(pm)
            if let charge = parsed.charge {
                battery.chargePct = charge
                // pmset saw a battery that ioreg didn't give us.
                if !battery.hasBattery { battery.hasBattery = true }
            }
            if battery.state == nil, let state = parsed.state {
                battery.state = state
            }
        }
        if let therm = await pmsetTherm {
            battery.thermalState = MachinePmsetParsers.parsePmsetThermal(therm)
        }
        snap.battery = battery

        // MARK: processes

        snap.topProcesses = MachineProcessTable.buildProcessList(
            cpuSorted: await psCPU ?? "",
            memorySorted: await psMem ?? "",
            currentUID: Int(getuid())
        )

        // MARK: sensors + capability

        let sensors = await sensorSnapshot
        snap.sensors = sensors
        let sensorCapability = (sensors?["capability"] as? [String: Bool]) ?? [:]
        snap.capability = MachineCapability.build(battery: battery, sensors: sensorCapability)

        // MARK: system

        var system = MachineSystem()
        if let bt = await boottime {
            system.uptimeSeconds = MachineSystemExtras.uptimeSeconds(
                bootEpochSeconds: MachineSystemExtras.parseBootTimeSeconds(bt)
            )
        }
        system.loadAvg = MachineSystemExtras.liveRoundedLoadAverage()
        if let sw = await swapusage {
            let swap = MachineSystemExtras.parseSwapUsage(sw)
            system.swapUsedBytes = swap.used
            system.swapTotalBytes = swap.total
        }
        if let disk = MachineSystemExtras.liveDiskBytes() {
            system.diskFreeBytes = disk.free
            system.diskTotalBytes = disk.total
        }
        // Last, and deliberately so: pressure is a function of memory percent
        // AND swap load (`machine_collector.py:580-581` passes the swap figures
        // straight out of the dict it has just built, so they are nil whenever
        // the swap oracle failed). Computing this before the swap parse — as a
        // first draft here did — silently drops the swap term, which is exactly
        // the half of the signal that distinguishes "using lots of RAM", which
        // macOS does happily, from actual pressure.
        system.memoryPressure = MachineMemoryProbe.pressureLevel(
            memoryPercent: snap.memoryPercent,
            swapUsedBytes: system.swapUsedBytes,
            swapTotalBytes: system.swapTotalBytes
        )
        snap.system = system

        return snap
    }

    // MARK: - Sensors

    /// Mirrors `helper/sensor_bridge.py:parse_output` rather than the shape of
    /// `SensorSnapshot`, because the wire dict is the contract.
    ///
    /// Two details that are easy to get backwards:
    ///
    ///  - A metric that could not be read is **omitted**, not emitted as null.
    ///    (`battery` does the opposite — it emits nulls. `system` omits, like
    ///    this one.) So the `sensors` key set is variable by design, and a
    ///    differential comparison must expect that.
    ///  - `parse_output` ends in `return out or None`, so the dict collapses to
    ///    JSON null only when it is COMPLETELY empty. Since `SensorSnapshot`
    ///    always carries a three-entry capability map, that never happens
    ///    in-process: reading sensors here yields a dict even on a machine with
    ///    no readable sensors, where the .pkg helper would have returned null
    ///    because its `clipulse-sensors` binary was absent. That difference is
    ///    the point of this port, not a drift — but it means "sensors is null"
    ///    is not a state this helper can produce, and nothing should rely on it.
    private static func readSensors() async -> [String: Any]? {
        let s = SensorReader.read(sampleMs: 300)
        var out: [String: Any] = [:]
        if let v = s.cpu_power_w { out["cpu_power_w"] = v }
        if let v = s.gpu_power_w { out["gpu_power_w"] = v }
        if let v = s.ane_power_w { out["ane_power_w"] = v }
        if let v = s.system_power_w { out["system_power_w"] = v }
        if let v = s.cpu_temp_c { out["cpu_temp_c"] = v }
        if let v = s.gpu_temp_c { out["gpu_temp_c"] = v }
        if let v = s.fan_rpm { out["fan_rpm"] = v }
        if let v = s.fan_max_rpm { out["fan_max_rpm"] = v }
        if !s.capability.isEmpty { out["capability"] = s.capability }
        return out.isEmpty ? nil : out
    }

    // MARK: - Plumbing

    /// `SubprocessRunner.run` already has Python's `_run` contract exactly —
    /// non-zero exit, timeout and spawn failure all yield nil — so this is only
    /// a path-resolving wrapper. Absolute paths, not a PATH lookup: the helper
    /// runs from launchd with an environment the user can influence.
    private static func run(
        _ path: String,
        _ arguments: [String],
        timeout: TimeInterval = 5
    ) async -> String? {
        await SubprocessRunner.run(
            executable: URL(fileURLWithPath: path),
            arguments: arguments,
            timeoutSeconds: timeout
        )
    }

    /// Python emits `datetime.now(timezone.utc).isoformat()`: 6-decimal
    /// microseconds and a literal `+00:00` offset. `ISO8601DateFormatter` emits
    /// 3-decimal milliseconds and `Z`, which is a different string.
    ///
    /// No client reads this field, so the difference is harmless in production —
    /// it is matched anyway so a differential run against the Python helper
    /// doesn't report a diff that nobody should act on.
    static func isoTimestamp(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        // `TimeZone(secondsFromGMT: 0)` cannot realistically fail, but this is a
        // long-lived daemon where a trap takes down sessions, hooks and
        // approvals — and it would do so over a field no client even reads.
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date
        )
        let micros = (c.nanosecond ?? 0) / 1000
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%06d+00:00",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, micros
        )
    }
}

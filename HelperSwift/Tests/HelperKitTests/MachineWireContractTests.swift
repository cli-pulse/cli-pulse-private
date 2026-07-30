import XCTest
@testable import HelperKit

/// Pins the `get_machine_snapshot` wire shape.
///
/// `MachineSnapshotModel.swift` opens by saying "the tests that pin them are the
/// only thing standing between a typo and a dashboard that lies". Self-review
/// pointed out that those tests did not exist — the parser tests cover parsing,
/// and nothing asserted the key NAMES. So the sentence was true about what the
/// tests would do and false about there being any.
///
/// This matters more than usual because the client cannot defend itself:
/// `MachineSnapshot(dict:)` is non-failable and non-throwing with `?? 0` on
/// every field, and the Machine tab shows its error UI only when the CALL threw.
/// Rename one nested key and the tab renders a confident zeroed cockpit — no
/// error, no crash, no log line. `swift test`, the method-parity gate and the
/// signed-binary smoke all stay green, because none of them look at key names.
final class MachineWireContractTests: XCTestCase {

    /// Exactly the keys `machine_snapshot_dict()` emits
    /// (helper/machine_collector.py:606-635). All ten, unconditionally.
    func testTopLevelKeySetIsExact() {
        let dict = MachineSnapshotValue().wireDict
        XCTAssertEqual(
            Set(dict.keys),
            [
                "collected_at", "cpu_percent", "memory_percent",
                "memory_used_bytes", "memory_total_bytes", "battery",
                "top_processes", "capability", "sensors", "system",
            ],
            "top-level key set drifted from the Python wire contract"
        )
    }

    /// Battery emits NULLS for absent values — it does not omit them. The client
    /// distinguishes the two, and `system` below does the opposite, so the
    /// asymmetry is deliberate and easy to "tidy up" into a bug.
    func testBatteryEmitsAllTenKeysWithNullsNotOmissions() {
        let dict = MachineBattery().wireDict
        XCTAssertEqual(
            Set(dict.keys),
            [
                "has_battery", "charge_pct", "state", "cycle_count",
                "health_pct", "design_capacity", "current_capacity",
                "battery_temp_c", "adapter_watts", "thermal_state",
            ]
        )
        // Every optional absent ⇒ nine NSNulls, and has_battery still a Bool.
        XCTAssertEqual(dict.values.filter { $0 is NSNull }.count, 9)
        XCTAssertEqual(dict["has_battery"] as? Bool, false)
    }

    /// `system` OMITS what it could not read; only `memory_pressure` is
    /// unconditional. Emitting nulls here instead would change the key set.
    func testSystemOmitsUnreadableKeys() {
        XCTAssertEqual(Set(MachineSystem().wireDict.keys), ["memory_pressure"])

        var full = MachineSystem()
        full.uptimeSeconds = 1
        full.loadAvg = [0, 0, 0]
        full.swapUsedBytes = 1
        full.swapTotalBytes = 2
        full.diskFreeBytes = 3
        full.diskTotalBytes = 4
        XCTAssertEqual(
            Set(full.wireDict.keys),
            [
                "memory_pressure", "uptime_seconds", "load_avg",
                "swap_used_bytes", "swap_total_bytes",
                "disk_free_bytes", "disk_total_bytes",
            ]
        )
        XCTAssertFalse(full.wireDict.values.contains { $0 is NSNull })
    }

    func testProcessRowKeySetIsExact() {
        let row = MachineProcess(
            pid: 1, name: "x", cpuPercent: 0, rssMB: 0, uid: 0, state: "running"
        ).wireDict
        XCTAssertEqual(Set(row.keys), ["pid", "name", "cpu_percent", "rss_mb", "uid", "state"])
    }

    /// The capability map must NOT advertise the two process-control verbs this
    /// helper does not implement. Python hardcodes both
    /// (machine_collector.py:546); copying that would put End/Suspend buttons on
    /// a DEVID build that answer `unknown_method`, because MachineControlGate
    /// treats an absent key as "hide the affordance".
    func testCapabilityOmitsUnimplementedControls() {
        let cap = MachineCapability.build(battery: MachineBattery(), sensors: [:])
        XCTAssertEqual(
            Set(cap.keys),
            ["process_table", "battery", "thermal_state", "temps", "fans", "power"]
        )
        XCTAssertNil(cap["kill_process"])
        XCTAssertNil(cap["suspend_process"])
    }

    func testSensorCapabilityOverridesTheSeededFlags() {
        let cap = MachineCapability.build(
            battery: MachineBattery(),
            sensors: ["temps": true, "fans": true, "power": true]
        )
        XCTAssertEqual(cap["temps"], true)
        XCTAssertEqual(cap["fans"], true)
        XCTAssertEqual(cap["power"], true)
        // …and cannot forge the three the battery/process probes own.
        XCTAssertEqual(cap["process_table"], true)
        XCTAssertEqual(cap["battery"], false)
    }

    /// A non-finite Double reaching `JSONSerialization.data(withJSONObject:)`
    /// raises an ObjC NSException, which Swift `try` CANNOT catch — so it would
    /// abort the whole daemon, not fail the one RPC. Both the RPC handler and
    /// the CLI subcommand go through `jsonSafeWireDict` for this reason.
    func testNonFiniteValuesAreStrippedSoTheDaemonCannotAbort() {
        var snap = MachineSnapshotValue()
        snap.topProcesses = [
            MachineProcess(pid: 1, name: "bad", cpuPercent: .nan, rssMB: .infinity,
                           uid: 0, state: "running"),
        ]
        snap.battery.healthPct = .nan
        snap.sensors = ["cpu_temp_c": Double.infinity, "fan_rpm": 1200]

        let safe = MachineSnapshotCollector.jsonSafeWireDict(snap)
        XCTAssertTrue(
            JSONSerialization.isValidJSONObject(safe),
            "a non-finite Double survived and would abort the helper on encode"
        )

        // Dropped, not coerced to 0 — a fabricated 0 is indistinguishable from
        // a real reading, whereas a missing key coerces to the client's default.
        let row = (safe["top_processes"] as? [[String: Any]])?.first
        XCTAssertNil(row?["cpu_percent"])
        XCTAssertNil(row?["rss_mb"])
        XCTAssertEqual(row?["pid"] as? Int, 1)
        XCTAssertNil((safe["battery"] as? [String: Any])?["health_pct"])
        XCTAssertNil((safe["sensors"] as? [String: Any])?["cpu_temp_c"])
        XCTAssertEqual((safe["sensors"] as? [String: Any])?["fan_rpm"] as? Int, 1200)
    }

    /// A healthy snapshot must survive the same filter untouched.
    func testFiniteValuesSurviveTheFilter() {
        var snap = MachineSnapshotValue()
        snap.cpuPercent = 42
        snap.battery.healthPct = 95.1
        snap.topProcesses = [
            MachineProcess(pid: 7, name: "claude", cpuPercent: 22.5, rssMB: 288.7,
                           uid: 501, state: "running"),
        ]
        let safe = MachineSnapshotCollector.jsonSafeWireDict(snap)
        XCTAssertEqual(safe["cpu_percent"] as? Int, 42)
        XCTAssertEqual((safe["battery"] as? [String: Any])?["health_pct"] as? Double, 95.1)
        let row = (safe["top_processes"] as? [[String: Any]])?.first
        XCTAssertEqual(row?["cpu_percent"] as? Double, 22.5)
        XCTAssertEqual(Set(row?.keys ?? [:].keys), ["pid", "name", "cpu_percent", "rss_mb", "uid", "state"])
    }

    /// `get_machine_snapshot` must be advertised and must bypass the
    /// local-control gate while still requiring the app auth token — matching
    /// Python's GATE_BYPASSED_METHODS (local_session_server.py:234-239).
    func testMethodIsAdvertisedAndBypassesTheLocalControlGate() {
        XCTAssertTrue(
            SupportedMethod.allCases.map(\.rawValue).contains("get_machine_snapshot")
        )
        XCTAssertTrue(SupportedMethod.getMachineSnapshot.bypassesGate)
        XCTAssertFalse(SupportedMethod.getMachineSnapshot.isHookAuth)
    }
}

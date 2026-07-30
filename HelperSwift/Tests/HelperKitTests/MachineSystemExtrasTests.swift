import XCTest
@testable import HelperKit

/// Port of `helper/test_machine_collector.py::TestSystemExtraMetrics` for the
/// oracles that live in `MachineSystemExtras` (swap, boot time, load average,
/// disk, cpu_percent). The fixture strings and expected values are the Python
/// ones verbatim — these are what pin the units, and a unit slip here renders as
/// a confident wrong number rather than an error.
final class MachineSystemExtrasTests: XCTestCase {

    // MARK: - Swap

    /// test_parse_swapusage
    func testParseSwapUsage() {
        let (used, total) = MachineSystemExtras.parseSwapUsage(
            "total = 3072.00M  used = 2285.50M  free = 786.50M  (encrypted)")
        XCTAssertEqual(total, Int(3072.0 * 1024 * 1024))
        XCTAssertEqual(used, Int(2285.5 * 1024 * 1024))
    }

    /// test_parse_swapusage_gigabytes_and_missing
    func testParseSwapUsageGigabytesAndMissing() {
        let (used, total) = MachineSystemExtras.parseSwapUsage("total = 2.00G  used = 0.50G  free = 1.50G")
        XCTAssertEqual(total, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(used, Int(0.5 * 1024 * 1024 * 1024))

        let garbage = MachineSystemExtras.parseSwapUsage("garbage")
        XCTAssertNil(garbage.used)
        XCTAssertNil(garbage.total)
    }

    /// The multipliers are 1024-based, so K is 1024 and not 1000. Not a Python
    /// fixture — added because this is the cheapest place for a 1000-based
    /// "fix" to slip in unnoticed.
    func testParseSwapUsageKilobytesAre1024Based() {
        let (used, total) = MachineSystemExtras.parseSwapUsage("total = 4.00K  used = 1.00K")
        XCTAssertEqual(total, 4096)
        XCTAssertEqual(used, 1024)
    }

    /// Truncation toward zero, matching Python's `int(float(...) * mult)`.
    func testParseSwapUsageTruncatesFraction() {
        let (used, _) = MachineSystemExtras.parseSwapUsage("used = 786.53M")
        XCTAssertEqual(used, Int(786.53 * 1024 * 1024))  // 824736481.28 → 824736481
    }

    /// One field present, the other absent: only the present key ships.
    func testParseSwapUsageMissingOneField() {
        let (used, total) = MachineSystemExtras.parseSwapUsage("total = 2.00G  free = 2.00G")
        XCTAssertNil(used)
        XCTAssertEqual(total, 2 * 1024 * 1024 * 1024)
    }

    /// Replicated Python bug: `[\d.]+` captures "3.0.0", `float()` raises, and
    /// `collect_system_extra` drops the WHOLE swap block — including the `total`
    /// that parsed fine.
    func testParseSwapUsageMalformedNumberDropsBothFields() {
        let (used, total) = MachineSystemExtras.parseSwapUsage("total = 2.00G  used = 3.0.0M")
        XCTAssertNil(used)
        XCTAssertNil(total)
    }

    // MARK: - Boot time / uptime

    /// test_parse_boottime
    func testParseBootTime() {
        XCTAssertEqual(
            MachineSystemExtras.parseBootTimeSeconds("{ sec = 1782641564, usec = 405122 } Sun Jun 28"),
            1782641564)
        XCTAssertNil(MachineSystemExtras.parseBootTimeSeconds("no numbers here"))
    }

    func testUptimeSecondsIsNowMinusBoot() {
        let boot = 1782641564
        let now = Date(timeIntervalSince1970: Double(boot) + 3600)
        XCTAssertEqual(MachineSystemExtras.uptimeSeconds(bootEpochSeconds: boot, now: now), 3600)
    }

    /// Clamped at 0 — the boot clock is wall-clock and an NTP correction can put
    /// it ahead of `now`.
    func testUptimeSecondsClampsNegativeToZero() {
        let boot = 1782641564
        let now = Date(timeIntervalSince1970: Double(boot) - 42)
        XCTAssertEqual(MachineSystemExtras.uptimeSeconds(bootEpochSeconds: boot, now: now), 0)
    }

    /// Python guards with `if boot:`, so 0 omits the key.
    func testUptimeSecondsNilForMissingOrZeroBootTime() {
        XCTAssertNil(MachineSystemExtras.uptimeSeconds(bootEpochSeconds: nil))
        XCTAssertNil(MachineSystemExtras.uptimeSeconds(bootEpochSeconds: 0, now: Date()))
    }

    // MARK: - Load average

    func testRoundLoadAverageTwoDecimals() {
        XCTAssertEqual(MachineSystemExtras.roundLoadAverage([3.1298828125, 3.1748046875, 5.34619140625]),
                       [3.13, 3.17, 5.35])
    }

    /// Python's `round()` breaks ties to even, and Darwin's k/2048 fixed-point
    /// load values do land exactly on .5 (0.125 → 0.12, 0.375 → 0.38).
    func testRoundLoadAverageBreaksTiesToEven() {
        XCTAssertEqual(MachineSystemExtras.roundLoadAverage([0.125, 0.375]), [0.12, 0.38])
    }

    /// test_collect_system_extra_shape — `load_avg` is [1m, 5m, 15m] or absent.
    func testLiveLoadAverageShape() {
        guard let loads = MachineSystemExtras.liveRoundedLoadAverage() else { return }
        XCTAssertEqual(loads.count, 3)
        for load in loads { XCTAssertGreaterThanOrEqual(load, 0) }
    }

    // MARK: - Disk

    /// test_collect_system_extra_shape — `disk_total_bytes` > 0 when present.
    func testLiveDiskBytesShape() {
        guard let disk = MachineSystemExtras.liveDiskBytes() else { return }
        XCTAssertGreaterThan(disk.total, 0)
        XCTAssertGreaterThanOrEqual(disk.free, 0)
        // f_bavail excludes root-reserved blocks, so free is strictly inside
        // total on any real volume.
        XCTAssertLessThanOrEqual(disk.free, disk.total)
    }

    func testLiveDiskBytesNilForMissingPath() {
        XCTAssertNil(MachineSystemExtras.liveDiskBytes(path: "/no/such/volume/cli-pulse-test"))
    }

    // MARK: - cpu_percent

    func testCPUPercentRatioAndTruncation() {
        XCTAssertEqual(MachineSystemExtras.cpuPercent(load1m: 0, cpuCount: 10), 0)
        XCTAssertEqual(MachineSystemExtras.cpuPercent(load1m: 5, cpuCount: 10), 50)
        XCTAssertEqual(MachineSystemExtras.cpuPercent(load1m: 10, cpuCount: 10), 100)
        // int() truncates: 3.19/10*100 = 31.9 → 31, never 32.
        XCTAssertEqual(MachineSystemExtras.cpuPercent(load1m: 3.19, cpuCount: 10), 31)
    }

    func testCPUPercentClamps() {
        XCTAssertEqual(MachineSystemExtras.cpuPercent(load1m: 48, cpuCount: 10), 100)
        XCTAssertEqual(MachineSystemExtras.cpuPercent(load1m: -1, cpuCount: 10), 0)
    }

    /// Python's `max(os.cpu_count() or 1, 1)` — a zero/absent core count must
    /// not divide by zero.
    func testCPUPercentZeroCoreCountFallsBackToOne() {
        XCTAssertEqual(MachineSystemExtras.cpuPercent(load1m: 0.5, cpuCount: 0), 50)
    }

    func testLiveCPUPercentInRange() {
        let pct = MachineSystemExtras.liveCPUPercent()
        XCTAssertGreaterThanOrEqual(pct, 0)
        XCTAssertLessThanOrEqual(pct, 100)
    }
}

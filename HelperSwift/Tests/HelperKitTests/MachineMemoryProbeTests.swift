import XCTest
@testable import HelperKit

/// Differential tests for `MachineMemoryProbe`.
///
/// The vm_stat fixtures and expectations are ported verbatim from
/// `helper/test_machine_collector.py::TestParseVmStatMemory` (:221) and
/// `::test_memory_pressure_levels` (:336), so a divergence between the Python
/// helper and the Swift helper fails here rather than on a user's dashboard.
final class MachineMemoryProbeTests: XCTestCase {

    /// Verbatim from `TestParseVmStatMemory.SAMPLE`.
    static let sample = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                          10000.
        Pages active:                        20000.
        Pages inactive:                      15000.
        Pages wired down:                    30000.
        Pages occupied by compressor:        5000.

        """

    // MARK: - vm_stat (ported fixtures)

    /// Python `test_used_and_percent`.
    func testUsedAndPercent() {
        let total = 17_179_869_184
        let r = MachineMemoryProbe.parseVMStat(Self.sample, totalBytes: total)
        // active + wired + compressor = 55000 pages * 16384
        XCTAssertEqual(r.usedBytes, 55000 * 16384)
        XCTAssertEqual(r.totalBytes, total)
        XCTAssertEqual(r.percent, Int(Double(r.usedBytes) / Double(total) * 100))
        XCTAssertEqual(r.percent, 5, "901120000 / 16 GiB = 5.24% → truncates to 5")
    }

    /// Python `test_zero_total_safe`.
    func testZeroTotalSafe() {
        let r = MachineMemoryProbe.parseVMStat(Self.sample, totalBytes: 0)
        XCTAssertEqual(r.percent, 0)
        XCTAssertEqual(r.usedBytes, 55000 * 16384,
                       "a failed hw.memsize zeroes the percent, not the byte count")
    }

    // MARK: - vm_stat (the three-line definition)

    func testFreeAndInactivePagesAreNotUsed() {
        // Same fixture with free/inactive inflated 100x. If either ever leaks
        // into the sum, memory_percent — and memory_pressure with it — jumps.
        let inflated = """
            Mach Virtual Memory Statistics: (page size of 16384 bytes)
            Pages free:                          1000000.
            Pages active:                        20000.
            Pages inactive:                      1500000.
            Pages speculative:                   900000.
            Pages wired down:                    30000.
            Pages occupied by compressor:        5000.

            """
        let r = MachineMemoryProbe.parseVMStat(inflated, totalBytes: 17_179_869_184)
        XCTAssertEqual(r.usedBytes, 55000 * 16384)
        XCTAssertEqual(r.percent, 5)
    }

    func testMissingCountersCountAsZero() {
        let r = MachineMemoryProbe.parseVMStat("", totalBytes: 17_179_869_184)
        XCTAssertEqual(r.usedBytes, 0)
        XCTAssertEqual(r.percent, 0)
    }

    // MARK: - page size

    func testPageSizeFallsBackTo4096WhenHeaderMissing() {
        let noHeader = """
            Pages active:                        20000.
            Pages wired down:                    30000.
            Pages occupied by compressor:        5000.

            """
        let r = MachineMemoryProbe.parseVMStat(noHeader, totalBytes: 17_179_869_184)
        XCTAssertEqual(r.usedBytes, 55000 * 4096,
                       "Python defaults page_size = 4096 when the header is absent")
    }

    func testHeaderPageSizeIsUsedNotAssumed() {
        let intelHeader = Self.sample.replacingOccurrences(
            of: "page size of 16384 bytes", with: "page size of 4096 bytes")
        let r = MachineMemoryProbe.parseVMStat(intelHeader, totalBytes: 17_179_869_184)
        XCTAssertEqual(r.usedBytes, 55000 * 4096)
    }

    // MARK: - percent arithmetic

    func testPercentTruncatesAndDoesNotRound() {
        // 599 pages of 1 byte over a 10000-byte total = 5.99%. Python's int()
        // truncates to 5; any rounding (banker's or half-up) would give 6.
        let fixture = """
            Mach Virtual Memory Statistics: (page size of 1 bytes)
            Pages active:                        599.

            """
        let r = MachineMemoryProbe.parseVMStat(fixture, totalBytes: 10000)
        XCTAssertEqual(r.usedBytes, 599)
        XCTAssertEqual(r.percent, 5)
    }

    func testPercentClampedTo100WhenUsedExceedsTotal() {
        let r = MachineMemoryProbe.parseVMStat(Self.sample, totalBytes: 1024)
        XCTAssertEqual(r.percent, 100)
        XCTAssertEqual(r.usedBytes, 55000 * 16384, "the byte count is NOT clamped")
    }

    func testNegativeTotalBehavesLikeZeroTotal() {
        let r = MachineMemoryProbe.parseVMStat(Self.sample, totalBytes: -1)
        XCTAssertEqual(r.percent, 0)
    }

    // MARK: - hw.memsize

    func testParseMemsize() {
        XCTAssertEqual(MachineMemoryProbe.parseMemsize("17179869184\n"), 17_179_869_184)
        XCTAssertEqual(MachineMemoryProbe.parseMemsize(""), 0)
        XCTAssertEqual(MachineMemoryProbe.parseMemsize("sysctl: unknown oid"), 0,
                       "Python's .isdigit() gate leaves total = 0 on any non-numeric output")
    }

    // MARK: - memory_pressure_level (ported fixtures)

    /// Python `test_memory_pressure_levels`.
    func testMemoryPressureLevels() {
        let level = MachineMemoryProbe.pressureLevel
        XCTAssertEqual(level(40, 0, 3000), "nominal")
        XCTAssertEqual(level(85, 0, 3000), "warn")        // high RAM%
        XCTAssertEqual(level(50, 1600, 3000), "warn")     // ~53% swap
        XCTAssertEqual(level(95, 0, 3000), "critical")    // very high RAM%
        XCTAssertEqual(level(50, 2600, 3000), "critical") // ~87% swap
        XCTAssertEqual(level(70, nil, nil), "nominal")    // no swap info
    }

    // MARK: - memory_pressure_level (thresholds)

    func testPressureRAMBoundaries() {
        let level = MachineMemoryProbe.pressureLevel
        XCTAssertEqual(level(79, nil, nil), "nominal")
        XCTAssertEqual(level(80, nil, nil), "warn", ">= 80 is warn")
        XCTAssertEqual(level(91, nil, nil), "warn")
        XCTAssertEqual(level(92, nil, nil), "critical", ">= 92 is critical")
        XCTAssertEqual(level(100, nil, nil), "critical")
        XCTAssertEqual(level(0, nil, nil), "nominal")
    }

    func testPressureSwapBoundaries() {
        let level = MachineMemoryProbe.pressureLevel
        // Ratios chosen to be exactly representable in binary64 so the >= lands
        // on the boundary in both languages.
        XCTAssertEqual(level(0, 399, 1000), "nominal")
        XCTAssertEqual(level(0, 400, 1000), "warn", "swap ratio >= 0.40 is warn")
        XCTAssertEqual(level(0, 749, 1000), "warn")
        XCTAssertEqual(level(0, 750, 1000), "critical", "swap ratio >= 0.75 is critical")
    }

    func testPressureIgnoresUnusableSwapTotals() {
        let level = MachineMemoryProbe.pressureLevel
        XCTAssertEqual(level(50, 900, 0), "nominal", "zero swap total is not a divide")
        XCTAssertEqual(level(50, nil, 1000), "nominal")
        XCTAssertEqual(level(50, 900, nil), "nominal")
        XCTAssertEqual(level(50, 0, 3000), "nominal", "no swap in use → ratio 0")
    }

    /// The two inputs are ORed, not averaged: heavy swap alone escalates even
    /// with modest RAM use, and high RAM use alone escalates with no swap.
    func testPressureEscalatesOnEitherSignal() {
        let level = MachineMemoryProbe.pressureLevel
        XCTAssertEqual(level(10, 3000, 3000), "critical")
        XCTAssertEqual(level(92, 0, 3000), "critical")
    }

    // MARK: - end-to-end

    /// percent → pressure is the chain a wrong "used" definition corrupts, so
    /// pin it once end to end.
    func testPercentFeedsPressure() {
        let r = MachineMemoryProbe.parseVMStat(Self.sample, totalBytes: 1_000_000_000)
        XCTAssertEqual(r.percent, 90, "901120000 / 1e9 = 90.1% → 90")
        XCTAssertEqual(MachineMemoryProbe.pressureLevel(memoryPercent: r.percent,
                                                       swapUsedBytes: nil,
                                                       swapTotalBytes: nil), "warn")
    }
}

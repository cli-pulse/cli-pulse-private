import XCTest
@testable import HelperKit
import Foundation

/// Port of `helper/test_machine_collector.py::TestParseTopProcesses` (:9) and
/// `::TestBuildProcessList` (:81). The fixture strings and expected values are
/// the Python ones verbatim — that is the point: the two helpers answer
/// `get_machine_snapshot` for the same users, and the client cannot tell them
/// apart, so any disagreement on the same `ps` bytes ships as a table that
/// silently differs by helper flavour.

final class MachineProcessTableParseTests: XCTestCase {

    // v1.38.1: six columns now — `state` (BSD STAT) sits before `comm`.
    private let sample =
        "  PID   UID  %CPU    RSS STAT COMM\n"
        + "  429     0  21.9  67512 Ss   WindowServer\n"
        + "33608   501  39.7 648848 S    Google Chrome Helper (Renderer)\n"
        + " 3942   501   5.8  29536 S    cli_pulse_helper\n"
        + "  555   501   0.0   1376 T    paused_zsh\n"
        + "  777   501   0.0      0 Z    defunct_proc\n"

    func testParsesAndRanks() {
        let rows = MachineProcessTable.parseTopProcesses(sample, limit: 10)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0].pid, 429)
        XCTAssertEqual(rows[0].name, "WindowServer")
        XCTAssertEqual(rows[0].cpuPercent, 21.9, accuracy: 1e-9)
        // RSS 67512 KiB -> ~65.9 MB
        XCTAssertEqual(rows[0].rssMB, MachineProcessTable.roundedToOneDecimal(67512 / 1024.0), accuracy: 1e-9)
        XCTAssertEqual(rows[0].rssMB, 65.9, accuracy: 1e-9)
    }

    func testUIDColumnParsed() {
        let rows = MachineProcessTable.parseTopProcesses(sample, limit: 10)
        XCTAssertEqual(rows[0].uid, 0)      // WindowServer runs as root
        XCTAssertEqual(rows[1].uid, 501)    // user-owned
        XCTAssertEqual(rows[2].uid, 501)
    }

    func testStateColumnNormalized() {
        let rows = MachineProcessTable.parseTopProcesses(sample, limit: 10)
        var byPID: [Int: MachineProcess] = [:]
        for r in rows { byPID[r.pid] = r }
        XCTAssertEqual(byPID[429]?.state, "running")    // "Ss" → running
        XCTAssertEqual(byPID[33608]?.state, "running")  // "S"  → running
        XCTAssertEqual(byPID[555]?.state, "stopped")    // "T"  → stopped
        XCTAssertEqual(byPID[777]?.state, "other")      // "Z"  → other (zombie)
    }

    func testStateHelperDirect() {
        XCTAssertEqual(MachineProcessTable.normalizeState("T"), "stopped")
        XCTAssertEqual(MachineProcessTable.normalizeState("TN"), "stopped")  // first char wins
        XCTAssertEqual(MachineProcessTable.normalizeState("Z"), "other")
        XCTAssertEqual(MachineProcessTable.normalizeState("R"), "running")
        XCTAssertEqual(MachineProcessTable.normalizeState("S+"), "running")
        XCTAssertEqual(MachineProcessTable.normalizeState(""), "running")    // empty → safe default
    }

    func testNonDigitUIDFallsBack() {
        let sample = "  429     x  21.9  67512 S    WindowServer\n"
        let rows = MachineProcessTable.parseTopProcesses(sample, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].uid, -1)
    }

    func testCommWithSpacesIsPreserved() {
        let rows = MachineProcessTable.parseTopProcesses(sample, limit: 10)
        XCTAssertEqual(rows[1].name, "Google Chrome Helper (Renderer)")
    }

    func testHeaderRowSkipped() {
        let rows = MachineProcessTable.parseTopProcesses(sample, limit: 10)
        XCTAssertTrue(rows.allSatisfy { $0.name != "COMM" })
    }

    func testLimitRespected() {
        XCTAssertEqual(MachineProcessTable.parseTopProcesses(sample, limit: 1).count, 1)
    }

    func testLimitNoneReturnsAll() {
        XCTAssertEqual(MachineProcessTable.parseTopProcesses(sample, limit: nil).count, 5)
    }

    func testEmptyAndMalformed() {
        XCTAssertEqual(MachineProcessTable.parseTopProcesses("", limit: 5), [])
        // Rows with fewer than 6 whitespace-separated fields are skipped.
        XCTAssertEqual(MachineProcessTable.parseTopProcesses("garbage\nx y\n", limit: 5), [])
        XCTAssertEqual(MachineProcessTable.parseTopProcesses("1 2 3 4\n", limit: 5), [])
        XCTAssertEqual(MachineProcessTable.parseTopProcesses("1 2 3 4 5\n", limit: 5), [])  // 5 fields still short
    }

    // MARK: - Swift-side pins (no Python counterpart)
    //
    // These cover the three places a naive Swift translation silently diverges
    // from Python on input the Python fixtures happen not to contain.

    /// `ps` %CPU is per-core and Python never clamps it, so neither do we — a
    /// 12-thread build really does report 400% and the client renders it.
    func testCPUPercentNotClampedAt100() {
        let rows = MachineProcessTable.parseTopProcesses("  42   501 412.5   1024 R    swift-frontend\n", limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].cpuPercent, 412.5, accuracy: 1e-9)
    }

    /// 256 KiB is exactly 0.25 MiB — a true tie. Python's `round` is
    /// ties-to-even and gives 0.2; `(x * 10).rounded() / 10` gives 0.3.
    func testRSSRoundingIsBankers() {
        let rows = MachineProcessTable.parseTopProcesses("  42   501   0.0    256 S    tiny\n", limit: 10)
        XCTAssertEqual(rows[0].rssMB, 0.2, accuracy: 1e-9)
        XCTAssertEqual(MachineProcessTable.roundedToOneDecimal(0.25), 0.2, accuracy: 1e-9)
        XCTAssertEqual(MachineProcessTable.roundedToOneDecimal(0.75), 0.8, accuracy: 1e-9)
        // 0.125 MiB (128 KiB) is NOT a tie at 1dp and must round down.
        XCTAssertEqual(MachineProcessTable.roundedToOneDecimal(0.125), 0.1, accuracy: 1e-9)
    }

    /// Python checks `limit` after appending, so `limit=0` yields one row.
    /// Bug, reproduced deliberately — see `parseTopProcesses`.
    func testZeroLimitReturnsOneRowLikePython() {
        XCTAssertEqual(MachineProcessTable.parseTopProcesses(sample, limit: 0).count, 1)
    }
}

/// The union of top-N-by-CPU (`-r`) and top-N-by-mem (`-m`), plus the
/// force-inclusion of every same-UID stopped process (vanishing-process fix).
final class MachineProcessTableBuildTests: XCTestCase {

    private let r =
        "  PID   UID  %CPU    RSS STAT COMM\n"
        + "  100   501  90.0   1000 R    hot\n"
        + "  200   501  10.0   2000 S    mid\n"
        + "  300   501   0.0    500 S    idle\n"
        + "  400   501   0.0   9000 S    bigmem\n"       // memory-heavy, low CPU
        + "  500   501   0.0    128 T    paused_mine\n"  // stopped, same-uid, tiny → vanishing risk
        + "  600     0   0.0    128 T    paused_root\n"  // stopped, OTHER uid → NOT force-pinned

    // -m is the SAME set re-sorted by memory (bigmem first).
    private let m =
        "  PID   UID  %CPU    RSS STAT COMM\n"
        + "  400   501   0.0   9000 S    bigmem\n"
        + "  200   501  10.0   2000 S    mid\n"
        + "  100   501  90.0   1000 R    hot\n"
        + "  300   501   0.0    500 S    idle\n"
        + "  500   501   0.0    128 T    paused_mine\n"
        + "  600     0   0.0    128 T    paused_root\n"

    func testUnionDedupesAndCoversBothRanks() {
        // topN=2: CPU top-2 = {100, 200}; mem top-2 = {400, 200}. Union covers
        // the memory-heavy 400 that a CPU-only list would miss, deduped (200 once).
        let rows = MachineProcessTable.buildProcessList(cpuSorted: r, memorySorted: m, currentUID: 501, topN: 2)
        let pids = rows.map(\.pid)
        XCTAssertTrue(pids.contains(100))
        XCTAssertTrue(pids.contains(200))
        XCTAssertTrue(pids.contains(400))              // memory-heavy, absent from CPU top-2
        XCTAssertEqual(pids.count, Set(pids).count)    // deduped
    }

    func testVanishingStoppedSameUIDAlwaysIncluded() {
        // pid 500 is stopped, same-uid, and NOT in top-2-by-CPU nor top-2-by-mem
        // — the exact vanishing case. It MUST still appear so the user can resume.
        let rows = MachineProcessTable.buildProcessList(cpuSorted: r, memorySorted: m, currentUID: 501, topN: 2)
        let p500 = rows.first { $0.pid == 500 }
        XCTAssertNotNil(p500, "stopped same-uid proc must not vanish")
        XCTAssertEqual(p500?.state, "stopped")
    }

    func testStoppedOtherUIDNotForceIncluded() {
        // A root-owned stopped process the user can't resume is NOT pinned in
        // (only same-uid stopped procs are force-unioned).
        let rows = MachineProcessTable.buildProcessList(cpuSorted: r, memorySorted: m, currentUID: 501, topN: 2)
        XCTAssertFalse(rows.map(\.pid).contains(600))
    }

    func testResultSortedCPUDesc() {
        // CPU-desc so an OLD (pre-sort) client still shows a sensible top-N.
        let rows = MachineProcessTable.buildProcessList(cpuSorted: r, memorySorted: m, currentUID: 501, topN: 6)
        let cpus = rows.map(\.cpuPercent)
        XCTAssertEqual(cpus, cpus.sorted(by: >))
    }

    func testEmptyInputs() {
        XCTAssertEqual(MachineProcessTable.buildProcessList(cpuSorted: "", memorySorted: "", currentUID: 501), [])
    }

    // MARK: - Swift-side pins (no Python counterpart)

    /// The union is NOT truncated to `topN`: 4 distinct pids come back for
    /// topN=2, in the exact insertion order Python's stable sort produces.
    /// Capping it here would restore the vanishing-process bug.
    func testUnionIsNotCappedAtTopNAndTiesKeepInsertionOrder() {
        let rows = MachineProcessTable.buildProcessList(cpuSorted: r, memorySorted: m, currentUID: 501, topN: 2)
        // 100 (90%) and 200 (10%) from CPU, 400 from memory, 500 force-pinned.
        // 400 and 500 are both 0.0% — Python's `list.sort` is stable, so 400
        // (added by the memory pass) stays ahead of 500 (added by the sweep).
        XCTAssertEqual(rows.map(\.pid), [100, 200, 400, 500])
    }

    /// A same-UID stopped process that is already in a ranked slice must not be
    /// duplicated by the force-union sweep.
    func testForceUnionDoesNotDuplicateAlreadyRankedStoppedProc() {
        let rows = MachineProcessTable.buildProcessList(cpuSorted: r, memorySorted: m, currentUID: 501, topN: 6)
        XCTAssertEqual(rows.filter { $0.pid == 500 }.count, 1)
        XCTAssertEqual(rows.map(\.pid).count, Set(rows.map(\.pid)).count)
    }
}

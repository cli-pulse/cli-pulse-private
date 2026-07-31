import XCTest
@testable import HelperKit

/// Port of `helper/test_machine_collector.py::TestParsePmset` (:191), fixture
/// strings copied verbatim so a divergence in either direction is a test
/// failure, plus the bucket boundaries the Python suite samples but does not pin.
final class MachinePmsetParsersTests: XCTestCase {

    // MARK: - parse_pmset_charge

    /// Python: test_charge_and_state_charged
    func testChargeAndState_charged() {
        let text = "Now drawing from 'AC Power'\n"
            + " -InternalBattery-0 (id=24182883)\t100%; charged; 0:00 remaining present: true\n"
        let (charge, state) = MachinePmsetParsers.parsePmsetCharge(text)
        XCTAssertEqual(charge, 100)
        XCTAssertEqual(state, "charged")
    }

    /// Python: test_charge_and_state_discharging
    func testChargeAndState_discharging() {
        let text = " -InternalBattery-0 (id=1)\t72%; discharging; 3:15 remaining present: true\n"
        let (charge, state) = MachinePmsetParsers.parsePmsetCharge(text)
        XCTAssertEqual(charge, 72)
        XCTAssertEqual(state, "discharging")
    }

    /// "discharging" contains "charging"; the substring order must not flip.
    func testChargeAndState_dischargingWins() {
        let (_, state) = MachinePmsetParsers.parsePmsetCharge("50%; discharging; charging")
        XCTAssertEqual(state, "discharging")
    }

    func testChargeAndState_finishingCharge() {
        let text = " -InternalBattery-0 (id=1)\t98%; finishing charge; 0:05 remaining present: true\n"
        let (charge, state) = MachinePmsetParsers.parsePmsetCharge(text)
        XCTAssertEqual(charge, 98)
        XCTAssertEqual(state, "charging")
    }

    func testChargeAndState_acPowerNoBattery() {
        // A desktop Mac prints only the power source — no %, no state word.
        let (charge, state) = MachinePmsetParsers.parsePmsetCharge("Now drawing from 'AC Power'\n")
        XCTAssertNil(charge)
        XCTAssertNil(state)
    }

    func testCharge_outOfRangeRejectedNotClamped() {
        // `{1,3}` captures "234" out of "1234%"; Python drops it rather than
        // clamping to 100, and so must this.
        let (charge, _) = MachinePmsetParsers.parsePmsetCharge("battery at 1234%; charged")
        XCTAssertNil(charge)
    }

    func testCharge_zeroIsValid() {
        let (charge, state) = MachinePmsetParsers.parsePmsetCharge(" -InternalBattery-0 (id=1)\t0%; discharging;")
        XCTAssertEqual(charge, 0)
        XCTAssertEqual(state, "discharging")
    }

    func testCharge_emptyInput() {
        let (charge, state) = MachinePmsetParsers.parsePmsetCharge("")
        XCTAssertNil(charge)
        XCTAssertNil(state)
    }

    func testBatteryStates_matchesRPCEnum() {
        XCTAssertEqual(MachinePmsetParsers.batteryStates,
                       ["charging", "discharging", "charged", "none", "unknown"])
    }

    // MARK: - parse_pmset_thermal

    /// Python: test_thermal_nominal
    func testThermal_nominal() {
        let text = "Note: No thermal warning level has been recorded\n"
            + "Note: No performance warning level has been recorded\n"
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal(text), 0)
    }

    /// Python: test_thermal_throttling_levels
    func testThermal_throttlingLevels() {
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 100"), 0)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 80"), 1)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 60"), 2)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 30"), 3)
    }

    /// Every band edge: an off-by-one here is invisible until a throttled Mac
    /// shows the wrong badge colour.
    func testThermal_bucketBoundaries() {
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 100"), 0)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 99"), 1)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 75"), 1)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 74"), 2)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 50"), 2)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 49"), 3)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit = 0"), 3)
    }

    /// `\s*=?\s*` — the `=` is optional and the spacing free.
    func testThermal_separatorVariants() {
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("CPU_Speed_Limit \t 40"), 3)
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal("cpu_speed_limit=90"), 1)
    }

    /// The speed limit is read before the literal-text branches.
    func testThermal_speedLimitBeatsNoWarningLine() {
        let text = "Note: No thermal warning level has been recorded\nCPU_Speed_Limit = 60\n"
        XCTAssertEqual(MachinePmsetParsers.parsePmsetThermal(text), 2)
    }

    /// Special case 2: a warning is on record but no speed-limit line parses.
    func testThermal_warningWithoutSpeedLimit() {
        XCTAssertEqual(
            MachinePmsetParsers.parsePmsetThermal("Note: Thermal warning level has been recorded: 1\n"),
            1)
    }

    /// Python: test_thermal_unknown — nil, not 0. `capability["thermal_state"]`
    /// keys off exactly this, so "unknown" must not collapse into "nominal".
    func testThermal_unknown() {
        XCTAssertNil(MachinePmsetParsers.parsePmsetThermal("something unrelated"))
        XCTAssertNil(MachinePmsetParsers.parsePmsetThermal(""))
        // "thermal" alone, without "warning", is still unknown.
        XCTAssertNil(MachinePmsetParsers.parsePmsetThermal("thermal pressure: nominal"))
    }
}

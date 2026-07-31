import XCTest
@testable import HelperKit
import Foundation

/// Port of `TestParseIoregBattery` (`helper/test_machine_collector.py:139`).
///
/// The Python fixtures are built with `plistlib.dumps([node])`; the plists
/// below are what that call emits for each fixture node (keys sorted,
/// tab-indented, bar the trailing newline), so the bytes under test are the
/// ones the Python suite parses.
final class MachineBatteryProbeTests: XCTestCase {

    // MARK: - Fixtures (verbatim `plistlib.dumps([node])` output)

    /// `{"CycleCount": 59, "DesignCapacity": 8694, "AppleRawMaxCapacity": 8262,
    ///   "AppleRawCurrentCapacity": 8262, "MaxCapacity": 100,
    ///   "Temperature": 3098, "ExternalConnected": True, "IsCharging": False,
    ///   "FullyCharged": True, "AdapterDetails": {"Watts": 65}}`
    private static let laptopPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <array>
    \t<dict>
    \t\t<key>AdapterDetails</key>
    \t\t<dict>
    \t\t\t<key>Watts</key>
    \t\t\t<integer>65</integer>
    \t\t</dict>
    \t\t<key>AppleRawCurrentCapacity</key>
    \t\t<integer>8262</integer>
    \t\t<key>AppleRawMaxCapacity</key>
    \t\t<integer>8262</integer>
    \t\t<key>CycleCount</key>
    \t\t<integer>59</integer>
    \t\t<key>DesignCapacity</key>
    \t\t<integer>8694</integer>
    \t\t<key>ExternalConnected</key>
    \t\t<true/>
    \t\t<key>FullyCharged</key>
    \t\t<true/>
    \t\t<key>IsCharging</key>
    \t\t<false/>
    \t\t<key>MaxCapacity</key>
    \t\t<integer>100</integer>
    \t\t<key>Temperature</key>
    \t\t<integer>3098</integer>
    \t</dict>
    </array>
    </plist>
    """

    /// `{"CycleCount": 10, "DesignCapacity": 5000, "AppleRawMaxCapacity": 4800,
    ///   "Temperature": 3000, "ExternalConnected": False, "IsCharging": False}`
    private static let dischargingPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <array>
    \t<dict>
    \t\t<key>AppleRawMaxCapacity</key>
    \t\t<integer>4800</integer>
    \t\t<key>CycleCount</key>
    \t\t<integer>10</integer>
    \t\t<key>DesignCapacity</key>
    \t\t<integer>5000</integer>
    \t\t<key>ExternalConnected</key>
    \t\t<false/>
    \t\t<key>IsCharging</key>
    \t\t<false/>
    \t\t<key>Temperature</key>
    \t\t<integer>3000</integer>
    \t</dict>
    </array>
    </plist>
    """

    /// `{"DesignCapacity": 5000, "AppleRawMaxCapacity": 4800,
    ///   "ExternalConnected": True, "IsCharging": True,
    ///   "AdapterDetails": {"Watts": 96}}`
    private static let chargingPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <array>
    \t<dict>
    \t\t<key>AdapterDetails</key>
    \t\t<dict>
    \t\t\t<key>Watts</key>
    \t\t\t<integer>96</integer>
    \t\t</dict>
    \t\t<key>AppleRawMaxCapacity</key>
    \t\t<integer>4800</integer>
    \t\t<key>DesignCapacity</key>
    \t\t<integer>5000</integer>
    \t\t<key>ExternalConnected</key>
    \t\t<true/>
    \t\t<key>IsCharging</key>
    \t\t<true/>
    \t</dict>
    </array>
    </plist>
    """

    /// `{"DesignCapacity": 5000, "AppleRawMaxCapacity": 4800,
    ///   "Temperature": 99999, "ExternalConnected": True, "IsCharging": False}`
    private static let absurdTempPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <array>
    \t<dict>
    \t\t<key>AppleRawMaxCapacity</key>
    \t\t<integer>4800</integer>
    \t\t<key>DesignCapacity</key>
    \t\t<integer>5000</integer>
    \t\t<key>ExternalConnected</key>
    \t\t<true/>
    \t\t<key>IsCharging</key>
    \t\t<false/>
    \t\t<key>Temperature</key>
    \t\t<integer>99999</integer>
    \t</dict>
    </array>
    </plist>
    """

    /// Builds `plistlib.dumps([node])` for cases the Python suite does not
    /// cover but the Swift port must still pin.
    private func plist(_ node: [String: Any]) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: [node], format: .xml, options: 0
        )
    }

    // MARK: - Ported from TestParseIoregBattery

    func testLaptopBattery() {
        let bt = MachineBatteryProbe.parseIoregBattery(Self.laptopPlist)

        XCTAssertTrue(bt.hasBattery)
        XCTAssertEqual(bt.cycleCount, 59)
        XCTAssertEqual(bt.designCapacity, 8694)
        XCTAssertEqual(bt.currentCapacity, 8262,
                       "AppleRawMaxCapacity wins over MaxCapacity=100 (a percent)")
        // round(8262 / 8694 * 100, 1) == round(95.03105590062113, 1) == 95.0
        XCTAssertEqual(bt.healthPct, 95.0)
        // 3098 is hundredths of a degree -> 30.98 °C, and round(30.98, 1) is
        // 31.0. The Python assertion is assertAlmostEqual(..., 30.98, places=1),
        // whose tolerance hides that the stored value is 31.0, not 30.98.
        XCTAssertEqual(bt.batteryTempC, 31.0)
        XCTAssertEqual(bt.adapterWatts, 65.0)
        XCTAssertEqual(bt.state, "charged", "external + not charging")
    }

    func testDischargingStateAndZeroAdapter() {
        let bt = MachineBatteryProbe.parseIoregBattery(Self.dischargingPlist)

        XCTAssertEqual(bt.state, "discharging")
        XCTAssertEqual(bt.adapterWatts, 0.0, "on battery -> 0 W in")
        XCTAssertEqual(bt.batteryTempC, 30.0)
    }

    func testChargingState() {
        let bt = MachineBatteryProbe.parseIoregBattery(Self.chargingPlist)

        XCTAssertEqual(bt.state, "charging")
        XCTAssertEqual(bt.adapterWatts, 96.0)
        XCTAssertNil(bt.batteryTempC, "no Temperature key -> nil")
    }

    func testDesktopNoBattery() {
        // Empty output (Mac mini / Studio) -> no battery.
        let bt = MachineBatteryProbe.parseIoregBattery(Data())

        XCTAssertFalse(bt.hasBattery)
        XCTAssertNil(bt.healthPct)
    }

    func testMalformedPlist() {
        let bt = MachineBatteryProbe.parseIoregBattery("not a plist")

        XCTAssertFalse(bt.hasBattery)
    }

    func testAbsurdTemperatureDropped() {
        let bt = MachineBatteryProbe.parseIoregBattery(Self.absurdTempPlist)

        XCTAssertNil(bt.batteryTempC, "out of sane window -> nil")
        XCTAssertTrue(bt.hasBattery, "one bad sensor must not void the battery")
    }

    // MARK: - Swift-side contract pins (no Python counterpart)

    /// The tri-state that the model comment calls load-bearing: plugged in with
    /// no AdapterDetails is nil, NOT 0.0, because 0.0 means "on battery".
    func testPluggedWithUnknownWattageIsNilNotZero() {
        let bt = MachineBatteryProbe.parseIoregBattery(plist([
            "DesignCapacity": 5000, "AppleRawMaxCapacity": 4800,
            "ExternalConnected": true, "IsCharging": true,
        ]))

        XCTAssertNil(bt.adapterWatts)
        XCTAssertEqual(bt.state, "charging")
    }

    func testPluggedWithZeroWattageIsNil() {
        let bt = MachineBatteryProbe.parseIoregBattery(plist([
            "ExternalConnected": true, "IsCharging": false,
            "AdapterDetails": ["Watts": 0],
        ]))

        XCTAssertNil(bt.adapterWatts, "Watts<=0 is 'unknown', not 'on battery'")
    }

    func testChargePctIsNeverSetByIoreg() {
        let bt = MachineBatteryProbe.parseIoregBattery(Self.laptopPlist)

        XCTAssertNil(bt.chargePct, "charge_pct comes only from pmset")
        XCTAssertNil(bt.thermalState, "thermal_state comes only from pmset -g therm")
    }

    func testTemperatureBandEdges() {
        func temp(_ raw: Int) -> Double? {
            MachineBatteryProbe.parseIoregBattery(plist(["Temperature": raw])).batteryTempC
        }
        XCTAssertNil(temp(0), "0 is a missing/asleep sensor, not 0 °C")
        XCTAssertNil(temp(20000))
        XCTAssertEqual(temp(19999), 200.0)
        XCTAssertEqual(temp(1), 0.0)
        XCTAssertNil(temp(-1))
    }

    /// Replicated Python quirk: `AppleRawMaxCapacity` of 0 is falsy, so the
    /// parser falls back to `MaxCapacity` — a PERCENT on Apple Silicon. Health
    /// then reads 100/5000 = 2.0%. Wrong, and deliberately preserved.
    func testZeroRawMaxFallsBackToMaxCapacityPercent() {
        let bt = MachineBatteryProbe.parseIoregBattery(plist([
            "DesignCapacity": 5000, "AppleRawMaxCapacity": 0, "MaxCapacity": 100,
            "ExternalConnected": false, "IsCharging": false,
        ]))

        XCTAssertEqual(bt.currentCapacity, 100)
        XCTAssertEqual(bt.healthPct, 2.0)
    }

    func testHealthNilUnlessBothCapacitiesUsable() {
        let missingDesign = MachineBatteryProbe.parseIoregBattery(
            plist(["AppleRawMaxCapacity": 4800, "ExternalConnected": false]))
        XCTAssertNil(missingDesign.healthPct)
        XCTAssertTrue(missingDesign.hasBattery)

        let zeroDesign = MachineBatteryProbe.parseIoregBattery(
            plist(["DesignCapacity": 0, "AppleRawMaxCapacity": 4800]))
        XCTAssertNil(zeroDesign.healthPct)

        let missingRawMax = MachineBatteryProbe.parseIoregBattery(
            plist(["DesignCapacity": 5000, "ExternalConnected": false]))
        XCTAssertNil(missingRawMax.healthPct)
        XCTAssertNil(missingRawMax.currentCapacity)
    }

    /// `_as_int` / `_as_float` reject booleans: `<true/>` for a numeric key must
    /// not become 1. In Python that is because `bool` subclasses `int`; in Swift
    /// because `NSNumber as? Int` would happily yield 1 for a CFBoolean.
    func testBooleanNumericFieldsAreRejected() {
        let bt = MachineBatteryProbe.parseIoregBattery(plist([
            "DesignCapacity": true, "AppleRawMaxCapacity": true,
            "CycleCount": true, "Temperature": true,
            "ExternalConnected": true, "IsCharging": false,
            "AdapterDetails": ["Watts": true],
        ]))

        XCTAssertNil(bt.designCapacity)
        XCTAssertNil(bt.currentCapacity)
        XCTAssertNil(bt.cycleCount)
        XCTAssertNil(bt.batteryTempC)
        XCTAssertNil(bt.healthPct)
        XCTAssertNil(bt.adapterWatts, "plugged in, Watts unreadable -> unknown")
    }

    /// Python accepts a bare top-level dict as well as the array `ioreg -a`
    /// actually emits, and treats an EMPTY node as "no battery" (`if not node`).
    func testTopLevelShapes() {
        let bare = try! PropertyListSerialization.data(
            fromPropertyList: ["DesignCapacity": 5000, "AppleRawMaxCapacity": 4800],
            format: .xml, options: 0)
        XCTAssertTrue(MachineBatteryProbe.parseIoregBattery(bare).hasBattery)

        XCTAssertFalse(MachineBatteryProbe.parseIoregBattery(plist([:])).hasBattery,
                       "empty node -> has_battery=false")

        let arrayOfStrings = try! PropertyListSerialization.data(
            fromPropertyList: ["nope"], format: .xml, options: 0)
        XCTAssertFalse(MachineBatteryProbe.parseIoregBattery(arrayOfStrings).hasBattery)
    }

    /// A wire-shape check: absent values must encode as JSON null, and
    /// `has_battery` must be the one key that is never null.
    func testWireDictShapeForDesktop() {
        let wire = MachineBatteryProbe.parseIoregBattery(Data()).wireDict

        XCTAssertEqual(wire["has_battery"] as? Bool, false)
        XCTAssertTrue(wire["state"] is NSNull)
        XCTAssertTrue(wire["health_pct"] is NSNull)
        XCTAssertTrue(wire["adapter_watts"] is NSNull)
        XCTAssertEqual(wire.count, 10)
    }
}

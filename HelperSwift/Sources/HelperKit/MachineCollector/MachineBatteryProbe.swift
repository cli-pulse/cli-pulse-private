import Foundation

// Port of `parse_ioreg_battery` from the .pkg Python helper
// (`helper/machine_collector.py:261`). Pure parser: the caller runs
// `ioreg -r -c AppleSmartBattery -a` and hands us its stdout.
//
// Everything here is fail-soft in the same way Python is: an empty blob (a
// Mac mini / Studio, which has no AppleSmartBattery node at all) and an
// unparseable blob both yield `has_battery=false` rather than an error. The
// client cannot tell a thrown call from a wrong-shaped dict, so a parser that
// guessed would render a confident lie — see MachineSnapshotModel.
public enum MachineBatteryProbe {

    /// `ioreg -a` writes a UTF-8 XML plist. The oracle layer decodes stdout to
    /// a String, so re-encoding here is lossless for anything plist-parseable;
    /// bytes that were not valid UTF-8 already lost their fidelity upstream and
    /// would not have parsed as a plist anyway.
    public static func parseIoregBattery(_ stdout: String) -> MachineBattery {
        parseIoregBattery(Data(stdout.utf8))
    }

    public static func parseIoregBattery(_ plistBytes: Data) -> MachineBattery {
        var battery = MachineBattery()   // has_battery=false, every field nil
        if plistBytes.isEmpty { return battery }

        guard let root = try? PropertyListSerialization.propertyList(
            from: plistBytes, options: [], format: nil
        ) else {
            return battery                // malformed plist -> no battery
        }

        // `ioreg -a` emits an ARRAY of matched nodes at the top level, one per
        // matching IOService; we want the first. Python also accepts a bare
        // dict, and both branches require a NON-EMPTY dict — `if not node`
        // makes `[{}]` report has_battery=false, not a battery with all-nil
        // fields.
        var node: [String: Any]?
        if let array = root as? [Any], let first = array.first as? [String: Any] {
            node = first
        } else if let dict = root as? [String: Any] {
            node = dict
        }
        guard let node, !node.isEmpty else { return battery }

        let design = asInt(node["DesignCapacity"])
        // Python: `_as_int(AppleRawMaxCapacity) or _as_int(MaxCapacity)`.
        // Replicated including the falsy-zero fallback: AppleRawMaxCapacity=0
        // falls through to MaxCapacity, which on Apple Silicon is a PERCENT
        // (100 in the laptop fixture) — so a zeroed raw reading reports
        // "100 mAh". Wire compatibility beats correctness here; the client
        // parses this dict and the Python helper has always behaved this way.
        var rawMax = asInt(node["AppleRawMaxCapacity"])
        if rawMax == nil || rawMax == 0 { rawMax = asInt(node["MaxCapacity"]) }
        let cycle = asInt(node["CycleCount"])
        let tempRaw = asInt(node["Temperature"])
        let external = isTruthy(node["ExternalConnected"])
        let charging = isTruthy(node["IsCharging"])

        // Python guards `design and raw_max and design > 0`; the truthiness
        // tests only exclude 0/None, so this is `design > 0 && rawMax != 0`.
        // A negative raw reading still yields a negative health % — not
        // clamped there, so not clamped here.
        var healthPct: Double?
        if let design, let rawMax, design > 0, rawMax != 0 {
            healthPct = roundHalfEven1(Double(rawMax) / Double(design) * 100.0)
        }

        // ioreg reports Temperature in hundredths of a degree (3098 -> 30.98 °C).
        // The band rejects BOTH ends of the failure mode: 0 is a missing or
        // asleep sensor, and anything >= 200 °C is a bogus reading (some units
        // report 0xFFFF-ish sentinels). Outside the window -> nil, never a
        // clamped value, because a plausible-looking wrong temperature is worse
        // than no temperature.
        var batteryTempC: Double?
        if let tempRaw, tempRaw > 0, tempRaw < 20000 {
            batteryTempC = roundHalfEven1(Double(tempRaw) / 100.0)
        }

        // TRI-STATE, and the three states are not interchangeable:
        //   0.0 = on battery (ExternalConnected false)
        //   >0  = plugged in, wattage known
        //   nil = plugged in, wattage unknown (no AdapterDetails, or Watts<=0)
        // Collapsing nil to 0.0 would make the client render "on battery" for a
        // machine that is plugged in. `watts > 0` also rejects NaN, matching
        // Python's `watts and watts > 0`.
        let adapter = node["AdapterDetails"] as? [String: Any]
        let watts = adapter.flatMap { asFloat($0["Watts"]) }
        let adapterWatts: Double?
        if !external {
            adapterWatts = 0.0
        } else if let watts, watts > 0 {
            adapterWatts = watts
        } else {
            adapterWatts = nil
        }

        battery.hasBattery = true
        // Derived from the reliable ExternalConnected + IsCharging booleans;
        // the messy pmset state word is only a fallback, applied by the
        // collector, not here.
        battery.state = external ? (charging ? "charging" : "charged") : "discharging"
        battery.cycleCount = cycle
        battery.healthPct = healthPct
        battery.designCapacity = design
        // AppleRawMaxCapacity, NOT CurrentCapacity: this field is the pack's
        // present full-charge capacity in mAh, which is what pairs with
        // design_capacity. Charge % comes only from pmset, so `chargePct` and
        // `thermalState` stay nil here.
        battery.currentCapacity = rawMax
        battery.batteryTempC = batteryTempC
        battery.adapterWatts = adapterWatts
        return battery
    }

    // MARK: - Python coercion semantics

    /// Python's `round(x, 1)`: correctly rounds the EXACT binary value to one
    /// decimal, ties to even. `(x * 10).rounded(.toNearestOrEven) / 10` is not
    /// the same function — it double-rounds, and disagrees with Python on ~0.4%
    /// of values (e.g. 0.05, whose double is a hair above 1/20: Python gives
    /// 0.1, the multiply gives an exact 309…/2 tie and rounds to 0.0). Darwin's
    /// `%.1f` uses the same correctly-rounded, ties-to-even conversion Python
    /// does, so it matches on every sample tested.
    private static func roundHalfEven1(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        return Double(String(format: "%.1f", value)) ?? value
    }

    /// Python `_as_int`. Booleans are rejected explicitly — in Python `bool` is
    /// a subclass of `int`, so `True` would otherwise become 1, and in Swift
    /// `NSNumber as? Int` has the same hazard from the other direction.
    private static func asInt(_ value: Any?) -> Int? {
        guard let value, !isBoolean(value) else { return nil }
        if let number = value as? NSNumber {
            // 64-bit plist integers already fit `Int` here; `clamping` only
            // exists so a pathological value cannot trap.
            guard CFNumberIsFloatType(number as CFNumber) else { return Int(clamping: number.int64Value) }
            let d = number.doubleValue
            // Python `int()` truncates toward zero and raises on NaN/inf.
            guard d.isFinite, d > -9.2e18, d < 9.2e18 else { return nil }
            return Int(d)
        }
        // ioreg never emits string capacities, but `_as_int` accepts anything
        // `int()` accepts, and a future ioreg quirk should degrade the same way.
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Python `_as_float`. Same bool rejection as `asInt`.
    private static func asFloat(_ value: Any?) -> Double? {
        guard let value, !isBoolean(value) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Python `bool(x)` on a plist value: missing/false/0/""/empty container are
    /// false, everything else (including NaN) is true.
    private static func isTruthy(_ value: Any?) -> Bool {
        guard let value else { return false }
        if isBoolean(value) { return (value as? NSNumber)?.boolValue ?? false }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let s = value as? String { return !s.isEmpty }
        if let d = value as? Data { return !d.isEmpty }
        if let a = value as? [Any] { return !a.isEmpty }
        if let d = value as? [String: Any] { return !d.isEmpty }
        return true
    }

    /// `<true/>` decodes to a CFBoolean, and `NSNumber(value: 1) as? Bool`
    /// succeeds, so the type id is the only reliable discriminator.
    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}

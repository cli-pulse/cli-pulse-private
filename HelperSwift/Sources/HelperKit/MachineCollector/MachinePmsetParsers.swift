import Foundation

// `pmset` text parsers, ported 1:1 from the .pkg Python helper
// (`helper/machine_collector.py` — `parse_pmset_charge` :323,
// `parse_pmset_thermal` :347).
//
// Pure text → value: the subprocess that produces `text` belongs to the oracle
// layer, not here. That split is what lets the tests pin the exact same fixture
// strings the Python suite pins, which is the only real proof of wire parity.

/// Namespaced so the sibling ports (ioreg / vm_stat / ps) can each keep their
/// own `parse…` names without colliding in the single HelperKit module.
public enum MachinePmsetParsers {

    /// Battery-state enum accepted by the v0.63 `helper_heartbeat` RPC
    /// (`_BATTERY_STATES`, machine_collector.py:33).
    ///
    /// `parsePmsetCharge` can only ever return three of these five; `none` and
    /// `unknown` exist for writers other than this parser. Kept whole so the
    /// set here stays the RPC's contract rather than this parser's range.
    public static let batteryStates: [String] = [
        "charging", "discharging", "charged", "none", "unknown",
    ]

    /// Parse `pmset -g batt` → (charge %, state word). Either may be nil.
    ///
    ///   " -InternalBattery-0 (id=24182883)\t100%; charged; 0:00 remaining present: true"
    ///
    /// This is the ONLY source of `charge_pct` — ioreg never sets it — so a
    /// nil here is what makes a battery Mac report `has_battery: true` with a
    /// null charge rather than a fabricated 0%.
    public static func parsePmsetCharge(_ text: String) -> (charge: Int?, state: String?) {
        var charge: Int?
        if let value = firstCapturedInt(pattern: "(\\d{1,3})%", in: text) {
            // Out-of-range is REJECTED, not clamped — matching Python, and for
            // a reason: `{1,3}` happily captures the tail of a longer digit run
            // ("1234%" → "234"), so >100 means the match was garbage, not that
            // the battery overflowed. Clamping would turn noise into "100%".
            if (0...100).contains(value) { charge = value }
        }

        var state: String?
        let low = text.lowercased()
        // Order is load-bearing: "discharging" CONTAINS "charging", so the
        // discharging test must run first or every draining Mac reads as
        // charging. `finishing charge` is pmset's trickle-charge wording.
        if low.contains("discharging") {
            state = "discharging"
        } else if low.contains("charging") || low.contains("finishing charge") {
            state = "charging"
        } else if low.contains("charged") {
            state = "charged"
        }
        // Ported hole, deliberately kept: the word "discharged" would fall
        // through to `charged` (it contains that substring and none of the
        // earlier ones). pmset does not print it, and the client parses this
        // dict — wire compatibility beats fixing a case that cannot occur.
        return (charge, state)
    }

    /// Parse `pmset -g therm` → 0…3.
    ///
    /// THIS IS NOT `ProcessInfo.thermalState`, despite the
    /// "NSProcessInfo.thermalState-style" wording on the Python dataclass
    /// (machine_collector.py:68) and on `MachineBattery.thermalState`. It is a
    /// bucketing of the `CPU_Speed_Limit` integer, and the native API answers
    /// with a DIFFERENT number for the same machine at the same instant — it
    /// reports OS-wide thermal pressure, not a CPU speed cap, and a Mac at 100%
    /// speed can sit in `.fair` while a throttled one still reads `.nominal`.
    ///
    /// So do not "modernise" this into `ProcessInfo.processInfo.thermalState`.
    /// `MachineHealthView.thermalInfo` switches on 0/1/2 and routes everything
    /// else to `default:` → a red "Critical" badge, so any scale drift shows the
    /// user a thermal emergency on an idle machine.
    public static func parsePmsetThermal(_ text: String) -> Int? {
        // Python lowercases the whole dump and then matches case-sensitively;
        // same thing here, so the `\s*=?\s*` slack behaves identically.
        let low = text.lowercased()

        // Checked BEFORE the literal-text branches: a dump carrying both a
        // speed limit and a "no warning recorded" note is graded on the number.
        if let limit = firstCapturedInt(pattern: "cpu_speed_limit\\s*=?\\s*(\\d{1,3})", in: low) {
            // Speed limit is a percentage of full clock — 100 means unthrottled.
            // `{1,3}` caps the capture at three digits, so a hypothetical
            // "1000" reads as 100 → nominal. Ported as-is; pmset never exceeds 100.
            if limit >= 100 { return 0 }
            if limit >= 75 { return 1 }
            if limit >= 50 { return 2 }
            return 3
        }
        if low.contains("no thermal warning level has been recorded") { return 0 }
        // A recorded thermal warning without a speed-limit line → at least "fair".
        if low.contains("thermal") && low.contains("warning") { return 1 }
        // nil, not 0: "unknown" must stay distinguishable from "nominal", since
        // it is what drives `capability["thermal_state"]` and thus whether the
        // badge renders at all.
        return nil
    }

    // MARK: - Internal

    /// First match's group 1 as an Int, or nil. Mirrors `re.search(...).group(1)`.
    private static func firstCapturedInt(pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[captured])
    }
}

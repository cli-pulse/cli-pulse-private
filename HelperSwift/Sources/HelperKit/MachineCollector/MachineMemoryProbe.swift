import Foundation

/// Memory probes ported from the .pkg Python helper:
/// `helper/machine_collector.py::parse_vm_stat_memory` (:387-412) and
/// `::memory_pressure_level` (:114-127).
///
/// Pure functions only. The oracle layer runs `vm_stat` and
/// `sysctl -n hw.memsize` and hands the stdout in; nothing here shells out.
///
/// ONE DEFINITION OF "USED", AND IT IS LOAD-BEARING.
/// Python sums EXACTLY three vm_stat lines — `Pages active`,
/// `Pages wired down`, `Pages occupied by compressor` — times the page size.
/// Not host_statistics64, not "total - free", and explicitly NOT including
/// `Pages inactive` or `Pages speculative` (macOS keeps both large and
/// reclaimable; counting them reads ~90% used on an idle Mac). Any other
/// definition diverges silently: `memory_percent` is derived from this byte
/// figure, and `system.memory_pressure` is in turn derived from
/// `memory_percent`, so a wrong sum shows up as a confident, wrong
/// "critical" badge rather than as an error.
public enum MachineMemoryProbe {

    /// vm_stat states its page size in the header line; Python falls back to
    /// 4096 when that line is missing or unparseable. On Apple Silicon the real
    /// value is 16384, so the fallback under-reports used bytes by 4x rather
    /// than failing — matching Python's choice to stay fail-soft here.
    public static let defaultPageSize = 4096

    // MARK: - vm_stat

    /// `(usedBytes, totalBytes, percent)` from `vm_stat` stdout plus the
    /// `hw.memsize` total. `totalBytes` is echoed back so callers get the whole
    /// wire triple from one call (Python splits this across
    /// `parse_vm_stat_memory` + `collect_memory`).
    ///
    /// `percent` is 0…100. A non-positive `totalBytes` yields percent 0 with the
    /// used byte count still populated — Python's zero-total guard, kept because
    /// `collect_memory` passes 0 whenever the sysctl failed.
    public static func parseVMStat(_ vmStatOut: String, totalBytes: Int)
        -> (usedBytes: Int, totalBytes: Int, percent: Int)
    {
        let pageSize = parsePageSize(vmStatOut)

        // Python builds a dict from every "key: value" line, stripping all
        // non-digits from the value. Two consequences are replicated
        // deliberately: the trailing "." on vm_stat counts is discarded, and so
        // is a leading "-", so "Pages active: -5." parses as 5. The header line
        // also matches (key "Mach Virtual Memory Statistics", value 16384) and
        // is simply never read.
        var values: [String: Int] = [:]
        for line in vmStatOut.split(whereSeparator: { $0.isNewline }) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = String(line[line.index(after: colon)...].filter(isASCIIDigit))
            guard !digits.isEmpty else { continue }
            // Python's int() is arbitrary-precision, Swift's Int is not. A count
            // too large for Int64 is dropped instead of trapping; unreachable
            // from real vm_stat output, and the alternative is a crashed helper.
            guard let count = Int(digits) else { continue }
            values[key] = count   // last occurrence wins, as with Python's dict
        }

        let usedPages = saturating(
            saturating(values["Pages active"] ?? 0, plus: values["Pages wired down"] ?? 0),
            plus: values["Pages occupied by compressor"] ?? 0)
        let usedBytes = saturating(usedPages, times: pageSize)

        guard totalBytes > 0 else { return (usedBytes, totalBytes, 0) }

        let ratio = Double(usedBytes) / Double(totalBytes) * 100
        // Python: `max(0, min(100, int(used / total * 100)))` — int() truncates
        // toward zero (no rounding at all, so nothing here depends on Python's
        // banker's rounding). Swift's Int(Double) truncates the same way but
        // TRAPS above Int.max, which a fabricated used >> total can reach.
        // Clamping in Double space first is equivalent — truncation is
        // monotonic and both bounds are exactly representable — and cannot trap.
        let percent = Int(min(100.0, max(0.0, ratio)))
        return (usedBytes, totalBytes, percent)
    }

    /// `sysctl -n hw.memsize` → bytes, or 0 when the output is not a bare
    /// integer. Python (:486-493) gates on `.isdigit()` and leaves `total = 0`
    /// otherwise; 0 is not a sentinel the wire model understands, it simply
    /// makes `parseVMStat` report percent 0 instead of dividing by zero.
    public static func parseMemsize(_ sysctlOut: String) -> Int {
        let trimmed = sysctlOut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(isASCIIDigit) else { return 0 }
        return Int(trimmed) ?? 0
    }

    // MARK: - Pressure

    /// Coarse, root-free memory-pressure signal: `nominal` | `warn` |
    /// `critical`. macOS swaps freely, so only HEAVY swap combined with high RAM
    /// use counts — a little swap is normal.
    ///
    /// Swap is optional because `collect_system_extra` passes
    /// `out.get("swap_used_bytes")`, which is absent when `sysctl vm.swapusage`
    /// failed. Python's guard is
    /// `if swap_used and swap_total and swap_total > 0` — the truthiness checks
    /// are dropped here because they change no outcome: used == 0 gives ratio
    /// 0.0 either way, and a negative or zero total is already excluded by
    /// `> 0`.
    public static func pressureLevel(memoryPercent: Int,
                                     swapUsedBytes: Int? = nil,
                                     swapTotalBytes: Int? = nil) -> String
    {
        var swapRatio = 0.0
        if let used = swapUsedBytes, let total = swapTotalBytes, total > 0 {
            swapRatio = Double(used) / Double(total)
        }
        // Both sides divide in IEEE-754 binary64, so a ratio landing exactly on
        // 0.40 or 0.75 compares the same in Swift as in Python.
        if memoryPercent >= 92 || swapRatio >= 0.75 { return "critical" }
        if memoryPercent >= 80 || swapRatio >= 0.40 { return "warn" }
        return "nominal"
    }

    // MARK: - Internals

    private static func parsePageSize(_ vmStatOut: String) -> Int {
        guard let range = vmStatOut.range(of: #"page size of (\d+) bytes"#,
                                          options: .regularExpression) else {
            return defaultPageSize
        }
        let digits = String(vmStatOut[range].filter(isASCIIDigit))
        // A page size too large for Int64 cannot come from a real kernel; the
        // fallback keeps the helper alive rather than trapping on the multiply.
        return Int(digits) ?? defaultPageSize
    }

    private static func isASCIIDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// Python ints never overflow; Swift's trap. Saturating at `Int.max` is only
    /// reachable with fabricated vm_stat output, and all operands are
    /// non-negative because the digit filter has already stripped any "-".
    private static func saturating(_ a: Int, plus b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    private static func saturating(_ a: Int, times b: Int) -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? .max : product
    }
}

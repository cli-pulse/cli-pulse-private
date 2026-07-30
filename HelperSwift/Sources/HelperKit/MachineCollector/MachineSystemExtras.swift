import Foundation
import Darwin

/// The "system extras" block of `get_machine_snapshot` — uptime, load average,
/// swap, disk — plus the top-level `cpu_percent`. Ported from
/// `helper/machine_collector.py` (`parse_swapusage`, `parse_boottime_sec`, the
/// `collect_system_extra` body, and `collect_cpu_percent`).
///
/// Split the way the Python file is split: the text oracles are pure functions
/// over the command's stdout so they can be pinned by the same fixtures pytest
/// uses, while `getloadavg(3)` and `statvfs(2)` are syscalls with no stdout to
/// parse and are wrapped in their own one-purpose functions so the parsers stay
/// unit-testable without a filesystem or a live host.
///
/// Every failure here is fail-soft and per-oracle: Python wraps each read in its
/// own `try/except` and simply omits the key, and `MachineSystem` encodes those
/// as omitted keys rather than nulls. So `nil` from anything below means "this
/// sub-key does not ship", never "ship a zero".
public enum MachineSystemExtras {

    // MARK: - Swap (pure; `sysctl -n vm.swapusage`)

    /// Parse `sysctl -n vm.swapusage` into (used, total) BYTES.
    ///
    /// e.g. `total = 3072.00M  used = 2285.50M  free = 786.50M  (encrypted)`.
    ///
    /// The suffix multipliers are 1024-based (`1024 ** 2` in Python), matching
    /// how the kernel prints the figure — using 1000-based ones would understate
    /// a 3 GiB swap file by ~7% and the client renders the number verbatim.
    ///
    /// Truncation, not rounding: Python is `int(float(...) * mult)`, and
    /// `Int(Double)` truncates toward zero the same way.
    public static func parseSwapUsage(_ text: String) -> (used: Int?, total: Int?) {
        // Python evaluates `field("used"), field("total")` with no try/except
        // inside the parser, so a matched-but-unconvertible number (e.g.
        // "3.0.0", which `[\d.]+` happily captures) raises ValueError out of the
        // whole function; `collect_system_extra`'s `except Exception` then drops
        // BOTH swap keys, not just the bad one. Replicated rather than fixed —
        // the wire shape is the contract, and a half-populated swap block would
        // be a new state the client has never seen.
        let used = swapField(text, label: "used")
        let total = swapField(text, label: "total")
        if case .malformed = used { return (nil, nil) }
        if case .malformed = total { return (nil, nil) }
        return (used.value, total.value)
    }

    private enum SwapField {
        case parsed(Int)
        case absent
        /// The label matched but the captured number is not a usable Double.
        case malformed

        var value: Int? {
            if case .parsed(let v) = self { return v }
            return nil
        }
    }

    private static func swapField(_ text: String, label: String) -> SwapField {
        // Same pattern as Python, including the deliberate lack of a word
        // boundary and the uppercase-only unit class.
        let pattern = "\(label)\\s*=\\s*([\\d.]+)\\s*([KMG])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return .absent }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 3 else {
            return .absent
        }
        guard let number = Double(ns.substring(with: m.range(at: 1))) else { return .malformed }
        let multiplier: Double
        switch ns.substring(with: m.range(at: 2)) {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        default: return .absent
        }
        // Divergence from Python, deliberately: Python's ints are arbitrary
        // precision, so an absurd capture just ships an absurd number, while
        // `Int(Double)` would trap and take the helper down. Out of range takes
        // the same path as an unparsable number — the swap block is dropped.
        let bytes = number * multiplier
        guard bytes.isFinite, let value = Int(exactly: bytes.rounded(.towardZero)) else {
            return .malformed
        }
        return .parsed(value)
    }

    // MARK: - Boot time / uptime (pure; `sysctl -n kern.boottime`)

    /// Extract the boot epoch seconds from `sysctl -n kern.boottime`
    /// (`{ sec = 1782641564, usec = 405122 } Sun Jun 28 ...`).
    ///
    /// Only the `sec` field is used; `usec` never contributes, so uptime has
    /// whole-second resolution — matching Python and, more importantly, the
    /// client's formatter, which renders days/hours.
    public static func parseBootTimeSeconds(_ text: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: "sec\\s*=\\s*(\\d+)") else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 2 else {
            return nil
        }
        // `Int(_:)` returns nil on a digit string too long for 64 bits, where
        // Python would build a big int. Same reasoning as the swap overflow
        // guard: a bogus reading is dropped rather than crashing the helper.
        return Int(ns.substring(with: m.range(at: 1)))
    }

    /// `uptime_seconds` from a parsed boot epoch, clamped at 0.
    ///
    /// The clamp matters because the two clocks are independent: `kern.boottime`
    /// is wall-clock and jumps when NTP corrects the machine, so a fresh boot
    /// can briefly compute negative and the client would render it as a huge
    /// unsigned duration.
    ///
    /// Replicates one Python quirk: the guard is `if boot:`, so a boot time of
    /// exactly 0 (epoch) is falsy and omits the key rather than reporting a
    /// 56-year uptime. Unreachable in practice, kept for wire equality.
    public static func uptimeSeconds(bootEpochSeconds: Int?, now: Date = Date()) -> Int? {
        guard let boot = bootEpochSeconds, boot != 0 else { return nil }
        // Python truncates `datetime.now(timezone.utc).timestamp()` with int()
        // before subtracting; `Int(_:)` on a positive TimeInterval does the same.
        let nowSeconds = Int(now.timeIntervalSince1970)
        return max(0, nowSeconds - boot)
    }

    // MARK: - Load average (`getloadavg(3)`)

    /// The three raw load figures [1m, 5m, 15m], or nil if the host refused.
    ///
    /// Requires all three samples: CPython's `os.getloadavg()` raises OSError
    /// unless `getloadavg` returns exactly 3, and an OSError there omits the
    /// `load_avg` key entirely. A partial array would change the array's length,
    /// which the client indexes positionally.
    public static func liveLoadAverage() -> [Double]? {
        var loads = [Double](repeating: 0, count: 3)
        let read = loads.withUnsafeMutableBufferPointer {
            Darwin.getloadavg($0.baseAddress, Int32($0.count))
        }
        guard read == 3 else { return nil }
        return loads
    }

    /// Round each element to 2dp, matching Python's `[round(x, 2) for x in ...]`.
    ///
    /// `.toNearestOrEven` — not the default `.rounded()` — because Python's
    /// `round()` breaks ties to even, and the tie case is reachable here: Darwin
    /// reports load as a fixed-point `k / 2048`, so `x * 100 == k * 25 / 512` is
    /// exact in a Double and lands on exactly .5 whenever 256 divides k (e.g.
    /// 0.125 → 0.12, not 0.13). Because that multiply is exact for real kernel
    /// values, the scale-round-unscale here agrees with Python's decimal-exact
    /// rounding rather than merely approximating it.
    public static func roundLoadAverage(_ raw: [Double]) -> [Double] {
        raw.map { x in
            guard x.isFinite else { return x }
            return (x * 100).rounded(.toNearestOrEven) / 100
        }
    }

    /// `load_avg` as it ships: 3 elements, each 2dp. nil omits the key.
    public static func liveRoundedLoadAverage() -> [Double]? {
        liveLoadAverage().map(roundLoadAverage)
    }

    // MARK: - Disk (`statvfs(2)`)

    /// (free, total) BYTES for `path`, or nil if `statvfs` failed (Python
    /// catches OSError and omits both keys).
    ///
    /// Free space is `f_bavail`, NOT `f_bfree`: `f_bavail` excludes the blocks
    /// reserved for root, which is what any non-root process can actually use
    /// and what Finder shows. The two differ by gigabytes on a big volume, so
    /// swapping them would make the Machine tab disagree with the Finder window
    /// next to it.
    public static func liveDiskBytes(path: String = "/") -> (free: Int, total: Int)? {
        var st = statvfs()
        guard statvfs(path, &st) == 0 else { return nil }
        // Both counts are in f_frsize units, not f_bsize — Python multiplies by
        // f_frsize and on APFS the two differ.
        let frsize = Int(clamping: st.f_frsize)
        let (free, freeOverflow) = Int(st.f_bavail).multipliedReportingOverflow(by: frsize)
        let (total, totalOverflow) = Int(st.f_blocks).multipliedReportingOverflow(by: frsize)
        guard !freeOverflow, !totalOverflow else { return nil }
        return (free, total)
    }

    // MARK: - CPU percent

    /// Coarse load-average-based CPU%, 0…100, truncated to an Int.
    ///
    /// `int(load / cpu_count * 100)` in Python truncates toward zero, and so
    /// does `Int(Double)`; the clamp is Python's `max(0, min(100, ...))`. This
    /// is deliberately the same definition `system_collector` uses, so the
    /// Machine tab and the device heartbeat never disagree about the same host.
    public static func cpuPercent(load1m: Double, cpuCount: Int) -> Int {
        let count = max(cpuCount, 1)
        let ratio = load1m / Double(count) * 100.0
        // Python would raise on a non-finite load rather than clamp; a helper
        // crash is a worse answer than the 0 the caller already uses for a
        // failed read.
        guard ratio.isFinite else { return 0 }
        return max(0, min(100, Int(ratio.rounded(.towardZero))))
    }

    /// Live `cpu_percent`. 0 on any failure, matching Python's `except` arm.
    public static func liveCPUPercent() -> Int {
        guard let loads = liveLoadAverage() else { return 0 }
        // LOGICAL cores, to match Python's `os.cpu_count()`, which is
        // `hw.logicalcpu_max` — hence `processorCount`, NOT
        // `activeProcessorCount`. The latter reports cores currently available
        // for scheduling and can drop under thermal pressure or on battery;
        // using it would shrink the divisor exactly when the machine is
        // struggling and silently inflate cpu_percent (a throttled 10-core Mac
        // showing 4 active cores would report 2.5x the real figure).
        return cpuPercent(load1m: loads[0], cpuCount: ProcessInfo.processInfo.processorCount)
    }
}

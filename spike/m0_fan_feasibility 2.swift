#!/usr/bin/env swift
//
// M0 — Fan-control feasibility spike  (THROWAWAY — DO NOT MERGE, DO NOT SHIP)
// =============================================================================
// Purpose (per DEV_PLAN_2026-07-06_machine_controls.md, milestone M0): answer the
// go/no-go questions for fan control BEFORE any root infrastructure is built.
// This file is NOT part of the app. It is run MANUALLY, AS ROOT, on the owner's
// own Apple-Silicon Mac, and then deleted. It never ships in any build.
//
// It reuses the exact AppleSMC read path proven in SensorProbe/Sources/SensorKit/
// SMC.swift (beltex/SMCKit layout, IOConnectCallStructMethod, cmd 5/8/9) and adds
// the guarded WRITE path (cmd 6) needed to test manual fan control.
//
// It answers:
//   Q-A  Does an SMC fan WRITE actually work on this Mac (does F{n}Ac follow F{n}Tg)?
//   Q-B  What exact sequence does the firmware accept? (Apple Silicon's
//        thermalmonitord overrides a bare F{n}Md/F{n}Tg write — you must set the
//        force/test key Ftst=1 first, then apply mode+target in a retry loop.)
//   Q-C  SAFETY CRUX: after a SIGKILL (kill -9) of the controlling process — which
//        cannot run any cleanup — does the firmware self-revert to Apple-auto, and
//        HOW FAST? If it does NOT, fan control is a NO-GO without a separate,
//        always-running root watchdog (and even then it's high-risk).
//
// SAFETY RAILS baked in:
//   * READ-ONLY by default. Any write mode requires BOTH root AND the explicit
//     flag  --i-understand-this-writes-smc-as-root .
//   * Target RPM is HARD-CLAMPED to the firmware's own [F{n}Mn, F{n}Mx]; a write
//     is REFUSED if min/max can't be read.
//   * `set` holds manual for a BOUNDED --hold N seconds, then auto-reverts. It
//     never leaves the fan in manual mode on a normal exit.
//   * SIGINT / SIGTERM / SIGHUP and atexit all restore auto (Ftst=0, F{n}Md=0).
//   * `restore` is a panic button that forces every fan back to Apple-auto.
//
//   The one thing this tool CANNOT protect against is the very thing Q-C tests:
//   a `kill -9`. That is why Q-C is a deliberate, observed experiment — run it
//   with the machine idle and watch temps.
//
// USAGE (run each as root, e.g. `sudo swift m0_fan_feasibility.swift <cmd> ...`):
//   read                                  # safe: dump all fan keys + values
//   keys [FILTER]                         # safe: list SMC keys (optional substr filter)
//   set   --fan N --rpm R [--hold S] --i-understand-this-writes-smc-as-root
//   revert-test --fan N --rpm R --i-understand-this-writes-smc-as-root
//   restore --i-understand-this-writes-smc-as-root
//
// Report back for the M0 deliverable: the `read` dump, whether `set` moved F{n}Ac
// toward the target, the accepted sequence, and — critically — the revert-test
// result (did F{n}Md return to 0 after kill -9, and after how many seconds).
// =============================================================================

import Foundation
import IOKit

// MARK: - SMC struct (pure-Swift beltex/SMCKit layout — matches CSensorShim.h)

// The C struct (CSensorShim.h) is 80 bytes under natural C alignment. Swift's
// automatic layout of the same fields comes out to 76 (it doesn't pad the inner
// SMCKeyInfoData up to its 4-byte-aligned stride, nor insert the pad before
// data32), which shifts data8/data32/bytes off their kernel-ABI offsets and
// makes every IOConnectCallStructMethod fail. We add explicit pad bytes so the
// stride is 80 and the offsets match C exactly (verified: data8@42 data32@44
// bytes@48). Do NOT reorder these fields.
struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var _p0: UInt8 = 0; var _p1: UInt8 = 0; var _p2: UInt8 = 0 }  // padded to 12

// 32-byte payload as a homogeneous tuple (matches uint8_t bytes[32]).
typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct SMCKeyData_t {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var _pad: UInt8 = 0            // align data32 to offset 44 (matches C)
    var data32: UInt32 = 0
    var bytes: Bytes32 = (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
                          0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
}

// MARK: - SMC client (read = ported from SMC.swift; write = new, guarded)

final class SMC {
    private var conn: io_connect_t = 0
    var isOpen: Bool { conn != 0 }

    private static let kSMCUserClientOpen: UInt32 = 0
    private static let kSMCHandleYPCEvent: UInt32 = 2
    static let cmdReadBytes: UInt8 = 5
    static let cmdWriteBytes: UInt8 = 6      // <-- the root-only command M0 tests
    static let cmdReadIndex: UInt8 = 8
    static let cmdReadKeyInfo: UInt8 = 9

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, Self.kSMCUserClientOpen, &conn) == kIOReturnSuccess else { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    static func fourCC(_ s: String) -> UInt32 {
        var k: UInt32 = 0
        for b in s.utf8.prefix(4) { k = (k << 8) | UInt32(b) }
        return k
    }
    static func keyString(_ k: UInt32) -> String {
        let b = [UInt8((k >> 24) & 0xff), UInt8((k >> 16) & 0xff), UInt8((k >> 8) & 0xff), UInt8(k & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? ""
    }
    static func typeString(_ t: UInt32) -> String {
        keyString(t).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
    }

    private func call(_ input: inout SMCKeyData_t) -> SMCKeyData_t? {
        guard conn != 0 else { return nil }
        var output = SMCKeyData_t()
        var outSize = MemoryLayout<SMCKeyData_t>.stride
        let r = IOConnectCallStructMethod(conn, Self.kSMCHandleYPCEvent,
                                          &input, MemoryLayout<SMCKeyData_t>.stride,
                                          &output, &outSize)
        return r == kIOReturnSuccess ? output : nil
    }

    struct KeyInfo { let type: String; let size: Int; let rawType: UInt32 }

    func keyInfo(_ key: String) -> KeyInfo? {
        var info = SMCKeyData_t()
        info.key = Self.fourCC(key)
        info.data8 = Self.cmdReadKeyInfo
        guard let ki = call(&info), ki.keyInfo.dataSize > 0, ki.keyInfo.dataSize <= 32 else { return nil }
        return KeyInfo(type: Self.typeString(ki.keyInfo.dataType),
                       size: Int(ki.keyInfo.dataSize), rawType: ki.keyInfo.dataType)
    }

    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let ki = keyInfo(key) else { return nil }
        var rd = SMCKeyData_t()
        rd.key = Self.fourCC(key)
        rd.keyInfo.dataSize = UInt32(ki.size)
        rd.data8 = Self.cmdReadBytes
        guard let out = call(&rd) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: out.bytes) { raw in for i in 0..<32 { bytes[i] = raw[i] } }
        return (ki.type, Array(bytes.prefix(ki.size)))
    }

    func readDouble(_ key: String) -> Double? {
        guard let (type, bytes) = read(key) else { return nil }
        return Self.decode(type: type, bytes: bytes)
    }
    func readInt(_ key: String) -> Int? { readDouble(key).map { Int($0.rounded()) } }

    static func decode(type: String, bytes b: [UInt8]) -> Double? {
        switch type {
        case "flt":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            let f = Float(bitPattern: bits); return f.isFinite ? Double(f) : nil
        case "ui8":  return b.count >= 1 ? Double(b[0]) : nil
        case "ui16": return b.count >= 2 ? Double(UInt16(b[0]) | (UInt16(b[1]) << 8)) : nil
        case "ui32": return b.count >= 4 ? Double(UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)) : nil
        case "sp78": return b.count >= 2 ? Double(Int16(bitPattern: (UInt16(b[0]) << 8) | UInt16(b[1]))) / 256.0 : nil
        case "fpe2": return b.count >= 2 ? Double(Int16(bitPattern: (UInt16(b[0]) << 8) | UInt16(b[1])) >> 2) : nil
        default:     return nil
        }
    }

    /// Encode a scalar into the wire bytes for a key's declared type. Apple
    /// Silicon fan keys are almost always `flt`; mode/force keys are `ui8`.
    static func encode(type: String, value: Double, size: Int) -> [UInt8]? {
        switch type {
        case "flt":
            let bits = Float(value).bitPattern
            var out = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
            while out.count < size { out.append(0) }
            return Array(out.prefix(max(size, 4)))
        case "ui8":  return [UInt8(clamping: Int(value.rounded()))]
        case "ui16":
            let v = UInt16(clamping: Int(value.rounded())); return [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
        case "ui32":
            let v = UInt32(clamping: Int(value.rounded()))
            return [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        default: return nil
        }
    }

    /// GUARDED WRITE (cmd 6, root-only). Reads the key's declared type/size,
    /// encodes `value`, and issues the write. Returns true iff the kernel
    /// accepted the call (NOT proof the firmware honored it — verify by reading
    /// F{n}Ac back). Refuses if the key is unknown.
    @discardableResult
    func write(_ key: String, value: Double) -> Bool {
        guard let ki = keyInfo(key), let payload = Self.encode(type: ki.type, value: value, size: ki.size) else {
            return false
        }
        var wr = SMCKeyData_t()
        wr.key = Self.fourCC(key)
        wr.data8 = Self.cmdWriteBytes
        wr.keyInfo.dataSize = UInt32(ki.size)
        wr.keyInfo.dataType = ki.rawType
        withUnsafeMutableBytes(of: &wr.bytes) { raw in
            for i in 0..<min(payload.count, 32) { raw[i] = payload[i] }
        }
        return call(&wr) != nil
    }

    /// #KEY holds the total key count as a BIG-ENDIAN ui32 (classic SMC), unlike
    /// the Apple-Silicon `flt` sensor values which are little-endian. Decoding it
    /// with the generic little-endian ui32 path yields a bogus huge number, so
    /// read it big-endian explicitly.
    func keyCount() -> Int? {
        guard let (_, b) = read("#KEY"), b.count >= 4 else { return nil }
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    func allKeys() -> [String] {
        guard let count = keyCount(), count > 0, count < 20000 else { return [] }
        var keys: [String] = []
        for i in 0..<count {
            var idx = SMCKeyData_t()
            idx.data8 = Self.cmdReadIndex
            idx.data32 = UInt32(i)
            guard let out = call(&idx), out.key != 0 else { continue }
            keys.append(Self.keyString(out.key))
        }
        return keys
    }
}

// MARK: - Fan model + helpers

struct Fan { let index: Int; let minRPM: Double?; let maxRPM: Double?; let actual: Double?; let target: Double?; let mode: Double? }

func fanCount(_ smc: SMC) -> Int {
    // FNum (ui8) is the canonical fan count key; fall back to probing F{0..9}Ac.
    if let n = smc.readInt("FNum"), n > 0, n < 10 { return n }
    var n = 0
    while n < 10, smc.read("F\(n)Ac") != nil { n += 1 }
    return n
}

func readFan(_ smc: SMC, _ i: Int) -> Fan {
    Fan(index: i,
        minRPM: smc.readDouble("F\(i)Mn"),
        maxRPM: smc.readDouble("F\(i)Mx"),
        actual: smc.readDouble("F\(i)Ac"),
        target: smc.readDouble("F\(i)Tg"),
        mode:   smc.readDouble("F\(i)Md"))
}

func fmt(_ d: Double?) -> String { d.map { String(format: "%.0f", $0) } ?? "—" }

// Left-pad-to-width WITHOUT %s (Swift's %s wants a C string, not a Swift String).
func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}

func dumpFans(_ smc: SMC) {
    let n = fanCount(smc)
    print("Fans detected: \(n)")
    print("  " + pad("idx", 5) + pad("actual", 9) + pad("min", 9) + pad("max", 9) + pad("target", 9) + "mode")
    for i in 0..<max(n, 0) {
        let f = readFan(smc, i)
        let modeStr = f.mode.map { $0 >= 1 ? "MANUAL(\(Int($0)))" : "auto(0)" } ?? "—"
        print("  " + pad("F\(i)", 5) + pad(fmt(f.actual), 9) + pad(fmt(f.minRPM), 9)
              + pad(fmt(f.maxRPM), 9) + pad(fmt(f.target), 9) + modeStr)
    }
    // The force/test key that Apple Silicon requires before manual writes take.
    for k in ["Ftst", "FS! "] {
        if let (t, b) = smc.read(k) { print("  \(k): type=\(t) raw=\(b.map { String(format: "%02x", $0) }.joined())") }
    }
}

// MARK: - Guarded manual-control sequence (Q-B)

let FTST = "Ftst"  // force/test enable; Apple Silicon overrides bare mode/target without it

func enterManual(_ smc: SMC, fan i: Int, rpm: Double) -> Bool {
    // Sequence under test: Ftst=1 → F{n}Md=1 → F{n}Tg=rpm, retried until F{n}Md reads back 1.
    _ = smc.write(FTST, value: 1)
    let deadline = Date().addingTimeInterval(6.0)
    var attempt = 0
    repeat {
        attempt += 1
        _ = smc.write("F\(i)Md", value: 1)     // 1 = manual
        _ = smc.write("F\(i)Tg", value: rpm)    // target RPM
        Thread.sleep(forTimeInterval: 0.5)
        let mode = smc.readDouble("F\(i)Md") ?? 0
        let tgt  = smc.readDouble("F\(i)Tg") ?? 0
        print(String(format: "  attempt %d: F%dMd=%.0f F%dTg=%.0f  actual=%@", attempt, i, mode, i, tgt, fmt(smc.readDouble("F\(i)Ac"))))
        if mode >= 1 && abs(tgt - rpm) < max(50, rpm * 0.1) { return true }
    } while Date() < deadline
    return false
}

func revertAuto(_ smc: SMC) {
    let n = fanCount(smc)
    for i in 0..<max(n, 0) { _ = smc.write("F\(i)Md", value: 0) }   // 0 = Apple auto
    _ = smc.write(FTST, value: 0)
}

// MARK: - Signal / atexit safety net (does NOT cover kill -9 — that's Q-C)

var gSMCForCleanup: SMC?
var gCleanupDone = false
func cleanupRestore() {
    guard !gCleanupDone, let smc = gSMCForCleanup else { return }
    gCleanupDone = true
    FileHandle.standardError.write("\n[cleanup] restoring Apple auto (Ftst=0, F*Md=0)\n".data(using: .utf8)!)
    revertAuto(smc)
}
func installSignalHandlers() {
    atexit { cleanupRestore() }
    for s in [SIGINT, SIGTERM, SIGHUP] {
        signal(s) { _ in cleanupRestore(); exit(128) }
    }
    // NOTE: SIGKILL (kill -9) CANNOT be trapped — that is exactly what revert-test probes.
}

// MARK: - CLI

func requireRootAndConsent() {
    if geteuid() != 0 {
        FileHandle.standardError.write("refusing: write modes require root — run with sudo.\n".data(using: .utf8)!)
        exit(2)
    }
    if !CommandLine.arguments.contains("--i-understand-this-writes-smc-as-root") {
        FileHandle.standardError.write("refusing: pass --i-understand-this-writes-smc-as-root to enable SMC writes.\n".data(using: .utf8)!)
        exit(2)
    }
}

func intArg(_ name: String) -> Int? {
    guard let idx = CommandLine.arguments.firstIndex(of: name), idx + 1 < CommandLine.arguments.count else { return nil }
    return Int(CommandLine.arguments[idx + 1])
}

func clampTarget(_ smc: SMC, fan i: Int, rpm: Double) -> Double? {
    guard let mn = smc.readDouble("F\(i)Mn"), let mx = smc.readDouble("F\(i)Mx"), mx > 0, mx >= mn else {
        FileHandle.standardError.write("refusing: F\(i)Mn/F\(i)Mx unreadable — cannot clamp safely.\n".data(using: .utf8)!)
        return nil
    }
    let clamped = min(max(rpm, mn), mx)
    if clamped != rpm { print("  target \(Int(rpm)) clamped to firmware range [\(Int(mn)),\(Int(mx))] → \(Int(clamped))") }
    return clamped
}

guard let smc = SMC(), smc.isOpen else {
    FileHandle.standardError.write("could not open AppleSMC.\n".data(using: .utf8)!)
    exit(1)
}

let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "read"

switch cmd {
case "read":
    dumpFans(smc)

case "keys":
    let filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
    for k in smc.allKeys() where filter.isEmpty || k.contains(filter) {
        if let ki = smc.keyInfo(k) { print("  \(k)  type=\(ki.type) size=\(ki.size)  value=\(smc.readDouble(k).map { String(format: "%.2f", $0) } ?? "?")") }
    }

case "set":
    requireRootAndConsent()
    guard let fan = intArg("--fan"), let rpmI = intArg("--rpm") else {
        print("usage: set --fan N --rpm R [--hold S] --i-understand-this-writes-smc-as-root"); exit(2)
    }
    let hold = intArg("--hold") ?? 20
    guard let target = clampTarget(smc, fan: fan, rpm: Double(rpmI)) else { exit(2) }
    gSMCForCleanup = smc; installSignalHandlers()
    print("[set] fan F\(fan) → \(Int(target)) rpm, holding \(hold)s, then auto-revert. (Ctrl-C reverts early.)")
    if enterManual(smc, fan: fan, rpm: target) {
        print("[set] firmware ACCEPTED manual control (F\(fan)Md=1). Q-A/Q-B = works.")
    } else {
        print("[set] firmware did NOT accept manual control within 6s. Note the Ftst/sequence findings for M0.")
    }
    for s in stride(from: 0, to: hold, by: 2) {
        Thread.sleep(forTimeInterval: 2)
        print(String(format: "  t+%02ds  F%dAc=%@ (target %d)", s + 2, fan, fmt(smc.readDouble("F\(fan)Ac")), Int(target)))
    }
    cleanupRestore()
    print("[set] reverted to auto.")

case "revert-test":
    // Q-C: the safety crux. Sets manual, then WAITS while printing this PID so the
    // owner can `sudo kill -9 <pid>` from another terminal — simulating a crash
    // that runs NO cleanup — and then observe (via a separate `read`) whether and
    // how fast the firmware self-reverts F{n}Md to 0. Ctrl-C here still cleans up.
    requireRootAndConsent()
    guard let fan = intArg("--fan"), let rpmI = intArg("--rpm") else {
        print("usage: revert-test --fan N --rpm R --i-understand-this-writes-smc-as-root"); exit(2)
    }
    guard let target = clampTarget(smc, fan: fan, rpm: Double(rpmI)) else { exit(2) }
    gSMCForCleanup = smc; installSignalHandlers()
    _ = enterManual(smc, fan: fan, rpm: target)
    print("""

    ================= Q-C: SIGKILL REVERT TEST =================
    Fan F\(fan) is now in MANUAL at \(Int(target)) rpm.
    THIS PROCESS PID = \(getpid())

    In ANOTHER terminal, run:   sudo kill -9 \(getpid())
    Then IMMEDIATELY, repeatedly run in that terminal:
        sudo swift \(CommandLine.arguments[0]) read
    and watch F\(fan)'s `mode` column + `actual` RPM.

    RECORD: does F\(fan)Md return to auto(0) on its own? After how many seconds?
      - reverts quickly  → firmware self-reverts; a watchdog is still advisable.
      - stays MANUAL      → NO-GO without an always-running root watchdog + the
                             machine could overheat if target was low. Treat as
                             a hard blocker for shipping fan control.
    (If you DON'T kill -9, this auto-reverts in 120s or on Ctrl-C.)
    ===========================================================

    """)
    Thread.sleep(forTimeInterval: 120)
    cleanupRestore()

case "restore":
    requireRootAndConsent()
    print("[restore] forcing every fan back to Apple auto…")
    revertAuto(smc)
    dumpFans(smc)

default:
    print("""
    M0 fan-feasibility spike (throwaway, root, Apple Silicon)
      read                                          safe: dump fan keys
      keys [FILTER]                                 safe: list SMC keys
      set --fan N --rpm R [--hold S] --i-understand-this-writes-smc-as-root
      revert-test --fan N --rpm R --i-understand-this-writes-smc-as-root
      restore --i-understand-this-writes-smc-as-root
    """)
}

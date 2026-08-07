#if os(macOS)
import Foundation
import OSLog

/// v1.46 — a health signal for the bundled `cli_pulse_helper` LaunchAgent that
/// can tell "registered and running" apart from "registered and failing to
/// spawn".
///
/// ## Why this exists
///
/// Everything the app previously used as a helper-agent health signal reports
/// success for a job that has never once executed. Measured on a real machine
/// on 2026-08-07, where `yyh.CLI-Pulse.helper.agent` had failed to spawn
/// **22,138 consecutive times** over ~11 days:
///
///   * `SMAppService.agent(...).status` → `.enabled`
///   * `SMAppService.agent(...).register()` → returns without throwing
///   * `launchctl kickstart -k gui/501/<label>` → **exit code 0**, while the
///     job it just kickstarted failed to exec milliseconds later
///
/// So `HelperLifecycleManager.Status.registered` means "launchd accepted the
/// plist", not "the helper is running". The distinction was invisible, which is
/// why nobody noticed for eleven days. `feedback_status_labels_that_lie.md`.
///
/// The only signal that does distinguish the two is launchd's own job record,
/// which `launchctl print gui/<uid>/<label>` prints:
///
/// ```
///     state = spawn scheduled          <- not "running"
///     parent bundle version = 96       <- frozen at registration time
///     runs = 22138
///     last exit code = 78: EX_CONFIG
///     job state = spawn failed
/// ```
///
/// ## What EX_CONFIG actually means here
///
/// The agent plist uses `BundleProgram` — a path *relative to the app bundle
/// that registered the job* (`Contents/Helpers/cli_pulse_helper`). launchd
/// resolves it against the parent bundle recorded in the registration, and
/// that recording is frozen: it survives an in-place app update untouched
/// (verified — `parent bundle version` stays at the registering build's number
/// forever, as do the plist's `ProgramArguments`).
///
/// Freezing the *path* is what kills it. When the bundle that registered the
/// job is no longer at that path, every spawn fails:
///
/// ```
/// launchd: Could not find and/or execute program specified by service:
///          3: No such process: Contents/Helpers/cli_pulse_helper
/// ```
///
/// → `EX_CONFIG` (78). Reproduced end-to-end with a signed throwaway app
/// (2026-08-07). The reproduction that matters is an ordinary user path, not a
/// developer one: **run the app once from the mounted DMG, then drag it to
/// /Applications and eject.** The agent is now bound to
/// `/Volumes/CLI Pulse/CLI Pulse.app`, which no longer exists, and every later
/// launch from `/Applications` calls `register()`, gets `.enabled` back, and
/// changes nothing. Moving or renaming the app after install does the same.
///
/// A plain in-place update — replace the bundle at the same path, which is what
/// the DMG drag-replace, the in-app updater and `brew upgrade --cask` all do —
/// does **not** break it: launchd re-resolves the program by path at each spawn
/// and picks up the new binary. Only the recorded metadata goes stale.
///
/// Note the failure mode is specifically *path* resolution. A code-identity
/// mismatch (right path, wrong signing identity) fails differently and is
/// reported by launchd as `last exit reason = OS_REASON_CODESIGNING`, so the
/// two are distinguishable here rather than collapsing into one "broken".
///
/// ## Recovery
///
/// `unregister()` then `register()` from the running bundle. Verified: rebinds
/// the parent bundle, resets `runs` to 1, and picks up the current plist's
/// `ProgramArguments`. `register()` alone never rebinds — that is the whole
/// bug. (`launchctl bootout` followed by a later `register()` also works, but
/// it needs an exec and only the API path works from every build flavour.)
public struct HelperAgentHealth: Sendable, Equatable {

    /// What the launchd job record actually says, reduced to the four states
    /// worth acting on.
    public enum Verdict: Sendable, Equatable, CustomStringConvertible {
        /// launchd has the job and it is running. The only good state.
        case running
        /// launchd has never heard of this label in the user's GUI domain.
        case notRegistered
        /// Registered, and launchd is trying — and failing — to exec it. The
        /// state that used to be indistinguishable from `.running`. Detail is
        /// launchd's own exit reason (`78: EX_CONFIG`, `OS_REASON_CODESIGNING`).
        case spawnFailing(String)
        /// Registered and not visibly failing, but bound to a different app
        /// build than the one now running. Not itself a fault — a healthy job
        /// stays pinned to the registering build's number across an in-place
        /// update — but it means the job's `ProgramArguments` and parent-bundle
        /// path are the old build's, so a re-register is due.
        case staleRegistration(recorded: String, current: String)
        /// Job record present but unreadable / in a transient state we should
        /// not act on (e.g. `state = xpcproxy` mid-exec).
        case indeterminate(String)

        public var description: String {
            switch self {
            case .running: return "running"
            case .notRegistered: return "notRegistered"
            case .spawnFailing(let d): return "spawnFailing(\(d))"
            case .staleRegistration(let r, let c): return "staleRegistration(recorded: \(r), current: \(c))"
            case .indeterminate(let s): return "indeterminate(\(s))"
            }
        }

        /// Whether a re-registration should be attempted. `.indeterminate` is
        /// deliberately excluded: we do not tear down a registration on a
        /// signal we could not read.
        public var needsRepair: Bool {
            switch self {
            case .running, .indeterminate: return false
            case .notRegistered, .spawnFailing, .staleRegistration: return true
            }
        }
    }

    /// False when launchd has no job for the label at all.
    public var jobKnown: Bool
    /// Top-level `state = ` — `running`, `spawn scheduled`, `xpcproxy`, …
    public var state: String?
    /// `job state = ` — `running`, `spawn failed`, `exited`, …
    public var jobState: String?
    public var pid: Int?
    public var runs: Int?
    /// Numeric part of `last exit code = 78: EX_CONFIG`. Nil for
    /// `(never exited)` and for records that carry a `last exit reason` instead.
    public var lastExitCode: Int?
    /// Verbatim right-hand side of `last exit code = `, e.g. `78: EX_CONFIG`.
    public var lastExitCodeText: String?
    /// `last exit reason = ` — present instead of an exit code when the kernel
    /// refused the exec, e.g. `OS_REASON_CODESIGNING`.
    public var lastExitReason: String?
    /// `parent bundle version = ` — the CFBundleVersion of the app bundle that
    /// registered the job, frozen at registration time.
    public var parentBundleVersion: String?
    /// `program identifier = ` — the `BundleProgram` path launchd resolves.
    public var programIdentifier: String?

    public init(
        jobKnown: Bool = false,
        state: String? = nil,
        jobState: String? = nil,
        pid: Int? = nil,
        runs: Int? = nil,
        lastExitCode: Int? = nil,
        lastExitCodeText: String? = nil,
        lastExitReason: String? = nil,
        parentBundleVersion: String? = nil,
        programIdentifier: String? = nil
    ) {
        self.jobKnown = jobKnown
        self.state = state
        self.jobState = jobState
        self.pid = pid
        self.runs = runs
        self.lastExitCode = lastExitCode
        self.lastExitCodeText = lastExitCodeText
        self.lastExitReason = lastExitReason
        self.parentBundleVersion = parentBundleVersion
        self.programIdentifier = programIdentifier
    }

    // MARK: - Parsing

    /// Parse `launchctl print gui/<uid>/<label>` output.
    ///
    /// Only **top-level** keys are read — those indented with exactly one tab.
    /// The record nests `resource coalition` and `jetsam coalition` blocks that
    /// each contain their own `state = active` line at two tabs; matching those
    /// would make a crash-looping job read as "active" and reintroduce exactly
    /// the lie this type exists to remove.
    ///
    /// `exitCode` is launchctl's own exit status: non-zero (with "Could not
    /// find service" on stderr) means the label is not registered, which is a
    /// real answer rather than a failure to measure.
    public static func parse(launchctlPrint output: String, exitCode: Int32) -> HelperAgentHealth {
        guard exitCode == 0 else {
            return HelperAgentHealth(jobKnown: false)
        }
        var health = HelperAgentHealth(jobKnown: true)
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // Exactly one leading tab = top level. Two or more = inside a
            // nested block; skip.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let body = line.dropFirst()
            guard let eq = body.range(of: " = ") else { continue }
            let key = String(body[body.startIndex..<eq.lowerBound])
            let value = String(body[eq.upperBound...])
            switch key {
            case "state":                 health.state = value
            case "job state":             health.jobState = value
            case "pid":                   health.pid = Int(value)
            case "runs":                  health.runs = Int(value)
            case "parent bundle version": health.parentBundleVersion = value
            case "program identifier":    health.programIdentifier = value
            case "last exit reason":      health.lastExitReason = value
            case "last exit code":
                health.lastExitCodeText = value
                // "78: EX_CONFIG" -> 78; "0" -> 0; "(never exited)" -> nil.
                let head = value.prefix(while: { $0.isNumber })
                health.lastExitCode = head.isEmpty ? nil : Int(head)
            default:                      break
            }
        }
        return health
    }

    // MARK: - Verdict

    /// Reduce a parsed record to the verdict the app acts on.
    ///
    /// `currentBundleVersion` is the running app's `CFBundleVersion` — the same
    /// value launchd records as `parent bundle version`, so the two compare
    /// directly. Pass nil to skip the staleness check.
    ///
    /// Order is load-bearing: spawn failure outranks staleness (a job that is
    /// failing *and* pinned to the current build must still report as failing),
    /// and staleness outranks running (a healthy job pinned to the previous
    /// build still needs re-registering to pick up the new binary and the new
    /// plist's arguments).
    public static func verdict(
        for health: HelperAgentHealth,
        currentBundleVersion: String?
    ) -> Verdict {
        guard health.jobKnown else { return .notRegistered }

        let running = health.state == "running"

        // launchd told us the last exec attempt failed. Any one of these is
        // sufficient; a record can carry an exit code OR a kernel exit reason,
        // not necessarily both.
        if !running {
            if health.jobState == "spawn failed" {
                let detail = health.lastExitReason
                    ?? health.lastExitCodeText
                    ?? health.state
                    ?? "spawn failed"
                return .spawnFailing(detail)
            }
            if let reason = health.lastExitReason {
                return .spawnFailing(reason)
            }
            if let code = health.lastExitCode, code != 0 {
                return .spawnFailing(health.lastExitCodeText ?? "\(code)")
            }
        }

        if let current = currentBundleVersion,
           let recorded = health.parentBundleVersion,
           recorded != current
        {
            return .staleRegistration(recorded: recorded, current: current)
        }

        if running { return .running }

        // Registered, no failure reported, not running: KeepAlive between
        // restarts, mid-exec (`xpcproxy`), or a clean exit awaiting respawn.
        // Not something to tear down a registration over.
        return .indeterminate(health.state ?? "unknown")
    }
}

/// Runs `launchctl print` and hands back the raw output. Split out from
/// `HelperAgentHealth` so the parsing and the verdict stay pure and testable
/// while the process spawn — the untestable part — has no logic in it.
public enum HelperAgentInspector {

    private static let logger = Logger(subsystem: "yyh.CLI-Pulse", category: "HelperAgentHealth")

    /// Read the launchd job record for `label` in the calling user's GUI
    /// domain. Returns nil only when `launchctl` could not be run at all (so
    /// the caller can distinguish "no answer" from "answered: not registered").
    ///
    /// Reads the pipe to EOF *before* `waitUntilExit()`: `launchctl print` emits
    /// a few KB and the opposite order deadlocks once the pipe buffer fills.
    public static func inspect(
        label: String,
        uid: uid_t = getuid(),
        timeout: TimeInterval = 5
    ) -> HelperAgentHealth? {
        let target = "gui/\(uid)/\(label)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["print", target]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            logger.error("launchctl print \(target, privacy: .public) could not be run: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Watchdog: a wedged launchctl must not hold up app launch.
        let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        deadline.cancel()

        let output = String(data: data, encoding: .utf8) ?? ""
        return HelperAgentHealth.parse(launchctlPrint: output, exitCode: proc.terminationStatus)
    }
}
#endif

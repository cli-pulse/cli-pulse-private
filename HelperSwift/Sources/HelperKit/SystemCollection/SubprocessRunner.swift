import Foundation
import Darwin

/// Shared utility for running short bounded subprocesses (`vm_stat`,
/// `ps`, etc.) used by the collectors. Combines three invariants the
/// naive `Process` + `waitUntilExit` pattern gets wrong:
///
///   1. **Concurrent stdout drain** — pipes to `Pipe()` and drains it
///      while the child runs, so the child never blocks on the OS pipe
///      buffer (~64 KB on macOS). Without this, a `ps`/`vm_stat` that
///      emits more than the buffer holds blocks on `write()` until the
///      parent reads, but the parent is busy waiting for the child
///      to exit — classic deadlock.
///
///   2. **Cooperative cancellation** — uses `try await Task.sleep(...)`
///      in the polling loop so the outer task can cancel us. Wraps
///      the whole thing in `withTaskCancellationHandler` so cancel
///      reaps the child cleanly.
///
///   3. **Hard timeout with SIGTERM grace + SIGKILL** — bounded by
///      `timeoutSeconds`. On expiry we `process.terminate()` (SIGTERM),
///      give the child up to 1 s to exit (not a `Task.sleep`, which
///      would honour an outer cancel and skip the grace), then
///      `kill(pid, SIGKILL)` if still alive.
///
/// **No blocking call runs on the Swift cooperative pool** (1.63.1).
/// That pool is only `activeProcessorCount` threads wide (3-4 on a CI
/// runner, 8-12 on a Mac), and every `await` in the helper — including
/// the 50 ms deadline loop below — needs one of those threads to resume.
/// Until 1.63.1 the drain was `Task.detached { readDataToEndOfFile() }`,
/// a read that holds its pool thread until the child exits, and the
/// grace was a `Thread.sleep(1)` on a pool thread. One machine snapshot
/// starts nine oracles at once, so it alone could occupy the whole pool
/// on a busy Mac; the deadline loop then could not run, the 2 s oracle
/// timeout did not fire, and `get_machine_snapshot` replies took 10-30 s
/// (measured 2026-11-19 with every core loaded). The client gives up
/// after its reply budget and the Machine tab said "Can't reach the
/// helper". Now the drain reads on its own `Thread` and hands the bytes
/// over through a continuation, and the reap runs on `reapQueue`; the
/// awaiting task is suspended, not parked on a pool thread.
///
/// Phase 4E Slice 2a Gemini P0/P1 fix — replaces the per-collector
/// hand-rolled subprocess code which had a `semaphore.wait()` /
/// `Thread.sleep` polling loop that could deadlock the cooperative
/// thread pool and ignored cancellation.
public enum SubprocessRunner {

    /// Granular result of a subprocess run. `KeychainReader` and other
    /// callers need to distinguish "process exited with code 44 because
    /// the Keychain item doesn't exist" from "watchdog tripped" — the
    /// former should not trigger a 24 h denial cache, the latter
    /// should. (Phase 4E Slice 2b Gemini P0.)
    public enum RunResult: Sendable, Equatable {
        /// `executable` exited 0. Returns its full stdout (may be empty).
        case success(stdout: String)
        /// `executable` exited non-zero. Returns the exit code AND
        /// whatever stdout was captured before exit (often empty for
        /// CLI tools that print errors to stderr only). Stderr is
        /// always discarded by this runner.
        case nonZeroExit(code: Int32, stdout: String)
        /// `Process.run()` itself threw — usually `executable` doesn't
        /// exist, or the spawn was denied by sandbox / SIP rules.
        case spawnError
        /// Hard `timeoutSeconds` deadline elapsed. The child is reaped
        /// (SIGTERM + 1 s grace + SIGKILL).
        case timedOut
        /// Outer task was cancelled before the child exited. The child
        /// is reaped as for `timedOut`.
        case cancelled
    }

    /// Granular variant — returns the exit code so callers like
    /// `KeychainReader` can disambiguate "service not found" (44)
    /// from "user denied" / "watchdog tripped".
    public static func runCapturingExit(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // Discarded. The null device rather than a `Pipe()` nobody reads:
        // an unread pipe blocks a child that writes more than ~64 KB of
        // errors, which would then sit until the timeout kills it.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // Nothing was spawned, so nothing will close the write end and
            // a drain would wait for EOF forever. None is started yet; close
            // both ends here.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            return .spawnError
        }

        // Started after a successful spawn: a child that fills the pipe
        // before this line just waits on `write()` for a moment.
        let drainTask = startDrain(stdoutPipe.fileHandleForReading)

        let reaper = ChildReaper(process: process, pid: process.processIdentifier)
        let deadlineNs = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutSeconds * 1_000_000_000)

        // Which outcome is reported is decided exactly as before: the
        // deadline loop throws `.timedOut`; anything else it throws is the
        // `Task.sleep` cancellation. Only the cleanup moved off the pool.
        enum WaitOutcome { case exited, timedOut, cancelled }
        var outcome: WaitOutcome = .exited
        do {
            try await withTaskCancellationHandler {
                while process.isRunning {
                    if DispatchTime.now().uptimeNanoseconds > deadlineNs {
                        throw RunnerError.timedOut
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } onCancel: {
                // Synchronous handler, may run on any thread: start the
                // reap without blocking the canceller. The catch below
                // awaits the same reaper, which runs its sequence once.
                Self.reapQueue.async { reaper.terminateAndReap() }
            }
        } catch RunnerError.timedOut {
            outcome = .timedOut
            await reap(reaper)
        } catch {
            outcome = .cancelled
            await reap(reaper)
        }

        switch outcome {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .exited:
            // Waits for EOF, as before: a child that hands its stdout to a
            // longer-lived descendant would hold this. None of the callers'
            // tools (ps, ioreg, pmset, vm_stat, sysctl, security, …) do.
            // The wait is a suspension now, not a parked pool thread.
            let data = await drainTask.value
            let stdout = String(data: data, encoding: .utf8) ?? ""
            let code = process.terminationStatus
            if code == 0 { return .success(stdout: stdout) }
            return .nonZeroExit(code: code, stdout: stdout)
        }
    }

    /// Convenience wrapper for callers that don't care about exit-code
    /// distinctions: returns stdout on success, `nil` on any failure.
    /// Existing 2a callers (`DeviceSnapshotCollector`, `SessionDetector`)
    /// continue to use this; KeychainReader uses `runCapturingExit`.
    public static func run(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> String? {
        switch await runCapturingExit(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        ) {
        case .success(let stdout): return stdout
        case .nonZeroExit, .spawnError, .timedOut, .cancelled: return nil
        }
    }

    private enum RunnerError: Error {
        case timedOut
    }

    // MARK: - Off-pool plumbing (1.63.1)

    /// Where the SIGTERM → grace → SIGKILL sequence blocks. Concurrent, so
    /// one child's 1 s grace never delays another's.
    private static let reapQueue = DispatchQueue(
        label: "cli-pulse.subprocess-reap",
        qos: .default,
        attributes: .concurrent
    )

    /// Reads `handle` to EOF on a dedicated thread. The returned task
    /// suspends on a continuation meanwhile, so no cooperative-pool thread
    /// is held for as long as the child runs. The thread ends at EOF, i.e.
    /// when the child (and anything it handed the pipe to) has exited.
    private static func startDrain(_ handle: FileHandle) -> Task<Data, Never> {
        Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
                let thread = Thread {
                    let data = handle.readDataToEndOfFile()
                    cont.resume(returning: data)
                }
                thread.name = "cli-pulse-subprocess-drain"
                thread.start()
            }
        }
    }

    /// `ChildReaper.terminateAndReap` on `reapQueue`, awaited: the caller
    /// returns only once the child has been dealt with, as before.
    private static func reap(_ reaper: ChildReaper) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Self.reapQueue.async {
                reaper.terminateAndReap()
                cont.resume()
            }
        }
    }
}

/// One child's SIGTERM → grace → SIGKILL sequence, run at most once.
///
/// Cancellation (from `onCancel`) and the runner's own catch path can both
/// ask for it. The lock makes the second caller wait for the first to finish
/// and then find the child gone, so the signals go out once and neither
/// caller returns while the child may still be alive. Only ever called on
/// `SubprocessRunner.reapQueue`: it blocks.
private final class ChildReaper: @unchecked Sendable {
    private let process: Process
    private let pid: pid_t
    private let lock = NSLock()

    init(process: Process, pid: pid_t) {
        self.process = process
        self.pid = pid
    }

    func terminateAndReap() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        process.terminate()
        if waitForExit(nanoseconds: 1_000_000_000) { return }
        kill(pid, SIGKILL)
        // `isRunning` turns false when Foundation has reaped the child, so
        // waiting for it (rather than returning right after the signal)
        // means the child is really gone. SIGKILL cannot be ignored; the
        // bound only guards against a child stuck in uninterruptible I/O.
        _ = waitForExit(nanoseconds: 1_000_000_000)
    }

    /// Polls `isRunning` for up to `nanoseconds`; true once it is false.
    private func waitForExit(nanoseconds: UInt64) -> Bool {
        let end = DispatchTime.now().uptimeNanoseconds + nanoseconds
        while process.isRunning {
            if DispatchTime.now().uptimeNanoseconds >= end { return false }
            usleep(20_000)
        }
        return true
    }
}

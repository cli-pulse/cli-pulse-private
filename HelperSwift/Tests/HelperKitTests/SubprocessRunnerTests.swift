import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// 1.63.1 — `SubprocessRunner` must never park a Swift cooperative-pool thread.
///
/// Found 2026-11-19: on a busy Mac the Machine tab flashed "Can't reach the
/// helper". A thread sample of the 1.63.0 helper showed ten cooperative-pool
/// threads — the whole pool on that 10-core Mac — blocked in `read(2)` inside
/// the runner's stdout drain (`Task.detached { readDataToEndOfFile() }`), plus
/// one in the sensor read. `get_machine_snapshot` replies took 10-30 s.
///
/// Every test here drives the runner from `Task.detached` and waits on a
/// semaphore from the test's own thread, so the waiting never depends on the
/// pool being healthy — that is the property under test.
final class SubprocessRunnerTests: XCTestCase {

    // MARK: - The regression

    /// While more children than the pool is wide are running, a task that
    /// needs a pool thread still gets one at once.
    ///
    /// Old runner: each child's drain held a pool thread (at `.utility`)
    /// until the child exited, so the probe (also `.utility`) waited the full
    /// 4 s. New runner: drains read on their own threads.
    func testRunningChildrenDoNotHoldCooperativePoolThreads() throws {
        let n = ProcessInfo.processInfo.activeProcessorCount + 2
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var runs: [Task<SubprocessRunner.RunResult, Never>] = []
        for i in 0..<n {
            let marker = dir.appendingPathComponent("\(i)").path
            runs.append(Task.detached {
                await SubprocessRunner.runCapturingExit(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "touch \"$0\"; exec sleep 4", marker],
                    timeoutSeconds: 10
                )
            })
        }
        defer { runs.forEach { $0.cancel() } }

        // Spawns happen in the runner tasks; give them a moment (polled on
        // this thread, not the pool).
        let started = waitForFiles(in: dir, count: n, timeout: 3)

        let probeDone = DispatchSemaphore(value: 0)
        let t0 = DispatchTime.now().uptimeNanoseconds
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(10))
            probeDone.signal()
        }
        let probeOK = probeDone.wait(timeout: .now() + 1.5) == .success
        let probeMs = (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000

        XCTAssertEqual(started, n, "every child should have started")
        XCTAssertTrue(probeOK, "a 10 ms task waited \(probeMs) ms for a pool thread while \(n) children ran — the runner is parking pool threads again")
    }

    // MARK: - Contract the callers rely on

    /// A spawn failure returns at once and leaks nothing. The old runner
    /// started its drain before `run()`, and on failure nothing ever closed
    /// the pipe's write end: the drain waited for EOF forever, holding its
    /// pool thread and four file descriptors per failure.
    func testSpawnFailureReturnsSpawnErrorAndLeaksNoDescriptors() {
        let before = openDescriptorCount()
        for _ in 0..<20 {
            let r = runSync(timeout: 5) {
                await SubprocessRunner.runCapturingExit(
                    executable: URL(fileURLWithPath: "/nonexistent/cli-pulse-test-binary"),
                    arguments: [],
                    timeoutSeconds: 2
                )
            }
            XCTAssertEqual(r, .spawnError)
        }
        let after = openDescriptorCount()
        XCTAssertLessThanOrEqual(after, before + 2, "spawn failures leaked descriptors: \(before) → \(after)")
    }

    /// Output larger than the pipe buffer is read in full.
    func testLargeStdoutIsReadInFull() {
        let r = runSync(timeout: 10) {
            await SubprocessRunner.runCapturingExit(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 204800 /dev/zero | tr '\\000' a"],
                timeoutSeconds: 5
            )
        }
        guard case .success(let out)? = r else {
            return XCTFail("expected success, got \(String(describing: r))")
        }
        XCTAssertEqual(out.count, 204_800)
    }

    /// A child that writes more than the pipe buffer to stderr still
    /// finishes. The old runner gave stderr a `Pipe()` nobody read, so such a
    /// child blocked on `write()` until the timeout killed it.
    func testLargeStderrDoesNotBlockTheChild() {
        let r = runSync(timeout: 10) {
            await SubprocessRunner.runCapturingExit(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 204800 /dev/zero >&2; echo done"],
                timeoutSeconds: 5
            )
        }
        XCTAssertEqual(r, .success(stdout: "done\n"))
    }

    /// Non-zero exit keeps its code and the stdout written before it —
    /// `KeychainReader` tells "item not found" (44) apart this way.
    func testNonZeroExitKeepsCodeAndStdout() {
        let r = runSync(timeout: 10) {
            await SubprocessRunner.runCapturingExit(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo partial; exit 44"],
                timeoutSeconds: 5
            )
        }
        XCTAssertEqual(r, .nonZeroExit(code: 44, stdout: "partial\n"))
    }

    /// A child that ignores SIGTERM is killed after the grace, the runner
    /// reports `.timedOut`, and the child is gone when it returns.
    func testTimeoutKillsAChildThatIgnoresTerm() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid").path

        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = runSync(timeout: 15) {
            await SubprocessRunner.runCapturingExit(
                executable: URL(fileURLWithPath: "/bin/sh"),
                // An ignored signal stays ignored across exec, and exec keeps
                // the pid, so the pid file names the process that must die.
                arguments: ["-c", "echo $$ > \"$0\"; trap '' TERM; exec sleep 30", pidFile],
                timeoutSeconds: 0.5
            )
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9

        XCTAssertEqual(r, .timedOut)
        // 0.5 s deadline + 1 s TERM grace + the KILL, with room for a slow runner.
        XCTAssertLessThan(seconds, 6, "took \(seconds) s")
        if let pid = readPid(pidFile) {
            XCTAssertFalse(processExists(pid), "child \(pid) survived the timeout")
        } else {
            XCTFail("child never wrote its pid")
        }
    }

    /// Cancelling the caller reaps the child and reports `.cancelled`.
    func testCancellationReapsTheChild() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid").path

        let finished = DispatchSemaphore(value: 0)
        let box = ResultBox<SubprocessRunner.RunResult>()
        let task = Task.detached {
            let r = await SubprocessRunner.runCapturingExit(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \"$0\"; exec sleep 30", pidFile],
                timeoutSeconds: 20
            )
            box.set(r)
            finished.signal()
        }
        XCTAssertEqual(waitForFiles(in: dir, count: 1, timeout: 5), 1, "child never started")
        // The pid file can exist before its content is flushed.
        let pid = waitForPid(pidFile, timeout: 2)
        task.cancel()

        XCTAssertEqual(finished.wait(timeout: .now() + 6), .success, "runner did not return after cancel")
        XCTAssertEqual(box.get(), .cancelled)
        if let pid {
            XCTAssertFalse(processExists(pid), "child \(pid) survived cancellation")
        } else {
            XCTFail("child never wrote its pid")
        }
    }

    // MARK: - Helpers (none of them needs the cooperative pool to be free)

    private func runSync(
        timeout: TimeInterval,
        _ body: @escaping @Sendable () async -> SubprocessRunner.RunResult
    ) -> SubprocessRunner.RunResult? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<SubprocessRunner.RunResult>()
        Task.detached {
            box.set(await body())
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.get()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subprocess-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitForFiles(in dir: URL, count: Int, timeout: TimeInterval) -> Int {
        let end = Date().addingTimeInterval(timeout)
        var n = 0
        repeat {
            n = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
            if n >= count { return n }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < end
        return n
    }

    private func readPid(_ path: String) -> pid_t? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func waitForPid(_ path: String, timeout: TimeInterval) -> pid_t? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let pid = readPid(path) { return pid }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < end
        return nil
    }

    /// The child is this test process's own child, so until Foundation has
    /// reaped it — even as a zombie — `kill(pid, 0)` succeeds. The runner
    /// returns only after the reap, so by then it must fail with ESRCH.
    private func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
}

/// Lock-protected slot for handing a result from a task to the test thread.
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ v: T) {
        lock.lock()
        value = v
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

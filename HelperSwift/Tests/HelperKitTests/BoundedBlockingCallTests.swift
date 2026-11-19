import XCTest
@testable import HelperKit
import Foundation

/// 1.63.1 — the machine snapshot's sensor read is bounded in time and never
/// stacked behind a stuck read (`BoundedBlockingCall`). Driven from
/// `Task.detached` and awaited with semaphores on the test thread, as in
/// `SubprocessRunnerTests`.
final class BoundedBlockingCallTests: XCTestCase {

    func testFastWorkReturnsItsValue() {
        let call = BoundedBlockingCall<Int>(label: "test.fast")
        XCTAssertEqual(run(call, timeout: 2, work: { 42 }), .value(42))
    }

    /// A read that outlives its budget gives the caller nil after the budget,
    /// not after the read.
    func testSlowWorkTimesOut() {
        let call = BoundedBlockingCall<Int>(label: "test.slow")
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = run(call, timeout: 0.2, work: { Thread.sleep(forTimeInterval: 1.5); return 1 })
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        XCTAssertEqual(r, .value(nil))
        XCTAssertLessThan(seconds, 1.2, "the caller waited for the work (\(seconds) s) instead of its 0.2 s budget")
    }

    /// While a timed-out read is still running, the next call returns nil at
    /// once and does not queue its own work behind it; once the stuck read
    /// ends, calls run again.
    func testNoNewWorkWhileAStuckReadIsStillRunning() {
        let call = BoundedBlockingCall<Int>(label: "test.stuck")
        let ran = Counter()
        let release = DispatchSemaphore(value: 0)

        XCTAssertEqual(run(call, timeout: 0.2, work: { release.wait(); return 1 }), .value(nil))

        let t0 = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(run(call, timeout: 2, work: { ran.increment(); return 2 }), .value(nil))
        let ms = (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        XCTAssertLessThan(ms, 500, "a call behind a stuck read should return at once, took \(ms) ms")
        XCTAssertEqual(ran.value, 0, "work was queued behind the stuck read")

        release.signal()
        // The stuck read clears `busy` when it returns; poll for that.
        let end = Date().addingTimeInterval(3)
        var last: Outcome = .value(nil)
        while Date() < end {
            last = run(call, timeout: 2, work: { ran.increment(); return 3 })
            if last == .value(3) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(last, .value(3))
        XCTAssertEqual(ran.value, 1)
    }

    // MARK: - Helpers

    enum Outcome: Equatable {
        case value(Int?)
        case hung
    }

    private func run(
        _ call: BoundedBlockingCall<Int>,
        timeout: TimeInterval,
        work: @escaping () -> Int
    ) -> Outcome {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<Int?>()
        Task.detached {
            box.set(await call.run(timeout: timeout, work))
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout + 3) == .success else { return .hung }
        return .value(box.get() ?? nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func increment() {
        lock.lock()
        n += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}

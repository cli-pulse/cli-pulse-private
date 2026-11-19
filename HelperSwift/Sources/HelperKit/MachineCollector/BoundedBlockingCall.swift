import Foundation

/// Runs a blocking closure on its own serial queue and waits for it for at
/// most `timeout`, suspended — never parking a Swift cooperative-pool thread.
///
/// 1.63.1, for the machine snapshot's sensor read. `SensorReader.read` blocks
/// for its 300 ms IOReport sample plus the SMC / HID reads and has no deadline
/// of its own. It used to run on a cooperative-pool thread inside the
/// snapshot's `async let` fan-out, and a thread sample of the 1.63.0 helper
/// under load showed it there, blocked, next to ten subprocess drains that
/// filled the pool (see `SubprocessRunner`).
///
/// Two bounds:
///  - **Time.** The caller gets `nil` after `timeout`; the work keeps running
///    on the queue and its late result is dropped.
///  - **Pile-up.** While a previous call's work is still running — including
///    one whose caller already gave up — a new call returns `nil` at once
///    instead of queueing more blocking work behind a stuck one.
final class BoundedBlockingCall<Value>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var busy = false

    init(label: String) {
        // `.default`, not `.utility`: this is on the RPC reply path, and the
        // helper already runs as a background launchd job.
        queue = DispatchQueue(label: label, qos: .default)
    }

    /// `work`'s result, or `nil` if it did not finish within `timeout` or a
    /// previous call's work is still running.
    func run(timeout: TimeInterval, _ work: @escaping () -> Value) async -> Value? {
        lock.lock()
        if busy {
            lock.unlock()
            return nil
        }
        busy = true
        lock.unlock()

        let gate = ResumeOnce<Value?>()
        return await withCheckedContinuation { (cont: CheckedContinuation<Value?, Never>) in
            gate.arm(cont)
            queue.async { [self] in
                let value = work()
                lock.lock()
                busy = false
                lock.unlock()
                gate.resume(value)
            }
            DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + timeout) {
                gate.resume(nil)
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of the result and the
/// deadline arrives first; the later one is dropped.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var done = false

    func arm(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: T) {
        lock.lock()
        guard !done, let continuation else {
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

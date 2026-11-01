// 1.61 (B3): what makes a deferred session restore try again before its next
// backoff tick.
//
// A cold launch that could not check its session (offline, a timeout, a 5xx)
// keeps its tokens and tries again 5 s later, doubling up to a minute
// (`AppState.applyDeferredSessionRestore`). Two moments are better than any
// tick: the app coming back to the front, and the network coming back. Each
// tries at once (`AppState.retryDeferredSessionRestoreNow`); the backoff stays
// as it was for everything else.

import Foundation
import Network

/// Watches for the network coming back: a path that was not satisfied
/// becoming satisfied. Behind a protocol so a test can say when.
protocol NetworkReturnWatching: AnyObject {
    /// Calls `onReturn` on the main actor each time the network comes back.
    func start(onReturn: @escaping @MainActor () -> Void)
    func cancel()
}

/// When a sequence of path updates means "the network came back".
///
/// `NWPathMonitor` reports the current path as soon as it starts, and again
/// on every change, including changes between two working paths (Wi-Fi to
/// Ethernet). Only a step from not satisfied to satisfied counts: the first
/// report is the state the watch started in, not a return.
struct NetworkReturnDetector: Equatable {
    private var wasSatisfied: Bool?

    init() {}

    /// Records an update; true when it is the network coming back.
    mutating func update(satisfied: Bool) -> Bool {
        defer { wasSatisfied = satisfied }
        return satisfied && wasSatisfied == false
    }
}

/// `NetworkReturnWatching` over `NWPathMonitor`. Started only while a restore
/// is deferred, and cancelled when that ends; a cancelled monitor cannot be
/// started again, so each deferral makes a new one.
final class NWPathNetworkReturnMonitor: NetworkReturnWatching, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.clipulse.deferred-restore.network")
    /// Read and written on `queue` only.
    private var detector = NetworkReturnDetector()

    func start(onReturn: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.detector.update(satisfied: path.status == .satisfied) else { return }
            Task { @MainActor in onReturn() }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

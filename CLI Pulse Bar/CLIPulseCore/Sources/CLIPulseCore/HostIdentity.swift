// 59-04 (1.59): this Mac's host name, read off the main thread.
//
// `ProcessInfo.processInfo.hostName` goes `-[NSHost name]` →
// `-[NSHost blockingResolveUntil:]`: it can wait on DNS. `DataRefreshManager`
// is `@MainActor`, and up to 1.58 it read it in every refresh, so a slow or unreachable
// resolver froze the menu bar. Every Sentry APPLE-MACOS-4 hang is
// `DataRefreshManager.refreshAll` → `ProcessInfo.hostName.getter` →
// `-[NSHost blockingResolveUntil:]`, in periodic refreshes during use, not at
// launch.
//
// The value is the same call as before, byte for byte: it names this Mac's
// rows in the Sessions tab and its local device row. Only the thread changes,
// and how often it is asked.
//
// `Host.current().localizedName` is not routed here. It makes none of the
// resolving `NSHost` calls (`testLocalizedNameMakesNoResolvingCall` measures
// that on whatever macOS runs the tests, CI's included), so it cannot wait on
// DNS.

import Foundation

public actor HostIdentity {
    public typealias Provider = @Sendable () -> String

    /// The one the app and the login item use.
    public static let shared = HostIdentity()

    /// How long a name is served before it is read again. The read after that
    /// runs in the background and the old name is served meanwhile, so only
    /// the very first caller ever waits.
    public static let defaultMaxAge: TimeInterval = 15 * 60

    private let provider: Provider
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: (name: String, readAt: Date)?
    private var reading: Task<String, Never>?

    /// `provider` is a seam for tests (a slow one that records its thread).
    /// It always runs on `readQueue`, never on the main thread.
    public init(
        provider: @escaping Provider = HostIdentity.liveHostName,
        maxAge: TimeInterval = HostIdentity.defaultMaxAge,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.maxAge = maxAge
        self.now = now
    }

    /// `ProcessInfo.processInfo.hostName`, read off the main thread. The
    /// first call waits for the read, so a caller never gets an empty or
    /// placeholder name; later calls return the cached one at once.
    public func hostName() async -> String {
        if let cached {
            if now().timeIntervalSince(cached.readAt) >= maxAge {
                _ = startReading()
            }
            return cached.name
        }
        return await startReading().value
    }

    /// One read at a time: callers that arrive while it runs share it.
    private func startReading() -> Task<String, Never> {
        if let reading { return reading }
        let provider = self.provider
        let task = Task<String, Never> {
            let name = await Self.read(provider)
            self.finishReading(name)
            return name
        }
        reading = task
        return task
    }

    private func finishReading(_ name: String) {
        cached = (name, now())
        reading = nil
    }

    /// A blocking call belongs on a thread of its own, not on the main thread
    /// and not on the cooperative pool that every `await` in the app shares.
    private static let readQueue = DispatchQueue(
        label: "com.clipulse.host-identity",
        qos: .utility
    )

    private static func read(_ provider: @escaping Provider) async -> String {
        await withCheckedContinuation { continuation in
            readQueue.async {
                #if DEBUG
                dispatchPrecondition(condition: .notOnQueue(.main))
                #endif
                continuation.resume(returning: provider())
            }
        }
    }

    /// The live provider. Only `HostIdentity` may call this API: the
    /// source-scan test allows `ProcessInfo.processInfo.hostName` in this file
    /// and holds every other one to its allowlist.
    public static let liveHostName: Provider = {
        ProcessInfo.processInfo.hostName
    }
}

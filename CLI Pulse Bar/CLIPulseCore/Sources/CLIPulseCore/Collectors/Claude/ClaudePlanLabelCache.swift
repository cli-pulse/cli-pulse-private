#if os(macOS)
import Foundation

/// What `/api/oauth/profile` says about the plan, kept per token so the
/// profile is asked at most once every 6 hours, not on every refresh.
///
/// Why the profile at all: the token's `rateLimitTier` and `subscriptionType`
/// are fixed at sign-in. After a plan change they keep the old plan; an Ultra
/// account's token still says `default_claude_max_20x`. The profile's
/// `plan_display_label` names the plan the account is on now ("Ultra plan"),
/// and its `rate_limit_tier` is the organization's current tier (it carries
/// the Max multiplier, which the label does not).
///
/// Off the usage path: `profile(forFingerprint:…)` answers with what is known
/// and, when that is stale, starts one read in the background (one per token
/// at a time); the next refresh shows its result. Only a token's very first
/// read is waited for, and for at most `firstReadWait`, so a launch does not
/// show the tier's plan name for one refresh and then change it.
///
/// A failed read keeps the last profile and is retried after 30 minutes; a
/// profile last confirmed more than a day ago is no longer given out.
///
/// In memory only, keyed by the same token fingerprint as
/// `ClaudeOAuthBackoffState` (never the token). Nothing is written to disk,
/// so another sign-in (another token) can never inherit this one's plan.
public actor ClaudePlanLabelCache {
    public static let shared = ClaudePlanLabelCache()

    /// How long a read is used before the profile is asked again.
    static let freshFor: TimeInterval = 6 * 60 * 60
    /// How long after a failed read before asking again.
    static let retryAfterFailure: TimeInterval = 30 * 60
    /// A profile not confirmed for this long is dropped.
    static let maxAge: TimeInterval = 24 * 60 * 60
    /// The longest a token's first read is waited for.
    public static let firstReadWait: TimeInterval = 1.5
    /// Tokens rotate; old fingerprints are dropped beyond this many.
    static let maxEntries = 8

    /// The two fields read from the profile; everything else in it is dropped.
    public struct Profile: Sendable, Equatable {
        public let planDisplayLabel: String?
        public let rateLimitTier: String?

        public init(planDisplayLabel: String?, rateLimitTier: String?) {
            self.planDisplayLabel = planDisplayLabel
            self.rateLimitTier = rateLimitTier
        }
    }

    public enum Outcome: Sendable, Equatable {
        case profile(Profile)
        case failed
    }

    private struct Entry {
        let profile: Profile?
        /// When the profile was last read successfully.
        let confirmedAt: Date?
        /// When it was last asked, successfully or not.
        let askedAt: Date
        let failed: Bool
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// The profile known for this token (nil before the first read lands, or
    /// once it is more than a day old). If it is stale and no read is
    /// running, starts one; a token's first read is waited for up to
    /// `firstReadWait` seconds.
    public func profile(
        forFingerprint fingerprint: String,
        firstReadWait: TimeInterval = ClaudePlanLabelCache.firstReadWait,
        fetch: @escaping @Sendable () async -> Outcome
    ) async -> Profile? {
        let entry = entries[fingerprint]
        let stale = entry.map {
            now().timeIntervalSince($0.askedAt) >= ($0.failed ? Self.retryAfterFailure : Self.freshFor)
        } ?? true
        if stale, inFlight[fingerprint] == nil {
            inFlight[fingerprint] = Task {
                let outcome = await fetch()
                self.store(outcome, for: fingerprint)
            }
        }
        if entry == nil, firstReadWait > 0, let task = inFlight[fingerprint] {
            await Self.wait(for: task, atMost: firstReadWait)
        }
        return current(fingerprint)
    }

    /// Waits for the reads that are running. For tests.
    func settle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    private func current(_ fingerprint: String) -> Profile? {
        guard let entry = entries[fingerprint], let confirmedAt = entry.confirmedAt,
              now().timeIntervalSince(confirmedAt) < Self.maxAge else { return nil }
        return entry.profile
    }

    private func store(_ outcome: Outcome, for fingerprint: String) {
        inFlight[fingerprint] = nil
        let at = now()
        switch outcome {
        case .profile(let profile):
            entries[fingerprint] = Entry(profile: profile, confirmedAt: at, askedAt: at, failed: false)
        case .failed:
            let previous = entries[fingerprint]
            entries[fingerprint] = Entry(profile: previous?.profile, confirmedAt: previous?.confirmedAt,
                                         askedAt: at, failed: true)
        }
        if entries.count > Self.maxEntries,
           let oldest = entries.min(by: { $0.value.askedAt < $1.value.askedAt })?.key {
            entries[oldest] = nil
        }
    }

    /// Returns when `task` finishes or after `seconds`, whichever is first.
    /// The task itself keeps running either way.
    private static func wait(for task: Task<Void, Never>, atMost seconds: TimeInterval) async {
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await task.value
                if once.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { continuation.resume() }
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
#endif

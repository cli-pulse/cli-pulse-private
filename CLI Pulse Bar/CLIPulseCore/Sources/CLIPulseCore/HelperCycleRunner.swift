import Foundation

/// The order of one LoginItem helper cycle, with every step injected.
///
/// `HelperDaemon` supplies the real steps; the helper target has no tests, so
/// the order that keeps a "Not now" from being read or sent lives here, where
/// `HelperCycleRunnerTests` can check it:
///
/// 1. Ask (`LocalCollectionPolicy.helperCycle`). Nothing is read unless the
///    answer and the account allow it.
/// 2. Collect.
/// 3. Ask again. An answer, sign-out or account switch that came while the
///    collectors ran drops what they read: nothing is written or sent.
/// 4. Write the results for the app on this Mac.
/// 5. Only for `.collectAndSync`, each upload step in order, asking again
///    before every one, with the pairing the cycle was decided with.
/// 6. Ask once more before reporting a sync.
///
/// The questions read the answer and the account afresh each time (two
/// app-group reads). The pairing, a Keychain read in the helper, is read only
/// by the questions before and after collecting, and only when the answer
/// depends on it.
public struct HelperCycleRunner<Collection> {
    public typealias UploadStep = (Collection, HelperConfig) async throws -> Void

    public enum Outcome {
        /// Nothing was read.
        case skipped(LocalCollectionPolicy.HelperCycle)
        /// Read, then dropped unwritten and unsent: the answer changed while
        /// the collectors ran.
        case dropped(LocalCollectionPolicy.HelperCycle)
        /// Read and written for the app; nothing uploaded, by decision.
        case collectedLocally
        /// Written for the app; stopped before an upload step, or before
        /// reporting a sync, because the answer or the account changed.
        case stopped(LocalCollectionPolicy.HelperCycle)
        /// Every upload step ran, and the answer still allowed it after.
        case synced(HelperConfig)
        /// An upload step threw; the ones after it did not run.
        case failed(HelperConfig, Error)
    }

    private let readConsent: () -> LocalScanConsent?
    private let readAccount: () -> HelperAccountRecord?
    private let readPairing: () -> HelperConfig?
    private let collect: () async -> Collection
    private let writeResults: (Collection) -> Void
    private let uploadSteps: [UploadStep]

    public init(
        readConsent: @escaping () -> LocalScanConsent?,
        readAccount: @escaping () -> HelperAccountRecord?,
        readPairing: @escaping () -> HelperConfig?,
        collect: @escaping () async -> Collection,
        writeResults: @escaping (Collection) -> Void,
        uploadSteps: [UploadStep]
    ) {
        self.readConsent = readConsent
        self.readAccount = readAccount
        self.readPairing = readPairing
        self.collect = collect
        self.writeResults = writeResults
        self.uploadSteps = uploadSteps
    }

    /// The question on its own, for a caller that only needs the answer (the
    /// helper, when the app says its inputs changed).
    public func ask() -> LocalCollectionPolicy.HelperCycle {
        decide(readPairing: readPairing).cycle
    }

    public func run() async -> Outcome {
        let first = decide(readPairing: readPairing)
        guard first.cycle.reads else { return .skipped(first.cycle) }

        let collection = await collect()

        let second = decide(readPairing: readPairing)
        guard second.cycle.reads else { return .dropped(second.cycle) }
        writeResults(collection)
        guard second.cycle == .collectAndSync, let pairing = second.pairing else {
            return .collectedLocally
        }

        for step in uploadSteps {
            let now = decide(readPairing: { pairing }).cycle
            guard now == .collectAndSync else { return .stopped(now) }
            do {
                try await step(collection, pairing)
            } catch {
                return .failed(pairing, error)
            }
        }
        let last = decide(readPairing: { pairing }).cycle
        guard last == .collectAndSync else { return .stopped(last) }
        return .synced(pairing)
    }

    /// Asks, reading the pairing at most once, and only if the answer needs it.
    private func decide(
        readPairing: () -> HelperConfig?
    ) -> (cycle: LocalCollectionPolicy.HelperCycle, pairing: HelperConfig?) {
        var pairingRead = false
        var pairing: HelperConfig?
        let cycle = LocalCollectionPolicy.helperCycle(
            mirroredConsent: readConsent(),
            account: readAccount(),
            pairedUserId: {
                if !pairingRead {
                    pairing = readPairing()
                    pairingRead = true
                }
                return pairing?.userId
            }
        )
        return (cycle, pairing)
    }
}

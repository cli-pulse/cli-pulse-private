import Foundation

/// Resolves the provider set a background helper is authorized to collect.
/// Missing or unreadable state fails closed instead of falling back to the
/// full provider catalog.
public struct ProviderCollectionAuthorization: Sendable {
    public let configs: [ProviderConfig]
    public let hasPersistentSelection: Bool

    public var enabledProviderKinds: Set<ProviderKind> {
        Set(configs.filter(\.isEnabled).map(\.kind))
    }

    public static func resolve(persistedData: Data?) -> Self {
        guard
            let persistedData,
            let configs = try? JSONDecoder().decode(
                [ProviderConfig].self,
                from: persistedData
            )
        else {
            return Self(configs: [], hasPersistentSelection: false)
        }

        return Self(configs: configs, hasPersistentSelection: true)
    }

    /// Only explicitly enabled accounts may hydrate Keychain-backed secrets.
    /// The consent gate is passed separately because a legacy all-enabled
    /// payload without a consent marker is catalog state, not authorization.
    public static func secretHydrationIndices(
        in configs: [ProviderConfig],
        consentRecorded: Bool = true
    ) -> [Int] {
        guard consentRecorded else { return [] }
        return configs.indices.filter { configs[$0].isEnabled }
    }

    #if os(macOS)
    /// Helper-facing process-scan seam. Missing, unreadable, or explicitly
    /// empty provider projections return before the scanner closure is called,
    /// so a login item cannot enumerate processes before provider consent.
    public func scanLocalProcesses(
        using scan: (Set<ProviderKind>) -> LocalScanResult
    ) -> LocalScanResult {
        let allowedKinds = enabledProviderKinds
        guard !allowedKinds.isEmpty else {
            return LocalScanResult(
                sessions: [],
                providers: [],
                totalUsage: 0,
                totalCost: 0,
                activeSessionCount: 0
            )
        }
        return scan(allowedKinds)
    }
    #endif
}

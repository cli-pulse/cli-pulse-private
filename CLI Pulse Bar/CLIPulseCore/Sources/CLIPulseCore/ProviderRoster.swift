import Foundation

// MARK: - Retired providers (1.57)
//
// Three providers CLI Pulse no longer reads. Their `ProviderKind` cases stay:
// configs saved by an older build, rows another device uploaded and archived
// history all name them by raw value, and must keep decoding. What changes is
// that nothing offers them, collects them or shows them:
//
// * the roster people pick from is `ProviderKind.offered`, never `allCases`
//   (`ProviderRosterReferenceTests` keeps it that way);
// * `CollectorRegistry` has no collector for them, so no request is sent;
// * their saved accounts are left out when configs are read
//   (`ProviderRoster.activeConfigs`) and dropped by the next save;
// * rows for them are left out where the apps commit rows for display
//   (`ProviderRoster.shown`): a device still on an older build may upload some.

/// Why a provider was retired.
public enum ProviderRetirement: Sendable, Equatable {
    /// The service shut down (Crof). Removed without a notice: there has been
    /// nothing to read since it closed.
    case serviceShutDown
    /// A relay whose operator CLI Pulse could not confirm: Kimi K2 (its
    /// collector read kimi-k2.ai, a different site from Moonshot's API, which
    /// the Moonshot provider reads) and CrossModel. CodexBar retired both for
    /// the same reason (0.44.0, "retire unverified provider relays"). Hidden;
    /// anyone who had one set up is told once (`RetiredProviderNotice`).
    case unconfirmedOperator
}

extension ProviderKind {
    /// Set for a provider CLI Pulse no longer reads; nil for every provider it
    /// offers.
    public var retirement: ProviderRetirement? {
        switch self {
        case .crof:
            return .serviceShutDown
        case .kimiK2, .crossModel:
            return .unconfirmedOperator
        default:
            return nil
        }
    }

    public var isRetired: Bool { retirement != nil }

    /// The providers CLI Pulse offers, in `allCases` order. A list a person
    /// picks from or reads iterates this, never `allCases`.
    public static let offered: [ProviderKind] = allCases.filter { !$0.isRetired }
}

public enum ProviderRoster {
    /// `configs` without retired providers' accounts, in the same order.
    public static func activeConfigs(
        _ configs: [ProviderConfig]
    ) -> [ProviderConfig] {
        configs.filter { !$0.kind.isRetired }
    }

    /// Provider rows for display, without retired providers' rows.
    public static func shown(_ usages: [ProviderUsage]) -> [ProviderUsage] {
        usages.filter { !isRetired(name: $0.provider) }
    }

    /// Account rows for display, without retired providers' rows.
    public static func shown(
        _ accounts: [ProviderAccountUsage]
    ) -> [ProviderAccountUsage] {
        accounts.filter { !$0.provider.isRetired }
    }

    /// Whether a provider name (a `ProviderKind` raw value) is retired. A name
    /// this build does not know is not.
    public static func isRetired(name: String) -> Bool {
        ProviderKind(rawValue: name)?.isRetired ?? false
    }

    /// The environment variables the Kimi K2 and CrossModel collectors read a
    /// key from before 1.57 (`KimiK2Collector.environmentKeys`,
    /// `CrossModelCollector.apiKeyEnv`). A key set there was sent to the relay
    /// as surely as one saved in CLI Pulse.
    static let unconfirmedOperatorEnvironmentKeys = [
        "KIMI_K2_API_KEY", "KIMI_API_KEY", "KIMI_KEY", "CROSSMODEL_API_KEY",
    ]

    /// Whether someone had a provider retired for `.unconfirmedOperator` set
    /// up, meaning its collector had a key to send: an account of one with a
    /// saved key or cookie, or a key in an environment variable the collector
    /// read. The account every install gets by default, untouched, is not
    /// "set up", and neither is one that only has a name: the notice is about
    /// a key, and they had none.
    ///
    /// `configs` must have their secrets loaded (`loadSecrets()`); without
    /// them a saved key does not count.
    public static func hadUnconfirmedOperatorSetUp(
        configs: [ProviderConfig],
        environment: [String: String]
    ) -> Bool {
        let configured = configs.contains { config in
            config.kind.retirement == .unconfirmedOperator
                && config.hasCredentials
        }
        if configured { return true }
        return unconfirmedOperatorEnvironmentKeys.contains { key in
            let value = environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !value.isEmpty
        }
    }
}

/// The one-time notice that Kimi K2 and CrossModel are no longer supported,
/// for someone who had either set up. Owed once: recorded when it is found to
/// be owed, kept until the person dismisses it, and never owed again after
/// that, so an account that comes back (a downgrade, a restore) does not bring
/// the notice back with it.
public struct RetiredProviderNotice {
    /// "pending" while owed and not yet dismissed; "dismissed" afterwards.
    static let stateKey = "cli_pulse_retired_provider_notice_v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records that the notice is owed when `owed` is true and it never was
    /// before. Returns whether it should be shown now.
    @discardableResult
    public func record(owed: Bool) -> Bool {
        let state = defaults.string(forKey: Self.stateKey)
        if owed, state == nil {
            defaults.set("pending", forKey: Self.stateKey)
            return true
        }
        return state == "pending"
    }

    public var isPending: Bool {
        defaults.string(forKey: Self.stateKey) == "pending"
    }

    public func dismiss() {
        defaults.set("dismissed", forKey: Self.stateKey)
    }
}

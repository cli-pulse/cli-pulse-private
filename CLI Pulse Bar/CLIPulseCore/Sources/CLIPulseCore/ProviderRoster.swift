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
//   (`ProviderRoster.activeConfigs`; at a launch, `configsKeptAtLaunch`, which
//   records the notice first), and the launch writes back the list without
//   them;
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

    /// What a launch keeps of the saved accounts: `activeConfigs(configs)`.
    ///
    /// Where collectors ran (a Mac), the launch is also where the notice is
    /// recorded, and the order is the point: whether a Kimi K2 or CrossModel
    /// collector had a key to send (`hadUnconfirmedOperatorSetUp`) is asked
    /// of `configs` as read, retired accounts still in and keys loaded,
    /// before they are left out. Asked of the kept list, it is never owed.
    /// It is asked only while the notice was never recorded: once it is
    /// pending or dismissed, no answer changes it (`RetiredProviderNotice`).
    ///
    /// `notice` is nil where collectors never ran (the iPhone).
    public static func configsKeptAtLaunch(
        _ configs: [ProviderConfig],
        environment: [String: String],
        notice: RetiredProviderNotice?
    ) -> [ProviderConfig] {
        notice?.record(
            owed: hadUnconfirmedOperatorSetUp(
                configs: configs,
                environment: environment
            )
        )
        return activeConfigs(configs)
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
    /// key from before 1.57, after the account's saved key
    /// (`KimiK2Collector.environmentKeys`, `CrossModelCollector.apiKeyEnv`).
    static let unconfirmedOperatorEnvironmentKeys: [ProviderKind: [String]] = [
        .kimiK2: ["KIMI_K2_API_KEY", "KIMI_API_KEY", "KIMI_KEY"],
        .crossModel: ["CROSSMODEL_API_KEY"],
    ]

    /// Whether a Kimi K2 or CrossModel collector had a key of this person's to
    /// send before 1.57, which is who the notice is for. Either:
    ///
    /// * an account of one has a saved API key (the only secret those
    ///   collectors read; enabled or not, the person set it up), or
    /// * an enabled account of one existed and an environment variable its
    ///   collector read holds a key. Collectors ran for enabled accounts only
    ///   (`CollectorRunner`), so a key in the environment reached nobody when
    ///   the account was off, or missing (a fresh 1.57 install has none).
    ///
    /// The account every install had by default, untouched, had no key of its
    /// own, and neither does one that only has a name. `configs` are the saved
    /// ones, retired accounts still in, with their secrets loaded
    /// (`loadSecrets()`); without them a saved key does not count.
    public static func hadUnconfirmedOperatorSetUp(
        configs: [ProviderConfig],
        environment: [String: String]
    ) -> Bool {
        func hasValue(_ value: String?) -> Bool {
            !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let accounts = configs.filter {
            $0.kind.retirement == .unconfirmedOperator
        }
        if accounts.contains(where: { hasValue($0.apiKey) }) { return true }
        return accounts.contains { account in
            account.isEnabled
                && (unconfirmedOperatorEnvironmentKeys[account.kind] ?? [])
                    .contains { hasValue(environment[$0]) }
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
    /// before. Returns whether it should be shown now. `owed` is evaluated
    /// only while nothing is recorded: once the notice is pending or
    /// dismissed, the answer cannot change it.
    @discardableResult
    public func record(owed: @autoclosure () -> Bool) -> Bool {
        let state = defaults.string(forKey: Self.stateKey)
        if state == nil, owed() {
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

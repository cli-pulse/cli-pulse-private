import Foundation

/// v1.57: the parts of a Mac provider card that can be hidden, provider by
/// provider.
///
/// The popover is 380 points wide and every provider's card is stacked in one
/// column, so a card that shows everything leaves room for about one card on
/// screen. Someone who never reads a provider's service status, or never looks
/// at its chart, can take that part off that provider's card and keep it on
/// the others. The idea and its rules are CodexBar's ("Visible usage items",
/// #3196; individual detail sections, #3638):
///
/// - a choice is kept by a stable identifier (`rawValue`), never by the
///   section's title, so it survives a restart and a change of language;
/// - hiding a section only stops the card from drawing it. Nothing stops
///   being read, refreshed or synced, and alerts fire as before;
/// - every section a provider's card has (`sections(for:)`) is always listed
///   where the choice is made, including one the card is not drawing right
///   now (a provider with no pace yet, a Codex account with no reset
///   credits), so a hidden section can always be shown again;
/// - "Show All Sections" puts one provider's card back the way it was.
///
/// The card's header and its warnings (a collector that failed, an account
/// that needs reconnecting) cannot be hidden: they are how a card says
/// something is wrong.
///
/// The raw values are stored: renaming one shows that section again for
/// everyone who hid it.
public enum ProviderCardSection: String, CaseIterable, Identifiable, Sendable {
    case serviceStatus = "service-status"
    case planAndSource = "plan-source"
    case usageTotals = "usage-totals"
    case dailyChart = "daily-chart"
    case quota = "quota"
    /// Codex's limit reset credits (`CodexResetCreditsCardRow`), under the
    /// quota bars; listed for Codex's card only.
    case resetCredits = "reset-credits"
    case recentSessions = "recent-sessions"
    case pace = "pace"

    public var id: String { rawValue }

    /// The name the section is listed under, in the card's order.
    public var title: String {
        switch self {
        case .serviceStatus: return L10n.providers.serviceStatus
        case .planAndSource: return L10n.providerCard.sectionPlanAndSource
        case .usageTotals: return L10n.providerCard.sectionUsageTotals
        case .dailyChart: return L10n.providerCard.sectionDailyChart
        case .quota: return L10n.providers.quota
        case .resetCredits: return L10n.resetCredits.title
        case .recentSessions: return L10n.tab.sessions
        case .pace: return L10n.display.pace
        }
    }

    /// Whether `provider`'s card has this section at all. Limit reset credits
    /// are Codex's alone; every other section is on every card, drawn or not.
    public func applies(to provider: ProviderKind) -> Bool {
        switch self {
        case .resetCredits: return provider == .codex
        default: return true
        }
    }

    /// The sections listed for `provider`'s card, in the card's order: what
    /// the card's menu and Settings › Providers offer.
    public static func sections(for provider: ProviderKind) -> [ProviderCardSection] {
        allCases.filter { $0.applies(to: provider) }
    }
}

/// Which sections each provider's card hides, as stored.
///
/// One string in this Mac's standard defaults (`defaultsKey`), so a view can
/// hold it in `@AppStorage` and redraw the moment it changes. It is a JSON
/// object from a provider's raw value to the identifiers hidden on its card.
///
/// An identifier this version does not know, written by a newer one, is kept
/// as it is when anything else changes: going back a version and forward again
/// does not lose the choice. Only "Show All Sections" drops it, as it drops
/// everything else on that card.
public struct ProviderCardVisibility: Equatable, Sendable {
    /// The `cli_pulse_` prefix keeps it in `UnsandboxedDataMigration`'s
    /// allow-list.
    public static let defaultsKey = "cli_pulse_provider_card_hidden_sections"

    /// Provider raw value → hidden section identifiers, known or not.
    public private(set) var hiddenByProvider: [String: Set<String>]

    public init(hiddenByProvider: [String: Set<String>] = [:]) {
        self.hiddenByProvider = hiddenByProvider.filter { !$0.value.isEmpty }
    }

    /// Reads what `storedValue` wrote. Anything that is not that shape
    /// (nothing stored yet, a damaged value) reads as nothing hidden: the
    /// card falls back to showing everything, never to showing nothing.
    public init(storedValue: String) {
        guard let data = storedValue.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            self.init()
            return
        }
        var hidden: [String: Set<String>] = [:]
        for (provider, value) in decoded {
            guard let ids = value as? [Any] else { continue }
            let strings = ids.compactMap { $0 as? String }.filter { !$0.isEmpty }
            if !strings.isEmpty { hidden[provider] = Set(strings) }
        }
        self.init(hiddenByProvider: hidden)
    }

    /// Stable JSON (keys and identifiers sorted), so writing the same choice
    /// twice stores the same bytes. Empty when nothing is hidden.
    public var storedValue: String {
        guard !hiddenByProvider.isEmpty else { return "" }
        let object = hiddenByProvider.mapValues { $0.sorted() }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    public func isVisible(_ section: ProviderCardSection, for provider: ProviderKind) -> Bool {
        !(hiddenByProvider[provider.rawValue]?.contains(section.rawValue) ?? false)
    }

    /// The sections this version knows that `provider`'s card hides.
    public func hiddenSections(for provider: ProviderKind) -> [ProviderCardSection] {
        ProviderCardSection.sections(for: provider).filter { !isVisible($0, for: provider) }
    }

    public mutating func setVisible(
        _ visible: Bool,
        _ section: ProviderCardSection,
        for provider: ProviderKind
    ) {
        var hidden = hiddenByProvider[provider.rawValue] ?? []
        if visible {
            hidden.remove(section.rawValue)
        } else {
            hidden.insert(section.rawValue)
        }
        hiddenByProvider[provider.rawValue] = hidden.isEmpty ? nil : hidden
    }

    /// "Show All Sections": `provider`'s card as it was before anything was
    /// hidden on it. Other providers' cards keep their choices.
    public mutating func restoreDefaults(for provider: ProviderKind) {
        hiddenByProvider[provider.rawValue] = nil
    }

    /// Whether "Show All Sections" would change anything for `provider`.
    public func hasHiddenSections(for provider: ProviderKind) -> Bool {
        !(hiddenByProvider[provider.rawValue]?.isEmpty ?? true)
    }

    /// Whether `provider`'s card draws the limit reset credits line (#666):
    /// Codex's card only, where it has quota bars to read them with
    /// (`hasQuotaTiers`, as before sections could be hidden), unless that
    /// section is hidden. Hiding the quota bars leaves it: it is a section
    /// of its own, listed beside them.
    public func showsResetCredits(for provider: ProviderKind, hasQuotaTiers: Bool) -> Bool {
        ProviderCardSection.resetCredits.applies(to: provider)
            && hasQuotaTiers
            && isVisible(.resetCredits, for: provider)
    }
}

// CurrencyConverter — v1.40 PR-7 multi-currency DISPLAY. All stored costs stay
// in USD; conversion happens only at display time (CostFormatter / Pricing.
// formatCost route through here). Daily FX rates fetched from a public
// read-only endpoint (open.er-api.com — sends nothing about the user), cached
// 24h in UserDefaults, with hardcoded fallback rates so the app is never blocked
// on the network.

import Foundation

public enum DisplayCurrency: String, CaseIterable, Codable, Sendable {
    /// Where the app keeps the choice: its own standard defaults. The widget
    /// extension and the Watch run in other processes and cannot read it.
    public static let defaultsKey = "cli_pulse_display_currency"

    /// The stored choice, read directly. For code that runs in the app's process
    /// without `AppState` having set up `CurrencyConverter.shared`, such as an
    /// App Intent launched by Siri in the background.
    public static func stored(in defaults: UserDefaults = .standard) -> DisplayCurrency {
        defaults.string(forKey: defaultsKey).flatMap(DisplayCurrency.init(rawValue:)) ?? .usd
    }

    case usd = "USD"
    case cny = "CNY"
    case eur = "EUR"
    case jpy = "JPY"
    case twd = "TWD"
    case hkd = "HKD"

    /// Symbol prefix. CNY and JPY share "¥"; since the user picks a single
    /// currency, every value on screen is that currency, so it's unambiguous.
    public var symbol: String {
        switch self {
        case .usd: return "$"
        case .cny: return "¥"
        case .eur: return "€"
        case .jpy: return "¥"
        case .twd: return "NT$"
        case .hkd: return "HK$"
        }
    }

    /// Fraction digits — JPY/TWD are conventionally whole-number.
    public var fractionDigits: Int {
        switch self {
        case .jpy, .twd: return 0
        default: return 2
        }
    }

    /// The smallest amount shown without a "<": one cent, or one whole unit.
    var smallestUnit: Double { fractionDigits == 0 ? 1.0 : 0.01 }

    /// Hardcoded fallback (approx. 2026) units per 1 USD — used until/if a live
    /// fetch succeeds.
    public var fallbackRate: Double {
        switch self {
        case .usd: return 1
        case .cny: return 7.15
        case .eur: return 0.92
        case .jpy: return 150
        case .twd: return 32.3
        case .hkd: return 7.8
        }
    }
}

public extension Notification.Name {
    /// Posted when the display currency (or its rate) changes, so cost views re-render.
    static let displayCurrencyDidChange = Notification.Name("cli_pulse_display_currency_did_change")
}

public final class CurrencyConverter: @unchecked Sendable {
    public static let shared = CurrencyConverter()

    private let lock = NSLock()
    private var currency: DisplayCurrency = .usd
    private var rates: [String: Double]          // units per 1 USD, keyed by ISO code

    private let defaults: UserDefaults
    static let ratesKey = "cli_pulse_fx_rates_v1"
    static let fetchedAtKey = "cli_pulse_fx_fetched_at"
    static let ttl: TimeInterval = 24 * 60 * 60
    private static let endpoint = "https://open.er-api.com/v6/latest/USD"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rates = Self.fallbackRates()
        if let cached = defaults.dictionary(forKey: Self.ratesKey) as? [String: Double], !cached.isEmpty {
            for (k, v) in cached where v > 0 { self.rates[k] = v }
        }
    }

    static func fallbackRates() -> [String: Double] {
        var r: [String: Double] = [:]
        for c in DisplayCurrency.allCases { r[c.rawValue] = c.fallbackRate }
        return r
    }

    // MARK: - Currency selection

    public func setCurrency(_ currency: DisplayCurrency) {
        lock.withLock { self.currency = currency }
        NotificationCenter.default.post(name: .displayCurrencyDidChange, object: nil)
    }

    public func currentCurrency() -> DisplayCurrency { lock.withLock { currency } }

    // MARK: - Convert + format (called at display time)

    /// Units per 1 USD for the active currency (falls back to the hardcoded rate).
    public func rate() -> Double {
        lock.withLock { rates[currency.rawValue] ?? currency.fallbackRate }
    }

    public func convert(_ usd: Double) -> Double { usd * rate() }

    /// Formats a USD cost in the active display currency. Mirrors CostFormatter's
    /// "<$0.01" small-value convention, adapted to the currency's smallest unit.
    public func format(_ usd: Double, locale: Locale = LocaleOverrideStore.shared.displayLocale) -> String {
        format(usd, as: currentCurrency(), locale: locale)
    }

    /// `format(_:)` in a given currency rather than the active one.
    public func format(
        _ usd: Double,
        as cur: DisplayCurrency,
        locale: Locale = LocaleOverrideStore.shared.displayLocale
    ) -> String {
        let converted = convert(usd, to: cur)
        let smallest = cur.smallestUnit
        if usd > 0, converted < smallest {
            return "<" + amount(smallest, in: cur, fractionDigits: cur.fractionDigits, locale: locale)
        }
        return amount(converted, in: cur, fractionDigits: cur.fractionDigits, locale: locale)
    }

    /// The active currency in whole units, for a glance with no room for cents:
    /// "$146", "¥1,044".
    public func formatWholeUnits(_ usd: Double, locale: Locale = LocaleOverrideStore.shared.displayLocale) -> String {
        let cur = currentCurrency()
        return amount(convert(usd, to: cur).rounded(), in: cur, fractionDigits: 0, locale: locale)
    }

    /// A cost as Siri says it. The dollar keeps its "less than one cent" floor;
    /// another currency says "less than ¥0.01", because a cent is not its unit
    /// and a spoken "<" is not a word.
    public func spokenFormat(_ usd: Double, as cur: DisplayCurrency) -> String {
        guard convert(usd, to: cur) < cur.smallestUnit else { return format(usd, as: cur) }
        return cur == .usd
            ? L10n.intents.lessThanOneCent
            : L10n.intents.lessThanAmount(amount(cur.smallestUnit, in: cur, fractionDigits: cur.fractionDigits))
    }

    func convert(_ usd: Double, to cur: DisplayCurrency) -> Double {
        usd * lock.withLock { rates[cur.rawValue] ?? cur.fallbackRate }
    }

    /// The symbol stays where `DisplayCurrency.symbol` puts it, in front, in
    /// every language: a locale's own currency style would turn a Japanese
    /// reader's CNY into "CN¥" and move the symbol behind the number in Spain,
    /// against the choice this setting makes. Only the digits follow the
    /// reader: "$1,234.56", or "$1234,56" in Spain, where an en_US comma reads
    /// as the decimal point.
    private func amount(
        _ value: Double,
        in cur: DisplayCurrency,
        fractionDigits: Int,
        locale: Locale = LocaleOverrideStore.shared.displayLocale
    ) -> String {
        cur.symbol + value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    // MARK: - Rate fetch (daily, cached 24h, non-blocking)

    public func refreshRatesIfStale(now: Date = Date()) async {
        let fetchedAt = defaults.double(forKey: Self.fetchedAtKey)
        if fetchedAt > 0, now.timeIntervalSince1970 - fetchedAt < Self.ttl { return }
        await refreshRates(now: now)
    }

    public func refreshRates(now: Date = Date()) async {
        guard let url = URL(string: Self.endpoint) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = Self.parseRates(data) else { return }
        // Keep only the currencies we display; validate positivity.
        var merged = lock.withLock { rates }
        for c in DisplayCurrency.allCases {
            if let v = parsed[c.rawValue], v.isFinite, v > 0 { merged[c.rawValue] = v }
        }
        lock.withLock { rates = merged }
        defaults.set(merged, forKey: Self.ratesKey)
        defaults.set(now.timeIntervalSince1970, forKey: Self.fetchedAtKey)
        NotificationCenter.default.post(name: .displayCurrencyDidChange, object: nil)
    }

    /// Parses the open.er-api.com `{result:"success", rates:{...}}` shape.
    static func parseRates(_ data: Data) -> [String: Double]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let result = root["result"] as? String, result != "success" { return nil }
        guard let rawRates = root["rates"] as? [String: Any] else { return nil }
        var out: [String: Double] = [:]
        for (k, v) in rawRates {
            if let n = v as? NSNumber { out[k] = n.doubleValue }
            else if let s = v as? String, let d = Double(s) { out[k] = d }
        }
        return out.isEmpty ? nil : out
    }
}

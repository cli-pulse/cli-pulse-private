import Foundation

/// What "Hide personal information" does to the name an account is shown
/// under, on every surface that shows one: the Mac's provider card, its
/// multi-account rows (Providers and Overview) and its Settings lists, the
/// iPhone's account rows, and the Watch.
///
/// An account's label is whatever its owner typed, and often that is the
/// address the account signs in with. With the switch on, a label that reads
/// as an email address is shown as "Account 2", its position among that
/// provider's accounts on this device. Any other label ("Work", "dev-box") is
/// the owner's own wording and stays. With the switch off, every label shows as
/// written.
///
/// "Reads as an email address" means it contains an at sign: that covers every
/// address, including one with no dot after the at sign (`name@company`), and
/// the full-width forms a CJK keyboard types. With the switch on, no account
/// label leaves an at sign on screen.
///
/// The Watch has no switch of its own. The iPhone puts its choice in the
/// application context it already sends (`addPhoneChoice`), and the Watch
/// keeps it in its own defaults under the same key (`adoptPhoneChoice`), so its
/// views read it the way the iPhone's do.
public enum PersonalInfoMask {
    /// The switch, in this device's standard defaults. `AppState`'s
    /// `@AppStorage` and the views that read the switch directly share it; on
    /// the Watch it holds the paired iPhone's choice.
    ///
    /// The key existing installs already have the switch under: renaming it
    /// would turn the switch off for everyone who turned it on. Its `cli_pulse_`
    /// prefix keeps it in `UnsandboxedDataMigration`'s allow-list.
    public static let defaultsKey = "cli_pulse_hide_personal_info"

    /// Where the iPhone puts the switch in the Watch's application context.
    public static let watchContextKey = "hide_personal_info"

    /// The at signs that make a label read as an email address.
    private static let atSigns: Set<Character> = ["@", "\u{FF20}", "\u{FE6B}"]

    /// Whether `label` reads as an email address (see the type's note).
    public static func looksLikeEmail(_ label: String) -> Bool {
        label.contains { atSigns.contains($0) }
    }

    /// The name an account is shown under.
    ///
    /// - Parameters:
    ///   - label: the account's label, as stored (blank counts as none).
    ///   - index: its position among the provider's accounts on this surface,
    ///     from 0; nil when it is not among them.
    ///   - accountCount: how many accounts the provider has there.
    ///   - hidePersonalInfo: the switch.
    ///
    /// An account without a label keeps the names it always had: "Account 2"
    /// among several, "Default account" alone.
    public static func accountName(
        label: String?,
        index: Int?,
        accountCount: Int,
        hidePersonalInfo: Bool
    ) -> String {
        if let shown = accountLabel(
            label,
            index: index,
            hidePersonalInfo: hidePersonalInfo
        ) {
            return shown
        }
        guard accountCount > 1, let index else {
            return L10n.providers.defaultAccount
        }
        return L10n.providers.accountNumber(index + 1)
    }

    /// The label itself, masked when the switch says so, or nil when the
    /// account has none: for a place that shows a label only when there is
    /// one, such as the line under a single-account provider's card.
    public static func accountLabel(
        _ label: String?,
        index: Int?,
        hidePersonalInfo: Bool
    ) -> String? {
        guard
            let trimmed = label?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !trimmed.isEmpty
        else {
            return nil
        }
        guard hidePersonalInfo, looksLikeEmail(trimmed) else {
            return trimmed
        }
        return L10n.providers.accountNumber((index ?? 0) + 1)
    }

    // MARK: - The Watch follows the iPhone

    /// The iPhone's side: adds its switch to the Watch's application context.
    public static func addPhoneChoice(
        _ hidePersonalInfo: Bool,
        to context: inout [String: Any]
    ) {
        context[watchContextKey] = hidePersonalInfo
    }

    /// The Watch's side: what a context from the iPhone says, or nil when it
    /// says nothing (an iPhone app older than this). Read before leaving the
    /// thread the context arrived on: the dictionary is not `Sendable`.
    public static func phoneChoice(
        inWatchContext context: [String: Any]
    ) -> Bool? {
        context[watchContextKey] as? Bool
    }

    /// Keeps the iPhone's choice where this device's views read the switch.
    /// With no choice in the context the Watch keeps the one it had: a context
    /// that says nothing must not show the addresses the owner hid.
    public static func adoptPhoneChoice(
        _ choice: Bool?,
        defaults: UserDefaults = .standard
    ) {
        guard let choice else { return }
        defaults.set(choice, forKey: defaultsKey)
    }

    /// The switch as this device's defaults hold it (off when never set).
    public static func isOn(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

public extension Notification.Name {
    /// Posted when this device's "Hide personal information" switch changes,
    /// so the iPhone can send the Watch the new choice now rather than at the
    /// next data refresh.
    static let hidePersonalInfoDidChange = Notification.Name(
        "cli_pulse_hide_personal_info_did_change"
    )
}

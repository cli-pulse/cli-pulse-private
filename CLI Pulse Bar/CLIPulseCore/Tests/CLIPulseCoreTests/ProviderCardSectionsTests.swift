import XCTest
@testable import CLIPulseCore

/// v1.57 P1-1b: hiding sections of a provider card, provider by provider
/// (CodexBar #3196 and #3638).
final class ProviderCardSectionsTests: XCTestCase {

    /// The identifiers are stored. Renaming one shows that section again for
    /// everyone who hid it, so a rename has to be deliberate.
    func testTheStoredIdentifiersDoNotChange() {
        XCTAssertEqual(ProviderCardSection.allCases.map(\.rawValue), [
            "service-status", "plan-source", "usage-totals", "daily-chart",
            "quota", "reset-credits", "recent-sessions", "pace",
        ])
        XCTAssertEqual(ProviderCardVisibility.defaultsKey, "cli_pulse_provider_card_hidden_sections")
        XCTAssertTrue(UnsandboxedDataMigration.appOwnedKeyPrefixes.contains { ProviderCardVisibility.defaultsKey.hasPrefix($0) })
    }

    func testNothingIsHiddenUntilSomeoneHidesIt() {
        let empty = ProviderCardVisibility(storedValue: "")
        for section in ProviderCardSection.allCases {
            XCTAssertTrue(empty.isVisible(section, for: .codex), section.rawValue)
        }
        XCTAssertFalse(empty.hasHiddenSections(for: .codex))
        XCTAssertEqual(empty.storedValue, "")
    }

    /// One provider's choice is that provider's: Claude's card keeps its chart
    /// when Codex's hides it.
    func testAChoiceIsPerProviderAndSurvivesARoundTrip() {
        var v = ProviderCardVisibility(storedValue: "")
        v.setVisible(false, .dailyChart, for: .codex)
        v.setVisible(false, .serviceStatus, for: .codex)
        let reread = ProviderCardVisibility(storedValue: v.storedValue)
        XCTAssertFalse(reread.isVisible(.dailyChart, for: .codex))
        XCTAssertFalse(reread.isVisible(.serviceStatus, for: .codex))
        XCTAssertTrue(reread.isVisible(.dailyChart, for: .claude))
        XCTAssertEqual(reread.hiddenSections(for: .codex), [.serviceStatus, .dailyChart])
        XCTAssertEqual(reread, v)
        XCTAssertEqual(v.storedValue, #"{"Codex":["daily-chart","service-status"]}"#,
                       "stable bytes: identifiers sorted, never titles")
    }

    /// Kept by identifier, not by title: switching language changes nothing.
    func testAChoiceSurvivesALanguageChange() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        var v = ProviderCardVisibility()
        LocaleOverrideStore.shared.set("ja")
        v.setVisible(false, .pace, for: .claude)
        let stored = v.storedValue
        LocaleOverrideStore.shared.set("es")
        XCTAssertFalse(ProviderCardVisibility(storedValue: stored).isVisible(.pace, for: .claude))
        XCTAssertFalse(stored.contains(ProviderCardSection.pace.title))
    }

    /// "Show All Sections" puts one card back and leaves the others alone.
    func testShowAllRestoresOneProvider() {
        var v = ProviderCardVisibility()
        v.setVisible(false, .quota, for: .codex)
        v.setVisible(false, .quota, for: .claude)
        v.restoreDefaults(for: .codex)
        XCTAssertTrue(v.isVisible(.quota, for: .codex))
        XCTAssertFalse(v.hasHiddenSections(for: .codex))
        XCTAssertFalse(v.isVisible(.quota, for: .claude))
        // Showing the last hidden section is the same as never hiding it.
        v.setVisible(true, .quota, for: .claude)
        XCTAssertEqual(v.storedValue, "")
    }

    /// A section a newer version added and hid survives this version changing
    /// something else.
    func testAnIdentifierFromANewerVersionIsKept() {
        let newer = "zz-newer-section"
        XCTAssertNil(ProviderCardSection(rawValue: newer), "pick an identifier no section has")
        var v = ProviderCardVisibility(storedValue: #"{"Codex":["\#(newer)"]}"#)
        XCTAssertTrue(v.hasHiddenSections(for: .codex))
        XCTAssertTrue(v.hiddenSections(for: .codex).isEmpty, "not one this version can draw")
        v.setVisible(false, .pace, for: .codex)
        XCTAssertEqual(v.storedValue, #"{"Codex":["pace","\#(newer)"]}"#)
    }

    /// Codex's limit reset credits (#666) are a section of Codex's card
    /// alone: listed in its menu and in Settings, and nowhere else.
    func testResetCreditsAreListedForCodexOnly() {
        XCTAssertEqual(ProviderCardSection.sections(for: .codex), ProviderCardSection.allCases)
        XCTAssertEqual(ProviderCardSection.sections(for: .codex).firstIndex(of: .resetCredits),
                       (ProviderCardSection.sections(for: .codex).firstIndex(of: .quota) ?? -2) + 1,
                       "listed under the quota bars, where the card draws it")
        for kind in ProviderKind.allCases where kind != .codex {
            XCTAssertFalse(ProviderCardSection.sections(for: kind).contains(.resetCredits), kind.rawValue)
            XCTAssertEqual(ProviderCardSection.sections(for: kind).count, ProviderCardSection.allCases.count - 1)
        }
        var v = ProviderCardVisibility()
        v.setVisible(false, .resetCredits, for: .codex)
        XCTAssertEqual(v.hiddenSections(for: .codex), [.resetCredits])
        XCTAssertEqual(v.storedValue, #"{"Codex":["reset-credits"]}"#)
        // A Claude card never lists it, so never counts it as hidden.
        let stray = ProviderCardVisibility(storedValue: #"{"Claude":["reset-credits"]}"#)
        XCTAssertTrue(stray.hiddenSections(for: .claude).isEmpty)
    }

    /// The reset credits line keeps the place it had before sections could
    /// be hidden (Codex, under its quota bars) and hides only with its own
    /// section: hiding the quota bars leaves it.
    func testResetCreditsHideOnlyWithTheirOwnSection() {
        var v = ProviderCardVisibility()
        XCTAssertTrue(v.showsResetCredits(for: .codex, hasQuotaTiers: true))
        XCTAssertFalse(v.showsResetCredits(for: .codex, hasQuotaTiers: false), "no quota read, nothing to read them with")
        XCTAssertFalse(v.showsResetCredits(for: .claude, hasQuotaTiers: true))
        v.setVisible(false, .quota, for: .codex)
        XCTAssertTrue(v.showsResetCredits(for: .codex, hasQuotaTiers: true), "hiding the quota bars leaves them")
        v.setVisible(false, .resetCredits, for: .codex)
        XCTAssertFalse(v.showsResetCredits(for: .codex, hasQuotaTiers: true))
        v.restoreDefaults(for: .codex)
        XCTAssertTrue(v.showsResetCredits(for: .codex, hasQuotaTiers: true))
    }

    /// A damaged value shows everything rather than nothing.
    func testADamagedValueHidesNothing() {
        for stored in ["{", "[]", #"{"Codex":"pace"}"#, #"{"Codex":[1,2]}"#, "null"] {
            let v = ProviderCardVisibility(storedValue: stored)
            XCTAssertTrue(v.isVisible(.pace, for: .codex), stored)
            XCTAssertFalse(v.hasHiddenSections(for: .codex), stored)
        }
    }

    /// Every section has a name in every language (asserted in Korean, where a
    /// missing key would fall back to English). The reset credits section is
    /// named as its line on the card is (`reset_credits.title`), one string.
    func testEverySectionHasATranslatedName() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("en")
        let english = ProviderCardSection.allCases.map(\.title)
        LocaleOverrideStore.shared.set("ko")
        let korean = ProviderCardSection.allCases.map(\.title)
        XCTAssertEqual(Set(english).count, english.count, "two sections share a name: \(english)")
        for (en, ko) in zip(english, korean) {
            XCTAssertNotEqual(en, ko, "\(en) is not translated")
        }
        XCTAssertEqual(ProviderCardSection.resetCredits.title, "한도 리셋권")
        XCTAssertEqual(ProviderCardSection.resetCredits.title, L10n.resetCredits.title)
    }
}

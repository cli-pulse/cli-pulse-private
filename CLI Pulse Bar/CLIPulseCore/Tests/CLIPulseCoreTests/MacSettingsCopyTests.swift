import XCTest
@testable import CLIPulseCore

/// Copy the offscreen renders of the Mac app showed to be wrong in every
/// language, pinned so it cannot drift back. Each check runs in every shipped
/// localization; in English several of them would pass with the lookup broken.
final class MacSettingsCopyTests: XCTestCase {

    override func tearDown() {
        LocaleOverrideStore.shared.set(nil)
        super.tearDown()
    }

    private func eachLocalization(_ body: (String) throws -> Void) rethrows {
        for localization in LocaleOverrideStore.shippedLocalizations {
            LocaleOverrideStore.shared.set(localization)
            try body(localization)
        }
    }

    /// The last setup page sent people to "Settings → Helper", a section no
    /// Settings page has, for Remote Approvals, which v1.52.1 retired. The
    /// section is titled with the helper's product name, the one its Install
    /// and Update buttons and every other "Settings → Companion CLI" path use.
    func test_theHelperHint_namesTheSettingsSectionByItsTitle() {
        eachLocalization { localization in
            let title = L10n.helper.title
            XCTAssertEqual(title, "Companion CLI", localization)
            XCTAssertTrue(L10n.helper.installButton.contains(title), localization)
            XCTAssertTrue(L10n.helper.updateButton.contains(title), localization)
            XCTAssertTrue(L10n.onboardingWizard.helperHint.contains(title),
                          "\(localization): \(L10n.onboardingWizard.helperHint)")
        }
        LocaleOverrideStore.shared.set("en")
        XCTAssertFalse(L10n.onboardingWizard.helperHint.contains("Remote Approvals"))
        XCTAssertFalse(L10n.onboardingWizard.helperHint.contains("→ Helper"))
    }

    /// The Yield Score card said to turn git tracking on in Settings › Privacy.
    /// The switch is in Settings › Advanced; the Privacy card at the top of
    /// Settings does not have it.
    func test_theYieldHint_pointsAtTheTabThatHasTheSwitch() {
        eachLocalization { localization in
            let hint = L10n.yield.emptyEnableHint
            XCTAssertTrue(hint.contains(L10n.settings.advanced), "\(localization): \(hint)")
            let toggle = L10n.advanced.trackGit
            let name = toggle[..<(toggle.firstIndex(where: { $0 == "(" || $0 == "（" }) ?? toggle.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            XCTAssertFalse(name.isEmpty, localization)
            XCTAssertTrue(hint.contains(name), "\(localization): \(hint) does not name \(name)")
        }
    }

    /// Setup v2's welcome page reused the mode chooser's lead-in, which ends in
    /// a colon, as a bullet that introduced nothing.
    func test_theSetupWelcomeBullets_areStatementsNotLeadIns() {
        eachLocalization { localization in
            let bullet = L10n.onboardingWizard.welcomeTrackingBody
            XCTAssertNotEqual(bullet, "onboarding_wizard.welcome_tracking_body", localization)
            XCTAssertNotEqual(bullet, L10n.welcomeChoice.subtitle, localization)
            XCTAssertFalse(bullet.hasSuffix(":") || bullet.hasSuffix("："), "\(localization): \(bullet)")
        }
    }

    /// The refresh picker showed "1m" … "30m" in every language, which reads as
    /// metres in Chinese and Japanese.
    func test_theRefreshIntervals_areInTheReadersMinutes() {
        let expected = ["en": "5 min", "zh-Hans": "5 分钟", "zh-Hant": "5 分鐘",
                        "ja": "5分", "ko": "5분", "es": "5 min"]
        eachLocalization { localization in
            XCTAssertEqual(L10n.settings.refreshMinutesShort(5), expected[localization], localization)
        }
    }

    // MARK: - The catalogues themselves

    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // …/CLIPulseCore
        .appending(path: "Sources/CLIPulseCore/Resources")

    /// Every `"key" = "value";` of one catalogue, comments left out.
    private func values(_ localization: String) throws -> [(key: String, value: String)] {
        let url = Self.resources.appending(path: "\(localization).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = try NSRegularExpression(pattern: #"^"([^"]+)"\s*=\s*"(.*)";\s*$"#, options: .anchorsMatchLines)
        return line.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let key = Range(match.range(at: 1), in: text),
                  let value = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[key]), String(text[value]))
        }
    }

    /// The brand is "CLI Pulse", two words, in every language. Three strings
    /// spelled it "CLIPulse" in all six catalogues, and About and Quit used the
    /// Xcode target's name, "CLI Pulse Bar".
    func test_noCatalogueMisspellsTheBrand() throws {
        for localization in LocaleOverrideStore.shippedLocalizations {
            let entries = try values(localization)
            XCTAssertGreaterThan(entries.count, 1_000, "\(localization) did not parse")
            for (key, value) in entries {
                XCTAssertFalse(value.contains("CLIPulse"), "\(localization) \(key): \(value)")
                XCTAssertFalse(value.contains("Pulse Bar"), "\(localization) \(key): \(value)")
            }
        }
    }

    /// Setup named the backend vendor ("No Supabase sync"), which means nothing
    /// to the person choosing. The server row in Settings still names it, as a
    /// server name.
    func test_setupDoesNotNameTheBackendVendor() throws {
        for localization in LocaleOverrideStore.shippedLocalizations {
            for (key, value) in try values(localization) where key.hasPrefix("onboarding_wizard.") {
                XCTAssertFalse(value.contains("Supabase"), "\(localization) \(key): \(value)")
            }
        }
    }

    /// Two screens gave two different provider counts (14+ in setup, 20+ in
    /// About) while Settings listed dozens. A count written into copy goes stale
    /// the day a provider is added, so the copy names none.
    func test_theProviderCountIsNotWrittenIntoCopy() throws {
        for localization in LocaleOverrideStore.shippedLocalizations {
            let entries = Dictionary(try values(localization), uniquingKeysWith: { first, _ in first })
            for key in ["onboarding_wizard.feature_usage_desc", "about.description"] {
                let value = try XCTUnwrap(entries[key], "\(localization) \(key)")
                XCTAssertNil(value.rangeOfCharacter(from: .decimalDigits), "\(localization) \(key): \(value)")
            }
        }
    }
}

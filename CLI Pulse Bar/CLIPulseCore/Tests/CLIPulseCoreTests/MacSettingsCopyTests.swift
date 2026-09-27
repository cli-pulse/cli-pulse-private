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

    /// The third welcome bullet reused the privacy page's card title, which has
    /// no final stop, under two bullets that end in one.
    func test_theSetupWelcomeBullets_allEndAsSentences() {
        eachLocalization { localization in
            let bullets = [L10n.onboardingWizard.welcomeTrackingBody,
                           L10n.onboardingWizard.welcomeAccountsBody,
                           L10n.onboardingWizard.welcomeKeysBody]
            for bullet in bullets {
                XCTAssertFalse(bullet.hasPrefix("onboarding_wizard."), "\(localization) renders the raw key")
                XCTAssertTrue(bullet.hasSuffix(".") || bullet.hasSuffix("。"), "\(localization): \(bullet)")
            }
            XCTAssertNotEqual(L10n.onboardingWizard.welcomeKeysBody,
                              L10n.onboardingWizard.privacyKeysTitle, localization)
        }
    }

    /// Settings had two sections called "Privacy": the card at the top of
    /// every page, with the switches, and a header inside Advanced over the
    /// where-your-data-goes rows. "Settings › Privacy" in the statistics and
    /// scan-consent copy could mean either.
    func test_onlyOneSettingsSectionIsCalledPrivacy() {
        eachLocalization { localization in
            XCTAssertFalse(L10n.advanced.dataTitle.hasPrefix("advanced."), "\(localization) renders the raw key")
            XCTAssertNotEqual(L10n.advanced.dataTitle, L10n.settings.privacy, localization)
        }
    }

    /// Settings › Privacy had a switch called "Local-only mode", and the
    /// no-account way of using the app is "local mode" everywhere else. A
    /// signed-in user reading the switch would think it stops syncing, which it
    /// does not: it skips other apps' credentials and turns off the anonymous
    /// statistics. The switch no longer says "local", and the three strings
    /// that refer to it by name use its current name.
    func test_thePrivacySwitch_isNotNamedLikeLocalMode() {
        let localWord = ["en": "local", "es": "local", "ja": "ローカル", "ko": "로컬",
                         "zh-Hans": "本地", "zh-Hant": "本機"]
        eachLocalization { localization in
            let name = L10n.settings.localOnlyMode
            XCTAssertNotNil(localWord[localization], "\(localization) has no entry here")
            let word = localWord[localization] ?? "?"
            XCTAssertTrue(L10n.welcomeChoice.localModeTitle.localizedCaseInsensitiveContains(word),
                          "\(localization): control, the local-mode title no longer says \(word)")
            XCTAssertFalse(name.localizedCaseInsensitiveContains(word), "\(localization): \(name)")
            for reference in [L10n.telemetry.toggleLocalOnly,
                              L10n.telemetry.disclosureBodyLocalOnly,
                              L10n.settings.skipClaudeKeychainForced] {
                XCTAssertTrue(reference.localizedCaseInsensitiveContains(name),
                              "\(localization): \"\(reference)\" does not name the switch \"\(name)\"")
            }
        }
    }

    /// The iPhone's usage heatmap is the history synced to the account, fetched
    /// from the server. It was captioned with the Mac's "Claude + Codex local
    /// history", which is what the Mac's own heatmap holds and was not true on
    /// the phone.
    func test_theIPhoneHeatmap_hasItsOwnCaptions() {
        eachLocalization { localization in
            XCTAssertFalse(L10n.usageDashboard.scopeSynced.hasPrefix("usage_dashboard."), localization)
            XCTAssertFalse(L10n.usageDashboard.emptySynced.hasPrefix("usage_dashboard."), localization)
            XCTAssertNotEqual(L10n.usageDashboard.scopeSynced, L10n.usageDashboard.scope, localization)
            XCTAssertNotEqual(L10n.usageDashboard.emptySynced, L10n.usageDashboard.empty, localization)
            XCTAssertFalse(L10n.usageDashboard.scopeSynced.contains("Codex"), localization)
        }
    }

    /// The English legend and helper hint were rewritten without the file
    /// format ("JSONL") and the internal "local fast path"; five catalogues kept
    /// translating the old wording.
    func test_theSessionsHints_doNotNameTheFileFormat() {
        eachLocalization { localization in
            XCTAssertFalse(L10n.sessions.freshnessLegend.contains("JSONL"),
                           "\(localization): \(L10n.sessions.freshnessLegend)")
            XCTAssertFalse(L10n.sessions.startHelperHint.isEmpty, localization)
            XCTAssertFalse(L10n.sessions.startHelperHint
                            .localizedCaseInsensitiveContains(L10n.sessions.localFastPathTitle),
                           "\(localization): \(L10n.sessions.startHelperHint)")
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

    /// Settings paths were written with "›" in some strings and "→" in others,
    /// in every language. They all use "›" now, the separator the popover's
    /// own telemetry and scan-consent copy used, with two exceptions: the
    /// version badge's arrow is not a path, and the English Claude quota hint
    /// is also the sentinel the collector writes as data
    /// (`ClaudeStatusSentinel.quotaUnavailable`), which status text already
    /// stored and other devices' apps match on.
    func test_settingsPaths_useOneSeparator() throws {
        let notPaths: Set<String> = ["app_updater.update_available_badge"]
        for localization in LocaleOverrideStore.shippedLocalizations {
            let entries = try values(localization)
            XCTAssertTrue(entries.contains { $0.value.contains(" › ") }, "\(localization): no path found, the scan reads nothing")
            for (key, value) in entries where !notPaths.contains(key) {
                if localization == "en", key == "providers.claude_quota_unavailable_hint" {
                    XCTAssertEqual(value, ClaudeStatusSentinel.quotaUnavailable)
                    continue
                }
                XCTAssertFalse(value.contains("→"), "\(localization) \(key): \(value)")
            }
        }
    }

    /// "Wi-Fi" broke at its hyphen in the zh-Hant statistics notice, "Wi-" at
    /// the end of one line and "Fi" starting the next. Every catalogue writes it
    /// with a non-breaking hyphen (U+2011), as Apple's own tables do.
    func test_wiFi_isNeverSplitAtItsHyphen() throws {
        for localization in LocaleOverrideStore.shippedLocalizations {
            let entries = try values(localization)
            XCTAssertTrue(entries.contains { $0.value.contains("Wi\u{2011}Fi") }, "\(localization): control, no Wi\u{2011}Fi found")
            for (key, value) in entries {
                XCTAssertFalse(value.contains("Wi-Fi"), "\(localization) \(key): \(value)")
            }
        }
    }

    /// "Apple Watch" broke at its space in the Chinese, Japanese and Korean
    /// setup copy, "Apple" ending one line and "Watch" starting the next. Those
    /// catalogues write it with a no-break space (U+00A0), so the name moves to
    /// the next line whole. English and Spanish break at spaces anyway and keep
    /// the plain one.
    func test_appleWatch_isNeverSplitInCJKOrKorean() throws {
        for localization in ["ja", "ko", "zh-Hans", "zh-Hant"] {
            let entries = try values(localization)
            XCTAssertTrue(entries.contains { $0.value.contains("Apple\u{00A0}Watch") }, "\(localization): control, none found")
            for (key, value) in entries {
                XCTAssertFalse(value.contains("Apple Watch"), "\(localization) \(key): \(value)")
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

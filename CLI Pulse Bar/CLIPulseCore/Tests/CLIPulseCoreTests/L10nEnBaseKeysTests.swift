import XCTest
@testable import CLIPulseCore

/// H-13 (2026-06-07 review): two L10n keys referenced by
/// `L10n.providerConfig.autoImportNote` / `.autoImportFailed`
/// (`provider_config.auto_import_note` / `_failed`) existed in
/// zh-Hans/ja/zh-Hant but were missing from the **en** base locale.
/// Because en.lproj is the development-region fallback, an English
/// user — or any es/ko user falling back to en — saw the literal key
/// string instead of copy.
///
/// These tests force the locale override to `en` and resolve through
/// the production `L10n.tr` path (which reads
/// `LocaleOverrideStore.shared.bundle`), so they assert against the en
/// base regardless of the CI machine's preferred language and would
/// have caught the gap. `NSLocalizedString` echoes the key back when
/// it's missing, which is exactly the "missing" signal asserted here.
final class L10nEnBaseKeysTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("en")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    func test_providerConfigAutoImportKeys_resolveInEnBase() {
        let note = L10n.providerConfig.autoImportNote
        let failed = L10n.providerConfig.autoImportFailed
        // A missing key resolves to the raw key string echoed back.
        XCTAssertNotEqual(note, "provider_config.auto_import_note",
                          "auto_import_note is missing from en.lproj")
        XCTAssertNotEqual(failed, "provider_config.auto_import_failed",
                          "auto_import_failed is missing from en.lproj")
        XCTAssertFalse(note.isEmpty)
        XCTAssertFalse(failed.isEmpty)
        // Must be real English copy, not the dotted key echoed back.
        XCTAssertFalse(note.hasPrefix("provider_config."))
        XCTAssertFalse(failed.hasPrefix("provider_config."))
    }

    /// Harness guard: a known-present key resolves under the same
    /// forced-`en` path, so the test above can't pass vacuously if the
    /// en bundle ever failed to load entirely.
    func test_enOverrideResolvesAKnownKey() {
        XCTAssertEqual(L10n.providerConfig.capabilities, "Capabilities")
    }

    func test_onboardingStepProgressHasLocalizedSemanticCopy() {
        XCTAssertEqual(
            L10n.onboardingWizard.stepProgress(
                current: 3,
                total: 6,
                name: "Your Coding Agents"
            ),
            "Step 3 of 6: Your Coding Agents"
        )
    }

    func test_providerAccountManagementCopyResolvesInEnBase() {
        XCTAssertEqual(L10n.providers.accountsCount(1), "1 account")
        XCTAssertEqual(L10n.providers.accountsCount(2), "2 accounts")
        XCTAssertEqual(
            L10n.providers.removeAccountTitle("Claude", "Work"),
            "Remove Claude · Work?"
        )
        XCTAssertFalse(
            L10n.providers.removeAccountMessage.hasPrefix("providers.")
        )
    }

    func test_providerAccountDestructiveCopyResolvesInEverySupportedLocale() {
        for locale in ["en", "ja", "zh-Hans", "zh-Hant", "es", "ko"] {
            LocaleOverrideStore.shared.set(locale)
            let title = L10n.providers.removeAccountTitle(
                "Claude",
                "Work"
            )
            let message = L10n.providers.removeAccountMessage
            let manualPlan = L10n.providerConfig.manualPlan

            XCTAssertFalse(
                title.hasPrefix("providers."),
                "\(locale) is missing the account removal title"
            )
            XCTAssertTrue(
                title.contains("Claude") && title.contains("Work"),
                "\(locale) removal title lost its provider/account placeholders"
            )
            XCTAssertFalse(
                message.hasPrefix("providers."),
                "\(locale) is missing the destructive account removal message"
            )
            XCTAssertFalse(
                manualPlan.hasPrefix("provider_config."),
                "\(locale) is missing manual-plan copy"
            )
        }
    }

    func test_providerAccountSourceCopyResolvesInEverySupportedLocale() {
        for locale in ["en", "ja", "zh-Hans", "zh-Hant", "es", "ko"] {
            LocaleOverrideStore.shared.set(locale)

            let source = L10n.providers.planSource(.providerAPI)
            let sourceLabel = L10n.providers.sourceLabel(source)
            let quotaUnavailable =
                L10n.providers.quotaDataUnavailable

            XCTAssertFalse(
                source.hasPrefix("providers."),
                "\(locale) is missing provider-plan source copy"
            )
            XCTAssertFalse(
                sourceLabel.hasPrefix("providers."),
                "\(locale) is missing the source label"
            )
            XCTAssertTrue(
                sourceLabel.contains(source),
                "\(locale) source label lost its placeholder"
            )
            XCTAssertFalse(
                quotaUnavailable.hasPrefix("providers."),
                "\(locale) is missing quota-unavailable copy"
            )
        }
    }

    func test_watchAccountFreshnessCopyResolvesInEverySupportedLocale() {
        for locale in ["en", "ja", "zh-Hans", "zh-Hant", "es", "ko"] {
            LocaleOverrideStore.shared.set(locale)

            let connect = L10n.watch.connectAgentsOnMac
            let stale = L10n.watch.staleUpdated("5m")
            let tightest = L10n.watch.tightestAccount("Work")

            XCTAssertFalse(
                connect.hasPrefix("watch."),
                "\(locale) is missing the Mac setup guidance"
            )
            XCTAssertFalse(
                stale.hasPrefix("watch."),
                "\(locale) is missing stale-data copy"
            )
            XCTAssertTrue(
                stale.contains("5m"),
                "\(locale) stale copy lost its timestamp"
            )
            XCTAssertFalse(
                tightest.hasPrefix("watch."),
                "\(locale) is missing tightest-account copy"
            )
            XCTAssertTrue(
                tightest.contains("Work"),
                "\(locale) tightest-account copy lost its label"
            )
        }
    }
}

#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// The whole value of the first-run window depends on it appearing for new
/// installs and NOT appearing for anyone else. Both failure directions are
/// silent in production — nobody files a bug saying "I did not see a window" —
/// so every case is pinned here, including the ones that must return false.
final class FirstRunPresentationTests: XCTestCase {

    // MARK: - The decision table

    func testBrandNewInstallIsPresented() {
        XCTAssertTrue(
            FirstRunPresentation.shouldPresent(
                existingKeys: [] as [String],
                alreadyShown: false,
                hasSentinel: false
            )
        )
    }

    func testFreshDevIDInstallIsPresentedDespiteMigrationDoneFlag() {
        // `UnsandboxedDataMigration.runIfNeeded()` writes its done-flag even when
        // there was nothing to migrate, and it runs BEFORE the decision. If that
        // key counted as prior use, the window would never appear on Developer ID
        // or Homebrew — two of the three channels — and nothing would say so.
        XCTAssertTrue(
            FirstRunPresentation.shouldPresent(
                existingKeys: [UnsandboxedDataMigration.migrationDoneKey],
                alreadyShown: false,
                hasSentinel: false
            )
        )
    }

    func testAlreadyShownIsNotPresentedAgain() {
        XCTAssertFalse(
            FirstRunPresentation.shouldPresent(
                existingKeys: [] as [String],
                alreadyShown: true,
                hasSentinel: false
            )
        )
    }

    func testSentinelSuppressesEvenWithoutTheShownFlag() {
        // Crash between presenting and marking. Erring toward silence is correct:
        // a repeated welcome window reads as a broken app.
        XCTAssertFalse(
            FirstRunPresentation.shouldPresent(
                existingKeys: [] as [String],
                alreadyShown: false,
                hasSentinel: true
            )
        )
    }

    func testUpgradeFromAVersionWithoutTheSentinelIsNotPresented() {
        // The case a flag added today cannot see by itself: someone on 1.47 who
        // has never written a sentinel. Their other preferences are the evidence.
        XCTAssertFalse(
            FirstRunPresentation.shouldPresent(
                existingKeys: [
                    UnsandboxedDataMigration.migrationDoneKey,
                    "privacy.anonymousTelemetryDisclosed",
                ],
                alreadyShown: false,
                hasSentinel: false
            )
        )
    }

    func testMASToDevIDMoverIsNotTreatedAsNew() {
        // Migration has copied their real preferences into the destination
        // domain. They are an established user on a new channel.
        XCTAssertFalse(
            FirstRunPresentation.shouldPresent(
                existingKeys: [
                    UnsandboxedDataMigration.migrationDoneKey,
                    "cli_pulse_local_mode_enabled",
                    "privacy.anonymousTelemetryEnabled",
                ],
                alreadyShown: false,
                hasSentinel: false
            )
        )
    }

    func testForeignKeysAreNotEvidenceOfPriorUse() {
        // Keys belonging to the OS or other software share the domain on the
        // unsandboxed build. Counting them would suppress the window for
        // everyone on Developer ID.
        XCTAssertTrue(
            FirstRunPresentation.shouldPresent(
                existingKeys: [
                    "AppleLanguages",
                    "NSWindow Frame about",
                    "com.apple.something",
                    "SUEnableAutomaticChecks",
                ],
                alreadyShown: false,
                hasSentinel: false
            )
        )
    }

    // MARK: - Prefix contract

    func testKeysCarryMigrationSafePrefixes() {
        // A key outside `appOwnedKeyPrefixes` is DROPPED on the Mac App Store ->
        // Developer ID move. For the shown-flag that means an established user
        // gets greeted like a stranger after an ordinary-looking update.
        for key in [
            FirstRunPresentation.shownKey,
            FirstRunPresentation.lastSeenAppVersionKey,
        ] {
            XCTAssertTrue(
                UnsandboxedDataMigration.appOwnedKeyPrefixes.contains {
                    key.hasPrefix($0)
                },
                "\(key) is outside appOwnedKeyPrefixes and will be dropped on channel change"
            )
        }
    }

    // MARK: - Store round-trip, on an isolated domain

    /// A private suite, never `.standard`. A test that wrote the real domain
    /// would suppress the window on this machine and poison later tests.
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let name = "com.clipulse.tests.firstrun.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testEvaluateRecordsSentinelAndIsIdempotentAcrossLaunches() throws {
        let defaults = try makeIsolatedDefaults()

        // Launch 1: nothing known -> present, and the sentinel lands.
        XCTAssertTrue(
            FirstRunPresentation.evaluateAndRecordLaunch(
                defaults: defaults, appVersion: "1.49.0"
            )
        )
        XCTAssertEqual(
            defaults.string(forKey: FirstRunPresentation.lastSeenAppVersionKey),
            "1.49.0"
        )

        // Launch 2, same build: the sentinel alone must suppress it, even though
        // nothing marked it shown.
        XCTAssertFalse(
            FirstRunPresentation.evaluateAndRecordLaunch(
                defaults: defaults, appVersion: "1.49.0"
            )
        )

        // Launch 3, a later build: still suppressed, and the sentinel advances so
        // future work can tell what someone upgraded FROM.
        XCTAssertFalse(
            FirstRunPresentation.evaluateAndRecordLaunch(
                defaults: defaults, appVersion: "1.50.0"
            )
        )
        XCTAssertEqual(
            defaults.string(forKey: FirstRunPresentation.lastSeenAppVersionKey),
            "1.50.0"
        )
    }

    func testMarkShownPersistsAndSuppresses() throws {
        let defaults = try makeIsolatedDefaults()
        FirstRunPresentation.markShown(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: FirstRunPresentation.shownKey))
        XCTAssertFalse(
            FirstRunPresentation.evaluateAndRecordLaunch(
                defaults: defaults, appVersion: "1.49.0"
            )
        )
    }

    func testSentinelIsWrittenEvenWhenNotPresenting() throws {
        // The sentinel describes launches, not presentations. If it only landed
        // when the window appeared, an upgrader would never acquire one and
        // every later release would have to re-derive "is this an upgrade" from
        // scratch — the exact gap that made this class necessary.
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: "privacy.anonymousTelemetryDisclosed")

        XCTAssertFalse(
            FirstRunPresentation.evaluateAndRecordLaunch(
                defaults: defaults, appVersion: "1.49.0"
            )
        )
        XCTAssertEqual(
            defaults.string(forKey: FirstRunPresentation.lastSeenAppVersionKey),
            "1.49.0"
        )
    }

    // MARK: - Localisation

    func testStringsResolveRatherThanEchoingTheirKeys() {
        // `tr()` returns the key itself when a string is missing, so a typo in a
        // key ships as literal "first_run.title" on screen. Assert the value
        // differs from the key rather than asserting the English text, which
        // would break on any copy edit.
        for (value, key) in [
            (L10n.firstRun.title, "first_run.title"),
            (L10n.firstRun.body, "first_run.body"),
            (L10n.firstRun.dismiss, "first_run.dismiss"),
        ] {
            XCTAssertNotEqual(value, key, "\(key) did not resolve to a translation")
            XCTAssertFalse(value.isEmpty, "\(key) resolved to an empty string")
        }
    }
}
#endif

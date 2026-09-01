import XCTest
@testable import CLIPulseCore

final class ProviderCollectionConsentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.providerconsent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMarkerRoundTripRequiresMatchingPersistedSelection() throws {
        let configs = ProviderConfig.defaults()
        try persist(configs)
        XCTAssertFalse(ProviderCollectionConsent.isRecorded(defaults: defaults))
        XCTAssertTrue(
            ProviderCollectionConsent.record(
                configs: configs,
                defaults: defaults
            )
        )
        XCTAssertTrue(ProviderCollectionConsent.isRecorded(defaults: defaults))
        XCTAssertEqual(
            defaults.integer(
                forKey: ProviderCollectionConsent.markerDefaultsKey
            ),
            ProviderCollectionConsent.currentVersion
        )
    }

    func testMarkerWithoutSelectionSnapshotFailsClosed() {
        defaults.set(
            ProviderCollectionConsent.currentVersion,
            forKey: ProviderCollectionConsent.markerDefaultsKey
        )

        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
    }

    func testSelectNoneCrashBeforeSnapshotFailsClosed() throws {
        var configs = ProviderConfig.defaults()
        for index in configs.indices {
            configs[index].isEnabled = false
        }
        try persist(configs)

        // Simulate interruption after the marker write but before the
        // matching selection snapshot was durably committed.
        defaults.set(
            ProviderCollectionConsent.currentVersion,
            forKey: ProviderCollectionConsent.markerDefaultsKey
        )

        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
    }

    func testChangedSelectionInvalidatesOldConsentUntilReconfirmed()
        throws
    {
        var configs = ProviderConfig.defaults()
        try persist(configs)
        XCTAssertTrue(
            ProviderCollectionConsent.record(
                configs: configs,
                defaults: defaults
            )
        )

        configs[0].isEnabled.toggle()
        try persist(configs)

        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
    }

    @MainActor
    func testAppStateRecordsConsentInItsInjectedDefaults() {
        let state = AppState(
            runtimeEnvironment: .current,
            defaults: defaults,
            performLaunchSetup: false
        )

        XCTAssertFalse(
            ProviderCollectionConsent.isRecorded(defaults: defaults)
        )

        XCTAssertTrue(state.confirmProviderCollectionSelection())

        XCTAssertTrue(
            ProviderCollectionConsent.isRecorded(defaults: defaults)
        )
    }

    func testFreshInstallRequiresProviderReviewByDefault() {
        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
    }

    func testFreshInstallCannotBeGrantedByDisablingNewUserUIRollout() {
        defaults.set(
            false,
            forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
        )

        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
    }

    func testFreshCohortStaysFailClosedAfterMetadataAppears() throws {
        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
        defaults.set(
            try JSONEncoder().encode(ProviderConfig.defaults()),
            forKey: ProviderAccountMigration.configsKey
        )

        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            ),
            "this release's own metadata write must not reclassify a fresh install"
        )
    }

    func testUnknownStoredCohortFailsClosed() throws {
        defaults.set(
            "future-value",
            forKey: ProviderCollectionConsent.installationCohortDefaultsKey
        )
        defaults.set(
            try JSONEncoder().encode(ProviderConfig.defaults()),
            forKey: ProviderAccountMigration.configsKey
        )

        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
    }

    func testLegacyInstallIsGrandfatheredUntilExistingUserReviewRollsOut() throws {
        defaults.set(
            try JSONEncoder().encode(ProviderConfig.defaults()),
            forKey: ProviderAccountMigration.configsKey
        )

        XCTAssertTrue(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
    }

    func testAgentSetupExistingUserRolloutDoesNotRevokeCollection() throws {
        defaults.set(
            try JSONEncoder().encode(ProviderConfig.defaults()),
            forKey: ProviderAccountMigration.configsKey
        )
        defaults.set(
            true,
            forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
        )

        XCTAssertTrue(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
    }

    func testIndependentExistingUserReviewFlagRequiresReview() throws {
        let configs = ProviderConfig.defaults()
        try persist(configs)
        defaults.set(
            true,
            forKey:
                ProviderCollectionReviewFeatureFlags
                    .existingUsersDefaultsKey
        )

        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderCollectionConsent.record(
                configs: configs,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        )
    }

    func testLegacyAllEnabledWithoutMarkerYieldsZeroCollectibleConfigs() {
        let collectible = ProviderCollectionConsent.collectibleConfigs(
            ProviderConfig.defaults(),
            consentRecorded: false
        )
        XCTAssertTrue(
            collectible.isEmpty,
            "legacy ambiguous state must fail closed, not keep collecting"
        )
    }

    func testRecordedConsentYieldsOnlyEnabledConfigs() {
        var configs = ProviderConfig.defaults()
        for index in configs.indices {
            configs[index].isEnabled = false
        }
        configs[0].isEnabled = true
        configs[2].isEnabled = true

        let collectible = ProviderCollectionConsent.collectibleConfigs(
            configs,
            consentRecorded: true
        )

        XCTAssertEqual(collectible.count, 2)
        XCTAssertTrue(collectible.allSatisfy(\.isEnabled))
    }

    func testMirrorWithoutMarkerContainsNoAccountMetadata() {
        let source = ProviderConfig.defaults()
        let mirrored = ProviderCollectionConsent.helperMirrorConfigs(
            source,
            consentRecorded: false
        )

        XCTAssertTrue(mirrored.isEmpty)
    }

    func testMirrorWithMarkerContainsOnlyEnabledAccounts() {
        var configs = ProviderConfig.defaults()
        for index in configs.indices {
            configs[index].isEnabled = false
        }
        configs[1].isEnabled = true

        let mirrored = ProviderCollectionConsent.helperMirrorConfigs(
            configs,
            consentRecorded: true
        )

        XCTAssertEqual(
            mirrored.map(\.accountID),
            configs.filter(\.isEnabled).map(\.accountID)
        )
        XCTAssertTrue(mirrored.allSatisfy(\.isEnabled))
    }

    private func persist(_ configs: [ProviderConfig]) throws {
        defaults.set(
            try JSONEncoder().encode(configs),
            forKey: ProviderAccountMigration.configsKey
        )
        defaults.set(
            ProviderAccountMigration.currentSchemaVersion,
            forKey: ProviderAccountMigration.schemaVersionKey
        )
    }
}

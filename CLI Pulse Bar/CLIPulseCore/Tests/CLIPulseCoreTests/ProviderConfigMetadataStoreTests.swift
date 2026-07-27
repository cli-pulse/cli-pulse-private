import Foundation
import XCTest
@testable import CLIPulseCore

final class ProviderConfigMetadataStoreTests: XCTestCase {
    func testSavePersistsNonSecretMetadataToBothSuites() throws {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.app.\(UUID())"
            )
        )
        let helperDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.helper.\(UUID())"
            )
        )
        defer {
            clear(appDefaults)
            clear(helperDefaults)
        }
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
            )
        )
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            isEnabled: false,
            apiKey: "must-not-persist",
            manualCookieHeader: "must-not-persist",
            accountLabel: "Work",
            planOverride: "Max",
            syncOwnerUserID: "user-a"
        )
        let store = ProviderConfigMetadataStore(
            defaults: appDefaults,
            helperDefaults: helperDefaults
        )
        appDefaults.set(
            true,
            forKey: ProviderAccountFeatureFlags.writeDefaultsKey
        )

        XCTAssertTrue(store.save([config]))
        XCTAssertTrue(
            helperDefaults.bool(
                forKey: HelperIPC.providerAccountsWriteV2Key
            )
        )

        let persistedLocations = [
            (
                defaults: appDefaults,
                key: ProviderAccountMigration.configsKey
            ),
            (
                defaults: helperDefaults,
                key: HelperIPC.providerConfigsKey
            ),
        ]
        for location in persistedLocations {
            let data = try XCTUnwrap(
                location.defaults.data(forKey: location.key)
            )
            let decoded = try JSONDecoder().decode(
                [ProviderConfig].self,
                from: data
            )
            XCTAssertEqual(decoded.map(\.accountID), [accountID])
            XCTAssertEqual(decoded.first?.accountLabel, "Work")
            XCTAssertEqual(decoded.first?.planOverride, "Max")
            XCTAssertEqual(
                decoded.first?.syncOwnerUserID,
                "user-a"
            )
            XCTAssertFalse(try XCTUnwrap(decoded.first).isEnabled)
            XCTAssertNil(decoded.first?.apiKey)
            XCTAssertNil(decoded.first?.manualCookieHeader)
        }
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}

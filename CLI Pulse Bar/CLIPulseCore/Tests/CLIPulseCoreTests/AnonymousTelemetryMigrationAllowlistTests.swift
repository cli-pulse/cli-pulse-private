import XCTest
@testable import CLIPulseCore

/// Every telemetry key must survive the sandboxed → Developer ID move.
///
/// `UnsandboxedDataMigration.appOwnedKeyPrefixes` is a strict allowlist; a key
/// outside it is simply dropped. For the opt-out flag that is not a lost
/// preference — it is a user who turned telemetry OFF being silently turned
/// back ON by an upgrade they did not ask for. Nothing in the build would warn
/// us, and the only visible symptom would be data we should not have.
///
/// The bug was real in the first draft of this feature: the keys were named
/// `anonymous_telemetry_*`, matching neither prefix.
final class AnonymousTelemetryMigrationAllowlistTests: XCTestCase {

    private var allKeys: [String] {
        [
            UserDefaultsAnonymousTelemetryStore.enabledKey,
            UserDefaultsAnonymousTelemetryStore.disclosureKey,
            UserDefaultsAnonymousTelemetryStore.installIDKey,
            UserDefaultsAnonymousTelemetryStore.installReportedKey,
            UserDefaultsAnonymousTelemetryStore.activationReportedKey,
        ]
    }

    func test_everyTelemetryKeySurvivesTheUnsandboxedMigration() {
        for key in allKeys {
            XCTAssertTrue(
                UnsandboxedDataMigration.appOwnedKeyPrefixes.contains(where: { key.hasPrefix($0) }),
                "'\(key)' is outside the allowlist and would be dropped on MAS -> DEVID"
            )
        }
    }

    /// The opt-out specifically, called out on its own because it is the one
    /// whose loss is a privacy regression rather than an inconvenience.
    func test_theOptOutFlagIsInThePrivacyNamespace() {
        XCTAssertTrue(
            UserDefaultsAnonymousTelemetryStore.enabledKey.hasPrefix("privacy."),
            "losing this key re-enables telemetry for someone who switched it off"
        )
    }

    // MARK: - local-only mode wins

    private func scratchDefaults() -> UserDefaults {
        let suite = "anon-telemetry-allowlist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Local-only mode promises to "skip all cross-app data sources". If
    /// telemetry ignored it, that promise would be false and the user would
    /// have no way to know.
    func test_localOnlyModeForcesTelemetryOff() {
        let defaults = scratchDefaults()
        let store = UserDefaultsAnonymousTelemetryStore(defaults: defaults)
        XCTAssertTrue(store.isEnabled, "precondition: on by default")

        defaults.set(true, forKey: "privacy.localOnlyMode")
        XCTAssertFalse(store.isEnabled, "local-only mode must win over the telemetry default")
    }

    /// The relationship is one-directional. Turning telemetry off is a
    /// statement about telemetry, not permission to change anything else.
    func test_turningTelemetryOffDoesNotTouchLocalOnlyMode() {
        let defaults = scratchDefaults()
        _ = UserDefaultsAnonymousTelemetryStore(defaults: defaults)
        defaults.set(false, forKey: UserDefaultsAnonymousTelemetryStore.enabledKey)
        XCTAssertFalse(defaults.bool(forKey: "privacy.localOnlyMode"))
    }

    /// The key string is duplicated from `PrivacySettings.Keys.localOnlyMode`,
    /// which is private. If that name ever changes, the guard above silently
    /// stops working — telemetry would keep sending for a local-only user and
    /// every test here would still pass. So pin the real setting's behaviour.
    func test_theLocalOnlyKeyMatchesPrivacySettings() {
        let defaults = scratchDefaults()
        let settings = PrivacySettings(defaults: defaults)
        settings.localOnlyMode = true

        let store = UserDefaultsAnonymousTelemetryStore(defaults: defaults)
        XCTAssertFalse(
            store.isEnabled,
            "PrivacySettings writes a different key than the telemetry guard reads"
        )
    }
}

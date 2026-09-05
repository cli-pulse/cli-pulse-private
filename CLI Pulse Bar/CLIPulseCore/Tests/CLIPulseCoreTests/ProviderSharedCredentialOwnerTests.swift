#if os(macOS)
import Darwin
import XCTest
@testable import CLIPulseCore

final class ProviderSharedCredentialOwnerTests: XCTestCase {
    private var originalDefaults: UserDefaults!
    private var testDefaults: UserDefaults!
    private var suiteName: String!
    private var originalMutationLock:
        GeminiCredentialMutationLock!
    private var mutationLockPath: String!
    private var originalSynchronizeDefaults:
        ((UserDefaults) -> Bool)!

    override func setUp() {
        super.setUp()
        originalDefaults = ProviderSharedCredentialOwner.defaults
        originalSynchronizeDefaults =
            ProviderSharedCredentialOwner
                .synchronizeDefaults
        ProviderSharedCredentialOwner
            .synchronizeDefaults = { _ in
                true
            }
        suiteName = "ProviderSharedCredentialOwnerTests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        testDefaults.removePersistentDomain(forName: suiteName)
        ProviderSharedCredentialOwner.defaults = testDefaults
        mutationLockPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "\(suiteName!).lock"
                )
                .path
        originalMutationLock =
            ProviderSharedCredentialOwner.mutationLock
        ProviderSharedCredentialOwner.mutationLock =
            GeminiCredentialMutationLock(
                lockFilePath: mutationLockPath
            )
    }

    override func tearDown() {
        ProviderSharedCredentialOwner.mutationLock =
            originalMutationLock
        ProviderSharedCredentialOwner
            .synchronizeDefaults =
                originalSynchronizeDefaults
        ProviderSharedCredentialOwner.defaults = originalDefaults
        testDefaults.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(
            atPath: mutationLockPath
        ) {
            try? FileManager.default.removeItem(
                atPath: mutationLockPath
            )
        }
        testDefaults = nil
        suiteName = nil
        originalDefaults = nil
        originalMutationLock = nil
        mutationLockPath = nil
        originalSynchronizeDefaults = nil
        super.tearDown()
    }

    func testConcurrentClaimsChooseOnePersistedOwner()
        async throws
    {
        let firstID = try XCTUnwrap(
            UUID(
                uuidString:
                    "01010101-0101-4101-8101-010101010101"
            )
        )
        let secondID = try XCTUnwrap(
            UUID(
                uuidString:
                    "02020202-0202-4202-8202-020202020202"
            )
        )
        let start = DispatchSemaphore(value: 0)
        let first = Task.detached {
            _ = start.wait(
                timeout: .now() + .seconds(2)
            )
            return ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: firstID
            )
        }
        let second = Task.detached {
            _ = start.wait(
                timeout: .now() + .seconds(2)
            )
            return ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: secondID
            )
        }
        start.signal()
        start.signal()

        let results = await [
            first.value,
            second.value,
        ]
        XCTAssertEqual(
            results.filter { $0 }.count,
            1
        )
        let winner = try XCTUnwrap(
            ProviderSharedCredentialOwner.owner(
                kind: .gemini
            )
        )
        XCTAssertTrue(
            winner == firstID || winner == secondID
        )
    }

    func testOwnerStoreUnavailableAndCorruptStatesFailClosed()
        throws
    {
        ProviderSharedCredentialOwner.defaults = nil
        XCTAssertEqual(
            ProviderSharedCredentialOwner.lookup(
                kind: .gemini
            ),
            .unavailable
        )
        XCTAssertFalse(
            ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: UUID()
            )
        )
        XCTAssertFalse(
            ProviderSharedCredentialOwner.canUse(
                kind: .gemini,
                accountID: UUID()
            )
        )

        ProviderSharedCredentialOwner.defaults = testDefaults
        let key =
            "cli_pulse_provider_shared_credential_owner_Gemini"
        testDefaults.set("not-a-uuid", forKey: key)
        XCTAssertEqual(
            ProviderSharedCredentialOwner.lookup(
                kind: .gemini
            ),
            .corrupt
        )
        XCTAssertFalse(
            ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: UUID()
            )
        )
        XCTAssertEqual(
            testDefaults.string(forKey: key),
            "not-a-uuid",
            "a corrupt owner record must remain fail-closed instead of being silently erased"
        )
    }

    func testOwnerStoreSynchronizationFailureFailsClosed()
        throws
    {
        ProviderSharedCredentialOwner
            .synchronizeDefaults = { _ in
                false
            }
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "04040404-0404-4404-8404-040404040404"
            )
        )

        XCTAssertEqual(
            ProviderSharedCredentialOwner.lookup(
                kind: .gemini
            ),
            .unowned,
            "a read-only synchronize hint is advisory; failed persistence must be enforced at the mutation boundary"
        )
        XCTAssertFalse(
            ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: accountID
            )
        )
        XCTAssertFalse(
            ProviderSharedCredentialOwner.reconcile(
                configs: [
                    ProviderConfig(
                        kind: .gemini,
                        accountID: accountID,
                        isEnabled: true
                    ),
                ]
            )
        )
        XCTAssertNil(
            ProviderSharedCredentialOwner.owner(
                kind: .gemini
            )
        )
    }

    func testReleaseForProviderWithoutSharedSourceIsSuccessfulNoOp() {
        XCTAssertTrue(
            ProviderSharedCredentialOwner.release(
                kind: .codex,
                accountID: UUID()
            )
        )
    }

    func testOwnerCallIsReentrantInsideCredentialMutationLock()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "03030303-0303-4303-8303-030303030303"
            )
        )
        let outer = GeminiCredentialMutationLock(
            lockFilePath: mutationLockPath
        )

        XCTAssertTrue(
            outer.withLock(or: false) {
                ProviderSharedCredentialOwner.claim(
                    kind: .gemini,
                    accountID: accountID
                )
            }
        )
        XCTAssertTrue(
            ProviderSharedCredentialOwner.isOwner(
                kind: .gemini,
                accountID: accountID
            )
        )
    }

    @MainActor
    func testAppSaveTransactionLockAllowsReentrantOwnerMutation()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "05050505-0505-4505-8505-050505050505"
            )
        )
        let state = AppState(
            runtimeEnvironment: TestRuntimeFixtures.productionApp,
            defaults: testDefaults,
            helperDefaults: testDefaults,
            performLaunchSetup: false
        )

        XCTAssertTrue(
            state.withProviderAccountPersistenceLock(or: false) {
                ProviderSharedCredentialOwner.claim(
                    kind: .gemini,
                    accountID: accountID
                )
            }
        )
        XCTAssertEqual(
            ProviderSharedCredentialOwner.lookup(kind: .gemini),
            .owned(accountID)
        )
    }

    func testMutationLockRejectsHardLinkBeforeChangingPermissions()
        throws
    {
        let directory =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "GeminiMutationLockHardLink-\(UUID().uuidString)",
                    isDirectory: true
                )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [
                .posixPermissions: 0o700,
            ]
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }
        let target = directory
            .appendingPathComponent("target")
        let lockPath = directory
            .appendingPathComponent("credential.lock")
        try Data("target".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: target.path
        )
        XCTAssertEqual(
            Darwin.link(
                target.path,
                lockPath.path
            ),
            0
        )

        let acquired =
            GeminiCredentialMutationLock(
                lockFilePath: lockPath.path
            ).withLock(or: false) {
                true
            }
        XCTAssertFalse(acquired)
        let attributes =
            try FileManager.default
                .attributesOfItem(
                    atPath: target.path
                )
        XCTAssertEqual(
            (
                attributes[
                    .posixPermissions
                ] as? NSNumber
            )?.intValue,
            0o644,
            "hard-link validation must happen before fchmod"
        )
    }

    func testReconcileChoosesOneDeterministicOwnerPerProvider() throws {
        let laterID = try XCTUnwrap(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        )
        let earlierID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let configs = [
            ProviderConfig(
                kind: .claude,
                accountID: laterID,
                isEnabled: true,
                sortOrder: 20
            ),
            ProviderConfig(
                kind: .claude,
                accountID: earlierID,
                isEnabled: true,
                sortOrder: 10
            ),
        ]

        ProviderSharedCredentialOwner.reconcile(configs: configs)

        XCTAssertTrue(
            ProviderSharedCredentialOwner.isOwner(
                kind: .claude,
                accountID: earlierID
            )
        )
        XCTAssertFalse(
            ProviderSharedCredentialOwner.isOwner(
                kind: .claude,
                accountID: laterID
            )
        )
    }

    func testReconcileRestoresEveryProviderWhenLaterOwnerWriteFails()
        throws
    {
        let claudeID = try XCTUnwrap(
            UUID(
                uuidString:
                    "DADADADA-DADA-4ADA-8ADA-DADADADADADA"
            )
        )
        let geminiID = try XCTUnwrap(
            UUID(
                uuidString:
                    "EAEAEAEA-EAEA-4AEA-8AEA-EAEAEAEAEAEA"
            )
        )
        var synchronizeCalls = 0
        ProviderSharedCredentialOwner.synchronizeDefaults = { _ in
            synchronizeCalls += 1
            return synchronizeCalls != 3
        }

        XCTAssertFalse(
            ProviderSharedCredentialOwner.reconcile(
                configs: [
                    ProviderConfig(
                        kind: .claude,
                        accountID: claudeID,
                        isEnabled: true
                    ),
                    ProviderConfig(
                        kind: .gemini,
                        accountID: geminiID,
                        isEnabled: true
                    ),
                ]
            )
        )
        XCTAssertNil(
            testDefaults.object(
                forKey:
                    "cli_pulse_provider_shared_credential_owner_Claude"
            )
        )
        XCTAssertNil(
            testDefaults.object(
                forKey:
                    "cli_pulse_provider_shared_credential_owner_Gemini"
            )
        )
    }

    func testReconcileSkipsAccountsThatDisableSharedFallback() throws {
        let isolatedID = try XCTUnwrap(
            UUID(uuidString: "12121212-1212-4121-8121-121212121212")
        )
        let compatibilityID = try XCTUnwrap(
            UUID(uuidString: "34343434-3434-4343-8343-343434343434")
        )

        ProviderSharedCredentialOwner.reconcile(configs: [
            ProviderConfig(
                kind: .claude,
                accountID: isolatedID,
                isEnabled: true,
                sortOrder: 0,
                sharedCredentialFallbackDisabled: true
            ),
            ProviderConfig(
                kind: .claude,
                accountID: compatibilityID,
                isEnabled: true,
                sortOrder: 1
            ),
        ])

        XCTAssertFalse(
            ProviderSharedCredentialOwner.isOwner(
                kind: .claude,
                accountID: isolatedID
            )
        )
        XCTAssertTrue(
            ProviderSharedCredentialOwner.isOwner(
                kind: .claude,
                accountID: compatibilityID
            )
        )
    }

    func testReconcileReassignsRemovedOwnerWithoutCrossingProviders() throws {
        let claudeID = try XCTUnwrap(
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")
        )
        let replacementID = try XCTUnwrap(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        )
        let geminiID = try XCTUnwrap(
            UUID(uuidString: "55555555-5555-4555-8555-555555555555")
        )
        ProviderSharedCredentialOwner.reconcile(configs: [
            ProviderConfig(
                kind: .claude,
                accountID: claudeID,
                isEnabled: true,
                sortOrder: 0
            ),
            ProviderConfig(
                kind: .gemini,
                accountID: geminiID,
                isEnabled: true,
                sortOrder: 1
            ),
        ])

        ProviderSharedCredentialOwner.reconcile(configs: [
            ProviderConfig(
                kind: .claude,
                accountID: replacementID,
                isEnabled: true,
                sortOrder: 0
            ),
            ProviderConfig(
                kind: .gemini,
                accountID: geminiID,
                isEnabled: true,
                sortOrder: 1
            ),
        ])

        XCTAssertTrue(
            ProviderSharedCredentialOwner.isOwner(
                kind: .claude,
                accountID: replacementID
            )
        )
        XCTAssertTrue(
            ProviderSharedCredentialOwner.isOwner(
                kind: .gemini,
                accountID: geminiID
            )
        )
        XCTAssertFalse(
            ProviderSharedCredentialOwner.isOwner(
                kind: .claude,
                accountID: geminiID
            )
        )
    }

    func testGeminiOAuthKeysAreAccountScoped() throws {
        let firstID = try XCTUnwrap(
            UUID(uuidString: "66666666-6666-4666-8666-666666666666")
        )
        let secondID = try XCTUnwrap(
            UUID(uuidString: "77777777-7777-4777-8777-777777777777")
        )

        XCTAssertNotEqual(
            GeminiOAuthManager.accountKey(
                GeminiOAuthManager.keyAccessToken,
                accountID: firstID
            ),
            GeminiOAuthManager.accountKey(
                GeminiOAuthManager.keyAccessToken,
                accountID: secondID
            )
        )
    }

    func testClaudeConfiguredTokensRemainAccountScoped() throws {
        let firstID = try XCTUnwrap(
            UUID(uuidString: "88888888-8888-4888-8888-888888888888")
        )
        let secondID = try XCTUnwrap(
            UUID(uuidString: "99999999-9999-4999-8999-999999999999")
        )
        let first = ClaudeCredentials.resolveTokenDetails(
            config: ProviderConfig(
                kind: .claude,
                accountID: firstID,
                apiKey: "sk-ant-oat-first"
            )
        )
        let second = ClaudeCredentials.resolveTokenDetails(
            config: ProviderConfig(
                kind: .claude,
                accountID: secondID,
                apiKey: "sk-ant-oat-second"
            )
        )

        XCTAssertEqual(first.token, "sk-ant-oat-first")
        XCTAssertEqual(first.source, .accountConfig)
        XCTAssertEqual(second.token, "sk-ant-oat-second")
        XCTAssertEqual(second.source, .accountConfig)
    }

    func testClaudeAccountCanDisableMachineGlobalFallback() throws {
        let accountID = try XCTUnwrap(
            UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        )
        ProviderSharedCredentialOwner.reconcile(configs: [
            ProviderConfig(
                kind: .claude,
                accountID: accountID,
                isEnabled: true,
                sortOrder: 0
            ),
        ])
        let resolved = ClaudeCredentials.resolveTokenDetails(
            config: ProviderConfig(
                kind: .claude,
                accountID: accountID,
                sharedCredentialFallbackDisabled: true
            )
        )

        XCTAssertEqual(resolved.token, "")
        XCTAssertEqual(resolved.source, .none)
    }

    func testGeminiRefreshBackoffIsAccountScoped() async throws {
        let firstID = try XCTUnwrap(
            UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")
        )
        let secondID = try XCTUnwrap(
            UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")
        )
        let backoff = GeminiRefreshBackoff()

        await backoff.recordFailure(
            source: .keychain,
            accountID: firstID
        )
        let firstSuppressed = await backoff.shouldSuppressFailure(
            source: .keychain,
            accountID: firstID
        )
        let secondSuppressed = await backoff.shouldSuppressFailure(
            source: .keychain,
            accountID: secondID
        )

        XCTAssertTrue(firstSuppressed)
        XCTAssertFalse(secondSuppressed)
    }
}
#endif

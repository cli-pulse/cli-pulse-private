#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import CLIPulseCore

final class GeminiCredentialPersistenceTests: XCTestCase {
    private var originalOwnerDefaults: UserDefaults!
    private var ownerDefaults: UserDefaults!
    private var ownerSuiteName: String!
    private var outboxDefaults: UserDefaults!
    private var outboxSuiteName: String!
    private var mutationLockPath: String!
    private var originalOwnerMutationLock:
        GeminiCredentialMutationLock!
    private var originalOwnerSynchronizeDefaults:
        ((UserDefaults) -> Bool)!
    private var temporaryCredentialFilePaths:
        [String] = []

    override func setUp() {
        super.setUp()
        originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        ownerSuiteName =
            "GeminiCredentialPersistenceOwner-\(UUID().uuidString)"
        ownerDefaults = UserDefaults(suiteName: ownerSuiteName)
        ownerDefaults.removePersistentDomain(forName: ownerSuiteName)
        ProviderSharedCredentialOwner.defaults = ownerDefaults
        originalOwnerSynchronizeDefaults =
            ProviderSharedCredentialOwner
                .synchronizeDefaults
        ProviderSharedCredentialOwner
            .synchronizeDefaults = { _ in
                true
            }

        outboxSuiteName =
            "GeminiCredentialPersistenceOutbox-\(UUID().uuidString)"
        outboxDefaults = UserDefaults(suiteName: outboxSuiteName)
        outboxDefaults.removePersistentDomain(
            forName: outboxSuiteName
        )
        mutationLockPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "\(outboxSuiteName!).lock"
                )
                .path
        originalOwnerMutationLock =
            ProviderSharedCredentialOwner.mutationLock
        ProviderSharedCredentialOwner.mutationLock =
            GeminiCredentialMutationLock(
                lockFilePath: mutationLockPath
            )
        temporaryCredentialFilePaths = []
    }

    override func tearDown() {
        ProviderSharedCredentialOwner.mutationLock =
            originalOwnerMutationLock
        ProviderSharedCredentialOwner
            .synchronizeDefaults =
                originalOwnerSynchronizeDefaults
        ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
        ownerDefaults.removePersistentDomain(forName: ownerSuiteName)
        outboxDefaults.removePersistentDomain(forName: outboxSuiteName)
        if FileManager.default.fileExists(
            atPath: mutationLockPath
        ) {
            try? FileManager.default.removeItem(
                atPath: mutationLockPath
            )
        }
        for path in temporaryCredentialFilePaths {
            let marker =
                GeminiOAuthManager
                    .globalTransactionMarkerPath(
                        sharedTokenFilePath: path
                    )
            try? FileManager.default.removeItem(
                atPath: path
            )
            try? FileManager.default.removeItem(
                atPath: marker
            )
            let url = URL(fileURLWithPath: path)
            let directory =
                url.deletingLastPathComponent()
            let prefix =
                "\(url.lastPathComponent).pending."
            if let names =
                try? FileManager.default
                    .contentsOfDirectory(
                        atPath: directory.path
                    )
            {
                for name
                    in names
                    where name.hasPrefix(prefix)
                {
                    try? FileManager.default
                        .removeItem(
                            at:
                                directory
                                    .appendingPathComponent(
                                        name
                                    )
                        )
                }
            }
        }
        temporaryCredentialFilePaths = []
        originalOwnerDefaults = nil
        ownerDefaults = nil
        ownerSuiteName = nil
        outboxDefaults = nil
        outboxSuiteName = nil
        mutationLockPath = nil
        originalOwnerMutationLock = nil
        originalOwnerSynchronizeDefaults = nil
        super.tearDown()
    }

    func testPreparedLegacyMigrationResumesAfterTokenCopyFailure()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "11111111-1111-4111-8111-111111111111"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        store.failingSaveKeys.insert(
            GeminiOAuthManager.accountBundleKey(
                accountID: accountID,
                credentialEpoch: 0
            )
        )
        let manager = makeManager(store: store)

        XCTAssertNil(manager.loadTokens(accountID: accountID))
        XCTAssertTrue(
            try XCTUnwrap(
                store.load(
                    key: legacyOwnerKey(accountID),
                    accessGroup:
                        KeychainHelper.sharedAccessGroup
                )
            ).hasPrefix("prepared|"),
            "provenance must be durable before any account token is copied"
        )

        store.failingSaveKeys.removeAll()
        let resumed = try XCTUnwrap(
            manager.loadTokens(accountID: accountID)
        )

        XCTAssertEqual(resumed.accessToken, "legacy-access")
        XCTAssertTrue(
            try XCTUnwrap(
                store.load(
                    key: legacyOwnerKey(accountID),
                    accessGroup:
                        KeychainHelper.sharedAccessGroup
                )
            ).hasPrefix("inherited|")
        )
    }

    func testOldInterruptedCopyRecoversMissingProvenance()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "22222222-2222-4222-8222-222222222222"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        seedAccountTokens(in: store, accountID: accountID)
        XCTAssertTrue(
            ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: accountID
            )
        )
        let manager = makeManager(store: store)

        XCTAssertNotNil(manager.loadTokens(accountID: accountID))
        XCTAssertTrue(
            try XCTUnwrap(
                store.load(
                    key: legacyOwnerKey(accountID),
                    accessGroup:
                        KeychainHelper.sharedAccessGroup
                )
            ).hasPrefix("inherited|")
        )
    }

    func testIndependentAuthorizationSupersedesPreparedLegacyCopy()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "23232323-2323-4323-8323-232323232323"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let bundleKey = GeminiOAuthManager.accountBundleKey(
            accountID: accountID,
            credentialEpoch: 0
        )
        store.failingSaveKeys.insert(bundleKey)
        let manager = makeManager(store: store)

        XCTAssertNil(manager.loadTokens(accountID: accountID))
        store.failingSaveKeys.removeAll()
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "independent-access",
                    refreshToken: "independent-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )

        XCTAssertEqual(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "independent-access",
            "a stale prepared marker must never replay legacy tokens over an independent OAuth commit"
        )
        XCTAssertNil(
            store.load(
                key: legacyOwnerKey(accountID),
                accessGroup: KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertEqual(
            store.load(
                key: GeminiOAuthManager.keyAccessToken,
                accessGroup: KeychainHelper.sharedAccessGroup
            ),
            "legacy-access",
            "superseding one account must not delete the still-unclaimed global compatibility credential"
        )
        XCTAssertFalse(
            ProviderSharedCredentialOwner.isOwner(
                kind: .gemini,
                accountID: accountID
            )
        )
    }

    func testTransferredLegacyOwnerCannotKeepUsingInheritedCopy()
        throws
    {
        let accountA = try XCTUnwrap(
            UUID(
                uuidString:
                    "24242424-2424-4424-8424-242424242424"
            )
        )
        let accountB = try XCTUnwrap(
            UUID(
                uuidString:
                    "25252525-2525-4525-8525-252525252525"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let manager = makeManager(store: store)

        XCTAssertEqual(
            manager.loadTokens(accountID: accountA)?
                .accessToken,
            "legacy-access"
        )
        ProviderSharedCredentialOwner.release(
            kind: .gemini,
            accountID: accountA
        )
        XCTAssertTrue(
            ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: accountB
            )
        )

        XCTAssertNil(
            manager.loadTokens(accountID: accountA),
            "an inherited copy is invalid as soon as legacy ownership moves to another account"
        )
        XCTAssertEqual(
            manager.loadTokens(accountID: accountB)?
                .accessToken,
            "legacy-access"
        )
    }

    func testIndependentAuthorizationThenDisconnectPreservesLegacyGlobal()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "26262626-2626-4626-8626-262626262626"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let manager = makeManager(store: store)
        XCTAssertNotNil(manager.loadTokens(accountID: accountID))

        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "independent-access",
                    refreshToken: "independent-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
        XCTAssertTrue(manager.clearTokens(accountID: accountID))

        XCTAssertEqual(
            store.load(
                key: GeminiOAuthManager.keyAccessToken,
                accessGroup: KeychainHelper.sharedAccessGroup
            ),
            "legacy-access",
            "disconnecting an independently authorized account must not delete a legacy credential it no longer owns"
        )
    }

    func testIndependentBundleWithStaleMarkerNeverDeletesLegacyGlobal()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "26363636-2636-4636-8636-263636363636"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let manager = makeManager(store: store)
        XCTAssertNotNil(manager.loadTokens(accountID: accountID))
        store.failingDeleteKeys.insert(
            legacyOwnerKey(accountID)
        )

        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "independent-access",
                    refreshToken: "independent-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
        XCTAssertFalse(
            manager.clearTokens(accountID: accountID),
            "the undeletable stale marker keeps cleanup retryable"
        )
        XCTAssertEqual(
            store.load(
                key: GeminiOAuthManager.keyAccessToken,
                accessGroup: KeychainHelper.sharedAccessGroup
            ),
            "legacy-access",
            "the committed bundle origin must override stale legacy provenance during deletion"
        )
    }

    func testAtomicBundleWriteFailureExposesNoPartialCredential()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "27272727-2727-4727-8727-272727272727"
            )
        )
        let store = InMemoryGeminiSecretStore()
        store.failingSaveKeys.insert(
            GeminiOAuthManager.accountBundleKey(
                accountID: accountID,
                credentialEpoch: 1
            )
        )
        let manager = makeManager(store: store)

        XCTAssertFalse(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "partial-access",
                    refreshToken: "partial-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
        XCTAssertNil(
            store.load(
                key: accountKey(
                    GeminiOAuthManager.keyAccessToken,
                    accountID: accountID
                ),
                accessGroup: KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertNil(
            store.load(
                key: accountKey(
                    GeminiOAuthManager.keyRefreshToken,
                    accountID: accountID
                ),
                accessGroup: KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testFailedAuthorizationPreservesPreviousCredential()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "37373737-3737-4737-8737-373737373737"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let manager = makeManager(store: store)
        XCTAssertEqual(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "legacy-access"
        )
        store.failingSaveKeys.insert(
            GeminiOAuthManager.accountBundleKey(
                accountID: accountID,
                credentialEpoch: 1
            )
        )

        XCTAssertFalse(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "failed-replacement",
                    refreshToken: "failed-replacement",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
        XCTAssertEqual(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "legacy-access",
            "a failed replacement must roll back the epoch and keep the previously committed credential readable"
        )
    }

    func testAbandonedCredentialWriteRecoversPreviousCredential()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "38383838-3838-4838-8838-383838383838"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let outbox = makeOutbox()
        let manager = makeManager(
            store: store,
            outbox: outbox
        )
        XCTAssertEqual(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "legacy-access"
        )

        let abandoned = try XCTUnwrap(
            outbox.beginCredentialWrite(accountID)
        )
        let abandonedKey =
            GeminiOAuthManager.accountBundleKey(
                accountID: accountID,
                credentialEpoch: abandoned.epoch
            )
        XCTAssertTrue(
            store.save(
                key: abandonedKey,
                value: "{partial",
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )

        XCTAssertEqual(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "legacy-access",
            "once the shared mutation lock is available, a remaining marker is an abandoned transaction and must roll back"
        )
        XCTAssertFalse(
            outbox.hasPendingCredentialWrite(accountID)
        )
        XCTAssertEqual(
            outbox.credentialEpoch(accountID),
            0
        )
        XCTAssertNil(
            store.load(
                key: abandonedKey,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testAbandonedWriteRecoveryResumesAfterEpochRollbackCrash()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "39393939-3939-4939-8939-393939393939"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let storageKeyPrefix =
            "gemini-rollback-resume-\(UUID().uuidString)"
        let outbox = makeOutbox(
            storageKeyPrefix: storageKeyPrefix
        )
        let manager = makeManager(
            store: store,
            outbox: outbox
        )
        XCTAssertNotNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
        let abandoned = try XCTUnwrap(
            outbox.beginCredentialWrite(accountID)
        )

        // Simulate a crash after rollback restored the previous epoch but
        // before it removed the durable write marker.
        outboxDefaults.set(
            Int64(abandoned.epoch - 1),
            forKey:
                "\(storageKeyPrefix).epoch.\(accountID.uuidString.lowercased())"
        )

        XCTAssertEqual(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "legacy-access"
        )
        XCTAssertFalse(
            outbox.hasPendingCredentialWrite(accountID)
        )
        XCTAssertEqual(
            outbox.credentialEpoch(accountID),
            abandoned.epoch - 1
        )
    }

    func testCorruptAtomicBundleFailsClosedInsteadOfFallingBack()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "28282828-2828-4828-8828-282828282828"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        XCTAssertTrue(
            store.save(
                key: accountKey(
                    GeminiOAuthManager.keyBundle,
                    accountID: accountID
                ),
                value: "{truncated",
                accessGroup: KeychainHelper.sharedAccessGroup
            )
        )

        XCTAssertNil(
            makeManager(store: store).loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            ),
            "a present but corrupt committed bundle must block stale individual-key fallback"
        )
    }

    func testDisconnectEpochRejectsInFlightRefreshWriteback()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "29292929-2929-4929-8929-292929292929"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let loader = GatedGeminiRefreshLoader()
        let storageKeyPrefix =
            "gemini-refresh-race-\(UUID().uuidString)"
        let helperManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            dataLoader: { request in
                try await loader.load(request)
            }
        )
        let appManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )
        let refresh = Task {
            try await helperManager.refreshAccessToken(
                accountID: accountID
            )
        }

        XCTAssertTrue(
            loader.waitUntilStarted(),
            "refresh request never reached the controlled network gate"
        )
        XCTAssertTrue(
            appManager.clearTokens(accountID: accountID)
        )
        loader.resume()

        do {
            _ = try await refresh.value
            XCTFail("stale refresh unexpectedly rewrote a deleted token")
        } catch GeminiOAuthError.credentialPersistenceFailed {
            // Expected: the monotonic account epoch changed at Disconnect.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }
        XCTAssertNil(
            helperManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
    }

    func testAuthorizationCommitBlocksRefreshDuringCredentialSwap()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "32323232-3232-4232-8232-323232323232"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let gate = GatedGeminiSecretSave(
            key: accountKey(
                GeminiOAuthManager.keyBundle,
                accountID: accountID
            )
        )
        store.beforeSave = { key in
            gate.pauseIfTarget(key)
        }
        let storageKeyPrefix =
            "gemini-authorization-race-\(UUID().uuidString)"
        let appManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )
        let helperManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            dataLoader: { request in
                let data = Data(
                    """
                    {
                      "access_token": "stale-refresh",
                      "expires_in": 3600
                    }
                    """.utf8
                )
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let authorization = GeminiAuthorizationTokens(
            accessToken: "new-independent-access",
            refreshToken: "new-independent-refresh",
            expiry: Date(timeIntervalSince1970: 2_100_000_000)
        )
        let commit = Task.detached {
            appManager.commitAuthorization(
                authorization,
                accountID: accountID
            )
        }

        XCTAssertTrue(
            gate.waitUntilPaused(),
            "authorization never reached the controlled credential write"
        )

        do {
            _ = try await helperManager.refreshAccessToken(
                accountID: accountID
            )
            XCTFail(
                "helper refresh entered while authorization was replacing the credential"
            )
        } catch GeminiOAuthError.noRefreshToken {
            // Expected: the shared mutation marker makes the account
            // temporarily unreadable in every process.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }

        gate.resume()
        let committed = await commit.value
        XCTAssertTrue(committed)
        XCTAssertEqual(
            helperManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "new-independent-access"
        )
    }

    func testDisconnectAfterInFlightAuthorizationLeavesAccountDisconnected()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "34343434-3434-4434-8434-343434343434"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let gate = GatedGeminiSecretSave(
            key: accountKey(
                GeminiOAuthManager.keyBundle,
                accountID: accountID
            )
        )
        store.beforeSave = { key in
            gate.pauseIfTarget(key)
        }
        let storageKeyPrefix =
            "gemini-disconnect-write-race-\(UUID().uuidString)"
        let writer = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )
        let disconnecter = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )
        let commit = Task.detached {
            writer.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "must-not-survive",
                    refreshToken: "must-not-survive",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        }

        XCTAssertTrue(gate.waitUntilPaused())
        let disconnect = Task.detached {
            disconnecter.clearTokens(accountID: accountID)
        }
        gate.resume()

        let committed = await commit.value
        let disconnected = await disconnect.value
        XCTAssertTrue(
            committed,
            "the authorization already inside the serialized mutation section commits first"
        )
        XCTAssertTrue(disconnected)
        XCTAssertNil(
            disconnecter.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
    }

    func testStaleRefreshCannotOverwriteNewAuthorization()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "36363636-3636-4636-8636-363636363636"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let storageKeyPrefix =
            "gemini-stale-refresh-write-\(UUID().uuidString)"
        let loader = GatedGeminiRefreshLoader()
        let helperManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            dataLoader: { request in
                try await loader.load(request)
            }
        )
        let appManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )

        // Finish the legacy individual-key migration before starting the
        // controlled stale refresh.
        XCTAssertNotNil(
            helperManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )

        let refresh = Task {
            try await helperManager.refreshAccessToken(
                accountID: accountID
            )
        }
        XCTAssertTrue(
            loader.waitUntilStarted(),
            "stale refresh never reached the controlled network gate"
        )
        XCTAssertTrue(
            appManager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "new-authorization-access",
                    refreshToken: "new-authorization-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
        loader.resume()

        do {
            _ = try await refresh.value
            XCTFail(
                "refresh from the retired epoch unexpectedly committed"
            )
        } catch GeminiOAuthError.credentialPersistenceFailed {
            // Expected: the replacement advanced the shared epoch.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }
        XCTAssertEqual(
            appManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "new-authorization-access",
            "a stale refresh must never overwrite or delete the credential committed at the new epoch"
        )
    }

    func testStaleRefreshAuthFailureCannotDeleteNewAuthorization()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "40404040-4040-4040-8040-404040404040"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let storageKeyPrefix =
            "gemini-stale-refresh-401-\(UUID().uuidString)"
        let loader = GatedGeminiRefreshLoader(
            statusCode: 401
        )
        let helperManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            dataLoader: { request in
                try await loader.load(request)
            }
        )
        let appManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )
        XCTAssertNotNil(
            helperManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )

        let refresh = Task {
            try await helperManager.refreshAccessToken(
                accountID: accountID
            )
        }
        XCTAssertTrue(loader.waitUntilStarted())
        XCTAssertTrue(
            appManager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "replacement-after-old-refresh",
                    refreshToken: "replacement-refresh-token",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
        loader.resume()

        do {
            _ = try await refresh.value
            XCTFail("the controlled refresh should return 401")
        } catch GeminiOAuthError.tokenRefreshFailed(401) {
            // Expected. The failure belongs to the retired credential only.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }
        XCTAssertEqual(
            appManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "replacement-after-old-refresh",
            "a permanent error from a retired refresh must not clear the newly authorized credential"
        )
    }

    func testStaleGlobalRefreshCannotRevokeInheritedReplacementAuthorization()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "53535353-5353-4353-8353-535353535353"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let storageKeyPrefix =
            "gemini-stale-global-refresh-\(UUID().uuidString)"
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-stale-global-refresh-\(UUID().uuidString).json"
                )
                .path
        let loader = GatedGeminiRefreshLoader(
            accessToken: "retired-global-refresh"
        )
        let helperManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            sharedTokenFilePath: tokenPath,
            dataLoader: { request in
                try await loader.load(request)
            }
        )
        let appManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            sharedTokenFilePath: tokenPath
        )
        XCTAssertNotNil(helperManager.loadTokens())

        let refresh = Task {
            try await helperManager.refreshAccessToken()
        }
        XCTAssertTrue(loader.waitUntilStarted())
        XCTAssertTrue(
            appManager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "replacement-global-access",
                    refreshToken: "replacement-global-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                )
            )
        )
        XCTAssertEqual(
            appManager.loadTokens(accountID: accountID)?
                .accessToken,
            "replacement-global-access"
        )
        XCTAssertEqual(
            ProviderSharedCredentialOwner.owner(kind: .gemini),
            accountID
        )

        loader.resume()
        do {
            _ = try await refresh.value
            XCTFail(
                "refresh from the retired global generation unexpectedly committed"
            )
        } catch GeminiOAuthError.credentialPersistenceFailed {
            // Expected: global generation CAS rejects the stale response.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }
        XCTAssertEqual(
            appManager.loadTokens()?.accessToken,
            "replacement-global-access"
        )
        XCTAssertEqual(
            appManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "replacement-global-access",
            "a stale global refresh must not revoke an account that inherited the replacement generation"
        )
        XCTAssertEqual(
            ProviderSharedCredentialOwner.owner(kind: .gemini),
            accountID,
            "stale global refresh must not release the replacement generation's owner"
        )
    }

    func testStaleGlobalRefresh401CannotRevokeInheritedReplacementAuthorization()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "54545454-5454-4454-8454-545454545454"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let storageKeyPrefix =
            "gemini-stale-global-refresh-401-\(UUID().uuidString)"
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-stale-global-refresh-401-\(UUID().uuidString).json"
                )
                .path
        let loader = GatedGeminiRefreshLoader(
            statusCode: 401
        )
        let helperManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            sharedTokenFilePath: tokenPath,
            dataLoader: { request in
                try await loader.load(request)
            }
        )
        let appManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            sharedTokenFilePath: tokenPath
        )
        XCTAssertNotNil(helperManager.loadTokens())

        let refresh = Task {
            try await helperManager.refreshAccessToken()
        }
        XCTAssertTrue(loader.waitUntilStarted())
        XCTAssertTrue(
            appManager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "replacement-after-global-401",
                    refreshToken:
                        "replacement-refresh-after-global-401",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                )
            )
        )
        XCTAssertEqual(
            appManager.loadTokens(accountID: accountID)?
                .accessToken,
            "replacement-after-global-401"
        )
        XCTAssertEqual(
            ProviderSharedCredentialOwner.owner(kind: .gemini),
            accountID
        )

        loader.resume()
        do {
            _ = try await refresh.value
            XCTFail("the controlled global refresh should return 401")
        } catch GeminiOAuthError.tokenRefreshFailed(401) {
            // Expected. The failure belongs to the retired generation only.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }
        XCTAssertEqual(
            appManager.loadTokens()?.accessToken,
            "replacement-after-global-401"
        )
        XCTAssertEqual(
            appManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )?.accessToken,
            "replacement-after-global-401",
            "a stale global 401 must not revoke an account that inherited the replacement generation"
        )
        XCTAssertEqual(
            ProviderSharedCredentialOwner.owner(kind: .gemini),
            accountID,
            "stale global 401 must not release the replacement generation's owner"
        )
    }

    func testConcurrentInheritedRefreshUsesGenerationCAS()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "41414141-4141-4141-8141-414141414141"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let storageKeyPrefix =
            "gemini-inherited-refresh-cas-\(UUID().uuidString)"
        let firstLoader = GatedGeminiRefreshLoader(
            accessToken: "first-inherited-refresh"
        )
        let secondLoader = GatedGeminiRefreshLoader(
            accessToken: "second-inherited-refresh"
        )
        let firstManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            dataLoader: { request in
                try await firstLoader.load(request)
            }
        )
        let secondManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            ),
            dataLoader: { request in
                try await secondLoader.load(request)
            }
        )
        XCTAssertNotNil(
            firstManager.loadTokens(accountID: accountID)
        )

        let firstRefresh = Task {
            try await firstManager.refreshAccessToken(
                accountID: accountID
            )
        }
        let secondRefresh = Task {
            try await secondManager.refreshAccessToken(
                accountID: accountID
            )
        }
        XCTAssertTrue(firstLoader.waitUntilStarted())
        XCTAssertTrue(secondLoader.waitUntilStarted())

        firstLoader.resume()
        let firstResult = try await firstRefresh.value
        XCTAssertEqual(
            firstResult,
            "first-inherited-refresh"
        )
        secondLoader.resume()
        do {
            _ = try await secondRefresh.value
            XCTFail(
                "the second refresh used a generation that had already been replaced"
            )
        } catch GeminiOAuthError.credentialPersistenceFailed {
            // Expected: generation CAS rejects the stale refresh.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }
        XCTAssertEqual(
            firstManager.loadTokens(accountID: accountID)?
                .accessToken,
            "first-inherited-refresh",
            "the winning bundle and inherited provenance must remain consistent"
        )
    }

    func testCorruptCredentialWriteBarrierFailsClosed()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "35353535-3535-4535-8535-353535353535"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let storageKeyPrefix =
            "gemini-corrupt-write-\(UUID().uuidString)"
        outboxDefaults.set(
            Data([0x00, 0x01]),
            forKey:
                "\(storageKeyPrefix).write.\(accountID.uuidString.lowercased())"
        )
        let manager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )

        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
        XCTAssertFalse(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "must-not-write",
                    refreshToken: "must-not-write",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
    }

    func testCorruptCredentialEpochFailsClosed() throws {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "30303030-3030-4030-8030-303030303030"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let storageKeyPrefix =
            "gemini-corrupt-epoch-\(UUID().uuidString)"
        outboxDefaults.set(
            "not-an-epoch",
            forKey:
                "\(storageKeyPrefix).epoch.\(accountID.uuidString.lowercased())"
        )
        let manager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )

        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
        XCTAssertFalse(manager.clearTokens(accountID: accountID))
        XCTAssertFalse(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "must-not-write",
                    refreshToken: "must-not-write",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
    }

    func testInheritedRefreshAdvancesBoundGeneration()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "31313131-3131-4131-8131-313131313131"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let manager = makeManager(
            store: store,
            dataLoader: { request in
                let data = Data(
                    """
                    {
                      "access_token": "refreshed-inherited",
                      "expires_in": 3600
                    }
                    """.utf8
                )
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        XCTAssertNotNil(manager.loadTokens(accountID: accountID))

        let refreshed = try await manager
            .refreshAccessToken(accountID: accountID)
        XCTAssertEqual(refreshed, "refreshed-inherited")
        XCTAssertEqual(
            manager.loadTokens(accountID: accountID)?
                .accessToken,
            "refreshed-inherited"
        )
        XCTAssertTrue(
            try XCTUnwrap(
                store.load(
                    key: legacyOwnerKey(accountID),
                    accessGroup:
                        KeychainHelper.sharedAccessGroup
                )
            ).hasPrefix("inherited|")
        )
    }

    func testFailedDisconnectPersistsAndRetriesWithoutResurrection()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "33333333-3333-4333-8333-333333333333"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let accessKey = accountKey(
            GeminiOAuthManager.keyAccessToken,
            accountID: accountID
        )
        store.failingDeleteKeys.insert(accessKey)
        let outbox = makeOutbox()
        let manager = makeManager(
            store: store,
            outbox: outbox
        )

        XCTAssertFalse(manager.clearTokens(accountID: accountID))
        XCTAssertTrue(outbox.contains(accountID))
        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            ),
            "a queued deletion must fail closed instead of exposing a partially deleted credential"
        )

        store.failingDeleteKeys.removeAll()
        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
        XCTAssertFalse(outbox.contains(accountID))
        XCTAssertNil(
            store.load(
                key: accessKey,
                accessGroup: KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testDisconnectRecoveryAdvancesEpochBeforeDeleting()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "42424242-4242-4242-8242-424242424242"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let loader = GatedGeminiRefreshLoader(
            accessToken: "must-not-resurrect"
        )
        let storageKeyPrefix =
            "gemini-disconnect-crash-\(UUID().uuidString)"
        let outbox = makeOutbox(
            storageKeyPrefix: storageKeyPrefix
        )
        let helperManager = makeManager(
            store: store,
            outbox: outbox,
            dataLoader: { request in
                try await loader.load(request)
            }
        )
        let recoveringManager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )
        XCTAssertNotNil(
            helperManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )

        let refresh = Task {
            try await helperManager.refreshAccessToken(
                accountID: accountID
            )
        }
        XCTAssertTrue(loader.waitUntilStarted())

        // Simulate a process crash after the durable deletion marker was
        // installed but before the epoch was advanced.
        let pendingDeletion = try XCTUnwrap(
            outbox.beginDeletion(
                accountID,
                deleteLegacyCredential: false,
                legacyCredentialIdentity: nil
            )
        )
        XCTAssertEqual(
            outbox.credentialEpoch(accountID),
            pendingDeletion.targetEpoch - 1
        )
        XCTAssertNil(
            recoveringManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
        loader.resume()
        do {
            _ = try await refresh.value
            XCTFail(
                "a refresh from before the recovered Disconnect resurrected the credential"
            )
        } catch GeminiOAuthError.credentialPersistenceFailed {
            // Expected: recovery establishes the tombstone epoch first.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }
        XCTAssertNil(
            recoveringManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
    }

    func testInheritedDisconnectRetainsGlobalCleanupObligation()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "43434343-4343-4343-8343-434343434343"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let storageKeyPrefix =
            "gemini-inherited-delete-retry-\(UUID().uuidString)"
        let manager = makeManager(
            store: store,
            outbox: makeOutbox(
                storageKeyPrefix: storageKeyPrefix
            )
        )
        XCTAssertNotNil(manager.loadTokens(accountID: accountID))

        store.failingDeleteKeys.insert(
            GeminiOAuthManager.keyRefreshToken
        )
        XCTAssertFalse(
            manager.clearTokens(accountID: accountID)
        )
        store.failingDeleteKeys.removeAll()

        XCTAssertNil(manager.loadTokens(accountID: accountID))
        XCTAssertNil(
            store.load(
                key: GeminiOAuthManager.keyRefreshToken,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            ),
            "the deletion transaction must remember that the inherited global refresh token still requires cleanup"
        )
    }

    func testPendingInheritedDeletionCompletesBeforeGlobalReauthorization()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "46464646-4646-4646-8646-464646464646"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let outbox = makeOutbox()
        let manager = makeManager(
            store: store,
            outbox: outbox
        )
        XCTAssertEqual(
            manager.loadTokens(
                accountID: accountID
            )?.accessToken,
            "legacy-access"
        )

        store.failingDeleteKeys.insert(
            GeminiOAuthManager.accountBundleKey(
                accountID: accountID,
                credentialEpoch: 0
            )
        )
        XCTAssertFalse(
            manager.clearTokens(accountID: accountID)
        )
        XCTAssertTrue(outbox.contains(accountID))
        store.failingDeleteKeys.removeAll()

        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "replacement-access",
                    refreshToken: "replacement-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                )
            )
        )

        XCTAssertFalse(outbox.contains(accountID))
        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
        XCTAssertEqual(
            manager.loadTokens()?.accessToken,
            "replacement-access",
            "global reauthorization must run only after the older inherited deletion is complete"
        )
    }

    func testTransferredOwnerPreservesReplacementGlobalCredential()
        throws
    {
        let firstAccountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "47474747-4747-4747-8747-474747474747"
            )
        )
        let secondAccountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "48484848-4848-4848-8848-484848484848"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let outbox = makeOutbox()
        let manager = makeManager(
            store: store,
            outbox: outbox
        )
        XCTAssertNotNil(
            manager.loadTokens(accountID: firstAccountID)
        )

        store.failingDeleteKeys.insert(
            GeminiOAuthManager.accountBundleKey(
                accountID: firstAccountID,
                credentialEpoch: 0
            )
        )
        XCTAssertFalse(
            manager.clearTokens(accountID: firstAccountID)
        )
        XCTAssertTrue(outbox.contains(firstAccountID))
        store.failingDeleteKeys.removeAll()

        ProviderSharedCredentialOwner.release(
            kind: .gemini,
            accountID: firstAccountID
        )
        XCTAssertTrue(
            ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: secondAccountID
            )
        )
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "new-owner-access",
                    refreshToken: "new-owner-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                )
            )
        )

        XCTAssertNil(
            manager.loadTokens(
                accountID: firstAccountID,
                allowLegacyFallback: false
            )
        )
        XCTAssertFalse(outbox.contains(firstAccountID))
        XCTAssertEqual(
            manager.loadTokens()?.accessToken,
            "new-owner-access",
            "a stale deletion owned by another account must not delete the replacement global credential"
        )
        XCTAssertEqual(
            ProviderSharedCredentialOwner.owner(
                kind: .gemini
            ),
            secondAccountID
        )
    }

    func testPendingInheritedDeletionWinsOverInFlightGlobalRefresh()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "49494949-4949-4949-8949-494949494949"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let outbox = makeOutbox()
        let loader = GatedGeminiRefreshLoader(
            accessToken: "must-not-replace-deleted-global"
        )
        let manager = makeManager(
            store: store,
            outbox: outbox,
            dataLoader: { request in
                try await loader.load(request)
            }
        )
        XCTAssertNotNil(
            manager.loadTokens(accountID: accountID)
        )

        let refresh = Task {
            try await manager.refreshAccessToken()
        }
        XCTAssertTrue(loader.waitUntilStarted())

        store.failingDeleteKeys.insert(
            GeminiOAuthManager.accountBundleKey(
                accountID: accountID,
                credentialEpoch: 0
            )
        )
        XCTAssertFalse(
            manager.clearTokens(accountID: accountID)
        )
        XCTAssertTrue(outbox.contains(accountID))
        store.failingDeleteKeys.removeAll()

        loader.resume()
        do {
            _ = try await refresh.value
            XCTFail(
                "an in-flight refresh replaced the global credential after its inherited owner disconnected"
            )
        } catch GeminiOAuthError.credentialPersistenceFailed {
            // Expected: the pending deletion is completed before writeback.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }

        XCTAssertFalse(outbox.contains(accountID))
        XCTAssertNil(manager.loadTokens())
        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
    }

    func testGlobalReauthorizationRevokesInheritedAccountAndSurvivesLaterDisconnect()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "50505050-5050-4050-8050-505050505050"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let manager = makeManager(store: store)
        XCTAssertEqual(
            manager.loadTokens(
                accountID: accountID
            )?.accessToken,
            "legacy-access"
        )

        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "unrelated-global-access",
                    refreshToken: "unrelated-global-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                )
            )
        )
        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            ),
            "replacing the global credential must revoke its old inherited account copy"
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager.accountBundleKey(
                        accountID: accountID,
                        credentialEpoch: 0
                    ),
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertNil(
            store.load(
                key: legacyOwnerKey(accountID),
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertTrue(
            manager.clearTokens(accountID: accountID)
        )
        XCTAssertEqual(
            manager.loadTokens()?.accessToken,
            "unrelated-global-access",
            "the old inherited account must never delete an unrelated replacement global credential"
        )
    }

    func testGlobalClearRevokesInheritedAccountCredential()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "51515151-5151-4151-8151-515151515151"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let manager = makeManager(store: store)
        XCTAssertNotNil(
            manager.loadTokens(accountID: accountID)
        )

        XCTAssertTrue(manager.clearTokens())
        XCTAssertNil(manager.loadTokens())
        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            ),
            "global clear must not leave an inherited refresh token usable from the account slot"
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager.accountBundleKey(
                        accountID: accountID,
                        credentialEpoch: 0
                    ),
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertNil(
            store.load(
                key: legacyOwnerKey(accountID),
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testGlobalRefresh401RevokesInheritedAccountCredential()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "52525252-5252-4252-8252-525252525252"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let manager = makeManager(
            store: store,
            dataLoader: { request in
                (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        XCTAssertNotNil(
            manager.loadTokens(accountID: accountID)
        )

        do {
            _ = try await manager.refreshAccessToken()
            XCTFail("the controlled global refresh should return 401")
        } catch GeminiOAuthError.tokenRefreshFailed(401) {
            // Expected.
        } catch {
            XCTFail("unexpected refresh error: \(error)")
        }
        XCTAssertNil(manager.loadTokens())
        XCTAssertNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            ),
            "permanent global auth failure must revoke the inherited account credential"
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager.accountBundleKey(
                        accountID: accountID,
                        credentialEpoch: 0
                    ),
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertNil(
            store.load(
                key: legacyOwnerKey(accountID),
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testGlobalCredentialTransactionAlignsKeychainAndHelperGeneration()
        throws
    {
        let store = InMemoryGeminiSecretStore()
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-transaction-\(UUID().uuidString).json"
                ).path
        let manager = makeManager(
            store: store,
            sharedTokenFilePath: tokenPath
        )

        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "transaction-access",
                    refreshToken: "transaction-refresh",
                    expiry: Date(
                        timeIntervalSince1970:
                            2_100_000_000
                    )
                )
            )
        )

        let keychain = try XCTUnwrap(
            jsonObject(
                try XCTUnwrap(
                    store.load(
                        key:
                            GeminiOAuthManager
                                .keyBundle,
                        accessGroup:
                            KeychainHelper
                                .sharedAccessGroup
                    )
                )
            )
        )
        let helper = try XCTUnwrap(
            jsonObject(
                try String(
                    contentsOfFile: tokenPath,
                    encoding: .utf8
                )
            )
        )
        XCTAssertEqual(
            helper["generation"] as? String,
            keychain["generation"] as? String
        )
        XCTAssertEqual(
            helper["access_token"] as? String,
            "transaction-access"
        )
        XCTAssertNil(helper["refresh_token"])
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyGlobalPendingBundle,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyGlobalTransactionControl,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    GeminiOAuthManager
                        .globalTransactionMarkerPath(
                            sharedTokenFilePath:
                                tokenPath
                        )
            )
        )
        let attributes =
            try FileManager.default.attributesOfItem(
                atPath: tokenPath
            )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?
                .intValue,
            0o600
        )
    }

    func testGlobalReplacementRecoversAfterActiveBundleWriteFailure()
        throws
    {
        let store = InMemoryGeminiSecretStore()
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-replace-recovery-\(UUID().uuidString).json"
                ).path
        let outbox = makeOutbox()
        let manager = makeManager(
            store: store,
            outbox: outbox,
            sharedTokenFilePath: tokenPath
        )
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "old-global-access",
                    refreshToken:
                        "old-global-refresh",
                    expiry: Date(
                        timeIntervalSince1970:
                            2_000_000_000
                    )
                )
            )
        )

        store.failingSaveKeys.insert(
            GeminiOAuthManager.keyBundle
        )
        XCTAssertFalse(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "new-global-access",
                    refreshToken:
                        "new-global-refresh",
                    expiry: Date(
                        timeIntervalSince1970:
                            2_100_000_000
                    )
                )
            )
        )
        let markerPath =
            GeminiOAuthManager
                .globalTransactionMarkerPath(
                    sharedTokenFilePath: tokenPath
                )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: markerPath
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(
                jsonObject(
                    try String(
                        contentsOfFile: tokenPath,
                        encoding: .utf8
                    )
                )
            )["access_token"] as? String,
            "old-global-access",
            "the helper must keep its old live credential while the marker makes readers fail closed"
        )
        XCTAssertNotNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyGlobalPendingBundle,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )

        store.failingSaveKeys.removeAll()
        let recoveringManager = makeManager(
            store: store,
            outbox: outbox,
            sharedTokenFilePath: tokenPath
        )
        XCTAssertEqual(
            recoveringManager.loadTokens()?
                .accessToken,
            "new-global-access"
        )
        XCTAssertEqual(
            try XCTUnwrap(
                jsonObject(
                    try String(
                        contentsOfFile: tokenPath,
                        encoding: .utf8
                    )
                )
            )["access_token"] as? String,
            "new-global-access"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: markerPath
            )
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyGlobalPendingBundle,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testDiskOnlyReplacementMarkerCannotAuthorizeKeychainMutation()
        throws
    {
        let store = InMemoryGeminiSecretStore()
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-marker-only-\(UUID().uuidString).json"
                ).path
        let manager = makeManager(
            store: store,
            sharedTokenFilePath: tokenPath
        )
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "old-marker-access",
                    refreshToken:
                        "old-marker-refresh",
                    expiry: Date(
                        timeIntervalSince1970:
                            2_100_000_000
                    )
                )
            )
        )
        let oldBundle = try XCTUnwrap(
            jsonObject(
                try XCTUnwrap(
                    store.load(
                        key:
                            GeminiOAuthManager
                                .keyBundle,
                        accessGroup:
                            KeychainHelper
                                .sharedAccessGroup
                    )
                )
            )
        )
        let oldGeneration = try XCTUnwrap(
            oldBundle["generation"] as? String
        )
        let operationID =
            "62626262-6262-4262-8262-626262626262"
        let markerPath =
            GeminiOAuthManager
                .globalTransactionMarkerPath(
                    sharedTokenFilePath: tokenPath
                )
        let marker: [String: Any] = [
            "version": 1,
            "operationID": operationID,
            "authorizationNonce":
                "64646464-6464-4464-8464-646464646464",
            "operation": "replace",
            "expectedOldIdentity":
                "generation:\(oldGeneration)",
            "targetGeneration":
                "63636363-6363-4363-8363-636363636363",
        ]
        let markerData =
            try JSONSerialization.data(
                withJSONObject: marker,
                options: [.sortedKeys]
            )
        try markerData.write(
            to: URL(fileURLWithPath: markerPath),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerPath
        )

        XCTAssertNil(
            manager.loadTokens(),
            "a disk-only marker has no Keychain authorization and must fail closed"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: markerPath
            ),
            "an unauthenticated marker must remain visible for diagnosis instead of being executed or silently erased"
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyGlobalPendingBundle,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertEqual(
            jsonObject(
                try XCTUnwrap(
                    store.load(
                        key:
                            GeminiOAuthManager
                                .keyBundle,
                        accessGroup:
                            KeychainHelper
                                .sharedAccessGroup
                    )
                )
            )?["generation"] as? String,
            oldGeneration,
            "disk-writable metadata must never authorize mutation of the active Keychain bundle"
        )
    }

    func testDiskOnlyClearMarkerCannotDeleteKeychainCredential()
        throws
    {
        let store = InMemoryGeminiSecretStore()
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-forged-clear-\(UUID().uuidString).json"
                ).path
        let manager = makeManager(
            store: store,
            sharedTokenFilePath: tokenPath
        )
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "must-survive-forged-clear",
                    refreshToken:
                        "must-survive-forged-clear-refresh",
                    expiry: Date(
                        timeIntervalSince1970:
                            2_100_000_000
                    )
                )
            )
        )
        let bundle = try XCTUnwrap(
            jsonObject(
                try XCTUnwrap(
                    store.load(
                        key:
                            GeminiOAuthManager
                                .keyBundle,
                        accessGroup:
                            KeychainHelper
                                .sharedAccessGroup
                    )
                )
            )
        )
        let generation = try XCTUnwrap(
            bundle["generation"] as? String
        )
        try writeGlobalTransactionArtifacts(
            [
                "version": 1,
                "operationID":
                    "65656565-6565-4565-8565-656565656565",
                "authorizationNonce":
                    "66666666-6666-4666-8666-666666666666",
                "operation": "clear",
                "expectedOldIdentity":
                    "generation:\(generation)",
            ],
            tokenPath: tokenPath,
            store: store,
            includeControl: false
        )

        XCTAssertNil(manager.loadTokens())
        XCTAssertFalse(manager.clearTokens())
        XCTAssertNotNil(
            store.load(
                key: GeminiOAuthManager.keyBundle,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            ),
            "a helper-directory marker cannot authorize Keychain deletion"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tokenPath
            )
        )
    }

    func testInterruptedLegacyClearPreservesLaterFieldReplacement()
        throws
    {
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-legacy-clear-cas-\(UUID().uuidString).json"
                ).path
        let manager = makeManager(
            store: store,
            sharedTokenFilePath: tokenPath
        )
        try writeGlobalTransactionArtifacts(
            [
                "version": 1,
                "operationID":
                    "67676767-6767-4767-8767-676767676767",
                "authorizationNonce":
                    "68686868-6868-4868-8868-686868686868",
                "operation": "clear",
                "expectedOldIdentity":
                    "digest:\(String(repeating: "a", count: 64))",
                "legacyKeyDigests": [
                    "access":
                        sha256Hex("legacy-access"),
                    "refresh":
                        sha256Hex("legacy-refresh"),
                    "expiry":
                        sha256Hex("2000000000"),
                ],
            ],
            tokenPath: tokenPath,
            store: store
        )
        XCTAssertTrue(
            store.save(
                key:
                    GeminiOAuthManager
                        .keyRefreshToken,
                value:
                    "later-legacy-refresh",
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )

        XCTAssertNil(manager.loadTokens())
        XCTAssertEqual(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyRefreshToken,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            ),
            "later-legacy-refresh",
            "an old clear transaction may delete only the exact legacy fields it originally targeted"
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyAccessToken,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyExpiry,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testAbortKeepsAuthorizationMarkerWhenPendingSecretCleanupFails()
        throws
    {
        let store = InMemoryGeminiSecretStore()
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-abort-cleanup-\(UUID().uuidString).json"
                ).path
        let manager = makeManager(
            store: store,
            sharedTokenFilePath: tokenPath
        )
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "abort-old-access",
                    refreshToken: "abort-old-refresh",
                    expiry: Date(
                        timeIntervalSince1970:
                            2_100_000_000
                    )
                )
            )
        )
        let bundle = try XCTUnwrap(
            jsonObject(
                try XCTUnwrap(
                    store.load(
                        key:
                            GeminiOAuthManager
                                .keyBundle,
                        accessGroup:
                            KeychainHelper
                                .sharedAccessGroup
                    )
                )
            )
        )
        let generation = try XCTUnwrap(
            bundle["generation"] as? String
        )
        try writeGlobalTransactionArtifacts(
            [
                "version": 1,
                "operationID":
                    "69696969-6969-4969-8969-696969696969",
                "authorizationNonce":
                    "70707070-7070-4070-8070-707070707070",
                "operation": "replace",
                "expectedOldIdentity":
                    "generation:\(generation)",
                "targetGeneration":
                    "71717171-7171-4171-8171-717171717171",
            ],
            tokenPath: tokenPath,
            store: store
        )
        XCTAssertTrue(
            store.save(
                key:
                    GeminiOAuthManager
                        .keyGlobalPendingBundle,
                value: "not-json",
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        store.failingDeleteKeys.insert(
            GeminiOAuthManager
                .keyGlobalPendingBundle
        )

        XCTAssertNil(manager.loadTokens())
        let markerPath =
            GeminiOAuthManager
                .globalTransactionMarkerPath(
                    sharedTokenFilePath: tokenPath
                )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: markerPath
            ),
            "the marker must remain while a pending Keychain secret cannot be removed"
        )
        XCTAssertNotNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyGlobalTransactionControl,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
        XCTAssertNotNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyGlobalPendingBundle,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )

        store.failingDeleteKeys.removeAll()
        XCTAssertEqual(
            manager.loadTokens()?.accessToken,
            "abort-old-access"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: markerPath
            )
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyGlobalTransactionControl,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testGlobalReplacementRecoveryIsIdempotentAfterPublish()
        throws
    {
        let store = InMemoryGeminiSecretStore()
        seedLegacyTokens(in: store)
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-publish-recovery-\(UUID().uuidString).json"
                ).path
        let manager = makeManager(
            store: store,
            sharedTokenFilePath: tokenPath
        )
        store.failingDeleteKeys.insert(
            GeminiOAuthManager.keyAccessToken
        )

        XCTAssertFalse(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken:
                        "published-global-access",
                    refreshToken:
                        "published-global-refresh",
                    expiry: Date(
                        timeIntervalSince1970:
                            2_100_000_000
                    )
                )
            )
        )
        let markerPath =
            GeminiOAuthManager
                .globalTransactionMarkerPath(
                    sharedTokenFilePath: tokenPath
                )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: markerPath
            )
        )
        XCTAssertNil(
            manager.loadTokens(),
            "an unfinished marker must hide even an already-published target from App readers"
        )
        XCTAssertEqual(
            try XCTUnwrap(
                jsonObject(
                    try String(
                        contentsOfFile: tokenPath,
                        encoding: .utf8
                    )
                )
            )["access_token"] as? String,
            "published-global-access"
        )

        store.failingDeleteKeys.removeAll()
        XCTAssertEqual(
            manager.loadTokens()?.accessToken,
            "published-global-access"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: markerPath
            )
        )
        XCTAssertNil(
            store.load(
                key:
                    GeminiOAuthManager
                        .keyGlobalPendingBundle,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testGlobalClearRecoversAfterInterruptedKeychainDeletion()
        throws
    {
        let store = InMemoryGeminiSecretStore()
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-clear-recovery-\(UUID().uuidString).json"
                ).path
        let manager = makeManager(
            store: store,
            sharedTokenFilePath: tokenPath
        )
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "clear-access",
                    refreshToken: "clear-refresh",
                    expiry: Date(
                        timeIntervalSince1970:
                            2_100_000_000
                    )
                )
            )
        )
        store.failingDeleteKeys.insert(
            GeminiOAuthManager.keyBundle
        )

        XCTAssertFalse(manager.clearTokens())
        let markerPath =
            GeminiOAuthManager
                .globalTransactionMarkerPath(
                    sharedTokenFilePath: tokenPath
                )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: markerPath
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tokenPath
            )
        )

        store.failingDeleteKeys.removeAll()
        XCTAssertNil(manager.loadTokens())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tokenPath
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: markerPath
            )
        )
    }

    func testCorruptGlobalTransactionMarkerFailsClosed()
        throws
    {
        let store = InMemoryGeminiSecretStore()
        let tokenPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "gemini-corrupt-transaction-\(UUID().uuidString).json"
                ).path
        let manager = makeManager(
            store: store,
            sharedTokenFilePath: tokenPath
        )
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "preserved-access",
                    refreshToken:
                        "preserved-refresh",
                    expiry: Date(
                        timeIntervalSince1970:
                            2_100_000_000
                    )
                )
            )
        )
        let markerPath =
            GeminiOAuthManager
                .globalTransactionMarkerPath(
                    sharedTokenFilePath: tokenPath
                )
        try Data("{\"version\":999}".utf8)
            .write(
                to: URL(fileURLWithPath: markerPath),
                options: .atomic
            )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerPath
        )

        XCTAssertNil(manager.loadTokens())
        XCTAssertFalse(manager.clearTokens())
        XCTAssertNotNil(
            store.load(
                key: GeminiOAuthManager.keyBundle,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            ),
            "corrupt recovery metadata must not authorize credential deletion"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tokenPath
            )
        )
    }

    func testMalformedDeletionMarkerRejectsOversizedEpochAndInvalidIdentity()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "53535353-5353-4353-8353-535353535353"
            )
        )
        let operationID =
            "54545454-5454-4454-8454-545454545454"
        let storageKeyPrefix =
            "gemini-malformed-delete-\(UUID().uuidString)"
        let markerKey =
            "\(storageKeyPrefix).\(accountID.uuidString.lowercased())"
        let outbox = makeOutbox(
            storageKeyPrefix: storageKeyPrefix
        )

        outboxDefaults.set(
            "v3|\(operationID)|9223372036854775808|0|",
            forKey: markerKey
        )
        XCTAssertNil(
            outbox.pendingDeletion(accountID),
            "an epoch that cannot be represented by UserDefaults Int64 must be rejected before recovery"
        )

        outboxDefaults.set(
            "v3|\(operationID)|1|1|generation:not-a-uuid",
            forKey: markerKey
        )
        XCTAssertNil(
            outbox.pendingDeletion(accountID),
            "only canonical generation or digest identities may authorize global deletion"
        )
    }

    func testHistoricalCredentialSlotsRemainBoundedAndDisconnectable()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "45454545-4545-4545-8545-454545454545"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let manager = makeManager(store: store)
        XCTAssertNotNil(
            manager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
        let firstEpochKey =
            GeminiOAuthManager.accountBundleKey(
                accountID: accountID,
                credentialEpoch: 0
            )
        store.failingDeleteKeys.insert(firstEpochKey)
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "epoch-one",
                    refreshToken: "epoch-one-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
        store.failingDeleteKeys.removeAll()
        XCTAssertTrue(
            manager.commitAuthorization(
                GeminiAuthorizationTokens(
                    accessToken: "epoch-two",
                    refreshToken: "epoch-two-refresh",
                    expiry: Date(
                        timeIntervalSince1970: 2_100_000_000
                    )
                ),
                accountID: accountID
            )
        )
        XCTAssertTrue(manager.clearTokens(accountID: accountID))
        XCTAssertNil(
            store.load(
                key: firstEpochKey,
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            ),
            "a failed retired-slot cleanup must not leave an unreachable refresh token after later authorizations and Disconnect"
        )
    }

    func testFailedDisconnectMarkerIsSharedAcrossAppAndHelperInstances()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "55555555-5555-4555-8555-555555555555"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        let accessKey = accountKey(
            GeminiOAuthManager.keyAccessToken,
            accountID: accountID
        )
        store.failingDeleteKeys.insert(accessKey)
        let storageKeyPrefix =
            "gemini-shared-deletion-\(UUID().uuidString)"
        let appOutbox = makeOutbox(
            storageKeyPrefix: storageKeyPrefix
        )
        let helperOutbox = makeOutbox(
            storageKeyPrefix: storageKeyPrefix
        )
        let appManager = makeManager(
            store: store,
            outbox: appOutbox
        )
        let helperManager = makeManager(
            store: store,
            outbox: helperOutbox
        )

        XCTAssertFalse(
            appManager.clearTokens(accountID: accountID)
        )
        XCTAssertTrue(
            helperOutbox.contains(accountID),
            "the helper process must observe the app's durable delete marker"
        )
        XCTAssertNil(
            helperManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            ),
            "a helper-side read must fail closed while deletion is pending"
        )

        store.failingDeleteKeys.removeAll()
        XCTAssertNil(
            helperManager.loadTokens(
                accountID: accountID,
                allowLegacyFallback: false
            )
        )
        XCTAssertFalse(appOutbox.contains(accountID))
        XCTAssertFalse(helperOutbox.contains(accountID))
        XCTAssertNil(
            store.load(
                key: accessKey,
                accessGroup: KeychainHelper.sharedAccessGroup
            )
        )
    }

    func testProductionDeletionOutboxUsesHelperAppGroup() {
        XCTAssertEqual(
            GeminiCredentialDeletionOutbox.productionSuiteName,
            HelperIPC.suiteName
        )
    }

    func testCredentialMutationLockSerializesIndependentInstances()
        async
    {
        let firstLock = GeminiCredentialMutationLock(
            lockFilePath: mutationLockPath
        )
        let secondLock = GeminiCredentialMutationLock(
            lockFilePath: mutationLockPath
        )
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)

        let first = Task.detached {
            firstLock.withLock(or: false) {
                firstEntered.signal()
                _ = releaseFirst.wait(
                    timeout: .now() + .seconds(2)
                )
                return true
            }
        }
        XCTAssertEqual(
            firstEntered.wait(
                timeout: .now() + .seconds(2)
            ),
            .success
        )

        let second = Task.detached {
            secondStarted.signal()
            return secondLock.withLock(or: false) {
                secondEntered.signal()
                return true
            }
        }
        XCTAssertEqual(
            secondStarted.wait(
                timeout: .now() + .seconds(2)
            ),
            .success
        )
        XCTAssertEqual(
            secondEntered.wait(
                timeout: .now() + .milliseconds(50)
            ),
            .timedOut,
            "the second App/Helper mutation entered before the first released the shared lock"
        )

        releaseFirst.signal()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(
            secondEntered.wait(
                timeout: .now() + .seconds(2)
            ),
            .success
        )
        let secondResult = await second.value
        XCTAssertTrue(secondResult)
    }

    func testDraftCommitReportsCredentialDeletionFailure()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "44444444-4444-4444-8444-444444444444"
            )
        )
        let store = InMemoryGeminiSecretStore()
        seedAccountTokens(in: store, accountID: accountID)
        store.failingDeleteKeys.insert(
            accountKey(
                GeminiOAuthManager.keyAccessToken,
                accountID: accountID
            )
        )
        var draft = GeminiCredentialDraft(isConnected: true)
        draft.stageDisconnect()

        XCTAssertFalse(
            draft.commit(
                using: makeManager(store: store),
                accountID: accountID
            )
        )
    }

    private func makeManager(
        store: InMemoryGeminiSecretStore,
        outbox: GeminiCredentialDeletionOutbox? = nil,
        sharedTokenFilePath: String? = nil,
        dataLoader:
            GeminiOAuthManager.TokenDataLoader? = nil
    ) -> GeminiOAuthManager {
        let tokenPath =
            sharedTokenFilePath
                ?? FileManager.default
                    .temporaryDirectory
                    .appendingPathComponent(
                        "gemini-\(UUID().uuidString).json"
                    )
                    .path
        if !temporaryCredentialFilePaths
            .contains(tokenPath)
        {
            temporaryCredentialFilePaths
                .append(tokenPath)
        }
        return GeminiOAuthManager(
            secretStore: store,
            deletionOutbox: outbox ?? makeOutbox(),
            credentialMutationLock:
                GeminiCredentialMutationLock(
                    lockFilePath: mutationLockPath
                ),
            sharedTokenFilePath: tokenPath,
            tokenDataLoader:
                dataLoader
                    ?? GeminiOAuthManager.defaultTokenDataLoader
        )
    }

    private func makeOutbox(
        storageKeyPrefix: String =
            "gemini-credential-deletion-\(UUID().uuidString)"
    ) -> GeminiCredentialDeletionOutbox {
        GeminiCredentialDeletionOutbox(
            // Use a fresh facade over the same suite for every manager. This
            // exercises the App/Helper cache boundary instead of accidentally
            // proving visibility through one shared UserDefaults instance.
            defaults: UserDefaults(suiteName: outboxSuiteName),
            storageKeyPrefix: storageKeyPrefix
        )
    }

    private func seedLegacyTokens(
        in store: InMemoryGeminiSecretStore
    ) {
        seed(
            in: store,
            accessKey: GeminiOAuthManager.keyAccessToken,
            refreshKey: GeminiOAuthManager.keyRefreshToken,
            expiryKey: GeminiOAuthManager.keyExpiry
        )
    }

    private func seedAccountTokens(
        in store: InMemoryGeminiSecretStore,
        accountID: UUID
    ) {
        seed(
            in: store,
            accessKey: accountKey(
                GeminiOAuthManager.keyAccessToken,
                accountID: accountID
            ),
            refreshKey: accountKey(
                GeminiOAuthManager.keyRefreshToken,
                accountID: accountID
            ),
            expiryKey: accountKey(
                GeminiOAuthManager.keyExpiry,
                accountID: accountID
            )
        )
    }

    private func seed(
        in store: InMemoryGeminiSecretStore,
        accessKey: String,
        refreshKey: String,
        expiryKey: String
    ) {
        let group = KeychainHelper.sharedAccessGroup
        XCTAssertTrue(
            store.save(
                key: accessKey,
                value: "legacy-access",
                accessGroup: group
            )
        )
        XCTAssertTrue(
            store.save(
                key: refreshKey,
                value: "legacy-refresh",
                accessGroup: group
            )
        )
        XCTAssertTrue(
            store.save(
                key: expiryKey,
                value: "2000000000",
                accessGroup: group
            )
        )
    }

    private func accountKey(
        _ base: String,
        accountID: UUID
    ) -> String {
        GeminiOAuthManager.accountKey(
            base,
            accountID: accountID
        )
    }

    private func legacyOwnerKey(_ accountID: UUID) -> String {
        accountKey(
            GeminiOAuthManager.keyLegacyOwner,
            accountID: accountID
        )
    }

    private func writeGlobalTransactionArtifacts(
        _ object: [String: Any],
        tokenPath: String,
        store: InMemoryGeminiSecretStore,
        includeControl: Bool = true
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let markerPath =
            GeminiOAuthManager
                .globalTransactionMarkerPath(
                    sharedTokenFilePath: tokenPath
                )
        try data.write(
            to: URL(fileURLWithPath: markerPath),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerPath
        )
        guard includeControl else { return }
        XCTAssertTrue(
            store.save(
                key:
                    GeminiOAuthManager
                        .keyGlobalTransactionControl,
                value: try XCTUnwrap(
                    String(
                        data: data,
                        encoding: .utf8
                    )
                ),
                accessGroup:
                    KeychainHelper.sharedAccessGroup
            )
        )
    }

    private func sha256Hex(
        _ value: String
    ) -> String {
        SHA256.hash(
            data: Data(value.utf8)
        ).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func jsonObject(
        _ raw: String
    ) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization
            .jsonObject(with: data)
            as? [String: Any]
    }
}

private final class InMemoryGeminiSecretStore:
    ProviderSecretStoring,
    @unchecked Sendable
{
    private struct Slot: Hashable {
        let key: String
        let accessGroup: String?
    }

    private var values: [Slot: String] = [:]
    private let lock = NSLock()
    var failingSaveKeys: Set<String> = []
    var failingDeleteKeys: Set<String> = []
    var beforeSave: (@Sendable (String) -> Void)?

    @discardableResult
    func save(
        key: String,
        value: String,
        accessGroup: String?
    ) -> Bool {
        beforeSave?(key)
        lock.lock()
        defer { lock.unlock() }
        guard !failingSaveKeys.contains(key) else {
            return false
        }
        values[Slot(key: key, accessGroup: accessGroup)] = value
        return true
    }

    func load(
        key: String,
        accessGroup: String?
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[
            Slot(key: key, accessGroup: accessGroup)
        ]
    }

    @discardableResult
    func delete(
        key: String,
        accessGroup: String?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !failingDeleteKeys.contains(key) else {
            return false
        }
        values.removeValue(
            forKey: Slot(key: key, accessGroup: accessGroup)
        )
        return true
    }
}

private final class GatedGeminiSecretSave:
    @unchecked Sendable
{
    private let targetKey: String
    private let paused = DispatchSemaphore(value: 0)
    private let resumeSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didPause = false

    init(key: String) {
        self.targetKey = key
    }

    func pauseIfTarget(_ key: String) {
        lock.lock()
        let shouldPause =
            (
                key == targetKey
                || key.hasPrefix("\(targetKey).slot.")
            )
            && !didPause
        if shouldPause {
            didPause = true
        }
        lock.unlock()
        guard shouldPause else { return }
        paused.signal()
        _ = resumeSignal.wait(
            // The production cross-process lock times out after two seconds.
            // Keep this fault-injection gate open longer so the competing
            // process deterministically observes that fail-closed boundary
            // instead of racing the gate's own timeout.
            timeout: .now() + .seconds(5)
        )
    }

    func waitUntilPaused() -> Bool {
        paused.wait(
            timeout: .now() + .seconds(2)
        ) == .success
    }

    func resume() {
        resumeSignal.signal()
    }
}

private final class GatedGeminiRefreshLoader:
    @unchecked Sendable
{
    private let statusCode: Int
    private let accessToken: String
    private let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<Void, Never>?

    init(
        statusCode: Int = 200,
        accessToken: String =
            "refresh-after-disconnect"
    ) {
        self.statusCode = statusCode
        self.accessToken = accessToken
    }

    func waitUntilStarted() -> Bool {
        started.wait(
            timeout: .now() + .seconds(2)
        ) == .success
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func load(
        _ request: URLRequest
    ) async throws -> (Data, URLResponse) {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            started.signal()
            lock.unlock()
        }
        let data = Data(
            """
            {
              "access_token": "\(accessToken)",
              "expires_in": 3600
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
#endif

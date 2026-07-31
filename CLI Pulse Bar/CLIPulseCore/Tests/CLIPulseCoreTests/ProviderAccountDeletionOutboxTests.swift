import XCTest
@testable import CLIPulseCore

@MainActor
final class ProviderAccountDeletionOutboxTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName =
            "ProviderAccountDeletionOutboxTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPendingDeletesAreDeduplicatedAndIsolatedByUser()
        throws
    {
        let accountA = try XCTUnwrap(
            UUID(
                uuidString:
                    "11111111-1111-4111-8111-111111111111"
            )
        )
        let accountB = try XCTUnwrap(
            UUID(
                uuidString:
                    "22222222-2222-4222-8222-222222222222"
            )
        )
        let outbox = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: "test.pending"
        )

        outbox.enqueue(
            userID: "USER-A",
            accountID: accountA,
            provider: .claude
        )
        outbox.enqueue(
            userID: "USER-A",
            accountID: accountA,
            provider: .claude
        )
        outbox.enqueue(
            userID: "USER-B",
            accountID: accountB,
            provider: .codex
        )

        XCTAssertEqual(
            outbox.pendingAccountIDs(for: "user-a"),
            [accountA]
        )
        XCTAssertEqual(
            outbox.pendingAccountIDs(for: "user-b"),
            [accountB]
        )
    }

    func testCompletionRemovesOnlyTheExactOwnerAndAccount()
        throws
    {
        let account = try XCTUnwrap(
            UUID(
                uuidString:
                    "33333333-3333-4333-8333-333333333333"
            )
        )
        let outbox = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: "test.pending"
        )
        outbox.enqueue(
            userID: "user-a",
            accountID: account,
            provider: .claude
        )
        outbox.enqueue(
            userID: "user-b",
            accountID: account,
            provider: .codex
        )

        outbox.markCompleted(
            userID: "user-a",
            accountID: account
        )

        XCTAssertTrue(
            outbox.pendingAccountIDs(for: "user-a").isEmpty
        )
        XCTAssertEqual(
            outbox.pendingAccountIDs(for: "user-b"),
            [account]
        )
    }

    func testPendingDeleteSurvivesOutboxRecreation() throws {
        let account = try XCTUnwrap(
            UUID(
                uuidString:
                    "44444444-4444-4444-8444-444444444444"
            )
        )
        ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: "test.pending"
        ).enqueue(
            userID: "user-a",
            accountID: account,
            provider: .claude
        )

        let restored = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: "test.pending"
        )

        XCTAssertEqual(
            restored.pendingAccountIDs(for: "USER-A"),
            [account]
        )
        XCTAssertEqual(
            restored.pendingIntents().first?.provider,
            .claude
        )
    }

    func testProviderlessV1IntentDecodesAndCanBeSafelyEnriched()
        throws
    {
        let account = try XCTUnwrap(
            UUID(
                uuidString:
                    "45454545-4545-4545-8545-454545454545"
            )
        )
        let storageKey = "test.pending"
        defaults.set(
            Data(
                """
                [{"userID":"user-a","accountID":"\(account.uuidString)"}]
                """.utf8
            ),
            forKey: storageKey
        )
        let outbox = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: storageKey
        )

        XCTAssertNil(outbox.pendingIntents().first?.provider)
        XCTAssertTrue(
            outbox.enqueue(
                userID: "user-a",
                accountID: account,
                provider: .claude
            )
        )
        XCTAssertEqual(outbox.pendingIntents().count, 1)
        XCTAssertEqual(
            outbox.pendingIntents().first?.provider,
            .claude
        )
    }

    func testPersistedIntentRecoversLocalConfigAfterCrash() throws {
        let account = try XCTUnwrap(
            UUID(
                uuidString:
                    "55555555-5555-4555-8555-555555555555"
            )
        )
        let outbox = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: "test.pending"
        )
        XCTAssertTrue(
            outbox.enqueue(
                userID: "user-a",
                accountID: account,
                provider: .claude
            )
        )
        let configs = [
            ProviderConfig(
                kind: .claude,
                accountID: account,
                syncOwnerUserID: "user-a"
            ),
            ProviderConfig(
                kind: .codex,
                accountID: UUID(),
                syncOwnerUserID: "user-b"
            ),
        ]

        let recovered = ProviderAccountDeletionRecovery
            .accountIDsToRemove(
                from: configs,
                pending: outbox.pendingIntents()
            )

        XCTAssertEqual(recovered, [account])
    }

    func testRecoveryNeverCrossesSyncOwnerBoundary() throws {
        let account = try XCTUnwrap(
            UUID(
                uuidString:
                    "66666666-6666-4666-8666-666666666666"
            )
        )
        let outbox = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: "test.pending"
        )
        XCTAssertTrue(
            outbox.enqueue(
                userID: "user-a",
                accountID: account,
                provider: .claude
            )
        )

        let recovered = ProviderAccountDeletionRecovery
            .accountIDsToRemove(
                from: [
                    ProviderConfig(
                        kind: .claude,
                        accountID: account,
                        syncOwnerUserID: "user-b"
                    ),
                ],
                pending: outbox.pendingIntents()
            )

        XCTAssertTrue(recovered.isEmpty)
    }

    func testTruncatedStorageFailsClosedAndIsPreserved()
        throws
    {
        let storageKey = "test.corrupt.truncated"
        let corruptData = Data("{\"version\":1".utf8)
        defaults.set(corruptData, forKey: storageKey)
        let outbox = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: storageKey
        )

        XCTAssertTrue(outbox.hasCorruptStorage)
        XCTAssertFalse(
            outbox.enqueue(
                userID: "user-a",
                accountID: UUID(),
                provider: .claude
            )
        )
        XCTAssertEqual(
            defaults.data(forKey: storageKey),
            corruptData,
            "a failed decode must never be overwritten as an empty queue"
        )
        XCTAssertEqual(
            defaults.data(
                forKey: "\(storageKey).corrupt_backup"
            ),
            corruptData
        )
    }

    func testUnknownEnvelopeVersionFailsClosed() {
        let storageKey = "test.corrupt.version"
        defaults.set(
            Data(
                """
                {"version":999,"intents":[]}
                """.utf8
            ),
            forKey: storageKey
        )
        let outbox = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: storageKey
        )

        XCTAssertTrue(outbox.hasCorruptStorage)
        XCTAssertFalse(
            outbox.enqueue(
                userID: "user-a",
                accountID: UUID(),
                provider: .codex
            )
        )
    }

    func testWrongStoredTypeFailsClosed() {
        let storageKey = "test.corrupt.type"
        defaults.set("not-data", forKey: storageKey)
        let outbox = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: storageKey
        )

        XCTAssertTrue(outbox.hasCorruptStorage)
        XCTAssertFalse(
            outbox.enqueue(
                userID: "user-a",
                accountID: UUID(),
                provider: .gemini
            )
        )
        XCTAssertEqual(
            defaults.string(forKey: storageKey),
            "not-data"
        )
    }
}

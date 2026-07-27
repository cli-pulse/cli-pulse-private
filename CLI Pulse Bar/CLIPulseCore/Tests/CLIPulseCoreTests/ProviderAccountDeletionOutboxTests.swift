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

        outbox.enqueue(userID: "USER-A", accountID: accountA)
        outbox.enqueue(userID: "USER-A", accountID: accountA)
        outbox.enqueue(userID: "USER-B", accountID: accountB)

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
        outbox.enqueue(userID: "user-a", accountID: account)
        outbox.enqueue(userID: "user-b", accountID: account)

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
        ).enqueue(userID: "user-a", accountID: account)

        let restored = ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: "test.pending"
        )

        XCTAssertEqual(
            restored.pendingAccountIDs(for: "USER-A"),
            [account]
        )
    }
}

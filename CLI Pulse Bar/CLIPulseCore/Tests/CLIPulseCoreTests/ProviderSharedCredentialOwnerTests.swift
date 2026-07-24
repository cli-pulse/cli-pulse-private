#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class ProviderSharedCredentialOwnerTests: XCTestCase {
    private var originalDefaults: UserDefaults!
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        originalDefaults = ProviderSharedCredentialOwner.defaults
        suiteName = "ProviderSharedCredentialOwnerTests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        testDefaults.removePersistentDomain(forName: suiteName)
        ProviderSharedCredentialOwner.defaults = testDefaults
    }

    override func tearDown() {
        ProviderSharedCredentialOwner.defaults = originalDefaults
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        originalDefaults = nil
        super.tearDown()
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

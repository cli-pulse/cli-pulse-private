import XCTest
@testable import CLIPulseCore

final class ProviderCollectionAuthorizationTests: XCTestCase {
    func testMissingPersistedSelectionCollectsNothing() {
        let authorization = ProviderCollectionAuthorization.resolve(
            persistedData: nil
        )

        XCTAssertFalse(authorization.hasPersistentSelection)
        XCTAssertTrue(
            authorization.configs.isEmpty,
            "the helper must not fall back to every provider before the user saves a selection"
        )
    }

    func testInvalidPersistedSelectionFailsClosed() {
        let authorization = ProviderCollectionAuthorization.resolve(
            persistedData: Data("not-json".utf8)
        )

        XCTAssertFalse(authorization.hasPersistentSelection)
        XCTAssertTrue(authorization.configs.isEmpty)
    }

    func testValidPersistedSelectionIsPreserved() throws {
        var cursor = ProviderConfig(kind: .cursor)
        cursor.isEnabled = false
        cursor.cookieSource = .automatic
        let data = try JSONEncoder().encode([cursor])

        let authorization = ProviderCollectionAuthorization.resolve(
            persistedData: data
        )

        XCTAssertTrue(authorization.hasPersistentSelection)
        XCTAssertEqual(authorization.configs.count, 1)
        XCTAssertEqual(authorization.configs.first?.kind, .cursor)
        XCTAssertEqual(authorization.configs.first?.isEnabled, false)
        XCTAssertEqual(authorization.configs.first?.cookieSource, .automatic)
    }

    func testSecretHydrationIncludesOnlyEnabledAccounts() {
        let configs = [
            ProviderConfig(kind: .codex, isEnabled: true),
            ProviderConfig(kind: .cursor, isEnabled: false),
            ProviderConfig(kind: .claude, isEnabled: true),
        ]

        XCTAssertEqual(
            ProviderCollectionAuthorization.secretHydrationIndices(
                in: configs
            ),
            [0, 2],
            "an unselected provider must not trigger startup Keychain reads"
        )
    }

    #if os(macOS)
    func testMissingProjectionDoesNotInvokeHelperProcessScanner() {
        let authorization = ProviderCollectionAuthorization.resolve(
            persistedData: nil
        )
        var scanCalls = 0

        let result = authorization.scanLocalProcesses { _ in
            scanCalls += 1
            return LocalScanResult(
                sessions: [],
                providers: [],
                totalUsage: 0,
                totalCost: 0,
                activeSessionCount: 0
            )
        }

        XCTAssertEqual(scanCalls, 0)
        XCTAssertEqual(result.activeSessionCount, 0)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func testHelperProcessScannerReceivesOnlyEnabledProviderKinds()
        throws
    {
        let configs = [
            ProviderConfig(kind: .codex, isEnabled: true),
            ProviderConfig(kind: .claude, isEnabled: false),
        ]
        let authorization = ProviderCollectionAuthorization.resolve(
            persistedData: try JSONEncoder().encode(configs)
        )
        var receivedKinds: Set<ProviderKind> = []

        _ = authorization.scanLocalProcesses { kinds in
            receivedKinds = kinds
            return LocalScanResult(
                sessions: [],
                providers: [],
                totalUsage: 0,
                totalCost: 0,
                activeSessionCount: 0
            )
        }

        XCTAssertEqual(receivedKinds, [.codex])
    }
    #endif
}

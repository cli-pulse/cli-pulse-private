import Foundation
import XCTest
@testable import CLIPulseCore

final class ProviderDiscoveryServiceTests: XCTestCase {
    func testPassiveDiscoveryUsesOnlyBoundedMetadataProbes() {
        let inspector = RecordingProviderDiscoveryInspector(
            existingPaths: [
                "/Users/tester/.claude/.credentials.json",
            ],
            executablePaths: [
                "/usr/local/bin/codex",
            ]
        )
        let claudeAccountID = UUID(
            uuidString: "11111111-1111-4111-8111-111111111111"
        )!
        let service = ProviderDiscoveryService(
            fileInspector: inspector,
            homeDirectory: "/Users/tester",
            pathDirectories: ["/usr/local/bin"]
        )

        let results = service.discover(
            context: ProviderDiscoveryContext(
                accounts: [
                    ProviderDiscoveryAccountMetadata(
                        accountID: claudeAccountID,
                        provider: .claude,
                        isEnabled: true
                    ),
                ],
                connectedAccountIDs: [],
                authorizedBookmarkIDs: ["gemini"]
            )
        )

        XCTAssertEqual(results.map(\.kind), [.codex, .claude, .gemini])
        XCTAssertEqual(
            results.first(where: { $0.kind == .codex })?.status,
            .detected
        )
        XCTAssertEqual(
            results.first(where: { $0.kind == .claude })?.status,
            .actionRequired
        )
        XCTAssertEqual(
            results.first(where: { $0.kind == .gemini })?.status,
            .detected
        )
        XCTAssertEqual(
            results.first(where: { $0.kind == .claude })?.accountIDs,
            [claudeAccountID]
        )

        XCTAssertEqual(
            Set(inspector.fileExistenceProbes),
            [
                "/Users/tester/.codex/auth.json",
                "/Users/tester/.claude/.credentials.json",
                "/Users/tester/.gemini/oauth_creds.json",
            ]
        )
        XCTAssertEqual(
            Set(inspector.executableProbes),
            [
                "/usr/local/bin/codex",
                "/usr/local/bin/claude",
                "/usr/local/bin/gemini",
            ]
        )
    }

    func testConnectedStatusWinsAndStableAccountIDsAreNotDuplicated() {
        let inspector = RecordingProviderDiscoveryInspector()
        let firstID = UUID(
            uuidString: "22222222-2222-4222-8222-222222222222"
        )!
        let secondID = UUID(
            uuidString: "33333333-3333-4333-8333-333333333333"
        )!
        let context = ProviderDiscoveryContext(
            accounts: [
                .init(
                    accountID: secondID,
                    provider: .claude,
                    isEnabled: true
                ),
                .init(
                    accountID: firstID,
                    provider: .claude,
                    isEnabled: false
                ),
                .init(
                    accountID: secondID,
                    provider: .claude,
                    isEnabled: true
                ),
            ],
            connectedAccountIDs: [secondID],
            authorizedBookmarkIDs: []
        )
        let service = ProviderDiscoveryService(
            fileInspector: inspector,
            homeDirectory: "/Users/tester",
            pathDirectories: []
        )

        let firstRun = service.discover(context: context)
        let secondRun = service.discover(context: context)
        let claude = firstRun.first { $0.kind == .claude }

        XCTAssertEqual(firstRun, secondRun)
        XCTAssertEqual(claude?.status, .connected)
        XCTAssertEqual(claude?.accountIDs, [firstID, secondID])
        XCTAssertEqual(
            claude?.signals,
            [.existingConfiguration, .knownConnection]
        )
    }

    func testUndetectedCoreProvidersReturnNotFoundWithoutScanningRegistry()
    {
        let inspector = RecordingProviderDiscoveryInspector()
        let service = ProviderDiscoveryService(
            fileInspector: inspector,
            homeDirectory: "/Users/tester",
            pathDirectories: ["/bin", "/opt/bin"]
        )

        let results = service.discover(context: .empty)

        XCTAssertEqual(results.map(\.kind), [.codex, .claude, .gemini])
        XCTAssertEqual(results.map(\.status), [
            .notFound, .notFound, .notFound,
        ])
        XCTAssertEqual(inspector.fileExistenceProbes.count, 3)
        XCTAssertEqual(inspector.executableProbes.count, 6)
        XCTAssertFalse(
            inspector.executableProbes.contains {
                $0.contains("cursor") || $0.contains("deepseek")
            }
        )
    }
}

private final class RecordingProviderDiscoveryInspector:
    ProviderDiscoveryFileInspecting
{
    private let existingPaths: Set<String>
    private let executablePaths: Set<String>
    private(set) var fileExistenceProbes: [String] = []
    private(set) var executableProbes: [String] = []

    init(
        existingPaths: Set<String> = [],
        executablePaths: Set<String> = []
    ) {
        self.existingPaths = existingPaths
        self.executablePaths = executablePaths
    }

    func fileExists(atPath path: String) -> Bool {
        fileExistenceProbes.append(path)
        return existingPaths.contains(path)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        executableProbes.append(path)
        return executablePaths.contains(path)
    }
}

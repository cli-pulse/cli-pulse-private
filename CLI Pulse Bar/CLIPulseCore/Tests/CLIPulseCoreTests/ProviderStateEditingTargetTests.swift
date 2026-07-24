import XCTest
@testable import CLIPulseCore

@MainActor
final class ProviderStateEditingTargetTests: XCTestCase {
    func testEditingTargetResolvesExactAccountWithinSameProvider() throws {
        let firstID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let secondID = try XCTUnwrap(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        )
        let state = ProviderState()
        state.providerConfigs = [
            ProviderConfig(
                kind: .claude,
                accountID: firstID,
                accountLabel: "Personal"
            ),
            ProviderConfig(
                kind: .claude,
                accountID: secondID,
                accountLabel: "Work"
            ),
        ]

        state.editingProviderAccountID = secondID

        XCTAssertEqual(state.editingProviderConfig?.accountID, secondID)
        XCTAssertEqual(state.editingProviderConfig?.accountLabel, "Work")
    }
}

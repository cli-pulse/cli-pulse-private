#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class GeminiCredentialDraftTests: XCTestCase {
    func testExistingConnectionStagesDisconnectWithoutImmediateCommit() {
        var draft = GeminiCredentialDraft(isConnected: true)

        draft.stageDisconnect()

        XCTAssertFalse(draft.isConnected)
        XCTAssertEqual(draft.pendingMutation, .disconnect)
    }

    func testNewAuthorizationStaysAnInMemoryConnectMutation() {
        var draft = GeminiCredentialDraft(isConnected: false)
        let authorization = GeminiAuthorizationTokens(
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            expiry: Date(timeIntervalSince1970: 2_000_000_000)
        )

        draft.stageAuthorization(authorization)

        XCTAssertTrue(draft.isConnected)
        XCTAssertEqual(draft.pendingMutation, .connect)
    }

    func testDisconnectAfterNewAuthorizationReturnsToNoChange() {
        var draft = GeminiCredentialDraft(isConnected: false)
        draft.stageAuthorization(
            GeminiAuthorizationTokens(
                accessToken: "access-secret",
                refreshToken: "refresh-secret",
                expiry: Date(timeIntervalSince1970: 2_000_000_000)
            )
        )

        draft.stageDisconnect()

        XCTAssertFalse(draft.isConnected)
        XCTAssertEqual(draft.pendingMutation, .unchanged)
    }

    func testOpeningAnEditorHasNoPendingCredentialMutation() {
        XCTAssertEqual(
            GeminiCredentialDraft(
                isConnected: true
            ).pendingMutation,
            .unchanged
        )
    }

    func testConnectionTestUsesPersistedCredentialsWhenUnchanged() {
        XCTAssertEqual(
            GeminiCredentialDraft(
                isConnected: true
            ).connectionTestDisposition,
            .usePersistedCredentials
        )
    }

    func testConnectionTestRecognizesAuthorizationReadyToSave() {
        var draft = GeminiCredentialDraft(isConnected: false)
        draft.stageAuthorization(
            GeminiAuthorizationTokens(
                accessToken: "access-secret",
                refreshToken: "refresh-secret",
                expiry: Date(timeIntervalSince1970: 2_000_000_000)
            )
        )

        XCTAssertEqual(
            draft.connectionTestDisposition,
            .authorizationReadyToSave
        )
    }

    func testConnectionTestRejectsStagedDisconnect() {
        var draft = GeminiCredentialDraft(isConnected: true)
        draft.stageDisconnect()

        XCTAssertEqual(
            draft.connectionTestDisposition,
            .stagedForRemoval
        )
    }
}
#endif

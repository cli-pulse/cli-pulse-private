import XCTest
@testable import CLIPulseCore

final class WatchSessionBoundaryTests: XCTestCase {
    func testDemoTransitionPreservesPersistedRealCredentials() {
        XCTAssertFalse(
            WatchAuthTransitionKind.demoMode
                .clearsPersistedCredentials
        )
        XCTAssertTrue(
            WatchAuthTransitionKind.authentication
                .clearsPersistedCredentials
        )
    }

    func testSessionRestorePreservesCredentialsUntilValidation() {
        XCTAssertFalse(
            WatchAuthTransitionKind.sessionRestore
                .clearsPersistedCredentials,
            "offline restore must leave the durable session retryable"
        )
    }

    func testRestoreFailureClearsCredentialsOnlyForExplicitExpiry() {
        XCTAssertTrue(
            WatchSessionRestoreCredentialPolicy
                .shouldDeletePersistedCredentials(
                    after: .tokenExpired
                )
        )
        XCTAssertTrue(
            WatchSessionRestoreCredentialPolicy
                .shouldDeletePersistedCredentials(
                    after: .httpError(status: 401, body: "expired")
                )
        )
        XCTAssertFalse(
            WatchSessionRestoreCredentialPolicy
                .shouldDeletePersistedCredentials(
                    after: .httpError(status: 500, body: "temporary")
                )
        )
        XCTAssertFalse(
            WatchSessionRestoreCredentialPolicy
                .shouldDeletePersistedCredentials(
                    after: .invalidResponse
            )
        )
    }

    func testWatchAppStateWiresCredentialPolicyToRestoreOnly()
        throws
    {
        let source = try watchAppStateSource()
        let otpSection = try sourceSection(
            source,
            from: "func verifyOTP(code: String) async",
            to: "func resetOTP()"
        )
        let restoreSection = try sourceSection(
            source,
            from: "private func restoreSession() async",
            to: "// MARK: - WCSession Fallback"
        )

        XCTAssertTrue(
            otpSection.contains("kind: .authentication"),
            "OTP verification must start a new authentication transition"
        )
        XCTAssertFalse(
            otpSection.contains(
                "WatchSessionRestoreCredentialPolicy"
            ),
            "restore-only deletion policy must not run for OTP"
        )
        XCTAssertTrue(
            restoreSection.contains("kind: .sessionRestore"),
            "restore must preserve Keychain until validation completes"
        )
        XCTAssertTrue(
            restoreSection.contains(
                "WatchSessionRestoreCredentialPolicy"
            ),
            "restore failures must classify explicit auth rejection"
        )

        let currentLeaseGuard = try XCTUnwrap(
            restoreSection.range(
                of: "guard authTransitionGate.canCommit(lease)"
            )
        )
        let deletionPolicy = try XCTUnwrap(
            restoreSection.range(
                of: "WatchSessionRestoreCredentialPolicy"
            )
        )
        XCTAssertLessThan(
            currentLeaseGuard.lowerBound,
            deletionPolicy.lowerBound,
            "a stale restore must not delete a newer session's credentials"
        )
    }

    func testLogoutInvalidatesPendingOTPTransition() {
        var gate = WatchAuthTransitionGate()
        let pendingOTP = gate.beginTransition()

        let logout = gate.beginTransition()

        XCTAssertFalse(gate.canCommit(pendingOTP))
        XCTAssertTrue(gate.canCommit(logout))
    }

    func testNewPhoneAuthInvalidatesPendingRestoreTransition() {
        var gate = WatchAuthTransitionGate()
        let pendingRestore = gate.beginTransition()

        let phoneAuth = gate.beginTransition()

        XCTAssertFalse(gate.canCommit(pendingRestore))
        XCTAssertTrue(gate.canCommit(phoneAuth))
        XCTAssertGreaterThan(
            phoneAuth.generation,
            pendingRestore.generation
        )
    }

    func testSessionOrderingRejectsDelayedOlderEvents() throws {
        var ordering = WatchSessionOrderingGate()
        let accountB = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "USER-B",
                epoch: 30
            )
        )
        let delayedAccountA = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "user-a",
                epoch: 20
            )
        )
        let forgedEqualEpochAccountA = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "user-a",
                epoch: 30
            )
        )

        XCTAssertTrue(ordering.accept(accountB))
        XCTAssertFalse(ordering.accept(delayedAccountA))
        XCTAssertFalse(
            ordering.accept(forgedEqualEpochAccountA),
            "one epoch may not be shared by different account owners"
        )
        XCTAssertTrue(
            ordering.accept(accountB),
            "auth and context for the same epoch must both be accepted"
        )
        XCTAssertEqual(ordering.highestAcceptedEpoch, 30)
    }

    func testFallbackRequiresAuthenticatedOwnerAndRemoteEpoch() throws {
        let accountB = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "User-B",
                epoch: 42
            )
        )

        XCTAssertTrue(
            accountB.matches(
                authenticatedUserID: "user-b",
                remoteEpoch: 42
            )
        )
        XCTAssertFalse(
            accountB.matches(
                authenticatedUserID: "user-a",
                remoteEpoch: 42
            )
        )
        XCTAssertFalse(
            accountB.matches(
                authenticatedUserID: "user-b",
                remoteEpoch: 41
            )
        )
        XCTAssertTrue(
            accountB.matches(
                authenticatedUserID: "user-b",
                remoteEpoch: nil
            ),
            "a locally authenticated watch may accept the latest same-owner context"
        )
    }

    func testRemoteLogoutInvalidatesPendingAuthentication() throws {
        let logout = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "user-a",
                epoch: 50
            )
        )

        XCTAssertTrue(
            WatchRemoteLogoutPolicy
                .shouldInvalidateAuthentication(
                    isAuthenticated: false,
                    currentUserID: "",
                    currentRemoteEpoch: nil,
                    logoutIdentity: logout
                ),
            "logout must cancel OTP/restore even while the UI is temporarily signed out"
        )
    }

    func testRemoteLogoutCannotClearDifferentAuthenticatedOwner() throws {
        let accountALogout = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "user-a",
                epoch: 60
            )
        )
        let staleAccountBLogout = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "user-b",
                epoch: 39
            )
        )
        let currentAccountBLogout = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "user-b",
                epoch: 41
            )
        )

        XCTAssertFalse(
            WatchRemoteLogoutPolicy
                .shouldInvalidateAuthentication(
                    isAuthenticated: true,
                    currentUserID: "user-b",
                    currentRemoteEpoch: 40,
                    logoutIdentity: accountALogout
                )
        )
        XCTAssertFalse(
            WatchRemoteLogoutPolicy
                .shouldInvalidateAuthentication(
                    isAuthenticated: true,
                    currentUserID: "user-b",
                    currentRemoteEpoch: 40,
                    logoutIdentity: staleAccountBLogout
                )
        )
        XCTAssertTrue(
            WatchRemoteLogoutPolicy
                .shouldInvalidateAuthentication(
                    isAuthenticated: true,
                    currentUserID: "user-b",
                    currentRemoteEpoch: 40,
                    logoutIdentity: currentAccountBLogout
                )
        )
    }

    func testDuplicateRemoteLogoutIsAcceptedOnlyOnce() throws {
        var gate = WatchLogoutDeduplicationGate()
        let logout = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "user-a",
                epoch: 70
            )
        )

        XCTAssertTrue(gate.accept(logout))
        XCTAssertFalse(
            gate.accept(logout),
            "the transfer and application-context copies are one logout event"
        )
    }

    func testNewerRemoteLogoutIsAcceptedAfterPriorLogout() throws {
        let first = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "user-a",
                epoch: 70
            )
        )
        let newer = try XCTUnwrap(
            WatchSessionIdentity(
                userID: "user-a",
                epoch: 72
            )
        )
        var gate = WatchLogoutDeduplicationGate(
            lastAcceptedIdentity: first
        )

        XCTAssertTrue(gate.accept(newer))
        XCTAssertEqual(gate.lastAcceptedIdentity, newer)
    }

    private func watchAppStateSource() throws -> String {
        var packageRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            packageRoot.deleteLastPathComponent()
        }
        let sourceURL = packageRoot
            .appendingPathComponent("CLI Pulse Bar Watch")
            .appendingPathComponent("WatchAppState.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourceSection(
        _ source: String,
        from start: String,
        to end: String
    ) throws -> Substring {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(
                of: end,
                range: startRange.upperBound..<source.endIndex
            )
        )
        return source[
            startRange.lowerBound..<endRange.lowerBound
        ]
    }
}

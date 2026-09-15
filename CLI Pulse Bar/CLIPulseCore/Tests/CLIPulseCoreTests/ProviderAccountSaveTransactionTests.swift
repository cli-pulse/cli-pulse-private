import XCTest
@testable import CLIPulseCore

final class ProviderAccountSaveTransactionTests: XCTestCase {
    func testCredentialMutationRunsAfterAllFallibleConfigWrites() {
        var events: [String] = []

        let result = ProviderAccountSaveTransaction.commit(
            persistSecrets: {
                events.append("secrets")
                return true
            },
            rollbackSecrets: {
                events.append("rollback-secrets")
                return true
            },
            persistMetadata: {
                events.append("metadata")
                return true
            },
            rollbackMetadata: {
                events.append("rollback-metadata")
                return true
            },
            commitProviderCredential: {
                events.append("credential")
                return true
            },
            finalize: {
                events.append("finalize")
            }
        )

        XCTAssertEqual(result, .committed)
        XCTAssertEqual(events, ["secrets", "metadata", "credential", "finalize"])
    }

    func testMetadataFailurePreventsCredentialMutationAndFinalization() {
        var events: [String] = []

        let result = ProviderAccountSaveTransaction.commit(
            persistSecrets: {
                events.append("secrets")
                return true
            },
            rollbackSecrets: {
                events.append("rollback-secrets")
                return true
            },
            persistMetadata: {
                events.append("metadata")
                return false
            },
            rollbackMetadata: {
                events.append("rollback-metadata")
                return true
            },
            commitProviderCredential: {
                events.append("credential")
                return true
            },
            finalize: {
                events.append("finalize")
            }
        )

        XCTAssertEqual(result, .failedRolledBack)
        XCTAssertEqual(
            events,
            [
                "secrets",
                "metadata",
                "rollback-metadata",
                "rollback-secrets",
            ]
        )
    }

    func testCredentialFailureLeavesDraftUnfinalized() {
        var events: [String] = []

        let result = ProviderAccountSaveTransaction.commit(
            persistSecrets: {
                events.append("secrets")
                return true
            },
            rollbackSecrets: {
                events.append("rollback-secrets")
                return true
            },
            persistMetadata: {
                events.append("metadata")
                return true
            },
            rollbackMetadata: {
                events.append("rollback-metadata")
                return true
            },
            commitProviderCredential: {
                events.append("credential")
                return false
            },
            finalize: {
                events.append("finalize")
            }
        )

        XCTAssertEqual(result, .failedRolledBack)
        XCTAssertEqual(
            events,
            [
                "secrets",
                "metadata",
                "credential",
                "rollback-metadata",
                "rollback-secrets",
            ]
        )
    }

    func testSecretFailureRetriesSecretRollbackBeforeReturning() {
        var events: [String] = []

        let result = ProviderAccountSaveTransaction.commit(
            persistSecrets: {
                events.append("secrets")
                return false
            },
            rollbackSecrets: {
                events.append("rollback-secrets")
                return true
            },
            persistMetadata: {
                events.append("metadata")
                return true
            },
            rollbackMetadata: {
                events.append("rollback-metadata")
                return true
            },
            commitProviderCredential: {
                events.append("credential")
                return true
            },
            finalize: {
                events.append("finalize")
            }
        )

        XCTAssertEqual(result, .failedRolledBack)
        XCTAssertEqual(events, ["secrets", "rollback-secrets"])
    }

    func testRollbackFailureIsDistinguishableFromCleanCompensation() {
        var finalized = false

        let result = ProviderAccountSaveTransaction.commit(
            persistSecrets: { true },
            rollbackSecrets: { true },
            persistMetadata: { true },
            rollbackMetadata: { false },
            commitProviderCredential: { false },
            finalize: {
                finalized = true
            }
        )

        XCTAssertEqual(result, .failedRollbackIncomplete)
        XCTAssertFalse(finalized)
    }
}

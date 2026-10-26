import XCTest
@testable import CLIPulseCore

/// 1.59: every collector telemetry token is still told apart once the server
/// cuts it.
///
/// `helper_report_app_version` stores `left(v, 24)` of each token
/// (migrate_v0.71). Four existing tokens are longer and production already
/// holds them cut (`not_ready_missing_creden`, `not_ready_shared_credent`,
/// …). They keep their names: a rename would split their history. A new
/// token must fit, and no two tokens may be cut to the same value, or the
/// fleet's `devices.collector_status` could not tell them apart.
final class CollectorTelemetryTokenLengthTests: XCTestCase {

    /// Every outcome there is. A new `CollectorOutcome` case without
    /// associated values needs a line here; the two reason enums are listed
    /// through `allCases`, so a new reason or category is covered on its own.
    private var everyOutcome: [CollectorOutcome] {
        [.disabled, .unsupported, .producedData, .ranButEmpty]
            + CollectorNotReadyReason.allCases.map { .notReady($0) }
            + CollectorFailureCategory.allCases.map { .failed($0) }
    }

    func test_everyTokenIsUniqueAtTheLengthTheServerKeeps() {
        let tokens = everyOutcome.map(\.telemetryToken)
        XCTAssertEqual(Set(tokens).count, tokens.count, "two outcomes share a token: \(tokens)")

        let stored = tokens.map { String($0.prefix(CollectorOutcome.telemetryTokenStoredLength)) }
        var seen: [String: String] = [:]
        for (token, cut) in zip(tokens, stored) {
            if let other = seen[cut] {
                XCTFail("\(token) and \(other) are both stored as \(cut)")
            }
            seen[cut] = token
        }
    }

    func test_onlyTheFourTokensAlreadyStoredCutAreLonger() {
        let long = everyOutcome.map(\.telemetryToken)
            .filter { $0.count > CollectorOutcome.telemetryTokenStoredLength }
        XCTAssertEqual(
            Set(long),
            [
                "not_ready_missing_credentials",
                "not_ready_missing_api_key",
                "not_ready_shared_credential_taken",
                "not_ready_strict_keychain",
            ],
            "a new token longer than \(CollectorOutcome.telemetryTokenStoredLength) characters is stored cut"
        )
    }

    func test_theServersLengthIsTheMigrationsLength() throws {
        let migration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .deletingLastPathComponent()   // CLI Pulse Bar
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("backend/supabase/migrate_v0.71_device_collector_status.sql")
        let sql = try String(contentsOf: migration, encoding: .utf8)
        XCTAssertTrue(
            sql.contains("jsonb_object_agg(k, left(v, \(CollectorOutcome.telemetryTokenStoredLength)))"),
            "the server no longer keeps \(CollectorOutcome.telemetryTokenStoredLength) characters of a token"
        )
    }
}

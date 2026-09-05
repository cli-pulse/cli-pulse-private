import XCTest
@testable import CLIPulseCore

/// Plan §8's remote-control latches, and the degrade ladder that lets the
/// client ship before the owner applies `migrate_v0.80`.
///
/// The whole risk here is silence: a body carrying one parameter the
/// database does not know makes PostgREST 404 the entire call, so a client
/// that shipped ahead of the migration would report NOTHING — not just the
/// new fields — which is indistinguishable from "nobody uses the app".
final class RemoteControlTelemetryLatchTests: XCTestCase {

    private func payload(_ v: AnonymousInstallPayload.WireVersion) -> AnonymousInstallPayload {
        AnonymousInstallPayload(
            installID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            channel: .devid, appVersion: "1.53.0", osVersion: "26.5",
            providerDetected: true, helperConnected: true, costShown: true,
            uiLanguage: .en,
            remoteLANUsed: true, remoteTailnetUsed: true,
            remoteDelegateUsed: true, remoteNonClaudeUsed: true,
            wireVersion: v)
    }

    private func keys(_ p: AnonymousInstallPayload) throws -> Set<String> {
        let data = try JSONEncoder().encode(p)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(obj.keys)
    }

    func testEachRungCarriesExactlyTheParametersItsDatabaseKnows() throws {
        let base: Set<String> = ["p_install_id", "p_channel", "p_app_version",
                                 "p_os_version", "p_provider_detected"]
        let v076: Set<String> = base.union(["p_helper_connected", "p_cost_shown", "p_ui_language"])
        let current: Set<String> = v076.union(["p_remote_lan", "p_remote_tailnet",
                                               "p_remote_delegate", "p_remote_nonclaude"])
        XCTAssertEqual(try keys(payload(.legacy)), base)
        XCTAssertEqual(try keys(payload(.v076)), v076)
        XCTAssertEqual(try keys(payload(.current)), current)
    }

    func testTheShapedCopiesDropTheRightKeysAndKeepTheFacts() throws {
        let p = payload(.current)
        let mid = p.v076Shaped()
        XCTAssertEqual(mid.wireVersion, .v076)
        XCTAssertFalse(try keys(mid).contains("p_remote_lan"))
        XCTAssertTrue(try keys(mid).contains("p_ui_language"), "the v0.76 rung must still carry v0.76's fields")
        // The facts it can still carry are unchanged.
        XCTAssertEqual(mid.helperConnected, p.helperConnected)
        XCTAssertEqual(mid.installID, p.installID)

        let old = p.legacyShaped()
        XCTAssertEqual(old.wireVersion, .legacy)
        for k in ["p_remote_lan", "p_helper_connected", "p_ui_language"] {
            XCTAssertFalse(try keys(old).contains(k), k)
        }
    }

    func testTheLatchesAreOffByDefaultSoAnUnrelatedSendCannotSetThem() throws {
        // A caller that does not know about remote control must not latch it.
        let p = AnonymousInstallPayload(
            installID: UUID(), channel: .devid, appVersion: "1.53.0",
            osVersion: "26.5", providerDetected: true)
        XCTAssertFalse(p.remoteLANUsed)
        XCTAssertFalse(p.remoteTailnetUsed)
        XCTAssertFalse(p.remoteDelegateUsed)
        XCTAssertFalse(p.remoteNonClaudeUsed)
        let data = try JSONEncoder().encode(p)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for k in ["p_remote_lan", "p_remote_tailnet", "p_remote_delegate", "p_remote_nonclaude"] {
            XCTAssertEqual(obj[k] as? Bool, false, k)
        }
    }

    /// Drift gate. The client's parameter names are a contract with
    /// `migrate_v0.80`; a rename on either side makes every call 404, which
    /// is silent. The existing suite pins v0.73's CHECK patterns the same way.
    func testParameterNamesMatchTheMigrationFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()   // repo root
        let sql = try String(
            contentsOf: root.appendingPathComponent("backend/supabase/migrate_v0.80_remote_control_usage_latches.sql"),
            encoding: .utf8)
        for name in ["p_remote_lan", "p_remote_tailnet", "p_remote_delegate", "p_remote_nonclaude"] {
            XCTAssertTrue(sql.contains(name), "\(name) is not in migrate_v0.80 — the client would 404")
        }
        for col in ["remote_lan_used_at", "remote_tailnet_used_at",
                    "remote_delegate_used_at", "remote_nonclaude_used_at"] {
            XCTAssertTrue(sql.contains(col), col)
        }
        // The migration must stay a latch: coalesce(EXISTING, new), never the
        // other way round, or a later launch would move the first-seen time.
        // Whitespace-insensitive: the surrounding file wraps its coalesce
        // arguments onto the next line, and the ORDER is what matters.
        let flat = sql.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        for col in ["remote_lan_used_at", "remote_tailnet_used_at",
                    "remote_delegate_used_at", "remote_nonclaude_used_at"] {
            XCTAssertTrue(flat.contains("coalesce( ai.\(col), excluded.\(col) )")
                          || flat.contains("coalesce(ai.\(col), excluded.\(col))"),
                          "\(col) is not latched as coalesce(existing, new)")
        }
        // And it must not have been applied by an agent: the file says so.
        XCTAssertTrue(sql.contains("OWNER GATE"), "the owner-gate notice was removed from the migration")
    }

    // MARK: - the wiring, which is what actually failed

    /// THE test that was missing. The first cut of this feature added the
    /// four payload fields, the migration and the disclosure — and nothing
    /// ever set them, so every install would have reported `false` forever
    /// against a schema that could never receive a `true`. Encoding tests
    /// passed the whole time. This asserts the emitters exist and that the
    /// source actually calls them.
    private func coreSource(_ name: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CLIPulseCore")
        return try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheAgentActuallyEmitsEachLatch() throws {
        let agent = try coreSource("LANLinkAgent.swift")
        XCTAssertTrue(agent.contains("remoteTransportUsed("),
                      "nothing reports which address class a phone arrived on")
        XCTAssertTrue(agent.contains("LANDirectAddress.classify("),
                      "the transport class must be DERIVED, not taken from the wire")

        let session = try coreSource("LANLinkAgentSession.swift")
        XCTAssertTrue(session.contains("remoteDelegateRequested()"),
                      "nothing reports that a session asked for the Claude hand-off")
        XCTAssertTrue(session.contains("remoteNonClaudeDriven()"),
                      "nothing reports that a non-Claude session was driven")
    }

    func testTheSinkHasAnEmitterForEveryLatch() throws {
        let sink = try coreSource("AnonymousInstallTelemetry.swift")
        for fn in ["recordRemoteTransportIfNeeded", "recordRemoteDelegateIfNeeded",
                   "recordRemoteNonClaudeIfNeeded"] {
            XCTAssertTrue(sink.contains("public func \(fn)"), "\(fn) is missing")
        }
        // Each must latch ONLY on `.current`: a `.v076` or `.legacy` send
        // omits these parameters, so latching on any other outcome would
        // mark a milestone the server never received — for the life of the
        // install, because the latch is persisted.
        let emitters = sink.components(separatedBy: "recordRemote").dropFirst()
        XCTAssertEqual(emitters.count, 3, "unexpected number of remote emitters")
        for body in emitters {
            let scope = String(body.prefix(1200))
            XCTAssertTrue(scope.contains("accepted == .current"),
                          "a remote emitter latches without checking the shape that landed")
        }
    }

    func testTheStoreKeysAreNamespacedSoAnUpgradeCannotDropThem() throws {
        // Every telemetry key must start with `privacy.` or `cli_pulse_`:
        // `UnsandboxedDataMigration.appOwnedKeyPrefixes` is a strict
        // allowlist and anything outside it is dropped when a user moves
        // from the App Store build to the Developer ID one.
        for key in [UserDefaultsAnonymousTelemetryStore.remoteLANReportedKey,
                    UserDefaultsAnonymousTelemetryStore.remoteTailnetReportedKey,
                    UserDefaultsAnonymousTelemetryStore.remoteDelegateReportedKey,
                    UserDefaultsAnonymousTelemetryStore.remoteNonClaudeReportedKey] {
            XCTAssertTrue(key.hasPrefix("cli_pulse_") || key.hasPrefix("privacy."), key)
        }
    }
}

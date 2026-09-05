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
        // The migration must stay a latch: coalesce(existing, new), never the
        // other way round, or a later launch would move the first-seen time.
        XCTAssertTrue(sql.contains("coalesce(ai.remote_lan_used_at,"),
                      "the LAN column is not latched with coalesce(existing, new)")
        // And it must not have been applied by an agent: the file says so.
        XCTAssertTrue(sql.contains("OWNER GATE"), "the owner-gate notice was removed from the migration")
    }
}

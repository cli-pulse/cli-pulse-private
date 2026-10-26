#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// 1.59: which response keys feed the Claude quota lanes, and which helper
/// snapshot lanes the app still trusts.
///
/// Up to 1.58 `iguana_necktie` was shown as "Designs" and
/// `seven_day_omelette` as "Daily Routines". Upstream (CodexBar) retired the
/// Design lane in May, reads Daily Routines from seven other keys, and since
/// October reads `iguana_necktie` as cloud credits in dollars. The fixtures
/// below use upstream's key names and shapes; values are invented.
final class ClaudeLaneKeysTests: XCTestCase {

    // MARK: - Fixtures

    /// The October `iguana_necktie` shape: cloud credits, no `utilization`.
    private static let cloudCreditsObject = """
    { "limit_dollars": 50.0, "used_dollars": 12.5, "remaining_dollars": 37.5,
      "resets_at": "2026-11-30T00:00:00Z", "locked_reason": null }
    """

    private func json(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func oauthTierNames(_ body: String) throws -> [String] {
        let usage = try ClaudeOAuthStrategy.parseUsage(XCTUnwrap(body.data(using: .utf8)))
        let snapshot = ClaudeSnapshot(
            sessionUsed: usage.fiveHour?.utilization,
            weeklyUsed: usage.sevenDay?.utilization,
            dailyRoutinesUsed: usage.routines?.utilization,
            dailyRoutinesReset: usage.routines?.resetsAt,
            sourceLabel: "oauth"
        )
        return ClaudeResultBuilder.build(from: snapshot).usage.tiers.map(\.name)
    }

    // MARK: - Response keys

    func testCloudCreditsObjectIsNoDesignsRow() throws {
        let body = """
        { "five_hour": { "utilization": 10.0, "resets_at": null },
          "seven_day": { "utilization": 20.0, "resets_at": null },
          "iguana_necktie": \(Self.cloudCreditsObject) }
        """
        XCTAssertEqual(try oauthTierNames(body), ["5h Window", "Weekly"],
                       "a cloud-credits object must not become a Designs row")
        let web = ClaudeWebStrategy.parseUsage(try json(body))
        XCTAssertNil(web.dailyRoutinesPercent)
        XCTAssertEqual(web.sessionPercent, 10)
    }

    func testSevenDayRoutinesIsDailyRoutines() throws {
        let body = """
        { "five_hour": { "utilization": 10.0, "resets_at": null },
          "seven_day_routines": { "utilization": 30.0, "resets_at": "2026-11-01T00:00:00Z" } }
        """
        XCTAssertEqual(try oauthTierNames(body), ["5h Window", "Daily Routines"])
        let usage = try ClaudeOAuthStrategy.parseUsage(XCTUnwrap(body.data(using: .utf8)))
        XCTAssertEqual(usage.routines, ClaudeRoutinesWindow.Window(
            utilization: 30, resetsAt: "2026-11-01T00:00:00Z", sourceKey: "seven_day_routines"))
        let web = ClaudeWebStrategy.parseUsage(try json(body))
        XCTAssertEqual(web.dailyRoutinesPercent, 30)
        XCTAssertEqual(web.dailyRoutinesResetISO, "2026-11-01T00:00:00Z")
    }

    /// The retired Design window must not come back under the Routines name.
    func testOnlySevenDayOmeletteIsNoDailyRoutines() throws {
        let body = """
        { "five_hour": { "utilization": 10.0, "resets_at": null },
          "seven_day_omelette": { "utilization": 5.0, "resets_at": null } }
        """
        XCTAssertEqual(try oauthTierNames(body), ["5h Window"])
        XCTAssertNil(ClaudeWebStrategy.parseUsage(try json(body)).dailyRoutinesPercent)
    }

    func testEachUpstreamRoutinesKeyIsRead() throws {
        XCTAssertEqual(ClaudeRoutinesWindow.keys, [
            "seven_day_routines", "seven_day_claude_routines", "claude_routines",
            "routines", "routine", "seven_day_cowork", "cowork",
        ])
        for (index, key) in ClaudeRoutinesWindow.keys.enumerated() {
            let window = ClaudeRoutinesWindow.parse(try json(
                #"{ "\#(key)": { "utilization": \#(index + 1), "resets_at": null } }"#))
            XCTAssertEqual(window?.utilization, index + 1, key)
            XCTAssertEqual(window?.sourceKey, key)
        }
    }

    func testFirstKeyHoldingAnObjectWins() throws {
        let both = ClaudeRoutinesWindow.parse(try json("""
        { "cowork": { "utilization": 9 }, "seven_day_routines": { "utilization": 4 } }
        """))
        XCTAssertEqual(both?.sourceKey, "seven_day_routines")
        XCTAssertEqual(both?.utilization, 4)

        // A null first key is not an object: the search moves on, as upstream's.
        let nullFirst = ClaudeRoutinesWindow.parse(try json("""
        { "seven_day_routines": null, "cowork": { "utilization": 9 } }
        """))
        XCTAssertEqual(nullFirst?.sourceKey, "cowork")
    }

    /// 1.58 showed a null window as "100% left". Upstream shows no row.
    func testNullRoutinesIsNoRow() throws {
        for body in [
            #"{ "seven_day_routines": null }"#,
            #"{ "seven_day_routines": { "utilization": null, "resets_at": null } }"#,
            #"{ "seven_day_routines": { "resets_at": "2026-11-01T00:00:00Z" } }"#,
            #"{ "seven_day_routines": { "utilization": true } }"#,
            #"{ "seven_day_routines": { "utilization": "12" } }"#,
        ] {
            XCTAssertNil(ClaudeRoutinesWindow.parse(try json(body)), body)
            XCTAssertNil(ClaudeWebStrategy.parseUsage(try json(body)).dailyRoutinesPercent, body)
            XCTAssertNil(try ClaudeOAuthStrategy.parseUsage(XCTUnwrap(body.data(using: .utf8))).routines, body)
        }
    }

    // MARK: - Web strategy recognition

    /// A web `/usage` with nothing but cloud credits is not a quota reading:
    /// `fetch` throws `parseFailed`, which falls through to the next strategy.
    func testWebOnlyCloudCreditsFallsThrough() throws {
        let onlyCredits = ClaudeWebStrategy.parseUsage(try json(
            #"{ "iguana_necktie": \#(Self.cloudCreditsObject) }"#))
        XCTAssertFalse(onlyCredits.hasRecognizedQuota)
        XCTAssertTrue(ClaudeStrategyError.parseFailed("x").shouldFallback)

        let onlyOmelette = ClaudeWebStrategy.parseUsage(try json(
            #"{ "seven_day_omelette": { "utilization": 5.0 } }"#))
        XCTAssertFalse(onlyOmelette.hasRecognizedQuota)

        let onlyRoutines = ClaudeWebStrategy.parseUsage(try json(
            #"{ "seven_day_routines": { "utilization": 5.0 } }"#))
        XCTAssertTrue(onlyRoutines.hasRecognizedQuota, "a routines-only account is a success")
    }

    // MARK: - Helper snapshot contract

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeLaneKeysTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Writes `dict` as a snapshot file with a fresh `fetched_at` and reads
    /// it back the way the resolver's cache does.
    private func readBack(_ dict: [String: Any]) throws -> ClaudeSnapshot? {
        var dict = dict
        dict["fetched_at"] = sharedISO8601Formatter.string(from: Date())
        let path = tempDir.appendingPathComponent("claude_snapshot.json")
        try JSONSerialization.data(withJSONObject: dict).write(to: path)
        return ClaudeHelperContract.readSnapshot(
            maxAge: ClaudeHelperContract.cacheSnapshotAge,
            sourceLabel: "cache",
            candidatePaths: [path.path]
        )
    }

    private let bothOldLanes: [[String: Any]] = [
        ["name": "Designs", "used": 0, "reset": "2026-11-30T00:00:00Z"],
        ["name": "Daily Routines", "used": 5, "reset": NSNull()],
    ]

    /// What 1.58 and Companion 1.33 write: both wrong lanes, no marker. The
    /// resolver serves this cache for 24 hours, so it must bring neither back.
    func testUnmarkedSnapshotFromBefore159CarriesNeitherLane() throws {
        let read = try XCTUnwrap(try readBack([
            "session_used": 10, "weekly_used": 20, "source": "oauth",
            "extra_tiers": bothOldLanes,
        ]))
        XCTAssertEqual(read.sessionUsed, 10, "the rest of the snapshot still reads")
        XCTAssertNil(read.dailyRoutinesUsed)
        XCTAssertEqual(ClaudeResultBuilder.build(from: read).usage.tiers.map(\.name),
                       ["5h Window", "Weekly"])
    }

    func testMarkedSnapshotCarriesDailyRoutinesButNeverDesigns() throws {
        let read = try XCTUnwrap(try readBack([
            "session_used": 10, "source": "oauth",
            "extra_tiers": bothOldLanes,
            "extra_tiers_schema": 2,
        ]))
        XCTAssertEqual(read.dailyRoutinesUsed, 5)
        XCTAssertNil(read.dailyRoutinesReset)
        XCTAssertEqual(ClaudeResultBuilder.build(from: read).usage.tiers.map(\.name),
                       ["5h Window", "Daily Routines"])
    }

    func testOnlyTheExactMarkerIsTrusted() throws {
        for marker: Any in ["2", 1, 3, true, NSNull()] {
            let read = try XCTUnwrap(try readBack([
                "session_used": 10, "extra_tiers": bothOldLanes, "extra_tiers_schema": marker,
            ]))
            XCTAssertNil(read.dailyRoutinesUsed, "marker \(marker)")
        }
    }

    /// The encoder writes the marker on every file, and what it writes reads back.
    func testWriterMarksEveryFileAndRoundTrips() throws {
        let plain = ClaudeHelperContract.snapshotDictionary(
            ClaudeSnapshot(sessionUsed: 10, sourceLabel: "oauth"), fetchedAt: Date())
        XCTAssertEqual(plain["extra_tiers_schema"] as? Int, 2)
        XCTAssertNil(plain["extra_tiers"])

        let withRoutines = ClaudeHelperContract.snapshotDictionary(
            ClaudeSnapshot(sessionUsed: 10, dailyRoutinesUsed: 7,
                           dailyRoutinesReset: "2026-11-01T00:00:00Z", sourceLabel: "oauth"),
            fetchedAt: Date())
        XCTAssertEqual(withRoutines["extra_tiers_schema"] as? Int, 2)
        let tiers = try XCTUnwrap(withRoutines["extra_tiers"] as? [[String: Any]])
        XCTAssertEqual(tiers.compactMap { $0["name"] as? String }, ["Daily Routines"])

        let read = try XCTUnwrap(try readBack(withRoutines))
        XCTAssertEqual(read.dailyRoutinesUsed, 7)
        XCTAssertEqual(read.dailyRoutinesReset, "2026-11-01T00:00:00Z")
    }
}
#endif

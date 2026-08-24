import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.50 — the audit that followed the Codex credential-rotation bug.
///
/// That bug was one instance of a pattern: `sharedISO8601Formatter` is the
/// STRICT formatter, it returns nil for the fractional-second timestamps this
/// project's own helpers write, and **the nil branch is usually the dangerous
/// one**. Twelve other call sites parsed input with it. This file pins the two
/// that were live defects.
///
/// The shape to watch for is not "the parse failed". It is "the parse failed and
/// the code carried on as if the answer had been reassuring".
final class SnapshotFreshnessTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - The formats actually in play

    /// Both are real strings taken off this project's own artifacts:
    /// the first from `~/Library/Group Containers/group.yyh.CLI-Pulse/claude_snapshot.json`
    /// (written by the app-group helper), the second from `~/.clipulse/claude_snapshot.json`.
    /// One writer emits microseconds and an offset, the other emits neither —
    /// and the strict formatter reads exactly one of them.
    func testBothHelperTimestampSpellingsParse() {
        for stamp in [
            "2026-08-07T13:00:41.901114+00:00",   // app-group helper
            "2026-08-17T17:29:02Z",               // the other writer
            "2026-08-23T05:57:04.859771Z",        // Codex CLI
        ] {
            XCTAssertNotNil(
                sharedISO8601Parse(stamp),
                "\(stamp) is a timestamp this project actually writes"
            )
        }
        XCTAssertNil(
            ISO8601DateFormatter().date(from: "2026-08-07T13:00:41.901114+00:00"),
            "…and the strict formatter is still the thing that could not read the first one"
        )
    }

    // MARK: - readSnapshot: the age check that wasn't

    /// `readSnapshot`'s doc says it "Returns nil when the file is missing,
    /// malformed, or older than `maxAge`". It did not.
    ///
    /// `fetchedDate` came from the strict parser, the check was `if let date =
    /// fetchedDate, … > maxAge { continue }`, and an unparseable timestamp made
    /// the `if let` false — skipping the `continue` and returning the snapshot as
    /// fresh. On the machine this was found on, that meant a **17-day-old**
    /// snapshot served as live Claude quota data, because the app-group helper
    /// writes the one spelling the strict parser rejects.
    func testAnOldSnapshotInTheAppGroupSpellingIsRejected() throws {
        let path = try writeSnapshot(
            fetchedAt: "2026-08-07T13:00:41.901114+00:00",   // long past any TTL
            named: "old-fractional.json"
        )
        XCTAssertNil(
            ClaudeHelperContract.readSnapshot(
                maxAge: 300, sourceLabel: "test", candidatePaths: [path]
            ),
            "a snapshot older than maxAge must be rejected whichever spelling its timestamp uses"
        )
    }

    /// The other half — the fix must not reject everything. A fresh snapshot in
    /// the same spelling still comes back.
    func testAFreshSnapshotInTheAppGroupSpellingIsAccepted() throws {
        let path = try writeSnapshot(
            fetchedAt: sharedISO8601FractionalString(from: Date()),
            named: "fresh-fractional.json"
        )
        XCTAssertNotNil(
            ClaudeHelperContract.readSnapshot(
                maxAge: 300, sourceLabel: "test", candidatePaths: [path]
            ),
            "a fresh snapshot must still be usable — a fix that rejects everything is not a fix"
        )
    }

    /// An age we cannot determine is treated as stale, not as fresh. This is the
    /// direction the doc comment always claimed and the direction
    /// `ClaudeSourceResolver` already used — the two disagreed about the same
    /// field in the same file.
    func testAnUnreadableTimestampCountsAsStale() throws {
        let path = try writeSnapshot(fetchedAt: "not-a-timestamp", named: "garbage.json")
        XCTAssertNil(
            ClaudeHelperContract.readSnapshot(
                maxAge: 300, sourceLabel: "test", candidatePaths: [path]
            )
        )
    }

    /// A missing `fetched_at` is the same case: unknown age, treated as stale.
    func testAMissingTimestampCountsAsStale() throws {
        let path = dir.appendingPathComponent("no-stamp.json").path
        try JSONSerialization
            .data(withJSONObject: ["session_used": 10] as [String: Any])
            .write(to: URL(fileURLWithPath: path))
        XCTAssertNil(
            ClaudeHelperContract.readSnapshot(
                maxAge: 300, sourceLabel: "test", candidatePaths: [path]
            )
        )
    }

    // MARK: - Helpers

    private func writeSnapshot(fetchedAt: String, named: String) throws -> String {
        let path = dir.appendingPathComponent(named).path
        let body: [String: Any] = [
            "fetched_at": fetchedAt,
            "session_used": 42,
            "weekly_used": 7,
        ]
        try JSONSerialization
            .data(withJSONObject: body)
            .write(to: URL(fileURLWithPath: path))
        return path
    }
}

#endif

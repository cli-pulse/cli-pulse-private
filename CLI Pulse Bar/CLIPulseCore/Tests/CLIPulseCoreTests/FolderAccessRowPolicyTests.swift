import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.50 W0. Settings › CLI Tool Access told Mac App Store users that CLI tools
/// they had installed were "not installed", and gave them no button to say
/// otherwise.
///
/// The mechanism is worth stating once, because it is the kind of bug that gets
/// re-introduced by someone simplifying the condition back:
/// `KnownDirectory.isInstalled` is `FileManager.fileExists`, and under the
/// sandbox that returns false for a directory that exists but has no bookmark.
/// `alwaysShow` was added precisely so those rows would still be listed — and
/// then the row body rendered `alwaysShow && !isInstalled` as "Not installed"
/// with no Grant button, restoring the same dead end and printing a falsehood
/// on the way.
///
/// The distinction the code was missing is not *does it exist* but **can we
/// tell**.
final class FolderAccessRowPolicyTests: XCTestCase {

    // MARK: - The defect

    /// Sandboxed, no bookmark, `fileExists` says no. The correct reading is
    /// "I cannot see it", and the correct offer is Grant.
    func testSandboxedWithoutABookmarkIsGrantableNotMissing() {
        XCTAssertEqual(
            FolderAccessRowPolicy.state(
                hasAccess: false,
                existsOnDisk: false,
                isSandboxed: true
            ),
            .grantable,
            "under the sandbox, not seeing a directory is not evidence it is absent"
        )
    }

    /// The same inputs on a Developer ID build. Here `fileExists` is authoritative,
    /// so "not installed" is a true statement and the label is right.
    func testUnsandboxedAbsenceIsRealAbsence() {
        XCTAssertEqual(
            FolderAccessRowPolicy.state(
                hasAccess: false,
                existsOnDisk: false,
                isSandboxed: false
            ),
            .notInstalled
        )
    }

    func testHoldingABookmarkAlwaysReadsAsGranted() {
        for sandboxed in [true, false] {
            for exists in [true, false] {
                XCTAssertEqual(
                    FolderAccessRowPolicy.state(
                        hasAccess: true,
                        existsOnDisk: exists,
                        isSandboxed: sandboxed
                    ),
                    .granted,
                    "sandboxed=\(sandboxed) exists=\(exists)"
                )
            }
        }
    }

    func testVisibleAndUngrantedDirectoryOffersGrant() {
        for sandboxed in [true, false] {
            XCTAssertEqual(
                FolderAccessRowPolicy.state(
                    hasAccess: false,
                    existsOnDisk: true,
                    isSandboxed: sandboxed
                ),
                .grantable,
                "sandboxed=\(sandboxed)"
            )
        }
    }

    // MARK: - Visibility

    /// The list stays useful: a CLI the user demonstrably does not have is not
    /// worth a row unless the entry is `alwaysShow`, whose whole purpose is to
    /// keep a grant path reachable.
    func testOnlyProvenAbsenceCanHideARow() {
        XCTAssertFalse(
            FolderAccessRowPolicy.isVisible(state: .notInstalled, alwaysShow: false)
        )
        XCTAssertTrue(
            FolderAccessRowPolicy.isVisible(state: .notInstalled, alwaysShow: true)
        )
        for state in [FolderAccessRowState.granted, .grantable] {
            for alwaysShow in [true, false] {
                XCTAssertTrue(
                    FolderAccessRowPolicy.isVisible(state: state, alwaysShow: alwaysShow),
                    "\(state) alwaysShow=\(alwaysShow) is actionable and must be listed"
                )
            }
        }
    }

    /// The widened half of the fix. `~/.codex/` is not `alwaysShow` — it was
    /// never flagged, because on a Developer ID build `fileExists` finds it. On a
    /// sandboxed build it did not, so the row vanished from the list entirely
    /// and the one control that could have fixed that went with it.
    func testASandboxedInstallListsEveryDirectoryItCannotSee() {
        let codex = BookmarkManager.knownDirectories.first { $0.id == "codex" }
        XCTAssertNotNil(codex)
        XCTAssertEqual(
            codex?.alwaysShow, false,
            "if this entry ever gains alwaysShow, this test stops covering the widened case"
        )

        let state = FolderAccessRowPolicy.state(
            hasAccess: false,
            existsOnDisk: false,
            isSandboxed: true
        )
        XCTAssertTrue(
            FolderAccessRowPolicy.isVisible(
                state: state,
                alwaysShow: codex?.alwaysShow ?? false
            ),
            "a sandboxed install must still be able to reach the Grant button for ~/.codex/"
        )
    }

    /// Every combination, so the table is legible in one place and a future
    /// simplification has to disagree with it explicitly.
    func testFullTruthTable() {
        let expected: [(hasAccess: Bool, exists: Bool, sandboxed: Bool, state: FolderAccessRowState)] = [
            (true,  true,  true,  .granted),
            (true,  true,  false, .granted),
            (true,  false, true,  .granted),
            (true,  false, false, .granted),
            (false, true,  true,  .grantable),
            (false, true,  false, .grantable),
            (false, false, true,  .grantable),      // cannot tell → offer Grant
            (false, false, false, .notInstalled),   // can tell, and it is absent
        ]
        for row in expected {
            XCTAssertEqual(
                FolderAccessRowPolicy.state(
                    hasAccess: row.hasAccess,
                    existsOnDisk: row.exists,
                    isSandboxed: row.sandboxed
                ),
                row.state,
                "hasAccess=\(row.hasAccess) exists=\(row.exists) sandboxed=\(row.sandboxed)"
            )
        }
    }
}

#endif

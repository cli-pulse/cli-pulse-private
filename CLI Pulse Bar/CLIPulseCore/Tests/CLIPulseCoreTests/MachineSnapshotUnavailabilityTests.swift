#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.44 — pin why the Machine tab is empty.
///
/// Found in the field: Settings showed "Managed CLI Helper — Built-in · v1.30.0 ✓"
/// while the Machine tab, in the same window, said "Helper not reachable —
/// machine health needs the CLI Pulse helper running". Both cannot be true.
///
/// Probing the live socket settled it: the helper answered `hello` instantly
/// (v1.30.0, `swift-bundled`) and answered `get_machine_snapshot` with
/// `unknown_method`. `get_machine_snapshot` lives only in the `.pkg` Python
/// helper; the bundled Swift helper's method surface is session control.
/// So the helper was reachable, healthy, and simply lacked the feature — and
/// the pane offering advice was the one that was wrong.
final class MachineSnapshotUnavailabilityTests: XCTestCase {

    /// The case that actually happens. `unknown_method` maps to
    /// `.notImplemented` (SessionControlErrorMapping), and it must NOT read as
    /// an outage.
    func testHelperAnsweringUnknownMethodIsNotCalledUnreachable() {
        XCTAssertEqual(
            MachineSnapshotUnavailability(SessionControlError.notImplemented),
            .unsupportedByHelper,
            "the helper answered — it just doesn't carry this method"
        )
    }

    /// A helper too old to know the method is the same user-facing situation:
    /// install the one that has it.
    func testVersionMismatchIsAlsoACapabilityGap() {
        XCTAssertEqual(
            MachineSnapshotUnavailability(SessionControlError.versionMismatch),
            .unsupportedByHelper
        )
    }

    /// Genuine absence must still say so, or the fix above would simply hide
    /// every outage behind "install the helper".
    func testNothingAnsweringIsStillUnreachable() {
        XCTAssertEqual(
            MachineSnapshotUnavailability(SessionControlError.helperNotRunning), .unreachable
        )
        XCTAssertEqual(
            MachineSnapshotUnavailability(SessionControlError.disconnected), .unreachable
        )
        struct Mystery: Error {}
        XCTAssertEqual(
            MachineSnapshotUnavailability(Mystery()), .unreachable,
            "an unrecognised error must not be dressed up as a capability gap"
        )
    }

    func testRejectedCredentialsAreTheirOwnCase() {
        XCTAssertEqual(
            MachineSnapshotUnavailability(SessionControlError.unauthenticated), .unauthenticated
        )
    }

    /// The three states must not share a message — that would undo the split.
    func testEachStateSaysSomethingDifferent() {
        let messages = Set([
            MachineSnapshotUnavailability.unsupportedByHelper.message,
            MachineSnapshotUnavailability.unreachable.message,
            MachineSnapshotUnavailability.unauthenticated.message,
        ])
        XCTAssertEqual(messages.count, 3, "collapsing two of these back together is the bug")
        for m in messages {
            XCTAssertFalse(m.isEmpty)
            XCTAssertFalse(m.hasPrefix("machine."), "unresolved L10n key leaked: \(m)")
        }
    }

    /// The capability gap must not claim the helper isn't running, and must name
    /// the actionable step. This is the assertion that would have caught the
    /// original bug.
    func testCapabilityGapDoesNotClaimTheHelperIsDown() {
        let m = MachineSnapshotUnavailability.unsupportedByHelper.message.lowercased()
        XCTAssertFalse(
            m.contains("not reachable") || m.contains("needs the cli pulse helper running"),
            "the helper IS running and reachable. Got: \(m)"
        )
        // And it must NOT tell them to install anything. When the bundled
        // helper answers `.notImplemented`, `HelperInstaller` resolves to
        // `.bundled` and `CompanionCLISection` deliberately renders NO install
        // action — it says "No separate install needed". Two earlier drafts of
        // this sentence sent the user to a button that is not on screen; the
        // second one even named a Settings section that does not exist. There is
        // no in-app remedy for this state, so the message states the gap and
        // stops.
        XCTAssertFalse(
            m.contains("install"),
            "there is no install action in the .bundled state. Got: \(m)"
        )
        XCTAssertTrue(
            m.contains("built-in") || m.contains("sensor"),
            "must say which helper and why. Got: \(m)"
        )
    }

    /// The route named in the advice must be a section that EXISTS. The first
    /// draft said "Settings › Pairing"; the picker only has General / Display /
    /// Providers / Advanced, and "Managed CLI Helper" lives under General. An
    /// instruction pointing at a tab the user cannot find is the same failure
    /// as the message it replaced.
    func testMessageDoesNotSendTheUserToASettingsSectionAtAll() {
        let m = MachineSnapshotUnavailability.unsupportedByHelper.message
        XCTAssertFalse(
            m.contains("Pairing") || m.contains("配对") || m.contains("配對")
                || m.contains("ペアリング") || m.contains("페어링") || m.contains("Emparejamiento"),
            "there is no Pairing section in the Settings picker. Got: \(m)"
        )
    }

    /// An outage and a missing capability should not look identical either —
    /// the old state rendered both with the same "power lost" bolt.
    func testIconsDistinguishTheStates() {
        XCTAssertNotEqual(
            MachineSnapshotUnavailability.unsupportedByHelper.iconName,
            MachineSnapshotUnavailability.unreachable.iconName
        )
    }
}
#endif

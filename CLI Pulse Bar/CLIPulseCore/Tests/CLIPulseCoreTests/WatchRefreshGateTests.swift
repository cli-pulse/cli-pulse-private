import XCTest
@testable import CLIPulseCore

final class WatchRefreshGateTests: XCTestCase {
    func testSignOutInvalidatesAnInFlightRefresh() throws {
        var gate = WatchRefreshGate()
        let lease = try XCTUnwrap(
            gate.beginRefresh(isAuthenticated: true)
        )

        gate.authDidChange()

        XCTAssertFalse(
            gate.canCommit(
                lease,
                isAuthenticated: false
            )
        )
    }

    func testAccountSwitchRejectsOldLeaseAndAcceptsNewLease() throws {
        var gate = WatchRefreshGate()
        let oldUserLease = try XCTUnwrap(
            gate.beginRefresh(isAuthenticated: true)
        )

        gate.authDidChange()
        let newUserLease = try XCTUnwrap(
            gate.beginRefresh(isAuthenticated: true)
        )

        XCTAssertFalse(
            gate.canCommit(
                oldUserLease,
                isAuthenticated: true
            )
        )
        XCTAssertTrue(
            gate.canCommit(
                newUserLease,
                isAuthenticated: true
            )
        )
    }

    func testNewerRefreshRejectsOlderResponseWithinSameSession()
        throws
    {
        var gate = WatchRefreshGate()
        let older = try XCTUnwrap(
            gate.beginRefresh(isAuthenticated: true)
        )
        let newer = try XCTUnwrap(
            gate.beginRefresh(isAuthenticated: true)
        )

        XCTAssertFalse(
            gate.canCommit(older, isAuthenticated: true)
        )
        XCTAssertTrue(
            gate.canCommit(newer, isAuthenticated: true)
        )
    }

    func testSignedOutStateCannotBeginRefresh() {
        var gate = WatchRefreshGate()

        XCTAssertNil(
            gate.beginRefresh(isAuthenticated: false)
        )
    }
}

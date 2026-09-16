import XCTest
@testable import CLIPulseCore

/// The Mac's Sessions banner used to show `SessionControlError.description` —
/// English debug text like "session not controllable from here" — in every
/// language. `LocalSessionFailureText` maps the case to words instead, while
/// `description` itself stays English for os_log, the LAN wire (compared by
/// prefix in `LANSessionControlClient`), and the tests that pin it.
final class LocalSessionFailureTextTests: XCTestCase {

    /// Every case. Kept complete by `assertListIsExhaustive` below, which
    /// switches over the enum with no `default`: add a case to
    /// `SessionControlError` and this file stops compiling until it is listed.
    static let allCases: [SessionControlError] = [
        .helperNotRunning, .runtimeRestricted, .unauthenticated, .versionMismatch,
        .notImplemented, .localControlOff, .timeout, .disconnected,
        .invalidResponse("bad json"), .internalError("boom"),
        .sessionNotFound, .notControllable,
        .approvalNotFound, .approvalExpired, .approvalAlreadyResolved,
        .approvalNotAllowed, .approvalCapabilityInvalid, .approvalLimitReached,
        .spawnFailed(detail: "claude: not on PATH"),
        .processNotFound, .processProtected, .processNotPermitted, .rateLimited,
        .attachFailed,
    ]

    private func assertListIsExhaustive(_ e: SessionControlError) {
        switch e {
        case .helperNotRunning, .runtimeRestricted, .unauthenticated, .versionMismatch,
             .notImplemented, .localControlOff, .timeout, .disconnected,
             .invalidResponse, .internalError, .sessionNotFound, .notControllable,
             .approvalNotFound, .approvalExpired, .approvalAlreadyResolved,
             .approvalNotAllowed, .approvalCapabilityInvalid, .approvalLimitReached,
             .spawnFailed, .processNotFound, .processProtected, .processNotPermitted,
             .rateLimited, .attachFailed:
            break
        }
    }

    private func withChinese(_ body: () -> Void) {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set("zh-Hans")
        defer { store.set(previous) }
        body()
    }

    func testTheCaseListReallyIsEveryCase() {
        XCTAssertEqual(Self.allCases.count, 24)
        Self.allCases.forEach(assertListIsExhaustive)
    }

    /// The banner must never show debug text. Asserted under zh-Hans: in
    /// English a mapped message and its English source can coincide, so an
    /// English-only check could pass with the mapper reduced to `description`.
    func testNoCaseShowsItsDebugDescription() {
        withChinese {
            for error in Self.allCases {
                let shown = LocalSessionFailureText.message(for: error)
                XCTAssertFalse(shown.isEmpty, "\(error) maps to an empty message")
                XCTAssertNotEqual(shown, error.description,
                                  "\(error) still shows its English debug description")
                XCTAssertFalse(shown.contains("%"), "\(error) leaked a format specifier: \(shown)")
            }
        }
    }

    /// Protocol detail carried by a case is not user copy. It is already in
    /// os_log at every call site.
    func testAssociatedDetailIsNotShown() {
        withChinese {
            for (error, detail) in [
                (SessionControlError.spawnFailed(detail: "claude: not on PATH"), "claude: not on PATH"),
                (.invalidResponse("bad json"), "bad json"),
                (.internalError("boom"), "boom"),
            ] {
                XCTAssertFalse(LocalSessionFailureText.message(for: error).contains(detail),
                               "\(error) put its protocol detail in front of the user")
            }
        }
    }

    /// The reason this is a new type rather than `LANRemoteFailureText`: those
    /// strings are written from the iPhone's point of view, and shown on the Mac
    /// about its own helper they are simply wrong.
    func testMacMessagesAreNotWrittenFromTheIPhonesPointOfView() {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set("en")
        defer { store.set(previous) }
        for error in Self.allCases {
            let shown = LocalSessionFailureText.message(for: error)
            // "iPhone" is the reliable tell. "this Mac" is NOT: the Mac-perspective
            // `helper_not_running_detail` correctly says "the local helper on this
            // Mac", and a check on that phrase would reject right copy.
            XCTAssertFalse(shown.contains("iPhone"),
                           "\(error) shows iPhone-perspective copy on the Mac: \(shown)")
        }
    }

    /// A catch-all receives a plain `Error`. It gets the generic line, not
    /// Foundation's "The operation couldn't be completed. (… error 1.)".
    func testANonSessionErrorGetsTheGenericLine() {
        withChinese {
            struct Other: Error {}
            let shown = LocalSessionFailureText.message(for: Other())
            XCTAssertEqual(shown, L10n.remote.errUnexpected)
            XCTAssertFalse(shown.contains("couldn"), "Foundation's generic text leaked: \(shown)")
        }
    }

    /// `description` stays English because os_log prints it and the LAN wire
    /// carries it — `LANSessionControlClient` compares that wire text by prefix.
    func testDescriptionIsStillEnglishUnderAnyLocale() {
        withChinese {
            XCTAssertEqual(SessionControlError.notControllable.description, "session not controllable from here")
            XCTAssertEqual(SessionControlError.spawnFailed(detail: "x").description, "spawn failed: x")
        }
    }
}

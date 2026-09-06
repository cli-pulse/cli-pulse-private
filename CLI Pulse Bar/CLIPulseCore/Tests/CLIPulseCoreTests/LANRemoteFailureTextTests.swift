import XCTest
import Network
@testable import CLIPulseCore

/// The phone used to paint `"\(error)"` into its own UI. These are real
/// behavioural tests, not source guards: `LANRemoteFailureText` is
/// deliberately outside `#if os(iOS)` so CI — which builds the iOS scheme
/// but runs no iOS tests — actually executes them.
final class LANRemoteFailureTextTests: XCTestCase {

    private var savedOverride: String?

    /// Pin the locale. `LocaleOverrideStore.shared.override` is persisted,
    /// so a filtered run inherits whatever the last full run left behind —
    /// which is how the first version of these tests saw EVERY key echo
    /// back, long-shipped ones included, and looked like a missing-strings
    /// bug in this change. With no locale pinned the leak assertions below
    /// would also be near-vacuous: a raw dotted key contains none of the
    /// markers they look for.
    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("en")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    /// Anything that betrays a Swift/Network error description rather than
    /// a sentence written for a person.
    private static let leaks = [
        "POSIXErrorCode", "rawValue", "NWError", "Error Domain",
        "nw_", "errSSL", "-9820", "Optional(", "CLIPulseCore.",
    ]

    private func assertHuman(_ s: String, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(s.isEmpty, "\(what) produced an empty message", file: file, line: line)
        // `tr` echoes the key when the strings entry is missing in the
        // active locale AND in the English fallback — exactly how a
        // half-landed localisation ships.
        XCTAssertFalse(s.hasPrefix("remote."),
                       "\(what) produced the raw key \(s) — en.lproj carries no such entry",
                       file: file, line: line)
        for marker in Self.leaks {
            XCTAssertFalse(s.contains(marker),
                           "\(what) leaked \(marker) to the user: \(s)", file: file, line: line)
        }
    }

    // MARK: - The distinction the old code threw away

    /// THE point of the change. Both of these arrive as `.waiting`, and
    /// both used to become `handshakeFailed("\(e)")` — one string, so the
    /// UI could not tell "pair again" from "wake the Mac" apart.
    ///
    /// Measured on macOS 26.5, loopback `NWListener`, pinned suite:
    ///   wrong PSK         → tls(-9820) "bad MAC"
    ///   nothing listening → posix(61)  "Connection refused"
    func test_wrongKeyAndUnreachableAreNotTheSameSentence() {
        let wrongKey = LANSessionControlClient.ConnectError.reason(for: .tls(-9820))
        let refused = LANSessionControlClient.ConnectError.reason(for: .posix(.ECONNREFUSED))
        XCTAssertEqual(wrongKey, .keyRejected)
        XCTAssertEqual(refused, .unreachable)

        let a = LANRemoteFailureText.message(for: LANSessionControlClient.ConnectError.handshakeFailed(wrongKey, "-9820: bad MAC"))
        let b = LANRemoteFailureText.message(for: LANSessionControlClient.ConnectError.handshakeFailed(refused, "POSIXErrorCode(rawValue: 61): Connection refused"))
        assertHuman(a, "wrong PSK")
        assertHuman(b, "nothing listening")
        XCTAssertNotEqual(a, b, "a rejected key and an unreachable Mac still say the same thing")
        XCTAssertEqual(a, L10n.remote.errPairingLost)
        XCTAssertEqual(b, L10n.remote.errMacUnreachable)
    }

    /// The exact string the user reported seeing on their phone.
    func test_theReportedPOSIX61StringNeverReachesTheUser() {
        let raw = "POSIXErrorCode(rawValue: 61): Connection refused"
        let msg = LANRemoteFailureText.message(
            for: LANSessionControlClient.ConnectError.handshakeFailed(.unreachable, raw))
        XCTAssertFalse(msg.contains("61"), "the errno reached the phone again: \(msg)")
        XCTAssertFalse(msg.contains(raw))
        assertHuman(msg, "the reported failure")
    }

    /// A handshake that SUCCEEDED but negotiated the wrong suite is a
    /// security signal, not a connectivity one, and must not be folded in.
    func test_anUnexpectedSuiteGetsItsOwnWords() {
        let msg = LANRemoteFailureText.message(
            for: LANSessionControlClient.ConnectError.unexpectedNegotiation("0x1301"))
        assertHuman(msg, "unexpected negotiation")
        XCTAssertEqual(msg, L10n.remote.errInsecureConnection)
        XCTAssertNotEqual(msg, L10n.remote.errMacUnreachable)
        XCTAssertFalse(msg.contains("0x1301"))
    }

    // MARK: - Nothing anywhere renders an error description

    func test_everyConnectErrorIsHuman() {
        let cases: [LANSessionControlClient.ConnectError] = [
            .handshakeFailed(.keyRejected, "-9820: bad MAC"),
            .handshakeFailed(.unreachable, "POSIXErrorCode(rawValue: 61): Connection refused"),
            .handshakeFailed(.cancelled, "cancelled"),
            .handshakeFailed(.other, "nw_error_domain 12345"),
            .unexpectedNegotiation("none"),
            .timeout,
        ]
        for c in cases { assertHuman(LANRemoteFailureText.message(for: c), "\(c)") }
    }

    func test_everyPairingFailureIsHuman() {
        let cases: [LANPairingSession.Failure] = [
            .channelClosed, .noExporter, .badExchange("bad b64"),
            .rejected, .expired, .protocolViolation("v"), .transport("mac not found on this wi-fi"),
        ]
        for c in cases { assertHuman(LANRemoteFailureText.message(for: c), "\(c)") }
        XCTAssertEqual(LANRemoteFailureText.message(for: LANPairingSession.Failure.rejected),
                       L10n.remote.errPairingDeclined,
                       "'Declined on the Mac' is hardcoded English again")
        XCTAssertNotEqual(LANRemoteFailureText.message(for: LANPairingSession.Failure.transport("x")),
                          "x", "the transport detail is being shown to the user")
    }

    /// Every case, so a new one has to be given words rather than
    /// inheriting a generic sentence by accident.
    func test_everySessionControlErrorIsHuman() {
        let cases: [SessionControlError] = [
            .helperNotRunning, .runtimeRestricted, .unauthenticated, .versionMismatch,
            .notImplemented, .localControlOff, .timeout, .disconnected,
            .invalidResponse("{"), .internalError("boom"), .sessionNotFound, .notControllable,
            .approvalNotFound, .approvalExpired, .approvalAlreadyResolved, .approvalNotAllowed,
            .approvalCapabilityInvalid, .approvalLimitReached, .spawnFailed(detail: "no binary"),
            .processNotFound, .processProtected, .processNotPermitted, .rateLimited, .attachFailed,
        ]
        for c in cases { assertHuman(LANRemoteFailureText.message(for: c), "\(c)") }
        XCTAssertNotEqual(LANRemoteFailureText.message(for: SessionControlError.internalError("boom")), "boom")
        XCTAssertFalse(LANRemoteFailureText.message(for: SessionControlError.spawnFailed(detail: "no binary")).contains("no binary"))
    }

    /// What the terminal's fallthrough catch ACTUALLY receives. `LANLinkChannel`
    /// wraps every NWConnection failure as `receiveFailed("\(e)")`, and the type
    /// has no `CustomStringConvertible`, so the old code painted the reflected
    /// Swift form — errno and all — after a localised "Disconnected: " prefix.
    func test_transportFailuresSayReachability_notTheReflectedSwiftForm() {
        let dropped: [LANLinkChannelError] = [
            .closed,
            .sendFailed("POSIXErrorCode(rawValue: 32): Broken pipe"),
            .receiveFailed("POSIXErrorCode(rawValue: 54): Connection reset by peer"),
        ]
        for e in dropped {
            let msg = LANRemoteFailureText.message(for: e)
            assertHuman(msg, "\(e)")
            XCTAssertEqual(msg, L10n.remote.errMacUnreachable,
                           "a dropped link should tell the user to check the Mac")
            XCTAssertFalse(msg.contains("54"), "the errno reached the phone: \(msg)")
        }
        // Framing is NOT a reachability failure — the bytes arrived and did not
        // parse. Telling the user to wake the Mac would aim them at the wrong
        // thing, so it deliberately gets different words.
        let framing = LANRemoteFailureText.message(for: LANLinkChannelError.framing(.tooLarge(claimed: 9_999_999)))
        assertHuman(framing, "framing")
        XCTAssertNotEqual(framing, L10n.remote.errMacUnreachable)
    }

    /// A hostname that does not resolve — `LANDirectAddress.parse` accepts
    /// hostnames on purpose (MagicDNS, `.local`), so a typo on the
    /// connect-by-address field lands here. "Try again" cannot help.
    func test_aNameThatDoesNotResolveIsAReachabilityFailure() {
        XCTAssertEqual(LANSessionControlClient.ConnectError.reason(for: .dns(-65554)), .unreachable)
        XCTAssertEqual(LANRemoteFailureText.message(for: NWError.dns(-65554)),
                       L10n.remote.errMacUnreachable)
        XCTAssertEqual(LANSessionControlClient.ConnectError.reason(for: .posix(.EADDRNOTAVAIL)), .unreachable)
    }

    /// A bare `NWError` reaching the UI unwrapped must land the same way.
    func test_bareNetworkErrorsAreHuman() {
        for e: NWError in [.posix(.ECONNREFUSED), .posix(.EHOSTUNREACH), .tls(-9820), .dns(-65554)] {
            assertHuman(LANRemoteFailureText.message(for: e), "\(e)")
        }
        XCTAssertEqual(LANRemoteFailureText.message(for: NWError.tls(-9820)), L10n.remote.errPairingLost)
    }

    /// An error from nowhere in particular still gets a sentence, and it
    /// is not the error's description.
    func test_anUnknownErrorFallsBackWithoutLeaking() {
        struct Weird: Error { let secret = "sk-ant-api03-XYZ" }
        let msg = LANRemoteFailureText.message(for: Weird())
        assertHuman(msg, "unknown error")
        XCTAssertEqual(msg, L10n.remote.errUnexpected)
        XCTAssertFalse(msg.contains("sk-ant"), "an unmapped error's contents reached the user")
    }

    // MARK: - Vacuity guard

    /// Proof that the localisation really resolved in this process. If it
    /// did not, every message above would be a dotted key, no key contains
    /// any leak marker, and the whole suite would pass while checking
    /// nothing.
    func test_theStringTableIsActuallyLive() {
        XCTAssertEqual(L10n.remote.errPairingDeclined, "Declined on the Mac.",
                       "en.lproj did not resolve — the rest of this suite is vacuous")
    }

    /// If every key resolved to the same string these tests would pass
    /// while saying nothing. They must be distinct sentences.
    func test_theMessagesAreActuallyDifferentSentences() {
        let all = [
            L10n.remote.errMacUnreachable, L10n.remote.errPairingLost,
            L10n.remote.errPairingDeclined, L10n.remote.errInsecureConnection,
            L10n.remote.errMacNeedsUpdate, L10n.remote.errTooFast,
            L10n.remote.errUnexpected,
        ]
        XCTAssertEqual(Set(all).count, all.count, "two of the new strings are identical: \(all)")
        for s in all { assertHuman(s, "string table") }
    }
}

/// Source guards for the `#if os(iOS)` screens that call the mapper — CI
/// compiles them but runs no iOS tests, so behaviour there is unreachable.
final class LANRemoteScreensErrorCopyTests: XCTestCase {

    private func screensSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let p = root.appendingPathComponent("Sources/CLIPulseCore/LANRemoteScreens.swift")
        return try String(contentsOf: p, encoding: .utf8)
    }

    /// ⚠️ This guard was FALSE GREEN when first written, and the way it failed
    /// is the reason it is worth reading.
    ///
    /// It matched the literal `"\(error)"` — WITH the delimiting quotes. That
    /// is the shape of a bare interpolation, and `main` had eight of those.
    /// It had two more that interpolate after a localised prefix:
    ///
    ///     setStatus("\(L10n.remote.disconnected): \(error)")
    ///
    /// There the `\(error)` is preceded by a space, so the quoted substring
    /// never appears and the assertion passed while the terminal's busiest
    /// failure path still painted `receiveFailed("POSIXErrorCode(rawValue:
    /// 54): Connection reset by peer")` at a six-language audience.
    ///
    /// The invariant is "no screen interpolates an Error", not "no screen
    /// contains this exact spelling". Match the interpolation itself. Verified
    /// precise rather than over-broad: on the fixed file neither pattern has a
    /// single hit, and `LANRemoteFailureText.message(for: error)` contains no
    /// interpolation to trip over.
    func test_noScreenPaintsAnErrorDescription() throws {
        let src = try screensSource()
        for bad in ["\\(error)", "\\(e)"] {
            XCTAssertFalse(src.contains(bad),
                           "a remote screen interpolates \(bad) into the UI again — "
                           + "route it through LANRemoteFailureText.message(for:). "
                           + "A localised prefix in front of it does not make it safe: "
                           + "the interpolated half is still an untranslated Swift dump.")
        }
    }

    func test_pairingDeclinedIsNotHardcodedEnglish() throws {
        let src = try screensSource()
        XCTAssertFalse(src.contains("\"Declined on the Mac\""),
                       "the pairing-declined copy is hardcoded English again")
        XCTAssertFalse(src.contains("\"Mac not found on this Wi-Fi\""),
                       "a user-visible English sentence is thrown as a transport detail again")
    }
}

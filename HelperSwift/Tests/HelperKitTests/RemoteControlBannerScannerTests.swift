import XCTest
@testable import HelperKit

/// Remote-control M1a — the scanner that turns `claude --remote-control`'s
/// start-up output into "here is the URL" or "here is why there is none".
///
/// Sentences are the ones shipped in Claude Code 2.1.259 (read out of the
/// binary, 2026-09-04). The positive banner could not be captured live on
/// the dev Mac (its CLI is not logged in to claude.ai), so the positive
/// cases here are the contract the scanner promises, not a recording.
final class RemoteControlBannerScannerTests: XCTestCase {

    private let url = "https://claude.ai/code/019a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8"

    private func banner(_ u: String) -> String {
        "\u{1b}[?25l\u{1b}[2K\r  \u{1b}[32m✓\u{1b}[39m connected\r\n  see this session at\r\n  \u{1b}[36m\(u)\u{1b}[39m\r\n  \u{1b}[2m\u{1b}[3mspace to show QR code\u{1b}[23m\u{1b}[22m\r\n"
    }

    // MARK: - Positive

    func testURLInsideANSIBannerIsFound() {
        let s = RemoteControlBannerScanner()
        XCTAssertEqual(s.feed(Data(banner(url).utf8)), .ready(url))
    }

    func testURLSplitAtEveryByteBoundaryIsStillFound() {
        let bytes = Array(banner(url).utf8)
        for cut in 1..<bytes.count {
            let s = RemoteControlBannerScanner()
            let first = s.feed(Data(bytes[..<cut]))
            let second = s.feed(Data(bytes[cut...]))
            XCTAssertEqual(first ?? second, .ready(url), "cut at \(cut)")
        }
    }

    func testSchemelessURLIsNormalisedToHTTPS() {
        let s = RemoteControlBannerScanner()
        XCTAssertEqual(s.feed(Data("see this session at claude.ai/code/abc123XYZ\r\n".utf8)),
                       .ready("https://claude.ai/code/abc123XYZ"))
    }

    func testQueryStringIsKept() {
        let s = RemoteControlBannerScanner()
        XCTAssertEqual(s.feed(Data("\(url)?from=cli\n".utf8)), .ready("\(url)?from=cli"))
    }

    // MARK: - Refusals

    func testEachRefusalSentenceMapsToItsReason() {
        let cases: [(String, RemoteControlBannerScanner.Reason)] = [
            ("Error: You must be logged in to use Remote Control.\n", .notLoggedIn),
            ("Remote Control is only available with claude.ai subscriptions. Please use `/login`…\n", .notLoggedIn),
            ("Remote Control is disabled by your organization's policy. Contact your organization admin for access.\n", .disabledByPolicy),
            ("Remote Control is only available when using Claude via api.anthropic.com.\n", .thirdPartyProvider),
        ]
        for (text, reason) in cases {
            let s = RemoteControlBannerScanner()
            XCTAssertEqual(s.feed(Data(("\u{1b}[31m" + text + "\u{1b}[39m").utf8)), .unavailable(reason), text)
        }
    }

    func testRefusalSplitAcrossChunksIsStillRecognised() {
        let text = "Remote Control is disabled by your organization's policy."
        let bytes = Array(text.utf8)
        for cut in stride(from: 1, to: bytes.count, by: 7) {
            let s = RemoteControlBannerScanner()
            let first = s.feed(Data(bytes[..<cut]))
            let second = s.feed(Data(bytes[cut...]))
            XCTAssertEqual(first ?? second, .unavailable(.disabledByPolicy), "cut at \(cut)")
        }
    }

    // MARK: - Negative controls

    func testOrdinaryOutputYieldsNothing() {
        let s = RemoteControlBannerScanner()
        XCTAssertNil(s.feed(Data("$ ls\nREADME.md  src\n❯ \n".utf8)))
        XCTAssertNil(s.feed(Data("Visit https://claude.ai/code/artifacts for the gallery\n".utf8)),
                     "the artifacts gallery URL is not a session URL")
        XCTAssertNil(s.feed(Data("https://claude.ai/code/ab\n".utf8)), "too short to be a session id")
    }

    func testFirstOutcomeLatchesAndLaterTextCannotChangeIt() {
        let s = RemoteControlBannerScanner()
        XCTAssertEqual(s.feed(Data(banner(url).utf8)), .ready(url))
        XCTAssertEqual(s.feed(Data("Remote Control is disabled by your organization's policy.\n".utf8)), .ready(url))
        XCTAssertEqual(s.outcome, .ready(url))
    }

    func testByteBudgetExhaustedWithoutABannerIsNoBannerSeen() {
        let s = RemoteControlBannerScanner(budgetBytes: 1024)
        var last: RemoteControlBannerScanner.Outcome?
        for _ in 0..<20 { last = s.feed(Data(String(repeating: "x", count: 100).utf8)) }
        XCTAssertEqual(last, .unavailable(.noBannerSeen))
    }

    func testANSIStrippingCoversCSIOSCAndCharsetSelects() {
        // The URL bytes themselves may be interleaved with cursor/colour
        // sequences by the renderer; the scanner must see one contiguous URL.
        let s = RemoteControlBannerScanner()
        let interleaved = "https://claude.ai/code/\u{1b}[36mabc123\u{1b}[39mDEF456\u{1b}]0;title\u{07}\u{1b}(B\n"
        XCTAssertEqual(s.feed(Data(interleaved.utf8)), .ready("https://claude.ai/code/abc123DEF456"))
    }
}

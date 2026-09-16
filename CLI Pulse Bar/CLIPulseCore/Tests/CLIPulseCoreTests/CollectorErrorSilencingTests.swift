#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// An Ollama that isn't running is the normal state for most users, so its
/// connection failures are silenced rather than logged every refresh.
///
/// That decision used to fall back to comparing `localizedDescription` with the
/// English "Could not connect to the server.". Under a Chinese or Japanese
/// system language that text is localized, so the comparison never matched and
/// the same failure was silenced for English users and logged for everyone
/// else. It is now decided by NSURLError domain and code, on the error and on
/// its underlying error.
final class CollectorErrorSilencingTests: XCTestCase {

    private func urlError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code)
    }

    /// A connection failure wrapped by some other layer, carrying whatever
    /// description that layer produced — which is localized by the system.
    private func wrapped(_ underlying: NSError, description: String) -> NSError {
        NSError(domain: "CLIPulse.Wrapper", code: 1, userInfo: [
            NSLocalizedDescriptionKey: description,
            NSUnderlyingErrorKey: underlying,
        ])
    }

    func testARawConnectionFailureIsSilenced() {
        for code in [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost] {
            XCTAssertTrue(DataRefreshManager.shouldSilenceCollectorError(kind: .ollama, error: urlError(code)))
        }
    }

    /// The bug. The identical failure, described in English and in Chinese,
    /// must get the identical answer.
    func testAWrappedConnectionFailureIsSilencedInEveryLanguage() {
        let cannotConnect = urlError(NSURLErrorCannotConnectToHost)
        for description in [
            "Could not connect to the server.",   // en
            "无法连接服务器。",                    // zh-Hans
            "無法連接伺服器。",                    // zh-Hant
            "サーバに接続できませんでした。",        // ja
        ] {
            XCTAssertTrue(
                DataRefreshManager.shouldSilenceCollectorError(
                    kind: .ollama, error: wrapped(cannotConnect, description: description)),
                "a wrapped connection failure described as \"\(description)\" was not silenced")
        }
    }

    func testOnlyOllamaIsSilenced() {
        XCTAssertFalse(DataRefreshManager.shouldSilenceCollectorError(
            kind: .claude, error: urlError(NSURLErrorCannotConnectToHost)),
            "a hosted provider being unreachable is a real problem and must be logged")
    }

    func testOtherOllamaFailuresAreStillLogged() {
        XCTAssertFalse(DataRefreshManager.shouldSilenceCollectorError(
            kind: .ollama, error: CollectorError.httpError(status: 500, provider: "Ollama")))
        XCTAssertFalse(DataRefreshManager.shouldSilenceCollectorError(
            kind: .ollama, error: urlError(NSURLErrorBadServerResponse)))
        // Matching the English TEXT alone must no longer be enough.
        XCTAssertFalse(DataRefreshManager.shouldSilenceCollectorError(
            kind: .ollama,
            error: NSError(domain: "Unrelated", code: 7,
                           userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."])),
            "silencing was decided by message text again")
    }

    func testTheSilentBackoffCaseStillWinsForEveryProvider() {
        XCTAssertTrue(DataRefreshManager.shouldSilenceCollectorError(
            kind: .gemini, error: CollectorError.silentBackoff("refresh token expired")))
    }
}
#endif

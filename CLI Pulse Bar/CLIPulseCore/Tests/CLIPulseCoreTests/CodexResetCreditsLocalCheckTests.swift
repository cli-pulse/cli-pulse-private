#if os(macOS)
import CryptoKit
import XCTest
@testable import CLIPulseCore

/// v1.57 (P1-3) acceptance on a real Mac: the limit reset credits CLI Pulse
/// reads for this Mac's Codex sign-in, as the main app's collector reads them,
/// against the endpoint's raw answer (and, by its digests, CodexBar's reading
/// of the same account).
///
/// Off unless asked for. It reads this Mac's own `~/.codex/auth.json` and asks
/// OpenAI, which no test may do for whoever happens to run the suite:
///
///     CLIPULSE_LOCAL_RESET_CREDITS_CHECK=1 swift test --filter CodexResetCreditsLocalCheckTests
///
/// Read-only: three GETs of `/wham/rate-limit-reset-credits`. The app's
/// request, then two variants of it with one header changed: with the
/// `originator` header upstream sends, and without `OpenAI-Beta`. The variants
/// run whether or not the app's read succeeds. If the app's read fails while
/// the request with `originator` answers, OpenAI has started to require that
/// header, and the output says so; likewise if only the request without
/// `OpenAI-Beta` answers. Nothing is redeemed, nothing is written, the sign-in
/// is never refreshed, and the keychain is never read (a Mac without a
/// readable auth.json skips). The output is counts, rounded countdowns and
/// short digests only: never a token, an account or credit ID, an email or a
/// body.
final class CodexResetCreditsLocalCheckTests: XCTestCase {
    /// What the app's own read sent and got, held in memory for the comparison.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var _headerNames: [String] = []
        private var _body: Data?
        private var _status: Int?
        var headerNames: [String] { lock.withLock { _headerNames } }
        var body: Data? { lock.withLock { _body } }
        var status: Int? { lock.withLock { _status } }
        func record(_ request: URLRequest) {
            lock.withLock { _headerNames = (request.allHTTPHeaderFields ?? [:]).keys.sorted() }
        }
        func record(_ data: Data, _ response: URLResponse) {
            lock.withLock {
                _body = data
                _status = (response as? HTTPURLResponse)?.statusCode
            }
        }
    }

    func testTheCreditsThisMacReadsMatchTheEndpointsAnswer() async throws {
        guard ProcessInfo.processInfo.environment["CLIPULSE_LOCAL_RESET_CREDITS_CHECK"] == "1" else {
            throw XCTSkip("set CLIPULSE_LOCAL_RESET_CREDITS_CHECK=1 to ask OpenAI with this Mac's Codex sign-in")
        }
        // The collector falls back to bridged credentials, a keychain read,
        // when auth.json cannot be read, and inside `swift test` that can
        // prompt or hang. With the file readable that fallback never runs.
        guard FileManager.default.isReadableFile(atPath: Self.authFilePath) else {
            print("LOCAL_RESET_CREDITS no readable Codex auth.json on this Mac")
            throw XCTSkip("no readable Codex auth.json on this Mac")
        }
        // The collector's own read of auth.json, in memory: no refresh, no write.
        guard let auth = CodexCollector().readAuthFile(), let token = auth.accessToken else {
            print("LOCAL_RESET_CREDITS no Codex sign-in on this Mac")
            throw XCTSkip("no Codex sign-in on this Mac")
        }
        print("LOCAL_RESET_CREDITS sign-in: ChatGPT account header \(auth.accountId?.isEmpty == false ? "present" : "absent")")

        // 1. Exactly the read the main app's collector starts after a quota
        //    read (`CodexResetCreditsReporter.live`): same request, same
        //    ephemeral session, same budget. The wrapper only looks.
        let capture = Capture()
        let outcome = await CodexResetCreditsFetcher.fetch(
            accessToken: token,
            chatGPTAccountID: auth.accountId,
            transport: { request in
                capture.record(request)
                let (data, response) = try await CodexResetCreditsFetcher.liveTransport(request)
                capture.record(data, response)
                return (data, response)
            }
        )
        print("LOCAL_RESET_CREDITS app request headers: \(capture.headerNames.joined(separator: ", "))")
        let now = Date()
        let snapshot: CodexRateLimitResetCreditsSnapshot
        switch outcome {
        case .fetched(let read):
            snapshot = read
        case .skippedStaleCredential:
            print("LOCAL_RESET_CREDITS app read: skipped, the sign-in expires within 5 minutes")
            throw XCTSkip("stale credential")
        case .failed(let failure):
            print("LOCAL_RESET_CREDITS app read: failed (\(failure)), http \(capture.status.map(String.init) ?? "none")")
            // The case the variants exist for: is one header the cause?
            let variants = await Self.probeVariants(token: token, accountID: auth.accountId, now: now, appCredits: nil)
            print("LOCAL_RESET_CREDITS diagnosis: \(Self.diagnosis(withOriginator: variants.withOriginator, withoutBeta: variants.withoutBeta))")
            XCTFail("the app's read failed: \(failure)")
            return
        }
        let inventory = snapshot.availableInventory(at: now)
        let card = CodexResetCreditsPresentation.make(snapshot: snapshot, now: now)
        print("LOCAL_RESET_CREDITS app read: http \(capture.status.map(String.init) ?? "none"), server count \(snapshot.availableCount), credits listed \(snapshot.credits.count), card count \(inventory.count)")
        print("LOCAL_RESET_CREDITS card countdowns: \(Self.countdowns(inventory.credits.map(\.expiresAt), now: now))")
        print("LOCAL_RESET_CREDITS card row: \(card.map { "\($0.text) | \($0.expirySummaryText)" } ?? "(hidden: nothing usable)")")
        let appIDs = Self.digest(inventory.credits.map(\.id))
        let appExpiries = Self.digest(inventory.credits.compactMap(\.expiresAt).map { String(Int($0.timeIntervalSince1970)) })
        print("LOCAL_RESET_CREDITS app id-set digest: \(appIDs)")
        print("LOCAL_RESET_CREDITS app expiry-set digest: \(appExpiries)")

        // 2. The same answer read without the app's model: what the endpoint
        //    itself says is usable now.
        let raw = try XCTUnwrap(capture.body.flatMap { Self.rawUsable($0, now: now) }, "the raw body is not the expected shape")
        print("LOCAL_RESET_CREDITS raw: available_count \(raw.serverCount), credits listed \(raw.listed), usable now \(raw.ids.count)")
        print("LOCAL_RESET_CREDITS raw id-set digest: \(Self.digest(raw.ids))")
        print("LOCAL_RESET_CREDITS raw expiry-set digest: \(Self.digest(raw.expiries))")
        XCTAssertEqual(inventory.count, raw.ids.count)
        XCTAssertEqual(appIDs, Self.digest(raw.ids))
        XCTAssertEqual(appExpiries, Self.digest(raw.expiries))

        // 3. The variants, each with one header changed and everything else
        //    the same, so a later release can see which headers matter.
        _ = await Self.probeVariants(token: token, accountID: auth.accountId, now: now, appCredits: inventory.credits.map(\.id))
    }

    /// The same path the collector reads: `$CODEX_HOME/auth.json`, else
    /// `~/.codex/auth.json` in the real home (not the sandbox container).
    private static var authFilePath: String {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (realUserHome() as NSString).appendingPathComponent(".codex")
        return (home as NSString).appendingPathComponent("auth.json")
    }

    /// What one variant got: its status and whether the body decodes.
    private struct Probe {
        let status: Int?
        let decodes: Bool
        var answers: Bool { status.map { (200..<300).contains($0) } == true && decodes }
    }

    /// The app's request with `originator` added, then without `OpenAI-Beta`.
    /// `appCredits` is the app's read when it succeeded, to say whether a
    /// variant lists the same credits; nil when it failed.
    private static func probeVariants(
        token: String,
        accountID: String?,
        now: Date,
        appCredits: [String]?
    ) async -> (withOriginator: Probe, withoutBeta: Probe) {
        let withOriginator = await probe("with upstream's originator", token: token, accountID: accountID, now: now, appCredits: appCredits) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "originator"), "the app's request sends no originator")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        }
        let withoutBeta = await probe("without OpenAI-Beta", token: token, accountID: accountID, now: now, appCredits: appCredits) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "codex-1", "the app's request sends OpenAI-Beta")
            request.setValue(nil, forHTTPHeaderField: "OpenAI-Beta")
        }
        return (withOriginator, withoutBeta)
    }

    /// One more GET of the app's request with one header changed. Prints the
    /// status, whether the body decodes and whether it lists the app's
    /// credits: never the body.
    private static func probe(
        _ label: String,
        token: String,
        accountID: String?,
        now: Date,
        appCredits: [String]?,
        change: (inout URLRequest) -> Void
    ) async -> Probe {
        var request = CodexResetCreditsFetcher.request(accessToken: token, chatGPTAccountID: accountID)
        change(&request)
        do {
            let (data, response) = try await CodexResetCreditsFetcher.liveTransport(request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let decoded = try? CodexRateLimitResetCreditsSnapshot.decode(data, now: now)
            let same: String
            if let decoded, let appCredits {
                same = decoded.availableInventory(at: now).credits.map(\.id) == appCredits ? "yes" : "no"
            } else {
                same = "n/a"
            }
            print("LOCAL_RESET_CREDITS \(label): http \(status.map(String.init) ?? "none"), decodes \(decoded == nil ? "no" : "yes"), same credits \(same)")
            return Probe(status: status, decodes: decoded != nil)
        } catch {
            print("LOCAL_RESET_CREDITS \(label): transport error \((error as? URLError)?.code.rawValue ?? -1)")
            return Probe(status: nil, decodes: false)
        }
    }

    /// Why the app's read failed, as far as the variants can tell.
    private static func diagnosis(withOriginator: Probe, withoutBeta: Probe) -> String {
        switch (withOriginator.answers, withoutBeta.answers) {
        case (true, false):
            return "the request with upstream's originator answers and the app's does not => the endpoint now requires originator"
        case (false, true):
            return "the request without OpenAI-Beta answers and the app's does not => the endpoint now rejects OpenAI-Beta: codex-1"
        case (true, true):
            return "both variants answer and the app's request did not => not a header; the failure did not repeat (rerun)"
        case (false, false):
            return "neither variant answers either => not a header: the sign-in, the account or the server"
        }
    }

    /// "2d 4h · 6d 1h", minutes rounded up as the card's countdown is, in a
    /// fixed spelling so it compares with any other reader's.
    private static func countdowns(_ expiries: [Date?], now: Date) -> String {
        expiries.map { expiry -> String in
            guard let expiry else { return "No expiry" }
            let seconds = expiry.timeIntervalSince(now)
            guard seconds >= 1 else { return "now" }
            let total = max(1, Int(ceil(seconds / 60)))
            let days = total / 1440, hours = (total / 60) % 24, minutes = total % 60
            if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : (minutes > 0 ? "\(days)d \(minutes)m" : "\(days)d") }
            if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
            return "\(total)m"
        }.joined(separator: " · ")
    }

    /// The first 12 hex digits of a SHA-256 over the sorted values.
    private static func digest(_ values: [String]) -> String {
        let joined = values.sorted().joined(separator: "\n")
        return String(SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// From the body as JSON, not through the app's decoder: the credits that
    /// are available and not expired at `now`, as hashed IDs and whole-second
    /// expiry instants.
    private static func rawUsable(_ body: Data, now: Date) -> (serverCount: Int, listed: Int, ids: [String], expiries: [String])? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let credits = json["credits"] as? [[String: Any]],
              let serverCount = json["available_count"] as? Int else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ raw: Any?) -> Date? {
            guard let raw = raw as? String else { return nil }
            return fractional.date(from: raw) ?? plain.date(from: raw)
        }
        var ids: [String] = []
        var expiries: [String] = []
        for credit in credits where credit["status"] as? String == "available" {
            let expiry = date(credit["expires_at"])
            if let expiry, expiry <= now { continue }
            guard let id = credit["id"] as? String else { continue }
            ids.append(CodexRateLimitResetCredit.stableID(forProviderID: id))
            if let expiry { expiries.append(String(Int(expiry.timeIntervalSince1970))) }
        }
        return (serverCount, credits.count, ids, expiries)
    }
}
#endif

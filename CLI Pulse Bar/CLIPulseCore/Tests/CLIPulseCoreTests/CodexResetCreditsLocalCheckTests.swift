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
/// Read-only: two GETs of `/wham/rate-limit-reset-credits` (the app's request,
/// then the same request with the `originator` header upstream sends). If the
/// app's read ever fails while the second answers, OpenAI has started to
/// require that header. Nothing is redeemed, nothing
/// is written, the sign-in is never refreshed. The output is counts, rounded
/// countdowns and short digests only: never a token, an account or credit ID,
/// an email or a body.
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

        // 3. Once more with the header upstream adds, everything else the same.
        var upstream = CodexResetCreditsFetcher.request(accessToken: token, chatGPTAccountID: auth.accountId)
        XCTAssertNil(upstream.value(forHTTPHeaderField: "originator"), "the app's request sends no originator")
        upstream.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        do {
            let (data, response) = try await CodexResetCreditsFetcher.liveTransport(upstream)
            let status = (response as? HTTPURLResponse)?.statusCode
            let decoded = try? CodexRateLimitResetCreditsSnapshot.decode(data, now: now)
            let same = decoded.map { $0.availableInventory(at: now).credits.map(\.id) == inventory.credits.map(\.id) }
            print("LOCAL_RESET_CREDITS with upstream's originator: http \(status.map(String.init) ?? "none"), decodes \(decoded == nil ? "no" : "yes"), same credits \(same.map { $0 ? "yes" : "no" } ?? "n/a")")
        } catch {
            print("LOCAL_RESET_CREDITS with upstream's originator: transport error \((error as? URLError)?.code.rawValue ?? -1)")
        }
    }

    /// "8d 9h · 15d 8h", minutes rounded up as the card's countdown is, in a
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

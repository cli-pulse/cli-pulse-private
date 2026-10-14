// The request in `CodexResetCreditsFetcher.request` follows steipete/CodexBar
// Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift
// (`fetchRateLimitResetCredits`, line 524 at upstream commit 25bba9b7,
// 2026-09-28): the path, the 4 s timeout and the headers OpenAI's endpoint is
// read with. When it is asked follows Sources/CodexBar/UsageStore+CodexResetCredits.swift
// (`fetchCodexResetCredits`): only with the credential the usage request just
// used, never a fresh read of auth.json, and not with one about to expire.
// https://github.com/steipete/CodexBar
//
// Not verbatim: the base URL is fixed to chatgpt.com, as CLI Pulse's own
// `/wham/usage` request is (upstream reads `chatgpt_base_url` from Codex's
// config.toml); the User-Agent is CLI Pulse's, and there is no `originator`
// header (upstream sends "Codex Desktop"); the 4 s is a budget for the
// whole read, not only URLSession's idle timeout; the read goes through an
// ephemeral session that stores nothing; a failure is an outcome, never a
// thrown error; and the read runs after the quota is returned, not before it.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

#if os(macOS)
import CryptoKit
import Foundation
import os

private let resetCreditsLogger = Logger(subsystem: "com.clipulse", category: "CodexResetCredits")

// MARK: - The read

/// One read of `/wham/rate-limit-reset-credits`. Read-only: a GET with no body,
/// and nothing in CLI Pulse calls the endpoint that redeems a credit.
public enum CodexResetCreditsFetcher {
    static let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    /// The whole read, connection included. Past it the read is cancelled and
    /// counts as failed.
    public static let budget: TimeInterval = 4

    /// A credential this close to its `exp` is not used: the read would most
    /// likely be refused, and renewing it is the usage path's business.
    static let staleCredentialWindow: TimeInterval = 5 * 60

    public enum Outcome: Equatable, Sendable {
        case fetched(CodexRateLimitResetCreditsSnapshot)
        /// Not asked: the credential expires within `staleCredentialWindow`.
        case skippedStaleCredential
        case failed(Failure)

        public var snapshot: CodexRateLimitResetCreditsSnapshot? {
            if case .fetched(let snapshot) = self { return snapshot }
            return nil
        }
    }

    /// Why a read failed. Logged by category only: never a credential, never
    /// a credit's ID, never the body.
    public enum Failure: Equatable, Sendable {
        case timedOut
        case http(Int)
        case transport
        case invalidResponse
        case cancelled
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The read's own session, which keeps nothing: no URL cache, no cookies,
    /// no stored credentials. `URLSession.shared` would write the request,
    /// bearer token included, and the raw body, with the provider's credit
    /// IDs, to the app's on-disk `Cache.db`: chatgpt.com's backend sends no
    /// `Cache-Control`, and a request's cache policy only governs reading from
    /// a cache, never storing to it.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    public static let liveTransport: Transport = { request in
        try await session.data(for: request)
    }

    /// The GET. `chatGPTAccountID` is the `account_id` from the same auth.json
    /// read as `accessToken`, so the credits and the quota are one account's.
    static func request(
        accessToken: String,
        chatGPTAccountID: String?,
        timeout: TimeInterval = budget
    ) -> URLRequest {
        // Never answered from a cache. Not storing the answer is `session`'s
        // job: a cache policy cannot do that.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CLIPulseBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Upstream sends this endpoint two headers OpenAI's own Codex clients
        // send. `OpenAI-Beta` stays. `originator` does not: its value names
        // OpenAI's Codex Desktop app, and CLI Pulse does not present itself as
        // another app. The endpoint answered a signed-in account the same
        // credits without it (2026-10-14, `CodexResetCreditsLocalCheckTests`).
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        if let chatGPTAccountID, !chatGPTAccountID.isEmpty {
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        return request
    }

    /// Reads the inventory, or says why not. Never throws and never runs past
    /// `budget`: whatever happens here cannot reach the quota read.
    public static func fetch(
        accessToken: String,
        chatGPTAccountID: String?,
        now: @escaping @Sendable () -> Date = { Date() },
        budget: TimeInterval = budget,
        transport: @escaping Transport = liveTransport
    ) async -> Outcome {
        if let expiry = CodexCollector.jwtExpiry(accessToken),
           expiry.timeIntervalSince(now()) <= staleCredentialWindow {
            return .skippedStaleCredential
        }
        let request = request(accessToken: accessToken, chatGPTAccountID: chatGPTAccountID, timeout: budget)
        return await withTaskGroup(of: Outcome?.self) { group in
            group.addTask {
                await attempt(request, now: now, transport: transport)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
                return nil // the budget ran out first
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed(.timedOut)
        }
    }

    private static func attempt(
        _ request: URLRequest,
        now: @Sendable () -> Date,
        transport: Transport
    ) async -> Outcome {
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { return .failed(.invalidResponse) }
            guard (200...299).contains(http.statusCode) else { return .failed(.http(http.statusCode)) }
            do {
                return .fetched(try CodexRateLimitResetCreditsSnapshot.decode(data, now: now()))
            } catch {
                return .failed(.invalidResponse)
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return .failed(.cancelled)
            }
            return .failed(.transport)
        }
    }
}

// MARK: - Where the card reads it

/// The latest reading per CLI Pulse account (`ProviderConfig.accountID`), in
/// memory only. The Codex card observes it.
///
/// Every pass that reads the quota replaces the account's reading: with what
/// the read returned, or with nothing when it failed, timed out, was skipped
/// or is switched off. A pass whose quota read failed clears it too. So the
/// card never shows credits a later pass could not confirm.
///
/// A pass signed in to another ChatGPT account than the reading's (a
/// `codex login` in between) drops the reading as soon as its read begins,
/// not when it ends: the new account's quota can be on the card before its
/// credits are read, and must never sit beside the old account's credits.
@MainActor
public final class CodexResetCreditsStore: ObservableObject {
    public static let shared = CodexResetCreditsStore()

    @Published public private(set) var snapshots: [UUID: CodexRateLimitResetCreditsSnapshot] = [:]

    /// Bumped by every `begin` and `clear`, so a slow read that finishes after
    /// a newer one (or after a clear) is dropped instead of putting back an
    /// older answer.
    private var generations: [UUID: Int] = [:]

    /// Which ChatGPT account each account's latest read was for, as a digest
    /// (`chatGPTAccountDigest`): the ID itself is not kept.
    private var chatGPTAccounts: [UUID: String] = [:]

    public init() {}

    /// A read for `account`, signed in to `chatGPTAccountID`, is starting.
    func begin(_ account: UUID, chatGPTAccountID: String?) -> Int {
        let next = (generations[account] ?? 0) + 1
        generations[account] = next
        let digest = Self.chatGPTAccountDigest(chatGPTAccountID)
        if chatGPTAccounts[account] != digest {
            chatGPTAccounts[account] = digest
            if snapshots[account] != nil {
                snapshots[account] = nil
            }
        }
        return next
    }

    func finish(_ account: UUID, generation: Int, snapshot: CodexRateLimitResetCreditsSnapshot?) {
        guard generations[account] == generation else { return }
        if let snapshot {
            // The same credits read again change nothing on the card, so they
            // do not publish: every provider card would redraw for nothing.
            if snapshots[account]?.hasTheSameCredits(as: snapshot) != true {
                snapshots[account] = snapshot
            }
        } else if snapshots[account] != nil {
            snapshots[account] = nil
        }
    }

    func clear(_ account: UUID) {
        generations[account] = (generations[account] ?? 0) + 1
        if snapshots[account] != nil {
            snapshots[account] = nil
        }
    }

    /// Every account's reading goes, and every read still in flight is
    /// dropped when it finishes. For a "Not now" to reading this Mac: the
    /// passes stop, so nothing would replace a reading made before it.
    public func clearAll() {
        for account in Set(generations.keys).union(snapshots.keys) {
            generations[account] = (generations[account] ?? 0) + 1
        }
        if !snapshots.isEmpty {
            snapshots = [:]
        }
    }

    /// Domain-separated SHA-256 of the ChatGPT account ID; nil and "" are one
    /// value, "no account header".
    nonisolated static func chatGPTAccountDigest(_ chatGPTAccountID: String?) -> String {
        let separated = "yyh.CLI-Pulse.codex-reset-credits-account.v1\0\(chatGPTAccountID ?? "")"
        return SHA256.hash(data: Data(separated.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The reading of the first of `accounts` that has one.
    public func snapshot(forAnyOf accounts: [UUID]) -> CodexRateLimitResetCreditsSnapshot? {
        accounts.lazy.compactMap { self.snapshots[$0] }.first
    }
}

/// Starts the read for a Codex collector pass. Only the main app's collector
/// has one (`CodexCollector.mainApp`): the helper login item runs the same
/// collector without it, so a Mac never asks twice and the helper never holds
/// a reading nobody shows.
struct CodexResetCreditsReporter: Sendable {
    let isEnabled: @Sendable () -> Bool
    let fetch: @Sendable (_ accessToken: String, _ chatGPTAccountID: String?) async -> CodexResetCreditsFetcher.Outcome
    let store: @Sendable () async -> CodexResetCreditsStore

    static let live = CodexResetCreditsReporter(
        isEnabled: { CodexResetCreditsFeature.isEnabled() },
        fetch: { token, accountID in
            await CodexResetCreditsFetcher.fetch(accessToken: token, chatGPTAccountID: accountID)
        },
        store: { await MainActor.run { CodexResetCreditsStore.shared } }
    )

    /// After the quota came back: read the credits with the same credential,
    /// in a task of their own, so the pass returns the quota without waiting
    /// for them. Returns that task (tests await it; the collector does not).
    @discardableResult
    func refresh(account: UUID, accessToken: String, chatGPTAccountID: String?) -> Task<Void, Never> {
        Task {
            let store = await store()
            let generation = await store.begin(account, chatGPTAccountID: chatGPTAccountID)
            guard isEnabled() else {
                await store.finish(account, generation: generation, snapshot: nil)
                return
            }
            let outcome = await fetch(accessToken, chatGPTAccountID)
            if case .failed(let failure) = outcome {
                resetCreditsLogger.info("Codex reset credits not read: \(String(describing: failure), privacy: .public)")
            }
            await store.finish(account, generation: generation, snapshot: outcome.snapshot)
        }
    }

    /// The quota read failed: whatever the card held for this account goes.
    @discardableResult
    func clear(account: UUID) -> Task<Void, Never> {
        Task {
            await store().clear(account)
        }
    }
}
#endif

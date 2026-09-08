import Foundation

/// R0 — the `pterm:` producer the Swift helper has been missing.
///
/// ## Why this is not just `SupabaseRealtimeBroadcastSink` with a
/// ## different topic string
///
/// The public sink POSTs straight to `/realtime/v1/api/broadcast`
/// with the project **anon key**. That works for `term:<sid>` because
/// that topic is not RLS-governed — its confidentiality is the
/// unguessable session UUID and nothing else.
///
/// `pterm:<sid>` IS RLS-governed, and an anon-key POST carries no
/// identity that the WRITE policy could authorize. v0.65's design
/// answered this with a minted `r0_broadcast` token posted directly
/// to the same endpoint. **That path cannot be made to work by the
/// owner of a hosted Supabase project**, measured 2026-09-08:
/// `realtime.messages` is owned by `supabase_realtime_admin`, the
/// migration role holds INSERT *without grant option*, and a GRANT
/// from a grantor lacking that option does not error — it warns and
/// returns success. `grant supabase_realtime_admin to postgres` is
/// refused by `supautils.reserved_memberships` (42501). See
/// `backend/supabase/migrate_v0.82_r0_broadcast_insert_grant.sql`.
///
/// So this sink takes the fallback v0.65 itself recorded at its own
/// line 65 — *"fall back to a service-relay broadcast (helper→edge
/// fn→service-role `realtime.send`)"* — which needs no privilege
/// nobody has:
///
/// ```
/// helper ──POST {device_id, helper_secret, session_id, event, chunks}──▶
///     edge fn `broadcast-terminal`
///        └─ remote_helper_authorize_broadcast(...)  ← the boundary
///        └─ POST /realtime/v1/api/broadcast as service_role
/// ```
///
/// **The authorization boundary moves from the RLS policy into the
/// edge function.** That is a real cost and it is stated plainly
/// rather than buried: `service_role` is `rolbypassrls`, so no policy
/// is consulted on the write path. What makes it acceptable is that
/// the check is not new code — `remote_helper_authorize_broadcast` is
/// the same gate `mint-realtime-token` has used since 2026-07, and it
/// raises 42501 on a bad secret, a wrong device, a session the device
/// does not own, or a non-private session.
///
/// ## Measured, not assumed (2026-09-08, against production)
///
/// The relay was proven end-to-end before this file was written, by
/// subscribing a WebSocket client to `pterm:<nil-uuid>` and publishing
/// to it two ways:
///
/// ```
/// publish as anon   -> HTTP 202  ->  NOT delivered
/// publish as secret -> HTTP 202  ->  DELIVERED
/// ```
///
/// Two things follow, and the second is a trap:
///
///   1. A `service_role` POST to a PRIVATE topic is accepted AND
///      delivered. That is the whole basis of this design.
///   2. **HTTP 202 from the broadcast endpoint does not mean
///      delivered.** The anon publish got the same 202 and was
///      silently dropped. So Realtime's write-side authorization is
///      real (good — no injection hole on `pterm:`), but it reports
///      failure as success. Never treat a 2xx here as proof a chunk
///      landed; the only evidence is a subscriber receiving it.
///
/// That is also why this sink authorizes through the edge function
/// rather than trusting the endpoint's status: the relay's 200 means
/// "the RPC authorized this device for this session", which is a
/// claim worth something, and it is checked against the DB rather
/// than inferred from a fire-and-forget ack.
///
/// (Incidentally settled at the same time: `realtime.messages` had no
/// partition newer than 2026-06-28, and `realtime.send` was failing
/// with `no partition of relation "messages" found for row` — swallowed
/// into a WARNING by that function. It is not a blocker for THIS path.
/// Partitions are created when a client connects; the probe's own
/// WebSocket join created 2026-09-11 and four others. The HTTP
/// broadcast path does not persist to that table at all.)
///
/// ## Coalescing
///
/// Every POST here costs one edge-function invocation, unlike the
/// public sink's direct hop. A chatty PTY would otherwise turn one
/// terminal into hundreds of invocations a minute, so this sink
/// batches: chunks that arrive within `coalesceWindow` are sent as
/// one request carrying an ordered array. The Python producer
/// (`helper/realtime_broadcast.py`) uses the same ~60 ms window for
/// the same reason.
///
/// ## What this sink must never do
///
/// It receives `redactedBytes` — `TerminalBroadcastPublisher` has
/// already run `Redactor.redact`. It MUST NOT reach for the raw
/// chunk by any side path; that invariant is pinned upstream by
/// `TerminalBroadcastPublisherTests`.
public actor EdgeRelayPrivateBroadcastSink: TerminalBroadcastSink {

    public enum SinkError: Error, Equatable {
        case notConfigured
        /// The relay rejected this device/session pair. Distinct from
        /// `.http` because the caller should stop trying rather than
        /// treat it as a blip — 403 is an authoritative denial from
        /// `remote_helper_authorize_broadcast`, not infrastructure.
        case denied
        case transport(String)
        case http(status: Int, body: String)
        /// The topic did not start with `pterm:`. A programming error
        /// that would publish private output on the public channel;
        /// refused loudly rather than repaired silently.
        case wrongTopic(String)
    }

    public let requestTimeout: TimeInterval
    public let coalesceWindow: Duration
    /// Cap on how much redacted output one relay POST may carry.
    /// Bounds both the edge-function payload and the damage a burst
    /// can do; excess is flushed as a second request, never dropped
    /// here (drop policy belongs to the publisher).
    public let maxBatchBytes: Int

    private let configProvider: @Sendable () -> HelperConfigStore.CloudConfig
    private let session: URLSession
    /// Sessions whose relay returned an authoritative 403. Cleared
    /// only by a helper restart or a new pairing — retrying a denied
    /// session every 60 ms would hammer the edge function for output
    /// nobody is allowed to receive.
    private var deniedSessions: Set<String> = []
    private var pending: [String: [(event: String, bytes: Data)]] = [:]
    private var flushTask: Task<Void, Never>?

    public init(
        configProvider: @escaping @Sendable () -> HelperConfigStore.CloudConfig,
        requestTimeout: TimeInterval = 2.5,
        coalesceWindow: Duration = .milliseconds(60),
        maxBatchBytes: Int = 64 * 1024,
        session: URLSession? = nil
    ) {
        self.configProvider = configProvider
        self.requestTimeout = requestTimeout
        self.coalesceWindow = coalesceWindow
        self.maxBatchBytes = max(1024, maxBatchBytes)
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = requestTimeout
            cfg.timeoutIntervalForResource = requestTimeout
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    public func publish(
        sessionId: String,
        channel: String,
        event: String,
        redactedBytes: Data
    ) async throws {
        guard channel.hasPrefix(TerminalBroadcastVisibility.privateTopic.topicPrefix) else {
            throw SinkError.wrongTopic(channel)
        }
        if deniedSessions.contains(sessionId) { throw SinkError.denied }

        pending[sessionId, default: []].append((event: event, bytes: redactedBytes))
        if flushTask == nil {
            flushTask = Task { [coalesceWindow] in
                try? await Task.sleep(for: coalesceWindow)
                await self.flush()
            }
        }
    }

    /// Test hook: flush now instead of waiting out the window.
    public func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        await flush()
    }

    private func flush() async {
        flushTask = nil
        let batches = pending
        pending.removeAll(keepingCapacity: true)
        for (sessionId, items) in batches {
            if deniedSessions.contains(sessionId) { continue }
            for group in Self.split(items, maxBytes: maxBatchBytes) {
                do {
                    try await send(sessionId: sessionId, items: group)
                } catch SinkError.denied {
                    deniedSessions.insert(sessionId)
                    break
                } catch {
                    // Transport/5xx: the chunk is gone. The publisher's
                    // drop accounting and the phone's reconnect
                    // tail-snapshot are the recovery path; retrying here
                    // would back-pressure the PTY drain loop.
                }
            }
        }
    }

    /// Split an ordered run of chunks into batches no larger than
    /// `maxBytes`, preserving order. A single chunk larger than the
    /// cap becomes its own batch rather than being silently truncated.
    static func split(
        _ items: [(event: String, bytes: Data)],
        maxBytes: Int
    ) -> [[(event: String, bytes: Data)]] {
        var out: [[(event: String, bytes: Data)]] = []
        var cur: [(event: String, bytes: Data)] = []
        var size = 0
        for item in items {
            if !cur.isEmpty && size + item.bytes.count > maxBytes {
                out.append(cur); cur = []; size = 0
            }
            cur.append(item)
            size += item.bytes.count
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func send(sessionId: String, items: [(event: String, bytes: Data)]) async throws {
        let cfg = configProvider()
        guard cfg.isPaired, let baseURL = URL(string: cfg.supabaseURL) else {
            throw SinkError.notConfigured
        }
        let endpoint = baseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("broadcast-terminal")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Gateway auth only — the project anon key gets us past the
        // edge runtime's JWT check. REAL per-device authorization is
        // `helper_secret`, verified inside the function. Same model as
        // `mint-realtime-token` and the other remote_helper_* paths.
        req.setValue(cfg.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(cfg.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "device_id": cfg.deviceId,
            "helper_secret": cfg.helperSecret,
            "session_id": sessionId,
            "chunks": items.map { ["event": $0.event, "data_b64": $0.bytes.base64EncodedString()] },
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw SinkError.transport("encode body: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SinkError.transport("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SinkError.transport("non-HTTP response")
        }
        // 403 is the RPC's authoritative 42501 denial. 5xx is infra —
        // the edge function maps a DB blip to 500 on purpose so this
        // side does not latch a healthy session into `deniedSessions`.
        if http.statusCode == 403 || http.statusCode == 401 {
            throw SinkError.denied
        }
        if !(200..<300).contains(http.statusCode) {
            throw SinkError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}

/// Routes a chunk to the public or private sink by looking at the
/// topic the publisher stamped on it.
///
/// The dispatch is on the TOPIC PREFIX rather than on a boolean
/// passed alongside, deliberately: the topic is the thing that
/// actually reaches Realtime, so routing on it makes "published to
/// `pterm:` but sent through the anon-key public sink" unrepresentable
/// rather than merely unlikely. An unrecognized prefix is refused,
/// not guessed.
public struct PrivacyRoutingBroadcastSink: TerminalBroadcastSink {

    public enum RouteError: Error, Equatable {
        case unroutableTopic(String)
        /// The private sink is not configured on this install, so a
        /// `pterm:` chunk has nowhere to go. Refused rather than
        /// downgraded to the public topic.
        case privateSinkUnavailable
    }

    private let publicSink: any TerminalBroadcastSink
    private let privateSink: (any TerminalBroadcastSink)?

    public init(
        publicSink: any TerminalBroadcastSink,
        privateSink: (any TerminalBroadcastSink)? = nil
    ) {
        self.publicSink = publicSink
        self.privateSink = privateSink
    }

    public func publish(
        sessionId: String,
        channel: String,
        event: String,
        redactedBytes: Data
    ) async throws {
        if channel.hasPrefix(TerminalBroadcastVisibility.privateTopic.topicPrefix) {
            guard let privateSink else { throw RouteError.privateSinkUnavailable }
            try await privateSink.publish(
                sessionId: sessionId, channel: channel,
                event: event, redactedBytes: redactedBytes)
            return
        }
        if channel.hasPrefix(TerminalBroadcastVisibility.publicTopic.topicPrefix) {
            try await publicSink.publish(
                sessionId: sessionId, channel: channel,
                event: event, redactedBytes: redactedBytes)
            return
        }
        throw RouteError.unroutableTopic(channel)
    }
}

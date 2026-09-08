import Foundation

/// R0 — the `pterm:` producer the SWIFT helper has been missing.
///
/// ⚠️ "Missing" is true of the Swift helper and FALSE of the repo. A complete
/// `pterm:` producer already ships in `helper/realtime_broadcast.py` (the
/// separately-installed Python .pkg), gated by
/// `remote_realtime_broadcast_enabled`, which has DEFAULTED ON since helper
/// 1.24.0. It takes v0.65's direct path: mint a token, POST to
/// `/realtime/v1/api/broadcast`. Measured 2026-09-08, that path cannot have
/// delivered a byte since at least 2026-08-30 — `r0_broadcast` holds no INSERT
/// on `realtime.messages`, so Realtime's write-side check refuses it, and the
/// endpoint returns 202 either way (see "Measured, not assumed" below). Its
/// failures are invisible for the same reason this sink's would be.
///
/// This file does NOT change, disable, or fix that producer. Two producers for
/// one topic is a state to resolve, not to leave — but resolving it means
/// deciding whether the Python helper keeps a terminal path at all, which is
/// a larger question than this change. Recorded here so the next reader does
/// not rediscover it as a surprise.
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
/// public sink's direct hop, so this sink batches: chunks arriving
/// within `coalesceWindow` go out as one ordered array.
///
/// Be honest about how much that buys, because the window was copied
/// from the Python producer without checking it against THIS
/// producer's cadence. `ManagedSessionManager.drainIntervalMs` is 50,
/// so a busy session hands us at most ~20 chunks/s. A 60 ms window
/// against a 50 ms arrival rate coalesces roughly 2 chunks, so a
/// continuously-chatty session still costs on the order of 10
/// requests/s — not the order-of-magnitude reduction "coalescing"
/// suggests. What actually bounds the cost today is that this ships
/// dark and applies only to shared attached sessions.
///
/// The single-flight latch below helps more than the window does: while
/// a POST is in flight every arriving chunk accumulates, so under real
/// latency the effective batch grows to whatever arrives during one
/// round trip. Raising `coalesceWindow` is the knob if invocation count
/// ever matters; the ordering guarantee does not depend on it.
///
/// ## What this sink must never do
///
/// It receives `redactedBytes` — `TerminalBroadcastPublisher` has
/// already run `Redactor.redact`. It MUST NOT reach for the raw
/// chunk by any side path; that invariant is pinned upstream by
/// `TerminalBroadcastPublisherTests`.
public actor EdgeRelayPrivateBroadcastSink: TerminalBroadcastSink, PurgeableBroadcastSink {

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
    /// Cap on buffered chunks PER SESSION, drop-oldest on overflow.
    ///
    /// `TerminalBroadcastPublisher` documents the pipeline's bound — "a laggy
    /// sink cannot back-pressure the drain loop" — and enforces it on ITS
    /// queue. That bound cannot reach this buffer: `publish` returns as soon as
    /// it appends here, so the publisher considers the chunk delivered and its
    /// drop-oldest never fires. Without a cap of its own, a relay that is slow
    /// or suppressed accumulates a session's entire output in memory.
    /// Mirrors the publisher's default so the two bounds are legible together.
    public let maxPendingPerSession: Int
    /// Chunks dropped here for exceeding `maxPendingPerSession`. Distinct from
    /// `failedBatches`: these never reached a request.
    public private(set) var droppedForBackpressure = 0

    /// Cap on how much redacted output one relay POST may carry.
    /// Bounds both the edge-function payload and the damage a burst
    /// can do; excess is flushed as a second request, never dropped
    /// here (drop policy belongs to the publisher).
    public let maxBatchBytes: Int
    /// Must not exceed the relay's `MAX_CHUNKS`. The server rejects an
    /// oversized batch WHOLESALE with 400, so a client-side bound that
    /// did not match would turn a burst into total loss for that batch
    /// rather than into two requests.
    public let maxBatchCount: Int
    /// How long a 403 suppresses a session. NOT permanent: the denial
    /// is genuinely user-reversible (an attached session is authorized
    /// only after `set_wrapped_session_cloud_shared`, and Remote
    /// Control can be switched off and back on), so latching forever
    /// would kill the mirror for the exact flow this exists to serve.
    public let denialBackoff: Duration

    private let configProvider: @Sendable () -> HelperConfigStore.CloudConfig
    private let session: URLSession
    /// Sessions suppressed until an instant, after a 403. Bounded in
    /// time rather than permanent — see `denialBackoff`.
    private var deniedUntil: [String: ContinuousClock.Instant] = [:]
    private var pending: [String: [(event: String, bytes: Data)]] = [:]
    /// Per-session PURGE generation, bumped only by `purge`.
    ///
    /// The pattern is lifted verbatim from `EventUploader.purgeGen`, which
    /// exists in this repo for the SAME M4.4d revoke and whose comment records
    /// the exact mistake made here: a pump "must NOT hold a local copy across
    /// the suspension", because doing so "RESURRECTS events removeSession
    /// purged (defeating M4.4d's revoke — the user's revoked output uploads
    /// anyway)".
    ///
    /// `flush` lifts the whole buffer into a local before its first `await`, so
    /// clearing `pending` cannot reach a batch already in flight — which is
    /// precisely the "whatever a slow relay was holding" case `purge` was
    /// written to cover. Capturing this counter at snapshot time and
    /// re-checking it before every `send` makes the purge a BARRIER instead of
    /// a filter.
    private var purgeGen: [String: Int] = [:]
    private var purgeGenCounter = 0
    private var flushTask: Task<Void, Never>?
    /// Single-flight latch. An actor is REENTRANT across `await`, so
    /// without this a chunk arriving during an in-flight POST arms a
    /// second flush that issues a CONCURRENT POST for the same
    /// session — and terminal output arriving out of order is
    /// corruption, not just lateness.
    private var flushing = false

    /// Observable outcome counters. A dark-shipped path with no signal is a
    /// path you cannot evaluate, and "turn it on per-machine and see" needs
    /// something to see. These are read by tests today and are the obvious
    /// hook for a diagnostics line later.
    public private(set) var sentBatches = 0
    public private(set) var failedBatches = 0
    public private(set) var suppressedSessions = 0

    /// Snapshot of the counters, for tests and diagnostics.
    public func stats() -> (sent: Int, failed: Int, suppressed: Int, droppedForBackpressure: Int) {
        (sentBatches, failedBatches, suppressedSessions, droppedForBackpressure)
    }

    /// Discard everything buffered for a session and forget its suppression.
    ///
    /// Called when consent is REVOKED. The visibility gate stops NEW chunks
    /// immediately, but anything already sitting in `pending` would still be
    /// POSTed by the next flush — a window of one coalescing interval plus
    /// whatever a slow relay was holding. `unshareAttachedSession` promises
    /// "from that instant nothing further uploads"; without this, that promise
    /// is approximately true instead of true.
    public func purge(sessionId: String) {
        pending.removeValue(forKey: sessionId)
        deniedUntil.removeValue(forKey: sessionId)
        purgeGenCounter += 1
        purgeGen[sessionId] = purgeGenCounter
    }

    public init(
        configProvider: @escaping @Sendable () -> HelperConfigStore.CloudConfig,
        requestTimeout: TimeInterval = 2.5,
        coalesceWindow: Duration = .milliseconds(60),
        maxBatchBytes: Int = 64 * 1024,
        maxBatchCount: Int = 64,
        maxPendingPerSession: Int = 256,
        denialBackoff: Duration = .seconds(60),
        session: URLSession? = nil
    ) {
        self.configProvider = configProvider
        self.requestTimeout = requestTimeout
        self.coalesceWindow = coalesceWindow
        self.maxBatchBytes = max(1024, maxBatchBytes)
        self.maxBatchCount = max(1, maxBatchCount)
        self.maxPendingPerSession = max(1, maxPendingPerSession)
        self.denialBackoff = denialBackoff
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
        if isDenied(sessionId) { throw SinkError.denied }

        var queue = pending[sessionId] ?? []
        if queue.count >= maxPendingPerSession {
            queue.removeFirst()
            droppedForBackpressure += 1
        }
        queue.append((event: event, bytes: redactedBytes))
        pending[sessionId] = queue
        armFlushIfNeeded()
    }

    private func isDenied(_ sessionId: String) -> Bool {
        guard let until = deniedUntil[sessionId] else { return false }
        if ContinuousClock.now >= until {
            deniedUntil.removeValue(forKey: sessionId)   // bounded: expires
            return false
        }
        return true
    }

    /// Arm the coalescing timer, unless one is already armed or there is
    /// nothing to send. Called after every append AND at the end of a
    /// flush, so a chunk that arrived while a POST was in flight cannot
    /// be stranded until the next unrelated `publish`.
    private func armFlushIfNeeded() {
        guard flushTask == nil, !pending.isEmpty else { return }
        flushTask = Task { [coalesceWindow] in
            try? await Task.sleep(for: coalesceWindow)
            await self.flush()
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
        // SINGLE FLIGHT. Everything below the first `await` runs with actor
        // isolation held, so this check-and-set is atomic. If a flush is
        // already draining, it will pick up whatever we just appended on its
        // next loop iteration — and if it happens to be past that point, the
        // `armFlushIfNeeded()` at its tail re-arms us.
        if flushing { armFlushIfNeeded(); return }
        flushing = true

        while !pending.isEmpty {
            let batches = pending
            pending.removeAll(keepingCapacity: true)
            for (sessionId, items) in batches {
                if isDenied(sessionId) { continue }
                // Captured BEFORE the first suspension, re-checked before every
                // send. A change means the session was purged mid-flush and
                // this batch must be abandoned, not delivered.
                let purgeAtEntry = purgeGen[sessionId]
                var deniedThisPass = false
                for group in Self.split(items, maxBytes: maxBatchBytes, maxCount: maxBatchCount) {
                    // One denial suppresses the SESSION, so the remaining
                    // groups of the same pass must not be sent. The `break`
                    // that did this was lost when the permanent latch became an
                    // expiring one: `isDenied` is checked once per session per
                    // pass, ABOVE this loop, so without this the sink re-POSTs
                    // and re-logs once per group for a session it has just been
                    // told it may not write to.
                    if deniedThisPass { break }
                    // The barrier. Consent was withdrawn while this batch was
                    // already out of `pending`; drop the rest of the tail.
                    if purgeGen[sessionId] != purgeAtEntry { break }
                    do {
                        try await send(sessionId: sessionId, items: group)
                        sentBatches += 1
                    } catch SinkError.denied {
                        deniedUntil[sessionId] = ContinuousClock.now.advanced(by: denialBackoff)
                        suppressedSessions += 1
                        deniedThisPass = true
                        // Log the SUPPRESSION, not every dropped chunk: this is
                        // the transition an operator needs to see, and it is
                        // rate-limited by construction (once per backoff
                        // window). Session id only — never the payload.
                        FileHandle.standardError.write(Data(
                            ("cli_pulse_helper: pterm relay denied session=\(sessionId) "
                             + "— suppressed for \(denialBackoff)\n").utf8))
                    } catch {
                        failedBatches += 1
                        // Transport/5xx: the chunk is gone. Retrying here would
                        // back-pressure the PTY drain loop. Logged only on the
                        // FIRST failure of a run so a flapping network cannot
                        // turn stderr into the firehose the PTY already is.
                        if failedBatches == 1 || failedBatches % 100 == 0 {
                            FileHandle.standardError.write(Data(
                                ("cli_pulse_helper: pterm relay batch failed "
                                 + "(total=\(failedBatches)) session=\(sessionId)\n").utf8))
                        }
                    }
                }
            }
        }

        flushing = false
        armFlushIfNeeded()
    }

    /// Split an ordered run of chunks into batches bounded by BOTH
    /// `maxBytes` and `maxCount`, preserving order. A single chunk
    /// larger than the byte cap becomes its own batch rather than
    /// being silently truncated.
    ///
    /// The count bound is not decoration: the relay rejects a batch of
    /// more than `MAX_CHUNKS` (64) entries WHOLESALE with 400, so a
    /// client that bounded only bytes would turn a burst of small
    /// chunks — the common case for a chatty PTY — into total loss for
    /// that batch. The two constants must stay in step; the relay's is
    /// `MAX_CHUNKS` in broadcast-terminal/request.ts.
    static func split(
        _ items: [(event: String, bytes: Data)],
        maxBytes: Int,
        maxCount: Int
    ) -> [[(event: String, bytes: Data)]] {
        var out: [[(event: String, bytes: Data)]] = []
        var cur: [(event: String, bytes: Data)] = []
        var size = 0
        for item in items {
            if !cur.isEmpty && (size + item.bytes.count > maxBytes || cur.count >= maxCount) {
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
        // 403 is the RPC's authoritative 42501 denial, and the ONLY status
        // that suppresses a session. 5xx is infra — the edge function maps a
        // DB blip to 500 on purpose so this side does not suppress a healthy
        // session.
        //
        // 401 is deliberately NOT a denial, though an earlier cut treated it
        // as one. The relay never emits 401: `classifyAuthorizeResult` yields
        // only 403 or 500, and the handler returns 400/403/405/500/502. A 401
        // can only come from the gateway — a wrong or rotated anon key — which
        // is a GLOBAL configuration fault affecting every session equally, not
        // a statement about this one. Suppressing per-session on it would
        // silently mark each session denied in turn while the real fault went
        // unreported.
        if http.statusCode == 403 {
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
public struct PrivacyRoutingBroadcastSink: TerminalBroadcastSink, PurgeableBroadcastSink {

    /// Forward a purge to whichever sink buffers. Only the private sink does.
    public func purge(sessionId: String) async {
        if let p = privateSink as? PurgeableBroadcastSink {
            await p.purge(sessionId: sessionId)
        }
    }

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
